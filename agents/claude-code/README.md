# Claude Code Agent Image (`agents/claude-code`)

Launcher (`ax-harness`) for running headless [Claude Code](https://claude.com/claude-code)
tasks under the AX in-container wrapper contract.

## Launcher Contract (`/usr/local/bin/ax-harness`)

The mounted AX runner prepares `/workspace`, writes task inputs to files, and
invokes `/usr/local/bin/ax-harness` with `/workspace` as the working directory:

- `AX_GOAL_FILE` *(required)* — Path to the file holding the task's goal (`spec.goal.text`). Passed to `claude --print` as the prompt as-is.
- `AX_CONFIG_FILE` *(optional)* — Path to `spec.config` serialized as JSON. Every `camelCase` key maps to the matching `claude --print` `--kebab-case` CLI flag (`prompt` is rejected; use `spec.goal.text`):
  - Strings and numbers → `--flag=value`
  - `true` → `--flag` (`false` omits the flag)
  - Lists → `--flag=elem` repeated per item
  - Objects → `--flag=<compact JSON>` (e.g. `settings`)
- `AX_MCP_CONFIG_FILE` *(optional)* — Path to the Workspace's MCP servers in the `{"mcpServers": {...}}` format. Passed as `--mcp-config` when it lists at least one server.
- `AX_OUTPUT_FILE` *(optional)* — Path the agent's answer is written to (AX reports it as `status.outcome.output`). The answer is also printed to stdout, and `claude`'s exit code is kept.

`AX_SESSION_FILE` is not used yet.

## Runtime Installation

If `claude` is not already present on `PATH`, `ax-harness` installs it on
startup using Anthropic's official installer (`https://claude.ai/install.sh`,
version controlled by `CLAUDE_CODE_VERSION`, defaulting to `stable`). In
egress-restricted sandboxes, runtime installation requires outbound HTTPS (`443`)
access to `claude.ai` and `downloads.claude.ai` unless `claude` was pre-installed
at image build time.

## Unit Test

```bash
./agents/claude-code/test_harness.sh
```
