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
--  Diese Felder werden daher als "n/a" markiert bzw. aus getCells (Typen/
--  Bytes) und getItems (Top-Verbraucher) bestmoeglich hergeleitet.
-- ============================================================================

local SCRIPT_VERSION = "2.0"

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

-- AP 0.7 auf MC 1.21.1 nutzt getItems({}); aeltere Versionen listItems().
local function getBridgeItems(bridge)
    local items = call(bridge, "getItems", {})
    if type(items) == "table" then return items end
    return call(bridge, "listItems")
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

local function cleanItemLabel(value)
    local label = tostring(value or "?"):gsub("^%s+", ""):gsub("%s+$", "")
    while #label >= 2 and label:sub(1, 1) == "[" and label:sub(-1) == "]" do
        label = label:sub(2, -2):gsub("^%s+", ""):gsub("%s+$", "")
    end
    return label ~= "" and label or "?"
end

local CATEGORY_DEFS = {
    { key = "metals", label = "ERZE/METALLE", color = colors.orange },
    { key = "blocks", label = "BLOECKE", color = colors.lightBlue },
    { key = "tech", label = "TECHNIK", color = colors.magenta },
    { key = "food", label = "NAHRUNG", color = colors.lime },
    { key = "tools", label = "WERKZEUGE", color = colors.yellow },
    { key = "drops", label = "DROPS", color = colors.red },
    { key = "misc", label = "SONSTIGES", color = colors.gray },
}

local function itemCategory(item)
    local text = (tostring(item.name or "") .. " " .. tostring(item.display or "")):lower()
    if text:find("ingot", 1, true) or text:find("ore", 1, true)
        or text:find("dust", 1, true) or text:find("nugget", 1, true)
        or text:find("gem", 1, true) or text:find("raw_", 1, true)
        or text:find("diamond", 1, true) or text:find("emerald", 1, true)
        or text:find("crystal", 1, true) then return "metals" end
    if text:find("_block", 1, true) or text:find("stone", 1, true)
        or text:find("cobble", 1, true) or text:find("planks", 1, true)
        or text:find("_log", 1, true) or text:find("glass", 1, true)
        or text:find("concrete", 1, true) or text:find("brick", 1, true)
        or text:find("sand", 1, true) or text:find("dirt", 1, true) then return "blocks" end
    if text:find("circuit", 1, true) or text:find("processor", 1, true)
        or text:find("component", 1, true) or text:find("machine", 1, true)
        or text:find("cable", 1, true) or text:find("wire", 1, true)
        or text:find("gear", 1, true) or text:find("plate", 1, true) then return "tech" end
    if text:find("bread", 1, true) or text:find("apple", 1, true)
        or text:find("beef", 1, true) or text:find("pork", 1, true)
        or text:find("chicken", 1, true) or text:find("carrot", 1, true)
        or text:find("potato", 1, true) or text:find("berry", 1, true)
        or text:find("cookie", 1, true) or text:find("stew", 1, true)
        or text:find("food", 1, true) then return "food" end
    if text:find("sword", 1, true) or text:find("pickaxe", 1, true)
        or text:find("shovel", 1, true) or text:find("helmet", 1, true)
        or text:find("chestplate", 1, true) or text:find("leggings", 1, true)
        or text:find("boots", 1, true) or text:find("shield", 1, true)
        or text:find("bow", 1, true) then return "tools" end
    if text:find("bone", 1, true) or text:find("rotten", 1, true)
        or text:find("gunpowder", 1, true) or text:find("ender_pearl", 1, true)
        or text:find("blaze", 1, true) or text:find("slime", 1, true)
        or text:find("feather", 1, true) or text:find("string", 1, true) then return "drops" end
    return "misc"
end

local function summarizeCategories(items)
    local totals, total = {}, 0
    for _, item in ipairs(items) do
        local amount = num(item.amount)
        local key = itemCategory(item)
        totals[key] = (totals[key] or 0) + amount
        total = total + amount
    end
    local result = {}
    for _, def in ipairs(CATEGORY_DEFS) do
        local amount = totals[def.key] or 0
        if amount > 0 then
            result[#result + 1] = {
                key = def.key, label = def.label, color = def.color,
                amount = amount, share = total > 0 and amount / total or 0,
            }
        end
    end
    table.sort(result, function(a, b) return a.amount > b.amount end)
    return result
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
    navRects  = {},
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
        categories = {},
        history = {},
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
        local items = getBridgeItems(b.dev)
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

local function amountColor(amount)
    amount = num(amount)
    if amount >= 1000000 then return colors.lightBlue end
    if amount >= 10000 then return colors.cyan end
    if amount >= 1000 then return colors.lime end
    return colors.yellow
end

local BIG_GLYPHS = {
    ["0"] = { "###", "# #", "# #", "# #", "###" },
    ["1"] = { " # ", "## ", " # ", " # ", "###" },
    ["2"] = { "###", "  #", "###", "#  ", "###" },
    ["3"] = { "###", "  #", " ##", "  #", "###" },
    ["4"] = { "# #", "# #", "###", "  #", "  #" },
    ["5"] = { "###", "#  ", "###", "  #", "###" },
    ["6"] = { "###", "#  ", "###", "# #", "###" },
    ["7"] = { "###", "  #", "  #", " # ", " # " },
    ["8"] = { "###", "# #", "###", "# #", "###" },
    ["9"] = { "###", "# #", "###", "  #", "###" },
    ["%"] = { "# #", "  #", " # ", "#  ", "# #" },
}

local function clockText()
    local ok, value = pcall(function()
        return textutils.formatTime(os.time("local"), true)
    end)
    return ok and tostring(value) or "LIVE"
end

local function drawBigText(c, x, y, text, color, scaleX)
    scaleX = scaleX or 1
    local cursorX = x
    for char in tostring(text):gmatch(".") do
        local glyph = BIG_GLYPHS[char]
        if glyph then
            for row = 1, 5 do
                for column = 1, 3 do
                    if glyph[row]:sub(column, column) == "#" then
                        writeAt(c, cursorX + (column - 1) * scaleX, y + row - 1,
                            string.rep("#", scaleX), color, colors.black)
                    end
                end
            end
            cursorX = cursorX + 3 * scaleX + 1
        end
    end
    return cursorX - x
end

local function drawThinBar(c, x, y, width, ratio, filled, empty)
    if width <= 0 then return end
    ratio = math.max(0, math.min(1, ratio or 0))
    local fill = math.floor(width * ratio + 0.5)
    writeAt(c, x, y, string.rep(" ", width), colors.white, empty or colors.gray)
    if fill > 0 then
        writeAt(c, x, y, string.rep(" ", fill), colors.white, filled or colors.lime)
    end
    c.setBackgroundColor(colors.black)
end

local function drawCompositionBar(c, x, y, width, categories)
    if width <= 0 then return end
    writeAt(c, x, y, string.rep(" ", width), colors.white, colors.gray)
    local cursor, remaining = x, width
    for index, category in ipairs(categories) do
        if remaining <= 0 then break end
        local segment
        if index == #categories then
            segment = remaining
        else
            segment = math.min(remaining, math.max(1, math.floor(width * category.share + 0.5)))
        end
        writeAt(c, cursor, y, string.rep(" ", segment), colors.white, category.color)
        cursor = cursor + segment
        remaining = remaining - segment
    end
    c.setBackgroundColor(colors.black)
end

local function drawCategoryLegend(c, x, y, width, categories, maxRows)
    local cursorX, cursorY = x, y
    for _, category in ipairs(categories) do
        local label = string.format("%s %d%%", category.label, math.floor(category.share * 100 + 0.5))
        local needed = #label + 3
        if cursorX + needed - 1 > x + width - 1 then
            cursorX = x
            cursorY = cursorY + 1
        end
        if cursorY >= y + maxRows then break end
        writeAt(c, cursorX, cursorY, " ", colors.white, category.color)
        writeAt(c, cursorX + 2, cursorY, label, colors.lightGray, colors.black)
        cursorX = cursorX + needed
    end
end

local function drawHistory(c, x, y, width, height, history)
    if width <= 0 or height <= 0 then return end
    for row = 0, height - 1 do
        writeAt(c, x, y + row, string.rep(" ", width), colors.white, colors.black)
    end
    writeAt(c, x, y + height - 1, string.rep("-", width), colors.gray, colors.black)
    if #history == 0 then return end

    local first = math.max(1, #history - width + 1)
    local minValue, maxValue = history[first], history[first]
    for index = first, #history do
        minValue = math.min(minValue, history[index])
        maxValue = math.max(maxValue, history[index])
    end
    local range = math.max(1, maxValue - minValue)
    local sampleCount = #history - first + 1
    for column = 0, width - 1 do
        local source = first + math.floor(column * math.max(0, sampleCount - 1) / math.max(1, width - 1))
        local value = history[source] or history[#history]
        local ratio = (value - minValue) / range
        local filled = math.max(1, math.floor(ratio * math.max(1, height - 1) + 0.5))
        for offset = 0, filled - 1 do
            local py = y + height - 1 - offset
            writeAt(c, x + column, py, " ", colors.white,
                offset == filled - 1 and colors.lime or colors.green)
        end
    end
    c.setBackgroundColor(colors.black)
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
    d.energyStored = num(call(b, "getStoredEnergy") or call(b, "getEnergyStorage"))
    d.energyMax    = num(call(b, "getEnergyCapacity") or call(b, "getMaxEnergyStorage"))
    d.energyUsage  = num(call(b, "getEnergyUsage"))
    d.energyUnit   = isRS and "FE" or "AE"

    if isRS then
        -- Neue 1.21.1-API: getUsed/TotalItemStorage in Stueck. Legacy-RS:
        -- Kapazitaet aus Disk + externem Speicher, Belegung aus der Item-Liste.
        local newItemTotal = call(b, "getTotalItemStorage")
        if newItemTotal ~= nil then
            d.itemTotal = num(newItemTotal)
            d.itemUsed = num(call(b, "getUsedItemStorage"))
        else
            d.itemTotal = num(call(b, "getMaxItemDiskStorage")) + num(call(b, "getMaxItemExternalStorage"))
            d.itemUsed = d.itemTotalCount
        end
        d.itemUnit  = "Stk."
        local newFluidTotal = call(b, "getTotalFluidStorage")
        if newFluidTotal ~= nil then
            d.fluidTotal = num(newFluidTotal)
            d.fluidUsed = num(call(b, "getUsedFluidStorage"))
        else
            d.fluidTotal = num(call(b, "getMaxFluidDiskStorage")) + num(call(b, "getMaxFluidExternalStorage"))
            d.fluidUsed = d.fluidUsedLive or 0
        end
        d.cpuSupported   = false   -- RS hat keine Crafting-CPUs-API
        d.cellsSupported = type(b.getCells) == "function" or type(b.listCells) == "function"
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
    local items = getBridgeItems(b)
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
                        display = cleanItemLabel(item.displayName or prettify(item.name)),
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
    d.categories = summarizeCategories(flat)

    local history = d.history
    history[#history + 1] = totalCount
    while #history > 120 do table.remove(history, 1) end

    local consumers = {}
    for i = 1, math.min(cfg.topConsumers, #flat) do
        consumers[i] = flat[i]
    end
    d.consumers = consumers

    -- Fluids (Summe der Mengen) - fuer RS als Belegung genutzt.
    local fluids = call(b, "getFluids", {}) or call(b, "listFluid") or call(b, "listFluids")
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
    --  Erst die dedizierte Liste probieren, sonst craftbare Items aus getItems
    --  zaehlen (funktioniert bei ME und RS unabhaengig von der API-Version).
    local patterns = 0
    local allPatterns = call(b, "getPatterns")
    if type(allPatterns) == "table" then
        for _ in pairs(allPatterns) do patterns = patterns + 1 end
    else
        local craftItems = call(b, "getCraftableItems", {}) or call(b, "listCraftableItems")
        local craftFluid = call(b, "getCraftableFluids", {})
            or call(b, "listCraftableFluid") or call(b, "listCraftableFluids")
        if type(craftItems) == "table" then for _ in pairs(craftItems) do patterns = patterns + 1 end end
        if type(craftFluid) == "table" then for _ in pairs(craftFluid) do patterns = patterns + 1 end end
    end
    if patterns == 0 then patterns = craftableCount end
    d.patterns = patterns

    -- Neue API: getCells() fuer ME und RS; Legacy-ME: listCells().
    local cells = call(b, "getCells") or call(b, "listCells")
    if type(cells) == "table" then
        local grouped, order = {}, {}
        local cellCount = 0
        for _, cell in pairs(cells) do
            if type(cell) == "table" then
                cellCount = cellCount + 1
                local cellItem = cell.item
                local key = type(cellItem) == "table" and (cellItem.name or cellItem.displayName) or cellItem
                key = tostring(key or "unbekannt")
                if not grouped[key] then
                    grouped[key] = { name = prettify(key), count = 0, totalBytes = 0, cellType = cell.type or cell.cellType or "?" }
                    order[#order + 1] = key
                end
                grouped[key].count = grouped[key].count + 1
                grouped[key].totalBytes = grouped[key].totalBytes
                    + num(cell.bytes or cell.totalBytes or cell.capacity)
            end
        end
        local cellList = {}
        for _, key in ipairs(order) do cellList[#cellList + 1] = grouped[key] end
        table.sort(cellList, function(a, c) return a.totalBytes > c.totalBytes end)
        d.cells = cellList
        d.cellCount = cellCount
    else
        d.cells = {}
        d.cellCount = 0
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
        add({ kind = "header", text = "ENERGIE", color = colors.orange })
        add({ kind = "text", text = string.format("%s / %s %s   (%s %s/t)",
            formatThousands(d.energyStored), formatThousands(d.energyMax), d.energyUnit,
            humanize(d.energyUsage), d.energyUnit) })
        add({ kind = "bar", percent = pct, color = colors.orange })
    end

    -- Item-Speicher.
    do
        local pct = d.itemTotal > 0 and math.floor((d.itemUsed / d.itemTotal) * 100) or 0
        add({ kind = "header", text = "ITEM-SPEICHER", color = colors.lime })
        add({ kind = "text", text = string.format("%s / %s %s   (%d Typen, %s Stk.)",
            humanize(d.itemUsed), humanize(d.itemTotal), d.itemUnit, d.itemTypes, humanize(d.itemTotalCount)) })
        add({ kind = "bar", percent = pct, color = colors.green })
    end

    -- Fluid-Speicher.
    do
        local pct = d.fluidTotal > 0 and math.floor((d.fluidUsed / d.fluidTotal) * 100) or 0
        add({ kind = "header", text = "FLUID-SPEICHER", color = colors.lightBlue })
        add({ kind = "text", text = string.format("%s / %s mB",
            humanize(d.fluidUsed), humanize(d.fluidTotal)) })
        add({ kind = "bar", percent = pct, color = colors.lightBlue })
    end

    -- Crafting-CPUs (nur ME; RS hat keine CPU-API).
    if not d.cpuSupported then
        add({ kind = "header", text = "CRAFTING-CPUS", color = colors.magenta })
        add({ kind = "text", text = "n/a (Refined Storage stellt keine CPU-Daten bereit)", color = colors.gray })
    else
        add({ kind = "header", text = string.format("CRAFTING-CPUS  (Busy %d/%d)", d.cpuBusy, #d.cpus),
            color = colors.magenta })
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
    add({ kind = "header", text = "SYSTEM", color = colors.cyan })
    add({ kind = "text", text = string.format("Rezepte/Patterns: %s", formatThousands(d.patterns)) })
    if d.cellsSupported then
        add({ kind = "row", text = string.format("Platten: %d  (%d Typen)  antippen ->", d.cellCount, #d.cells),
            click = { kind = "cells" }, color = colors.white })
        add({ kind = "text", text = "AE2-Kanaele/Subnets: n/a (nicht per ME-Bridge abrufbar)", color = colors.gray })
    else
        add({ kind = "text", text = "Platten/Zellen: n/a (Refined Storage)", color = colors.gray })
    end

    -- Top-Verbraucher (anklickbar).
    add({ kind = "header", text = "GROESSTE VERBRAUCHER", color = colors.yellow })
    if #d.consumers == 0 then
        add({ kind = "text", text = "Keine Items im System." })
    else
        for _, it in ipairs(d.consumers) do
            local amountText = formatThousands(it.amount)
            local label = "[" .. it.display .. "]"
            add({ kind = "row", text = label, right = amountText, rightColor = amountColor(it.amount),
                click = { kind = "item", item = it }, color = it.craftable and colors.lightBlue or colors.white })
        end
    end

    return lines
end

-- ---------------------------------------------------------------------------
--  Rendering
-- ---------------------------------------------------------------------------

local function renderHeader(c, width, titleText)
    local st = state.data.online and "ONLINE" or "OFFLINE"
    local badge = " " .. st .. " "
    local badgeBg = state.data.online and colors.green or colors.red
    fillLine(c, 1, width, colors.purple)
    writeAt(c, 2, 1, trim(titleText, math.max(1, width - #badge - 3)), colors.white, colors.purple)
    writeAt(c, math.max(1, width - #badge + 1), 1, badge, colors.white, badgeBg)
    c.setBackgroundColor(colors.black)
end

local function renderStatusCompact(c, width, height)
    renderHeader(c, width, cfg.title)
    fillLine(c, 2, width, colors.gray)
    local kindLabel = state.bridgeKind == "rs" and "RS" or (state.bridgeKind == "me" and "ME" or "?")
    local kindBadge = " " .. kindLabel .. " "
    local kindBg = state.bridgeKind == "rs" and colors.magenta or colors.blue
    writeAt(c, 2, 2, trim(cfg.subtitle, math.max(1, width - #kindBadge - 3)), colors.lightBlue, colors.gray)
    writeAt(c, math.max(1, width - #kindBadge + 1), 2, kindBadge, colors.white, kindBg)

    fillLine(c, 3, width, colors.black)
    local summaryX = 2
    local function summaryPart(label, value, valueColor)
        local prefix = label .. " "
        if summaryX + #prefix + #value - 1 <= width then
            writeAt(c, summaryX, 3, prefix, colors.gray, colors.black)
            summaryX = summaryX + #prefix
            writeAt(c, summaryX, 3, value, valueColor, colors.black)
            summaryX = summaryX + #value + 3
        end
    end
    summaryPart("ITEMS", formatThousands(state.data.itemTotalCount), amountColor(state.data.itemTotalCount))
    summaryPart("TYPEN", tostring(state.data.itemTypes), colors.cyan)
    summaryPart("PATTERNS", formatThousands(state.data.patterns), colors.magenta)

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
            fillLine(c, y, width, colors.gray)
            writeAt(c, 2, y, trim(line.text, math.max(1, width - 2)), line.color or colors.orange, colors.gray)
        elseif line.kind == "bar" then
            local barWidth = math.min(width, math.max(4, math.min(width - 6, 40)))
            drawBar(c, 1, y, barWidth, line.percent, line.color or barColorFor(line.percent), colors.gray)
            local pctText = (line.percent or 0) .. "%"
            if barWidth + #pctText + 1 <= width then
                writeAt(c, barWidth + 2, y, pctText, line.color or colors.yellow, colors.black)
            end
        elseif line.kind == "row" then
            fillLine(c, y, width, colors.gray)
            writeAt(c, 1, y, "> ", colors.yellow, colors.gray)
            local right = line.right and trim(line.right, math.max(1, width - 4))
            local rightX = right and math.max(3, width - #right + 1) or nil
            local maxText = right and math.max(1, rightX - 4) or math.max(1, width - 2)
            writeAt(c, 3, y, trim(line.text, maxText), line.color or colors.white, colors.gray)
            if right then
                writeAt(c, rightX, y, right, line.rightColor or colors.lime, colors.gray)
            end
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
    fillLine(c, height, width, colors.gray)
    writeAt(c, 1, height, trim(table.concat(hints, "  |  "), width), colors.white, colors.gray)
end

local function renderStatusDashboard(c, width, height)
    local d = state.data
    state.rowRects = {}
    state.navRects = {}
    state.scroll = 0
    state.maxScroll = 0

    -- Schmale Kopfzeile wie ein Operations-Terminal.
    fillLine(c, 1, width, colors.black)
    writeAt(c, 2, 1, "ME STORAGE", colors.white, colors.black)
    local mode = state.bridgeKind == "rs" and "RS GRID" or "AE2 GRID"
    writeAt(c, 13, 1, "| " .. mode, colors.gray, colors.black)
    local typeText = string.format("%d ITEM TYPES", d.itemTypes)
    if 24 + #typeText < width - 8 then
        writeAt(c, 24, 1, typeText, colors.gray, colors.black)
    end
    local time = clockText()
    writeAt(c, math.max(1, width - #time + 1), 1, time, colors.lightGray, colors.black)

    -- Grosse Speicher-KPI links, Detailwerte rechts.
    local storagePercent = d.itemTotal > 0 and math.floor((d.itemUsed / d.itemTotal) * 100 + 0.5) or 0
    if d.itemUsed > 0 and storagePercent == 0 then storagePercent = 1 end
    storagePercent = math.max(0, math.min(100, storagePercent))
    local healthText, healthColor = "HEALTHY", colors.lime
    if not d.online then healthText, healthColor = "OFFLINE", colors.red
    elseif storagePercent >= 95 then healthText, healthColor = "FULL", colors.red
    elseif storagePercent >= 80 then healthText, healthColor = "HIGH", colors.orange
    elseif storagePercent >= 60 then healthText, healthColor = "MODERATE", colors.yellow end

    local scaleX = width >= 72 and 2 or 1
    local bigWidth = drawBigText(c, 2, 2, tostring(storagePercent) .. "%", healthColor, scaleX)
    writeAt(c, 2, 7, healthText, healthColor, colors.black)

    local statsX = math.max(18, bigWidth + 5)
    local statsWidth = math.max(8, width - statsX)
    local storageLine = string.format("%s / %s %s USED",
        humanize(d.itemUsed), humanize(d.itemTotal), d.itemUnit)
    writeAt(c, statsX, 2, trim(storageLine, statsWidth), colors.white, colors.black)
    drawThinBar(c, statsX, 3, statsWidth, storagePercent / 100, healthColor, colors.gray)
    writeAt(c, statsX, 4,
        trim(string.format("%s ITEMS  |  %d TYPES", formatThousands(d.itemTotalCount), d.itemTypes), statsWidth),
        colors.lightGray, colors.black)
    writeAt(c, statsX, 5,
        trim(string.format("ENERGY %s/%s %s  |  %s/t", humanize(d.energyStored), humanize(d.energyMax),
            d.energyUnit, humanize(d.energyUsage)), statsWidth), colors.lightGray, colors.black)
    writeAt(c, statsX, 6,
        trim(string.format("PATTERNS %s  |  CELLS %d", formatThousands(d.patterns), d.cellCount), statsWidth),
        colors.lightGray, colors.black)
    local cpuText = d.cpuSupported and string.format("CRAFTING %d/%d BUSY", d.cpuBusy, #d.cpus)
        or "CRAFTING DATA N/A"
    writeAt(c, statsX, 7, trim(cpuText, statsWidth), d.cpuBusy > 0 and colors.yellow or colors.gray, colors.black)

    -- Zusammensetzung.
    fillLine(c, 8, width, colors.black)
    writeAt(c, 2, 8, "COMPOSITION", colors.gray, colors.black)
    writeAt(c, math.max(2, width - 17), 8, "SHARE OF ITEMS", colors.gray, colors.black)
    drawCompositionBar(c, 2, 9, math.max(1, width - 3), d.categories)
    drawCategoryLegend(c, 2, 10, math.max(1, width - 3), d.categories, 2)

    -- Rollender Verlauf. Der untere Bereich behaelt immer genug Platz fuer Tabellen.
    local trendTitleY = 12
    local lowerTitleY = math.max(17, height - 8)
    local chartY = trendTitleY + 1
    local chartHeight = math.max(2, lowerTitleY - chartY)
    writeAt(c, 2, trendTitleY, "ITEM TREND", colors.gray, colors.black)
    local trendRange = ""
    if #d.history > 0 then
        trendRange = string.format("%s -> %s", humanize(d.history[1]), humanize(d.history[#d.history]))
        writeAt(c, math.max(2, width - #trendRange + 1), trendTitleY,
            trim(trendRange, width - 1), colors.gray, colors.black)
    end
    drawHistory(c, 2, chartY, math.max(1, width - 3), chartHeight, d.history)

    -- Untere Zweispaltenansicht.
    local splitX = math.floor(width * 0.60)
    writeAt(c, 2, lowerTitleY, "TOP CONSUMERS", colors.gray, colors.black)
    writeAt(c, splitX + 1, lowerTitleY, "SYSTEM LOAD", colors.gray, colors.black)
    local listStart, listEnd = lowerTitleY + 1, height - 2
    local leftEnd = splitX - 2
    local leftWidth = math.max(12, leftEnd - 1)
    local maxAmount = d.consumers[1] and d.consumers[1].amount or 1

    for row = 0, listEnd - listStart do
        local item = d.consumers[row + 1]
        if not item then break end
        local y = listStart + row
        local amount = humanize(item.amount)
        local barWidth = math.max(4, math.min(10, math.floor(leftWidth * 0.22)))
        local barX = leftEnd - #amount - barWidth
        local nameWidth = math.max(4, barX - 5)
        local swatchColor = colors.gray
        local key = itemCategory(item)
        for _, def in ipairs(CATEGORY_DEFS) do
            if def.key == key then swatchColor = def.color break end
        end
        writeAt(c, 2, y, " ", colors.white, swatchColor)
        writeAt(c, 4, y, trim(item.display, nameWidth), colors.lightGray, colors.black)
        drawThinBar(c, barX, y, barWidth, item.amount / math.max(1, maxAmount), swatchColor, colors.gray)
        writeAt(c, leftEnd - #amount + 1, y, amount, amountColor(item.amount), colors.black)
        state.rowRects[y] = state.rowRects[y] or {}
        state.rowRects[y][#state.rowRects[y] + 1] = {
            x1 = 1, x2 = splitX, kind = "item", item = item,
        }
    end

    local rightX, rightEnd = splitX + 1, width - 1
    local rightWidth = math.max(8, rightEnd - rightX + 1)
    local metrics = {
        { "CRAFTING", d.cpuSupported and string.format("%d/%d", d.cpuBusy, #d.cpus) or "N/A",
            d.cpuBusy > 0 and colors.yellow or colors.lime },
        { "PATTERNS", formatThousands(d.patterns), colors.magenta },
        { "CELLS", tostring(d.cellCount), colors.lightBlue, "cells" },
        { "ENERGY/T", humanize(d.energyUsage), colors.orange },
        { "BRIDGE", state.bridgeKind == "rs" and "RS" or "ME", colors.cyan },
        { "STATUS", healthText, healthColor },
    }
    for index = 1, math.min(#metrics, listEnd - listStart + 1) do
        local metric = metrics[index]
        local y = listStart + index - 1
        writeAt(c, rightX, y, trim(metric[1], math.max(1, rightWidth - #metric[2] - 2)), colors.gray, colors.black)
        writeAt(c, math.max(rightX, rightEnd - #metric[2] + 1), y, metric[2], metric[3], colors.black)
        if metric[4] then
            state.rowRects[y] = state.rowRects[y] or {}
            state.rowRects[y][#state.rowRects[y] + 1] = {
                x1 = rightX, x2 = width, kind = metric[4],
            }
        end
    end

    -- Eine kompakte Alarmzeile statt dekorativer Karten.
    local alertY = height - 1
    local alertText, alertColor = "No active alerts", colors.lime
    if not d.online then alertText, alertColor = "Bridge offline", colors.red
    elseif storagePercent >= 95 then alertText, alertColor = "Item storage is full", colors.red
    elseif storagePercent >= 80 then alertText, alertColor = "Item storage above 80%", colors.orange
    elseif d.cpuBusy > 0 then alertText, alertColor = string.format("%d crafting CPU(s) active", d.cpuBusy), colors.yellow end
    fillLine(c, alertY, width, colors.black)
    writeAt(c, 1, alertY, " ALERTS ", colors.black, colors.orange)
    writeAt(c, 10, alertY, trim(alertText, math.max(1, width - 9)), alertColor, colors.black)

    -- Funktionale Tab-Leiste.
    fillLine(c, height, width, colors.gray)
    local function tab(x, label, action, active)
        if x > width then return x end
        local text = " " .. label .. " "
        text = trim(text, math.max(1, width - x + 1))
        writeAt(c, x, height, text, active and colors.black or colors.white,
            active and colors.lightGray or colors.gray)
        state.navRects[#state.navRects + 1] = { x1 = x, x2 = x + #text - 1, action = action }
        return x + #text + 1
    end
    local footerX = tab(1, "OVERVIEW", "status", true)
    footerX = tab(footerX, "CELLS", "cells", false)
    local hint = "TOUCH ITEM = DETAILS"
    if footerX + #hint < width then
        writeAt(c, width - #hint + 1, height, hint, colors.lightGray, colors.gray)
    end
end

local function renderStatus(c, width, height)
    if width >= 48 and height >= 23 then
        renderStatusDashboard(c, width, height)
    else
        renderStatusCompact(c, width, height)
    end
end

local function renderItemDetail(c, width, height)
    local it = state.selectedItem
    renderHeader(c, width, "< Zurueck")
    if not it then state.view = "status" return end

    fillLine(c, 2, width, colors.gray)
    writeAt(c, 1, 2, " ITEM-DETAIL ", colors.black, colors.lightBlue)
    fillLine(c, 3, width, colors.black)
    writeAt(c, 1, 3, trim(" [" .. it.display .. "] ", width), colors.black, colors.yellow)

    writeAt(c, 1, 5, "REGISTRY", colors.cyan, colors.black)
    writeAt(c, 11, 5, trim(tostring(it.name or "?"), math.max(1, width - 10)), colors.lightGray, colors.black)
    writeAt(c, 1, 7, "MENGE", colors.cyan, colors.black)
    writeAt(c, 11, 7, formatThousands(it.amount) .. " Stk.", amountColor(it.amount), colors.black)
    writeAt(c, 1, 9, "CRAFTBAR", colors.cyan, colors.black)
    local craftText = it.craftable and " JA " or " NEIN "
    writeAt(c, 11, 9, craftText, colors.white, it.craftable and colors.green or colors.red)

    fillLine(c, height, width, colors.gray)
    writeAt(c, 1, height, trim("< Kopfzeile antippen: zurueck", width), colors.white, colors.gray)
end

local function renderCells(c, width, height)
    renderHeader(c, width, "< Zurueck  -  PLATTEN")
    local d = state.data
    fillLine(c, 2, width, colors.gray)
    writeAt(c, 2, 2, trim(string.format("%d Platten  |  %d Typen", d.cellCount, #d.cells), width - 1),
        colors.yellow, colors.gray)
    fillLine(c, 3, width, colors.lightGray)
    writeAt(c, 1, 3, "PLATTE / TYP", colors.black, colors.lightGray)
    if width >= 16 then writeAt(c, width - 6, 3, "GROESSE", colors.black, colors.lightGray) end

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
        local right = trim(string.format("x%d  %s B", cell.count, humanize(cell.totalBytes)),
            math.max(1, width - 4))
        local rightX = math.max(3, width - #right + 1)
        local maxLeft = math.max(1, rightX - 2)
        local left = string.format("%s (%s)", cell.name, cell.cellType)
        local rowBg = ((i - state.scroll) % 2 == 0) and colors.gray or colors.black
        fillLine(c, y, width, rowBg)
        writeAt(c, 1, y, trim(left, maxLeft), colors.white, rowBg)
        writeAt(c, rightX, y, right, colors.lightBlue, rowBg)
        y = y + 1
    end

    local hints = { "< oben = zurueck" }
    if state.maxScroll > 0 then
        if state.scroll > 0 then hints[#hints + 1] = "^ oben" end
        if state.scroll < state.maxScroll then hints[#hints + 1] = "v unten" end
    end
    fillLine(c, height, width, colors.gray)
    writeAt(c, 1, height, trim(table.concat(hints, "  |  "), width), colors.white, colors.gray)
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
    state.navRects = {}

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
    if not state.canvas then return end
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

    local _, height = state.canvas.getSize()
    if y == height then
        for _, nav in ipairs(state.navRects) do
            if x >= nav.x1 and x <= nav.x2 then
                if nav.action == "cells" then
                    state.view = "cells"
                    state.scroll = 0
                    state.selectedItem = nil
                else
                    state.view = "status"
                end
                render()
                return
            end
        end
    end

    -- Statusansicht: anklickbare Zeile?
    local rowEntry = state.rowRects[y]
    local click
    if rowEntry and rowEntry.kind then
        click = rowEntry
    elseif type(rowEntry) == "table" then
        for _, candidate in ipairs(rowEntry) do
            if x >= (candidate.x1 or 1) and x <= (candidate.x2 or math.huge) then
                click = candidate
                break
            end
        end
    end
    if click then
        if click.kind == "item" then
            state.selectedItem = click.item
            state.view = "item"
        elseif click.kind == "cells" then
            state.view = "cells"
            state.scroll = 0
            state.selectedItem = nil
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
