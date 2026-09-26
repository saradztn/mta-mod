--[[
    SentinelAC :: client/main.lua
    Client helper layer. Nothing here is trusted by the server; it only supplies telemetry that
    the server cross-checks against its own view. Never freezes, crashes or inspects the player's machine.
]]

SentinelClient = { config = nil, token = nil, seq = 0, ready = false }

function SentinelClient.nextSeq()
    SentinelClient.seq = SentinelClient.seq + 1
    return SentinelClient.seq
end

function SentinelClient.send(eventName, payload)
    if not SentinelClient.token then return false end
    payload = payload or {}
    payload.token = SentinelClient.token
    payload.seq = SentinelClient.nextSeq()
    payload.tick = getTickCount()
    triggerServerEvent(eventName, localPlayer, payload)
    return true
end

local function stopAll()
    if Telemetry and Telemetry.stop then Telemetry.stop() end
    if Integrity and Integrity.stop then Integrity.stop() end
    if ClientMovement and ClientMovement.stop then ClientMovement.stop() end
end

addEvent("SentinelAC:client:init", true)
addEventHandler("SentinelAC:client:init", resourceRoot, function(data)
    if type(data) ~= "table" or type(data.token) ~= "string" then return end
    SentinelClient.config = {
        telemetryInterval = math.max(500, tonumber(data.telemetryInterval) or 1000),
        heartbeatInterval = math.max(2000, tonumber(data.heartbeatInterval) or 5000),
        noclipRay = data.noclipRay ~= false,
        sendFPS = data.sendFPS ~= false,
    }
    SentinelClient.token = data.token
    SentinelClient.ready = true
    ClientMovement.start()
    Telemetry.start()
    Integrity.start()
    SentinelClient.send("SentinelAC:server:ready", {})
end)

addEvent("SentinelAC:client:token", true)
addEventHandler("SentinelAC:client:token", resourceRoot, function(token)
    if type(token) ~= "string" then return end
    SentinelClient.token = token
end)

addEvent("SentinelAC:client:warn", true)
addEventHandler("SentinelAC:client:warn", resourceRoot, function(detection)
    outputChatBox("[SentinelAC] Warning: abnormal activity detected (" .. tostring(detection) .. ").", 255, 150, 0)
end)

addEventHandler("onClientResourceStart", resourceRoot, function()
    SentinelClient.seq = 0
    triggerServerEvent("SentinelAC:server:hello", localPlayer)
end)

addEventHandler("onClientResourceStop", resourceRoot, function()
    stopAll()
    SentinelClient.ready = false
end)
