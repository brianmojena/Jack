"""Synthetic, automatically checked coding tasks for Stellar Code.

Every task builds a small project, gives the agent a prompt, checks the result on disk and in the final reply, and
carries an oracle: the tool calls and reply of a good solution, used to write training trajectories. Train and eval
draw names and values from disjoint pools so the benchmark is not a copy of the training data.
"""
from __future__ import annotations

import json
import os
import random
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

FAMILIES = ["fix_bug", "add_function", "question", "create_file", "rename", "run_report", "todo_search", "chat"]


@dataclass
class Task:
    id: str
    family: str
    split: str
    lang: str
    prompt: str
    files: dict[str, str]
    check: Callable[[str, dict], tuple[bool, str]]
    oracle: list[tuple] = field(default_factory=list)  # ("call", name, args) | ("reply", text)

    def materialize(self, root: str) -> None:
        for path, content in self.files.items():
            target = Path(root, path)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")


# MARK: - Pools (even indexes train, odd indexes eval)

PACKAGES = ["inventory", "billing", "orders", "shipping", "accounts", "catalog", "payments", "reports", "library", "clinic",
            "school", "garden", "weather", "fleet", "recipes", "tickets", "budget", "music", "parking", "hotel", "gym", "bakery"]
PROJECTS = ["tienda-api", "agenda", "panel-admin", "bot-ventas", "notas", "facturador", "rutas", "reservas", "encuestas", "turnos",
            "cocina", "biblioteca", "taller", "eventos", "clima", "flota"]
PERSONS = ["Ana", "Luis", "Marta", "Pedro", "Lucía", "Jorge", "Sofía", "Diego", "Elena", "Raúl", "Carmen", "Iván"]


def pool(values: list, split: str) -> list:
    return values[0::2] if split == "train" else values[1::2]


# MARK: - Checks

def _tests_pass(root: str) -> tuple[bool, str]:
    try:
        result = subprocess.run(["python3", "-m", "unittest"], cwd=root, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return False, "tests: timeout"
    return result.returncode == 0, "tests pasan" if result.returncode == 0 else "tests fallan: " + result.stderr[-300:]


def _unchanged(root: str, files: dict[str, str], only: list[str] | None = None) -> tuple[bool, str]:
    for path in only or files:
        target = Path(root, path)
        if not target.is_file() or target.read_text(encoding="utf-8") != files[path]:
            return False, f"{path} cambió"
    return True, ""


def _mentions(text: str, *needles) -> tuple[bool, str]:
    for needle in needles:
        pattern = rf"(?<![\w.]){re.escape(str(needle))}(?![\w])" if isinstance(needle, int) or str(needle).isdigit() else re.escape(str(needle))
        if not re.search(pattern, text, re.IGNORECASE):
            return False, f"la respuesta no menciona {needle!r}"
    return True, ""


def _used_tools(result: dict) -> tuple[bool, str]:
    return (True, "") if result["events"] else (False, "respondió sin mirar el proyecto")


def _all(*checks: tuple[bool, str]) -> tuple[bool, str]:
    for ok, reason in checks:
        if not ok:
            return False, reason
    return True, "ok"


def _python_ok(root: str, code: str) -> tuple[bool, str]:
    try:
        result = subprocess.run(["python3", "-c", code], cwd=root, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return False, "timeout"
    return result.returncode == 0, "comprobación ok" if result.returncode == 0 else "comprobación falla: " + result.stderr[-300:]


def _numbered(text: str) -> str:
    return "\n".join(f"{n}\t{line}" for n, line in enumerate(text.split("\n"), 1))


# MARK: - Shared project pieces

HELPERS = [
    ("def clamp_percent(value):\n    return max(0, min(100, value))\n", "self.assertEqual(clamp_percent(150), 100)", "clamp_percent"),
    ("def full_name(first, last):\n    return f\"{first} {last}\".strip()\n", "self.assertEqual(full_name(\"Ada\", \"Lovelace\"), \"Ada Lovelace\")", "full_name"),
    ("def is_blank(text):\n    return not text or not text.strip()\n", "self.assertTrue(is_blank(\"  \"))", "is_blank"),
    ("def cents(amount):\n    return int(round(amount * 100))\n", "self.assertEqual(cents(1.25), 125)", "cents"),
    ("def first_or_none(items):\n    return items[0] if items else None\n", "self.assertIsNone(first_or_none([]))", "first_or_none"),
    ("def unique_sorted(items):\n    return sorted(set(items))\n", "self.assertEqual(unique_sorted([3, 1, 3]), [1, 3])", "unique_sorted"),
]


def _project(rng: random.Random, split: str, pkg: str, extra: dict[str, str] | None = None) -> dict[str, str]:
    name = rng.choice(pool(PROJECTS, split))
    files = {"README.md": f"# {name}\n\nUtilidades de {pkg} escritas en Python.\n\nEjecuta los tests con `python3 -m unittest`.\n",
             f"{pkg}/__init__.py": "", "tests/__init__.py": ""}
    files.update(extra or {})
    return files


# MARK: - fix_bug

BUGS = [
    dict(names=["total", "sum_all", "add_up", "grand_total"],
         code="def {f}(values):\n    \"\"\"Return the sum of all values.\"\"\"\n    total = 0\n    for value in values[1:]:\n        total += value\n    return total\n",
         old="for value in values[1:]:", new="for value in values:",
         tests=["self.assertEqual({f}([1, 2, 3]), 6)", "self.assertEqual({f}([]), 0)", "self.assertEqual({f}([5]), 5)"],
         es="se saltaba el primer elemento", en="skipped the first element"),
    dict(names=["is_adult", "can_vote", "of_age", "can_sign"],
         code="def {f}(age):\n    return age > 18\n", old="return age > 18", new="return age >= 18",
         tests=["self.assertTrue({f}(18))", "self.assertFalse({f}(17))", "self.assertTrue({f}(40))"],
         es="excluía a quien tiene justo 18 años", en="excluded someone who is exactly 18"),
    dict(names=["apply_discount", "discounted_price", "final_price", "sale_price"],
         code="def {f}(price, discount):\n    \"\"\"discount is a fraction: 0.2 means 20% off.\"\"\"\n    return round(price * discount, 2)\n",
         old="return round(price * discount, 2)", new="return round(price * (1 - discount), 2)",
         tests=["self.assertEqual({f}(100, 0.2), 80.0)", "self.assertEqual({f}(50, 0), 50.0)"],
         es="devolvía el descuento en lugar del precio final", en="returned the discount instead of the final price"),
    dict(names=["slugify", "make_slug", "to_slug", "url_slug"],
         code="def {f}(title):\n    return title.strip().lower().replace(\" \", \"_\")\n",
         old="replace(\" \", \"_\")", new="replace(\" \", \"-\")",
         tests=["self.assertEqual({f}(\"Hola Mundo\"), \"hola-mundo\")", "self.assertEqual({f}(\" A B \"), \"a-b\")"],
         es="usaba guion bajo en lugar de guion", en="used underscores instead of hyphens"),
    dict(names=["count_words", "word_frequencies", "word_counts", "tally_words"],
         code="def {f}(text):\n    counts = {{}}\n    for word in text.lower().split():\n        counts[word] = 1\n    return counts\n",
         old="counts[word] = 1", new="counts[word] = counts.get(word, 0) + 1",
         tests=["self.assertEqual({f}(\"a b a\"), {{\"a\": 2, \"b\": 1}})", "self.assertEqual({f}(\"\"), {{}})"],
         es="no acumulaba las repeticiones", en="did not accumulate repeated words"),
    dict(names=["average", "mean", "avg_score", "mean_value"],
         code="def {f}(values):\n    if not values:\n        return 0\n    return sum(values) / (len(values) - 1)\n",
         old="return sum(values) / (len(values) - 1)", new="return sum(values) / len(values)",
         tests=["self.assertEqual({f}([2, 4, 6]), 4)", "self.assertEqual({f}([]), 0)", "self.assertEqual({f}([5]), 5)"],
         es="dividía entre n - 1", en="divided by n - 1"),
    dict(names=["largest", "max_value", "highest", "peak"],
         code="def {f}(values):\n    best = 0\n    for value in values:\n        if value > best:\n            best = value\n    return best\n",
         old="best = 0", new="best = values[0]",
         tests=["self.assertEqual({f}([-3, -1, -2]), -1)", "self.assertEqual({f}([1, 5, 2]), 5)"],
         es="empezaba en 0 y fallaba con números negativos", en="started at 0 and failed with negative numbers"),
    dict(names=["to_fahrenheit", "c_to_f", "celsius_to_fahrenheit", "fahrenheit"],
         code="def {f}(celsius):\n    return celsius * 9 / 5 - 32\n", old="return celsius * 9 / 5 - 32", new="return celsius * 9 / 5 + 32",
         tests=["self.assertEqual({f}(100), 212)", "self.assertEqual({f}(0), 32)"],
         es="restaba 32 en lugar de sumarlo", en="subtracted 32 instead of adding it"),
    dict(names=["is_palindrome", "palindrome", "reads_same", "is_mirror"],
         code="def {f}(text):\n    cleaned = text.replace(\" \", \"\")\n    return cleaned == cleaned[::-1]\n",
         old="cleaned = text.replace(\" \", \"\")", new="cleaned = text.replace(\" \", \"\").lower()",
         tests=["self.assertTrue({f}(\"Anita lava la tina\"))", "self.assertFalse({f}(\"hola\"))"],
         es="distinguía mayúsculas y minúsculas", en="was case-sensitive"),
    dict(names=["paginate", "get_page", "page_items", "slice_page"],
         code="def {f}(items, page, size):\n    \"\"\"Pages start at 1.\"\"\"\n    return items[page * size:(page + 1) * size]\n",
         old="return items[page * size:(page + 1) * size]", new="return items[(page - 1) * size:page * size]",
         tests=["self.assertEqual({f}(list(range(1, 11)), 1, 3), [1, 2, 3])", "self.assertEqual({f}(list(range(1, 11)), 4, 3), [10])"],
         es="trataba las páginas como si empezaran en 0", en="treated pages as starting at 0"),
]

FIX_PROMPTS = [
    ("es", "Los tests de `{pkg}` fallan. Encuentra el error y arréglalo sin tocar los tests."),
    ("es", "`python3 -m unittest` falla en este proyecto, ¿lo puedes corregir? No modifiques los tests."),
    ("es", "La función `{f}` devuelve resultados incorrectos. Arréglala y comprueba con los tests."),
    ("es", "hay un bug en {pkg}/{mod}.py, los tests no pasan. arreglalo porfa"),
    ("en", "Some tests are failing in this repo. Fix the bug without modifying the tests."),
    ("en", "`{f}` in {pkg}/{mod}.py is broken. Please fix it and run the tests."),
]


def _module_with(rng: random.Random, main: str, helpers: int) -> tuple[str, list]:
    chosen = rng.sample(HELPERS, helpers)
    blocks = [h[0] for h in chosen] + [main]
    rng.shuffle(blocks)
    return "\n\n".join(blocks), chosen


def fix_bug(rng: random.Random, split: str, index: int) -> Task:
    bug = rng.choice(BUGS)
    f = rng.choice(pool(bug["names"], split))
    pkg, mod = rng.choice(pool(PACKAGES, split)), rng.choice(["utils", "core", "helpers", "logic"])
    code = bug["code"].format(f=f)
    module, helpers = _module_with(rng, code, rng.randint(1, 2))
    tests = [t.format(f=f) for t in bug["tests"]] + [h[1] for h in helpers]
    names = ", ".join([f] + [h[2] for h in helpers])
    test = (f"import unittest\n\nfrom {pkg}.{mod} import {names}\n\n\nclass {pkg.title()}Tests(unittest.TestCase):\n"
            + "\n".join(f"    def test_{i}(self):\n        {t}\n" for i, t in enumerate(tests)) + "\n\nif __name__ == \"__main__\":\n    unittest.main()\n")
    module_path, test_path = f"{pkg}/{mod}.py", f"tests/test_{mod}.py"
    files = _project(rng, split, pkg, {module_path: module, test_path: test})
    lang, template = rng.choice(FIX_PROMPTS)
    prompt = template.format(pkg=pkg, f=f, mod=mod)
    edit = ("call", "edit_file", {"path": module_path, "old_string": bug["old"], "new_string": bug["new"]})
    run = ("call", "run_command", {"command": "python3 -m unittest"})
    route = rng.choice(["run_first", "explore", "search"] if "{f}" in template else ["run_first", "explore"])
    if route == "run_first":
        steps = [run, ("call", "read_file", {"path": module_path}), edit, run]
    elif route == "explore":
        steps = [("call", "list_files", {}), ("call", "read_file", {"path": test_path}), ("call", "read_file", {"path": module_path}), edit, run]
    else:
        steps = [("call", "search", {"pattern": f"def {f}"}), ("call", "read_file", {"path": module_path}), edit, run]
    reply = (f"Arreglado. `{f}` en `{module_path}` {bug['es']}: cambié `{bug['old']}` por `{bug['new']}`. Los {len(tests)} tests pasan."
             if lang == "es" else
             f"Fixed. `{f}` in `{module_path}` {bug['en']}: I changed `{bug['old']}` to `{bug['new']}`. All {len(tests)} tests pass.")
    return Task(f"{split}-fix_bug-{index}", "fix_bug", split, lang, prompt, files,
                lambda root, result: _all(_unchanged(root, files, [test_path]), _tests_pass(root)), steps + [("reply", reply)])


# MARK: - add_function

FEATURES = [
    dict(name="clamp", sig="clamp(value, low, high)", es="limite `value` al rango entre `low` y `high`", en="limits `value` to the range between `low` and `high`",
         body="def clamp(value, low, high):\n    return max(low, min(high, value))\n",
         check="assert clamp(5, 0, 3) == 3 and clamp(-1, 0, 3) == 0 and clamp(2, 0, 3) == 2", demo="print(clamp(5, 0, 3), clamp(-1, 0, 3))"),
    dict(name="chunk", sig="chunk(items, size)", es="divida una lista en sublistas de tamaño `size` (la última puede ser más corta)",
         en="splits a list into sublists of length `size` (the last one may be shorter)",
         body="def chunk(items, size):\n    return [items[i:i + size] for i in range(0, len(items), size)]\n",
         check="assert chunk([1, 2, 3, 4, 5], 2) == [[1, 2], [3, 4], [5]] and chunk([], 3) == []", demo="print(chunk([1, 2, 3, 4, 5], 2))"),
    dict(name="count_vowels", sig="count_vowels(text)", es="cuente las vocales (a, e, i, o, u) sin distinguir mayúsculas",
         en="counts the vowels (a, e, i, o, u), case-insensitively",
         body="def count_vowels(text):\n    return sum(1 for char in text.lower() if char in \"aeiou\")\n",
         check="assert count_vowels('Hola Mundo') == 4 and count_vowels('xyz') == 0", demo="print(count_vowels('Hola Mundo'))"),
    dict(name="initials", sig="initials(name)", es="devuelva las iniciales en mayúsculas, p. ej. `\"ada lovelace\"` → `\"AL\"`",
         en="returns the uppercase initials, e.g. `\"ada lovelace\"` → `\"AL\"`",
         body="def initials(name):\n    return \"\".join(part[0].upper() for part in name.split())\n",
         check="assert initials('ada lovelace') == 'AL' and initials('Grace') == 'G'", demo="print(initials('ada lovelace'))"),
    dict(name="dedupe", sig="dedupe(items)", es="elimine los duplicados de una lista manteniendo el orden original",
         en="removes duplicates from a list while keeping the original order",
         body="def dedupe(items):\n    seen = set()\n    result = []\n    for item in items:\n        if item not in seen:\n            seen.add(item)\n            result.append(item)\n    return result\n",
         check="assert dedupe([3, 1, 3, 2, 1]) == [3, 1, 2] and dedupe([]) == []", demo="print(dedupe([3, 1, 3, 2, 1]))"),
    dict(name="safe_divide", sig="safe_divide(a, b)", es="devuelva `a / b`, o `None` si `b` es 0", en="returns `a / b`, or `None` when `b` is 0",
         body="def safe_divide(a, b):\n    if b == 0:\n        return None\n    return a / b\n",
         check="assert safe_divide(6, 3) == 2 and safe_divide(1, 0) is None", demo="print(safe_divide(6, 3), safe_divide(1, 0))"),
    dict(name="is_even", sig="is_even(n)", es="indique si un entero es par", en="tells whether an integer is even",
         body="def is_even(n):\n    return n % 2 == 0\n", check="assert is_even(4) and not is_even(7) and is_even(0)", demo="print(is_even(4), is_even(7))"),
    dict(name="truncate", sig="truncate(text, limit)", es="recorte `text` a `limit` caracteres y añada `…` si lo recortó",
         en="cuts `text` to `limit` characters and appends `…` when it was cut",
         body="def truncate(text, limit):\n    if len(text) <= limit:\n        return text\n    return text[:limit] + \"…\"\n",
         check="assert truncate('hola mundo', 4) == 'hola…' and truncate('hola', 10) == 'hola'", demo="print(truncate('hola mundo', 4))"),
]


def add_function(rng: random.Random, split: str, index: int) -> Task:
    feature = rng.choice(FEATURES)
    pkg, mod = rng.choice(pool(PACKAGES, split)), rng.choice(["utils", "text", "tools", "common"])
    module = "\n\n".join(h[0] for h in rng.sample(HELPERS, rng.randint(1, 2)))
    module_path = f"{pkg}/{mod}.py"
    files = _project(rng, split, pkg, {module_path: module})
    lang = rng.choice(["es", "es", "en"])
    prompt = (f"Añade a `{module_path}` una función `{feature['sig']}` que {feature['es']}."
              if lang == "es" else f"Add a function `{feature['sig']}` to `{module_path}` that {feature['en']}.")
    last = module.rstrip("\n").split("\n")[-1]
    assert module.count(last) == 1
    check_code = f"from {pkg}.{mod} import {feature['name']}\n{feature['check']}"
    steps = [("call", "read_file", {"path": module_path}),
             ("call", "edit_file", {"path": module_path, "old_string": last, "new_string": last + "\n\n\n" + feature["body"].rstrip("\n")}),
             ("call", "run_command", {"command": f"python3 -c \"from {pkg}.{mod} import {feature['name']}; {feature['demo']}\""})]
    reply = (f"Listo: añadí `{feature['sig']}` al final de `{module_path}` y la probé con un ejemplo."
             if lang == "es" else f"Done: I added `{feature['sig']}` at the end of `{module_path}` and tried it with an example.")
    return Task(f"{split}-add_function-{index}", "add_function", split, lang, prompt, files,
                lambda root, result: _python_ok(root, check_code), steps + [("reply", reply)])


# MARK: - question (read-only, several languages)

def question(rng: random.Random, split: str, index: int) -> Task:
    kind = rng.choice(["port", "retries", "where", "version"])
    stack = rng.choice(["python", "swift", "ts"])
    port = rng.choice(pool(list(range(3000, 9100, 37)), split))
    retries, timeout = rng.randint(2, 9), rng.choice([10, 15, 20, 30, 45, 60])
    if stack == "python":
        config_path = "app/config.py"
        config = f"DEFAULT_HOST = \"0.0.0.0\"\nDEFAULT_PORT = {port}\nTIMEOUT_SECONDS = {timeout}\nMAX_RETRIES = {retries}\n"
        code_path, class_name = "app/client.py", rng.choice(pool(["ApiClient", "HttpClient", "Fetcher", "Gateway", "Connector", "Requester"], split))
        code = f"from app.config import MAX_RETRIES, TIMEOUT_SECONDS\n\n\nclass {class_name}:\n    def fetch(self, url):\n        for attempt in range(MAX_RETRIES):\n            pass\n"
        files = {"README.md": "# servicio\n", "app/__init__.py": "", config_path: config, code_path: code, "requirements.txt": "",
                 "app/main.py": "from app.config import DEFAULT_HOST, DEFAULT_PORT\n\n\ndef main():\n    print(DEFAULT_HOST, DEFAULT_PORT)\n"}
        dep_file, port_pattern, retry_pattern = "requirements.txt", "PORT", "RETRIES"
    elif stack == "swift":
        config_path = "Sources/App/Config.swift"
        config = f"enum Config {{\n    static let host = \"0.0.0.0\"\n    static let defaultPort = {port}\n    static let timeout: TimeInterval = {timeout}\n    static let maxRetries = {retries}\n}}\n"
        code_path, class_name = "Sources/App/Networking.swift", rng.choice(pool(["APIClient", "HTTPClient", "Fetcher", "Gateway", "Connector", "Requester"], split))
        code = f"import Foundation\n\nfinal class {class_name} {{\n    func fetch(_ url: URL) async throws -> Data {{\n        for _ in 0..<Config.maxRetries {{ }}\n        return Data()\n    }}\n}}\n"
        files = {"README.md": "# App\n", config_path: config, code_path: code, "Package.swift": "// swift-tools-version:5.9\nimport PackageDescription\n"}
        dep_file, port_pattern, retry_pattern = "Package.swift", "Port", "Retries"
    else:
        config_path = "src/config.ts"
        config = f"export const HOST = \"0.0.0.0\";\nexport const DEFAULT_PORT = {port};\nexport const TIMEOUT_MS = {timeout * 1000};\nexport const MAX_RETRIES = {retries};\n"
        code_path, class_name = "src/client.ts", rng.choice(pool(["ApiClient", "HttpClient", "Fetcher", "Gateway", "Connector", "Requester"], split))
        code = f"import {{ MAX_RETRIES }} from \"./config\";\n\nexport class {class_name} {{\n  async fetch(url: string) {{\n    for (let i = 0; i < MAX_RETRIES; i++) {{}}\n  }}\n}}\n"
        files = {"README.md": "# web\n", config_path: config, code_path: code, "package.json": "{}\n", "src/index.ts": "import { DEFAULT_PORT } from \"./config\";\nconsole.log(DEFAULT_PORT);\n"}
        dep_file, port_pattern, retry_pattern = "package.json", "PORT", "RETRIES"
    lang = rng.choice(["es", "es", "en"])
    if kind == "version":
        dep, version = rng.choice([("requests", "2.32.3"), ("flask", "3.0.3"), ("pydantic", "2.8.2"), ("httpx", "0.27.0"), ("rich", "13.7.1")] if stack == "python" else
                                  [("swift-argument-parser", "1.5.0"), ("swift-log", "1.6.1"), ("swift-nio", "2.65.0")] if stack == "swift" else
                                  [("react", "18.3.1"), ("zod", "3.23.8"), ("express", "4.19.2"), ("vite", "5.4.2")])
        if stack == "python":
            files[dep_file] = "\n".join(sorted({f"{dep}=={version}", "pytest==8.3.2", "python-dotenv==1.0.1"})) + "\n"
        elif stack == "swift":
            files[dep_file] = ("// swift-tools-version:5.9\nimport PackageDescription\n\nlet package = Package(\n    name: \"App\",\n    dependencies: [\n"
                               f"        .package(url: \"https://github.com/apple/{dep}\", exact: \"{version}\"),\n    ]\n)\n")
        else:
            files[dep_file] = json.dumps({"name": "web", "dependencies": {dep: version, "typescript": "5.5.4"}}, indent=2) + "\n"
        prompt = f"¿Qué versión de {dep} usa este proyecto?" if lang == "es" else f"Which version of {dep} does this project use?"
        answer, needles = version, [version]
        steps = [("call", "search", {"pattern": dep}), ("reply", f"Usa **{dep} {version}**, fijada en `{dep_file}`." if lang == "es" else f"It uses **{dep} {version}**, pinned in `{dep_file}`.")]
    elif kind == "port":
        prompt = "¿En qué puerto escucha el servidor por defecto?" if lang == "es" else "Which port does the server listen on by default?"
        needles = [port]
        steps = [("call", "search", {"pattern": port_pattern}), ("call", "read_file", {"path": config_path}),
                 ("reply", f"Por defecto escucha en el puerto **{port}** (`{config_path}`)." if lang == "es" else f"It listens on port **{port}** by default (`{config_path}`).")]
    elif kind == "retries":
        prompt = (f"¿Cuántas veces reintenta `{class_name}` una petición antes de rendirse?" if lang == "es"
                  else f"How many times does `{class_name}` retry a request before giving up?")
        needles = [retries]
        steps = [("call", "search", {"pattern": class_name}), ("call", "read_file", {"path": code_path}), ("call", "search", {"pattern": retry_pattern}),
                 ("reply", f"Hasta **{retries}** intentos: `{class_name}` recorre el máximo de reintentos definido en `{config_path}`." if lang == "es"
                  else f"Up to **{retries}** attempts: `{class_name}` loops over the max retries set in `{config_path}`.")]
    else:
        prompt = f"¿Dónde está definida la clase `{class_name}`?" if lang == "es" else f"Where is the `{class_name}` class defined?"
        needles = [os.path.basename(code_path)]
        steps = [("call", "search", {"pattern": f"class {class_name}"}),
                 ("reply", f"En `{code_path}`." if lang == "es" else f"In `{code_path}`.")]
    return Task(f"{split}-question-{index}", "question", split, lang, prompt, files,
                lambda root, result: _all(_used_tools(result), _unchanged(root, files), _mentions(result["final"], *needles)), steps)


# MARK: - create_file

def create_file(rng: random.Random, split: str, index: int) -> Task:
    kind = rng.choice(["json", "gitignore", "readme", "script"])
    pkg = rng.choice(pool(PACKAGES, split))
    files = _project(rng, split, pkg, {f"{pkg}/core.py": rng.choice(HELPERS)[0]})
    lang = rng.choice(["es", "es", "en"])
    if kind == "json":
        port, path = rng.choice(pool(list(range(4000, 9000, 53)), split)), rng.choice(["config/settings.json", "settings.json", "config/app.json"])
        expected = {"host": "localhost", "port": port, "debug": False}
        prompt = (f"Crea `{path}` con host `localhost`, puerto {port} y debug desactivado." if lang == "es"
                  else f"Create `{path}` with host `localhost`, port {port} and debug turned off.")
        steps = [("call", "write_file", {"path": path, "content": json.dumps(expected, indent=2) + "\n"}),
                 ("reply", f"Creado `{path}`." if lang == "es" else f"Created `{path}`.")]

        def check(root, result):
            try:
                return (json.loads(Path(root, path).read_text()) == expected, "json correcto")
            except Exception as error:
                return False, f"json: {error}"
    elif kind == "gitignore":
        prompt = ("Crea un .gitignore que ignore `__pycache__/`, `.venv/` y los archivos `.log`." if lang == "es"
                  else "Create a .gitignore that ignores `__pycache__/`, `.venv/` and `.log` files.")
        steps = [("call", "write_file", {"path": ".gitignore", "content": "__pycache__/\n.venv/\n*.log\n"}),
                 ("reply", "Creado `.gitignore` con esas tres reglas." if lang == "es" else "Created `.gitignore` with those three rules.")]

        def check(root, result):
            target = Path(root, ".gitignore")
            lines = {line.strip().lstrip("/") for line in target.read_text().splitlines()} if target.is_file() else set()
            ok = bool(lines & {"__pycache__/", "__pycache__"}) and bool(lines & {".venv/", ".venv"}) and "*.log" in lines
            return ok, ".gitignore " + ("correcto" if ok else f"incompleto: {sorted(lines)}")
    elif kind == "readme":
        license_name = rng.choice(["MIT", "Apache 2.0", "GPL-3.0"])
        prompt = (f"Añade al final del README.md una sección `## Licencia` que diga que el proyecto usa la licencia {license_name}." if lang == "es"
                  else f"Add a `## License` section at the end of README.md saying the project is licensed under {license_name}.")
        heading = "## Licencia" if lang == "es" else "## License"
        sentence = (f"Este proyecto usa la licencia {license_name}." if lang == "es" else f"This project is licensed under {license_name}.")
        original = files["README.md"]
        last = original.rstrip("\n").split("\n")[-1]
        steps = [("call", "read_file", {"path": "README.md"}),
                 ("call", "edit_file", {"path": "README.md", "old_string": last, "new_string": f"{last}\n\n{heading}\n\n{sentence}"}),
                 ("reply", f"Añadida la sección {heading} al final del README." if lang == "es" else f"Added the {heading} section at the end of the README.")]

        def check(root, result):
            text = Path(root, "README.md").read_text()
            ok = text.startswith(original.rstrip("\n")) and heading in text and license_name in text.split(heading)[-1]
            return ok, "README " + ("correcto" if ok else "incorrecto")
    else:
        person = rng.choice(pool(PERSONS, split))
        path = rng.choice(["scripts/hello.py", "hello.py", "tools/greet.py"])
        prompt = (f"Crea `{path}` que imprima `Hola, {person}` y ejecútalo." if lang == "es" else f"Create `{path}` that prints `Hola, {person}` and run it.")
        steps = [("call", "write_file", {"path": path, "content": f"print(\"Hola, {person}\")\n"}),
                 ("call", "run_command", {"command": f"python3 {path}"}),
                 ("reply", f"Creado `{path}`; al ejecutarlo imprime `Hola, {person}`." if lang == "es" else f"Created `{path}`; running it prints `Hola, {person}`.")]

        def check(root, result):
            if not Path(root, path).is_file():
                return False, f"no existe {path}"
            out = subprocess.run(["python3", path], cwd=root, capture_output=True, text=True, timeout=30).stdout.strip()
            return out == f"Hola, {person}", f"imprime {out!r}"
    return Task(f"{split}-create_file-{index}", "create_file", split, lang, prompt, files, check, steps)


# MARK: - rename

RENAMES = [("calc", "calculate_total"), ("proc", "process_order"), ("fmt", "format_price"), ("get_u", "get_user"), ("chk", "is_valid"),
           ("do_it", "send_email"), ("tmp_fn", "parse_date"), ("helper", "normalize_name"), ("f1", "compute_tax"), ("run2", "sync_cache")]


def rename(rng: random.Random, split: str, index: int) -> Task:
    old, new = rng.choice(pool(RENAMES, split))
    pkg = rng.choice(pool(PACKAGES, split))
    a, b = f"{pkg}/core.py", f"{pkg}/service.py"
    core = f"def {old}(x):\n    return x * 2\n"
    service = f"from {pkg}.core import {old}\n\n\ndef handle(value):\n    return {old}(value) + 1\n"
    test = (f"import unittest\n\nfrom {pkg}.core import {old}\nfrom {pkg}.service import handle\n\n\nclass Tests(unittest.TestCase):\n"
            f"    def test_double(self):\n        self.assertEqual({old}(2), 4)\n\n    def test_handle(self):\n        self.assertEqual(handle(3), 7)\n")
    files = _project(rng, split, pkg, {a: core, b: service, "tests/test_core.py": test})
    lang = rng.choice(["es", "es", "en"])
    prompt = (f"Renombra la función `{old}` a `{new}` en todo el proyecto y comprueba que los tests siguen pasando." if lang == "es"
              else f"Rename the function `{old}` to `{new}` across the project and make sure the tests still pass.")
    steps = [("call", "search", {"pattern": rf"\b{old}\b"})]
    for path, lines in [(a, [f"def {old}(x):"]), (b, [f"from {pkg}.core import {old}", f"    return {old}(value) + 1"]),
                        ("tests/test_core.py", [f"from {pkg}.core import {old}", f"        self.assertEqual({old}(2), 4)"])]:
        steps.append(("call", "read_file", {"path": path}))
        steps += [("call", "edit_file", {"path": path, "old_string": line, "new_string": line.replace(old, new)}) for line in lines]
    steps += [("call", "run_command", {"command": "python3 -m unittest"}),
              ("reply", f"Renombré `{old}` a `{new}` en 3 archivos (definición, uso en `{b}` y tests). Los tests pasan." if lang == "es"
               else f"Renamed `{old}` to `{new}` in 3 files (definition, its use in `{b}` and the tests). Tests pass.")]

    def check(root, result):
        leftovers = [p for p in (a, b, "tests/test_core.py") if re.search(rf"\b{old}\b", Path(root, p).read_text())]
        if leftovers:
            return False, f"queda {old} en {leftovers}"
        return _all(_python_ok(root, f"from {pkg}.core import {new}"), _tests_pass(root))
    return Task(f"{split}-rename-{index}", "rename", split, lang, prompt, files, check, steps)


# MARK: - run_report

def run_report(rng: random.Random, split: str, index: int) -> Task:
    pkg = rng.choice(pool(PACKAGES, split))
    total, failing = rng.randint(4, 9), rng.randint(1, 3)
    bad = set(rng.sample(range(total), failing))
    module = "def double(x):\n    return x * 2\n"
    cases = [f"    def test_{i}(self):\n        self.assertEqual(double({i}), {i * 2 + (1 if i in bad else 0)})\n" for i in range(total)]
    test = f"import unittest\n\nfrom {pkg}.math import double\n\n\nclass Tests(unittest.TestCase):\n" + "\n".join(cases)
    files = _project(rng, split, pkg, {f"{pkg}/math.py": module, "tests/test_math.py": test})
    lang = rng.choice(["es", "es", "en"])
    prompt = ("Ejecuta los tests y dime cuántos hay en total y cuántos fallan. No cambies nada." if lang == "es"
              else "Run the tests and tell me how many there are and how many fail. Don't change anything.")
    names = ", ".join(f"`test_{i}`" for i in sorted(bad))
    steps = [("call", "run_command", {"command": "python3 -m unittest"}),
             ("reply", f"Hay **{total}** tests: {total - failing} pasan y **{failing}** fallan ({names})." if lang == "es"
              else f"There are **{total}** tests: {total - failing} pass and **{failing}** fail ({names}).")]
    return Task(f"{split}-run_report-{index}", "run_report", split, lang, prompt, files,
                lambda root, result: _all(_used_tools(result), _unchanged(root, files), _mentions(result["final"], total, failing)), steps)


# MARK: - todo_search

def todo_search(rng: random.Random, split: str, index: int) -> Task:
    pkg = rng.choice(pool(PACKAGES, split))
    marker = rng.choice(["TODO", "FIXME"])
    notes = ["validar la entrada", "manejar el caso vacío", "añadir caché", "registrar errores", "quitar este parche", "soportar decimales"]
    candidates = [f"{pkg}/api.py", f"{pkg}/models.py", f"{pkg}/views.py", f"{pkg}/db.py", "scripts/migrate.py"]
    chosen = rng.sample(candidates, rng.randint(2, 3))
    files = _project(rng, split, pkg)
    count = 0
    for path in candidates:
        n = rng.randint(1, 2) if path in chosen else 0
        count += n
        body = "".join(f"# {marker}: {rng.choice(notes)}\n" for _ in range(n))
        files[path] = body + "def placeholder():\n    return None\n"
    lang = rng.choice(["es", "es", "en"])
    prompt = (f"¿Cuántos {marker} quedan en el proyecto y en qué archivos están?" if lang == "es"
              else f"How many {marker} comments are left in the project, and in which files?")
    listing = ", ".join(f"`{p}`" for p in sorted(chosen))
    steps = [("call", "search", {"pattern": marker}),
             ("reply", f"Hay **{count}** {marker} en {len(chosen)} archivos: {listing}." if lang == "es"
              else f"There are **{count}** {marker} comments in {len(chosen)} files: {listing}.")]
    return Task(f"{split}-todo_search-{index}", "todo_search", split, lang, prompt, files,
                lambda root, result: _all(_used_tools(result), _unchanged(root, files),
                                          _mentions(result["final"], count, *[os.path.basename(p) for p in chosen])), steps)


# MARK: - chat (no tools needed)

CHATS = [
    ("es", "¿Qué diferencia hay entre una lista y una tupla en Python?",
     "Una **lista** es mutable: puedes añadir, quitar o cambiar elementos. Una **tupla** es inmutable: una vez creada no cambia, "
     "por eso puede usarse como clave de un diccionario y suele ser algo más ligera.\n\n```python\nxs = [1, 2]; xs.append(3)   # ok\nt = (1, 2); t[0] = 5        # TypeError\n```"),
    ("es", "Explícame en dos frases qué es un decorador en Python.",
     "Un decorador es una función que recibe otra función y devuelve una versión envuelta con comportamiento extra. "
     "Se aplica con `@nombre` encima de la definición, p. ej. `@functools.cache`."),
    ("en", "What's the difference between `let` and `var` in Swift?",
     "`let` declares a constant: it is assigned once and can't change. `var` declares a variable you can reassign. Prefer `let` unless you need mutation."),
    ("es", "¿Qué hace `git rebase` comparado con `git merge`?",
     "`git merge` une dos ramas creando un commit de merge y conserva la historia tal cual. `git rebase` reaplica tus commits encima de otra rama, "
     "dejando una historia lineal pero reescribiendo los hashes; no lo uses sobre commits ya compartidos."),
    ("es", "hola! qué puedes hacer?",
     "¡Hola! Soy Stellar Code. Puedo explorar este proyecto, leer y editar archivos, buscar en el código y ejecutar comandos como tests o builds. "
     "Dime qué necesitas."),
    ("en", "Explain what a race condition is, briefly.",
     "A race condition happens when the result depends on the timing of concurrent operations, e.g. two threads read-modify-write the same value "
     "and one update is lost. Fix it with locks, actors or atomic operations."),
    ("es", "¿Para qué sirve `async`/`await`?",
     "Permiten escribir código asíncrono de forma secuencial: `await` suspende la función hasta que la operación termina sin bloquear el hilo, "
     "y `async` marca las funciones que pueden suspenderse."),
    ("es", "¿Qué es una expresión regular?",
     "Es un patrón para buscar o validar texto. Por ejemplo, `^\\d{3}-\\d{4}$` coincide con `555-1234`. Se usan en búsquedas, validaciones y reemplazos."),
    ("en", "When should I use a struct instead of a class in Swift?",
     "Use a `struct` by default: it's a value type, copied on assignment, and safer with concurrency. Use a `class` when you need shared identity, "
     "reference semantics, inheritance or Objective-C interop."),
    ("es", "¿Qué significa el error HTTP 404?",
     "**404 Not Found**: el servidor responde pero no encuentra el recurso pedido. Suele ser una URL mal escrita, una ruta que no existe o un recurso borrado."),
    ("es", "dame un ejemplo de list comprehension",
     "```python\ncuadrados = [n * n for n in range(10) if n % 2 == 0]\n# [0, 4, 16, 36, 64]\n```\nCrea una lista aplicando una expresión a cada elemento que cumple la condición."),
    ("en", "What does `chmod +x` do?",
     "It adds the execute permission to a file, so you can run it directly, e.g. `chmod +x build.sh && ./build.sh`."),
    ("es", "¿Qué es un índice en una base de datos?",
     "Una estructura auxiliar (normalmente un árbol B) que permite encontrar filas por una columna sin recorrer toda la tabla. "
     "Acelera las lecturas a costa de algo de espacio y escrituras más lentas."),
    ("es", "gracias, eso era todo",
     "¡De nada! Si necesitas algo más del proyecto, aquí estoy."),
    ("en", "What's a pure function?",
     "A function whose result depends only on its arguments and that has no side effects, so the same input always gives the same output."),
    ("es", "¿Cuál es la diferencia entre `==` y `is` en Python?",
     "`==` compara valores; `is` compara identidad (si son el mismo objeto). Usa `is` solo con `None`, `True` o `False`."),
]


def chat(rng: random.Random, split: str, index: int) -> Task:
    lang, prompt, answer = rng.choice(pool(CHATS, split))
    pkg = rng.choice(pool(PACKAGES, split))
    files = _project(rng, split, pkg, {f"{pkg}/core.py": rng.choice(HELPERS)[0]})

    def check(root, result):
        if result["events"]:
            return False, "usó herramientas para una pregunta general"
        return (len(result["final"].strip()) >= 30, "respuesta " + ("ok" if len(result["final"].strip()) >= 30 else "vacía o muy corta"))
    return Task(f"{split}-chat-{index}", "chat", split, lang, prompt, files, check, [("reply", answer)])


GENERATORS = {"fix_bug": fix_bug, "add_function": add_function, "question": question, "create_file": create_file,
              "rename": rename, "run_report": run_report, "todo_search": todo_search, "chat": chat}


def make_tasks(split: str, per_family: int, seed: int = 0, families: list[str] | None = None) -> list[Task]:
    rng = random.Random(f"{split}-{seed}")
    return [GENERATORS[family](rng, split, i) for family in (families or FAMILIES) for i in range(per_family)]
