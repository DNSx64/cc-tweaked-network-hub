-- MULTI-SYSTEM HUB / RECEIVER
-- Zentrale Übersicht für Energie, ME/AE2, Flüssigkeit, Inventar und Maschinen-Status.
-- Anforderungen: Modem auf "back", Monitor optional auf "top" oder anderer Peripheral-Seite.

local peripheral = peripheral
local rednet = rednet
local os = os
local colors = colors
local textutils = textutils

local cfg = {
    modemSide = "back",
    monitorSide = "top",
    protocol = "network_status_v1",
    refreshEvery = 0.5,
    staleAfter = 15,
    title = "NETWORK HUB",
}

local hub = {
    monitor = nil,
    senders = {},
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

local function wrapPeripheral(name)
    if type(name) ~= "string" then
        return nil
    end
    local found = peripheral.find(name)
    if found and type(found) == "table" then
        return found
    end
    return nil
end

local function safeCall(obj, method, ...)
    if type(obj) ~= "table" then
        return nil
    end
    local fn = obj[method]
    if type(fn) ~= "function" then
        return nil
    end
    local ok, result = pcall(fn, obj, ...)
    if not ok then
        return nil
    end
    return result
end

local function ensureModem()
    local modem = wrapPeripheral("modem")
    if not modem then
        print("[HUB] Kein Rednet-Modem gefunden.")
        return false
    end

    if rednet and rednet.open then
        local ok, err = pcall(rednet.open, cfg.modemSide)
        if not ok then
            print("[HUB] Modem konnte nicht geöffnet werden: " .. tostring(err))
            return false
        end
    end

    return true
end

local function attachMonitor()
    local mon = nil
    if cfg.monitorSide then
        mon = peripheral.wrap(cfg.monitorSide)
    end
    if not mon then
        mon = wrapPeripheral("monitor")
    end
    if not mon then
        print("[HUB] Kein Monitor gefunden.")
        return false
    end

    hub.monitor = mon

    if mon.setTextScale then
        pcall(mon.setTextScale, mon, 0.5)
    end
    if mon.setBackgroundColor then
        pcall(mon.setBackgroundColor, mon, colors.black)
    end
    if mon.clear then
        pcall(mon.clear, mon)
    end
    if mon.setTextColor then
        pcall(mon.setTextColor, mon, colors.lime)
    end
    if mon.setCursorPos then
        pcall(mon.setCursorPos, mon, 1, 1)
    end
    if mon.write then
        pcall(mon.write, mon, cfg.title)
    end

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

local function padRight(str, width)
    str = tostring(str or "")
    if #str >= width then
        return str
    end
    return str .. string.rep(" ", width - #str)
end

local function render()
    if not hub.monitor then
        return
    end

    local mon = hub.monitor
    pcall(mon.setBackgroundColor, mon, colors.black)
    pcall(mon.clear, mon)

    local width, height = 51, 19
    if mon.getSize then
        width, height = mon.getSize()
    end

    pcall(mon.setCursorPos, mon, 1, 1)
    pcall(mon.setTextColor, mon, colors.yellow)
    pcall(mon.write, mon, trim(cfg.title .. "  " .. os.date("%H:%M:%S"), width))

    pcall(mon.setCursorPos, mon, 1, 2)
    pcall(mon.write, mon, string.rep("-", width))

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
        pcall(mon.setCursorPos, mon, xPos[i], 3)
        pcall(mon.setTextColor, mon, colors.white)
        pcall(mon.write, mon, trim(header[i], 10))
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
            pcall(mon.setCursorPos, mon, xPos[c], y)
            pcall(mon.setTextColor, mon, (i % 2 == 0) and colors.gray or colors.lime)
            pcall(mon.write, mon, trim(values[c], 10))
        end

        y = y + 1
    end

    if #rows == 0 then
        pcall(mon.setCursorPos, mon, 1, 5)
        pcall(mon.setTextColor, mon, colors.yellow)
        pcall(mon.write, mon, "Warte auf Sender...")
    end

    pcall(mon.setCursorPos, mon, 1, height)
    pcall(mon.setTextColor, mon, colors.cyan)
    pcall(mon.write, mon, "Live: " .. tostring(#rows) .. " sender")
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
            render()
            tick = os.startTimer(cfg.refreshEvery)
        elseif event == "monitor_touch" then
            render()
        end
    end
end

local function main()
    if not ensureModem() then
        error("[HUB] Kein Rednet-Modem vorhanden.")
    end
    if not attachMonitor() then
        error("[HUB] Kein Monitor verfügbar.")
    end

    render()
    eventLoop()
end

main()
