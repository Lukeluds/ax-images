#!/usr/bin/env bash

# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${PORT:-18091}"
EXPECTED_KEY="${EXPECTED_KEY:-throwaway-test-key}"
BASE="http://127.0.0.1:${PORT}"
GEN="${BASE}/v1beta/models/gemini-mock"
BODY='{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}'
LOG_FILE="$(mktemp)"

PORT="${PORT}" EXPECTED_KEY="${EXPECTED_KEY}" REPLY_TEXT="MOCK_OK" \
  python3 -B "${DIR}/mock_gemini.py" >"${LOG_FILE}" 2>&1 &
SERVER_PID=$!
trap 'kill "${SERVER_PID}" 2>/dev/null || true; rm -f "${LOG_FILE}"' EXIT

for _ in $(seq 1 30); do
  curl -fsS "${BASE}/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS "${BASE}/healthz" >/dev/null

post() {
  local url="$1" body="$2"
  shift 2
  curl -s -X POST "${url}" -H "content-type: application/json" -d "${body}" "$@"
}
code() { post "$@" -o /dev/null -w "%{http_code}"; }

# 1. Wrong key -> 400, missing key -> 401
test "$(code "${GEN}:generateContent" "${BODY}" -H "x-goog-api-key: wrong")" = "400"
test "$(code "${GEN}:generateContent" "${BODY}")" = "401"

# 2. SSE stream -> 200 + MOCK_OK
sse="$(post "${GEN}:streamGenerateContent?alt=sse" "${BODY}" -H "x-goog-api-key: ${EXPECTED_KEY}")"
python3 - "${sse}" <<'EOF'
import json, sys
data = sys.argv[1]
assert data.startswith("data: "), data
chunk = json.loads(data[len("data: "):].strip())
assert chunk["candidates"][0]["content"]["parts"][0]["text"] == "MOCK_OK"
assert chunk["candidates"][0]["finishReason"] == "STOP"
EOF

# 3. Non-stream with ?key= and with Authorization: Bearer -> 200 + MOCK_OK
resp_qs="$(post "${GEN}:generateContent?key=${EXPECTED_KEY}" "${BODY}")"
resp_bearer="$(post "${GEN}:generateContent" "${BODY}" -H "authorization: Bearer ${EXPECTED_KEY}")"
python3 - "${resp_qs}" "${resp_bearer}" <<'EOF'
import json, sys
for raw in sys.argv[1:]:
    d = json.loads(raw)
    assert d["candidates"][0]["content"]["parts"][0]["text"] == "MOCK_OK", d
EOF

# 4. countTokens and model list
test "$(post "${GEN}:countTokens" "${BODY}" -H "x-goog-api-key: ${EXPECTED_KEY}")" = '{"totalTokens": 10}'
curl -fsS "${BASE}/v1beta/models" -H "x-goog-api-key: ${EXPECTED_KEY}" | grep -q "models/gemini-mock"

# 5. Request log records auth results and strips secret headers and ?key=
reqs="$(curl -fsS "${BASE}/_mock/requests")"
python3 - "${reqs}" "${EXPECTED_KEY}" <<'EOF'
import json, sys
log, secret = json.loads(sys.argv[1]), sys.argv[2]
assert [r["auth_ok"] for r in log] == [False, False, True, True, True, True, True], log
assert [r["key_presented"] for r in log] == [True, False, True, True, True, True, True], log
for r in log:
    assert "x-goog-api-key" not in r["headers"] and "authorization" not in r["headers"]
    assert secret not in r["path"], r["path"]
EOF

# 6. Config validation: unknown keys, invalid faults, and bad slow_delay -> 400
#    with zero partial state mutation.
test "$(code "${BASE}/_mock/config" '{"bogus":1}')" = "400"
test "$(code "${BASE}/_mock/config" '{"fault":"bogus"}')" = "400"
test "$(code "${BASE}/_mock/config" '{"fault":"slow","slow_delay":"abc"}')" = "400"
test "$(code "${BASE}/_mock/config" '{"fault":"slow","slow_delay":-1}')" = "400"
test "$(code "${BASE}/_mock/config" '{"fault":"slow","slow_delay":true}')" = "400"
test "$(code "${BASE}/_mock/config" '{"fault":"slow","slow_delay":false}')" = "400"
test "$(code "${BASE}/_mock/config" '{"fault":"slow","slow_delay":null}')" = "400"

cfg_now="$(post "${BASE}/_mock/config" '{}')"
python3 - "${cfg_now}" <<'EOF'
import json, sys
cfg = json.loads(sys.argv[1])
assert cfg["fault"] == "", cfg
assert cfg["slow_delay"] == 2.0, cfg
EOF

# 7. Fault modes: 429, 500, 503, slow, truncated_sse (stream & non-stream)
K=(-H "x-goog-api-key: ${EXPECTED_KEY}")
for fault in 429 500 503; do
  post "${BASE}/_mock/config" "{\"fault\":\"${fault}\"}" >/dev/null
  test "$(code "${GEN}:streamGenerateContent?alt=sse" "${BODY}" "${K[@]}")" = "${fault}"
done

post "${BASE}/_mock/config" '{"fault":"slow","slow_delay":0.15}' >/dev/null
post "${GEN}:generateContent" "${BODY}" "${K[@]}" | grep -q "MOCK_OK"

post "${BASE}/_mock/config" '{"fault":"truncated_sse"}' >/dev/null
trunc="$(post "${GEN}:streamGenerateContent?alt=sse" "${BODY}" "${K[@]}")"
python3 - "${trunc}" <<'EOF'
import json, sys
data = sys.argv[1]
assert data.startswith("data: "), data
try:
    json.loads(data[len("data: "):])
except ValueError:
    pass
else:
    raise AssertionError("truncated_sse returned valid SSE JSON")
EOF

# Non-streaming :generateContent under truncated_sse returns application/json
# cut off mid-body (curl exit 18 = partial file), never SSE or full JSON.
trunc_hdrs="$(mktemp)"
set +e
trunc_json="$(curl -s -D "${trunc_hdrs}" -X POST "${GEN}:generateContent" \
  -H "content-type: application/json" "${K[@]}" -d "${BODY}")"
trunc_rc=$?
set -e
test "${trunc_rc}" -eq 18
python3 - "${trunc_json}" "${trunc_hdrs}" <<'EOF'
import json, sys
body, hdr_path = sys.argv[1], sys.argv[2]
with open(hdr_path, encoding="utf-8") as f:
    hdrs = f.read().lower()
assert "content-type: application/json" in hdrs, hdrs
assert "text/event-stream" not in hdrs, hdrs
try:
    json.loads(body)
except ValueError:
    pass
else:
    raise AssertionError(f"expected truncated JSON, got complete body: {body!r}")
EOF
rm -f "${trunc_hdrs}"

# 8. Scripted 2-turn write_file functionCall -> functionResponse -> MOCK_OK
post "${BASE}/_mock/reset" "{}" >/dev/null
post "${BASE}/_mock/config" '{"tool_write_path":"/workspace/out.txt","tool_write_content":"HELLO_TOOL"}' >/dev/null

# Tool-less side requests (or tools without write_file) must get plain text.
t0_notools="$(post "${GEN}:generateContent" "${BODY}" "${K[@]}")"
t0_othertools="$(post "${GEN}:generateContent" '{"tools":[{"functionDeclarations":[{"name":"read_file"}]}],"contents":[{"role":"user","parts":[{"text":"hi"}]}]}' "${K[@]}")"
python3 - "${t0_notools}" "${t0_othertools}" <<'EOF'
import json, sys
for raw in sys.argv[1:]:
    d = json.loads(raw)
    part = d["candidates"][0]["content"]["parts"][0]
    assert "functionCall" not in part and part["text"] == "MOCK_OK", d
EOF

TOOLS='"tools":[{"functionDeclarations":[{"name":"read_file"},{"name":"write_file"}]}]'
t1="$(post "${GEN}:streamGenerateContent?alt=sse" "{${TOOLS},\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"write\"}]}]}" "${K[@]}")"
python3 - "${t1}" <<'EOF'
import json, sys
chunk = json.loads(sys.argv[1][len("data: "):].strip())
call = chunk["candidates"][0]["content"]["parts"][0]["functionCall"]
assert call["name"] == "write_file", call
assert call["args"]["Path"] == "/workspace/out.txt" and call["args"]["Content"] == "HELLO_TOOL", call
EOF

t2="$(post "${GEN}:streamGenerateContent?alt=sse" "{${TOOLS},\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"write\"}]},{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"write_file\",\"args\":{}}}]},{\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"name\":\"write_file\",\"response\":{}}}]}]}" "${K[@]}")"
echo "${t2}" | grep -q "MOCK_OK"

# 9. Reset clears log and restores defaults
post "${BASE}/_mock/reset" "{}" >/dev/null
test "$(curl -fsS "${BASE}/_mock/requests")" = "[]"

echo "ALL MOCK GEMINI SELFTEST CHECKS PASSED"
