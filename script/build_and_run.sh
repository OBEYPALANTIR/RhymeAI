#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---run}"
case "$MODE" in
  --run|--build-only|--verify|--debug|--logs|--telemetry) ;;
  *) echo "Usage: $0 [--run|--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
APP_NAME="Writers Block Mac"
WORKTREE_KEY="$(printf '%s' "$ROOT_DIR" | shasum -a 256 | cut -c 1-16)"
DERIVED_DATA="$HOME/Library/Caches/WritersBlockMac/$WORKTREE_KEY"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
if [[ "$MODE" != "--build-only" ]] && pgrep -x "$APP_NAME" >/dev/null; then
  echo "Writers Block Mac is running. Quit it after saving before rebuilding and launching." >&2
  exit 1
fi
xcodebuild -project "$ROOT_DIR/Writers Block/Writers Block Mac.xcodeproj" \
  -scheme "$APP_NAME" -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY=- build
# Local development signing preserves the sandbox and hardened runtime.
# Distribution requires an Apple signing identity and notarization.
codesign --force --sign - --options runtime \
  --entitlements "$ROOT_DIR/Writers Block/Mac/WritersBlockMac.entitlements" "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"
if [[ "$MODE" == "--build-only" ]]; then
  printf '%s\n' "$APP_BUNDLE"
  exit 0
fi
if [[ "$MODE" == "--debug" ]]; then
  exec lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi
open -g "$APP_BUNDLE"
case "$MODE" in
  --verify) sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  --logs) exec log stream --info --style compact --predicate 'process == "Writers Block Mac"' ;;
  --telemetry) exec log stream --info --style compact --predicate 'subsystem == "ShaydeTree.Writers-Block.macOS"' ;;
esac
