#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESTART_SH="$ROOT/lua/restart_steam.sh"

if [ ! -f "$RESTART_SH" ]; then
  echo "FAIL: restart helper is missing" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.local/share/SLSsteam/path"

write_systemctl() {
  local mode="$1"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "${TEST_SYSTEMCTL_MODE:-}" in' \
    '  steamos)' \
    '    [[ "$*" == *"is-active --quiet steam-launcher.service"* ]] && exit 0' \
    '    ;;' \
    '  gamescope)' \
    '    [[ "$*" == *"is-active --quiet steam-launcher.service"* ]] && exit 1' \
    '    [[ "$*" == *"list-units"* ]] && {' \
    '      echo "gamescope-session-plus@steam.service loaded active running Gamescope"' \
    '      exit 0' \
    '    }' \
    '    ;;' \
    '  desktop)' \
    '    [[ "$*" == *"is-active --quiet steam-launcher.service"* ]] && exit 1' \
    '    [[ "$*" == *"list-units"* ]] && exit 0' \
    '    ;;' \
    'esac' \
    'exit 1' >"$TMP/bin/systemctl"
  chmod +x "$TMP/bin/systemctl"
  export TEST_SYSTEMCTL_MODE="$mode"
}

write_systemctl steamos
HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" \
  bash "$RESTART_SH" --check
result="$(
  HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" SLS_RESTART_DRYRUN=1 \
    bash "$RESTART_SH"
)"
[[ "$result" == "unit:steam-launcher.service" ]] || {
  echo "FAIL: SteamOS unit decision: $result" >&2
  exit 1
}

write_systemctl gamescope
HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" \
  bash "$RESTART_SH" --check
result="$(
  HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" SLS_RESTART_DRYRUN=1 \
    bash "$RESTART_SH"
)"
[[ "$result" == "unit:gamescope-session-plus@steam.service" ]] || {
  echo "FAIL: gamescope unit decision: $result" >&2
  exit 1
}

write_systemctl desktop
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  >"$TMP/home/.local/share/SLSsteam/path/steam"
chmod +x "$TMP/home/.local/share/SLSsteam/path/steam"
HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" \
  bash "$RESTART_SH" --check
result="$(
  HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" SLS_RESTART_DRYRUN=1 \
    bash "$RESTART_SH"
)"
[[ "$result" == "desktop:$TMP/home/.local/share/SLSsteam/path/steam" ]] || {
  echo "FAIL: desktop wrapper decision: $result" >&2
  exit 1
}

unlink "$TMP/home/.local/share/SLSsteam/path/steam"
if HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" \
    bash "$RESTART_SH" --check; then
  echo "FAIL: preflight accepted a desktop without the slsteam-moon wrapper" >&2
  exit 1
fi

grep -q "flock -n" "$RESTART_SH" || {
  echo "FAIL: restart helper has no cross-process lock" >&2
  exit 1
}
grep -q 'setsid nohup "$LAUNCHER" 9>&-' "$RESTART_SH" || {
  echo "FAIL: launched Steam inherits the restart lock descriptor" >&2
  exit 1
}

echo "test_restart_steam: ALL PASS"
