#!/usr/bin/env bash
# --- Telegram->MT5 bridge: init/control script (no systemd needed) -----------
# Usage: bridge/start_bridge.sh start|stop|restart|status|log
# The bridge logs a heartbeat line every heartbeat_min minutes (config.
# properties), so "status"/"log" show proof of life without touching the EA.

BRIDGE_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(dirname "$BRIDGE_DIR")"
PY="$ROOT/venv/bin/python3"
SCRIPT="$BRIDGE_DIR/telegram_to_mt5.py"
LOG="$BRIDGE_DIR/bridge.log"
PIDF="$BRIDGE_DIR/bridge.pid"

running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }

do_stop() {
    if running; then kill "$(cat "$PIDF")"; rm -f "$PIDF"; echo "stopped";
    else echo "not running"; fi
}

do_start() {
    if running; then echo "already running (pid $(cat "$PIDF"))"; return; fi
    if [ ! -x "$PY" ]; then
        echo "no venv found: creating it (pip install telethon)"
        "$ROOT"/python3 -m venv venv && "$ROOT"/venv/bin/pip install telethon
        echo "or run: venv/bin/python bridge/telegram_to_mt5.py in a terminal first"
    fi
    if ! ls "$BRIDGE_DIR"/*.session >/dev/null 2>&1; then
        echo "hint: no saved session yet - log in FIRST in a terminal:"
        echo "      venv/bin/python $SCRIPT   (browser login); then use start"
    fi
    # -u: keep prints line-buffered even when redirected to a file, so
    # heartbeats/writes show up in bridge.log immediately
    nohup "$PY" -u "$SCRIPT" >>"$LOG" 2>&1 &
    echo $! > "$PIDF"
    echo "started (pid $(cat "$PIDF")). log: $LOG"
}

case "${1:-start}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 1; do_start ;;
    status)
        if running; then
            echo "RUNNING pid $(cat "$PIDF")"
            echo "--- last heartbeats:"; grep heartbeat "$LOG" 2>/dev/null | tail -n 3
        else
            echo "not running"
        fi ;;
    log)     tail -n 20 "$LOG" 2>/dev/null; [ "${2:-}" = "-f" ] && tail -f "$LOG" ;;
    *) echo "usage: $0 start|stop|restart|status|log"; exit 1 ;;
esac
