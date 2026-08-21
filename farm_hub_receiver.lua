-- MULTI-SYSTEM HUB / RECEIVER
-- Zentrale Übersicht für Energie, ME/AE2, Flüssigkeit, Inventar und Maschinen-Status.
-- Vollautomatisch: Modem-Seite und Monitor werden zur Laufzeit erkannt (inkl. Hotplug).
-- Ohne Monitor läuft die Anzeige als Fallback auf dem eigenen Computer-Bildschirm.

local peripheral = peripheral
local rednet = rednet
local os = os
local colors = colors
local textutils = textutils
local term = term

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
}

-- Adapter, damit der eigene Computer-Bildschirm (term) dieselbe Aufruf-Konvention
-- wie ein gewrapptes Monitor-Peripheriegeärt versteht (einheitliches render()).
local termAdapter = {
    setBackgroundColor = function(_, c) term.setBackgroundColor(c) end,
    setTextColor = function(_, c) term.setTextColor(c) end,
    clear = function(_) term.clear() end,
    setCursorPos = function(_, x, y) term.setCursorPos(x, y) end,
    write = function(_, s) term.write(s) end,
    getSize = function(_) return term.getSize() end,
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

local function getScreen()
    return hub.monitor or termAdapter
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
    call(mon, "setBackgroundColor", colors.black)
    call(mon, "clear")
    call(mon, "setTextColor", colors.lime)
    call(mon, "setCursorPos", 1, 1)
    call(mon, "write", cfg.title)

    print("[HUB] Monitor gefunden auf Seite: " .. tostring(hub.monitorSide))
    return true
end

local function safeString(value, fallback)
    if value == nil then
        return fallback or "N/A"
    end
    return tostring(value)
end

local function formatEnergy(val)
    if type(val) ~= "table" then
        return "N/A"
    end
    local stored = tonumber(val.stored) or 0
    local capacity = tonumber(val.capacity) or 0
    if capacity <= 0 then
        return "N/A"
    end
    return string.format("%d/%d (%d%%)", stored, capacity, math.floor((stored / capacity) * 100))
end

local function formatMe(val)
    if type(val) ~= "table" then
        return "N/A"
    end
    local count = tonumber(val.count) or tonumber(val.items) or 0
    return tostring(count)
end

local function formatFluid(val)
    if type(val) ~= "table" then
        return "N/A"
    end
    local stored = tonumber(val.stored) or 0
    local capacity = tonumber(val.capacity) or 0
    if capacity <= 0 then
        return "N/A"
    end
    return string.format("%d/%d (%d%%)", stored, capacity, math.floor((stored / capacity) * 100))
end

local function render()
    local screen = getScreen()

    call(screen, "setBackgroundColor", colors.black)
    call(screen, "clear")

    local width, height = call(screen, "getSize")
    width = width or 51
    height = height or 19

    call(screen, "setCursorPos", 1, 1)
    call(screen, "setTextColor", colors.yellow)
    call(screen, "write", trim(cfg.title .. "  " .. os.date("%H:%M:%S"), width))

    call(screen, "setCursorPos", 1, 2)
    call(screen, "write", string.rep("-", width))

    local rows = {}
    for id, sender in pairs(hub.senders) do
        local data = sender and sender.data or nil
        if type(data) == "table" then
            table.insert(rows, {
                id = id,
                name = trim(data.name or ("Node-" .. tostring(id)), 10),
                energy = formatEnergy(data.energy),
                me = formatMe(data.me),
                fluid = formatFluid(data.fluid),
                inv = formatMe(data.inventory),
                status = data.status or "OK",
                machine = safeString(data.machine or data.machineStatus, "OK"),
            })
        end
    end

    table.sort(rows, function(a, b)
        return a.id < b.id
    end)

    local header = { "ID", "NODE", "ENERGY", "ME", "FLUID", "INV", "STAT" }
    local xPos = {1, 5, 17, 31, 36, 45, 50}

    for i = 1, #header do
        call(screen, "setCursorPos", xPos[i], 3)
        call(screen, "setTextColor", colors.white)
        call(screen, "write", trim(header[i], 10))
    end

    local y = 4
    for i = 1, #rows do
        local row = rows[i]
        if y >= height then
            break
        end

        local values = {
            tostring(row.id),
            row.name,
            row.energy,
            row.me,
            row.fluid,
            row.inv,
            row.status,
        }

        for c = 1, #values do
            call(screen, "setCursorPos", xPos[c], y)
            call(screen, "setTextColor", (i % 2 == 0) and colors.gray or colors.lime)
            call(screen, "write", trim(values[c], 10))
        end

        y = y + 1
    end

    if #rows == 0 then
        call(screen, "setCursorPos", 1, 5)
        call(screen, "setTextColor", colors.yellow)
        call(screen, "write", "Warte auf Sender...")
    end

    call(screen, "setCursorPos", 1, height)
    call(screen, "setTextColor", colors.cyan)
    local suffix = hub.monitor and "" or " (Fallback: eigener Bildschirm, kein Monitor erkannt)"
    call(screen, "write", "Live: " .. tostring(#rows) .. " sender" .. suffix)
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
                print("[HUB] Monitor entfernt, wechsle auf Bildschirm-Fallback.")
                render()
            elseif side == hub.modemSide then
                hub.modemSide = nil
                print("[HUB] Modem entfernt, suche neues Modem...")
            end
        end
    end
end

local function main()
    waitForModem()
    attachMonitor()
    render()
    eventLoop()
end

main()
