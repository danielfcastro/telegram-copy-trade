# Telegram Signal Copier — Expert Advisor for MetaTrader 5

An EA that reads trading signals from your Telegram channel/group and copies them
to live MT5 orders.

## Features

- **Real pending orders at the entry-zone edges**: `BUY STOP` at the upper edge
  (BUY signals) / `SELL LIMIT` at the lower edge (SELL signals); when the price is
  already at or past the edge — and always honoring the broker's **stops level** —
  it falls back to market orders instead of being rejected with "invalid price".
- **Three orders per signal** (one per TP, sharing one SL), with **risk-based
  sizing**: `InpRiskPct`% of Balance is the maximum loss per signal split across
  the orders (lots hard-clamped to [0.01..100]); fixed-lot fallback by category.
- **Break-even → trailing cascade**: when the TP1 order closes with profit the
  remaining SLs move to entry — only while `InpConservativeMode=true`; when the
  **middle (TP2)** order closes with profit, the farthest order gets a **trailing
  stop** that follows the price (`InpTrailPts`, default = the signal's risk
  distance). Expired untriggered pendings auto-deleted (`InpMaxAgeMin`).
- **Channel management replies are handled too**: "Moving SL to \<value>" relocates
  the stop on live positions *and* on untriggered pendings; "Closing the signal"
  closes everything when open P/L is positive, otherwise **shortens each SL toward
  the SMA** of the chart timeframe (`InpCloseMaPeriod`) and lets the stop decide.
- **Journal logs every order line in full**: `TYPE PAIR RISK% LOT TP SL` + why
  pending/market was chosen; `[DRY-RUN]` prints the exact same line while testing.
- **Signal files are never deleted**: processed files are moved to
  `tg_signals/consumed/` (the MQL5-native UTF-16 format) — full history of every
  signal the EA saw, for inspection and replay.
- **Python bridge, no bot**: Telethon on the public Telegram endpoints (web ids
  from `web.telegram.org` links are auto-derived to the real chat ids), leveled
  & colored logging (`debug < info < warn < error < fatal`), proof-of-life
  heartbeats, atomic UTF-16 file writes, daemon script + systemd unit.
- Symbols are **resolved against the current broker** (names like `XAUUSD!` are
  handled automatically); a pair-mask configuration is coming (roadmap below).
- **Roadmap (next)**: per-broker pair mask in config; multi-folder bridge output
  (one signals folder per watched group/broker).

## How to configure and run everything (step by step)

### 0. Repo layout

| Path | Role |
|------|------|
| `TelegramSignalCopier.mq5` | The Expert Advisor (your copy in MT5: `TelegramCopyTrade.mq5`) |
| `TelegramSignalCopier.set` | Ready-to-use input preset (`InpDryRun=true`, `InpRiskPct=3`) |
| `bridge/telegram_to_mt5.py` | Python watcher (Telethon): reads Telegram, writes one JSON per signal message |
| `bridge/config.properties` | Telegram credentials, watched groups and the MT5 output folder |
| `venv/` | Python environment with Telethon already installed (see step 2) — **not tracked** by git; rebuild it with step 2's commands |

### 1. Configure the bridge — `bridge/config.properties`

| Key | What to put |
|-----|-------------|
| `api_id` / `api_hash` | Your app credentials from <https://my.telegram.org> (own account) |
| `session_name` | Telethon session filename (login is saved here after the first run) |
| `groups=` | Comma-separated chat ids exactly as they appear in the `web.telegram.org` links — the bridge automatically also watches the two derived real forms (migrated-group `id − 2³²` and channel `−100…` form), so no conversion is needed |
| `log_level` | Logging verbosity `debug`/`info`/`warn`/`error`/`fatal` (default `info`: startup, written files, heartbeats; `debug` also logs every message received from watched channels) |
| `color` | `always` (default): the log file itself carries the ANSI color codes, so `tail -f bridge/bridge.log` shows colors in your terminal (`grep` then sees raw `^[[` codes — pipe through `sed 's/\x1b\[[0-9;]*m//g'` to strip). `auto` = only on a terminal, `never` = plain |
| `heartbeat_min` | Minutes between `[INFO] heartbeat: alive ...` proof-of-life lines (default 10; `0` = none) |
| `mt5_folder=` | **Absolute POSIX path** of the `tg_signals` folder **inside the MT5 data folder**. Under Wine the "C: drive" is the prefix, e.g. `~/.wine_mt5/drive_c/Program Files/MetaTrader 5/MQL5/Files/tg_signals` (already set in this repo) |

The old `vendor/` folder of the vendored project was **deleted entirely** (its
`TelegramReader.py`, `TradeExecutor.py`, `PositionMonitor.py`, `integration/`,
`start_all.py`, `start_bot.sh`, `docs/` etc. were never imported by the bridge). The
config now lives in `bridge/config.properties`, next to the script; the bridge finds
the config next to itself automatically (a standalone PyInstaller `.exe` reads the
`config.properties` sitting next to it — copy both together if you move things around).
`mt5_folder` values pasted from a shell (escaped `\ `, duplicated `//`, trailing `/`) are normalized automatically.

### 2. Run the bridge (normal Linux Python — never inside Wine or MT5 folders)

```bash
cd /mnt/data/projetos/telegram-copy-trade
python3 -m venv venv                      # already done in this repo
venv/bin/pip install telethon             # already installed: Telethon 1.45.0
venv/bin/python bridge/telegram_to_mt5.py # foreground: first run asks to log in via browser
```

- **First run**: Telethon prints a login URL — open it in a browser, type the code, and the `.session` file is saved next to the script; later runs start silently.
- **Keep it running** after the session exists:

```bash
nohup venv/bin/python bridge/telegram_to_mt5.py > bridge/bridge.log 2>&1 &
tail -f bridge/bridge.log
```

The bridge reads `config.properties` from next to the script (or next to the `.exe` if compiled), so keep the two files together if you copy them around; all it does is write JSON files into `mt5_folder`.

### 3. Install the EA in MT5

1. Copy `TelegramSignalCopier.mq5` into `<MT5 data folder>/MQL5/Experts/` (in your terminal that is the project `TelegramCopyTrade.mqproj`) and compile it in MetaEditor — 0 errors expected.
2. Load the inputs: open the EA on a chart and apply `TelegramSignalCopier.set` (or type the same values into the Inputs dialog; see the Inputs reference table below).
3. Attach the EA to any chart and keep the terminal's Auto-Trading ON.
4. Start with **`InpDryRun=true`** (as shipped): nothing is sent, the journal shows every pending/market order the EA *would* place. Set `InpDryRun=false` only when you want live orders.

### 4. Verify the chain end-to-end

- Bridge side: `tail -f bridge/bridge.log` shows watched groups and written files; check with `ls "…/MQL5/Files/tg_signals"` that `PAIR_*.json` files appear and get **moved into `consumed/`** by the EA (never deleted — every processed signal stays there for inspection).
- MT5 side: Terminal → Journal shows one line per order, always in the same format
  `order-type  PAIR  RISK=x%  LOT=x  TPn=x  SL=x  - why pending/market was chosen`:
  `PENDING SELL LIMIT XAUUSD RISK=3.00% LOT=0.02  TP3=4148  SL=4193  - price outside the zone: terminal will trigger it when price reaches 4171`
  or, price already past the zone edge: `MARKET BUY XAUUSD RISK=3.00% LOT=0.02  TP1=...  SL=...  - price already at/past the zone edge: market entry`.
  From a shell: `tail -f <data folder>/logs/…log`.
  From a shell: `tail -f <data folder>/logs/…log`.
- **Troubleshooting — "a message came but nothing was written"**: look for
  `[WARN] message from unwatched chat <id> ...` lines in the bridge log — they
  reveal the **real chat ids** of your channels; paste those ids into `groups=`
  (the web link id also works, the bridge derives the real forms by itself). Also confirm it's alive:
  `pgrep -af telegram_to_mt5` (start/stop via `bridge/start_bridge.sh`). A
  `database is locked` fatal error means you launched a **second** watcher while
  one was already running (both share the same Telethon session SQLite file) —
  stop one of them first (`bridge/start_bridge.sh stop` or `pkill -f telegram_to_mt5`)
  and then start exactly one.

### 5. What you should see happen to an order

1. Signal JSON read → **pending orders at the zone edge** (BUY STOP at the upper edge / SELL LIMIT at the lower edge, one per TP sharing the SL) — or market orders if the price already reached that edge.
2. Price hits the trigger level → the terminal converts them into live positions (SL/TP already attached).
3. The TP1 order closes with profit → the SL of the others moves to entry (breakeven)
   — **only while `InpConservativeMode=true` (the default)**; off, the original SLs
   stay. The TP2 order closes with profit → the last order (TP3) gets a trailing stop
   that follows the price (`InpTrailPts`, default = the signal's risk distance).
4. A pending never triggered and is older than `InpMaxAgeMin` minutes → the EA auto-deletes it.
5. Watcher side: heartbeats every `heartbeat_min` minutes prove liveness; when a signal
   arrives it logs `[INFO] wrote signal file, full path: .../PAIR_....json` (the whole
   absolute path of the file dropped into `tg_signals`).
6. Channel **management replies** also arrive as files (`MSG_*.json`) and adjust the
   active signal:
   - `Moving SL to <value>` → the shared SL moves to that value — applied to open
     positions (`PositionModify`) and to untriggered pendings (`OrderModify`).
   - `Closing the signal` → open P/L of that signal is computed: **positive** →
     every open position is closed and untriggered pendings deleted; **negative** →
     each SL is *shortened toward* the SMA of `InpCloseMaPeriod` on the chart
     timeframe (never loosened) and the stop decides the rest by itself.
   A reply that does not name the pair is acted on only when exactly **one** signal
   is active; otherwise the EA logs "skipped (ambiguous)". 

Signal files are **UTF-16 with BOM + CRLF** — the native text format of MQL5 `FILE_TXT`
(this is why MT5's own `.set`/state files look the same). From a shell, read them with
`iconv -f UTF-16LE -t UTF-8 <file>`; the files in `consumed/` keep exactly this format.

---

## Signal format handled

```
SELL BTCUSD
Entry: 82063-82157

TP1: 81987
TP2: 81485
TP3: 80910

SL 83092
```

- `BUY` / `SELL` + symbol (`BTCUSD`, `XAUUSD`, `ETHUSD`, any forex; `BTC`/`ETH`/`XAU`
  short forms are auto-expanded with `USD`)
- `Entry: low-high` — entry zone (also accepts `~` or `–` separators)
- `TP1/TP2/TP3` — three take-profit levels (a plain `TP:` is treated as TP1)
- `SL` / `STOP` / `S/L` — stop-loss
- Several signals may be packed in one message (they are split on `BUY`/`SELL` keywords)

## Copy logic (as requested)

1. The EA does **not** talk to Telegram. The Python bridge (`bridge/telegram_to_mt5.py`)
   reads your groups (Telethon login, `groups=` in `bridge/config.properties`)
   and writes one JSON file per relevant message into `MQL5\Files\tg_signals`. The EA
   rescans that folder every `InpPollSec` seconds (default 15, up to 20 files per scan).
2. The moment the signal JSON is read, the EA compares the current price against
   the entry zone and **immediately places real pending orders at the zone edge**
   — it never keeps a signal waiting "in memory":
   - **BUY** signal → a **Buy Stop at the upper edge** of the interval
     (`Entry: low-high` → trigger level `high`).
   - **SELL** signal → a **Sell Limit at the lower edge** of the interval
     (trigger level `low`).
   - The terminal itself triggers the pending when price reaches that edge
     (this also survives EA restarts — the pending lives on the account). The
     EA auto-deletes a pending that has not triggered after `InpMaxAgeMin`
     minutes (0 = never, keep waiting).
   - If the price has **already reached/passed that edge** when the signal is
     read, the pending would be invalid → market orders are sent instead
     (late entry). Signals without an entry zone also go straight to market
     orders.
3. For each defined TP the EA places **one separate order** (the pending at the
   edge, one per TP, all sharing the SL) with the **full lot**:
   ```
   SELL XAUUSD, Entry 4171-4173, TP1 4163 / TP2 4156 / TP3 4148, SL 4193
   → order 1: 0.01, TP 4163, SL 4193
   → order 2: 0.01, TP 4156, SL 4193
   → order 3: 0.01, TP 4148, SL 4193
   ```
4. **Profitable-close cascade** (the original rule + the trailing upgrade):
   - **TP1 order closes with profit** → the SL of the remaining open orders moves
     to their entry price (breakeven) — gated by **`InpConservativeMode`**
     (`true` = default, do the breakeven; `false` = keep the original SLs).
   - **TP2 order closes with profit** → the last order (TP3) does *not* stop at the
     entry: its SL is rearmed as a **TRAILING stop** — it starts at the entry and
     then follows the price, always keeping `InpTrailPts` of distance. Values:
     `-1` = auto (the signal's own risk distance `|entry−SL|`, the default),
     `0` = disabled (plain breakeven), `>0` = fixed distance in points.
     The trailing SL only ever ratchets toward profit — it never loosens.
   - Orders closed at SL or manually with a loss trigger nothing.

## Lot sizes (per order)

| Category | Detection | Default lot |
|----------|-----------|-------------|
| Gold | `XAU`, `XAG`, `GOLD` | `InpLotGold = 0.01` |
| Currencies (forex) | anything else | `InpLotForex = 0.2` |
| ETH | `ETH` | `InpLotETH = 0.3` |
| Bitcoin | `BTC`, `XBT` | `InpLotBTC = 0.03` |

Lots are normalized to the broker's volume step/minimum automatically.

## Running MT5 on Linux via Wine

MT5 under Wine works with this bridge — for Wine the "C: drive" **is your Wine
prefix**, so the whole setup is just filesystem paths:

1. Find the data folder **inside the terminal** (Help → About → Data Folder).
   With the default prefix it looks like
   `Z:\users\<username>\drive_c\users\<username>\AppData\Roaming\MetaQuotes\Terminal\<hash>\`,
   which on Linux is
   `~/.wine/drive_c/users/<username>/AppData/Roaming/MetaQuotes/Terminal/<hash>/`.
2. Set `mt5_folder` in `bridge/config.properties` to that path
   **in POSIX form** + `/MQL5/Files/tg_signals` (expand `~` to `/home/...`;
   the bridge writes files there with plain Python `open()`).
3. Run the bridge as normal Linux Python (`python3 bridge/telegram_to_mt5.py`).
   No Wine involved — it just writes files into the prefix.
4. The EA's file calls (`FileOpen`, `FileFindFirst`) work transparently: MT5 on
   Wine accepts `MQL5\Files\tg_signals\...` with backslashes and maps them to
   the prefix's `filesfos` directory automatically. Nothing else changes.
5. **Console/journal**: the EA's `Print`/`LogMsg` output goes to the terminal
   "Terminal→Journal" tab (same viewer under Wine). To watch it from a shell,
   `tail -f logs/*.log` inside the data folder — the file log contains the same
   journal lines.

**This repo is now configured for the actual setup** (`WINEPREFIX=/home/dfcastro/.wine_mt5`):

- `config.properties` → `mt5_folder=/home/dfcastro/.wine_mt5/drive_c/Program Files/MetaTrader 5/MQL5/Files/tg_signals`
  (the folder was pre-created; the bridge accepts the spaces in the path as-is).
- `TelegramSignalCopier.set` → `InpRiskPct=3` (3% of Balance at risk per signal), `InpDryRun=true` (flip to `false` only when you want live orders).

## Bridge mode (recommended — uses YOUR OWN Telegram account)

MT5 cannot log into Telegram directly, but a small Python watcher (Telethon,
user login with your own account) can. `bridge/telegram_to_mt5.py` watches the
groups you belong to and writes each BUY/SELL message as a JSON file
`PAIR_YYYYMMDD_HHMMSS_<msgid>.json` into the MT5 Files sandbox; the EA scans
that folder, parses the message text with its own parser (same logic as bot
mode), opens the trades and **moves** the file to the `consumed/` subfolder inside
the signals folder — nothing is ever deleted, so you can always review exactly
what each signal contained. No bot, no Bot API.

Files inside `consumed/` are **never reprocessed**: the scan skips any hit that
lies in a subfolder (names arriving as `consumed\...`) and any bridge temp file
`.tmp_*` (the bridge writes via a temp file and renames atomically).

The groups watched are configured in `bridge/config.properties`:

```
groups=-4361070602,-3726820241,-3744710110   # ids from web.telegram.org links
mt5_folder=C:\Users\you\AppData\Roaming\MetaQuotes\Terminal\<hash>\MQL5\Files\tg_signals
```

Web links show a "short" group id; the bridge converts it to the full chat id
automatically (full = short − 2³²), so pasting the ids from your browser URL
is fine.

Run it (see step 2 of the quickstart for the exact venv commands):

```bash
venv/bin/python bridge/telegram_to_mt5.py
```

- **First run**: Telethon prints a login URL (opens a browser), then saves a
  `.session` file next to the script — later runs start silently.
- **Optional standalone .exe** ("compile"): `pip install pyinstaller` and
  `pyinstaller --onefile --console bridge/telegram_to_mt5.py`.
- **Find the MT5 data folder**: in the terminal, Help → About → Data Folder.
  The EA only sees files under `<data folder>/MQL5/Files/`, so `mt5_folder`
  must point inside it (the `tg_signals` subfolder is created automatically by
  both the bridge and the EA).
- The EA scans the folder every `InpPollSec` seconds, max 20 files per scan,
  oldest first (file names sort by timestamp).

## Dry run & risk-based lot sizing

Two inputs control what the EA actually sends:

| Input | Meaning |
|-------|---------|
| `InpDryRun` | `true` = **no orders are sent at all**; the EA parses signals, checks the entry zone and prints what it *would* place (`[DRY-RUN] would place PENDING SELL LIMIT XAUUSD RISK=3.00% LOT=0.02  TP3=4148  SL=4193  - price outside the zone ...`) to the journal, in the exact order-line format. Use it to validate parser/zone logic before going live. |
| `InpRiskPct` | Lot sizing from risk instead of fixed lots. Set it to `x` to make the **maximum total loss of one signal = x% of your current Balance**. Leave `0` to use the fixed `InpLot*` values. |

How the risk lot is computed (per signal):

- The signal is split in `n` market orders (one per TP), all opened at the same
  price and sharing the same SL. Each order's loss = `|entry − SL| × lot ×
  (tickValue ÷ tickSize)`.
- Per-order risk = `Balance × x% ÷ n` (so all orders together never lose more
  than `x%` of the balance).
- `lot = perOrderRisk ÷ (|entry − SL| ÷ tickSize × tickValue)`, rounded down to
  the broker's volume step, then **clamped to [0.01 … 100]** exactly as you
  asked. If the clamp kicks in, the journal says so (risk served will be lower/
  higher than `x%`).
- The TPs define the *reward* (`entry → TPi`), not the risk, so they don't
  change the lot — they are printed in the log line for verification.

Example: `InpRiskPct=1.0` with a 10,000 balance and a SELL signal whose SL is
200 USD away → total allowed loss = 100 → each of the 3 orders may lose ~33.
XAUUSD at tick 0.01/0.01 (i.e. $1 per 0.01 move per 1 lot) → raw lot ≈ 0.11 →
normalized to the step → one 0.11-lot order per TP.

## Setup — installing the EA (the EA never authenticates with Telegram)

Telegram authentication (Telethon login), group selection (`groups=` in
`bridge/config.properties`) and the BUY/SELL filtering all live in
the Python side (`bridge/telegram_to_mt5.py`). The EA only consumes the JSON files
the bridge drops into `MQL5\Files\tg_signals`.

1. Copy `TelegramSignalCopier.mq5` into `<MT5 data folder>/MQL5/Experts/`, compile it
   (MetaEditor) and attach it to any chart with auto-trading enabled.
2. The shipped inputs are already correct for this repo's configuration
   (`InpSignalsFolder=tg_signals` matches the tail of `mt5_folder=` in config.properties).
3. The EA remembers the last processed message id in `MQL5/Files/tg_copier_state.txt`,
   so restarting never duplicates signals; processed JSON files are **moved** to
   `<signals folder>/consumed/` (kept as history — if something behaved oddly for
   one signal, open that file in `consumed/` and you have the exact text the EA saw).

## Inputs reference

| Input | Meaning |
|-------|---------|
| `InpPollSec` | Interval between scans of the signal folder, in seconds (default 15) |
| `InpMagic` | Magic number marking all EA orders (default 20261019) |
| `InpLotGold/Forex/ETH/BTC` | Lot **per order** per category |
| `InpMaxAgeMin` | Auto-delete untriggered **pending orders** after N minutes (default 120; `0` = never delete) |
| `InpMaxOpen` | Max simultaneous open positions/orders (default 15) |
| `InpZoneTolPct` | Widen the entry zone by % of its width — moves the pending trigger edge earlier by that amount (default 0) |
| `InpDevPoints` | Deviation in points, **only** used for the market-order fallback (default 30) |
| `InpConservativeMode` | `true` (default): when the **TP1** order closes with profit, remaining SLs move to breakeven. `false`: original SLs are kept — only the trailing cascade after TP2 applies |
| `InpCloseMaPeriod` | SMA period (current chart timeframe) used when a "Closing the signal" reply arrives with **negative** P/L: each SL is shortened toward that SMA and the stop finishes by itself; `0` = leave stops untouched |
| `InpTrailPts` | Trailing stop rearmed on the farthest open order after the **middle** TP closes: `-1` = auto — the signal's own risk distance `|entry−SL|` (default), `0` = disabled (plain breakeven), `>0` = fixed distance in points |
| `InpDebug` | Journal logging switch |
| `InpDryRun` | `true`: never send orders, only log what would be placed — `[DRY-RUN] would place PENDING SELL LIMIT XAUUSD RISK=3.00% LOT=0.02 TP3=4148 SL=4193 - ...` (order line format: type PAIR RISK LOT TP SL; default `false` in code; `true` in the shipped `.set`) |
| `InpRiskPct` | % of Balance risk per signal; `0` = fixed lots (default `0`) |
| `InpSignalsFolder` | Subfolder of `MQL5\Files` the bridge writes into (default `tg_signals`) |

## Notes / limitations

- Duplicate protection: a second signal for the same symbol+side is ignored while
  one is pending or open.
- On restart, untriggered **pending orders** and open positions with your magic
  number are both re-adopted: pendings keep waiting on the account (and their
  expiry clock restarts from the reload), positions keep their current SL/TP;
  the TP→breakeven rules then apply to the next closes. A **trailing** stop that
  was already armed stays at the last value applied (the EA stops following the
  price for it until the signal is tracked again).
- All EA orders carry comment `TG SIG` and your magic number, so you can manage
  them manually without affecting other positions.
