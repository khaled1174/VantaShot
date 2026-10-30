#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-run}"
case "$MODE" in run|--verify|--debug|--logs|--telemetry) ;; *) printf 'Usage: %s [--verify|--debug|--logs|--telemetry]\n' "$0" >&2; exit 2;; esac
APP_PATH="$(pwd)/dist/VantaShot.app"
for pid in $(pgrep -x VantaShot || true); do
  COMMAND_PATH="$(ps -ww -p "$pid" -o args=)"
  if [[ "$COMMAND_PATH" == *"$APP_PATH/Contents/MacOS/VantaShot"* || "$COMMAND_PATH" == *"/dist/VantaShot.app/Contents/MacOS/VantaShot"* ]]; then kill -TERM "$pid"; fi
done
./bundle-app.sh
./script/verify_release.sh
if [[ "$MODE" == --debug ]]; then exec lldb -- "$APP_PATH/Contents/MacOS/VantaShot"; fi
open -n "$APP_PATH" --args "${@:2}"
case "$MODE" in
  --verify) sleep 2; pgrep -x VantaShot >/dev/null; printf '%s\n' 'VantaShot launched.';;
  --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "VantaShot"';;
  --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.vantashot.macos"';;
esac
