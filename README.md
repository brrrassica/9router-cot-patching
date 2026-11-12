# 9router CoT patch

Makes **streaming chain-of-thought** reach the client for custom
`openai-compatible-*` connections in [9Router](https://github.com/decolua/9router).

A ~1500-byte, idempotent, fail-open boot script plus a one-line entrypoint change.
No fork, no rebuild, no image hacking.

Verified against `decolua/9router:latest` = app **v0.5.116**.

---

## Problem statement

9Router passes provider SSE through more or less verbatim (`mode === "passthrough"`).
OpenAI-shaped clients look for thinking text under one field name:

```json
{"delta": {"reasoning_content": "We"}}
```

But OpenRouter-backed models stream it under the **OpenRouter aliases** instead:

```json
{"delta": {
  "reasoning": "We",
  "reasoning_details": [{"index": 0, "type": "reasoning.text", "text": "We"}]
}}
```

`reasoning` and `reasoning_details[]` are not OpenAI wire format. So a client that
only reads `reasoning_content` sees **nothing** — the model thinks, the tokens
arrive, and the thinking is silently dropped on the floor.

9Router already knows how to fix this. `open-sse/utils/stream.js` has an alias-lift
step (`Wy` / `liftAliases`) that copies `reasoning` / `reasoning_details[]` into
`reasoning_content` on every passthrough delta. But it is gated:

```js
// open-sse/utils/stream.js:106
const liftAliases =
  mode === STREAM_MODE.PASSTHROUGH &&
  !!PROVIDERS[provider]?.quirks?.reasoningAliasFields;
```

The gate is a **static registry lookup**. `PROVIDERS` is built once at import time
from `open-sse/providers/registry/{id}.js` (`open-sse/providers/index.js`):

```js
export const PROVIDERS = {};
for (const entry of REGISTRY) {
  if (entry.transport) PROVIDERS[entry.id] = buildTransport(entry.transport, entry.oauth);
  ...
}
```

Only providers with a **file on disk** get a key. Exactly one declares the quirk
(`open-sse/providers/registry/opencode.js:35`, for OpenCode Free's MiMo route):

```js
quirks: {
  reasoningAliasFields: true,
},
```

Custom connections are named `openai-compatible-<uuid>` at runtime and have no
registry file. Confirmed in the v0.5.116 image:

```
total providers: 101
compat keys: []
PROVIDERS["openai-compatible-abc"]?.quirks?.reasoningAliasFields  ->  undefined
```

### Why only *some* lanes work

| Lane | Gate | CoT |
|---|---|---|
| `openrouter` | streams `reasoning_content` natively | works — lift would be a no-op |
| `oc/*` (OpenCode Free) | `opencode.js` sets `reasoningAliasFields: true` | works |
| **`openai-compatible-*`** | **key never exists in `PROVIDERS`** | **dropped** |

So the bug is **not** "streaming loses reasoning". It is narrower and nastier:
**the lift is keyed on an identity the dynamic providers can never have.**
The `openrouter` lane is unaffected for an unrelated reason (it doesn't need the
lift at all), which is why the failure looks model-specific instead of structural.

### Why non-streaming "works"

The non-streaming path doesn't consult the gate. `nonStreamingHandler.js:41` reads
both names directly:

```js
const reasoning = message.reasoning_content || message.reasoning;
```

So the same request returns `reasoning` fine when `stream: false` and silently
loses it when `stream: true`. A very confusing pair of observations.

---

## The patch

One condition, widened so runtime-named compat providers qualify:

```diff
- U = b===p && !!f.xq[s]?.quirks?.reasoningAliasFields
+ U = b===p && (!!f.xq[s]?.quirks?.reasoningAliasFields
+               || "string"==typeof s && s.startsWith("openai-compatible-"))
```

Read as uncompiled source (`open-sse/utils/stream.js:106`):

```js
const liftAliases =
  mode === STREAM_MODE.PASSTHROUGH &&
  (!!PROVIDERS[provider]?.quirks?.reasoningAliasFields ||
   (typeof provider === "string" && provider.startsWith("openai-compatible-")));
```

Applied to the built server bundle. In v0.5.116 the gate is minified into
`/app/.next/server/chunks/8895.js` as:

```js
U=b===p&&!!f.xq[s]?.quirks?.reasoningAliasFields
```

Full script: [`patch/apply.mjs`](patch/apply.mjs).

### Why it was done this way

`PROVIDERS` is built at import time from registry files, so there is no
runtime or config seam for a dynamic provider to opt in. The choices were:

| Approach | Verdict |
|---|---|
| Fork 9router and rebuild | correct fix, but heavy: own image, own CI, upstream drift |
| Register a fake `openai-compatible-*` key | no seam — `PROVIDERS` is import-time and frozen-ish |
| `NODE_OPTIONS=--require` preload | mutates ESM namespace, breaks under Next's bundle |
| **Patch the minified gate at boot** | smallest diff, no build, trivially reversible |

The boot patch wins because the affected surface is **one boolean expression**, and
it's fail-open by construction: if a future image renames the chunk or rewords the
gate, the script warns and boots unpatched rather than crashing the router.

### Properties

- **Idempotent** — detects the already-patched form; second run is
  `0 patched, 1 already patched`.
- **Scoped** — requires exactly **one** occurrence of the gate string before
  writing; ambiguous matches are skipped, not guessed.
- **Fail-open** — the whole body is wrapped in `try/catch`, always exits 0, and the
  entrypoint uses `;` not `&&`. A patch failure can never block boot.
- **Survives restarts** — the script lives on the mounted volume
  (`./data/patch/apply.mjs`), so it re-applies to the fresh writable layer on every
  start, including after an image pull.
- **Additive only** — `reasoning` and `reasoning_details[]` are **preserved**;
  `reasoning_content` is added alongside. Nothing downstream loses a field.

---

## Install

```bash
# 1. drop the script onto the data volume
mkdir -p data/patch
cp patch/apply.mjs data/patch/apply.mjs

# 2. one line in docker-compose.yml (exec form, so node stays PID 1)
#    entrypoint: ["/bin/sh", "-c", "node /app/data/patch/apply.mjs; exec node custom-server.js"]

# 3. recreate (NOT restart — see below)
docker compose up -d --force-recreate 9router
```

Or `./install.sh install` to copy the file and print the exact line.
[`compose.example.yml`](compose.example.yml) is a full working service block.

### Verify

```bash
docker logs 9router | grep cot-patch
# [cot-patch] patched /app/.next/server/chunks/8895.js
# [cot-patch] done: 1 patched, 0 already patched

docker exec 9router md5sum /app/.next/server/chunks/8895.js
# 0d292a15c4a3356ff2d2941048f39bc7   (stock v0.5.116: 2f02c3c8d1258bf00647fd0abc0ff279)
```

Then check a stream for real: [`verify/verify-cot.sh`](verify/verify-cot.sh)

```bash
BASE=http://127.0.0.1:20128 KEY=sk-... MODEL=amr-link/your-model ./verify/verify-cot.sh
```

### Uninstall

```bash
./install.sh restore                  # removes the script
# revert the entrypoint line in compose, then
docker compose up -d --force-recreate 9router
```

`./install.sh status` shows version, boot-log line, chunk md5 and patched state.

---

## Observed results (v0.5.116)

Streaming request to `amr-link/deepseek-v4.1-flash`, `max_tokens: 60`:

| Check | Before | After |
|---|---|---|
| `reasoning_content` deltas | **0** | **21** |
| aliases still present | `reasoning`, `reasoning_details` | all three coexist |
| non-stream response | `reasoning` + `reasoning_details` | unchanged |
| non-reasoning model (`claude-haiku-5.5`) | no `reasoning_content` | still 0 — no false injection |
| chunk md5 | `2f02c3c8…` | `0d292a15…` |
| restart | — | `0 patched, 1 already patched`, md5 stable |
| `GET /api/health` | 200 | 200 |

A patched delta:

```json
{"delta":{
  "reasoning":"We",
  "reasoning_details":[{"index":0,"type":"reasoning.text","text":"We"}],
  "reasoning_content":"We"
}}
```

---

## Caveats

**`restart` does not revert it.** A patch is written into the container's writable
layer, which survives `docker compose restart`. Use `--force-recreate` to toggle.

**Image upgrades are detected, not auto-fixed.** If `decolua/9router` changes the
chunk name or the minified gate wording, `apply.mjs` logs:

```
[cot-patch] WARNING: gate not found. Expected md5 2f02c3c8... CoT lifting is OFF.
```

The router still boots; CoT silently stops. **After every image upgrade, check
`docker logs 9router | grep cot-patch`.** To re-target, update `ORIG`/`PATCHED` in
`apply.mjs` — the strings are stable across v0.5.116 and readable in the image's
`/app/open-sse/utils/stream.js`.

**This is a client/transport fix, not a reasoning fix.** It makes existing thinking
visible; it never invents reasoning for models that emit none (verified above with
`claude-haiku-5.5`).

**Not a substitute for the upstream fix.** The real fix is one line in
`open-sse/utils/stream.js`: treat `openai-compatible-*` as alias-emitting, e.g.

```js
const liftAliases =
  mode === STREAM_MODE.PASSTHROUGH &&
  (!!PROVIDERS[provider]?.quirks?.reasoningAliasFields ||
   (typeof provider === "string" && provider.startsWith("openai-compatible-")));
```

If that lands upstream, this repo becomes unnecessary — delete it.

## License

MIT. No 9router source is redistributed here; the patch is applied to the image at
runtime, in your own container.
