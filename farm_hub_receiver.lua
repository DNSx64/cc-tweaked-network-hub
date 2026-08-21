-- MULTI-SYSTEM HUB / RECEIVER
-- Zentrale Übersicht für Energie, ME/AE2, Flüssigkeit, Inventar und Maschinen-Status.
-- Vollautomatisch: Modem-Seite und Monitor werden zur Laufzeit erkannt (inkl. Hotplug).
-- Ohne Monitor läuft die Anzeige als Fallback auf dem eigenen Computer-Bildschirm.

-- Versionskennung: wird beim Start ausgegeben, damit man im Terminal eindeutig sehen
-- kann, ob wirklich die neueste heruntergeladene Version laeuft (statt eines alten,
-- gecachten Skripts).
local SCRIPT_VERSION = "2026-08-21-2 (callSelf ohne self-Argument)"

local peripheral = peripheral
local rednet = rednet
local os = os
local colors = colors
local textutils = textutils
local term = term
local window = window
local sleep = sleep

local cfg = {
    protocol = "network_status_v1",
    refreshEvery = 0.5,
    staleAfter = 15,
    title = "NETWORK HUB",
}

local hub = {
    monitor = nil,
    monitorSide = nil,
    modemSide = nil,
    senders = {},
    canvas = nil,
    view = "overview", -- "overview" | "detail"
    selectedID = nil,
    rowRects = {},
    detailScroll = 0,
    detailMaxScroll = 0,
    lastDetailVisibleRows = 10,
}

local function trim(value, maxLen)
    if type(value) ~= "string" then
        value = tostring(value or "")
    end
    if maxLen and #value > maxLen then
        return string.sub(value, 1, maxLen)
    end
    return value
end

-- Ruft eine Peripherie-Methode sicher auf, OHNE das Objekt selbst als extra
-- Argument mitzugeben (gewrappte CC:Tweaked-Peripherals erwarten kein self!).
local function call(obj, method, ...)
    if type(obj) ~= "table" then
        return nil
    end
    local fn = obj[method]
    if type(fn) ~= "function" then
        return nil
    end
    local ok, a, b = pcall(fn, ...)
    if not ok then
        return nil
    end
    return a, b
end

-- Ruft eine Methode des Anzeigepuffers (window-Objekt aus window.create()) auf. Genau
-- wie gewrappte Peripherals binden CC:Tweaked-window-Objekte "self" bereits intern per
-- Closure - das Objekt darf NICHT zusaetzlich als erstes Argument mitgegeben werden
-- (sonst verschieben sich alle echten Argumente um eine Position, z. B.
-- "setCursorPos: bad argument #1 (number expected, got table)").
-- Schlaegt ein Aufruf trotzdem fehl, wird das protokolliert statt den Monitor
-- stillschweigend leer zu lassen.
local function callSelf(obj, method, ...)
    if type(obj) ~= "table" then
        print("[HUB] Anzeige-Fehler: kein gueltiger Anzeigepuffer (Methode " .. tostring(method) .. ")")
        return nil
    end
    local fn = obj[method]
    if type(fn) ~= "function" then
        print("[HUB] Anzeige-Fehler: Methode nicht gefunden: " .. tostring(method))
        return nil
    end
    local ok, a, b = pcall(fn, ...)
    if not ok then
        print("[HUB] Anzeige-Fehler bei " .. tostring(method) .. ": " .. tostring(a))
        return nil
    end
    return a, b
end

local function normalizeTypeName(value)
    return tostring(value or ""):lower():gsub("[^%a]", "")
end

-- Sucht ein Peripheriegerät zunächst über peripheral.find(type). Falls das nichts
-- findet, wird zusätzlich normalisiert (Groß-/Kleinschreibung, Unterstriche) über
-- ALLE von peripheral.getType() gemeldeten Typen gesucht (ein "Generic Peripheral"
-- kann laut CC:Tweaked-API mehrere Typen gleichzeitig melden).
local function findPeripheral(name)
    local found = peripheral.find(name)
    if found and type(found) == "table" then
        return found
    end

    local target = normalizeTypeName(name)
    for _, peripheralName in ipairs(peripheral.getNames()) do
        local types = table.pack(peripheral.getType(peripheralName))
        for i = 1, types.n do
            if types[i] and normalizeTypeName(types[i]) == target then
                local ok, wrapped = pcall(peripheral.wrap, peripheralName)
                if ok and type(wrapped) == "table" then
                    return wrapped
                end
                break
            end
        end
    end

    return nil
end

-- Erstellt einen unsichtbaren Zeichenpuffer (window-API) über dem Monitor oder dem
-- eigenen Bildschirm. Dadurch wird jeder render()-Durchlauf komplett "hinter den
-- Kulissen" gezeichnet und erst am Ende in einem Rutsch sichtbar geschaltet - das
-- verhindert das typische Flackern beim Neuzeichnen von Monitoren (Anti-Flicker).
local function createCanvas()
    local parent, width, height

    if hub.monitor then
        parent = hub.monitor
        width, height = call(hub.monitor, "getSize")
    else
        parent = term.current()
        width, height = term.getSize()
    end

    width = width or 51
    height = height or 19

    local ok, win = pcall(window.create, parent, 1, 1, width, height, false)
    if ok and type(win) == "table" then
        hub.canvas = win
        print(string.format("[HUB] Anzeigepuffer erstellt: %dx%d (Ziel: %s)", width, height, hub.monitor and ("Monitor/" .. tostring(hub.monitorSide)) or "eigener Bildschirm"))
    else
        hub.canvas = nil
        print("[HUB] FEHLER beim Erstellen des Anzeigepuffers: " .. tostring(win))
    end
end

local function ensureModem()
    local modem = findPeripheral("modem")
    if not modem then
        return false
    end

    local side = peripheral.getName and peripheral.getName(modem) or nil
    if not side then
        return false
    end

    if rednet.isOpen and rednet.isOpen(side) then
        hub.modemSide = side
        return true
    end

    local ok = pcall(rednet.open, side)
    if not ok then
        return false
    end

    if hub.modemSide ~= side then
        print("[HUB] Modem aktiv auf Seite: " .. side)
    end
    hub.modemSide = side
    return true
end

local function waitForModem()
    local warned = false
    while not ensureModem() do
        if not warned then
            print("[HUB] Warte auf Rednet-Modem (Wireless-/Ender-Modem anschließen oder Wired-Modem per Rechtsklick aktivieren)...")
            warned = true
        end
        os.pullEvent("peripheral")
    end
end

local function attachMonitor()
    local mon = findPeripheral("monitor")
    if not mon then
        return false
    end

    hub.monitor = mon
    hub.monitorSide = peripheral.getName and peripheral.getName(mon) or nil
    call(mon, "setTextScale", 0.5)

    createCanvas()

    print("[HUB] Monitor gefunden auf Seite: " .. tostring(hub.monitorSide))
    return true
end

local function safeString(value, fallback)
    if value == nil then
        return fallback or "N/A"
    end
    return tostring(value)
end

local function statusColor(status)
    status = tostring(status or ""):upper()
    if status == "RUNNING" or status == "ACTIVE" or status == "OK" then
        return colors.lime
    elseif status == "IDLE" then
        return colors.yellow
    elseif status == "LOW_ENERGY" then
        return colors.orange
    elseif status == "N/A" then
        return colors.gray
    end
    return colors.red
end

-- Zeichnet einen horizontalen Fortschrittsbalken (z. B. Energie-/Füllstand) in den
-- Canvas - deutlich mehr visueller "Wumms" als reiner Text.
local function drawBar(canvas, x, y, width, percent, filledColor, emptyColor)
    percent = math.max(0, math.min(100, percent or 0))
    local filled = math.floor((percent / 100) * width + 0.5)

    callSelf(canvas, "setCursorPos", x, y)
    callSelf(canvas, "setBackgroundColor", filledColor)
    callSelf(canvas, "write", string.rep(" ", filled))
    callSelf(canvas, "setBackgroundColor", emptyColor)
    callSelf(canvas, "write", string.rep(" ", math.max(0, width - filled)))
    callSelf(canvas, "setBackgroundColor", colors.black)
end

local function collectRows()
    local rows = {}
    for id, sender in pairs(hub.senders) do
        local data = sender and sender.data or nil
        if type(data) == "table" then
            table.insert(rows, {
                id = id,
                name = trim(data.name or ("Node-" .. tostring(id)), 14),
                status = data.status or "OK",
            })
        end
    end

    table.sort(rows, function(a, b)
        return a.id < b.id
    end)

    return rows
end

-- Summiert Energie/Items/Fluessigkeit ueber ALLE Sender im Netzwerk (nicht nur ein
-- einzelnes ME-System) fuer die Netzwerk-Dashboard-Anzeige oben in der Uebersicht.
local function aggregateNetwork()
    local totals = {
        energyStored = 0,
        energyCapacity = 0,
        itemCount = 0,
        fluidStored = 0,
        fluidCapacity = 0,
    }

    for _, sender in pairs(hub.senders) do
        local data = sender and sender.data
        if type(data) == "table" then
            if type(data.energy) == "table" then
                totals.energyStored = totals.energyStored + (tonumber(data.energy.stored) or 0)
                totals.energyCapacity = totals.energyCapacity + (tonumber(data.energy.capacity) or 0)
            end

            if type(data.me) == "table" then
                totals.itemCount = totals.itemCount + (tonumber(data.me.count) or tonumber(data.me.items) or 0)
            end

            if type(data.fluid) == "table" then
                totals.fluidStored = totals.fluidStored + (tonumber(data.fluid.stored) or 0)
                totals.fluidCapacity = totals.fluidCapacity + (tonumber(data.fluid.capacity) or 0)
            end
        end
    end

    return totals
end

-- Zeichnet eine Dashboard-Statuszeile (Label + Wert + Prozent rechtsbuendig), optional
-- mit Fortschrittsbalken darunter. Gibt die naechste freie Zeile zurueck. Werte ohne
-- Prozentangabe (percent == nil) zeigen keinen Balken -> "N/A"-Zeilen werden so gar
-- nicht erst gebaut (vom Aufrufer ausgelassen), statt leer angezeigt zu werden.
local function renderStatLine(canvas, y, width, label, valueText, percent, barColor)
    callSelf(canvas, "setCursorPos", 1, y)
    callSelf(canvas, "setTextColor", colors.white)
    callSelf(canvas, "write", label .. ": ")

    local percentText = percent and (percent .. "%") or ""
    local valueWidth = math.max(0, width - #label - 2 - #percentText - 1)

    callSelf(canvas, "setTextColor", colors.lightGray)
    callSelf(canvas, "write", trim(valueText, valueWidth))

    if percent then
        callSelf(canvas, "setCursorPos", math.max(1, width - #percentText + 1), y)
        callSelf(canvas, "setTextColor", colors.yellow)
        callSelf(canvas, "write", percentText)

        drawBar(canvas, 1, y + 1, width, percent, barColor, colors.gray)
        return y + 2
    end

    return y + 1
end

local function renderOverview(canvas, width, height)
    hub.rowRects = {}

    -- Kopfzeile: Titel links, ONLINE-Status mittig, Uhrzeit rechts.
    callSelf(canvas, "setCursorPos", 1, 1)
    callSelf(canvas, "setTextColor", colors.yellow)
    callSelf(canvas, "write", trim(cfg.title, math.floor(width / 2)))

    callSelf(canvas, "setCursorPos", math.floor(width / 2) + 1, 1)
    callSelf(canvas, "setTextColor", colors.lime)
    callSelf(canvas, "write", "ONLINE")

    local clock = os.date("%H:%M:%S")
    callSelf(canvas, "setCursorPos", math.max(1, width - #clock + 1), 1)
    callSelf(canvas, "setTextColor", colors.lightGray)
    callSelf(canvas, "write", clock)

    callSelf(canvas, "setCursorPos", 1, 2)
    callSelf(canvas, "setTextColor", colors.gray)
    callSelf(canvas, "write", string.rep("-", width))

    -- Netzwerk-Dashboard: Energie/Items/Fluessigkeit summiert ueber ALLE Systeme.
    local totals = aggregateNetwork()
    local y = 3

    if totals.energyCapacity > 0 then
        local percent = math.floor((totals.energyStored / totals.energyCapacity) * 100)
        y = renderStatLine(canvas, y, width, "Energie", string.format("%d / %d RF", totals.energyStored, totals.energyCapacity), percent, colors.orange)
    end

    if totals.itemCount > 0 then
        y = renderStatLine(canvas, y, width, "Items", tostring(totals.itemCount), nil, nil)
    end

    if totals.fluidCapacity > 0 then
        local percent = math.floor((totals.fluidStored / totals.fluidCapacity) * 100)
        y = renderStatLine(canvas, y, width, "Fluessigkeit", string.format("%d / %d mB", totals.fluidStored, totals.fluidCapacity), percent, colors.blue)
    end

    y = y + 1

    local rows = collectRows()

    callSelf(canvas, "setCursorPos", 1, y)
    callSelf(canvas, "setTextColor", colors.orange)
    callSelf(canvas, "write", trim(string.format("NODES (%d online)", #rows), width))
    y = y + 1

    for i = 1, #rows do
        local row = rows[i]
        if y >= height then
            break
        end

        local statusText = row.status
        local prefix = string.format("%-3s %s", tostring(row.id), row.name)
        local maxPrefixWidth = math.max(0, width - #statusText - 4)

        callSelf(canvas, "setCursorPos", 1, y)
        callSelf(canvas, "setTextColor", statusColor(row.status))
        callSelf(canvas, "write", "> ")

        callSelf(canvas, "setTextColor", colors.white)
        callSelf(canvas, "write", trim(prefix, maxPrefixWidth))

        callSelf(canvas, "setCursorPos", math.max(1, width - #statusText + 1), y)
        callSelf(canvas, "setTextColor", statusColor(row.status))
        callSelf(canvas, "write", statusText)

        hub.rowRects[row.id] = y
        y = y + 1
    end

    if #rows == 0 and y < height then
        callSelf(canvas, "setCursorPos", 1, y)
        callSelf(canvas, "setTextColor", colors.yellow)
        callSelf(canvas, "write", "Warte auf Sender...")
    end

    callSelf(canvas, "setCursorPos", 1, height)
    callSelf(canvas, "setTextColor", colors.cyan)
    local suffix = hub.monitor and "" or " (Fallback: eigener Bildschirm)"
    callSelf(canvas, "write", trim("Zeile antippen fuer Details" .. suffix, width))
end

-- Gruppiert ALLE einzeln gemeldeten Peripheriegeräte (jedes Mod-Gerät für sich, egal
-- ob Mekanism, Thermal, AE2/RS, Reaktoren, Tanks, Truhen, ...) nach Kategorie und baut
-- daraus eine flache Zeilenliste fürs Detail-Menü. Geräte ohne verwertbare Werte wurden
-- vom Sender bereits gar nicht erst mitgeschickt -> "N/A" taucht hier nie auf.
local function buildDetailLines(data)
    local lines = {}
    local categories = { "energy", "fluid", "storage", "inventory", "machine" }
    local headers = {
        energy = "ENERGIE",
        fluid = "FLUESSIGKEIT",
        storage = "ME / STORAGE",
        inventory = "INVENTAR",
        machine = "MASCHINEN",
    }

    local grouped = {}
    for _, item in ipairs(data.details or {}) do
        grouped[item.category] = grouped[item.category] or {}
        table.insert(grouped[item.category], item)
    end

    for _, category in ipairs(categories) do
        local items = grouped[category]
        if items and #items > 0 then
            table.insert(lines, { header = true, text = headers[category] or category:upper() })
            for _, item in ipairs(items) do
                table.insert(lines, { text = item.text, percent = item.percent })
            end
        end
    end

    if #lines == 0 then
        table.insert(lines, { text = "Keine Daten verfuegbar." })
    end

    return lines
end

local function renderDetail(canvas, width, height)
    local sender = hub.senders[hub.selectedID]
    local data = sender and sender.data

    if not data then
        hub.view = "overview"
        hub.selectedID = nil
        renderOverview(canvas, width, height)
        return
    end

    callSelf(canvas, "setCursorPos", 1, 1)
    callSelf(canvas, "setTextColor", colors.cyan)
    callSelf(canvas, "write", trim("< Zurueck", width))

    callSelf(canvas, "setCursorPos", 1, 2)
    callSelf(canvas, "setTextColor", colors.gray)
    callSelf(canvas, "write", string.rep("-", width))

    callSelf(canvas, "setCursorPos", 1, 3)
    callSelf(canvas, "setTextColor", colors.yellow)
    callSelf(canvas, "write", trim("Node " .. tostring(hub.selectedID) .. ": " .. tostring(data.name or "?"), width))

    callSelf(canvas, "setCursorPos", 1, 4)
    callSelf(canvas, "setTextColor", colors.white)
    callSelf(canvas, "write", "Maschine: ")
    callSelf(canvas, "setTextColor", colors.lightGray)
    callSelf(canvas, "write", trim(safeString(data.machine, "?"), math.max(1, width - 10)))

    callSelf(canvas, "setCursorPos", 1, 5)
    callSelf(canvas, "setTextColor", colors.white)
    callSelf(canvas, "write", "Status: ")
    callSelf(canvas, "setTextColor", statusColor(data.status))
    callSelf(canvas, "write", tostring(data.status or "OK"))

    local top = 6
    local bottom = height - 1
    local visibleRows = math.max(1, bottom - top + 1)
    hub.lastDetailVisibleRows = visibleRows

    local lines = buildDetailLines(data)
    hub.detailMaxScroll = math.max(0, #lines - visibleRows)
    hub.detailScroll = math.max(0, math.min(hub.detailScroll or 0, hub.detailMaxScroll))

    local y = top
    local barWidth = math.max(5, math.min(width, 30))

    for i = 1 + hub.detailScroll, #lines do
        if y > bottom then
            break
        end
        local line = lines[i]

        if line.header then
            callSelf(canvas, "setCursorPos", 1, y)
            callSelf(canvas, "setTextColor", colors.orange)
            callSelf(canvas, "write", trim("-- " .. line.text .. " --", width))
            y = y + 1
        else
            callSelf(canvas, "setCursorPos", 1, y)
            callSelf(canvas, "setTextColor", colors.lightGray)
            callSelf(canvas, "write", trim(line.text, width))
            y = y + 1

            if line.percent and y <= bottom then
                local barColor = colors.green
                if line.percent < 25 then
                    barColor = colors.red
                elseif line.percent < 60 then
                    barColor = colors.yellow
                end
                drawBar(canvas, 1, y, barWidth, line.percent, barColor, colors.gray)
                y = y + 1
            end
        end
    end

    local footerParts = {}
    if sender.lastSeen then
        local age = math.max(0, math.floor((os.clock() or 0) - sender.lastSeen))
        table.insert(footerParts, "vor " .. age .. "s")
    end
    if hub.detailMaxScroll > 0 then
        local hint = {}
        if hub.detailScroll > 0 then
            table.insert(hint, "^ oben")
        end
        if hub.detailScroll < hub.detailMaxScroll then
            table.insert(hint, "v unten")
        end
        if #hint > 0 then
            table.insert(footerParts, table.concat(hint, " / "))
        end
    end

    callSelf(canvas, "setCursorPos", 1, height)
    callSelf(canvas, "setTextColor", colors.cyan)
    callSelf(canvas, "write", trim(table.concat(footerParts, "  |  "), width))
end

local function render()
    if not hub.canvas then
        createCanvas()
    end
    local canvas = hub.canvas
    if not canvas then
        print("[HUB] Kein Anzeigepuffer vorhanden - Rendering uebersprungen.")
        return
    end

    callSelf(canvas, "setVisible", false)
    callSelf(canvas, "setBackgroundColor", colors.black)
    callSelf(canvas, "clear")

    local width, height = callSelf(canvas, "getSize")
    width = width or 51
    height = height or 19

    -- Zeichnen wird abgesichert: stürzt renderOverview/renderDetail aus irgendeinem
    -- Grund ab, würde der Canvas sonst für immer unsichtbar/leer bleiben (setVisible
    -- true würde nie erreicht) - der Monitor "rendert dann nichts mehr". Stattdessen
    -- wird der Fehler angezeigt und der Canvas trotzdem sichtbar geschaltet.
    local ok, err = pcall(function()
        if hub.view == "detail" and hub.selectedID ~= nil then
            renderDetail(canvas, width, height)
        else
            renderOverview(canvas, width, height)
        end
    end)

    if not ok then
        callSelf(canvas, "setBackgroundColor", colors.black)
        callSelf(canvas, "setCursorPos", 1, 1)
        callSelf(canvas, "setTextColor", colors.red)
        callSelf(canvas, "write", trim("Render-Fehler: " .. tostring(err), width))
        print("[HUB] Fehler beim Rendern: " .. tostring(err))
    end

    callSelf(canvas, "setVisible", true)
end

local function handleTouch(x, y)
    if hub.view == "overview" then
        for id, rowY in pairs(hub.rowRects) do
            if y == rowY then
                hub.view = "detail"
                hub.selectedID = id
                hub.detailScroll = 0
                render()
                return
            end
        end
    else
        if y == 1 and x <= 10 then
            hub.view = "overview"
            hub.selectedID = nil
            hub.detailScroll = 0
            render()
            return
        end

        -- Scrollen per Antippen: oberer Bereich der Liste = hoch, unterer Bereich = runter.
        local contentTop = 6
        local visible = hub.lastDetailVisibleRows or 10
        if y >= contentTop and y <= contentTop + visible - 1 then
            local half = contentTop + math.floor(visible / 2)
            if y < half then
                hub.detailScroll = math.max(0, (hub.detailScroll or 0) - 5)
            else
                hub.detailScroll = math.min(hub.detailMaxScroll or 0, (hub.detailScroll or 0) + 5)
            end
            render()
        end
    end
end

local function handleMessage(senderID, message, protocol)
    if type(message) ~= "string" then
        return
    end
    if protocol ~= cfg.protocol then
        return
    end

    local ok, data = pcall(textutils.unserialize, message)
    if not ok or type(data) ~= "table" then
        return
    end

    hub.senders[senderID] = {
        data = data,
        lastSeen = os.clock() or 0,
    }
end

local function cleanupStaleSenders()
    local now = os.clock() or 0
    for id, sender in pairs(hub.senders) do
        if sender and sender.lastSeen and (now - sender.lastSeen) > cfg.staleAfter then
            hub.senders[id] = nil
            if hub.view == "detail" and hub.selectedID == id then
                hub.view = "overview"
                hub.selectedID = nil
            end
        end
    end
end

local function eventLoop()
    local tick = os.startTimer(cfg.refreshEvery)

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "rednet_message" then
            handleMessage(p1, p2, p3)
        elseif event == "timer" and p1 == tick then
            cleanupStaleSenders()
            ensureModem()
            render()
            tick = os.startTimer(cfg.refreshEvery)
        elseif event == "monitor_touch" then
            handleTouch(p2, p3)
        elseif event == "monitor_resize" then
            createCanvas()
            render()
        elseif event == "peripheral" then
            local side = p1
            local types = table.pack(peripheral.getType(side))
            local isMonitor, isModem = false, false
            for i = 1, types.n do
                local normalized = normalizeTypeName(types[i])
                if normalized == "monitor" then
                    isMonitor = true
                elseif normalized == "modem" then
                    isModem = true
                end
            end
            if isMonitor and not hub.monitor then
                if attachMonitor() then
                    render()
                end
            end
            if isModem then
                ensureModem()
            end
        elseif event == "peripheral_detach" then
            local side = p1
            if side == hub.monitorSide then
                hub.monitor = nil
                hub.monitorSide = nil
                hub.canvas = nil
                print("[HUB] Monitor entfernt, wechsle auf Bildschirm-Fallback.")
                createCanvas()
                render()
            elseif side == hub.modemSide then
                hub.modemSide = nil
                print("[HUB] Modem entfernt, suche neues Modem...")
            end
        end
    end
end

local function main()
    print("[HUB] Version: " .. SCRIPT_VERSION)
    waitForModem()
    attachMonitor()
    if not hub.canvas then
        createCanvas()
    end
    render()
    eventLoop()
end

-- Falls doch irgendwo ein unerwarteter Fehler auftritt (z. B. defektes Peripheriegerät,
-- Modem kurz weg o. Ä.), soll der Hub NICHT komplett stehen bleiben und der Monitor
-- dauerhaft leer/eingefroren sein, sondern sich automatisch neu starten.
while true do
    local ok, err = pcall(main)
    if ok then
        break
    end
    print("[HUB] Unerwarteter Fehler: " .. tostring(err))
    print("[HUB] Starte in 3 Sekunden neu...")
    sleep(3)
end
