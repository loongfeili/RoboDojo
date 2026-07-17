#!/usr/bin/env python3
"""Launch one RoboDojo scene and verify physics plus RGB observations."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess

# Importing OpenCV before Kit avoids a known libstdc++ loading conflict.
import cv2  # noqa: F401
from isaaclab.app import AppLauncher


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task", default="stack_bowls")
    parser.add_argument("--env-cfg", default="arx_x5")
    parser.add_argument("--device-id", type=int, default=0)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--steps", type=int, default=20)
    parser.add_argument(
        "--output-dir",
        default=os.environ.get("ROBODOJO_SMOKE_OUTPUT", "smoke_results/sim_smoke"),
    )
    AppLauncher.add_app_launcher_args(parser)
    args = parser.parse_args()
    args.headless = True
    os.environ["CUDA_VISIBLE_DEVICES"] = str(args.device_id)
    args.device = "cuda:0"
    return args


ARGS = parse_args()
APP_LAUNCHER = AppLauncher(ARGS)
SIMULATION_APP = APP_LAUNCHER.app

import numpy as np
from omegaconf import OmegaConf
from PIL import Image
import torch

from env.environment.base_env import BaseEnv
from env.global_configs import BENCHMARK, ENV_CONFIG_PATH, ROOT_DIR
from env.seed_manager.seed_manager import SeedManager
from task.RoboDojo import task_registry
from utils.load_file import load_yaml
from utils.pipeline_utils import process_config, process_randomization


def gpu_diagnostics():
    result = {
        "torch": torch.__version__,
        "torch_cuda": torch.version.cuda,
        "cuda_available": torch.cuda.is_available(),
    }
    if torch.cuda.is_available():
        result["gpu_name"] = torch.cuda.get_device_name(0)
        result["gpu_capability"] = list(torch.cuda.get_device_capability(0))
        result["physical_gpu_id"] = ARGS.device_id
    try:
        output = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=driver_version",
                "--format=csv,noheader",
                f"--id={ARGS.device_id}",
            ],
            text=True,
        )
        result["driver_version"] = output.strip().splitlines()[0]
    except (OSError, subprocess.SubprocessError, IndexError):
        result["driver_version"] = None
    return result


def build_config():
    eval_cfg = load_yaml(os.path.join(ENV_CONFIG_PATH, f"{ARGS.env_cfg}.yml"))
    eval_cfg.update(
        {
            "task_name": ARGS.task,
            "num_envs": 1,
            "device_id": ARGS.device_id,
            "seed": ARGS.seed,
            "config_name": eval_cfg.get("config_name", ARGS.env_cfg),
        }
    )
    benchmark_path = os.path.join(ROOT_DIR, "task", BENCHMARK)
    config = OmegaConf.create(
        {
            "sim": load_yaml(
                os.path.join(ENV_CONFIG_PATH, "sim", eval_cfg["config"]["sim"] + ".yml")
            ),
            "scene": load_yaml(
                os.path.join(ENV_CONFIG_PATH, "scene", eval_cfg["config"]["scene"] + ".yml")
            ),
            "camera": load_yaml(
                os.path.join(ENV_CONFIG_PATH, "camera", eval_cfg["config"]["camera"] + ".yml")
            ),
            "robot": load_yaml(
                os.path.join(ENV_CONFIG_PATH, "robot", eval_cfg["config"]["robot"] + ".yml")
            ),
            "task_env": load_yaml(
                task_registry.task_config_path(
                    os.path.join(benchmark_path, "config"), ARGS.task
                )
            ),
            "eval_cfg": eval_cfg,
        }
    )
    OmegaConf.update(config, "sim.scene.num_envs", 1, force_add=True)
    OmegaConf.update(config, "sim.seed", [ARGS.seed], force_add=True)
    OmegaConf.update(config, "sim.device", "cuda:0", force_add=True)
    OmegaConf.update(config, "sim.use_fabric", True, force_add=True)
    OmegaConf.update(
        config,
        "camera.default_frequency",
        eval_cfg["observation"].get("collect_freq", 0),
        force_add=True,
    )
    config = process_randomization(config)
    config, _ = process_config(config, task_name=ARGS.task)
    for name, annotator_config in config.camera.annotator.items():
        if name not in {"common", "cam_head"}:
            annotator_config["enabled"] = False
    # Camera/physics validation does not issue robot motions. Avoid compiling
    # CuRobo kernels so this smoke isolates the simulator and renderer.
    for robot_config in config.robot.robots:
        robot_config["need_planner"] = False
    return config


def main():
    output_dir = Path(ARGS.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    diagnostics = {"gpu": gpu_diagnostics(), "task": ARGS.task, "seed": ARGS.seed}
    env = None
    try:
        config = build_config()
        _, task_class = task_registry.load_task_class(ARGS.task)

        class SmokeTask(task_class):
            """Task variant using a standard camera instead of tiled rendering."""

            def _post_setup_scene(self, sim):
                self.scene_manager.initialize(sim)
                BaseEnv._post_setup_scene(self, sim)
                self.camera_manager.initialize(sim)
                self.camera_manager.post_init()
                if hasattr(self, "reward_manager"):
                    self.reward_manager.initialize(self)

            def reset(self, seed=None, options=None):
                BaseEnv.reset(self, seed=seed, options=options)
                self.scene_manager.reload_scene()
                self.robot_manager.reset()
                for _ in range(300):
                    self.sim_step(render=False)
                self.camera_manager.reset()
                if hasattr(self, "reward_manager"):
                    self.reward_manager.reset()

            def close(self):
                self.camera_manager.destroy()
                self.robot_manager.close()
                self.scene_manager.close()
                BaseEnv.close(self)

        env = SmokeTask(config, SIMULATION_APP)

        seed_manager = SeedManager(config.eval_cfg)
        seed_manager.init_eval()
        env.scene_manager.layout_manager.replay = True
        env.scene_manager.layout_manager.set_saved_layout(
            0, seed_manager.get_seed_scene_info(0)
        )
        env.reset(seed=[0])

        camera_name = env.camera_manager.camera_names[0][0]
        camera = env.camera_manager.cameras[0][0]
        camera.initialize()
        start_time = float(env.sim.sim.current_time)
        color = None
        max_steps = max(ARGS.steps, 200)
        for step in range(max_steps):
            env.sim_step(render=False)
            env.render()
            SIMULATION_APP.update()
            candidate = camera.get_rgb(device="cpu")
            if candidate is not None and getattr(candidate, "size", 0) > 0:
                color = np.asarray(candidate)
                if step + 1 >= ARGS.steps:
                    break
        end_time = float(env.sim.sim.current_time)

        cameras = {}
        if color is None:
            raise RuntimeError(
                f"{camera_name}: no RGB frame after {max_steps} rendered steps"
            )
        if color.ndim != 3 or color.shape[2] != 3:
            raise RuntimeError(f"{camera_name}: invalid RGB shape {color.shape}")
        if not np.isfinite(color).all() or float(color.std()) <= 0.0:
            raise RuntimeError(f"{camera_name}: empty or non-finite RGB frame")
        image_path = output_dir / f"{camera_name}.png"
        Image.fromarray(color.astype(np.uint8)).save(image_path)
        cameras[camera_name] = {
            "path": str(image_path),
            "shape": list(color.shape),
            "mean": float(color.mean()),
            "std": float(color.std()),
            "min": int(color.min()),
            "max": int(color.max()),
        }

        if not cameras:
            raise RuntimeError("No RGB cameras were captured")
        if end_time <= start_time:
            raise RuntimeError(
                f"Physics time did not advance: {start_time} -> {end_time}"
            )
        diagnostics.update(
            {
                "status": "PASS",
                "physics": {
                    "start_time": start_time,
                    "end_time": end_time,
                    "steps": ARGS.steps,
                },
                "cameras": cameras,
            }
        )
        print(
            f"[sim_smoke] PASS physics={start_time:.4f}->{end_time:.4f} "
            f"cameras={','.join(cameras)}"
        )
    except Exception as exc:
        diagnostics.update({"status": "FAIL", "error": f"{type(exc).__name__}: {exc}"})
        (output_dir / "diagnostics.json").write_text(
            json.dumps(diagnostics, indent=2), encoding="utf-8"
        )
        print(f"[sim_smoke] FAIL {type(exc).__name__}: {exc}", flush=True)
        # SimulationApp.close() can terminate Kit with status 0 and mask the
        # active Python exception. This process is disposable, so preserve the
        # smoke failure status and let the OS release Kit/GPU resources.
        os._exit(1)
    finally:
        (output_dir / "diagnostics.json").write_text(
            json.dumps(diagnostics, indent=2), encoding="utf-8"
        )
        if env is not None:
            env.close()
        SIMULATION_APP.close()


if __name__ == "__main__":
    main()
