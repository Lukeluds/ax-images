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

# Pure Antigravity (agy) agent image for AX: no AX runner baked in.
#
# By default (PREINSTALL_AGY=true), the image installs the pinned Antigravity
# CLI into /usr/local/bin at build time, alongside Debian packages,
# /usr/local/share/ax/install-agy.sh, and /usr/local/bin/ax-harness. Pass
# --build-arg PREINSTALL_AGY=false for a runtime-install image with no agy
# binary, where ax-harness installs the pinned agy on startup only when a task
# sets AGY_RUNTIME_INSTALL=true. Published images are runtime-install builds
# until shipping the agy binary is cleared (see release.yaml).
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        jq \
        openssh-client \
        procps \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# The agy version this image installs, recorded in the image as AGY_VERSION
# and a label. It must equal PINNED_VERSION in install-agy.sh (CI checks
# this), so bump both together.
ARG AGY_VERSION=1.5.10
ARG PREINSTALL_AGY=true

COPY install-agy.sh /usr/local/share/ax/install-agy.sh
RUN chmod 0755 /usr/local/share/ax/install-agy.sh \
    && if [ "${PREINSTALL_AGY}" = "true" ]; then \
        /usr/local/share/ax/install-agy.sh "${AGY_VERSION}" /usr/local/bin \
        && agy --version; \
    fi

LABEL io.agentexecutor.agy.version="${AGY_VERSION}"

ENV AGY_CLI_DISABLE_AUTO_UPDATE=true \
    AGY_VERSION="${AGY_VERSION}"

# ax-harness installs agy at runtime into <workspace>/.ax/bin. Putting the
# default workspace's copy on PATH lets `ax ssh` sessions, which never run the
# launcher, find it too. It goes last, so a leftover workspace copy never
# shadows an agy installed in the image. Tasks that change the workspace path
# don't get this.
ENV PATH="${PATH}:/workspace/.ax/bin"

COPY ax-harness /usr/local/bin/ax-harness
RUN chmod 0755 /usr/local/bin/ax-harness
