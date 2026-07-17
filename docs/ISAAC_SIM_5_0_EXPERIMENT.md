# Isaac Sim 5.0 experiment

This branch records a diagnostic fallback attempted while investigating RTX
camera hangs on the target container. It is intentionally separate from
`main`, which uses Isaac Sim 5.1.

## Why 5.0 was tested

The host reports NVIDIA driver `535.261.03`, and the neighboring RoboLab
checkout was able to render with Isaac Sim 5.0. Downgrading RoboDojo provided
a quick way to distinguish a 5.1 regression from a host-driver or container
library problem.

The branch changes only the version-specific dependency set:

- `isaacsim[all,extscache] == 5.0.0`
- `pillow == 11.2.1`, matching Isaac Sim 5.0 metadata
- the corresponding `uv.lock`

All uv installation, persistent asset handling, doctor checks, and simulation
smoke tooling come from the shared parent commit.

## Findings

- Isaac Sim 5.0 could start and advance physics.
- A standard head camera produced RGB after bypassing the erroneous driver
  version gate.
- The original tiled camera path could still hang at its first RTX frame.
- CuRobo kernel compilation exposed an independent Warp compatibility issue
  when the planner was enabled.

The experiment therefore showed that changing Isaac Sim versions was not the
real fix. The eventual root cause was a mixed NVIDIA stack: the loaded kernel,
Vulkan, and GLX libraries were `535.261.03`, while `libcuda`, PTX JIT, and NVVM
defaulted to `550.54.15`. Use the 5.1 compatibility implementation on `main`
for normal evaluation.
