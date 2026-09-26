--[[
    SentinelAC :: client/movement.lua
    Local movement helpers: ground distance, ped task classification and a two-way ray check that
    counts crossings through solid world geometry. Counts are reported, the server decides.
]]

ClientMovement = {}

local rayTimer = nil
local lastX, lastY, lastZ = nil, nil, nil
local lastInterior, lastDimension = nil, nil
local hits = 0
local moved = 0

function ClientMovement.start()
    ClientMovement.stop()
    lastX = nil
    rayTimer = setTimer(ClientMovement.rayTick, 250, 0)
end

function ClientMovement.stop()
    if rayTimer and isTimer(rayTimer) then killTimer(rayTimer) end
    rayTimer = nil
end

function ClientMovement.isRunning()
    return rayTimer ~= nil and isTimer(rayTimer)
end

function ClientMovement.consumeNoClipHits()
    local h, m = hits, moved
    hits, moved = 0, 0
    return h, m
end

function ClientMovement.groundDistance(x, y, z)
    local gz = getGroundPosition(x, y, z)
    if type(gz) ~= "number" then return nil end
    return z - gz
end

function ClientMovement.vehicleGroundDistance(vehicle)
    if not isElement(vehicle) then return nil end
    local x, y, z = getElementPosition(vehicle)
    return ClientMovement.groundDistance(x, y, z)
end

function ClientMovement.currentTask()
    if isPedDoingTask(localPlayer, "TASK_SIMPLE_JETPACK") then return "jetpack" end
    if getPedWeapon(localPlayer) == 46 and not isPedOnGround(localPlayer) then return "parachute" end
    if isPedDoingTask(localPlayer, "TASK_COMPLEX_IN_WATER") then return "swim" end
    if isPedDoingTask(localPlayer, "TASK_SIMPLE_CLIMB") then return "climb" end
    if isPedDoingTask(localPlayer, "TASK_COMPLEX_FALL_AND_GET_UP") or isPedDoingTask(localPlayer, "TASK_SIMPLE_FALL") then return "fall" end
    if isPedDoingTask(localPlayer, "TASK_SIMPLE_IN_AIR") then return "air" end
    if isPedOnGround(localPlayer) then return "ground" end
    return "unknown"
end

local function blocked(x1, y1, z1, x2, y2, z2)
    -- buildings + objects only; vehicles, peds and dummies are ignored so doors of cars etc. never count
    local hit = processLineOfSight(x1, y1, z1, x2, y2, z2, true, false, false, true, false, false, false, false, localPlayer)
    return hit == true
end

function ClientMovement.rayTick()
    local cfg = SentinelClient.config
    if not cfg or not cfg.noclipRay then return end
    if isPedDead(localPlayer) or getPedOccupiedVehicle(localPlayer) or isElementFrozen(localPlayer) or isElementAttached(localPlayer) then
        lastX = nil
        return
    end
    local x, y, z = getElementPosition(localPlayer)
    local interior = getElementInterior(localPlayer)
    local dimension = getElementDimension(localPlayer)

    if lastX and lastInterior == interior and lastDimension == dimension then
        local dist = getDistanceBetweenPoints3D(lastX, lastY, lastZ, x, y, z)
        -- ignore micro movement and large jumps (teleports / lag corrections are the server's business)
        if dist > 0.75 and dist < 40 then
            -- both directions must be blocked: rules out standing next to a wall or a door swinging open
            if blocked(lastX, lastY, lastZ + 0.5, x, y, z + 0.5) and blocked(x, y, z + 0.5, lastX, lastY, lastZ + 0.5) then
                hits = hits + 1
                moved = moved + dist
            end
        end
    end
    lastX, lastY, lastZ = x, y, z
    lastInterior, lastDimension = interior, dimension
end
