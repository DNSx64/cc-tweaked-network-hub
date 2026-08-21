-- probe.lua  -  Diagnose-Werkzeug fuer Peripherals (v1.0)
--
-- Gibt ALLES aus, was ein Peripheriegeraet liefert: alle gemeldeten Typen,
-- alle verfuegbaren Methoden und die Ergebnisse aller "read"-artigen Methoden
-- (list, get..., size, ...). Ideal um herauszufinden, welche Daten z. B.
-- Functional Storage, ME/RS Bridge, Drawer-Controller usw. bereitstellen.
--
-- Benutzung:
--   probe                 -> nur Functional-Storage-Geraete
--   probe all             -> ALLE Peripherals (ausser Modem)
--   probe drawer          -> alle Geraete, deren Name/Typ "drawer" enthaelt
--   probe <suchbegriff>   -> Filtert nach Name ODER Typ (Teilstring)

local args = { ... }
local filter = (args[1] or "functional"):lower()

-- Methoden, die wir gefahrlos aufrufen und ausgeben (keine Parameter noetig).
local READ_METHODS = {
    "list", "getItems", "getItemList", "getAllItems", "getAvailableItems",
    "listItems", "listFluid", "listFluids", "listGas", "listCells",
    "size", "getItemDetail", "getItemLimit",
    "getTotalItemStorage", "getUsedItemStorage", "getAvailableItemStorage",
    "getTotalFluidStorage", "getUsedFluidStorage", "getAvailableFluidStorage",
    "getMaxItemDiskStorage", "getMaxFluidDiskStorage",
    "getMaxItemExternalStorage", "getMaxFluidExternalStorage",
    "getEnergyStorage", "getMaxEnergyStorage", "getEnergyUsage",
    "getEnergyStored", "getMaxEnergyStored", "getStoredEnergy", "getEnergy",
    "getTransferRate", "getTransferRateLimit",
    "getCraftingCPUs", "isConnected", "getName",
}

-- Sichtbar machen, wieviele Kategorien / Zeilen gedruckt werden.
local function printf(fmt, ...)
    print(string.format(fmt, ...))
end

-- Wert kompakt und lesbar ausgeben (Tabellen werden zusammengefasst).
local function describe(value)
    local t = type(value)
    if t == "table" then
        local n = 0
        for _ in pairs(value) do n = n + 1 end
        -- Wenn es eine Item-/Fluid-Liste ist: erste paar Eintraege zeigen.
        local sample = {}
        local shown = 0
        for _, v in pairs(value) do
            if type(v) == "table" and (v.name or v.amount or v.count or v.displayName) then
                shown = shown + 1
                table.insert(sample, string.format("    - %s x%s",
                    tostring(v.displayName or v.name or "?"),
                    tostring(v.amount or v.count or "?")))
                if shown >= 5 then break end
            end
        end
        local head = string.format("table (%d Eintraege)", n)
        if #sample > 0 then
            return head .. "\n" .. table.concat(sample, "\n")
                .. (n > shown and string.format("\n    ... (+%d weitere)", n - shown) or "")
        end
        -- Sonst: kurze Serialisierung.
        local ok, s = pcall(textutils.serialize, value)
        if ok and #s < 400 then
            return head .. " = " .. s
        end
        return head
    end
    return string.format("%s (%s)", tostring(value), t)
end

local function matches(name, types)
    if filter == "all" then
        return true
    end
    if name:lower():find(filter, 1, true) then
        return true
    end
    for _, t in ipairs(types) do
        if tostring(t):lower():find(filter, 1, true) then
            return true
        end
    end
    return false
end

local function probeOne(name)
    local types = table.pack(peripheral.getType(name))
    local typeList = {}
    for i = 1, types.n do typeList[i] = types[i] end

    if not matches(name, typeList) then
        return false
    end

    -- Modems ueberspringen (nicht relevant).
    for _, t in ipairs(typeList) do
        if tostring(t):lower() == "modem" then return false end
    end

    print("========================================")
    printf("PERIPHERAL: %s", name)
    printf("TYPEN     : %s", table.concat(typeList, ", "))

    local dev = peripheral.wrap(name)
    if type(dev) ~= "table" then
        print("  (konnte nicht gewrappt werden)")
        return true
    end

    -- Alle verfuegbaren Methoden auflisten.
    local methods = peripheral.getMethods(name)
    if type(methods) == "table" then
        printf("METHODEN  (%d): %s", #methods, table.concat(methods, ", "))
    end

    -- Bekannte Read-Methoden aufrufen und Ergebnis anzeigen.
    print("--- WERTE ---")
    local printedAny = false
    for _, m in ipairs(READ_METHODS) do
        if type(dev[m]) == "function" then
            local ok, result = pcall(dev[m])
            if ok and result ~= nil then
                printf("%s -> %s", m, describe(result))
                printedAny = true
            end
        end
    end
    if not printedAny then
        print("  (keine der bekannten Read-Methoden lieferte Daten)")
    end
    return true
end

local function main()
    print("[PROBE] Filter: '" .. filter .. "'  (Tipp: 'probe all' fuer alles)")
    local names = peripheral.getNames()
    local hits = 0
    for _, name in ipairs(names) do
        local ok, shown = pcall(probeOne, name)
        if ok and shown then hits = hits + 1 end
    end
    print("========================================")
    printf("[PROBE] Fertig. %d von %d Peripherals passten zum Filter.", hits, #names)
    if hits == 0 then
        print("[PROBE] Nichts gefunden. Versuche 'probe all' oder einen anderen Suchbegriff.")
    end
end

main()
