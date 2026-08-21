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

local SCRIPT_VERSION = "1.0"

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

local function normalizeTypeName(value)
    return (tostring(value or ""):lower():gsub("[^a-z0-9]", ""))
end

-- ---------------------------------------------------------------------------
--  Zustand
-- ---------------------------------------------------------------------------

local state = {
    bridge   = nil,
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

local function findBridge() return findByType("meBridge", "me_bridge") end
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

    local items = call(b, "listItems")
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
                        display = item.displayName or prettify(item.name),
                        amount = amount,
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

        -- Kopf.
        fillLine(c, 1, width, colors.blue)
        writeAt(c, 2, 1, trim(cfg.title, math.max(1, width - 10)), colors.white, colors.blue)
        local st = state.online and "ONLINE" or "OFFLINE"
        local stCol = state.online and colors.lime or colors.red
        writeAt(c, math.max(1, width - #st), 1, st, stCol, colors.blue)
        c.setBackgroundColor(colors.black)

        writeAt(c, 2, 2, trim(cfg.subtitle, width - 2), colors.cyan, colors.black)
        local info = string.format("%d Typen  |  %s Stk.", #state.view, formatThousands(state.totalCount))
        writeAt(c, math.max(1, width - #info), 2, info, colors.lightGray, colors.black)

        if state.query ~= "" then
            writeAt(c, 1, 3, trim("Suche: " .. state.query, width), colors.yellow, colors.black)
        else
            writeAt(c, 1, 3, string.rep("-", width), colors.gray, colors.black)
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
            local amountText = formatThousands(it.amount)
            local label = "[" .. it.display .. "]"
            local maxLabel = math.max(4, width - #amountText - 1)
            writeAt(c, 1, y, trim(label, maxLabel), colors.white, colors.black)
            writeAt(c, math.max(1, width - #amountText), y, amountText, colors.lime, colors.black)
            y = y + 1
        end
        if #state.view == 0 then
            writeAt(c, 1, top, "Keine Items gefunden.", colors.yellow, colors.black)
        end

        -- Fussleiste mit Buttons.
        state.buttons = {}
        fillLine(c, height, width, colors.gray)

        local pageText = string.format("Seite %d/%d", state.page, state.pages)
        writeAt(c, 2, height, pageText, colors.white, colors.gray)

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

        local function button(x, label, action)
            if x < #pageText + 3 then return end   -- kein Platz -> weglassen
            writeAt(c, x, height, label, colors.black, colors.lightGray)
            state.buttons[#state.buttons + 1] = { x1 = x, x2 = x + #label - 1, action = action }
        end
        button(xPrev, bPrev, "prev")
        button(xAuto, bAuto, "auto")
        button(xNext, bNext, "next")
        button(xSearch, bSearch, "search")

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
    if not state.bridge then state.bridge = findBridge() end
    return state.bridge ~= nil
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
            state.bridge = findBridge()
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
