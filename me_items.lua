-- ============================================================================
--  ME ITEM LIST   (CC:Tweaked + Advanced Peripherals ME Bridge)
-- ----------------------------------------------------------------------------
--  Reines Monitoring: listet ALLE Items des ME-Systems auf einem Advanced
--  Monitor, sortiert nach Menge. Volle Seiten koennen durchblaettert werden
--  (Touch oder Tastatur), es gibt Auto-Blaettern und eine Suche.
--
--  Setup: Computer + Advanced Monitor + ME Bridge (daneben ODER per Wired
--  Modem). Danach:  me_items
--
--  Bedienung:
--   * Monitor antippen: untere Leiste [< zurueck] [Auto] [weiter >] [Suche]
--   * Tastatur am Computer:
--       Pfeil links/rechts = Seite blaettern
--       Leertaste          = Auto-Blaettern an/aus
--       s                  = Suche eingeben
--       c                  = Suche loeschen
--       q                  = Beenden
--
--  WICHTIG (CC:Tweaked): Peripherals UND window-Objekte OHNE self aufrufen.
-- ============================================================================

local SCRIPT_VERSION = "1.2"

local cfg = {
    title        = "ME DASHBOARD / ITEMS",
    subtitle     = "Taracraft productions",
    refreshData  = 5,     -- Sekunden zwischen Neuladen der Item-Liste
    autoInterval = 5,     -- Sekunden pro Seite beim Auto-Blaettern
    autoEnabled  = true,  -- Auto-Blaettern beim Start aktiv?
}

-- ---------------------------------------------------------------------------
--  Hilfsfunktionen
-- ---------------------------------------------------------------------------

local function trim(value, maxLen)
    if type(value) ~= "string" then value = tostring(value or "") end
    if maxLen and #value > maxLen then return string.sub(value, 1, maxLen) end
    return value
end

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

local function num(value) return tonumber(value) or 0 end

local function formatThousands(n)
    n = math.floor(num(n))
    local sign = n < 0 and "-" or ""
    local s = tostring(math.abs(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1."):reverse()
    out = out:gsub("^%.", "")
    return sign .. out
end

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

local function normalizeTypeName(value)
    return (tostring(value or ""):lower():gsub("[^a-z0-9]", ""))
end

-- ---------------------------------------------------------------------------
--  Zustand
-- ---------------------------------------------------------------------------

local state = {
    bridge   = nil,
    bridgeKind = nil,  -- "me" | "rs"
    bridgeName = nil,
    monitor  = nil,
    canvas   = nil,
    allItems = {},     -- vollstaendige, sortierte Liste
    view     = {},     -- gefilterte Liste (Suche)
    query    = "",
    page     = 1,
    pages    = 1,
    perPage  = 10,
    auto     = cfg.autoEnabled,
    autoLeft = cfg.autoInterval,
    online   = false,
    buttons  = {},     -- Touch-Bereiche der Fussleiste: { {x1,x2,action}, ... }
    totalCount = 0,
    tick     = nil,    -- aktueller 1s-Timer (ID-Abgleich gegen alte Timer)
    sinceData = 0,     -- Sekunden seit letztem Neuladen der Item-Liste
}

-- Startet den 1s-Tick neu. Alte, noch schwebende Timer werden ueber den
-- ID-Abgleich (p1 == state.tick) ignoriert -> kein doppeltes Zaehlen.
local function restartTick()
    state.tick = os.startTimer(1)
end

-- ---------------------------------------------------------------------------
--  Peripherie
-- ---------------------------------------------------------------------------

local function findByType(...)
    local wanted = { ... }
    for _, name in ipairs(wanted) do
        local dev = peripheral.find(name)
        if dev then return dev end
    end
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

-- Waehlt automatisch die Bridge mit den MEISTEN Items (so wird das volle RS-
-- System bevorzugt, nicht eine leere ME Bridge).
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

local function findMonitor() return findByType("monitor") end

-- ---------------------------------------------------------------------------
--  Zeichnen
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

local function rankColor(rank)
    if rank == 1 then return colors.yellow end
    if rank == 2 then return colors.white end
    if rank == 3 then return colors.orange end
    return colors.cyan
end

local function createCanvas()
    local target = state.monitor or term.current()
    if state.monitor then
        call(state.monitor, "setTextScale", 0.5)
    end
    local w, h = target.getSize()
    local ok, win = pcall(window.create, target, 1, 1, w or 51, h or 19, true)
    state.canvas = (ok and win) or nil
end

local function attachMonitor()
    state.monitor = findMonitor()
    createCanvas()
end

-- ---------------------------------------------------------------------------
--  Daten
-- ---------------------------------------------------------------------------

local function refreshItems()
    local b = state.bridge
    if not b then state.online = false return end
    state.online = true

    local items = getBridgeItems(b)
    -- Liefert die aktuelle Bridge nichts, aber es gibt evtl. eine andere (z. B.
    -- RS statt leerer ME): neu waehlen und erneut versuchen.
    if type(items) ~= "table" or next(items) == nil then
        if selectBridge() and state.bridge ~= b then
            b = state.bridge
            items = getBridgeItems(b)
        end
    end

    local flat = {}
    local total = 0
    if type(items) == "table" then
        for _, item in pairs(items) do
            if type(item) == "table" then
                local amount = num(item.amount or item.count)
                if amount > 0 then
                    total = total + amount
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
    state.allItems = flat
    state.totalCount = total
end

-- Gefilterte Ansicht anhand der Suche neu aufbauen.
local function applyFilter()
    local q = state.query:lower()
    if q == "" then
        state.view = state.allItems
    else
        local out = {}
        for _, it in ipairs(state.allItems) do
            if it.display:lower():find(q, 1, true) or tostring(it.name):lower():find(q, 1, true) then
                out[#out + 1] = it
            end
        end
        state.view = out
    end
end

-- ---------------------------------------------------------------------------
--  Rendering
-- ---------------------------------------------------------------------------

local function render()
    if not state.canvas then createCanvas() end
    local c = state.canvas
    if not c then return end

    c.setVisible(false)
    c.setBackgroundColor(colors.black)
    c.clear()

    local width, height = c.getSize()
    width  = width or 51
    height = height or 19

    local ok, err = pcall(function()
        applyFilter()

        -- Kopf mit kompaktem Status-Badge.
        local st = state.online and "ONLINE" or "OFFLINE"
        local stBadge = " " .. st .. " "
        local stBg = state.online and colors.green or colors.red
        fillLine(c, 1, width, colors.purple)
        writeAt(c, 2, 1, trim(cfg.title, math.max(1, width - #stBadge - 3)), colors.white, colors.purple)
        writeAt(c, math.max(1, width - #stBadge + 1), 1, stBadge, colors.white, stBg)

        fillLine(c, 2, width, colors.gray)
        local subtitle = trim(cfg.subtitle, math.max(1, width - 2))
        writeAt(c, 2, 2, subtitle, colors.lightBlue, colors.gray)
        local kindLabel = state.bridgeKind == "rs" and "RS" or (state.bridgeKind == "me" and "ME" or "?")
        local info = string.format("%s  %d Typen  %s Stk.", kindLabel, #state.view, formatThousands(state.totalCount))
        local infoX = width - #info
        if infoX > #subtitle + 3 then
            writeAt(c, infoX, 2, info, colors.yellow, colors.gray)
        end

        if state.query ~= "" then
            fillLine(c, 3, width, colors.gray)
            writeAt(c, 1, 3, " SUCHE ", colors.black, colors.yellow)
            writeAt(c, 9, 3, trim(state.query, math.max(1, width - 8)), colors.white, colors.gray)
        else
            fillLine(c, 3, width, colors.lightGray)
            writeAt(c, 1, 3, " #  ITEM", colors.black, colors.lightGray)
            if width >= 18 then
                writeAt(c, width - 5, 3, "MENGE", colors.black, colors.lightGray)
            end
        end

        -- Listenbereich.
        local top    = 4
        local bottom = height - 1
        state.perPage = math.max(1, bottom - top + 1)
        state.pages   = math.max(1, math.ceil(#state.view / state.perPage))
        if state.page > state.pages then state.page = state.pages end
        if state.page < 1 then state.page = 1 end

        local startIdx = (state.page - 1) * state.perPage + 1
        local y = top
        for i = startIdx, math.min(#state.view, startIdx + state.perPage - 1) do
            local it = state.view[i]
            local amountText = trim(formatThousands(it.amount), math.max(1, width - 5))
            local amountX = math.max(4, width - #amountText + 1)
            local label = "[" .. it.display .. "]"
            local rowBg = ((i - startIdx) % 2 == 0) and colors.black or colors.gray
            local maxLabel = math.max(1, amountX - 5)
            fillLine(c, y, width, rowBg)
            writeAt(c, 1, y, string.format("%2d", i), rankColor(i), rowBg)
            writeAt(c, 4, y, trim(label, maxLabel), it.craftable and colors.lightBlue or colors.white, rowBg)
            writeAt(c, amountX, y, amountText, amountColor(it.amount), rowBg)
            y = y + 1
        end
        if #state.view == 0 then
            local emptyText = state.query ~= "" and "Keine Treffer fuer diese Suche." or "Keine Items im System."
            writeAt(c, math.max(1, math.floor((width - #emptyText) / 2)), top + 1,
                trim(emptyText, width), colors.orange, colors.black)
        end

        -- Fussleiste mit Buttons.
        state.buttons = {}
        fillLine(c, height, width, colors.gray)

        local pageText = string.format(" %d/%d ", state.page, state.pages)
        writeAt(c, 1, height, pageText, colors.white, colors.purple)

        local autoText
        if state.auto then
            autoText = string.format("[ Auto %ds ]", state.autoLeft)
        else
            autoText = "[ Pause ]"
        end

        -- Buttons rechtsbuendig anordnen: [< zur] [Auto] [weiter >] [Suche]
        local bSearch = "[ Suche ]"
        local bNext   = "[ weiter > ]"
        local bAuto   = autoText
        local bPrev   = "[ < zur ]"

        local xSearch = width - #bSearch - 1
        local xNext   = xSearch - #bNext - 1
        local xAuto   = xNext - #bAuto - 1
        local xPrev   = xAuto - #bPrev - 1

        local function button(x, label, action, fg, bg)
            if x < #pageText + 2 then return end   -- kein Platz -> weglassen
            writeAt(c, x, height, label, fg, bg)
            state.buttons[#state.buttons + 1] = { x1 = x, x2 = x + #label - 1, action = action }
        end
        button(xPrev, bPrev, "prev", colors.black, colors.cyan)
        button(xAuto, bAuto, "auto", colors.black, state.auto and colors.lime or colors.orange)
        button(xNext, bNext, "next", colors.black, colors.cyan)
        button(xSearch, bSearch, "search", colors.black, colors.yellow)

        c.setBackgroundColor(colors.black)
    end)

    if not ok then
        c.setBackgroundColor(colors.black)
        c.setTextColor(colors.red)
        c.setCursorPos(1, 1)
        c.write(trim("Render-Fehler: " .. tostring(err), width))
    end

    c.setVisible(true)
end

-- ---------------------------------------------------------------------------
--  Aktionen
-- ---------------------------------------------------------------------------

local function nextPage()
    state.page = state.page + 1
    if state.page > state.pages then state.page = 1 end
    state.autoLeft = cfg.autoInterval
end

local function prevPage()
    state.page = state.page - 1
    if state.page < 1 then state.page = state.pages end
    state.autoLeft = cfg.autoInterval
end

local function toggleAuto()
    state.auto = not state.auto
    state.autoLeft = cfg.autoInterval
end

-- Sucheingabe am Computer-Terminal (Monitor bleibt stehen).
local function promptSearch()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("== ME Item Suche ==")
    print("Suchbegriff eingeben (leer = alle anzeigen):")
    term.setTextColor(colors.yellow)
    local q = read()
    term.setTextColor(colors.white)
    state.query = q or ""
    state.page = 1
    print("[ME] Suche gesetzt: '" .. state.query .. "'")
    -- read() kann den Tick-Timer verschluckt haben -> sicher neu starten.
    restartTick()
end

local function handleTouch(x, y)
    for _, b in ipairs(state.buttons) do
        if y == select(2, state.canvas.getSize()) and x >= b.x1 and x <= b.x2 then
            if b.action == "prev" then prevPage()
            elseif b.action == "next" then nextPage()
            elseif b.action == "auto" then toggleAuto()
            elseif b.action == "search" then promptSearch() end
            render()
            return
        end
    end
    -- Antippen ausserhalb der Buttons: obere Haelfte = zurueck, untere = weiter.
    local _, h = state.canvas.getSize()
    if y < math.floor(h / 2) then prevPage() else nextPage() end
    render()
end

-- ---------------------------------------------------------------------------
--  Hauptschleife
-- ---------------------------------------------------------------------------

local function ensureBridge()
    -- Bridge (neu) waehlen, wenn keine da ist ODER die aktuelle nichts liefert.
    if not state.bridge then return selectBridge() end
    return true
end

local function main()
    print("[ME] ME Item List v" .. SCRIPT_VERSION .. " startet...")
    attachMonitor()

    if not ensureBridge() then
        print("[ME] Keine ME Bridge gefunden. Bitte daneben setzen oder")
        print("     per Wired Modem verbinden. Warte...")
    else
        pcall(refreshItems)
    end
    render()

    restartTick()

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "timer" and p1 == state.tick then
            -- 1x pro Sekunde: Auto-Blaettern + periodisches Neuladen der Liste.
            state.sinceData = state.sinceData + 1
            if state.sinceData >= cfg.refreshData then
                state.sinceData = 0
                if ensureBridge() then pcall(refreshItems) end
            end
            if state.auto then
                state.autoLeft = state.autoLeft - 1
                if state.autoLeft <= 0 then nextPage() end
            end
            render()
            restartTick()

        elseif event == "monitor_touch" then
            handleTouch(p2, p3)

        elseif event == "monitor_resize" or event == "term_resize" then
            createCanvas()
            render()

        elseif event == "peripheral" or event == "peripheral_detach" then
            selectBridge()
            attachMonitor()
            if ensureBridge() then pcall(refreshItems) end
            render()

        elseif event == "key" then
            if p1 == keys.right then nextPage(); render()
            elseif p1 == keys.left then prevPage(); render()
            elseif p1 == keys.space then toggleAuto(); render()
            elseif p1 == keys.s then promptSearch(); render()
            elseif p1 == keys.c then state.query = ""; state.page = 1; render()
            elseif p1 == keys.q then break end
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

while true do
    local ok, err = pcall(main)
    if ok then break end
    print("[ME] Absturz: " .. tostring(err))
    print("[ME] Neustart in 3s...")
    sleep(3)
end
