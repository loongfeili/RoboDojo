#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

info() { echo -e "\e[1;32m>>> $*\e[0m"; }
error() { echo -e "\e[1;31m[ERROR] $*\e[0m" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: bash scripts/install.sh

RoboDojo uses uv for Python dependency management. This helper only validates
system prerequisites, initializes pinned submodules, and invokes `uv sync`.
It never installs Miniconda and never calls pip or `uv pip`.

Environment:
  UV_CACHE_DIR  Local uv cache location (HDFS FUSE is not supported)

For ephemeral containers, archive the completed environment afterward with:
  bash scripts/persist_uv_env.sh save
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || { usage >&2; exit 2; }

command -v uv >/dev/null 2>&1 || error "uv is required: https://docs.astral.sh/uv/"
command -v git >/dev/null 2>&1 || error "git is required"
command -v ffmpeg >/dev/null 2>&1 || error "ffmpeg is required (apt-get install ffmpeg)"

cd "${ROOT_DIR}"
info "Initializing pinned submodules..."
git submodule update --init --recursive

export OMNI_KIT_ACCEPT_EULA="${OMNI_KIT_ACCEPT_EULA:-Y}"
export UV_HTTP_TIMEOUT="${UV_HTTP_TIMEOUT:-600}"
export UV_CONCURRENT_DOWNLOADS="${UV_CONCURRENT_DOWNLOADS:-8}"

info "Synchronizing the locked RoboDojo environment..."
uv sync

info "RoboDojo environment is ready. Run commands with: uv run <command>"
