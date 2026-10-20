import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from gguf import GGUFWriter

from . import generate
from .run_gate import main


def metadata_file(path, blocks, embedding):
    writer = GGUFWriter(path, "gemma4")
    writer.add_block_count(blocks)
    writer.add_embedding_length(embedding)
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.close()
    return path


class IncumbentSizeTest(unittest.TestCase):
    def test_cli_selects_same_size_from_metadata_despite_misleading_filename(self):
        for size, blocks, embedding in (("E2B", 35, 1536), ("E4B", 42, 2560)):
            with self.subTest(size=size), tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                candidate = metadata_file(out / ("candidate-E2B.gguf" if size == "E4B" else "candidate-E4B.gguf"), blocks, embedding)
                incumbents = {"E2B": metadata_file(out / "shipped-small.gguf", 35, 1536),
                              "E4B": metadata_file(out / "shipped-large.gguf", 42, 2560)}
                called = []
                def stop_after_selection(target, role, path, offset):
                    called.append((role, path))
                    if role == "incumbent":
                        raise InterruptedError("No inference in this test")
                with patch.object(generate, "INCUMBENTS", incumbents, create=True), patch("gate.run_gate.freeze"), patch("gate.run_gate.freeze_prompts"):
                    with patch("sys.argv", ["run_gate.py", "--candidate", str(candidate), "--out", str(out)]):
                        with patch("gate.run_gate.generate", side_effect=stop_after_selection):
                            with self.assertRaises(InterruptedError):
                                main()
                self.assertEqual(called, [("candidate", candidate), ("incumbent", incumbents[size])])

    def test_mismatched_override_and_unsupported_shape_fail_before_generation(self):
        for blocks, embedding in ((42, 2560), (99, 1536), (35, 2560)):
            with self.subTest(blocks=blocks, embedding=embedding), tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                candidate = metadata_file(out / "candidate-E2B.gguf", blocks, embedding)
                incumbent = metadata_file(out / "incumbent.gguf", 35, 1536)
                with patch("gate.run_gate.freeze"), patch("gate.run_gate.freeze_prompts"):
                    with patch("sys.argv", ["run_gate.py", "--candidate", str(candidate), "--incumbent", str(incumbent), "--out", str(out)]):
                        with patch("gate.run_gate.generate", side_effect=AssertionError("Inference must not start")):
                            with self.assertRaisesRegex(ValueError, "size|shape"):
                                main()


if __name__ == "__main__":
    unittest.main()
