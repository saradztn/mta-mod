--[[
    SentinelAC :: server/scanner.lua
    Static resource scanner. Reads every resource's meta.xml, classifies scripts (client / server / shared),
    and extracts a static fingerprint from readable Lua sources:
        - server events registered with addEvent(name, true)   -> remotely triggerable (attack surface)
        - events the CLIENT code actually triggers (triggerServerEvent / triggerLatentServerEvent)
        - event handlers, client-side events, dynamic (unresolvable) names, compiled files
    Requires ACL right 'general.ModifyOtherObjects' for this resource to read other resources' files.
    Nothing is ever written to other resources.
]]

Scanner = {
    resources = {},
    globalClientTriggers = {},   -- [event] = { resourceName, ... }
    globalRemoteEvents = {},     -- [event] = owner resource
    dynamicTriggerCount = 0,
    lastScan = 0,
    lastSummary = nil,
}

local selfName = getResourceName(getThisResource())
local LUAC_HEADER = string.char(27) .. "Lua"

-- level-1 long brackets: the patterns themselves contain "]]" inside character classes
local PAT_ADDEVENT      = [=[addEvent%s*%(%s*(["'])(.-)%1%s*([^%)]*)%)]=]
local PAT_ADDEVENT_DYN  = [=[addEvent%s*%(%s*([%a_][%w_%.%[%]]*)]=]
local PAT_TRIGGER       = [=[trigger[%a]*ServerEvent%s*%(%s*(["'])(.-)%1]=]
local PAT_TRIGGER_DYN   = [=[trigger[%a]*ServerEvent%s*%(%s*([%a_][%w_%.%[%]]*)%s*[,%)]]=]
local PAT_HANDLER       = [=[addEventHandler%s*%(%s*(["'])(.-)%1]=]

local function isIgnored(name)
    for _, n in ipairs(Config.Scanner.IgnoredResources or {}) do
        if n == name then return true end
    end
    return false
end

local function readResourceFile(resName, path)
    local full = ":" .. resName .. "/" .. path
    if not fileExists(full) then return nil, "missing" end
    local handle = fileOpen(full, true)
    if not handle then return nil, "no-access" end
    local size = fileGetSize(handle) or 0
    if size > (Config.Scanner.MaxFileKB or 2048) * 1024 then
        fileClose(handle)
        return nil, "too-large"
    end
    local content = ""
    if size > 0 then content = fileRead(handle, size) or "" end
    fileClose(handle)
    return content
end

local function stripComments(content)
    content = string.gsub(content, "%-%-%[%[.-%]%]", "")
    content = string.gsub(content, "%-%-[^\n]*", "")
    return content
end

local function extract(content, info, side)
    content = stripComments(content)

    for _, name, rest in string.gmatch(content, PAT_ADDEVENT) do
        local remote = string.find(rest, "true", 1, true) ~= nil
        if side ~= "client" then
            if remote then info.remoteEvents[name] = true else info.localServerEvents[name] = true end
        end
        if side ~= "server" then
            info.clientEvents[name] = true
        end
    end
    for _ in string.gmatch(content, PAT_ADDEVENT_DYN) do
        info.dynamicAddEvent = info.dynamicAddEvent + 1
    end

    if side ~= "server" then
        for _, name in string.gmatch(content, PAT_TRIGGER) do
            info.clientTriggers[name] = true
        end
        for _ in string.gmatch(content, PAT_TRIGGER_DYN) do
            info.dynamicTrigger = info.dynamicTrigger + 1
        end
        -- which sensitive functions does this resource's client code call at all?
        local padded = " " .. content
        for _, fn in ipairs((Config.Instrument and Config.Instrument.WrappedFunctions) or {}) do
            local count = 0
            for _ in string.gmatch(padded, "[^%w_]" .. fn .. "%s*%(") do count = count + 1 end
            if count > 0 then info.clientCalls[fn] = (info.clientCalls[fn] or 0) + count end
        end
    end

    for _, name in string.gmatch(content, PAT_HANDLER) do
        info.handlers[name] = true
    end
end

function Scanner.hasFileAccess()
    return hasObjectPermissionTo(getThisResource(), "general.ModifyOtherObjects", false) == true
end

function Scanner.scanResource(res)
    local name = getResourceName(res)
    local info = {
        name = name,
        state = getResourceState(res),
        scripts = {},
        counts = { client = 0, server = 0, shared = 0 },
        remoteEvents = {}, localServerEvents = {}, clientEvents = {}, clientTriggers = {}, handlers = {},
        clientCalls = {},
        dynamicAddEvent = 0, dynamicTrigger = 0, compiled = 0, unreadable = 0,
        scannedAt = getTickCount(), error = nil,
    }

    local meta = xmlLoadFile(":" .. name .. "/meta.xml", true)
    if not meta then
        info.error = "meta.xml unreadable (missing ACL right general.ModifyOtherObjects?)"
        Scanner.resources[name] = info
        return info
    end

    for _, node in ipairs(xmlNodeGetChildren(meta)) do
        if xmlNodeGetName(node) == "script" then
            local src = xmlNodeGetAttribute(node, "src")
            local stype = string.lower(xmlNodeGetAttribute(node, "type") or "server")
            if stype ~= "client" and stype ~= "shared" then stype = "server" end
            local isCanary = Config.Instrument and src == Config.Instrument.CanaryFile
            if src and src ~= "" and not isCanary then
                info.counts[stype] = info.counts[stype] + 1
                local entry = { src = src, type = stype, compiled = false, size = 0 }
                local content, err = readResourceFile(name, src)
                if not content then
                    entry.error = err
                    info.unreadable = info.unreadable + 1
                else
                    entry.size = #content
                    if string.sub(content, 1, 4) == LUAC_HEADER then
                        entry.compiled = true
                        info.compiled = info.compiled + 1
                    else
                        extract(content, info, stype)
                    end
                end
                info.scripts[#info.scripts + 1] = entry
            end
        end
    end
    xmlUnloadFile(meta)

    Scanner.resources[name] = info
    return info
end

function Scanner.rebuildIndex()
    Scanner.globalClientTriggers = {}
    Scanner.globalRemoteEvents = {}
    Scanner.dynamicTriggerCount = 0
    for name, info in pairs(Scanner.resources) do
        for ev in pairs(info.clientTriggers) do
            local list = Scanner.globalClientTriggers[ev] or {}
            list[#list + 1] = name
            Scanner.globalClientTriggers[ev] = list
        end
        for ev in pairs(info.remoteEvents) do
            Scanner.globalRemoteEvents[ev] = name
        end
        Scanner.dynamicTriggerCount = Scanner.dynamicTriggerCount + info.dynamicTrigger
    end
end

function Scanner.isClientTriggered(eventName)
    return Scanner.globalClientTriggers[eventName] ~= nil
end

function Scanner.exposedEvents()
    local list = {}
    for ev, owner in pairs(Scanner.globalRemoteEvents) do
        if not Scanner.globalClientTriggers[ev] and string.sub(ev, 1, 11) ~= "SentinelAC:" then
            list[#list + 1] = ev .. "@" .. owner
        end
    end
    table.sort(list)
    return list
end

function Scanner.scanAll()
    local summary = {
        resources = 0, client = 0, server = 0, shared = 0, compiled = 0, unreadable = 0,
        remoteEvents = 0, clientTriggers = 0, dynamic = 0, errors = 0, exposed = {},
        fileAccess = Scanner.hasFileAccess(),
    }
    if not Config.Scanner.Enabled then
        Scanner.lastSummary = summary
        return summary
    end

    Scanner.resources = {}
    for _, res in ipairs(getResources()) do
        local name = getResourceName(res)
        -- folders without meta.xml show up as "failed to load" resources: never scanned, never written to
        local loadable = getResourceState(res) ~= "failed to load" and fileExists(":" .. name .. "/meta.xml")
        if name ~= selfName and not isIgnored(name) and loadable then
            local info = Scanner.scanResource(res)
            summary.resources = summary.resources + 1
            summary.client = summary.client + info.counts.client
            summary.server = summary.server + info.counts.server
            summary.shared = summary.shared + info.counts.shared
            summary.compiled = summary.compiled + info.compiled
            summary.unreadable = summary.unreadable + info.unreadable
            summary.dynamic = summary.dynamic + info.dynamicTrigger
            if info.error then summary.errors = summary.errors + 1 end
        end
    end
    Scanner.rebuildIndex()
    summary.remoteEvents = Util.tableCount(Scanner.globalRemoteEvents)
    summary.clientTriggers = Util.tableCount(Scanner.globalClientTriggers)
    summary.exposed = Scanner.exposedEvents()
    Scanner.lastScan = getTickCount()
    Scanner.lastSummary = summary

    Logger.info("Static scan complete", {
        resources = summary.resources, client = summary.client, server = summary.server, shared = summary.shared,
        compiled = summary.compiled, unreadable = summary.unreadable, errors = summary.errors,
        remoteEvents = summary.remoteEvents, clientTriggers = summary.clientTriggers, dynamicTriggers = summary.dynamic,
        fileAccess = summary.fileAccess,
    })
    if not summary.fileAccess then
        Logger.warning("Scanner has no file access to other resources. Grant 'general.ModifyOtherObjects' to resource." .. selfName .. " (read-only use).")
    end
    if Config.Scanner.ReportExposedEvents and #summary.exposed > 0 then
        Logger.warning("Remote-triggerable server events with no client caller anywhere (attack surface)", {
            count = #summary.exposed, events = table.concat(summary.exposed, ", "),
        })
    end
    return summary
end

-- keep the index fresh when resources start/stop
addEventHandler("onResourceStart", root, function(startedResource)
    if startedResource == getThisResource() then return end
    if not Config.Scanner.Enabled then return end
    local name = getResourceName(startedResource)
    if isIgnored(name) then return end
    if not fileExists(":" .. name .. "/meta.xml") then return end
    Scanner.scanResource(startedResource)
    Scanner.rebuildIndex()
    if Firewall and Firewall.hookResource then Firewall.hookResource(name) end
end)

addEventHandler("onResourceStop", root, function(stoppedResource)
    if stoppedResource == getThisResource() then return end
    local name = getResourceName(stoppedResource)
    local info = Scanner.resources[name]
    if info then info.state = "loaded" end
    if Firewall and Firewall.unhookResource then Firewall.unhookResource(name) end
end)
