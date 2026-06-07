-- BodyDrop v001
-- AI-free dead-body spawner. Spawns ragdolled corpses around eligible players.
-- IPC: bodydrop/bd verb routed from CommandBridge

local MOD_NAME    = "BodyDrop"
local MOD_VERSION = "v001"

local SAVED_DIR    = "Mods/BodyDrop/Saved"
local INBOX_PATH   = SAVED_DIR .. "/inbox.ndjson"
local EVENTS_FILE  = SAVED_DIR .. "/events.ndjson"
local CONFIG_FILE  = SAVED_DIR .. "/config.json"
local RELOAD_FLAG  = SAVED_DIR .. "/reload.flag"
local RESULTS_FILE = "Mods/CommandBridge/Saved/results.ndjson"

local POLL_INTERVAL_MS  = 5000
local SPAWN_INTERVAL_MS = 30000  -- auto-spawn tick

local function log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(msg)))
end

-- ============================================================
-- Species catalog
-- ============================================================

local SPECIES_PATHS = {
    Tyrannosaurus     = "/Game/TheIsle/Core/Characters/Dinosaurs/Tyrannosaurus/BP_Tyrannosaurus.BP_Tyrannosaurus_C",
    Triceratops       = "/Game/TheIsle/Core/Characters/Dinosaurs/Triceratops/BP_Triceratops.BP_Triceratops_C",
    Allosaurus        = "/Game/TheIsle/Core/Characters/Dinosaurs/Allosaurus/BP_Allosaurus.BP_Allosaurus_C",
    Stegosaurus       = "/Game/TheIsle/Core/Characters/Dinosaurs/Stegosaurus/BP_Stegosaurus.BP_Stegosaurus_C",
    Carnotaurus       = "/Game/TheIsle/Core/Characters/Dinosaurs/Carnotaurus/BP_Carnotaurus.BP_Carnotaurus_C",
    Ceratosaurus      = "/Game/TheIsle/Core/Characters/Dinosaurs/Ceratosaurus/BP_Ceratosaurus.BP_Ceratosaurus_C",
    Deinosuchus       = "/Game/TheIsle/Core/Characters/Dinosaurs/Deinosuchus/BP_Deinosuchus.BP_Deinosuchus_C",
    Diabloceratops    = "/Game/TheIsle/Core/Characters/Dinosaurs/Diabloceratops/BP_Diabloceratops.BP_Diabloceratops_C",
    Dilophosaurus     = "/Game/TheIsle/Core/Characters/Dinosaurs/Dilophosaurus/BP_Dilophosaurus.BP_Dilophosaurus_C",
    Dryosaurus        = "/Game/TheIsle/Core/Characters/Dinosaurs/Dryosaurus/BP_Dryosaurus.BP_Dryosaurus_C",
    Gallimimus        = "/Game/TheIsle/Core/Characters/Dinosaurs/Gallimimus/BP_Gallimimus.BP_Gallimimus_C",
    Herrerasaurus     = "/Game/TheIsle/Core/Characters/Dinosaurs/Herrerasaurus/BP_Herrerasaurus.BP_Herrerasaurus_C",
    Hypsilophodon     = "/Game/TheIsle/Core/Characters/Dinosaurs/Hypsilophodon/BP_Hypsilophodon.BP_Hypsilophodon_C",
    Maiasaura         = "/Game/TheIsle/Core/Characters/Dinosaurs/Maiasaura/BP_Maiasaura.BP_Maiasaura_C",
    Omniraptor        = "/Game/TheIsle/Core/Characters/Dinosaurs/Omniraptor/BP_Omniraptor.BP_Omniraptor_C",
    Pachycephalosaurus = "/Game/TheIsle/Core/Characters/Dinosaurs/Pachycephalosaurus/BP_Pachycephalosaurus.BP_Pachycephalosaurus_C",
    Pteranodon        = "/Game/TheIsle/Core/Characters/Dinosaurs/Pteranodon/BP_Pteranodon.BP_Pteranodon_C",
    Tenontosaurus     = "/Game/TheIsle/Core/Characters/Dinosaurs/Tenontosaurus/BP_Tenontosaurus.BP_Tenontosaurus_C",
    Troodon           = "/Game/TheIsle/Core/Characters/Dinosaurs/Troodon/BP_Troodon.BP_Troodon_C",
    Beipiaosaurus     = "/Game/TheIsle/Core/Characters/Dinosaurs/Beipiaosaurus/BP_Beipiaosaurus.BP_Beipiaosaurus_C",
    Compsognathus     = "/Game/TheIsle/Core/Characters/Dinosaurs/Compsognathus/BP_Compsognathus.BP_Compsognathus_C",
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
    body = body:gsub("^%s+",""):gsub("%s+$","")
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
    s = s:gsub("\\","\\\\"):gsub('"','\\"'):gsub("\n","\\n"):gsub("\r","\\r"):gsub("\t","\\t")
    return s
end

local function jsonReadString(body, key)
    return string.match(body or "", '"'..key..'"%s*:%s*"([^"]*)"')
end

local function jsonReadNumber(body, key)
    return tonumber(string.match(body or "", '"'..key..'"%s*:%s*(-?%d+%.?%d*)'))
end

local function jsonReadBool(body, key)
    local v = string.match(body or "", '"'..key..'"%s*:%s*([%a]+)')
    if v == "true" then return true end
    if v == "false" then return false end
    return nil
end

-- ============================================================
-- Config
-- ============================================================

local config = {
    enabled                  = true,
    autoSpawnEnabled         = true,
    growthFilterEnabled      = false,
    maxGrowthPercent         = 70,
    hungerFilterEnabled      = false,
    maxHungerPercent         = 15,
    spawnForHerbivores       = true,
    excludeSameSpecies       = false,
    ragdollSeconds           = 3600,
    scatterRadius            = 5000,  -- UU
    adminSteamIds            = {},
}

local function loadConfig()
    local body = readAll(CONFIG_FILE)
    if body == nil then return end
    local function rb(k) local v = jsonReadBool(body,k); if v ~= nil then return v end end
    local function rn(k) return jsonReadNumber(body,k) end
    if rb("enabled") ~= nil then config.enabled = rb("enabled") end
    if rb("autoSpawnEnabled") ~= nil then config.autoSpawnEnabled = rb("autoSpawnEnabled") end
    if rb("growthFilterEnabled") ~= nil then config.growthFilterEnabled = rb("growthFilterEnabled") end
    if rn("maxGrowthPercent") ~= nil then config.maxGrowthPercent = rn("maxGrowthPercent") end
    if rb("hungerFilterEnabled") ~= nil then config.hungerFilterEnabled = rb("hungerFilterEnabled") end
    if rn("maxHungerPercent") ~= nil then config.maxHungerPercent = rn("maxHungerPercent") end
    if rb("spawnForHerbivores") ~= nil then config.spawnForHerbivores = rb("spawnForHerbivores") end
    if rb("excludeSameSpecies") ~= nil then config.excludeSameSpecies = rb("excludeSameSpecies") end
    if rn("ragdollSeconds") ~= nil then config.ragdollSeconds = rn("ragdollSeconds") end
    if rn("scatterRadius") ~= nil then config.scatterRadius = rn("scatterRadius") end
    local adminBlock = string.match(body, '"adminSteamIds"%s*:%s*%[(.-)%]')
    if adminBlock then
        config.adminSteamIds = {}
        for s in adminBlock:gmatch('"([^"]+)"') do config.adminSteamIds[s] = true end
    end
    log("Config loaded")
end

local function isAdmin(steam)
    return steam ~= nil and config.adminSteamIds[tostring(steam)] == true
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
-- Corpse spawn recipe
-- ============================================================

local SCATTER_OFFSETS = {
    {3000, 3000, 0}, {-3000, 3000, 0}, {3000, -3000, 0}, {-3000, -3000, 0},
    {4000, 0, 0}, {-4000, 0, 0}, {0, 4000, 0}, {0, -4000, 0},
}

local function spawnCorpse(speciesName, location, growthFraction)
    local classPath = SPECIES_PATHS[speciesName]
    if classPath == nil then return nil, "unknown species: "..tostring(speciesName) end

    local pawnCls; pcall(function() pawnCls = StaticFindObject(classPath) end)
    if pawnCls == nil then return nil, "class not found: "..classPath end

    local gm = findGameMode()
    if gm == nil then return nil, "no game mode" end
    local world; pcall(function() world = gm:GetWorld() end)
    if world == nil then return nil, "no world" end

    for i = 0, #SCATTER_OFFSETS do
        local offset = SCATTER_OFFSETS[i] or {0, 0, 0}
        local loc = {
            X = location.X + offset[1],
            Y = location.Y + offset[2],
            Z = location.Z + offset[3] + 1500,  -- +15m to land on terrain
        }
        local pawn
        pcall(function() pawn = world:SpawnActor(pawnCls, loc, {Pitch=0,Yaw=0,Roll=0}) end)

        local validPawn = false
        if pawn ~= nil then
            local addr; pcall(function() addr = pawn:GetAddress() end)
            validPawn = (addr ~= nil and addr ~= 0)
        end

        if validPawn then
            -- Network flags
            pcall(function() pawn:SetReplicates(true) end)
            pcall(function() pawn.bAlwaysRelevant = true end)
            -- Growth (before corpse state)
            pcall(function() pawn:SetGrowth(growthFraction or 1.0) end)
            -- Corpse state sequence — order matters
            pcall(function() pawn:SetHealth(0) end)
            pcall(function() pawn.bIsDead = true end)
            pcall(function() pawn:OnRep_IsNowDead() end)
            pcall(function() pawn:ToggleServerRagdoll(true) end)
            pcall(function() pawn:ActivateDeadbody(false, config.ragdollSeconds) end)
            pcall(function() pawn:ForceNetUpdate() end)
            return true, "spawned"
        end
    end

    return false, "all spawn positions failed"
end

-- ============================================================
-- Auto-spawn loop
-- ============================================================

-- Herbivore species for auto-spawning (prefer feeding carnivores)
local HERBIVORE_PATHS_SET = {
    "/Game/TheIsle/Core/Characters/Dinosaurs/Triceratops/BP_Triceratops.BP_Triceratops_C",
    "/Game/TheIsle/Core/Characters/Dinosaurs/Stegosaurus/BP_Stegosaurus.BP_Stegosaurus_C",
    "/Game/TheIsle/Core/Characters/Dinosaurs/Maiasaura/BP_Maiasaura.BP_Maiasaura_C",
    "/Game/TheIsle/Core/Characters/Dinosaurs/Tenontosaurus/BP_Tenontosaurus.BP_Tenontosaurus_C",
    "/Game/TheIsle/Core/Characters/Dinosaurs/Gallimimus/BP_Gallimimus.BP_Gallimimus_C",
    "/Game/TheIsle/Core/Characters/Dinosaurs/Troodon/BP_Troodon.BP_Troodon_C",
}

local HERBIVORE_SET = {}
for _, p in ipairs(HERBIVORE_PATHS_SET) do
    local name = p:match("BP_(.-)%.") or p
    HERBIVORE_SET[name] = true
end

local AUTO_SPAWN_SPECIES = {
    "Triceratops","Stegosaurus","Maiasaura","Tenontosaurus","Gallimimus","Troodon"
}

local function isHerbivore(classPath)
    if classPath == nil then return false end
    local name = classPath:match("BP_(.-)%.") or ""
    return HERBIVORE_SET[name] == true
end

local function autoSpawnTick()
    if not config.enabled or not config.autoSpawnEnabled then return end

    local players = enumerateOnlinePlayers()
    if #players == 0 then
        log("Spawn tick: no players online")
        return
    end

    -- Build eligible anchors
    local eligible = {}
    for _, p in ipairs(players) do
        local isEligible = (p.pawn ~= nil)
        local classPath = ""

        if isEligible then
            pcall(function() classPath = p.pawn:GetClass():GetFullName() end)
            classPath = classPath and (classPath:match("^%S+%s+(.+)$") or classPath) or ""

            if not config.spawnForHerbivores and isHerbivore(classPath) then
                isEligible = false
            end
        end

        if isEligible and config.growthFilterEnabled then
            local growth = 0; pcall(function() growth = p.pawn:GetGrowth() end)
            if (growth * 100) > config.maxGrowthPercent then isEligible = false end
        end

        if isEligible and config.hungerFilterEnabled then
            local hunger = 0; local maxHunger = 1
            pcall(function() hunger = p.pawn:GetHunger() end)
            pcall(function() maxHunger = p.pawn:GetMaxHunger() end)
            local hungerPct = maxHunger > 0 and (hunger / maxHunger * 100) or 100
            if hungerPct > config.maxHungerPercent then isEligible = false end
        end

        if isEligible then
            eligible[#eligible+1] = { p=p, classPath=classPath }
        end
    end

    if #eligible == 0 then
        log("Spawn tick skipped: no eligible anchors")
        return
    end

    -- Pick random anchor
    local anchor = eligible[math.random(#eligible)]
    local loc; pcall(function() loc = anchor.p.pawn:K2_GetActorLocation() end)
    if loc == nil then return end

    -- Pick species (optionally excluding same as anchor)
    local spawnList = {}
    for _, name in ipairs(AUTO_SPAWN_SPECIES) do
        if not config.excludeSameSpecies or not anchor.classPath:find(name) then
            spawnList[#spawnList+1] = name
        end
    end
    if #spawnList == 0 then spawnList = AUTO_SPAWN_SPECIES end

    local species = spawnList[math.random(#spawnList)]
    local ok, msg = spawnCorpse(species, loc, 1.0)

    -- Emit event
    local eventLine = string.format(
        '{"ts":%d,"anchor":"%s","species":"%s","x":%.0f,"y":%.0f,"z":%.0f,"ok":%s}',
        os.time(), jsonEscape(anchor.p.steam), jsonEscape(species),
        loc.X, loc.Y, loc.Z, tostring(ok==true)
    )
    appendLine(EVENTS_FILE, eventLine)

    if ok then
        log(string.format("Auto-spawned %s near %s", species, anchor.p.steam))
    else
        log(string.format("Auto-spawn failed: %s", tostring(msg)))
    end
end

-- ============================================================
-- IPC: inbox handler
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
        tostring(ok==true), jsonEscape(tostring(msg or ""))
    )
    appendLine(RESULTS_FILE, line)
end

local function handleCommand(steam, tokens)
    local verb = tokens[1] or ""

    if verb == "spawn" then
        -- tokens: spawn <Species> <x> <y> <z> [growth]
        local species  = tokens[2]
        local x        = tonumber(tokens[3])
        local y        = tonumber(tokens[4])
        local z        = tonumber(tokens[5])
        local growth   = tonumber(tokens[6]) or 1.0
        if species == nil or x == nil or y == nil or z == nil then
            return false, "usage: spawn <Species> <x> <y> <z> [growth]"
        end
        local ok, msg = spawnCorpse(species, {X=x, Y=y, Z=z}, growth)
        return ok, msg

    elseif verb == "status" then
        local playerCount = 0
        for _ in pairs(presenceRegistry) do playerCount = playerCount + 1 end
        return true, string.format(
            "BodyDrop %s | enabled=%s autoSpawn=%s | %d players tracked",
            MOD_VERSION, tostring(config.enabled), tostring(config.autoSpawnEnabled), playerCount
        )

    elseif verb == "set" then
        -- tokens: set <key> <value>
        local key = tokens[2]; local value = tokens[3]
        if key == "interval" then
            -- Can't change LoopInGameThreadWithDelay from here; just acknowledge
            return true, "interval change requires mod restart"
        elseif key == "autospawn" then
            config.autoSpawnEnabled = (value == "on" or value == "true" or value == "1")
            return true, string.format("autoSpawnEnabled=%s", tostring(config.autoSpawnEnabled))
        elseif key == "growth_filter" then
            config.growthFilterEnabled = (value == "on" or value == "true")
            return true, "growth filter = " .. tostring(config.growthFilterEnabled)
        elseif key == "hunger_filter" then
            config.hungerFilterEnabled = (value == "on" or value == "true")
            return true, "hunger filter = " .. tostring(config.hungerFilterEnabled)
        end
        return false, "unknown setting: "..tostring(key)

    elseif verb == "diag" then
        local species = tokens[2] or "Triceratops"
        if SPECIES_PATHS[species] == nil then
            return false, "unknown species: "..species
        end
        -- Try to find the class (does it exist on this server?)
        local cls; pcall(function() cls = StaticFindObject(SPECIES_PATHS[species]) end)
        return cls ~= nil, cls ~= nil and "class found" or "class NOT found"
    end

    return false, "unknown verb: "..tostring(verb)
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
            for s in argsBlock:gmatch('"([^"]*)"') do tokens[#tokens+1] = s end
        end

        local callOk, r1, r2 = pcall(handleCommand, steam, tokens)
        if callOk then
            emitResult(id, steam, tokens, r1 == true, tostring(r2 or ""))
        else
            emitResult(id, steam, tokens, false, "error: "..tostring(r1))
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
        safeCall("pollInbox", pollInbox)

        local reload = consumeFlag(RELOAD_FLAG)
        if reload ~= nil and RestartCurrentMod ~= nil then
            log("RELOAD"); RestartCurrentMod()
        end
    end)

    LoopInGameThreadWithDelay(SPAWN_INTERVAL_MS, function()
        safeCall("autoSpawnTick", autoSpawnTick)
    end)
end

log(string.format("Loaded; version=%s", MOD_VERSION))
