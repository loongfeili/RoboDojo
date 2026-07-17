# Isaac Sim 5.1 driver compatibility

This document records the investigation and fix for Isaac Sim 5.1 RTX camera
hangs in the target container. The final configuration keeps Isaac Sim 5.1 and
does not modify system NVIDIA libraries.

## Verified configuration

- NVIDIA L20
- loaded kernel module: `535.261.03`
- Isaac Sim: `5.1.0`
- PyTorch: `2.7.0+cu128`
- three RoboDojo RGB cameras at 640 x 480

The final end-to-end `stack_bowls` demo evaluation completed 800 steps, wrote
three camera videos, and produced `_result.json` with `eval_time: 1`.

## Symptoms

Before the fix, Kit could load the scene, robots, PhysX, and camera extensions.
It then consistently stopped after creating the tiled RTX render products and
attaching the RGB annotators:

```text
HydraTexture ... camera_prim_view_tiled_sensor
Attaching rgb to render product(s) ...
FabricPopulation: 0 meshes ...
```

No first frame arrived. After 120 seconds, Kit reported `Hang detected`.
Increasing the timeout did not help, and warm-cache runs ruled out ongoing
shader compilation.

Two driver-version observations initially appeared contradictory:

```text
nvidia-smi / NVRM: 535.261.03
Kit Vulkan table: 535.05.03
```

## Root cause

Two independent problems were present.

### Vulkan version truncation

NVIDIA's Vulkan version field allocates eight bits to the minor component.
Consequently, the minor value is truncated:

```text
261 & 0xff = 5
535.261.03 -> 535.05.03
```

Kit compared the truncated value with its blocked driver range and incorrectly
treated the installed driver as older than `535.129`.

Disabling `/rtx/verifyDriverVersion` only bypasses this false-negative check. It
does not by itself make the graphics stack consistent.

### Mixed kernel and user-space NVIDIA libraries

The kernel module, Vulkan ICD, GLX, and OpenGL libraries were `535.261.03`, but
three default user-space symlinks pointed to `550.54.15`:

```text
libcuda.so.1                    -> libcuda.so.550.54.15
libnvidia-ptxjitcompiler.so.1  -> libnvidia-ptxjitcompiler.so.550.54.15
libnvidia-nvvm.so.4            -> libnvidia-nvvm.so.550.54.15
```

Both 535 and 550 files existed in the container. This allowed basic CUDA checks
to pass while leaving CUDA-Vulkan interoperability inconsistent. The mismatch
manifested at the first RTX camera frame.

## Implemented fix

[`scripts/internal/prepare_nvidia_driver_compat.sh`](../scripts/internal/prepare_nvidia_driver_compat.sh)
compares the loaded kernel version with the resolved `libcuda.so.1`.

When they differ and matching versioned libraries exist, it creates a non-root
overlay under:

```text
.cache/nvidia-driver-compat/<kernel-version>/
```

The overlay contains symlinks for `libcuda`, PTX JIT, and NVVM. RoboDojo
prepends it to `LD_LIBRARY_PATH` only for the launched process. It never changes
files under `/usr/lib`.

Both simulator entry points apply the same logic:

- [`scripts/robodojo.sh`](../scripts/robodojo.sh)
- [`scripts/eval_policy.sh`](../scripts/eval_policy.sh)

For verified `535.261.x` installations, the launchers also disable the Kit
driver gate automatically because its Vulkan minor field cannot represent
`261` correctly.

## Controls

```bash
# Default: automatically handle the verified 535.261 encoding edge case.
export ROBODOJO_SKIP_DRIVER_CHECK=auto

# Force the gate off.
export ROBODOJO_SKIP_DRIVER_CHECK=1

# Never bypass the gate.
export ROBODOJO_SKIP_DRIVER_CHECK=0

# Override where versioned NVIDIA libraries are discovered.
export ROBODOJO_NVIDIA_LIB_DIR=/usr/lib/x86_64-linux-gnu

# Joint-only diagnostics can skip CuRobo planner initialization.
export ROBODOJO_DISABLE_PLANNER=1
```

`ROBODOJO_DISABLE_PLANNER=1` is intended for diagnostics and joint-action demo
policies. Normal end-effector policies require the planner.

## Validation

Check the driver overlay without starting Isaac Sim:

```bash
bash scripts/internal/prepare_nvidia_driver_compat.sh
readlink -f /usr/lib/x86_64-linux-gnu/libcuda.so.1
cat /proc/driver/nvidia/version
```

Run the short physics and standard-camera check:

```bash
bash scripts/robodojo.sh sim-smoke \
  --enable_cameras \
  --rendering_mode performance \
  --device-id 2
```

The verified run produced:

```text
status: PASS
physics: 1.216 -> 2.016
camera: cam_head
shape: 480 x 640 x 3
```

The formal tiled-camera path was then tested with `demo_policy`,
`EVAL_NUM=1`, and planner initialization disabled. It completed all 800 steps
and wrote videos for:

- `cam_head`
- `cam_left_wrist`
- `cam_right_wrist`

## Why the 5.0 experiment is separate

Isaac Sim 5.0 was tested because RoboLab rendered successfully on the same
host. It helped show that changing Isaac Sim versions did not resolve the
mixed-driver root cause. The experiment and its lock file live only on the
`feature/isaac-sim-5.0` branch; `main` remains on 5.1.

## Limitations

- Driver 535 is not the current officially recommended Isaac Sim 5.1 driver.
  The configuration above is empirically validated for this container, not a
  general replacement for upgrading the host driver.
- The overlay requires matching versioned NVIDIA libraries to already exist.
  It fails explicitly rather than downloading or installing driver files.
- Missing remote MDL materials may produce warnings and fallback appearances,
  but did not prevent physics, RGB capture, video writing, or result generation.
