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

# Opt-in end-to-end verification of the default PREINSTALL_AGY=false
# agents/antigravity image on Agent Substrate (gVisor) against the live Gemini
# API (generativelanguage.googleapis.com), exercising:
#   1. Opt-in runtime download (AGY_RUNTIME_INSTALL=true) of the pinned agy
#      from storage.googleapis.com via tlsPassthrough;
#   2. Substrate HTTPS MITM CA trust bundle auto-wiring in ax-harness;
#   3. Gateway x-goog-api-key credential injection from a Kubernetes Secret
#      (the sandbox holds only GEMINI_API_KEY=placeholder);
#   4. Hero-demo code edit + unit test execution inside /workspace/app.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AX_DIR="${AX_DIR:-${REPO_ROOT}/../ax}"

if [[ -z "${KUBECONFIG:-}" && -f "${AX_DIR}/.tmp/e2e.env" ]]; then
  # shellcheck disable=SC1091
  source "${AX_DIR}/.tmp/e2e.env"
fi

export PATH="${GOPATH:-${HOME}/go}/bin:${PATH}"
KUBECTL_ATE="${KUBECTL_ATE:-$(command -v kubectl-ate || true)}"
if [[ -z "${KUBECTL_ATE}" ]]; then
  echo "error: kubectl-ate not found on PATH (or set KUBECTL_ATE)" >&2
  exit 1
fi
if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "error: KUBECONFIG is not set and ${AX_DIR}/.tmp/e2e.env was not found" >&2
  exit 1
fi

KCTL=(kubectl --kubeconfig "${KUBECONFIG}")
KATE=("${KUBECTL_ATE}" --kubeconfig "${KUBECONFIG}")
LOCAL_REGISTRY="${LOCAL_REGISTRY:-localhost:5001}"
PREINSTALL_AGY="${PREINSTALL_AGY:-false}"

GEMINI_SECRET_NAMESPACE="${GEMINI_SECRET_NAMESPACE:-ax-test}"
GEMINI_SECRET_NAME="${GEMINI_SECRET_NAME:-real-gemini}"
GEMINI_SECRET_KEY="${GEMINI_SECRET_KEY:-api-key}"
CREDENTIAL_URI="ate-secret://k8s.io/default/${GEMINI_SECRET_NAMESPACE}/${GEMINI_SECRET_NAME}/${GEMINI_SECRET_KEY}"

# Verify secret presence by resource name only -- never read or print .data.
if ! "${KCTL[@]}" -n "${GEMINI_SECRET_NAMESPACE}" get secret "${GEMINI_SECRET_NAME}" -o name >/dev/null 2>&1; then
  cat >&2 <<EOF
error: Kubernetes Secret ${GEMINI_SECRET_NAMESPACE}/${GEMINI_SECRET_NAME} not found.

Create it before running this opt-in live Gemini E2E check:
  kubectl --kubeconfig "${KUBECONFIG}" -n "${GEMINI_SECRET_NAMESPACE}" \\
    create secret generic "${GEMINI_SECRET_NAME}" \\
    --from-literal="${GEMINI_SECRET_KEY}=YOUR_GEMINI_API_KEY"
EOF
  exit 1
fi

if [[ -z "${TASK_CMD_KEY:-}" ]]; then
  if [[ -f "${AX_DIR}/pkg/apis/v1alpha1/ax.proto" ]] && grep -q "repeated string commands" "${AX_DIR}/pkg/apis/v1alpha1/ax.proto"; then
    TASK_CMD_KEY="commands"
  else
    TASK_CMD_KEY="command"
  fi
fi

TMP_DIR="$(mktemp -d)"
RUN_ID="$(date +%s)-$$"
ACTOR="agy-actor-real-gemini-${RUN_ID}"
TMPL="agy-tmpl-real-gemini-${RUN_ID}"

cleanup() {
  "${KATE[@]}" delete actor "${ACTOR}" -a default >/dev/null 2>&1 || true
  "${KATE[@]}" delete actor-template "${TMPL}" -a default >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# 1. Build/push local images if digests were not supplied.
if [[ -z "${AGY_DIGEST:-}" ]]; then
  BUILD_CTX="${REPO_ROOT}/agents/antigravity"
  if [[ ! -f "${BUILD_CTX}/Dockerfile" ]]; then
    if git -C "${REPO_ROOT}" rev-parse --verify feat/antigravity-dockerfile >/dev/null 2>&1; then
      git -C "${REPO_ROOT}" archive --format=tar feat/antigravity-dockerfile agents/antigravity | tar -xf - -C "${TMP_DIR}"
      BUILD_CTX="${TMP_DIR}/agents/antigravity"
    else
      echo "error: ${REPO_ROOT}/agents/antigravity/Dockerfile not found; set AGY_DIGEST" >&2
      exit 1
    fi
  fi
  echo "==> Building and pushing pure Antigravity image (PREINSTALL_AGY=${PREINSTALL_AGY})..."
  docker build --build-arg "PREINSTALL_AGY=${PREINSTALL_AGY}" \
    -t "${LOCAL_REGISTRY}/ax-antigravity:real-e2e" "${BUILD_CTX}" >/dev/null
  if [[ "${PREINSTALL_AGY}" == "false" ]] && docker run --rm "${LOCAL_REGISTRY}/ax-antigravity:real-e2e" bash -c 'command -v agy' >/dev/null 2>&1; then
    echo "error: agy should not be preinstalled when PREINSTALL_AGY=false" >&2
    exit 1
  fi
  docker push "${LOCAL_REGISTRY}/ax-antigravity:real-e2e" >/dev/null
  AGY_DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${LOCAL_REGISTRY}/ax-antigravity:real-e2e" | grep "^${LOCAL_REGISTRY}/" | head -n1)"
fi

if [[ -z "${RUNNER_DIGEST:-}" ]]; then
  RUNNER_DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${LOCAL_REGISTRY}/ax-runner:e2e" 2>/dev/null | grep "^${LOCAL_REGISTRY}/" | head -n1 || true)"
  if [[ -z "${RUNNER_DIGEST}" ]]; then
    if [[ ! -d "${AX_DIR}" ]]; then
      echo "error: AX_DIR (${AX_DIR}) not found; set AX_DIR or RUNNER_DIGEST" >&2
      exit 1
    fi
    echo "==> Building and pushing static ax-task-runner volume image..."
    mkdir -p "${TMP_DIR}/runner"
    (cd "${AX_DIR}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o "${TMP_DIR}/runner/ax-task-runner" ./cmd/ax-task-runner)
    printf 'FROM scratch\nCOPY ax-task-runner /ax-task-runner\n' >"${TMP_DIR}/runner/Dockerfile"
    docker build -t "${LOCAL_REGISTRY}/ax-runner:e2e" "${TMP_DIR}/runner" >/dev/null
    docker push "${LOCAL_REGISTRY}/ax-runner:e2e" >/dev/null
    RUNNER_DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${LOCAL_REGISTRY}/ax-runner:e2e" | grep "^${LOCAL_REGISTRY}/" | head -n1)"
  fi
fi

GOAL="Add a subtract(a, b) function to /workspace/app/math_utils.py and a unit test in test_math.py."

cat >"${TMP_DIR}/actor-template.yaml" <<EOF
metadata:
  name: ${TMPL}
  atespace: default
containers:
- name: guest
  image: ${AGY_DIGEST}
  command:
  - /opt/ax/ax-task-runner
  env:
  - name: AX_WORKSPACE_YAML
    value: |
      apiVersion: ax.io/v1alpha1
      kind: Workspace
      metadata:
        name: hero-demo-ws
        atespace: default
      spec:
        files:
        - path: app/math_utils.py
          content: |
            def add(a, b):
                return a + b
        - path: app/test_math.py
          content: |
            import unittest
            from math_utils import add

            class TestMath(unittest.TestCase):
                def test_add(self):
                    self.assertEqual(add(2, 3), 5)
        - path: .ax/goal.md
          content: "${GOAL}"
        - path: .ax/config.json
          content: '{"prompt":"${GOAL}"}'
        - path: .ax/verify.sh
          content: |
            #!/usr/bin/env bash
            set -euo pipefail
            git init /workspace/app >/dev/null
            if [[ "\${GEMINI_API_KEY:-}" == "placeholder" ]]; then
              echo "IS_PLACEHOLDER=yes"
            else
              echo "IS_PLACEHOLDER=no"
              exit 1
            fi
            if tr '\0' '\n' </proc/1/environ | grep -qE 'AIzaSy[A-Za-z0-9_-]{20,}'; then
              echo "PROC1_CLEAN=no"
              exit 1
            else
              echo "PROC1_CLEAN=yes"
            fi
            /usr/local/bin/ax-harness
            if [[ -s "\${AX_OUTPUT_FILE}" ]]; then
              echo "AX_OUTPUT_WRITTEN=yes"
            fi
            echo "=== math_utils.py ==="
            cat /workspace/app/math_utils.py
            echo "=== test_math.py ==="
            cat /workspace/app/test_math.py
            echo "=== unittest ==="
            PYTHONPATH=/workspace/app python3 -m unittest discover -s /workspace/app -p "test_*.py" -v
  - name: AX_TASK_YAML
    value: |
      apiVersion: ax.io/v1alpha1
      kind: Task
      metadata:
        name: ${ACTOR}
        atespace: default
      spec:
        ${TASK_CMD_KEY}:
        - /bin/bash
        - /workspace/.ax/verify.sh
        env:
        - name: AX_GOAL_FILE
          value: /workspace/.ax/goal.md
        - name: AX_CONFIG_FILE
          value: /workspace/.ax/config.json
        - name: AX_OUTPUT_FILE
          value: /workspace/.ax/output
        - name: AGY_RUNTIME_INSTALL
          value: "true"
        - name: GEMINI_API_KEY
          value: placeholder
  volumeMounts:
  - mountPath: /workspace
    name: workspace
  - mountPath: /opt/ax
    name: ax-runner
  - mountPath: /run/ate/egress-trust-bundle
    name: egress-trust-bundle
  wakeupProbe:
    httpGet:
      path: /readyz
      port: 80
    timeoutSeconds: 30
volumes:
- name: workspace
  durableDir: {}
- name: ax-runner
  image:
    reference: ${RUNNER_DIGEST}
- name: egress-trust-bundle
  systemInfo:
    dataSources:
    - trustBundle:
        names:
        - egress-mitm.ate.dev
        - system-roots.ate.dev
        path: trust-bundle.pem
resources:
  limits:
    cpuMillicores: "2000"
    memoryBytes: "4294967296"
snapshotConfig:
  preferredFidelity: SNAPSHOT_FIDELITY_VOLUMES
EOF

sed "s|CREDENTIAL_URI_PLACEHOLDER|${CREDENTIAL_URI}|g" \
  "${SCRIPT_DIR}/k8s/egress-policy-real-gemini.yaml" >"${TMP_DIR}/egress-policy.yaml"

echo "==> Creating ActorTemplate, Actor, and EgressPolicy (${CREDENTIAL_URI})..."
"${KATE[@]}" create actor-template -f "${TMP_DIR}/actor-template.yaml" >/dev/null
"${KATE[@]}" create actor "${ACTOR}" -a default --template "${TMPL}" >/dev/null
"${KATE[@]}" create egress-policy "${ACTOR}" -a default -f "${TMP_DIR}/egress-policy.yaml" >/dev/null

echo "==> Resuming Actor and waiting for live Gemini task completion..."
"${KATE[@]}" resume actor "${ACTOR}" -a default >/dev/null

LOGS=""
COMPLETED="false"
TIMEOUT_S="${TIMEOUT_S:-180}"
for _ in $(seq 1 "${TIMEOUT_S}"); do
  LOGS="$("${KATE[@]}" logs actor "${ACTOR}" -a default 2>&1 || true)"
  if echo "${LOGS}" | grep -qE "task command completed successfully|task command exited with error"; then
    COMPLETED="true"
    break
  fi
  sleep 1
done

if [[ "${COMPLETED}" != "true" ]]; then
  echo "${LOGS}" >&2
  echo "[FAIL] Timed out waiting for ${ACTOR} after ${TIMEOUT_S}s" >&2
  exit 1
fi

PASS=0
FAIL=0
check() {
  local name="$1"
  local ok="$2"
  local detail="$3"
  if [[ "${ok}" == "true" ]]; then
    echo "[PASS] ${name}: ${detail}"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] ${name}: ${detail}"
    FAIL=$((FAIL + 1))
  fi
}

if [[ "${PREINSTALL_AGY}" == "false" ]]; then
  check "runtime-install-agy" \
    "$(echo "${LOGS}" | grep -q "install-agy: installed agy" && echo true || echo false)" \
    "downloaded and verified the pinned agy via tlsPassthrough"
fi
check "ax-output-file" \
  "$(echo "${LOGS}" | grep -q "AX_OUTPUT_WRITTEN=yes" && echo true || echo false)" \
  "answer written to AX_OUTPUT_FILE (/workspace/.ax/output)"
check "placeholder-env" \
  "$(echo "${LOGS}" | grep -q "IS_PLACEHOLDER=yes" && echo true || echo false)" \
  "container GEMINI_API_KEY remained placeholder"
check "proc1-secret-clean" \
  "$(echo "${LOGS}" | grep -q "PROC1_CLEAN=yes" && echo true || echo false)" \
  "/proc/1/environ free of real API key"
check "math-utils-subtract" \
  "$(echo "${LOGS}" | grep -q "def subtract" && echo true || echo false)" \
  "real Gemini added subtract(a, b) to /workspace/app/math_utils.py"
check "test-math-subtract" \
  "$(echo "${LOGS}" | grep -q "test_subtract" && echo true || echo false)" \
  "real Gemini added test_subtract to /workspace/app/test_math.py"
check "unittest-pass" \
  "$(echo "${LOGS}" | grep -q "task command completed successfully" && echo true || echo false)" \
  "task and python3 unittest exited 0"

echo
echo "Summary: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  echo "--- Actor logs ---" >&2
  echo "${LOGS}" >&2
  exit 1
fi
