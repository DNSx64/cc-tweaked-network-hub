-- MULTI-SYSTEM NETWORK SENDER
-- Sendet Statusdaten für Energie, ME/AE2, Flüssigkeit, Inventar und Maschinenbetrieb an den Hub.
-- Vollautomatisch: Modem-Seite und alle Peripheriegeräte werden zur Laufzeit erkannt (inkl. Hotplug).

local peripheral = peripheral
local rednet = rednet
local os = os
local textutils = textutils
local sleep = sleep

local cfg = {
    protocol = "network_status_v1",
    sendInterval = 2,
    hubID = 0,
    senderName = "NODE-01",
    machineName = "Generic Machine",
}

local state = {
    modemSide = nil,
    knownPeripherals = {},
}

local function normalizeTypeName(value)
    return tostring(value or ""):lower():gsub("[^%a]", "")
end

-- Bekannte Peripherie-Typen pro Kategorie. Neue Geräte-Typen können hier einfach
-- ergänzt werden. Groß-/Kleinschreibung und Unterstriche spielen dank
-- normalizeTypeName() keine Rolle (z. B. passt "energy_cube" auf "energyCube").
local TYPE_CATEGORIES = {
    energy = { "energyDetector", "energyStorage", "capacitor", "battery", "rfStorage", "energyCube", "energyCell", "inductionPort" },
    storage = { "meBridge", "ae2", "meBridgeProxy", "refinedStorage", "rsBridge", "storageBridge" },
    fluid = { "tank", "fluidStorage", "liquidTank", "dynamicTank", "barrel", "thermalTank" },
    inventory = { "chest", "inventory", "supply", "crate" },
    machine = { "machine", "furnace", "assembler", "crusher", "sawmill" },
}

local function findPeripheral(name)
    if type(name) ~= "string" then
        return nil
    end

    local found = peripheral.find(name)
    if found and type(found) == "table" then
        return found
    end

    -- Fallback: manche Mods registrieren ihren Peripherie-Typ mit abweichender
    -- Groß-/Kleinschreibung oder Unterstrichen. Zusätzlich kann ein "Generic
    -- Peripheral" laut CC:Tweaked-API MEHRERE Typen gleichzeitig melden - deshalb
    -- werden hier alle gemeldeten Typen geprüft, nicht nur der erste.
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

-- Ordnet ein Peripheriegerät anhand seiner gemeldeten Typen einer Kategorie zu.
-- Gibt Kategorie + Rohtyp (für Log-Ausgaben) zurück, oder nil, wenn unbekannt.
local function classifyPeripheral(peripheralName)
    local types = table.pack(peripheral.getType(peripheralName))
    for i = 1, types.n do
        local normalized = normalizeTypeName(types[i])
        for category, candidates in pairs(TYPE_CATEGORIES) do
            for _, candidate in ipairs(candidates) do
                if normalized == normalizeTypeName(candidate) then
                    return category, types[i]
                end
            end
        end
    end
    return nil, types[1]
end

-- Liefert ALLE aktuell angeschlossenen Peripheriegeräte einer Kategorie (nicht nur
-- das erste gefundene), damit z. B. mehrere Energiezellen zusammen gezählt werden.
local function findAllByCategory(category)
    local matches = {}
    for _, peripheralName in ipairs(peripheral.getNames()) do
        local matchedCategory = classifyPeripheral(peripheralName)
        if matchedCategory == category then
            local ok, wrapped = pcall(peripheral.wrap, peripheralName)
            if ok and type(wrapped) == "table" then
                table.insert(matches, { name = peripheralName, device = wrapped })
            end
        end
    end
    return matches
end

-- Scannt alle angeschlossenen Peripheriegeräte und meldet neu hinzugekommene bzw.
-- entfernte Geräte im Terminal, inklusive erkannter Kategorie (z. B.
-- "energy_cube_1 (energy_cube) -> Kategorie: energy"). Läuft bei jedem Zyklus mit,
-- daher werden Hotplug-Änderungen live erkannt und protokolliert.
local function reportPeripheralChanges()
    local current = {}

    for _, peripheralName in ipairs(peripheral.getNames()) do
        current[peripheralName] = true
        if not state.knownPeripherals[peripheralName] then
            local category, rawType = classifyPeripheral(peripheralName)
            if normalizeTypeName(rawType) ~= "modem" then
                if category then
                    print("[SENDER] Erkannt: " .. peripheralName .. " (" .. tostring(rawType) .. ") -> Kategorie: " .. category)
                else
                    print("[SENDER] Gefunden (nicht kategorisiert): " .. peripheralName .. " (" .. tostring(rawType) .. ")")
                end
            end
        end
    end

    for peripheralName in pairs(state.knownPeripherals) do
        if not current[peripheralName] then
            print("[SENDER] Entfernt: " .. peripheralName)
        end
    end

    state.knownPeripherals = current
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
    local ok, result = pcall(fn, ...)
    if not ok then
        return nil
    end
    return result
end

local function countTable(value)
    if type(value) ~= "table" then
        return 0
    end
    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end
    return count
end

local function getEnergy()
    local devices = findAllByCategory("energy")
    if #devices == 0 then
        return nil
    end

    local totalStored, totalCapacity = 0, 0
    local any = false

    for _, entry in ipairs(devices) do
        local device = entry.device
        local stored = call(device, "getEnergyStored")
            or call(device, "getStoredEnergy")
            or call(device, "getEnergyLevel")
            or call(device, "getEnergy")
            or call(device, "getStored")

        local capacity = call(device, "getMaxEnergyStored")
            or call(device, "getCapacity")
            or call(device, "getMaxEnergy")
            or call(device, "getMaxStored")
            or call(device, "getEnergyCapacity")

        if stored ~= nil and capacity ~= nil then
            totalStored = totalStored + (tonumber(stored) or 0)
            totalCapacity = totalCapacity + (tonumber(capacity) or 0)
            any = true
        end
    end

    if not any or totalCapacity <= 0 then
        return nil
    end

    return {
        stored = totalStored,
        capacity = totalCapacity,
        percent = math.floor((totalStored / totalCapacity) * 100),
        sources = #devices,
    }
end

local function getME()
    local devices = findAllByCategory("storage")
    if #devices == 0 then
        return nil
    end

    local totalCount = 0
    for _, entry in ipairs(devices) do
        local items = call(entry.device, "getItems")
            or call(entry.device, "listItems")
            or call(entry.device, "getItemList")
            or call(entry.device, "getAvailableItems")

        if type(items) == "table" then
            totalCount = totalCount + countTable(items)
        end
    end

    return {
        count = totalCount,
        items = totalCount,
        sources = #devices,
    }
end

local function getFluid()
    local devices = findAllByCategory("fluid")
    if #devices == 0 then
        return nil
    end

    local totalStored, totalCapacity = 0, 0
    local any = false

    for _, entry in ipairs(devices) do
        local device = entry.device
        local stored = call(device, "getFluidAmount")
            or call(device, "getAmount")
            or call(device, "getStored")

        local capacity = call(device, "getCapacity")
            or call(device, "getMaxAmount")
            or call(device, "getMaxStored")

        if stored ~= nil and capacity ~= nil then
            totalStored = totalStored + (tonumber(stored) or 0)
            totalCapacity = totalCapacity + (tonumber(capacity) or 0)
            any = true
        end
    end

    if not any or totalCapacity <= 0 then
        return nil
    end

    return {
        stored = totalStored,
        capacity = totalCapacity,
        percent = math.floor((totalStored / totalCapacity) * 100),
        sources = #devices,
    }
end

local function getInventory()
    local devices = findAllByCategory("inventory")
    if #devices == 0 then
        return nil
    end

    local totalCount = 0
    for _, entry in ipairs(devices) do
        local items = call(entry.device, "list")
            or call(entry.device, "getItems")
            or call(entry.device, "getAllItems")

        if type(items) == "table" then
            totalCount = totalCount + countTable(items)
        end
    end

    return {
        count = totalCount,
        sources = #devices,
    }
end

local function getMachineState()
    local devices = findAllByCategory("machine")
    if #devices == 0 then
        return "N/A"
    end

    for _, entry in ipairs(devices) do
        local device = entry.device
        local status = call(device, "getStatus")
            or call(device, "getMachineStatus")
            or call(device, "getState")
            or call(device, "isRunning")

        if type(status) == "boolean" then
            return status and "RUNNING" or "IDLE"
        end

        if type(status) == "string" then
            return status
        end

        local active = call(device, "isActive")
        if type(active) == "boolean" then
            return active and "ACTIVE" or "IDLE"
        end
    end

    return "OK"
end

local function collectStatus()
    local payload = {
        type = "network_status",
        name = cfg.senderName,
        machine = cfg.machineName,
        id = os.getComputerID(),
        status = "OK",
        timestamp = os.time(),
        energy = nil,
        me = nil,
        fluid = nil,
        inventory = nil,
        machineStatus = "OK",
    }

    payload.energy = getEnergy()
    payload.me = getME()
    payload.fluid = getFluid()
    payload.inventory = getInventory()
    payload.machineStatus = getMachineState()

    if payload.energy and payload.energy.capacity > 0 then
        payload.status = (payload.energy.percent >= 25) and "OK" or "LOW_ENERGY"
    end

    return payload
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
        state.modemSide = side
        return true
    end

    local ok = pcall(rednet.open, side)
    if not ok then
        return false
    end

    if state.modemSide ~= side then
        print("[SENDER] Modem aktiv auf Seite: " .. side)
    end
    state.modemSide = side
    return true
end

local function waitForModem()
    local warned = false
    while not ensureModem() do
        if not warned then
            print("[SENDER] Warte auf Rednet-Modem (Wireless-/Ender-Modem anschließen oder Wired-Modem per Rechtsklick aktivieren)...")
            warned = true
        end
        os.pullEvent("peripheral")
    end
end

local function sendPacket()
    local payload = collectStatus()
    local packet = textutils.serialize(payload)

    if cfg.hubID and cfg.hubID > 0 then
        rednet.send(cfg.hubID, packet, cfg.protocol)
    else
        rednet.broadcast(cfg.protocol, packet)
    end
end

local function main()
    waitForModem()
    reportPeripheralChanges()

    while true do
        ensureModem()
        reportPeripheralChanges()

        local ok, err = pcall(sendPacket)
        if not ok then
            print("[SENDER] Fehler beim Senden: " .. tostring(err))
        end

        sleep(cfg.sendInterval)
    end
end

main()
