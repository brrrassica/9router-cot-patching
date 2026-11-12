#!/usr/bin/env bash
# Verify that 9router lifts OpenRouter-style reasoning aliases into
# `reasoning_content` for a custom openai-compatible-* connection.
#
# Usage:
#   BASE=http://127.0.0.1:20128 KEY=sk-... MODEL=amr-link/your-model ./verify-cot.sh
#
# Exit codes: 0 = CoT visible, 1 = CoT missing (patch absent or not matched).

set -uo pipefail

BASE="${BASE:-http://127.0.0.1:20128}"
: "${KEY:?set KEY to a 9router API key}"
: "${MODEL:?set MODEL to a model on an openai-compatible-* connection}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "== streaming: $MODEL"
curl -s -N -X POST "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $KEY" \
  -d "{\"model\":\"$MODEL\",\"stream\":true,\"max_tokens\":60,
       \"messages\":[{\"role\":\"user\",\"content\":\"What is 17*23? Think briefly.\"}]}" \
  -m 90 > "$tmp"

n=$(grep -c reasoning_content "$tmp" || true)
echo "   reasoning_content deltas: $n"

if [ "$n" -gt 0 ]; then
  echo "   first delta:"
  tr -d '\r' < "$tmp" | grep '^data:' | grep reasoning_content | head -1 | cut -c1-200 | sed 's/^/     /'
  echo "PASS - CoT is reaching the client."
  exit 0
fi

echo "FAIL - no reasoning_content. Is the boot patch applied?"
echo "       docker logs 9router | grep cot-patch"
exit 1
