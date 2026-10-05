#!/usr/bin/env bash
# Run Lamar's Groceries on your Android phone over Wi-Fi, with hot reload.
#
#   tool/phone.sh            build, install, run (r / R in this terminal)
#   tool/phone.sh attach     reconnect to the app already running on the phone
#   tool/reload.sh [-R]      hot reload (or restart) from another terminal
#
# One-time setup: Developer options → Wireless debugging → "Pair device with
# pairing code", then `adb pair <ip:port> <code>`. After that the phone
# reconnects automatically whenever it's on the same Wi-Fi as this Mac.
#
# Wireless adb is flaky in a few predictable ways, which this handles:
#   - adb keeps listing a phone whose connection went stale (phone slept,
#     Wi-Fi power-save): we probe it and reconnect via mDNS.
#   - a long Gradle build lets the phone doze: we build *first*, then connect.
#   - the debug connection drops while the app keeps running (e.g. during the
#     Google sign-in hop to Chrome): we re-attach instead of giving up.
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
APP_ID="com.lamarsgroceries.app"
APK="build/app/outputs/flutter-apk/app-debug.apk"
PID_FILE=".dart_tool/flutter_run.pid"
DEFINES=(--dart-define-from-file=env.json)
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export PATH="/opt/homebrew/bin:$PATH"

with_timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }   # macOS has no `timeout`
say() { printf '\033[1;35m▸ %s\033[0m\n' "$*"; }

# A phone counts as connected only if it actually answers.
responsive() { with_timeout 6 "$ADB" -s "$1" shell echo ok 2>/dev/null | grep -q ok; }

wifi_devices() {
  "$ADB" devices | awk '$2 == "device" && ($1 ~ /_adb-tls-connect/ || $1 ~ /^[0-9.]+:[0-9]+$/) { print $1 }'
}

# Prints the serial of a responsive phone, reconnecting if needed.
connect_phone() {
  local tries="${1:-5}" d addr
  for ((i = 1; i <= tries; i++)); do
    for d in $(wifi_devices); do
      if responsive "$d"; then echo "$d"; return 0; fi
      "$ADB" disconnect "$d" >/dev/null 2>&1 || true   # stale: drop it and rediscover
    done
    addr="$("$ADB" mdns services 2>/dev/null | awk '/_adb-tls-connect/ { print $3; exit }')"
    [[ -n "$addr" ]] && with_timeout 10 "$ADB" connect "$addr" >/dev/null 2>&1 || true
    sleep 2
  done
  return 1
}

app_running() { [[ -n "$(with_timeout 6 "$ADB" -s "$1" shell pidof "$APP_ID" 2>/dev/null | tr -d '\r')" ]]; }

no_phone() {
  echo "Can't reach your phone. Check that it's unlocked, on the same Wi-Fi as this Mac," >&2
  echo "and that Wireless debugging is still on (Settings → System → Developer options)." >&2
  echo "Android turns it off after a while and whenever you change Wi-Fi networks." >&2
  exit 1
}

mode="${1:-run}"

if [[ "$mode" != "attach" ]]; then
  say "Building (arm64 only, so there's less to send over Wi-Fi)…"
  flutter build apk --debug --target-platform android-arm64 "${DEFINES[@]}"
fi

say "Finding your phone…"
device="$(connect_phone)" || no_phone
say "Connected: $("$ADB" -s "$device" shell getprop ro.product.model | tr -d '\r')"
# Wake the screen so Wi-Fi leaves power-save for the install.
"$ADB" -s "$device" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true

if [[ "$mode" == "attach" ]]; then
  flutter attach -d "$device" "${DEFINES[@]}" --pid-file "$PID_FILE" || true
else
  flutter run -d "$device" --use-application-binary "$APK" "${DEFINES[@]}" --pid-file "$PID_FILE" || true
fi

# flutter exits when the debug connection drops. If the app is still running,
# reconnect and re-attach rather than making you redeploy.
while true; do
  device="$(connect_phone 15)" || no_phone
  if ! app_running "$device"; then
    say "The app was closed on the phone. Run tool/phone.sh again to relaunch."
    exit 0
  fi
  say "Connection dropped; re-attaching to the running app…"
  flutter attach -d "$device" "${DEFINES[@]}" --pid-file "$PID_FILE" || true
done
