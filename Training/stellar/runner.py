"""Runs a task with a model (benchmark, teacher) or with its oracle (training data), in a throwaway project folder."""
from __future__ import annotations

import datetime
import random
import shutil
import tempfile
from pathlib import Path

import stellar_env
from tasks import PROJECTS, Task
from data_utils import task_key


def _workspace(task: Task) -> tuple[str, str]:
    base = tempfile.mkdtemp(prefix="stellar-")
    root = str(Path(base, random.Random(task.id).choice(PROJECTS)))
    Path(root).mkdir()
    task.materialize(root)
    return base, root


def run_model(task: Task, model: str, options: dict | None = None, keep: bool = False) -> dict:
    base, root = _workspace(task)
    try:
        result = stellar_env.run_agent(model, task.prompt, root, options=options)
        try:
            ok, reason = task.check(root, result)
        except Exception as error:
            ok, reason = False, f"check: {type(error).__name__}: {error}"
        result.update(ok=ok, reason=reason, root=root)
        return result
    finally:
        if not keep:
            shutil.rmtree(base, ignore_errors=True)


def run_oracle(task: Task) -> dict:
    """Plays the oracle's steps through the real tools, so tool outputs in the data are exactly what Stellar returns."""
    base, root = _workspace(task)
    try:
        messages: list[dict] = [{"role": "user", "content": task.prompt}]
        events: list[dict] = []
        for step in task.oracle:
            if step[0] == "reply":
                messages.append({"role": "assistant", "content": step[1]})
                continue
            _, name, args = step
            call_id = f"call_{len(events):04d}"
            messages.append({"role": "assistant", "content": "", "tool_calls": [{"id": call_id, "name": name, "arguments": args}]})
            output, failed = stellar_env.execute(name, args, root)
            events.append({"name": name, "arguments": args, "failed": failed, "output": output})
            messages.append({"role": "tool", "content": output[:24_000], "tool_call_id": call_id, "tool_name": name})
        result = {"messages": messages, "events": events, "final": messages[-1]["content"]}
        ok, reason = task.check(root, result)
        if not ok or any(e["failed"] for e in events if e["name"] != "run_command"):
            raise AssertionError(f"oracle de {task.id} falla: {reason} {[e for e in events if e['failed']]}")
        day = datetime.date(2026, 1, 1) + datetime.timedelta(days=random.Random(task.id).randint(0, 364))
        return {"family": task.family, "lang": task.lang, "source": "oracle", "task_key": task_key(task),
                **stellar_env.to_training_record(root, messages, day)}
    finally:
        shutil.rmtree(base, ignore_errors=True)


def training_record(task: Task, result: dict, source: str) -> dict:
    return {"family": task.family, "lang": task.lang, "source": source, "task_key": task_key(task),
            **stellar_env.to_training_record(result["root"], result["messages"])}
