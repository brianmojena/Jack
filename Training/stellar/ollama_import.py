"""Import new GGUF weights with Ollama's native Gemma 4 renderer and tool parser."""
from __future__ import annotations

import argparse
import re
from pathlib import Path


def write_modelfile(gguf: Path, destination: Path):
    # Native renderer/parser directives are supported by current Ollama.
    # Explicitly configure them so custom GGUFs retain the tools capability.
    shard = re.match(r"(.*)-\d{5}-of-\d{5}\.gguf$", gguf.name)
    filename = shard.group(1) + "-*.gguf" if shard else gguf.name
    destination.write_text(
        f'FROM "./{filename}"\nTEMPLATE "{{{{ .Prompt }}}}"\n'
        'RENDERER gemma4\nPARSER gemma4\nPARAMETER stop "<turn|>"\n'
        'PARAMETER num_ctx 16384\nPARAMETER temperature 1\nPARAMETER top_p 0.95\nPARAMETER top_k 64\n',
        encoding="utf-8"
    )


def main():
    import subprocess
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("gguf", type=Path)
    parser.add_argument("--name", default="stellar-gemma:e2b")
    parser.add_argument("--write-only", action="store_true")
    args = parser.parse_args()
    gguf = args.gguf.resolve()
    if not gguf.is_file() or gguf.suffix.lower() != ".gguf":
        parser.error("Indica un archivo .gguf exportado desde Colab")
    modelfile = gguf.parent / "Modelfile"
    write_modelfile(gguf, modelfile)
    print(modelfile)
    if not args.write_only:
        subprocess.run(["ollama", "create", args.name, "-f", str(modelfile)], check=True, cwd=gguf.parent)
        subprocess.run(["ollama", "show", args.name], check=True)
        print("Importado:", args.name)


if __name__ == "__main__":
    main()
