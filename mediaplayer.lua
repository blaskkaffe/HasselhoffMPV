--[[
================================================================================
  MPV STATE MACHINE MEDIA CONTROLLER
================================================================================
  Folder-driven kiosk player for mpv: a silent background loop, keyboard- and
  time-triggered media modes, intro/outro/transition cutscenes, per-loop
  overrides, and fades between every clip.

  FOLDERS (all live directly in content/ — text after " - " is ignored):
    L0, L1, L2 - Christmas   loops          L0 = ESC, L1..L12 = F1..F12
    M1, M2 - Promos, Ma      media modes    key = the character after the M
    L1M1, L1M1 - Xmas        override       replaces M1 while loop L1 is active
    Intro / IntroM1 / IntroL1M1      cutscene before a media mode
    Outro / OutroM1 / OutroL1M1      cutscene after a media mode
    Transition / TransitionL1        cutscene when switching TO a loop
    Cutscene fallback: most specific first, empty folder = skipped.
    Overlay / L1Overlay / M1Overlay / L1M1Overlay
                     PNG frames/logos (.png/.webp) and text (.txt) drawn on top
                     of the picture. They STACK: Overlay shows everywhere,
                     L1Overlay while loop L1 is active, M1Overlay while M1 plays.
    Audio files (mp3 ...) in a media folder are SONGS: the loop video keeps
    playing silently and the song plays on top of it. A folder may hold songs,
    videos, or both mixed.

  FILES: "01 - name.mp4" plays in number order; un-numbered = alphabetical.

  LAUNCH (see README):  launch.sh  /  launch.command
================================================================================
--]]


-- ==============================================================================
-- SECTION 1: PATHS
-- ==============================================================================

local function script_dir()
    -- Explicit path from the launch script (most reliable):
    --   --script-opts=mediaplayer-root=/path/to/folder
    local opt = mp.get_opt("mediaplayer-root")
    if opt and opt ~= "" then return opt end
    local d = mp.get_script_directory()
    if d and d ~= "" then return d end
    local info = mp.get_script_info and mp.get_script_info()
    if info and info.filename then
        local dir = info.filename:match("^(.+)[/\\][^/\\]+$")
        if dir then return dir end
    end
    return "."   -- works only if mpv was started from inside the folder
end

local SCRIPT_DIR = script_dir()
mp.msg.info("[SM] Base folder: " .. SCRIPT_DIR)

local PATHS = {
    ROOT     = SCRIPT_DIR .. "/content/",
    SCHEDULE = SCRIPT_DIR .. "/schedule.cfg",
    CONFIG   = SCRIPT_DIR .. "/config.cfg",
}


-- ==============================================================================
-- SECTION 2: SETTINGS  (this is the part you edit)
-- Prefer plain-text edits? Put the same settings in config.cfg next to this
-- script instead (see SECTION 4b). Values in config.cfg win over this file.
-- ==============================================================================

local CONFIG = {
    ---- Playback --------------------------------------------------------------
    DEFAULT_LOOP         = "L0",       -- loop used when the schedule has no opinion
    DEFAULT_ORDER        = "random",   -- sequential | reverse | pingpong | shuffle | random
    CUTSCENE_ORDER       = "random",   -- sequential | shuffle | random
    CLIPS_PER_TRIGGER    = 1,          -- clips played per key press (0 = until interrupted/timer)
    SECONDS_PER_TRIGGER  = 0,          -- stop media after N seconds (0 = off; beats clip count)
    LOOP_MUTED           = true,       -- loops are silent

    ---- Keys ------------------------------------------------------------------
    LOCK_KEYS            = false,      -- true: ignore every key while media plays
    KEY_CANCEL           = false,      -- true: pressing the same key again cancels the media
    QUIT_KEY             = "Ctrl+q",   -- "" disables the quit key

    ---- Cutscenes (a cutscene only plays if its folder exists and has files) --
    CUTSCENE_ON_TRIGGER  = true,       -- Intro  before a media mode
    CUTSCENE_ON_RETURN   = false,      -- Outro  after a media mode
    CUTSCENE_ON_SWITCH   = false,      -- Transition when a loop changes

    ---- Fades (brightness to black and back, around every clip) ---------------
    FADE_ENABLED         = true,
    FADE_OUT_DURATION    = 0.4,        -- seconds to fade to black
    FADE_BLACK_HOLD      = 0.1,        -- seconds of black between clips (0 = none)
    FADE_IN_DURATION     = 0.4,        -- seconds to fade in
    FADE_BEFORE_END      = true,       -- also fade out just before a clip ends by itself
    FADE_FPS             = 30,         -- smoothness of the fade

    ---- Music (media folders that contain only audio files) -------------------
    MPV_BINARY           = "mpv",      -- program used to play the songs (a second, hidden mpv)
    MUSIC_VOLUME         = 100,        -- 0-100
    MUSIC_FADE_IN        = 0,          -- seconds of fade-in at the start of every song (0 = off, plain start)
    MUSIC_EXTRA_ARGS     = {},         -- extra mpv options for the song player, e.g. {"--audio-device=alsa/hw:1"}

    ---- Overlays (PNG frames / logos / text, see the Overlay folders) ----------
    OVERLAYS             = true,       -- false = switch all overlays off
    OVERLAYS_ON_CUTSCENES = false,     -- show overlays during Intro/Outro/Transition too

    ---- Misc ------------------------------------------------------------------
    TICK_INTERVAL        = 1.0,        -- scheduler check interval (seconds)
    DEBUG                = false,      -- true: log every mpv end-file event
}

-- Per-mode overrides. Anything not listed here uses CONFIG above.
-- Keys: order, clips_per_trigger, seconds_per_trigger, lock_keys, key_cancel,
--       cutscene_on_trigger (Intro), cutscene_on_return (Outro),
--       cutscene_on_switch (loops only), overlays (false = hide all overlays in this mode)
--       Songs also: music (false = play audio files like videos),
--       visual_loop ("L5": show that loop's video while the songs play)
--
-- Example:
--   media_cfg = {
--       M1 = { order = "shuffle", clips_per_trigger = 2, cutscene_on_return = true },
--       M3 = { order = "pingpong", seconds_per_trigger = 30, key_cancel = true },
--   },
--   loop_cfg = {
--       L1 = { order = "pingpong", cutscene_on_switch = true },
--   },
local MODES = {
    loops     = {},   -- filled by the folder scan
    media     = {},
    overrides = {},
    overlay_dirs = {},   -- "*" (global), "L1", "M1", "L1M1" -> overlay folder path
    media_cfg = {},
    loop_cfg  = {},
}


-- ==============================================================================
-- SECTION 3: RUNTIME STATE (managed by the script — do not edit)
-- ==============================================================================

local STATE = {
    current_loop       = CONFIG.DEFAULT_LOOP,
    current_media      = nil,
    phase              = "loop",   -- "loop" | "media" | "cutscene"
    cutscene_done      = nil,      -- what to do when the running cutscene ends

    playing            = false,    -- a clip we loaded is on screen / playing
    transitioning      = false,    -- fading out the old clip before loading the next
    token              = 0,        -- bumped by every new transition; stale ones abort
    fade_id            = 0,        -- bumped by every brightness animation
    bright             = 0,        -- current brightness (0 normal .. -100 black)
    end_faded          = false,    -- the "fade before end" already started for this clip

    playlists          = {},
    pending_loop       = nil,      -- scheduler wants this loop after the current media
    pending_media      = nil,      -- scheduler wants this media after the current media
    media_timer        = nil,
    clips_played       = 0,
    active_trigger_key = nil,

    music              = nil,      -- {media_id, folder, serial, cmd} while songs are playing
    visual_loop        = nil,      -- loop whose video is shown during a music mode
    clip_kind          = nil,      -- "loop" | "media" | "cutscene": what is on screen
    vw                 = 1920,     -- size of the video on screen (learned from mpv)
    vh                 = 1080,
    vf_graph           = "",       -- overlay filter graph currently applied
    texts              = {},       -- text overlays currently shown
    text_ov            = nil,      -- mpv osd overlay object
    text_last          = nil,
    overlay_cache      = {},

    schedule_layers    = {},
    sched_loop         = nil,      -- last loop the *scheduler* asked for
    warned             = {},
    _initialised       = false,
}


-- ==============================================================================
-- SECTION 4: UTILITIES
-- ==============================================================================

local utils = require("mp.utils")

local function log(msg)   mp.msg.info("[SM] " .. tostring(msg)) end
local function warn(msg)  mp.msg.warn("[SM] WARN: " .. tostring(msg)) end
local function debug_log(msg) if CONFIG.DEBUG then log(msg) end end

-- Warn only once per key, so a persistent problem cannot flood the log
local function warn_once(key, msg)
    if STATE.warned[key] then return end
    STATE.warned[key] = true
    warn(msg)
end

local function path_exists(p) return utils.file_info(p) ~= nil end

local function join(...)
    local parts = {...}
    local r = parts[1]:gsub("/$", "")
    for i = 2, #parts do
        local seg = parts[i]:gsub("^/", ""):gsub("/$", "")
        r = r .. "/" .. seg
    end
    return r
end

-- "L1 - Christmas" -> "L1"   "M2 - Promos" -> "M2"   "L1M2" -> "L1M2"
local function parse_folder_id(name)
    local id = name:match("^([^%-]*)") or name
    id = id:gsub("^%s+", ""):gsub("%s+$", "")
    return id
end

local MEDIA_EXT = {
    mp4=true, mkv=true, avi=true, mov=true, webm=true, flv=true, wmv=true, m4v=true,
    mp3=true, aac=true, wav=true, ogg=true, flac=true, m4a=true, opus=true,
}
local AUDIO_EXT = { mp3=true, aac=true, wav=true, ogg=true, flac=true, m4a=true, opus=true }

-- Numbered files first (by number), then A-Z
local function file_less(a, b)
    if a.number and b.number then
        if a.number ~= b.number then return a.number < b.number end
        return a.name < b.name
    elseif a.number then return true
    elseif b.number then return false
    else return a.name < b.name end
end

-- Playable files in a folder: numbered files first (by number), then A-Z.
-- Hidden files (".DS_Store", macOS "._clip.mp4" leftovers on USB sticks) are skipped.
local function scan_files(folder_path)
    local files = {}
    if not path_exists(folder_path) then return files end
    local entries = utils.readdir(folder_path, "files")
    if not entries then return files end
    for _, name in ipairs(entries) do
        local ext = name:match("%.([^%.]+)$")
        if ext and MEDIA_EXT[ext:lower()] and name:sub(1, 1) ~= "." then
            files[#files + 1] = {
                name   = name,
                path   = join(folder_path, name),
                number = tonumber(name:match("^(%d+)")),
                audio  = AUDIO_EXT[ext:lower()] == true,
            }
        end
    end
    table.sort(files, file_less)
    return files
end

local function copy(t)
    local c = {}
    for i, v in ipairs(t) do c[i] = v end
    return c
end

-- Setting lookup: per-mode value first, then the global CONFIG
local function lookup(tbl, id, key)
    local cfg_key = key:upper()
    if id and tbl[id] then
        local v = tbl[id][key]
        if v ~= nil then return v end
        v = tbl[id][cfg_key]
        if v ~= nil then return v end
    end
    if CONFIG["DEFAULT_" .. cfg_key] ~= nil then return CONFIG["DEFAULT_" .. cfg_key] end
    return CONFIG[cfg_key]
end
local function mcfg(media_id, key) return lookup(MODES.media_cfg, media_id, key) end
local function lcfg(loop_id, key)  return lookup(MODES.loop_cfg,  loop_id,  key) end


-- ==============================================================================
-- SECTION 4b: EXTERNAL CONFIG  (config.cfg, optional)
-- Lets you change CONFIG and the per-mode overrides with a plain-text file next
-- to this script, so the stick only ever needs text edits.
--
--   # comment
--   key = value        global setting; key is a CONFIG name (any case):
--                      default_loop = L1     lock_keys = true     quit_key = ""
--
--   [M1]               per-media-mode section  (M1, M2, Ma ...)
--   order = shuffle
--   clips_per_trigger = 2
--
--   [L1]               per-loop section  (L1, L12 ...)
--   order = pingpong
--
-- Values: true/false -> boolean, numbers -> number, anything else -> text
-- (quotes around text are optional). Unknown keys/sections are warned about
-- and skipped. config.cfg wins over the values hard-coded above.
-- List settings (MUSIC_EXTRA_ARGS) can only be changed in this file.
-- ==============================================================================

local function parse_cfg_value(raw)
    local v = raw:match("^%s*(.-)%s*$")
    local q = v:match('^"(.*)"$') or v:match("^'(.*)'$")
    if q ~= nil then return q end
    local low = v:lower()
    if low == "true"  then return true  end
    if low == "false" then return false end
    local n = tonumber(v)
    if n ~= nil then return n end
    return v
end

local function load_config()
    if not path_exists(PATHS.CONFIG) then
        log("No config.cfg - using the settings in mediaplayer.lua")
        return
    end
    local f = io.open(PATHS.CONFIG, "r")
    if not f then warn("Cannot open " .. PATHS.CONFIG); return end

    local section, line_num, applied = nil, 0, 0
    for raw_line in f:lines() do
        line_num = line_num + 1
        local line = raw_line:gsub("\r", ""):gsub("^\239\187\191", ""):gsub("#.*$", ""):match("^%s*(.-)%s*$")
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
                local key, val = line:match("^([%w_]+)%s*=%s*(.*)$")
                if not key then
                    warn("config.cfg line " .. line_num .. ": cannot parse: " .. line)
                elseif section and section.kind == "invalid" then
                    -- header already reported
                else
                    local value = parse_cfg_value(val)
                    if not section then
                        local k = key:upper()
                        if type(CONFIG[k]) == "table" then
                            warn("config.cfg line " .. line_num .. ": '" .. key .. "' is a list; set it in mediaplayer.lua")
                        elseif CONFIG[k] ~= nil then
                            CONFIG[k] = value
                            applied = applied + 1
                        else
                            warn("config.cfg line " .. line_num .. ": unknown setting '" .. key .. "'")
                        end
                    else
                        local tbl = (section.kind == "media") and MODES.media_cfg or MODES.loop_cfg
                        tbl[section.id] = tbl[section.id] or {}
                        tbl[section.id][key:lower()] = value
                        applied = applied + 1
                    end
                end
            end
        end
    end
    f.close(f)
    log("config.cfg: " .. applied .. " value(s) applied")
end


-- ==============================================================================
-- SECTION 5: FOLDER SCANNER
-- ==============================================================================

local function scan_root()
    local entries = utils.readdir(PATHS.ROOT, "dirs")
    if not entries then
        warn("Cannot read content folder: " .. PATHS.ROOT)
        return
    end
    for _, name in ipairs(entries) do
        local id          = parse_folder_id(name)
        local folder_path = join(PATHS.ROOT, name)

        local loop_num = id:match("^L(%d+)$")
        if loop_num then
            local loop_id = "L" .. tonumber(loop_num)
            MODES.loops[loop_id] = { id = loop_id, path = folder_path, num = tonumber(loop_num) }
            log("Loop found:     " .. loop_id .. "  (" .. name .. ")")
        end

        local media_char = id:match("^M([%d%l])$")
        if media_char then
            local media_id = "M" .. media_char
            MODES.media[media_id] = { id = media_id, path = folder_path, char = media_char }
            log("Media found:    " .. media_id .. "  (" .. name .. ")")
        end

        -- Overlay folders: "Overlay", "L1Overlay", "M1Overlay", "L1M1Overlay"
        local ov_key = (id == "Overlay") and "*" or id:match("^(L%d+M[%d%l])Overlay$")
                       or id:match("^(L%d+)Overlay$") or id:match("^(M[%d%l])Overlay$")
        if ov_key then MODES.overlay_dirs[ov_key] = folder_path end

        local ov_loop, ov_media = id:match("^(L%d+)(M[%d%l])$")
        if ov_loop then
            local ov_id = ov_loop .. ov_media
            MODES.overrides[ov_id] = { id = ov_id, loop_id = ov_loop, media_id = ov_media, path = folder_path }
            log("Override found: " .. ov_id .. "  (" .. name .. ")")
        end
    end
end


-- ==============================================================================
-- SECTION 6: CUTSCENE RESOLVER
--   Intro:      IntroL1M1 -> IntroM1 -> Intro
--   Outro:      OutroL1M1 -> OutroM1 -> Outro
--   Transition: TransitionL1 -> Transition
-- A folder that is missing OR empty is skipped (falls back one tier).
-- ==============================================================================

local function usable_folder(path)
    if path_exists(path) and #scan_files(path) > 0 then return path end
    return nil
end

local function resolve_cutscene(prefix, loop_id, media_id)
    if loop_id and media_id then
        local p = usable_folder(join(PATHS.ROOT, prefix .. loop_id .. media_id))
        if p then return p end
    end
    if media_id then
        local p = usable_folder(join(PATHS.ROOT, prefix .. media_id))
        if p then return p end
    end
    if loop_id and not media_id then
        local p = usable_folder(join(PATHS.ROOT, prefix .. loop_id))
        if p then return p end
    end
    return usable_folder(join(PATHS.ROOT, prefix))
end


-- ==============================================================================
-- SECTION 7: PLAYLIST ENGINE (one independent playlist per folder)
-- ==============================================================================

local function get_playlist(folder_path)
    if not STATE.playlists[folder_path] then
        local files = scan_files(folder_path)
        STATE.playlists[folder_path] = {
            files = files, index = 1, direction = 1, pool = copy(files),
        }
        log("Playlist ready: " .. folder_path .. " (" .. #files .. " files)")
    end
    return STATE.playlists[folder_path]
end

local function next_file(folder_path, order)
    local pl = get_playlist(folder_path)
    local n = #pl.files
    if n == 0 then return nil end

    if order == "random" then
        return pl.files[math.random(1, n)]

    elseif order == "shuffle" then               -- no repeats until all have played
        if #pl.pool == 0 then pl.pool = copy(pl.files) end
        local i = math.random(1, #pl.pool)
        return table.remove(pl.pool, i)

    elseif order == "reverse" then
        local file = pl.files[pl.index]
        pl.index = pl.index - 1
        if pl.index < 1 then pl.index = n end
        return file

    elseif order == "pingpong" then              -- forward, then backward, repeat
        local file = pl.files[pl.index]
        if n == 1 then return file end
        pl.index = pl.index + pl.direction
        if pl.index > n then
            pl.direction, pl.index = -1, n - 1
        elseif pl.index < 1 then
            pl.direction, pl.index = 1, 2
        end
        return file

    else                                         -- sequential
        local file = pl.files[pl.index]
        pl.index = pl.index + 1
        if pl.index > n then pl.index = 1 end
        return file
    end
end


-- ==============================================================================
-- SECTION 8: OVERRIDE RESOLVER
--   active loop L1 + key for M1  ->  folder L1M1 if it exists, else M1
-- ==============================================================================

local function resolve_media_folder(media_id)
    local ov = MODES.overrides[STATE.current_loop .. media_id]
    if ov then return ov.path, true end
    local info = MODES.media[media_id]
    if info then return info.path, false end
    return nil
end

local function resolve_loop_folder(loop_id)
    local info = MODES.loops[loop_id]
    return info and info.path or nil
end


-- ==============================================================================
-- SECTION 8b: OVERLAYS
-- Folders in content/ (all optional, all STACK on top of each other):
--     Overlay          always            L1Overlay     while loop L1 is active
--     M1Overlay        while M1 plays    L1M1Overlay   while M1 plays under L1
-- Inside a folder:
--   *.png / *.webp   transparent picture. Stretched over the whole picture
--                    (a frame), unless the file name contains tags:
--                      top-left top-center top-right middle-left center
--                      middle-right bottom-left bottom-center bottom-right
--                      40%        width as % of the picture (height follows)
--                      opacity50  50 % visible
--                    e.g. "logo bottom-right 12%.png"   (no position tag + no % = frame)
--   *.txt            text. Either just the text, or settings then text:
--                      position: bottom-center    size: 48     color: FFFFFF
--                      outline: 3                 text: Merry Christmas
--                    (everything after "text:" is the text, several lines allowed)
-- Pictures are drawn by an mpv video filter, text by mpv's on-screen display.
-- ==============================================================================

local OVERLAY_POS = {   -- name -> horizontal (l c r), vertical (t m b); longest names first
    { "bottom-center", "c", "b" }, { "bottom-right", "r", "b" }, { "bottom-left", "l", "b" },
    { "middle-right",  "r", "m" }, { "middle-left",  "l", "m" },
    { "top-center",    "c", "t" }, { "top-right",    "r", "t" }, { "top-left",    "l", "t" },
    { "center",        "c", "m" },
}

local function parse_image_tags(name)
    local lname = name:lower():gsub("%.[^%.]+$", "")
    local e = { pos_h = nil, pos_v = nil, pct = tonumber(lname:match("(%d+)%%")),
                opacity = tonumber(lname:match("opacity(%d+)")) }
    for _, p in ipairs(OVERLAY_POS) do
        if lname:find(p[1], 1, true) then e.pos_h, e.pos_v = p[2], p[3]; break end
    end
    return e
end

local function ass_color(hex)
    hex = tostring(hex or ""):gsub("^#", "")
    if not hex:match("^%x%x%x%x%x%x$") then hex = "FFFFFF" end
    return (hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2)):upper()   -- RRGGBB -> BBGGRR
end

local function parse_text_file(path, name)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a") or ""
    f:close()
    content = content:gsub("\r", "")
    local t = { kind = "text", name = name, position = "bottom-center", size = 48,
                color = "FFFFFF", outline = 3, text = content }
    if ("\n" .. content):lower():find("\ntext%s*:") then
        local text_lines, in_text = {}, false
        for line in (content .. "\n"):gmatch("(.-)\n") do
            if in_text then
                text_lines[#text_lines + 1] = line
            else
                local k, v = line:match("^%s*(%a+)%s*:%s*(.-)%s*$")
                k = k and k:lower()
                if k == "text" then in_text = true; if v ~= "" then text_lines[1] = v end
                elseif k == "position" then t.position = v:lower()
                elseif k == "size" then t.size = tonumber(v) or t.size
                elseif k == "color" then t.color = v
                elseif k == "outline" then t.outline = tonumber(v) or t.outline
                end
            end
        end
        t.text = table.concat(text_lines, "\n")
    end
    t.text = t.text:gsub("%s+$", "")
    if t.text == "" then return nil end
    return t
end

-- Contents of one overlay folder (scanned once, then cached)
local function overlay_entries(folder)
    if STATE.overlay_cache[folder] then return STATE.overlay_cache[folder] end
    local list = { images = {}, texts = {} }
    local names = utils.readdir(folder, "files") or {}
    local items = {}
    for _, name in ipairs(names) do
        if name:sub(1, 1) ~= "." then
            items[#items + 1] = { name = name, number = tonumber(name:match("^(%d+)")) }
        end
    end
    table.sort(items, file_less)
    for _, it in ipairs(items) do
        local ext = (it.name:match("%.([^%.]+)$") or ""):lower()
        local path = join(folder, it.name)
        if ext == "png" or ext == "webp" then
            if path:find("[']") then
                warn_once("ovq" .. path, "Overlay skipped (the name contains an apostrophe): " .. path)
            else
                local e = parse_image_tags(it.name)
                e.kind, e.path, e.name = "image", path, it.name
                list.images[#list.images + 1] = e
            end
        elseif ext == "txt" then
            local t = parse_text_file(path, it.name)
            if t then list.texts[#list.texts + 1] = t end
        end
    end
    STATE.overlay_cache[folder] = list
    return list
end

-- Which overlay folders apply right now?
local function active_overlay_folders()
    if not CONFIG.OVERLAYS then return {} end
    if STATE.phase == "cutscene" and not CONFIG.OVERLAYS_ON_CUTSCENES then return {} end
    local lp = STATE.current_loop
    local md = (STATE.phase == "media") and STATE.current_media or nil
    if lcfg(lp, "overlays") == false then return {} end
    if md and mcfg(md, "overlays") == false then return {} end
    local names = { "*", lp }
    if md then names[#names + 1] = md; names[#names + 1] = lp .. md end
    local out = {}
    for _, n in ipairs(names) do
        local p = MODES.overlay_dirs[n]
        if p then out[#out + 1] = p end
    end
    return out
end

-- One lavfi graph that stacks all the pictures on the video ("in" -> "out").
-- vw/vh = size of the video, so sizes can be worked out here (no scale2ref: its
-- variable names differ between ffmpeg versions).
local function build_graph(images, vw, vh)
    if #images == 0 then return "" end
    local parts = {}
    local base = "in"
    for i, im in ipairs(images) do
        local chain = "movie='" .. im.path .. "',format=rgba"
        if im.pct then
            chain = chain .. string.format(",scale=%d:-1", math.max(2, math.floor(vw * im.pct / 100 + 0.5)))
        elseif not im.pos_h then
            chain = chain .. string.format(",scale=%d:%d", vw, vh)           -- a frame: whole picture
        end
        if im.opacity and im.opacity < 100 then
            chain = chain .. ",colorchannelmixer=aa=" .. string.format("%.2f", im.opacity / 100)
        end
        parts[#parts + 1] = chain .. "[o" .. i .. "]"
        local x, y = "0", "0"
        if im.pos_h then
            x = (im.pos_h == "l" and "W*0.03") or (im.pos_h == "c" and "(W-w)/2") or "W-w-W*0.03"
            y = (im.pos_v == "t" and "W*0.03") or (im.pos_v == "m" and "(H-h)/2") or "H-h-W*0.03"
        end
        local out = (i == #images) and "out" or ("b" .. i)
        parts[#parts + 1] = "[" .. base .. "][o" .. i .. "]overlay=x=" .. x .. ":y=" .. y .. "[" .. out .. "]"
        base = out
    end
    return table.concat(parts, ";")
end

-- ASS text for all text overlays, faded together with the picture
local function refresh_text()
    local texts = STATE.texts
    if #texts == 0 then
        if STATE.text_ov and STATE.text_last ~= "" then STATE.text_ov:remove(); STATE.text_last = "" end
        return
    end
    local vis = math.max(0, math.min(1, (100 + STATE.bright) / 100))
    local alpha = string.format("%02X", math.floor((1 - vis) * 255 + 0.5))
    local ev = {}
    for _, t in ipairs(texts) do
        local h, v = "c", "b"
        for _, p in ipairs(OVERLAY_POS) do if p[1] == t.position then h, v = p[2], p[3] end end
        local x = (h == "l" and 60) or (h == "c" and 960) or 1860
        local y = (v == "t" and 60) or (v == "m" and 540) or 1020
        local an = ((v == "b") and 0 or (v == "m") and 3 or 6) + ((h == "l") and 1 or (h == "c") and 2 or 3)
        local txt = t.text:gsub("{", "\\{"):gsub("}", "\\}"):gsub("\n", "\\N")
        ev[#ev + 1] = string.format("{\\an%d\\pos(%d,%d)\\fs%d\\bord%s\\1c&H%s&\\3c&H000000&\\alpha&H%s&}%s",
                                    an, x, y, t.size, tostring(t.outline), ass_color(t.color), alpha, txt)
    end
    local data = table.concat(ev, "\n")
    if data == STATE.text_last then return end
    STATE.text_last = data
    if not STATE.text_ov then
        STATE.text_ov = mp.create_osd_overlay("ass-events")
        STATE.text_ov.res_x, STATE.text_ov.res_y = 1920, 1080
    end
    STATE.text_ov.data = data
    STATE.text_ov:update()
end

-- Work out the overlays for the current situation and apply them
local function apply_overlays()
    local images, texts = {}, {}
    for _, folder in ipairs(active_overlay_folders()) do
        local e = overlay_entries(folder)
        for _, im in ipairs(e.images) do images[#images + 1] = im end
        for _, t in ipairs(e.texts) do texts[#texts + 1] = t end
    end
    local graph = build_graph(images, STATE.vw, STATE.vh)
    if graph ~= STATE.vf_graph then
        STATE.vf_graph = graph
        if graph == "" then
            mp.set_property_native("vf", {})
        else
            debug_log("Overlay graph: " .. graph)
            mp.set_property_native("vf", { { name = "lavfi", params = { graph = graph } } })
        end
    end
    STATE.texts = texts
    refresh_text()
end


-- ==============================================================================
-- SECTION 9: FADE SYSTEM
-- Fades by animating mpv's `brightness` (0 = normal, -100 = black).
-- Every new brightness animation cancels the previous one, and every clip
-- change carries a token, so a key press in the middle of a fade can never
-- leave two fades fighting each other or load two clips.
-- ==============================================================================

local function set_bright(v)
    v = math.max(-100, math.min(0, math.floor(v + 0.5)))
    if v ~= STATE.bright then
        STATE.bright = v
        mp.set_property_number("brightness", v)
        if #STATE.texts > 0 then refresh_text() end     -- text fades with the picture
    end
end

-- Animate brightness to `to_val`. Starts from the CURRENT brightness.
-- A newer animation silently cancels this one (on_done is then not called).
local function animate_brightness(to_val, duration, on_done)
    STATE.fade_id = STATE.fade_id + 1
    local my = STATE.fade_id
    local from_val = STATE.bright
    if duration <= 0 or from_val == to_val then
        set_bright(to_val)
        if on_done then on_done() end
        return
    end
    local steps    = math.max(1, math.floor(duration * CONFIG.FADE_FPS))
    local interval = duration / steps
    local count    = 0
    local function step()
        if STATE.fade_id ~= my then return end          -- cancelled
        count = count + 1
        if count >= steps then
            set_bright(to_val)
            if on_done then on_done() end
        else
            set_bright(from_val + (to_val - from_val) * count / steps)
            mp.add_timeout(interval, step)
        end
    end
    mp.add_timeout(interval, step)
end

-- Fade out just before a clip ends by itself (driven by mpv's time-remaining)
local function on_time_remaining(_, remaining)
    if not (CONFIG.FADE_ENABLED and CONFIG.FADE_BEFORE_END) then return end
    if type(remaining) ~= "number" then return end
    if not STATE.playing or STATE.transitioning or STATE.end_faded then return end
    if remaining > 0.05 and remaining <= CONFIG.FADE_OUT_DURATION then
        STATE.end_faded = true
        animate_brightness(-100, remaining, nil)
    end
end


-- ==============================================================================
-- SECTION 10: CLIP LOADER — the ONE place that calls loadfile
--   playing clip:   fade out -> black hold -> load -> fade in
--   nothing playing (clip already ended / startup): black -> hold -> load -> fade in
-- ==============================================================================

local function load_clip(path, muted)
    STATE.token = STATE.token + 1
    local my = STATE.token

    local function go()
        if STATE.token ~= my then return end            -- a newer transition took over
        mp.set_property_bool("mute", muted)              -- audio switches exactly now
        STATE.transitioning = false
        STATE.end_faded     = false
        STATE.playing       = true
        apply_overlays()                                 -- overlays for what is about to play
        mp.commandv("loadfile", path, "replace")
        if CONFIG.FADE_ENABLED then
            mp.add_timeout(0.05, function()              -- let mpv start decoding first
                if STATE.token == my then
                    animate_brightness(0, CONFIG.FADE_IN_DURATION, nil)
                end
            end)
        end
    end

    local function after_dark()
        if STATE.token ~= my then return end
        local hold = CONFIG.FADE_BLACK_HOLD or 0
        if hold > 0 then mp.add_timeout(hold, go) else go() end
    end

    if not CONFIG.FADE_ENABLED then
        go()
    elseif STATE.playing and STATE.bright > -99 then
        STATE.transitioning = true                       -- old clip still on screen
        animate_brightness(-100, CONFIG.FADE_OUT_DURATION, after_dark)
    else
        STATE.transitioning = STATE.playing              -- (faded already, or nothing playing)
        animate_brightness(-100, 0, nil)                 -- instant black
        after_dark()
    end
end


-- ==============================================================================
-- SECTION 11: PLAYBACK ENGINE
-- ==============================================================================

local play_loop, play_loop_clip, play_cutscene, start_media, play_media_clip, return_to_loop, switch_loop
local stop_music, play_song

local function kill_media_timer()
    if STATE.media_timer then
        STATE.media_timer:kill()
        STATE.media_timer = nil
    end
end

-- Load the next clip of the loop on screen (the visual loop during a music mode)
play_loop_clip = function()
    local loop_id = STATE.visual_loop or STATE.current_loop
    local folder = resolve_loop_folder(loop_id)
    if not folder then
        warn_once("noloop" .. loop_id, "No folder for loop " .. loop_id)
        return
    end
    local file = next_file(folder, lcfg(loop_id, "order") or CONFIG.DEFAULT_ORDER)
    if not file then
        warn_once("empty" .. folder, "No playable files in " .. folder .. " (retrying every 2s)")
        mp.add_timeout(2.0, function()
            if (STATE.phase == "loop" or STATE.clip_kind == "loop") and not STATE.playing and not STATE.transitioning then
                play_loop_clip()
            end
        end)
        return
    end
    log("Loop clip:  " .. file.name .. "  [" .. loop_id .. "]")
    STATE.clip_kind = "loop"
    load_clip(file.path, CONFIG.LOOP_MUTED)
end

-- Back to plain loop state (and a fresh loop clip)
play_loop = function()
    stop_music()
    STATE.visual_loop        = nil
    STATE.phase              = "loop"
    STATE.current_media      = nil
    STATE.clips_played       = 0
    STATE.active_trigger_key = nil
    kill_media_timer()
    play_loop_clip()
end

-- Play one cutscene clip, then run on_done()
play_cutscene = function(folder, on_done)
    local file = next_file(folder, CONFIG.CUTSCENE_ORDER or "random")
    if not file then
        if on_done then on_done() end
        return
    end
    log("Cutscene:   " .. file.name)
    STATE.phase         = "cutscene"
    STATE.cutscene_done = on_done
    STATE.clip_kind     = "cutscene"
    load_clip(file.path, false)
end

-- Load the next clip of the active media mode
play_media_clip = function()
    local media_id = STATE.current_media
    local folder   = media_id and resolve_media_folder(media_id)
    local file     = folder and next_file(folder, mcfg(media_id, "order") or CONFIG.DEFAULT_ORDER)
    if not file then
        warn("No playable files for " .. tostring(media_id))
        return_to_loop()
        return
    end
    if file.audio and mcfg(media_id, "music") ~= false then
        play_song(media_id, file)                         -- loop video stays, song on top
        return
    end
    log("Media clip: " .. file.name .. "  [" .. media_id .. "]")
    STATE.visual_loop = nil
    STATE.clip_kind = "media"
    load_clip(file.path, false)
end


-- ------------------------------------------------------------------------------
-- SONGS
-- Audio files (mp3 ...) in a media folder are SONGS: the loop video keeps playing,
-- silently, and the song is played on top of it by a second, hidden mpv process.
-- A folder may hold only songs, only videos, or a mix: each item picked from the
-- folder is played its own way. clips_per_trigger counts items (songs AND videos).
-- Set  music = false  for a mode to play audio files like videos instead.
-- ------------------------------------------------------------------------------

stop_music = function()
    local m = STATE.music
    if not m then return end
    STATE.music = nil                          -- (the end-of-song callback now ignores itself)
    if m.cmd then mp.abort_async_command(m.cmd) end
end

-- One item of the active media mode finished: count it, then go on or stop
local function media_item_done()
    STATE.clips_played = STATE.clips_played + 1
    local max = mcfg(STATE.current_media, "clips_per_trigger") or 1
    if max == 0 or STATE.clips_played < max then
        play_media_clip()
    else
        log("Clip limit reached (" .. max .. ")")
        return_to_loop()
    end
end

play_song = function(media_id, file)
    log("Song:       " .. file.name .. "  [" .. media_id .. "]")
    STATE.music = { media_id = media_id }
    local m = STATE.music

    -- the picture behind the song: a special visual loop, or the normal loop video
    local vl = mcfg(media_id, "visual_loop")
    local new_visual = nil
    if vl and MODES.loops[vl] then
        if STATE.visual_loop ~= vl then new_visual = vl end
        STATE.visual_loop = vl
    elseif vl then
        warn_once("novl" .. vl, "visual_loop " .. vl .. " has no folder; using the current loop")
    end
    apply_overlays()
    if new_visual or STATE.clip_kind ~= "loop" or not STATE.playing then
        play_loop_clip()
    end

    local args = { CONFIG.MPV_BINARY, "--no-config", "--load-scripts=no", "--no-video",
                   "--no-terminal", "--idle=no", "--force-window=no", "--audio-display=no",
                   "--volume=" .. tostring(CONFIG.MUSIC_VOLUME) }
    local fade = CONFIG.MUSIC_FADE_IN or 0
    if fade > 0 then args[#args + 1] = "--af=lavfi=[afade=t=in:st=0:d=" .. tostring(fade) .. "]" end
    local dev = mp.get_property("audio-device")
    if dev and dev ~= "" and dev ~= "auto" then args[#args + 1] = "--audio-device=" .. dev end
    for _, a in ipairs(CONFIG.MUSIC_EXTRA_ARGS or {}) do args[#args + 1] = a end
    args[#args + 1] = "--"
    args[#args + 1] = file.path

    m.cmd = mp.command_native_async({ name = "subprocess", args = args, playback_only = false },
        function(success, result, err)
            if STATE.music ~= m then return end                          -- stopped / replaced
            m.cmd = nil
            local failed = (not success) or (result and result.status ~= 0)
            local function finished()
                if STATE.music ~= m then return end
                STATE.music = nil
                media_item_done()
            end
            if failed then
                warn("Could not play song " .. file.name .. " (is '" .. tostring(CONFIG.MPV_BINARY) .. "' installed?)")
                mp.add_timeout(1.0, finished)            -- never spin on a folder of bad files
            else
                finished()
            end
        end)
end

-- Begin a media mode: optional Intro cutscene, then the media itself.
-- skip_intro = true when called from the Intro's own callback.
start_media = function(media_id, trigger_key, skip_intro)
    local folder, is_override = resolve_media_folder(media_id)
    if not folder then return end
    kill_media_timer()                                    -- never let an old timer cut this one short
    stop_music()                                          -- (interrupting a music mode)
    STATE.visual_loop = nil

    if not skip_intro and mcfg(media_id, "cutscene_on_trigger") then
        local cf = resolve_cutscene("Intro", STATE.current_loop, media_id)
        if cf then
            play_cutscene(cf, function() start_media(media_id, trigger_key, true) end)
            return
        end
    end

    log("Media mode: " .. media_id .. (is_override and "  (override " .. STATE.current_loop .. media_id .. ")" or ""))
    STATE.phase              = "media"
    STATE.current_media      = media_id
    STATE.clips_played       = 0
    STATE.active_trigger_key = trigger_key

    local seconds = mcfg(media_id, "seconds_per_trigger") or 0
    if seconds > 0 then
        STATE.media_timer = mp.add_timeout(seconds, function()
            STATE.media_timer = nil
            if STATE.phase == "media" then
                log("Media time limit reached (" .. seconds .. "s)")
                return_to_loop()
            end
        end)
    end
    play_media_clip()
end

-- Media is over: apply anything the scheduler queued, else Outro, else loop
return_to_loop = function()
    kill_media_timer()
    local had_visual = STATE.visual_loop ~= nil
    stop_music()
    STATE.visual_loop = nil

    if STATE.pending_loop then
        local nl = STATE.pending_loop
        STATE.pending_loop = nil
        STATE.pending_media = nil
        if switch_loop(nl) then return end      -- false = nothing to switch to; carry on below
    end
    if STATE.pending_media then
        local pm = STATE.pending_media
        STATE.pending_media = nil
        start_media(pm, nil)
        return
    end

    local media_id = STATE.current_media
    if media_id and mcfg(media_id, "cutscene_on_return") then
        local cf = resolve_cutscene("Outro", STATE.current_loop, media_id)
        if cf then
            play_cutscene(cf, function() play_loop() end)
            return
        end
    end
    if not had_visual and STATE.clip_kind == "loop" and STATE.playing then
        -- the last song ended while the normal loop video was on screen: carry on, no reload
        STATE.phase, STATE.current_media = "loop", nil
        STATE.clips_played, STATE.active_trigger_key = 0, nil
        apply_overlays()
        return
    end
    play_loop()
end

-- Returns true if it started playing something, false if there was nothing to do
-- (same loop, or the folder does not exist) so callers can carry on themselves.
switch_loop = function(new_loop)
    if new_loop == STATE.current_loop then return false end
    if not MODES.loops[new_loop] then
        warn_once("noloop" .. new_loop, "Cannot switch to " .. new_loop .. ": no such loop folder")
        return false
    end
    log("Loop switch: " .. STATE.current_loop .. " -> " .. new_loop)
    STATE.current_loop  = new_loop
    STATE.current_media = nil
    kill_media_timer()
    stop_music()
    STATE.visual_loop = nil

    if lcfg(new_loop, "cutscene_on_switch") then
        local cf = resolve_cutscene("Transition", new_loop, nil)
        if cf then
            play_cutscene(cf, function() play_loop() end)
            return true
        end
    end
    play_loop()
    return true
end


-- ==============================================================================
-- SECTION 12: CLIP-END HANDLER
-- mpv sends end-file with reason "stop" every time WE replace a clip, so only
-- "eof" (finished by itself) and "error" (unplayable file) mean "next, please".
-- ==============================================================================

local function on_clip_finished()
    if STATE.phase == "cutscene" then
        local done = STATE.cutscene_done
        STATE.cutscene_done = nil
        if done then done() else play_loop() end

    elseif STATE.phase == "media" and STATE.clip_kind == "loop" then
        play_loop_clip()                       -- the loop video behind a song ended; the song plays on

    elseif STATE.phase == "media" then
        media_item_done()

    else  -- loop
        if STATE.pending_loop then
            local nl = STATE.pending_loop
            STATE.pending_loop = nil
            if not switch_loop(nl) then play_loop() end
        elseif STATE.pending_media then
            local pm = STATE.pending_media
            STATE.pending_media = nil
            start_media(pm, nil)
        else
            play_loop()
        end
    end
end

local function on_end_file(ev)
    debug_log("end-file reason=" .. tostring(ev.reason) .. " phase=" .. STATE.phase ..
              " playing=" .. tostring(STATE.playing) .. " transitioning=" .. tostring(STATE.transitioning))
    local reason = ev.reason
    if reason ~= "eof" and reason ~= "error" then return end   -- our own replace, quit, etc.
    if not STATE.playing then return end                       -- stray event
    STATE.playing = false
    if STATE.transitioning then return end                     -- old clip ended mid-fade; load continues
    if reason == "error" then
        -- Unplayable file: wait a second so a folder of bad files cannot spin the CPU
        warn("Could not play the last clip; moving on")
        local my = STATE.token
        mp.add_timeout(1.0, function()
            if STATE.token == my and not STATE.playing and not STATE.transitioning then on_clip_finished() end
        end)
        return
    end
    on_clip_finished()
end


-- ==============================================================================
-- SECTION 13: KEY HANDLERS
-- ==============================================================================

local function handle_media_key(media_id, trigger_key)
    if STATE.phase == "cutscene" then return end                 -- keys ignored during cutscenes
    if not resolve_media_folder(media_id) then return end        -- no folder -> silently ignored

    if STATE.phase == "media" then
        local active = STATE.current_media
        if mcfg(active, "lock_keys") then return end             -- locked: ignore everything

        if trigger_key == STATE.active_trigger_key then          -- same key again
            if mcfg(active, "key_cancel") then
                log("Same key pressed: cancelling " .. active)
                return_to_loop()
            end
            return
        end
        log("Interrupting " .. active .. " with " .. media_id)
    end
    STATE.pending_media = nil
    start_media(media_id, trigger_key)
end

local function handle_loop_key(loop_id)
    if STATE.phase == "cutscene" then return end
    if loop_id == STATE.current_loop then return end             -- already on it
    STATE.pending_loop, STATE.pending_media = nil, nil           -- a manual choice wins
    switch_loop(loop_id)
end

local function register_keybinds()
    -- Media keys: the character after the M. Override-only modes count too.
    local media_ids = {}
    for id in pairs(MODES.media) do media_ids[id] = true end
    for _, ov in pairs(MODES.overrides) do media_ids[ov.media_id] = true end
    for media_id in pairs(media_ids) do
        local key = media_id:sub(2)
        local mid = media_id
        -- (forced bindings: they keep working with --no-input-default-bindings, which switches
        --  off mpv's own keys such as q / f / space. Normal bindings would be switched off too.)
        mp.add_forced_key_binding(key, "media_" .. mid, function() handle_media_key(mid, key) end)
        log("Key [" .. key .. "] -> " .. mid)
    end

    -- Loop keys: L0 = ESC, L1..L12 = F1..F12
    for loop_id, info in pairs(MODES.loops) do
        local lid = loop_id
        local key
        if info.num == 0 then key = "ESC"
        elseif info.num <= 12 then key = "F" .. info.num
        else warn(loop_id .. " has no F-key (only up to L12); the scheduler can still use it") end
        if key then
            mp.add_forced_key_binding(key, "loop_" .. lid, function() handle_loop_key(lid) end)
            log("Key [" .. key .. "] -> " .. lid)
        end
    end

    if CONFIG.QUIT_KEY and CONFIG.QUIT_KEY ~= "" then
        mp.add_forced_key_binding(CONFIG.QUIT_KEY, "sm_quit", function() mp.command("quit") end)
    end
end


-- ==============================================================================
-- SECTION 14: SCHEDULER
--
--   schedule.cfg (one entry per line, "#" = comment):
--     loop   L1  START END [FROM-DATE TO-DATE]     e.g.  loop L1 08:00 22:00 12-01 01-06
--     media  M2  TIME      [FROM-DATE TO-DATE]     e.g.  media M2 12:00
--   Times are HH:MM (24h). Dates are MM-DD, yearly, and may wrap New Year.
--   Lines lower in the file have HIGHER priority when entries overlap.
--
-- The scheduler only acts when the loop it WANTS changes. A manual F-key press
-- therefore stays in effect until the schedule's wish changes again.
-- ==============================================================================

local function parse_hhmm(str)
    if not str then return nil end
    local h, m = str:match("^(%d%d?):(%d%d)$")
    if h then return tonumber(h) * 60 + tonumber(m) end
    return nil
end

local function parse_mmdd(str)
    if not str then return nil end
    local m, d = str:match("^(%d%d?)%-(%d%d?)$")
    if m then return tonumber(m) * 100 + tonumber(d) end
    return nil
end

local function date_active(ev, month, day)
    if not ev.from_date then return true end
    local v = month * 100 + day
    if ev.from_date <= ev.to_date then
        return v >= ev.from_date and v <= ev.to_date
    end
    return v >= ev.from_date or v <= ev.to_date          -- wraps over New Year
end

local function load_schedule()
    STATE.schedule_layers = {}
    if not path_exists(PATHS.SCHEDULE) then
        log("No schedule file (" .. PATHS.SCHEDULE .. ") - running without a schedule")
        return
    end
    local f = io.open(PATHS.SCHEDULE, "r")
    if not f then warn("Cannot open " .. PATHS.SCHEDULE); return end

    local line_num = 0
    for line in f:lines() do
        line_num = line_num + 1
        line = line:gsub("\r", ""):match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local p = {}
            for w in line:gmatch("%S+") do p[#p + 1] = w end
            local etype, eid = p[1] and p[1]:lower(), p[2]
            local ev

            if etype == "loop" and #p >= 4 then
                ev = { type = "loop", id = eid, start_min = parse_hhmm(p[3]), end_min = parse_hhmm(p[4]),
                       dates = { p[5], p[6] } }
                if not (ev.start_min and ev.end_min) then ev = nil end
            elseif etype == "media" and #p >= 3 then
                ev = { type = "media", id = eid, start_min = parse_hhmm(p[3]), dates = { p[4], p[5] },
                       fired = false, last_min = -1 }
                if not ev.start_min then ev = nil end
            end

            if ev and (ev.dates[1] or ev.dates[2]) then
                ev.from_date, ev.to_date = parse_mmdd(ev.dates[1]), parse_mmdd(ev.dates[2])
                if not (ev.from_date and ev.to_date) then ev = nil end
            end

            if ev then
                STATE.schedule_layers[#STATE.schedule_layers + 1] = ev
                log("Schedule line " .. line_num .. ": " .. line)
            else
                warn("Ignoring schedule line " .. line_num .. ": " .. line)
            end
        end
    end
    f:close()
    log("Schedule loaded: " .. #STATE.schedule_layers .. " entries")
end

-- Which loop does the schedule want right now, and which media fire this minute?
local function compute_schedule(t)
    local now_min = t.hour * 60 + t.min
    local winning, fires = nil, {}
    for _, ev in ipairs(STATE.schedule_layers) do
        if date_active(ev, t.month, t.day) then
            if ev.type == "loop" then
                local active
                if ev.start_min <= ev.end_min then
                    active = now_min >= ev.start_min and now_min < ev.end_min
                else
                    active = now_min >= ev.start_min or now_min < ev.end_min   -- overnight
                end
                if active then winning = ev.id end        -- later lines overwrite earlier ones
            else
                if now_min ~= ev.last_min then ev.last_min, ev.fired = now_min, false end
                if now_min == ev.start_min and not ev.fired then
                    ev.fired = true
                    fires[#fires + 1] = ev.id
                end
            end
        end
    end
    return winning, fires
end

local function request_loop(target)
    if target == STATE.current_loop then
        STATE.pending_loop = nil
    elseif STATE.phase == "media" or STATE.phase == "cutscene" then
        if STATE.pending_loop ~= target then
            log("Scheduler: " .. target .. " queued until the current media ends")
            STATE.pending_loop = target
        end
    else
        switch_loop(target)
    end
end

local function evaluate_schedule()
    local winning, fires = compute_schedule(os.date("*t"))
    local target = winning or CONFIG.DEFAULT_LOOP
    if target ~= STATE.sched_loop then
        STATE.sched_loop = target
        request_loop(target)
    end
    for _, mid in ipairs(fires) do
        if resolve_media_folder(mid) then
            log("Scheduler: trigger " .. mid)
            if STATE.phase == "media" or STATE.phase == "cutscene" then
                STATE.pending_media = mid
            else
                start_media(mid, nil)
            end
        else
            warn_once("nomedia" .. mid, "Scheduled media " .. mid .. " has no folder")
        end
    end
end


-- ==============================================================================
-- SECTION 15: STARTUP
-- ==============================================================================

local function init()
    if STATE._initialised then return end
    STATE._initialised = true
    log("Starting up")
    math.randomseed(os.time())
    math.random(); math.random(); math.random()

    mp.set_property("keep-open",     "no")        -- let mpv report eof
    mp.set_property("loop-file",     "no")
    mp.set_property("loop-playlist", "no")
    mp.set_property("idle",          "yes")
    mp.set_property("force-window",  "yes")       -- keep the (black) window while between clips
    mp.set_property_number("brightness", 0)
    STATE.bright = 0

    load_config()
    scan_root()
    register_keybinds()
    load_schedule()

    -- Start directly in the loop the schedule wants (no flash of the default loop)
    local winning = compute_schedule(os.date("*t"))
    local wanted  = winning or CONFIG.DEFAULT_LOOP
    STATE.sched_loop   = wanted
    STATE.current_loop = MODES.loops[wanted] and wanted or CONFIG.DEFAULT_LOOP
    if not MODES.loops[STATE.current_loop] then
        warn("Default loop folder '" .. CONFIG.DEFAULT_LOOP .. "' not found in " .. PATHS.ROOT)
    end

    mp.register_event("end-file", on_end_file)
    mp.observe_property("time-remaining", "number", on_time_remaining)

    -- Overlay sizes depend on the video size: rebuild them if a clip has another size
    local function on_video_size()
        local w = mp.get_property_number("video-params/w")
        local h = mp.get_property_number("video-params/h")
        if w and h and w > 0 and h > 0 and (w ~= STATE.vw or h ~= STATE.vh) then
            STATE.vw, STATE.vh = w, h
            if STATE.vf_graph ~= "" then apply_overlays() end
        end
    end
    mp.observe_property("video-params/w", "number", on_video_size)
    mp.observe_property("video-params/h", "number", on_video_size)

    mp.add_periodic_timer(CONFIG.TICK_INTERVAL, evaluate_schedule)
    play_loop()
    log("Ready")
end

mp.add_timeout(0.1, init)
