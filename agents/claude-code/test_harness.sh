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

printf 'Reply with MOCK_OK.' >"${TMP}/goal.md"
cat >"${TMP}/config.json" <<'EOF'
{
  "model": "claude-mock",
  "maxTurns": 3,
  "dangerouslySkipPermissions": true,
  "verbose": false,
  "allowedTools": ["Bash", "Edit"],
  "settings": {"includeCoAuthoredBy": false}
}
EOF
printf '{"mcpServers":{"docs":{"type":"http","url":"http://docs.local/mcp"}}}' >"${TMP}/mcp.json"
printf '{"mcpServers":{}}' >"${TMP}/mcp-empty.json"

cat >"${TMP}/fake-claude" <<'EOF'
#!/usr/bin/env python3
import json, sys
print(json.dumps(sys.argv[1:]))
EOF
chmod +x "${TMP}/fake-claude"

# expect_args <json> <python list literal>
expect_args() {
  python3 - "$1" "$2" <<'EOF'
import ast, json, sys
got = json.loads(sys.argv[1])
want = ast.literal_eval(sys.argv[2])
assert got == want, f"got {got!r}, want {want!r}"
EOF
}

# 1. Goal file as-is, spec.config translated to sorted flags, MCP servers
#    passed with --mcp-config, and the answer written to AX_OUTPUT_FILE.
got="$(AX_GOAL_FILE="${TMP}/goal.md" AX_CONFIG_FILE="${TMP}/config.json" \
  AX_MCP_CONFIG_FILE="${TMP}/mcp.json" AX_OUTPUT_FILE="${TMP}/ws/.ax/output" \
  CLAUDE_BIN="${TMP}/fake-claude" "${DIR}/ax-harness")"
want="[
    '--print',
    '--allowed-tools=Bash',
    '--allowed-tools=Edit',
    '--dangerously-skip-permissions',
    '--max-turns=3',
    '--model=claude-mock',
    '--settings={\"includeCoAuthoredBy\":false}',
    '--mcp-config=${TMP}/mcp.json',
    '--',
    'Reply with MOCK_OK.',
]"
expect_args "${got}" "${want}"
expect_args "$(cat "${TMP}/ws/.ax/output")" "${want}"

# 2. Empty or missing mcpServers adds no flag; without AX_OUTPUT_FILE only stdout is used.
got="$(AX_GOAL_FILE="${TMP}/goal.md" AX_MCP_CONFIG_FILE="${TMP}/mcp-empty.json" \
  CLAUDE_BIN="${TMP}/fake-claude" "${DIR}/ax-harness")"
expect_args "${got}" "['--print', '--', 'Reply with MOCK_OK.']"

got="$(AX_GOAL_FILE="${TMP}/goal.md" AX_MCP_CONFIG_FILE="${TMP}/does-not-exist.json" \
  CLAUDE_BIN="${TMP}/fake-claude" "${DIR}/ax-harness")"
expect_args "${got}" "['--print', '--', 'Reply with MOCK_OK.']"

# 3. Runtime install fallback: installs into $HOME/.local/bin when missing
FAKE_HOME="${TMP}/home"
mkdir -p "${FAKE_HOME}"
cat >"${TMP}/mock-install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${HOME}/.local/bin"
printf '%s' "${1:-}" > "${HOME}/installed_version.txt"
cat > "${HOME}/.local/bin/claude-runtime-test" <<'INNER'
#!/usr/bin/env python3
import json, sys
print(json.dumps(sys.argv[1:]))
INNER
chmod +x "${HOME}/.local/bin/claude-runtime-test"
EOF

got_rt="$(HOME="${FAKE_HOME}" \
  AX_GOAL_FILE="${TMP}/goal.md" \
  CLAUDE_BIN="claude-runtime-test" \
  CLAUDE_CODE_VERSION="2.1.322" \
  CLAUDE_INSTALL_SCRIPT_URL="file://${TMP}/mock-install.sh" \
  "${DIR}/ax-harness" 2>/dev/null)"

test "$(cat "${FAKE_HOME}/installed_version.txt")" = "2.1.322"
expect_args "${got_rt}" "['--print', '--', 'Reply with MOCK_OK.']"

# expect_rc <want> <env...>: runs ax-harness and checks its exit code.
expect_rc() {
  local want="$1" rc
  shift
  set +e
  env "$@" "${DIR}/ax-harness" >/dev/null 2>&1
  rc=$?
  set -e
  test "${rc}" -eq "${want}" || { echo "got exit ${rc}, want ${want} for: $*" >&2; exit 1; }
}

# 4. Empty goal file fails with exit code 2
: >"${TMP}/empty.md"
expect_rc 2 AX_GOAL_FILE="${TMP}/empty.md" CLAUDE_BIN="${TMP}/fake-claude"

# 5. spec.config.prompt is rejected (the prompt comes from spec.goal.text)
printf '{"prompt":"hi"}' >"${TMP}/prompt.json"
expect_rc 2 AX_GOAL_FILE="${TMP}/goal.md" AX_CONFIG_FILE="${TMP}/prompt.json" \
  CLAUDE_BIN="${TMP}/fake-claude"

# 6. Invalid spec.config fails the launcher instead of dropping flags
printf '{"bad_key":1}' >"${TMP}/bad.json"
expect_rc 2 AX_GOAL_FILE="${TMP}/goal.md" AX_CONFIG_FILE="${TMP}/bad.json" \
  CLAUDE_BIN="${TMP}/fake-claude"

# 7. claude's exit code is kept when the answer is teed to AX_OUTPUT_FILE
cat >"${TMP}/failing-claude" <<'EOF'
#!/usr/bin/env bash
echo "partial answer"
exit 7
EOF
chmod +x "${TMP}/failing-claude"
expect_rc 7 AX_GOAL_FILE="${TMP}/goal.md" AX_OUTPUT_FILE="${TMP}/fail/output" \
  CLAUDE_BIN="${TMP}/failing-claude"
test "$(cat "${TMP}/fail/output")" = "partial answer"

echo "ALL AX-HARNESS TESTS PASSED"
