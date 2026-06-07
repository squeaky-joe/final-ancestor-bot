-- BodyDrop v002
-- Admin-only corpse spawner. Bodies are only dropped when an admin explicitly
-- runs /bodydrop spawn from Discord. No automatic spawning.
-- IPC: bodydrop commands routed from CommandBridge

local MOD_NAME    = "BodyDrop"
local MOD_VERSION = "v002"

local SAVED_DIR    = "Mods/BodyDrop/Saved"
local INBOX_PATH   = SAVED_DIR .. "/inbox.ndjson"
local RELOAD_FLAG  = SAVED_DIR .. "/reload.flag"
local RESULTS_FILE = "Mods/CommandBridge/Saved/results.ndjson"

local POLL_INTERVAL_MS = 2000

local function log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(msg)))
end

-- ============================================================
-- Species catalog
-- ============================================================

local SPECIES_PATHS = {
    Tyrannosaurus      = "/Game/TheIsle/Core/Characters/Dinosaurs/Tyrannosaurus/BP_Tyrannosaurus.BP_Tyrannosaurus_C",
    Triceratops        = "/Game/TheIsle/Core/Characters/Dinosaurs/Triceratops/BP_Triceratops.BP_Triceratops_C",
    Allosaurus         = "/Game/TheIsle/Core/Characters/Dinosaurs/Allosaurus/BP_Allosaurus.BP_Allosaurus_C",
    Stegosaurus        = "/Game/TheIsle/Core/Characters/Dinosaurs/Stegosaurus/BP_Stegosaurus.BP_Stegosaurus_C",
    Carnotaurus        = "/Game/TheIsle/Core/Characters/Dinosaurs/Carnotaurus/BP_Carnotaurus.BP_Carnotaurus_C",
    Ceratosaurus       = "/Game/TheIsle/Core/Characters/Dinosaurs/Ceratosaurus/BP_Ceratosaurus.BP_Ceratosaurus_C",
    Deinosuchus        = "/Game/TheIsle/Core/Characters/Dinosaurs/Deinosuchus/BP_Deinosuchus.BP_Deinosuchus_C",
    Diabloceratops     = "/Game/TheIsle/Core/Characters/Dinosaurs/Diabloceratops/BP_Diabloceratops.BP_Diabloceratops_C",
    Dilophosaurus      = "/Game/TheIsle/Core/Characters/Dinosaurs/Dilophosaurus/BP_Dilophosaurus.BP_Dilophosaurus_C",
    Dryosaurus         = "/Game/TheIsle/Core/Characters/Dinosaurs/Dryosaurus/BP_Dryosaurus.BP_Dryosaurus_C",
    Gallimimus         = "/Game/TheIsle/Core/Characters/Dinosaurs/Gallimimus/BP_Gallimimus.BP_Gallimimus_C",
    Herrerasaurus      = "/Game/TheIsle/Core/Characters/Dinosaurs/Herrerasaurus/BP_Herrerasaurus.BP_Herrerasaurus_C",
    Hypsilophodon      = "/Game/TheIsle/Core/Characters/Dinosaurs/Hypsilophodon/BP_Hypsilophodon.BP_Hypsilophodon_C",
    Maiasaura          = "/Game/TheIsle/Core/Characters/Dinosaurs/Maiasaura/BP_Maiasaura.BP_Maiasaura_C",
    Omniraptor         = "/Game/TheIsle/Core/Characters/Dinosaurs/Omniraptor/BP_Omniraptor.BP_Omniraptor_C",
    Pachycephalosaurus = "/Game/TheIsle/Core/Characters/Dinosaurs/Pachycephalosaurus/BP_Pachycephalosaurus.BP_Pachycephalosaurus_C",
    Pteranodon         = "/Game/TheIsle/Core/Characters/Dinosaurs/Pteranodon/BP_Pteranodon.BP_Pteranodon_C",
    Tenontosaurus      = "/Game/TheIsle/Core/Characters/Dinosaurs/Tenontosaurus/BP_Tenontosaurus.BP_Tenontosaurus_C",
    Troodon            = "/Game/TheIsle/Core/Characters/Dinosaurs/Troodon/BP_Troodon.BP_Troodon_C",
    Beipiaosaurus      = "/Game/TheIsle/Core/Characters/Dinosaurs/Beipiaosaurus/BP_Beipiaosaurus.BP_Beipiaosaurus_C",
    Compsognathus      = "/Game/TheIsle/Core/Characters/Dinosaurs/Compsognathus/BP_Compsognathus.BP_Compsognathus_C",
}

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
    return body ~= "" and body or nil
end

local function ensureDir(path)
    local winPath = path:gsub("/", "\\")
    os.execute('mkdir "' .. winPath .. '" 2>nul')
end

-- ============================================================
-- JSON helpers
-- ============================================================

local function jsonEscape(s)
    if s == nil then return "" end
    s = tostring(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return s
end

local function jsonReadString(body, key)
    return string.match(body or "", '"' .. key .. '"%s*:%s*"([^"]*)"')
end

local function jsonReadNumber(body, key)
    return tonumber(string.match(body or "", '"' .. key .. '"%s*:%s*(-?%d+%.?%d*)'))
end

-- ============================================================
-- Game helpers
-- ============================================================

local function findGameMode()
    local candidates = { "BP_SurvivalGameMode_C", "TISurvivalGameMode", "TIGameModeBase", "GameModeBase" }
    for _, name in ipairs(candidates) do
        local gm; pcall(function() gm = FindFirstOf(name) end)
        if gm ~= nil then return gm end
    end
    return nil
end

local function getPlayerLocation(steam)
    if steam == nil or steam == "" then return nil, "no steam id" end
    local gm = findGameMode()
    if gm == nil then return nil, "no game mode" end
    local ctrl; pcall(function() ctrl = gm:GetControllerBySteamId(steam) end)
    if ctrl == nil then return nil, "player not found or not online" end
    local pawn; pcall(function() pawn = ctrl:K2_GetPawn() end)
    if pawn == nil then return nil, "player has no pawn (not spawned)" end
    local loc; pcall(function() loc = pawn:K2_GetActorLocation() end)
    if loc == nil then return nil, "could not read pawn location" end
    return loc, nil
end

-- ============================================================
-- Corpse spawner
-- ============================================================

local SCATTER_OFFSETS = {
    { 3000,  3000, 0 }, { -3000,  3000, 0 },
    { 3000, -3000, 0 }, { -3000, -3000, 0 },
    { 4000,     0, 0 }, { -4000,     0, 0 },
    {    0,  4000, 0 }, {     0, -4000, 0 },
}

local function spawnCorpse(speciesName, location, growthFraction)
    local classPath = SPECIES_PATHS[speciesName]
    if classPath == nil then return false, "unknown species: " .. tostring(speciesName) end

    local pawnCls; pcall(function() pawnCls = StaticFindObject(classPath) end)
    if pawnCls == nil then return false, "class not found: " .. classPath end

    local gm = findGameMode()
    if gm == nil then return false, "no game mode" end
    local world; pcall(function() world = gm:GetWorld() end)
    if world == nil then return false, "no world" end

    for i = 0, #SCATTER_OFFSETS do
        local offset = SCATTER_OFFSETS[i] or { 0, 0, 0 }
        local loc = {
            X = location.X + offset[1],
            Y = location.Y + offset[2],
            Z = location.Z + offset[3] + 1500, -- +15m to land on terrain
        }

        local pawn; pcall(function() pawn = world:SpawnActor(pawnCls, loc, { Pitch = 0, Yaw = 0, Roll = 0 }) end)

        local validPawn = false
        if pawn ~= nil then
            local addr; pcall(function() addr = pawn:GetAddress() end)
            validPawn = (addr ~= nil and addr ~= 0)
        end

        if validPawn then
            pcall(function() pawn:SetReplicates(true) end)
            pcall(function() pawn.bAlwaysRelevant = true end)
            pcall(function() pawn:SetGrowth(growthFraction or 1.0) end)
            pcall(function() pawn:SetHealth(0) end)
            pcall(function() pawn.bIsDead = true end)
            pcall(function() pawn:OnRep_IsNowDead() end)
            pcall(function() pawn:ToggleServerRagdoll(true) end)
            pcall(function() pawn:ActivateDeadbody(false, 3600) end)
            pcall(function() pawn:ForceNetUpdate() end)
            return true, "spawned"
        end
    end

    return false, "all spawn positions failed"
end

-- ============================================================
-- IPC
-- ============================================================

local function emitResult(id, steam, tokens, ok, msg)
    local tokensJson = "["
    for i, t in ipairs(tokens) do
        if i > 1 then tokensJson = tokensJson .. "," end
        tokensJson = tokensJson .. '"' .. jsonEscape(t) .. '"'
    end
    tokensJson = tokensJson .. "]"
    local line = string.format(
        '{"id":"%s","ts":%d,"source":"BodyDrop","steam":"%s","args":%s,"ok":%s,"msg":"%s"}',
        jsonEscape(tostring(id or "")), os.time(),
        jsonEscape(tostring(steam)), tokensJson,
        tostring(ok == true), jsonEscape(tostring(msg or ""))
    )
    appendLine(RESULTS_FILE, line)
end

local function handleCommand(steam, tokens)
    local verb = tokens[1] or ""

    if verb == "spawn" then
        -- tokens: spawn <Species> <x> <y> <z> [growthFraction]
        -- If a target steam64 is provided, x/y/z are ignored and we look up their location.
        -- Bot sends: spawn <Species> <x> <y> <z> [growth] [targetSteam]
        local species = tokens[2]
        local x       = tonumber(tokens[3])
        local y       = tonumber(tokens[4])
        local z       = tonumber(tokens[5])
        local growth  = tonumber(tokens[6]) or 1.0
        local target  = tokens[7]  -- optional: steam64 of player to spawn near

        if species == nil then
            return false, "usage: spawn <Species> <x> <y> <z> [growth] [targetSteam]"
        end

        local location

        if target ~= nil and target ~= "" then
            -- Spawn near a live player
            local loc, err = getPlayerLocation(target)
            if loc == nil then return false, "cannot locate target: " .. tostring(err) end
            location = loc
        elseif x ~= nil and y ~= nil and z ~= nil then
            -- Spawn at explicit coordinates
            location = { X = x, Y = y, Z = z }
        else
            return false, "provide coordinates or a target steam64"
        end

        local ok, msg = spawnCorpse(species, location, growth)
        return ok, msg

    elseif verb == "status" then
        return true, string.format("BodyDrop %s | ready", MOD_VERSION)

    elseif verb == "diag" then
        local species = tokens[2] or "Triceratops"
        if SPECIES_PATHS[species] == nil then
            return false, "unknown species: " .. species
        end
        local cls; pcall(function() cls = StaticFindObject(SPECIES_PATHS[species]) end)
        return cls ~= nil, cls ~= nil and "class found" or "class NOT found on this server"
    end

    return false, "unknown verb: " .. tostring(verb)
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
        local argsBlock = string.match(line, '"args"%s*:%s*%[([^%]]*)%]')
        local tokens = {}
        if argsBlock then
            for s in argsBlock:gmatch('"([^"]*)"') do tokens[#tokens + 1] = s end
        end

        local callOk, r1, r2 = pcall(handleCommand, steam, tokens)
        if callOk then
            emitResult(id, steam, tokens, r1 == true, tostring(r2 or ""))
        else
            emitResult(id, steam, tokens, false, "error: " .. tostring(r1))
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

if LoopInGameThreadWithDelay ~= nil then
    local bootHandle
    bootHandle = LoopInGameThreadWithDelay(5000, function()
        log(string.format("Boot; version=%s", MOD_VERSION))
        ensureDir(SAVED_DIR)
        local tf = io.open(SAVED_DIR .. "/.keep", "wb")
        if tf then tf:write(""); tf:close()
        else log("WARNING: cannot write to " .. SAVED_DIR) end
        if bootHandle ~= nil and CancelDelayedAction ~= nil then
            pcall(function() CancelDelayedAction(bootHandle) end)
        end
    end)

    LoopInGameThreadWithDelay(POLL_INTERVAL_MS, function()
        safeCall("pollInbox", pollInbox)
        local reload = consumeFlag(RELOAD_FLAG)
        if reload ~= nil and RestartCurrentMod ~= nil then
            log("RELOAD"); RestartCurrentMod()
        end
    end)
end

log(string.format("Loaded; version=%s", MOD_VERSION))
