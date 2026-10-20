"""The 12B teacher must train and evaluate on exactly the app's Gemma 4 prompt.

Run: python3 -m unittest discover -s finetune/train -p 'test_*.py'
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import train_teacher  # noqa: E402
from test_envelope import SAMPLE_PROMPT, swift_gemma_prompt  # noqa: E402


class FakeTokenizer:
    """Lossless stand-in: each special marker is one id, every other character
    is its own id. Never adds <bos> on its own (like Gemma 4's HF tokenizer),
    so the prompt text must carry it."""

    specials = ["<bos>", "<|turn>", "<turn|>", "<|channel>", "<channel|>", "<pad>"]
    bos_token = "<bos>"
    bos_token_id = 0
    pad_token_id = 5

    def convert_tokens_to_ids(self, token):
        return self.specials.index(token)

    def encode(self, text, add_special_tokens=False):
        assert add_special_tokens is False
        ids, i = [], 0
        while i < len(text):
            for index, special in enumerate(self.specials):
                if text.startswith(special, i):
                    ids.append(index)
                    i += len(special)
                    break
            else:
                ids.append(len(self.specials) + ord(text[i]))
                i += 1
        return ids

    def __call__(self, text, add_special_tokens=False, truncation=False, **kwargs):
        return {"input_ids": self.encode(text, add_special_tokens)}

    def decode(self, ids, skip_special_tokens=False):
        return "".join(self.specials[i] if i < len(self.specials) else chr(i - len(self.specials))
                       for i in ids)


class TeacherPromptTests(unittest.TestCase):
    def setUp(self):
        self.tokenizer = FakeTokenizer()

    def test_prompt_is_bos_plus_app_envelope_bytes(self):
        text = train_teacher.prompt_text(self.tokenizer, SAMPLE_PROMPT)
        expected = "<bos>" + swift_gemma_prompt(SAMPLE_PROMPT, "gemma4")
        self.assertEqual(text.encode("utf-8"), expected.encode("utf-8"))
        for marker in ("<|channel>", "<channel|>", "<start_of_turn>", "<end_of_turn>"):
            self.assertNotIn(marker, text)

    def test_prompt_is_not_trimmed(self):
        padded = "  " + SAMPLE_PROMPT + "\n\n"
        text = train_teacher.prompt_text(self.tokenizer, padded)
        self.assertEqual(text, "<bos>" + swift_gemma_prompt(padded, "gemma4"))

    def test_masked_prefix_is_exactly_the_app_prompt(self):
        row = {"prompt": SAMPLE_PROMPT, "completion": "Line one\nLine two"}
        example = train_teacher.supervised_row(self.tokenizer, row)
        masked = sum(label == -100 for label in example["labels"])
        prefix = self.tokenizer.decode(example["input_ids"][:masked])
        self.assertEqual(prefix, "<bos>" + swift_gemma_prompt(SAMPLE_PROMPT, "gemma4"))
        self.assertEqual(example["input_ids"][:1], [self.tokenizer.bos_token_id])
        self.assertEqual(example["input_ids"].count(self.tokenizer.bos_token_id), 1)
        self.assertEqual(self.tokenizer.decode(example["labels"][masked:]),
                         row["completion"] + "<turn|>")
        self.assertEqual(example["labels"][masked:], example["input_ids"][masked:])

    def test_rejects_prefix_with_thought_channel_or_extra_bos(self):
        class Twice(FakeTokenizer):
            bos_token = "<bos><bos>"

        class Thinking(FakeTokenizer):
            bos_token = "<bos><|channel>thought\n<channel|>"

        row = {"prompt": SAMPLE_PROMPT, "completion": "x"}
        for tokenizer in (Twice(), Thinking()):
            with self.assertRaises(ValueError):
                train_teacher.supervised_row(tokenizer, row)


if __name__ == "__main__":
    unittest.main()
