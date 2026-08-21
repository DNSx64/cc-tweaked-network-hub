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
}

local function findPeripheral(name)
    if type(name) ~= "string" then
        return nil
    end
    local found = peripheral.find(name)
    if found and type(found) == "table" then
        return found
    end
    return nil
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

local function getEnergy(device)
    if not device then
        return nil
    end

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

    if stored == nil or capacity == nil then
        return nil
    end

    stored = tonumber(stored) or 0
    capacity = tonumber(capacity) or 0
    if capacity <= 0 then
        return nil
    end

    return {
        stored = stored,
        capacity = capacity,
        percent = math.floor((stored / capacity) * 100),
    }
end

local function getME(device)
    if not device then
        return nil
    end

    local items = call(device, "getItems")
        or call(device, "listItems")
        or call(device, "getItemList")
        or call(device, "getAvailableItems")

    local count = 0
    if type(items) == "table" then
        count = countTable(items)
    end

    return {
        count = count,
        items = count,
    }
end

local function getFluid(device)
    if not device then
        return nil
    end

    local stored = call(device, "getFluidAmount")
        or call(device, "getAmount")
        or call(device, "getStored")

    local capacity = call(device, "getCapacity")
        or call(device, "getMaxAmount")
        or call(device, "getMaxStored")

    if stored == nil or capacity == nil then
        return nil
    end

    stored = tonumber(stored) or 0
    capacity = tonumber(capacity) or 0
    if capacity <= 0 then
        return nil
    end

    return {
        stored = stored,
        capacity = capacity,
        percent = math.floor((stored / capacity) * 100),
    }
end

local function getInventory(device)
    if not device then
        return nil
    end

    local items = call(device, "list")
        or call(device, "getItems")
        or call(device, "getAllItems")

    if type(items) ~= "table" then
        return nil
    end

    return {
        count = countTable(items),
        items = items,
    }
end

local function getMachineState(device)
    if not device then
        return "N/A"
    end

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

    local energyDevice = findPeripheral("energyDetector")
        or findPeripheral("energyStorage")
        or findPeripheral("capacitor")
        or findPeripheral("battery")
        or findPeripheral("rfStorage")
        or findPeripheral("mekanism:energyCube")
        or findPeripheral("inductionPort")

    local meDevice = findPeripheral("meBridge")
        or findPeripheral("ae2")
        or findPeripheral("meBridgeProxy")
        or findPeripheral("refinedStorage")
        or findPeripheral("rsBridge")
        or findPeripheral("storageBridge")

    local fluidDevice = findPeripheral("tank")
        or findPeripheral("fluidStorage")
        or findPeripheral("liquidTank")
        or findPeripheral("dynamicTank")
        or findPeripheral("barrel")
        or findPeripheral("thermalTank")

    local inventoryDevice = findPeripheral("chest")
        or findPeripheral("inventory")
        or findPeripheral("supply")
        or findPeripheral("crate")

    local machineDevice = findPeripheral("machine")
        or findPeripheral("furnace")
        or findPeripheral("assembler")
        or findPeripheral("crusher")
        or findPeripheral("sawmill")

    payload.energy = getEnergy(energyDevice)
    payload.me = getME(meDevice)
    payload.fluid = getFluid(fluidDevice)
    payload.inventory = getInventory(inventoryDevice)
    payload.machineStatus = getMachineState(machineDevice)

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

    while true do
        ensureModem()

        local ok, err = pcall(sendPacket)
        if not ok then
            print("[SENDER] Fehler beim Senden: " .. tostring(err))
        end

        sleep(cfg.sendInterval)
    end
end

main()
