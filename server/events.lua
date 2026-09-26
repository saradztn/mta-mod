--[[
    SentinelAC :: server/events.lua
    Event security: source/argument/rate validation for SentinelAC's own client events,
    session tokens (replay / duplicate / stale protection), protected element data, command flooding.
    Tokens complement server-side validation; they never replace it.
]]

Session    = {}
EventGuard = {}

local renewTimer = nil
local CHARSET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
local protectedData = {}

local function rebuildProtectedData()
    protectedData = {}
    for _, key in ipairs(Config.Detection.EventAbuse.ProtectedElementData or {}) do
        protectedData[key] = true
    end
end

-- ------------------------------------------------------------------ session tokens
function Session.generateToken()
    local t = {}
    for i = 1, (Config.Session.TokenLength or 24) do
        local r = math.random(1, #CHARSET)
        t[i] = string.sub(CHARSET, r, r)
    end
    return table.concat(t)
end

function Session.clientConfig()
    return {
        telemetryInterval = Config.Client.TelemetryInterval,
        heartbeatInterval = Config.Client.HeartbeatInterval,
        noclipRay = Config.Client.NoClipRayEnabled,
        sendFPS = Config.Client.SendFPS,
    }
end

function Session.issue(player, isRenewal)
    local st = PlayerState.getOrCreate(player)
    if not st then return nil end
    st.token.previous = st.token.value
    st.token.value = Session.generateToken()
    st.token.issuedAt = getTickCount()
    if isRenewal then
        triggerClientEvent(player, "SentinelAC:client:token", resourceRoot, st.token.value)
    else
        local payload = Session.clientConfig()
        payload.token = st.token.value
        triggerClientEvent(player, "SentinelAC:client:init", resourceRoot, payload)
    end
    Logger.debug("Session token issued", { player = getPlayerName(player), renewal = isRenewal == true })
    return st.token.value
end

function Session.get(player)
    local st = PlayerState.get(player)
    return st and st.token.value or nil
end

-- Validates token + strictly increasing sequence + client tick monotonicity/drift.
function Session.validate(player, token, seq, clientTick)
    if not Config.Session.Enabled then return true end
    local st = PlayerState.get(player)
    if not st or not st.token.value then return false, "no-session" end
    local now = getTickCount()

    if token ~= st.token.value then
        local graceOld = st.token.previous and token == st.token.previous and (now - st.token.issuedAt) < 10000
        if not graceOld then return false, "invalid-token" end
    end
    if type(seq) ~= "number" then return false, "invalid-sequence" end
    if seq <= st.token.seq then return false, "replay-or-duplicate" end
    if seq - st.token.seq > (Config.Session.MaxSequenceGap or 200) then return false, "sequence-gap" end

    if type(clientTick) == "number" then
        if st.token.lastClientTick then
            if clientTick < st.token.lastClientTick then return false, "stale-timestamp" end
            local serverDelta = now - st.token.lastServerTick
            local clientDelta = clientTick - st.token.lastClientTick
            if math.abs(serverDelta - clientDelta) > (Config.Session.MaxClientTickDrift or 15000) then
                return false, "timestamp-drift"
            end
        end
        st.token.lastClientTick = clientTick
        st.token.lastServerTick = now
    end
    st.token.seq = seq
    return true
end

function Session.renewAll()
    for _, player in ipairs(getElementsByType("player")) do
        local st = PlayerState.get(player)
        if st and st.token.value then Session.issue(player, true) end
    end
end

function Session.start()
    Session.stop()
    rebuildProtectedData()
    if Config.Session.Enabled then
        renewTimer = setTimer(Session.renewAll, Config.Session.RenewInterval or 300000, 0)
    end
end

function Session.stop()
    if renewTimer and isTimer(renewTimer) then killTimer(renewTimer) end
    renewTimer = nil
end

-- ------------------------------------------------------------------ event guard
local function flag(player, eventName, reason, details)
    local cfg = Config.Detection.EventAbuse
    local st = PlayerState.get(player)
    local info = Logger.playerIdentity(player)
    info.event = eventName
    info.reason = reason
    info.resource = details and details.resource or getResourceName(getThisResource())
    if details then
        for k, v in pairs(details) do if info[k] == nil then info[k] = v end end
    end
    Logger.warning("Event abuse", info)
    if not cfg.Enabled or not PlayerState.canDetect(player, "EventAbuse") then return end
    if not st then return end
    local now = getTickCount()
    if now - st.eventLastDetect <= (cfg.Cooldown or 3000) then return end
    st.eventLastDetect = now
    Suspicion.add(player, "EventAbuse", reason .. " on " .. tostring(eventName), { event = eventName })
end

local function describeArgs(args)
    local out = {}
    for i, v in ipairs(args) do
        if type(v) == "table" then out[i] = "table" else out[i] = tostring(v) end
        if #out >= 8 then break end
    end
    return table.concat(out, ",")
end

--[[
    EventGuard.check(player, eventName, options) -> ok(bool), reason(string|nil)
    options:
        source        = element that must equal `player`
        args          = { ... }            actual arguments
        types         = { "number", ... } expected Lua types ("any" allowed)
        maxPerSecond  = number             per-player rate limit for this event
        requireAlive  = bool
        range         = { x, y, z, maxDistance } player must be within maxDistance of the point
        token, seq, clientTick             validated through Session.validate when token ~= nil
        resource      = string             caller resource name for logging
]]
function EventGuard.check(player, eventName, options)
    options = options or {}
    local cfg = Config.Detection.EventAbuse
    if not Util.isPlayer(player) then return false, "invalid-player" end
    local st = PlayerState.getOrCreate(player)
    if not st then return false, "no-state" end
    local now = getTickCount()

    if cfg.InvalidSource and options.source ~= nil and options.source ~= player then
        flag(player, eventName, "invalid-source", { resource = options.resource, sourceType = isElement(options.source) and getElementType(options.source) or type(options.source) })
        return false, "invalid-source"
    end

    if cfg.InvalidArguments and type(options.types) == "table" then
        local args = options.args or {}
        for i, expected in ipairs(options.types) do
            local actual = type(args[i])
            if expected ~= "any" and actual ~= expected then
                flag(player, eventName, "invalid-arguments", { resource = options.resource, index = i, expected = expected, actual = actual, args = describeArgs(args) })
                return false, "invalid-arguments"
            end
        end
    end

    if options.requireAlive and isPedDead(player) then
        flag(player, eventName, "invalid-state", { resource = options.resource, state = "dead" })
        return false, "invalid-state"
    end

    if type(options.range) == "table" and #options.range >= 4 then
        local px, py, pz = getElementPosition(player)
        local d = getDistanceBetweenPoints3D(px, py, pz, options.range[1], options.range[2], options.range[3])
        local lag = PlayerState.getLagMultiplier(player, getPlayerPing(player), nil, nil)
        if d > options.range[4] * lag then
            flag(player, eventName, "out-of-range", { resource = options.resource, distance = Util.round(d, 1), max = options.range[4] })
            return false, "out-of-range"
        end
    end

    if cfg.RateLimit then
        local limit = options.maxPerSecond or cfg.MaxEventsPerSecond or 20
        local rec = st.events[eventName]
        if not rec or now - rec.windowStart >= 1000 then
            rec = { windowStart = now, count = 0 }
            st.events[eventName] = rec
        end
        rec.count = rec.count + 1
        if rec.count > limit then
            if rec.count == limit + 1 then
                flag(player, eventName, "rate-limit", { resource = options.resource, perSecond = rec.count })
            end
            return false, "rate-limit"
        end
    end

    if options.token ~= nil then
        local ok, reason = Session.validate(player, options.token, options.seq, options.clientTick)
        if not ok then
            flag(player, eventName, "session:" .. tostring(reason), { resource = options.resource })
            return false, reason
        end
    end
    return true
end

-- ------------------------------------------------------------------ SentinelAC remote events
addEvent("SentinelAC:server:hello", true)
addEvent("SentinelAC:server:ready", true)
addEvent("SentinelAC:server:telemetry", true)
addEvent("SentinelAC:server:heartbeat", true)
addEvent("SentinelAC:server:integrity", true)

addEventHandler("SentinelAC:server:hello", root, function()
    local player = client
    if not Util.isPlayer(player) then return end
    local ok = EventGuard.check(player, "SentinelAC:server:hello", { source = source, maxPerSecond = 2 })
    if not ok then return end
    Session.issue(player, false)
end)

addEventHandler("SentinelAC:server:ready", root, function(payload)
    local player = client
    if not Util.isPlayer(player) then return end
    if type(payload) ~= "table" then
        flag(player, "SentinelAC:server:ready", "invalid-arguments", { actual = type(payload) })
        return
    end
    local ok = EventGuard.check(player, "SentinelAC:server:ready", {
        source = source, maxPerSecond = 2, token = payload.token, seq = payload.seq, clientTick = payload.tick,
    })
    if not ok then return end
    local st = PlayerState.get(player)
    if st then
        st.telemetry.ready = true
        st.telemetry.lastTick = getTickCount()
        st.telemetry.lastHeartbeat = st.telemetry.lastTick
    end
    Logger.debug("Client ready", { player = getPlayerName(player) })
end)

addEventHandler("SentinelAC:server:telemetry", root, function(payload)
    local player = client
    if not Util.isPlayer(player) then return end
    if type(payload) ~= "table" then
        flag(player, "SentinelAC:server:telemetry", "invalid-arguments", { actual = type(payload) })
        return
    end
    local perSecond = math.max(2, math.ceil(2000 / (Config.Client.TelemetryInterval or 1000)))
    local ok = EventGuard.check(player, "SentinelAC:server:telemetry", {
        source = source, maxPerSecond = perSecond, token = payload.token, seq = payload.seq, clientTick = payload.tick,
    })
    if not ok then return end
    Telemetry.process(player, payload)
end)

addEventHandler("SentinelAC:server:heartbeat", root, function(payload)
    local player = client
    if not Util.isPlayer(player) then return end
    if type(payload) ~= "table" then
        flag(player, "SentinelAC:server:heartbeat", "invalid-arguments", { actual = type(payload) })
        return
    end
    local ok = EventGuard.check(player, "SentinelAC:server:heartbeat", {
        source = source, maxPerSecond = 2, token = payload.token, seq = payload.seq, clientTick = payload.tick,
    })
    if not ok then return end
    local st = PlayerState.get(player)
    if st then
        st.telemetry.lastHeartbeat = getTickCount()
        st.telemetry.missingReported = false
    end
end)

addEventHandler("SentinelAC:server:integrity", root, function(payload)
    local player = client
    if not Util.isPlayer(player) then return end
    if type(payload) ~= "table" then
        flag(player, "SentinelAC:server:integrity", "invalid-arguments", { actual = type(payload) })
        return
    end
    local ok = EventGuard.check(player, "SentinelAC:server:integrity", {
        source = source, maxPerSecond = 1, token = payload.token, seq = payload.seq, clientTick = payload.tick,
    })
    if not ok then return end
    Telemetry.processIntegrity(player, payload)
end)

-- ------------------------------------------------------------------ protected element data
addEventHandler("onElementDataChange", root, function(dataName, oldValue, newValue)
    if not client then return end -- changed by a server script: trusted (Exemptions.ServerResources)
    local player = client

    -- flood / oversized element data from the client
    local fcfg = Config.Detection.Flood
    if fcfg and fcfg.Enabled then
        local fst = PlayerState.getOrCreate(player)
        if fst then
            local now = getTickCount()
            local fl = fst.flood
            if now - fl.dataWindow >= 1000 then
                fl.dataWindow = now
                fl.dataCount = 0
            end
            fl.dataCount = fl.dataCount + 1
            local reason
            if fl.dataCount > (fcfg.ElementDataPerSecond or 40) then
                reason = "element data flood (" .. fl.dataCount .. "/s)"
            else
                local size = Util.estimateSize(newValue)
                if size > (fcfg.MaxElementDataBytes or 8192) then reason = "oversized element data (" .. size .. " bytes)" end
            end
            if reason then
                setElementData(source, dataName, oldValue) -- revert, never let the flood stick
                if PlayerState.canDetect(player, "Flood") and now - fl.lastDetect > (fcfg.Cooldown or 3000) then
                    fl.lastDetect = now
                    Suspicion.add(player, "Flood", reason, { key = tostring(dataName), element = getElementType(source) })
                end
                return
            end
        end
    end

    local cfg = Config.Detection.EventAbuse
    if not cfg.Enabled then return end
    if not protectedData[dataName] then return end
    if cfg.RevertProtectedData then
        setElementData(source, dataName, oldValue)
    end
    if not PlayerState.canDetect(player, "ElementData") then return end
    local st = PlayerState.get(player)
    local now = getTickCount()
    if st and now - st.eventLastDetect <= (cfg.Cooldown or 3000) then return end
    if st then st.eventLastDetect = now end
    Suspicion.add(player, "ElementData", "Client modified protected element data", {
        key = dataName, element = getElementType(source), reverted = cfg.RevertProtectedData == true,
        newValue = type(newValue) == "table" and "table" or tostring(newValue),
    })
end)

-- ------------------------------------------------------------------ command flooding
addEventHandler("onPlayerCommand", root, function(command)
    local cfg = Config.Detection.EventAbuse
    if not cfg.Enabled or not cfg.RateLimit then return end
    local st = PlayerState.get(source)
    if not st then return end
    local now = getTickCount()
    local kept = {}
    for _, t in ipairs(st.commandTimes) do
        if now - t < 1000 then kept[#kept + 1] = t end
    end
    kept[#kept + 1] = now
    st.commandTimes = kept
    if #kept > (cfg.CommandFloodPerSecond or 8) then
        st.commandTimes = {}
        flag(source, "command:" .. tostring(command), "command-flood", { perSecond = #kept })
    end
end)
