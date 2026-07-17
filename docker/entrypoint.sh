#!/usr/bin/env bash
# Activate the locked RoboDojo uv environment, then exec the requested command
# from the project root.
set -e

cd /workspace/RoboDojo
export VIRTUAL_ENV=/workspace/RoboDojo/.venv
export PATH="${VIRTUAL_ENV}/bin:${PATH}"

exec "$@"
