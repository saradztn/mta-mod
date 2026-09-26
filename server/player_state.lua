--[[
    SentinelAC :: server/player_state.lua
    Per-player state machine, grace periods, exemptions, movement samples, lag compensation.
]]

PlayerState = {}
PlayerState.STATES = {
    ALIVE = "ALIVE", DYING = "DYING", DEAD = "DEAD", RESPAWNING = "RESPAWNING",
    SPAWN_GRACE = "SPAWN_GRACE", NORMAL = "NORMAL",
}

local states = {}

function PlayerState.create(player)
    local now = getTickCount()
    local st = {
        player = player,
        state = PlayerState.STATES.NORMAL,
        stateSince = now,
        joinTick = now,

        grace = { untilTick = 0, reason = nil },
        exempt = {},

        samples = {},
        lastSample = nil,

        -- fly
        air = { start = nil, startZ = 0, peakZ = 0, lastVz = 0, hoverSamples = 0, horizontalSamples = 0, oscillations = 0, lastDir = 0 },
        ascend = { samples = 0, total = 0 },
        flyScore = 0, flyLastDetect = 0,

        -- speed (on foot)
        speedStrikes = 0, speedLastDetect = 0,
        lastHeavyDamage = 0,

        -- teleport
        teleportStrikes = {}, teleportPending = nil, teleportLastDetect = 0,

        -- noclip
        noclipStrikes = 0, noclipWindowStart = 0, noclipLastDetect = 0, collisionStrikes = 0,

        -- vehicle
        vehicle = { speedStrikes = 0, ascendSamples = 0, ascendTotal = 0, airSamples = 0, lastDetect = 0, clientGround = nil, clientGroundTick = 0 },

        -- combat
        combat = {
            shots = {}, lastExplosiveWeaponTick = 0, mismatchStrikes = 0, rangeStrikes = 0, lastDetect = 0,
            -- aimbot statistics (per EvaluateWindow)
            evalStart = 0, shotsTotal = 0, hitsTotal = 0, headshots = 0, switches = 0, lastVictim = nil, lastHitTick = 0, aimLastDetect = 0,
            -- ammo
            ammo = {}, ammoStrikes = 0, ammoLastDetect = 0,
            -- wallhack helper signal
            wallShots = {}, wallLastDetect = 0,
        },

        -- god mode (as victim)
        godmode = { hits = {}, lastDamageTick = 0, lastDetect = 0 },

        -- flood protection
        flood = { dataWindow = 0, dataCount = 0, triggerWindow = 0, triggerCount = 0, invalid = {}, lastDetect = 0 },

        -- explosions
        explosions = {}, explosionLastDetect = 0,

        -- events / commands
        events = {}, commandTimes = {}, eventLastDetect = 0,

        -- event firewall
        firewall = { rates = {}, lastDetect = 0 },

        -- per-resource canary heartbeats: [resourceName] = { lastTick, reports, reported }
        canary = {},

        -- telemetry (client helper layer)
        telemetry = {
            ready = false, lastTick = 0, lastHeartbeat = 0, groundDist = nil, groundTick = 0, task = nil,
            positionStrikes = 0, gameSpeedStrikes = 0, gravityStrikes = 0, integrityStrikes = 0,
            missingReported = false, lastDetect = 0,
        },

        -- session token
        token = { value = nil, previous = nil, issuedAt = 0, seq = 0, lastClientTick = nil, lastServerTick = nil },

        -- suspicion
        suspicion = { score = 0, lastIncrease = 0, detections = {}, count = 0 },
        evidence = {},

        -- punishment
        punishment = { last = {}, pending = false, warnings = 0 },

        jetpackAllowed = false,
        jetpackLastDetect = 0,

        adminCached = false,
        adminCheckTick = nil,
    }
    states[player] = st
    return st
end

function PlayerState.get(player)
    return states[player]
end

function PlayerState.getOrCreate(player)
    if not Util.isPlayer(player) then return nil end
    return states[player] or PlayerState.create(player)
end

function PlayerState.remove(player)
    states[player] = nil
end

function PlayerState.each(fn)
    for player, st in pairs(states) do
        if isElement(player) then
            fn(player, st)
        else
            states[player] = nil
        end
    end
end

function PlayerState.count()
    return Util.tableCount(states)
end

-- ------------------------------------------------------------------ state machine
function PlayerState.setState(player, newState)
    local st = states[player]
    if not st or st.state == newState then return end
    Logger.debug("State transition", { player = getPlayerName(player), from = st.state, to = newState })
    st.state = newState
    st.stateSince = getTickCount()
end

function PlayerState.resetAir(st)
    st.air.start = nil
    st.air.hoverSamples = 0
    st.air.horizontalSamples = 0
    st.air.oscillations = 0
    st.air.lastDir = 0
    st.ascend.samples = 0
    st.ascend.total = 0
end

function PlayerState.resetBaseline(st, reason)
    st.lastSample = nil
    st.teleportPending = nil
    st.speedStrikes = 0
    st.vehicle.speedStrikes = 0
    st.vehicle.ascendSamples = 0
    st.vehicle.ascendTotal = 0
    st.vehicle.airSamples = 0
    PlayerState.resetAir(st)
    if reason then Logger.debug("Baseline reset", { player = getPlayerName(st.player), reason = reason }) end
end

-- Lazy state transitions evaluated by the sampler.
function PlayerState.update(st, now)
    local S = PlayerState.STATES
    local elapsed = now - st.stateSince
    if st.state == S.DYING and elapsed >= 2000 then
        PlayerState.setState(st.player, S.DEAD)
    elseif st.state == S.RESPAWNING and elapsed >= 500 then
        PlayerState.setState(st.player, S.SPAWN_GRACE)
    elseif st.state == S.SPAWN_GRACE and elapsed >= Config.GracePeriods.Spawn then
        PlayerState.setState(st.player, S.NORMAL)
        PlayerState.resetBaseline(st, "spawn grace ended")
    elseif st.state == S.DEAD and not isPedDead(st.player) and elapsed >= Config.GracePeriods.Death then
        -- spawned without onPlayerSpawn firing (some gamemodes revive via setElementHealth)
        PlayerState.setState(st.player, S.NORMAL)
        PlayerState.resetBaseline(st, "revived")
    end
end

-- ------------------------------------------------------------------ grace
function PlayerState.addGrace(player, duration, reason)
    local st = PlayerState.getOrCreate(player)
    if not st then return false end
    duration = tonumber(duration) or 0
    local untilTick = getTickCount() + duration
    if untilTick > st.grace.untilTick then
        st.grace.untilTick = untilTick
        st.grace.reason = reason or "unspecified"
    end
    PlayerState.resetBaseline(st, nil)
    Logger.debug("Movement grace", { player = getPlayerName(player), duration = duration, reason = reason })
    return true
end

function PlayerState.isInGrace(player)
    local st = states[player]
    if not st then return false end
    if getTickCount() < st.grace.untilTick then
        return true, st.grace.reason
    end
    if st.state ~= PlayerState.STATES.NORMAL and st.state ~= PlayerState.STATES.ALIVE then
        return true, st.state
    end
    return false
end

-- ------------------------------------------------------------------ exemptions
function PlayerState.setExempt(player, detection, duration)
    local st = PlayerState.getOrCreate(player)
    if not st then return false end
    detection = tostring(detection or "ALL")
    if duration and tonumber(duration) then
        st.exempt[detection] = getTickCount() + tonumber(duration)
    else
        st.exempt[detection] = true
    end
    return true
end

function PlayerState.removeExempt(player, detection)
    local st = states[player]
    if not st then return false end
    st.exempt[tostring(detection or "ALL")] = nil
    return true
end

local function exemptEntryActive(st, key, now)
    local e = st.exempt[key]
    if e == nil then return false end
    if e == true then return true end
    if type(e) == "number" then
        if now < e then return true end
        st.exempt[key] = nil
    end
    return false
end

function PlayerState.isExempt(player, detection)
    local st = states[player]
    if not st then return false end
    local now = getTickCount()
    if exemptEntryActive(st, "ALL", now) then return true end
    if detection and exemptEntryActive(st, tostring(detection), now) then return true end
    return false
end

-- ------------------------------------------------------------------ ACL helpers
function PlayerState.isInACLGroups(player, groups)
    if not Util.isPlayer(player) or type(groups) ~= "table" then return false end
    local account = getPlayerAccount(player)
    if not account or isGuestAccount(account) then return false end
    local object = "user." .. getAccountName(account)
    for _, groupName in ipairs(groups) do
        local group = aclGetGroup(groupName)
        if group and isObjectInACLGroup(object, group) then
            return true
        end
    end
    return false
end

function PlayerState.isAdmin(player)
    if not Config.Exemptions.Admins then return false end
    return PlayerState.isInACLGroups(player, Config.Exemptions.AdminGroups)
end

function PlayerState.isAdminCached(player)
    local st = states[player]
    if not st then return PlayerState.isAdmin(player) end
    local now = getTickCount()
    if st.adminCheckTick and now - st.adminCheckTick < (Config.Exemptions.AdminCacheTime or 10000) then
        return st.adminCached
    end
    st.adminCached = PlayerState.isAdmin(player)
    st.adminCheckTick = now
    return st.adminCached
end

function PlayerState.invalidateAdminCache(player)
    local st = states[player]
    if st then st.adminCheckTick = nil end
end

-- Combined gate used by every detection.
function PlayerState.canDetect(player, detection)
    if not Config.Enabled then return false end
    if not Config.isDetectionEnabled(detection) then return false end
    if not Util.isPlayer(player) then return false end
    if PlayerState.isExempt(player, detection) then return false end
    if PlayerState.isAdminCached(player) then return false end
    return true
end

-- ------------------------------------------------------------------ samples
function PlayerState.pushSample(st, sample)
    local list = st.samples
    list[#list + 1] = sample
    local max = Config.Evidence.SampleCount or 20
    while #list > max do
        table.remove(list, 1)
    end
end

-- ------------------------------------------------------------------ lag compensation
function PlayerState.getLagMultiplier(player, ping, dt, expectedDt)
    local lag = Config.Lag
    local m = 1.0
    ping = tonumber(ping) or 0
    if ping >= lag.PingHard then
        m = lag.ToleranceHard
    elseif ping >= lag.PingSoft then
        m = lag.ToleranceSoft
    end
    if expectedDt and dt and dt > expectedDt * 1.5 then
        m = math.max(m, lag.ToleranceSoft)
    end
    if ServerHealth and ServerHealth.jitter and ServerHealth.jitter > lag.TickJitterThreshold then
        m = math.max(m, lag.ToleranceHard)
    end
    return m
end

-- ------------------------------------------------------------------ events
addEventHandler("onPlayerJoin", root, function()
    PlayerState.create(source)
    PlayerState.addGrace(source, Config.GracePeriods.Join, "join")
end)

addEventHandler("onPlayerQuit", root, function()
    PlayerState.remove(source)
end)

addEventHandler("onPlayerLogin", root, function()
    PlayerState.invalidateAdminCache(source)
end)

addEventHandler("onPlayerLogout", root, function()
    PlayerState.invalidateAdminCache(source)
end)

addEventHandler("onPlayerWasted", root, function()
    local st = PlayerState.getOrCreate(source)
    if not st then return end
    PlayerState.setState(source, PlayerState.STATES.DYING)
    PlayerState.resetBaseline(st, "death")
    if Config.Exemptions.Death then
        PlayerState.addGrace(source, Config.GracePeriods.Death, "death")
    end
end)

addEventHandler("onPlayerSpawn", root, function()
    local st = PlayerState.getOrCreate(source)
    if not st then return end
    PlayerState.setState(source, PlayerState.STATES.RESPAWNING)
    PlayerState.resetBaseline(st, "spawn")
    if Config.Exemptions.Spawn or Config.Exemptions.Respawn then
        PlayerState.addGrace(source, Config.GracePeriods.Spawn, "spawn")
    end
end)

addEventHandler("onElementInteriorChange", root, function()
    if not Util.isPlayer(source) then return end
    if Config.Exemptions.InteriorChange then
        PlayerState.addGrace(source, Config.GracePeriods.Interior, "interior change")
    end
end)

addEventHandler("onElementDimensionChange", root, function()
    if not Util.isPlayer(source) then return end
    if Config.Exemptions.DimensionChange then
        PlayerState.addGrace(source, Config.GracePeriods.Dimension, "dimension change")
    end
end)

addEventHandler("onPlayerVehicleEnter", root, function(vehicle, seat, jacked)
    if Config.Exemptions.VehicleEnter or Config.Exemptions.Warp then
        PlayerState.addGrace(source, Config.GracePeriods.VehicleEnter, "vehicle enter")
    end
end)

addEventHandler("onPlayerVehicleExit", root, function(vehicle, seat, jacker, forcedByScript)
    if Config.Exemptions.VehicleExit then
        PlayerState.addGrace(source, Config.GracePeriods.VehicleExit, forcedByScript and "vehicle exit (script)" or "vehicle exit")
    end
end)

-- Explosions, vehicle hits and falls fling players around: remember it so speed/teleport checks relax.
addEventHandler("onPlayerDamage", root, function(attacker, weapon, bodypart, loss)
    local st = states[source]
    if not st then return end
    if weapon == 51 or weapon == 49 or weapon == 50 or weapon == 54 or weapon == 63 then
        st.lastHeavyDamage = getTickCount()
    end
end)
