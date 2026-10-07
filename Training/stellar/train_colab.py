"""Text/tool LoRA for Gemma 4 E2B. Run on a Colab NVIDIA GPU, not on the Mac."""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path

from data_utils import load_records, validate_dataset
from gemma_format import AssistantCollator, tokenize_record


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", default="data")
    parser.add_argument("--output", default="outputs/stellar-gemma-e2b")
    parser.add_argument("--model", default="unsloth/gemma-4-E2B-it")
    parser.add_argument("--max-length", type=int, default=4096)
    parser.add_argument("--epochs", type=float, default=1)
    parser.add_argument("--max-steps", type=int, default=-1)
    parser.add_argument("--learning-rate", type=float, default=5e-5)
    parser.add_argument("--rank", type=int, default=8)
    parser.add_argument("--seed", type=int, default=3407)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--export-gguf", action="store_true")
    args = parser.parse_args(argv)
    if args.max_length < 512 or args.epochs <= 0 or args.rank < 1 or args.max_steps == 0:
        parser.error("Revisa max-length, epochs, rank y max-steps")
    print("[Stellar] Validando los datos", flush=True)
    summary = validate_dataset(args.data)

    # Import Unsloth before torch/transformers so its Gemma KV-sharing fixes are active.
    print("[Stellar] Importando las dependencias de entrenamiento", flush=True)
    from unsloth import FastModel
    import torch
    from datasets import Dataset
    from huggingface_hub import HfApi, hf_hub_download
    from transformers import Trainer, TrainingArguments, set_seed
    from transformers.trainer_utils import get_last_checkpoint

    if not torch.cuda.is_available():
        raise RuntimeError("Activa Entorno de ejecución > Cambiar tipo > GPU en Colab")
    set_seed(args.seed)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    checkpoint = get_last_checkpoint(str(output)) if args.resume else None
    if args.resume and not checkpoint:
        raise RuntimeError("No hay checkpoint para reanudar en " + str(output))
    if not args.resume and ((output / "run_config.json").exists() or get_last_checkpoint(str(output))):
        raise RuntimeError("La carpeta ya contiene un entrenamiento; usa --resume o un --output diferente")

    previous = json.loads((output / "run_config.json").read_text()) if args.resume else None
    if previous:
        if previous["data"] != summary:
            raise RuntimeError("Los datos cambiaron desde el checkpoint")
        for name in ("model", "max_length", "rank", "seed", "learning_rate", "epochs", "max_steps"):
            if previous["arguments"][name] != vars(args)[name]:
                raise RuntimeError(f"--resume requiere el mismo {name}")
    print("[Stellar] Resolviendo el modelo y la plantilla", flush=True)
    model_revision = previous["model_revision"] if previous else HfApi().model_info(args.model).sha
    template_repo = "google/gemma-4-E2B-it"
    template_revision = previous["template_revision"] if previous else HfApi().model_info(template_repo).sha
    template_file = hf_hub_download(template_repo, "chat_template.jinja", revision=template_revision)
    template = Path(template_file).read_text(encoding="utf-8")
    print("[Stellar] Cargando el modelo en GPU", flush=True)
    model, processor = FastModel.from_pretrained(
        model_name=args.model, revision=model_revision, max_seq_length=args.max_length,
        dtype=None, load_in_4bit=True, full_finetuning=False,
    )
    tokenizer = getattr(processor, "tokenizer", processor)
    tokenizer.chat_template = template
    processor.chat_template = template
    if not tokenizer.is_fast:
        raise RuntimeError("Hace falta un tokenizer rápido con offsets para verificar las etiquetas")
    tokenizer.padding_side = "right"
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token
    model = FastModel.get_peft_model(
        model, finetune_vision_layers=False, finetune_language_layers=True,
        finetune_attention_modules=True, finetune_mlp_modules=True,
        r=args.rank, lora_alpha=args.rank * 2, lora_dropout=0, bias="none",
        random_state=args.seed, use_gradient_checkpointing="unsloth",
    )
    for peft_config in model.peft_config.values():
        peft_config.revision = model_revision

    print("[Stellar] Preparando las trayectorias y sus etiquetas", flush=True)
    prepared, report = {}, {}
    for split in ("train", "valid"):
        records = load_records(Path(args.data) / f"{split}.jsonl")
        tokenized, dropped = [], []
        for record in records:
            row = tokenize_record(record, tokenizer, args.max_length)
            if row is None:
                dropped.append(record["task_key"])
            else:
                tokenized.append(row)
        if not tokenized or len(dropped) / len(records) > 0.1:
            raise RuntimeError(f"{split}: {len(dropped)}/{len(records)} ejemplos largos. Aumenta --max-length; no se truncarán")
        prepared[split] = Dataset.from_list(tokenized)
        report[split] = {"kept": len(tokenized), "dropped": dropped,
                         "max_tokens": max(len(r["input_ids"]) for r in tokenized),
                         "supervised_tokens": sum(sum(t != -100 for t in r["labels"]) for r in tokenized)}
    (output / "tokenization_report.json").write_text(json.dumps(report, indent=2))
    versions = {name: importlib.metadata.version(name) for name in
                ("torch", "transformers", "unsloth", "unsloth_zoo", "peft", "datasets", "bitsandbytes")}
    config = {"arguments": vars(args), "data": summary, "versions": versions,
              "model_revision": model_revision, "template_revision": template_revision,
              "template_sha256": hashlib.sha256(template.encode()).hexdigest(),
              "gpu": torch.cuda.get_device_name(), "tokenization": report}
    (output / "run_config.json").write_text(json.dumps(config, indent=2, ensure_ascii=False))
    print(json.dumps({"gpu": config["gpu"], "data": report}, indent=2), flush=True)
    # Inspect labels before spending GPU time; tool result text must be absent here.
    sample = prepared["train"][0]
    print("TOKENS QUE SE ENTRENAN:\n" + tokenizer.decode([i for i in sample["labels"] if i != -100]), flush=True)

    interval = min(50, max(1, args.max_steps // 2)) if args.max_steps > 0 else 50
    print("[Stellar] Configurando el entrenador", flush=True)
    trainer = Trainer(
        model=model, processing_class=tokenizer, data_collator=AssistantCollator(tokenizer),
        train_dataset=prepared["train"], eval_dataset=prepared["valid"],
        args=TrainingArguments(
            output_dir=str(output), per_device_train_batch_size=1, per_device_eval_batch_size=1,
            gradient_accumulation_steps=4, num_train_epochs=args.epochs, max_steps=args.max_steps,
            learning_rate=args.learning_rate, warmup_ratio=0.05, weight_decay=0.01,
            optim="adamw_8bit", lr_scheduler_type="cosine", max_grad_norm=0.3,
            bf16=torch.cuda.is_bf16_supported(), fp16=not torch.cuda.is_bf16_supported(),
            logging_steps=1, eval_strategy="steps", eval_steps=interval,
            save_strategy="steps", save_steps=interval, save_total_limit=2,
            load_best_model_at_end=True, metric_for_best_model="eval_loss", greater_is_better=False,
            report_to="none", seed=args.seed, data_seed=args.seed,
            remove_unused_columns=False, label_names=["labels"],
        ),
    )
    if not args.resume:
        print("[Stellar] Midiendo la pérdida antes de entrenar", flush=True)
        before = trainer.evaluate()
        (output / "metrics_before.json").write_text(json.dumps(before, indent=2))
    print("[Stellar] Entrenando", flush=True)
    result = trainer.train(resume_from_checkpoint=checkpoint)
    print("[Stellar] Evaluando y guardando el adaptador", flush=True)
    after = trainer.evaluate()
    trainer.save_metrics("train", result.metrics)
    trainer.save_metrics("eval", after)
    adapter = output / "adapter"
    model.save_pretrained(str(adapter))
    processor.save_pretrained(str(adapter))
    print("Adaptador guardado en", adapter, flush=True)
    if args.export_gguf:
        export_model(model, processor, output)


def export_model(model, processor, output: Path):
    from ollama_import import write_modelfile
    destination = output / "gguf"
    model.save_pretrained_gguf(str(destination), processor, quantization_method="Q8_0")
    # Some exporters append the quantization to the output directory name.
    files = [p for p in output.rglob("*.gguf") if not any(tag in p.name.lower() for tag in ("mmproj", "mtp"))]
    if not files:
        raise RuntimeError("La exportación no produjo un GGUF de lenguaje")
    files.sort(key=lambda p: ("q8_0" not in str(p).lower(), str(p)))
    write_modelfile(files[0], files[0].parent / "Modelfile")
    print("GGUF y Modelfile:", files[0].parent, flush=True)


if __name__ == "__main__":
    main()
