# AX Images

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Prebuilt container images for [AX](https://github.com/agentexecutor), such as
agent images (Antigravity, Claude Code) and, later, MCP server images.

Images are built by this repository's CI and published by digest to the public
Artifact Registry in the AX GCP project. Agent images stay "pure": they contain
the agent CLI and a small launcher, and never the AX runner.
