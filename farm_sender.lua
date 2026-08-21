-- MULTI-SYSTEM NETWORK SENDER
-- Sendet Statusdaten für Energie, ME/AE2, Flüssigkeit, Inventar und Maschinenbetrieb an den Hub.
-- Anforderungen: Rednet-Modem auf "back". Optional passende Peripheriegeräte der Maschine.

local peripheral = peripheral
local rednet = rednet
local os = os
local textutils = textutils
local sleep = sleep

local cfg = {
    modemSide = "back",
    protocol = "network_status_v1",
    sendInterval = 2,
    hubID = 0,
    senderName = "NODE-01",
    machineName = "Generic Machine",
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

    local stored = safeCall(device, "getEnergyStored")
        or safeCall(device, "getStoredEnergy")
        or safeCall(device, "getEnergyLevel")
        or safeCall(device, "getEnergy")
        or safeCall(device, "getStored")

    local capacity = safeCall(device, "getMaxEnergyStored")
        or safeCall(device, "getCapacity")
        or safeCall(device, "getMaxEnergy")
        or safeCall(device, "getMaxStored")
        or safeCall(device, "getEnergyCapacity")

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

    local items = safeCall(device, "getItems")
        or safeCall(device, "listItems")
        or safeCall(device, "getItemList")
        or safeCall(device, "getAvailableItems")

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

    local stored = safeCall(device, "getFluidAmount")
        or safeCall(device, "getAmount")
        or safeCall(device, "getStored")

    local capacity = safeCall(device, "getCapacity")
        or safeCall(device, "getMaxAmount")
        or safeCall(device, "getMaxStored")

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

    local items = safeCall(device, "list")
        or safeCall(device, "getItems")
        or safeCall(device, "getAllItems")

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

    local status = safeCall(device, "getStatus")
        or safeCall(device, "getMachineStatus")
        or safeCall(device, "getState")
        or safeCall(device, "isRunning")

    if type(status) == "boolean" then
        return status and "RUNNING" or "IDLE"
    end

    if type(status) == "string" then
        return status
    end

    local active = safeCall(device, "isActive")
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

    local energyDevice = findPeripheral("energyStorage")
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
        print("[SENDER] Kein Rednet-Modem gefunden.")
        return false
    end

    if rednet and rednet.open then
        local ok, err = pcall(rednet.open, cfg.modemSide)
        if not ok then
            print("[SENDER] Modem konnte nicht geöffnet werden: " .. tostring(err))
            return false
        end
    end

    return true
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
    if not ensureModem() then
        error("[SENDER] Modem fehlt. Sender stoppt.")
    end

    while true do
        local ok, err = pcall(sendPacket)
        if not ok then
            print("[SENDER] Fehler beim Senden: " .. tostring(err))
        end
        sleep(cfg.sendInterval)
    end
end

main()
