-- Induction Matrix Monitor for CC: Tweaked / Mekanism (Minecraft 1.21.1)
-- Monitor directly on the LEFT; matrix connected through a wired modem.
-- Upload this single file to GitHub, then download its RAW URL with wget.
-- All peripheral calls are read-only. Stop with Ctrl+T.

local CONFIG = {
    monitor = "left",
    matrixName = nil,       -- nil = detect; or e.g. "inductionPort_0"
    displayUnit = "FE",     -- "FE" or "J"; automatic safe fallback to J
    refreshSeconds = 0.5,
    smoothingSeconds = 5,   -- rolling observation window for trend and ETA
    textScale = nil,        -- nil = automatic; otherwise 0.5, 1, 1.5, ... 5
}

local C = colors
local monitor, matrixName, history = nil, nil, {}
local previousRows, previousWidth, previousHeight
local lastLog, timer
local factor, unit = 1, "J"
local paletteApplied = false

-- A monitor-local palette keeps panels distinct without harsh default colors.
local THEME = {
    [C.black] = 0x080D14, [C.gray] = 0x142130, [C.blue] = 0x1B3046,
    [C.white] = 0xE9F1F6, [C.lightGray] = 0x91A6B9, [C.cyan] = 0x58D1DC,
    [C.green] = 0x35B78C, [C.lime] = 0x7DE2BB,
    [C.orange] = 0xEFB366, [C.red] = 0xED7483,
}

-- Mekanism's native computer methods return Joules, independently of GUI units.
-- Derive conversion from the mod's helper instead of assuming a server ratio.
if CONFIG.displayUnit == "FE" then
    for _, helperName in ipairs({"computerEnergyHelper", "mekanismEnergyHelper"}) do
        local helper = _G[helperName]
        if helper and type(helper.joulesToFE) == "function" then
            local ok, value = pcall(helper.joulesToFE, 1000000)
            value = ok and tonumber(value) or nil
            if value and value > 0 and value < math.huge then
                factor, unit = value / 1000000, "FE"
                break
            end
        end
    end
end

local function log(message)
    if message ~= lastLog then
        print(message)
        lastLog = message
    end
end

local function finite(value, label)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge
        or value == -math.huge or value < 0 then
        error("Ungueltiger Messwert: " .. label, 0)
    end
    return value
end

local function now()
    return os.epoch("utc") / 1000
end

local function formatEnergy(value, suffix, digits)
    local prefixes = {"", "k", "M", "G", "T", "P", "E"}
    local scaled, index = math.abs(value) * factor, 1
    while scaled >= 1000 and index < #prefixes do
        scaled, index = scaled / 1000, index + 1
    end
    return string.format("%." .. (digits or 2) .. "f %s%s%s",
        scaled, prefixes[index], unit, suffix or "")
end

local function duration(seconds)
    if seconds ~= seconds or seconds == math.huge or seconds < 0 then
        return "--"
    end
    seconds = math.ceil(seconds)
    if seconds < 60 then return seconds .. "s" end
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then return minutes .. "m " .. (seconds % 60) .. "s" end
    local hours = math.floor(minutes / 60)
    if hours < 24 then return hours .. "h " .. (minutes % 60) .. "m" end
    local days = math.floor(hours / 24)
    return days .. "d " .. (hours % 24) .. "h"
end

local function isMatrix(device)
    if not device then return false end
    for _, method in ipairs({"getEnergy", "getMaxEnergy", "getLastInput", "getLastOutput"}) do
        if type(device[method]) ~= "function" then return false end
    end
    return true
end

local function findMatrix()
    if CONFIG.matrixName then
        local device = peripheral.wrap(CONFIG.matrixName)
        if not isMatrix(device) then
            error("Keine Matrix unter " .. CONFIG.matrixName
                .. ". Induction Port und Modems pruefen.", 0)
        end
        return device, CONFIG.matrixName
    end
    local matches = {}
    for _, name in ipairs(peripheral.getNames()) do
        local device = peripheral.wrap(name)
        if isMatrix(device) then
            matches[#matches + 1] = {device = device, name = name}
        end
    end
    table.sort(matches, function(a, b) return a.name < b.name end)
    if #matches == 0 then
        error("Keine Matrix gefunden. Wired Modem am Induction Port aktivieren; "
            .. "Kabel, geladene Chunks und fertig gebaute Matrix pruefen.", 0)
    elseif #matches > 1 then
        local names = {}
        for _, match in ipairs(matches) do names[#names + 1] = match.name end
        error("Mehrere Matrix-Ports gefunden: " .. table.concat(names, ", ")
            .. ". CONFIG.matrixName oben in der Datei festlegen.", 0)
    end
    return matches[1].device, matches[1].name
end

local function measure()
    local device, name = findMatrix()
    local cap = finite(device.getMaxEnergy(), "Kapazitaet")
    local energy = finite(device.getEnergy(), "Energie")
    local input = finite(device.getLastInput(), "Eingang")
    local output = finite(device.getLastOutput(), "Ausgang")
    if cap <= 0 then error("Kapazitaet ist 0. Matrix und Induction Cells pruefen.", 0) end
    if energy > cap then error("Energie liegt ueber Kapazitaet. Matrix erneut pruefen.", 0) end

    local t = now()
    local last = history[#history]
    if matrixName ~= name or (last and (last.cap ~= cap or t < last.t
        or t - last.t > math.max(30, CONFIG.smoothingSeconds * 3))) then
        history = {}
        last = nil
    end
    matrixName = name

    if not last or t > last.t then
        history[#history + 1] = {t = t, energy = energy, cap = cap, input = input, output = output}
    end
    local boundary = t - CONFIG.smoothingSeconds
    -- Keep the two samples surrounding the exact window boundary.
    while #history > 2 and history[2].t <= boundary do
        table.remove(history, 1)
    end
    local first = history[1]
    local startTime, startEnergy = first.t, first.energy
    if first.t < boundary and #history >= 2 then
        local second = history[2]
        local fraction = (boundary - first.t) / (second.t - first.t)
        startTime = boundary
        startEnergy = first.energy + (second.energy - first.energy) * fraction
    end
    local elapsed = t - startTime
    local net = elapsed > 0 and (energy - startEnergy) / elapsed or nil
    -- Time-weight the sampled tick rates over exactly the same five seconds.
    -- Linear interpolation also handles a boundary between two observations.
    local avgInput, avgOutput = input, output
    if elapsed > 0 then
        local totalInput, totalOutput = 0, 0
        for i = 1, #history - 1 do
            local a, b = history[i], history[i + 1]
            local from, to = math.max(a.t, startTime), math.min(b.t, t)
            if to > from then
                local firstFraction = (from - a.t) / (b.t - a.t)
                local lastFraction = (to - a.t) / (b.t - a.t)
                local averageFraction = (firstFraction + lastFraction) / 2
                totalInput = totalInput + (a.input + (b.input - a.input) * averageFraction) * (to - from)
                totalOutput = totalOutput + (a.output + (b.output - a.output) * averageFraction) * (to - from)
            end
        end
        avgInput, avgOutput = totalInput / elapsed, totalOutput / elapsed
    end
    local status, eta, color = "MESSE...", "Messung laeuft...", C.lightGray
    if energy == 0 then
        status, eta, color = "LEER", "Speicher ist leer", C.red
    elseif energy == cap then
        status, eta, color = "VOLL", "Speicher ist voll", C.green
    elseif net == nil then
        -- First observation: no elapsed time, so no rate or ETA yet.
    elseif net > 0 then
        status, eta, color = "LAEDT", "Voll in ca. " .. duration((cap - energy) / net), C.lime
    elseif net < 0 then
        status, eta, color = "ENTLAEDT", "Leer in ca. " .. duration(energy / -net), C.orange
    else
        status, eta = "STABIL", "Keine Netto-Aenderung"
    end
    return {energy = energy, cap = cap, input = avgInput, output = avgOutput,
        flowNet = avgInput - avgOutput, net = net,
        percent = energy / cap * 100, status = status, eta = eta,
        color = color, name = name, elapsed = elapsed}
end

local function colorCode(color)
    local index = 0
    while color > 1 do color, index = color / 2, index + 1 end
    return ("0123456789abcdef"):sub(index + 1, index + 1)
end

-- Compose a full frame in memory, then send only changed rows (no clear flicker).
local function newFrame(width, height)
    local rows = {}
    for y = 1, height do
        rows[y] = {string.rep(" ", width), string.rep("0", width), string.rep("f", width)}
    end
    local function put(x, y, text, fg, bg)
        if y < 1 or y > height then return end
        x, y = math.floor(x), math.floor(y)
        text = tostring(text)
        if x < 1 then text, x = text:sub(2 - x), 1 end
        text = text:sub(1, math.max(0, width - x + 1))
        if #text == 0 then return end
        local row = rows[y]
        local values = {text, string.rep(colorCode(fg or C.white), #text),
            string.rep(colorCode(bg or C.black), #text)}
        for i = 1, 3 do
            row[i] = row[i]:sub(1, x - 1) .. values[i] .. row[i]:sub(x + #text)
        end
    end
    local function center(y, text, fg, bg, x, span)
        x, span = x or 1, span or width
        text = tostring(text):sub(1, span)
        put(x + math.max(0, math.floor((span - #text) / 2)), y, text, fg, bg)
    end
    local function rectangle(x, y, w, h, color)
        for row = y, y + h - 1 do put(x, row, string.rep(" ", math.max(0, w)), C.white, color) end
    end
    return {rows = rows, put = put, center = center, rect = rectangle}
end

local FONT = {
    ["0"] = {"111","101","101","101","111"},
    ["1"] = {"010","110","010","010","111"},
    ["2"] = {"111","001","111","100","111"},
    ["3"] = {"111","001","111","001","111"},
    ["4"] = {"101","101","111","001","001"},
    ["5"] = {"111","100","111","001","111"},
    ["6"] = {"111","100","111","101","111"},
    ["7"] = {"111","001","010","010","010"},
    ["8"] = {"111","101","111","101","111"},
    ["9"] = {"111","101","111","001","111"},
    ["."] = {"000","000","000","000","010"},
    ["%"] = {"101","001","010","100","101"},
}

local function bigText(frame, text, y, scale, width, color)
    local x = math.floor((width - (#text * 4 - 1) * scale) / 2) + 1
    for i = 1, #text do
        local glyph = FONT[text:sub(i, i)]
        for gy = 1, 5 do
            for gx = 1, 3 do
                if glyph[gy]:sub(gx, gx) == "1" then
                    frame.rect(x + (i - 1) * 4 * scale + (gx - 1) * scale,
                        y + (gy - 1) * scale, scale, scale, color)
                end
            end
        end
    end
end

local function bar(frame, y, width, height, percent, color)
    local margin = width >= 20 and 2 or 1
    local inner = math.max(1, width - margin * 2)
    local filled = math.floor(inner * math.max(0, math.min(100, percent)) / 100 + 0.5)
    frame.rect(margin + 1, y, inner, height, C.gray)
    frame.rect(margin + 1, y, filled, height, color)
end

local function renderData(data, width, height)
    local f = newFrame(width, height)
    local pct = string.format("%.1f%%", data.percent)
    -- Do not round a not-quite-full store to a misleading 100.0%.
    if data.percent < 100 and pct == "100.0%" then pct = "99.9%" end
    local fillColor = data.percent <= 20 and C.red or (data.percent <= 50 and C.orange or C.green)
    local precision = width >= 28 and 2 or 1
    local flowColor = data.flowNet > 0 and C.lime or (data.flowNet < 0 and C.orange or C.lightGray)
    local flowSign = data.flowNet > 0 and "+" or (data.flowNet < 0 and "-" or "")
    local net = flowSign .. formatEnergy(data.flowNet, "/t", precision)
    f.rect(1, 1, width, 1, C.blue)
    f.center(1, width >= 20 and "INDUCTION MATRIX" or "MATRIX", C.white, C.blue)
    if width >= 38 and height >= 22 then
        f.put(2, 2, "ENERGIESPEICHER", C.lightGray)
        f.put(width - #pct, 2, pct, C.cyan)
        local scale = math.max(1, math.min(2, math.floor((height - 17) / 5),
            math.floor((width - 4) / (#pct * 4 - 1))))
        bigText(f, pct, 4, scale, width, C.white)
        local statusY = 4 + 5 * scale
        f.center(statusY, "  " .. data.status .. "  ", C.black, data.color)
        local barY = statusY + 2
        bar(f, barY, width, 2, data.percent, fillColor)

        f.put(3, barY + 2, "0%", C.lightGray)
        f.center(barY + 2, "50%", C.lightGray)
        f.put(width - 5, barY + 2, "100%", C.lightGray)

        local storageY, inner = barY + 4, width - 2
        local leftWidth = math.floor((inner - 1) / 2)
        local rightX = leftWidth + 3
        local rightWidth = width - rightX
        f.rect(2, storageY, leftWidth, 2, C.gray)
        f.rect(rightX, storageY, rightWidth, 2, C.gray)
        f.center(storageY, "GESPEICHERT", C.lightGray, C.gray, 2, leftWidth)
        f.center(storageY + 1, formatEnergy(data.energy), C.white, C.gray, 2, leftWidth)
        f.center(storageY, "KAPAZITAET", C.lightGray, C.gray, rightX, rightWidth)
        f.center(storageY + 1, formatEnergy(data.cap), C.white, C.gray, rightX, rightWidth)

        local flowY = storageY + 3
        local cardWidth = math.floor((inner - 2) / 3)
        local windowLabel = tostring(CONFIG.smoothingSeconds) .. "s"
        if data.elapsed < CONFIG.smoothingSeconds then
            windowLabel = math.floor(data.elapsed) .. "/" .. windowLabel
        end
        f.center(flowY - 1, "MITTELWERTE - " .. windowLabel, C.lightGray)
        local cards = {
            {"EINGANG", data.input, C.lime, ""},
            {"AUSGANG", data.output, C.orange, ""},
            {"NETTO", data.flowNet, flowColor, flowSign},
        }
        for i, card in ipairs(cards) do
            local x = 2 + (i - 1) * (cardWidth + 1)
            local span = i == 3 and (width - x) or cardWidth
            -- Preserve two decimals whenever they fit, including narrow walls.
            local digits = 2
            local value = card[4] .. formatEnergy(card[2], "/t", digits)
            while #value > span and digits > 0 do
                digits = digits - 1
                value = card[4] .. formatEnergy(card[2], "/t", digits)
            end
            f.rect(x, flowY, span, 2, C.gray)
            f.center(flowY, card[1], C.lightGray, C.gray, x, span)
            f.center(flowY + 1, value, card[3], C.gray, x, span)
        end

        local etaY = flowY + 3
        local window = tostring(CONFIG.smoothingSeconds) .. "s"
        local label = "PROGNOSE - LETZTE " .. window
        if data.elapsed < CONFIG.smoothingSeconds then
            label = "PROGNOSE - MESSUNG " .. math.floor(data.elapsed) .. "/" .. window
        end
        f.rect(2, etaY, inner, 2, C.blue)
        f.center(etaY, label, C.lightGray, C.blue, 2, inner)
        f.center(etaY + 1, data.eta, C.cyan, C.blue, 2, inner)
        if height > etaY + 2 then
            f.put(2, height, "o ONLINE", C.green)
            local note = "Speichertrend: Messung..."
            if data.net then
                local sign = data.net > 0 and "+" or (data.net < 0 and "-" or "")
                note = "Speichertrend: " .. sign .. formatEnergy(data.net, "/s")
            end
            f.put(width - #note, height, note, C.lightGray)
        end
    else
        f.center(2, pct, fillColor)
        bar(f, 3, width, 1, data.percent, fillColor)
        f.center(4, data.status, data.color)
        local storage = formatEnergy(data.energy, "", precision)
        if width >= 38 then storage = storage .. " / " .. formatEnergy(data.cap, "", precision) end
        f.center(5, storage, C.lightGray)
        local long = width >= 28
        f.put(1, 6, (long and "Eingang: " or "In  ") .. formatEnergy(data.input, "/t", precision), C.lime)
        f.put(1, 7, (long and "Ausgang: " or "Out ") .. formatEnergy(data.output, "/t", precision), C.orange)
        f.put(1, 8, (long and "Netto: " or "Net ") .. net, flowColor)
        local eta = data.eta
        if not long then eta = eta:gsub(" in ca%. ", " ~ ") end
        f.center(9, eta, data.color)
        if height >= 10 then
            f.center(height, "Mittel " .. CONFIG.smoothingSeconds .. "s / " .. unit, C.lightGray)
        end
    end
    return f
end

local function renderMessage(message, width, height, title)
    local f = newFrame(width, height)
    f.center(1, title or "VERBINDUNGSFEHLER", C.red)
    local line, y = "", 3
    for word in (message .. " "):gmatch("(%S+)%s+") do
        if #line + #word + 1 > width and #line > 0 then
            f.put(1, y, line, C.lightGray)
            line, y = "", y + 1
        end
        -- Also wrap long peripheral names without writing outside the screen.
        while #word > width do
            if #line > 0 then f.put(1, y, line, C.lightGray); line, y = "", y + 1 end
            f.put(1, y, word:sub(1, width), C.lightGray)
            word, y = word:sub(width + 1), y + 1
        end
        line = #line > 0 and line .. " " .. word or word
    end
    if #line > 0 then f.put(1, y, line, C.lightGray) end
    return f
end

local function display(frame, width, height)
    if previousWidth ~= width or previousHeight ~= height then previousRows = nil end
    for y = 1, height do
        local row, old = frame.rows[y], previousRows and previousRows[y]
        if not old or row[1] ~= old[1] or row[2] ~= old[2] or row[3] ~= old[3] then
            monitor.setCursorPos(1, y)
            monitor.blit(row[1], row[2], row[3])
        end
    end
    previousRows, previousWidth, previousHeight = frame.rows, width, height
end

local function connectMonitor()
    local device = peripheral.wrap(CONFIG.monitor)
    if not device or type(device.blit) ~= "function" or type(device.setTextScale) ~= "function" then
        monitor, previousRows, paletteApplied = nil, nil, false
        log("Kein Monitor links. Advanced Monitor direkt links am Computer anschliessen.")
        return false
    end
    monitor = device
    if not paletteApplied and type(monitor.setPaletteColor) == "function" then
        for color, value in pairs(THEME) do monitor.setPaletteColor(color, value) end
        paletteApplied = true
    end
    local w, h = monitor.getSize()
    local current = monitor.getTextScale()
    local target = CONFIG.textScale
    if not target then
        -- Infer physical area from the current character grid; avoid resize loops.
        local available = math.min(w * current / 38, h * current / 22)
        target = math.max(0.5, math.min(2, math.floor(available * 2) / 2))
    end
    if target ~= current then
        monitor.setTextScale(target)
        previousRows = nil
    end
    return true
end

local function refresh()
    local okMonitor, ready = pcall(connectMonitor)
    if not okMonitor or not ready then
        history = {}
        if not okMonitor then log("Monitor nicht erreichbar: " .. tostring(ready)) end
        return
    end
    local width, height = monitor.getSize()
    local ok, data = pcall(measure)
    if ok then
        display(renderData(data, width, height), width, height)
        log("Matrix verbunden: " .. data.name .. ". Anzeige in " .. unit .. ". Stoppen: Ctrl+T.")
    else
        history = {}
        display(renderMessage(tostring(data), width, height), width, height)
        log(tostring(data))
    end
end

local args = {...}
if args[1] == "--list" then
    print("Sichtbare Peripheriegeraete:")
    local names = peripheral.getNames()
    table.sort(names)
    for _, name in ipairs(names) do
        print(name .. (isMatrix(peripheral.wrap(name)) and " [Matrix]" or ""))
    end
    return
end

print("Induction Matrix Monitor - Monitor links / Matrix per Wired Modem")
if unit == "J" and CONFIG.displayUnit == "FE" then
    print("FE-Helfer nicht verfuegbar: korrekte Rohwerte in Joule (J).")
end

local function safeRefresh()
    local ok, err = pcall(refresh)
    if not ok then
        previousRows, history = nil, {}
        log("Anzeige nicht erreichbar; erneuter Versuch: " .. tostring(err))
    end
end

safeRefresh()
timer = os.startTimer(CONFIG.refreshSeconds)
while true do
    local event, name = os.pullEventRaw()
    if event == "terminate" then
        if monitor then
            pcall(function()
                local w, h = monitor.getSize()
                display(renderMessage("Programm am Computer erneut starten.", w, h, "GESTOPPT"), w, h)
            end)
        end
        print("Matrix-Monitor gestoppt.")
        return
    elseif event == "timer" and name == timer then
        safeRefresh()
        timer = os.startTimer(CONFIG.refreshSeconds)
    elseif event == "monitor_resize" and name == CONFIG.monitor then
        previousRows = nil
        safeRefresh()
    elseif event == "peripheral" or event == "peripheral_detach" then
        previousRows = nil
        if name == CONFIG.monitor then paletteApplied = false end
        safeRefresh()
    end
end
