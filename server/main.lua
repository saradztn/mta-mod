--[[
    SentinelAC :: server/main.lua
    Lifecycle, exported API, /ac admin commands.
]]

SentinelAC = {}
local API = {}
local commandRegistered = false

-- ------------------------------------------------------------------ API helpers
function API.callerName()
    local res = sourceResource
    if res then return getResourceName(res) end
    return "internal"
end

function API.allowed(fnName)
    local res = sourceResource
    if not res then return true end
    if Config.Trust.APIRequireTrustedCaller and not Trust.isTrusted(res) then
        Logger.warning("API call rejected: caller is not a trusted resource", { fn = fnName, caller = getResourceName(res) })
        return false
    end
    return true
end

-- ------------------------------------------------------------------ exported API
function allowMovement(player, duration, reason)
    if not API.allowed("allowMovement") then return false end
    if not Util.isPlayer(player) then return false end
    if not Config.Exemptions.CustomScriptMovement then
        Logger.debug("allowMovement ignored (Exemptions.CustomScriptMovement = false)", { caller = API.callerName() })
        return false
    end
    duration = tonumber(duration) or Config.GracePeriods.ScriptedTeleport
    if duration > 60000 then duration = 60000 end
    if duration < 0 then duration = 0 end
    return PlayerState.addGrace(player, duration, tostring(reason or "scripted movement") .. " [" .. API.callerName() .. "]")
end

function registerTeleport(player, reason)
    return allowMovement(player, Config.GracePeriods.ScriptedTeleport, reason or "scripted teleport")
end

function setExempt(player, detection, duration)
    if not API.allowed("setExempt") then return false end
    if not Util.isPlayer(player) then return false end
    local ok = PlayerState.setExempt(player, detection or "ALL", tonumber(duration))
    Logger.info("Exemption set", { player = getPlayerName(player), detection = detection or "ALL", duration = duration or "permanent", caller = API.callerName() })
    return ok
end

function removeExempt(player, detection)
    if not API.allowed("removeExempt") then return false end
    if not Util.isPlayer(player) then return false end
    Logger.info("Exemption removed", { player = getPlayerName(player), detection = detection or "ALL", caller = API.callerName() })
    return PlayerState.removeExempt(player, detection or "ALL")
end

function isPlayerExempt(player, detection)
    if not Util.isPlayer(player) then return false end
    return PlayerState.isExempt(player, detection) or PlayerState.isAdminCached(player)
end

function getSuspicion(player)
    if not Util.isPlayer(player) then return 0, "Low" end
    local score = Suspicion.get(player)
    return score, Suspicion.getLevel(score)
end

function resetSuspicion(player)
    if not API.allowed("resetSuspicion") then return false end
    if not Util.isPlayer(player) then return false end
    Logger.info("Suspicion reset", { player = getPlayerName(player), caller = API.callerName() })
    return Suspicion.reset(player)
end

function isProtected()
    return Config.Enabled == true and Movement.isRunning()
end

function addTrustedResource(name)
    local res = sourceResource
    if res and not Trust.isTrusted(res) then
        Logger.warning("addTrustedResource rejected: only trusted resources may extend trust", { caller = getResourceName(res), target = tostring(name) })
        return false
    end
    return Trust.add(name)
end

function isTrustedResource(name)
    return Trust.isTrusted(name)
end

function registerJetpack(player, allowed)
    if not API.allowed("registerJetpack") then return false end
    local st = PlayerState.getOrCreate(player)
    if not st then return false end
    st.jetpackAllowed = allowed ~= false
    Logger.debug("Jetpack registration", { player = getPlayerName(player), allowed = st.jetpackAllowed, caller = API.callerName() })
    return true
end

function getSessionToken(player)
    if not API.allowed("getSessionToken") then return nil end
    if not Util.isPlayer(player) then return nil end
    return Session.get(player)
end

function validateRequest(player, token, seq, clientTick)
    if not Util.isPlayer(player) then return false, "invalid-player" end
    return Session.validate(player, token, seq, clientTick)
end

function guardEvent(player, eventName, options)
    if type(options) ~= "table" then options = {} end
    options.resource = API.callerName()
    return EventGuard.check(player, tostring(eventName or "unknown"), options)
end

function getPlayerEvidence(player)
    if not API.allowed("getPlayerEvidence") then return {} end
    if not Util.isPlayer(player) then return {} end
    return Evidence.get(player)
end

function getPlayerReport(player)
    if not Util.isPlayer(player) then return nil end
    local st = PlayerState.get(player)
    if not st then return nil end
    local inGrace, graceReason = PlayerState.isInGrace(player)
    local exempt = {}
    for k in pairs(st.exempt) do exempt[#exempt + 1] = k end
    return {
        name = getPlayerName(player),
        score = st.suspicion.score,
        level = Suspicion.getLevel(st.suspicion.score),
        detections = st.suspicion.detections,
        detectionCount = st.suspicion.count,
        state = st.state,
        inGrace = inGrace,
        graceReason = graceReason,
        exempt = exempt,
        admin = PlayerState.isAdminCached(player),
        telemetryReady = st.telemetry.ready,
        telemetryAgeMs = st.telemetry.ready and (getTickCount() - st.telemetry.lastTick) or nil,
        flyScore = st.flyScore,
        warnings = st.punishment.warnings,
        ping = getPlayerPing(player),
        evidenceEntries = #st.evidence,
    }
end

-- internal aliases
SentinelAC.allowMovement      = allowMovement
SentinelAC.registerTeleport   = registerTeleport
SentinelAC.setExempt          = setExempt
SentinelAC.removeExempt       = removeExempt
SentinelAC.getSuspicion       = getSuspicion
SentinelAC.resetSuspicion     = resetSuspicion
SentinelAC.isProtected        = isProtected
SentinelAC.addTrustedResource = addTrustedResource
SentinelAC.registerJetpack    = registerJetpack
SentinelAC.guardEvent         = guardEvent
SentinelAC.getPlayerReport    = getPlayerReport

-- ------------------------------------------------------------------ commands
local function hasCommandPermission(player)
    if hasObjectPermissionTo(player, Config.Commands.ACLRight or "command.ac", false) then return true end
    return PlayerState.isInACLGroups(player, Config.Exemptions.AdminGroups)
end

local function findPlayer(name)
    if type(name) ~= "string" or name == "" then return nil, "missing name" end
    local exact = getPlayerFromName(name)
    if exact then return exact end
    local lower = string.lower(name)
    local found = nil
    for _, p in ipairs(getElementsByType("player")) do
        if string.find(string.lower(getPlayerName(p)), lower, 1, true) then
            if found then return nil, "ambiguous name" end
            found = p
        end
    end
    if not found then return nil, "player not found" end
    return found
end

local function reply(player, msg, r, g, b)
    outputChatBox(Config.Prefix .. " " .. msg, player, r or 180, g or 200, b or 255)
end

local function enabledDetections()
    local list = {}
    for name, d in pairs(Config.Detection) do
        if d.Enabled ~= false then list[#list + 1] = name end
    end
    table.sort(list)
    return list
end

local function cmdStatus(player)
    reply(player, string.format("Enabled: %s | Mode: %s | Debug: %s | Sampler: %s (%dms, jitter %.2f)",
        tostring(Config.Enabled), Config.Mode, tostring(Config.Debug), Movement.isRunning() and "running" or "STOPPED",
        Config.Sampling.Interval, ServerHealth.jitter or 1))
    reply(player, "Tracked players: " .. PlayerState.count() .. " | Detections: " .. table.concat(enabledDetections(), ", "))
    local top = {}
    PlayerState.each(function(p, st)
        if st.suspicion.score > 0 then top[#top + 1] = { name = getPlayerName(p), score = st.suspicion.score } end
    end)
    table.sort(top, function(a, b) return a.score > b.score end)
    if #top == 0 then
        reply(player, "No player currently has a suspicion score.")
    else
        local parts = {}
        for i = 1, math.min(5, #top) do parts[#parts + 1] = top[i].name .. "=" .. top[i].score end
        reply(player, "Top suspicion: " .. table.concat(parts, ", "))
    end
end

local function cmdPlayer(player, target)
    local r = getPlayerReport(target)
    if not r then reply(player, "No state for that player.", 255, 150, 0) return end
    local det = {}
    for k, v in pairs(r.detections) do det[#det + 1] = k .. "x" .. v end
    reply(player, string.format("%s | Score %d (%s) | State %s | Grace %s%s | Admin %s | Ping %d",
        r.name, r.score, r.level, r.state, tostring(r.inGrace), r.graceReason and (":" .. r.graceReason) or "", tostring(r.admin), r.ping))
    reply(player, string.format("Detections: %s | FlyScore %d | Warnings %d | Telemetry %s | Exempt: %s | Evidence %d",
        #det > 0 and table.concat(det, ", ") or "none", r.flyScore, r.warnings,
        r.telemetryReady and ("ok(" .. math.floor((r.telemetryAgeMs or 0) / 1000) .. "s)") or "none",
        #r.exempt > 0 and table.concat(r.exempt, ",") or "none", r.evidenceEntries))
end

local function cmdEvidence(player, target)
    local list = Evidence.get(target)
    if #list == 0 then reply(player, "No evidence stored for " .. getPlayerName(target)) return end
    for i, e in ipairs(list) do
        reply(player, string.format("#%d %s | %s | %s | score %d | %d samples", i, e.time, e.detection, tostring(e.reason), e.score or 0, #e.samples))
        if i >= 3 then break end
    end
    reply(player, "Full sample data is written to " .. Config.Logging.FileName)
end

local function commandHandler(player, cmd, sub, a1, a2, a3)
    if not Config.Commands.Enabled then return end
    if not hasCommandPermission(player) then
        reply(player, "Access denied.", 255, 80, 80)
        Logger.warning("Unauthorised /" .. cmd .. " attempt", Logger.playerIdentity(player))
        return
    end
    sub = string.lower(sub or "help")
    local admin = Logger.playerIdentity(player)

    if sub == "status" then
        cmdStatus(player)

    elseif sub == "reload" then
        admin.command = "reload"
        Logger.warning("Config reload requested (resource restart)", admin)
        reply(player, "Restarting " .. getResourceName(getThisResource()) .. " to reload config.lua ...")
        if not restartResource(getThisResource()) then
            reply(player, "restartResource failed: grant 'function.restartResource' to this resource (aclrequest).", 255, 80, 80)
        end

    elseif sub == "debug" then
        Config.Debug = not Config.Debug
        Logger.setDebug(Config.Debug)
        admin.debug = Config.Debug
        Logger.info("Debug toggled", admin)
        reply(player, "Debug logging: " .. (Config.Debug and "ON" or "OFF"))

    elseif sub == "mode" then
        local ok, err = Config.applyMode(a1)
        if ok then
            if Config.Mode == "DEBUG" then Logger.setDebug(true) end
            admin.mode = Config.Mode
            Logger.warning("Mode changed at runtime (use /ac reload for a clean preset)", admin)
            reply(player, "Mode applied: " .. Config.Mode .. " (merged over current values; /ac reload for a clean apply)")
        else
            reply(player, "Error: " .. tostring(err) .. ". Presets: SAFE, BALANCED, STRICT, DEBUG", 255, 150, 0)
        end

    elseif sub == "player" or sub == "reset" or sub == "exempt" or sub == "unexempt" or sub == "evidence" then
        local target, err = findPlayer(a1)
        if not target then reply(player, "Error: " .. tostring(err), 255, 150, 0) return end
        admin.target = getPlayerName(target)
        admin.command = sub
        if sub == "player" then
            cmdPlayer(player, target)
        elseif sub == "reset" then
            Suspicion.reset(target)
            Logger.info("Suspicion reset by admin", admin)
            reply(player, "Suspicion reset for " .. getPlayerName(target))
        elseif sub == "exempt" then
            local detection = a2 or "ALL"
            local seconds = tonumber(a3)
            PlayerState.setExempt(target, detection, seconds and seconds * 1000 or nil)
            admin.detection = detection
            admin.seconds = seconds or "permanent(session)"
            Logger.info("Exemption set by admin", admin)
            reply(player, string.format("%s exempted from %s %s", getPlayerName(target), detection, seconds and ("for " .. seconds .. "s") or "until disconnect"))
        elseif sub == "unexempt" then
            local detection = a2 or "ALL"
            PlayerState.removeExempt(target, detection)
            admin.detection = detection
            Logger.info("Exemption removed by admin", admin)
            reply(player, string.format("Exemption %s removed for %s", detection, getPlayerName(target)))
        elseif sub == "evidence" then
            cmdEvidence(player, target)
        end

    elseif sub == "scan" then
        local s = Scanner.scanAll()
        Firewall.hookAll()
        admin.command = "scan"
        Logger.info("Manual scan by admin", admin)
        reply(player, string.format("Scanned %d resources | scripts: client %d, server %d, shared %d | compiled %d | unreadable %d | errors %d",
            s.resources, s.client, s.server, s.shared, s.compiled, s.unreadable, s.errors))
        reply(player, string.format("Remote events %d | client-triggered %d | dynamic triggers %d | firewall hooked %d",
            s.remoteEvents, s.clientTriggers, s.dynamic, Util.tableCount(Firewall.hooked)))
        if not s.fileAccess then
            reply(player, "No file access: grant 'general.ModifyOtherObjects' to resource." .. getResourceName(getThisResource()), 255, 150, 0)
        end
        if #s.exposed > 0 then
            local shown = {}
            for i = 1, math.min(8, #s.exposed) do shown[i] = s.exposed[i] end
            reply(player, string.format("Attack surface (%d remote events with no client caller): %s%s", #s.exposed,
                table.concat(shown, ", "), #s.exposed > 8 and " ..." or ""), 255, 200, 120)
        end

    elseif sub == "events" then
        local info = a1 and Scanner.resources[a1]
        if not info then reply(player, "Unknown or unscanned resource. Usage: /ac events <resource>", 255, 150, 0) return end
        local remote, triggers = {}, {}
        for ev in pairs(info.remoteEvents) do remote[#remote + 1] = ev .. (Firewall.hooked[ev] and "*" or "") end
        for ev in pairs(info.clientTriggers) do triggers[#triggers + 1] = ev end
        table.sort(remote) table.sort(triggers)
        reply(player, string.format("%s [%s] scripts c/s/sh %d/%d/%d compiled %d unreadable %d dynamic %d%s",
            info.name, info.state, info.counts.client, info.counts.server, info.counts.shared, info.compiled, info.unreadable,
            info.dynamicTrigger, info.error and (" ERROR: " .. info.error) or ""))
        reply(player, "Remote events (* = hooked): " .. (#remote > 0 and table.concat(remote, ", ") or "none"))
        reply(player, "Client triggers: " .. (#triggers > 0 and table.concat(triggers, ", ") or "none"))

    elseif sub == "firewall" then
        local action = string.lower(a1 or "status")
        if action == "learn" or action == "enforce" then
            Firewall.setMode(action)
            admin.mode = string.upper(action)
            Logger.warning("Firewall mode set by admin", admin)
            reply(player, "Firewall mode: " .. Firewall.mode)
        elseif action == "save" then
            Firewall.save(true)
            reply(player, "Firewall baseline saved.")
        else
            local fs = Firewall.status()
            reply(player, string.format("Firewall: mode %s | hooked events %d | learned events %d | dynamic triggers in scan %d | unsaved %s",
                fs.mode, fs.hooked, fs.learned, fs.dynamicTriggers, tostring(fs.dirty)))
        end

    elseif sub == "instrument" then
        local action = string.lower(a1 or "status")
        admin.command = "instrument " .. action
        if action == "apply" then
            if a2 then
                local result, detail = Instrument.apply(a2)
                Logger.warning("Instrument apply by admin", admin)
                reply(player, string.format("%s: %s%s", a2, result, detail and (" (" .. detail .. ")") or ""))
                if result == "instrumented" or result == "updated" then reply(player, "Restart '" .. a2 .. "' to load the new canary (or /ac instrument apply for all with auto restart).") end
            else
                local s = Instrument.applyAll(true)
                Logger.warning("Instrument apply-all by admin", admin)
                reply(player, string.format("Instrumented %d new, %d already, %d errors. Restarting %d running resources.",
                    s.instrumented, s.already, s.errors, #s.changed))
                if #s.details > 0 then reply(player, "Errors: " .. table.concat(s.details, "; "), 255, 150, 0) end
            end
        elseif action == "unzip" then
            Logger.warning("Zip conversion by admin", admin)
            if a2 then
                local ok, detail = Instrument.convertZip(a2)
                reply(player, a2 .. ": " .. (ok and "converted" or "failed") .. " (" .. tostring(detail) .. ")")
            else
                local z = Instrument.convertAllZips()
                reply(player, string.format("Converted %d zip resources, %d failed.", z.converted, z.failed))
                if #z.details > 0 then reply(player, "Errors: " .. table.concat(z.details, "; "), 255, 150, 0) end
            end
        elseif action == "remove" then
            Logger.warning("Instrument remove by admin", admin)
            if a2 then
                reply(player, a2 .. ": " .. (Instrument.remove(a2) and "restored" or "failed"))
            else
                reply(player, "Restored " .. Instrument.removeAll() .. " resources. Restart them to unload the canary.")
            end
        else
            local is = Instrument.status()
            reply(player, string.format("Instrumentation: enabled %s | auto %s | instrumented %d (running %d) | zips left %d | unloadable folders %d | file access %s",
                tostring(Config.Instrument.Enabled), tostring(Config.Instrument.AutoInstrument), is.instrumented, is.running, is.zips, is.unloadable, tostring(Scanner.hasFileAccess())))
        end

    elseif sub == "trust" then
        if Trust.add(a1) then
            admin.resource = a1
            Logger.info("Trusted resource added by admin (runtime only)", admin)
            reply(player, "Resource '" .. a1 .. "' trusted until restart. Add it to Config.TrustedResources to persist.")
        else
            reply(player, "Usage: /ac trust <resourceName>", 255, 150, 0)
        end

    else
        reply(player, "/ac status | reload | debug | mode <SAFE|BALANCED|STRICT|DEBUG> | player <name> | reset <name>")
        reply(player, "/ac exempt <name> [detection|ALL] [seconds] | unexempt <name> [detection|ALL] | evidence <name> | trust <resource>")
        reply(player, "/ac scan | events <resource> | firewall status|learn|enforce|save | instrument status|apply|remove|unzip [resource]")
    end
end

-- ------------------------------------------------------------------ lifecycle
addEventHandler("onResourceStart", resourceRoot, function()
    local rt = getRealTime()
    math.randomseed(getTickCount() + (rt.timestamp or 0))

    local ok, err = Config.applyMode(Config.Mode)
    Logger.init()
    if not ok then Logger.warning("Preset not applied", { error = err }) end
    if Config.Mode == "DEBUG" then Logger.setDebug(true) end

    -- players already online (resource restart): fresh state + grace, client will re-hello
    for _, p in ipairs(getElementsByType("player")) do
        local st = PlayerState.getOrCreate(p)
        st.joinTick = getTickCount()
        PlayerState.addGrace(p, Config.GracePeriods.Join, "resource start")
    end

    Session.start()
    Suspicion.start()
    Telemetry.start()
    Movement.start()
    ResourceGuard.init()
    Scanner.scanAll()
    Firewall.start()
    Instrument.init()

    if Config.Commands.Enabled and not commandRegistered then
        commandRegistered = addCommandHandler(Config.Commands.Name or "ac", commandHandler, false, false) == true
    end

    Logger.info("SentinelAC started", {
        resource = getResourceName(getThisResource()), mode = Config.Mode, enabled = Config.Enabled,
        detections = table.concat(enabledDetections(), ","), players = #getElementsByType("player"),
    })
    outputServerLog("[SentinelAC] Ready. Mode=" .. Config.Mode .. ". Use /ac status.")
end)

addEventHandler("onResourceStop", resourceRoot, function()
    ResourceGuard.onSelfStop()
    Movement.stop()
    Suspicion.stop()
    Telemetry.stop()
    Session.stop()
    Firewall.stop()
    Instrument.shutdown()
    ResourceGuard.shutdown()
    Logger.info("SentinelAC stopped")
    Logger.shutdown()
end)
