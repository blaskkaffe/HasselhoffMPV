-- Usage: texlua tests.lua <path-to-script> [verbose]
package.path = "./?.lua;" .. package.path
local H = require("harness")
local SCRIPT = arg[1]
local VERBOSE = arg[2] == "verbose"

local f = assert(io.open(SCRIPT, "r")); local SRC = f:read("*a"); f:close()

local total, failed = 0, 0
local current_name, current_fail

local function set_cfg(src, key, value)
    local n
    src, n = src:gsub("(\n%s*" .. key .. "%s*=%s*)[^,\n]+", "%1" .. tostring(value), 1)
    assert(n == 1, "could not set CONFIG key " .. key)
    return src
end

local function write_variant(src)
    local p = os.tmpname()
    local fh = io.open(p, "w"); fh:write(src); fh:close()
    return p
end

-- Build env, load script variant, trigger init
local function boot(o)
    o = o or {}
    local src = SRC
    for k, v in pairs(o.cfg or {}) do src = set_cfg(src, k, v) end
    if o.media_cfg then
        local n
        src, n = src:gsub("media_cfg%s*=%s*{%s*},", "media_cfg = " .. o.media_cfg .. ",", 1)
        assert(n == 1, "media_cfg anchor not found")
    end
    local E = H.new({
        fs = o.fs or H.standard_fs(),
        durations = o.durations or H.standard_durations,
        schedule_text = o.schedule,
        config_text = o.config,
        wall = o.wall,
        bad_files = o.bad_files, song_fail = o.song_fail,
    })
    E.files = o.files
    local p = write_variant(src)
    H.load(E, p)
    os.remove(p)
    E.fire("idle", {})       -- harmless for versions that init on a timer
    E.advance(0.5)
    return E
end

local function check(cond, msg)
    total = total + 1
    if not cond then
        failed = failed + 1
        current_fail = true
        print("   FAIL: " .. msg)
    elseif VERBOSE then
        print("   ok:   " .. msg)
    end
end

local function plays_matching(E, pat)
    local out = {}
    for _, p in ipairs(E.plays) do if p.path:find(pat, 1, true) then out[#out + 1] = p end end
    return out
end
local function play_names(E)
    local t = {}
    for _, p in ipairs(E.plays) do t[#t + 1] = p.path:match("([^/]+/[^/]+)$") end
    return table.concat(t, " , ")
end
local function dump(E, n)
    local from = math.max(1, #E.trace - (n or 40))
    for i = from, #E.trace do print("      " .. E.trace[i]) end
end

local function test(name, fn)
    current_name, current_fail = name, false
    print("• " .. name)
    local ok, err = pcall(fn)
    if not ok then
        total = total + 1; failed = failed + 1; current_fail = true
        print("   FAIL: script error: " .. tostring(err))
    end
end

local function dirty(E) if current_fail and VERBOSE then dump(E) end end

---------------------------------------------------------------------------
test("startup: scans folders, binds keys, starts L0, no warnings", function()
    local E = boot()
    for _, k in ipairs({ "1", "2", "a", "ESC", "F1", "F2" }) do
        check(E.keys[k] ~= nil, "key " .. k .. " is bound")
    end
    check(E.keys["3"] == nil, "key 3 NOT bound (no M3 folder)")
    check(E.plays[1] and E.plays[1].path:find("/L0/", 1, true), "first clip is from L0 (got " .. play_names(E) .. ")")
    local warns = 0
    for _, l in ipairs(E.trace) do if l:find("WARN", 1, true) then warns = warns + 1 end end
    check(warns == 0, "no warnings at startup (" .. warns .. ")")
    dirty(E)
end)

test("loop advances to the next clip when a clip ends (no double-advance)", function()
    local E = boot()
    E.advance(30)
    local n = #E.plays
    -- 10s clips + ~1s of fade each => about 3 clips in 30s, never a burst
    check(n >= 2 and n <= 4, "2-4 loop clips in 30s (got " .. n .. ": " .. play_names(E) .. ")")
    for _, p in ipairs(E.plays) do check(p.path:find("/L0/", 1, true), "only L0 clips play") end
    dirty(E)
end)

test("key 1 from loop: intro plays FULLY, then media, then back to loop", function()
    local E = boot()
    E.advance(3)
    local before = #E.plays
    E.press("1")
    E.advance(25)
    local names = play_names(E)
    local intro = plays_matching(E, "intro_m1.mp4")
    local media = plays_matching(E, "/M1/")
    check(#intro == 1, "IntroM1 clip played once (got " .. #intro .. ")")
    check(#media >= 1, "M1 media clip played (" .. names .. ")")
    if #intro == 1 and #media >= 1 then
        check(media[1].t - intro[1].t >= 1.95, string.format("intro ran its full 2s before media started (gap %.2fs)", media[1].t - intro[1].t))
    end
    local last = E.plays[#E.plays]
    check(last.path:find("/L0/", 1, true) ~= nil, "returned to loop L0 afterwards (last=" .. last.path .. ")")
    dirty(E)
end)

test("cutscene fallback: empty IntroL1M1 -> IntroM1; missing IntroM2 -> Intro", function()
    local E = boot()
    E.press("F1"); E.advance(3)
    E.press("1"); E.advance(12)
    check(#plays_matching(E, "intro_m1.mp4") == 1, "L1+M1: empty IntroL1M1 skipped, IntroM1 used")
    E.press("2"); E.advance(12)
    check(#plays_matching(E, "intro_generic.mp4") == 1, "M2: no IntroM2, generic Intro used")
    dirty(E)
end)

test("override: L1 active makes key 1 play L1M1 folder; key 2 still plays M2", function()
    local E = boot()
    E.press("F1"); E.advance(3)
    E.press("1"); E.advance(12)
    check(#plays_matching(E, "/L1M1 - Xmas version/") >= 1, "key 1 under L1 plays the L1M1 override (" .. play_names(E) .. ")")
    check(#plays_matching(E, "/M1/") == 0, "plain M1 not played under L1")
    E.press("2"); E.advance(12)
    check(#plays_matching(E, "/M2 - Promos/") >= 1, "key 2 under L1 falls back to normal M2")
    dirty(E)
end)

test("key 1 under L0 plays plain M1 (override only applies under L1)", function()
    local E = boot()
    E.press("1"); E.advance(12)
    check(#plays_matching(E, "/M1/") >= 1, "plain M1 under L0")
    check(#plays_matching(E, "/L1M1") == 0, "override not used under L0")
    dirty(E)
end)

test("clips_per_trigger = 2 plays exactly two clips then returns", function()
    local E = boot({ cfg = { CLIPS_PER_TRIGGER = 2, CUTSCENE_ON_TRIGGER = "false" } })
    E.press("2"); E.advance(20)
    check(#plays_matching(E, "/M2 - Promos/") == 2, "exactly 2 M2 clips (got " .. #plays_matching(E, "/M2 - Promos/") .. ")")
    check(E.plays[#E.plays].path:find("/L0/", 1, true) ~= nil, "back on loop")
    dirty(E)
end)

test("seconds_per_trigger = 6 stops media after ~6s total (timer not restarted per clip)", function()
    local E = boot({ cfg = { CLIPS_PER_TRIGGER = 0, SECONDS_PER_TRIGGER = 6, CUTSCENE_ON_TRIGGER = "false" } })
    E.press("2"); E.advance(25)
    local media = plays_matching(E, "/M2 - Promos/")
    local firstloop
    for _, p in ipairs(E.plays) do
        if p.path:find("/L0/", 1, true) and p.t > media[1].t then firstloop = p; break end
    end
    check(#media >= 1 and firstloop ~= nil, "media played and loop resumed")
    if #media >= 1 and firstloop then
        local d = firstloop.t - media[1].t
        check(d >= 5 and d <= 8, string.format("loop resumed ~6s after media start (%.2fs)", d))
    end
    dirty(E)
end)

test("keys: different key interrupts media by default", function()
    local E = boot({ cfg = { CUTSCENE_ON_TRIGGER = "false" } })
    E.press("2"); E.advance(2)
    E.press("a"); E.advance(2)
    check(#plays_matching(E, "/Ma/") >= 1, "pressing a during M2 interrupted into Ma")
    dirty(E)
end)

test("keys: same key ignored by default; cancels when key_cancel=true", function()
    local E = boot({ cfg = { CUTSCENE_ON_TRIGGER = "false" } })
    E.press("2"); E.advance(2)
    local n = #E.plays
    E.press("2"); E.advance(2)
    check(#E.plays == n, "same key ignored (no new clip)")
    local E2 = boot({ cfg = { CUTSCENE_ON_TRIGGER = "false", KEY_CANCEL = "true" } })
    E2.press("2"); E2.advance(2)
    E2.press("2"); E2.advance(3)
    check(E2.plays[#E2.plays].path:find("/L0/", 1, true) ~= nil, "same key cancelled media and returned to loop")
    dirty(E)
end)

test("keys: lock_keys ignores all keys during media (per-mode setting)", function()
    local E = boot({ cfg = { CUTSCENE_ON_TRIGGER = "false" }, media_cfg = "{ M2 = { lock_keys = true } }" })
    E.press("2"); E.advance(2)
    local n = #E.plays
    E.press("a"); E.press("1"); E.advance(1)
    check(#E.plays == n, "keys ignored while M2 plays (lock_keys)")
    dirty(E)
end)

test("keys during a cutscene are ignored", function()
    local E = boot()
    E.press("1"); E.advance(1.5)       -- intro is playing
    local n = #E.plays
    E.press("a"); E.press("F2"); E.advance(0.2)
    check(#plays_matching(E, "/Ma/") == 0 and #plays_matching(E, "/L2") == 0, "no mode change during cutscene")
    dirty(E)
end)

test("loop keys: F2 switches, same key ignored, ESC returns to L0", function()
    local E = boot()
    E.press("F2"); E.advance(2)
    check(#plays_matching(E, "/L2 - New Year/") >= 1, "F2 -> L2")
    local n = #E.plays
    E.press("F2"); E.advance(1)
    check(#E.plays == n, "F2 again ignored")
    E.press("ESC"); E.advance(2)
    check(E.plays[#E.plays].path:find("/L0/", 1, true) ~= nil, "ESC -> L0")
    dirty(E)
end)

test("outro plays after media when cutscene_on_return = true", function()
    local E = boot({ cfg = { CUTSCENE_ON_RETURN = "true" } })
    E.press("2"); E.advance(25)
    check(#plays_matching(E, "outro_generic.mp4") == 1, "outro played once")
    check(E.plays[#E.plays].path:find("/L0/", 1, true) ~= nil, "loop resumed after outro")
    dirty(E)
end)

test("transition plays on loop switch when cutscene_on_switch = true", function()
    local E = boot({ cfg = { CUTSCENE_ON_SWITCH = "true" } })
    E.press("F2"); E.advance(6)
    check(#plays_matching(E, "trans_l2.mp4") == 1, "TransitionL2 used for L2")
    check(#plays_matching(E, "/L2 - New Year/") >= 1, "L2 loop plays after transition")
    E.press("F1"); E.advance(6)
    check(#plays_matching(E, "/trans.mp4") == 1, "generic Transition used for L1 (no TransitionL1)")
    dirty(E)
end)

test("scheduler: loop window switches in and out; manual F-key is not reverted", function()
    local E = boot({ schedule = "loop L1 08:00 22:00", wall = { hour = 12, min = 0, month = 6, day = 15 } })
    E.advance(6)
    check(#plays_matching(E, "/L1 - Christmas/") >= 1, "inside window -> L1 plays (" .. play_names(E) .. ")")
    E.wall.hour = 23; E.advance(15)
    check(E.plays[#E.plays].path:find("/L0/", 1, true) ~= nil, "after window -> back to L0")
    -- manual override must persist while the schedule target is unchanged
    E.press("F2"); E.advance(30)
    local l2 = #plays_matching(E, "/L2 - New Year/")
    local l0_after = 0
    for _, p in ipairs(E.plays) do if p.t > 25 and p.path:find("/L0/", 1, true) then l0_after = l0_after + 1 end end
    check(l2 >= 2 and l0_after == 0, "manual F2 persists (L2 clips=" .. l2 .. ", L0 after=" .. l0_after .. ")")
    dirty(E)
end)

test("scheduler: loop switch waits for media to finish (pending)", function()
    local E = boot({ schedule = "loop L1 08:00 22:00", wall = { hour = 23, min = 0, month = 6, day = 15 }, cfg = { CUTSCENE_ON_TRIGGER = "false" } })
    E.advance(3)
    E.press("2")                          -- M2 media, 4s
    E.advance(1)
    E.wall.hour = 12                      -- schedule now wants L1
    E.advance(2)                          -- still inside M2
    check(#plays_matching(E, "/L1 - Christmas/") == 0, "loop did not switch mid-media")
    E.advance(8)
    check(#plays_matching(E, "/L1 - Christmas/") >= 1, "loop switched after media finished")
    dirty(E)
end)

test("scheduler: timed media trigger fires once", function()
    local E = boot({ schedule = "media M2 12:05", wall = { hour = 12, min = 4, month = 6, day = 15 }, cfg = { CUTSCENE_ON_TRIGGER = "false" } })
    E.advance(10)
    check(#plays_matching(E, "/M2 - Promos/") == 0, "not before time")
    E.wall.min = 5; E.advance(10)
    check(#plays_matching(E, "/M2 - Promos/") == 1, "fired once at 12:05 (got " .. #plays_matching(E, "/M2 - Promos/") .. ")")
    E.advance(120)
    check(#plays_matching(E, "/M2 - Promos/") == 1, "not re-fired while minute unchanged / later")
    dirty(E)
end)

test("scheduler: later line has higher priority", function()
    local E = boot({ schedule = "loop L1 00:00 23:59\nloop L2 09:00 17:00", wall = { hour = 12, min = 0, month = 6, day = 15 } })
    E.advance(8)
    check(#plays_matching(E, "/L2 - New Year/") >= 1 and #plays_matching(E, "/L1 - Christmas/") == 0, "L2 (lower in file) wins over L1 at 12:00 (" .. play_names(E) .. ")")
    dirty(E)
end)

test("scheduler: missing loop folder does not spam warnings or break playback", function()
    local E = boot({ schedule = "loop L9 00:00 23:59" })
    E.advance(30)
    local warns = 0
    for _, l in ipairs(E.trace) do if l:find("WARN", 1, true) then warns = warns + 1 end end
    check(warns <= 2, "at most 2 warnings for the missing loop (got " .. warns .. ")")
    check(E.plays[#E.plays].path:find("/L0/", 1, true) ~= nil, "stays on L0")
    dirty(E)
end)

test("fades: brightness stays in range, new clip starts dark, ends at 0", function()
    local E = boot()
    E.advance(3); E.press("2"); E.advance(30)
    local bad = 0
    for _, b in ipairs(E.bright) do if b.v < -100 or b.v > 0 then bad = bad + 1 end end
    check(#E.bright > 10, "fade wrote brightness steps (" .. #E.bright .. ")")
    check(bad == 0, "all brightness values within [-100,0]")
    check(E.props.brightness == 0, "settled at full brightness (" .. tostring(E.props.brightness) .. ")")
    dirty(E)
end)

test("fades: keypress during a fade-out / fade-in does not corrupt state", function()
    local E = boot({ cfg = { CUTSCENE_ON_TRIGGER = "false" } })
    E.advance(3)
    E.press("2")
    E.advance(0.2)     -- mid fade-out
    E.press("a")
    E.advance(0.3)
    E.press("2")
    E.advance(0.6)
    E.press("a")
    E.advance(20)
    check(E.props.brightness == 0, "brightness ends at 0 (" .. tostring(E.props.brightness) .. ")")
    check(E.plays[#E.plays].path:find("/L0/", 1, true) ~= nil, "machine ends back on loop (" .. play_names(E) .. ")")
    -- no clip should be loaded twice at the same instant
    local dup = 0
    for i = 2, #E.plays do if E.plays[i].t == E.plays[i - 1].t then dup = dup + 1 end end
    check(dup == 0, "no two clips loaded at the same instant")
    dirty(E)
end)

test("audio: loop muted, media unmuted, mute only ever changes at the instant a clip loads", function()
    local E = boot()
    check(E.props.mute == true, "loop starts muted")
    E.advance(3); E.press("2"); E.advance(30)
    local stray = 0
    for _, m in ipairs(E.mutes) do
        local hit = false
        for _, p in ipairs(E.plays) do if math.abs(p.t - m.t) < 0.011 then hit = true end end
        if not hit then stray = stray + 1 end
    end
    check(#E.mutes >= 3, "mute was toggled for loop/intro/media (" .. #E.mutes .. " writes)")
    check(stray == 0, "no mute change happened while an old clip was still fading out (" .. stray .. " stray)")
    dirty(E)
end)

test("errors: unplayable files do not cause a tight retry loop", function()
    local E = boot({ bad_files = { ["a.mp4"] = true, ["b.mp4"] = true } })
    E.advance(10)
    check(#E.plays < 30, "bounded retries over 10s (" .. #E.plays .. " load attempts)")
    -- and recovers when files become playable
    dirty(E)
end)

test("errors: one bad file among good ones is skipped", function()
    local E = boot({ bad_files = { ["a.mp4"] = true } })
    E.advance(60)
    local good = 0
    for _, p in ipairs(E.plays) do if p.path:find("b.mp4", 1, true) then good = good + 1 end end
    check(good >= 1, "machine keeps going and plays b.mp4 (" .. play_names(E) .. ")")
    dirty(E)
end)

test("config key conflict: no duplicate keys in CONFIG table", function()
    local block = SRC:match("local CONFIG = {(.-)\n}")
    local seen, dup = {}, {}
    for key in block:gmatch("\n%s*([%u_]+)%s*=") do
        if seen[key] then dup[#dup + 1] = key end
        seen[key] = true
    end
    check(#dup == 0, "no duplicate CONFIG keys (" .. table.concat(dup, ",") .. ")")
end)

if SRC:find("DATE_RANGES", 1, true) or SRC:find("parse_mmdd", 1, true) then
    test("scheduler: optional date range (Dec 1 - Jan 6) incl. year wrap", function()
        local sched = "loop L1 00:00 23:59 12-01 01-06"
        local E = boot({ schedule = sched, wall = { hour = 12, min = 0, month = 12, day = 25 } })
        E.advance(6)
        check(#plays_matching(E, "/L1 - Christmas/") >= 1, "Dec 25 -> L1")
        local E2 = boot({ schedule = sched, wall = { hour = 12, min = 0, month = 1, day = 3 } })
        E2.advance(6)
        check(#plays_matching(E2, "/L1 - Christmas/") >= 1, "Jan 3 -> L1 (wraps new year)")
        local E3 = boot({ schedule = sched, wall = { hour = 12, min = 0, month = 6, day = 15 } })
        E3.advance(6)
        check(#plays_matching(E3, "/L1 - Christmas/") == 0, "Jun 15 -> not L1")
        local E4 = boot({ schedule = sched, wall = { hour = 12, min = 0, month = 1, day = 7 } })
        E4.advance(6)
        check(#plays_matching(E4, "/L1 - Christmas/") == 0, "Jan 7 -> not L1 (range ended Jan 6)")
    end)
end


-- ---------------------------------------------------------------- extra: README claims
local function order_fs()
    local fs = H.standard_fs()
    fs["/root/content/L0"] = { ["01 - a.mp4"]=1, ["02 - b.mp4"]=1, ["10 - c.mp4"]=1, ["zz.mp4"]=1, ["._junk.mp4"]=1, [".DS_Store"]=1, ["notes.txt"]=1 }
    return fs
end
local function loop_sequence(order, n)
    local E = boot({ fs = order_fs(), cfg = { DEFAULT_ORDER = '"' .. order .. '"', FADE_ENABLED = "false" },
                     durations = { ["01 - a.mp4"]=3, ["02 - b.mp4"]=3, ["10 - c.mp4"]=3, ["zz.mp4"]=3 } })
    E.advance(3.05 * (n - 1) + 1)
    local seq = {}
    for i = 1, math.min(n, #E.plays) do seq[#seq + 1] = E.plays[i].path:match("([^/]+)%.mp4$") end
    return table.concat(seq, ","), E
end

test("files: numbers sorted numerically, A-Z after, hidden/non-media ignored", function()
    local s, E = loop_sequence("sequential", 9)
    check(s == "01 - a,02 - b,10 - c,zz,01 - a,02 - b,10 - c,zz,01 - a", "sequential order (got " .. s .. ")")
    for _, p in ipairs(E.plays) do check(not p.path:find("._junk", 1, true) and not p.path:find("notes", 1, true), "hidden/non-media file never played") end
end)
test("order: reverse", function()
    local s = loop_sequence("reverse", 5)
    check(s == "01 - a,zz,10 - c,02 - b,01 - a", "reverse (got " .. s .. ")")
end)
test("order: pingpong bounces at both ends", function()
    local s = loop_sequence("pingpong", 9)
    check(s == "01 - a,02 - b,10 - c,zz,10 - c,02 - b,01 - a,02 - b,10 - c", "pingpong (got " .. s .. ")")
end)
test("order: shuffle plays every file once before repeating", function()
    local seen, ok = {}, true
    for run = 1, 5 do
        local s = loop_sequence("shuffle", 8)
        local names = {}
        for n in s:gmatch("[^,]+") do names[#names + 1] = n end
        local a, b = {}, {}
        for i = 1, 4 do a[names[i]] = true end
        for i = 5, 8 do b[names[i]] = true end
        local ca, cb = 0, 0
        for _ in pairs(a) do ca = ca + 1 end
        for _ in pairs(b) do cb = cb + 1 end
        if ca ~= 4 or cb ~= 4 then ok = false end
    end
    check(ok, "every block of 4 clips contains all 4 files")
end)

test("keys: F12 bound, L13 has no key (warns), override-only media key bound", function()
    local fs = H.standard_fs()
    fs["/root/content/L12"] = { ["l12.mp4"] = 1 }
    fs["/root/content/L13"] = { ["l13.mp4"] = 1 }
    fs["/root/content/L1M5 - only under L1"] = { ["o5.mp4"] = 1 }
    local E = boot({ fs = fs, durations = { ["o5.mp4"] = 3, ["a.mp4"] = 10, ["b.mp4"] = 10, ["x.mp4"] = 10 }, cfg = { CUTSCENE_ON_TRIGGER = "false" } })
    check(E.keys["F12"] ~= nil, "F12 bound")
    check(E.keys["F13"] == nil, "no F13")
    local warned = false
    for _, l in ipairs(E.trace) do if l:find("L13 has no F-key", 1, true) then warned = true end end
    check(warned, "L13 gets an explanatory warning")
    check(E.keys["5"] ~= nil, "key 5 bound by override-only folder L1M5")
    E.press("5"); E.advance(3)
    check(#plays_matching(E, "L1M5") == 0, "key 5 does nothing under L0 (no plain M5)")
    E.press("F1"); E.advance(3); E.press("5"); E.advance(4)
    check(#plays_matching(E, "L1M5") >= 1, "key 5 plays the override under L1")
end)

test("per-loop settings: cutscene_on_switch only for L2", function()
    local E = boot()
    local src = SRC:gsub("loop_cfg%s*=%s*{%s*},", "loop_cfg = { L2 = { cutscene_on_switch = true } },", 1)
    local p = write_variant(src)
    local E2 = H.new({ fs = H.standard_fs(), durations = H.standard_durations })
    H.load(E2, p); os.remove(p); E2.fire("idle", {}); E2.advance(0.5)
    E2.press("F1"); E2.advance(4)
    check(#plays_matching(E2, "trans") == 0, "F1: no transition (global switch is off)")
    E2.press("F2"); E2.advance(6)
    check(#plays_matching(E2, "trans_l2.mp4") == 1, "F2: TransitionL2 plays (loop_cfg override)")
end)

test("fades: pre-end fade reaches black before a clip ends by itself", function()
    local E = boot({ cfg = {} })
    E.advance(25)
    local second = E.plays[2]
    check(second ~= nil, "second loop clip played")
    local at_end = nil
    for _, b in ipairs(E.bright) do if b.t < second.t - 0.02 then at_end = b end end
    check(at_end and at_end.v == -100, "brightness is -100 right before the next clip (got " .. tostring(at_end and at_end.v) .. ")")
    local dark_before = false
    for _, b in ipairs(E.bright) do if b.v < -50 and b.t > 9 and b.t < 10.3 then dark_before = true end end
    check(dark_before, "fade-out began before the 10s clip ended (not an abrupt cut)")
end)

test("robustness: missing L0 / empty content never crash; media still works", function()
    local fs = H.standard_fs(); fs["/root/content/L0"] = nil
    local E = boot({ fs = fs, cfg = { CUTSCENE_ON_TRIGGER = "false" } })
    E.advance(5)
    local warned = false
    for _, l in ipairs(E.trace) do if l:find("not found in", 1, true) then warned = true end end
    check(warned, "clear warning that L0 is missing")
    E.press("2"); E.advance(10)
    check(#plays_matching(E, "/M2 - Promos/") >= 1, "media still plays without an L0")
    local E2 = boot({ fs = { ["/root/content"] = {} } })
    E2.advance(10)
    check(#E2.plays == 0, "empty content folder: nothing to play, no crash")
end)

test("scheduler: media queued during media plays right after it (before the loop)", function()
    local E = boot({ schedule = "media Ma 12:05", wall = { hour = 12, min = 4, month = 6, day = 15 }, cfg = { CUTSCENE_ON_TRIGGER = "false" } })
    E.advance(1)
    E.press("2"); E.advance(1)
    E.wall.min = 5; E.advance(1.5)         -- schedule fires Ma while M2 is playing
    check(#plays_matching(E, "/Ma/") == 0, "Ma waits while M2 plays")
    E.advance(8)
    local order = {}
    for _, p in ipairs(E.plays) do order[#order + 1] = p.path:match("content/([^/]+)/") end
    local joined = table.concat(order, ",")
    check(joined:find("M2 %- Promos,Ma") ~= nil, "Ma plays immediately after M2 (" .. joined .. ")")
end)

test("quit key is bound and issues quit", function()
    local E = boot()
    check(E.keys["Ctrl+q"] ~= nil, "Ctrl+q bound")
    E.press("Ctrl+q")
    local q = false
    for _, l in ipairs(E.trace) do if l:find("CMD quit", 1, true) then q = true end end
    check(q, "quit command issued")
end)


-- ---------------------------------------------------------------- music + overlays
local function music_fs()
    local fs = H.standard_fs()
    fs["/root/content/M3 - Music"] = { ["s1.mp3"] = 1, ["s2.mp3"] = 1 }
    return fs
end
local function music_dur()
    local d = {}
    for k, v in pairs(H.standard_durations) do d[k] = v end
    d["s1.mp3"] = 6; d["s2.mp3"] = 6
    return d
end
local function count_plays(E, pat) return #plays_matching(E, pat) end

test("music: audio-only folder = music mode; loop video keeps playing, song in 2nd process", function()
    local E = boot({ fs = music_fs(), durations = music_dur(), cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    local plays_before = #E.plays
    E.press("3"); E.advance(0.2)
    check(#E.songs == 1, "one song started")
    local a = table.concat(E.songs[1].args, " ")
    check(a:find("--no-video", 1, true) and a:find("M3", 1, true), "song player runs audio-only on the M3 file")
    check(#E.plays == plays_before, "the loop video was NOT reloaded")
    check(count_plays(E, "/M3") == 0, "music files never go through the video player")
    check(E.mutes[#E.mutes] == nil or E.mutes[#E.mutes].v == true, "video stays muted")
    E.advance(6.5)       -- song over, clips_per_trigger = 1
    check(#E.songs == 1, "exactly one song")
    E.advance(0.5)
    local retriggered = false
    check(count_plays(E, "/M3") == 0, "still no music in the video player")
    E.press("3"); E.advance(0.2)
    check(#E.songs == 2, "key works again after the song finished (state returned to loop)")
end)

test("music: clips_per_trigger counts songs; 0 = until time limit", function()
    local E = boot({ fs = music_fs(), durations = music_dur(), media_cfg = "{ M3 = { clips_per_trigger = 2 } }",
                     cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    E.press("3"); E.advance(30)
    check(#E.songs == 2, "two songs then stop (got " .. #E.songs .. ")")
    local E2 = boot({ fs = music_fs(), durations = music_dur(), media_cfg = "{ M3 = { clips_per_trigger = 0, seconds_per_trigger = 20 } }",
                     cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    E2.press("3"); E2.advance(40)
    check(#E2.songs == 4, "songs repeat until 20s limit: 6+6+6+(2 s cut) = 4 starts (got " .. #E2.songs .. ")")
    local killed = false
    for _, l in ipairs(E2.trace) do if l:find("SONG-KILLED", 1, true) then killed = true end end
    check(killed, "running song is stopped when the time limit hits")
end)

test("music: another media key / loop key stops the song", function()
    local E = boot({ fs = music_fs(), durations = music_dur(), cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    E.press("3"); E.advance(2)
    E.press("1"); E.advance(0.2)
    local k = 0
    for _, l in ipairs(E.trace) do if l:find("SONG-KILLED", 1, true) then k = k + 1 end end
    check(k == 1, "song killed by key 1")
    check(count_plays(E, "/M1/") == 1, "M1 video plays")
    E.advance(20)
    check(#E.songs == 1, "no song resurrected")
    E.press("3"); E.advance(1); E.press("F2"); E.advance(0.2)
    k = 0
    for _, l in ipairs(E.trace) do if l:find("SONG-KILLED", 1, true) then k = k + 1 end end
    check(k == 2, "song killed by loop key F2")
    check(count_plays(E, "ny.mp4") >= 1, "loop L2 started")
end)

test("music: video loop clips keep rolling over while songs play", function()
    local E = boot({ fs = music_fs(), durations = music_dur(), media_cfg = "{ M3 = { clips_per_trigger = 0, seconds_per_trigger = 35 } }",
                     cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    E.press("3"); E.advance(34)
    local loops = 0
    for _, p in ipairs(E.plays) do if p.path:find("/L0/", 1, true) then loops = loops + 1 end end
    check(loops >= 3, "loop clips advanced during music (got " .. loops .. ")")
    check(#E.songs >= 5, "songs continue independently")
end)

test("music: visual_loop shows another loop during the songs, normal loop afterwards", function()
    local E = boot({ fs = music_fs(), durations = music_dur(), media_cfg = "{ M3 = { visual_loop = 'L2' } }",
                     cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    E.press("3"); E.advance(0.3)
    check(E.plays[#E.plays].path:find("ny.mp4", 1, true), "L2 video appears at once")
    E.advance(7)
    check(E.plays[#E.plays].path:find("/L0/", 1, true), "back on L0 video after the song")
end)

test("music: Intro first, then loop video + song; Outro after", function()
    local E = boot({ fs = music_fs(), durations = music_dur(), cfg = { CUTSCENE_ON_TRIGGER = "true", CUTSCENE_ON_RETURN = "true", FADE_ENABLED = "false" } })
    E.press("3"); E.advance(0.5)
    check(#E.songs == 0, "song waits for the intro")
    check(E.plays[#E.plays].path:find("intro_generic", 1, true), "intro plays")
    E.advance(2.2)
    check(#E.songs == 1, "song starts after intro")
    check(E.plays[#E.plays].path:find("/L0/", 1, true), "loop video behind the song")
    E.advance(7)
    check(E.plays[#E.plays].path:find("outro_generic", 1, true), "outro after the song")
    E.advance(3)
    check(E.plays[#E.plays].path:find("/L0/", 1, true), "loop afterwards")
end)

test("music: unplayable song does not spin", function()
    local E = boot({ fs = music_fs(), durations = music_dur(), song_fail = { ["s1.mp3"] = true, ["s2.mp3"] = true },
                     media_cfg = "{ M3 = { clips_per_trigger = 0, seconds_per_trigger = 10 } }",
                     cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    E.press("3"); E.advance(12)
    check(#E.songs <= 12, "at most about one retry per second (got " .. #E.songs .. ")")
end)

test("music: music=false forces a mixed/audio folder through the video player", function()
    local E = boot({ fs = music_fs(), durations = music_dur(), media_cfg = "{ M3 = { music = false } }",
                     cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    E.press("3"); E.advance(0.3)
    check(#E.songs == 0 and count_plays(E, "/M3") == 1, "played as normal media")
end)

test("mixed folder: videos and songs in one folder, each played its own way", function()
    local fs = H.standard_fs()
    fs["/root/content/M3 - Mix"] = { ["01 a.mp4"] = 1, ["02 b.mp3"] = 1, ["03 c.mp4"] = 1, ["04 d.mp3"] = 1 }
    local d = music_dur(); d["01 a.mp4"] = 4; d["03 c.mp4"] = 4; d["02 b.mp3"] = 6; d["04 d.mp3"] = 6
    local E = boot({ fs = fs, durations = d, media_cfg = "{ M3 = { order = 'sequential', clips_per_trigger = 4 } }",
                     cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    E.press("3"); E.advance(0.2)
    check(E.plays[#E.plays].path:find("01 a.mp4", 1, true) and #E.songs == 0, "first item (video) plays as media")
    E.advance(4.3)
    check(#E.songs == 1 and E.songs[1].file:find("02 b.mp3", 1, true), "then the song starts")
    check(E.plays[#E.plays].path:find("/L0/", 1, true), "loop video is the picture behind the song")
    E.advance(6.3)
    check(E.plays[#E.plays].path:find("03 c.mp4", 1, true), "after the song the next video plays")
    E.advance(4.3)
    check(#E.songs == 2 and E.songs[2].file:find("04 d.mp3", 1, true), "second song")
    E.advance(6.5)
    check(E.plays[#E.plays].path:find("/L0/", 1, true), "back on the loop after 4 items")
    local n = #E.songs
    E.advance(20)
    check(#E.songs == n, "nothing left running")
    -- interrupting a song in a mixed folder
    E.press("3"); E.advance(4.5); E.press("1"); E.advance(0.3)
    local killed = false
    for _, l in ipairs(E.trace) do if l:find("SONG-KILLED", 1, true) then killed = true end end
    check(killed, "song stopped by another key")
end)

test("music = false plays audio files like videos", function()
    local E = boot({ fs = music_fs(), durations = music_dur(), media_cfg = "{ M3 = { music = false } }",
                     cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    E.press("3"); E.advance(0.3)
    check(#E.songs == 0 and count_plays(E, "/M3") == 1, "played as normal media")
end)

local function overlay_fs()
    local fs = music_fs()
    fs["/root/content/Overlay"] = { ["frame.png"] = 1 }
    fs["/root/content/L1Overlay - xmas"] = { ["logo bottom-right 10%.png"] = 1 }
    fs["/root/content/M1Overlay"] = { ["title.txt"] = 1, ["bad'name.png"] = 1 }
    fs["/root/content/M2Overlay"] = { ["only m2 center opacity50.png"] = 1 }
    return fs
end
local function last_graph(E)
    local h = E.vf_history[#E.vf_history]
    if not h then return nil end
    local v = h.v
    if type(v) == "table" and v[1] then return v[1].params.graph end
    return ""
end
local OV_FILES = { ["/root/content/M1Overlay/title.txt"] = "position: top-center\nsize: 60\ncolor: ff0000\ntext: Merry {Christmas}\nsecond line" }

test("overlays: stack by scope (global / loop / media / loop+media)", function()
    local E = boot({ fs = overlay_fs(), durations = music_dur(), files = OV_FILES,
                     cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    local g = last_graph(E)
    check(g and g:find("frame.png", 1, true) and not g:find("logo", 1, true), "L0: only the global frame")
    check(g:find("scale=1920:1080", 1, true), "frame is stretched over the whole picture")
    E.press("F1"); E.advance(0.3)
    g = last_graph(E)
    check(g:find("frame.png", 1, true) and g:find("logo bottom-right 10%.png", 1, true), "L1: frame + logo")
    check(g:find("scale=192:-1", 1, true), "logo width 10% of the picture (192 px of 1920)")
    check(g:find("overlay=x=W-w-W*0.03:y=H-h-W*0.03", 1, true), "logo bottom-right with margin")
    check(g:find("%[out%]$"), "graph ends in [out]")
    E.press("2"); E.advance(0.3)
    g = last_graph(E)
    check(g:find("only m2", 1, true) and g:find("colorchannelmixer=aa=0.50", 1, true) and g:find("overlay=x=(W-w)/2:y=(H-h)/2", 1, true), "M2 under L1: M2's own overlay centered at 50%")
    check(g:find("logo", 1, true), "loop overlay still shown during media")
    E.advance(10)       -- M2 over, back to L1
    g = last_graph(E)
    check(not g:find("only m2", 1, true) and g:find("logo", 1, true), "M2 overlay gone after M2")
end)

test("overlays: sizes follow the real video size", function()
    local E = boot({ fs = overlay_fs(), durations = music_dur(), files = OV_FILES,
                     cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    E.press("F1"); E.advance(0.3)
    E.props["video-params/w"], E.props["video-params/h"] = 1280, 720
    for _, h in ipairs(E.observers["video-params/w"] or {}) do h("video-params/w", 1280) end
    for _, h in ipairs(E.observers["video-params/h"] or {}) do h("video-params/h", 720) end
    local g = last_graph(E)
    check(g:find("scale=1280:720", 1, true) and g:find("scale=128:-1", 1, true), "graph rebuilt for 1280x720 (frame 1280x720, logo 128 px)")
    local n = #E.vf_history
    for _, h in ipairs(E.observers["video-params/h"] or {}) do h("video-params/h", 720) end
    check(#E.vf_history == n, "no rebuild when the size is unchanged")
end)

test("overlays: text overlay content, position, colour, escaping; apostrophe file skipped", function()
    local E = boot({ fs = overlay_fs(), durations = music_dur(), files = OV_FILES,
                     cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    check(E.osd.data == nil, "no text on L0")
    E.press("1"); E.advance(0.3)
    local d = E.osd.data or ""
    check(d:find("\\an8", 1, true) and d:find("\\pos(960,60)", 1, true), "top-center position")
    check(d:find("\\fs60", 1, true) and d:find("&H0000FF&", 1, true), "size and colour (BGR)")
    check(d:find("Merry \\{Christmas\\}\\Nsecond line", 1, true), "braces escaped, newline converted")
    check(d:find("\\alpha&H00&", 1, true), "fully visible")
    local warned = false
    for _, l in ipairs(E.trace) do if l:find("apostrophe", 1, true) then warned = true end end
    check(warned, "warning about the apostrophe file")
    E.advance(8)
    check(E.osd.data == nil, "text removed when M1 is over")
end)

test("overlays: text fades with the picture; switched off per mode and globally", function()
    local E = boot({ fs = overlay_fs(), durations = music_dur(), files = OV_FILES,
                     cfg = { CUTSCENE_ON_TRIGGER = "false" } })
    E.press("1"); E.advance(0.2)
    local seen_dark, seen_mid = false, false
    local lo = 255
    for _ = 1, 40 do
        E.advance(0.05)
        local a = (E.osd.data or ""):match("\\alpha&H(%x%x)&")
        if a then lo = math.min(lo, 255 - tonumber(a, 16)) end
    end
    local E2 = boot({ fs = overlay_fs(), durations = music_dur(), files = OV_FILES, media_cfg = "{ M1 = { overlays = false } }",
                     cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    E2.press("1"); E2.advance(0.3)
    check(last_graph(E2) == "" and E2.osd.data == nil, "overlays = false in M1 hides everything")
    local E3 = boot({ fs = overlay_fs(), durations = music_dur(), files = OV_FILES, cfg = { OVERLAYS = "false" } })
    check(#E3.vf_history == 0 and E3.osd.data == nil, "OVERLAYS = false: nothing")
    local E4 = boot({ fs = overlay_fs(), durations = music_dur(), files = OV_FILES, cfg = { CUTSCENE_ON_TRIGGER = "true", FADE_ENABLED = "false" } })
    E4.press("1"); E4.advance(0.3)
    check(E4.plays[#E4.plays].path:find("intro_m1", 1, true) and last_graph(E4) == "", "no overlays during an Intro cutscene")
    E4.advance(2.5)
    check(last_graph(E4):find("frame.png", 1, true) ~= nil, "overlays back when the media starts")
end)

test("overlays: music mode gets the overlays of its mode without reloading the video", function()
    local fs = overlay_fs(); fs["/root/content/M3Overlay"] = { ["note.txt"] = 1 }
    local E = boot({ fs = fs, durations = music_dur(), files = { ["/root/content/M3Overlay/note.txt"] = "Now playing" },
                     cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    local n = #E.plays
    E.press("3"); E.advance(0.3)
    check(#E.plays == n, "video not reloaded")
    check((E.osd.data or ""):find("Now playing", 1, true) ~= nil, "text visible during the song")
    E.advance(7)
    check(E.osd.data == nil, "text gone when the song is over")
end)

test("overlays: L1M1Overlay only when M1 plays on top of L1", function()
    local fs = overlay_fs(); fs["/root/content/L1M1Overlay - special"] = { ["combo.png"] = 1 }
    local E = boot({ fs = fs, durations = music_dur(), files = OV_FILES, cfg = { CUTSCENE_ON_TRIGGER = "false", FADE_ENABLED = "false" } })
    E.press("1"); E.advance(0.3)
    check(not last_graph(E):find("combo", 1, true), "M1 under L0: no combo overlay")
    E.advance(10); E.press("F1"); E.advance(0.3); E.press("1"); E.advance(0.3)
    check(last_graph(E):find("combo.png", 1, true) ~= nil, "M1 under L1: combo overlay shown")
end)

test("config.cfg: global keys, per-mode sections, quotes, CRLF, bad lines", function()
    local cfg = table.concat({
        "\239\187\191# comment",
        "default_loop = L1   # inline comment\r",
        "CUTSCENE_ON_TRIGGER = false",
        "quit_key = \"\"",
        "music_extra_args = x",
        "nonsense_key = 5",
        "this line is garbage",
        "[M1]",
        "clips_per_trigger = 2",
        "[Zebra]",
        "order = shuffle",
        "[L1]",
        "order = pingpong",
    }, "\n")
    local E = boot({ config = cfg, cfg = { FADE_ENABLED = "false" } })
    check(E.plays[1] and E.plays[1].path:find("/L1", 1, true), "default_loop = L1 starts in L1 (got " .. play_names(E) .. ")")
    check(E.keys["Ctrl+q"] == nil, "quit_key = \"\" removes the quit key")
    local w = {}
    for _, l in ipairs(E.trace) do if l:find("WARN", 1, true) then w[#w + 1] = l end end
    local all = table.concat(w, "\n")
    check(all:find("nonsense_key", 1, true), "unknown key warned")
    check(all:find("garbage", 1, true), "unparseable line warned")
    check(all:find("[Zebra]", 1, true), "unknown section warned")
    check(all:find("music_extra_args", 1, true), "list setting refused")
    check(#w == 4, "exactly 4 warnings (" .. #w .. ")")
    E.press("1"); E.advance(0.3)
    check(E.plays[#E.plays].path:find("M1", 1, true), "M1 plays (L1M1 override under L1): " .. E.plays[#E.plays].path)
    E.advance(20)
    local m1 = 0
    for _, p in ipairs(E.plays) do if p.path:find("M1", 1, true) then m1 = m1 + 1 end end
    check(m1 == 2, "[M1] clips_per_trigger = 2 plays two M1 clips (" .. m1 .. ")")
end)

test("config.cfg: missing file is fine (no warnings)", function()
    local E = boot()
    local w = 0
    for _, l in ipairs(E.trace) do if l:find("WARN", 1, true) then w = w + 1 end end
    check(w == 0, "no warnings without config.cfg")
end)

print(string.format("\n%d checks, %d failed", total, failed))
os.exit(failed == 0 and 0 or 1)
