"""Run after mix escript.build: real files and replay across independent VMs."""

import json
import os
import signal
import socket
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXECUTABLE = str(ROOT / "zekkyou")


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
    process.communicate(timeout=10)


def launch(environment, socket_path):
    process = subprocess.Popen(
        [EXECUTABLE, "serve", str(ROOT / "examples/inspect.exs")],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    deadline = time.monotonic() + 15
    try:
        while True:
            if process.poll() is not None:
                raise RuntimeError(process.communicate())
            try:
                # A socket file alone can be left over from the previous VM.
                with socket.socket(socket.AF_UNIX) as probe:
                    probe.settimeout(0.2)
                    probe.connect(socket_path)
                    if probe.recv(4096):
                        return process
            except (FileNotFoundError, ConnectionRefusedError, socket.timeout):
                pass
            if time.monotonic() > deadline:
                raise RuntimeError("Service did not become ready")
            time.sleep(0.025)
    except BaseException:
        stop(process)
        raise


def command(environment, socket_path, *arguments):
    result = subprocess.run(
        [EXECUTABLE, *arguments, "--socket", socket_path],
        env=environment,
        capture_output=True,
        text=True,
        timeout=15,
    )
    if result.returncode:
        raise RuntimeError(result.stderr)
    return [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]


def main():
    with zipfile.ZipFile(EXECUTABLE) as artifact:
        assert not any("ex_ratatui" in name for name in artifact.namelist())

    with tempfile.TemporaryDirectory(prefix="zekkyou-executable-") as temporary:
        base = Path(temporary)
        workspace = base / "workspace"
        workspace.mkdir()
        (workspace / "verified.txt").write_text("actual workspace input\n")
        state = base / "state"
        socket_path = str(state / "service.sock")
        environment = os.environ.copy()
        environment.update(
            ZEKKYOU_WORKSPACE=str(workspace),
            ZEKKYOU_STATE_DIR=str(state),
            ERL_FLAGS="+S 2:2",
        )

        process = launch(environment, socket_path)
        try:
            started = command(environment, socket_path, "start", "inspect", '{"path":"."}')[-1]
            events = command(environment, socket_path, "watch", started["run_id"])
            result = next(row for row in events if row.get("type") == "result")
            assert result["outcome"] == "ok", result
            assert any(
                entry["name"] == "verified.txt"
                for output in result["output"]
                for entry in output["entries"]
            ), result
            history = command(environment, socket_path, "history", started["session_id"])[-1]
            assert any(
                event["event"] == "tool_completed"
                and event["data"]["value"]["entries"][0]["name"] == "verified.txt"
                for event in history["events"]
            ), history
        finally:
            stop(process)

        process = launch(environment, socket_path)
        try:
            replay = command(environment, socket_path, "history", started["session_id"])[-1]
            assert replay["events"] == history["events"]
            status = command(environment, socket_path, "status")[-1]
            assert any(session["id"] == started["session_id"] for session in status["sessions"])
        finally:
            stop(process)

    print("PASS: real workspace execution, reconnect, fresh-VM replay, no native TUI dependency")


if __name__ == "__main__":
    main()
