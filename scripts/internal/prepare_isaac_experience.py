#!/usr/bin/env python3
"""Create a local IsaacLab experience matching the installed Isaac Sim extensions."""

from __future__ import annotations

from pathlib import Path
import re
import site
import tomllib

ROOT_DIR = Path(__file__).resolve().parents[2]
BASE_EXPERIENCE = ROOT_DIR / "third_party/IsaacLab/apps/isaaclab.python.kit"
OUTPUT = ROOT_DIR / ".cache/robodojo/isaaclab.python.kit"


def installed_urdf_version() -> str:
    for site_dir in site.getsitepackages():
        config = (
            Path(site_dir)
            / "isaacsim/exts/isaacsim.asset.importer.urdf/config/extension.toml"
        )
        if config.is_file():
            with config.open("rb") as stream:
                return str(tomllib.load(stream)["package"]["version"])
    raise FileNotFoundError("Could not locate the installed Isaac Sim URDF extension")


def main():
    version = installed_urdf_version()
    source = BASE_EXPERIENCE.read_text(encoding="utf-8")
    patched, count = re.subn(
        r'("isaacsim\.asset\.importer\.urdf"\s*=\s*\{version\s*=\s*")[^"]+(")',
        rf"\g<1>{version}\g<2>",
        source,
        count=1,
    )
    if count != 1:
        raise RuntimeError(f"URDF dependency pin not found in {BASE_EXPERIENCE}")
    isaaclab_source = ROOT_DIR / "third_party/IsaacLab/source"
    patched = patched.replace(
        '"${app}/../source", # needed to find extensions in Isaac Lab',
        f'"{isaaclab_source}", # RoboDojo vendored IsaacLab extensions',
    )
    patched = re.sub(
        r'^"isaaclab_(?:mimic|rl)" = \{order = 1000\}\n',
        "",
        patched,
        flags=re.MULTILINE,
    )
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(patched, encoding="utf-8")
    print(OUTPUT)


if __name__ == "__main__":
    main()
