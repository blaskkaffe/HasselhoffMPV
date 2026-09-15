================================================================================
  MPV STATE MACHINE — SETUP GUIDE
================================================================================

FOLDER STRUCTURE (everything flat in content/)
-----------------------------------------------
content/
├── L0/                     ← default loop (ESC key)
├── L1/                     ← loop 1 (F1 key)
├── L1 - Christmas/         ← same as L1, label after " - " is cosmetic only
├── L2 - New Year/          ← loop 2 (F2 key)
├── M1/                     ← media mode (key "1")
├── M2 - Promos/            ← media mode (key "2")
├── Ma/                     ← media mode (key "a")
├── L1M2/                   ← override: plays instead of M2 when L1 is active
├── L1M2 - Christmas Ads/   ← same as L1M2
├── Intro/                  ← generic intro cutscene (fallback)
├── IntroM1/                ← intro for M1 specifically
├── IntroL1M1/              ← intro for M1 when L1 is active (most specific)
├── Outro/                  ← generic outro cutscene
├── OutroM1/                ← outro for M1
├── OutroL1M1/              ← outro for M1 when L1 is active
├── Transition/             ← generic loop-switch cutscene
└── TransitionL1/           ← cutscene played when switching TO L1

CUTSCENE FALLBACK CHAIN
------------------------
Most specific wins. Empty folder = skipped, falls back one tier.
  IntroL1M1 → IntroM1 → Intro → (no cutscene)
  OutroL1M1 → OutroM1 → Outro → (no cutscene)
  TransitionL1 → Transition   → (no cutscene)

FILE NAMING (inside any folder)
---------------------------------
Numbered files play in number order:
  01 - ambient loop.mp4
  02 - ambient loop 2.mp4
Files without numbers sort alphabetically.
Mix both fine — numbered always comes first.

AUTO KEYBINDS
--------------
  M1 → press 1      M2 → press 2      Ma → press a
  L0 → ESC          L1 → F1           L12 → F12
  L13+ → scheduler only (no F-key available beyond F12)

SCHEDULE.CFG FORMAT
--------------------
  # comment
  loop   L1   08:00   22:00    active window (supports overnight: 22:00 06:00)
  media  M2   12:00            one-shot trigger at noon daily

File order = priority. Lines lower in the file have HIGHER priority.
On conflict, the last matching entry wins.

CONFIG.CFG FORMAT (optional — overrides SECTION 2/3 without editing the script)
---------------------------------------------------------------------------------
  # comment
  key = value          global setting, matches a name from TUNING BEHAVIOUR below
                        (case-insensitive, e.g. "default_loop")

  [M1]                 media mode section — overrides just M1
  order = shuffle
  clips_per_trigger = 2

  [L1]                 loop section — overrides just L1
  order = pingpong

Values are auto-typed: true/false -> boolean, numbers -> number, else string.
Missing config.cfg = built-in defaults only. Unknown keys/sections are logged
and skipped, not fatal. config.cfg wins per-key over anything hard-coded in
mediaplayer.lua SECTION 3; keys it doesn't mention are left alone.
A commented-out template ships as config.cfg — uncomment what you need.

INSTALLATION ON LIVE USB
--------------------------
1. Copy mediaplayer.lua, schedule.cfg, config.cfg (optional), and content/ to your USB
2. Place mediaplayer.lua in MPV scripts folder:
     ~/.config/mpv/scripts/mediaplayer.lua
   Or launch directly:
     mpv --script=/path/to/mediaplayer.lua --idle --fs
3. Autostart (add to .xinitrc or session):
     mpv --script=/path/to/mediaplayer.lua --idle --fs &

TUNING BEHAVIOUR (via config.cfg, or edit mediaplayer.lua SECTION 2 directly)
---------------------------------------------------------------------------------
  LOCK_KEYS           = false   true = ignore keys while media plays
  KEY_CANCEL          = false   true = same key again cancels media
  CLIPS_PER_TRIGGER   = 1       clips per keypress (0 = infinite)
  SECONDS_PER_TRIGGER = 0       seconds per keypress (0 = use clip count)
  CUTSCENE_ON_TRIGGER = false   play intro before media
  CUTSCENE_ON_RETURN  = false   play outro after media
  CUTSCENE_ON_SWITCH  = false   play transition on loop switch
  LOOP_MUTED          = true    mute audio during loop playback
  FADE_DURATION       = 0.5     fade length in seconds

PER-MODE OVERRIDES (via config.cfg, or edit SECTION 3 in mediaplayer.lua)
--------------------------------------------------------------------------
  MODES.media_cfg = {
    M1 = { order="shuffle", clips_per_trigger=2, cutscene_on_trigger=true },
    M2 = { lock_keys=true, order="random" },
  }
  MODES.loop_cfg = {
    L1 = { order="pingpong", cutscene_on_switch=true },
  }

PLAYBACK ORDERS
----------------
  sequential   forward through files, wrap
  reverse      backward through files, wrap
  pingpong     forward then back then forward
  shuffle      no repeats until all played, then reshuffle
  random       pure random, may repeat

================================================================================
