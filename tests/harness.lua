-- Mock mpv environment for testing mediaplayer.lua without a real mpv.
-- Faithful to the behaviours that matter for the state machine:
--   * virtual clock + timers
--   * loadfile "replace" on a playing file fires end-file reason="stop" (seen in real mpv log)
--   * natural end of a file fires end-file reason="eof" (keep-open=no)
--   * virtual filesystem for content folders
--   * controllable wall clock for the scheduler (os.date)
local H = {}

function H.new(opts)
    opts = opts or {}
    local E = {
        now = 0,            -- virtual seconds
        seq = 0,
        timers = {},        -- {t, seq, fn, dead}
        events = {},        -- event name -> list of handlers
        keys = {},          -- key -> fn
        props = { brightness = 0, mute = false, volume = 100 },
        trace = {},         -- ordered list of strings
        plays = {},         -- {t=, path=, kind=}
        bright = {},        -- {t=, v=} every brightness write
        mutes = {},         -- {t=, v=}
        current = nil,      -- {path, eof_timer}
        fs = opts.fs or {},       -- folder path -> {file=dur,...}
        durations = opts.durations or {},
        wall = opts.wall or { hour = 12, min = 0, month = 6, day = 15 },
        bad_files = opts.bad_files or {},
        opt = opts.opt or { ["mediaplayer-root"] = "/root" },
        schedule_text = opts.schedule_text,
        config_text = opts.config_text,
    }

    local function tr(s) E.trace[#E.trace + 1] = string.format("[%7.2f] %s", E.now, s) end
    E.tr = tr

    local function add_timer(delay, fn, period)
        E.seq = E.seq + 1
        local tm = { t = E.now + delay, seq = E.seq, fn = fn, dead = false, period = period, delay = delay }
        E.timers[#E.timers + 1] = tm
        return setmetatable({}, { __index = {
            kill = function() tm.dead = true end,
            resume = function() end,
        } })
    end

    local function fire(name, ev)
        for _, h in ipairs(E.events[name] or {}) do h(ev or {}) end
    end
    E.fire = fire

    -- ---- the mp table ----
    local mp = {}
    mp.msg = {
        info = function(s) tr("LOG " .. s) end,
        warn = function(s) tr("WARN " .. s) end,
        error = function(s) tr("ERR " .. s) end,
        verbose = function() end, debug = function() end,
    }
    mp.get_opt = function(k) return E.opt[k] end
    mp.get_script_directory = function() return nil end
    mp.get_script_info = function() return nil end
    mp.add_timeout = function(sec, fn) return add_timer(sec, fn) end
    mp.add_periodic_timer = function(sec, fn) return add_timer(sec, fn, sec) end
    mp.register_event = function(name, fn)
        E.events[name] = E.events[name] or {}
        table.insert(E.events[name], fn)
    end
    mp.observe_property = function(name, kind, fn)
        E.observers = E.observers or {}
        E.observers[name] = E.observers[name] or {}
        table.insert(E.observers[name], fn)
    end
    mp.add_forced_key_binding = function(key, name, fn)
        if type(name) == "function" then fn = name end
        E.keys[key] = fn
    end
    mp.add_key_binding = function(key, name, fn)
        if type(name) == "function" then fn = name end
        E.keys[key] = fn
    end
    mp.set_property = function(k, v) E.props[k] = v end
    mp.set_property_native = mp.set_property
    mp.set_property_number = function(k, v)
        E.props[k] = v
        if k == "brightness" then E.bright[#E.bright + 1] = { t = E.now, v = v } end
    end
    mp.set_property_bool = function(k, v)
        E.props[k] = v
        if k == "mute" then E.mutes[#E.mutes + 1] = { t = E.now, v = v } end
    end
    mp.get_property = function(k) return E.props[k] and tostring(E.props[k]) or nil end
    mp.get_property_number = function(k)
        if k == "time-remaining" then return E.time_remaining and E.time_remaining() or nil end
        return tonumber(E.props[k])
    end
    mp.get_property_bool = function(k) return E.props[k] end
    mp.get_property_native = function(k) return E.props[k] end
    mp.command = function(s) tr("CMD " .. tostring(s)) end

    local function dur_of(path)
        local name = path:match("([^/]+)$")
        return E.durations[name] or 5
    end

    mp.commandv = function(cmd, a, b)
        if cmd == "loadfile" then
            if E.current then
                -- real mpv: replacing a playing file reports reason=stop for the old one
                E.current.eof_timer.kill()
                local old = E.current
                E.current = nil
                tr("end-file(stop) " .. old.path)
                fire("end-file", { reason = "stop" })
            end
            local path = a
            local kind = "?"
            E.plays[#E.plays + 1] = { t = E.now, path = path }
            tr("PLAY " .. path)
            fire("start-file", {})
            if E.bad_files[path:match("([^/]+)$")] then
                add_timer(0.01, function()
                    tr("end-file(error) " .. path)
                    E.current = nil
                    fire("end-file", { reason = "error" })
                end)
                E.current = { path = path, eof_timer = { kill = function() end } }
                return true
            end
            local d = dur_of(path)
            local started = E.now
            local cur = { path = path, started = started, dur = d }
            cur.eof_timer = add_timer(d, function()
                if E.current == cur then
                    E.current = nil
                    tr("end-file(eof) " .. path)
                    fire("end-file", { reason = "eof" })
                end
            end)
            E.current = cur
            -- real mpv emits time-remaining updates continuously while playing
            local tk
            tk = add_timer(0.1, function()
                if E.current ~= cur then tk.kill(); return end
                for _, h in ipairs((E.observers or {})["time-remaining"] or {}) do
                    h("time-remaining", E.time_remaining())
                end
            end, 0.1)
            return true
        elseif cmd == "quit" then
            tr("QUIT")
        end
        return true
    end

    E.time_remaining = function()
        if not E.current then return nil end
        return E.current.dur - (E.now - E.current.started)
    end

    mp.set_property_native = mp.set_property

    -- ---- music subprocess (second mpv) ----
    E.songs = {}      -- {t=, file=, args=}
    E.song_fail = opts.song_fail or {}
    mp.command_native_async = function(cmd, cb)
        assert(cmd.name == "subprocess", "unexpected async command")
        local file = cmd.args[#cmd.args]
        local name = file:match("([^/]+)$")
        local rec = { t = E.now, file = file, args = cmd.args, alive = true }
        E.songs[#E.songs + 1] = rec
        tr("SONG " .. file)
        local d = E.durations[name] or 5
        local tm = add_timer(d, function()
            rec.alive = false
            cb(true, { status = E.song_fail[name] and 2 or 0 }, nil)
        end)
        rec.timer = tm
        return rec
    end
    mp.abort_async_command = function(rec)
        if rec and rec.alive then rec.alive = false; rec.timer.kill(); tr("SONG-KILLED " .. rec.file) end
    end
    E.osd = { data = nil, updates = 0 }
    mp.create_osd_overlay = function(kind)
        local o = { res_x = 0, res_y = 0, data = "" }
        function o:update() E.osd.data = self.data; E.osd.updates = E.osd.updates + 1 end
        function o:remove() E.osd.data = nil end
        return o
    end
    E.vf_history = {}
    mp.set_property_native = function(k, v)
        E.props[k] = v
        if k == "vf" then E.vf_history[#E.vf_history + 1] = { t = E.now, v = v } end
    end

    -- ---- mp.utils ----
    local function norm(p) p = p:gsub("//+", "/"); p = p:gsub("/$", ""); return p end
    local utils = {}
    utils.file_info = function(p)
        p = norm(p)
        if E.fs[p] ~= nil then return { is_dir = true } end
        local dir, name = p:match("^(.*)/([^/]+)$")
        if dir and E.fs[dir] and E.fs[dir][name] then return { is_file = true } end
        if p == "/root/schedule.cfg" and E.schedule_text then return { is_file = true } end
        if p == "/root/config.cfg" and E.config_text then return { is_file = true } end
        if E.files and E.files[p] then return { is_file = true } end
        return nil
    end
    utils.readdir = function(p, filter)
        p = norm(p)
        local out = {}
        if filter == "dirs" then
            for k in pairs(E.fs) do
                local parent, name = k:match("^(.*)/([^/]+)$")
                if parent == p then out[#out + 1] = name end
            end
        else
            for name in pairs(E.fs[p] or {}) do out[#out + 1] = name end
        end
        table.sort(out)
        return out
    end

    -- ---- wall clock for scheduler ----
    E.os_date = function(fmt)
        if fmt == "*t" then
            return { hour = E.wall.hour, min = E.wall.min, month = E.wall.month, day = E.wall.day, year = 2026 }
        end
        return os.date(fmt)
    end

    -- schedule file via io.open override
    E.io_open = function(path, mode)
        if path == "/root/config.cfg" and E.config_text then
            local lines = {}
            for l in (E.config_text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
            return {
                lines = function() local n = 0; return function() n = n + 1; return lines[n] end end,
                close = function() end,
            }
        end
        if path == "/root/schedule.cfg" and E.schedule_text then
            local lines, i = {}, 0
            for l in (E.schedule_text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
            return {
                lines = function() local n = 0; return function() n = n + 1; return lines[n] end end,
                close = function() end,
                read = function() return E.schedule_text end,
            }
        end
        if E.files and E.files[path] and (mode == nil or mode == "r") then
            local txt = E.files[path]
            return { read = function() return txt end, close = function() end }
        end
        return nil
    end

    -- ---- driving the clock ----
    function E.advance(sec)
        local target = E.now + sec
        while true do
            local best, bi
            for i, tm in ipairs(E.timers) do
                if not tm.dead and tm.t <= target and (not best or tm.t < best.t or (tm.t == best.t and tm.seq < best.seq)) then
                    best, bi = tm, i
                end
            end
            if not best then break end
            E.now = best.t
            if best.period then
                best.t = best.t + best.period
                E.seq = E.seq + 1; best.seq = E.seq
            else
                best.dead = true
            end
            best.fn()
        end
        E.now = target
    end

    function E.press(key)
        tr("KEY " .. key)
        local fn = E.keys[key]
        if fn then fn() else tr("(no binding for " .. key .. ")") end
    end

    E.mp, E.utils = mp, utils
    return E
end

-- Load the script under test into a fresh sandbox bound to env E
function H.load(E, script_path)
    local real_date, real_open = os.date, io.open
    os.date = E.os_date
    local real_time = os.time
    os.time = function() return 1700000000 end
    E.real_time = real_time
    io.open = function(p, m) return E.io_open(p, m) or real_open(p, m) end
    local saved_mp = _G.mp
    _G.mp = E.mp
    package.loaded["mp.utils"] = E.utils
    package.loaded["mp.options"] = nil
    local f, err = loadfile(script_path)
    assert(f, err)
    local ok, e = pcall(f)
    E.restore = function() os.time = E.real_time; os.date = real_date; io.open = real_open; _G.mp = saved_mp end
    if not ok then E.restore(); error(e) end
    return E
end

-- Standard virtual content tree used by most tests
function H.standard_fs()
    return {
        ["/root/content"] = {},
        ["/root/content/L0"] = { ["a.mp4"] = 1, ["b.mp4"] = 1 },
        ["/root/content/L1 - Christmas"] = { ["x.mp4"] = 1 },
        ["/root/content/L2 - New Year"] = { ["ny.mp4"] = 1 },
        ["/root/content/M1"] = { ["m1a.mp4"] = 1, ["m1b.mp4"] = 1 },
        ["/root/content/M2 - Promos"] = { ["p1.mp4"] = 1 },
        ["/root/content/Ma"] = { ["ma.mp4"] = 1 },
        ["/root/content/L1M1 - Xmas version"] = { ["xm1.mp4"] = 1 },
        ["/root/content/Intro"] = { ["intro_generic.mp4"] = 1 },
        ["/root/content/IntroM1"] = { ["intro_m1.mp4"] = 1 },
        ["/root/content/IntroL1M1"] = {},                       -- exists but empty -> must be skipped
        ["/root/content/Outro"] = { ["outro_generic.mp4"] = 1 },
        ["/root/content/Transition"] = { ["trans.mp4"] = 1 },
        ["/root/content/TransitionL2"] = { ["trans_l2.mp4"] = 1 },
    }
end

H.standard_durations = {
    ["a.mp4"] = 10, ["b.mp4"] = 10, ["x.mp4"] = 10, ["ny.mp4"] = 10,
    ["m1a.mp4"] = 4, ["m1b.mp4"] = 4, ["p1.mp4"] = 4, ["ma.mp4"] = 4, ["xm1.mp4"] = 4,
    ["intro_generic.mp4"] = 2, ["intro_m1.mp4"] = 2,
    ["outro_generic.mp4"] = 2, ["trans.mp4"] = 2, ["trans_l2.mp4"] = 2,
}

return H
