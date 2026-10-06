"""Training text must start with exactly the prompt the app tokenizes.

Run: python3 -m unittest discover -s finetune/train -p 'test_*.py'
"""

import ast
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FINETUNE = os.path.dirname(HERE)
REPO = os.path.dirname(FINETUNE)
for path in (HERE, FINETUNE):
    if path not in sys.path:
        sys.path.insert(0, path)

import prepare_dataset  # noqa: E402
from eval import prompts  # noqa: E402

SWIFT_SERVICE = os.path.join(REPO, "Writers Block", "Writers Block", "Services",
                             "GGUFModelService.swift")

SAMPLE_PROMPT = (
    'Lyrics context:\n"""\nNeon on the river, I’m counting every light\n"""\n'
    "Write 6 different next lines.\nReturn only the lines.")
COMPLETION = "Line one\nLine two"


def swift_gemma_prompt(user_prompt, prompt_format):
    """Independent transcription of GGUFModelService.gemmaPrompt
    ("Writers Block/Writers Block/Services/GGUFModelService.swift" lines
    469-491), the oracle every training row is compared against."""
    if prompt_format == "gemmaLegacy":
        user_marker = "<start_of_turn>user\n"
        model_marker = "\n<end_of_turn>\n<start_of_turn>model"
    elif prompt_format == "gemma4":
        user_marker = "<|turn>user\n"
        model_marker = "<turn|>\n<|turn>model"
    else:
        raise ValueError(prompt_format)
    content = user_prompt
    while content.startswith(user_marker):
        normalized = content[:-1] if content.endswith(model_marker + "\n") else content
        if not normalized.endswith(model_marker):
            break
        content = normalized[len(user_marker):len(normalized) - len(model_marker)]
    return user_marker + content + model_marker + ("\n" if prompt_format == "gemma4" else "")


def train_lora_symbols():
    """ENVELOPES and dataset_envelope from train_lora.py without importing
    unsloth (the script runs alone on the GPU box)."""
    with open(os.path.join(HERE, "train_lora.py"), encoding="utf-8") as handle:
        module = ast.parse(handle.read())
    wanted = [node for node in module.body
              if (isinstance(node, ast.Assign) and node.targets[0].id == "ENVELOPES")
              or (isinstance(node, ast.FunctionDef) and node.name == "dataset_envelope")]
    namespace = {"json": json}
    exec(compile(ast.Module(body=wanted, type_ignores=[]), "train_lora.py", "exec"), namespace)
    return namespace


def notebook_constants():
    with open(os.path.join(HERE, "colab_train_gemma.ipynb"), encoding="utf-8") as handle:
        cells = json.load(handle)["cells"]
    for cell in cells:
        source = "".join(cell["source"])
        if cell["cell_type"] == "code" and "INSTRUCTION_PART =" in source:
            values = {}
            for node in ast.parse(source).body:
                if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
                    try:
                        values[node.targets[0].id] = ast.literal_eval(node.value)
                    except ValueError:
                        pass
            return values
    raise AssertionError("notebook defines no INSTRUCTION_PART")


class EnvelopeTests(unittest.TestCase):
    def test_gemma4_row_is_app_prompt_then_completion(self):
        text = prepare_dataset.build_text(SAMPLE_PROMPT, COMPLETION)
        expected = swift_gemma_prompt(SAMPLE_PROMPT, "gemma4") + COMPLETION + "<turn|>"
        self.assertEqual(text.encode("utf-8"), expected.encode("utf-8"))
        self.assertEqual(text, "<|turn>user\n" + SAMPLE_PROMPT + "<turn|>\n<|turn>model\n"
                         + COMPLETION + "<turn|>")

    def test_gemma4_row_has_no_bos_thought_channel_or_legacy_markers(self):
        text = prepare_dataset.build_text(SAMPLE_PROMPT, COMPLETION)
        for marker in ("<bos>", "<|channel>", "<channel|>", "<start_of_turn>", "<end_of_turn>"):
            self.assertNotIn(marker, text)

    def test_masked_prefix_is_exactly_the_app_prompt(self):
        for envelope in prompts.ENVELOPES.values():
            text = prepare_dataset.build_text(SAMPLE_PROMPT, COMPLETION, envelope)
            instruction, response = prepare_dataset.masking_markers(envelope)
            self.assertTrue(text.startswith(instruction))
            self.assertEqual(text.count(response), 1)
            prefix = text[:text.index(response) + len(response)]
            app = swift_gemma_prompt(SAMPLE_PROMPT, envelope.name)
            self.assertTrue(prefix.startswith(app))
            # Gemma 4: the masked prompt is the app prompt, byte for byte.
            # Legacy: the app stops at "<start_of_turn>model", the turn's newline follows.
            self.assertEqual(prefix, app if envelope is prompts.GEMMA4 else app + "\n")
            self.assertEqual(text[len(prefix):], COMPLETION + envelope.end_of_turn)

    def test_legacy_rows_keep_their_previous_bytes(self):
        text = prepare_dataset.build_text(SAMPLE_PROMPT, COMPLETION, prompts.GEMMA_LEGACY)
        self.assertEqual(text, "<start_of_turn>user\n" + SAMPLE_PROMPT
                         + "\n<end_of_turn>\n<start_of_turn>model\n" + COMPLETION + "<end_of_turn>")
        self.assertEqual(prompts.gemma_instruction_prompt(SAMPLE_PROMPT),
                         swift_gemma_prompt(SAMPLE_PROMPT, "gemmaLegacy"))

    def test_app_prompt_mirrors_swift_rule(self):
        for name, envelope in prompts.ENVELOPES.items():
            once = swift_gemma_prompt(SAMPLE_PROMPT, name)
            for value in ("", "x", "a\nb\n", SAMPLE_PROMPT, once, once + "\n",
                          swift_gemma_prompt(once, name), envelope.user_marker,
                          "<|turn>user\nhi<turn|>\n<|turn>model\n",
                          "<start_of_turn>user\nhi\n<end_of_turn>\n<start_of_turn>model"):
                self.assertEqual(prompts.app_prompt(value, envelope), swift_gemma_prompt(value, name))
            self.assertEqual(prompts.app_prompt(once, envelope), once)

    def test_resolve_matches_swift_routing(self):
        # Writers BlockTests/GGUFRoutingTests.swift lines 28-39.
        legacy, gemma4 = "<start_of_turn>user <end_of_turn>", "<|turn>user <turn|>"
        resolve = prompts.resolve_prompt_envelope
        self.assertIs(resolve("gemma4", gemma4), prompts.GEMMA4)
        for architecture in ("gemma", "gemma2", "gemma3", "gemma3n"):
            self.assertIs(resolve(architecture, legacy), prompts.GEMMA_LEGACY)
            self.assertIsNone(resolve(architecture, gemma4))
        self.assertIsNone(resolve("gemma4", legacy))
        self.assertIsNone(resolve("gemma4", gemma4 + legacy))
        self.assertIsNone(resolve("llama", gemma4))
        self.assertIsNone(resolve("gemma4", ""))

    def test_swift_source_still_renders_these_envelopes(self):
        if not os.path.exists(SWIFT_SERVICE):
            self.skipTest("Swift source not in this checkout")
        with open(SWIFT_SERVICE, encoding="utf-8") as handle:
            swift = handle.read()
        literal = r'"((?:[^"\\]|\\.)*)"'
        found = {case: (json.loads('"%s"' % user), json.loads('"%s"' % model))
                 for case, user, model in re.findall(
                     r"case \.(gemmaLegacy|gemma4):\s*userMarker = " + literal
                     + r"\s*modelMarker = " + literal, swift)}
        self.assertEqual(found, {name: (envelope.user_marker, envelope.model_marker)
                                 for name, envelope in prompts.ENVELOPES.items()})
        self.assertIn('(format == .gemma4 ? "\\n" : "")', swift)
        self.assertIn('case "gemma4" where hasGemma4Turns && !hasLegacyTurns:', swift)
        self.assertIn('case "gemma", "gemma2", "gemma3", "gemma3n":', swift)
        # llama.cpp adds <bos>; the app never writes one.
        self.assertIn("static let addSpecialTokens = true", swift)
        self.assertNotIn("<bos>", swift)

    def test_trainer_and_notebook_use_the_same_markers(self):
        lora = train_lora_symbols()["ENVELOPES"]
        self.assertEqual(set(lora), set(prompts.ENVELOPES))
        for name, envelope in prompts.ENVELOPES.items():
            markers = lora[name]
            self.assertEqual((markers["instruction_part"], markers["response_part"]),
                             prepare_dataset.masking_markers(envelope))
            first, last = markers["special_tokens"]
            self.assertTrue(envelope.user_marker.startswith(first))
            self.assertEqual(last, envelope.end_of_turn)
        notebook = notebook_constants()
        self.assertEqual((notebook["INSTRUCTION_PART"], notebook["RESPONSE_PART"]),
                         prepare_dataset.masking_markers(prompts.GEMMA4))
        self.assertEqual(notebook["SPECIAL_TOKENS"], lora["gemma4"]["special_tokens"])

    def test_trainer_detects_the_dataset_envelope(self):
        detect = train_lora_symbols()["dataset_envelope"]
        with tempfile.TemporaryDirectory() as tmp:
            def write(name, envelopes):
                path = os.path.join(tmp, name)
                with open(path, "w", encoding="utf-8") as handle:
                    for envelope in envelopes:
                        text = prepare_dataset.build_text(SAMPLE_PROMPT, COMPLETION, envelope)
                        handle.write(json.dumps({"text": text}) + "\n")
                return path
            gemma4 = write("g4.jsonl", [prompts.GEMMA4] * 2)
            legacy = write("legacy.jsonl", [prompts.GEMMA_LEGACY])
            self.assertEqual(detect([gemma4]), "gemma4")
            self.assertEqual(detect([legacy]), "gemmaLegacy")
            with self.assertRaises(SystemExit):
                detect([gemma4, legacy])

    def test_cli_defaults_to_gemma4_and_rejects_wrapped_prompts(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = os.path.join(tmp, "in.jsonl")
            with open(source, "w", encoding="utf-8") as handle:
                for index in range(4):
                    handle.write(json.dumps({"task": "suggestions", "case_seed": str(index),
                                             "user_prompt": "%s %d" % (SAMPLE_PROMPT, index),
                                             "completion": COMPLETION}, ensure_ascii=False) + "\n")
            command = [sys.executable, os.path.join(HERE, "prepare_dataset.py"),
                       "--in", source, "--out-dir", os.path.join(tmp, "out")]
            subprocess.run(command, check=True, capture_output=True)
            rows = []
            for name in ("train.jsonl", "val.jsonl"):
                with open(os.path.join(tmp, "out", name), encoding="utf-8") as handle:
                    rows += [json.loads(line) for line in handle]
            self.assertEqual(sorted(row["case_seed"] for row in rows), ["0", "1", "2", "3"])
            for row in rows:
                user_prompt = "%s %s" % (SAMPLE_PROMPT, row["case_seed"])
                self.assertEqual(row["text"], swift_gemma_prompt(user_prompt, "gemma4")
                                 + COMPLETION + "<turn|>")

            with open(source, "w", encoding="utf-8") as handle:
                handle.write(json.dumps({"task": "suggestions", "completion": COMPLETION,
                                         "user_prompt": prompts.gemma_instruction_prompt("x")}) + "\n")
            failed = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("inner prompt", failed.stderr)


if __name__ == "__main__":
    unittest.main()
