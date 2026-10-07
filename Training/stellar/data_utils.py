"""Dataset validation and grouping, without GPU dependencies."""
from __future__ import annotations

import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path


def digest(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def task_key(task) -> str:
    # General chat and explicit new-file requests do not observe the incidental project.
    observes_project = task.family != "chat" and not (
        task.family == "create_file" and not any(
            step[0] == "call" and step[1] in {"read_file", "search", "list_files", "edit_file"}
            for step in task.oracle
        )
    )
    return digest([task.family, task.prompt, task.files if observes_project else {}])


def trajectory_key(record: dict) -> str:
    """Ignore IDs, project names and test timing when comparing actual examples."""
    messages = []
    for message in record["messages"][1:]:
        item = {k: v for k, v in message.items() if k != "tool_call_id"}
        if item.get("tool_calls"):
            item["tool_calls"] = [{k: v for k, v in call.items() if k != "id"} for call in item["tool_calls"]]
        messages.append(item)
    text = json.dumps(messages, sort_keys=True, ensure_ascii=False)
    text = re.sub(r'/Users/usuario/Projects/[^/\s"\x27]+', '<PROJECT>', text)
    text = re.sub(r'Ran (\d+) tests? in [0-9.]+s', r'Ran \1 tests in TIME', text)
    return hashlib.sha256(text.encode()).hexdigest()


def validate_record(record: dict) -> None:
    messages = record["messages"]
    assert messages[0]["role"] == "system", "Falta system"
    assert messages[1]["role"] == "user", "Falta user"
    assert messages[-1]["role"] == "assistant" and messages[-1]["content"].strip(), "Falta respuesta final"
    specs = {t["function"]["name"]: t["function"]["parameters"] for t in record["tools"]}
    pending, seen_ids = {}, set()
    for message in messages:
        assert message["role"] in {"system", "user", "assistant", "tool"}
        assert isinstance(message["content"], str)
        if message["role"] != "tool":
            assert not pending, "Falta resultado de una llamada"
        if message.get("tool_calls"):
            assert message["role"] == "assistant"
            for call in message["tool_calls"]:
                name, args = call["function"]["name"], call["function"]["arguments"]
                assert name in specs and isinstance(args, dict), "Llamada inválida"
                assert all(k in args for k in specs[name]["required"]), "Falta argumento"
                for key, value in args.items():
                    assert key in specs[name]["properties"], f"Argumento desconocido: {key}"
                    kind = specs[name]["properties"][key]["type"]
                    assert isinstance(value, str) if kind == "string" else type(value) is int
                assert call["id"] not in seen_ids, "ID de llamada repetido"
                seen_ids.add(call["id"])
                pending[call["id"]] = name
        if message["role"] == "tool":
            assert pending.pop(message["tool_call_id"]) == message["name"], "Resultado mal enlazado"
    assert not pending


def split_records(records: list[dict], fraction: float, seed: int) -> dict[str, list[dict]]:
    """Stratify by family and keep all trajectories of the same task in one split."""
    import random
    by_family = defaultdict(lambda: defaultdict(list))
    for record in records:
        by_family[record["family"]][record["task_key"]].append(record)
    parts = {"train": [], "valid": []}
    for family, groups in sorted(by_family.items()):
        keys = sorted(groups)
        if len(keys) < 2:
            raise ValueError(f"{family}: hacen falta al menos dos tareas distintas; aumenta --per-family")
        random.Random(f"{seed}-{family}").shuffle(keys)
        cut = min(len(keys) - 1, max(1, round(len(keys) * fraction)))
        for i, key in enumerate(keys):
            parts["valid" if i < cut else "train"].extend(groups[key])
    for name, rows in parts.items():
        random.Random(f"{seed}-{name}").shuffle(rows)
    return parts


def load_records(path: str | Path) -> list[dict]:
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]


def validate_dataset(directory: str | Path) -> dict:
    directory = Path(directory)
    parts = {name: load_records(directory / f"{name}.jsonl") for name in ("train", "valid")}
    keys = {}
    trajectories = {}
    summary = {}
    for name, records in parts.items():
        assert records, f"{name} vacío"
        for record in records:
            validate_record(record)
        keys[name] = {r["task_key"] for r in records}
        trajectories[name] = {trajectory_key(r) for r in records}
        assert len(trajectories[name]) == len(records), f"Trayectorias equivalentes repetidas en {name}"
        pairs = [(r["task_key"], r["source"]) for r in records]
        assert len(set(pairs)) == len(pairs), f"Duplicados en {name}"
        summary[name] = {"records": len(records), "tasks": len(keys[name]),
                         "families": dict(Counter(r["family"] for r in records)),
                         "languages": dict(Counter(r["lang"] for r in records)),
                         "sources": dict(Counter(r["source"] for r in records)),
                         "sha256": hashlib.sha256((directory / f"{name}.jsonl").read_bytes()).hexdigest()}
    assert not keys["train"] & keys["valid"], "Hay tareas compartidas entre train y valid"
    assert not trajectories["train"] & trajectories["valid"], "Hay ejemplos equivalentes en train y valid"
    return summary


if __name__ == "__main__":
    import sys
    print(json.dumps(validate_dataset(sys.argv[1] if len(sys.argv) > 1 else "data"), indent=2, ensure_ascii=False))
