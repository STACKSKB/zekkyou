"""Qualify a bundled release under a temporary systemd user unit.

Usage: python3 scripts/systemd_smoke.py RELEASE_DIR

The unit is transient and all application state is temporary.  This requires a
running systemd user manager; no unit is installed or enabled.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


def run(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True, timeout=20)


def show(unit, prop):
    result = run("systemctl", "--user", "show", unit, f"-p{prop}")
    prefix = f"{prop}="
    value = result.stdout.strip()
    assert value.startswith(prefix), value
    return value[len(prefix) :]


def wait_for_socket(path, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            try:
                with socket.socket(socket.AF_UNIX) as probe:
                    probe.settimeout(0.2)
                    probe.connect(str(path))
                    if probe.recv(4096):
                        return
            except (ConnectionRefusedError, OSError, socket.timeout):
                pass
        time.sleep(0.05)
    raise AssertionError(f"service socket did not become ready: {path}")


def command(executable, socket_path, environment, *args):
    result = subprocess.run(
        [executable, *args, "--socket", str(socket_path)],
        capture_output=True,
        text=True,
        timeout=15,
        env=environment,
    )
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    assert rows, result.stdout
    return rows[-1]


def wait_task(executable, socket_path, environment, task_id, status, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        task = command(executable, socket_path, environment, "task", task_id)["task"]
        if task["status"] == status:
            return task
        time.sleep(0.1)
    raise AssertionError(f"{task_id} did not become {status}: {task}")


def main(release_dir):
    release = Path(release_dir).resolve(strict=True)
    executable = release / "bin/zekkyou-cli"
    config = release / "examples/inspect.exs"
    assert executable.is_file(), executable
    assert config.is_file(), config
    assert shutil.which("systemd-run"), "systemd-run is required"

    unit = f"zekkyou-smoke-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    with tempfile.TemporaryDirectory(prefix="zekkyou-systemd-") as temporary:
        base = Path(temporary)
        workspace = base / "workspace"
        workspace.mkdir()
        (workspace / "verified.txt").write_text("systemd input\n")
        state = base / "state"
        socket_path = state / "service.sock"
        environment = {
            "HOME": os.environ.get("HOME", str(Path.home())),
            "ZEKKYOU_WORKSPACE": str(workspace),
            "ZEKKYOU_STATE_DIR": str(state),
            "ERL_FLAGS": "+S 2:2",
        }
        started = False
        try:
            args = [
                "systemd-run",
                "--user",
                f"--unit={unit}",
                "--property=Type=simple",
                "--property=Restart=on-failure",
                "--property=RestartSec=1",
                "--property=KillMode=control-group",
                "--property=TimeoutStopSec=10",
                "--property=UMask=0077",
            ]
            args.extend(f"--setenv={key}={value}" for key, value in environment.items())
            args.extend([str(executable), "serve", str(config)])
            started = True
            run(*args)
            wait_for_socket(socket_path)
            queued = command(executable, socket_path, environment, "schedule", "inspect", '{"path":"."}',
                             "--id", "systemd-restart", "--delay-ms", "10000")
            assert queued["status"] == "queued", queued
            before_pid = int(show(unit, "MainPID"))
            run("systemctl", "--user", "kill", "--kill-who=main", "--signal=SIGKILL", unit)

            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if int(show(unit, "NRestarts")) > 0:
                    after_pid = int(show(unit, "MainPID"))
                    if after_pid and after_pid != before_pid:
                        break
                time.sleep(0.2)
            else:
                raise AssertionError(
                    f"systemd did not restart main process: pid={before_pid}, "
                    f"restarts={show(unit, 'NRestarts')}"
                )

            wait_for_socket(socket_path)
            completed = wait_task(executable, socket_path, environment, "systemd-restart", "completed")
            assert completed["session_id"], completed
            history = command(executable, socket_path, environment, "history", completed["session_id"])
            assert history["events"], history

            run("systemctl", "--user", "restart", unit)
            wait_for_socket(socket_path)
            restarted_history = command(
                executable, socket_path, environment, "history", completed["session_id"]
            )
            assert restarted_history["events"] == history["events"], (
                history,
                restarted_history,
            )
            recovered = command(
                executable, socket_path, environment, "task", "systemd-restart"
            )["task"]
            assert recovered["status"] == "completed", recovered
            assert recovered["session_id"] == completed["session_id"], recovered

        finally:
            qualification_failed = sys.exc_info()[0] is not None
            cleanup_errors = []
            if started:
                run("systemctl", "--user", "stop", unit, check=False)
                run("systemctl", "--user", "reset-failed", unit, check=False)
                deadline = time.monotonic() + 10
                stopped = False
                while time.monotonic() < deadline:
                    state = run(
                        "systemctl", "--user", "show", unit, "-pActiveState", check=False
                    )
                    if state.returncode or state.stdout.strip() in (
                        "ActiveState=inactive",
                        "ActiveState=failed",
                    ):
                        stopped = True
                        break
                    time.sleep(0.1)
                if not stopped:
                    cleanup_errors.append(f"unit did not stop: {unit}")
                deadline = time.monotonic() + 5
                while socket_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.1)
            if socket_path.exists():
                cleanup_errors.append(f"socket survived unit stop: {socket_path}")
            if cleanup_errors and not qualification_failed:
                raise AssertionError("; ".join(cleanup_errors))

    print("PASS: transient systemd startup, restart, durable task/history, and cleanup")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: systemd_smoke.py RELEASE_DIR")
    main(sys.argv[1])
