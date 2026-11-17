# Antigravity + Mounted AX Runner E2E Suite (`e2e/antigravity`)

End-to-end test suite exercising the pure `agents/antigravity` image inside real
Agent Substrate gVisor sandboxes with a static `ax-task-runner` binary mounted
read-only at `/opt/ax` (`ImageVolumeSource`), tested against an in-cluster
`fakes/mock-gemini` Deployment.

## Cases Covered

1. **Happy path (`x-goog-api-key`):** Direct Gemini `:streamGenerateContent?alt=sse` stream → `MOCK_OK`.
2. **Wrong key (`400`):** Rejected by `mock-gemini`, command exits non-zero.
3. **Missing key:** Command exits non-zero without authenticated calls.
4. **Egress denied (no `EgressPolicy`):** Outbound DNS/HTTP blocked by Substrate (`0` requests reach `mock-gemini`).
5. **Gateway credential injection (`k8s.io`):** Sandbox holds only `GEMINI_API_KEY=placeholder`; Substrate egress gateway injects `ax-test/mock-gemini[key]` on `x-goog-api-key`, and `/proc/1/environ` inside the sandbox is verified free of the secret.
6. **Scripted `write_file` `functionCall` + `outputFile`:** Multi-turn tool call writes `/workspace/tool_ok.txt` inside the durable workspace volume and `outputFile` writes `/workspace/answer.md` alongside stdout logs.
7. **`FAULT=503` retry & recovery:** Injects transient `503 UNAVAILABLE` errors, clears fault via `/_mock/config`, and verifies `agy` retry recovery to `MOCK_OK`.

## Prerequisites

- A KinD cluster with Agent Substrate (`gvisor` `WorkerPool`, `atenet` with `k8s.io` credential provider, and `k8s-credential-provider-namespace-policy` allowing `default` → `ax-test`), such as the cluster created by `ax`'s `hack/setup-e2e-kind.sh` (`localhost:5001` local registry).
- `kubectl` and `kubectl-ate` on `PATH` (or `KUBECTL_ATE` set).
- Either an adjacent `ax` checkout (`AX_DIR`, default `../ax`) to cross-compile the static `ax-task-runner`, or `RUNNER_DIGEST` pointing to a pre-pushed runner volume image.

## Running (Hermetic `mock-gemini` Suite)

```bash
./e2e/antigravity/run_e2e.sh
```

Optional environment overrides: `AX_DIR`, `KUBECONFIG`, `KUBECTL_ATE`,
`LOCAL_REGISTRY` (default `localhost:5001`), `MOCK_DIGEST`, `AGY_DIGEST`, and
`RUNNER_DIGEST`.

## Running (Opt-In Live Gemini API Suite)

To exercise the default `PREINSTALL_AGY=false` image end-to-end against real
`generativelanguage.googleapis.com` (including runtime `install-agy.sh` download
of the pinned `agy` from `storage.googleapis.com` via `tlsPassthrough` with
`AGY_RUNTIME_INSTALL=true`, answer written to `AX_OUTPUT_FILE`, Substrate HTTPS
MITM CA trust bundle auto-wiring, and
gateway `x-goog-api-key` credential injection on the `ax` hero-demo task):

1. Store a Gemini API key in the allowed credential namespace (never commit or
   pass the real key inside the container):
   ```bash
   kubectl -n ax-test create secret generic real-gemini \
     --from-literal=api-key="YOUR_GEMINI_API_KEY"
   ```
2. Run:
   ```bash
   ./e2e/antigravity/run_real_gemini_e2e.sh
   ```

Optional environment overrides: `GEMINI_SECRET_NAMESPACE` (default `ax-test`),
`GEMINI_SECRET_NAME` (default `real-gemini`), `GEMINI_SECRET_KEY` (default
`api-key`), `PREINSTALL_AGY` (default `false`), `AGY_DIGEST`, `RUNNER_DIGEST`,
and `TIMEOUT_S` (default `180`).
