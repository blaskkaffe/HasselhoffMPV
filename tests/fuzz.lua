package.path = "./?.lua;" .. package.path
local H = require("harness")
local f = assert(io.open(arg[1])); local SRC = f:read("*a"); f:close()
local RUNS = tonumber(arg[2]) or 300
-- private PRNG so the script's own math.randomseed() cannot disturb the fuzzer
local SEED = 1
local function R(a, b)
    SEED = (SEED * 1103515245 + 12345) % 2147483648
    local x = SEED / 2147483648
    if a == nil then return x end
    if b == nil then b = a; a = 1 end
    return a + math.floor(x * (b - a + 1))
end


local function set_cfg(src, key, value)
    local n
    src, n = src:gsub("(\n%s*" .. key .. "%s*=%s*)[^,\n]+", "%1" .. tostring(value), 1)
    assert(n == 1, key)
    return src
end

local keys = { "1", "2", "a", "F1", "F2", "ESC", "3", "3", "4", "4", "x" }
local scheds = {
    nil,
    "loop L1 08:00 22:00",
    "loop L1 00:00 23:59\nloop L2 09:00 17:00\nmedia M2 12:00",
    "media M2 12:01\nmedia Ma 12:02\nloop L2 12:00 12:30",
    "loop L9 00:00 23:59",
}
local failures, total_plays = 0, 0
for run = 1, RUNS do
    SEED = run * 7919 + 13
    local src = SRC
    local clips = R(0, 3)
    local secs = (clips == 0) and R(3, 9) or (R() < 0.3 and R(3, 9) or 0)
    local cfg = {
        CLIPS_PER_TRIGGER = clips, SECONDS_PER_TRIGGER = secs,
        LOCK_KEYS = tostring(R() < 0.2), KEY_CANCEL = tostring(R() < 0.4),
        CUTSCENE_ON_TRIGGER = tostring(R() < 0.6), CUTSCENE_ON_RETURN = tostring(R() < 0.5),
        CUTSCENE_ON_SWITCH = tostring(R() < 0.5), FADE_ENABLED = tostring(R() < 0.8),
        FADE_BEFORE_END = tostring(R() < 0.7),
        FADE_BLACK_HOLD = ({ 0, 0.1, 0.3 })[R(1, 3)],
        FADE_OUT_DURATION = ({ 0, 0.4, 1.5 })[R(1, 3)],
        FADE_IN_DURATION = ({ 0, 0.4, 1.5 })[R(1, 3)],
        DEFAULT_ORDER = '"' .. ({ "random", "shuffle", "sequential", "pingpong", "reverse" })[R(1, 5)] .. '"',
    }
    for k, v in pairs(cfg) do src = set_cfg(src, k, v) end
    local p = os.tmpname(); local fh = io.open(p, "w"); fh:write(src); fh:close()
    local sch = scheds[R(1, #scheds)]
    local jitter = {}
    for name, d in pairs(H.standard_durations) do jitter[name] = d + R() * 0.93 + 0.011 end
    local fs = H.standard_fs()
    fs["/root/content/M3 - Music"] = { ["s1.mp3"] = 1, ["s2.mp3"] = 1 }
    fs["/root/content/M4 - Mix"] = { ["01 a.mp4"] = 1, ["02 b.mp3"] = 1, ["03 c.mp4"] = 1 }
    jitter["01 a.mp4"] = 3 + R()*2; jitter["03 c.mp4"] = 3 + R()*2; jitter["02 b.mp3"] = 4 + R()*3
    fs["/root/content/Overlay"] = { ["frame.png"] = 1 }
    fs["/root/content/L1Overlay"] = { ["logo center 10%.png"] = 1 }
    fs["/root/content/M1Overlay"] = { ["t.txt"] = 1 }
    jitter["s1.mp3"] = 4 + R() * 3; jitter["s2.mp3"] = 3 + R() * 3
    local E = H.new({ fs = fs, durations = jitter, schedule_text = sch,
        wall = { hour = R(0, 23), min = R(0, 59), month = R(1, 12), day = R(1, 28) } })
    E.files = { ["/root/content/M1Overlay/t.txt"] = "hello" }
    local ok, err = pcall(function()
        H.load(E, p)
        E.advance(0.5)
        for _ = 1, R(5, 25) do
            local r = R()
            if r < 0.7 then E.press(keys[R(1, #keys)])
            elseif r < 0.85 then E.wall.hour = R(0, 23); E.wall.min = R(0, 59)
            end
            E.advance(R() * ({ 0.15, 0.6, 3, 8 })[R(1, 4)])
        end
        E.advance(90)       -- quiet period: no input
        -- wait for a calm mid-clip moment before sampling brightness
        for _ = 1, 200 do
            local c = E.current
            if c and (E.now - c.started) > (tonumber(cfg.FADE_IN_DURATION) or 0) + (tonumber(cfg.FADE_BLACK_HOLD) or 0) + 0.4
               and E.time_remaining() > (tonumber(cfg.FADE_OUT_DURATION) or 0) + 0.4 then break end
            E.advance(0.2)
        end
    end)
    os.remove(p)
    local problems = {}
    if not ok then problems[#problems + 1] = "LUA ERROR: " .. tostring(err) end
    if ok then
        total_plays = total_plays + #E.plays
        local last = E.plays[#E.plays]
        if not last then problems[#problems + 1] = "nothing ever played"
        else
            -- should have settled on a loop clip (media/cutscene always end)
            if not last.path:match("/L%d+[^/]*/[^/]+$") or last.path:match("/L%d+M") then
                problems[#problems + 1] = "did not settle on a loop clip: " .. last.path
            end
            if E.current and E.props.brightness ~= 0 and cfg.FADE_ENABLED == "true" then
                problems[#problems + 1] = "brightness stuck at " .. tostring(E.props.brightness)
            end
        end
        local async_gap = cfg.FADE_ENABLED == "true" and (tonumber(cfg.FADE_BLACK_HOLD) or 0) > 0
        for i = 2, #E.plays do
            if async_gap and E.plays[i].t == E.plays[i - 1].t then
                problems[#problems + 1] = "two clips loaded at t=" .. E.plays[i].t
                if os.getenv("REPRO") == tostring(run) then
                    print("---- trace around t=" .. E.plays[i].t .. " cfg:")
                    for k, v in pairs(cfg) do io.write(k, "=", tostring(v), " ") end
                    print()
                    for _, l in ipairs(E.trace) do
                        local t = tonumber(l:match("^%[%s*([%d%.]+)%]"))
                        if t and t > E.plays[i].t - 3 and t < E.plays[i].t + 1 and not l:find("LOG %[SM%] Playlist") then print(l) end
                    end
                end
                break
            end
        end
        for _, sg in ipairs(E.songs) do
            if sg.alive then problems[#problems + 1] = "a song is still running after the quiet period"; break end
        end
        if E.osd.data ~= nil then problems[#problems + 1] = "text overlay left on screen (M1 not active)"; end
        local late = 0
        for _, pl in ipairs(E.plays) do if pl.t > E.now - 60 then late = late + 1 end end
        if late > 60 then problems[#problems + 1] = "too many loads in the quiet period: " .. late end
        for _, b in ipairs(E.bright) do if b.v < -100 or b.v > 0 then problems[#problems + 1] = "brightness out of range"; break end end
    end
    if #problems > 0 then
        failures = failures + 1
        if failures <= 6 then
            print(string.format("run %d FAILED (clips=%s secs=%s sched=%s):", run, tostring(cfg.CLIPS_PER_TRIGGER), tostring(cfg.SECONDS_PER_TRIGGER), tostring(sch)))
            for _, q in ipairs(problems) do print("   - " .. q) end
        end
    end
end
print(string.format("\nfuzz: %d runs, %d failed, %d clip loads simulated", RUNS, failures, total_plays))
os.exit(failures == 0 and 0 or 1)
