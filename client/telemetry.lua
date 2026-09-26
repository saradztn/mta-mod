--[[
    SentinelAC :: client/telemetry.lua
    Periodic telemetry + heartbeat. Every packet carries token / seq / tick for replay protection.
]]

Telemetry = {}

local telemetryTimer = nil
local heartbeatTimer = nil
local renderHooked = false
local frames, fps, fpsTick = 0, 0, 0
local wallShots = 0

-- hits registered on a player while the straight line from muzzle to hit point is blocked by world geometry
addEventHandler("onClientPlayerWeaponFire", localPlayer, function(weapon, ammo, ammoInClip, hitX, hitY, hitZ, hitElement, startX, startY, startZ)
    if source ~= localPlayer then return end
    if not isElement(hitElement) or getElementType(hitElement) ~= "player" then return end
    if type(startX) ~= "number" or type(hitX) ~= "number" then return end
    if type(isLineOfSightClear) ~= "function" then return end
    -- buildings + objects only, see-through materials (glass) allowed, players/vehicles ignored
    local clear = isLineOfSightClear(startX, startY, startZ, hitX, hitY, hitZ, true, false, false, true, false, true, false, localPlayer)
    if not clear then wallShots = wallShots + 1 end
end)

local function onRender()
    frames = frames + 1
    local now = getTickCount()
    if now - fpsTick >= 1000 then
        fps = frames
        frames = 0
        fpsTick = now
    end
end

function Telemetry.start()
    Telemetry.stop()
    local cfg = SentinelClient.config
    if not cfg then return end
    telemetryTimer = setTimer(Telemetry.tick, cfg.telemetryInterval, 0)
    heartbeatTimer = setTimer(Telemetry.heartbeat, cfg.heartbeatInterval, 0)
    if cfg.sendFPS and not renderHooked then
        renderHooked = addEventHandler("onClientRender", root, onRender) == true
    end
end

function Telemetry.stop()
    if telemetryTimer and isTimer(telemetryTimer) then killTimer(telemetryTimer) end
    if heartbeatTimer and isTimer(heartbeatTimer) then killTimer(heartbeatTimer) end
    telemetryTimer, heartbeatTimer = nil, nil
    if renderHooked then
        removeEventHandler("onClientRender", root, onRender)
        renderHooked = false
    end
end

function Telemetry.isRunning()
    return telemetryTimer ~= nil and isTimer(telemetryTimer)
end

function Telemetry.tick()
    if not SentinelClient.ready then return end
    local x, y, z = getElementPosition(localPlayer)
    local vx, vy, vz = getElementVelocity(localPlayer)
    local vehicle = getPedOccupiedVehicle(localPlayer)

    local payload = {
        x = x, y = y, z = z,
        vz = vz,
        onGround = isPedOnGround(localPlayer),
        inWater = isElementInWater(localPlayer),
        dead = isPedDead(localPlayer),
        ground = ClientMovement.groundDistance(x, y, z),
        task = ClientMovement.currentTask(),
    }
    -- optional APIs: availability differs between MTA builds, never assume they exist
    if type(getGameSpeed) == "function" then payload.gameSpeed = getGameSpeed() end
    if type(getGravity) == "function" then payload.gravity = getGravity() end
    if type(getPedGravity) == "function" then payload.pedGravity = getPedGravity(localPlayer) end
    if type(getElementCollisionsEnabled) == "function" then payload.collisions = getElementCollisionsEnabled(localPlayer) end
    local hits, moved = ClientMovement.consumeNoClipHits()
    if hits > 0 then
        payload.noclipHits = hits
        payload.noclipMoved = moved
    end
    if vehicle then
        payload.vehGround = ClientMovement.vehicleGroundDistance(vehicle)
    end
    if wallShots > 0 then
        payload.wallShots = wallShots
        wallShots = 0
    end
    if SentinelClient.config.sendFPS then
        payload.fps = fps
    end
    SentinelClient.send("SentinelAC:server:telemetry", payload)
end

function Telemetry.heartbeat()
    if not SentinelClient.ready then return end
    SentinelClient.send("SentinelAC:server:heartbeat", {})
end
