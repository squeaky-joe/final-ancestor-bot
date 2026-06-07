-- HeatmapCollector: samples all player XY positions periodically
-- and appends them to positions.ndjson for the Discord bot to consume.

local UEHelpers = require("UEHelpers")

-- ---- Config ----

local POLL_INTERVAL_MS  = 5 * 60 * 1000   -- 5 minutes
local SAVED_DIR         = "HeatmapCollector/Saved/"
local POSITIONS_FILE    = SAVED_DIR .. "positions.ndjson"
local KEEP_FILE         = SAVED_DIR .. ".keep"

-- ---- Directory creation ----

local function ensureDir(path)
    local winPath = path:gsub("/", "\\")
    os.execute('mkdir "' .. winPath .. '" 2>nul')
end

local function checkSavedDir()
    ensureDir(SAVED_DIR)
    local f = io.open(KEEP_FILE, "w")
    if f then f:close()
        print("[HeatmapCollector] Saved directory OK")
    else
        print("[HeatmapCollector] WARNING: Cannot write to " .. SAVED_DIR ..
              " — directory creation may have failed.")
    end
end

-- ---- Position writer ----

local function appendPositions(entries)
    if #entries == 0 then return end
    local f = io.open(POSITIONS_FILE, "a")
    if not f then
        print("[HeatmapCollector] ERROR: Cannot open " .. POSITIONS_FILE)
        return
    end
    for _, e in ipairs(entries) do
        f:write(e .. "\n")
    end
    f:close()
end

-- ---- Player iteration ----

local function collectPositions()
    local entries = {}
    local ts = os.time()

    local players = UEHelpers.GetGameModeBase() and
                    UEHelpers.GetGameModeBase():GetAllChildActors() or {}

    -- Walk all actors to find PlayerControllers, then get their pawns
    local allActors = FindAllOf("PlayerController")
    if not allActors then
        print("[HeatmapCollector] No PlayerControllers found this tick")
        return
    end

    for _, pc in ipairs(allActors) do
        local pawn = nil
        local ok = pcall(function()
            pawn = pc:GetPawn()
        end)
        if not ok or pawn == nil then goto continue_pc end

        local loc = nil
        local locOk = pcall(function()
            loc = pawn:GetActorLocation()
        end)

        if locOk and loc ~= nil then
            local entry = string.format(
                '{"x":%.1f,"y":%.1f,"ts":%d}',
                loc.X, loc.Y, ts
            )
            entries[#entries + 1] = entry
        end

        ::continue_pc::
    end

    if #entries > 0 then
        appendPositions(entries)
        print(string.format("[HeatmapCollector] Logged %d position(s)", #entries))
    end
end

-- ---- Poll loop ----

local function schedulePoll()
    ExecuteWithDelay(POLL_INTERVAL_MS, function()
        local ok, err = pcall(collectPositions)
        if not ok then
            print("[HeatmapCollector] Error during collection: " .. tostring(err))
        end
        schedulePoll()
    end)
end

-- ---- Init ----

checkSavedDir()
print("[HeatmapCollector] Started — polling every " .. (POLL_INTERVAL_MS / 60000) .. " minute(s)")
schedulePoll()
