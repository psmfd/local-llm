# Wiring oMLX into the .NET `IInferenceBackend` / `FallbackInferenceRouter`

This note shows how to register the local oMLX server as one `IInferenceBackend`
behind your `FallbackInferenceRouter`, routing the three local tiers
(`coding-fast`, `coding-balanced`, `coding-quality`) → oMLX and falling through to
a remote backend on failure or saturation.

> **Forward direction — [ADR-009](../adrs/009-mac-single-workhorse-cloud-frontier.md)
> (additive, pending implementation #14).** A reframe collapses the Mac to a
> *single* GLM-4.7-Flash workhorse (local executor) with the **cloud as the
> frontier/quality tier** and the AMD peer repurposed. See
> [ADR-009 forward direction](#adr-009-forward-direction-single-workhorse-cloud-frontier)
> below; the ADR-006/008 multi-tier wiring described first remains the implemented
> state until #14 lands.

- **Endpoint:** `http://localhost:8000/v1` (OpenAI-style `POST /v1/chat/completions`).
  oMLX also serves Anthropic-style `POST /v1/messages`; this note uses the
  OpenAI chat-completions shape.
- **Auth:** bearer key read once at startup from `OMLX_API_KEY`, else from the
  0600 file `~/.omlx/api-key`. **Never hardcode the key.**
- **Aliases:** the `model` field carries the oMLX alias. This host serves three
  tiers ([ADR-006](../adrs/006-multi-tier-coresident-lineup-stay-on-omlx.md)):
  `coding-fast` + `coding-balanced` are pinned co-resident; `coding-quality` is the
  **on-demand** max tier (Qwen3-Coder-Next, lazy-loaded ~16 s on first request).
  Keep a remote backend as the fallback after the local tiers. Aliases/pins are
  applied by `setup-omlx-m5.sh` via the admin API.
- **Concurrency:** typed `HttpClient` via `IHttpClientFactory` +
  `AddStandardResilienceHandler` so a local hiccup degrades into the fallback
  router rather than throwing.

> **Interface assumption.** No source exists for `IInferenceBackend` /
> `FallbackInferenceRouter` here, so the shapes below are assumed. Adjust method
> signatures to the real contract — the structural pattern is unchanged. The
> snippet uses the "throw a typed `InferenceUnavailableException`" path; switch to
> an `IsAvailable=false` return if your router prefers that.

## Assumed contract

```csharp
public enum ModelRole { Fast, Balanced, Quality }
public sealed record ChatMessage(string Role, string Content);
public sealed record InferenceRequest(ModelRole Role, IReadOnlyList<ChatMessage> Messages, float? Temperature = null);
public sealed record InferenceResponse(string Content, bool IsAvailable);

public sealed class InferenceUnavailableException(string message, Exception? inner = null)
    : Exception(message, inner);

public interface IInferenceBackend
{
    string Name { get; }
    Task<InferenceResponse> CompleteAsync(InferenceRequest request, CancellationToken cancellationToken = default);
}
```

## Configuration (no secrets in appsettings)

```json
{
  "Omlx": {
    "BaseUrl": "http://localhost:8000",
    "ApiKeyFilePath": "~/.omlx/api-key"
  }
}
```

`OMLX_API_KEY` (env var) takes precedence over the file path. Resolve once at
startup (not per-request):

```csharp
internal static class OmlxApiKeyResolver
{
    internal static string Resolve(IConfiguration configuration)
    {
        string? envKey = configuration["OMLX_API_KEY"];
        if (!string.IsNullOrWhiteSpace(envKey)) return envKey;

        string rawPath = configuration["Omlx:ApiKeyFilePath"] ?? "~/.omlx/api-key";
        // Expand a leading "~/" (or a bare "~") only — "~user/" is not supported.
        // Guarding the bare "~" avoids an ArgumentOutOfRangeException on rawPath[2..].
        string path = rawPath == "~" || rawPath.StartsWith("~/")
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                rawPath.Length > 2 ? rawPath[2..] : string.Empty)
            : rawPath;

        if (!File.Exists(path))
            // Keep the resolved path OUT of the exception message — it can leak a
            // home-directory path into shared log sinks. Log it at Debug if needed.
            throw new InvalidOperationException(
                "oMLX API key not found. Set OMLX_API_KEY or provide a readable key file (mode 0600).");

        return File.ReadAllText(path).Trim();
    }
}
```

## Backend

```csharp
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

internal sealed record OmlxMessage([property: JsonPropertyName("role")] string Role,
                                   [property: JsonPropertyName("content")] string Content);
internal sealed record OmlxChatRequest([property: JsonPropertyName("model")] string Model,
                                       [property: JsonPropertyName("messages")] IReadOnlyList<OmlxMessage> Messages,
                                       [property: JsonPropertyName("temperature"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] float? Temperature);
internal sealed record OmlxChoice([property: JsonPropertyName("message")] OmlxMessage Message);
internal sealed record OmlxChatResponse([property: JsonPropertyName("choices")] IReadOnlyList<OmlxChoice> Choices);

public sealed class OmlxInferenceBackend(HttpClient httpClient, ILogger<OmlxInferenceBackend> logger)
    : IInferenceBackend
{
    // Logical role → oMLX model alias (the "model" field).
    private static readonly Dictionary<ModelRole, string> ModelAliases = new()
    {
        [ModelRole.Fast]     = "coding-fast",
        [ModelRole.Balanced] = "coding-balanced",
        [ModelRole.Quality]  = "coding-quality",   // on-demand: first call lazy-loads (~16 s)
    };

    // No global DefaultIgnoreCondition: the property-level [JsonIgnore] on the
    // nullable Temperature already omits it when null, and a global WhenWritingNull
    // is a latent trap (it throws if a non-nullable value-type member is added).
    private static readonly JsonSerializerOptions JsonOptions = new();

    public string Name => "omlx-local";

    public async Task<InferenceResponse> CompleteAsync(InferenceRequest request, CancellationToken ct = default)
    {
        if (!ModelAliases.TryGetValue(request.Role, out string? alias))
            throw new ArgumentOutOfRangeException(nameof(request), request.Role, "No oMLX alias for role.");

        var wire = new OmlxChatRequest(
            alias,
            request.Messages.Select(m => new OmlxMessage(m.Role, m.Content)).ToList(),
            request.Temperature);

        try
        {
            using HttpResponseMessage resp =
                // Path-relative (no leading slash) so it composes onto a BaseAddress
                // that may carry a path prefix (a leading slash would discard it).
                await httpClient.PostAsJsonAsync("v1/chat/completions", wire, JsonOptions, ct);

            if (!resp.IsSuccessStatusCode)
            {
                logger.LogWarning("oMLX returned {Status} for {Role}.", (int)resp.StatusCode, request.Role);
                throw new InferenceUnavailableException($"oMLX returned HTTP {(int)resp.StatusCode}.");
            }

            OmlxChatResponse? body = await resp.Content.ReadFromJsonAsync<OmlxChatResponse>(JsonOptions, ct);
            string content = body?.Choices.FirstOrDefault()?.Message.Content
                ?? throw new InferenceUnavailableException("oMLX response contained no choices.");

            return new InferenceResponse(content, IsAvailable: true);
        }
        catch (InferenceUnavailableException) { throw; }
        // OperationCanceledException already covers TaskCanceledException (its subclass),
        // so listing both is redundant. (If you need to distinguish caller-cancellation
        // from a timeout, rethrow when ct.IsCancellationRequested before wrapping.)
        catch (Exception ex) when (ex is HttpRequestException
                                      or OperationCanceledException
                                      or Polly.CircuitBreaker.BrokenCircuitException)
        {
            logger.LogWarning(ex, "oMLX local backend unavailable for {Role}.", request.Role);
            throw new InferenceUnavailableException("oMLX local backend unavailable.", ex);
        }
    }
}
```

## DI registration (`Program.cs`)

```csharp
using System.Net.Http.Headers;
using Microsoft.Extensions.Options;

// Options bound from the "Omlx" config section.
public sealed class OmlxOptions
{
    public string BaseUrl { get; init; } = "http://localhost:8000";
    public string ApiKeyFilePath { get; init; } = "~/.omlx/api-key";
}

builder.Services.Configure<OmlxOptions>(builder.Configuration.GetSection("Omlx"));

// Resolve the key once — fail fast if absent.
string omlxApiKey = OmlxApiKeyResolver.Resolve(builder.Configuration);

// 1. The concrete typed client. AddHttpClient<T> registers T as TRANSIENT with a
//    factory-managed HttpClient (handler rotation preserved). Do NOT also register
//    T against the interface with AddSingleton — that overwrites this registration
//    with a plain `new HttpClient()` (no BaseAddress/auth/resilience) and captures
//    the handler forever. See the Gotchas section.
builder.Services.AddHttpClient<OmlxInferenceBackend>((sp, client) =>
    {
        var opts = sp.GetRequiredService<IOptions<OmlxOptions>>().Value;
        client.BaseAddress = new Uri(opts.BaseUrl.TrimEnd('/') + "/"); // trailing slash matters
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", omlxApiKey);
        // Cede ALL timeout control to the resilience pipeline below. The default
        // 100 s HttpClient.Timeout would fire before AttemptTimeout, producing a
        // TaskCanceledException that bypasses Polly's timeout telemetry.
        client.Timeout = Timeout.InfiniteTimeSpan;
    })
    .AddStandardResilienceHandler(static o =>
    {
        o.Retry.DisableForUnsafeHttpMethods();          // chat completions are NOT idempotent
        // Validation constraint: SamplingDuration >= 2 * AttemptTimeout.Timeout,
        // and TotalRequestTimeout >= AttemptTimeout. Large-model decode is slow, so
        // AttemptTimeout is generous; the rest is sized to satisfy the validator.
        o.AttemptTimeout.Timeout           = TimeSpan.FromSeconds(120);
        o.CircuitBreaker.SamplingDuration  = TimeSpan.FromSeconds(300); // >= 2 * 120
        o.CircuitBreaker.BreakDuration     = TimeSpan.FromSeconds(30);
        o.CircuitBreaker.MinimumThroughput = 3;         // local server: the default 100 never trips
        o.TotalRequestTimeout.Timeout      = TimeSpan.FromSeconds(300); // >= AttemptTimeout
    });

// 2. Bridge the concrete typed client to IInferenceBackend with a TRANSIENT factory
//    delegate. Each resolution pulls a fresh OmlxInferenceBackend (and a pooled
//    HttpClient) from the factory, preserving handler rotation. Registration order
//    is preserved, so IEnumerable<IInferenceBackend> yields oMLX first.
//    (AddHttpClient<IInferenceBackend, OmlxInferenceBackend> is NOT used: multiple
//    typed clients sharing one interface collide on the named-client key — dotnet/runtime #110996.)
builder.Services.AddTransient<IInferenceBackend>(
    static sp => sp.GetRequiredService<OmlxInferenceBackend>());

// 3. Other backends follow the same concrete-client + transient-bridge pattern:
// builder.Services.AddHttpClient<RemoteAnthropicBackend>(/* ... */).AddStandardResilienceHandler(/* ... */);
// builder.Services.AddTransient<IInferenceBackend>(static sp => sp.GetRequiredService<RemoteAnthropicBackend>());

// 4. The router consumes IEnumerable<IInferenceBackend>. Register it Transient (or
//    Scoped) — never Singleton, or it captures the transient backends and defeats
//    handler rotation.
builder.Services.AddTransient<FallbackInferenceRouter>();
```

## Router ordering

> **Revised by [ADR-008](../adrs/008-cross-host-routing-integration.md) for the
> two-host topology** — see [Cross-host topology](#cross-host-topology-adr-008) below.
> With the AMD peer present, the AMD backend registers *first* and serves
> `coding-fast` only; oMLX serves `coding-balanced`/`coding-quality` and is the
> fast-role fallback. The single-host narrative here still describes the oMLX side.

- **Order = priority.** Register oMLX first; the router iterates registration
  order, so the local backend is primary for every role. It catches
  `InferenceUnavailableException` and advances to the next backend.
- **Role routing.** All three roles map through the alias dictionary to local oMLX
  tiers (ADR-006). `coding-fast` and `coding-balanced` are pinned co-resident, so
  they answer immediately. `coding-quality` (Qwen3-Coder-Next) is **on-demand**:
  oMLX lazy-loads it on the first request (~16 s), so that call is slow — size the
  resilience `AttemptTimeout` to tolerate it, or pre-warm with a throwaway request.
  If a tier ever errors (e.g. transient load failure) it is wrapped as
  `InferenceUnavailableException` → fallback to the next backend.
- **Saturation.** oMLX runs at `--max-concurrent-requests 16`; a 429 trips the
  circuit breaker, diverting traffic to the remote backend until it recovers.

## Cross-host topology (ADR-008)

With the always-on **AMD vLLM appliance** added as a second endpoint, the router is
no longer single-host. Register the AMD backend **first** and the Mac oMLX backend
second:

- `coding-fast` → **AMD vLLM** primary; on `InferenceUnavailableException` →
  **Mac oMLX T1** (still co-resident, zero-swap) → cloud.
- `coding-balanced` → AMD throws `InferenceUnavailableException` (it serves only
  `coding-fast`) → **Mac oMLX T2** → cloud.
- `coding-quality` → AMD can't fit the ~45 GB max tier → **Mac oMLX** on-demand → cloud.

The AMD backend's alias dictionary contains only `coding-fast`; every other role
throws `InferenceUnavailableException` so the chain advances — which is why **both**
backends must throw that exception type (not `ArgumentOutOfRangeException`) for
unserved roles. See [ADR-008](../adrs/008-cross-host-routing-integration.md).

## ADR-009 forward direction: single workhorse, cloud frontier

[ADR-009](../adrs/009-mac-single-workhorse-cloud-frontier.md) is **additive and not
yet implemented** (tracked in #14); the wiring above stays in force until then. The
forward target:

- **Local Mac = one pinned GLM-4.7-Flash workhorse** serving the executor roles;
  the AMD peer (ADR-008) is repurposed/deprecated.
- **Cloud = the frontier**: the high-fidelity `coding-quality` role routes to a
  cloud backend, not a local tier.

Collapse the three local aliases to one workhorse model, and let the quality role
fall through to the cloud frontier backend:

```csharp
// oMLX workhorse backend: executor roles all map to the single pinned model.
private static readonly Dictionary<ModelRole, string> ModelAliases = new()
{
    [ModelRole.Fast]     = "coding-workhorse",   // single GLM-4.7-Flash alias
    [ModelRole.Balanced] = "coding-workhorse",
    // Quality is NOT served locally — omit it so the role throws
    // InferenceUnavailableException and the chain advances to the cloud frontier.
};
```

Router ordering under ADR-009:

- `coding-fast` / `coding-balanced` → **Mac oMLX workhorse** primary → cloud fallback.
- `coding-quality` → Mac throws `InferenceUnavailableException` (no local quality
  tier) → **cloud frontier** backend (registered for the quality role).

Serving/resilience notes specific to the workhorse:

- oMLX runs `--max-concurrent-requests 10` (**"The Mark"**, validated on-host; the
  safe ceiling falls as shared-prefix context grows — clean to N≥15 @ ~9K ctx but
  10 @ ~16K, so keep subagent prefixes modest). A 429 or a memory-guard 500 trips
  the circuit breaker → cloud.
- GLM-4.7-Flash emits a **reasoning preamble before tool calls**; keep `max_tokens`
  ≥ ~200 on tool-bearing requests so the call is not truncated, and keep
  `AttemptTimeout` generous (no ~16 s cold-load tier anymore, but decode + preamble
  still take time).

## Tool-call schema-validate-and-retry guard

A small local workhorse occasionally emits a malformed tool call (invalid JSON
arguments) or — if `max_tokens` is too low — truncates before completing it. A
single malformed call breaks an agent pipeline silently. Wrap tool-bearing
completions in a validate-and-retry loop at the dispatcher: parse the call,
validate its arguments against the tool's JSON schema, and on failure re-issue once
with a structured corrective message before falling through.

```csharp
// Sketch — assumes the backend surfaces tool_calls and you hold the tool's
// argument schema. Validates the arguments JSON; retries once on failure.
public async Task<InferenceResponse> CompleteWithToolGuardAsync(
    InferenceRequest request, Func<string, bool> argumentsAreValid, CancellationToken ct = default)
{
    var messages = request.Messages.ToList();
    for (int attempt = 0; attempt < 2; attempt++)
    {
        InferenceResponse resp = await CompleteAsync(request with { Messages = messages }, ct);

        // Adapt extraction to your wire shape; a null/empty call or invalid-JSON
        // arguments is the failure we retry on.
        string? toolArgs = TryExtractToolArguments(resp);
        if (toolArgs is not null && argumentsAreValid(toolArgs))
            return resp;

        if (attempt == 0)
        {
            // One corrective turn: name what was wrong, demand a single clean call.
            messages.Add(new ChatMessage("assistant", resp.Content));
            messages.Add(new ChatMessage("user",
                "The previous tool call was missing or had invalid JSON arguments. " +
                "Return exactly one well-formed tool call matching the schema, with no other text."));
            continue;
        }

        // Both attempts failed — advance to the next backend rather than pass a
        // malformed call downstream.
        throw new InferenceUnavailableException("Workhorse returned no valid tool call after one retry.");
    }
    throw new InvalidOperationException("unreachable");
}
```

Notes:

- Keep the retry count at **one** — the failure is usually a truncation or a
  formatting slip the corrective turn fixes; more retries waste a fan-out slot.
- Validate against the **actual tool schema** (required fields, types), not merely
  "is it JSON" — the common GLM failure is a complete-but-wrong-shape object.
- Pair with generous `max_tokens` (above); truncation is the most common cause of a
  missing call.

## Gotchas

- **Do not also `AddSingleton<IInferenceBackend, OmlxInferenceBackend>()`.** That
  overwrites the `AddHttpClient<T>` registration with a plain-constructed instance
  holding an unconfigured `HttpClient` (no `BaseAddress`, auth, or resilience) and
  pins its handler forever (a captive dependency that defeats rotation). Use the
  transient factory bridge (step 2). Likewise keep `FallbackInferenceRouter`
  transient/scoped, never singleton.
- **Resilience options are validated at startup.** `SamplingDuration ≥ 2 ×
  AttemptTimeout` and `TotalRequestTimeout ≥ AttemptTimeout`; violating either
  throws `OptionsValidationException` before the first request. The values in
  step 1 satisfy both.
- **Timeouts:** `client.Timeout = Timeout.InfiniteTimeSpan` hands all timeout
  authority to the pipeline. Leaving the 100 s default would fire before
  `AttemptTimeout` and produce a `TaskCanceledException` that bypasses Polly's
  timeout telemetry and the circuit-breaker sample.
- `BrokenCircuitException` lives in `Polly.CircuitBreaker` (Polly v8, used by
  `Microsoft.Extensions.Http.Resilience` 8+). Verify the namespace against your
  pinned version.
- Requires the `Microsoft.Extensions.Http.Resilience` NuGet package.

*Source: synthesized from `dotnet-expert` against .NET 10 LTS guidance
(`learn.microsoft.com` HTTP resilience + `IHttpClientFactory` docs).*
