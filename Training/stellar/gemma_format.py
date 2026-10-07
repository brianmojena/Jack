"""Supervise native Gemma tool calls and assistant text, never tool result bodies."""
from __future__ import annotations

import re

TURN = re.compile(r"<\|turn>(system|developer|user|model|assistant)\n|<turn\|>")
TOOL_RESPONSE = re.compile(r"<\|tool_response>.*?<tool_response\|>", re.DOTALL)


def assistant_spans(text: str) -> list[tuple[int, int]]:
    spans = []
    start = None
    for match in TURN.finditer(text):
        if match.group(1):
            if start is not None:
                raise ValueError("Turno de asistente sin cerrar")
            start = match.end() if match.group(1) in {"model", "assistant"} else None
        elif start is not None:
            spans.append((start, match.end()))
            start = None
    if start is not None:
        raise ValueError("La conversación de entrenamiento debe estar cerrada")
    if not spans:
        raise ValueError("La plantilla no contiene turnos de Gemma 4")
    return spans


def tokenize_record(record: dict, tokenizer, max_length: int) -> dict | None:
    text = tokenizer.apply_chat_template(record["messages"], tools=record["tools"],
                                         tokenize=False, add_generation_prompt=False, enable_thinking=False)
    calls = sum(len(m.get("tool_calls", [])) for m in record["messages"])
    outputs = sum(m["role"] == "tool" for m in record["messages"])
    if text.count("<|tool_call>") != calls or text.count("<tool_response|>") != outputs:
        raise ValueError("La plantilla perdió llamadas o resultados de herramientas; no entrenar así")
    encoded = tokenizer(text, add_special_tokens=False, return_offsets_mapping=True, truncation=False)
    if len(encoded["input_ids"]) > max_length:
        return None  # Never train on a truncated, incomplete tool trajectory.
    spans = assistant_spans(text)
    # The opening tool_response is the model's hand-off token; its body and closing delimiter are input.
    excluded = [(m.start() + len("<|tool_response>"), m.end()) for m in TOOL_RESPONSE.finditer(text)]
    labels = []
    for token, (a, b) in zip(encoded["input_ids"], encoded["offset_mapping"]):
        supervise = b > a and any(a >= x and b <= y for x, y in spans)
        supervise = supervise and not any(a < y and b > x for x, y in excluded)
        labels.append(token if supervise else -100)
    if not any(label != -100 for label in labels):
        raise ValueError("Ejemplo sin tokens supervisados")
    return {"input_ids": encoded["input_ids"], "attention_mask": encoded["attention_mask"], "labels": labels}


class AssistantCollator:
    def __init__(self, tokenizer):
        self.tokenizer = tokenizer

    def __call__(self, features):
        import torch
        length = ((max(len(f["input_ids"]) for f in features) + 7) // 8) * 8
        rows = {key: [] for key in ("input_ids", "attention_mask", "labels")}
        for feature in features:
            pad = length - len(feature["input_ids"])
            rows["input_ids"].append(feature["input_ids"] + [self.tokenizer.pad_token_id] * pad)
            rows["attention_mask"].append(feature["attention_mask"] + [0] * pad)
            rows["labels"].append(feature["labels"] + [-100] * pad)
        return {key: torch.tensor(value, dtype=torch.long) for key, value in rows.items()}
