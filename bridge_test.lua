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
--  Ausgabe mitschreiben (fuer den Drucker)
-- ---------------------------------------------------------------------------

-- Wir ersetzen print durch eine eigene Version, die jede Zeile zusaetzlich in
-- printLog sammelt. Am Ende wird printLog auf einen Printer gedruckt.
local realPrint = print
local printLog = {}
local function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    printLog[#printLog + 1] = table.concat(parts, "\t")
    realPrint(...)
end

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
--  Ausgabe auf Monitor (Screen) umleiten, falls einer vorhanden ist
-- ---------------------------------------------------------------------------

-- Sucht einen angeschlossenen Advanced Monitor und leitet die gesamte
-- Ausgabe dorthin um. Faellt sonst auf das Terminal zurueck.
local monitor = peripheral.find("monitor")
local prevTerm
if monitor then
    pcall(monitor.setTextScale, 0.5)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    prevTerm = term.redirect(monitor)
end

-- Am Ende (oder bei Fehler) das Terminal wiederherstellen.
local function restoreTerm()
    if prevTerm then
        term.redirect(prevTerm)
        prevTerm = nil
    end
end

-- ---------------------------------------------------------------------------
--  Test-Ablauf
-- ---------------------------------------------------------------------------

print("=== bridge_test v1.4 ===")
if monitor then
    print("(Ausgabe auf Monitor: " .. peripheral.getName(monitor) .. ")")
end
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
    restoreTerm()
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

    -- Falls listItems fehlt (neues AP-Bridge-System): andere Namen probieren.
    print("  Kandidaten fuer Item-Liste:")
    local candidates = {
        "listItems", "items", "getItems", "getItemList", "getAllItems",
        "getStoredItems", "getItemDetail", "list", "getItemsInStorage",
    }
    for _, m in ipairs(candidates) do
        if type(b.dev[m]) == "function" then
            local res = call(b.dev, m)
            if type(res) == "table" then
                printf("     %-20s -> OK, %d Eintraege", m, countEntries(res))
            else
                printf("     %-20s -> vorhanden, liefert %s", m, type(res))
            end
        end
    end

    -- ALLE verfuegbaren Methoden der Bridge auflisten (das zeigt die echten
    -- Namen des neuen Bridge-Systems).
    local methods = peripheral.getMethods(b.name)
    if type(methods) == "table" then
        table.sort(methods)
        printf("  Verfuegbare Methoden (%d):", #methods)
        local line = "    "
        for _, m in ipairs(methods) do
            if #line + #m + 2 > 50 then
                print(line)
                line = "    "
            end
            line = line .. m .. ", "
        end
        if line ~= "    " then print(line) end
    end

    print("")
end

-- ---------------------------------------------------------------------------
--  Zusaetzlich: normale Inventare (Kiste, Fass, RS/AE-Interface am Kabel)
-- ---------------------------------------------------------------------------
-- Wenn die Bridge 0 Items liefert, kann man Items auch direkt aus einem
-- Inventar lesen. Jedes Peripheriegeraet mit einer list()-Methode ist ein
-- Inventar (chest, barrel, drawer, functionalstorage, RS/AE Interface, ...).

print("--- Inventare (list-Methode) ---")
local foundInv = 0
for _, pname in ipairs(names) do
    local ok, dev = pcall(peripheral.wrap, pname)
    if ok and type(dev) == "table" and type(dev.list) == "function" then
        foundInv = foundInv + 1
        local contents, err = call(dev, "list")
        if contents == nil then
            printf("  %-22s list() FEHLER -> %s", pname, tostring(err))
        else
            local slots = countEntries(contents)
            local total = 0
            for _, it in pairs(contents) do total = total + (it.count or it.amount or 0) end
            local sz = call(dev, "size")
            printf("  %-22s belegte Slots=%d/%s, Items gesamt=%d",
                pname, slots, tostring(sz or "?"), total)
            local shown = 0
            for _, it in pairs(contents) do
                shown = shown + 1
                printf("     %2d) %-26s x %s", shown, itemName(it), tostring(itemAmount(it)))
                if shown >= 5 then
                    if slots > 5 then printf("     ... und %d weitere Slots", slots - 5) end
                    break
                end
            end
        end
    end
end
if foundInv == 0 then
    print("  Keine normalen Inventare gefunden.")
    print("  -> Tipp: RS/AE Interface oder Kiste per Wired Modem ans Kabel")
    print("     haengen, dann tauchen sie hier als Inventar auf.")
end
print("")

print("=== fertig ===")
restoreTerm()
if monitor then
    realPrint("[bridge_test] Ausgabe steht auf dem Monitor.")
end

-- ---------------------------------------------------------------------------
--  Gesammelte Ausgabe auf einen Drucker (Printer) drucken
-- ---------------------------------------------------------------------------

local function printToPaper()
    local printer = peripheral.find("printer")
    if not printer then
        realPrint("[bridge_test] Kein Printer gefunden - nichts gedruckt.")
        return
    end

    local paper = call(printer, "getPaperLevel") or 0
    local ink   = call(printer, "getInkLevel") or 0
    if paper < 1 then
        realPrint("[bridge_test] Printer hat kein Papier!")
        return
    end
    if ink < 1 then
        realPrint("[bridge_test] Printer hat keine Tinte (Farbstoff)!")
        return
    end

    local page = 0
    local function startPage()
        if not printer.newPage() then return false end
        page = page + 1
        pcall(printer.setPageTitle, "bridge_test #" .. page)
        return true
    end

    if not startPage() then
        realPrint("[bridge_test] newPage() fehlgeschlagen (Papier/Tinte pruefen).")
        return
    end

    local w, h = printer.getPageSize()
    w = w or 25
    h = h or 21
    local y = 1
    for _, line in ipairs(printLog) do
        local text = (line == "") and " " or line
        -- Zeilen, die breiter als die Seite sind, umbrechen.
        repeat
            local chunk = text:sub(1, w)
            text = text:sub(w + 1)
            printer.setCursorPos(1, y)
            printer.write(chunk)
            y = y + 1
            if y > h then
                printer.endPage()
                if not startPage() then
                    realPrint("[bridge_test] Papier/Tinte alle - Rest nicht gedruckt.")
                    return
                end
                y = 1
            end
        until #text == 0
    end
    printer.endPage()
    realPrint(string.format("[bridge_test] Auf Papier gedruckt: %d Seite(n).", page))
end

printToPaper()
