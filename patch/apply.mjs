import fs from "node:fs";
import path from "node:path";

const ROOT = "/app/.next/server";
const ORIG = "U=b===p&&!!f.xq[s]?.quirks?.reasoningAliasFields";
const PATCHED =
  'U=b===p&&(!!f.xq[s]?.quirks?.reasoningAliasFields||"string"==typeof s&&s.startsWith("openai-compatible-"))';
const KNOWN_MD5 = "2f02c3c8d1258bf00647fd0abc0ff279"; // v0.5.116 original

const walk = (d, out = []) => {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (p.endsWith(".js")) out.push(p);
  }
  return out;
};

let patched = 0,
  already = 0;

try {
  for (const f of walk(ROOT)) {
    const s = fs.readFileSync(f, "utf8");
    if (s.includes(PATCHED)) {
      already++;
      continue;
    }
    if (!s.includes(ORIG)) continue;
    const n = s.split(ORIG).length - 1;
    if (n !== 1) {
      console.warn(`[cot-patch] ${f}: ${n} occurrences, skipping`);
      continue;
    }
    fs.writeFileSync(f, s.replace(ORIG, PATCHED));
    console.log(`[cot-patch] patched ${f}`);
    patched++;
  }

  if (patched === 0 && already === 0) {
    // Fail-open: image upgraded and the chunk changed. Router still boots.
    console.warn(
      `[cot-patch] WARNING: gate not found. Expected md5 ${KNOWN_MD5}. CoT lifting is OFF.`
    );
  } else {
    console.log(`[cot-patch] done: ${patched} patched, ${already} already patched`);
  }
} catch (e) {
  // Never block boot on a patch failure.
  console.warn(`[cot-patch] ERROR: ${e && e.message ? e.message : e}`);
}
