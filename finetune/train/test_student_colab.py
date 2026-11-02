"""The student package preserves SFT order/counts and keeps evaluation disjoint."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock
import types
import subprocess

import make_student_colab as package
from train_teacher import APP_USER, APP_MODEL, APP_END, read_splits, sha, validate_resume_checkpoint


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
                result = package.build(inputs, records, root / 'out', 'test-source', rate=6.73, cap=45)
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
                namespace = {}
                exec(compile(stage, '<stage>', 'exec'), namespace)
                exec(compile(stage, '<stage-again>', 'exec'), namespace)
                # Execute orchestration against a real temporary filesystem;
                # only unavailable Colab services and dependency installation are replaced.
                colab = types.ModuleType('google.colab')
                colab.drive = Mock()
                colab.runtime = Mock()
                google = types.ModuleType('google')
                google.colab = colab
                setup = ''.join(notebook['cells'][2]['source']).replace('/content/drive', str(root / 'drive'))
                with patch.dict('sys.modules', {'google': google, 'google.colab': colab}), \
                     patch('threading.Timer') as timer, patch('subprocess.run') as install:
                    exec(compile(setup, '<setup-fresh>', 'exec'), namespace)
                    budget = (namespace['PERSIST'] / 'budget.json').read_bytes()
                    exec(compile(setup, '<setup-reconnect>', 'exec'), namespace)
                    self.assertEqual((namespace['PERSIST'] / 'budget.json').read_bytes(), budget)
                    self.assertTrue((namespace['source'] / 'train_teacher.py').is_file())
                    # Soft flush has a bounded API timeout; hard release is independent.
                    callbacks = [call.args[1] for call in timer.call_args_list]
                    self.assertIn(colab.runtime.unassign, callbacks)
                    namespace['release_at_deadline']()
                    colab.drive.flush_and_unmount.assert_called_with(timeout_ms=30000)
                    install.side_effect = subprocess.CalledProcessError(1, 'install')
                    with self.assertRaises(subprocess.CalledProcessError):
                        exec(compile(setup, '<setup-install-failure>', 'exec'), namespace)
                    self.assertGreaterEqual(colab.runtime.unassign.call_count, 2)
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

    def test_resume_rejects_partial_optimizer_or_wrong_horizon(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            checkpoint = out / 'checkpoints/checkpoint-10'
            checkpoint.mkdir(parents=True)
            names = ['trainer_state.json', 'training_args.bin', 'optimizer.pt', 'scheduler.pt',
                     'rng_state.pth', 'adapter_config.json', 'adapter_model.safetensors']
            for name in names:
                (checkpoint / name).write_text('saved')
            (checkpoint / 'trainer_state.json').write_text(json.dumps(dict(global_step=10, max_steps=331)))
            (out / 'scheduler-horizon.json').write_text(json.dumps(dict(max_steps=331)))
            self.assertEqual(validate_resume_checkpoint(out, checkpoint), checkpoint.resolve())
            for name in names[1:]:
                path = checkpoint / name
                path.unlink()
                with self.assertRaisesRegex(ValueError, 'Incomplete resume'):
                    validate_resume_checkpoint(out, checkpoint)
                path.write_text('saved')
            (out / 'scheduler-horizon.json').write_text(json.dumps(dict(max_steps=10)))
            with self.assertRaisesRegex(ValueError, 'scheduler state differs'):
                validate_resume_checkpoint(out, checkpoint)


if __name__ == '__main__':
    unittest.main()
