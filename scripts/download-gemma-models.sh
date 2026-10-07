#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="${GEMMA_MODEL_DIR:-$ROOT_DIR/artifacts/gemma-local-models}"

mkdir -p "$MODEL_DIR"

models=(
  "e2b|RhymeAI Gemma E2B|gemma-4-E2B-it-rhymeai-Q4_K_M.gguf|3427880800|https://huggingface.co/Shayde182/rhymeai-gemma-4-gguf/resolve/main/gemma-4-E2B-it-rhymeai-Q4_K_M.gguf?download=true"
  "e4b|RhymeAI Gemma E4B|gemma-4-E4B-it-rhymeai-Q4_K_M.gguf|5335292800|https://huggingface.co/Shayde182/rhymeai-gemma-4-gguf/resolve/main/gemma-4-E4B-it-rhymeai-Q4_K_M.gguf?download=true"
)

file_size() {
  wc -c < "$1" | tr -d ' '
}

verify_model() {
  local label="$1"
  local path="$2"
  local expected_bytes="$3"

  if [[ ! -r "$path" ]]; then
    echo "$label is missing: $path" >&2
    return 1
  fi

  local actual_bytes
  actual_bytes="$(file_size "$path")"
  if [[ "$actual_bytes" != "$expected_bytes" ]]; then
    echo "$label has unexpected size: $actual_bytes bytes, expected $expected_bytes" >&2
    return 1
  fi

  if [[ "$(LC_ALL=C head -c 4 "$path")" != "GGUF" ]]; then
    echo "$label does not start with a GGUF header: $path" >&2
    return 1
  fi
}

selected="${*:-all}"
for model in "${models[@]}"; do
  IFS='|' read -r key label file_name expected_bytes url <<< "$model"
  if [[ "$selected" != "all" && " $selected " != *" $key "* && " $selected " != *" $file_name "* ]]; then
    continue
  fi

  dest="$MODEL_DIR/$file_name"
  temp="$dest.partial"

  if verify_model "$label" "$dest" "$expected_bytes" >/dev/null 2>&1; then
    echo "$label already verified at $dest"
    continue
  fi

  echo "Downloading $label to $dest"
  curl --fail --location --continue-at - --output "$temp" "$url"

  actual_bytes="$(file_size "$temp")"
  if [[ "$actual_bytes" != "$expected_bytes" ]]; then
    echo "$label partial has unexpected size: $actual_bytes bytes, expected $expected_bytes" >&2
    exit 1
  fi
  mv "$temp" "$dest"
  verify_model "$label" "$dest" "$expected_bytes"
  echo "$label verified at $dest"
done
