"""Build the fine-tuning dataset from the training tasks.

Each task contributes its oracle trajectory (tool outputs come from really running the tools). With --teacher, a bigger
local model also solves training tasks and only its verified, error-free trajectories are kept, which adds variety.

    python make_dataset.py --per-family 150 --out data
    python make_dataset.py --per-family 150 --teacher gemma4:26b --teacher-per-family 40 --out data
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

from runner import run_model, run_oracle, training_record
from tasks import FAMILIES, make_tasks
from data_utils import split_records, validate_dataset, validate_record, trajectory_key


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--per-family", type=int, default=150)
    parser.add_argument("--teacher", help="Modelo de Ollama que resuelve tareas extra (opcional)")
    parser.add_argument("--teacher-per-family", type=int, default=30)
    parser.add_argument("--max-teacher-steps", type=int, default=15)
    parser.add_argument("--valid-fraction", type=float, default=0.05)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--out", default="data")
    args = parser.parse_args(argv)
    if args.per_family < 2 or not 0 < args.valid_fraction < 1:
        parser.error("--per-family debe ser >= 2 y --valid-fraction debe estar entre 0 y 1")

    records, seen, trajectories = [], set(), set()

    def add(record: dict) -> None:
        validate_record(record)
        key = (record["task_key"], record["source"])
        trajectory = trajectory_key(record)
        if key not in seen and trajectory not in trajectories:
            seen.add(key)
            trajectories.add(trajectory)
            records.append(record)

    tasks = make_tasks("train", args.per_family, seed=args.seed)
    for n, task in enumerate(tasks, 1):
        add(run_oracle(task))
        if n % 100 == 0:
            print(f"oracle {n}/{len(tasks)}", flush=True)

    if args.teacher:
        teacher_tasks = make_tasks("train", args.teacher_per_family, seed=args.seed + 1000)
        kept = 0
        for n, task in enumerate(teacher_tasks, 1):
            result = run_model(task, args.teacher)
            clean = (result["ok"] and not result["stats"]["error"] and result["stats"]["steps"] <= args.max_teacher_steps
                     and not any(e["failed"] for e in result["events"] if e["name"] != "run_command"))
            if clean:
                add(training_record(task, result, "teacher"))
                kept += 1
            print(f"teacher {n}/{len(teacher_tasks)} {'✓' if clean else '✗'} {task.id} {result['reason'][:80]} (guardadas {kept})", flush=True)

    parts = split_records(records, args.valid_fraction, args.seed)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for name, part in parts.items():
        with (out / f"{name}.jsonl").open("w", encoding="utf-8") as file:
            for record in part:
                file.write(json.dumps(record, ensure_ascii=False) + "\n")
    counts = Counter((r["family"], r["source"]) for r in records)
    manifest = {"schema_version": 1, "seed": args.seed, "per_family": args.per_family,
                "valid_fraction": args.valid_fraction, "teacher": args.teacher, "splits": validate_dataset(out)}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"\n{len(parts['train'])} ejemplos de entrenamiento y {len(parts['valid'])} de validación en {out}/")
    for family in FAMILIES:
        print(f"  {family:<14} oracle {counts[(family, 'oracle')]:>4}  teacher {counts[(family, 'teacher')]:>4}")


if __name__ == "__main__":
    main(sys.argv[1:])
