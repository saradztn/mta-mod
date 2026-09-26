--[[
    SentinelAC :: server/event_firewall.lua
    Global event firewall + native anti-cheat integration.

    For every remotely triggerable server event found by the scanner, a passive handler is attached
    on root (custom event names are global in MTA, no resource is modified). Each client trigger is:
        1. rate limited per player/event
        2. checked against the static set of events that legitimate CLIENT code triggers
        3. compared to a learned consensus baseline of argument signatures
    Mode LEARN: build the baseline, log only. Mode ENFORCE: unknown event => Injection detection.

    Honest limits: our handler runs after the owning resource's handler (detect, not prevent the first
    call) - MTA executes every handler of an event that reached the server; there is no veto mechanism.
    True pre-execution blocking of injected events happens client-side: the per-resource canary
    (instrument.lua / templates/canary.lua) stops injected calls before they are sent when
    Config.Instrument.BlockInjectCalls is on. This layer stays the server-side backstop for injected
    code that bypasses the canary. Injected code that never talks to the server is invisible here.
]]

Firewall = {
    hooked = {},                  -- [event] = owner resource
    baseline = { events = {} },   -- [event] = { players, calls, signatures = { [sig] = { players } } }
    mode = "LEARN",
    dirty = false,
    unknownLogged = {},
}

local BASELINE_FILE = "logs/firewall_baseline.json"
local saveTimer = nil
local selfName = getResourceName(getThisResource())

-- ------------------------------------------------------------------ helpers
local function ignoredEvent(name)
    if string.sub(name, 1, 11) == "SentinelAC:" then return true end
    for _, n in ipairs(Config.Detection.EventFirewall.IgnoredEvents or {}) do
        if n == name then return true end
    end
    return false
end

local function ignoredResource(name)
    if name == selfName then return true end
    for _, n in ipairs(Config.Scanner.IgnoredResources or {}) do
        if n == name then return true end
    end
    return false
end

local function typeOf(v)
    local t = type(v)
    if t == "userdata" then
        if isElement(v) then return "el:" .. getElementType(v) end
        return "userdata"
    end
    return t
end

local function signature(src, player, ...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, math.min(n, 8) do
        parts[i] = typeOf((select(i, ...)))
    end
    local srcKind
    if src == player then srcKind = "self"
    elseif src == root then srcKind = "root"
    elseif isElement(src) then
        srcKind = "el:" .. getElementType(src)
        if getElementType(src) == "player" then srcKind = "foreign-player" end
    else srcKind = type(src) end
    return srcKind .. "|" .. table.concat(parts, ","), srcKind
end

-- ------------------------------------------------------------------ baseline persistence
function Firewall.load()
    Firewall.mode = string.upper(tostring(Config.Detection.EventFirewall.Mode or "LEARN"))
    if Firewall.mode ~= "ENFORCE" then Firewall.mode = "LEARN" end
    if not fileExists(BASELINE_FILE) then return end
    local f = fileOpen(BASELINE_FILE, true)
    if not f then return end
    local size = fileGetSize(f) or 0
    local content = size > 0 and fileRead(f, size) or ""
    fileClose(f)
    local data = fromJSON(content)
    if type(data) == "table" and type(data.events) == "table" then
        for ev, entry in pairs(data.events) do
            entry.serials = {}
            entry.players = tonumber(entry.players) or 0
            entry.calls = tonumber(entry.calls) or 0
            entry.signatures = type(entry.signatures) == "table" and entry.signatures or {}
            for _, sigEntry in pairs(entry.signatures) do
                sigEntry.serials = {}
                sigEntry.players = tonumber(sigEntry.players) or 0
            end
        end
        Firewall.baseline = data
        if type(data.mode) == "string" and Config.Detection.EventFirewall.PersistMode then
            Firewall.mode = data.mode
        end
        Logger.info("Firewall baseline loaded", { events = Util.tableCount(data.events), mode = Firewall.mode })
    end
end

function Firewall.save(force)
    if not Firewall.dirty and not force then return end
    local out = { mode = Firewall.mode, events = {} }
    for ev, entry in pairs(Firewall.baseline.events) do
        local sigs = {}
        for sig, s in pairs(entry.signatures) do sigs[sig] = { players = s.players } end
        out.events[ev] = { players = entry.players, calls = entry.calls, signatures = sigs }
    end
    local json = toJSON(out)
    if not json then return end
    if fileExists(BASELINE_FILE) then fileDelete(BASELINE_FILE) end
    local f = fileCreate(BASELINE_FILE)
    if not f then return end
    fileWrite(f, json)
    fileFlush(f)
    fileClose(f)
    Firewall.dirty = false
end

function Firewall.setMode(mode)
    mode = string.upper(tostring(mode or ""))
    if mode ~= "LEARN" and mode ~= "ENFORCE" then return false end
    Firewall.mode = mode
    Firewall.dirty = true
    Firewall.save(true)
    Logger.warning("Firewall mode changed", { mode = mode })
    return true
end

-- ------------------------------------------------------------------ hooking
function Firewall.hookEvent(eventName, owner)
    if Firewall.hooked[eventName] then return true end
    if ignoredEvent(eventName) then return false end
    local ok = addEventHandler(eventName, root, Firewall.onEvent)
    if ok then
        Firewall.hooked[eventName] = owner
    end
    return ok == true
end

function Firewall.hookResource(name)
    if not Config.Detection.EventFirewall.Enabled then return 0 end
    if ignoredResource(name) then return 0 end
    local info = Scanner.resources[name]
    if not info then return 0 end
    local res = getResourceFromName(name)
    if not res or getResourceState(res) ~= "running" then return 0 end
    local n = 0
    for ev in pairs(info.remoteEvents) do
        if Firewall.hookEvent(ev, name) then n = n + 1 end
    end
    if n > 0 then Logger.debug("Firewall hooked resource events", { resource = name, events = n }) end
    return n
end

function Firewall.unhookResource(name)
    for ev, owner in pairs(Firewall.hooked) do
        if owner == name then
            removeEventHandler(ev, root, Firewall.onEvent)
            Firewall.hooked[ev] = nil
        end
    end
end

function Firewall.hookAll()
    local total = 0
    for name in pairs(Scanner.resources) do
        total = total + Firewall.hookResource(name)
    end
    Logger.info("Firewall active", { mode = Firewall.mode, hookedEvents = Util.tableCount(Firewall.hooked), learnedEvents = Util.tableCount(Firewall.baseline.events) })
    return total
end

function Firewall.unhookAll()
    for ev in pairs(Firewall.hooked) do
        removeEventHandler(ev, root, Firewall.onEvent)
    end
    Firewall.hooked = {}
end

-- ------------------------------------------------------------------ the passive handler
local function raise(player, st, detection, reason, details, now)
    local cfg = Config.Detection.EventFirewall
    if not PlayerState.canDetect(player, detection) then return end
    if now - st.firewall.lastDetect <= (cfg.Cooldown or 5000) then return end
    st.firewall.lastDetect = now
    Suspicion.add(player, detection, reason, details)
end

function Firewall.onEvent(...)
    local player = client
    if not player or not Util.isPlayer(player) then return end -- triggered by server code: trusted
    local cfg = Config.Detection.EventFirewall
    if not cfg.Enabled then return end

    local name = eventName
    if type(name) ~= "string" then return end
    local owner = Firewall.hooked[name] or "unknown"
    local st = PlayerState.getOrCreate(player)
    if not st then return end
    local now = getTickCount()

    -- 0) global flood across all resources: triggers per second and payload size
    local fcfg = Config.Detection.Flood
    if fcfg and fcfg.Enabled then
        local fl = st.flood
        if now - fl.triggerWindow >= 1000 then
            fl.triggerWindow = now
            fl.triggerCount = 0
        end
        fl.triggerCount = fl.triggerCount + 1
        local reason
        if fl.triggerCount > (fcfg.TriggersPerSecond or 60) then
            reason = "server event flood (" .. fl.triggerCount .. "/s)"
        elseif select("#", ...) > 0 then
            local size = Util.estimateSize({ ... })
            if size > (fcfg.MaxTriggerBytes or 16384) then reason = "oversized event payload (" .. size .. " bytes)" end
        end
        if reason then
            if PlayerState.canDetect(player, "Flood") and now - fl.lastDetect > (fcfg.Cooldown or 3000) then
                fl.lastDetect = now
                Suspicion.add(player, "Flood", reason, { event = name, resource = owner })
            end
            return
        end
    end

    -- 1) rate limit per player/event
    if cfg.RateLimit then
        local rec = st.firewall.rates[name]
        if not rec or now - rec.windowStart >= 1000 then
            rec = { windowStart = now, count = 0, flagged = false }
            st.firewall.rates[name] = rec
        end
        rec.count = rec.count + 1
        if rec.count > (cfg.MaxPerSecond or 30) then
            if not rec.flagged then
                rec.flagged = true
                raise(player, st, "EventFirewall", "Event flood", { event = name, resource = owner, perSecond = rec.count }, now)
            end
            return
        end
    end

    -- 2) learn / compare signature
    local sig, srcKind = signature(source, player, ...)
    local entry = Firewall.baseline.events[name]
    if not entry then
        entry = { players = 0, calls = 0, signatures = {}, serials = {} }
        Firewall.baseline.events[name] = entry
    end
    local playersBefore = entry.players
    local serial = getPlayerSerial(player)
    if not entry.serials[serial] then
        entry.serials[serial] = true
        entry.players = entry.players + 1
    end
    entry.calls = entry.calls + 1
    local sigEntry = entry.signatures[sig]
    local newSig = sigEntry == nil
    if newSig then
        sigEntry = { players = 0, serials = {} }
        entry.signatures[sig] = sigEntry
    end
    if not sigEntry.serials[serial] then
        sigEntry.serials[serial] = true
        sigEntry.players = sigEntry.players + 1
    end
    Firewall.dirty = true

    local staticKnown = Scanner.isClientTriggered(name)
    local learnedKnown = playersBefore >= (cfg.LearnMinPlayers or 3)

    if Firewall.mode ~= "ENFORCE" then
        if not staticKnown and not Firewall.unknownLogged[name] then
            Firewall.unknownLogged[name] = true
            Logger.info("Firewall learning: event triggered by a client but not found in any client script", {
                event = name, resource = owner, signature = sig, player = getPlayerName(player),
            })
        end
        return
    end

    -- ENFORCE
    if not staticKnown and not learnedKnown then
        local detection = "Injection"
        local reason = "Client triggered a server event that no client script triggers and no baseline knows"
        if Scanner.dynamicTriggerCount > 0 and cfg.DowngradeWhenDynamic then
            detection = "EventFirewall"
            reason = reason .. " (dynamic event names exist in scan: downgraded)"
        end
        raise(player, st, detection, reason, { event = name, resource = owner, signature = sig }, now)
        return
    end

    if cfg.FlagForeignPlayerSource and srcKind == "foreign-player" then
        raise(player, st, "EventFirewall", "Event triggered with another player as source", { event = name, resource = owner, signature = sig }, now)
        return
    end

    if newSig and learnedKnown and Util.tableCount(entry.signatures) > 1 then
        raise(player, st, "EventFirewall", "Unusual argument signature for a well-known event", {
            event = name, resource = owner, signature = sig, knownSignatures = Util.tableCount(entry.signatures) - 1,
        }, now)
    end
end

-- ------------------------------------------------------------------ native MTA anti-cheat integration
addEventHandler("onPlayerACInfo", root, function(detectedACList, d3d9Size, d3d9MD5, d3d9SHA256)
    local cfg = Config.Detection.NativeAC
    if not cfg or not cfg.Enabled then return end
    local player = source
    if not Util.isPlayer(player) then return end
    local hard, soft = {}, {}
    if type(detectedACList) == "table" then
        for _, code in ipairs(detectedACList) do
            local c = tonumber(code)
            if c and not (cfg.IgnoreCodes or {})[c] then
                if (cfg.SoftCodes or {})[c] and not (cfg.EnforceCodes or {})[c] then
                    soft[#soft + 1] = tostring(c)
                else
                    hard[#hard + 1] = tostring(c)
                end
            end
        end
    end
    local info = Logger.playerIdentity(player)
    info.acCodes = table.concat(hard, ",")
    info.sdCodes = table.concat(soft, ",")
    info.d3d9Size = d3d9Size
    info.d3d9MD5 = d3d9MD5

    if #hard == 0 and #soft == 0 then
        Logger.info("Native AC info without actionable codes", info)
        return
    end

    -- special detections: environment indicators, logged with low weight only
    if #soft > 0 then
        Logger.warning("MTA special detection (SD) codes reported - environment indicator, not a cheat detection", info)
        local st = PlayerState.get(player)
        local now = getTickCount()
        if st and Config.isDetectionEnabled("NativeSD") and PlayerState.canDetect(player, "NativeSD")
            and now - (st.firewall.lastSD or 0) > (Config.Detection.NativeSD.Cooldown or 300000) then
            st.firewall.lastSD = now
            Suspicion.add(player, "NativeSD", "MTA special detection codes " .. info.sdCodes, { codes = info.sdCodes })
        end
    end

    if #hard == 0 then return end
    if not PlayerState.canDetect(player, "NativeAC") then
        Logger.warning("Native AC codes on exempt/admin player", info)
        return
    end
    Suspicion.add(player, "NativeAC", "MTA built-in anti-cheat reported codes " .. info.acCodes, {
        codes = info.acCodes, d3d9Size = d3d9Size,
    })
end)

addEventHandler("onPlayerModInfo", root, function(fileName, itemList)
    local cfg = Config.Detection.NativeAC
    if not cfg or not cfg.LogModInfo then return end
    local ids = {}
    if type(itemList) == "table" then
        for _, item in ipairs(itemList) do
            if type(item) == "table" then
                ids[#ids + 1] = tostring(item.id or "?") .. (item.name and (":" .. tostring(item.name)) or "")
            end
            if #ids >= 10 then break end
        end
    end
    local info = Logger.playerIdentity(source)
    info.file = fileName
    info.items = table.concat(ids, ",")
    Logger.info("Client modified game files reported (mods are often legitimate)", info)
end)

-- Available on recent MTA builds; on older builds addEventHandler simply returns false.
local invalidHooked = addEventHandler("onPlayerTriggerInvalidEvent", root, function(evName, isAdded, isRemote)
    local cfg = Config.Detection.Injection
    if not cfg or not cfg.Enabled then return end
    local player = source
    if not Util.isPlayer(player) then return end
    local st = PlayerState.getOrCreate(player)
    if not st then return end
    local why
    if not isAdded then why = "event does not exist"
    elseif not isRemote then why = "event is not remotely triggerable"
    else why = "rejected by server" end
    local now = getTickCount()

    -- a few invalid events are normal (race conditions, outdated clients): only a flood is punished
    local fcfg = Config.Detection.Flood or {}
    local maxInvalid = fcfg.InvalidEventsMax or 30
    local window = fcfg.InvalidEventsWindow or 10000
    local kept = {}
    for _, t in ipairs(st.flood.invalid) do
        if now - t <= window then kept[#kept + 1] = t end
    end
    kept[#kept + 1] = now
    st.flood.invalid = kept
    if #kept <= maxInvalid then
        Logger.debug("Invalid server event (below flood threshold)", { player = getPlayerName(player), event = tostring(evName), why = why, count = #kept })
        return
    end
    st.flood.invalid = {}
    if not PlayerState.canDetect(player, "Injection") then return end
    if now - st.firewall.lastDetect <= (cfg.Cooldown or 5000) then return end
    st.firewall.lastDetect = now
    Suspicion.add(player, "Injection", string.format("Invalid server event flood: %d in %ds (%s)", #kept, math.floor(window / 1000), why), { event = tostring(evName) })
end)

local thresholdHooked = addEventHandler("onPlayerTriggerEventThreshold", root, function()
    local player = source
    if not Util.isPlayer(player) then return end
    local st = PlayerState.getOrCreate(player)
    if not st then return end
    local now = getTickCount()
    if not PlayerState.canDetect(player, "EventFirewall") then return end
    if now - st.firewall.lastDetect <= 5000 then return end
    st.firewall.lastDetect = now
    Suspicion.add(player, "EventFirewall", "Server event trigger threshold exceeded (mtaserver.conf)")
end)

-- ------------------------------------------------------------------ lifecycle
function Firewall.start()
    Firewall.stop()
    if not Config.Detection.EventFirewall.Enabled then
        Logger.info("Event firewall disabled by config")
        return
    end
    Firewall.load()
    Firewall.hookAll()
    saveTimer = setTimer(function() Firewall.save(false) end, Config.Detection.EventFirewall.SaveInterval or 120000, 0)
    Logger.info("Native AC hooks", { invalidEvent = invalidHooked == true, eventThreshold = thresholdHooked == true })
end

function Firewall.stop()
    if saveTimer and isTimer(saveTimer) then killTimer(saveTimer) end
    saveTimer = nil
    Firewall.save(false)
    Firewall.unhookAll()
end

function Firewall.status()
    return {
        mode = Firewall.mode,
        hooked = Util.tableCount(Firewall.hooked),
        learned = Util.tableCount(Firewall.baseline.events),
        dynamicTriggers = Scanner.dynamicTriggerCount,
        dirty = Firewall.dirty,
    }
end
