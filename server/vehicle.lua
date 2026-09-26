--[[
    SentinelAC :: server/vehicle.lua
    Vehicle speed (per vehicle class) and impossible movement (sustained ascent / hovering) for land & sea vehicles.
    Only the vehicle controller (driver) is held responsible.
]]

VehicleDetection = {}

local AIRCRAFT = { Plane = true, Helicopter = true }

local function raise(player, st, reason, details, now)
    local cfg = Config.Detection.Vehicle
    if now - st.vehicle.lastDetect <= (cfg.Cooldown or 8000) then return end
    st.vehicle.lastDetect = now
    st.vehicle.speedStrikes = 0
    st.vehicle.ascendSamples = 0
    st.vehicle.ascendTotal = 0
    st.vehicle.airSamples = 0
    Suspicion.add(player, "Vehicle", reason, details)
end

function VehicleDetection.check(player, st, prev, sample, ctx)
    local cfg = Config.Detection.Vehicle
    if not cfg.Enabled or not PlayerState.canDetect(player, "Vehicle") then return end
    local veh = sample.veh
    if not veh or not isElement(veh) then return end
    if not sample.driver then return end
    if prev.veh ~= veh then return end

    local vtype = sample.vehType or "Automobile"
    local now = sample.t
    local vs = st.vehicle

    -- towed / attached vehicles follow the tower: skip
    if getVehicleTowingVehicle(veh) or isElementAttached(veh) then return end

    -- 1) speed per class
    if cfg.SpeedHack then
        local base  = cfg.MaxSpeed[vtype] or cfg.MaxSpeed.Automobile or 95
        local limit = base * (cfg.ToleranceMultiplier or 1.3) * ctx.lag
        if ctx.speed > limit and ctx.dist3 > 5 then
            vs.speedStrikes = vs.speedStrikes + 1
            Logger.debug("Vehicle speed strike", {
                player = getPlayerName(player), class = vtype, speed = Util.round(ctx.speed, 0), limit = Util.round(limit, 0), strikes = vs.speedStrikes,
            })
            if vs.speedStrikes >= (cfg.SamplesRequired or 4) then
                raise(player, st, "Vehicle speed exceeds class limit", {
                    class = vtype, model = getElementModel(veh), speed = Util.round(ctx.speed, 0), limit = Util.round(limit, 0),
                }, now)
            end
        else
            vs.speedStrikes = math.max(0, vs.speedStrikes - 1)
        end
    end

    -- 2) impossible movement for non-aircraft
    if cfg.ImpossibleMovement and not AIRCRAFT[vtype] then
        -- a) sustained ascent (ramps launch a car for ~2s, not 3s+ while still climbing)
        if ctx.dz > 2.0 * ctx.lag then
            vs.ascendSamples = vs.ascendSamples + 1
            vs.ascendTotal = vs.ascendTotal + ctx.dz
        else
            vs.ascendSamples = 0
            vs.ascendTotal = 0
        end
        if vs.ascendSamples >= (cfg.AscendSamplesRequired or 6) and vs.ascendTotal >= (cfg.AscendTotal or 60) then
            raise(player, st, "Land/sea vehicle sustained ascent", {
                class = vtype, model = getElementModel(veh), climbed = Util.round(vs.ascendTotal, 0), samples = vs.ascendSamples,
            }, now)
            return
        end

        -- b) hovering: client reports large ground distance AND the server sees no falling and no vertical change.
        --    Client data can only ADD suspicion here; a spoofed low value simply disables this extra layer.
        if vs.clientGround and now - vs.clientGroundTick < 3000
            and vs.clientGround > (cfg.VehicleFlyGround or 15)
            and math.abs(sample.vz) < 0.03 and math.abs(ctx.dz) < 1.0 and not sample.inWater then
            vs.airSamples = vs.airSamples + 1
            if vs.airSamples >= (cfg.VehicleFlySamples or 6) then
                raise(player, st, "Land/sea vehicle hovering above ground", {
                    class = vtype, model = getElementModel(veh), groundDistance = Util.round(vs.clientGround, 1), samples = vs.airSamples,
                }, now)
            end
        else
            vs.airSamples = math.max(0, vs.airSamples - 1)
        end
    end
end
