--[[
    SentinelAC :: server/logger.lua
    Structured logging (console + rotating file), log levels and player context helpers.
]]

Util = {}

function Util.round(n, decimals)
    if type(n) ~= "number" then return n end
    local m = 10 ^ (decimals or 0)
    return math.floor(n * m + 0.5) / m
end

function Util.formatVec(x, y, z, decimals)
    decimals = decimals or 1
    local f = "%." .. decimals .. "f"
    return string.format(f .. "," .. f .. "," .. f, x or 0, y or 0, z or 0)
end

function Util.tableCount(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
end

function Util.isPlayer(element)
    return isElement(element) and getElementType(element) == "player"
end

-- Cheap payload size estimate (bytes) with depth/element caps; used by flood protection.
function Util.estimateSize(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "string" then return #v end
    if t == "number" or t == "boolean" then return 8 end
    if t == "table" then
        if depth >= 4 then return 64 end
        local total, n = 16, 0
        for k, val in pairs(v) do
            total = total + Util.estimateSize(k, depth + 1) + Util.estimateSize(val, depth + 1)
            n = n + 1
            if n >= 500 or total > 1048576 then break end
        end
        return total
    end
    return 8
end

Logger = {}
Logger.LEVELS = { DEBUG = 1, INFO = 2, WARNING = 3, DETECTION = 4, CRITICAL = 5 }

local fileHandle    = nil
local minLevel      = Logger.LEVELS.INFO
local flushTimer    = nil
local pendingWrites = 0

local function timestamp()
    local t = getRealTime()
    return string.format("%04d-%02d-%02d %02d:%02d:%02d",
        t.year + 1900, t.month + 1, t.monthday, t.hour, t.minute, t.second)
end

local function serialise(data)
    if type(data) ~= "table" then return "" end
    local parts = {}
    for k, v in pairs(data) do
        local vs
        if type(v) == "table" then
            vs = toJSON(v) or "{}"
        elseif type(v) == "userdata" and isElement(v) then
            vs = getElementType(v) .. ":" .. tostring(v)
        else
            vs = tostring(v)
        end
        parts[#parts + 1] = tostring(k) .. "=" .. vs
    end
    table.sort(parts)
    return table.concat(parts, " | ")
end

function Logger.openFile()
    local cfg  = Config.Logging
    local path = cfg.FileName
    if fileHandle then
        fileClose(fileHandle)
        fileHandle = nil
    end
    local handle
    if fileExists(path) then
        handle = fileOpen(path)
        if handle then
            local size = fileGetSize(handle) or 0
            if size > (cfg.MaxFileSizeKB or 4096) * 1024 then
                fileClose(handle)
                local backup = path .. ".old"
                if fileExists(backup) then fileDelete(backup) end
                fileRename(path, backup)
                handle = fileCreate(path)
            else
                fileSetPos(handle, size)
            end
        end
    else
        handle = fileCreate(path)
    end
    if not handle then
        outputServerLog("[SentinelAC] WARNING: unable to open log file '" .. tostring(path) .. "'. File logging disabled.")
        return false
    end
    fileHandle = handle
    return true
end

function Logger.init()
    local cfg = Config.Logging
    minLevel = Logger.LEVELS[cfg.Level] or Logger.LEVELS.INFO
    if Config.Debug then minLevel = Logger.LEVELS.DEBUG end
    if cfg.File then Logger.openFile() end
    if flushTimer and isTimer(flushTimer) then killTimer(flushTimer) end
    flushTimer = setTimer(Logger.flush, cfg.FlushInterval or 30000, 0)
    Logger.log("INFO", "Logger initialised", {
        level = cfg.Level, file = cfg.File and cfg.FileName or "disabled", debug = Config.Debug, mode = Config.Mode,
    })
end

function Logger.flush()
    if fileHandle and pendingWrites > 0 then
        fileFlush(fileHandle)
        pendingWrites = 0
    end
end

function Logger.shutdown()
    if flushTimer and isTimer(flushTimer) then killTimer(flushTimer) end
    flushTimer = nil
    if fileHandle then
        fileFlush(fileHandle)
        fileClose(fileHandle)
        fileHandle = nil
    end
end

function Logger.setDebug(enabled)
    if enabled then
        minLevel = Logger.LEVELS.DEBUG
    else
        minLevel = Logger.LEVELS[Config.Logging.Level] or Logger.LEVELS.INFO
    end
end

function Logger.log(level, message, data)
    local lvl = Logger.LEVELS[level]
    if not lvl then
        level = "INFO"
        lvl = Logger.LEVELS.INFO
    end
    if lvl < minLevel then return end
    local line  = string.format("[%s] [%s] %s", timestamp(), level, tostring(message))
    local extra = serialise(data)
    if extra ~= "" then line = line .. " || " .. extra end
    if Config.Logging.Console then
        outputServerLog("[SentinelAC] " .. line)
    end
    if fileHandle then
        fileWrite(fileHandle, line .. "\n")
        pendingWrites = pendingWrites + 1
        if lvl >= Logger.LEVELS.WARNING or pendingWrites >= 50 then
            fileFlush(fileHandle)
            pendingWrites = 0
        end
    end
end

function Logger.debug(message, data)     Logger.log("DEBUG", message, data) end
function Logger.info(message, data)      Logger.log("INFO", message, data) end
function Logger.warning(message, data)   Logger.log("WARNING", message, data) end
function Logger.detection(message, data) Logger.log("DETECTION", message, data) end
function Logger.critical(message, data)  Logger.log("CRITICAL", message, data) end

-- Identity: only what is needed to act on a detection (name, serial, account). No IP, no hardware data.
function Logger.playerIdentity(player)
    if not Util.isPlayer(player) then return { name = "unknown" } end
    local account = getPlayerAccount(player)
    local accountName = "guest"
    if account and not isGuestAccount(account) then
        accountName = getAccountName(account)
    end
    return {
        name    = getPlayerName(player),
        serial  = getPlayerSerial(player),
        account = accountName,
    }
end

function Logger.playerContext(player)
    local ctx = Logger.playerIdentity(player)
    if not Util.isPlayer(player) then return ctx end
    local x, y, z    = getElementPosition(player)
    local vx, vy, vz = getElementVelocity(player)
    ctx.pos       = Util.formatVec(x, y, z, 1)
    ctx.vel       = Util.formatVec(vx, vy, vz, 3)
    local vehicle = getPedOccupiedVehicle(player)
    if vehicle then
        ctx.vehicle = getVehicleName(vehicle) .. "(" .. getElementModel(vehicle) .. ")"
    else
        ctx.vehicle = "none"
    end
    ctx.interior  = getElementInterior(player)
    ctx.dimension = getElementDimension(player)
    ctx.ping      = getPlayerPing(player)
    return ctx
end
