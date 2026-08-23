-- bridge_test.lua  -  Gezielter Item-Test fuer ME / RS Bridge (v1.0)
--
-- Findet ALLE ME-/RS-Bridges im Netzwerk und testet Schritt fuer Schritt,
-- ob und wieviele Items sie liefern. Zeigt genau, WO es klemmt:
--   - Wird ueberhaupt eine Bridge gefunden?
--   - Welchen Typ meldet sie (meBridge / rsBridge / ...)?
--   - Was gibt listItems() zurueck (Typ, Anzahl, erste Eintraege)?
--   - Ist die Bridge mit dem Netzwerk verbunden (isConnected)?
--   - Wieviel Energie / Speicher meldet sie?
--
-- Benutzung einfach:  bridge_test
--
-- Tipp: Auf einem Computer mit direkt angesetzter Bridge ODER per Wired Modem
-- (roter Ring am Kabel aktiv!) ausfuehren. Die Bridge MUSS an das RS-/ME-Netz
-- angeschlossen sein, sonst liefert sie 0 Items.

local WANTED = { "meBridge", "me_bridge", "rsBridge", "rs_bridge" }

-- ---------------------------------------------------------------------------
--  Hilfen
-- ---------------------------------------------------------------------------

local function printf(fmt, ...)
    print(string.format(fmt, ...))
end

-- Peripherie-Methode gefahrlos aufrufen (ohne self, mit pcall).
local function call(dev, method, ...)
    if type(dev) ~= "table" or type(dev[method]) ~= "function" then
        return nil, "keine Methode: " .. method
    end
    local packed = table.pack(pcall(dev[method], ...))
    if not packed[1] then
        return nil, tostring(packed[2])
    end
    return packed[2]
end

local function normalize(t)
    return tostring(t or ""):gsub("[^%w]", ""):lower()
end

-- Zaehlt Eintraege einer beliebigen (auch luecken-behafteten) Tabelle.
local function countEntries(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function itemName(item)
    if type(item) ~= "table" then return tostring(item) end
    return item.displayName or item.name or item.technicalName or "?"
end

local function itemAmount(item)
    if type(item) ~= "table" then return 0 end
    return item.amount or item.count or 0
end

-- ---------------------------------------------------------------------------
--  Bridges finden
-- ---------------------------------------------------------------------------

local function listBridges()
    local out = {}
    for _, pname in ipairs(peripheral.getNames()) do
        local types = table.pack(peripheral.getType(pname))
        for i = 1, types.n do
            local nt = normalize(types[i])
            for _, want in ipairs(WANTED) do
                if nt == normalize(want) then
                    local ok, dev = pcall(peripheral.wrap, pname)
                    if ok and type(dev) == "table" then
                        out[#out + 1] = {
                            dev = dev, name = pname, rawType = types[i],
                            kind = nt:find("me") and "ME" or "RS",
                        }
                    end
                    break
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
--  Test-Ablauf
-- ---------------------------------------------------------------------------

print("=== bridge_test v1.0 ===")
print("")

-- 1) Alle Peripherie auflisten.
local names = peripheral.getNames()
printf("Angeschlossene Peripherie (%d):", #names)
for _, pname in ipairs(names) do
    printf("  - %-22s [%s]", pname, table.concat({ peripheral.getType(pname) }, ", "))
end
print("")

-- 2) Bridges filtern.
local bridges = listBridges()
if #bridges == 0 then
    print("!! KEINE ME/RS Bridge gefunden.")
    print("   -> Bridge direkt ansetzen ODER per Wired Modem verbinden")
    print("      und am Modem den roten Ring aktivieren (Rechtsklick).")
    return
end

printf("Gefundene Bridges: %d", #bridges)
print("")

-- 3) Jede Bridge einzeln durchtesten.
for idx, b in ipairs(bridges) do
    printf("--- Bridge #%d: %s  (%s, Typ '%s') ---", idx, b.name, b.kind, b.rawType)

    -- Verbindungsstatus.
    local conn = call(b.dev, "isConnected")
    if conn ~= nil then
        printf("  isConnected      : %s", tostring(conn))
    end

    -- Energie (nur zur Kontrolle, ob die Bridge ueberhaupt antwortet).
    local e   = call(b.dev, "getEnergyStorage")
    local em  = call(b.dev, "getMaxEnergyStorage")
    printf("  Energie          : %s / %s", tostring(e), tostring(em))

    -- Speicher-Kapazitaet.
    if b.kind == "ME" then
        printf("  Item-Speicher    : %s / %s Bytes",
            tostring(call(b.dev, "getUsedItemStorage")),
            tostring(call(b.dev, "getTotalItemStorage")))
    else
        printf("  Item-Disk max    : %s", tostring(call(b.dev, "getMaxItemDiskStorage")))
        printf("  Item-Extern max  : %s", tostring(call(b.dev, "getMaxItemExternalStorage")))
    end

    -- DER eigentliche Test: listItems.
    local items, err = call(b.dev, "listItems")
    if items == nil then
        printf("  listItems()      : FEHLER -> %s", tostring(err))
    else
        local n = countEntries(items)
        printf("  listItems()      : Typ=%s, Eintraege=%d", type(items), n)
        if n == 0 then
            print("     (leer! Bridge ist verbunden, aber das Netz meldet 0 Items")
            print("      -> falsches Netz? Storage nicht mit Bridge verkabelt?)")
        else
            local shown = 0
            for _, item in pairs(items) do
                shown = shown + 1
                printf("     %2d) %-28s x %s", shown, itemName(item), tostring(itemAmount(item)))
                if shown >= 10 then
                    if n > 10 then printf("     ... und %d weitere", n - 10) end
                    break
                end
            end
        end
    end

    print("")
end

print("=== fertig ===")
