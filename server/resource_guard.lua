--[[
    SentinelAC :: server/resource_guard.lua
    Resource trust list + resource guard/watchdog (server-side only).

    Honesty note: MTA does not expose WHO stopped a resource. We log the stop, correlate it with
    /stop /restart commands seen shortly before (reported as *possible* initiators, unconfirmed),
    and track clean vs. unclean shutdowns with a state file. A stopped resource cannot restart
    itself; RestartPolicy only applies to other critical resources listed in the config.
]]

Trust         = {}
ResourceGuard = {}

local STATE_FILE = "logs/state.dat"
local recentCommands = {}
local restartCounts = {}
local watchdogTimer = nil
local selfResource = getThisResource()
local selfName = getResourceName(selfResource)

-- ------------------------------------------------------------------ trust
function Trust.isTrusted(resourceOrName)
    local name
    if type(resourceOrName) == "string" then
        name = resourceOrName
    elseif resourceOrName then
        name = getResourceName(resourceOrName)
    end
    if not name then return false end
    if name == selfName then return true end
    if not Config.TrustedResources[name] then return false end
    if Config.Trust.RequireACLGroup then
        for _, groupName in ipairs(Config.Trust.ACLGroups or {}) do
            local group = aclGetGroup(groupName)
            if group and isObjectInACLGroup("resource." .. name, group) then
                return true
            end
        end
        return false
    end
    return true
end

function Trust.add(name)
    if type(name) ~= "string" or name == "" then return false end
    Config.TrustedResources[name] = true
    Logger.info("Trusted resource added at runtime", { resource = name })
    return true
end

-- ------------------------------------------------------------------ state file
local function writeState(text)
    local f
    if fileExists(STATE_FILE) then
        f = fileOpen(STATE_FILE)
        if f then
            fileClose(f)
            fileDelete(STATE_FILE)
        end
    end
    f = fileCreate(STATE_FILE)
    if not f then return false end
    fileWrite(f, text)
    fileFlush(f)
    fileClose(f)
    return true
end

local function readState()
    if not fileExists(STATE_FILE) then return nil end
    local f = fileOpen(STATE_FILE, true)
    if not f then return nil end
    local size = fileGetSize(f) or 0
    local content = size > 0 and fileRead(f, size) or ""
    fileClose(f)
    return content
end

-- ------------------------------------------------------------------ command correlation
local function pruneCommands(now)
    local kept = {}
    for _, c in ipairs(recentCommands) do
        if now - c.tick <= (Config.ResourceGuard.CommandCorrelationWindow or 3000) then kept[#kept + 1] = c end
    end
    recentCommands = kept
end

local function possibleInitiators(now)
    pruneCommands(now)
    if #recentCommands == 0 then return "none observed (MTA does not expose the initiator)" end
    local parts = {}
    for _, c in ipairs(recentCommands) do
        parts[#parts + 1] = string.format("%s(/%s, %dms ago)", c.name, c.cmd, now - c.tick)
    end
    return "UNCONFIRMED: " .. table.concat(parts, "; ")
end

addEventHandler("onPlayerCommand", root, function(command)
    if command == "stop" or command == "restart" or command == "start" or command == "refresh" or command == "refreshall" then
        local now = getTickCount()
        pruneCommands(now)
        recentCommands[#recentCommands + 1] = { name = getPlayerName(source), serial = getPlayerSerial(source), cmd = command, tick = now }
    end
end)

-- ------------------------------------------------------------------ restart policy for critical resources
local function isCritical(name)
    for _, n in ipairs(Config.ResourceGuard.CriticalResources or {}) do
        if n == name then return true end
    end
    return false
end

local function tryRestart(name)
    local rg = Config.ResourceGuard
    if rg.RestartPolicy ~= "CRITICAL_ONLY" then return end
    local now = getTickCount()
    local rec = restartCounts[name]
    if not rec or now - rec.windowStart > (rg.RestartWindow or 600000) then
        rec = { windowStart = now, count = 0 }
        restartCounts[name] = rec
    end
    if rec.count >= (rg.MaxRestarts or 3) then
        Logger.critical("Restart limit reached for critical resource, giving up to avoid a loop", { resource = name, restarts = rec.count })
        return
    end
    rec.count = rec.count + 1
    setTimer(function(resName)
        local res = getResourceFromName(resName)
        if res and getResourceState(res) ~= "running" and getResourceState(res) ~= "starting" then
            local ok = startResource(res)
            Logger.warning("Critical resource restart attempted", { resource = resName, success = ok == true })
            if not ok then
                Logger.warning("startResource failed: check that sentinel_ac has 'function.startResource' (aclrequest)", { resource = resName })
            end
        end
    end, 2000, 1, name)
end

-- ------------------------------------------------------------------ resource events
addEventHandler("onResourceStop", root, function(stoppedResource)
    local rg = Config.ResourceGuard
    if not rg.Enabled then return end
    local name = getResourceName(stoppedResource)
    local now = getTickCount()

    if stoppedResource == selfResource then
        -- handled by ResourceGuard.onSelfStop(), called from main.lua before the logger closes
        return
    end

    if Trust.isTrusted(name) or isCritical(name) then
        if rg.LogUnexpectedStop then
            Logger.warning("Trusted/critical resource stopped", { resource = name, possibleInitiators = possibleInitiators(now) })
        end
        if rg.NotifyAdmins then Notifications.broadcast("Resource '" .. name .. "' stopped. " .. possibleInitiators(now)) end
        if isCritical(name) then tryRestart(name) end
    end
end)

addEventHandler("onResourceStart", root, function(startedResource)
    if startedResource == selfResource then return end
    local rg = Config.ResourceGuard
    if not rg.Enabled or not rg.DetectUnauthorizedRestart then return end
    local name = getResourceName(startedResource)
    if Trust.isTrusted(name) or isCritical(name) then
        Logger.info("Trusted/critical resource started", { resource = name, possibleInitiators = possibleInitiators(getTickCount()) })
    end
end)

-- ------------------------------------------------------------------ watchdog
function ResourceGuard.watchdogTick()
    if not Config.ResourceGuard.Enabled then return end
    -- self-heal internal timers (a runtime error in a callback can kill a timer)
    if Config.Enabled and not Movement.isRunning() then
        Logger.warning("Watchdog: movement sampler was not running, restarting it")
        Movement.start()
    end
    -- critical resources must be running
    for _, name in ipairs(Config.ResourceGuard.CriticalResources or {}) do
        local res = getResourceFromName(name)
        if res and getResourceState(res) ~= "running" then
            Logger.warning("Watchdog: critical resource not running", { resource = name, state = getResourceState(res) })
            tryRestart(name)
        end
    end
end

function ResourceGuard.init()
    local rg = Config.ResourceGuard
    if not rg.Enabled then return end
    local previous = readState()
    if previous == "running" then
        Logger.warning("Previous SentinelAC session did not shut down cleanly (server crash, kill or forced restart)")
    elseif previous == "stopped" and rg.DetectUnauthorizedRestart then
        Logger.info("SentinelAC (re)started", { possibleInitiators = possibleInitiators(getTickCount()) })
    end
    writeState("running")
    if watchdogTimer and isTimer(watchdogTimer) then killTimer(watchdogTimer) end
    watchdogTimer = setTimer(ResourceGuard.watchdogTick, rg.WatchdogInterval or 60000, 0)
    Logger.info("Resource guard active", {
        restartPolicy = rg.RestartPolicy, critical = #(rg.CriticalResources or {}), trusted = Util.tableCount(Config.TrustedResources),
    })
end

-- Called from main.lua (resourceRoot handler runs before root handlers and before Logger.shutdown()).
function ResourceGuard.onSelfStop()
    local rg = Config.ResourceGuard
    if not rg.Enabled then return end
    local now = getTickCount()
    local initiators = possibleInitiators(now)
    if rg.LogUnexpectedStop then
        Logger.critical("SentinelAC is stopping", {
            possibleInitiators = initiators,
            players = #getElementsByType("player"),
        })
    end
    if rg.NotifyAdmins then
        Notifications.broadcast("Anti-cheat is stopping. Initiator: " .. initiators)
    end
    writeState("stopped")
end

function ResourceGuard.shutdown()
    if watchdogTimer and isTimer(watchdogTimer) then killTimer(watchdogTimer) end
    watchdogTimer = nil
end
