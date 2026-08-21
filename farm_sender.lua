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
    energy = {
        "energyDetector", "energyStorage", "energy_storage", "capacitor", "capacitorBank",
        "battery", "rfStorage", "energyCube", "energyCell", "inductionPort", "inductionMatrix",
        "powahCell", "reactorPort", "reactorChassis", "creativeCell", "basicCapacitorBank",
    },
    storage = {
        "meBridge", "ae2", "meBridgeProxy", "meController", "refinedStorage", "rsBridge",
        "storageBridge", "rsController", "diskDrive",
    },
    fluid = {
        "tank", "fluidStorage", "fluid_storage", "liquidTank", "dynamicTank", "barrel",
        "thermalTank", "fluidTank", "fluidHandler", "basicFluidTank", "portableTank",
    },
    inventory = {
        "chest", "inventory", "supply", "crate", "drawer", "drawerController", "shulkerBox",
        "cache", "woodenChest", "ironChest", "backpack",
    },
    machine = {
        "machine", "furnace", "assembler", "crusher", "sawmill", "digitalMiner", "sps",
        "fissionReactor", "fissionReactorLogicAdapter", "boilerValve", "turbine", "turbineValve",
        "bigReactorsReactor", "biggerReactorsReactor", "reactor", "heatGenerator", "dynamo",
        "electricFurnace", "enrichmentChamber", "combiner", "crystallizer", "compressor",
        "purificationChamber", "chemicalReactor", "inductionSmelter", "metallurgicInfuser",
        "chemicalInfuser", "pressurizedReactionChamber", "osmiumCompressor", "rollingMachine",
        "quarry", "pump", "plantGatherer", "blockPlacer", "blockBreaker", "laserDrill",
    },
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

-- Probiert nacheinander mehrere Getter-Methodennamen an einem Gerät durch (viele Mods
-- benennen dieselbe Sache unterschiedlich) und gibt den ersten numerischen Treffer zurück.
local function extractNumericStat(device, getters)
    for _, name in ipairs(getters) do
        local value = call(device, name)
        if value ~= nil then
            local number = tonumber(value)
            if number then
                return number
            end
        end
    end
    return nil
end

local ENERGY_STORED_GETTERS = { "getEnergyStored", "getStoredEnergy", "getEnergyLevel", "getEnergy", "getStored" }
local ENERGY_CAPACITY_GETTERS = { "getMaxEnergyStored", "getCapacity", "getMaxEnergy", "getMaxStored", "getEnergyCapacity" }
local FLUID_STORED_GETTERS = { "getFluidAmount", "getAmount", "getStored" }
local FLUID_CAPACITY_GETTERS = { "getCapacity", "getMaxAmount", "getMaxStored" }

-- Liefert 1) die aufsummierte Übersicht (für die Tabelle) und 2) eine Detail-Liste mit
-- jedem EINZELNEN Gerät (für das Detail-Menü im Hub). Geräte ohne auswertbare Werte
-- (N/A) werden gar nicht erst in die Detail-Liste aufgenommen -> automatisch ausgeblendet.
local function getEnergy()
    local devices = findAllByCategory("energy")
    if #devices == 0 then
        return nil, nil
    end

    local totalStored, totalCapacity = 0, 0
    local details = {}

    for _, entry in ipairs(devices) do
        local device = entry.device
        local stored = extractNumericStat(device, ENERGY_STORED_GETTERS)
        local capacity = extractNumericStat(device, ENERGY_CAPACITY_GETTERS)

        if stored ~= nil and capacity ~= nil and capacity > 0 then
            totalStored = totalStored + stored
            totalCapacity = totalCapacity + capacity
            local percent = math.floor((stored / capacity) * 100)
            table.insert(details, {
                category = "energy",
                source = entry.name,
                text = string.format("%s: %d/%d FE (%d%%)", entry.name, stored, capacity, percent),
                percent = percent,
            })
        end
    end

    if totalCapacity <= 0 then
        return nil, nil
    end

    local summary = {
        stored = totalStored,
        capacity = totalCapacity,
        percent = math.floor((totalStored / totalCapacity) * 100),
        sources = #devices,
    }

    return summary, details
end

local function getME()
    local devices = findAllByCategory("storage")
    if #devices == 0 then
        return nil, nil
    end

    local totalCount = 0
    local details = {}

    for _, entry in ipairs(devices) do
        local items = call(entry.device, "getItems")
            or call(entry.device, "listItems")
            or call(entry.device, "getItemList")
            or call(entry.device, "getAvailableItems")

        if type(items) == "table" then
            local count = countTable(items)
            totalCount = totalCount + count
            table.insert(details, {
                category = "storage",
                source = entry.name,
                text = string.format("%s: %d Eintraege", entry.name, count),
            })
        end
    end

    if #details == 0 then
        return nil, nil
    end

    local summary = {
        count = totalCount,
        items = totalCount,
        sources = #devices,
    }

    return summary, details
end

local function getFluid()
    local devices = findAllByCategory("fluid")
    if #devices == 0 then
        return nil, nil
    end

    local totalStored, totalCapacity = 0, 0
    local details = {}

    for _, entry in ipairs(devices) do
        local device = entry.device
        local stored = extractNumericStat(device, FLUID_STORED_GETTERS)
        local capacity = extractNumericStat(device, FLUID_CAPACITY_GETTERS)

        if stored ~= nil and capacity ~= nil and capacity > 0 then
            totalStored = totalStored + stored
            totalCapacity = totalCapacity + capacity
            local percent = math.floor((stored / capacity) * 100)
            table.insert(details, {
                category = "fluid",
                source = entry.name,
                text = string.format("%s: %d/%d mB (%d%%)", entry.name, stored, capacity, percent),
                percent = percent,
            })
        end
    end

    if totalCapacity <= 0 then
        return nil, nil
    end

    local summary = {
        stored = totalStored,
        capacity = totalCapacity,
        percent = math.floor((totalStored / totalCapacity) * 100),
        sources = #devices,
    }

    return summary, details
end

local function getInventory()
    local devices = findAllByCategory("inventory")
    if #devices == 0 then
        return nil, nil
    end

    local totalCount = 0
    local details = {}

    for _, entry in ipairs(devices) do
        local items = call(entry.device, "list")
            or call(entry.device, "getItems")
            or call(entry.device, "getAllItems")

        if type(items) == "table" then
            local count = countTable(items)
            totalCount = totalCount + count
            table.insert(details, {
                category = "inventory",
                source = entry.name,
                text = string.format("%s: %d Slots belegt", entry.name, count),
            })
        end
    end

    if #details == 0 then
        return nil, nil
    end

    local summary = {
        count = totalCount,
        sources = #devices,
    }

    return summary, details
end

local function getMachineState()
    local devices = findAllByCategory("machine")
    if #devices == 0 then
        return "N/A", nil
    end

    local details = {}
    local summaryStatus = nil

    for _, entry in ipairs(devices) do
        local device = entry.device
        local status = call(device, "getStatus")
            or call(device, "getMachineStatus")
            or call(device, "getState")

        local statusText = nil
        if type(status) == "string" then
            statusText = status
        elseif type(status) == "boolean" then
            statusText = status and "RUNNING" or "IDLE"
        else
            local running = call(device, "isRunning")
            if type(running) == "boolean" then
                statusText = running and "RUNNING" or "IDLE"
            else
                local active = call(device, "isActive")
                if type(active) == "boolean" then
                    statusText = active and "ACTIVE" or "IDLE"
                end
            end
        end

        if statusText then
            summaryStatus = summaryStatus or statusText
            table.insert(details, {
                category = "machine",
                source = entry.name,
                text = string.format("%s: %s", entry.name, statusText),
            })
        end
    end

    if #details == 0 then
        return "OK", nil
    end

    return summaryStatus or "OK", details
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
        details = {},
    }

    local energyDetails, fluidDetails, meDetails, invDetails, machineDetails

    payload.energy, energyDetails = getEnergy()
    payload.me, meDetails = getME()
    payload.fluid, fluidDetails = getFluid()
    payload.inventory, invDetails = getInventory()
    payload.machineStatus, machineDetails = getMachineState()

    -- Alle Einzelgeräte-Details (jedes Mod-Peripheriegerät für sich) werden mit
    -- angehängt, damit der Hub im Detail-Menü ALLES einzeln anzeigen kann.
    local function appendAll(list)
        if type(list) == "table" then
            for _, item in ipairs(list) do
                table.insert(payload.details, item)
            end
        end
    end

    appendAll(energyDetails)
    appendAll(fluidDetails)
    appendAll(meDetails)
    appendAll(invDetails)
    appendAll(machineDetails)

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
        -- rednet.broadcast(message, protocol) - Reihenfolge exakt so, sonst
        -- verwirft der Hub die Nachricht wegen falschem Protokoll.
        rednet.broadcast(packet, cfg.protocol)
    end
end

local function main()
    print("[SENDER] Version 3.0 startet...")
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
