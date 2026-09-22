#!/usr/bin/env python3
"""Orchestration fixtures only: no real SDK, devices, builds, or provider calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
KEY = "synthetic-runtime-secret-12345"
CERT = "a" * 64
FAKE = r'''#!/usr/bin/env python3
import html,json,os,sys,zipfile
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['RECORD'],'a') as f:
 f.write(json.dumps({'name':name,'args':args,'key_env':os.environ.get('GEMINI_TEST_KEY'),'private_env':os.environ.get('gemini_key')})+'\n')
mode=os.environ.get('MODE','')
if name=='adb':
 a=args[2:]
 if a and a[0]=='install' and mode=='install-mismatch': sys.exit('INSTALL_FAILED_UPDATE_INCOMPATIBLE')
 elif a==['get-state']: print('offline' if mode=='offline' else 'device')
 elif a[:3]==['shell','getprop','ro.kernel.qemu']: print('0' if mode=='physical' else '1')
 elif a[:5]==['shell','pm','list','packages','com.rhymeai.app']:
  if mode=='probe-fail': sys.exit(1)
  if mode=='installed': print('package:com.rhymeai.app')
 elif a[:4]==['shell','settings','get','system']: print(os.environ.get('FONT','null'))
 elif a==['shell','cmd','uimode','night']: print('Night mode: '+os.environ.get('NIGHT','auto'))
 elif a[:3]==['shell','cat','/sdcard/rhymeai-window.xml']:
  labels=['New Song','Settings','AI Provider','Paste your API key here...','Save Settings','Settings saved successfully.','Close','Song Title...','Start writing your lyrics here...','Saved','UnBlock','Suggest Next Line','AI-generated','borrowed train','Rephrase','Previewing Rephrase','Cancel']
  print('<hierarchy>'+''.join('<node text="'+html.escape(s,quote=True)+'" bounds="[0,0][100,100]"/>' for s in labels)+'</hierarchy>')
 elif a[:3]==['shell','pidof','com.rhymeai.app']: print('1234')
 elif a and a[0]=='logcat' and '-d' in a:
  if mode=='log-secret': print('synthetic-runtime-secret-12345')
 elif len(a)==2 and a[0]=='shell' and 'read -r key' in a[1]:
  data=sys.stdin.read().rstrip('\n')
  if mode=='input-echo':print(data)
  with open(os.environ['RECORD'],'a') as f:f.write(json.dumps({'runtime_input_matches':data=='synthetic-runtime-secret-12345'})+'\n')
 elif a[:3]==['shell','mktemp','/data/local/tmp/rhymeai-model.XXXXXX']: print('/data/local/tmp/rhymeai-model.fixture')
 elif a[:3]==['shell','am','instrument']: print('OK (1 test)')
elif name=='apksigner':
 if mode=='unsigned':sys.exit(1)
 print('Signer #1 certificate SHA-256 digest: '+('b'*64 if mode=='wrong-signer' else 'a'*64))
elif name=='gradlew':
 root=Path(os.environ['APP_BUILD'])
 if ':app:properties' in args: print('buildDir: '+str(root))
 else:
  for name in ['outputs/apk/release/app-release.apk','outputs/bundle/release/app-release.aab']:
   p=root/name;p.parent.mkdir(parents=True,exist_ok=True)
   with zipfile.ZipFile(p,'w',zipfile.ZIP_DEFLATED) as z:z.writestr('classes.dex','synthetic-runtime-secret-12345' if mode=='artifact-secret' else 'benign fixture')
elif name in ['emulator','xcrun','xcodebuild']:sys.exit('Unexpected platform command')
'''


class ReleaseOrchestrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(SCRIPTS, self.root / "scripts")
        sdk = self.root / "sdk"
        for name in ["platform-tools/adb", "build-tools/36.1.0/apksigner", "build-tools/36.1.0/aapt2", "emulator/emulator"]:
            p = sdk / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(FAKE)
            p.chmod(0o755)
        (self.root / "android").mkdir()
        (self.root / "android/gradlew").write_text(FAKE)
        (self.root / "android/gradlew").chmod(0o755)
        (self.root / "model.gguf").write_bytes(b"GGUFfixture")
        self.record = self.root / "commands.jsonl"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("ANDROID_", "IOS_", "GEMINI_", "SKIP_", "RUN_", "SIMCTL_CHILD_"))}
        self.env.update(ANDROID_HOME=str(sdk), ANDROID_SERIAL="emulator-5554", ANDROID_RELEASE_CERT_SHA256=CERT,
                        RECORD=str(self.record), APP_BUILD=str(self.root / "resolved-build"),
                        LOCAL_GGUF_PATH=str(self.root / "model.gguf"), GEMINI_TEST_KEY=KEY)

    def run_script(self, script, **env):
        self.record.unlink(missing_ok=True)
        return subprocess.run(["bash", str(self.root / "scripts" / script)], env=self.env | env,
                              capture_output=True, text=True, timeout=30)

    def records(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()] if self.record.exists() else []

    def test_rejected_targets_never_build_or_mutate(self):
        scripts = ["android-release-smoke.sh", "android-release-walkthrough.sh", "android-release-visual-audit.sh",
                   "android-release-live-gemini.sh", "android-local-model-smoke.sh"]
        for script in scripts:
            for serial, mode in [("", ""), ("invalid", ""), ("emulator-5554", "offline"),
                                 ("emulator-5554", "installed"), ("emulator-5554", "probe-fail"), ("emulator-5554", "physical")]:
                with self.subTest(script=script, serial=serial, mode=mode):
                    result = self.run_script(script, ANDROID_SERIAL=serial, MODE=mode)
                    self.assertNotEqual(result.returncode, 0)
                    for record in self.records():
                        self.assertEqual(record['name'], 'adb')
                        self.assertIn(record['args'][2:], [["get-state"], ["shell", "getprop", "ro.kernel.qemu"],
                                                          ["shell", "pm", "list", "packages", "com.rhymeai.app"]])

    def test_bad_signer_never_installs(self):
        for mode in ["wrong-signer", "unsigned"]:
            result = self.run_script("android-release-smoke.sh", MODE=mode)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any('install' in r['args'] for r in self.records()))

    def test_local_signature_mismatch_has_no_destructive_retry(self):
        result = self.run_script('android-local-model-smoke.sh', MODE='install-mismatch')
        self.assertNotEqual(result.returncode, 0)
        calls = [r['args'][2:] for r in self.records() if r['name'] == 'adb']
        self.assertEqual(sum(c[0] == 'install' for c in calls), 1)
        self.assertFalse(any(c[0] == 'uninstall' or c[:3] == ['shell', 'pm', 'clear'] for c in calls))
        self.assertIn(['shell', 'rm', '-f', '/data/local/tmp/rhymeai-model.fixture'], calls)

    def test_both_skipped_runs_nothing(self):
        for script in ["verify.sh", "provider-live-smoke.sh"]:
            result = self.run_script(script, SKIP_ANDROID="1", SKIP_IOS="1")
            self.assertEqual(result.returncode, 2)
            self.assertIn("Both platforms are skipped", result.stderr)
            self.assertEqual(self.records(), [])

    def test_existing_visual_output_is_preserved(self):
        out = self.root / "existing"
        out.mkdir()
        (out / "keep").write_text("unchanged")
        result = self.run_script("android-release-visual-audit.sh", ANDROID_VISUAL_OUTPUT_DIR=str(out))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.records(), [])
        self.assertEqual((out / "keep").read_text(), "unchanged")

    def test_original_visual_state_is_restored(self):
        common = self.root / "scripts/android-release-common.sh"
        adb = self.root / "sdk/platform-tools/adb"
        for font in ['null', '1.3']:
            for night in ['auto', 'yes', 'no', 'custom']:
                self.record.unlink(missing_ok=True)
                result = subprocess.run(['bash', '-euo', 'pipefail', '-c',
                    'source "$1"; ADB="$2"; capture_android_visual_state; restore_android_visual_state',
                    'fixture', str(common), str(adb)], env=self.env | {'FONT': font, 'NIGHT': night}, capture_output=True)
                self.assertEqual(result.returncode, 0)
                calls = [r['args'][2:] for r in self.records()]
                self.assertIn(['shell', 'settings', 'delete', 'system', 'font_scale'] if font == 'null' else
                              ['shell', 'settings', 'put', 'system', 'font_scale', font], calls)
                self.assertIn(['shell', 'cmd', 'uimode', 'night', night], calls)

    def test_runtime_key_never_reaches_host_argv_build_env_or_diagnostics(self):
        for mode, status in [('', 0), ('input-echo', 0), ('artifact-secret', 1), ('log-secret', 1)]:
            result = self.run_script('android-release-live-gemini.sh', MODE=mode)
            self.assertEqual(result.returncode, status, result.stdout + result.stderr)
            self.assertNotIn(KEY, result.stdout + result.stderr)
            self.assertNotIn(KEY, json.dumps(self.records()))
            if mode == 'artifact-secret':
                self.assertFalse(any('install' in r.get('args', []) for r in self.records()))
            else:
                self.assertTrue(any(r.get('runtime_input_matches') for r in self.records()))


if __name__ == '__main__':
    unittest.main()
