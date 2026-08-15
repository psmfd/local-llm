// thinking-ab harness — local-llm#44 reconstruction.
// Tool-call fidelity A/B for coding-workhorse: enable_thinking on vs off,
// realistic agentic prompts with a tools array, incl. 10K+ context scenarios.
// Direct against oMLX /v1/chat/completions; no pi involved (the server-level
// lever is what #44 gates; payload-tuner is just the delivery mechanism).
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const BASE = "http://localhost:8000/v1";
const MODEL = "coding-workhorse";
const KEY = readFileSync(join(homedir(), ".omlx", "api-key"), "utf8").trim();
const REPS = Number(process.env.REPS ?? 2);
const OUT = process.env.OUT ?? "results.jsonl";

const TOOLS = [
  { type: "function", function: { name: "read", description: "Read a file from disk. Optionally a line range.", parameters: { type: "object", properties: { path: { type: "string" }, offset: { type: "integer" }, limit: { type: "integer" } }, required: ["path"] } } },
  { type: "function", function: { name: "write", description: "Create or overwrite a file with content.", parameters: { type: "object", properties: { path: { type: "string" }, content: { type: "string" } }, required: ["path", "content"] } } },
  { type: "function", function: { name: "edit", description: "Replace an exact string in a file with a new string.", parameters: { type: "object", properties: { path: { type: "string" }, old_string: { type: "string" }, new_string: { type: "string" } }, required: ["path", "old_string", "new_string"] } } },
  { type: "function", function: { name: "bash", description: "Run a shell command and return its output.", parameters: { type: "object", properties: { command: { type: "string" } }, required: ["command"] } } },
  { type: "function", function: { name: "grep", description: "Search file contents for a regex pattern.", parameters: { type: "object", properties: { pattern: { type: "string" }, path: { type: "string" } }, required: ["pattern"] } } },
];

const SYSTEM = "You are a coding agent working in a TypeScript repository. Use the provided tools to act on the user's request. Call exactly one tool when an action is needed; answer directly in text when no action is needed.";

// ~10K-token context pad: a plausible tool-result transcript prefix.
function pad10k() {
  const chunk = [];
  for (let i = 0; i < 260; i++) {
    chunk.push(`export function helper${i}(input: string): string {\n  // normalize and validate segment ${i}\n  const trimmed = input.trim().toLowerCase();\n  if (trimmed.length === 0) { throw new Error("empty input in helper${i}"); }\n  return trimmed + "-${i}";\n}\n`);
  }
  chunk.push(`// TODO: consolidate the helper functions above into a table-driven design\n`);
  return chunk.join("\n");
}
const BIGFILE = pad10k();

const SCENARIOS = [
  { id: "read-file", user: "Open the file src/config.ts and show me its contents.", expect: { tool: "read", args: /src\/config\.ts/ } },
  { id: "run-tests", user: "Run the test suite.", expect: { tool: "bash", args: /test/ } },
  { id: "grep-usage", user: "Find all usages of the function parseSettings in the repo.", expect: { tool: "grep", args: /parseSettings/ } },
  { id: "edit-word", user: "In README.md replace the word 'colour' with 'color'.", expect: { tool: "edit", args: /README\.md[\s\S]*colour/ } },
  { id: "git-branch", user: "What's the current git branch?", expect: { tool: "bash", args: /git\s+(branch|status|rev-parse)/ } },
  { id: "read-range", user: "Read lines 40 to 60 of scripts/validate.sh.", expect: { tool: "read", args: /validate\.sh/ } },
  { id: "no-tool-fact", user: "What does HTTP status 404 mean? Answer in one sentence.", expect: { tool: null } },
  { id: "write-file", user: "Create a file notes/todo.md with the content 'ship v1'.", expect: { tool: "write", args: /notes\/todo\.md[\s\S]*ship v1/ } },
  { id: "disk-space", user: "How much disk space is free on this machine?", expect: { tool: "bash", args: /\bdf\b|diskutil/ } },
  { id: "install-dep", user: "The tests failed with 'module not found: lodash'. Install the missing dependency.", expect: { tool: "bash", args: /(npm|pnpm|yarn|bun)[\s\S]*(install|add)[\s\S]*lodash/ } },
  { id: "longctx-tool", longctx: true, user: "Now search the repository for other files that also contain the marker TODO.", expect: { tool: "grep", args: /TODO/ } },
  { id: "longctx-notool", longctx: true, user: "Roughly how many helper functions are defined in the file above? Answer with just a number, no tools needed.", expect: { tool: null } },
];

function messagesFor(s) {
  const msgs = [{ role: "system", content: SYSTEM }];
  if (s.longctx) {
    msgs.push({ role: "user", content: "Read the file src/generated/helpers.ts." });
    msgs.push({ role: "assistant", tool_calls: [{ id: "call_ctx1", type: "function", function: { name: "read", arguments: JSON.stringify({ path: "src/generated/helpers.ts" }) } }] });
    msgs.push({ role: "tool", tool_call_id: "call_ctx1", content: BIGFILE });
  }
  msgs.push({ role: "user", content: s.user });
  return msgs;
}

async function callOnce(s, thinking) {
  const body = {
    model: MODEL,
    messages: messagesFor(s),
    tools: TOOLS,
    tool_choice: "auto",
    max_tokens: 1024,
    stream: false,
  };
  if (!thinking) body.chat_template_kwargs = { enable_thinking: false };
  const t0 = performance.now();
  const res = await fetch(`${BASE}/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${KEY}` },
    body: JSON.stringify(body),
  });
  // fetch resolves on headers; the model generates while the body streams.
  // The clock must stop only after the body is fully consumed.
  if (!res.ok) {
    const errText = (await res.text()).slice(0, 300);
    return { ok: false, status: res.status, ms: Math.round(performance.now() - t0), err: errText };
  }
  const j = await res.json();
  const ms = Math.round(performance.now() - t0);
  const msg = j.choices?.[0]?.message ?? {};
  const tcs = msg.tool_calls ?? [];
  let toolName = null, argsRaw = null, argsValid = null;
  if (tcs.length > 0) {
    toolName = tcs[0]?.function?.name ?? null;
    argsRaw = tcs[0]?.function?.arguments ?? "";
    try { JSON.parse(argsRaw); argsValid = true; } catch { argsValid = false; }
  }
  const reasoning = msg.reasoning_content ?? null;
  const content = typeof msg.content === "string" ? msg.content : "";
  return {
    ok: true, ms,
    completion: j.usage?.completion_tokens ?? null,
    prompt: j.usage?.prompt_tokens ?? null,
    nToolCalls: tcs.length, toolName, argsRaw, argsValid,
    reasoningChars: reasoning ? reasoning.length : (content.includes("<think>") ? -1 : 0),
    contentChars: content.length,
  };
}

function score(s, r) {
  if (!r.ok) return { wellFormed: false, correct: false };
  if (s.expect.tool === null) {
    const noTool = r.nToolCalls === 0;
    return { wellFormed: true, correct: noTool };
  }
  const wellFormed = r.nToolCalls >= 1 && r.argsValid === true;
  const correct = wellFormed && r.toolName === s.expect.tool && (!s.expect.args || s.expect.args.test(r.argsRaw));
  return { wellFormed, correct };
}

const rows = [];
for (const arm of ["thinking-on", "thinking-off"]) {
  for (const s of SCENARIOS) {
    for (let rep = 0; rep < REPS; rep++) {
      const r = await callOnce(s, arm === "thinking-on");
      const sc = score(s, r);
      const row = { arm, id: s.id, rep, ...r, ...sc };
      rows.push(row);
      console.log(`${arm} ${s.id} rep${rep}: ok=${r.ok} tool=${r.toolName ?? "-"} correct=${sc.correct} ms=${r.ms} ctok=${r.completion ?? "?"}`);
    }
  }
}
writeFileSync(OUT, rows.map((r) => JSON.stringify(r)).join("\n") + "\n");

for (const arm of ["thinking-on", "thinking-off"]) {
  const a = rows.filter((r) => r.arm === arm);
  const n = a.length;
  const correct = a.filter((r) => r.correct).length;
  const wf = a.filter((r) => r.wellFormed).length;
  const meanMs = Math.round(a.reduce((x, r) => x + r.ms, 0) / n);
  const meanTok = Math.round(a.reduce((x, r) => x + (r.completion ?? 0), 0) / n);
  console.log(`SUMMARY ${arm}: correct ${correct}/${n}, well-formed ${wf}/${n}, mean latency ${meanMs}ms, mean completion ${meanTok} tok`);
}
