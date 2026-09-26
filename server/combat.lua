--[[
    SentinelAC :: server/combat.lua
    Weapon fire-rate, weapon-possession mismatch, blocked weapons, impossible hit range and damage sanity.
    All checks use strikes + cooldowns; default action is LOG because weapon sync is noisy.
]]

Combat  = {}
GodMode = {}

Combat.EXPLOSIVE_WEAPONS = { [16] = true, [18] = true, [35] = true, [36] = true, [39] = true, [40] = true }
Combat.EXPLOSIVE_VEHICLES = { [425] = true, [520] = true, [432] = true }
Combat.HITSCAN = { [22] = true, [23] = true, [24] = true, [25] = true, [26] = true, [27] = true, [28] = true, [29] = true,
                   [30] = true, [31] = true, [32] = true, [33] = true, [34] = true, [38] = true }

-- ------------------------------------------------------------------ god mode (victim side)
function GodMode.recordHit(victim, attacker, weapon, now)
    local cfg = Config.Detection.GodMode
    if not cfg or not cfg.Enabled then return end
    local st = PlayerState.get(victim)
    if not st or isPedDead(victim) then return end
    local g = st.godmode
    local hp = (getElementHealth(victim) or 0) + (getPedArmor(victim) or 0)
    local kept = {}
    for _, h in ipairs(g.hits) do
        if now - h.t <= (cfg.Window or 20000) then kept[#kept + 1] = h end
    end
    kept[#kept + 1] = { t = now, hp = hp, attacker = getPlayerName(attacker) }
    g.hits = kept
    if #kept < (cfg.HitsRequired or 12) then return end
    -- took any damage inside the window, or health actually dropped: not god mode
    if now - g.lastDamageTick <= (cfg.Window or 20000) or hp < kept[1].hp then
        g.hits = {}
        return
    end
    if not PlayerState.canDetect(victim, "GodMode") then g.hits = {} return end
    if now - g.lastDetect <= (cfg.Cooldown or 30000) then return end
    g.lastDetect = now
    g.hits = {}
    Suspicion.add(victim, "GodMode", string.format("%d registered weapon hits in %ds without any damage", #kept, math.floor((cfg.Window or 20000) / 1000)), {
        hits = #kept, healthPlusArmor = Util.round(hp, 0), lastAttacker = getPlayerName(attacker), weapon = weapon,
    })
end

-- ------------------------------------------------------------------ per-shot bookkeeping (ammo, aimbot, god mode)
function Combat.evaluateAimbot(player, st, now)
    local aim = Config.Detection.Aimbot
    local c = st.combat
    if not PlayerState.canDetect(player, "Aimbot") then return end
    if now - c.aimLastDetect <= (aim.Cooldown or 60000) then return end
    local reasons = {}
    if c.hitsTotal >= (aim.MinHits or 25) and c.headshots / c.hitsTotal >= (aim.HeadshotRatio or 0.75) then
        reasons[#reasons + 1] = string.format("headshot ratio %.0f%% over %d hits", c.headshots / c.hitsTotal * 100, c.hitsTotal)
    end
    if c.shotsTotal >= (aim.MinShots or 50) and c.hitsTotal / c.shotsTotal >= (aim.AccuracyRatio or 0.97) then
        reasons[#reasons + 1] = string.format("accuracy %.0f%% over %d shots", c.hitsTotal / c.shotsTotal * 100, c.shotsTotal)
    end
    if c.switches >= (aim.SwitchesRequired or 6) then
        reasons[#reasons + 1] = string.format("%d rapid target switches", c.switches)
    end
    if #reasons == 0 then return end
    c.aimLastDetect = now
    c.evalStart = now
    c.shotsTotal, c.hitsTotal, c.headshots, c.switches = 0, 0, 0, 0
    Suspicion.add(player, "Aimbot", "Aim pattern anomaly: " .. table.concat(reasons, "; "))
end

function Combat.trackShot(player, st, weapon, ammo, hitElement, now)
    local c = st.combat
    local victim = (Util.isPlayer(hitElement) and hitElement ~= player) and hitElement or nil

    -- infinite ammo
    local acfg = Config.Detection.AmmoHack
    if acfg and acfg.Enabled and Combat.HITSCAN[weapon] and type(ammo) == "number" then
        local prev = c.ammo[weapon]
        if prev and ammo >= prev then c.ammoStrikes = c.ammoStrikes + 1 else c.ammoStrikes = 0 end
        c.ammo[weapon] = ammo
        if c.ammoStrikes >= (acfg.ShotsRequired or 30) and PlayerState.canDetect(player, "AmmoHack")
            and now - c.ammoLastDetect > (acfg.Cooldown or 60000) then
            c.ammoLastDetect = now
            c.ammoStrikes = 0
            Suspicion.add(player, "AmmoHack", "Total ammo never decreases while firing", { weapon = weapon, ammo = ammo, shots = acfg.ShotsRequired })
        end
    end

    -- aimbot statistics
    local aim = Config.Detection.Aimbot
    if aim and aim.Enabled and Combat.HITSCAN[weapon] and not (aim.ExcludedWeapons or {})[weapon] then
        if now - c.evalStart > (aim.EvaluateWindow or 60000) then
            c.evalStart = now
            c.shotsTotal, c.hitsTotal, c.headshots, c.switches = 0, 0, 0, 0
        end
        c.shotsTotal = c.shotsTotal + 1
        if victim then
            c.hitsTotal = c.hitsTotal + 1
            if c.lastVictim and c.lastVictim ~= victim and now - c.lastHitTick <= (aim.SwitchWindow or 150) then
                c.switches = c.switches + 1
            end
            c.lastVictim = victim
            c.lastHitTick = now
        end
        Combat.evaluateAimbot(player, st, now)
    end

    if victim then GodMode.recordHit(victim, player, weapon, now) end
end

local function raise(player, st, reason, details, now)
    local cfg = Config.Detection.Combat
    if now - st.combat.lastDetect <= (cfg.Cooldown or 5000) then return end
    st.combat.lastDetect = now
    Suspicion.add(player, "Combat", reason, details)
end

addEventHandler("onPlayerWeaponFire", root, function(weapon, ammo, ammoInClip, hitX, hitY, hitZ, hitElement)
    local player = source
    local st = PlayerState.get(player)
    if not st then return end
    local now = getTickCount()

    -- always remember explosive weapon usage (needed by explosion.lua even when Combat is disabled)
    if Combat.EXPLOSIVE_WEAPONS[weapon] then
        st.combat.lastExplosiveWeaponTick = now
    end

    Combat.trackShot(player, st, weapon, ammo, hitElement, now)

    local cfg = Config.Detection.Combat
    if not cfg.Enabled or not PlayerState.canDetect(player, "Combat") then return end

    -- blocked weapons
    if cfg.BlockedWeapons[weapon] then
        raise(player, st, "Fired a blocked weapon", { weapon = weapon, name = getWeaponNameFromID(weapon) }, now)
        return
    end

    -- weapon mismatch: server view of the currently held weapon
    local serverWeapon = getPedWeapon(player)
    if serverWeapon ~= weapon then
        st.combat.mismatchStrikes = st.combat.mismatchStrikes + 1
        if st.combat.mismatchStrikes >= (cfg.WeaponMismatchStrikes or 3) then
            st.combat.mismatchStrikes = 0
            raise(player, st, "Fired a weapon the server does not see the player holding", {
                fired = weapon, held = serverWeapon,
            }, now)
        end
    else
        st.combat.mismatchStrikes = math.max(0, st.combat.mismatchStrikes - 1)
    end

    -- fire rate
    if cfg.FireRateCheck then
        local maxPerSec = cfg.MaxShotsPerSecond[weapon]
        if maxPerSec then
            local window = cfg.FireRateWindow or 2000
            local shots = st.combat.shots[weapon] or {}
            local kept = {}
            for _, t in ipairs(shots) do
                if now - t <= window then kept[#kept + 1] = t end
            end
            kept[#kept + 1] = now
            local allowed = maxPerSec * (window / 1000) * (cfg.FireRateTolerance or 1.5)
            if #kept > allowed then
                st.combat.shots[weapon] = {}
                raise(player, st, "Fire rate exceeds weapon capability", {
                    weapon = weapon, name = getWeaponNameFromID(weapon), shots = #kept, windowMs = window, allowed = Util.round(allowed, 1),
                }, now)
            else
                st.combat.shots[weapon] = kept
            end
        end
    end

    -- range: hit point far beyond the weapon's range
    if cfg.RangeCheck and type(hitX) == "number" and type(hitY) == "number" and type(hitZ) == "number" then
        local range = getWeaponProperty(weapon, "pro", "weapon_range")
        if type(range) == "number" and range > 0 then
            local px, py, pz = getElementPosition(player)
            local d = getDistanceBetweenPoints3D(px, py, pz, hitX, hitY, hitZ)
            if d > range * (cfg.RangeTolerance or 1.5) and d > 60 then
                st.combat.rangeStrikes = st.combat.rangeStrikes + 1
                if st.combat.rangeStrikes >= 3 then
                    st.combat.rangeStrikes = 0
                    raise(player, st, "Hits registered beyond weapon range", {
                        weapon = weapon, distance = Util.round(d, 0), range = Util.round(range, 0),
                    }, now)
                end
            else
                st.combat.rangeStrikes = math.max(0, st.combat.rangeStrikes - 1)
            end
        end
    end
end)

-- track explosive weapon selection as well (satchels are placed, then detonated much later)
addEventHandler("onPlayerWeaponSwitch", root, function(previousSlot, currentSlot)
    local st = PlayerState.get(source)
    if not st then return end
    local weapon = getPedWeapon(source, currentSlot)
    if weapon and Combat.EXPLOSIVE_WEAPONS[weapon] then
        st.combat.lastExplosiveWeaponTick = getTickCount()
    end
end)

-- Damage sanity. Damage is calculated on the victim's client, so blame is ambiguous: logged with reduced weight.
addEventHandler("onPlayerDamage", root, function(attacker, weapon, bodypart, loss)
    local now = getTickCount()
    local victimSt = PlayerState.get(source)
    if victimSt then victimSt.godmode.lastDamageTick = now end
    if Util.isPlayer(attacker) and attacker ~= source and bodypart == 9 then
        local ast = PlayerState.get(attacker)
        if ast then ast.combat.headshots = ast.combat.headshots + 1 end
    end

    local cfg = Config.Detection.Combat
    if not cfg.Enabled then return end
    if not Util.isPlayer(attacker) or attacker == source then return end
    if type(loss) ~= "number" then return end
    if weapon == 51 or weapon == 49 or weapon == 50 or weapon == 54 or weapon == 63 then return end
    if loss > (cfg.MaxDamagePerHit or 200) then
        local st = PlayerState.get(attacker)
        if not st or not PlayerState.canDetect(attacker, "Combat") then return end
        local now = getTickCount()
        if now - st.combat.lastDetect <= (cfg.Cooldown or 5000) then return end
        st.combat.lastDetect = now
        Suspicion.add(attacker, "Combat", "Single hit damage exceeds possible maximum", {
            weapon = weapon, loss = Util.round(loss, 0), victim = getPlayerName(source),
        }, math.floor((Config.Suspicion.Weights.Combat or 20) / 2))
    end
end)
