#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

pass() {
  printf 'PASS: %s\n' "$1"
}

pending() {
  printf 'PENDING: %s\n' "$1"
  failures=$((failures + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

run_optional() {
  local label="$1"
  shift
  printf 'RUN: %s\n' "$label"
  if "$@"; then
    pass "$label"
  else
    fail "$label"
  fi
}

cd "$ROOT_DIR"

for file in BUGS.md KNOWN_ISSUES.md PARITY.md README.md RELEASE_NOTES.md docs/FINAL_SIGNOFF_STATUS.md; do
  if [[ -s "$file" ]]; then
    pass "$file exists"
  else
    fail "$file is missing or empty"
  fi
done

gemini_prefix='AI''za'
if git grep -n "$gemini_prefix" -- . ':!*.xcresult/**' ':!artifacts/**' >/tmp/rhymeai-final-signoff-key-scan.txt; then
  cat /tmp/rhymeai-final-signoff-key-scan.txt >&2
  fail "tracked files contain a Gemini key prefix"
else
  pass "tracked files contain no Gemini key prefix"
fi

if [[ -f android/local.properties ]] && rg -q '^geminiTestKey=.+' android/local.properties; then
  pass "gitignored Android Gemini test key is present"
else
  pending "android/local.properties has no geminiTestKey for live Gemini gates"
fi

if [[ -n "${RUN_VERIFY:-}" ]]; then
  run_optional "./scripts/verify.sh" ./scripts/verify.sh
else
  pending "set RUN_VERIFY=1 to rerun the full local verification harness"
fi

if [[ -n "${OPENAI_TEST_KEY:-}" && -n "${CLAUDE_TEST_KEY:-${ANTHROPIC_TEST_KEY:-}}" ]]; then
  if [[ -n "${RUN_PROVIDER_LIVE:-}" ]]; then
    run_optional "./scripts/provider-live-smoke.sh" ./scripts/provider-live-smoke.sh
  else
    pending "OpenAI/Claude keys are present; set RUN_PROVIDER_LIVE=1 to execute provider live smoke"
  fi
else
  pending "OpenAI/Claude live smoke needs OPENAI_TEST_KEY and CLAUDE_TEST_KEY or ANTHROPIC_TEST_KEY"
fi

if [[ -n "${LOCAL_GGUF_PATH:-}" && -r "${LOCAL_GGUF_PATH:-}" ]]; then
  if [[ "$(LC_ALL=C head -c 4 "$LOCAL_GGUF_PATH")" == "GGUF" ]]; then
    if [[ -n "${RUN_LOCAL_GGUF:-}" ]]; then
      run_optional "./scripts/android-local-model-smoke.sh" ./scripts/android-local-model-smoke.sh
    else
      pending "LOCAL_GGUF_PATH is valid; set RUN_LOCAL_GGUF=1 to execute Android local GGUF smoke"
    fi
  else
    fail "LOCAL_GGUF_PATH does not start with a GGUF header"
  fi
else
  pending "Android local GGUF smoke needs LOCAL_GGUF_PATH to a readable .gguf model"
fi

if [[ -n "${RUN_CLOUDKIT_READINESS:-}" ]]; then
  run_optional "./scripts/ios-cloudkit-readiness.sh" ./scripts/ios-cloudkit-readiness.sh
else
  pending "set RUN_CLOUDKIT_READINESS=1 to rerun static CloudKit readiness"
fi

if [[ "${CLOUDKIT_LIVE_MATRIX_PASSED:-}" == "1" ]]; then
  pass "CloudKit live matrix externally marked complete for this shell"
else
  pending "CloudKit live matrix still needs two iCloud-signed-in simulators/devices"
fi

if [[ "$failures" -eq 0 ]]; then
  echo "Final production sign-off status: complete."
else
  echo "Final production sign-off status: incomplete ($failures item(s) pending or failed)." >&2
  exit 2
fi
