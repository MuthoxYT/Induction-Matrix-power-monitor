-- Induction Matrix Monitor for CC: Tweaked / Mekanism (Minecraft 1.21.1)
-- Monitor directly on the LEFT; matrix connected through a wired modem.
-- Optional reactor_fission.lua in the same folder adds active reactor control.
-- Matrix access remains read-only. Ctrl+T requests reactor SCRAM if installed.

local CONFIG = {
    monitor = "left",
    matrixName = nil,       -- nil = detect; or e.g. "inductionPort_0"
    displayUnit = "FE",     -- "FE" or "J"; automatic safe fallback to J
    refreshSeconds = 0.5,
    smoothingSeconds = 5,   -- rolling observation window for trend and ETA
    textScale = nil,        -- nil = automatic; otherwise 0.5, 1, 1.5, ... 5
    reactorModule = "reactor_fission.lua", -- relative to THIS script; nil disables
    remoteModule = "matrix_remote.lua", -- optional Pocket transport, same folder
    remoteClients = {3},     -- allowed Pocket computer IDs
}

local C = colors
local monitor, matrixName, history = nil, nil, {}
local previousRows, previousWidth, previousHeight
local lastLog, timer
local factor, unit = 1, "J"
local paletteApplied = false
local reactor, addonError, addonPresent, page, hits = nil, nil, false, "matrix", {}
local cachedMatrix, cachedError, cachedReactor
local remote
local monitorGeneration = 0
local terminating = false
local function protected(fn, ...)
    local ok, value, b, c = pcall(fn, ...)
    -- CC main-thread peripheral calls may raise this while yielding rather
    -- than return a raw terminate event to our outer event loop.
    if not ok and value == "Terminated" then terminating = true end
    return ok, value, b, c
end

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
            local ok, value = protected(helper.joulesToFE, 1000000)
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
    local sampledAt = now() -- age includes Matrix discovery and yielding reads
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
        color = color, name = name, elapsed = elapsed, sampledAt = sampledAt}
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

local function navigation(f, width, targets)
    if not addonPresent then return end
    local split = math.floor(width / 2)
    local state = cachedReactor
    local reactorLabel = state and state.mode == "FAULT" and "REAKTOR ! FAULT" or "REAKTOR > CONTROL"
    for i, tab in ipairs({{"matrix", "MATRIX"}, {"reactor", reactorLabel}}) do
        local x, span = i == 1 and 1 or split + 1, i == 1 and split or width - split
        local bg = page == tab[1] and C.blue or C.gray
        f.rect(x, 1, span, 1, bg)
        local fg = i==2 and (addonError or (state and state.mode=="FAULT")) and C.red
            or (page == tab[1] and C.cyan or C.lightGray)
        f.center(1, tab[2], fg, bg, x, span)
        targets[#targets + 1] = {x=x,y=1,w=span,h=1,page=tab[1]}
    end
end

local function renderReactor(width, height, targets)
    if addonError or not reactor then
        return renderMessage("Addon: " .. tostring(addonError or "nicht geladen"), width, height, "REAKTOR FEHLER")
    end
    local v, f = cachedReactor, newFrame(width, height)
    if not v then return renderMessage("Reaktormessung laeuft...",width,height,"REAKTOR") end
    local spacious = width >= 38 and height >= 22
    local color = v.mode == "FAULT" and C.red or (v.mode == "AUTO" and C.lime or C.orange)
    local firstControlY = height - (spacious and 5 or 3)
    local rowHeight = spacious and 2 or 1
    local secondControlY = height - (spacious and 2 or 1)
    local function line(y, text, fg)
        if y > 1 and y < firstControlY then f.center(y, text, fg or C.lightGray) end
    end
    line(2, "FISSION / WASSER", C.cyan)
    local status = "STATUS UNKLAR"
    if not v.stopError and v.readings then
        if v.readings.active == true then status = "REAKTOR AN"
        elseif v.readings.active == false then status = "REAKTOR AUS" end
    end
    line(3, v.mode .. "  |  " .. status, color)
    local r = v.readings
    local rate = r and string.format("%.2f", r.actual) or "--"
    local max = r and string.format("%.1f", r.max) or "--"
    local pct = v.matrixPercent and string.format("%.1f%%", v.matrixPercent) or "--"
    if spacious then
        local cardWidth = math.floor((width - 5) / 2)
        for i, card in ipairs({{"BRENNRATE / IST",rate .. " mB/t"},
            {"FREIGEGEBEN / MAX",string.format("%.1f",v.ceiling) .. " mB/t"}}) do
            local x = 2 + (i - 1) * (cardWidth + 2)
            f.rect(x,5,cardWidth,3,C.gray)
            f.center(5,card[1],C.lightGray,C.gray,x,cardWidth)
            f.center(6,card[2],C.white,C.gray,x,cardWidth)
        end
        line(8, (width < 55 and "Struktur " or "Strukturmaximum ") .. max .. " mB/t  |  Matrix " .. pct)
        if r then
            line(10,string.format("TEMPERATUR %.0f K   |   SCHADEN %.0f%%",r.temperature,r.damage),r.temperature>=600 and C.orange or C.white)
            local tanks = {{"WASSER",r.water,C.cyan},{"DAMPF",r.steam,C.orange},{"ABFALL",r.waste,C.red}}
            local span = math.floor((width - 4) / 3)
            for i,tank in ipairs(tanks) do
                local x = 2+(i-1)*(span+1)
                f.rect(x,11,span,3,C.gray)
                f.center(11,tank[1],C.lightGray,C.gray,x,span)
                f.center(12,string.format("%.0f%%",tank[2]*100),tank[3],C.gray,x,span)
                f.rect(x,13,math.floor(span*tank[2]+0.5),1,tank[3])
            end
            line(14,string.format("Brennstoff %.0f%%  |  Kuehlung: WASSER",r.fuel*100))
        else line(10,"Keine gueltigen Reaktor-/Matrix-Messwerte",C.red) end
        local message = v.stopError or v.notice or v.reason or ""
        local y = 15
        while #message > 0 and y < firstControlY do
            line(y,message:sub(1,width-2),v.stopError and C.red or color)
            message=message:sub(width-1); y=y+1
        end
        if height>=27 then line(firstControlY-2,"95% STOP  /  80% WEITER  /  Neustart: PAUSE") end
    else
        line(4,rate .. " / " .. string.format("%.1f",v.ceiling) .. " mB/t",C.white)
        line(5,r and string.format("%.0fK W%.0f%% D%.0f%%",r.temperature,r.water*100,r.steam*100) or "Messwerte fehlen",C.cyan)
        line(6,v.stopError or v.notice or v.reason,color)
    end
    if width >= 12 and height >= 9 then
        local span = math.floor(width / 3)
        for i,a in ipairs(v.actions) do
            local x = 1 + ((i-1)%3)*span
            local w = i%3==0 and width-x+1 or span-1
            local y = i<=3 and firstControlY or secondControlY
            local bg = a.id=="scram" and C.red or (a.enabled and C.blue or C.gray)
            f.rect(x,y,w,rowHeight,bg)
            f.center(y,a.label,a.id=="scram" and C.black or (a.enabled and C.white or C.lightGray),bg,x,w)
            if a.enabled then targets[#targets+1]={x=x,y=y,w=w,h=rowHeight,action=a.id} end
        end
    else
        line(height,"Monitor vergroessern",C.orange)
    end
    return f
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

-- Draw only the last completed observation. Changing pages never performs a
-- telemetry/control cycle. New hit targets become visible atomically after
-- the whole draw succeeds; the old targets stay usable during yielding reads.
local function drawCached()
    -- Capture before ANY monitor call: connect/size/blit may all yield while
    -- captureEvents invalidates the geometry or replaces the monitor lifetime.
    local generation = monitorGeneration
    local okMonitor, ready = protected(connectMonitor)
    if terminating then return end
    if generation ~= monitorGeneration then
        hits, previousRows = {}, nil
        return -- the queued geometry event requests a fresh complete draw
    end
    if not okMonitor or not ready then
        hits = {}
        if not okMonitor then log("Monitor nicht erreichbar: " .. tostring(ready)) end
        return
    end
    local width, height = monitor.getSize()
    local frame, targets = nil, {}
    if page == "reactor" and addonPresent then
        frame = renderReactor(width,height,targets)
    elseif cachedMatrix then
        frame = renderData(cachedMatrix,width,height)
    else
        frame = renderMessage(cachedError or "Messung laeuft...", width, height)
    end
    navigation(frame,width,targets)
    display(frame,width,height)
    if generation == monitorGeneration then
        hits = targets
    else
        -- A completed old draw must never resurrect invalidated targets or
        -- cache rows from a screen that was cleared/reconnected while yielding.
        hits, previousRows = {}, nil
    end
end

local function safeDraw()
    if terminating then return end
    local ok, err = protected(drawCached)
    if not ok and not terminating then
        hits, previousRows = {}, nil
        log("Anzeige nicht erreichbar; erneuter Versuch: " .. tostring(err))
    end
end

local function poll()
    -- Only the serial owner calls this, even while capture receives events.
    local ok, data = protected(measure)
    if terminating then return end
    cachedMatrix, cachedError = ok and data or nil, not ok and tostring(data) or nil
    if not ok then history = {}; log(tostring(data)) end
    if reactor then
        local updated, err = protected(reactor.update, cachedMatrix, now())
        if not updated then
            addonError = "Steuerung fehlgeschlagen: " .. tostring(err)
            protected(reactor.shutdown, addonError)
        end
        if terminating then return end
        local viewed, v = protected(reactor.getView)
        if viewed then cachedReactor = v else addonError = tostring(v) end
    end
    if terminating then return end
    if cachedMatrix then
        log("Matrix verbunden: " .. data.name .. ". Anzeige in " .. unit .. ". Stoppen: Ctrl+T.")
    end
    -- Network discovery and publication belong to the serial owner, AFTER
    -- reactor protection. They reuse the completed observation only.
    if remote then
        protected(remote.open)
        if terminating then return end
        protected(remote.publish, {matrix=cachedMatrix,error=cachedError,
            reactor=cachedReactor,addonError=addonError,unit=unit,factor=factor})
        if terminating then return end
    end
    safeDraw()
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

-- loadfile uses the normal CC environment; location is independent of shell cwd.
if CONFIG.reactorModule and fs and shell and shell.getRunningProgram then
    local dir = fs.getDir(shell.getRunningProgram())
    local path = fs.combine(dir, CONFIG.reactorModule)
    if fs.exists(path) then
        addonPresent = true
        local loaded, result = protected(function()
            local chunk, err = loadfile(path)
            if not chunk then error(err,0) end
            local module = chunk()
            assert(type(module)=="table" and type(module.create)=="function", "Addon-Vertrag ungueltig")
            local instance = module.create({dir=dir,clock=now,
                onTerminate=function() terminating=true end})
            for _,method in ipairs({"update","getView","action","shutdown"}) do
                assert(type(instance[method])=="function", "Addon-Methode fehlt: "..method)
            end
            return instance
        end)
        if loaded then reactor = result else addonError = tostring(result); log("Addon: "..addonError) end
    end
end

-- Transport is optional: a missing/corrupt file or absent rednet API must not
-- affect local measurement, controls or protection. create() does no I/O;
-- wireless discovery first happens after poll() has updated reactor safety.
if CONFIG.remoteModule then
    local loaded, result = protected(function()
        if not (fs and shell and shell.getRunningProgram) then return end
        local path = fs.combine(fs.getDir(shell.getRunningProgram()), CONFIG.remoteModule)
        if not fs.exists(path) then return end
        local chunk, err = loadfile(path)
        if not chunk then error(err,0) end
        local module = chunk()
        assert(type(module)=="table" and type(module.create)=="function", "Remote-Vertrag ungueltig")
        local instance = module.create({clock=now,allowedClients=CONFIG.remoteClients,
            onTerminate=function() terminating=true end})
        for _,method in ipairs({"open","publish","capture","process"}) do
            assert(type(instance)=="table" and type(instance[method])=="function",
                "Remote-Methode fehlt: "..method)
        end
        return instance
    end)
    if loaded then remote = result else log("Pocket-Verbindung nicht verfuegbar: "..tostring(result)) end
end

print("Induction Matrix Monitor - Monitor links / Matrix per Wired Modem")
if type(os.getComputerID)=="function" then
    local identified, id = protected(os.getComputerID)
    if identified then print("Computer-ID (Pocket-Ziel): "..tostring(id)) end
end
if unit == "J" and CONFIG.displayUnit == "FE" then
    print("FE-Helfer nicht verfuegbar: korrekte Rohwerte in Joule (J).")
end

local nextPoll = 0
local function safePoll()
    if terminating then return end
    -- Old timers may arrive during main-thread waits. Cancel before polling,
    -- then schedule exactly one future check after all yielding work finishes.
    if timer then os.cancelTimer(timer); timer = nil end
    local ok, err = protected(poll)
    if terminating then return end
    if not ok then
        log("Messung nicht erreichbar; erneuter Versuch: " .. tostring(err))
    end
    nextPoll = now() + CONFIG.refreshSeconds
    timer = os.startTimer(CONFIG.refreshSeconds)
end

local function finalStop()
        if timer then os.cancelTimer(timer) end
        local shutdownOK, shutdownErr = true, nil
        if reactor then shutdownOK, shutdownErr = protected(reactor.shutdown,"Ctrl+T") end
        local stopNote = "Programm am Computer erneut starten."
        if reactor then
            local okView, v = protected(reactor.getView)
            if not shutdownOK then stopNote = "STOP FEHLER: " .. tostring(shutdownErr)
            elseif not okView then stopNote = "STOP unbestaetigt: Addon-Status fehlt"
            elseif v.stopError then stopNote = v.stopError
            else stopNote = "Reaktor gestoppt; NOT-AUS gespeichert. RESET nach Neustart." end
        end
        if monitor then
            protected(function()
                local w, h = monitor.getSize()
                display(renderMessage(stopNote, w, h, "GESTOPPT"), w, h)
            end)
        end
        print("Matrix-Monitor gestoppt.")
        if reactor then print(stopNote) end
end

local queue, head, tail = {}, 1, 0
local wakeEvent = "matrix_control_wake"
local pollRequested = true
local function wake() os.queueEvent(wakeEvent) end
local function enqueue(command)
    tail = tail + 1
    queue[tail] = command
    wake()
end

-- This coroutine never calls a peripheral or an addon method. Classic parallel
-- broadcasts every event to it, regardless of the owner's task_complete filter.
local function captureEvents()
    while true do
        local event, name, x, y = os.pullEventRaw()
        if event == "terminate" then
            terminating = true
            wake()
        elseif event == "char" and addonPresent and (name == "m" or name == "r") then
            enqueue({page=name == "m" and "matrix" or "reactor"})
        elseif event == "monitor_touch" and name == CONFIG.monitor then
            for _,hit in ipairs(hits) do
                if x>=hit.x and x<hit.x+hit.w and y>=hit.y and y<hit.y+hit.h then
                    -- Resolve NOW against the completed visible frame. Never
                    -- reinterpret queued coordinates on a different page.
                    enqueue({page=hit.page,action=hit.action})
                    break
                end
            end
        elseif event == "rednet_message" and remote then
            -- Pure validation only: no discovery, sends or device operations
            -- while the owner may be suspended inside a peripheral read.
            local captured, command = protected(remote.capture,name,x,y)
            if captured and command then enqueue({remote=command}) end
        elseif event == "timer" and name == timer then
            pollRequested = true
            wake()
        elseif event == "monitor_resize" and name == CONFIG.monitor then
            monitorGeneration = monitorGeneration + 1
            hits, previousRows = {}, nil
            enqueue({redraw=true})
        elseif event == "peripheral" or event == "peripheral_detach" then
            if name == CONFIG.monitor then
                monitorGeneration = monitorGeneration + 1
                hits, previousRows = {}, nil
            end
            enqueue({peripheral=name})
        end
    end
end

local function controlOwner()
    while not terminating do
        -- Deadline first, including between queued commands: UI traffic cannot
        -- perpetually defer protection, even if the timer wake was filtered out.
        if pollRequested or now() >= nextPoll then
            pollRequested = false
            safePoll()
        end
        if terminating then return end
        if head <= tail then
            local command = queue[head]
            queue[head], head = nil, head + 1
            if command.page then
                page, previousRows = command.page, nil
                safeDraw()
            elseif command.remote and remote then
                -- A click can arrive between polls or during a yielding read.
                -- Refresh protection before the transport checks current state.
                safePoll()
                if terminating then return end
                protected(remote.process,command.remote,function(action)
                    if terminating or not reactor then return false,"Steuerung nicht verfuegbar" end
                    local acted, err = protected(reactor.action,action)
                    if not acted then
                        addonError=tostring(err)
                        protected(reactor.shutdown,addonError)
                    end
                    -- Apply intent through the same fresh-data owner path.
                    safePoll()
                    if terminating then return false,"Terminated" end
                    if not acted or addonError then return false,addonError or tostring(err) end
                    return true
                end)
            elseif command.action and reactor then
                local acted, err = protected(reactor.action,command.action)
                if not acted then addonError=tostring(err); protected(reactor.shutdown,addonError) end
                -- Actions may arm AUTO or change limits; apply through the same
                -- serialized fresh-data path, never a concurrent command worker.
                safePoll()
            elseif command.peripheral then
                previousRows = nil
                if command.peripheral == CONFIG.monitor then paletteApplied = false end
                pollRequested = true
            elseif command.redraw then
                previousRows = nil
                safeDraw()
            end
        else
            queue, head, tail = {}, 1, 0
            -- The persistent queue is always checked before waiting. A wake
            -- consumed during a peripheral call cannot lose its command.
            os.pullEventRaw(wakeEvent)
        end
    end
end

local ran, runError = protected(parallel.waitForAny,captureEvents,controlOwner)
if not ran and not terminating then log("Eventschleife fehlgeschlagen: " .. tostring(runError)) end
terminating = true
finalStop()
