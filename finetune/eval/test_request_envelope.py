"""The eval harness and data generator send llama-server the app's exact
request: the inner prompt in the app's turn envelope, with no <bos>.

Run: python3 -m unittest discover -s finetune -p 'test_*.py'
"""

import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FINETUNE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if FINETUNE not in sys.path:
    sys.path.insert(0, FINETUNE)

from eval import cases, prompts, run_eval  # noqa: E402
from data import generate, teacher  # noqa: E402

GEMMA4_TEMPLATE = "{{ bos_token }}<|turn>{{ role }}\n{{ content }}<turn|>\n"
LEGACY_TEMPLATE = "{{ bos_token }}<start_of_turn>{{ role }}\n{{ content }}<end_of_turn>\n"


def app_request(user_prompt):
    """GGUFModelService.gemmaPrompt for a Gemma 4 model ("Writers Block/Writers
    Block/Services/GGUFModelService.swift" lines 476-478 and 490)."""
    return "<|turn>user\n" + user_prompt + "<turn|>\n<|turn>model\n"


def old_request(user_prompt):
    """What the harness and generator sent before (the legacy wrapper)."""
    return "<start_of_turn>user\n" + user_prompt + "\n<end_of_turn>\n<start_of_turn>model"


def sample_cases():
    """The first eval case of each task."""
    first = {}
    for case in cases.CASES:
        first.setdefault(case["task"], case)
    return list(first.values())


class FakeLlamaServer:
    """Records requests; answers /props, /completion and /v1/chat/completions."""

    def __init__(self, chat_template=GEMMA4_TEMPLATE):
        self.requests = []
        recorded = self.requests

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                recorded.append(("GET", self.path, None))
                self.reply({"chat_template": chat_template, "bos_token": "<bos>"})

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                recorded.append(("POST", self.path, body))
                if self.path == "/completion":
                    self.reply({"content": "glow", "tokens_predicted": 1})
                else:
                    self.reply({"choices": [{"message": {"content": "glow"}}]})

            def reply(self, payload):
                data = json.dumps(payload).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.url = "http://127.0.0.1:%d" % self.port

    def __enter__(self):
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()

    def last_post(self):
        return [r for r in self.requests if r[0] == "POST"][-1]


class RequestEnvelopeTests(unittest.TestCase):
    def test_eval_request_is_the_app_envelope_byte_for_byte(self):
        with FakeLlamaServer() as server:
            for case in sample_cases():
                prepared = run_eval.prepare_case(case)
                user_prompt = prepared["user_prompt"]
                self.assertFalse(any(m in user_prompt for m in prompts.TURN_MARKERS))
                text = run_eval.request_text(prepared, prompts.GEMMA4)
                run_eval.completion(server.port, text, [prompts.GEMMA4.end_of_turn])
                _, path, body = server.last_post()
                self.assertEqual(path, "/completion")
                self.assertEqual(body["prompt"].encode("utf-8"),
                                 app_request(user_prompt).encode("utf-8"))
                self.assertEqual(body["stop"], ["<turn|>"])
                self.assertNotIn("<bos>", body["prompt"])

    def test_eval_legacy_option_reproduces_the_old_request(self):
        legacy = prompts.ENVELOPE_OPTIONS["legacy"]
        for case in sample_cases():
            prepared = run_eval.prepare_case(case)
            self.assertEqual(run_eval.request_text(prepared, legacy),
                             old_request(prepared["user_prompt"]))
        self.assertEqual(legacy.end_of_turn, "<end_of_turn>")  # the old STOP

    def test_teacher_completion_sends_the_app_envelope(self):
        user_prompt = run_eval.prepare_case(sample_cases()[0])["user_prompt"]
        with FakeLlamaServer() as server:
            client = teacher.TeacherClient(server.url, api="completion", retries=0)
            self.assertEqual(client.generate(user_prompt, seed=7), "glow")
            _, path, body = server.last_post()
        self.assertEqual(path, "/completion")
        self.assertEqual(body["prompt"].encode("utf-8"), app_request(user_prompt).encode("utf-8"))
        self.assertEqual((body["stop"], body["seed"]), (["<turn|>"], 7))

    def test_teacher_legacy_option_reproduces_the_old_request(self):
        user_prompt = run_eval.prepare_case(sample_cases()[0])["user_prompt"]
        with FakeLlamaServer(LEGACY_TEMPLATE) as server:
            client = teacher.TeacherClient(server.url, api="completion", retries=0,
                                           envelope=prompts.ENVELOPE_OPTIONS["legacy"])
            client.generate(user_prompt)
            _, _, body = server.last_post()
        self.assertEqual(body["prompt"], old_request(user_prompt))
        self.assertEqual(body["stop"], ["<end_of_turn>"])

    def test_teacher_chat_sends_the_inner_prompt_unwrapped(self):
        # /v1/chat/completions applies the GGUF's own template server-side;
        # wrapping here would double the turn markers.
        user_prompt = run_eval.prepare_case(sample_cases()[0])["user_prompt"]
        with FakeLlamaServer() as server:
            teacher.TeacherClient(server.url, api="chat", retries=0).generate(user_prompt)
            _, path, body = server.last_post()
        self.assertEqual(path, "/v1/chat/completions")
        self.assertEqual(body["messages"], [{"role": "user", "content": user_prompt}])

    def test_generator_queries_and_stores_the_inner_prompt(self):
        case = dict(sample_cases()[0])
        seen = []

        class Client:
            def generate(self, user_prompt, seed=None):
                seen.append(user_prompt)
                return ""

        record, reason = generate.generate_one(Client(), case, "1-0-0")
        self.assertEqual((record, reason), (None, "empty_output"))
        case["id"] = "1-0-0"
        self.assertEqual(seen, [run_eval.prepare_case(case)["user_prompt"]])

    def test_served_template_is_checked_against_the_envelope(self):
        with FakeLlamaServer(GEMMA4_TEMPLATE) as server:
            self.assertIsNone(run_eval.envelope_mismatch(server.url, prompts.GEMMA4))
            self.assertIn("gemma4 turn markers",
                          run_eval.envelope_mismatch(server.url, prompts.GEMMA_LEGACY))
        with FakeLlamaServer(LEGACY_TEMPLATE) as server:
            self.assertIsNone(run_eval.envelope_mismatch(server.url, prompts.GEMMA_LEGACY))
            self.assertIsNotNone(run_eval.envelope_mismatch(server.url, prompts.GEMMA4))
        closed = FakeLlamaServer()
        closed.server.server_close()
        self.assertIn("could not read", run_eval.envelope_mismatch(closed.url, prompts.GEMMA4))


if __name__ == "__main__":
    unittest.main()
