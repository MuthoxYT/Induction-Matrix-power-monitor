-- Optional WATER fission controller, Mekanism 10.7 / CC:Tweaked, Lua 5.2.
-- Contract for future addons: return {id,title,create(context)}. context.dir is
-- the main script folder; context.clock() returns seconds. Optional injectable
-- discover() -> device,name; readState() -> table|nil; writeState(table) -> nil.
-- onTerminate() notifies the host of CC's exact yielding-call Terminated error;
-- the host must leave its loop and call shutdown, even if a pcall caught it.
-- Instance functions use DOT calls: update(matrix|nil, now), getView(),
-- action(id), shutdown(reason). matrix={percent=0..100,energy,cap,sampledAt}.
-- update MUST run even without a monitor, on every refresh. Actions only arm
-- intentions; activation is confined to update with a newly validated reading.
-- View: mode,reason,notice,stopError,ceiling,name,readings,matrixPercent,actions.
-- Each action={id,label,enabled}; matrix.lua owns rendering and hit rectangles.
-- No armed AUTO state is saved. Local settings/latch survive script restarts.

local CONFIG = {
    reactorName = nil,          -- nil = exactly one compatible reactor
    stateFile = "reactor_fission.state",
    defaultCeiling = 10,        -- approved water/turbine limit; NOT structural max
    stopPercent = 95, resumePercent = 80,
    tripTemperature = 1000, resetTemperature = 600, -- Kelvin
    tripWater = 0.50, resetWater = 0.95,
    throttleWater = 0.90, coolingStepSeconds = 1,
    -- Match the monitor's whole-percent 100% band; ignore refill jitter in it.
    coolingDownStep = 0.1, urgentWater = 0.80, urgentDownStep = 1,
    fullWater = 0.995, fullIncreasesRequired = 3,
    tripSteam = 0.80, resetSteam = 0.20,
    tripWaste = 0.80, resetWaste = 0.50,
    startRate = 0.1, rampStep = 0.1, rampSeconds = 2,
    fastRampStep = 0.5, fastRampSeconds = 1,
    ceilingStep = 1, maxAgeSeconds = 2,
}

local M = {id = "fission_water", title = "FISSION / WASSER"}
local function number(v, low, high)
    return type(v) == "number" and v == v and v >= low and v <= high
end
local function requireNumber(v, low, high, name)
    if not number(v, low, high) then error("Ungueltiger Messwert: " .. name, 0) end
    return v
end
local methods = {"getStatus", "activate", "scram", "getBurnRate", "getActualBurnRate",
    "getMaxBurnRate", "setBurnRate", "getTemperature", "getCoolant",
    "getCoolantFilledPercentage", "getHeatedCoolantFilledPercentage",
    "getWasteFilledPercentage", "getFuelFilledPercentage", "getDamagePercent", "isForceDisabled"}
local function compatible(device)
    if not device then return false end
    for _, method in ipairs(methods) do
        if type(device[method]) ~= "function" then return false end
    end
    return true
end
local function discover()
    if CONFIG.reactorName then
        local d = peripheral.wrap(CONFIG.reactorName)
        if not compatible(d) then error("Reaktor nicht erreichbar: " .. CONFIG.reactorName, 0) end
        return d, CONFIG.reactorName
    end
    local found, name
    for _, n in ipairs(peripheral.getNames()) do
        local d = peripheral.wrap(n)
        if compatible(d) then
            if found then error("Mehrere Reaktoren: reactorName festlegen", 0) end
            found, name = d, n
        end
    end
    if not found then error("Kein Fission-Reaktor: Modem und Chunks pruefen", 0) end
    return found, name
end

function M.create(context)
    context = context or {}
    local interrupted = false
    local function protected(fn, ...)
        local ok, value, b, c = pcall(fn, ...)
        if not ok and value == "Terminated" then
            interrupted = true
            if context.onTerminate then context.onTerminate() end
        end
        return ok, value, b, c
    end
    local clock = context.clock or function() return os.epoch("utc") / 1000 end
    local path = fs and fs.combine(context.dir or "", CONFIG.stateFile) or CONFIG.stateFile
    local function readFile()
        if not fs.exists(path) then return nil end
        local h = assert(fs.open(path, "r"), "Statusdatei nicht lesbar")
        local contents = h.readAll(); h.close()
        return assert(textutils.unserialize(contents), "Statusdatei beschaedigt")
    end
    local function writeFile(value)
        local encoded = textutils.serialize(value)
        local h = assert(fs.open(path, "w"), "Statusdatei nicht schreibbar")
        local ok, err = protected(h.write, encoded)
        local closed, closeErr = protected(h.close)
        if not ok then error(err, 0) end
        if not closed then error(closeErr, 0) end
        local check = readFile()
        if not check or check.version ~= value.version or check.ceiling ~= value.ceiling
            or check.latch ~= value.latch then error("Statusdatei: Schreibpruefung fehlgeschlagen", 0) end
    end
    local readState, writeState = context.readState or readFile, context.writeState or writeFile
    local find = context.discover or discover
    local ceiling, latch = CONFIG.defaultCeiling, false
    local mode, reason, notice = "PAUSE", "Start in Pause - AUTO bewusst einschalten", nil
    local device, deviceName, readings, matrixPercent, sampledAt
    local stopError, persistenceError, expectedActive, initialized = nil, nil, false, false
    local lastRamp, resetRequested = 0, false
    local resumeRate, resumeRequested = nil, false -- memory only, normal manual pause
    -- Learned supply limit is memory only and survives normal PAUSE/STANDBY.
    local coolingLimit, previousWater, previousWaterAt, lastCoolingReduction
    local calibrationFast, fullIncreases, pendingIncrease = true, 0, nil
    local function resetCalibration()
        coolingLimit, previousWater, previousWaterAt, lastCoolingReduction = nil, nil, nil, nil
        calibrationFast, fullIncreases, pendingIncrease = true, 0, nil
    end
    local function persist()
        local ok, err = protected(writeState, {version = 1, ceiling = ceiling, latch = latch})
        if not ok then
            persistenceError = "Statusdatei: " .. tostring(err)
            mode, reason = "FAULT", persistenceError
            return false
        end
        return true
    end
    local ok, saved = protected(readState)
    if not ok or (saved ~= nil and (type(saved) ~= "table" or saved.version ~= 1
        or not number(saved.ceiling, 0.1, 1000000)
        or not (saved.latch == false or type(saved.latch) == "string"))) then
        persistenceError = "Statusdatei ungueltig/nicht lesbar - Datei am Computer pruefen"
        mode, reason, latch = "FAULT", persistenceError, persistenceError
    elseif saved then
        ceiling, latch = saved.ceiling, saved.latch
        if latch then mode, reason = "FAULT", latch end
    else
        persist()
    end
    local function command(name, ...)
        local result = device[name](...)
        if result == false then error("Befehl abgelehnt: " .. name, 0) end
    end
    -- A failed telemetry read must not prevent a best-effort stop attempt.
    local function stop()
        expectedActive = false
        if not device then stopError = "STOP unbestaetigt: kein erreichbarer Reaktor"; return false end
        local statusOK, status = protected(device.getStatus)
        if statusOK and status == false then
            stopError = nil
            if readings then readings.active = false end
            return true
        end
        local stopped, err = protected(command, "scram")
        if not stopped then stopError = "STOP FEHLER: " .. tostring(err); return false end
        local verified, active = protected(device.getStatus)
        if verified and active == true then stopError = "STOP FEHLER: Reaktor weiter aktiv"; return false end
        if not verified or active ~= false then
            stopError = "STOP gesendet, Status unbestaetigt"
            return false
        end
        stopError = nil
        if readings then readings.active = false end
        return true
    end
    local function trip(message)
        resumeRate, resumeRequested = nil, false
        previousWater, previousWaterAt, pendingIncrease = nil, nil, nil
        calibrationFast, fullIncreases = false, 0
        mode, reason = "FAULT", tostring(message)
        if not latch then latch = reason; persist() end
        if persistenceError then reason = persistenceError end
        stop()
    end
    local function healthyForStart(r, needFuel)
        return r.temperature <= CONFIG.resetTemperature and r.water >= CONFIG.resetWater
            and r.steam <= CONFIG.resetSteam and r.waste <= CONFIG.resetWaste
            and r.damage == 0 and not r.forced and (not needFuel or r.fuel > 0)
    end
    local function freshness(matrix, started)
        local t = clock()
        if not number(t, 0, math.huge - 1) or t < started or t - started > CONFIG.maxAgeSeconds
            or not matrix or not number(matrix.sampledAt, 0, t)
            or t - matrix.sampledAt > CONFIG.maxAgeSeconds then
            error("Messwerte veraltet / Abfrage zu langsam", 0)
        end
        return t
    end
    local function read()
        local r = {}
        r.active = device.getStatus()
        r.forced = device.isForceDisabled()
        if type(r.active) ~= "boolean" or type(r.forced) ~= "boolean" then error("Status ungueltig", 0) end
        r.rate = requireNumber(device.getBurnRate(), 0, 1000000, "Brennrate")
        r.actual = requireNumber(device.getActualBurnRate(), 0, 1000000, "Ist-Brennrate")
        r.max = requireNumber(device.getMaxBurnRate(), 0.1, 1000000, "Strukturmaximum")
        r.temperature = requireNumber(device.getTemperature(), 0, 1000000, "Temperatur")
        r.water = requireNumber(device.getCoolantFilledPercentage(), 0, 1, "Wasser")
        r.steam = requireNumber(device.getHeatedCoolantFilledPercentage(), 0, 1, "Dampf")
        r.waste = requireNumber(device.getWasteFilledPercentage(), 0, 1, "Abfall")
        r.fuel = requireNumber(device.getFuelFilledPercentage(), 0, 1, "Brennstoff")
        r.damage = requireNumber(device.getDamagePercent(), 0, 100, "Schaden")
        local coolant = device.getCoolant()
        if type(coolant) ~= "table" or coolant.name ~= "minecraft:water" then
            error("Nur WASSER unterstuetzt - Kuehlmittel pruefen", 0)
        end
        return r
    end
    local function cooling(r, t)
        -- Use fresh raw pairs: averaging must not hide an approaching dry tank.
        local continuous = previousWaterAt and t > previousWaterAt
            and t - previousWaterAt <= CONFIG.maxAgeSeconds
        local falling = continuous and r.water < CONFIG.fullWater
            and r.water < previousWater - 0.000001
        previousWater, previousWaterAt = r.water, t
        if not r.active then fullIncreases, pendingIncrease = 0, nil; return false end
        if not continuous or falling or r.water < CONFIG.fullWater then
            fullIncreases, pendingIncrease = 0, nil
            if not continuous or r.water <= CONFIG.throttleWater then calibrationFast = false end
        elseif pendingIncrease then
            if math.abs(r.rate - pendingIncrease.rate) > 0.000001 then
                fullIncreases, pendingIncrease = 0, nil
            elseif t - pendingIncrease.at >= pendingIncrease.seconds then
                fullIncreases = math.min(CONFIG.fullIncreasesRequired, fullIncreases + 1)
                pendingIncrease = nil
                if fullIncreases >= CONFIG.fullIncreasesRequired then calibrationFast = true end
            end
        end
        if r.water <= CONFIG.throttleWater and (falling or not continuous)
            and (not lastCoolingReduction or t - lastCoolingReduction >= CONFIG.coolingStepSeconds) then
            local reduced = math.max(CONFIG.startRate,
                math.floor((r.rate - (r.water <= CONFIG.urgentWater
                    and CONFIG.urgentDownStep or CONFIG.coolingDownStep)) * 100 + 0.000001) / 100)
            coolingLimit = math.min(coolingLimit or math.huge, reduced)
            lastCoolingReduction = t
        end
        -- Only this reserve boundary constrains running power. Full-water
        -- detection above it is used for confirmation credits, not derating.
        return r.water <= CONFIG.throttleWater
    end
    local self = {}
    function self.update(matrix, now)
        if interrupted then trip("Programmabbruch: Terminated"); return end
        notice, readings, matrixPercent, sampledAt = nil, nil, nil, nil
        local started = clock()
        local success, err = protected(function()
            local found, name = find()
            if not compatible(found) then error("Reaktor-Schnittstelle unvollstaendig", 0) end
            if deviceName and name ~= deviceName then error("Reaktor gewechselt - Neustart erforderlich", 0) end
            device, deviceName = found, name
            if not initialized then
                initialized = true
                if not stop() then error(stopError,0) end
            end
            if interrupted then error("Terminated",0) end
            local r = read()
            if not matrix or not number(matrix.percent, 0, 100)
                or not number(matrix.energy, 0, math.huge - 1)
                or not number(matrix.cap, 0.000001, math.huge - 1)
                or matrix.energy > matrix.cap then error("Matrix-Messwerte fehlen/ungueltig", 0) end
            local t = freshness(matrix, started)
            readings, matrixPercent, sampledAt = r, matrix.percent, t
            if r.temperature >= CONFIG.tripTemperature then error("Temperatur zu hoch", 0) end
            if r.water <= CONFIG.tripWater then error("Wasserreserve <=50% - Kuehlung pruefen", 0) end
            if r.steam >= CONFIG.tripSteam then error("Dampfstau / Turbine pruefen", 0) end
            if r.waste >= CONFIG.tripWaste then error("Abfalltank zu voll", 0) end
            if r.damage > 0 then error("Reaktorschaden gemeldet", 0) end
            if r.forced then error("Reaktor zwangsdeaktiviert", 0) end
            if r.fuel == 0 and (r.active or mode == "AUTO" or mode == "STANDBY") then
                error("Kein Brennstoff", 0)
            end
            if persistenceError then error(persistenceError, 0) end
            if resetRequested then
                resetRequested = false
                if (mode == "FAULT" or mode == "PAUSE") and healthyForStart(r, false) and not r.active and not stopError then
                    latch = false
                    if persist() then
                        resetCalibration()
                        resumeRate, resumeRequested = nil, false
                        mode, reason = "PAUSE", "RESET: Wassergrenze geloescht - AUTO einschalten"
                    end
                else notice = "RESET gesperrt: kalt, sicher und gestoppt erforderlich" end
            end
            if mode == "FAULT" or latch then stop(); return end
            local waterLimited = cooling(r, t)
            local resuming = mode == "PAUSE" and resumeRequested and resumeRate ~= nil
            if mode == "PAUSE" and resumeRate and r.active then
                error("Unerwarteter Start waehrend manueller Pause",0)
            end
            if resuming and (matrix.percent >= CONFIG.stopPercent or not healthyForStart(r,true)) then
                -- A blocked manual request never becomes automatic standby or
                -- a silently armed retry when battery/cooling later recovers.
                resumeRequested = false
                notice = matrix.percent >= CONFIG.stopPercent
                    and "WEITER gesperrt: Matrix >=95% - spaeter erneut antippen"
                    or "WEITER gesperrt: sichere Startwerte erforderlich - erneut antippen"
                if not stop() then error(stopError,0) end
                return
            end
            if mode == "PAUSE" and not resuming then
                if not stop() then error(stopError,0) end
                return
            end
            if expectedActive and not r.active then error("Externer/manueller Reaktorstopp - RESET erforderlich", 0) end
            if matrix.percent >= CONFIG.stopPercent then
                mode, reason = "STANDBY", "Matrix voll (>=95%) - wartet bis <=80%"
                if not stop() then error(stopError, 0) end
                return
            end
            if mode == "STANDBY" and matrix.percent > CONFIG.resumePercent then
                if r.active then error("Externer Start im Standby", 0) end
                return
            end
            local limit = math.min(ceiling, r.max, coolingLimit or math.huge)
            if not r.active then
                if not healthyForStart(r, true) then
                    notice = "Start wartet: <=600K, Wasser>=95%, Dampf<=20%, Abfall<=50%"
                    return
                end
                if not persist() then error(persistenceError,0) end
                local requestedRate = resuming and resumeRate or CONFIG.startRate
                local liveCap = requireNumber(device.getMaxBurnRate(), 0.1, 1000000, "Strukturmaximum")
                freshness(matrix, started)
                local startRate = math.min(requestedRate, limit, liveCap)
                command("setBurnRate", startRate)
                -- The set call may yield: recheck age and live cap before activation.
                liveCap = requireNumber(device.getMaxBurnRate(), 0.1, 1000000, "Strukturmaximum")
                freshness(matrix, started)
                if startRate > liveCap then error("Strukturmaximum waehrend Start geaendert", 0) end
                command("activate")
                if device.getStatus() ~= true then error("Start nicht bestaetigt", 0) end
                r.active, r.rate = true, startRate
                expectedActive, lastRamp = true, clock()
                resumeRate, resumeRequested = nil, false
                mode, reason = "AUTO", "Regelt nach Matrix-Fuellstand"
                return
            end
            if not expectedActive then error("Unerwartet aktiver Reaktor", 0) end
            local fraction = math.max(0, math.min(1, (CONFIG.stopPercent - matrix.percent) / CONFIG.stopPercent))
            local batteryTarget = math.max(CONFIG.startRate, math.min(ceiling, r.max) * fraction * fraction)
            local step = calibrationFast and CONFIG.fastRampStep or CONFIG.rampStep
            local seconds = calibrationFast and CONFIG.fastRampSeconds or CONFIG.rampSeconds
            local ready = t - lastRamp >= seconds
            -- Probe supply only when demand can actually use the increase.
            if coolingLimit and ready and not waterLimited
                and r.rate >= math.min(limit, batteryTarget) - 0.001 and batteryTarget > r.rate then
                coolingLimit = math.min(ceiling, r.max, coolingLimit + step)
                limit = math.min(ceiling, r.max, coolingLimit)
            end
            local target = math.min(limit, batteryTarget)
            -- Recovery cannot race the normal battery ramp or a saved resume rate.
            if waterLimited then target = math.min(target, r.rate) end
            local nextRate = r.rate
            if nextRate > target then nextRate = target
            elseif ready then nextRate = math.min(target, nextRate + step) end
            if nextRate ~= r.rate then
                local liveCap = requireNumber(device.getMaxBurnRate(), 0.1, 1000000, "Strukturmaximum")
                freshness(matrix, started)
                nextRate = math.min(nextRate, ceiling, liveCap)
                command("setBurnRate", nextRate)
                if nextRate > r.rate and r.water >= CONFIG.fullWater and not waterLimited then
                    pendingIncrease = {rate=nextRate, at=clock(), seconds=seconds}
                else fullIncreases, pendingIncrease = 0, nil end
                r.rate = nextRate
                lastRamp = clock()
            end
            mode, reason = "AUTO", "Regelt nach Matrix-Fuellstand"
            if coolingLimit then
                local cap = math.min(coolingLimit, ceiling, r.max)
                if not waterLimited then
                    reason = string.format("Kalibriert %s | Limit %.2f", calibrationFast and "SCHNELL" or "LANGSAM", cap)
                else reason = string.format("Wasser begrenzt: %.2f mB/t", cap) end
            elseif waterLimited then
                reason = "Wasser erholt sich - Leistung halten"
            else
                reason = "Kalibriert: " .. (calibrationFast and "SCHNELL" or "LANGSAM")
            end
        end)
        if not success then resetRequested = false; trip(err) end
    end
    function self.action(id)
        if interrupted then trip("Programmabbruch: Terminated"); return end
        notice = nil
        if id == "scram" then trip("Manueller NOT-AUS - RESET erforderlich")
        elseif id == "pause" then
            -- Old queued PAUSE commands are stop-only, never a toggle and never
            -- a second capture from an already stopped reactor.
            if mode == "PAUSE" and resumeRate then return end
            if mode == "AUTO" and expectedActive and not latch and not persistenceError then
                local started = clock()
                local captured, value = protected(function()
                    if device.getStatus() ~= true then error("Externer Reaktorstopp vor PAUSE",0) end
                    local value = requireNumber(device.getBurnRate(),0.1,1000000,"Pause-Brennrate")
                    local t = clock()
                    if not number(t,started,started+CONFIG.maxAgeSeconds) then error("Pause-Abfrage veraltet",0) end
                    return value
                end)
                if not captured then trip("PAUSE-Aufnahme fehlgeschlagen: " .. tostring(value)); return end
                if not stop() then trip(stopError); return end
                resumeRate, resumeRequested = value, false
                mode, reason = "PAUSE", string.format("Manuell pausiert - WEITER mit %.2f mB/t",value)
                return
            end
            if not latch and not persistenceError then mode, reason = "PAUSE", "Manuell pausiert" end
            if not stop() then trip(stopError) end
        elseif id == "resume" then
            if mode == "PAUSE" and resumeRate and not latch and not persistenceError and not stopError then
                resumeRequested = true
            end
        elseif id == "reset" then
            if mode == "FAULT" or mode == "PAUSE" then
                resumeRate, resumeRequested = nil, false
                resetRequested = true
            end
        elseif id == "auto" then
            if mode == "PAUSE" and not resumeRate and not resetRequested and not latch and not persistenceError then
                if persist() then mode, reason = "AUTO", "AUTO angefordert - pruefe frische Messwerte"
                else trip(persistenceError) end
            end
        elseif (id == "max_plus" or id == "max_minus") and mode == "PAUSE"
            and not latch and not persistenceError and readings and sampledAt
            and clock() >= sampledAt and clock() - sampledAt <= CONFIG.maxAgeSeconds then
            local new = ceiling + (id == "max_plus" and CONFIG.ceilingStep or -CONFIG.ceilingStep)
            new = math.max(0.1, new)
            if id == "max_plus" then new = math.min(new, readings.max) end
            if new ~= ceiling then ceiling = new; if not persist() then trip(persistenceError) end end
        end
    end
    function self.getView()
        local editable = mode == "PAUSE" and not latch and not persistenceError and readings ~= nil
        local resumable = mode == "PAUSE" and resumeRate ~= nil and not latch and not persistenceError
        return {mode = mode, reason = reason, notice = notice, stopError = stopError,
            ceiling = ceiling, coolingCeiling = coolingLimit,
            calibration = calibrationFast and "SCHNELL" or "LANGSAM", fullIncreases = fullIncreases,
            name = deviceName, readings = readings, matrixPercent = matrixPercent,
            actions = {
                {id="auto",label="AUTO",enabled=mode=="PAUSE" and not resumeRate and not resetRequested and not latch and not persistenceError},
                {id=resumable and "resume" or "pause",label=resumable and "WEITER" or "PAUSE",enabled=true},
                {id="scram",label="NOT-AUS",enabled=true},
                {id="reset",label="RESET",enabled=(mode=="FAULT" or mode=="PAUSE") and not persistenceError},
                {id="max_minus",label="MAX -",enabled=editable},
                {id="max_plus",label="MAX +",enabled=editable and ceiling < readings.max},
            }}
    end
    function self.shutdown(why) trip("Programm beendet: " .. tostring(why or "Stop")) end
    return self
end
return M
