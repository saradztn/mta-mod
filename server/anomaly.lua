--[[
    SentinelAC :: server/anomaly.lua
    Suspicion scoring (with decay), evidence capture, admin notifications,
    telemetry cross-checks (client data is only used to ADD suspicion, never to suppress a server check)
    and NoClip evaluation.
]]

Suspicion     = {}
Evidence      = {}
Notifications = {}
Telemetry     = {}
NoClipDetection = {}

local decayTimer = nil
local watchTimer = nil
local LEVEL_ORDER = { Low = 1, Medium = 2, High = 3, Critical = 4 }

-- ------------------------------------------------------------------ Suspicion
function Suspicion.getLevel(score)
    local L = Config.Suspicion.Levels
    if score > L.High then return "Critical" end
    if score > L.Medium then return "High" end
    if score > L.Low then return "Medium" end
    return "Low"
end

function Suspicion.get(player)
    local st = PlayerState.get(player)
    return st and st.suspicion.score or 0
end

function Suspicion.reset(player)
    local st = PlayerState.get(player)
    if not st then return false end
    st.suspicion.score = 0
    st.suspicion.count = 0
    st.suspicion.detections = {}
    st.punishment.warnings = 0
    st.flyScore = 0
    st.teleportStrikes = {}
    st.noclipStrikes = 0
    return true
end

-- Confidence is a transparent heuristic: repeated hits of the same detection and hits across
-- independent detections raise it. It is reported to admins, never used alone for punishment.
function Suspicion.confidence(st, detection)
    local sameType  = st.suspicion.detections[detection] or 0
    local distinct  = Util.tableCount(st.suspicion.detections)
    local c = 40 + sameType * 12 + (distinct - 1) * 8
    if c > 99 then c = 99 end
    if c < 0 then c = 0 end
    return math.floor(c)
end

function Suspicion.add(player, detection, reason, details, weightOverride)
    if not Util.isPlayer(player) then return 0, "Low" end
    local st = PlayerState.get(player)
    if not st then return 0, "Low" end

    local now    = getTickCount()
    local weight = tonumber(weightOverride) or Config.Suspicion.Weights[detection] or 10
    local sus    = st.suspicion

    sus.score = math.min(sus.score + weight, Config.Suspicion.MaxScore or 200)
    sus.lastIncrease = now
    sus.count = sus.count + 1
    sus.detections[detection] = (sus.detections[detection] or 0) + 1

    local level      = Suspicion.getLevel(sus.score)
    local confidence = Suspicion.confidence(st, detection)

    if Config.Evidence.Enabled then
        Evidence.capture(st, detection, reason, details)
    end

    local action = Punishment.handle(player, detection, sus.score, level, reason)

    local ctx = Logger.playerContext(player)
    ctx.detection  = detection
    ctx.score      = sus.score
    ctx.weight     = weight
    ctx.level      = level
    ctx.confidence = confidence
    ctx.reason     = reason
    ctx.action     = action
    ctx.state      = st.state
    if type(details) == "table" then
        for k, v in pairs(details) do
            if ctx[k] == nil then ctx[k] = v end
        end
    end
    Logger.log(level == "Critical" and "CRITICAL" or "DETECTION", "Detection: " .. tostring(detection), ctx)
    Notifications.send(player, detection, sus.score, level, confidence, action)
    return sus.score, level
end

function Suspicion.decayTick()
    local now = getTickCount()
    local cfg = Config.Suspicion
    PlayerState.each(function(player, st)
        local sus = st.suspicion
        if sus.score > 0 and now - sus.lastIncrease >= (cfg.DecayDelay or 20000) then
            sus.score = math.max(0, sus.score - (cfg.DecayAmount or 5))
        end
        -- fly score also decays slowly with time
        if st.flyScore > 0 and now - st.flyLastDetect > 30000 then
            st.flyScore = math.max(0, st.flyScore - 1)
        end
    end)
end

function Suspicion.start()
    if decayTimer and isTimer(decayTimer) then killTimer(decayTimer) end
    decayTimer = setTimer(Suspicion.decayTick, Config.Suspicion.DecayInterval or 10000, 0)
end

function Suspicion.stop()
    if decayTimer and isTimer(decayTimer) then killTimer(decayTimer) end
    decayTimer = nil
end

-- ------------------------------------------------------------------ Evidence
local function timestampString()
    local t = getRealTime()
    return string.format("%04d-%02d-%02d %02d:%02d:%02d", t.year + 1900, t.month + 1, t.monthday, t.hour, t.minute, t.second)
end

function Evidence.capture(st, detection, reason, details)
    local snapshot = {}
    for i, s in ipairs(st.samples) do
        snapshot[i] = {
            t = s.t,
            x = Util.round(s.x, 1), y = Util.round(s.y, 1), z = Util.round(s.z, 1),
            v = Util.formatVec(s.vx, s.vy, s.vz, 3),
            veh = (s.veh and isElement(s.veh)) and getElementModel(s.veh) or 0,
            g = s.onGround and 1 or 0,
            st = s.state,
            p = s.ping,
        }
    end
    local entry = {
        time = timestampString(),
        detection = detection,
        reason = reason,
        details = details,
        score = st.suspicion.score,
        samples = snapshot,
    }
    table.insert(st.evidence, 1, entry)
    while #st.evidence > (Config.Evidence.MaxEntries or 5) do
        table.remove(st.evidence)
    end
    if Config.Evidence.WriteToLog then
        local id = Logger.playerIdentity(st.player)
        id.detection = detection
        id.samples = snapshot
        Logger.log("DETECTION", "Evidence", id)
    end
end

function Evidence.get(player)
    local st = PlayerState.get(player)
    return st and st.evidence or {}
end

-- ------------------------------------------------------------------ Notifications
function Notifications.send(player, detection, score, level, confidence, action)
    local cfg = Config.Notifications
    if not cfg.Enabled then return end
    if (LEVEL_ORDER[level] or 1) < (LEVEL_ORDER[cfg.MinLevel] or 3) then return end
    local msg = string.format("%s Player: %s | Detection: %s | Score: %d (%s) | Confidence: %d%% | Action: %s",
        Config.Prefix, getPlayerName(player), tostring(detection), score, level, confidence, tostring(action))
    local c = cfg.Color or { 255, 120, 120 }
    for _, admin in ipairs(getElementsByType("player")) do
        if admin ~= player and PlayerState.isInACLGroups(admin, cfg.Groups) then
            outputChatBox(msg, admin, c[1], c[2], c[3])
        end
    end
end

function Notifications.broadcast(message)
    local cfg = Config.Notifications
    local c = cfg.Color or { 255, 120, 120 }
    for _, admin in ipairs(getElementsByType("player")) do
        if PlayerState.isInACLGroups(admin, cfg.Groups) then
            outputChatBox(Config.Prefix .. " " .. message, admin, c[1], c[2], c[3])
        end
    end
end

-- ------------------------------------------------------------------ NoClip
function NoClipDetection.addHits(player, st, hits, movedClaimed)
    local cfg = Config.Detection.NoClip
    if not PlayerState.canDetect(player, "NoClip") then return end
    if PlayerState.isInGrace(player) then return end
    if getPedOccupiedVehicle(player) and not cfg.CheckVehicles then return end

    local now = getTickCount()
    if now - st.noclipWindowStart > (cfg.Window or 15000) then
        st.noclipWindowStart = now
        st.noclipStrikes = 0
    end
    st.noclipStrikes = st.noclipStrikes + math.min(hits, cfg.MaxHitsPerReport or 2)

    if st.noclipStrikes >= cfg.SamplesRequired and now - st.noclipLastDetect > (cfg.Cooldown or 10000) then
        -- server corroboration: the server itself must have seen real displacement recently
        local samples = st.samples
        local displacement = 0
        if #samples >= 2 then
            local a, b = samples[1], samples[#samples]
            displacement = getDistanceBetweenPoints3D(a.x, a.y, a.z, b.x, b.y, b.z)
        end
        if displacement < (cfg.MinServerDisplacement or 2.0) then
            Logger.debug("NoClip strikes ignored: no server-side displacement", { player = getPlayerName(player) })
            st.noclipStrikes = 0
            return
        end
        st.noclipLastDetect = now
        st.noclipStrikes = 0
        Suspicion.add(player, "NoClip", "Repeated movement through solid geometry", {
            strikes = cfg.SamplesRequired, serverDisplacement = Util.round(displacement, 1), clientMoved = Util.round(movedClaimed or 0, 1),
        })
    end
end

-- ------------------------------------------------------------------ Telemetry cross-checks
local function bump(st, field, condition, limit)
    if condition then
        st.telemetry[field] = st.telemetry[field] + 1
    else
        st.telemetry[field] = math.max(0, st.telemetry[field] - 1)
    end
    return st.telemetry[field] >= limit
end

function Telemetry.process(player, data)
    local st = PlayerState.get(player)
    if not st then return end
    local now = getTickCount()
    local tel = st.telemetry
    tel.lastTick = now
    tel.ready = true
    tel.missingReported = false

    local inGrace = PlayerState.isInGrace(player)
    local lag = PlayerState.getLagMultiplier(player, getPlayerPing(player), nil, nil)

    -- ground distance / task are stored for context only (used to ADD confidence, never to suppress)
    if type(data.ground) == "number" then
        tel.groundDist = data.ground
        tel.groundTick = now
    end
    if type(data.task) == "string" and #data.task <= 16 then
        tel.task = data.task
    end

    -- 1) position divergence: client claims to be somewhere else than the server sees
    if Config.isDetectionEnabled("Telemetry") and type(data.x) == "number" and type(data.y) == "number" and type(data.z) == "number" then
        local sx, sy, sz = getElementPosition(player)
        local d = getDistanceBetweenPoints3D(sx, sy, sz, data.x, data.y, data.z)
        local tcfg = Config.Detection.Telemetry
        if bump(st, "positionStrikes", (d > tcfg.PositionTolerance * lag) and not inGrace, tcfg.StrikesRequired)
            and PlayerState.canDetect(player, "Telemetry") and now - tel.lastDetect > tcfg.Cooldown then
            tel.lastDetect = now
            tel.positionStrikes = 0
            Suspicion.add(player, "Telemetry", "Client-reported position diverges from server position", { distance = Util.round(d, 1) })
        end
    end

    -- 2) game speed mismatch (speed hack indicator)
    if type(data.gameSpeed) == "number" and type(getGameSpeed) == "function" then
        local scfg = Config.Detection.SpeedHack
        local mismatch = math.abs(data.gameSpeed - getGameSpeed()) > (scfg.GameSpeedTolerance or 0.05)
        if bump(st, "gameSpeedStrikes", mismatch, scfg.GameSpeedStrikes or 3)
            and PlayerState.canDetect(player, "SpeedHack") and now - st.speedLastDetect > scfg.Cooldown then
            st.speedLastDetect = now
            tel.gameSpeedStrikes = 0
            Suspicion.add(player, "SpeedHack", "Client game speed differs from server game speed", {
                client = Util.round(data.gameSpeed, 3), server = Util.round(getGameSpeed(), 3),
            })
        end
    end

    -- 3) gravity mismatch (only for APIs available on this server build)
    local canWorldGravity = type(data.gravity) == "number" and type(getGravity) == "function"
    local canPedGravity   = type(data.pedGravity) == "number" and type(getPedGravity) == "function"
    if canWorldGravity or canPedGravity then
        local icfg = Config.Detection.Integrity
        local mismatch = false
        if canWorldGravity and math.abs(data.gravity - getGravity()) > icfg.GravityTolerance then mismatch = true end
        if canPedGravity and math.abs(data.pedGravity - getPedGravity(player)) > icfg.GravityTolerance then mismatch = true end
        if bump(st, "gravityStrikes", mismatch, icfg.Strikes or 3)
            and PlayerState.canDetect(player, "Integrity") and now - tel.lastDetect > icfg.Cooldown then
            tel.lastDetect = now
            tel.gravityStrikes = 0
            Suspicion.add(player, "Integrity", "Client gravity differs from server gravity", {
                clientWorld = data.gravity, clientPed = data.pedGravity,
                serverWorld = canWorldGravity and getGravity() or "n/a",
                serverPed = canPedGravity and getPedGravity(player) or "n/a",
            })
        end
    end

    -- 4) collisions disabled on the client while enabled on the server
    if data.collisions == false and type(getElementCollisionsEnabled) == "function" then
        local ncfg = Config.Detection.NoClip
        if getElementCollisionsEnabled(player) then
            st.collisionStrikes = st.collisionStrikes + 1
            if st.collisionStrikes >= (ncfg.CollisionStrikes or 3) and PlayerState.canDetect(player, "NoClip")
                and now - st.noclipLastDetect > ncfg.Cooldown then
                st.noclipLastDetect = now
                st.collisionStrikes = 0
                Suspicion.add(player, "NoClip", "Client collisions disabled while server has them enabled")
            end
        end
    elseif data.collisions == true then
        st.collisionStrikes = math.max(0, st.collisionStrikes - 1)
    end

    -- 5) solid geometry crossings reported by the client ray layer
    if type(data.noclipHits) == "number" and data.noclipHits > 0 then
        NoClipDetection.addHits(player, st, math.floor(data.noclipHits), tonumber(data.noclipMoved) or 0)
    end

    -- 5b) shots that hit a player while the client-side line of sight was blocked (wallhack helper signal)
    if type(data.wallShots) == "number" and data.wallShots > 0 then
        local wcfg = Config.Detection.Wallhack
        if wcfg and wcfg.Enabled then
            local c = st.combat
            local kept = {}
            for _, t in ipairs(c.wallShots) do
                if now - t <= (wcfg.Window or 60000) then kept[#kept + 1] = t end
            end
            for _ = 1, math.min(math.floor(data.wallShots), 5) do kept[#kept + 1] = now end
            c.wallShots = kept
            if #kept >= (wcfg.ShotsRequired or 5) and PlayerState.canDetect(player, "Wallhack")
                and now - c.wallLastDetect > (wcfg.Cooldown or 60000) then
                c.wallLastDetect = now
                c.wallShots = {}
                Suspicion.add(player, "Wallhack", "Repeated hits on players through blocked line of sight", { shots = #kept })
            end
        end
    end

    -- 6) vehicle ground distance for land-vehicle hovering (consumed by vehicle.lua)
    if type(data.vehGround) == "number" then
        st.vehicle.clientGround = data.vehGround
        st.vehicle.clientGroundTick = now
    end
end

function Telemetry.processIntegrity(player, data)
    local st = PlayerState.get(player)
    if not st then return end
    local now = getTickCount()
    local icfg = Config.Detection.Integrity
    local flags = {}
    if data.telemetryRestarted == true then flags[#flags + 1] = "telemetry-timer-restarted" end
    if data.rayRestarted == true then flags[#flags + 1] = "ray-timer-restarted" end
    if data.devMode == true then
        Logger.info("Client reports development mode", Logger.playerIdentity(player))
    end
    if #flags > 0 then
        st.telemetry.integrityStrikes = st.telemetry.integrityStrikes + 1
        Logger.debug("Integrity flags", { player = getPlayerName(player), flags = table.concat(flags, ",") })
        if st.telemetry.integrityStrikes >= (icfg.Strikes or 3) and PlayerState.canDetect(player, "Integrity")
            and now - st.telemetry.lastDetect > icfg.Cooldown then
            st.telemetry.lastDetect = now
            st.telemetry.integrityStrikes = 0
            Suspicion.add(player, "Integrity", "Client component repeatedly interrupted: " .. table.concat(flags, ","))
        end
    end
end

-- Heartbeat / missing telemetry watch. Loss of telemetry is a WEAK signal (crash, network, resource restart).
function Telemetry.watchTick()
    local tcfg = Config.Detection.Telemetry
    if not tcfg.Enabled then return end
    local now = getTickCount()
    PlayerState.each(function(player, st)
        local tel = st.telemetry
        if isPedDead(player) or PlayerState.isInGrace(player) then return end
        if now - st.joinTick < (Config.GracePeriods.TelemetryStart or 20000) then return end
        if not PlayerState.canDetect(player, "Telemetry") then return end
        -- re-raise every Cooldown while the outage persists so the score can accumulate
        if tel.missingReported and now - tel.lastDetect < (tcfg.Cooldown or 60000) then return end
        local missing = false
        if not tel.ready then
            missing = tcfg.RequireTelemetry == true
        elseif now - tel.lastTick > (tcfg.HeartbeatTimeout or 30000) and now - tel.lastHeartbeat > (tcfg.HeartbeatTimeout or 30000) then
            missing = true
        end
        if missing and getPlayerPing(player) < Config.Lag.PingHard then
            tel.missingReported = true
            tel.lastDetect = now
            Suspicion.add(player, "Telemetry", tel.ready and "Client telemetry stopped" or "Client never reported telemetry", {
                sinceMs = tel.ready and (now - tel.lastTick) or (now - st.joinTick),
            })
        end
    end)
end

function Telemetry.start()
    if watchTimer and isTimer(watchTimer) then killTimer(watchTimer) end
    watchTimer = setTimer(Telemetry.watchTick, 10000, 0)
end

function Telemetry.stop()
    if watchTimer and isTimer(watchTimer) then killTimer(watchTimer) end
    watchTimer = nil
end
