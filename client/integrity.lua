--[[
    SentinelAC :: client/integrity.lua
    Self-check of the client helper layer. Restarts its own timers if they died and reports the fact.
    Interruptions are reported as weak signals only; the server never punishes on this alone.
]]

Integrity = {}

local timer = nil

function Integrity.start()
    Integrity.stop()
    timer = setTimer(Integrity.tick, 15000, 0)
end

function Integrity.stop()
    if timer and isTimer(timer) then killTimer(timer) end
    timer = nil
end

function Integrity.isRunning()
    return timer ~= nil and isTimer(timer)
end

function Integrity.tick()
    if not SentinelClient.ready then return end
    local payload = {
        telemetryRestarted = false,
        rayRestarted = false,
        frozen = isElementFrozen(localPlayer),
    }
    if type(getElementCollisionsEnabled) == "function" then payload.collisions = getElementCollisionsEnabled(localPlayer) end
    if type(getFPSLimit) == "function" then payload.fpsLimit = getFPSLimit() end
    if not Telemetry.isRunning() then
        Telemetry.start()
        payload.telemetryRestarted = true
    end
    if SentinelClient.config and SentinelClient.config.noclipRay and not ClientMovement.isRunning() then
        ClientMovement.start()
        payload.rayRestarted = true
    end
    if type(getDevelopmentMode) == "function" then
        payload.devMode = getDevelopmentMode() == true
    end
    SentinelClient.send("SentinelAC:server:integrity", payload)
end
