"""Build a portable, validated zip and a notebook for uploading to Google Colab."""
from __future__ import annotations

import hashlib
import json
import textwrap
import zipfile
from pathlib import Path

from data_utils import validate_dataset

ROOT = Path(__file__).resolve().parent


def cell(kind, source):
    value = {"cell_type": kind, "metadata": {}, "source": textwrap.dedent(source).strip() + "\n"}
    value["id"] = hashlib.sha256((kind + value["source"]).encode()).hexdigest()[:12]
    if kind == "code":
        value.update(execution_count=None, outputs=[])
    return value


def make_notebook():
    cells = [
        cell("markdown", """
        # Stellar Code · Gemma 4 E2B en Colab

        Ajuste QLoRA de texto y herramientas para Jack. Selecciona **Entorno de ejecución → Cambiar tipo → GPU**.
        Sube `stellar-colab.zip` cuando aparezca el selector. Los checkpoints y el adaptador se guardan en Drive.
        La primera ejecución comprueba 10 pasos; cambia `SMOKE_TEST=False` y vuelve a ejecutar entrenamiento
        para hacer una época completa. Cada modo usa una carpeta diferente.

        Los datos son sintéticos y verificados. Mejorar la pérdida no prueba que el agente sea mejor:
        al terminar importa el GGUF y ejecuta el benchmark del README contra `gemma4:e2b`.
        """),
        cell("code", """
        import sys, json, zipfile, hashlib, subprocess
        from pathlib import Path
        from google.colab import files, drive

        PROJECT = Path('/content/stellar')
        uploaded = files.upload()
        archives = [name for name in uploaded if name.endswith('.zip')]
        if len(archives) != 1:
            raise ValueError('Sube únicamente stellar-colab.zip')
        PROJECT.mkdir(exist_ok=True)
        with zipfile.ZipFile(archives[0]) as archive:
            for item in archive.infolist():
                target = (PROJECT / item.filename).resolve()
                if not target.is_relative_to(PROJECT.resolve()):
                    raise ValueError('Ruta inválida en el zip')
            archive.extractall(PROJECT)
        sys.path.insert(0, str(PROJECT))
        from data_utils import validate_dataset
        from colab_runner import run_logged
        actual = validate_dataset(PROJECT / 'data')
        expected = json.loads((PROJECT / 'data/manifest.json').read_text())['splits']
        assert actual == expected, 'Los datos no coinciden con el manifiesto'
        print(json.dumps(actual, indent=2, ensure_ascii=False))
        drive.mount('/content/drive')
        """),
        cell("markdown", """
        ## Instalar dependencias

        La receta conserva el PyTorch/CUDA de Colab y fija Transformers como el notebook oficial de Unsloth.
        Si Colab pide reiniciar la sesión, reiníciala y vuelve a ejecutar la primera celda antes de continuar.
        Las versiones resueltas y las revisiones del modelo se registrarán en `run_config.json`.
        """),
        cell("code", """
        import torch
        assert torch.cuda.is_available(), 'Activa una GPU en Colab antes de continuar'
        print(torch.cuda.get_device_name(0), 'VRAM GB:', round(torch.cuda.get_device_properties(0).total_memory / 2**30, 1))
        constraints = Path('/content/stellar-torch-constraints.txt')
        constraints.write_text('torch==' + torch.__version__ + '\\n')
        subprocess.run([sys.executable, '-m', 'pip', 'install', '-r', str(PROJECT / 'requirements-colab.txt'),
                        '-c', str(constraints)], check=True)
        subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', str(PROJECT), '-p', 'test_*.py'],
                       cwd=PROJECT, check=True)
        """),
        cell("code", """
        SMOKE_TEST = True
        RESUME = False
        RUN_NAME = 'stellar-e2b-v1'
        MAX_LENGTH = 4096
        OUTPUT = Path('/content/drive/MyDrive/JackTraining') / (RUN_NAME + ('-smoke' if SMOKE_TEST else ''))
        command = [sys.executable, '-u', str(PROJECT / 'train_colab.py'), '--data', str(PROJECT / 'data'),
                   '--output', str(OUTPUT), '--max-length', str(MAX_LENGTH)]
        if SMOKE_TEST:
            command += ['--max-steps', '10']
        if RESUME:
            command += ['--resume']
        print('Modo:', 'prueba de 10 pasos' if SMOKE_TEST else 'entrenamiento completo')
        print('Carpeta de salida:', OUTPUT, 'Reanudar:', RESUME)
        run_logged(command, cwd=PROJECT, log_path=OUTPUT.parent / (OUTPUT.name + '-train.log'))
        print('Adaptador guardado en Drive:', OUTPUT / 'adapter')
        """),
        cell("markdown", """
        ## Exportar para Ollama

        Ejecuta la siguiente celda después del entrenamiento completo. Exporta Q8_0, la opción admitida
        por la receta oficial E2B consultada. Esto puede consumir bastante RAM y espacio; el adaptador ya
        está a salvo en Drive si la conversión falla. Para continuar tras una desconexión: monta Drive,
        instala las dependencias y define OUTPUT apuntando a tu ejecución terminada; no necesitas reentrenar.
        """),
        cell("code", """
        EXPORT_GGUF = not SMOKE_TEST
        if EXPORT_GGUF:
            run_logged([sys.executable, '-u', str(PROJECT / 'export_colab.py'), '--output', str(OUTPUT)],
                       cwd=PROJECT, log_path=OUTPUT.parent / (OUTPUT.name + '-export.log'))
            print('Descarga desde Drive el GGUF de lenguaje y su Modelfile en:', OUTPUT / 'gguf')
        else:
            print('Prueba corta terminada. Cambia SMOKE_TEST=False para entrenar una época completa.')
        """),
        cell("markdown", """
        ## Probar en el Mac

        Descarga el GGUF y consulta `README.md`: el importador añade `RENDERER gemma4` y `PARSER gemma4`
        para conservar las llamadas a herramientas. Después compara ambas versiones en las mismas tareas.
        Selecciona `stellar-gemma:e2b` en Stellar Code de Jack una vez verificada la mejora.

        Referencias: [Unsloth: Gemma 4](https://unsloth.ai/docs/models/gemma-4/train),
        [plantilla oficial de Google](https://huggingface.co/google/gemma-4-E2B-it/blob/main/chat_template.jinja),
        [Ollama: importar modelos](https://docs.ollama.com/import).
        """),
    ]
    return {"cells": cells, "metadata": {"colab": {"name": "Stellar_Gemma4_E2B_Colab.ipynb"},
            "accelerator": "GPU", "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
            "language_info": {"name": "python", "version": "3.12"}}, "nbformat": 4, "nbformat_minor": 5}


def main():
    summary = validate_dataset(ROOT / "data")
    notebook = ROOT / "Stellar_Gemma4_E2B_Colab.ipynb"
    notebook.write_text(json.dumps(make_notebook(), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    archive = ROOT / "stellar-colab.zip"
    sources = sorted(ROOT.glob("*.py")) + [ROOT / "requirements-colab.txt", ROOT / "README.md"]
    sources += [ROOT / "data" / name for name in ("train.jsonl", "valid.jsonl", "manifest.json")]
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for source in sources:
            bundle.write(source, source.relative_to(ROOT))
    print(f"Notebook: {notebook}\nPaquete: {archive} ({archive.stat().st_size:,} bytes)")
    print("SHA256:", hashlib.sha256(archive.read_bytes()).hexdigest())
    print(f"Datos: {summary['train']['records']} train / {summary['valid']['records']} valid")


if __name__ == "__main__":
    main()
