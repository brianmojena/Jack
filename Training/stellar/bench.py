"""Benchmark a local model as Stellar Code on the held-out tasks, and compare runs.

    python bench.py run --model gemma4:e2b --out runs/base
    python bench.py run --model stellar-gemma:e2b --out runs/finetuned
    python bench.py compare runs/base runs/finetuned
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import hashlib
from collections import defaultdict
from pathlib import Path

from runner import run_model
from tasks import FAMILIES, make_tasks

ACTION_FAMILIES = {"fix_bug", "add_function", "create_file", "rename"}
BAD_CALL_PREFIXES = ("Falta", "Herramienta desconocida")


def summarize(rows: list[dict]) -> dict:
    def block(items: list[dict]) -> dict:
        events = [e for r in items for e in r["events"]]
        return {
            "tasks": len(items),
            "success": round(sum(r["ok"] for r in items) / max(1, len(items)), 3),
            "avg_steps": round(sum(r["stats"]["steps"] for r in items) / max(1, len(items)), 1),
            "avg_seconds": round(sum(r["stats"]["seconds"] for r in items) / max(1, len(items)), 1),
            "tool_calls": len(events),
            "tool_error_rate": round(sum(e["failed"] for e in events if e["name"] != "run_command") / max(1, len(events)), 3),
            "malformed_calls": sum(e["output"].startswith(BAD_CALL_PREFIXES) for e in events),
            "no_action": sum(1 for r in items if r["family"] in ACTION_FAMILIES and not r["events"]),
            "hit_limit": sum(r["stats"]["hit_limit"] for r in items),
            "errors": sum(bool(r["stats"]["error"]) for r in items),
        }
    by_family = defaultdict(list)
    for row in rows:
        by_family[row["family"]].append(row)
    return {"overall": block(rows), "families": {f: block(by_family[f]) for f in FAMILIES if by_family[f]}}


def run(args) -> None:
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    tasks = make_tasks("eval", args.per_family, seed=args.seed, families=args.families)
    options = json.loads(args.options) if args.options else None
    if options is not None and not isinstance(options, dict):
        raise ValueError("--options debe ser un objeto JSON")
    config = {"model": args.model, "options": options, "per_family": args.per_family, "repeat": args.repeat,
              "seed": args.seed, "families": args.families or FAMILIES,
              "tasks_sha256": hashlib.sha256(Path(__file__).with_name("tasks.py").read_bytes()).hexdigest()}
    config_path = out / "run_config.json"
    done = {}
    results_path = out / "results.jsonl"
    if results_path.exists():
        if not args.resume:
            raise ValueError("La carpeta ya tiene resultados; usa --resume o una carpeta nueva")
        if not config_path.exists() or json.loads(config_path.read_text()) != config:
            raise ValueError("No se pueden mezclar modelos, opciones o tareas al reanudar")
    config_path.write_text(json.dumps(config, indent=2, ensure_ascii=False))
    if results_path.exists() and args.resume:
        done = {json.loads(line)["id"]: json.loads(line) for line in results_path.open()}
    rows = list(done.values())
    with results_path.open("a" if args.resume else "w") as file:
        for n, task in enumerate(tasks, 1):
            for attempt in range(args.repeat):
                key = f"{task.id}#{attempt}"
                if key in done:
                    continue
                started = time.time()
                result = run_model(task, args.model, options=options)
                row = {"id": key, "family": task.family, "lang": task.lang, "prompt": task.prompt, "ok": result["ok"], "reason": result["reason"],
                       "stats": result["stats"], "events": result["events"], "final": result["final"], "messages": result["messages"]}
                rows.append(row)
                file.write(json.dumps(row, ensure_ascii=False) + "\n")
                file.flush()
                mark = "✓" if row["ok"] else "✗"
                print(f"[{n}/{len(tasks)}] {mark} {key:<28} {time.time() - started:5.1f}s  {row['reason'][:90]}", flush=True)
    summary = {"model": args.model, "options": options, "evaluation": {k: v for k, v in config.items() if k not in {"model", "options"}},
               **summarize(rows)}
    (out / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print_summary(summary)


def print_summary(summary: dict) -> None:
    o = summary["overall"]
    print(f"\n{summary['model']}: {o['success']:.0%} de {o['tasks']} tareas · {o['avg_steps']} pasos · {o['avg_seconds']}s por tarea · "
          f"errores de herramienta {o['tool_error_rate']:.0%} · llamadas mal formadas {o['malformed_calls']} · sin actuar {o['no_action']} · "
          f"límite de pasos {o['hit_limit']} · fallos del servidor {o['errors']}")
    for family, block in summary["families"].items():
        print(f"  {family:<14} {block['success']:>5.0%}  ({block['tasks']} tareas, {block['avg_steps']} pasos)")


def compare(args) -> None:
    summaries = [json.loads(Path(p, "summary.json").read_text()) for p in args.runs]
    if any(s.get("evaluation") != summaries[0].get("evaluation") or s["options"] != summaries[0]["options"] for s in summaries):
        raise ValueError("La comparación requiere las mismas tareas, semilla, repeticiones y opciones")
    names = [s["model"] for s in summaries]
    width = max(14, *(len(n) for n in names)) + 2
    print("".ljust(16) + "".join(n.rjust(width) for n in names))
    rows = [("success", lambda b: f"{b['success']:.0%}"), ("avg_steps", lambda b: str(b["avg_steps"])),
            ("avg_seconds", lambda b: str(b["avg_seconds"])), ("tool_error_rate", lambda b: f"{b['tool_error_rate']:.0%}"),
            ("malformed_calls", lambda b: str(b["malformed_calls"])), ("no_action", lambda b: str(b["no_action"])), ("hit_limit", lambda b: str(b["hit_limit"]))]
    for label, fmt in rows:
        print(label.ljust(16) + "".join(fmt(s["overall"]).rjust(width) for s in summaries))
    print("\néxito por familia")
    for family in FAMILIES:
        if all(family in s["families"] for s in summaries):
            print(f"  {family:<14}" + "".join(f"{s['families'][family]['success']:.0%}".rjust(width) for s in summaries))


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("--model", required=True, help="Nombre del modelo en Ollama, p. ej. gemma4:e2b")
    r.add_argument("--out", required=True)
    r.add_argument("--per-family", type=int, default=8)
    r.add_argument("--repeat", type=int, default=1, help="Repeticiones por tarea para medir la varianza")
    r.add_argument("--seed", type=int, default=0)
    r.add_argument("--families", nargs="*", choices=FAMILIES)
    r.add_argument("--options", help="Opciones de Ollama en JSON. Vacío = igual que Stellar (solo num_ctx)")
    r.add_argument("--resume", action="store_true")
    c = sub.add_parser("compare")
    c.add_argument("runs", nargs="+")
    args = parser.parse_args(argv)
    if args.command == "run" and (args.per_family < 1 or args.repeat < 1):
        parser.error("--per-family y --repeat deben ser >= 1")
    {"run": run, "compare": compare}[args.command](args)


if __name__ == "__main__":
    main(sys.argv[1:])
