"""Export an already saved adapter without retraining (including after a Colab disconnect)."""
from __future__ import annotations

import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    adapter = args.output / "adapter"
    if not (adapter / "adapter_config.json").is_file():
        parser.error("No hay un adaptador terminado en " + str(adapter))
    from unsloth import FastModel
    from train_colab import export_model
    model, processor = FastModel.from_pretrained(model_name=str(adapter), max_seq_length=4096, load_in_4bit=True)
    export_model(model, processor, args.output)


if __name__ == "__main__":
    main()
