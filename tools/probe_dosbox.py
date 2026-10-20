"""Boot a disposable DOSBox-X guest and verify a fresh guest-written marker.

Run with the toolbox Python:
  python -X utf8 tools/probe_dosbox.py --executable <portable dosbox-x.exe>
No game files are mounted. Debugger availability requires separate verification.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import time

from child_window_placement import monitor_work_area, move_child_windows
import uuid


def verify_marker(returncode: int, expected: str, actual: str | None) -> None:
    if returncode != 0:
        raise RuntimeError(f"DOSBox-X exited with {returncode}")
    if actual is None:
        raise RuntimeError("DOSBox-X did not create the guest marker")
    if actual.strip() != expected:
        raise RuntimeError("DOSBox-X guest marker did not match this invocation")


def probe(executable: Path, timeout: int = 45, window_monitor_device: str = "") -> dict:
    executable = executable.resolve(strict=True)
    if not executable.is_file():
        raise ValueError("executable must be an existing file")
    work_area = monitor_work_area(window_monitor_device) if window_monitor_device else None
    window_moves = 0
    logs = Path(__file__).resolve().parents[1] / "logs"
    logs.mkdir(exist_ok=True)
    work = logs / ("dosbox-boot-" + uuid.uuid4().hex)
    work.mkdir()
    nonce = "TOOLBOX_DOSBOX_" + uuid.uuid4().hex.upper()
    config = work / "smoke.conf"
    config.write_text(
        "[sdl]\nfullscreen=false\noutput=surface\n"
        "[mixer]\nnosound=true\n"
        "[autoexec]\nmount c .\nc:\n"
        f"echo {nonce} > SMOKE.TXT\n"
        "help DEBUGBOX > DEBUGGER.TXT\nexit\n",
        encoding="ascii",
    )
    env = os.environ.copy()
    env["SDL_VIDEODRIVER"] = "dummy"
    env["SDL_AUDIODRIVER"] = "dummy"
    startup = None
    flags = 0
    if os.name == "nt":
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = subprocess.SW_HIDE
        flags = subprocess.CREATE_NO_WINDOW
    output = work / "process.log"
    with output.open("wb") as stream:
        process = subprocess.Popen(
            [str(executable), "-conf", str(config)],
            cwd=work, env=env, stdin=subprocess.DEVNULL,
            stdout=stream, stderr=subprocess.STDOUT,
            startupinfo=startup, creationflags=flags,
        )
        try:
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError(
                        f"DOSBox-X did not exit within {timeout}s; evidence: {work}"
                    )
                if work_area is not None:
                    window_moves += move_child_windows(process, work_area)
                try:
                    process.wait(timeout=min(0.2, remaining))
                except subprocess.TimeoutExpired:
                    pass
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
    returncode = process.returncode
    marker = work / "SMOKE.TXT"
    actual = marker.read_text(encoding="ascii") if marker.is_file() else None
    try:
        verify_marker(returncode, nonce, actual)
    except RuntimeError as exc:
        raise RuntimeError(f"{exc}; evidence: {work}") from exc
    help_file = work / "DEBUGGER.TXT"
    return {
        "nonce_verified": True,
        "exit_code": returncode,
        "window_monitor_device": window_monitor_device or None,
        "window_placements": window_moves,
        "work": str(work),
        "process_log": str(output),
        "debugger_shell_help": str(help_file) if help_file.is_file() else None,
        "debugger_capability": "unverified",
        "protected_mode_capture": "unverified",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--timeout", type=int, default=45, choices=range(5, 121))
    parser.add_argument("--window-monitor-device", default="", help="Optional explicit Windows display device; hidden state is preserved")
    args = parser.parse_args()
    print(json.dumps(probe(args.executable, args.timeout, args.window_monitor_device)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
