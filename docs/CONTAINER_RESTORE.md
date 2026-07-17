# Restoring RoboDojo in a new container

The working container is ephemeral. Persistent RoboDojo data is stored under:

```text
/mnt/hdfs/haruna/home/byte_data_seed/hdd_hldy/iccv/user/cuihaiqin/robodojo-data
```

The root RoboDojo project uses `uv` exclusively. Python installation is always
performed with `uv sync`; neither `pip` nor `uv pip` is part of the installation
or recovery process.

## Persistent layout

```text
robodojo-data/
├── Assets/                         # complete RoboDojo simulation assets
├── logs/                           # background download/archive logs
├── smoke/                          # persistent simulation smoke evidence
├── recovery-manifest.sha256        # checksums for uv/venv and state manifest
├── uv-cache.tar.zst                # restorable uv download/build cache
├── venv.tar.zst                    # fast-path .venv snapshot
└── state/
    ├── RoboDojo-source.tar.zst     # source, .git, and submodule worktrees
    ├── RoboDojo.bundle             # main Git repository backup
    ├── XPolicyLab.bundle           # policy/client submodule backup
    ├── IsaacLab.bundle             # IsaacLab submodule backup
    ├── curobo.bundle               # CuRobo submodule backup
    ├── nvidia/<version>/           # matching user-space driver libraries
    ├── assets-lfs-manifest.txt     # expected asset object hashes
    ├── git-head.txt
    ├── git-status.txt
    ├── submodules.txt
    └── manifest.sha256
```

`uv` cache directories must not be used directly on HDFS FUSE: uv requires
atomic temporary-file operations that the mount does not reliably support.
The cache is restored locally from `uv-cache.tar.zst` instead.

## 1. Check the archive

```bash
export ROBODOJO_DATA_ROOT=/mnt/hdfs/haruna/home/byte_data_seed/hdd_hldy/iccv/user/cuihaiqin/robodojo-data

cd "$ROBODOJO_DATA_ROOT"
sha256sum -c recovery-manifest.sha256

cd "$ROBODOJO_DATA_ROOT/state"
sha256sum -c manifest.sha256
```

## 2. Restore the repository

The source archive is the fastest and most complete path because it includes
the pinned submodule worktrees and Git metadata:

```bash
mkdir -p /home/tiger
tar -C /home/tiger -I zstd -xf \
  "$ROBODOJO_DATA_ROOT/state/RoboDojo-source.tar.zst"

cd /home/tiger/RoboDojo
git status --short --branch
git submodule status
```

If the source archive is unavailable, clone the main bundle and reconstruct
the three submodules from their corresponding bundles. The commit IDs expected
for each submodule are recorded in `state/submodules.txt`.

## 3. Restore persistent assets

Code expects an `Assets` entry at the repository root:

```bash
cd /home/tiger/RoboDojo
ln -sfn "$ROBODOJO_DATA_ROOT/Assets" Assets
export ASSETS_PATH=/home/tiger/RoboDojo
```

The full asset download is resumable:

```bash
export https_proxy=http://sys-proxy-rd-relay.byted.org:8118
export http_proxy=http://sys-proxy-rd-relay.byted.org:8118
bash scripts/init_assets.sh --all-assets
```

This downloads only `Assets/**` (about 40 GB), never the repository's
checkpoint or training-data collections.

## 4. Restore or recreate the Python environment

Install these small system prerequisites in the base image:

- `uv`
- Git and Git LFS
- `ffmpeg`
- `zstd`
- the headless EGL/Vulkan libraries listed in the project `Dockerfile`

For a fast recovery, restore the local `.venv` and uv cache snapshots:

```bash
cd /home/tiger/RoboDojo
export ROBODOJO_DATA_ROOT=/mnt/hdfs/haruna/home/byte_data_seed/hdd_hldy/iccv/user/cuihaiqin/robodojo-data
bash scripts/persist_uv_env.sh restore
```

Then always reconcile the environment with the committed lock file:

```bash
export https_proxy=http://sys-proxy-rd-relay.byted.org:8118
export http_proxy=http://sys-proxy-rd-relay.byted.org:8118
export HTTPS_PROXY="$https_proxy"
export HTTP_PROXY="$http_proxy"
export UV_HTTP_TIMEOUT=600
export UV_CONCURRENT_DOWNLOADS=8

uv sync --frozen
```

`uv sync --frozen` is the authoritative installation command. The `.venv`
archive is only an optimization and may be discarded if the Python ABI or
container base changes.

## 5. Restore NVIDIA compatibility libraries

The investigated container loaded NVIDIA kernel module `535.261.03` while
several default CUDA user-space symlinks pointed to `550.54.15`. The state
archive keeps matching 535 libraries.

Normally the launchers detect and use matching system files automatically. If
the new container lacks those versioned files, point discovery at the archive:

```bash
driver_version="$(
  awk '/NVRM version:/ {
    for (i = 1; i <= NF; i++)
      if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }
  }' /proc/driver/nvidia/version
)"

export ROBODOJO_NVIDIA_LIB_DIR="$ROBODOJO_DATA_ROOT/state/nvidia/$driver_version"
bash scripts/internal/prepare_nvidia_driver_compat.sh
```

See [Isaac Sim 5.1 driver compatibility](ISAAC_SIM_5_1_DRIVER_COMPAT.md) for
the root cause, controls, and validation evidence.

## 6. Verify the restored environment

```bash
cd /home/tiger/RoboDojo
export OMNI_KIT_ACCEPT_EULA=Y
export ACCEPT_EULA=Y

bash scripts/robodojo.sh doctor --skip-policy
bash scripts/robodojo.sh sim-smoke \
  --enable_cameras \
  --rendering_mode performance \
  --device-id 0
```

Expected doctor result:

```text
pass=14 warn=3 fail=0
```

The smoke must write `diagnostics.json` with `status: PASS`, advance physics
time, and produce a non-empty RGB image.

## 7. Refresh the persistent snapshot

After code, lockfile, submodule, or environment changes:

```bash
cd /home/tiger/RoboDojo
export ROBODOJO_DATA_ROOT=/mnt/hdfs/haruna/home/byte_data_seed/hdd_hldy/iccv/user/cuihaiqin/robodojo-data
bash scripts/persist_container_state.sh
```

Use `--skip-uv` when the existing uv and `.venv` archives are already current:

```bash
bash scripts/persist_container_state.sh --skip-uv
```

Policy-specific dependencies remain owned by XPolicyLab and should use their
own environments. They are intentionally not merged into the RoboDojo
simulation lock.
