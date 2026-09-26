--[[
    SentinelAC :: server/punishment.lua
    Action resolution (detection action vs. score level), server-allowed actions, ban safeguards,
    duplicate/cooldown protection and deferred kicks.
]]

Punishment = {}
Punishment.ORDER = { NONE = 0, LOG = 1, WARN = 2, FREEZE = 3, KICK = 4, BAN = 5 }

local DOWNGRADE = { BAN = "KICK", KICK = "FREEZE", FREEZE = "WARN", WARN = "LOG", LOG = "LOG", NONE = "NONE" }

local function normalise(action)
    action = string.upper(tostring(action or "LOG"))
    if Punishment.ORDER[action] == nil then return "LOG" end
    return action
end

function Punishment.isAllowed(action)
    local allowed = Config.Punishment.Actions
    if action == "WARN"   then return allowed.Warn   == true end
    if action == "FREEZE" then return allowed.Freeze == true end
    if action == "KICK"   then return allowed.Kick   == true end
    if action == "BAN"    then return allowed.Ban    == true end
    return true -- NONE / LOG always allowed
end

-- Resolve the action for a detection given the player's current score/level.
function Punishment.resolve(detection, score, level, st)
    if not Config.Punishment.Enabled or Config.Mode == "DEBUG" then
        return "LOG"
    end
    local dcfg = Config.Detection[detection]
    local detectionAction = normalise(dcfg and dcfg.Action or Config.Punishment.DefaultAction)
    local levelAction     = normalise(Config.Punishment.ScoreActions[level] or "NONE")

    local action = detectionAction
    if Punishment.ORDER[levelAction] > Punishment.ORDER[action] then
        action = levelAction
    end

    -- BAN safeguards: never from a single weak detection
    if action == "BAN" then
        if score < (Config.Punishment.MinScoreForBan or 120) then action = "KICK" end
        if Config.Punishment.RequireMultipleDetectionsForBan and st and st.suspicion.count < 2 then action = "KICK" end
    end

    -- cap by what the server allows
    while Punishment.ORDER[action] > Punishment.ORDER.LOG and not Punishment.isAllowed(action) do
        action = DOWNGRADE[action]
    end
    return action
end

local function messageFor(action, detection)
    local p = Config.Punishment
    if action == "WARN"   then return p.WarnMessage end
    if action == "FREEZE" then return p.FreezeMessage end
    if action == "KICK"   then return p.KickMessage .. " (" .. tostring(detection) .. ")" end
    if action == "BAN"    then return p.BanMessage .. " (" .. tostring(detection) .. ")" end
    return ""
end

function Punishment.apply(player, action, detection, reason, score)
    if not Util.isPlayer(player) then return "NONE" end
    local st = PlayerState.get(player)
    if not st then return "NONE" end
    action = normalise(action)
    if action == "NONE" or action == "LOG" then return action end

    local now = getTickCount()
    if st.punishment.pending then
        return "PENDING"
    end
    local last = st.punishment.last[action]
    if last and now - last < (Config.Punishment.Cooldown or 5000) then
        return "COOLDOWN"
    end
    st.punishment.last[action] = now

    local identity = Logger.playerIdentity(player)
    identity.action = action
    identity.detection = detection
    identity.reason = reason
    identity.score = score

    if action == "WARN" then
        st.punishment.warnings = st.punishment.warnings + 1
        outputChatBox(messageFor("WARN", detection), player, 255, 150, 0)
        triggerClientEvent(player, "SentinelAC:client:warn", resourceRoot, tostring(detection))
        identity.warnings = st.punishment.warnings
        Logger.warning("Punishment applied", identity)
        if st.punishment.warnings >= (Config.Punishment.MaxWarningsBeforeKick or 3) and Punishment.isAllowed("KICK") then
            st.punishment.warnings = 0
            st.punishment.last["KICK"] = nil
            return Punishment.apply(player, "KICK", detection, "warning limit reached: " .. tostring(reason), score)
        end
        return "WARN"

    elseif action == "FREEZE" then
        setElementFrozen(player, true)
        outputChatBox(messageFor("FREEZE", detection), player, 255, 100, 0)
        setTimer(function(p)
            if isElement(p) then setElementFrozen(p, false) end
        end, Config.Punishment.FreezeDuration or 10000, 1, player)
        Logger.warning("Punishment applied", identity)
        return "FREEZE"

    elseif action == "KICK" then
        st.punishment.pending = true
        Logger.warning("Punishment applied", identity)
        setTimer(function(p, msg)
            if isElement(p) then kickPlayer(p, msg) end
        end, 100, 1, player, messageFor("KICK", detection))
        return "KICK"

    elseif action == "BAN" then
        st.punishment.pending = true
        Logger.critical("Punishment applied", identity)
        setTimer(function(p, msg)
            if isElement(p) then
                banPlayer(p, Config.Punishment.BanByIP == true, false, Config.Punishment.BanBySerial ~= false, nil, msg, Config.Punishment.BanDuration or 0)
            end
        end, 100, 1, player, messageFor("BAN", detection))
        return "BAN"
    end
    return "NONE"
end

-- Entry point used by Suspicion.add(): decide + apply.
function Punishment.handle(player, detection, score, level, reason)
    local st = PlayerState.get(player)
    local action = Punishment.resolve(detection, score, level, st)
    if action == "NONE" or action == "LOG" then return action end
    return Punishment.apply(player, action, detection, reason, score)
end
