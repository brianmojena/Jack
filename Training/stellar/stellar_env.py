"""Legacy offline training environment for Stellar Code (Sources/JackCore/StellarCode.swift).

This environment keeps the oracle/trajectory format used by the training pipeline. It does not implement the newer
Normal-mode prompt, scoped AGENTS.md delivery, context budgeting, or Normal-only recursive listing contract; benchmark
results here must not be presented as a measurement of those Jack app behaviors.
"""
from __future__ import annotations

import datetime
import json
import os
import shutil
import signal
import subprocess
import time
import urllib.request
import uuid
from pathlib import Path

MAX_STEPS = 40
CONTEXT_LENGTH = 16_384
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
# An edit of the same size within the same second would otherwise run a stale .pyc.
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
SKIPPED = {".git", "node_modules", ".build", "build", "DerivedData", ".venv", "venv", "__pycache__", "dist", ".next", "Pods"}


def _string(description: str) -> dict:
    return {"type": "string", "description": description}


def _object(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required}


_SPECS = [
    ("list_files", "List files and folders under a directory of the project (recursive, skips build and dependency folders).",
     _object({"path": _string("Directory, relative to the project root. Defaults to the root.")}, [])),
    ("read_file", "Read a text file. Returns numbered lines. Use offset and limit for long files.",
     _object({"path": _string("File path, relative to the project root."),
              "offset": {"type": "integer", "description": "First line to read, starting at 1."},
              "limit": {"type": "integer", "description": "Maximum number of lines (default 400)."}}, ["path"])),
    ("search", "Search file contents with a regular expression. Returns matching lines as path:line:text.",
     _object({"pattern": _string("Regular expression to search for."),
              "path": _string("Directory or file to search in, relative to the project root.")}, ["pattern"])),
    ("write_file", "Create a file or replace its whole content.",
     _object({"path": _string("File path, relative to the project root."), "content": _string("The complete new content.")}, ["path", "content"])),
    ("edit_file", "Replace one exact, unique occurrence of old_string with new_string in a file. Read the file first.",
     _object({"path": _string("File path, relative to the project root."), "old_string": _string("Exact text to replace, unique in the file."),
              "new_string": _string("Replacement text.")}, ["path", "old_string", "new_string"])),
    ("run_command", "Run a shell command (zsh) in the project root and return its output. Times out after 2 minutes.",
     _object({"command": _string("The command to run.")}, ["command"])),
]
TOOLS = [{"type": "function", "function": {"name": n, "description": d, "parameters": p}} for n, d, p in _SPECS]
TOOL_NAMES = [n for n, _, _ in _SPECS]

_WEEKDAYS = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]
_MONTHS = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]


def _date(day: datetime.date) -> str:
    # Swift's `.formatted(date: .complete, time: .omitted)` with a Spanish locale.
    return f"{_WEEKDAYS[day.weekday()]}, {day.day} de {_MONTHS[day.month - 1]} de {day.year}"


def system_prompt(root: str, tools: bool = True, day: datetime.date | None = None) -> str:
    body = ("You can inspect and change the project with tools. Work step by step:\n"
            "- Explore with list_files, search and read_file before changing anything; never guess file contents.\n"
            "- Change files with edit_file (exact, unique old_string) or write_file for new files.\n"
            "- Use run_command to build, test or inspect; prefer short, non-interactive commands.\n"
            "- Call tools directly instead of describing what you would do. When the task is done, stop calling tools and reply."
            if tools else "You cannot use tools with this model: answer from the conversation and ask the user for any file you need.")
    return ("You are Stellar Code, the coding agent built into Jack, a macOS app for coding agents. You run on a local model on the user's Mac.\n"
            f"Working directory (project root): {root}\n"
            f"Date: {_date(day or datetime.date.today())}. Platform: macOS.\n"
            f"{body}\n"
            "Reply in the user's language, briefly and concretely. Use Markdown for code.")


# MARK: - Tools

def resolve(path: str, root: str) -> str:
    expanded = os.path.expanduser(path.strip())
    return os.path.normpath(expanded if expanded.startswith("/") else os.path.join(root, expanded))


def _relative(text: str, root: str) -> str:
    bases = sorted({os.path.realpath(root), root}, key=len, reverse=True)
    for base in bases:
        text = text.replace(base if base.endswith("/") else base + "/", "")
    return text


def _int(value) -> int | None:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return None


def _run(argv: list[str], root: str, timeout: float) -> tuple[str, int]:
    process = subprocess.Popen(argv, cwd=root, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        data, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        data, _ = process.communicate()
    status = process.returncode
    return data[:2_000_000].decode("utf-8", "replace"), (-status if status < 0 else status)


def _list(base: str, root: str) -> str:
    if not os.path.isdir(base):
        raise FileNotFoundError(f"No existe la carpeta {base}.")
    lines: list[str] = []

    def walk(directory: str, level: int) -> bool:
        for name in sorted(os.listdir(directory)):
            if name.startswith("."):
                continue
            full = os.path.join(directory, name)
            is_dir = os.path.isdir(full)
            if (is_dir and name in SKIPPED) or level > 4:
                continue
            lines.append(_relative(full, root) + ("/" if is_dir else ""))
            if len(lines) >= 400:
                lines.append("… (más de 400 entradas; lista una subcarpeta)")
                return False
            if is_dir and not walk(full, level + 1):
                return False
        return True

    walk(base, 1)
    return "\n".join(lines) if lines else "(vacía)"


def execute(name: str, args: dict, root: str) -> tuple[str, bool]:
    """Runs a tool; returns its output and whether it failed, as StellarTools.execute does."""
    def path(key: str = "path") -> str | None:
        value = args.get(key)
        return resolve(value, root) if isinstance(value, str) else None

    try:
        if name == "list_files":
            return _list(path() or root, root), False
        if name == "read_file":
            file = path()
            if not file:
                return "Falta el parámetro path.", True
            lines = _read(file).split("\n")
            start = max(1, _int(args.get("offset")) or 1)
            limit = max(1, min(2000, _int(args.get("limit")) or 400))
            if start > len(lines):
                return f"El archivo tiene {len(lines)} líneas.", False
            end = min(len(lines), start + limit - 1)
            output = "\n".join(f"{n}\t{lines[n - 1][:2000]}" for n in range(start, end + 1))
            if end < len(lines):
                output += f"\n… ({len(lines) - end} more lines; use offset {end + 1})"
            return output, False
        if name == "search":
            pattern = args.get("pattern")
            if not isinstance(pattern, str) or not pattern:
                return "Falta el parámetro pattern.", True
            target = path() or root
            rg = shutil.which("rg")
            argv = ([rg, "--line-number", "--no-heading", "--color", "never", "--max-count", "50", "-e", pattern, target] if rg else
                    ["grep", "-rnI", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=.build", "--exclude-dir=build", "-E", pattern, target])
            output, status = _run(argv, root, 30)
            if status == 1 and not output:
                return "Sin coincidencias.", False
            return _relative(output[:20_000], root), status > 1
        if name == "write_file":
            file, content = path(), args.get("content")
            if not file or not isinstance(content, str):
                return "Faltan path o content.", True
            os.makedirs(os.path.dirname(file), exist_ok=True)
            existed = os.path.exists(file)
            Path(file).write_text(content, encoding="utf-8")
            return f"{'Reemplazado' if existed else 'Creado'}: {file} ({len(content.split(chr(10)))} líneas)", False
        if name == "edit_file":
            file, old, new = path(), args.get("old_string"), args.get("new_string")
            if not file or not isinstance(old, str) or not isinstance(new, str) or not old:
                return "Faltan path, old_string o new_string.", True
            text = _read(file)
            count = text.count(old)
            if count != 1:
                return ("old_string no aparece en el archivo. Léelo de nuevo y copia el texto exacto." if count == 0
                        else f"old_string aparece {count} veces; incluye más contexto para que sea única."), True
            Path(file).write_text(text.replace(old, new), encoding="utf-8")
            return f"Editado: {file}", False
        if name == "run_command":
            command = args.get("command")
            if not isinstance(command, str) or not command:
                return "Falta el parámetro command.", True
            shell = shutil.which("zsh") or "/bin/bash"
            output, status = _run([shell, "-lc", command], root, 120)
            if len(output) > 30_000:
                output = output[:15_000] + "\n… (salida recortada) …\n" + output[-15_000:]
            return output + ("" if status == 0 else f"\n[exit {status}]"), status != 0
        return f"Herramienta desconocida: {name}. Usa: {', '.join(TOOL_NAMES)}.", True
    except Exception as error:  # Swift returns error.localizedDescription
        return str(error), True


def _read(file: str) -> str:
    if not os.path.isfile(file):
        raise FileNotFoundError(f"The file “{os.path.basename(file)}” couldn’t be opened because there is no such file.")
    return Path(file).read_text(encoding="utf-8")


# MARK: - Model client and loop

def _ollama_message(message: dict) -> dict:
    value = {"role": message["role"], "content": message.get("content", "")}
    if message.get("tool_calls"):
        value["tool_calls"] = [{"function": {"name": c["name"], "arguments": c["arguments"]}} for c in message["tool_calls"]]
    if message.get("tool_name"):
        value["tool_name"] = message["tool_name"]
    return value


def chat(model: str, messages: list[dict], tools: list | None = TOOLS, options: dict | None = None, timeout: float = 600) -> dict:
    body = {"model": model, "stream": False, "messages": [_ollama_message(m) for m in messages],
            "options": {"num_ctx": CONTEXT_LENGTH, **(options or {})}}
    if tools:
        body["tools"] = tools
    request = urllib.request.Request(OLLAMA_URL + "/api/chat", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


def _arguments(raw) -> dict:
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            value = json.loads(raw)
            return value if isinstance(value, dict) else {}
        except json.JSONDecodeError:
            return {}
    return {}


def run_agent(model: str, prompt: str, root: str, options: dict | None = None, max_steps: int = MAX_STEPS) -> dict:
    """One Stellar Code turn in auto mode. Returns the transcript (without the system message) and stats."""
    system = {"role": "system", "content": system_prompt(root)}
    history: list[dict] = [{"role": "user", "content": prompt}]
    events: list[dict] = []
    stats = {"steps": 0, "hit_limit": False, "prompt_tokens": 0, "output_tokens": 0, "thinking_chars": 0, "error": None}
    started = time.time()
    for step in range(max_steps):
        stats["steps"] = step + 1
        try:
            response = chat(model, [system] + history, options=options)
        except Exception as error:
            stats["error"] = f"{type(error).__name__}: {error}"
            break
        message = response.get("message", {})
        stats["prompt_tokens"] += response.get("prompt_eval_count", 0)
        stats["output_tokens"] += response.get("eval_count", 0)
        stats["thinking_chars"] += len(message.get("thinking") or "")
        calls = [{"id": call.get("id") or "call_" + uuid.uuid4().hex[:8], "name": call.get("function", {}).get("name", ""),
                  "arguments": _arguments(call.get("function", {}).get("arguments"))}
                 for call in message.get("tool_calls") or []]
        history.append({"role": "assistant", "content": message.get("content", ""), **({"tool_calls": calls} if calls else {})})
        if not calls:
            break
        for call in calls:
            output, failed = execute(call["name"], call["arguments"], root)
            events.append({"name": call["name"], "arguments": call["arguments"], "failed": failed, "output": output[:2000]})
            history.append({"role": "tool", "content": output[:24_000], "tool_call_id": call["id"], "tool_name": call["name"]})
        if step == max_steps - 1:
            stats["hit_limit"] = True
    stats["seconds"] = round(time.time() - started, 1)
    final = next((m["content"] for m in reversed(history) if m["role"] == "assistant" and not m.get("tool_calls")), "")
    return {"messages": history, "events": events, "final": final, "stats": stats}


def to_training_record(root: str, messages: list[dict], day: datetime.date | None = None) -> dict:
    """A transcript in Hugging Face chat format, ready for `apply_chat_template(messages, tools=tools)`."""
    out = [{"role": "system", "content": system_prompt(root, day=day)}]
    for message in messages:
        if message["role"] == "assistant":
            entry = {"role": "assistant", "content": message.get("content", "")}
            if message.get("tool_calls"):
                entry["tool_calls"] = [{"id": c["id"], "type": "function", "function": {"name": c["name"], "arguments": c["arguments"]}}
                                       for c in message["tool_calls"]]
            out.append(entry)
        elif message["role"] == "tool":
            out.append({"role": "tool", "tool_call_id": message["tool_call_id"], "name": message["tool_name"], "content": message["content"]})
        else:
            out.append({"role": message["role"], "content": message["content"]})
    # The real executions happen in /tmp; train on varied macOS project paths instead.
    canonical_root = "/Users/usuario/Projects/" + Path(root).name
    def normalize(value):
        if isinstance(value, str):
            return value.replace(os.path.realpath(root), canonical_root).replace(root, canonical_root)
        if isinstance(value, list):
            return [normalize(v) for v in value]
        if isinstance(value, dict):
            return {k: normalize(v) for k, v in value.items()}
        return value
    return {"messages": normalize(out), "tools": TOOLS}
