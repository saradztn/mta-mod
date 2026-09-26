--[[
    SentinelAC :: server/instrument.lua
    Automatic per-resource instrumentation.

    For every resource (except this one and Config.Instrument.IgnoredResources):
        - meta.xml is backed up to meta.xml.sentinel.bak (once)
        - <script src="sentinel_canary.lua" type="client" cache="false"/> is inserted as the FIRST script
        - templates/canary.lua is rendered and written into the resource
    The canary runs first in that resource's client VM and reports calls that come from foreign code or
    use triggers/functions the resource never uses. When Config.Instrument.BlockInjectCalls is on, the
    canary BLOCKS such calls before they execute (an injected triggerServerEvent never leaves the client,
    so the server never runs it). The server re-validates non-blocked reports against the static scan and
    raises an Injection detection (Action KICK by default); blocked reports are trusted as confirmed.

    Everything is reversible with /ac instrument remove. Requires ACL 'general.ModifyOtherObjects'.
]]

Instrument = { state = {}, lastRun = nil }

local selfName = getResourceName(getThisResource())
local watchTimer = nil
local restartGuard = {}
local canaryCache = nil

-- ------------------------------------------------------------------ file helpers
local function readText(path)
    if not fileExists(path) then return nil end
    local f = fileOpen(path, true)
    if not f then return nil end
    local size = fileGetSize(f) or 0
    local text = size > 0 and (fileRead(f, size) or "") or ""
    fileClose(f)
    return text
end

local function writeText(path, text)
    if fileExists(path) then
        if not fileDelete(path) then return false end
    end
    local f = fileCreate(path)
    if not f then return false end
    fileWrite(f, text)
    fileFlush(f)
    fileClose(f)
    return true
end

local function escapePattern(s)
    return (string.gsub(s, "%p", "%%%0"))
end

local function isIgnored(name)
    if name == selfName then return true end
    for _, n in ipairs(Config.Instrument.IgnoredResources or {}) do
        if n == name then return true end
    end
    for _, n in ipairs(Config.Scanner.IgnoredResources or {}) do
        if n == name then return true end
    end
    return false
end

local function normalise(s)
    if type(s) ~= "string" then return "?" end
    s = string.lower(s)
    s = string.gsub(s, "\\", "/")
    if string.sub(s, 1, 1) == "@" then s = string.sub(s, 2) end
    return s
end

-- A real, loadable resource: not "failed to load" and has a readable meta.xml. Anything else is never written to.
local function isLoadable(res)
    if not res then return false end
    if getResourceState(res) == "failed to load" then return false end
    return fileExists(":" .. getResourceName(res) .. "/meta.xml") == true
end

local function isArchived(res)
    if type(isResourceArchived) == "function" then
        return isResourceArchived(res) == true
    end
    return false
end

Instrument.isLoadable = isLoadable
Instrument.isArchived = isArchived

-- ------------------------------------------------------------------ zip -> folder conversion
local META_FILE_TAGS = { script = true, file = true, map = true, config = true, html = true }

local function listResourceFiles(resName)
    local files, seen = { "meta.xml" }, { ["meta.xml"] = true }
    local meta = xmlLoadFile(":" .. resName .. "/meta.xml", true)
    if not meta then return nil end
    for _, node in ipairs(xmlNodeGetChildren(meta)) do
        if META_FILE_TAGS[xmlNodeGetName(node)] then
            local src = xmlNodeGetAttribute(node, "src")
            if src and src ~= "" and not seen[src] then
                seen[src] = true
                files[#files + 1] = src
            end
        end
    end
    xmlUnloadFile(meta)
    return files
end

local function copyFile(fromPath, toPath)
    local src = fileOpen(fromPath, true)
    if not src then return false, "cannot open " .. fromPath end
    if fileExists(toPath) then fileDelete(toPath) end
    local dst = fileCreate(toPath)
    if not dst then
        fileClose(src)
        return false, "cannot create " .. toPath
    end
    local size = fileGetSize(src) or 0
    local copied = 0
    while copied < size do
        local chunk = fileRead(src, math.min(524288, size - copied))
        if not chunk or #chunk == 0 then break end
        fileWrite(dst, chunk)
        copied = copied + #chunk
    end
    fileFlush(dst)
    fileClose(dst)
    fileClose(src)
    return copied == size, copied .. "/" .. size .. " bytes"
end

-- Copies every file listed in meta.xml into a new folder resource, moves the original zip to
-- resources-cache/trash (deleteResource never erases permanently) and renames the folder to the original name.
function Instrument.convertZip(resName)
    local res = getResourceFromName(resName)
    if not res then return false, "unknown resource" end
    if resName == selfName then return false, "cannot convert self" end
    if not isLoadable(res) then return false, "not a loadable resource" end
    if not isArchived(res) then return false, "not a zip archive" end
    if type(createResource) ~= "function" or type(deleteResource) ~= "function" or type(renameResource) ~= "function" then
        return false, "server build lacks createResource/deleteResource/renameResource"
    end

    local files = listResourceFiles(resName)
    if not files then return false, "meta.xml unreadable" end
    local wasRunning = getResourceState(res) == "running"
    local orgPath = getResourceOrganizationalPath(res)
    if orgPath == "" then orgPath = nil end
    local tmpName = resName .. "_sentinelunzip"

    local existing = getResourceFromName(tmpName)
    if existing then
        if getResourceState(existing) == "running" then stopResource(existing) end
        deleteResource(tmpName)
    end

    local tmp = createResource(tmpName, orgPath)
    if not tmp then return false, "createResource failed (ACL function.createResource?)" end

    for _, f in ipairs(files) do
        local ok, detail = copyFile(":" .. resName .. "/" .. f, ":" .. tmpName .. "/" .. f)
        if not ok then
            deleteResource(tmpName)
            return false, "copy failed for '" .. f .. "' (" .. tostring(detail) .. "), original untouched"
        end
    end

    if wasRunning then stopResource(res) end
    if not deleteResource(resName) then
        deleteResource(tmpName)
        return false, "deleteResource failed (ACL function.deleteResource? resource still running?)"
    end
    if not renameResource(tmpName, resName, orgPath) then
        return false, "renameResource failed: converted folder left as '" .. tmpName .. "', original zip in resources-cache/trash"
    end
    if type(refreshResources) == "function" then refreshResources(true) end
    if wasRunning then
        setTimer(function(name)
            local r = getResourceFromName(name)
            if r and getResourceState(r) ~= "running" then startResource(r) end
        end, 1500, 1, resName)
    end
    Logger.warning("Zip resource converted to folder", {
        resource = resName, files = #files, wasRunning = wasRunning, originalZip = "moved to resources-cache/trash",
        note = "files not listed in meta.xml are not copied; recover them from the trash zip if needed",
    })
    return true, #files .. " files copied"
end

function Instrument.convertAllZips()
    local summary = { converted = 0, failed = 0, details = {} }
    for _, res in ipairs(getResources()) do
        local name = getResourceName(res)
        if not isIgnored(name) and isLoadable(res) and isArchived(res) then
            local ok, detail = Instrument.convertZip(name)
            if ok then
                summary.converted = summary.converted + 1
            else
                summary.failed = summary.failed + 1
                summary.details[#summary.details + 1] = name .. ": " .. tostring(detail)
            end
        end
    end
    if summary.converted > 0 or summary.failed > 0 then
        Logger.info("Zip conversion pass", { converted = summary.converted, failed = summary.failed, details = table.concat(summary.details, "; ") })
    end
    return summary
end

-- ------------------------------------------------------------------ canary rendering
function Instrument.canarySource()
    if canaryCache then return canaryCache end
    local template = readText("templates/canary.lua")
    if not template then
        Logger.critical("templates/canary.lua missing inside sentinel_ac")
        return nil
    end
    local wrapped = {}
    for _, fn in ipairs(Config.Instrument.WrappedFunctions or {}) do
        wrapped[#wrapped + 1] = string.format("%q", fn)
    end
    local map = {
        __AC_RESOURCE__ = selfName,
        __CANARY_FILE__ = Config.Instrument.CanaryFile,
        __HEARTBEAT__   = tostring(Config.Instrument.HeartbeatInterval or 15000),
        __WRAPPED__     = table.concat(wrapped, ", "),
    }
    canaryCache = string.gsub(template, "__[%u_]-__", function(key) return map[key] or key end)
    return canaryCache
end

-- ------------------------------------------------------------------ meta.xml editing helpers
local function insertCanaryLine(text, line)
    local patterns = { "(<meta>)", "(<meta%s[^>]*>)", "(<[Mm][Ee][Tt][Aa][^>]*>)" }
    for _, pattern in ipairs(patterns) do
        local newText, n = string.gsub(text, pattern, function(tag) return tag .. "\n    " .. line end, 1)
        if n > 0 then return newText end
    end
    return nil
end

-- delete+create first; if the file cannot be deleted, overwrite in place (new text is always longer)
local function overwriteText(path, text)
    if writeText(path, text) then return true, "rewrite" end
    local f = fileOpen(path, false)
    if f then
        fileSetPos(f, 0)
        fileWrite(f, text)
        fileFlush(f)
        fileClose(f)
        return true, "overwrite-in-place"
    end
    return false, "no write access"
end

-- last resort: append a <script> node through the XML API (loads last instead of first)
local function appendViaXml(resName, cfg)
    local meta = xmlLoadFile(":" .. resName .. "/meta.xml")
    if not meta then return false end
    local node = xmlCreateChild(meta, "script")
    if not node then
        xmlUnloadFile(meta)
        return false
    end
    xmlNodeSetAttribute(node, "src", cfg.CanaryFile)
    xmlNodeSetAttribute(node, "type", "client")
    xmlNodeSetAttribute(node, "cache", "false")
    local ok = xmlSaveFile(meta)
    xmlUnloadFile(meta)
    return ok == true
end

-- ------------------------------------------------------------------ apply / remove
function Instrument.isInstrumented(resName)
    local text = readText(":" .. resName .. "/meta.xml")
    if not text then return false end
    return string.find(text, Config.Instrument.CanaryFile, 1, true) ~= nil
end

-- returns "instrumented" | "already" | "skipped" | "error", detail
function Instrument.apply(resName)
    local cfg = Config.Instrument
    local metaPath   = ":" .. resName .. "/meta.xml"
    local canaryPath = ":" .. resName .. "/" .. cfg.CanaryFile

    local res = getResourceFromName(resName)
    if not res then return "error", "unknown resource" end
    if not isLoadable(res) then
        return "skipped", "not a loadable resource (no meta.xml / failed to load) - nothing written"
    end
    if isArchived(res) then
        return "skipped", "zip archive - never modified in place (Config.Instrument.ConvertZip converts it to a folder)"
    end

    local text = readText(metaPath)
    if not text then return "error", "meta.xml unreadable (ACL general.ModifyOtherObjects?)" end

    local canary = Instrument.canarySource()
    if not canary then return "error", "canary template missing" end

    -- already referenced by meta.xml: keep the canary file current ("updated" => resource needs a restart)
    if string.find(text, cfg.CanaryFile, 1, true) then
        Instrument.state[resName] = true
        if readText(canaryPath) ~= canary then
            if not writeText(canaryPath, canary) then return "error", "cannot update canary file" end
            Logger.info("Canary updated to current template", { resource = resName })
            return "updated"
        end
        return "already"
    end

    -- 1) backup (required)
    local bak = metaPath .. ".sentinel.bak"
    if not fileExists(bak) and not writeText(bak, text) then
        return "error", "cannot write backup " .. bak
    end

    -- 2) modify meta.xml FIRST (the canary is useless unless meta.xml loads it)
    local line = string.format('<script src="%s" type="client" cache="false" />', cfg.CanaryFile)
    local method = nil
    local newText = insertCanaryLine(text, line)
    if newText then
        local ok, how = overwriteText(metaPath, newText)
        if ok then method = how end
    end
    if not method and appendViaXml(resName, cfg) then
        method = "xml-append (loads last)"
    end
    if not method then
        return "error", "could not modify meta.xml (write denied or no <meta> tag)"
    end

    -- 3) verify by re-reading
    local check = readText(metaPath)
    if not check or not string.find(check, cfg.CanaryFile, 1, true) then
        return "error", "meta.xml verification failed after write (method " .. method .. ")"
    end

    -- 4) write the canary; roll meta.xml back if that fails so the resource stays consistent
    if not writeText(canaryPath, canary) then
        if not writeText(metaPath, text) then
            Logger.critical("Canary write failed AND meta.xml rollback failed - restore manually from backup", { resource = resName, backup = bak })
        end
        return "error", "cannot write canary file; meta.xml rolled back"
    end

    Instrument.state[resName] = true
    Logger.info("Resource instrumented", { resource = resName, method = method, backup = bak })
    return "instrumented"
end

function Instrument.remove(resName)
    local cfg = Config.Instrument
    local metaPath   = ":" .. resName .. "/meta.xml"
    local canaryPath = ":" .. resName .. "/" .. cfg.CanaryFile
    local bak = metaPath .. ".sentinel.bak"
    local ok = true
    if fileExists(bak) then
        local original = readText(bak)
        if original and writeText(metaPath, original) then
            fileDelete(bak)
        else
            ok = false
        end
    else
        local text = readText(metaPath)
        if text then
            local stripped = string.gsub(text, "%s*<script[^>]*" .. escapePattern(cfg.CanaryFile) .. "[^>]*/>", "", 1)
            if stripped ~= text and not writeText(metaPath, stripped) then ok = false end
        end
    end
    if fileExists(canaryPath) then fileDelete(canaryPath) end
    Instrument.state[resName] = nil
    Logger.info("Resource instrumentation removed", { resource = resName, success = ok })
    return ok
end

local function guardedRestart(resName)
    local now = getTickCount()
    local last = restartGuard[resName]
    if last and now - last < 600000 then
        Logger.warning("Instrument: restart suppressed (already restarted recently)", { resource = resName })
        return
    end
    restartGuard[resName] = now
    setTimer(function(name)
        local res = getResourceFromName(name)
        if res and getResourceState(res) == "running" then
            local ok = restartResource(res)
            Logger.warning("Instrument: resource restarted to load canary", { resource = name, success = ok == true })
        end
    end, 1500, 1, resName)
end

function Instrument.applyAll(restartChanged)
    local summary = { instrumented = 0, already = 0, skipped = 0, errors = 0, changed = {}, details = {} }
    for _, res in ipairs(getResources()) do
        local name = getResourceName(res)
        if not isIgnored(name) then
            local result, detail = Instrument.apply(name)
            if result == "instrumented" or result == "updated" then
                summary.instrumented = summary.instrumented + 1
                if getResourceState(res) == "running" then summary.changed[#summary.changed + 1] = name end
            elseif result == "already" then
                summary.already = summary.already + 1
            elseif result == "skipped" then
                summary.skipped = summary.skipped + 1
                Logger.debug("Instrument skipped", { resource = name, reason = detail })
            else
                summary.errors = summary.errors + 1
                summary.details[#summary.details + 1] = name .. ": " .. tostring(detail)
            end
        end
    end
    Instrument.lastRun = summary
    Logger.info("Instrumentation pass", {
        instrumented = summary.instrumented, already = summary.already, skipped = summary.skipped, errors = summary.errors,
        changedRunning = #summary.changed,
    })
    if summary.errors > 0 then
        Logger.warning("Instrumentation errors (resources left untouched or rolled back)", { details = table.concat(summary.details, "; ") })
    end
    if #summary.changed > 0 then
        if type(refreshResources) == "function" then refreshResources(true) end
        if restartChanged then
            for _, name in ipairs(summary.changed) do guardedRestart(name) end
        else
            Logger.warning("Instrumented running resources need a restart to load the canary", { resources = table.concat(summary.changed, ", ") })
        end
    end
    return summary
end

function Instrument.removeAll()
    local n = 0
    for _, res in ipairs(getResources()) do
        local name = getResourceName(res)
        if not isIgnored(name) and isLoadable(res) and not isArchived(res) and Instrument.isInstrumented(name) then
            if Instrument.remove(name) then n = n + 1 end
        end
    end
    if type(refreshResources) == "function" then refreshResources(true) end
    return n
end

-- ------------------------------------------------------------------ server-side validation of canary reports
local function fileMatches(info, src)
    src = normalise(src)
    if src == normalise(Config.Instrument.CanaryFile) then return true end
    for _, s in ipairs(info.scripts) do
        if s.type ~= "server" then
            local f = normalise(s.src)
            if src == f or string.sub(src, -(#f + 1)) == "/" .. f then return true end
        end
    end
    return false
end

-- returns confirmed(bool), weak(bool)
function Instrument.confirm(info, item)
    local cfg = Config.Instrument
    local k = item.k
    if k == "unknown-source" then
        if type(item.s) ~= "string" then return false, false end
        local s = normalise(item.s)
        -- pseudo frames are never evidence (tail calls, C frames, unknown): guards against canary bugs
        if s == "?" or s == "=?" or string.find(s, "tail call", 1, true) or string.find(s, "[c]", 1, true) then
            return false, false
        end
        if info.clientCalls.loadstring or info.clientCalls.dofile or info.clientCalls.loadfile then
            return false, true          -- resource legitimately loads external code chunks
        end
        if info.compiled > 0 and not cfg.StrictCompiled then return false, true end
        if fileMatches(info, item.s) then return false, false end
        return true, false
    elseif k == "trigger-not-in-resource" then
        if info.compiled > 0 then return false, true end
        return type(item.n) == "string" and not info.clientTriggers[item.n] and info.dynamicTrigger == 0, false
    elseif k == "function-not-in-resource" then
        if info.compiled > 0 then return false, true end
        return type(item.f) == "string" and not info.clientCalls[item.f], false
    elseif k == "loadstring-not-in-resource" then
        if info.compiled > 0 then return false, true end
        return not info.clientCalls.loadstring, false
    end
    return false, false
end

addEvent("SentinelAC:server:canaryHello", true)
addEventHandler("SentinelAC:server:canaryHello", root, function(resName)
    local player = client
    if not Util.isPlayer(player) or type(resName) ~= "string" then return end
    if not EventGuard.check(player, "SentinelAC:server:canaryHello", { source = source, maxPerSecond = 120 }) then return end
    local info = Scanner.resources[resName]
    if not info then return end
    local files = {}
    for _, s in ipairs(info.scripts) do
        if s.type ~= "server" then files[#files + 1] = s.src end
    end
    triggerClientEvent(player, "SentinelAC:canary:baseline", resourceRoot, resName, {
        files = files, triggers = info.clientTriggers, calls = info.clientCalls, dynamic = info.dynamicTrigger,
        compiled = info.compiled > 0,
        strict   = Config.Instrument.StrictCompiled == true,
        block    = Config.Instrument.BlockInjectCalls == true and Config.Detection.Injection.Enabled ~= false,
    })
    local st = PlayerState.getOrCreate(player)
    if st then st.canary[resName] = { lastTick = getTickCount(), reports = 0 } end
end)

addEvent("SentinelAC:server:canary", true)
addEventHandler("SentinelAC:server:canary", root, function(resName, payload)
    local player = client
    if not Util.isPlayer(player) or type(resName) ~= "string" or type(payload) ~= "table" then return end
    if not EventGuard.check(player, "SentinelAC:server:canary", { source = source, maxPerSecond = 120 }) then return end
    local st = PlayerState.getOrCreate(player)
    if not st then return end
    local now = getTickCount()
    local entry = st.canary[resName]
    if not entry then
        entry = { lastTick = now, reports = 0 }
        st.canary[resName] = entry
    end
    entry.lastTick = now
    entry.reported = nil

    local info = Scanner.resources[resName]
    if not info or type(payload.items) ~= "table" then return end
    local cfg = Config.Detection.Injection

    local n = 0
    for _, item in ipairs(payload.items) do
        n = n + 1
        if n > 20 then break end
        if type(item) == "table" and type(item.k) == "string" then
            entry.reports = entry.reports + 1
            -- item.blocked: the canary applied the exact same certain/weak rules as confirm() and stopped
            -- the call before it executed - treat it as confirmed (the event never ran anywhere)
            local confirmed, weak
            if item.blocked == true then
                confirmed, weak = true, false
            else
                confirmed, weak = Instrument.confirm(info, item)
            end
            local details = { resource = resName, kind = item.k, fn = tostring(item.f), event = tostring(item.n), source = tostring(item.s), blocked = item.blocked == true }
            if confirmed then
                if not PlayerState.canDetect(player, "Injection") then return end
                if now - st.firewall.lastDetect <= (cfg.Cooldown or 5000) then return end
                st.firewall.lastDetect = now
                local reason = "Injected code detected inside resource '" .. resName .. "' (" .. item.k .. ")"
                if item.blocked == true then reason = reason .. " - call BLOCKED client-side, never executed" end
                Suspicion.add(player, "Injection", reason, details)
                return
            elseif weak then
                details.player = getPlayerName(player)
                Logger.warning("Canary report could not be confirmed (compiled resource or legitimate loadstring)", details)
            else
                details.player = getPlayerName(player)
                Logger.debug("Canary report rejected by server re-validation", details)
            end
        end
    end
end)

-- ------------------------------------------------------------------ heartbeat watch
function Instrument.watchTick()
    local cfg = Config.Instrument
    if not cfg.Enabled then return end
    local now = getTickCount()
    PlayerState.each(function(player, st)
        if now - st.joinTick < 60000 then return end
        for resName, entry in pairs(st.canary) do
            local res = getResourceFromName(resName)
            if not res or getResourceState(res) ~= "running" or not Instrument.state[resName] then
                st.canary[resName] = nil
            elseif now - entry.lastTick > (cfg.HeartbeatTimeout or 60000) then
                if not entry.reported or now - entry.reported > (cfg.HeartbeatTimeout or 60000) then
                    entry.reported = now
                    local detection = cfg.KickOnMissingCanary and "Injection" or "Integrity"
                    if PlayerState.canDetect(player, detection) then
                        Suspicion.add(player, detection, "Canary inside resource '" .. resName .. "' stopped reporting", {
                            resource = resName, sinceMs = now - entry.lastTick,
                        })
                    end
                end
            end
        end
    end)
end

-- ------------------------------------------------------------------ resource events
addEventHandler("onResourceStart", root, function(startedResource)
    if startedResource == getThisResource() then return end
    local cfg = Config.Instrument
    if not cfg.Enabled or not cfg.AutoInstrument then return end
    local name = getResourceName(startedResource)
    if isIgnored(name) then return end
    if not Scanner.hasFileAccess() then return end
    if not isLoadable(startedResource) then return end
    if isArchived(startedResource) then
        if cfg.ConvertZip then
            local ok, detail = Instrument.convertZip(name)
            if not ok then Logger.warning("Zip conversion failed on start", { resource = name, reason = detail }) end
        end
        return -- the converted folder resource restarts and passes through here again as a folder
    end
    local result = Instrument.apply(name)
    if result == "instrumented" or result == "updated" then
        if type(refreshResources) == "function" then refreshResources(false, startedResource) end
        if cfg.AutoRestart then guardedRestart(name) end
    end
end)

addEventHandler("onResourceStop", root, function(stoppedResource)
    if stoppedResource == getThisResource() then return end
    local name = getResourceName(stoppedResource)
    PlayerState.each(function(player, st)
        st.canary[name] = nil
    end)
end)

-- ------------------------------------------------------------------ lifecycle
function Instrument.init()
    local cfg = Config.Instrument
    if not cfg.Enabled then
        Logger.info("Resource instrumentation disabled by config")
        return
    end
    if not Scanner.hasFileAccess() then
        Logger.warning("Instrumentation skipped: grant 'general.ModifyOtherObjects' to resource." .. selfName)
        return
    end
    if cfg.ConvertZip then
        local z = Instrument.convertAllZips()
        if z.converted > 0 then Scanner.scanAll() end
    end
    -- mark already instrumented resources
    for _, res in ipairs(getResources()) do
        local name = getResourceName(res)
        if not isIgnored(name) and isLoadable(res) and not isArchived(res) and Instrument.isInstrumented(name) then
            Instrument.state[name] = true
        end
    end
    if cfg.AutoInstrument then
        Instrument.applyAll(cfg.AutoRestart)
    end
    if watchTimer and isTimer(watchTimer) then killTimer(watchTimer) end
    watchTimer = setTimer(Instrument.watchTick, 30000, 0)
    Logger.info("Instrumentation active", { instrumented = Util.tableCount(Instrument.state), autoRestart = cfg.AutoRestart })
end

function Instrument.shutdown()
    if watchTimer and isTimer(watchTimer) then killTimer(watchTimer) end
    watchTimer = nil
end

function Instrument.status()
    local running, total, zips, unloadable = 0, 0, 0, 0
    for name in pairs(Instrument.state) do
        total = total + 1
        local res = getResourceFromName(name)
        if res and getResourceState(res) == "running" then running = running + 1 end
    end
    for _, res in ipairs(getResources()) do
        if not isLoadable(res) then unloadable = unloadable + 1
        elseif isArchived(res) then zips = zips + 1 end
    end
    return { instrumented = total, running = running, zips = zips, unloadable = unloadable, lastRun = Instrument.lastRun }
end
