#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# telegram_to_mt5.py — bridge between your Telegram account and the MT5 EA.
#
# Watches several Telegram groups with YOUR OWN account (Telethon user login,
# same api_id/api_hash as the vendored TelegramReader repo; the groups to watch
# come from 'groups=' in config.properties or the WEB_IDS list below) and, for
# every new message that looks like a trading signal (BUY/SELL + symbol), first
# filters (only watched groups, only signal-looking messages) and then writes a
# JSON file named  PAIR_YYYYMMDD_HHMMSS_<telegram_msg_id>.json  into the MT5
# Files sandbox (or the per-group folder configured with 'id:<folder>' entries
# in groups=, so one bridge can feed several MT5 terminals at once). The
# Expert Advisor (TelegramSignalCopier.mq5) scans that folder, parses the
# message text with its own parser, opens the trades and deletes the file
# once processed.
#
# Run (console):
#   pip install telethon
#   python bridge/telegram_to_mt5.py
#
# First run: Telethon prints a login URL (opens browser) and saves your session
# to a .session file, so later runs start silently.
#
# "Compiled" (optional, standalone .exe):
#   pip install pyinstaller
#   pyinstaller --onefile --console bridge/telegram_to_mt5.py
# -----------------------------------------------------------------------------
import os
import re
import sys
import json
import time
import asyncio
from pathlib import Path

from telethon import TelegramClient, events

# --- console logging: plain timestamp + colored [LEVEL] tag + message --------
RANK = {"debug": 4, "info": 3, "warn": 2, "error": 1, "fatal": 0}
ANSI = {"debug": "\x1b[90m", "info": "\x1b[36m", "warn": "\x1b[33m",
        "error": "\x1b[31m", "fatal": "\x1b[1;97;41m"}  # gray/cyan/yellow/red/hd
USE_COLOR = True   # colors go into the log file too: tail -f shows them;
#                   config 'color=never' strips them, 'color=auto' = only TTY
LOG_THRESHOLD = "info"

def plog(lvl, msg):
    if RANK.get(lvl, 3) > RANK.get(LOG_THRESHOLD, 3):
        return
    line = f"[{lvl.upper()}] {msg}"
    color = ANSI.get(lvl) if USE_COLOR else None
    if color:
        line = f"{color}{line}\x1b[0m"
    sys.__stdout__.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {line}\n")
    sys.__stdout__.flush()

# --- locate config -----------------------------------------------------------
if getattr(sys, "frozen", False):          # running as PyInstaller exe
    BASE = Path(sys.argv[0]).resolve().parent
    CONFIG = BASE / "config.properties"    # kept next to the exe
else:
    BASE = Path(__file__).resolve().parent.parent   # project root (bridge/..)
    CONFIG = Path(__file__).resolve().parent / "config.properties"  # next to the script


def norm_path(v):
    # accept paths pasted from a shell (escaped "\ "), tolerate duplicated
    # "//" separators and a trailing "/"
    v = v.replace("\\ ", " ")
    v = re.sub(r"//+", "/", v)
    if len(v) > 1:
        v = v.rstrip("/")
    return v

def load_config(path):
    cfg = {}
    local = Path(path).with_name("config.local.properties")
    for p in (path, local):
        # bridge/config.local.properties (gitignored) overrides keys from the
        # tracked config.properties — keep your REAL api_id/api_hash there, so
        # the repo copy can carry placeholders without breaking the watcher.
        if not p.exists():
            continue
        with open(p, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip()
    if cfg.get("mt5_folder"):
        cfg["mt5_folder"] = norm_path(cfg["mt5_folder"])
    return cfg

def parse_watch(raw_tokens, default_dir):
    """Map every watched chat id to its OUTPUT FOLDER.

    A groups= entry is either "id" (uses the default mt5_folder) or
    "id:<absolute folder>" (own output dir - one per broker/terminal). The
    id is accepted exactly as pasted from a web.telegram.org link; all derived
    real forms (migrated-group id-2^32 and channel -100...) map to the SAME
    folder. Returns {chat_id: folder}.
    """
    watch = {}
    for tok in raw_tokens:
        tok = tok.strip()
        if not tok:
            continue
        if ":" in tok:
            gid, folder = tok.split(":", 1)
            folder = norm_path(folder.strip())
        else:
            gid, folder = tok, default_dir
        n = int(gid.strip())
        keys = [n]
        if n < 0:
            keys += [n - 2**32, -(10**12 + abs(n))]   # same forms as before
        for k in keys:
            watch[k] = folder
    return watch

# --- groups to watch ---------------------------------------------------------
# The ids below are the ones from your web.telegram.org links
#   https://web.telegram.org/k/#-4361070602  ->  full chat_id -8656037898
#   https://web.telegram.org/k/#-3726820241  ->  full chat_id -8021787537
#   https://web.telegram.org/k/#-3744710110  ->  full chat_id -8039677406
# (web links show a "short" id; the full id = short id - 2^32).
# You can also set groups= (comma separated, short or full ids) in
# config.properties to override these.
WEB_IDS = [-4361070602, -3726820241, -3744710110]

def to_full_id(raw):
    """Accept a short (web) or full chat id; return the full negative id.

    Web links show a "short" id in the range (-2^32, 0); the full chat id is
    short - 2^32 (e.g. -4361070602 -> -8656037898). Anything at or below
    -2^32 is already a full id and is returned unchanged.
    """
    n = int(raw)
    if -2**32 < n < 0:           # short web id like -4361070602
        return n - 2**32
    return n

# --- signal detection (only to filter noise + name the file) -----------------
# Besides real BUY/SELL signals this also lets the channel's management
# replies through so the EA can act on them ("Moving SL to X", "Closing the
# signal"). They get file name MSG_... - the EA does not care about names.
SIGNAL_RE = re.compile(r"\b(BUY|SELL)\b"
                      r"|MOVING\s+SL|MOVE\s+SL|SL\s+MOVED|MOVING\s+STOP\s+LOSS|STOP\s+LOSS\s+MOVED"
                      r"|CLOSING\s+THE\s+SIGNAL|CLOSE\s+(THE\s+)?SIGNAL|SIGNAL\s+CLOSED", re.I)
PAIR_RE = re.compile(r"\b(BUY|SELL)\s+([A-Z][A-Z/]{2,11})", re.I)

def pair_of(text):
    m = PAIR_RE.search(text.upper())
    if not m:
        return "MSG"
    p = m.group(2).replace("/", "")
    if len(p) == 3:
        p += "USD"          # BTC->BTCUSD, XAU->XAUUSD, same rule as the EA
    return p

# Telegram threads management replies ("Moving SL to X", "Closing the
# signal") to the signal message they act on: we keep that link in the
# JSON (reply_to + reply_to_text) so the EA acts on the exact signal
# instead of guessing by pair name. seen_texts caches ids -> one-line
# text because the reply reference from Telegram may carry no text.
seen_texts = {}

def flat_line(s):
    return " ".join((s or "").split())

def reply_link_id(msg):
    # Where the link of a reply is found, by Telethon generation:
    # - 1.45+: msg.reply_to is a MessageReplyHeader -> .reply_to_msg_id
    # - older: msg.in_reply_to / msg.comment_id (may not exist anymore)
    # 0 = the message is not a reply.
    ref = getattr(msg, "reply_to", None)
    rid = getattr(ref, "reply_to_msg_id", 0) if ref is not None else 0
    if not rid:
        hdr = getattr(msg, "in_reply_to", None)
        rid = (getattr(hdr, "reply_to_msg_id", 0) if hdr is not None
               else getattr(msg, "comment_id", 0) or 0)
    return rid or 0

def write_signal_file(out_dir, msg, chat_id=0):
    ts = msg.date.strftime("%Y%m%d_%H%M%S")
    name = f"{pair_of(msg.text or 'MSG')}_{ts}_{msg.id}.json"
    rid = reply_link_id(msg)
    rtxt = seen_texts.get((chat_id, rid), "") if rid else ""
    payload = {
        "message_id": msg.id,
        "date": msg.date.isoformat(),
        "text": msg.text or "",
        "reply_to": rid,
        "reply_to_text": rtxt,
    }
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    tmp = out / (".tmp_" + name)
    final = out / name
    with open(tmp, "w", encoding="utf-16", newline="\r\n") as f:  # BOM + CRLF: MQL5 FILE_TXT native
        json.dump(payload, f, ensure_ascii=True)                   # content ASCII -> \uXXXX
        f.write("\r\n")
    os.replace(tmp, final)                            # atomic: EA never sees half-written files
    plog("info", f"[mt5-bridge] wrote signal file, full path: {out / name}")

# --- main ------------------------------------------------------------------
async def main():
    cfg = load_config(CONFIG)
    api_id = int(cfg["api_id"])
    api_hash = cfg["api_hash"]
    global LOG_THRESHOLD, USE_COLOR
    lvl = (cfg.get("log_level") or "info").strip().lower()
    if lvl in RANK:
        LOG_THRESHOLD = lvl
    col = (cfg.get("color") or "always").strip().lower()
    if col == "never":
        USE_COLOR = False
    elif col == "auto":
        USE_COLOR = sys.stdout.isatty()
    session = cfg.get("session_name", "minha_sessao")
    if not Path(session).is_absolute():
        # keep the Telethon session file next to the script/exe, so the login
        # is reused no matter which directory the bridge is launched from
        sess_dir = Path(sys.argv[0]).resolve().parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent
        session = str(sess_dir / Path(session).name)
    out_dir = cfg.get("mt5_folder") or str(BASE / "mt5_files" / "tg_signals")

    # groups: config.properties 'groups=' wins, else the WEB_IDS list above.
    # An entry may also be 'id:<absolute folder>' so that each group's files
    # go to its own MT5 sandbox folder (multi-broker / multi-terminal); bare
    # ids use mt5_folder. All derived real forms of an id share its folder.
    raw_groups = ([s for s in cfg["groups"].split(",") if s.strip()]
               if cfg.get("groups") else [str(i) for i in WEB_IDS])
    watch = parse_watch(raw_groups, out_dir)
    # event.chat_id is the SIGNED raw chat id (negative for groups/channels);
    # parse_watch registered every pasted and derived form → direct lookup.
    ignored_seen = set()   # print the real chat id of unwatched chats once

    if not cfg.get("mt5_folder"):
        plog("warn", f"[mt5-bridge] 'mt5_folder' not set in config.properties - "
             f"writing to local '{out_dir}' instead (the EA will not see files)")

    written = 0   # signal files written this run (shown on heartbeats)

    client = TelegramClient(session, api_id, api_hash)

    # 'async with client' connects AND performs the interactive login the
    # first time (browser URL); run_until_disconnected() alone would never
    # connect (that is what raised "Cannot send requests while disconnected").
    async with client:
        @client.on(events.NewMessage)
        async def ev(event):
            nonlocal written
            # filter first: only the watched groups, only BUY/SELL-looking messages
            folder = watch.get(event.chat_id)
            if folder is None:
                if event.chat_id not in ignored_seen:
                    ignored_seen.add(event.chat_id)
                    plog("warn", f"[mt5-bridge] message from unwatched chat {event.chat_id} "
                          f"- if it is one of your channels, paste that id into groups= "
                          f"of bridge/config.properties")
                return
            body = (event.message.text or event.message.caption or
                    event.message.title or "")
            one = " | ".join(body.splitlines())
            plog("debug", f"[mt5-bridge] message received from chat {event.chat_id}: "
                  f"{one[:90]}")
            msg = event.message
            # remember every message we saw, keyed by chat (ids repeat per
            # chat!), so a later reply can quote the text of the signal
            seen_texts[(event.chat_id, msg.id)] = flat_line(body)
            if len(seen_texts) > 800:
                seen_texts.pop(next(iter(seen_texts)))  # drop oldest
            rid0 = reply_link_id(msg)
            if rid0 and (event.chat_id, rid0) not in seen_texts:
                # cache missed (e.g. bridge restarted after the signal): fetch
                # the replied-to message so the link still carries its text
                try:
                    rf = await client.get_messages(event.chat_id, ids=rid0)
                    if rf:
                        seen_texts[(event.chat_id, rid0)] = flat_line(
                            rf.text or rf.caption or rf.title or "")
                except Exception:
                    pass
            if not msg.text or not SIGNAL_RE.search(msg.text):
                return
            write_signal_file(folder, msg, event.chat_id)
            written += 1

        folders = sorted(set(watch.values()))
        plog("info", f"[mt5-bridge] watching the {len(raw_groups)} configured groups "
              f"(ids as in the web.telegram.org links) into {len(folders)} output "
              f"folder(s): {', '.join(folders)} - Ctrl+C to stop")
        hb_min = 0
        try:
            hb_min = int(cfg.get("heartbeat_min", "10") or 0)
        except ValueError:
            hb_min = 0
        hb_task = None
        if hb_min > 0:
            # Proof-of-life: log a heartbeat line every hb_min minutes while
            # the watcher runs (journalctl -u tg-bridge, or bridge.log via
            # bridge/start_bridge.sh). Cancelled when the watch ends below.
            async def heartbeat_loop():
                while True:
                    await asyncio.sleep(hb_min * 60)
                    plog("info", f"[mt5-bridge] heartbeat: alive ({written} signal "
                          f"file(s) written so far)")
            hb_task = asyncio.ensure_future(heartbeat_loop())
        try:
            # Ends (returns or raises) when the Telegram connection ends; a
            # systemd service with Restart=always starts a fresh watch then.
            await client.run_until_disconnected()
        finally:
            if hb_task:
                hb_task.cancel()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        plog("info", "[mt5-bridge] stopped by user.")
    except Exception as e:
        plog("fatal", f"[mt5-bridge] fatal error: {e}")
        sys.exit(1)
