--[[
    SentinelAC :: server/explosion.lua
    Explosion monitoring: type, creator, distance, frequency and weapon capability.
    Policy: ALLOW (no checks) | LOG (detect only) | BLOCK (cancel anomalous explosions).
    Vehicle/object explosions and anything without a player source are never touched.
]]

Explosion = {}

Explosion.TYPE_NAMES = {
    [0] = "grenade", [1] = "molotov", [2] = "rocket", [3] = "rocket-weak", [4] = "car", [5] = "car-quick",
    [6] = "boat", [7] = "heli", [8] = "mine", [9] = "object", [10] = "tank-grenade", [11] = "small", [12] = "tiny",
}

function Explosion.playerCanExplode(player, st, now)
    local cfg = Config.Detection.Explosion
    for _, slot in ipairs({ 7, 8, 12 }) do
        local w = getPedWeapon(player, slot)
        if w and w > 0 and Combat.EXPLOSIVE_WEAPONS[w] then return true end
    end
    if now - (st.combat.lastExplosiveWeaponTick or 0) < (cfg.ExplosiveWeaponMemory or 120000) then return true end
    local veh = getPedOccupiedVehicle(player)
    if veh and Combat.EXPLOSIVE_VEHICLES[getElementModel(veh)] then return true end
    return false
end

addEventHandler("onExplosion", root, function(x, y, z, theType)
    local player = source
    if not Util.isPlayer(player) then return end -- server / resource created explosions are never judged

    local cfg = Config.Detection.Explosion
    if not cfg.Enabled or cfg.Policy == "ALLOW" then return end
    if cfg.IgnoredTypes[theType] then return end
    if not PlayerState.canDetect(player, "Explosion") then return end

    local st = PlayerState.get(player)
    if not st then return end
    local now = getTickCount()
    local reasons = {}

    if cfg.BlockedTypes[theType] then
        reasons[#reasons + 1] = "blocked-type"
    end

    -- rate limiter per player
    local kept = {}
    for _, t in ipairs(st.explosions) do
        if now - t <= (cfg.Window or 10000) then kept[#kept + 1] = t end
    end
    kept[#kept + 1] = now
    st.explosions = kept
    if #kept > (cfg.MaxRate or 5) then
        reasons[#reasons + 1] = "rate"
    end

    -- distance from creator
    local px, py, pz = getElementPosition(player)
    local distance = getDistanceBetweenPoints3D(px, py, pz, x, y, z)
    if distance > (cfg.MaxDistance or 350) then
        reasons[#reasons + 1] = "distance"
    end

    -- weapon capability
    if cfg.RequireExplosiveWeapon and not Explosion.playerCanExplode(player, st, now) then
        reasons[#reasons + 1] = "no-explosive-weapon"
    end

    if #reasons == 0 then return end

    if cfg.Policy == "BLOCK" then
        cancelEvent()
    end

    local details = {
        type = theType, typeName = Explosion.TYPE_NAMES[theType] or "unknown",
        distance = Util.round(distance, 0), rate = #kept, at = Util.formatVec(x, y, z, 0), blocked = cfg.Policy == "BLOCK",
    }
    if now - st.explosionLastDetect > (cfg.Cooldown or 5000) then
        st.explosionLastDetect = now
        Suspicion.add(player, "Explosion", "Explosion anomaly: " .. table.concat(reasons, ","), details)
    else
        details.player = getPlayerName(player)
        details.reasons = table.concat(reasons, ",")
        Logger.debug("Explosion anomaly (cooldown)", details)
    end
end)
