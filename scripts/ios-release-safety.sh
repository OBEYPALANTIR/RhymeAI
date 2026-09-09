#!/usr/bin/env bash

require_simulator_id() {
  local variable="$1"
  local udid="$2"
  if [[ ! "$udid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
    echo "Set $variable to the explicit UDID of a booted disposable simulator with no Writers Block installation." >&2
    return 1
  fi
}

validate_simulator() {
  local udid="$1"
  local family="$2"
  xcrun simctl list devices available --json | /usr/bin/python3 -c '
import json
import sys

udid, family = sys.argv[1:]
data = json.load(sys.stdin)
for runtime, devices in data["devices"].items():
    for device in devices:
        if device["udid"].lower() != udid.lower():
            continue
        if not runtime.startswith("com.apple.CoreSimulator.SimRuntime.iOS-") or not device.get("isAvailable"):
            sys.exit("Selected simulator is not an available iOS simulator: " + udid)
        if not device.get("deviceTypeIdentifier", "").startswith("com.apple.CoreSimulator.SimDeviceType." + family + "-"):
            sys.exit("Selected simulator must be an " + family + ": " + udid)
        if device.get("state") != "Booted":
            sys.exit("Selected disposable simulator must already be booted: " + udid)
        print(device["name"] + " | " + runtime.rsplit(".", 1)[-1].replace("-", " ") + " | " + udid)
        sys.exit(0)
sys.exit("Selected simulator was not found: " + udid)
' "$udid" "$family"
}

require_uninstalled_app() {
  local udid="$1"
  local bundle_id="$2"
  xcrun simctl listapps "$udid" | plutil -convert json -o - - | /usr/bin/python3 -c '
import json
import sys

udid, bundle_id = sys.argv[1:]
apps = json.load(sys.stdin)
if not isinstance(apps, dict) or not apps or not all(isinstance(app, dict) and app.get("CFBundleIdentifier") == key for key, app in apps.items()):
    sys.exit("Unable to verify installed applications on " + udid)
for protected_id in {"ShaydeTree.Writers-Block", bundle_id}:
    if protected_id in apps:
        sys.exit("Refusing to replace existing " + protected_id + " installation on " + udid + "; select a disposable simulator without the app.")
' "$udid" "$bundle_id"
}

require_app_bundle() {
  local app="$1"
  local expected_id="$2"
  local actual_id
  actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")" || return 1
  if [[ "$actual_id" != "$expected_id" ]]; then
    echo "Release app bundle ID $actual_id does not match requested $expected_id." >&2
    return 1
  fi
}

require_new_path() {
  if [[ -e "$1" || -L "$1" ]]; then
    echo "Refusing to reuse existing output path: $1" >&2
    return 1
  fi
}

create_work_directory() {
  local designated="$1"
  local prefix="$2"
  if [[ -n "$designated" ]]; then
    require_new_path "$designated" || return 1
    mkdir -p "$(dirname "$designated")"
    mkdir "$designated" || return 1
    printf '%s\n' "$designated"
  else
    mktemp -d "${TMPDIR:-/tmp}/$prefix.XXXXXX"
  fi
}
