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
curl_exit=0
curl -sS -N -X POST "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $KEY" \
  -d "{\"model\":\"$MODEL\",\"stream\":true,\"max_tokens\":60,
       \"messages\":[{\"role\":\"user\",\"content\":\"What is 17*23? Think briefly.\"}]}" \
  -m 90 -w "\n__HTTP_STATUS__:%{http_code}" > "$tmp" || curl_exit=$?

if [ "$curl_exit" -ne 0 ]; then
  echo "FAIL - curl transport/request error (exit $curl_exit). Check BASE/KEY/network and that the server is reachable."
  exit 2
fi

http_status=$(grep -oE '__HTTP_STATUS__:[0-9]+' "$tmp" | tail -1 | cut -d: -f2 || true)
# strip status marker line from tmp for content checks
if [ -n "$http_status" ]; then
  grep -v '__HTTP_STATUS__:' "$tmp" > "$tmp.body" 2>/dev/null || true
  mv "$tmp.body" "$tmp"
fi

if [ -z "$http_status" ]; then
  echo "WARN - could not parse HTTP status; continuing with body checks."
elif [ "$http_status" -lt 200 ] || [ "$http_status" -ge 300 ]; then
  echo "FAIL - HTTP $http_status (not 2xx). Response body (first 300 chars):"
  tr -d '\r' < "$tmp" | head -c 300 | sed 's/^/  /'
  echo ""
  echo "Fix the request/server/auth/model first; patch cannot be evaluated on a failed HTTP response."
  exit 3
fi

n=$(grep -c reasoning_content "$tmp" || true)
echo "   reasoning_content deltas: $n"

if [ "$n" -gt 0 ]; then
  echo "   first delta:"
  tr -d '\r' < "$tmp" | grep '^data:' | grep reasoning_content | head -1 | cut -c1-200 | sed 's/^/     /'
  echo "PASS - CoT is reaching the client."
  exit 0
fi

echo "FAIL - no reasoning_content in a successful (2xx) streamed response. Is the boot patch applied?"
echo "       docker logs 9router | grep cot-patch"
exit 1
