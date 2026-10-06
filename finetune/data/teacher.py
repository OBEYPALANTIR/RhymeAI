"""HTTP client for the teacher model used by the training-data generator.

Two API shapes against a single base URL; both take the INNER user prompt:

  api="completion"  llama-server's raw /completion endpoint (no chat
                    template). Sends the app's exact on-device request,
                    eval.prompts.app_prompt(user_prompt, envelope), with the
                    envelope's end-of-turn as stop — the same transport as
                    finetune/eval/run_eval.py, with a higher default
                    temperature for diversity. No <bos> in the text:
                    llama-server adds one when the GGUF sets add_bos_token,
                    as llama.cpp does in the app.

  api="chat"        Any OpenAI-compatible /v1/chat/completions server (vLLM,
                    llama-server, TGI, a cloud gateway...). Sends the inner
                    prompt unwrapped; the server applies the model's own chat
                    template, so no envelope is added here. That rendering is
                    the server's, not byte-identical to the app's (Gemma 4's
                    template trims the content, and server options such as
                    thinking can change it).

Stdlib only.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request

from eval import prompts

DEFAULT_TEMPERATURE = 0.9  # higher than the app's 0.8: diversity for training data
DEFAULT_TOP_K = 40
DEFAULT_TOP_P = 0.95
DEFAULT_N_PREDICT = 256
DEFAULT_TIMEOUT_S = 300
DEFAULT_RETRIES = 2


class TeacherError(RuntimeError):
    """Raised after all retries against the teacher endpoint are exhausted."""


class TeacherClient:
    def __init__(
        self,
        endpoint: str,
        api: str = "completion",
        envelope: prompts.PromptEnvelope = prompts.GEMMA4,
        temperature: float = DEFAULT_TEMPERATURE,
        top_k: int = DEFAULT_TOP_K,
        top_p: float = DEFAULT_TOP_P,
        n_predict: int = DEFAULT_N_PREDICT,
        timeout_s: float = DEFAULT_TIMEOUT_S,
        retries: int = DEFAULT_RETRIES,
        retry_backoff_s: float = 2.0,
        api_key: str = "",
        model: str = "",
    ):
        if api not in ("completion", "chat"):
            raise ValueError("api must be 'completion' or 'chat'")
        self.endpoint = endpoint.rstrip("/")
        self.api = api
        self.envelope = envelope
        self.temperature = temperature
        self.top_k = top_k
        self.top_p = top_p
        self.n_predict = n_predict
        self.timeout_s = timeout_s
        self.retries = retries
        self.retry_backoff_s = retry_backoff_s
        self.api_key = api_key
        self.model = model

    # -- request bodies ------------------------------------------------------

    def _completion_body(self, user_prompt: str, seed):
        body = {
            "prompt": prompts.app_prompt(user_prompt, self.envelope),
            "n_predict": self.n_predict,
            "temperature": self.temperature,
            "top_k": self.top_k,
            "top_p": self.top_p,
            "stop": [self.envelope.end_of_turn],
            "cache_prompt": False,
        }
        if seed is not None:
            body["seed"] = seed
        return "/completion", body

    def _chat_body(self, user_prompt: str, seed):
        body = {
            "messages": [{"role": "user", "content": user_prompt}],
            "temperature": self.temperature,
            "top_p": self.top_p,
            "max_tokens": self.n_predict,
        }
        if self.model:
            body["model"] = self.model
        if seed is not None:
            body["seed"] = seed
        return "/v1/chat/completions", body

    # -- transport -----------------------------------------------------------

    def _post(self, path: str, body: dict) -> dict:
        data = json.dumps(body).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = "Bearer %s" % self.api_key
        request = urllib.request.Request(
            self.endpoint + path, data=data, headers=headers, method="POST"
        )
        with urllib.request.urlopen(request, timeout=self.timeout_s) as response:
            return json.loads(response.read().decode("utf-8"))

    def generate(self, user_prompt: str, seed=None) -> str:
        """Return the raw teacher text for one inner prompt (retries built in)."""
        if self.api == "completion":
            path, body = self._completion_body(user_prompt, seed)
        else:
            path, body = self._chat_body(user_prompt, seed)

        last_error = None
        for attempt in range(self.retries + 1):
            try:
                payload = self._post(path, body)
                if self.api == "completion":
                    return payload.get("content", "")
                return payload["choices"][0]["message"]["content"] or ""
            except (urllib.error.URLError, urllib.error.HTTPError, OSError,
                    json.JSONDecodeError, KeyError, IndexError) as error:
                last_error = error
                if attempt < self.retries:
                    time.sleep(self.retry_backoff_s * (attempt + 1))
        raise TeacherError(
            "teacher request failed after %d attempts: %r"
            % (self.retries + 1, last_error)
        )
