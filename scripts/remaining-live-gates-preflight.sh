#!/usr/bin/env bash
set -euo pipefail

failures=0

pass() {
  printf 'PASS: %s\n' "$1"
}

pending() {
  printf 'PENDING: %s\n' "$1"
  failures=$((failures + 1))
}

sim_label() {
  local udid="$1"
  xcrun simctl list devices | rg "$udid" | sed 's/^[[:space:]]*//'
}

check_provider_keys() {
  if [[ -n "${OPENAI_TEST_KEY:-}" ]]; then
    pass "OPENAI_TEST_KEY is present"
  else
    pending "OPENAI_TEST_KEY is missing for OpenAI live smoke"
  fi

  if [[ -n "${CLAUDE_TEST_KEY:-${ANTHROPIC_TEST_KEY:-}}" ]]; then
    pass "CLAUDE_TEST_KEY or ANTHROPIC_TEST_KEY is present"
  else
    pending "CLAUDE_TEST_KEY or ANTHROPIC_TEST_KEY is missing for Claude live smoke"
  fi
}

booted_simulators() {
  xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p'
}

check_cloudkit_simulator() {
  local label="$1"
  local udid="$2"
  local account_out
  local account_err
  local sync_out
  local sync_err
  account_out="$(mktemp)"
  account_err="$(mktemp)"
  sync_out="$(mktemp)"
  sync_err="$(mktemp)"

  if ! xcrun simctl getenv "$udid" HOME >/dev/null 2>&1; then
    pending "$label simulator is not booted or cannot read simulator environment: $udid"
    rm -f "$account_out" "$account_err" "$sync_out" "$sync_err"
    return
  fi

  if xcrun simctl spawn "$udid" /usr/bin/defaults read MobileMeAccounts Accounts >"$account_out" 2>"$account_err" && [[ -s "$account_out" ]]; then
    pass "$label simulator has a MobileMeAccounts record"
  else
    pending "$label simulator has no MobileMeAccounts account record: $(sim_label "$udid")"
  fi

  if xcrun simctl icloud_sync "$udid" >"$sync_out" 2>"$sync_err"; then
    pass "$label simulator accepted simctl icloud_sync"
  else
    pending "$label simulator failed simctl icloud_sync: $(tr '\n' ' ' <"$sync_err" | sed 's/[[:space:]]*$//')"
  fi

  rm -f "$account_out" "$account_err" "$sync_out" "$sync_err"
}

check_cloudkit_targets() {
  local sim_a="${CLOUDKIT_SIM_A:-}"
  local sim_b="${CLOUDKIT_SIM_B:-}"
  local booted

  if [[ -z "$sim_a" || -z "$sim_b" ]]; then
    booted="$(booted_simulators)"
    if [[ -z "$sim_a" ]]; then
      sim_a="$(printf '%s\n' "$booted" | sed -n '1p')"
    fi
    if [[ -z "$sim_b" ]]; then
      sim_b="$(printf '%s\n' "$booted" | sed -n '2p')"
    fi
  fi

  if [[ -z "$sim_a" || -z "$sim_b" ]]; then
    pending "CloudKit live matrix needs two booted iOS simulators or CLOUDKIT_SIM_A/CLOUDKIT_SIM_B"
    return
  fi

  if [[ "$sim_a" == "$sim_b" ]]; then
    pending "CloudKit live matrix needs two distinct simulator UDIDs"
    return
  fi

  check_cloudkit_simulator "CloudKit A" "$sim_a"
  check_cloudkit_simulator "CloudKit B" "$sim_b"
}

check_provider_keys
check_cloudkit_targets

if [[ "$failures" -eq 0 ]]; then
  echo "Remaining live gate preflight passed. Run ./scripts/provider-live-smoke.sh and complete docs/CLOUDKIT_SYNC_CHECKLIST.md."
else
  echo "Remaining live gate preflight incomplete ($failures item(s) pending)." >&2
  exit 2
fi
