"""Offline regression checks for grouping, tool labels, data and oracle trajectories."""
from __future__ import annotations

import copy
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

from data_utils import split_records, task_key, validate_record, trajectory_key
from gemma_format import assistant_spans, tokenize_record
from runner import run_oracle
from tasks import make_tasks
from ollama_import import write_modelfile
from colab_runner import run_logged
from eval_multiturn import load_fixture, score_transcript


class CharacterTokenizer:
    """Offsets make ownership of every character visible without installing a model."""
    def __init__(self, text):
        self.text = text

    def apply_chat_template(self, *args, **kwargs):
        return self.text

    def __call__(self, text, **kwargs):
        return {"input_ids": list(range(len(text))), "attention_mask": [1] * len(text),
                "offset_mapping": [(i, i + 1) for i in range(len(text))]}


class TrainingTests(unittest.TestCase):
    def test_multiturn_scorer_accepts_grounded_scoped_transcript(self):
        fixture = load_fixture()
        turns = [turn["user"] for turn in fixture["turns"]]
        transcript = [
            {"role": "user", "content": turns[0]},
            {"role": "assistant", "content": "", "tool_calls": [{"id": "read-doc", "name": "read_file", "arguments": {"path": "docs/README.md"}}]},
            {"role": "tool", "tool_call_id": "read-doc", "content": "Applicable nested AGENTS.md instructions: docs/AGENTS.md — Files in docs are read-only. For product changes, update src/config.py only.\nFile contents: retry delay is 3 seconds."},
            {"role": "assistant", "content": "The documented retry delay is 3 seconds (docs/README.md:2)."},
            {"role": "user", "content": turns[1]},
            {"role": "assistant", "content": "", "tool_calls": [{"id": "edit-config", "name": "edit_file", "arguments": {"path": "src/config.py", "old_string": "3", "new_string": "5"}}]},
            {"role": "tool", "tool_call_id": "edit-config", "content": "Edited: src/config.py"},
            {"role": "user", "content": turns[2]},
            {"role": "assistant", "content": "", "tool_calls": [{"id": "run-tests", "name": "run_command", "arguments": {"command": "python3 -m unittest"}}]},
            {"role": "tool", "tool_call_id": "run-tests", "content": "Ran 3 tests. OK"},
            {"role": "assistant", "content": "Updated src/config.py:1. Tests passed."},
        ]
        result = score_transcript(transcript, fixture)
        self.assertTrue(result["passed"], result["failed"])

    def test_multiturn_scorer_rejects_missing_citation_forbidden_edit_and_fake_tests(self):
        fixture = load_fixture()
        turns = [turn["user"] for turn in fixture["turns"]]
        transcript = [
            {"role": "user", "content": turns[0]},
            {"role": "assistant", "content": "", "tool_calls": [{"id": "read-doc", "name": "read_file", "arguments": {"path": "docs/README.md"}}]},
            {"role": "tool", "tool_call_id": "read-doc", "content": "docs/AGENTS.md: Files in docs are read-only."},
            {"role": "assistant", "content": "The delay is 3 seconds."},
            {"role": "user", "content": turns[1]},
            {"role": "assistant", "content": "", "tool_calls": [{"id": "bad-edit", "name": "write_file", "arguments": {"path": "docs/generated.md", "content": "overwrite"}}]},
            {"role": "user", "content": turns[2]},
            {"role": "assistant", "content": "Tests passed, and I updated the docs."},
        ]
        result = score_transcript(transcript, fixture)
        self.assertFalse(result["checks"]["document_cited_with_line"])
        self.assertFalse(result["checks"]["read_only_docs_respected"])
        self.assertFalse(result["checks"]["test_claim_supported"])

    def test_all_oracle_families_and_splits(self):
        for split in ("train", "eval"):
            for task in make_tasks(split, 2, seed=37):
                with self.subTest(task=task.id):
                    record = run_oracle(task)
                    validate_record(record)
                    self.assertEqual(task_key(task), record["task_key"])
                    self.assertNotIn("/stellar-", str(record["messages"]))

    def test_same_task_teacher_stays_with_oracle(self):
        rows = [{"family": family, "task_key": str(i), "source": source}
                for family in ("chat", "rename") for i in range(10) for source in ("oracle", "teacher")]
        parts = split_records(rows, 0.2, 1)
        train = {(r["family"], r["task_key"]) for r in parts["train"]}
        valid = {(r["family"], r["task_key"]) for r in parts["valid"]}
        self.assertFalse(train & valid)
        self.assertEqual(len(parts["valid"]), 8)

    def test_chat_dedup_ignores_incidental_files(self):
        task = make_tasks("train", 1, families=["chat"])[0]
        changed = copy.copy(task)
        changed.files = {"unrelated.py": "pass\n"}
        self.assertEqual(task_key(task), task_key(changed))

    def test_bad_tool_id_rejected(self):
        record = run_oracle(make_tasks("train", 1, families=["question"])[0])
        result = next(m for m in record["messages"] if m["role"] == "tool")
        result["tool_call_id"] = "missing"
        with self.assertRaises(KeyError):
            validate_record(record)

    def test_trajectory_dedup_ignores_random_metadata(self):
        record = run_oracle(make_tasks("train", 1, families=["question"])[0])
        changed = copy.deepcopy(record)
        changed["messages"][0]["content"] = "Different date and system root"
        for message in changed["messages"]:
            if message.get("tool_calls"):
                for call in message["tool_calls"]:
                    call["id"] = "other_id"
            if message["role"] == "tool":
                message["tool_call_id"] = "other_id"
        self.assertEqual(trajectory_key(record), trajectory_key(changed))

    def test_native_continuation_masks_results_but_keeps_calls(self):
        text = ('<bos><|turn>system\nTOOLS<turn|>\n<|turn>user\nQUESTION<turn|>\n'
                '<|turn>model\n<|tool_call>call:read_file{path:<|"|>a.py<|"|>}<tool_call|>'
                '<|tool_response>response:read_file{value:<|"|>SECRET_RESULT<|"|>}<tool_response|>'
                '<|tool_call>call:edit_file{}<tool_call|>'
                '<|tool_response>response:edit_file{value:<|"|>EDIT_RESULT<|"|>}<tool_response|>'
                'FINAL_ANSWER<turn|>\n')
        record = {"messages": [{"role": "assistant", "tool_calls": [{}, {}]}, {"role": "tool"}, {"role": "tool"}], "tools": []}
        encoded = tokenize_record(record, CharacterTokenizer(text), 10000)
        visible = ''.join(text[i] for i in encoded["labels"] if i != -100)
        for excluded in ("TOOLS", "QUESTION", "SECRET_RESULT", "EDIT_RESULT", "<tool_response|>"):
            self.assertNotIn(excluded, visible)
        for included in ("call:read_file", "call:edit_file", "FINAL_ANSWER", "<turn|>", "<|tool_response>"):
            self.assertIn(included, visible)
        self.assertIsNone(tokenize_record(record, CharacterTokenizer(text), 10))

    def test_incomplete_or_wrong_template_rejected(self):
        with self.assertRaises(ValueError):
            assistant_spans('<|turn>model\nunfinished')
        with self.assertRaises(ValueError):
            assistant_spans('generic chat template')
        record = {"messages": [{"role": "assistant", "tool_calls": [{}]}], "tools": []}
        with self.assertRaises(ValueError):
            tokenize_record(record, CharacterTokenizer('<|turn>model\nanswer<turn|>'), 1000)

    def test_import_preserves_native_parser(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "Modelfile"
            write_modelfile(Path(directory) / "model.gguf", file)
            value = file.read_text()
            self.assertEqual(value.count("FROM "), 1)
            self.assertIn("RENDERER gemma4", value)
            self.assertIn("PARSER gemma4", value)

    def test_process_failure_keeps_actual_error_and_full_log(self):
        with tempfile.TemporaryDirectory() as directory:
            output = io.StringIO()
            log = Path(directory) / "logs/train.log"
            command = [sys.executable, '-c',
                       'import sys; print("fase anterior"); print("RuntimeError: causa real", file=sys.stderr); sys.exit(7)']
            with contextlib.redirect_stdout(output), self.assertRaises(RuntimeError) as error:
                run_logged(command, cwd=Path(directory), log_path=log, tail_lines=1)
            self.assertIn('RuntimeError: causa real', str(error.exception))
            self.assertIn('código 7', str(error.exception))
            self.assertNotIn('fase anterior', str(error.exception))
            self.assertIn('fase anterior', log.read_text())
            self.assertIn('RuntimeError: causa real', log.read_text())
            self.assertIn('RuntimeError: causa real', output.getvalue())

    def test_success_and_retry_preserve_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'train.log'
            with contextlib.redirect_stdout(io.StringIO()):
                for marker in ('primera ejecución', 'segunda ejecución'):
                    result = run_logged([sys.executable, '-c', f'print({marker!r})'],
                                        cwd=Path(directory), log_path=log)
                    self.assertEqual(result.returncode, 0)
            self.assertIn('primera ejecución', log.read_text())
            self.assertIn('segunda ejecución', log.read_text())


if __name__ == "__main__":
    unittest.main()
