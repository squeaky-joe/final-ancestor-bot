-- ServerStats v002
-- Real-time server statistics tracking for The Isle Evrima.
-- Tracks player count, species distribution, and diet types.
-- Updates Discord channel with live data.

local MOD_NAME    = "ServerStats"
local MOD_VERSION = "v002"

local SAVED_DIR    = "Mods/ServerStats/Saved"
local CONFIG_FILE  = SAVED_DIR .. "/config.json"
local RELOAD_FLAG  = SAVED_DIR .. "/reload.flag"
local STATS_FILE   = SAVED_DIR .. "/stats.ndjson"
local INBOX_PATH   = SAVED_DIR .. "/inbox.ndjson"
local RESULTS_FILE = "Mods/CommandBridge/Saved/results.ndjson"

local POLL_INTERVAL_MS = 5000  -- check stats / poll IPC inbox every 5s

local function log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(msg)))
end

-- ============================================================
-- File helpers
-- ============================================================

local function fileExists(path)
    local f = io.open(path, "rb"); if f == nil then return false end
    f:close(); return true
end

local function readAll(path)
    local f = io.open(path, "rb"); if f == nil then return nil end
    local body = f:read("*a"); f:close(); return body
end

local function appendLine(path, line)
    local f = io.open(path, "ab"); if f == nil then return false end
    f:write(line); f:write("\n"); f:close(); return true
end

local function consumeFlag(path)
    local f = io.open(path, "rb"); if f == nil then return nil end
    local body = f:read("*all") or ""; f:close()
    os.remove(path)
    body = body:gsub("^%s+", ""):gsub("%s+$", "")
    if body == "" then return nil end
    return body
end

local function ensureDir(path)
    local winPath = path:gsub("/", "\\")
    os.execute('mkdir "' .. winPath .. '" 2>nul')
end

-- ============================================================
-- JSON helpers
-- ============================================================

local function jsonReadBool(body, key)
    local v = string.match(body or "", '"'..key..'"%s*:%s*([%a]+)')
    if v == "true" then return true end
    if v == "false" then return false end
    return nil
end

local function jsonEscape(s)
    if s == nil then return "" end
    s = tostring(s)
    s = s:gsub("\\","\\\\"):gsub('"','\\"'):gsub("\n","\\n"):gsub("\r","\\r"):gsub("\t","\\t")
    return s
end

local function jsonReadString(body, key)
    return string.match(body or "", '"' .. key .. '"%s*:%s*"([^"]*)"')
end

-- Encode a flat string->number table (e.g. species counts) as a JSON object.
local function encodeCountMap(t)
    local parts = {}
    for k, v in pairs(t) do
        parts[#parts + 1] = string.format('"%s":%d', jsonEscape(k), v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- ============================================================
-- Config
-- ============================================================

local config = {
    enabled = true,
}

local function loadConfig()
    local body = readAll(CONFIG_FILE)
    if body == nil then return end
    local e = jsonReadBool(body, "enabled")
    if e ~= nil then config.enabled = e end
    log("Config loaded")
end

-- ============================================================
-- Presence registry
-- ============================================================

local presenceRegistry = {}
local PRESENCE_EXPIRY_SEC = 180

local function presenceUpdate(steam)
    if steam == nil or steam == "" then return end
    local s = tostring(steam)
    if not presenceRegistry[s] then presenceRegistry[s] = { firstSeen = os.time() } end
    presenceRegistry[s].lastSeen = os.time()
end

local function findGameMode()
    local candidates = {"BP_SurvivalGameMode_C","TISurvivalGameMode","TIGameModeBase","GameModeBase"}
    for _, name in ipairs(candidates) do
        local gm; pcall(function() gm = FindFirstOf(name) end)
        if gm ~= nil then return gm end
    end
    return nil
end

local function livePawnFromCtrl(ctrl)
    if ctrl == nil then return nil end
    local pawn; pcall(function() pawn = ctrl:K2_GetPawn() end)
    if pawn == nil then return nil end
    local addr; pcall(function() addr = pawn:GetAddress() end)
    if addr == nil or addr == 0 then return nil end
    return pawn
end

local function presenceRegisterHook()
    local ok, err = pcall(function()
        RegisterHook("/Script/TheIsle.TIPlayerController:SetAdminCred", function(ctrlParam, _)
            local self_; pcall(function() self_ = ctrlParam:get() end)
            if self_ == nil then return end
            local sId; pcall(function() sId = self_:GetSteamId() end)
            if sId == nil then return end
            local s; pcall(function() s = sId:ToString() end)
            if s ~= nil and tostring(s) ~= "" then presenceUpdate(s) end
        end)
    end)
    if ok then log("Presence hook registered") else log("Presence hook FAILED: "..tostring(err)) end
end

local function presenceStartRefreshTick()
    if LoopInGameThreadWithDelay == nil then return end
    LoopInGameThreadWithDelay(15000, function()
        local gm = findGameMode(); if gm == nil then return end
        local now = os.time()
        for steam, _ in pairs(presenceRegistry) do
            local ctrl; pcall(function() ctrl = gm:GetControllerBySteamId(steam) end)
            if ctrl == nil then presenceRegistry[steam] = nil
            else presenceRegistry[steam].lastSeen = now end
        end
    end)
    log("Presence refresh tick started")
end

local function enumerateOnlinePlayers()
    local results = {}
    local gm = findGameMode(); if gm == nil then return results end
    local now = os.time()
    for steam, entry in pairs(presenceRegistry) do
        if (now-entry.lastSeen) > PRESENCE_EXPIRY_SEC then
            presenceRegistry[steam] = nil
        else
            local ctrl; pcall(function() ctrl = gm:GetControllerBySteamId(steam) end)
            if ctrl == nil then presenceRegistry[steam] = nil
            else
                local pawn = livePawnFromCtrl(ctrl)
                results[#results+1] = { controller=ctrl, pawn=pawn, steam=steam }
            end
        end
    end
    return results
end

-- ============================================================
-- Server stats collection and reporting
-- ============================================================

-- Helper function to get species from pawn (simplified version)
local function getPlayerSpecies(pawn)
    if pawn == nil then return "Unknown" end
    
    local speciesName
    local ok = pcall(function() 
        speciesName = pawn:GetSpeciesName()
    end)
    
    if not ok or speciesName == nil then return "Unknown" end
    
    -- Clean up the species name
    speciesName = string.gsub(speciesName, "BP_", "")
    speciesName = string.gsub(speciesName, "_C", "")
    
    return speciesName
end

-- Species -> diet lookup (matches the playable roster in BodyDrop/Scripts/main.lua)
local SPECIES_DIET = {
    Tyrannosaurus      = "Carnivore",
    Allosaurus         = "Carnivore",
    Carnotaurus        = "Carnivore",
    Ceratosaurus       = "Carnivore",
    Deinosuchus        = "Carnivore",
    Dilophosaurus      = "Carnivore",
    Herrerasaurus      = "Carnivore",
    Pteranodon         = "Carnivore",
    Troodon            = "Carnivore",
    Compsognathus      = "Carnivore",
    Austroraptor       = "Carnivore",

    Triceratops        = "Herbivore",
    Stegosaurus        = "Herbivore",
    Diabloceratops     = "Herbivore",
    Dryosaurus         = "Herbivore",
    Hypsilophodon      = "Herbivore",
    Maiasaura          = "Herbivore",
    Pachycephalosaurus = "Herbivore",
    Tenontosaurus      = "Herbivore",
    Beipiaosaurus      = "Herbivore",
    Kentrosaurus       = "Herbivore",

    Gallimimus         = "Omnivore",
    Omniraptor         = "Omnivore",
}

-- Helper function to get diet type for a (already cleaned) species name
local function getPlayerDiet(species)
    return SPECIES_DIET[species] or "Unknown"
end

-- Build a snapshot of the current server state (player count, species
-- distribution, diet type breakdown). Shared by the periodic file logger
-- and the IPC endpoint below.
local function collectStatsSnapshot()
    local players = enumerateOnlinePlayers()

    local stats = {
        timestamp = os.time(),
        playerCount = #players,
        speciesDistribution = {},
        dietTypes = {
            carnivore = 0,
            herbivore = 0,
            omnivore = 0,
            unknown = 0
        }
    }

    for _, p in ipairs(players) do
        if p.pawn ~= nil then
            local species = getPlayerSpecies(p.pawn)
            local diet = getPlayerDiet(species)

            if stats.speciesDistribution[species] == nil then
                stats.speciesDistribution[species] = 0
            end
            stats.speciesDistribution[species] = stats.speciesDistribution[species] + 1

            if diet == "Carnivore" then
                stats.dietTypes.carnivore = stats.dietTypes.carnivore + 1
            elseif diet == "Herbivore" then
                stats.dietTypes.herbivore = stats.dietTypes.herbivore + 1
            elseif diet == "Omnivore" then
                stats.dietTypes.omnivore = stats.dietTypes.omnivore + 1
            else
                stats.dietTypes.unknown = stats.dietTypes.unknown + 1
            end
        end
    end

    return stats
end

local function statsToJson(stats)
    return string.format(
        '{"timestamp":%d,"playerCount":%d,"speciesDistribution":%s,"dietTypes":%s}',
        stats.timestamp,
        stats.playerCount,
        encodeCountMap(stats.speciesDistribution),
        encodeCountMap(stats.dietTypes)
    )
end

local function collectServerStats()
    if not config.enabled then return end
    appendLine(STATS_FILE, statsToJson(collectStatsSnapshot()))
end

-- ============================================================
-- IPC — serve server_stats requests routed from CommandBridge
-- ============================================================

local function emitIpcResult(id, steam, ok, msg)
    local line = string.format(
        '{"id":"%s","ts":%d,"source":"ServerStats","steam":"%s","ok":%s,"msg":"%s"}',
        jsonEscape(tostring(id or "")), os.time(), jsonEscape(tostring(steam or "")),
        tostring(ok == true), jsonEscape(msg or "")
    )
    appendLine(RESULTS_FILE, line)
end

local function pollInbox()
    if not fileExists(INBOX_PATH) then return end
    local stash = INBOX_PATH .. ".processing"
    os.remove(stash)
    os.rename(INBOX_PATH, stash)
    local body = readAll(stash)
    if body == nil or body == "" then os.remove(stash); return end

    for line in body:gmatch("[^\n]+") do
        local id    = jsonReadString(line, "id")
        local steam = jsonReadString(line, "steam") or ""

        local callOk, stats = pcall(collectStatsSnapshot)
        if callOk then
            emitIpcResult(id, steam, true, statsToJson(stats))
        else
            emitIpcResult(id, steam, false, "error: " .. tostring(stats))
        end
    end

    os.remove(stash)
end

-- ============================================================
-- Boot
-- ============================================================

local function safeCall(label, fn)
    local ok, err = pcall(fn)
    if not ok then log(string.format("safeCall(%s) failed: %s", label, tostring(err))) end
    return ok, err
end

log(string.format("Loading; version=%s", MOD_VERSION))

presenceRegisterHook()
presenceStartRefreshTick()

if LoopInGameThreadWithDelay ~= nil then
    local bootHandle
    bootHandle = LoopInGameThreadWithDelay(5000, function()
        log(string.format("Boot; version=%s", MOD_VERSION))
        ensureDir(SAVED_DIR)
        local testPath = SAVED_DIR .. "/.keep"
        local tf = io.open(testPath, "wb")
        if tf then tf:write(""); tf:close()
        else log("WARNING: cannot write to " .. SAVED_DIR .. " — directory creation may have failed!") end
        safeCall("loadConfig", loadConfig)
        if bootHandle ~= nil and CancelDelayedAction ~= nil then
            pcall(function() CancelDelayedAction(bootHandle) end)
        end
    end)

    LoopInGameThreadWithDelay(POLL_INTERVAL_MS, function()
        safeCall("collectServerStats", collectServerStats)
        safeCall("pollInbox", pollInbox)

        local reload = consumeFlag(RELOAD_FLAG)
        if reload ~= nil and RestartCurrentMod ~= nil then
            log("RELOAD"); RestartCurrentMod()
        end
    end)
end

log(string.format("Loaded; version=%s", MOD_VERSION))