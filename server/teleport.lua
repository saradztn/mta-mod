--[[
    SentinelAC :: server/teleport.lua
    Teleport detection: candidate -> confirmation on next sample -> strikes inside a window -> suspicion.
    Falls, sync rubber-banding, vehicles, lag, grace periods and scripted movement are all excluded.
]]

TeleportDetection = {}

local function movementClass(sample)
    if sample.veh then
        return sample.vehType or "Automobile"
    end
    return "OnFoot"
end

function TeleportDetection.confirm(player, st, pending, now)
    local cfg = Config.Detection.Teleport

    -- purge old strikes
    local kept = {}
    for _, t in ipairs(st.teleportStrikes) do
        if now - t <= (cfg.StrikeWindow or 90000) then kept[#kept + 1] = t end
    end
    kept[#kept + 1] = now
    st.teleportStrikes = kept

    Logger.warning("Teleport confirmed", {
        player = getPlayerName(player),
        from = Util.formatVec(pending.fromX, pending.fromY, pending.fromZ, 0),
        to = Util.formatVec(pending.x, pending.y, pending.z, 0),
        distance = Util.round(pending.dist, 0), dt = pending.dt, speed = Util.round(pending.speed, 0),
        class = pending.class, velocityInconsistent = pending.inconsistent, strikes = #kept,
    })

    if #kept >= (cfg.StrikesRequired or 2) and now - st.teleportLastDetect > (cfg.Cooldown or 3000) then
        st.teleportLastDetect = now
        st.teleportStrikes = {}
        local weight = Config.Suspicion.Weights.Teleport or 35
        if not pending.inconsistent then
            -- displacement roughly matches synced velocity: more likely extreme speed than a warp
            weight = math.floor(weight * 0.7)
        end
        Suspicion.add(player, "Teleport",
            string.format("Displacement of %.0fm in %dms (%.0f m/s, class %s)", pending.dist, pending.dt, pending.speed, pending.class),
            { distance = Util.round(pending.dist, 0), dt = pending.dt, speed = Util.round(pending.speed, 0), class = pending.class },
            weight)
    end
end

function TeleportDetection.check(player, st, prev, sample, ctx)
    local cfg = Config.Detection.Teleport
    if not cfg.Enabled or not PlayerState.canDetect(player, "Teleport") then
        st.teleportPending = nil
        return
    end
    local now = sample.t

    -- 1) confirmation phase for a previous candidate
    if st.teleportPending then
        local p = st.teleportPending
        st.teleportPending = nil
        local d = getDistanceBetweenPoints3D(p.x, p.y, p.z, sample.x, sample.y, sample.z)
        if d <= (cfg.ConfirmRadius or 60) * ctx.lag then
            TeleportDetection.confirm(player, st, p, now)
        else
            Logger.debug("Teleport candidate discarded (position not stable, likely sync correction)", {
                player = getPlayerName(player), drift = Util.round(d, 1),
            })
        end
        return -- the sample after a jump is a fresh baseline, never a second candidate
    end

    -- 2) candidate detection
    if ctx.dist3 < (cfg.Threshold or 120) then return end

    local class = movementClass(sample)
    local maxSpeed = (cfg.MaxLegitSpeed[class] or cfg.MaxLegitSpeed.OnFoot or 60) * ctx.lag
    if ctx.speed <= maxSpeed then return end

    -- falling from the sky is not a teleport: mostly vertical, downward, plausible fall speed
    if ctx.dz < 0 and math.abs(ctx.dz) >= 0.8 * ctx.dist3 and math.abs(ctx.vspeed) <= (cfg.MaxFallSpeed or 120) * ctx.lag then
        Logger.debug("Large vertical drop treated as fall", { player = getPlayerName(player), dz = Util.round(ctx.dz, 1) })
        return
    end

    -- recently flung by explosion / vehicle impact
    if now - (st.lastHeavyDamage or 0) < (Config.GracePeriods.HeavyDamage or 3000) then return end

    -- frozen players are usually being moved by a script
    if sample.frozen or prev.frozen then return end

    local velRef = math.max(ctx.prevVelSpeed, ctx.velSpeed, 5)
    local inconsistent = ctx.speed > velRef * (cfg.VelocityFactor or 3.0)

    st.teleportPending = {
        t = now, x = sample.x, y = sample.y, z = sample.z,
        fromX = prev.x, fromY = prev.y, fromZ = prev.z,
        dist = ctx.dist3, speed = ctx.speed, dt = ctx.dt, class = class, inconsistent = inconsistent,
    }
    Logger.debug("Teleport candidate", {
        player = getPlayerName(player), distance = Util.round(ctx.dist3, 0), speed = Util.round(ctx.speed, 0),
        velRef = Util.round(velRef, 0), class = class,
    })
end
