"""Фоновый headless-редактор Godot с GDScript LSP для Claude Code (macOS, Linux, Windows).

    python3 tools/lsp.py start GODOT PORT   запустить, если порт ещё не слушается
    python3 tools/lsp.py stop PORT          остановить запущенный этим скриптом редактор
"""

import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PID_FILE = ROOT / "build" / "lsp.pid"
WAIT_SECONDS = 30


def listening(port: int) -> bool:
    try:
        with socket.create_connection(("localhost", port), timeout=1):
            return True
    except OSError:
        return False


def start(godot: str, port: int) -> int:
    if listening(port):
        print(f"LSP уже слушает порт {port}")
        return 0
    args = [godot, "--headless", "--editor", "--path", str(ROOT), "--lsp-port", str(port)]
    options: dict = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL, "stdin": subprocess.DEVNULL}
    if os.name == "nt":
        options["creationflags"] = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        options["start_new_session"] = True
    process = subprocess.Popen(args, **options)
    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(process.pid), encoding="utf-8")
    for _ in range(WAIT_SECONDS):
        if listening(port):
            print(f"LSP запущен на порту {port}")
            return 0
        time.sleep(1)
    print(f"LSP не поднялся за {WAIT_SECONDS} с")
    return 1


def stop(port: int) -> int:
    if not PID_FILE.is_file():
        print("LSP не был запущен" if not listening(port) else "LSP запущен не этим скриптом: закройте редактор Godot")
        return 0
    pid = int(PID_FILE.read_text(encoding="utf-8"))
    PID_FILE.unlink()
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True, check=False)
        else:
            os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    print("LSP остановлен")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[0] == "start":
        return start(argv[1], int(argv[2]))
    if len(argv) == 2 and argv[0] == "stop":
        return stop(int(argv[1]))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
