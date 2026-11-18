# Antigravity Agent Image (`agents/antigravity`)

Pure mount-ready container image and launcher (`ax-harness`) for running
headless [Antigravity CLI (`agy`)](https://antigravity.google/docs/cli/install)
tasks under the AX in-container wrapper contract. Contains no AX runner binary
(`ax-task-runner` is mounted read-only by AX at `/opt/ax`).

## Launcher Contract (`/usr/local/bin/ax-harness`)

The mounted AX runner prepares `/workspace`, writes task inputs to files, and
invokes `/usr/local/bin/ax-harness` with `/workspace` as the working directory
(see `runner/launcher.go` in [google/ax](https://github.com/google/ax)):

- `AX_GOAL_FILE` *(required)* — Path to the file holding the task prompt (`spec.goal.text`), passed as-is via `--print=<goal>`.
- `AX_CONFIG_FILE` *(optional)* — Path to `spec.config` serialized as JSON. Every `camelCase` key maps to the matching `agy` `--kebab-case` CLI flag, with two special keys:
  - `outputFile` — Optional extra path where `agy`'s answer is also written.
  - `settings` — Merged into `--settings=<JSON>`.
- `AX_MCP_CONFIG_FILE` *(optional)* — Path to the Workspace's MCP servers (`{"mcpServers": {...}}`). Each `http` (`url`) or `stdio` (`command` + `args`) server is registered with `agy mcp add` before the task runs; a malformed file fails the task.
- `AX_OUTPUT_FILE` *(optional)* — Path where `agy`'s final answer is written (AX reports it as `status.outcome.output`). The answer is always printed to stdout/logs as well, and `ax-harness` exits with `agy`'s exit code.
- `AX_SESSION_FILE` — Not used yet: AX's `spec.session_id` does not map to an `agy` conversation ID (`--conversation`).
- **Defaults:** `--dangerously-skip-permissions` (headless runs cannot answer interactive prompts) and `--add-dir=<cwd>` (so relative file-tool paths resolve inside `/workspace`).
- **Authentication:**
  - When `GEMINI_API_KEY` is set (and `AGY_ADC_AUTH` is unset), `ax-harness` automatically sets `"modelProvider": "gemini"` in `--settings`; `GOOGLE_GEMINI_BASE_URL` optionally points requests at a gateway or mock endpoint.
  - When `AGY_ADC_AUTH=true`, `agy` authenticates via Application Default Credentials against `GOOGLE_CLOUD_PROJECT` (Vertex AI).
- **Egress TLS trust bundle:** When `/run/ate/egress-trust-bundle/trust-bundle.pem` is mounted by Agent Substrate, `ax-harness` defaults `SSL_CERT_FILE` and `CURL_CA_BUNDLE` to it so both runtime installation (`curl`) and `agy` trust the egress gateway's TLS certificate during HTTPS credential injection.

## Pinned `agy` Version

`install-agy.sh` pins the `agy` version (`PINNED_VERSION`) along with each
platform's release URL and SHA-512 checksum. The only network request is the
tarball download from `storage.googleapis.com`, and the checksum never comes
from the same bucket as the binary. Versions that are not pinned (including
`latest`) are rejected. To bump `agy`, add the new release's execution ID and
the SHA-512 of each platform's tarball (computed from the downloaded files).

## Runtime vs. Pre-Installed Builds

- **Default (`PREINSTALL_AGY=false`):** Ships Debian packages, `/usr/local/share/ax/install-agy.sh`, and `/usr/local/bin/ax-harness` (no `agy` binary bundled in the image). A task must opt in to runtime installation with `AGY_RUNTIME_INSTALL=true`, which installs the pinned `agy` into `/workspace/.ax/bin` (so a resumed sandbox reuses it) and needs egress to `storage.googleapis.com`. Without the opt-in, a missing `agy` fails the task with exit code `127`.
- **Optional pre-installed build (`--build-arg PREINSTALL_AGY=true`):** Installs the pinned `agy` during `docker build` for local or airgapped E2E environments where internet egress is blocked.

## Local Test

```bash
./agents/antigravity/test_harness.sh
```
