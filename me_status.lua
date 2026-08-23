-- ============================================================================
--  ME STATUS DASHBOARD   (CC:Tweaked + Advanced Peripherals ME Bridge)
-- ----------------------------------------------------------------------------
--  Reines Monitoring (keine Steuerung!) des ME-Systems auf einem Advanced
--  Monitor. Zeigt Energie, Item-/Fluid-Speicher, Crafting-CPUs (Memory,
--  Co-Prozessoren, ob gerade gecraftet wird), Anzahl Rezepte/Patterns, eine
--  Platten-Uebersicht und die groessten Speicher-Verbraucher (anklickbar ->
--  Item-Detail).
--
--  Setup: Computer + Advanced Monitor + ME Bridge (direkt daneben ODER per
--  Wired Modem verbunden). Danach:  me_status
--
--  WICHTIG (CC:Tweaked): Peripherals UND window-Objekte werden OHNE self
--  aufgerufen -> obj.method(args), niemals obj:method(args).
--
--  Grenzen der ME-Bridge-API: AE2-Kanaele/Subnets und die Items EINER
--  EINZELNEN Platte werden von Advanced Peripherals NICHT bereitgestellt.
--  Diese Felder werden daher als "n/a" markiert bzw. aus listCells (Typen/
--  Bytes) und listItems (Top-Verbraucher) bestmoeglich hergeleitet.
-- ============================================================================

local SCRIPT_VERSION = "1.1"

local cfg = {
    title        = "ME SYSTEM",
    subtitle     = "Taracraft productions",
    refreshFast  = 1,     -- Sekunden: Energie / Speicher / CPUs
    refreshSlow  = 5,     -- Sekunden: Item-/Zellen-/Patternlisten (teurer)
    topConsumers = 12,    -- so viele Top-Verbraucher listen
    -- Optionale eigene Namen fuer die Crafting-CPUs (in Reihenfolge von
    -- getCraftingCPUs()). Leer lassen -> CPU #1, CPU #2, ...
    cpuNames     = {
        -- [1] = "Haupt",
        -- [2] = "Erze",
    },
}

-- ---------------------------------------------------------------------------
--  Hilfsfunktionen
-- ---------------------------------------------------------------------------

local function trim(value, maxLen)
    if type(value) ~= "string" then value = tostring(value or "") end
    if maxLen and #value > maxLen then return string.sub(value, 1, maxLen) end
    return value
end

-- Sicherer Methodenaufruf OHNE self (Peripherals + window-Objekte).
local function call(obj, method, ...)
    if type(obj) ~= "table" then return nil end
    local fn = obj[method]
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if not ok then return nil end
    return a
end

local function num(value)
    return tonumber(value) or 0
end

-- Grosse Zahlen kompakt: 1.5M / 2.3G / 4.8T.
local function humanize(n)
    n = num(n)
    local a = math.abs(n)
    if a >= 1e12 then return string.format("%.2fT", n / 1e12) end
    if a >= 1e9  then return string.format("%.2fG", n / 1e9)  end
    if a >= 1e6  then return string.format("%.2fM", n / 1e6)  end
    if a >= 1e3  then return string.format("%.1fK", n / 1e3)  end
    return tostring(math.floor(n + 0.5))
end

-- Ganze Zahl mit Tausenderpunkten: 2048 -> "2.048".
local function formatThousands(n)
    n = math.floor(num(n))
    local sign = n < 0 and "-" or ""
    local s = tostring(math.abs(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1."):reverse()
    out = out:gsub("^%.", "")
    return sign .. out
end

-- "minecraft:white_concrete" -> "White_Concrete".
local function prettify(id)
    id = tostring(id or "?")
    local afterColon = id:match(":(.+)$") or id
    local parts = {}
    for word in afterColon:gmatch("[^_]+") do
        parts[#parts + 1] = word:sub(1, 1):upper() .. word:sub(2)
    end
    if #parts == 0 then return afterColon end
    return table.concat(parts, "_")
end

local function normalizeTypeName(value)
    return (tostring(value or ""):lower():gsub("[^a-z0-9]", ""))
end

-- ---------------------------------------------------------------------------
--  Zustand
-- ---------------------------------------------------------------------------

local state = {
    bridge    = nil,
    bridgeKind = nil,      -- "me" | "rs"
    bridgeName = nil,
    monitor   = nil,
    canvas    = nil,
    view      = "status",  -- status | item | cells
    scroll    = 0,
    maxScroll = 0,
    lastVisible = 10,
    rowRects  = {},        -- [y] = { kind=..., payload=... }
    selectedItem = nil,
    lastFast  = 0,
    lastSlow  = 0,
    data = {
        energyStored = 0, energyMax = 0, energyUsage = 0,
        energyUnit = "AE",
        itemUsed = 0, itemTotal = 0, itemUnit = "Bytes",
        fluidUsed = 0, fluidTotal = 0,
        cpus = {}, cpuBusy = 0, cpuSupported = true,
        patterns = 0,
        cells = {},        -- gruppiert: { {name, count, totalBytes, cellType}, ... }
        cellCount = 0, cellsSupported = true,
        consumers = {},     -- { {name, display, amount, craftable}, ... }
        itemTypes = 0, itemTotalCount = 0,
        online = false,
    },
}

-- ---------------------------------------------------------------------------
--  Peripherie finden
-- ---------------------------------------------------------------------------

local function findByType(...)
    local wanted = { ... }
    -- Direktversuch.
    for _, name in ipairs(wanted) do
        local dev = peripheral.find(name)
        if dev then return dev end
    end
    -- Fallback: alle Namen scannen und Typen normalisiert vergleichen.
    for _, pname in ipairs(peripheral.getNames()) do
        local types = table.pack(peripheral.getType(pname))
        for i = 1, types.n do
            local nt = normalizeTypeName(types[i])
            for _, want in ipairs(wanted) do
                if nt == normalizeTypeName(want) then
                    local ok, wrapped = pcall(peripheral.wrap, pname)
                    if ok and type(wrapped) == "table" then return wrapped end
                end
            end
        end
    end
    return nil
end

-- Findet ALLE ME-/RS-Bridges im Netzwerk (der User kann beide haben).
local function listBridges()
    local out = {}
    local wanted = { "meBridge", "me_bridge", "rsBridge", "rs_bridge" }
    for _, pname in ipairs(peripheral.getNames()) do
        local types = table.pack(peripheral.getType(pname))
        for i = 1, types.n do
            local nt = normalizeTypeName(types[i])
            for _, want in ipairs(wanted) do
                if nt == normalizeTypeName(want) then
                    local ok, dev = pcall(peripheral.wrap, pname)
                    if ok and type(dev) == "table" then
                        out[#out + 1] = { dev = dev, kind = nt:find("me") and "me" or "rs", name = pname }
                    end
                    break
                end
            end
        end
    end
    return out
end

-- Waehlt automatisch die Bridge mit den MEISTEN Items (bevorzugt das volle
-- RS-System statt einer leeren ME Bridge).
local function selectBridge()
    local bridges = listBridges()
    local best, bestCount = nil, -1
    for _, b in ipairs(bridges) do
        local items = call(b.dev, "listItems")
        local n = 0
        if type(items) == "table" then for _ in pairs(items) do n = n + 1 end end
        if n > bestCount then best, bestCount = b, n end
    end
    if best then
        state.bridge     = best.dev
        state.bridgeKind = best.kind
        state.bridgeName = best.name
    end
    return state.bridge ~= nil
end

local function findBridge()
    return findByType("meBridge", "me_bridge")
end

local function findMonitor()
    return findByType("monitor")
end

-- ---------------------------------------------------------------------------
--  Zeichen-Primitive (auf dem Canvas / window)
-- ---------------------------------------------------------------------------

local function writeAt(c, x, y, text, fg, bg)
    if bg then c.setBackgroundColor(bg) end
    if fg then c.setTextColor(fg) end
    c.setCursorPos(x, y)
    c.write(text)
end

local function fillLine(c, y, width, bg)
    c.setBackgroundColor(bg)
    c.setCursorPos(1, y)
    c.write(string.rep(" ", width))
end

local function drawBar(c, x, y, width, percent, filled, empty)
    percent = math.max(0, math.min(100, percent or 0))
    local inner = math.max(0, width - 2)
    local fillN = math.floor((percent / 100) * inner + 0.5)
    writeAt(c, x, y, "[", colors.gray, colors.black)
    c.setCursorPos(x + 1, y)
    c.setBackgroundColor(filled)
    c.write(string.rep(" ", fillN))
    c.setBackgroundColor(empty)
    c.write(string.rep(" ", inner - fillN))
    writeAt(c, x + width - 1, y, "]", colors.gray, colors.black)
    c.setBackgroundColor(colors.black)
end

local function barColorFor(percent)
    if percent < 25 then return colors.red end
    if percent < 60 then return colors.yellow end
    return colors.green
end

-- ---------------------------------------------------------------------------
--  Monitor / Canvas
-- ---------------------------------------------------------------------------

local function createCanvas()
    local target = state.monitor or term.current()
    if state.monitor then
        call(state.monitor, "setTextScale", 0.5)
    end
    local w, h = target.getSize()
    local ok, win = pcall(window.create, target, 1, 1, w or 51, h or 19, true)
    if ok and win then
        state.canvas = win
    else
        state.canvas = nil
    end
end

local function attachMonitor()
    state.monitor = findMonitor()
    createCanvas()
end

-- ---------------------------------------------------------------------------
--  Datenerfassung
-- ---------------------------------------------------------------------------

local function collectFast()
    local b = state.bridge
    if not b then state.data.online = false return end

    local d = state.data
    local isRS = state.bridgeKind == "rs"
    d.online = true

    -- Energie (RS -> FE, ME -> AE).
    d.energyStored = num(call(b, "getEnergyStorage"))
    d.energyMax    = num(call(b, "getMaxEnergyStorage"))
    d.energyUsage  = num(call(b, "getEnergyUsage"))
    d.energyUnit   = isRS and "FE" or "AE"

    if isRS then
        -- RS: kein "used/total item storage" in Bytes. Kapazitaet = Disk +
        -- externer Speicher (in Stueck), Belegung = Summe aller Item-Mengen.
        d.itemTotal = num(call(b, "getMaxItemDiskStorage")) + num(call(b, "getMaxItemExternalStorage"))
        d.itemUsed  = d.itemTotalCount  -- wird in collectSlow gefuellt
        d.itemUnit  = "Stk."
        d.fluidTotal = num(call(b, "getMaxFluidDiskStorage")) + num(call(b, "getMaxFluidExternalStorage"))
        d.fluidUsed  = d.fluidUsedLive or 0
        d.cpuSupported   = false   -- RS hat keine Crafting-CPUs-API
        d.cellsSupported = false   -- RS hat kein listCells
        d.cpus = {}
        d.cpuBusy = 0
        return
    end

    -- ME: echte Byte-Werte.
    d.itemUnit   = "Bytes"
    d.itemUsed   = num(call(b, "getUsedItemStorage"))
    d.itemTotal  = num(call(b, "getTotalItemStorage"))
    d.fluidUsed  = num(call(b, "getUsedFluidStorage"))
    d.fluidTotal = num(call(b, "getTotalFluidStorage"))
    d.cpuSupported   = true
    d.cellsSupported = true

    -- Crafting-CPUs (Live: busy/idle) - nur ME.
    local cpus = call(b, "getCraftingCPUs")
    local list, busy = {}, 0
    if type(cpus) == "table" then
        local idx = 0
        for _, cpu in pairs(cpus) do
            if type(cpu) == "table" then
                idx = idx + 1
                local name = cpu.name
                if type(name) ~= "string" or name == "" then
                    name = cfg.cpuNames[idx] or ("CPU #" .. idx)
                end
                -- Manche AP-Versionen liefern ein aktuell craftendes Item mit.
                local craftingItem = cpu.craftingItem or cpu.activeItem or cpu.output
                local craftName
                if type(craftingItem) == "table" then
                    craftName = craftingItem.displayName or prettify(craftingItem.name)
                end
                if cpu.isBusy then busy = busy + 1 end
                list[idx] = {
                    name = name,
                    storage = num(cpu.storage),
                    coProcessors = num(cpu.coProcessors),
                    isBusy = cpu.isBusy and true or false,
                    craftName = craftName,
                }
            end
        end
    end
    d.cpus = list
    d.cpuBusy = busy
end

local function collectSlow()
    local b = state.bridge
    if not b then return end
    local d = state.data
    local isRS = state.bridgeKind == "rs"

    -- Alle Items -> Gesamtzahl, Typen, Top-Verbraucher, craftbare Anzahl.
    local items = call(b, "listItems")
    local flat = {}
    local totalCount, typeCount, craftableCount = 0, 0, 0
    if type(items) == "table" then
        for _, item in pairs(items) do
            if type(item) == "table" then
                local amount = num(item.amount or item.count)
                if amount > 0 then
                    typeCount = typeCount + 1
                    totalCount = totalCount + amount
                    if item.isCraftable then craftableCount = craftableCount + 1 end
                    flat[#flat + 1] = {
                        name = item.name,
                        display = item.displayName or prettify(item.name),
                        amount = amount,
                        craftable = item.isCraftable and true or false,
                    }
                end
            end
        end
    end
    table.sort(flat, function(a, c) return a.amount > c.amount end)
    d.itemTotalCount = totalCount
    d.itemTypes = typeCount

    local consumers = {}
    for i = 1, math.min(cfg.topConsumers, #flat) do
        consumers[i] = flat[i]
    end
    d.consumers = consumers

    -- Fluids (Summe der Mengen) - fuer RS als Belegung genutzt.
    local fluids = call(b, "listFluid") or call(b, "listFluids")
    local fluidSum = 0
    if type(fluids) == "table" then
        for _, f in pairs(fluids) do
            if type(f) == "table" then fluidSum = fluidSum + num(f.amount or f.count) end
        end
    end
    d.fluidUsedLive = fluidSum
    if isRS then
        d.itemUsed = totalCount
        d.fluidUsed = fluidSum
    end

    -- Rezepte / Patterns:
    --  Erst die dedizierte Liste probieren, sonst craftbare Items aus listItems
    --  zaehlen (funktioniert bei ME und RS unabhaengig von der API-Version).
    local craftItems = call(b, "listCraftableItems")
    local craftFluid = call(b, "listCraftableFluid") or call(b, "listCraftableFluids")
    local patterns = 0
    if type(craftItems) == "table" then for _ in pairs(craftItems) do patterns = patterns + 1 end end
    if type(craftFluid) == "table" then for _ in pairs(craftFluid) do patterns = patterns + 1 end end
    if patterns == 0 then patterns = craftableCount end
    d.patterns = patterns

    -- Platten / Zellen: nur ME (RS hat kein listCells).
    if isRS then
        d.cells = {}
        d.cellCount = 0
    else
        local cells = call(b, "listCells")
        local grouped, order = {}, {}
        local cellCount = 0
        if type(cells) == "table" then
            for _, cell in pairs(cells) do
                if type(cell) == "table" then
                    cellCount = cellCount + 1
                    local key = tostring(cell.item or "unbekannt")
                    if not grouped[key] then
                        grouped[key] = { name = prettify(key), count = 0, totalBytes = 0, cellType = cell.cellType or "?" }
                        order[#order + 1] = key
                    end
                    grouped[key].count = grouped[key].count + 1
                    grouped[key].totalBytes = grouped[key].totalBytes + num(cell.totalBytes)
                end
            end
        end
        local cellList = {}
        for _, key in ipairs(order) do cellList[#cellList + 1] = grouped[key] end
        table.sort(cellList, function(a, c) return a.totalBytes > c.totalBytes end)
        d.cells = cellList
        d.cellCount = cellCount
    end
end

-- ---------------------------------------------------------------------------
--  Ansichten: Zeilen aufbauen
-- ---------------------------------------------------------------------------

-- Baut die scrollbare Zeilenliste der Hauptansicht.
--  Zeilentypen: header | text | bar | row(click) | blank
local function buildStatusLines(width)
    local d = state.data
    local lines = {}
    local function add(t) lines[#lines + 1] = t end

    -- Energie.
    do
        local pct = d.energyMax > 0 and math.floor((d.energyStored / d.energyMax) * 100) or 0
        add({ kind = "header", text = "ENERGIE" })
        add({ kind = "text", text = string.format("%s / %s %s   (%s %s/t)",
            formatThousands(d.energyStored), formatThousands(d.energyMax), d.energyUnit,
            humanize(d.energyUsage), d.energyUnit) })
        add({ kind = "bar", percent = pct, color = colors.orange })
    end

    -- Item-Speicher.
    do
        local pct = d.itemTotal > 0 and math.floor((d.itemUsed / d.itemTotal) * 100) or 0
        add({ kind = "header", text = "ITEM-SPEICHER" })
        add({ kind = "text", text = string.format("%s / %s %s   (%d Typen, %s Stk.)",
            humanize(d.itemUsed), humanize(d.itemTotal), d.itemUnit, d.itemTypes, humanize(d.itemTotalCount)) })
        add({ kind = "bar", percent = pct, color = colors.green })
    end

    -- Fluid-Speicher.
    do
        local pct = d.fluidTotal > 0 and math.floor((d.fluidUsed / d.fluidTotal) * 100) or 0
        add({ kind = "header", text = "FLUID-SPEICHER" })
        add({ kind = "text", text = string.format("%s / %s mB",
            humanize(d.fluidUsed), humanize(d.fluidTotal)) })
        add({ kind = "bar", percent = pct, color = colors.lightBlue })
    end

    -- Crafting-CPUs (nur ME; RS hat keine CPU-API).
    if not d.cpuSupported then
        add({ kind = "header", text = "CRAFTING-CPUS" })
        add({ kind = "text", text = "n/a (Refined Storage stellt keine CPU-Daten bereit)", color = colors.gray })
    else
        add({ kind = "header", text = string.format("CRAFTING-CPUS  (Busy %d/%d)", d.cpuBusy, #d.cpus) })
        if #d.cpus == 0 then
            add({ kind = "text", text = "Keine Crafting-CPUs gefunden." })
        else
            for _, cpu in ipairs(d.cpus) do
                local statusText = cpu.isBusy and "CRAFTET" or "frei"
                local col = cpu.isBusy and colors.yellow or colors.lightGray
                local base = string.format("%s: %s  co:%d  mem:%s",
                    cpu.name, statusText, cpu.coProcessors, humanize(cpu.storage))
                add({ kind = "text", text = base, color = col })
                if cpu.isBusy and cpu.craftName then
                    add({ kind = "text", text = "   -> " .. cpu.craftName, color = colors.yellow })
                end
            end
        end
    end

    -- System-Infos.
    add({ kind = "header", text = "SYSTEM" })
    add({ kind = "text", text = string.format("Rezepte/Patterns: %s", formatThousands(d.patterns)) })
    if d.cellsSupported then
        add({ kind = "row", text = string.format("Platten: %d  (%d Typen)  antippen ->", d.cellCount, #d.cells),
            click = { kind = "cells" }, color = colors.white })
        add({ kind = "text", text = "AE2-Kanaele/Subnets: n/a (nicht per ME-Bridge abrufbar)", color = colors.gray })
    else
        add({ kind = "text", text = "Platten/Zellen: n/a (Refined Storage)", color = colors.gray })
    end

    -- Top-Verbraucher (anklickbar).
    add({ kind = "header", text = "GROESSTE VERBRAUCHER" })
    if #d.consumers == 0 then
        add({ kind = "text", text = "Keine Items im System." })
    else
        for _, it in ipairs(d.consumers) do
            local amountText = formatThousands(it.amount)
            local label = "[" .. it.display .. "]"
            local maxLabel = math.max(4, width - #amountText - 3)
            local text = string.format("%-" .. maxLabel .. "s %s", trim(label, maxLabel), amountText)
            add({ kind = "row", text = text, click = { kind = "item", item = it }, color = colors.white })
        end
    end

    return lines
end

-- ---------------------------------------------------------------------------
--  Rendering
-- ---------------------------------------------------------------------------

local function renderHeader(c, width, titleText)
    fillLine(c, 1, width, colors.blue)
    writeAt(c, 2, 1, trim(titleText, math.max(1, width - 10)), colors.white, colors.blue)
    local st = state.data.online and "ONLINE" or "OFFLINE"
    local stCol = state.data.online and colors.lime or colors.red
    writeAt(c, math.max(1, width - #st), 1, st, stCol, colors.blue)
    c.setBackgroundColor(colors.black)
end

local function renderStatus(c, width, height)
    renderHeader(c, width, cfg.title)
    writeAt(c, 2, 2, trim(cfg.subtitle, width - 2), colors.cyan, colors.black)
    local kindLabel = state.bridgeKind == "rs" and "RS" or (state.bridgeKind == "me" and "ME" or "?")
    writeAt(c, math.max(1, width - #kindLabel - 1), 2, kindLabel, colors.lightGray, colors.black)

    local top    = 4
    local bottom = height - 1
    local visible = math.max(1, bottom - top + 1)
    state.lastVisible = visible

    local lines = buildStatusLines(width)

    -- Sichtbare "Zeileneinheiten" zaehlen (Balken belegen eine extra Zeile).
    state.maxScroll = math.max(0, #lines - visible)
    state.scroll = math.max(0, math.min(state.scroll or 0, state.maxScroll))

    state.rowRects = {}
    local y = top
    for i = 1 + state.scroll, #lines do
        if y > bottom then break end
        local line = lines[i]
        if line.kind == "header" then
            writeAt(c, 1, y, trim("-- " .. line.text .. " --", width), colors.orange, colors.black)
        elseif line.kind == "bar" then
            drawBar(c, 1, y, math.min(width, 40), line.percent, line.color or barColorFor(line.percent), colors.gray)
            local pctText = (line.percent or 0) .. "%"
            writeAt(c, math.min(width, 40) + 2, y, pctText, colors.yellow, colors.black)
        elseif line.kind == "row" then
            writeAt(c, 1, y, "> ", colors.cyan, colors.black)
            writeAt(c, 3, y, trim(line.text, math.max(1, width - 2)), line.color or colors.white, colors.black)
            state.rowRects[y] = line.click
        else
            writeAt(c, 1, y, trim(line.text, width), line.color or colors.lightGray, colors.black)
        end
        y = y + 1
    end

    -- Fusszeile.
    local hints = {}
    if state.maxScroll > 0 then
        if state.scroll > 0 then hints[#hints + 1] = "^ oben" end
        if state.scroll < state.maxScroll then hints[#hints + 1] = "v unten" end
    end
    hints[#hints + 1] = "Zeile (>) = Details"
    writeAt(c, 1, height, trim(table.concat(hints, "  |  "), width), colors.cyan, colors.black)
end

local function renderItemDetail(c, width, height)
    local it = state.selectedItem
    renderHeader(c, width, "< Zurueck")
    if not it then state.view = "status" return end

    writeAt(c, 1, 3, trim("[" .. it.display .. "]", width), colors.yellow, colors.black)
    writeAt(c, 1, 4, string.rep("-", width), colors.gray, colors.black)
    writeAt(c, 1, 6, "Registry: ", colors.white, colors.black)
    writeAt(c, 11, 6, trim(tostring(it.name or "?"), width - 10), colors.lightGray)
    writeAt(c, 1, 7, "Menge: ", colors.white, colors.black)
    writeAt(c, 8, 7, formatThousands(it.amount) .. " Stk.", colors.lime)
    writeAt(c, 1, 8, "Craftbar: ", colors.white, colors.black)
    writeAt(c, 11, 8, it.craftable and "JA" or "NEIN", it.craftable and colors.lime or colors.red)

    writeAt(c, 1, height, trim("< oben antippen fuer zurueck", width), colors.cyan, colors.black)
end

local function renderCells(c, width, height)
    renderHeader(c, width, "< Zurueck  -  PLATTEN")
    local d = state.data
    writeAt(c, 1, 2, trim(string.format("%d Platten, %d Typen", d.cellCount, #d.cells), width),
        colors.lightGray, colors.black)
    writeAt(c, 1, 3, string.rep("-", width), colors.gray, colors.black)

    local top = 4
    local bottom = height - 1
    local visible = math.max(1, bottom - top + 1)
    state.lastVisible = visible
    state.maxScroll = math.max(0, #d.cells - visible)
    state.scroll = math.max(0, math.min(state.scroll or 0, state.maxScroll))

    local y = top
    for i = 1 + state.scroll, #d.cells do
        if y > bottom then break end
        local cell = d.cells[i]
        local right = string.format("x%d  %s B", cell.count, humanize(cell.totalBytes))
        local maxLeft = math.max(4, width - #right - 1)
        local left = string.format("%s (%s)", cell.name, cell.cellType)
        writeAt(c, 1, y, trim(left, maxLeft), colors.white, colors.black)
        writeAt(c, math.max(1, width - #right), y, right, colors.lightGray, colors.black)
        y = y + 1
    end

    local hints = { "< oben = zurueck" }
    if state.maxScroll > 0 then
        if state.scroll > 0 then hints[#hints + 1] = "^ oben" end
        if state.scroll < state.maxScroll then hints[#hints + 1] = "v unten" end
    end
    writeAt(c, 1, height, trim(table.concat(hints, "  |  "), width), colors.cyan, colors.black)
end

local function render()
    if not state.canvas then createCanvas() end
    local c = state.canvas
    if not c then
        print("[ME] Kein Anzeigepuffer - Rendering uebersprungen.")
        return
    end

    c.setVisible(false)
    c.setBackgroundColor(colors.black)
    c.clear()

    local width, height = c.getSize()
    width  = width or 51
    height = height or 19

    local ok, err = pcall(function()
        if state.view == "item" then
            renderItemDetail(c, width, height)
        elseif state.view == "cells" then
            renderCells(c, width, height)
        else
            renderStatus(c, width, height)
        end
    end)

    if not ok then
        c.setBackgroundColor(colors.black)
        c.setTextColor(colors.red)
        c.setCursorPos(1, 1)
        c.write(trim("Render-Fehler: " .. tostring(err), width))
        print("[ME] Render-Fehler: " .. tostring(err))
    end

    c.setVisible(true)
end

-- ---------------------------------------------------------------------------
--  Interaktion (Touch)
-- ---------------------------------------------------------------------------

local function handleTouch(x, y)
    if state.view == "item" then
        if y == 1 then state.view = "status"; state.scroll = 0; render() end
        return
    end
    if state.view == "cells" then
        if y == 1 then state.view = "status"; state.scroll = 0; render(); return end
        -- Scrollen per Antippen (obere/untere Haelfte).
        local half = 4 + math.floor((state.lastVisible or 10) / 2)
        if y < half then state.scroll = math.max(0, state.scroll - 5)
        else state.scroll = math.min(state.maxScroll, state.scroll + 5) end
        render()
        return
    end

    -- Statusansicht: anklickbare Zeile?
    local click = state.rowRects[y]
    if click then
        if click.kind == "item" then
            state.selectedItem = click.item
            state.view = "item"
        elseif click.kind == "cells" then
            state.view = "cells"
            state.scroll = 0
        end
        render()
        return
    end

    -- Sonst scrollen (obere/untere Haelfte).
    local half = 4 + math.floor((state.lastVisible or 10) / 2)
    if y < half then state.scroll = math.max(0, state.scroll - 5)
    else state.scroll = math.min(state.maxScroll, state.scroll + 5) end
    render()
end

-- ---------------------------------------------------------------------------
--  Hauptschleife
-- ---------------------------------------------------------------------------

local function ensureBridge()
    if not state.bridge then return selectBridge() end
    return true
end

local function main()
    print("[ME] ME Status Dashboard v" .. SCRIPT_VERSION .. " startet...")
    attachMonitor()

    if not ensureBridge() then
        print("[ME] Keine ME/RS Bridge gefunden. Bitte ME- oder RS-Bridge daneben")
        print("     setzen oder per Wired Modem verbinden. Warte...")
    end

    -- Erstbefuellung.
    if ensureBridge() then
        pcall(collectFast)
        pcall(collectSlow)
        state.lastFast = os.clock()
        state.lastSlow = os.clock()
    end
    render()

    local timer = os.startTimer(cfg.refreshFast)
    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "timer" and p1 == timer then
            local now = os.clock()
            if ensureBridge() then
                pcall(collectFast)
                if (now - (state.lastSlow or 0)) >= cfg.refreshSlow then
                    pcall(collectSlow)
                    state.lastSlow = now
                end
            end
            render()
            timer = os.startTimer(cfg.refreshFast)

        elseif event == "monitor_touch" then
            -- p1 = Seite, p2 = x, p3 = y
            handleTouch(p2, p3)

        elseif event == "monitor_resize" or event == "term_resize" then
            createCanvas()
            render()

        elseif event == "peripheral" or event == "peripheral_detach" then
            -- Hotplug: Monitor/Bridge neu suchen.
            selectBridge()
            attachMonitor()
            render()

        elseif event == "key" and p1 == keys.q then
            break
        end
    end

    if state.monitor then
        call(state.monitor, "setBackgroundColor", colors.black)
        call(state.monitor, "clear")
    end
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("[ME] Beendet.")
end

-- Automatischer Neustart bei unerwartetem Fehler (robuster Dauerbetrieb).
while true do
    local ok, err = pcall(main)
    if ok then break end
    print("[ME] Absturz: " .. tostring(err))
    print("[ME] Neustart in 3s... (Q zum Abbrechen)")
    sleep(3)
end
