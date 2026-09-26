--[[
    SentinelAC :: server/movement.lua
    Timer-based adaptive sampler (never onPlayerMove). Builds per-player samples and contexts,
    dispatches to Teleport / Vehicle detections and runs on-foot Speed, Fly and Jetpack checks.
]]

Movement     = {}
ServerHealth = { jitter = 1.0, lastTick = 0 }

local timer  = nil
local cursor = 1
local hasJetpack = isPedWearingJetpack or doesPedHaveJetPack

-- ------------------------------------------------------------------ lifecycle
function Movement.start()
    Movement.stop()
    ServerHealth.lastTick = getTickCount()
    timer = setTimer(Movement.tick, Config.Sampling.Interval or 500, 0)
    Logger.info("Movement sampler started", { interval = Config.Sampling.Interval, batch = Config.Sampling.MaxPlayersPerTick })
end

function Movement.stop()
    if timer and isTimer(timer) then killTimer(timer) end
    timer = nil
end

function Movement.isRunning()
    return timer ~= nil and isTimer(timer)
end

-- ------------------------------------------------------------------ sampler
function Movement.tick()
    local now = getTickCount()
    local expected = Config.Sampling.Interval or 500
    local actual = now - ServerHealth.lastTick
    ServerHealth.lastTick = now
    if actual > 0 then ServerHealth.jitter = actual / expected end
    if not Config.Enabled then return end

    local players = getElementsByType("player")
    local count = #players
    if count == 0 then cursor = 1 return end

    local batch = Config.Sampling.MaxPlayersPerTick or 40
    if not Config.Sampling.Adaptive or count <= batch then
        for i = 1, count do
            Movement.samplePlayer(players[i], now)
        end
    else
        for _ = 1, batch do
            if cursor > count then cursor = 1 end
            Movement.samplePlayer(players[cursor], now)
            cursor = cursor + 1
        end
    end
end

function Movement.buildSample(player, now, st)
    local x, y, z    = getElementPosition(player)
    local vx, vy, vz = getElementVelocity(player)
    local veh = getPedOccupiedVehicle(player)
    return {
        t = now, x = x, y = y, z = z,
        vx = vx or 0, vy = vy or 0, vz = vz or 0,
        veh = veh or false,
        vehType = veh and getVehicleType(veh) or false,
        driver = (veh and getVehicleController(veh) == player) or false,
        interior = getElementInterior(player),
        dimension = getElementDimension(player),
        onGround = isPedOnGround(player),
        inWater = isElementInWater(player),
        ping = getPlayerPing(player),
        frozen = isElementFrozen(player),
        attached = isElementAttached(player),
        jetpack = hasJetpack(player),
        weapon = getPedWeapon(player) or 0,
        health = getElementHealth(player) or 0,
        armor = getPedArmor(player) or 0,
        state = st.state,
    }
end

-- health / armor above the possible maximum (independent of movement state)
function Movement.checkHealth(player, st, sample)
    local cfg = Config.Detection.GodMode
    if not cfg or not cfg.Enabled or not PlayerState.canDetect(player, "GodMode") then return end
    local now = sample.t
    if now - st.godmode.lastDetect <= (cfg.Cooldown or 30000) then return end
    if sample.health > (cfg.MaxHealth or 250) then
        st.godmode.lastDetect = now
        Suspicion.add(player, "GodMode", "Health above possible maximum", { health = Util.round(sample.health, 0) })
    elseif sample.armor > (cfg.MaxArmor or 100) + 0.5 then
        st.godmode.lastDetect = now
        Suspicion.add(player, "GodMode", "Armor above possible maximum", { armor = Util.round(sample.armor, 0) })
    end
end

function Movement.buildContext(player, prev, sample)
    local dt = sample.t - prev.t
    if dt <= 0 then return nil end
    local dx, dy, dz = sample.x - prev.x, sample.y - prev.y, sample.z - prev.z
    local dist2 = math.sqrt(dx * dx + dy * dy)
    local dist3 = math.sqrt(dist2 * dist2 + dz * dz)
    local seconds = dt / 1000
    return {
        dt = dt, seconds = seconds,
        dx = dx, dy = dy, dz = dz,
        dist2 = dist2, dist3 = dist3,
        speed = dist3 / seconds,
        hspeed = dist2 / seconds,
        vspeed = dz / seconds,
        -- synced velocity is in units per 1/50 s -> m/s ~= |v| * 50
        prevVelSpeed = math.sqrt(prev.vx * prev.vx + prev.vy * prev.vy + prev.vz * prev.vz) * 50,
        velSpeed = math.sqrt(sample.vx * sample.vx + sample.vy * sample.vy + sample.vz * sample.vz) * 50,
        lag = PlayerState.getLagMultiplier(player, sample.ping, dt, Config.Sampling.Interval),
    }
end

function Movement.samplePlayer(player, now)
    if not isElement(player) then return end
    local st = PlayerState.get(player)
    if not st then
        st = PlayerState.create(player)
        PlayerState.addGrace(player, Config.GracePeriods.Join, "late state creation")
    end
    PlayerState.update(st, now)

    if isPedDead(player) then
        if st.state == PlayerState.STATES.NORMAL or st.state == PlayerState.STATES.ALIVE then
            PlayerState.setState(player, PlayerState.STATES.DEAD)
        end
        st.lastSample = nil
        PlayerState.resetAir(st)
        return
    end

    local sample = Movement.buildSample(player, now, st)
    local prev = st.lastSample
    st.lastSample = sample
    PlayerState.pushSample(st, sample)
    Movement.checkHealth(player, st, sample)
    if not prev then return end -- baseline established

    local ctx = Movement.buildContext(player, prev, sample)
    if not ctx then return end

    -- structural transitions: grace + fresh baseline, never compared across
    if prev.interior ~= sample.interior then
        PlayerState.addGrace(player, Config.GracePeriods.Interior, "interior change (sampled)")
        return
    end
    if prev.dimension ~= sample.dimension then
        PlayerState.addGrace(player, Config.GracePeriods.Dimension, "dimension change (sampled)")
        return
    end
    if prev.veh ~= sample.veh then
        PlayerState.addGrace(player, sample.veh and Config.GracePeriods.VehicleEnter or Config.GracePeriods.VehicleExit, "vehicle transition (sampled)")
        return
    end
    if sample.attached or sample.frozen then
        PlayerState.resetAir(st)
        return
    end
    if ctx.dt > (Config.Lag.MaxDeltaTime or 3000) then
        Logger.debug("Large deltaTime, sample used as baseline only", { player = getPlayerName(player), dt = ctx.dt })
        PlayerState.resetAir(st)
        return
    end

    local inGrace = PlayerState.isInGrace(player)
    if inGrace then return end

    TeleportDetection.check(player, st, prev, sample, ctx)

    if sample.veh then
        VehicleDetection.check(player, st, prev, sample, ctx)
        PlayerState.resetAir(st)
    else
        Movement.checkSpeed(player, st, prev, sample, ctx)
        Movement.checkFly(player, st, prev, sample, ctx)
        Movement.checkJetpack(player, st, sample)
    end
end

-- ------------------------------------------------------------------ on-foot speed
function Movement.checkSpeed(player, st, prev, sample, ctx)
    local cfg = Config.Detection.SpeedHack
    if not cfg.Enabled or not PlayerState.canDetect(player, "SpeedHack") then return end
    local now = sample.t
    if now - (st.lastHeavyDamage or 0) < (Config.GracePeriods.HeavyDamage or 3000) then return end
    if sample.inWater then return end

    local limit = (cfg.MaxOnFootSpeed or 20) * ctx.lag
    if not sample.onGround then limit = limit * (cfg.AirborneMultiplier or 1.8) end

    if ctx.hspeed > limit and ctx.dist2 > (cfg.MinDistance or 3.0) then
        st.speedStrikes = st.speedStrikes + 1
        Logger.debug("Speed strike", { player = getPlayerName(player), speed = Util.round(ctx.hspeed, 1), limit = Util.round(limit, 1), strikes = st.speedStrikes })
        if st.speedStrikes >= (cfg.SamplesRequired or 4) and now - st.speedLastDetect > (cfg.Cooldown or 8000) then
            st.speedLastDetect = now
            st.speedStrikes = 0
            Suspicion.add(player, "SpeedHack", "On-foot speed exceeds limit over consecutive samples", {
                speed = Util.round(ctx.hspeed, 1), limit = Util.round(limit, 1), samples = cfg.SamplesRequired,
            })
        end
    else
        st.speedStrikes = math.max(0, st.speedStrikes - 1)
    end
end

-- ------------------------------------------------------------------ fly
local function vehicleNearby(x, y, z, dimension, interior)
    if type(getElementsWithinRange) ~= "function" then return false end
    local list = getElementsWithinRange(x, y, z, 5, "vehicle", interior, dimension)
    return list ~= false and #list > 0
end

local function raiseFly(player, st, reasons, details, now)
    local cfg = Config.Detection.Fly
    if st.flyScore < (cfg.SamplesRequired or 4) then return end
    if now - st.flyLastDetect <= (cfg.Cooldown or 10000) then return end
    st.flyLastDetect = now
    st.flyScore = 0
    PlayerState.resetAir(st)
    Suspicion.add(player, "Fly", "Airborne movement without falling physics: " .. table.concat(reasons, ","), details)
end

function Movement.checkFly(player, st, prev, sample, ctx)
    local cfg = Config.Detection.Fly
    if not cfg.Enabled or not PlayerState.canDetect(player, "Fly") then return end
    local now = sample.t
    local air = st.air
    local legit = sample.jetpack or sample.weapon == 46 or sample.attached

    -- (A) ascent check runs regardless of the (client-synced) on-ground flag
    if not legit then
        if ctx.dz > (cfg.AscendThreshold or 2.5) * ctx.lag then
            st.ascend.samples = st.ascend.samples + 1
            st.ascend.total = st.ascend.total + ctx.dz
        elseif ctx.dz < 0 then
            st.ascend.samples = 0
            st.ascend.total = 0
        end
        if st.ascend.samples >= (cfg.AscendSamplesRequired or 3) then
            st.flyScore = st.flyScore + 2
            Logger.debug("Fly anomaly: sustained ascent", { player = getPlayerName(player), climbed = Util.round(st.ascend.total, 1), flyScore = st.flyScore })
            local climbed = st.ascend.total
            st.ascend.samples = 0
            st.ascend.total = 0
            raiseFly(player, st, { "ascend" }, { climbed = Util.round(climbed, 1) }, now)
            return
        end
    end

    -- (B) grounded / legitimate: rebuild baseline
    if sample.onGround or sample.inWater or legit then
        if air.start then
            Logger.debug("Air phase ended", { player = getPlayerName(player), airTime = now - air.start })
        end
        PlayerState.resetAir(st)
        st.flyScore = math.max(0, st.flyScore - (cfg.ScoreDecayOnGround or 2))
        return
    end

    -- (C) airborne tracking
    if not air.start then
        air.start = prev.t
        air.startZ = prev.z
        air.peakZ = math.max(prev.z, sample.z)
        air.lastVz = sample.vz
        air.oscillations = 0
        air.lastDir = 0
        return
    end

    local airTime = now - air.start
    local vz = sample.vz
    if sample.z > air.peakZ then air.peakZ = sample.z end

    local falling     = vz < -(cfg.FallVelocity or 0.05) and ctx.dz < 0
    local naturalFall = falling and vz <= (air.lastVz + (cfg.FallAccelTolerance or 0.02))

    local dir = 0
    if ctx.dz > (cfg.VerticalTolerance or 3.0) then dir = 1 elseif ctx.dz < -(cfg.VerticalTolerance or 3.0) then dir = -1 end
    if dir ~= 0 and air.lastDir ~= 0 and dir ~= air.lastDir then air.oscillations = air.oscillations + 1 end
    if dir ~= 0 then air.lastDir = dir end
    air.lastVz = vz

    if naturalFall then
        air.hoverSamples = 0
        air.horizontalSamples = 0
        return
    end
    if airTime < (cfg.MinAirTime or 5000) then return end

    -- standing on a vehicle roof / truck bed looks like hovering to the server: skip hover/horizontal checks
    if vehicleNearby(sample.x, sample.y, sample.z, sample.dimension, sample.interior) then
        air.hoverSamples = 0
        air.horizontalSamples = 0
        return
    end

    local anomaly = 0
    local reasons = {}

    -- after MinAirTime every hovering / airborne-horizontal sample counts (falling samples already returned above)
    if math.abs(ctx.dz) < (cfg.VerticalTolerance or 3.0) and math.abs(vz) < (cfg.FallVelocity or 0.05) then
        air.hoverSamples = air.hoverSamples + 1
        anomaly = anomaly + 1
        reasons[#reasons + 1] = "hover"
    else
        air.hoverSamples = 0
    end

    if ctx.dist2 > (cfg.HorizontalThreshold or 6.0) * ctx.lag and not falling then
        air.horizontalSamples = air.horizontalSamples + 1
        anomaly = anomaly + 1
        reasons[#reasons + 1] = "airborne-horizontal"
    else
        air.horizontalSamples = 0
    end

    if air.oscillations >= 3 then
        anomaly = anomaly + 1
        reasons[#reasons + 1] = "oscillation"
        air.oscillations = 0
    end

    if airTime > (cfg.MaxAirTimeWithoutFall or 25000) and not falling then
        anomaly = anomaly + 1
        reasons[#reasons + 1] = "airtime"
        air.start = now -- avoid re-counting the same phase every sample
    end

    if anomaly > 0 then
        st.flyScore = st.flyScore + anomaly
        Logger.debug("Fly anomaly", { player = getPlayerName(player), reasons = table.concat(reasons, ","), flyScore = st.flyScore, airTime = airTime })
        raiseFly(player, st, reasons, {
            airTime = airTime, altitudeGain = Util.round(sample.z - air.startZ, 1),
            clientGround = st.telemetry.groundDist and Util.round(st.telemetry.groundDist, 1) or "n/a",
            clientTask = st.telemetry.task or "n/a",
        }, now)
    end
end

-- ------------------------------------------------------------------ jetpack
function Movement.checkJetpack(player, st, sample)
    local cfg = Config.Detection.Jetpack
    if not cfg.Enabled or not sample.jetpack then return end
    if not PlayerState.canDetect(player, "Jetpack") then return end
    if st.jetpackAllowed then return end
    if not cfg.RequireRegistration then
        -- informational only: jetpack usage is recorded once per cooldown
        if sample.t - st.jetpackLastDetect > (cfg.Cooldown or 60000) then
            st.jetpackLastDetect = sample.t
            Logger.info("Jetpack in use (unregistered, RequireRegistration=false)", Logger.playerIdentity(player))
        end
        return
    end
    if sample.t - st.jetpackLastDetect > (cfg.Cooldown or 60000) then
        st.jetpackLastDetect = sample.t
        Suspicion.add(player, "Jetpack", "Jetpack in use without registration by a trusted resource")
    end
end
