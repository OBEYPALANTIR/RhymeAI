"""Minimal stdlib HTTP client with retries and polite headers.

Uses only urllib so the tool runs on any Python 3.9+ with zero installs.
Honors HTTPS_PROXY/HTTP_PROXY through urllib's default ProxyHandler.
"""

import json
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_TIMEOUT = 30
DEFAULT_RETRIES = 3


class SourceUnavailable(Exception):
    """A data source could not be reached or returned an error."""

    def __init__(self, source, detail):
        self.source = source
        self.detail = detail
        super().__init__(f"{source}: {detail}")


def _request(url, *, method="GET", body=None, headers=None, timeout=DEFAULT_TIMEOUT):
    data = None
    all_headers = {"Accept": "application/json"}
    if headers:
        all_headers.update(headers)
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        all_headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=all_headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def fetch_json(source, url, *, method="GET", body=None, headers=None,
               retries=DEFAULT_RETRIES, timeout=DEFAULT_TIMEOUT):
    """Fetch a URL and parse JSON, retrying transient failures with backoff.

    Raises SourceUnavailable with a human-readable reason on hard failure so
    the report can show *which* source failed and why instead of dying.
    """
    last_error = None
    for attempt in range(retries):
        try:
            raw = _request(url, method=method, body=body, headers=headers,
                           timeout=timeout)
            return json.loads(raw)
        except urllib.error.HTTPError as e:
            # 4xx (except 429) won't improve with retries.
            if e.code == 429:
                last_error = "rate limited (HTTP 429)"
            elif 400 <= e.code < 500:
                raise SourceUnavailable(source, f"HTTP {e.code} {e.reason}")
            else:
                last_error = f"HTTP {e.code} {e.reason}"
        except urllib.error.URLError as e:
            last_error = f"network error: {e.reason}"
        except (json.JSONDecodeError, TimeoutError) as e:
            last_error = f"bad response: {e}"
        if attempt < retries - 1:
            time.sleep(2 ** attempt)
    raise SourceUnavailable(source, last_error or "unknown error")


def qs(params):
    """Build a query string, dropping None values."""
    return urllib.parse.urlencode(
        {k: v for k, v in params.items() if v is not None})
