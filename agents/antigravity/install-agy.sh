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

# Installs a pinned Antigravity CLI (agy) release for the current Linux
# platform (glibc). The release URL and SHA-512 checksum of every supported
# version are pinned below, so the only network request is the tarball
# download and its checksum never comes from the same bucket as the binary.
#
#   install-agy.sh [version] [dest-dir]
#
# To bump agy, add a case below with the release's execution ID and the
# SHA-512 of each platform's tarball, computed from the downloaded files, and
# update PINNED_VERSION.

set -euo pipefail

PINNED_VERSION="1.5.10"

version="${1:-${PINNED_VERSION}}"
dest="${2:-${HOME:-/root}/.local/bin}"
GCS="${AGY_GCS_BASE_URL:-https://storage.googleapis.com/antigravity-public}"

case "$(uname -m)" in
  x86_64|amd64) platform="linux-x64" tarball="cli_linux_x64.tar.gz" ;;
  aarch64|arm64) platform="linux-arm" tarball="cli_linux_arm64.tar.gz" ;;
  *)
    echo "install-agy: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

case "${version}" in
  1.5.10)
    execution_id="5253791805734912"
    case "${platform}" in
      linux-x64) sha512="713ae840845d74736e2d4a96f5d84e3353d614e73a875793ddf500997ccee09595448cebfd8e94fdd90ce2a0fa97707bd1cc29763dcfe01c945d80c92234378f" ;;
      linux-arm) sha512="f9f5c7ebc47a8b8de536acca8116b1f5a43dca614cde94008fe5a510517b23535fb281d85416930d76e76478858bf3dc66ea6d1b0c9b6eeadcfabe4d8ef2a807" ;;
    esac
    ;;
  *)
    echo "install-agy: agy ${version} is not pinned in install-agy.sh (pinned: ${PINNED_VERSION})" >&2
    exit 1
    ;;
esac

url="${GCS}/antigravity-cli/${version}-${execution_id}/${platform}/${tarball}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Fail fast with an actionable message before downloading if the temp or
# destination volume lacks space (e.g., AX's default 512Mi memory-backed
# workspace cannot hold the ~100 MB archive + ~267 MB agy binary).
min_free_mb="${AGY_MIN_FREE_MB:-450}"
check_free_space() {
  local dir="$1"
  while [[ ! -d "${dir}" && "${dir}" != "/" ]]; do
    dir="$(dirname "${dir}")"
  done
  local avail_mb
  avail_mb="$(df -Pm "${dir}" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
  if [[ "${avail_mb}" =~ ^[0-9]+$ && "${avail_mb}" -lt "${min_free_mb}" ]]; then
    echo "install-agy: insufficient space in ${dir} (${avail_mb} MiB free, need at least ${min_free_mb} MiB for agy archive + binary); raise spec.profile.resources.limits.memory (recommended: 4Gi)" >&2
    exit 1
  fi
}
check_free_space "${tmp}"
check_free_space "${dest}"

curl -fsSL -o "${tmp}/agy.tar.gz" "${url}"
echo "${sha512}  ${tmp}/agy.tar.gz" | sha512sum -c - >/dev/null
tar -xzf "${tmp}/agy.tar.gz" -C "${tmp}" antigravity
rm -f "${tmp}/agy.tar.gz"

mkdir -p "${dest}"
install -m 0755 "${tmp}/antigravity" "${dest}/agy"
echo "install-agy: installed agy ${version} (${platform}) to ${dest}/agy" >&2
