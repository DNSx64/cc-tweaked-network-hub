-- ============================================================================
--  NETWORK HUB / RECEIVER   (CC:Tweaked)
-- ----------------------------------------------------------------------------
--  Zentrale Uebersicht fuer Energie, ME/AE2, Fluessigkeit, Inventar und
--  Maschinen-Status aller Sender im Netzwerk.
--
--  - Modem-Seite und Monitor werden zur Laufzeit automatisch erkannt (Hotplug).
--  - Ohne Monitor laeuft die Anzeige als Fallback auf dem Computer-Bildschirm.
--  - Advanced Monitor: Zeilen antippen -> Detail-Ansicht des jeweiligen Nodes.
--
--  WICHTIG (CC:Tweaked-Konvention, offiziell dokumentiert):
--  Gewrappte Peripherals UND window-Objekte werden OHNE self aufgerufen, also
--  obj.method(args) - NICHT obj:method(args) und NICHT obj.method(obj, args).
-- ============================================================================

local SCRIPT_VERSION = "3.0"

local peripheral = peripheral
local rednet      = rednet
local os          = os
local colors      = colors
local textutils   = textutils
local term        = term
local window      = window
local sleep       = sleep

local cfg = {
    protocol    = "network_status_v1",
    refreshEvery = 0.5,   -- Sekunden zwischen Neuzeichnen
    staleAfter   = 15,    -- Sekunden ohne Nachricht -> Node gilt als offline
    title        = "NETWORK HUB",
}

local hub = {
    monitor      = nil,
    monitorSide  = nil,
    modemSide    = nil,
    senders      = {},        -- [rednetID] = { data = <payload>, lastSeen = os.clock() }
    canvas       = nil,       -- window-Objekt (Doppelpuffer gegen Flackern)
    view         = "overview",-- "overview" | "detail"
    selectedID   = nil,
    rowRects     = {},        -- [rednetID] = y-Zeile (fuer Touch-Trefferpruefung)
    detailScroll = 0,
    detailMaxScroll = 0,
    lastDetailVisibleRows = 10,
}

-- ---------------------------------------------------------------------------
--  Hilfsfunktionen
-- ---------------------------------------------------------------------------

local function trim(value, maxLen)
    if type(value) ~= "string" then
        value = tostring(value or "")
    end
    if maxLen and #value > maxLen then
        return string.sub(value, 1, maxLen)
    end
    return value
end

-- Sicherer Methodenaufruf OHNE self (gilt fuer Peripherals und window-Objekte).
-- Fehler werden bewusst verschluckt: wird nur fuers "Abklopfen" optionaler
-- Peripherie-Getter genutzt, wo ein Fehlschlag normal ist.
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

local function normalizeTypeName(value)
    return tostring(value or ""):lower():gsub("[^%a]", "")
end

-- Sucht ein Peripheriegeraet ueber peripheral.find(type); faellt das nichts,
-- werden normalisiert (Gross-/Kleinschreibung, Unterstriche) alle gemeldeten
-- Typen aller Namen geprueft.
local function findPeripheral(name)
    local found = peripheral.find(name)
    if found and type(found) == "table" then
        return found
    end

    local target = normalizeTypeName(name)
    for _, pName in ipairs(peripheral.getNames()) do
        local types = table.pack(peripheral.getType(pName))
        for i = 1, types.n do
            if types[i] and normalizeTypeName(types[i]) == target then
                local ok, wrapped = pcall(peripheral.wrap, pName)
                if ok and type(wrapped) == "table" then
                    return wrapped
                end
                break
            end
        end
    end
    return nil
end

-- Grosse Zahlen lesbar machen (K/M/G/T), z. B. 1.5M FE.
local function humanize(n)
    n = tonumber(n) or 0
    local a = math.abs(n)
    if a >= 1e12 then return string.format("%.1fT", n / 1e12) end
    if a >= 1e9  then return string.format("%.1fG", n / 1e9)  end
    if a >= 1e6  then return string.format("%.1fM", n / 1e6)  end
    if a >= 1e3  then return string.format("%.1fK", n / 1e3)  end
    return tostring(math.floor(n + 0.5))
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

-- ---------------------------------------------------------------------------
--  Zeichen-Primitive (arbeiten direkt auf dem window-Canvas, ohne self)
-- ---------------------------------------------------------------------------

local function fillLine(c, y, width, bg)
    c.setBackgroundColor(bg or colors.black)
    c.setCursorPos(1, y)
    c.write(string.rep(" ", width))
end

local function writeAt(c, x, y, text, fg, bg)
    if bg then c.setBackgroundColor(bg) end
    if fg then c.setTextColor(fg) end
    c.setCursorPos(x, y)
    c.write(text)
end

local function drawBar(c, x, y, width, percent, filledColor, emptyColor)
    percent = math.max(0, math.min(100, percent or 0))
    local filled = math.floor((percent / 100) * width + 0.5)
    c.setCursorPos(x, y)
    c.setBackgroundColor(filledColor)
    c.write(string.rep(" ", filled))
    c.setBackgroundColor(emptyColor)
    c.write(string.rep(" ", math.max(0, width - filled)))
    c.setBackgroundColor(colors.black)
end

-- ---------------------------------------------------------------------------
--  Canvas / Monitor
-- ---------------------------------------------------------------------------

-- Erstellt einen unsichtbaren Zeichenpuffer (window-API) ueber Monitor oder
-- eigenem Bildschirm. Jeder render()-Durchlauf wird komplett unsichtbar
-- gezeichnet und erst am Ende in einem Rutsch sichtbar geschaltet (Anti-Flicker).
local function createCanvas()
    local parent, width, height

    if hub.monitor then
        parent = hub.monitor
        width, height = call(hub.monitor, "getSize")
    else
        parent = term.current()
        width, height = term.getSize()
    end

    width  = width  or 51
    height = height or 19

    local ok, win = pcall(window.create, parent, 1, 1, width, height, false)
    if ok and type(win) == "table" then
        hub.canvas = win
    else
        hub.canvas = nil
        print("[HUB] FEHLER beim Erstellen des Anzeigepuffers: " .. tostring(win))
    end
end

local function attachMonitor()
    local mon = findPeripheral("monitor")
    if not mon then
        return false
    end

    hub.monitor     = mon
    hub.monitorSide = peripheral.getName and peripheral.getName(mon) or nil
    call(mon, "setTextScale", 0.5)
    createCanvas()

    print("[HUB] Monitor gefunden auf Seite: " .. tostring(hub.monitorSide))
    return true
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
            print("[HUB] Warte auf Rednet-Modem (Wireless-/Ender-Modem anschliessen oder Wired-Modem per Rechtsklick aktivieren)...")
            warned = true
        end
        os.pullEvent("peripheral")
    end
end

-- ---------------------------------------------------------------------------
--  Datenaufbereitung
-- ---------------------------------------------------------------------------

-- Liefert eine sortierte Liste { id, name, status } aller bekannten Sender.
local function collectRows()
    local rows = {}
    for id, sender in pairs(hub.senders) do
        local data = sender and sender.data
        if type(data) == "table" then
            table.insert(rows, {
                id     = id,
                name   = trim(data.name or ("Node-" .. tostring(id)), 16),
                status = data.status or "OK",
            })
        end
    end
    table.sort(rows, function(a, b) return a.id < b.id end)
    return rows
end

-- Summiert Energie / Items / Fluessigkeit ueber ALLE Sender.
local function aggregateNetwork()
    local t = {
        energyStored = 0, energyCapacity = 0,
        itemCount = 0,
        fluidStored = 0, fluidCapacity = 0,
    }
    for _, sender in pairs(hub.senders) do
        local data = sender and sender.data
        if type(data) == "table" then
            if type(data.energy) == "table" then
                t.energyStored   = t.energyStored   + (tonumber(data.energy.stored)   or 0)
                t.energyCapacity = t.energyCapacity + (tonumber(data.energy.capacity) or 0)
            end
            if type(data.me) == "table" then
                t.itemCount = t.itemCount + (tonumber(data.me.count) or tonumber(data.me.items) or 0)
            end
            if type(data.fluid) == "table" then
                t.fluidStored   = t.fluidStored   + (tonumber(data.fluid.stored)   or 0)
                t.fluidCapacity = t.fluidCapacity + (tonumber(data.fluid.capacity) or 0)
            end
        end
    end
    return t
end

-- Gruppiert alle Einzelgeraete eines Nodes (aus data.details) nach Kategorie
-- und baut daraus eine flache Zeilenliste fuers Detail-Menue.
local function buildDetailLines(data)
    local lines = {}
    local categories = { "energy", "fluid", "storage", "inventory", "machine" }
    local headers = {
        energy    = "ENERGIE",
        fluid     = "FLUESSIGKEIT",
        storage   = "ME / STORAGE",
        inventory = "INVENTAR",
        machine   = "MASCHINEN",
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
        table.insert(lines, { text = "Keine Detaildaten verfuegbar." })
    end
    return lines
end

-- ---------------------------------------------------------------------------
--  Ansichten
-- ---------------------------------------------------------------------------

-- Zeichnet eine Statuszeile (Label links, Wert+Prozent rechts) + Balken darunter.
-- Ohne percent (nil) wird kein Balken/Prozent gezeigt. Gibt naechste freie Zeile.
local function renderStatLine(c, y, width, label, valueText, percent, barColor)
    writeAt(c, 1, y, label .. ": ", colors.white, colors.black)

    local percentText = percent and (percent .. "%") or ""
    local valueWidth  = math.max(0, width - #label - 2 - #percentText - 1)

    writeAt(c, #label + 3, y, trim(valueText, valueWidth), colors.lightGray)

    if percent then
        writeAt(c, math.max(1, width - #percentText + 1), y, percentText, colors.yellow)
        drawBar(c, 1, y + 1, width, percent, barColor, colors.gray)
        return y + 2
    end
    return y + 1
end

local function renderOverview(c, width, height)
    hub.rowRects = {}

    -- Kopfleiste (farbig): Titel links, Uhrzeit rechts.
    fillLine(c, 1, width, colors.blue)
    writeAt(c, 2, 1, trim(cfg.title, math.max(1, width - 11)), colors.white, colors.blue)
    local clock = os.date("%H:%M:%S")
    writeAt(c, math.max(1, width - #clock), 1, clock, colors.white, colors.blue)
    c.setBackgroundColor(colors.black)

    local rows = collectRows()
    writeAt(c, 2, 2, "ONLINE", colors.lime, colors.black)
    writeAt(c, 9, 2, string.format("%d Node(s)", #rows), colors.lightGray, colors.black)

    writeAt(c, 1, 3, string.rep("-", width), colors.gray, colors.black)

    -- Netzwerk-Dashboard: aggregierte Werte ueber alle Systeme.
    local totals = aggregateNetwork()
    local y = 4

    if totals.energyCapacity > 0 then
        local percent = math.floor((totals.energyStored / totals.energyCapacity) * 100)
        y = renderStatLine(c, y, width, "Energie",
            string.format("%s / %s FE", humanize(totals.energyStored), humanize(totals.energyCapacity)),
            percent, colors.orange)
    end
    if totals.itemCount > 0 then
        y = renderStatLine(c, y, width, "Items", humanize(totals.itemCount), nil, nil)
    end
    if totals.fluidCapacity > 0 then
        local percent = math.floor((totals.fluidStored / totals.fluidCapacity) * 100)
        y = renderStatLine(c, y, width, "Fluessigkeit",
            string.format("%s / %s mB", humanize(totals.fluidStored), humanize(totals.fluidCapacity)),
            percent, colors.lightBlue)
    end

    y = y + 1
    writeAt(c, 1, y, trim(string.format("NODES (%d)", #rows), width), colors.orange, colors.black)
    y = y + 1

    -- Klickbare Node-Liste.
    for i = 1, #rows do
        local row = rows[i]
        if y >= height then break end

        local statusText = tostring(row.status)
        local prefix     = string.format("%-3s %s", tostring(row.id), row.name)
        local maxPrefix  = math.max(0, width - #statusText - 4)

        writeAt(c, 1, y, "> ", statusColor(row.status), colors.black)
        writeAt(c, 3, y, trim(prefix, maxPrefix), colors.white)
        writeAt(c, math.max(1, width - #statusText + 1), y, statusText, statusColor(row.status))

        hub.rowRects[row.id] = y
        y = y + 1
    end

    if #rows == 0 and y < height then
        writeAt(c, 1, y, "Warte auf Sender...", colors.yellow, colors.black)
    end

    local suffix = hub.monitor and "" or " (Fallback: eigener Bildschirm)"
    writeAt(c, 1, height, trim("Zeile antippen fuer Details" .. suffix, width), colors.cyan, colors.black)
end

local function renderDetail(c, width, height)
    local sender = hub.senders[hub.selectedID]
    local data   = sender and sender.data

    if not data then
        hub.view       = "overview"
        hub.selectedID = nil
        renderOverview(c, width, height)
        return
    end

    -- Kopf: Zurueck-Button + Node-Infos.
    fillLine(c, 1, width, colors.blue)
    writeAt(c, 2, 1, trim("< Zurueck", width), colors.white, colors.blue)
    c.setBackgroundColor(colors.black)

    writeAt(c, 1, 2, trim("Node " .. tostring(hub.selectedID) .. ": " .. tostring(data.name or "?"), width),
        colors.yellow, colors.black)

    writeAt(c, 1, 3, "Maschine: ", colors.white, colors.black)
    writeAt(c, 11, 3, trim(safeString(data.machine, "?"), math.max(1, width - 10)), colors.lightGray)

    writeAt(c, 1, 4, "Status: ", colors.white, colors.black)
    writeAt(c, 9, 4, tostring(data.status or "OK"), statusColor(data.status))

    writeAt(c, 1, 5, string.rep("-", width), colors.gray, colors.black)

    -- Scrollbarer Detailbereich.
    local top     = 6
    local bottom  = height - 1
    local visible = math.max(1, bottom - top + 1)
    hub.lastDetailVisibleRows = visible

    local lines = buildDetailLines(data)
    hub.detailMaxScroll = math.max(0, #lines - visible)
    hub.detailScroll    = math.max(0, math.min(hub.detailScroll or 0, hub.detailMaxScroll))

    local y        = top
    local barWidth = math.max(5, math.min(width, 30))

    for i = 1 + hub.detailScroll, #lines do
        if y > bottom then break end
        local line = lines[i]

        if line.header then
            writeAt(c, 1, y, trim("-- " .. line.text .. " --", width), colors.orange, colors.black)
            y = y + 1
        else
            writeAt(c, 1, y, trim(line.text, width), colors.lightGray, colors.black)
            y = y + 1
            if line.percent and y <= bottom then
                local barColor = colors.green
                if line.percent < 25 then
                    barColor = colors.red
                elseif line.percent < 60 then
                    barColor = colors.yellow
                end
                drawBar(c, 1, y, barWidth, line.percent, barColor, colors.gray)
                y = y + 1
            end
        end
    end

    -- Fusszeile: Alter der letzten Nachricht + Scroll-Hinweise.
    local footerParts = {}
    if sender.lastSeen then
        local age = math.max(0, math.floor((os.clock() or 0) - sender.lastSeen))
        table.insert(footerParts, "vor " .. age .. "s")
    end
    if hub.detailMaxScroll > 0 then
        local hint = {}
        if hub.detailScroll > 0 then table.insert(hint, "^ oben") end
        if hub.detailScroll < hub.detailMaxScroll then table.insert(hint, "v unten") end
        if #hint > 0 then table.insert(footerParts, table.concat(hint, " / ")) end
    end
    writeAt(c, 1, height, trim(table.concat(footerParts, "  |  "), width), colors.cyan, colors.black)
end

-- ---------------------------------------------------------------------------
--  Render (Doppelpuffer + Absicherung)
-- ---------------------------------------------------------------------------

local function render()
    if not hub.canvas then
        createCanvas()
    end
    local c = hub.canvas
    if not c then
        print("[HUB] Kein Anzeigepuffer vorhanden - Rendering uebersprungen.")
        return
    end

    -- Unsichtbar zeichnen, am Ende in einem Rutsch sichtbar schalten.
    c.setVisible(false)
    c.setBackgroundColor(colors.black)
    c.clear()

    local width, height = c.getSize()
    width  = width  or 51
    height = height or 19

    -- Abgesichert: stuerzt eine Ansicht ab, bleibt der Canvas nicht fuer immer
    -- unsichtbar - stattdessen wird der Fehler angezeigt und trotzdem sichtbar
    -- geschaltet.
    local ok, err = pcall(function()
        if hub.view == "detail" and hub.selectedID ~= nil then
            renderDetail(c, width, height)
        else
            renderOverview(c, width, height)
        end
    end)

    if not ok then
        c.setBackgroundColor(colors.black)
        c.setTextColor(colors.red)
        c.setCursorPos(1, 1)
        c.write(trim("Render-Fehler: " .. tostring(err), width))
        print("[HUB] Render-Fehler: " .. tostring(err))
    end

    c.setVisible(true)
end

-- ---------------------------------------------------------------------------
--  Interaktion
-- ---------------------------------------------------------------------------

local function handleTouch(x, y)
    if hub.view == "overview" then
        for id, rowY in pairs(hub.rowRects) do
            if y == rowY then
                hub.view         = "detail"
                hub.selectedID   = id
                hub.detailScroll = 0
                render()
                return
            end
        end
    else
        -- Detail: Zurueck (obere Zeile) oder Scrollen per Antippen.
        if y == 1 then
            hub.view         = "overview"
            hub.selectedID   = nil
            hub.detailScroll = 0
            render()
            return
        end

        local contentTop = 6
        local visible    = hub.lastDetailVisibleRows or 10
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
    if type(message) ~= "string" then return end
    if protocol ~= cfg.protocol then return end

    local ok, data = pcall(textutils.unserialize, message)
    if not ok or type(data) ~= "table" then return end

    hub.senders[senderID] = {
        data     = data,
        lastSeen = os.clock() or 0,
    }
end

local function cleanupStaleSenders()
    local now = os.clock() or 0
    for id, sender in pairs(hub.senders) do
        if sender and sender.lastSeen and (now - sender.lastSeen) > cfg.staleAfter then
            hub.senders[id] = nil
            if hub.view == "detail" and hub.selectedID == id then
                hub.view       = "overview"
                hub.selectedID = nil
            end
        end
    end
end

-- ---------------------------------------------------------------------------
--  Ereignisschleife
-- ---------------------------------------------------------------------------

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
            -- monitor_touch -> (event, side, x, y)
            handleTouch(p2, p3)

        elseif event == "monitor_resize" then
            createCanvas()
            render()

        elseif event == "peripheral" then
            local types = table.pack(peripheral.getType(p1))
            local isMonitor, isModem = false, false
            for i = 1, types.n do
                local n = normalizeTypeName(types[i])
                if n == "monitor" then isMonitor = true
                elseif n == "modem" then isModem = true end
            end
            if isMonitor and not hub.monitor then
                if attachMonitor() then render() end
            end
            if isModem then
                ensureModem()
            end

        elseif event == "peripheral_detach" then
            if p1 == hub.monitorSide then
                hub.monitor     = nil
                hub.monitorSide = nil
                hub.canvas      = nil
                print("[HUB] Monitor entfernt, wechsle auf Bildschirm-Fallback.")
                createCanvas()
                render()
            elseif p1 == hub.modemSide then
                hub.modemSide = nil
                print("[HUB] Modem entfernt, suche neues Modem...")
            end
        end
    end
end

-- ---------------------------------------------------------------------------
--  Start
-- ---------------------------------------------------------------------------

local function main()
    print("[HUB] Version " .. SCRIPT_VERSION .. " startet...")
    waitForModem()
    attachMonitor()
    if not hub.canvas then
        createCanvas()
    end
    render()
    eventLoop()
end

-- Auto-Neustart bei unerwarteten Fehlern, damit der Hub nicht dauerhaft
-- einfriert (z. B. defektes Peripheriegeraet, Modem kurz weg).
while true do
    local ok, err = pcall(main)
    if ok then
        break
    end
    print("[HUB] Unerwarteter Fehler: " .. tostring(err))
    print("[HUB] Starte in 3 Sekunden neu...")
    sleep(3)
end
