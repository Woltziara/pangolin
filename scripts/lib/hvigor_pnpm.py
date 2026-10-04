"""Seed a locked pnpm into HVIGOR_USER_HOME. Never unbounded npm install on a fresh HOME."""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

PNPM_VERSION = "10.28.2"
INSTALL_TIMEOUT_SEC = 90


class PnpmSeedError(RuntimeError):
    pass


def _bin(dest: Path, version: str = PNPM_VERSION) -> Path:
    return dest / "wrapper" / "tools" / version / "node_modules" / ".bin" / "pnpm"


def _real(dest: Path, version: str = PNPM_VERSION) -> Path:
    return dest / "wrapper" / "tools" / version / "node_modules" / "pnpm" / "bin" / "pnpm.cjs"


def _repair_shim(tool_root: Path) -> None:
    real = (tool_root / "node_modules" / "pnpm" / "bin" / "pnpm.cjs").resolve()
    shim = tool_root / "node_modules" / ".bin" / "pnpm"
    if not real.is_file():
        return
    shim.parent.mkdir(parents=True, exist_ok=True)
    if shim.is_symlink():
        shim.unlink()  # Replace the link, never overwrite pnpm.cjs through it.
    shim.write_text("#!/bin/sh\nexec node \"%s\" \"$@\"\n" % real)
    os.chmod(shim, 0o755)


def pnpm_ok(root: Path, version: str = PNPM_VERSION) -> bool:
    path = _bin(root, version)
    real = _real(root, version)
    cmds: list[list[str]] = []
    if path.is_file() and os.access(path, os.X_OK):
        cmds.append([str(path), "--version"])
    if real.is_file():
        cmds.append(["node", str(real), "--version"])
    if not cmds:
        return False
    tool = root / "wrapper" / "tools" / version
    cwd = str(tool) if tool.is_dir() else None
    for cmd in cmds:
        try:
            out = subprocess.check_output(cmd, text=True, timeout=8, cwd=cwd)
        except subprocess.TimeoutExpired:
            continue
        except subprocess.CalledProcessError:
            continue
        except OSError:
            continue
        got = out.strip().splitlines()[-1].strip() if out.strip() else ""
        if got == version or got.startswith(version + "."):
            return True
    return False


def seed_hvigor_pnpm(
    user_home: Path,
    cache: Path,
    *,
    npm: str,
    version: str = PNPM_VERSION,
    timeout: int = INSTALL_TIMEOUT_SEC,
) -> str:
    user_home = Path(user_home)
    dest = user_home / "wrapper" / "tools" / version
    if pnpm_ok(user_home, version):
        return "present"
    cache = Path(cache)
    cache_tool = cache / version
    if pnpm_ok(cache, version) or (cache_tool / "node_modules" / ".bin" / "pnpm").is_file() or (
        cache_tool / "node_modules" / "pnpm" / "bin" / "pnpm.cjs"
    ).is_file():
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(cache_tool, dest, symlinks=True)
        _repair_shim(dest)
        if pnpm_ok(user_home, version):
            return "restored-from-cache"
        shutil.rmtree(dest, ignore_errors=True)
    cache_tool.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["npm_config_audit"] = "false"
    env["npm_config_fund"] = "false"
    env["npm_config_update_notifier"] = "false"
    env["npm_config_fetch_timeout"] = "30000"
    env["npm_config_fetch_retries"] = "1"
    env["npm_config_prefer_offline"] = "true"
    pkg = cache_tool / "package.json"
    if not pkg.is_file():
        pkg.write_text('{"dependencies":{"pnpm":"%s"}}\n' % version)
    try:
        subprocess.run(
            [
                npm,
                "install",
                f"pnpm@{version}",
                "--no-audit",
                "--no-fund",
                "--no-update-notifier",
                "--prefer-offline",
            ],
            cwd=str(cache_tool),
            env=env,
            timeout=timeout,
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.TimeoutExpired as exc:
        raise PnpmSeedError(f"pnpm install timed out after {timeout}s") from exc
    except subprocess.CalledProcessError as exc:
        raise PnpmSeedError(f"pnpm install failed: {(exc.stderr or exc.stdout or '')[-400:]}") from exc
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(cache_tool, dest, symlinks=True)
    _repair_shim(dest)
    if not pnpm_ok(user_home, version):
        raise PnpmSeedError("pnpm install did not produce a runnable binary")
    return "installed-bounded"
