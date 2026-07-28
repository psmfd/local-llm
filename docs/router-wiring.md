# Wiring oMLX into the .NET `IInferenceBackend` / `FallbackInferenceRouter`

This note shows how to register the local oMLX server as one `IInferenceBackend`
behind your `FallbackInferenceRouter`, routing the executor roles to the single
local **workhorse** (`coding-workhorse`, [ADR-009](../adrs/009-mac-single-workhorse-cloud-frontier.md))
and the quality role to a **cloud frontier** backend.

- **Endpoint:** `http://localhost:8000/v1` (OpenAI-style `POST /v1/chat/completions`).
  oMLX also serves Anthropic-style `POST /v1/messages`; this note uses the
  OpenAI chat-completions shape.
- **Auth:** bearer key read once at startup from `OMLX_API_KEY`, else from the
  0600 file `~/.omlx/api-key`. **Never hardcode the key.**
- **Aliases:** the `model` field carries the oMLX alias. This host serves one
  pinned model ([ADR-009](../adrs/009-mac-single-workhorse-cloud-frontier.md),
  quant per [ADR-010](../adrs/010-6bit-workhorse-sustained-mark.md)):
  `coding-workhorse` (GLM-4.7-Flash-6bit, sole resident). The high-fidelity
  quality role is **not served locally** — it routes to the cloud frontier.
  The alias/pin is applied by `setup-omlx-m5.sh` via the admin API.
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
// MaxTokens: tool-bearing requests against the workhorse need >= ~200 (GLM emits
// a reasoning preamble before the tool call — ADR-009); expose it end-to-end.
public sealed record InferenceRequest(ModelRole Role, IReadOnlyList<ChatMessage> Messages, float? Temperature = null, int? MaxTokens = null);
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
                                       [property: JsonPropertyName("temperature"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] float? Temperature,
                                       [property: JsonPropertyName("max_tokens"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? MaxTokens);
internal sealed record OmlxChoice([property: JsonPropertyName("message")] OmlxMessage Message);
internal sealed record OmlxChatResponse([property: JsonPropertyName("choices")] IReadOnlyList<OmlxChoice> Choices);

public sealed class OmlxInferenceBackend(HttpClient httpClient, ILogger<OmlxInferenceBackend> logger)
    : IInferenceBackend
{
    // Logical role → oMLX model alias (the "model" field). Executor roles all
    // map to the single pinned workhorse (ADR-009). Quality is deliberately
    // ABSENT: the role must fall through to the cloud frontier backend.
    private static readonly Dictionary<ModelRole, string> ModelAliases = new()
    {
        [ModelRole.Fast]     = "coding-workhorse",   // single GLM-4.7-Flash alias
        [ModelRole.Balanced] = "coding-workhorse",
    };

    // No global DefaultIgnoreCondition: the property-level [JsonIgnore] on the
    // nullable Temperature already omits it when null, and a global WhenWritingNull
    // is a latent trap (it throws if a non-nullable value-type member is added).
    private static readonly JsonSerializerOptions JsonOptions = new();

    public string Name => "omlx-local";

    public async Task<InferenceResponse> CompleteAsync(InferenceRequest request, CancellationToken ct = default)
    {
        // A role this backend does not serve (Quality) must throw
        // InferenceUnavailableException — NOT ArgumentOutOfRangeException — or the
        // FallbackInferenceRouter never advances to the cloud frontier backend.
        if (!ModelAliases.TryGetValue(request.Role, out string? alias))
            throw new InferenceUnavailableException($"oMLX does not serve the {request.Role} role.");

        var wire = new OmlxChatRequest(
            alias,
            request.Messages.Select(m => new OmlxMessage(m.Role, m.Content)).ToList(),
            request.Temperature,
            request.MaxTokens);

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

// 3. The cloud frontier backend (serves the Quality role; also the fallback for
//    the executor roles) follows the same concrete-client + transient-bridge pattern:
// builder.Services.AddHttpClient<CloudFrontierBackend>(/* ... */).AddStandardResilienceHandler(/* ... */);
// builder.Services.AddTransient<IInferenceBackend>(static sp => sp.GetRequiredService<CloudFrontierBackend>());

// 4. The router consumes IEnumerable<IInferenceBackend>. Register it Transient (or
//    Scoped) — never Singleton, or it captures the transient backends and defeats
//    handler rotation.
builder.Services.AddTransient<FallbackInferenceRouter>();
```

## Router ordering (ADR-009)

- **Order = priority.** Register oMLX first, the cloud frontier backend second;
  the router iterates registration order. It catches
  `InferenceUnavailableException` and advances to the next backend.
- **Role routing.** `Fast` / `Balanced` → **Mac oMLX workhorse** primary → cloud
  fallback. `Quality` → oMLX throws `InferenceUnavailableException` (no local
  quality tier — the alias dictionary omits the role) → **cloud frontier**.
- **Saturation.** oMLX runs at `--max-concurrent-requests 4` (**the
  large-context mark**,
  [ADR-012](../adrs/012-concurrency-mark-4-large-context.md):
  [ADR-010](../adrs/010-6bit-workhorse-sustained-mark.md)'s mark of 8 was
  measured at ~16K contexts, but real 25–45K agentic streams oversubscribe the
  ~83K-token shared KV pool ~3× — 2026-07-26 incident; at 4, matching the pi
  subagent spawn cap, excess requests queue at admission and consume no KV).
  **Saturation surfaces as HTTP `400`, not 429/503**: when the memory guard's
  preflight rejects, the body carries
  `"oMLX prefill memory guard rejected this prompt"`. The router MUST treat that
  specific 400 as a **capacity signal** — retry with backoff or trip the circuit
  breaker and divert to the cloud frontier — never as a permanent client error
  (a generic 400 without that marker remains a real client error). A 429 or a
  memory-guard 500 still trips the breaker as before.
- **max_tokens.** GLM-4.7-Flash emits a **reasoning preamble before tool calls**;
  set `InferenceRequest.MaxTokens` ≥ ~200 on tool-bearing requests so the call is
  not truncated, and keep `AttemptTimeout` generous (no cold-load tier anymore,
  but decode + preamble still take time).

> **Historical note.** Earlier revisions of this doc described the ADR-006
> three-tier wiring (`coding-fast`/`coding-balanced`/`coding-quality` all local)
> and the ADR-008 two-host AMD topology. Both ADRs are superseded by
> [ADR-009](../adrs/009-mac-single-workhorse-cloud-frontier.md); see git history
> for the retired wiring.

## Tool-call schema-validate-and-retry guard

A small local workhorse occasionally emits a malformed tool call (invalid JSON
arguments) or — if `max_tokens` is too low — truncates before completing it. A
single malformed call breaks an agent pipeline silently. Wrap tool-bearing
completions in a validate-and-retry loop: parse the call, validate its arguments
against the tool's JSON schema, and on failure re-issue once with a structured
corrective message before falling through.

**This guard wraps a single `IInferenceBackend` (the workhorse), not the
`FallbackInferenceRouter`.** Implement it as a method on (or decorator around)
`OmlxInferenceBackend`, so the corrective retry re-targets the same local model.
Wrapped around the router instead, the first failure could already have failed
over to the cloud backend, and the "retry" would never re-exercise the workhorse.
The terminal `InferenceUnavailableException` is what hands the request to the
router's next backend.

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
