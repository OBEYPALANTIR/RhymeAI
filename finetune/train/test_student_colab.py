"""The student package preserves SFT order/counts and keeps evaluation disjoint."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import make_student_colab as package
from train_teacher import APP_USER, APP_MODEL, APP_END, read_splits, sha


class StudentPackageTests(unittest.TestCase):
    def test_exact_rows_duplicate_counts_and_validation_leakage(self):
        def row(prompt, split, group):
            import hashlib
            return dict(prompt=prompt, completion='answer', task='synonyms', split=split,
                        prompt_sha256=hashlib.sha256(prompt.encode()).hexdigest(), song_id=group)
        rows = [row('training', 'train', 'a'), row('training', 'train', 'a'),
                row('training', 'validation', 'b'), row('validation', 'validation', 'c'),
                row('test', 'test', 'd')]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = root / 'inputs'
            inputs.mkdir()
            expected = {}
            for split, name in [('train', 'train.jsonl'), ('validation', 'val.jsonl'), ('test', 'teacher-test.jsonl')]:
                values = [r for r in rows if r['split'] == split]
                if split != 'test':
                    values = [dict(text=APP_USER+r['prompt']+APP_MODEL+r['completion']+APP_END, task=r['task']) for r in values]
                path = inputs / name
                path.write_text(''.join(json.dumps(r)+'\n' for r in values))
                expected[name] = sha(path)
            records = root / 'records.jsonl'
            records.write_text(''.join(json.dumps(r)+'\n' for r in rows))
            with patch.dict(package.EXPECTED, expected, clear=True):
                result = package.build(inputs, records, root / 'out', 'test-source')
                splits, manifest = read_splits(root / 'out/data')
                self.assertEqual([r['prompt'] for r in splits['train']], ['training', 'training'])
                self.assertEqual([r['prompt'] for r in splits['validation']], ['validation'])
                self.assertEqual([r['prompt'] for r in splits['test']], ['test'])
                self.assertEqual(manifest['validation_leakage_disposition']['removed_rows'], 1)
                notebook = json.loads(Path(result['notebook']).read_text())
                for cell in notebook['cells']:
                    if cell['cell_type'] == 'code':
                        compile(''.join(cell['source']), '<notebook>', 'exec')
                stage = ''.join(notebook['cells'][1]['source']).replace(
                    "/content/rhymeai-12b-package", str(root / 'staged'))
                exec(compile(stage, '<stage>', 'exec'), {})
                exec(compile(stage, '<stage-again>', 'exec'), {})
                self.assertEqual((root / 'staged/train_teacher.py').read_bytes(),
                                 (root / 'out/train_teacher.py').read_bytes())
                (root / 'staged/train_teacher.py').write_text('changed')
                with self.assertRaises(AssertionError):
                    exec(compile(stage, '<corrupt-stage>', 'exec'), {})
                # An edited input must fail before creating another output directory.
                (inputs / 'train.jsonl').write_text('{}\n')
                with self.assertRaisesRegex(ValueError, 'input changed'):
                    package.build(inputs, records, root / 'rejected', 'test-source')
                self.assertFalse((root / 'rejected').exists())


if __name__ == '__main__':
    unittest.main()
