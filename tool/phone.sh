#!/usr/bin/env bash
# Run Basil on your Android phone over Wi-Fi with hot reload.
#
#   tool/phone.sh            # build, install, run (press r / R in this terminal)
#   tool/reload.sh [-R]      # hot reload (or restart) a session started here,
#                            # e.g. from another terminal or an editor hook
#
# One-time setup: Developer options → Wireless debugging → "Pair device with
# pairing code", then `adb pair <ip:port> <code>`. After that the phone
# reconnects automatically whenever it's on the same Wi-Fi as this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export PATH="/opt/homebrew/bin:$PATH"

find_phone() { "$ADB" devices | awk '/_adb-tls-connect/ && $2 == "device" { print $1; exit }'; }

device="$(find_phone)"
if [[ -z "$device" ]]; then
  # Paired but not connected yet: connect to whatever mDNS advertises.
  addr="$("$ADB" mdns services | awk '/_adb-tls-connect/ { print $3; exit }')"
  [[ -n "$addr" ]] && "$ADB" connect "$addr" >/dev/null && sleep 1
  device="$(find_phone)"
fi
if [[ -z "$device" ]]; then
  echo "No phone found. Check it's on the same Wi-Fi with Wireless debugging on" >&2
  echo "(Settings → System → Developer options), and pair it once with adb pair." >&2
  exit 1
fi

echo "Running on $("$ADB" -s "$device" shell getprop ro.product.model | tr -d '\r') ($device)"
exec flutter run -d "$device" --dart-define-from-file=env.json \
  --pid-file .dart_tool/flutter_run.pid "$@"
