--[[
================================================================================
  MPV STATE MACHINE MEDIA CONTROLLER
================================================================================
  A folder-driven state machine for MPV that handles:
    - Continuous background loop playback
    - Keyboard-triggered media modes (auto-bound from folder names)
    - Scheduled loop switching and media triggering
    - Per-loop content overrides (e.g. folder "L1M2" overrides "M2" during L1)
    - Configurable cutscene transitions (Intro, Outro, Transition)
    - Playlist ordering: sequential, reverse, ping-pong, shuffle, random
    - Priority-layered scheduler (file order = priority, bottom = highest)

  FOLDER NAMING CONVENTIONS (all folders live in ROOT):
    L0              → default loop (mapped to ESC key)
    L1              → loop 1 (mapped to F1)
    L1 - Christmas  → same as L1, human label after " - " is ignored
    L12             → loop 12 (mapped to F12)
    M1              → media mode 1 (mapped to key "1")
    M2 - Promos     → same as M2, human label ignored
    Ma              → media mode a (mapped to key "a")
    L1M2            → override: replaces M2 when L1 is active
    L1M2 - Label    → same as L1M2
    Intro           → generic intro cutscene (fallback)
    IntroM1         → intro for M1 specifically
    IntroL1M1       → intro for M1 when L1 is active (highest priority)
    Outro           → generic outro cutscene (fallback)
    OutroM1         → outro for M1 specifically
    OutroL1M1       → outro for M1 when L1 is active
    Transition      → generic loop-switch cutscene (fallback)
    TransitionL1    → cutscene played when switching TO L1

  FILE NAMING CONVENTIONS (inside any folder):
    01 - filename.mp4   → numbered (number defines order)
    filename.mp4        → alphabetical fallback

  CUTSCENE FALLBACK CHAIN (most specific wins, empty folder = skip tier):
    IntroL1M1 → IntroM1 → Intro   (then no cutscene if all empty/missing)
    OutroL1M1 → OutroM1 → Outro
    TransitionL1 → Transition

  KEYBINDS (auto-generated from folder scan):
    M1 → "1",  M2 → "2",  Ma → "a",  Mb → "b"
    L1 → F1,   L2 → F2,   L12 → F12, L0 → ESC

  LIVE USB NOTE:
    The script uses its own directory as the base path automatically.
    Launch with: mpv --script=/path/to/mediaplayer.lua --idle --fs

  EXTERNAL CONFIG (optional):
    Drop a config.cfg next to this script to override CONFIG defaults and
    add per-mode/per-loop overrides without editing this file. See SECTION 6.
================================================================================
--]]


-- ==============================================================================
-- SECTION 1: PATH CONFIGURATION
-- All folders live directly under ROOT. No subfolders needed.
-- ==============================================================================

-- Resolve the script's own directory safely.
-- mp.get_script_directory() can return nil when mpv starts in --idle mode
-- with no file loaded. We fall back to mp.get_script_info() and then to
-- the current working directory so the script always has a usable base path.
local function script_dir()
    -- Priority 1: explicit override via --script-opts=mediaplayer-root=/path/to/dir
    -- Use this when mpv can't resolve the script path automatically (e.g. --idle mode)
    local opt = mp.get_opt("mediaplayer-root")
    if opt and opt ~= "" then return opt end

    -- Priority 2: mpv built-in (works when a file is already loaded)
    local d = mp.get_script_directory()
    if d and d ~= "" then return d end

    -- Priority 3: parse from mp.get_script_info() on newer mpv builds
    local info = mp.get_script_info and mp.get_script_info()
    if info and info.filename then
        local dir = info.filename:match("^(.+)[/\\][^/\\]+$")
        if dir then return dir end
    end

    -- Priority 4: current working directory — requires cd into folder before launch
    return "."
end

local SCRIPT_DIR = script_dir()
mp.msg.info("[SM] Script directory: " .. SCRIPT_DIR)

local PATHS = {
    -- Root content directory. All L, M, override, and cutscene folders go here.
    ROOT = SCRIPT_DIR .. "/content/",

    -- Schedule and config files sit alongside the script
    SCHEDULE = SCRIPT_DIR .. "/schedule.cfg",
    CONFIG   = SCRIPT_DIR .. "/config.cfg",
}


-- ==============================================================================
-- SECTION 2: GLOBAL CONFIGURATION DEFAULTS
-- Per-mode overrides are stored in MODES.media[id] and MODES.loops[id].
-- These are the fallback values when no per-mode override exists.
-- ==============================================================================

local CONFIG = {
    -- Scheduler tick rate in seconds
    TICK_INTERVAL        = 1.0,

    -- The loop ID to use on startup (before scheduler kicks in)
    DEFAULT_LOOP         = "L0",

    -- Default playback order for loops and media
    -- Options: "sequential" | "reverse" | "pingpong" | "shuffle" | "random"
    DEFAULT_ORDER        = "sequential",

    -- Default cutscene playback order
    -- Options: "sequential" | "shuffle" | "random"
    CUTSCENE_ORDER       = "random",

    -- Clips to play per keyboard trigger. 0 = play until interrupted or timer.
    CLIPS_PER_TRIGGER    = 1,

    -- Seconds to play per keyboard trigger. 0 = use CLIPS_PER_TRIGGER instead.
    -- If both are non-zero, SECONDS_PER_TRIGGER takes precedence.
    SECONDS_PER_TRIGGER  = 0,

    -- When true: all keypresses are ignored while media is playing
    LOCK_KEYS            = false,

    -- When true: pressing the same key that triggered current media cancels it
    -- Only applies when LOCK_KEYS = false
    KEY_CANCEL           = false,

    -- Whether to play an intro cutscene when entering a media mode
    CUTSCENE_ON_TRIGGER  = true,

    -- Whether to play an outro cutscene when returning to loop from media
    CUTSCENE_ON_RETURN   = true,

    -- Whether to play a transition cutscene when switching loops
    CUTSCENE_ON_SWITCH   = true,

    -- Mute audio during loop playback (loops are usually silent ambience)
    LOOP_MUTED           = true,
}


-- ==============================================================================
-- SECTION 3: PER-MODE CONFIGURATION
-- media_cfg / loop_cfg can be populated two ways: hard-coded here, or via
-- config.cfg (Section 6) using [M1] / [L1] style sections. config.cfg wins
-- per-key on conflict; anything it doesn't mention keeps what's written here.
-- Each entry uses the mode ID (e.g. "M1", "L1") as the key.
-- Any key not set (here or in config.cfg) falls back to CONFIG defaults above.
-- ==============================================================================

local MODES = {
    -- Populated by scanner: { id, folder_path, label }
    loops  = {},   -- keyed by loop ID e.g. "L0", "L1"
    media  = {},   -- keyed by media ID e.g. "M1", "Ma"
    -- Populated by scanner: { loop_id, media_id, folder_path }
    overrides = {},  -- keyed by "L1M2" etc.

    -- Per-mode config overrides (optional — set here to override CONFIG defaults)
    -- Example:
    --   media_cfg = {
    --     M1 = { order="shuffle", clips_per_trigger=2, cutscene_on_trigger=true },
    --     M2 = { lock_keys=true, cutscene_on_return=false },
    --   }
    media_cfg = {},
    loop_cfg  = {},
}


-- ==============================================================================
-- SECTION 4: RUNTIME STATE
-- Live state of the system. Managed entirely by state machine functions.
-- Do not edit manually.
-- ==============================================================================

local STATE = {
    current_loop        = CONFIG.DEFAULT_LOOP,  -- active loop ID
    current_media       = nil,                  -- active media ID or nil
    phase               = "loop",               -- "loop" | "media" | "cutscene"
    in_cutscene         = false,                -- true while a cutscene plays
    cutscene_done       = nil,                  -- callback after cutscene ends

    playlists           = {},   -- per-folder playlist state (index, direction, pool)
    pending_loop        = nil,  -- deferred loop switch from scheduler
    pending_media       = nil,  -- deferred media trigger from scheduler

    media_timer         = nil,  -- handle for SECONDS_PER_TRIGGER timeout
    clips_played        = 0,    -- clips played in current media trigger
    active_trigger_key  = nil,  -- key that triggered current media (key_cancel logic)

    schedule_layers     = {},   -- parsed schedule events (index = file line = priority)
    _initialised        = false,
}


-- ==============================================================================
-- SECTION 5: UTILITIES
-- Low-level helpers used throughout the script.
-- ==============================================================================

local utils = require("mp.utils")

local function log(msg)  mp.msg.info("[SM] " .. tostring(msg))  end
local function warn(msg) mp.msg.warn("[SM] WARN: " .. tostring(msg)) end

-- Check whether a filesystem path exists
local function path_exists(p)
    return utils.file_info(p) ~= nil
end

-- Join path segments, handling trailing/leading slashes
local function join(...)
    local parts = {...}
    local r = parts[1]:gsub("/$", "")
    for i = 2, #parts do
        r = r .. "/" .. parts[i]:gsub("^/", ""):gsub("/$", "")
    end
    return r
end

-- Return the ID portion of a folder name, stripping " - Label" suffix.
-- e.g. "L1 - Christmas" → "L1", "M2 - Promos" → "M2", "L1M2" → "L1M2"
local function parse_folder_id(name)
    return name:match("^([^%-]+)") :gsub("%s+$", "")
end

-- Supported media file extensions
local MEDIA_EXT = {
    mp4=true, mkv=true, avi=true, mov=true, webm=true,
    flv=true, wmv=true, m4v=true,
    mp3=true, aac=true, wav=true, ogg=true, flac=true, m4a=true,
}

-- Scan a folder for playable files, sorted by leading number then alphabetically.
-- Returns an empty table (not nil) if folder is missing or empty.
local function scan_files(folder_path)
    local files = {}
    if not path_exists(folder_path) then return files end
    local entries = utils.readdir(folder_path, "files")
    if not entries then return files end

    for _, name in ipairs(entries) do
        local ext = name:match("%.([^%.]+)$")
        if ext and MEDIA_EXT[ext:lower()] then
            table.insert(files, {
                name   = name,
                path   = join(folder_path, name),
                number = tonumber(name:match("^(%d+)")),
            })
        end
    end

    table.sort(files, function(a, b)
        if a.number and b.number then return a.number < b.number
        elseif a.number then return true
        elseif b.number then return false
        else return a.name < b.name end
    end)
    return files
end

-- Shallow copy of an array table
local function copy(t)
    local c = {}
    for i, v in ipairs(t) do c[i] = v end
    return c
end

-- Read a per-mode config value, falling back to global CONFIG
local function mcfg(media_id, key)
    local cfg_key = key:upper()
    if media_id and MODES.media_cfg[media_id] then
        local v = MODES.media_cfg[media_id][key]
        if v ~= nil then return v end
        -- Also check uppercase variant
        v = MODES.media_cfg[media_id][cfg_key]
        if v ~= nil then return v end
    end
    -- Fall back to global CONFIG (try both "key" and "DEFAULT_KEY" forms)
    if CONFIG["DEFAULT_" .. cfg_key] ~= nil then
        return CONFIG["DEFAULT_" .. cfg_key]
    end
    return CONFIG[cfg_key]
end

local function lcfg(loop_id, key)
    local cfg_key = key:upper()
    if loop_id and MODES.loop_cfg[loop_id] then
        local v = MODES.loop_cfg[loop_id][key]
        if v ~= nil then return v end
        v = MODES.loop_cfg[loop_id][cfg_key]
        if v ~= nil then return v end
    end
    if CONFIG["DEFAULT_" .. cfg_key] ~= nil then
        return CONFIG["DEFAULT_" .. cfg_key]
    end
    return CONFIG[cfg_key]
end


-- ==============================================================================
-- SECTION 6: EXTERNAL CONFIG LOADER
-- Reads config.cfg (optional — built-in defaults above apply if it's missing).
-- Lets you tune CONFIG and add per-mode/per-loop overrides without touching
-- this script, so a live USB deployment only ever needs plain-text edits.
--
-- CONFIG.CFG FORMAT:
--   # comment
--   key = value              global override — key must match a CONFIG.* field
--                             (case-insensitive, e.g. "default_loop" → DEFAULT_LOOP)
--
--   [M1]                     media mode section → MODES.media_cfg["M1"]
--   order = shuffle
--   clips_per_trigger = 2
--
--   [L1]                     loop section → MODES.loop_cfg["L1"]
--   order = pingpong
--   cutscene_on_switch = true
--
-- Values are auto-typed: "true"/"false" → boolean, numeric strings → number,
-- anything else stays a string. Unknown global keys and section headers are
-- warned about (mp.msg) and skipped rather than failing the whole file.
-- config.cfg values win per-key over anything hard-coded in SECTION 3; keys
-- not mentioned in config.cfg keep whatever SECTION 3 (or the CONFIG default)
-- already had.
-- ==============================================================================

-- Coerce a raw string value to boolean / number / string.
local function parse_cfg_value(raw)
    local v   = raw:match("^%s*(.-)%s*$")
    local low = v:lower()
    if low == "true"  then return true  end
    if low == "false" then return false end
    local n = tonumber(v)
    if n ~= nil then return n end
    return v
end

local function load_config()
    if not path_exists(PATHS.CONFIG) then
        log("No external config file: " .. PATHS.CONFIG .. " — using built-in defaults")
        return
    end

    local f = io.open(PATHS.CONFIG, "r")
    if not f then
        warn("Cannot open config: " .. PATHS.CONFIG)
        return
    end

    local section  = nil  -- nil = global scope, or {kind="media"|"loop"|"invalid", id=...}
    local line_num = 0
    local applied  = 0

    for raw_line in f:lines() do
        line_num = line_num + 1
        -- Strip "# ..." comments (rest of line), then trim whitespace
        local line = raw_line:gsub("#.*$", ""):match("^%s*(.-)%s*$")

        if line ~= "" then
            local header = line:match("^%[%s*(.-)%s*%]$")
            if header then
                if header:match("^L%d+$") then
                    section = { kind = "loop", id = header }
                elseif header:match("^M[%d%l]$") then
                    section = { kind = "media", id = header }
                else
                    warn("config.cfg line " .. line_num .. ": unknown section [" .. header .. "]")
                    section = { kind = "invalid" }
                end
            else
                local key, val = line:match("^([%w_]+)%s*=%s*(.+)$")
                if not key then
                    warn("config.cfg line " .. line_num .. ": cannot parse: " .. line)
                else
                    local value = parse_cfg_value(val)
                    if not section then
                        local cfg_key = key:upper()
                        if CONFIG[cfg_key] ~= nil then
                            CONFIG[cfg_key] = value
                            applied = applied + 1
                        else
                            warn("config.cfg line " .. line_num .. ": unknown global key '" .. key .. "'")
                        end
                    elseif section.kind == "media" then
                        MODES.media_cfg[section.id] = MODES.media_cfg[section.id] or {}
                        MODES.media_cfg[section.id][key:lower()] = value
                        applied = applied + 1
                    elseif section.kind == "loop" then
                        MODES.loop_cfg[section.id] = MODES.loop_cfg[section.id] or {}
                        MODES.loop_cfg[section.id][key:lower()] = value
                        applied = applied + 1
                    end
                    -- section.kind == "invalid": already warned at the header, drop silently
                end
            end
        end
    end
    f:close()
    log("Config loaded: " .. applied .. " value(s) from " .. PATHS.CONFIG)
end


-- ==============================================================================
-- SECTION 7: FOLDER SCANNER
-- Scans ROOT for all L, M, override, and cutscene folders.
-- Populates MODES.loops, MODES.media, MODES.overrides.
-- Auto-generates keybindings from folder names.
-- ==============================================================================

local function scan_root()
    local entries = utils.readdir(PATHS.ROOT, "dirs")
    if not entries then
        warn("Cannot read ROOT folder: " .. PATHS.ROOT)
        return
    end

    for _, name in ipairs(entries) do
        local id = parse_folder_id(name)
        local folder_path = join(PATHS.ROOT, name)

        -- ---------------------------------------------------------------
        -- Loop folders: start with L followed by one or more digits
        -- e.g. "L0", "L1", "L12 - Christmas"
        -- ---------------------------------------------------------------
        local loop_num = id:match("^L(%d+)$")
        if loop_num then
            local loop_id = "L" .. loop_num
            MODES.loops[loop_id] = {
                id    = loop_id,
                path  = folder_path,
                label = name:match("^[^%-]+%-%s*(.+)$") or loop_id,
                num   = tonumber(loop_num),
            }
            log("Loop found: " .. loop_id .. " → " .. folder_path)
        end

        -- ---------------------------------------------------------------
        -- Media folders: start with M followed by a digit or lowercase letter
        -- e.g. "M1", "M2 - Promos", "Ma", "Mb - Special"
        -- ---------------------------------------------------------------
        local media_char = id:match("^M([%d%l])$")
        if media_char then
            local media_id = "M" .. media_char
            MODES.media[media_id] = {
                id    = media_id,
                path  = folder_path,
                label = name:match("^[^%-]+%-%s*(.+)$") or media_id,
                char  = media_char,
            }
            log("Media found: " .. media_id .. " → " .. folder_path)
        end

        -- ---------------------------------------------------------------
        -- Override folders: L followed by digits then M followed by digit/letter
        -- e.g. "L1M2", "L1Ma", "L1M2 - Christmas version"
        -- ---------------------------------------------------------------
        local ov_loop, ov_media = id:match("^(L%d+)(M[%d%l])$")
        if ov_loop and ov_media then
            local ov_id = ov_loop .. ov_media
            MODES.overrides[ov_id] = {
                id        = ov_id,
                loop_id   = ov_loop,
                media_id  = ov_media,
                path      = folder_path,
                label     = name:match("^[^%-]+%-%s*(.+)$") or ov_id,
            }
            log("Override found: " .. ov_id .. " → " .. folder_path)
        end

        -- Cutscene folders (Intro, Outro, Transition + variants) are resolved
        -- dynamically in Section 9 — no pre-registration needed.
    end
end


-- ==============================================================================
-- SECTION 8: KEYBINDING (auto-generated after folder scan)
-- M folders → digit/letter key. L folders → Fkey. L0 → ESC.
-- ==============================================================================

-- Forward declarations
local handle_media_key
local handle_loop_key

local function register_keybinds()
    -- Media keybinds: character after M becomes the key
    for media_id, info in pairs(MODES.media) do
        local key = info.char  -- e.g. "1", "2", "a", "b"
        local mid = media_id   -- capture for closure
        mp.add_key_binding(key, "media_" .. mid, function()
            handle_media_key(mid, key)
        end)
        log("Keybind: [" .. key .. "] → " .. mid)
    end

    -- Loop keybinds: L0 → ESC, L1 → F1, L2 → F2 ... L12 → F12
    for loop_id, info in pairs(MODES.loops) do
        local n   = info.num
        local lid = loop_id
        local key
        if n == 0 then
            key = "ESC"
        elseif n >= 1 and n <= 12 then
            key = "F" .. n
        else
            -- L13+ have no automatic F-key (F-keys only go to F12)
            -- They can still be triggered by the scheduler
            warn("No F-key available for " .. loop_id .. " (> L12) — scheduler only")
        end

        if key then
            mp.add_key_binding(key, "loop_" .. lid, function()
                handle_loop_key(lid)
            end)
            log("Keybind: [" .. key .. "] → " .. lid)
        end
    end
end


-- ==============================================================================
-- SECTION 9: CUTSCENE RESOLVER
-- Finds the best matching cutscene folder using the fallback chain.
-- Returns a folder path if a non-empty match is found, or nil.
--
-- Fallback chains:
--   Intro:      IntroL{n}M{x} → IntroM{x} → Intro
--   Outro:      OutroL{n}M{x} → OutroM{x} → Outro
--   Transition: TransitionL{n} → Transition
-- Empty folder = intentional skip (stops fallback chain, returns nil).
-- Missing folder = fall through to next tier.
-- ==============================================================================

-- Returns path+true if folder exists and has files.
-- Returns nil+true if folder exists but is empty (intentional skip).
-- Returns nil+false if folder does not exist (fall through).
local function usable_folder(path)
    if not path_exists(path) then return nil, false end
    local files = scan_files(path)
    if #files > 0 then return path, true end
    return nil, true  -- exists but empty — intentional skip
end

local function resolve_cutscene(prefix, loop_id, media_id)
    -- Tier 1: most specific — loop + media
    if loop_id and media_id then
        local p, exists = usable_folder(join(PATHS.ROOT, prefix .. loop_id .. media_id))
        if exists then return p end
    end
    -- Tier 2: media only
    if media_id then
        local p, exists = usable_folder(join(PATHS.ROOT, prefix .. media_id))
        if exists then return p end
    end
    -- Tier 3: loop only (used for Transition)
    if loop_id and not media_id then
        local p, exists = usable_folder(join(PATHS.ROOT, prefix .. loop_id))
        if exists then return p end
    end
    -- Tier 4: generic fallback
    local p = usable_folder(join(PATHS.ROOT, prefix))
    return p  -- nil if nothing found
end

-- ==============================================================================
-- SECTION 10: PLAYLIST ENGINE
-- Per-folder playlist state. Tracks position, direction, shuffle pool.
-- ==============================================================================

local function get_playlist(folder_path)
    if not STATE.playlists[folder_path] then
        local files = scan_files(folder_path)
        STATE.playlists[folder_path] = {
            files     = files,
            index     = 1,
            direction = 1,       -- 1=forward, -1=reverse (pingpong)
            pool      = copy(files),
        }
        log("Playlist init: " .. folder_path .. " (" .. #files .. " files)")
    end
    return STATE.playlists[folder_path]
end

local function next_file(folder_path, order)
    local pl = get_playlist(folder_path)
    if #pl.files == 0 then
        warn("Empty playlist: " .. folder_path)
        return nil
    end

    if order == "random" then
        return pl.files[math.random(1, #pl.files)]

    elseif order == "shuffle" then
        if #pl.pool == 0 then
            pl.pool = copy(pl.files)
        end
        local i    = math.random(1, #pl.pool)
        local file = pl.pool[i]
        table.remove(pl.pool, i)
        return file

    elseif order == "reverse" then
        local file = pl.files[pl.index]
        pl.index   = pl.index - 1
        if pl.index < 1 then pl.index = #pl.files end
        return file

    elseif order == "pingpong" then
        local file = pl.files[pl.index]
        pl.index   = pl.index + pl.direction
        if pl.index > #pl.files then
            pl.direction = -1
            pl.index     = math.max(1, #pl.files - 1)
        elseif pl.index < 1 then
            pl.direction = 1
            pl.index     = math.min(#pl.files, 2)
        end
        return file

    else  -- sequential (default)
        local file = pl.files[pl.index]
        pl.index   = pl.index + 1
        if pl.index > #pl.files then pl.index = 1 end
        return file
    end
end


-- ==============================================================================
-- SECTION 11: OVERRIDE RESOLVER
-- Finds the right content folder for a media mode given the active loop.
-- Priority: L{n}M{x} override → default M{x} folder
-- ==============================================================================

local function resolve_media_folder(media_id)
    -- Check for a loop-specific override first
    local ov_id   = STATE.current_loop .. media_id  -- e.g. "L1M2"
    local override = MODES.overrides[ov_id]
    if override then
        log("Override active: " .. ov_id)
        return override.path
    end
    -- Fall back to the default media folder
    local info = MODES.media[media_id]
    if info then return info.path end
    return nil
end

local function resolve_loop_folder(loop_id)
    local info = MODES.loops[loop_id]
    if info then return info.path end
    return nil
end


-- ==============================================================================
-- SECTION 12: PLAYBACK ENGINE
-- Core state transitions: loop → cutscene → media → cutscene → loop
-- ==============================================================================

-- Forward declarations
local play_loop, play_media, play_cutscene, return_to_loop, switch_loop

play_loop = function()
    STATE.phase             = "loop"
    STATE.current_media     = nil
    STATE.clips_played      = 0
    STATE.active_trigger_key = nil
    STATE.in_cutscene       = false

    local folder = resolve_loop_folder(STATE.current_loop)
    if not folder then
        warn("No folder for loop: " .. STATE.current_loop)
        return
    end

    local order = lcfg(STATE.current_loop, "order") or CONFIG.DEFAULT_ORDER
    local file  = next_file(folder, order)
    if not file then
        warn("No files in loop folder: " .. folder .. " — retrying in 2s")
        mp.add_timeout(2.0, play_loop)
        return
    end

    mp.set_property_bool("mute", CONFIG.LOOP_MUTED)
    log("Loop clip: " .. file.name)
    mp.commandv("loadfile", file.path, "replace")
end

-- play_cutscene: pick a clip from folder, set cutscene state, call on_done when it ends
play_cutscene = function(folder, on_done)
    local order = CONFIG.CUTSCENE_ORDER or "random"
    local file  = next_file(folder, order)
    if not file then
        warn("No files in cutscene folder: " .. folder)
        if on_done then on_done() end
        return
    end

    log("Cutscene: " .. file.name)
    STATE.in_cutscene   = true
    STATE.phase         = "cutscene"
    STATE.cutscene_done = on_done
    mp.set_property_bool("mute", false)
    mp.commandv("loadfile", file.path, "replace")
end

play_media = function(media_id, trigger_key)
    local folder = resolve_media_folder(media_id)
    if not folder then
        log("No folder for media: " .. media_id .. " — ignoring")
        return
    end

    -- Check for intro cutscene (skip if we are already inside a cutscene chain)
    local play_intro = mcfg(media_id, "cutscene_on_trigger")
    if play_intro == nil then play_intro = CONFIG.CUTSCENE_ON_TRIGGER end

    if play_intro and not STATE.in_cutscene then
        local cf = resolve_cutscene("Intro", STATE.current_loop, media_id)
        if cf then
            play_cutscene(cf, function()
                play_media(media_id, trigger_key)
            end)
            return
        end
    end

    -- Update state
    STATE.phase              = "media"
    STATE.current_media      = media_id
    STATE.clips_played       = 0
    STATE.active_trigger_key = trigger_key
    STATE.in_cutscene        = false

    -- Start seconds timer if configured
    local seconds = mcfg(media_id, "seconds_per_trigger") or CONFIG.SECONDS_PER_TRIGGER
    if seconds and seconds > 0 then
        if STATE.media_timer then STATE.media_timer:kill() end
        STATE.media_timer = mp.add_timeout(seconds, function()
            log("Media timed out (" .. seconds .. "s)")
            STATE.media_timer = nil
            return_to_loop()
        end)
    end

    mp.set_property_bool("mute", false)

    local order = mcfg(media_id, "order") or CONFIG.DEFAULT_ORDER
    local file  = next_file(folder, order)
    if not file then
        warn("No files for media: " .. media_id)
        return_to_loop()
        return
    end

    log("Media clip: " .. file.name .. " [" .. media_id .. "]")
    mp.commandv("loadfile", file.path, "replace")
end

return_to_loop = function()
    -- Cancel any running seconds timer
    if STATE.media_timer then
        STATE.media_timer:kill()
        STATE.media_timer = nil
    end

    -- If scheduler posted a loop switch while media was playing, apply it now
    if STATE.pending_loop then
        local new_loop = STATE.pending_loop
        STATE.pending_loop = nil
        switch_loop(new_loop)
        return
    end

    -- Check for outro cutscene
    local media_id   = STATE.current_media
    local play_outro = mcfg(media_id, "cutscene_on_return")
    if play_outro == nil then play_outro = CONFIG.CUTSCENE_ON_RETURN end

    if play_outro and media_id then
        local cf = resolve_cutscene("Outro", STATE.current_loop, media_id)
        if cf then
            play_cutscene(cf, function() play_loop() end)
            return
        end
    end

    play_loop()
end

switch_loop = function(new_loop_id)
    if new_loop_id == STATE.current_loop then
        log("Loop switch ignored — already on " .. new_loop_id)
        return
    end
    -- If the target loop folder does not exist, stay on current loop
    if not MODES.loops[new_loop_id] then
        warn("Loop switch aborted — no folder for: " .. new_loop_id .. " (staying on " .. STATE.current_loop .. ")")
        return
    end
    log("Switching loop: " .. STATE.current_loop .. " → " .. new_loop_id)

    local play_trans = lcfg(new_loop_id, "cutscene_on_switch")
    if play_trans == nil then play_trans = CONFIG.CUTSCENE_ON_SWITCH end

    STATE.current_loop  = new_loop_id
    STATE.current_media = nil
    STATE.phase         = "loop"

    if play_trans then
        local cf = resolve_cutscene("Transition", new_loop_id, nil)
        if cf then
            play_cutscene(cf, function() play_loop() end)
            return
        end
    end

    play_loop()
end


-- ==============================================================================
-- SECTION 13: CLIP END HANDLER
-- Called by MPV every time a file finishes. Drives the state machine forward.
-- ==============================================================================

local function on_clip_end(event)
    -- Log every end-file event so we can see exactly what mpv is reporting
    log("end-file: reason=" .. tostring(event.reason) ..
        " phase=" .. tostring(STATE.phase) ..
        " in_cutscene=" .. tostring(STATE.in_cutscene))

    -- "replace" fires when we call loadfile() to load the next file.
    -- "quit" fires on mpv exit. Both must be ignored or they corrupt state.
    if event.reason == "replace" or event.reason == "quit" then return end

    -- Cutscene just finished — fire its callback.
    -- Check both in_cutscene flag AND phase so either catches it.
    if STATE.in_cutscene or STATE.phase == "cutscene" then
        log("Cutscene end fired — calling callback")
        STATE.in_cutscene = false
        STATE.phase       = "loop"  -- safe default; callback will set correct phase
        local done = STATE.cutscene_done
        STATE.cutscene_done = nil
        if done then done() end
        return
    end

    -- Media mode: decide whether to play another clip or return to loop
    if STATE.phase == "media" then
        local media_id  = STATE.current_media
        local clips_max = mcfg(media_id, "clips_per_trigger") or CONFIG.CLIPS_PER_TRIGGER

        STATE.clips_played = STATE.clips_played + 1

        -- 0 = play indefinitely (until timer or interrupt)
        if clips_max == 0 then
            play_media(media_id, STATE.active_trigger_key)
            return
        end

        if STATE.clips_played < clips_max then
            play_media(media_id, STATE.active_trigger_key)
            return
        end

        log("Clip limit reached (" .. clips_max .. ") — returning to loop")
        return_to_loop()
        return
    end

    -- Loop mode: check for deferred scheduler events, then play next loop clip
    if STATE.phase == "loop" then
        if STATE.pending_loop then
            local new_loop = STATE.pending_loop
            STATE.pending_loop = nil
            switch_loop(new_loop)
            return
        end
        if STATE.pending_media then
            local mid = STATE.pending_media
            STATE.pending_media = nil
            play_media(mid, nil)
            return
        end
        play_loop()
        return
    end
end

mp.register_event("end-file", on_clip_end)


-- ==============================================================================
-- SECTION 14: KEY HANDLERS
-- ==============================================================================

handle_media_key = function(media_id, trigger_key)
    -- Always ignore keypresses during a cutscene
    if STATE.in_cutscene then
        log("Key ignored (in cutscene)")
        return
    end

    -- No matching folder — silently ignore
    if not MODES.media[media_id] and not MODES.overrides[STATE.current_loop .. media_id] then
        return
    end

    if STATE.phase == "media" then
        local active_id  = STATE.current_media
        local lock       = mcfg(active_id, "lock_keys")
        if lock == nil then lock = CONFIG.LOCK_KEYS end

        -- Lock mode: ignore all keys while media plays
        if lock then
            log("Key ignored (lock_keys on " .. active_id .. ")")
            return
        end

        -- Same key pressed again
        if trigger_key == STATE.active_trigger_key then
            local cancel = mcfg(active_id, "key_cancel")
            if cancel == nil then cancel = CONFIG.KEY_CANCEL end
            if cancel then
                log("Same key — cancelling " .. active_id)
                return_to_loop()
            else
                log("Same key — ignored (key_cancel off)")
            end
            return
        end

        -- Different key: interrupt current media immediately
        log("Interrupting " .. active_id .. " → " .. media_id)
        if STATE.media_timer then
            STATE.media_timer:kill()
            STATE.media_timer = nil
        end
        play_media(media_id, trigger_key)
        return
    end

    -- Loop mode: trigger media normally
    play_media(media_id, trigger_key)
end

handle_loop_key = function(loop_id)
    if STATE.in_cutscene then
        log("Loop key ignored (in cutscene)")
        return
    end
    -- Already on this loop — do nothing
    if loop_id == STATE.current_loop then
        log("Loop key ignored — already on " .. loop_id)
        return
    end
    -- Interrupt media if playing, then switch loop
    if STATE.media_timer then
        STATE.media_timer:kill()
        STATE.media_timer = nil
    end
    switch_loop(loop_id)
end


-- ==============================================================================
-- SECTION 15: SCHEDULER
-- Reads schedule.cfg. File line order = priority (bottom line = highest).
-- Evaluates on each tick; highest-priority matching loop event wins.
-- Media events fire once per minute at their scheduled time.
--
-- SCHEDULE.CFG FORMAT:
--   # comment lines start with #
--   loop   L1   08:00   22:00    (active during window; overnight wraps work)
--   media  M2   12:00            (one-shot trigger at this time each day)
--
-- Lower in the file = higher priority. On conflict, last matching entry wins.
-- ==============================================================================

local function parse_hhmm(str)
    if not str then return nil end
    local h, m = str:match("^(%d+):(%d+)$")
    if h and m then return tonumber(h) * 60 + tonumber(m) end
    return nil
end

local function minutes_now()
    local t = os.date("*t")
    return t.hour * 60 + t.min
end

local function load_schedule()
    STATE.schedule_layers = {}
    if not path_exists(PATHS.SCHEDULE) then
        log("No schedule file: " .. PATHS.SCHEDULE)
        return
    end

    local f = io.open(PATHS.SCHEDULE, "r")
    if not f then
        warn("Cannot open schedule: " .. PATHS.SCHEDULE)
        return
    end

    local line_num = 0
    for line in f:lines() do
        line_num = line_num + 1
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") then
            local parts = {}
            for p in line:gmatch("%S+") do table.insert(parts, p) end

            if #parts >= 3 then
                local etype     = parts[1]:lower()
                local eid       = parts[2]
                local start_min = parse_hhmm(parts[3])
                local end_min   = parts[4] and parse_hhmm(parts[4]) or nil

                if start_min then
                    table.insert(STATE.schedule_layers, {
                        type      = etype,
                        id        = eid,
                        start_min = start_min,
                        end_min   = end_min,
                        priority  = line_num,   -- lower line = lower priority
                        fired     = false,
                        _last_min = -1,
                    })
                    log("Schedule [line " .. line_num .. "]: " .. etype .. " " .. eid)
                else
                    warn("Bad time on schedule line " .. line_num)
                end
            end
        end
    end
    f:close()
    log("Schedule loaded: " .. #STATE.schedule_layers .. " entries")
end

local function evaluate_schedule()
    local now_min = minutes_now()

    -- Walk all layers in file order (lowest priority first).
    -- For loop events, each matching entry overwrites the previous candidate —
    -- so the last (highest priority) match is what we end up with.
    local winning_loop  = nil
    local media_fires   = {}

    for _, ev in ipairs(STATE.schedule_layers) do
        if ev.type == "loop" and ev.end_min then
            local active
            if ev.start_min <= ev.end_min then
                active = now_min >= ev.start_min and now_min < ev.end_min
            else
                -- Overnight window e.g. 22:00–06:00
                active = now_min >= ev.start_min or now_min < ev.end_min
            end
            if active then
                winning_loop = ev.id   -- later entry overwrites earlier
            end

        elseif ev.type == "media" then
            -- Reset one-shot flag each new minute
            if now_min ~= ev._last_min then
                ev._last_min = now_min
                ev.fired     = false
            end
            if now_min == ev.start_min and not ev.fired then
                ev.fired = true
                table.insert(media_fires, ev.id)
            end
        end
    end

    -- No matching loop event → fall back to default
    local target_loop = winning_loop or CONFIG.DEFAULT_LOOP

    -- Apply loop switch if needed
    if target_loop ~= STATE.current_loop then
        if STATE.phase == "media" or STATE.in_cutscene then
            -- Defer: switch after current clip ends
            if STATE.pending_loop ~= target_loop then
                log("Scheduler: pending loop → " .. target_loop)
                STATE.pending_loop = target_loop
            end
        else
            switch_loop(target_loop)
        end
    end

    -- Apply media triggers (defer if busy)
    for _, mid in ipairs(media_fires) do
        log("Scheduler: trigger " .. mid)
        if STATE.phase == "media" or STATE.in_cutscene then
            STATE.pending_media = mid
        else
            play_media(mid, nil)
        end
    end
end

local function start_scheduler()
    mp.add_periodic_timer(CONFIG.TICK_INTERVAL, function()
        evaluate_schedule()
    end)
    log("Scheduler running (tick=" .. CONFIG.TICK_INTERVAL .. "s)")
end


-- ==============================================================================
-- SECTION 16: INITIALISATION
-- Runs once after MPV is ready. Scans folders, registers keys, starts scheduler.
-- ==============================================================================

local function init()
    log("MPV State Machine starting...")
    math.randomseed(os.time())

    -- Load external config.cfg first — everything downstream (scheduler tick
    -- rate, default loop, per-mode overrides) should see the final values.
    load_config()
    STATE.current_loop = CONFIG.DEFAULT_LOOP  -- re-sync: STATE was built before config.cfg was read

    -- MPV options for unattended kiosk playback
    mp.set_property("loop-file",     "no")
    mp.set_property("loop-playlist", "no")
    -- keep-open=no is critical: allows end-file to fire when a clip finishes.
    -- keep-open=yes causes mpv to pause on the last frame instead of firing
    -- the end-file event, which breaks the state machine entirely.
    mp.set_property("keep-open",     "no")
    mp.set_property("idle",          "yes")

    -- Scan root folder to discover all L, M, and override folders
    scan_root()

    -- Auto-register keybinds from discovered folders
    register_keybinds()

    -- Load and start the scheduler
    load_schedule()
    start_scheduler()

    -- Verify the default loop exists
    if not MODES.loops[CONFIG.DEFAULT_LOOP] then
        warn("Default loop folder not found: " .. CONFIG.DEFAULT_LOOP ..
             " — create a folder named '" .. CONFIG.DEFAULT_LOOP ..
             "' in " .. PATHS.ROOT)
    end

    -- Start playback
    log("Starting loop: " .. CONFIG.DEFAULT_LOOP)
    play_loop()

    log("Ready.")
end

-- Start once MPV is idle (handles both cold start and --idle launch)
mp.register_event("idle", function()
    if not STATE._initialised then
        STATE._initialised = true
        mp.add_timeout(0.1, init)
    end
end)

mp.register_event("start-file", function()
    if not STATE._initialised then
        STATE._initialised = true
        mp.add_timeout(0.1, init)
    end
end)
