-- Induction Matrix Monitor for CC: Tweaked / Mekanism (Minecraft 1.21.1)
-- Monitor directly on the LEFT; matrix connected through a wired modem.
-- Upload this single file to GitHub, then download its RAW URL with wget.
-- All peripheral calls are read-only. Stop with Ctrl+T.

local CONFIG = {
    monitor = "left",
    matrixName = nil,       -- nil = detect; or e.g. "inductionPort_0"
    displayUnit = "FE",     -- "FE" or "J"; automatic safe fallback to J
    refreshSeconds = 0.5,
    smoothingSeconds = 10,  -- rolling observation window for trend and ETA
    textScale = nil,        -- nil = automatic; otherwise 0.5, 1, 1.5, ... 5
}

local C = colors
local monitor, matrixName, history = nil, nil, {}
local previousRows, previousWidth, previousHeight
local lastLog, timer
local factor, unit = 1, "J"

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

    -- Discard the old trend immediately when the measured direction reverses.
    if last and #history >= 2 then
        local oldChange = last.energy - history[1].energy
        local newChange = energy - last.energy
        if oldChange * newChange < 0 then history = {last} end
    end
    if not last or t > last.t then
        history[#history + 1] = {t = t, energy = energy, cap = cap}
    end
    -- Keep the observation immediately before the window boundary, if present.
    while #history > 2 and history[2].t <= t - CONFIG.smoothingSeconds do
        table.remove(history, 1)
    end
    local first = history[1]
    local elapsed = t - first.t
    local net = elapsed > 0 and (energy - first.energy) / elapsed or nil
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
    return {energy = energy, cap = cap, input = input, output = output,
        net = net, percent = energy / cap * 100, status = status, eta = eta,
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
    local function center(y, text, fg, bg)
        put(math.max(1, math.floor((width - #text) / 2) + 1), y, text, fg, bg)
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
    local net = "Messung..."
    if data.net then
        net = (data.net > 0 and "+" or (data.net < 0 and "-" or ""))
            .. formatEnergy(data.net, "/s", precision)
    end
    f.rect(1, 1, width, 1, C.gray)
    f.center(1, width >= 20 and "INDUCTION MATRIX" or "MATRIX", C.white, C.gray)
    if width >= 38 and height >= 22 then
        local scale = math.max(1, math.min(2, math.floor((height - 17) / 5),
            math.floor((width - 4) / (#pct * 4 - 1))))
        f.center(3, "Ladezustand: " .. pct, C.lightGray)
        bigText(f, pct, 5, scale, width, fillColor)
        local statusY = 6 + 5 * scale
        f.center(statusY, data.status, data.color)
        local barY = statusY + 2
        bar(f, barY, width, 2, data.percent, fillColor)
        f.center(barY + 3, formatEnergy(data.energy) .. " / " .. formatEnergy(data.cap), C.lightGray)
        f.put(3, barY + 5, "Eingang: " .. formatEnergy(data.input, "/t"), C.lime)
        f.put(3, barY + 6, "Ausgang: " .. formatEnergy(data.output, "/t"), C.orange)
        f.put(3, barY + 7, "Netto:   " .. net, data.color)
        f.center(barY + 9, data.eta, data.color)
        if height > barY + 10 then
            f.center(height, "Restzeit: Trend der letzten "
                .. math.floor(math.min(CONFIG.smoothingSeconds, data.elapsed)) .. "s", C.gray)
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
        f.put(1, 8, (long and "Netto: " or "Net ") .. net, data.color)
        local eta = data.eta
        if not long then eta = eta:gsub(" in ca%. ", " ~ ") end
        f.center(9, eta, data.color)
        if height >= 10 then f.center(height, "Prognose / " .. unit, C.gray) end
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
        monitor, previousRows = nil, nil
        log("Kein Monitor links. Advanced Monitor direkt links am Computer anschliessen.")
        return false
    end
    monitor = device
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
        safeRefresh()
    end
end
