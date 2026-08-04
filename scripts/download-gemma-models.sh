#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="${GEMMA_MODEL_DIR:-$ROOT_DIR/artifacts/gemma-local-models}"
HUGGING_FACE_REVISION="27492c6696f2f868bbbe3aeafb633009ef932598"

mkdir -p "$MODEL_DIR"

models=(
  "e2b|RhymeAI Gemma E2B|gemma-4-E2B-it-rhymeai-Q4_K_M.gguf|3427878784|059e73281d764ba0d541470aabdbd89de84878263b67d50c6c3afbc292933626|https://huggingface.co/Shayde182/rhymeai-gemma-4-gguf/resolve/$HUGGING_FACE_REVISION/gemma-4-E2B-it-rhymeai-Q4_K_M.gguf?download=true"
  "e4b|RhymeAI Gemma E4B|gemma-4-E4B-it-rhymeai-Q4_K_M.gguf|5335290784|e39b2475a5c8d86d1b376babe16ffce32993c96ab650b6fed7c4e14f5d0d11a3|https://huggingface.co/Shayde182/rhymeai-gemma-4-gguf/resolve/$HUGGING_FACE_REVISION/gemma-4-E4B-it-rhymeai-Q4_K_M.gguf?download=true"
)

file_size() {
  wc -c < "$1" | tr -d ' '
}

verify_model() {
  local label="$1"
  local path="$2"
  local expected_bytes="$3"
  local expected_sha256="$4"

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

  local actual_sha256
  actual_sha256="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "$label failed its SHA-256 integrity check" >&2
    return 1
  fi
}

selected="${*:-all}"
for model in "${models[@]}"; do
  IFS='|' read -r key label file_name expected_bytes expected_sha256 url <<< "$model"
  if [[ "$selected" != "all" && " $selected " != *" $key "* && " $selected " != *" $file_name "* ]]; then
    continue
  fi

  dest="$MODEL_DIR/$file_name"
  temp="$dest.partial"

  if verify_model "$label" "$dest" "$expected_bytes" "$expected_sha256" >/dev/null 2>&1; then
    echo "$label already verified at $dest"
    continue
  fi

  echo "Downloading $label to $dest"
  curl --fail --location --continue-at - --output "$temp" "$url"

  if ! verify_model "$label" "$temp" "$expected_bytes" "$expected_sha256"; then
    rm -f "$temp"
    exit 1
  fi
  mv "$temp" "$dest"
  verify_model "$label" "$dest" "$expected_bytes" "$expected_sha256"
  echo "$label verified at $dest"
done
