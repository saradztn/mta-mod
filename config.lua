--[[
    SentinelAC :: config.lua  (SERVER-ONLY - this file is never sent to clients)

    Every detection is independent: set Detection.<Name>.Enabled = false to switch it off
    without touching any other file. Every detection has its own Action, thresholds,
    sample requirements and cooldown.

    Actions: "NONE" | "LOG" | "WARN" | "FREEZE" | "KICK" | "BAN"
    The action actually applied is the strongest of:
        - Detection.<Name>.Action
        - Punishment.ScoreActions[<suspicion level>]
    ...capped by Punishment.Actions (what this server allows at all) and the BAN safeguards.

    Speeds are in metres per second (m/s). Times are in milliseconds.
]]

Config = {}

Config.Enabled = true
Config.Debug   = false
Config.Mode    = "BALANCED"        -- "SAFE" | "BALANCED" | "STRICT" | "DEBUG"  (see Config.Presets)
Config.Prefix  = "[SentinelAC]"

-- ------------------------------------------------------------------ Logging
Config.Logging = {
    Console       = true,
    File          = true,
    FileName      = "logs/sentinel.log",
    MaxFileSizeKB = 4096,
    Level         = "INFO",          -- DEBUG | INFO | WARNING | DETECTION | CRITICAL
    FlushInterval = 30000,
}

-- ------------------------------------------------------------------ Sampling / performance
Config.Sampling = {
    Interval          = 500,          -- ms between sampler ticks
    MaxPlayersPerTick = 40,           -- above this, players are sampled round-robin (adaptive)
    Adaptive          = true,
}

-- ------------------------------------------------------------------ Lag compensation
Config.Lag = {
    PingSoft            = 150,        -- ping >= this  -> tolerance x ToleranceSoft
    PingHard            = 300,        -- ping >= this  -> tolerance x ToleranceHard
    ToleranceSoft       = 1.5,
    ToleranceHard       = 2.5,
    TickJitterThreshold = 1.6,        -- sampler interval drift ratio treated as server lag
    MaxDeltaTime        = 3000,       -- samples further apart than this are used as baseline only
}

-- ------------------------------------------------------------------ Grace periods (ms)
Config.GracePeriods = {
    Join             = 15000,
    Death            = 8000,
    Spawn            = 6000,
    Warp             = 3000,
    ScriptedTeleport = 3000,
    Interior         = 3000,
    Dimension        = 3000,
    VehicleEnter     = 2500,
    VehicleExit      = 3000,
    HeavyDamage      = 3000,          -- explosion / vehicle / fall damage flings players
    TelemetryStart   = 20000,         -- time a client has to start sending telemetry
    Cutscene         = 5000,
}

-- ------------------------------------------------------------------ Punishment
Config.Punishment = {
    Enabled = true,

    Actions = {                       -- what this server allows at all
        Warn   = true,
        Freeze = false,
        Kick   = true,
        Ban    = false,
    },

    DefaultAction = "LOG",

    -- escalation by suspicion level
    ScoreActions = {
        Low      = "NONE",
        Medium   = "WARN",
        High     = "KICK",
        Critical = "BAN",
    },

    MinScoreForBan                  = 120,
    RequireMultipleDetectionsForBan = true,   -- never ban from a single detection
    MaxWarningsBeforeKick           = 2,
    Cooldown                        = 5000,   -- same action not repeated within this window
    FreezeDuration                  = 10000,

    WarnMessage   = "SentinelAC: abnormal activity detected. Further violations will be punished.",
    FreezeMessage = "SentinelAC: you have been frozen temporarily.",
    KickMessage   = "SentinelAC: Suspicious activity detected.",
    BanMessage    = "SentinelAC: Banned for cheating.",
    BanDuration   = 0,                -- seconds, 0 = permanent
    BanBySerial   = true,
    BanByIP       = false,
}

-- ------------------------------------------------------------------ Suspicion score
Config.Suspicion = {
    Weights = {
        Teleport    = 35,
        Fly         = 25,
        SpeedHack   = 20,
        NoClip      = 30,
        EventAbuse  = 15,
        Explosion   = 25,
        Vehicle     = 20,
        Combat      = 20,
        Jetpack     = 15,
        Telemetry   = 10,
        Integrity   = 15,
        ElementData = 15,
        EventFirewall = 15,
        Injection   = 45,
        NativeAC    = 50,
        NativeSD    = 5,
        Flood       = 40,
        GodMode     = 30,
        Aimbot      = 25,
        AmmoHack    = 20,
        Wallhack    = 20,
    },
    Levels = { Low = 30, Medium = 60, High = 90 },   -- Low: 0-30, Medium: 31-60, High: 61-90, Critical: 91+
    MaxScore      = 200,
    DecayInterval = 10000,            -- every N ms ...
    DecayAmount   = 5,                -- ... remove this much ...
    DecayDelay    = 20000,            -- ... if no new violation for this long
}

-- ------------------------------------------------------------------ Detections
Config.Detection = {

    Teleport = {
        Enabled         = true,
        Action          = "KICK",
        Threshold       = 120,        -- minimum displacement (m) between two samples to be a candidate
        MaxLegitSpeed   = {           -- m/s per movement class; below this a jump is never a teleport
            OnFoot = 60, Automobile = 120, Bike = 120, BMX = 60, Quad = 90,
            ["Monster Truck"] = 100, Boat = 100, Plane = 260, Helicopter = 180, Train = 110, Trailer = 120,
        },
        MaxFallSpeed    = 120,        -- vertical m/s still considered a natural fall
        ConfirmRadius   = 60,         -- player must stay within this radius on the next sample (rules out sync rubber-banding)
        StrikesRequired = 1,          -- one CONFIRMED teleport is enough (confirmation = the next sample, ~0.5s)
        StrikeWindow    = 90000,
        VelocityFactor  = 3.0,        -- displacement speed vs synced velocity ratio marking an "inconsistent" jump
        Cooldown        = 3000,
    },

    Fly = {
        Enabled               = true,
        Action                = "KICK",
        EnabledForVehicles    = false,   -- vehicle fly is handled by Detection.Vehicle.ImpossibleMovement
        MinAirTime            = 3000,
        VerticalTolerance     = 3.0,     -- |dz| below this per sample = hovering
        FallVelocity          = 0.05,    -- |vz| below this = not falling
        FallAccelTolerance    = 0.02,
        AscendThreshold       = 2.5,     -- metres gained per sample without vehicle/jetpack
        AscendSamplesRequired = 3,
        HorizontalThreshold   = 6.0,     -- metres of horizontal movement per sample while airborne and not falling
        MaxAirTimeWithoutFall = 20000,
        SamplesRequired       = 3,       -- FlyScore needed before suspicion is raised (~1.5s after MinAirTime)
        ScoreDecayOnGround    = 2,
        Cooldown              = 10000,
    },

    NoClip = {
        Enabled              = true,
        Action               = "WARN",
        SamplesRequired      = 3,        -- solid-geometry crossings inside Window
        Window               = 15000,
        MaxHitsPerReport     = 2,        -- caps how much a single client report may contribute
        MinServerDisplacement= 2.0,      -- server must have seen the player actually move
        CollisionStrikes     = 3,        -- client reports collisions disabled while server says enabled
        CheckVehicles        = false,
        Cooldown             = 10000,
    },

    SpeedHack = {
        Enabled            = true,
        Action             = "KICK",
        MaxOnFootSpeed     = 20,         -- m/s horizontal (sprint is ~8 m/s; margin for slopes/lag)
        AirborneMultiplier = 1.8,        -- flung by explosions / falling off bikes
        MinDistance        = 3.0,
        SamplesRequired    = 3,          -- consecutive samples (~1.5s)
        GameSpeedTolerance = 0.05,       -- client-reported game speed vs server game speed
        GameSpeedStrikes   = 3,
        Cooldown           = 8000,
    },

    Jetpack = {
        Enabled             = true,
        Action              = "LOG",
        RequireRegistration = false,     -- true: any jetpack not registered via registerJetpack() is flagged
        Cooldown            = 60000,
    },

    Explosion = {
        Enabled                = true,
        Action                 = "LOG",
        Policy                 = "LOG",  -- "ALLOW" (no checks) | "LOG" (detect only) | "BLOCK" (cancel anomalous explosions)
        MaxRate                = 5,      -- explosions per Window per player
        Window                 = 10000,
        MaxDistance            = 350,    -- explosion further than this from its creator is anomalous
        IgnoredTypes           = { [4] = true, [5] = true, [6] = true, [7] = true, [9] = true }, -- vehicle/boat/heli/object explosions
        BlockedTypes           = {},     -- e.g. { [10] = true } to forbid tank grenades
        RequireExplosiveWeapon = true,   -- creator must hold/have recently used an explosive weapon or vehicle
        ExplosiveWeaponMemory  = 120000, -- satchels can be detonated long after being placed
        Cooldown               = 5000,
    },

    Vehicle = {
        Enabled               = true,
        Action                = "KICK",
        SpeedHack             = true,
        ImpossibleMovement    = true,
        MaxSpeed = {                      -- m/s per vehicle class (getVehicleType)
            Automobile = 95, Bike = 85, BMX = 25, Quad = 50, ["Monster Truck"] = 60,
            Boat = 65, Plane = 170, Helicopter = 120, Train = 75, Trailer = 95,
        },
        ToleranceMultiplier   = 1.3,     -- multiplied into MaxSpeed (handling mods, nitro, downhill)
        SamplesRequired       = 3,
        AscendSamplesRequired = 5,       -- consecutive ascending samples for land/sea vehicles
        AscendTotal           = 60,      -- ... and total metres climbed
        VehicleFlyGround      = 15,      -- client-reported ground distance (m) for hovering land vehicles
        VehicleFlySamples     = 6,
        Cooldown              = 8000,
    },

    Combat = {
        Enabled               = true,
        Action                = "LOG",
        FireRateCheck         = true,
        MaxShotsPerSecond = {            -- generous upper bounds (dual-wield included)
            [22] = 12, [23] = 6, [24] = 3.5, [25] = 2, [26] = 8, [27] = 5, [28] = 20, [29] = 15,
            [30] = 13, [31] = 13, [32] = 20, [33] = 1.5, [34] = 1.5, [35] = 1, [36] = 1, [38] = 45,
        },
        FireRateTolerance     = 1.5,
        FireRateWindow        = 2000,
        WeaponMismatchStrikes = 3,       -- fired weapon differs from the weapon the server knows
        BlockedWeapons        = {},      -- e.g. { [38] = true } to flag minigun usage
        RangeCheck            = true,
        RangeTolerance        = 1.5,
        MaxDamagePerHit       = 200,
        Cooldown              = 5000,
    },

    EventAbuse = {
        Enabled               = true,
        Action                = "LOG",
        RateLimit             = true,
        InvalidArguments      = true,
        InvalidSource         = true,
        MaxEventsPerSecond    = 20,      -- per player, per SentinelAC event
        CommandFloodPerSecond = 8,
        ProtectedElementData  = { "money", "admin", "adminlevel", "level", "rank", "health" }, -- client may never change these
        RevertProtectedData   = true,
        Cooldown              = 3000,
    },

    Telemetry = {
        Enabled           = true,
        Action            = "LOG",
        PositionTolerance = 25,          -- m between client-reported and server position
        StrikesRequired   = 4,
        HeartbeatTimeout  = 30000,
        RequireTelemetry  = false,       -- true: flag players whose client never reports (weak signal, LOG only recommended)
        Cooldown          = 60000,
    },

    Integrity = {
        Enabled          = true,
        Action           = "LOG",
        GravityTolerance = 0.002,
        Strikes          = 3,
        Cooldown         = 60000,
    },

    -- Global event firewall (server/event_firewall.lua). Passive handlers on every remotely
    -- triggerable event of every resource. Run in LEARN for a few days, then switch to ENFORCE.
    EventFirewall = {
        Enabled                 = true,
        Action                  = "LOG",       -- for flood / unusual signature anomalies
        Mode                    = "LEARN",     -- "LEARN" | "ENFORCE"  (also /ac firewall learn|enforce)
        PersistMode             = true,        -- keep the mode chosen with /ac firewall across restarts
        LearnMinPlayers         = 3,           -- distinct players needed before an event/signature counts as known
        RateLimit               = true,
        MaxPerSecond            = 30,          -- per player, per event
        DowngradeWhenDynamic    = true,        -- unknown event becomes a medium anomaly if the scan found dynamic event names
        FlagForeignPlayerSource = false,       -- flag events triggered with another player as `source`
        IgnoredEvents           = {},
        SaveInterval            = 120000,
        Cooldown                = 5000,
    },

    -- Strong signals of injected client code: unknown events in ENFORCE mode, canary reports,
    -- and invalid-event floods (a few invalid events are normal, see Flood.InvalidEventsMax).
    Injection = {
        Enabled  = true,
        Action   = "KICK",
        Cooldown = 5000,
    },

    -- Flood protection: element data spam / oversized data, server event spam / oversized payloads,
    -- invalid event spam. Flooding data is reverted, offender is punished with Action.
    Flood = {
        Enabled              = true,
        Action               = "KICK",
        ElementDataPerSecond = 40,        -- client-side setElementData changes per second per player
        MaxElementDataBytes  = 8192,      -- estimated size of a single element data value
        TriggersPerSecond    = 60,        -- server events triggered per second per player (all resources)
        MaxTriggerBytes      = 16384,     -- estimated size of a single event payload
        InvalidEventsMax     = 30,        -- invalid server events allowed inside InvalidEventsWindow
        InvalidEventsWindow  = 10000,
        Cooldown             = 3000,
    },

    -- God mode / health hack. Weapon hits registered on a player who takes no damage for a whole window,
    -- or health/armor above the possible maximum. Safe-zone scripts that cancel damage should call
    -- exports.sentinel_ac:setExempt(player, "GodMode", duration).
    GodMode = {
        Enabled      = true,
        Action       = "LOG",
        HitsRequired = 12,
        Window       = 20000,
        MaxHealth    = 250,
        MaxArmor     = 100,
        Cooldown     = 30000,
    },

    -- Aimbot heuristics (server-side, statistical): headshot ratio, accuracy, rapid target switching.
    -- Statistical signals: keep Action at LOG/WARN and let the score escalate.
    Aimbot = {
        Enabled          = true,
        Action           = "LOG",
        MinHits          = 25,
        HeadshotRatio    = 0.75,
        MinShots         = 50,
        AccuracyRatio    = 0.97,
        SwitchWindow     = 150,          -- ms between hits on two different players = "switch"
        SwitchesRequired = 6,
        EvaluateWindow   = 60000,
        ExcludedWeapons  = { [25] = true, [26] = true, [27] = true, [33] = true, [34] = true, [35] = true, [36] = true, [38] = true },
        Cooldown         = 60000,
    },

    -- Infinite ammo: total ammo never decreases across many consecutive shots.
    AmmoHack = {
        Enabled       = true,
        Action        = "LOG",
        ShotsRequired = 30,
        Cooldown      = 60000,
    },

    -- Wallhack helper signal (client-side line of sight at the moment of a registered hit on a player).
    -- Client data: raises suspicion only, never suppresses anything.
    Wallhack = {
        Enabled       = true,
        Action        = "LOG",
        ShotsRequired = 5,
        Window        = 60000,
        Cooldown      = 60000,
    },

    -- MTA's built-in anti-cheat reports (onPlayerACInfo). The only layer with memory-level visibility.
    -- onPlayerACInfo delivers two kinds of codes:
    --   AC codes  = actual cheat detections                       -> Detection.NativeAC (enforced)
    --   SD codes  = "special detections", environment indicators   -> Detection.NativeSD (logged only)
    --     12 custom d3d9.dll, 14 virtual machine, 15 driver signature enforcement disabled (Windows test mode),
    --     16 AC components disabled, 20 unsigned MTA, 22 debugger/cheat tool environment, 26 non-standard Windows,
    --     28 Wine, 31 injected input, 32-35 other environment checks.
    --   Put an SD code into EnforceCodes to treat it like a real AC code. Same list as <enablesd> in mtaserver.conf.
    NativeAC = {
        Enabled      = true,
        Action       = "KICK",
        SoftCodes    = { [12] = true, [14] = true, [15] = true, [16] = true, [20] = true, [22] = true, [26] = true,
                         [28] = true, [31] = true, [32] = true, [33] = true, [34] = true, [35] = true },
        EnforceCodes = {},                     -- SD codes you DO want enforced, e.g. { [22] = true }
        IgnoreCodes  = {},                     -- codes ignored completely, e.g. { [15] = true }
        LogModInfo   = true,                   -- onPlayerModInfo: log only, mods are often legitimate
    },

    -- Special detections that are not enforced: low weight, LOG only. Repeated soft codes still add up.
    NativeSD = {
        Enabled  = true,
        Action   = "LOG",
        Cooldown = 300000,
    },
}

-- ------------------------------------------------------------------ Per-resource instrumentation (in-VM canary)
-- Automatically adds sentinel_canary.lua as the first client script of every resource (backup kept as
-- meta.xml.sentinel.bak). The canary reports calls from injected code or usage of triggers/functions the
-- resource never uses; the server re-validates and raises Detection.Injection (KICK by default).
Config.Instrument = {
    Enabled             = true,
    AutoInstrument      = true,       -- instrument at start and whenever a resource starts
    AutoRestart         = true,       -- restart running resources the first time they get instrumented
    ConvertZip          = true,       -- convert .zip resources to folders (original zip moved to resources-cache/trash)
                                      -- folders without meta.xml ("failed to load") are never touched
    IgnoredResources    = {},         -- never touched, e.g. { "mapmanager" }
    CanaryFile          = "sentinel_canary.lua",
    HeartbeatInterval   = 15000,
    HeartbeatTimeout    = 60000,
    KickOnMissingCanary = false,      -- true: a silent canary counts as Injection instead of Integrity
    StrictCompiled      = false,      -- true: unknown-source reports from compiled resources are also enforced
    BlockInjectCalls    = true,       -- true: the canary BLOCKS injected calls BEFORE they execute
                                      -- (the event never leaves the client / never runs). false: report-only.
                                      -- Only "certain" calls are blocked (see Instrument.confirm): never a
                                      -- call with an unresolvable caller, a compiled script, or a resource
                                      -- that legitimately loads code (loadstring/dofile/loadfile).
    WrappedFunctions = {
        "triggerServerEvent", "triggerLatentServerEvent", "triggerEvent",
        "outputChatBox", "outputConsole", "outputDebugString",
        "loadstring", "dofile", "loadfile", "addEvent", "addEventHandler",
        "setElementData", "setElementPosition", "setElementVelocity", "setElementHealth",
        "setElementCollisionsEnabled", "setElementFrozen", "setElementAlpha", "setElementDimension", "setElementInterior",
        "setGravity", "setGameSpeed", "setPedGravity", "setPedWearingJetpack", "giveWeapon", "setWeaponAmmo",
        "createExplosion", "createProjectile", "fetchRemote",
    },
}

-- ------------------------------------------------------------------ Static resource scanner
Config.Scanner = {
    Enabled             = true,
    MaxFileKB           = 2048,
    IgnoredResources    = {},                  -- resources never scanned/hooked
    ReportExposedEvents = true,                -- warn about remote events no client script ever triggers
}

-- ------------------------------------------------------------------ Resource guard
Config.ResourceGuard = {
    Enabled                  = true,
    LogUnexpectedStop        = true,
    DetectUnauthorizedRestart= true,
    RestartPolicy            = "CRITICAL_ONLY",   -- "NONE" | "CRITICAL_ONLY"
    CriticalResources        = {},                -- e.g. { "admin" } : restarted if they stop unexpectedly
    MaxRestarts              = 3,                 -- per resource inside RestartWindow (prevents loops)
    RestartWindow            = 600000,
    NotifyAdmins             = true,
    CommandCorrelationWindow = 3000,              -- /stop /restart commands seen within this window are logged as *possible* initiators
    WatchdogInterval         = 60000,
}

-- ------------------------------------------------------------------ Exemptions
Config.Exemptions = {
    Admins         = true,
    AdminGroups    = { "Admin", "Console" },
    AdminCacheTime = 10000,
    Console        = true,
    ServerResources= true,     -- element data changed by server scripts is never flagged
    Death          = true,
    Respawn        = true,
    Spawn          = true,
    Warp           = true,
    InteriorChange = true,
    DimensionChange= true,
    VehicleEnter   = true,
    VehicleExit    = true,
    Cutscene       = true,     -- honoured through the allowMovement() API
    CustomScriptMovement = true, -- false: allowMovement()/registerTeleport() API calls are ignored
}

-- ------------------------------------------------------------------ Resource trust
Config.TrustedResources = {
    ["admin"]    = true,
    ["freeroam"] = true,
    ["play"]     = true,
}
Config.Trust = {
    RequireACLGroup         = false,   -- true: a trusted resource must ALSO be in one of ACLGroups ("resource.<name>")
    ACLGroups               = { "Admin" },
    APIRequireTrustedCaller = false,   -- true: only trusted resources may call the exported API
}

-- ------------------------------------------------------------------ Session tokens
Config.Session = {
    Enabled            = true,
    RenewInterval      = 300000,
    MaxSequenceGap     = 200,
    MaxClientTickDrift = 15000,
    TokenLength        = 24,
}

-- ------------------------------------------------------------------ Client helper layer
Config.Client = {
    TelemetryInterval = 1000,
    HeartbeatInterval = 5000,
    NoClipRayEnabled  = true,
    SendFPS           = true,
}

-- ------------------------------------------------------------------ Admin notifications
Config.Notifications = {
    Enabled  = true,
    MinLevel = "High",               -- Low | Medium | High | Critical
    Groups   = { "Admin" },
    Color    = { 255, 120, 120 },
}

-- ------------------------------------------------------------------ Evidence
Config.Evidence = {
    Enabled     = true,
    SampleCount = 20,
    MaxEntries  = 5,
    WriteToLog  = true,
}

-- ------------------------------------------------------------------ Commands
Config.Commands = {
    Enabled  = true,
    Name     = "ac",
    ACLRight = "command.ac",         -- players with this right OR in Exemptions.AdminGroups may use /ac
}

-- ------------------------------------------------------------------ Presets (deep-merged over the values above)
Config.Presets = {
    SAFE = {
        Punishment = {
            Actions      = { Freeze = false, Ban = false },
            ScoreActions = { Low = "NONE", Medium = "NONE", High = "WARN", Critical = "KICK" },
        },
        Lag = { ToleranceSoft = 1.8, ToleranceHard = 3.0 },
        Detection = {
            Teleport  = { Threshold = 200, StrikesRequired = 2, Action = "WARN" },
            Fly       = { MinAirTime = 6000, SamplesRequired = 5, Action = "LOG" },
            NoClip    = { SamplesRequired = 6, Action = "LOG" },
            SpeedHack = { MaxOnFootSpeed = 26, SamplesRequired = 5, Action = "LOG" },
            Vehicle   = { ToleranceMultiplier = 1.6, SamplesRequired = 5, Action = "LOG" },
            Explosion = { MaxRate = 8 },
            Flood     = { Action = "WARN", ElementDataPerSecond = 80, TriggersPerSecond = 120, InvalidEventsMax = 60 },
            Injection = { Action = "WARN" },
            NativeAC  = { Action = "WARN" },
            EventFirewall = { LearnMinPlayers = 5 },
        },
    },

    BALANCED = {},

    STRICT = {
        Punishment = {
            Actions      = { Warn = true, Freeze = true, Kick = true, Ban = true },
            ScoreActions = { Low = "NONE", Medium = "WARN", High = "KICK", Critical = "BAN" },
            MinScoreForBan = 100,
        },
        Detection = {
            Teleport  = { Threshold = 90, StrikesRequired = 1, Action = "WARN" },
            Fly       = { MinAirTime = 4000, SamplesRequired = 3, Action = "KICK" },
            NoClip    = { SamplesRequired = 3, Action = "WARN" },
            SpeedHack = { MaxOnFootSpeed = 17, SamplesRequired = 3, Action = "KICK" },
            Vehicle   = { ToleranceMultiplier = 1.15, SamplesRequired = 3, Action = "KICK" },
            Explosion = { MaxRate = 4, Policy = "BLOCK", Action = "WARN" },
            Combat    = { Action = "WARN" },
            EventFirewall = { Action = "WARN", FlagForeignPlayerSource = true },
            Injection = { Action = "BAN" },
            NativeAC  = { Action = "BAN" },
        },
    },

    DEBUG = {
        Debug   = true,
        Logging = { Level = "DEBUG" },
        Punishment = { Enabled = false },
    },
}

-- ------------------------------------------------------------------ helpers
function Config.deepMerge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            Config.deepMerge(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
 end

function Config.applyMode(mode)
    mode = string.upper(tostring(mode or Config.Mode))
    local preset = Config.Presets[mode]
    if not preset then
        return false, "unknown preset '" .. mode .. "'"
    end
    Config.deepMerge(Config, preset)
    Config.Mode = mode
    return true
 end

function Config.getDetection(name)
    return Config.Detection[name]
 end

function Config.isDetectionEnabled(name)
    if not Config.Enabled then return false end
    local d = Config.Detection[name]
    if d == nil then return true end
    return d.Enabled ~= false
 end
