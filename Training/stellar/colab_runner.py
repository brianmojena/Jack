"""Stream subprocess output in Colab and retain the underlying error in Drive."""
from __future__ import annotations

from collections import deque
import datetime
import os
from pathlib import Path
import subprocess


def run_logged(command: list[str], *, cwd: Path, log_path: Path, tail_lines: int = 60):
    log_path = Path(log_path)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    tail = deque(maxlen=tail_lines)
    print(f"Registro de esta ejecución: {log_path}", flush=True)
    environment = {**os.environ, "PYTHONUNBUFFERED": "1"}
    with log_path.open("a", encoding="utf-8") as log:
        log.write(f"\n--- Ejecución {datetime.datetime.now(datetime.timezone.utc).isoformat()} ---\n")
        log.flush()
        with subprocess.Popen(command, cwd=cwd, env=environment, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace",
                              bufsize=1) as process:
            try:
                for line in process.stdout:
                    print(line, end="", flush=True)
                    log.write(line)
                    log.flush()
                    tail.append(line)
                status = process.wait()
            except BaseException:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                raise
        log.write(f"\nCódigo de salida: {status}\n")
    if status:
        raise RuntimeError(
            f"El proceso terminó con código {status}. Registro completo: {log_path}\n"
            f"Últimas {tail_lines} líneas del proceso:\n{''.join(tail)}"
        )
    return subprocess.CompletedProcess(command, status)
