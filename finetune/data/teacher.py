"""HTTP client for the teacher model used by the training-data generator.

Two API shapes against a single base URL:

  api="completion"  llama-server's raw /completion endpoint. Sends the fully
                    Gemma-templated prompt (``<start_of_turn>user ...
                    <start_of_turn>model``) with stop ``<end_of_turn>`` —
                    identical transport to finetune/eval/run_eval.py, but with
                    a higher default temperature for diversity.

  api="chat"        Any OpenAI-compatible /v1/chat/completions server (vLLM,
                    llama-server --chat-template, TGI, a cloud gateway...).
                    Sends the INNER user prompt only; the server applies its
                    own chat template. Use this when the teacher is a big
                    Gemma (or other instruct model) behind an OpenAI facade.

Stdlib only.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request

GEMMA_PREFIX = "<start_of_turn>user\n"
GEMMA_SUFFIX = "\n<end_of_turn>\n<start_of_turn>model"
STOP = ["<end_of_turn>"]

DEFAULT_TEMPERATURE = 0.9  # higher than the app's 0.8: diversity for training data
DEFAULT_TOP_K = 40
DEFAULT_TOP_P = 0.95
DEFAULT_N_PREDICT = 256
DEFAULT_TIMEOUT_S = 300
DEFAULT_RETRIES = 2


class TeacherError(RuntimeError):
    """Raised after all retries against the teacher endpoint are exhausted."""


def inner_user_prompt(templated_prompt: str) -> str:
    """Recover the inner user prompt from a Gemma-templated prompt built by
    eval.prompts.gemma_instruction_prompt."""
    if not (templated_prompt.startswith(GEMMA_PREFIX)
            and templated_prompt.endswith(GEMMA_SUFFIX)):
        raise ValueError("prompt does not carry the expected Gemma turn template")
    return templated_prompt[len(GEMMA_PREFIX):-len(GEMMA_SUFFIX)]


class TeacherClient:
    def __init__(
        self,
        endpoint: str,
        api: str = "completion",
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

    def _completion_body(self, templated_prompt: str, seed):
        body = {
            "prompt": templated_prompt,
            "n_predict": self.n_predict,
            "temperature": self.temperature,
            "top_k": self.top_k,
            "top_p": self.top_p,
            "stop": STOP,
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

    def generate(self, templated_prompt: str, seed=None) -> str:
        """Return the raw teacher text for one prompt (retries built in)."""
        if self.api == "completion":
            path, body = self._completion_body(templated_prompt, seed)
        else:
            path, body = self._chat_body(inner_user_prompt(templated_prompt), seed)

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
