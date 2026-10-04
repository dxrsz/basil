#!/usr/bin/env bash
# Hot reload (default) or hot restart (-R) the session started by tool/phone.sh.
set -euo pipefail
pid_file="$(dirname "$0")/../.dart_tool/flutter_run.pid"
[[ -f "$pid_file" ]] || { echo "No running tool/phone.sh session" >&2; exit 1; }
if [[ "${1:-}" == "-R" ]]; then kill -USR2 "$(cat "$pid_file")"; else kill -USR1 "$(cat "$pid_file")"; fi
