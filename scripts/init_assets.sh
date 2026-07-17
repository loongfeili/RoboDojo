#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

HF_REPO_ID="${HF_REPO_ID:-RoboDojo-Benchmark/RoboDojo}"
HF_REVISION="${HF_REVISION:-main}"
HF_REPO_URL="${HF_REPO_URL:-https://huggingface.co/datasets/${HF_REPO_ID}}"
DATA_ROOT="${ROBODOJO_DATA_ROOT:-${ROOT_DIR}/.cache/robodojo-data}"
WORK_REPO="${ROBODOJO_ASSET_CACHE:-${ROOT_DIR}/.cache/robodojo_assets_repo}"
PERSISTENT_ASSETS="${DATA_ROOT}/Assets"
TARGET_DIR="${ROOT_DIR}/Assets"
MODE="all-assets"

info() { echo -e "\e[1;32m>>> $*\e[0m"; }
error() { echo -e "\e[1;31m[ERROR] $*\e[0m" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: bash scripts/init_assets.sh [--minimal | --all-assets]

Modes:
  --minimal     Download assets for stack_bowls seed 0 (about 0.5 GB)
  --all-assets  Download Assets/** only (about 40 GB; default)

Environment:
  ROBODOJO_DATA_ROOT   Persistent data root; its Assets/ is the final store
  ROBODOJO_ASSET_CACHE Local Git/LFS work cache (fast, safe to discard)
  HF_REPO_ID           Hugging Face dataset repository
  HF_REVISION          Repository revision

Git metadata and downloads use a local cache because HDFS FUSE is too slow for
thousands of small Git files. Completed asset files are copied to DATA_ROOT.
The script never downloads ckpt/** or data/** from the 2.1 TB dataset.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --minimal) MODE="minimal"; shift ;;
    --all-assets) MODE="all-assets"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

command -v git >/dev/null 2>&1 || error "git not found"
git lfs version >/dev/null 2>&1 || error "git-lfs not found"
mkdir -p "${DATA_ROOT}" "$(dirname "${WORK_REPO}")"

if [[ ! -d "${WORK_REPO}/.git" ]]; then
  [[ ! -e "${WORK_REPO}" ]] || error "${WORK_REPO} exists but is not a git repository"
  info "Creating local sparse clone: ${WORK_REPO}"
  GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 --sparse "${HF_REPO_URL}" "${WORK_REPO}"
else
  info "Updating local asset cache..."
  git -C "${WORK_REPO}" fetch --depth 1 origin "${HF_REVISION}"
fi

GIT_LFS_SKIP_SMUDGE=1 git -C "${WORK_REPO}" sparse-checkout set Assets
GIT_LFS_SKIP_SMUDGE=1 git -C "${WORK_REPO}" checkout "${HF_REVISION}"
git -C "${WORK_REPO}" lfs install --local >/dev/null

minimal_paths=(
  "Assets/Robots/x5"
  "Assets/Room/Simple_Room_nolight"
  "Assets/Material/material_0122"
  "Assets/Material/material_0564"
  "Assets/Object/RoboDojo/Rigid/bowl/00010"
  "Assets/Object/RoboDojo/Geometry/camera_stand/00000"
  "Assets/Eval_Layout/RoboDojo/arx_x5/0/stack_bowls_0.json"
  "Assets/Background/brown_photostudio_02_4k.hdr"
)

if [[ "${MODE}" == "minimal" ]]; then
  include="$(
    printf '%s\n' \
      "Assets/Robots/x5/**" \
      "Assets/Room/Simple_Room_nolight/**" \
      "Assets/Material/material_0122/**" \
      "Assets/Material/material_0564/**" \
      "Assets/Object/RoboDojo/Rigid/bowl/00010/**" \
      "Assets/Object/RoboDojo/Geometry/camera_stand/00000/**" \
      "Assets/Eval_Layout/RoboDojo/arx_x5/0/stack_bowls_0.json" \
      "Assets/Background/brown_photostudio_02_4k.hdr" |
      paste -sd, -
  )"
else
  include="Assets/**"
fi

info "Downloading ${MODE} LFS objects (ckpt/** and data/** excluded)..."
git -C "${WORK_REPO}" lfs pull --include="${include}" --exclude="ckpt/**,data/**"

mkdir -p "${PERSISTENT_ASSETS}"
if [[ "${MODE}" == "minimal" ]]; then
  for source in "${minimal_paths[@]}"; do
    relative="${source#Assets/}"
    destination="${PERSISTENT_ASSETS}/${relative}"
    mkdir -p "$(dirname "${destination}")"
    if [[ -d "${WORK_REPO}/${source}" ]]; then
      mkdir -p "${destination}"
      cp -a "${WORK_REPO}/${source}/." "${destination}/"
    else
      cp -a "${WORK_REPO}/${source}" "${destination}"
    fi
  done
else
  cp -a "${WORK_REPO}/Assets/." "${PERSISTENT_ASSETS}/"
fi

if [[ -f "${PERSISTENT_ASSETS}/Robots/x5/curobo_tmp.yml" ]]; then
  sed "s|\${ASSETS_PATH}|${ROOT_DIR}|g" \
    "${PERSISTENT_ASSETS}/Robots/x5/curobo_tmp.yml" \
    > "${PERSISTENT_ASSETS}/Robots/x5/curobo.yml"
fi

if [[ -e "${TARGET_DIR}" && ! -L "${TARGET_DIR}" ]]; then
  error "${TARGET_DIR} exists and is not a symlink; move it before continuing"
fi
ln -sfn "${PERSISTENT_ASSETS}" "${TARGET_DIR}"

for source in "${minimal_paths[@]}"; do
  relative="${source#Assets/}"
  [[ -e "${TARGET_DIR}/${relative}" ]] || error "Asset missing after copy: ${TARGET_DIR}/${relative}"
done

required_files=(
  "Robots/x5/ARX.usd"
  "Robots/x5/curobo.yml"
  "Room/Simple_Room_nolight/simple_room_nolight.usd"
  "Object/RoboDojo/Rigid/bowl/00010/object.usdz"
  "Object/RoboDojo/Geometry/camera_stand/00000/object.usd"
)
for relative in "${required_files[@]}"; do
  file="${TARGET_DIR}/${relative}"
  [[ -s "${file}" ]] || error "Required runtime asset is empty or missing: ${file}"
  if grep -q '^version https://git-lfs.github.com/spec/v1' "${file}"; then
    error "Required runtime asset is still an LFS pointer: ${file}"
  fi
done

info "Assets ready: ${TARGET_DIR} -> ${PERSISTENT_ASSETS}"
