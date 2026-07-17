#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_ROOT="${ROBODOJO_DATA_ROOT:-}"
SKIP_UV="false"

usage() {
  cat <<'EOF'
Usage: ROBODOJO_DATA_ROOT=/persistent/path bash scripts/persist_container_state.sh [--skip-uv]

Archives the repository (including submodules), Git bundles, NVIDIA compatibility
libraries, uv environment/cache, and integrity manifests. Assets must already
live under ROBODOJO_DATA_ROOT/Assets via scripts/init_assets.sh.

Options:
  --skip-uv  Keep existing venv.tar.zst and uv-cache.tar.zst archives.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-uv) SKIP_UV="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "${DATA_ROOT}" ]] || {
  echo "ROBODOJO_DATA_ROOT must point to persistent storage" >&2
  exit 1
}
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
command -v zstd >/dev/null 2>&1 || { echo "zstd is required" >&2; exit 1; }

STATE_DIR="${DATA_ROOT}/state"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
mkdir -p "${STATE_DIR}"

if [[ -n "$(git -C "${ROOT_DIR}" status --porcelain)" ]]; then
  echo "Repository must be clean before it is archived" >&2
  exit 1
fi

archive_repository() {
  local archive="${TMP_DIR}/RoboDojo-source.tar.zst"
  tar -C "$(dirname "${ROOT_DIR}")" \
    --exclude="RoboDojo/.cache" \
    --exclude="RoboDojo/.venv" \
    --exclude="RoboDojo/Assets" \
    --exclude="RoboDojo/eval_result" \
    --exclude="RoboDojo/smoke_results" \
    --exclude="RoboDojo/logs" \
    --exclude="RoboDojo/**/__pycache__" \
    -I "zstd -T0 -6" \
    -cf "${archive}" \
    "$(basename "${ROOT_DIR}")"
  mv -f "${archive}" "${STATE_DIR}/RoboDojo-source.tar.zst"
}

create_bundle() {
  local repo="$1"
  local name="$2"
  git -C "${repo}" bundle create "${TMP_DIR}/${name}.bundle" --all
  mv -f "${TMP_DIR}/${name}.bundle" "${STATE_DIR}/${name}.bundle"
}

archive_driver_libraries() {
  local version
  version="$(
    awk '/NVRM version:/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) {
          print $i
          exit
        }
      }
    }' /proc/driver/nvidia/version
  )"
  [[ -n "${version}" ]] || return 0

  local source_dir="${ROBODOJO_NVIDIA_LIB_DIR:-/usr/lib/x86_64-linux-gnu}"
  local target_dir="${STATE_DIR}/nvidia/${version}"
  local stem source
  mkdir -p "${target_dir}"
  for stem in \
    libcuda.so \
    libGLX_nvidia.so \
    libnvidia-glcore.so \
    libnvidia-glvkspirv.so \
    libnvidia-ml.so \
    libnvidia-nvvm.so \
    libnvidia-ptxjitcompiler.so \
    libnvidia-rtcore.so; do
    source="${source_dir}/${stem}.${version}"
    [[ -f "${source}" ]] && cp -a "${source}" "${target_dir}/"
  done
  ln -sfn "libcuda.so.${version}" "${target_dir}/libcuda.so"
  ln -sfn "libcuda.so.${version}" "${target_dir}/libcuda.so.1"
  ln -sfn "libnvidia-ml.so.${version}" "${target_dir}/libnvidia-ml.so.1"
  ln -sfn "libnvidia-nvvm.so.${version}" "${target_dir}/libnvidia-nvvm.so.4"
  ln -sfn "libnvidia-ptxjitcompiler.so.${version}" \
    "${target_dir}/libnvidia-ptxjitcompiler.so.1"
}

write_manifests() {
  git -C "${ROOT_DIR}" status --short --branch > "${STATE_DIR}/git-status.txt"
  git -C "${ROOT_DIR}" submodule status > "${STATE_DIR}/submodules.txt"
  git -C "${ROOT_DIR}" log -1 --format=fuller > "${STATE_DIR}/git-head.txt"

  local asset_repo="${ROBODOJO_ASSET_CACHE:-${ROOT_DIR}/.cache/robodojo_assets_repo}"
  if [[ -d "${asset_repo}/.git" ]]; then
    git -C "${asset_repo}" lfs ls-files -l > "${STATE_DIR}/assets-lfs-manifest.txt"
  fi

  (
    cd "${STATE_DIR}"
    find . -type f ! -name manifest.sha256 -print0 |
      sort -z |
      xargs -0 sha256sum > manifest.sha256
  )

  (
    cd "${DATA_ROOT}"
    sha256sum \
      uv-cache.tar.zst \
      venv.tar.zst \
      state/manifest.sha256 \
      > recovery-manifest.sha256
  )
}

archive_repository
create_bundle "${ROOT_DIR}" "RoboDojo"
create_bundle "${ROOT_DIR}/XPolicyLab" "XPolicyLab"
create_bundle "${ROOT_DIR}/third_party/IsaacLab" "IsaacLab"
create_bundle "${ROOT_DIR}/third_party/curobo" "curobo"
archive_driver_libraries

if [[ "${SKIP_UV}" != "true" ]]; then
  ROBODOJO_DATA_ROOT="${DATA_ROOT}" bash "${ROOT_DIR}/scripts/persist_uv_env.sh" save
fi

write_manifests
echo "[persist_container_state] state saved under ${STATE_DIR}"
