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
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

cat >"${TMP}/fake-agy" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:2] == ["mcp"]:
    with open(os.environ["FAKE_AGY_LOG"], "a", encoding="utf-8") as f:
        f.write(json.dumps(sys.argv[1:]) + "\n")
    sys.exit(0)
print(json.dumps(sys.argv[1:]))
sys.exit(int(os.environ.get("FAKE_AGY_EXIT", "0")))
EOF
chmod +x "${TMP}/fake-agy"
export FAKE_AGY_LOG="${TMP}/agy-calls.log"

run_case() {
  local cfg="$1"
  shift
  printf 'Reply with MOCK_OK.' >"${TMP}/goal.md"
  printf '%s' "${cfg}" >"${TMP}/config.json"
  (
    cd "${TMP}"
    env -u GEMINI_API_KEY -u AGY_ADC_AUTH -u AX_OUTPUT_FILE -u AX_MCP_CONFIG_FILE -u AX_SESSION_FILE -u AX_SESSION_HOME "$@" \
      AX_GOAL_FILE="${TMP}/goal.md" \
      AX_CONFIG_FILE="${TMP}/config.json" \
      AGY_BIN="${TMP}/fake-agy" \
      "${DIR}/ax-harness"
  )
}

check_eq() {
  python3 - "$1" "$2" "$3" <<'EOF'
import json, sys
name, got, want = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3])
assert got == want, f"{name}:\n got  {got!r}\n want {want!r}"
EOF
}

# 1. Defaults: skip permissions, workspace registered via --add-dir, goal as --print.
check_eq "defaults" "$(run_case '{"prompt":"Reply with MOCK_OK."}')" \
  "[\"--add-dir=${TMP}\", \"--dangerously-skip-permissions\", \"--print=Reply with MOCK_OK.\"]"

# 2. Config keys map to sorted flags; false booleans pass =false explicitly.
check_eq "flags" "$(run_case '{"prompt":"x","model":"gemini-mock","printTimeout":"15m","outputFormat":"json","dangerouslySkipPermissions":false,"addDir":["/a","/b"]}')" \
  '["--add-dir=/a", "--add-dir=/b", "--dangerously-skip-permissions=false", "--model=gemini-mock", "--output-format=json", "--print-timeout=15m", "--print=Reply with MOCK_OK."]'

# 3. GEMINI_API_KEY opts into {"modelProvider":"gemini"} and merges user settings.
check_eq "gemini-api-key" "$(run_case '{"settings":{"customModelsConfig":{"customModels":{"m":{"modelName":"m"}}}}}' GEMINI_API_KEY=k)" \
  "[\"--add-dir=${TMP}\", \"--dangerously-skip-permissions\", \"--settings={\\\"modelProvider\\\":\\\"gemini\\\",\\\"customModelsConfig\\\":{\\\"customModels\\\":{\\\"m\\\":{\\\"modelName\\\":\\\"m\\\"}}}}\", \"--print=Reply with MOCK_OK.\"]"

# 4. AGY_ADC_AUTH=true suppresses modelProvider:gemini even if GEMINI_API_KEY is set.
check_eq "adc" "$(run_case '{}' GEMINI_API_KEY=k AGY_ADC_AUTH=true)" \
  "[\"--add-dir=${TMP}\", \"--dangerously-skip-permissions\", \"--print=Reply with MOCK_OK.\"]"

# 5. outputFile tees stdout to file and preserves agy's exit status.
set +e
out="$(run_case '{"outputFile":"out/answer.txt"}' FAKE_AGY_EXIT=3)"
status=$?
set -e
test "${status}" -eq 3
check_eq "outputFile stdout" "${out}" \
  "[\"--add-dir=${TMP}\", \"--dangerously-skip-permissions\", \"--print=Reply with MOCK_OK.\"]"
check_eq "outputFile file" "$(cat "${TMP}/out/answer.txt")" "${out}"

# 6. No outputFile leaves workspace untouched.
run_case '{}' >/dev/null
test ! -e "${TMP}/ax-output.md"

# 7. Runtime install is opt-in (AGY_RUNTIME_INSTALL=true) and installs into
#    <workspace>/.ax/bin, so a resumed sandbox finds agy without reinstalling.
FAKE_HOME="${TMP}/home"
mkdir -p "${FAKE_HOME}"
cat >"${TMP}/mock-install-agy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$2"
printf '%s\n' "$1" >> "${HOME}/installed_versions.txt"
cat > "$2/agy-runtime-test" <<'INNER'
#!/usr/bin/env python3
import json, sys
print(json.dumps(sys.argv[1:]))
INNER
chmod +x "$2/agy-runtime-test"
EOF
chmod +x "${TMP}/mock-install-agy.sh"

run_runtime() {
  printf 'Reply with MOCK_OK.' >"${TMP}/goal.md"
  (
    cd "${TMP}"
    env -u GEMINI_API_KEY -u AGY_ADC_AUTH -u AGY_VERSION -u AGY_INSTALL_DIR -u AGY_RUNTIME_INSTALL "$@" \
      HOME="${FAKE_HOME}" \
      AX_GOAL_FILE="${TMP}/goal.md" \
      AGY_BIN="agy-runtime-test" \
      AGY_INSTALL_SCRIPT="${TMP}/mock-install-agy.sh" \
      "${DIR}/ax-harness" 2>/dev/null
  )
}

# 7a. Without opt-in, a missing agy fails with 127 and nothing is installed.
set +e
run_runtime >/dev/null
rc=$?
set -e
test "${rc}" -eq 127
test ! -e "${FAKE_HOME}/installed_versions.txt"

# 7b. With opt-in, AGY_VERSION is passed through and agy lands in .ax/bin.
got_rt="$(run_runtime AGY_RUNTIME_INSTALL=true AGY_VERSION=1.5.7)"
test -x "${TMP}/.ax/bin/agy-runtime-test"
check_eq "runtime-install" "${got_rt}" \
  "[\"--add-dir=${TMP}\", \"--dangerously-skip-permissions\", \"--print=Reply with MOCK_OK.\"]"

# 7c. A resumed run reuses the installed agy instead of downloading again.
run_runtime AGY_RUNTIME_INSTALL=true >/dev/null
test "$(cat "${FAKE_HOME}/installed_versions.txt")" = "1.5.7"
rm -rf "${TMP}/.ax"

# 7d. Without AGY_VERSION, the installer gets an empty version (its pin).
rm -f "${FAKE_HOME}/installed_versions.txt"
run_runtime AGY_RUNTIME_INSTALL=true >/dev/null
test "$(cat "${FAKE_HOME}/installed_versions.txt")" = ""
rm -rf "${TMP}/.ax"

# 7f. An agy installed in the image wins over a leftover workspace copy.
mkdir -p "${TMP}/sysbin" "${TMP}/.ax/bin"
for where in sysbin .ax/bin; do
  printf '#!/usr/bin/env bash\necho "%s"\n' "${where}" >"${TMP}/${where}/agy-shadow"
  chmod +x "${TMP}/${where}/agy-shadow"
done
printf 'Reply with MOCK_OK.' >"${TMP}/goal.md"
got_shadow="$(
  cd "${TMP}"
  env -u GEMINI_API_KEY -u AGY_ADC_AUTH -u AGY_INSTALL_DIR \
    PATH="${TMP}/sysbin:${PATH}" \
    AX_GOAL_FILE="${TMP}/goal.md" \
    AGY_BIN="agy-shadow" \
    "${DIR}/ax-harness"
)"
test "${got_shadow}" = "sysbin"
rm -rf "${TMP}/.ax" "${TMP}/sysbin"

# 7e. install-agy.sh refuses versions without a pinned checksum, before any
#     download (the base URL points at a closed port).
for v in latest 9.9.9; do
  set +e
  AGY_GCS_BASE_URL="http://127.0.0.1:9" "${DIR}/install-agy.sh" "${v}" "${TMP}/never" >/dev/null 2>&1
  rc=$?
  set -e
  test "${rc}" -eq 1
  test ! -e "${TMP}/never"
done

# 7g. install-agy.sh fails fast with a clear memory-limit hint when free space
#     is below AGY_MIN_FREE_MB (without touching the network or creating dest).
set +e
space_err="$(AGY_MIN_FREE_MB=999999999 AGY_GCS_BASE_URL="http://127.0.0.1:9" "${DIR}/install-agy.sh" "" "${TMP}/never-space" 2>&1)"
rc=$?
set -e
test "${rc}" -eq 1
test ! -e "${TMP}/never-space"
grep -q "spec.profile.resources.limits.memory" <<<"${space_err}"

# 8. Empty goal file fails with exit code 2.
: >"${TMP}/empty.md"
set +e
AX_GOAL_FILE="${TMP}/empty.md" AGY_BIN="${TMP}/fake-agy" \
  "${DIR}/ax-harness" >/dev/null 2>&1
rc=$?
set -e
test "${rc}" -eq 2

# 9. Substrate egress trust bundle sets SSL_CERT_FILE and CURL_CA_BUNDLE when unset.
cat >"${TMP}/env-agy" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
print(json.dumps({
    "ssl": os.environ.get("SSL_CERT_FILE"),
    "curl": os.environ.get("CURL_CA_BUNDLE"),
}))
EOF
chmod +x "${TMP}/env-agy"
printf 'FAKE_CA' >"${TMP}/trust-bundle.pem"
printf 'Reply with MOCK_OK.' >"${TMP}/goal.md"

ca_out="$(
  cd "${TMP}"
  env -u SSL_CERT_FILE -u CURL_CA_BUNDLE \
    AX_CA_BUNDLE="${TMP}/trust-bundle.pem" \
    AX_GOAL_FILE="${TMP}/goal.md" \
    AGY_BIN="${TMP}/env-agy" \
    "${DIR}/ax-harness"
)"
check_eq "trust-bundle-default" "${ca_out}" \
  "{\"ssl\":\"${TMP}/trust-bundle.pem\",\"curl\":\"${TMP}/trust-bundle.pem\"}"

ca_override="$(
  cd "${TMP}"
  env -u CURL_CA_BUNDLE \
    SSL_CERT_FILE="/custom/ca.pem" \
    AX_CA_BUNDLE="${TMP}/trust-bundle.pem" \
    AX_GOAL_FILE="${TMP}/goal.md" \
    AGY_BIN="${TMP}/env-agy" \
    "${DIR}/ax-harness"
)"
check_eq "trust-bundle-preserve" "${ca_override}" \
  "{\"ssl\":\"/custom/ca.pem\",\"curl\":\"${TMP}/trust-bundle.pem\"}"

DEFAULT_ARGS="[\"--add-dir=${TMP}\", \"--dangerously-skip-permissions\", \"--print=Reply with MOCK_OK.\"]"

# 10. AX_OUTPUT_FILE receives the answer (also on stdout), and agy's exit
#     status is preserved.
set +e
out="$(run_case '{}' AX_OUTPUT_FILE="${TMP}/ws/.ax/output" FAKE_AGY_EXIT=4)"
status=$?
set -e
test "${status}" -eq 4
check_eq "ax-output stdout" "${out}" "${DEFAULT_ARGS}"
check_eq "ax-output file" "$(cat "${TMP}/ws/.ax/output")" "${DEFAULT_ARGS}"

# 11. AX_OUTPUT_FILE and spec.config.outputFile both receive the answer.
rm -rf "${TMP}/ws" "${TMP}/out"
run_case '{"outputFile":"out/answer.txt"}' AX_OUTPUT_FILE="${TMP}/ws/.ax/output" >/dev/null
check_eq "ax-output both (AX_OUTPUT_FILE)" "$(cat "${TMP}/ws/.ax/output")" "${DEFAULT_ARGS}"
check_eq "ax-output both (outputFile)" "$(cat "${TMP}/out/answer.txt")" "${DEFAULT_ARGS}"

# 12. MCP servers are registered with `agy mcp add` (http and stdio, sorted by
#     name) before the task runs, without polluting the answer.
rm -f "${FAKE_AGY_LOG}"
cat >"${TMP}/mcp.json" <<'EOF'
{"mcpServers": {
  "web": {"type": "http", "url": "https://mcp.example.com/mcp"},
  "fs": {"type": "stdio", "command": "npx", "args": ["-y", "@mcp/fs", "/workspace"]},
  "broken": {"type": "stdio"}
}}
EOF
out="$(run_case '{}' AX_MCP_CONFIG_FILE="${TMP}/mcp.json" 2>/dev/null)"
check_eq "mcp answer" "${out}" "${DEFAULT_ARGS}"
check_eq "mcp calls" "$(python3 - "${FAKE_AGY_LOG}" <<'EOF'
import json, sys
print(json.dumps([json.loads(line) for line in open(sys.argv[1])]))
EOF
)" \
  '[["mcp", "add", "--type", "stdio", "fs", "--", "npx", "-y", "@mcp/fs", "/workspace"], ["mcp", "add", "--type", "http", "web", "https://mcp.example.com/mcp"]]'

# 13. No MCP servers means no `agy mcp` calls.
rm -f "${FAKE_AGY_LOG}"
printf '{"mcpServers":{}}' >"${TMP}/mcp-empty.json"
run_case '{}' AX_MCP_CONFIG_FILE="${TMP}/mcp-empty.json" >/dev/null
test ! -e "${FAKE_AGY_LOG}"

# 14. A malformed MCP config fails the task instead of being ignored.
printf '{not json' >"${TMP}/mcp-bad.json"
set +e
run_case '{}' AX_MCP_CONFIG_FILE="${TMP}/mcp-bad.json" >/dev/null 2>&1
rc=$?
set -e
test "${rc}" -ne 0

# 15. AX_SESSION_FILE isolates HOME under <workspace>/.ax/sessions/<id> and
#     omits --continue on Turn 1, then passes --continue once conversation
#     state exists in that session directory.
cat >"${TMP}/home-agy" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
print(json.dumps({"home": os.environ.get("HOME"), "args": sys.argv[1:]}))
EOF
chmod +x "${TMP}/home-agy"
printf 'sess-42\n' >"${TMP}/session-id"
turn1="$(
  cd "${TMP}"
  env -u GEMINI_API_KEY -u AGY_ADC_AUTH -u AX_OUTPUT_FILE -u AX_MCP_CONFIG_FILE -u AX_SESSION_HOME \
    AX_GOAL_FILE="${TMP}/goal.md" \
    AX_SESSION_FILE="${TMP}/session-id" \
    AGY_BIN="${TMP}/home-agy" \
    "${DIR}/ax-harness"
)"
check_eq "session-turn-1" "${turn1}" \
  "{\"home\":\"${TMP}/.ax/sessions/sess-42\",\"args\":[\"--add-dir=${TMP}\",\"--dangerously-skip-permissions\",\"--print=Reply with MOCK_OK.\"]}"

mkdir -p "${TMP}/.ax/sessions/sess-42/.gemini/antigravity-cli/conversations"
touch "${TMP}/.ax/sessions/sess-42/.gemini/antigravity-cli/conversations/conv.db"
turn2="$(
  cd "${TMP}"
  env -u GEMINI_API_KEY -u AGY_ADC_AUTH -u AX_OUTPUT_FILE -u AX_MCP_CONFIG_FILE -u AX_SESSION_HOME \
    AX_GOAL_FILE="${TMP}/goal.md" \
    AX_SESSION_FILE="${TMP}/session-id" \
    AGY_BIN="${TMP}/home-agy" \
    "${DIR}/ax-harness"
)"
check_eq "session-turn-2" "${turn2}" \
  "{\"home\":\"${TMP}/.ax/sessions/sess-42\",\"args\":[\"--add-dir=${TMP}\",\"--continue\",\"--dangerously-skip-permissions\",\"--print=Reply with MOCK_OK.\"]}"

# 16. Explicit continue:false or conversation in spec.config is not overridden.
check_eq "session-explicit-no-continue" \
  "$(run_case '{"continue":false}' AX_SESSION_FILE="${TMP}/session-id")" \
  "[\"--add-dir=${TMP}\", \"--continue=false\", \"--dangerously-skip-permissions\", \"--print=Reply with MOCK_OK.\"]"
check_eq "session-explicit-conversation" \
  "$(run_case '{"conversation":"conv-99"}' AX_SESSION_FILE="${TMP}/session-id")" \
  "[\"--add-dir=${TMP}\", \"--conversation=conv-99\", \"--dangerously-skip-permissions\", \"--print=Reply with MOCK_OK.\"]"

# 17. Invalid session IDs (e.g. path traversal) are rejected with exit code 2.
for bad in "../escape" "a/b" ".."; do
  printf '%s' "${bad}" >"${TMP}/bad-session"
  set +e
  run_case '{}' AX_SESSION_FILE="${TMP}/bad-session" >/dev/null 2>&1
  rc=$?
  set -e
  test "${rc}" -eq 2
done

# 18. Same path in AX_OUTPUT_FILE and spec.config.outputFile writes atomically
#     without duplicate-temp errors or leftover .tmp files.
rm -rf "${TMP}/ws"
run_case '{"outputFile":"ws/.ax/output"}' AX_OUTPUT_FILE="ws/.ax/output" >/dev/null
check_eq "ax-output dedup" "$(cat "${TMP}/ws/.ax/output")" "${DEFAULT_ARGS}"
test -z "$(find "${TMP}/ws/.ax" -name '*.tmp.*')"

echo "ALL AX-HARNESS TESTS PASSED"
