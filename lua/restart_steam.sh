#!/usr/bin/env bash
# Restart Steam through the slsteam-moon launcher while surviving Steam's exit.
set -u

CHECK_ONLY="${1:-}"

# Steam's runtime variables can break system utilities and must not leak into
# the fresh client process.
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT STEAM_RUNTIME_LIBRARY_PATH STEAM_ZENITY

# Serialize helpers from every Lumen/UI context. flock releases automatically
# if the helper exits unexpectedly; mkdir is a fallback for minimal systems.
if [ "$CHECK_ONLY" != "--check" ] && [ -z "${SLS_RESTART_DRYRUN:-}" ]; then
  lock_base="${XDG_RUNTIME_DIR:-/tmp}"
  [ -d "$lock_base" ] || lock_base="/tmp"
  lock_file="$lock_base/lumen-restart-${UID:-$(id -u)}.lock"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock_file" || exit 1
    flock -n 9 || exit 0
  else
    lock_dir="${lock_file}.d"
    mkdir "$lock_dir" 2>/dev/null || exit 0
    trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT HUP INT TERM
  fi
fi

# Game Mode sessions supervise Steam with a user service. Restarting that
# service is safer than fighting its process supervisor.
if command -v systemctl >/dev/null 2>&1; then
  : "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
  export XDG_RUNTIME_DIR

  if systemctl --user is-active --quiet steam-launcher.service 2>/dev/null; then
    if [ "$CHECK_ONLY" = "--check" ]; then exit 0; fi
    if [ -n "${SLS_RESTART_DRYRUN:-}" ]; then
      echo "unit:steam-launcher.service"
      exit 0
    fi
    setsid nohup systemctl --user restart steam-launcher.service \
      </dev/null >/dev/null 2>&1 &
    exit 0
  fi

  gs_unit="$(
    systemctl --user list-units --type=service --state=active \
      --plain --no-legend 'gamescope-session*' 2>/dev/null \
      | awk '{print $1}' | head -n1
  )"
  if [ -n "${gs_unit:-}" ]; then
    if [ "$CHECK_ONLY" = "--check" ]; then exit 0; fi
    if [ -n "${SLS_RESTART_DRYRUN:-}" ]; then
      echo "unit:$gs_unit"
      exit 0
    fi
    setsid nohup systemctl --user restart "$gs_unit" \
      </dev/null >/dev/null 2>&1 &
    exit 0
  fi
fi

# Desktop sessions require the slsteam-moon wrapper. Never close Steam when the
# only relaunch option would omit SLSsteam/Lumen injection.
LAUNCHER="$HOME/.local/share/SLSsteam/path/steam"
if [ ! -x "$LAUNCHER" ]; then
  if [ -n "${SLS_RESTART_DRYRUN:-}" ]; then echo "desktop:none"; fi
  exit 1
fi
if [ "$CHECK_ONLY" = "--check" ]; then exit 0; fi

if [ -n "${SLS_RESTART_DRYRUN:-}" ]; then
  echo "desktop:$LAUNCHER"
  exit 0
fi

if command -v steam >/dev/null 2>&1; then
  steam -shutdown >/dev/null 2>&1 || true
fi

# Allow a clean shutdown, then escalate only if Steam is still alive.
for _ in $(seq 1 50); do
  if ! pgrep -x steam >/dev/null 2>&1 \
      && ! pgrep -f 'steamwebhelper' >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

if pgrep -x steam >/dev/null 2>&1 \
    || pgrep -f 'steamwebhelper' >/dev/null 2>&1; then
  pkill -TERM -x steam >/dev/null 2>&1 || true
  pkill -TERM -f 'steamwebhelper' >/dev/null 2>&1 || true
  sleep 2
fi
if pgrep -x steam >/dev/null 2>&1 \
    || pgrep -f 'steamwebhelper' >/dev/null 2>&1; then
  pkill -KILL -x steam >/dev/null 2>&1 || true
  pkill -KILL -f 'steamwebhelper' >/dev/null 2>&1 || true
  sleep 1
fi

sleep 1
setsid nohup "$LAUNCHER" </dev/null >/dev/null 2>&1 &
exit 0
