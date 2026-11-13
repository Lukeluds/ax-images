# Claude Code Agent Image (`agents/claude-code`)

Pure mount-ready container image and launcher (`ax-harness`) for running
headless [Claude Code](https://claude.com/claude-code) tasks under the AX
in-container wrapper contract. Contains no AX runner binary (`ax-task-runner` is
mounted read-only by AX at `/opt/ax`).

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

## Runtime vs. Pre-Installed Builds

- **Default (`PREINSTALL_CLAUDE=false`):** Ships only Debian packages and `ax-harness` (no `claude` binary inside the image). When `claude` is missing at container startup, `ax-harness` installs `CLAUDE_CODE_VERSION` (default `stable`) via `https://claude.ai/install.sh`. Egress-restricted sandboxes using this mode must allow outbound HTTPS (`443`) to `claude.ai` and `downloads.claude.ai`.
- **Optional pre-installed build (`--build-arg PREINSTALL_CLAUDE=true`):** Installs `claude` during `docker build` for local or airgapped E2E environments where internet egress is blocked.

## Local Build & Test

```bash
./agents/claude-code/test_harness.sh

# Default runtime-install image (no claude binary inside):
docker build -t ax-claude-code:dev ./agents/claude-code

# Optional pre-installed local build:
docker build --build-arg PREINSTALL_CLAUDE=true -t ax-claude-code:prebaked ./agents/claude-code
```
