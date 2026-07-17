#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_ROOT="${ROBODOJO_DATA_ROOT:-${ROOT_DIR}/.cache/robodojo-data}"
UV_CACHE_DIR="${UV_CACHE_DIR:-${HOME}/.cache/uv}"
ACTION="${1:-}"

usage() {
  echo "Usage: bash scripts/persist_uv_env.sh save|restore"
}

[[ "${ACTION}" == "save" || "${ACTION}" == "restore" ]] || { usage >&2; exit 2; }
command -v zstd >/dev/null 2>&1 || {
  echo "zstd is required to persist the uv environment" >&2
  exit 1
}
mkdir -p "${DATA_ROOT}"

archive() {
  local source="$1"
  local destination="$2"
  [[ -e "${source}" ]] || return 0
  local parent base
  parent="$(dirname "${source}")"
  base="$(basename "${source}")"
  tar -C "${parent}" -I "zstd -T0 -3" -cf "${destination}.partial" "${base}"
  mv -f "${destination}.partial" "${destination}"
}

restore() {
  local archive_path="$1"
  local parent="$2"
  [[ -f "${archive_path}" ]] || return 0
  mkdir -p "${parent}"
  tar -C "${parent}" -I zstd -xf "${archive_path}"
}

if [[ "${ACTION}" == "save" ]]; then
  # Some NVIDIA wheels ship documentation directories without owner read
  # permission, which makes an otherwise valid environment impossible to tar.
  chmod -R u+rwX "${ROOT_DIR}/.venv"
  archive "${ROOT_DIR}/.venv" "${DATA_ROOT}/venv.tar.zst"
  archive "${UV_CACHE_DIR}" "${DATA_ROOT}/uv-cache.tar.zst"
  echo "[persist_uv_env] saved under ${DATA_ROOT}"
else
  [[ -e "${ROOT_DIR}/.venv" ]] || restore "${DATA_ROOT}/venv.tar.zst" "${ROOT_DIR}"
  [[ -e "${UV_CACHE_DIR}" ]] || restore "${DATA_ROOT}/uv-cache.tar.zst" "$(dirname "${UV_CACHE_DIR}")"
  echo "[persist_uv_env] restored available archives from ${DATA_ROOT}"
fi
