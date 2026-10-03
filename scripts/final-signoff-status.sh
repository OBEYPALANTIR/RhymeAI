#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

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
if git grep -q "$gemini_prefix" -- . ':!*.xcresult/**' ':!artifacts/**' 2>/dev/null; then
  fail "tracked files contain a Gemini key prefix (matching content withheld)"
else
  scan_status=$?
  if [[ "$scan_status" == "1" ]]; then
    pass "tracked files contain no Gemini key prefix"
  else
    fail "tracked key scan could not complete"
  fi
fi

if [[ -f android/local.properties ]] && rg -q '^geminiTestKey=.+' android/local.properties; then
  pass "gitignored Android Gemini test key is present"
else
  pending "android/local.properties has no geminiTestKey for live Gemini gates"
fi

if [[ "${RUN_VERIFY:-0}" == "1" ]]; then
  run_optional "./scripts/verify.sh" ./scripts/verify.sh
else
  pending "set RUN_VERIFY=1 to run verification for this checkout; historical markdown is not current evidence"
fi

if [[ -n "${OPENAI_TEST_KEY:-}" && -n "${CLAUDE_TEST_KEY:-${ANTHROPIC_TEST_KEY:-}}" ]]; then
  if [[ "${RUN_PROVIDER_LIVE:-0}" == "1" ]]; then
    run_optional "./scripts/provider-live-smoke.sh" ./scripts/provider-live-smoke.sh
  else
    pending "OpenAI/Claude keys are present; set RUN_PROVIDER_LIVE=1 to execute provider live smoke"
  fi
else
  pending "OpenAI/Claude live smoke needs OPENAI_TEST_KEY and CLAUDE_TEST_KEY or ANTHROPIC_TEST_KEY"
fi

if [[ -n "${LOCAL_GGUF_PATH:-}" && -r "${LOCAL_GGUF_PATH:-}" ]]; then
  if [[ "$(LC_ALL=C head -c 4 "$LOCAL_GGUF_PATH")" == "GGUF" ]]; then
    if [[ "${RUN_LOCAL_GGUF:-0}" == "1" ]]; then
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

if [[ "${RUN_CLOUDKIT_READINESS:-0}" == "1" ]]; then
  run_optional "./scripts/ios-cloudkit-readiness.sh" ./scripts/ios-cloudkit-readiness.sh
else
  pending "set RUN_CLOUDKIT_READINESS=1 to run static CloudKit readiness"
fi

pending "CloudKit live matrix requires reviewed two-device results bound to the candidate; shell flags do not verify it"
pending "Final release approval requires reviewed installed candidate evidence, signing and store metadata"

echo "Release diagnostic status: incomplete ($failures item(s) pending or failed)." >&2
exit 2
