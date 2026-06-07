-- CommandBridge v001
-- IPC layer between Discord bot and server-side mods.
-- Polls Saved/commands.ndjson, dispatches verbs, writes Saved/results.ndjson.

local MOD_NAME    = "CommandBridge"
local MOD_VERSION = "v001"

local SAVED_DIR      = "Mods/CommandBridge/Saved"
local COMMANDS_FILE  = SAVED_DIR .. "/commands.ndjson"
local RESULTS_FILE   = SAVED_DIR .. "/results.ndjson"
local CONFIG_FILE    = SAVED_DIR .. "/config.json"
local RELOAD_FLAG    = SAVED_DIR .. "/reload.flag"

local POLL_INTERVAL_MS   = 1000
local INPUT_POLL_SECONDS = 2

local function log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(msg)))
end

-- ============================================================
-- File helpers
-- ============================================================

local function fileExists(path)
    local f = io.open(path, "rb")
    if f == nil then return false end
    f:close(); return true
end

local function readAll(path)
    local f = io.open(path, "rb")
    if f == nil then return nil end
    local body = f:read("*a")
    f:close()
    return body
end

local function appendLine(path, line)
    local f = io.open(path, "ab")
    if f == nil then return false end
    f:write(line); f:write("\n"); f:close()
    return true
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
    -- Windows: mkdir creates all intermediate directories automatically.
    -- 2>nul suppresses the "already exists" error so this is always safe to call.
    local winPath = path:gsub("/", "\\")
    os.execute('mkdir "' .. winPath .. '" 2>nul')
end

-- ============================================================
-- JSON helpers (no external library)
-- ============================================================

local function jsonReadString(body, fieldName)
    return string.match(body or "", '"' .. fieldName .. '"%s*:%s*"([^"]*)"')
end

local function jsonReadNumber(body, fieldName)
    return tonumber(string.match(body or "", '"' .. fieldName .. '"%s*:%s*(-?%d+%.?%d*)'))
end

local function jsonReadBool(body, fieldName)
    local v = string.match(body or "", '"' .. fieldName .. '"%s*:%s*([%a]+)')
    if v == "true" then return true end
    if v == "false" then return false end
    return nil
end

local function jsonEscape(s)
    if s == nil then return "" end
    s = tostring(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    return s
end

-- Read a balanced-brace object from a JSON string at the given field.
-- Returns the raw {...} string including outer braces, or nil.
local function jsonReadObject(body, fieldName)
    local startPat = '"' .. fieldName .. '"%s*:%s*(%b{})'
    local m = string.match(body or "", startPat)
    return m
end

-- ============================================================
-- Presence registry (shared helpers)
-- ============================================================

local presenceRegistry = {}
local PRESENCE_EXPIRY_SEC = 180

local function presenceUpdate(steam)
    if steam == nil or steam == "" then return end
    local s = tostring(steam)
    if not presenceRegistry[s] then
        presenceRegistry[s] = { firstSeen = os.time() }
    end
    presenceRegistry[s].lastSeen = os.time()
end

local function findGameMode()
    local candidates = { "BP_SurvivalGameMode_C", "TISurvivalGameMode", "TIGameModeBase", "GameModeBase" }
    for _, name in ipairs(candidates) do
        local gm
        pcall(function() gm = FindFirstOf(name) end)
        if gm ~= nil then return gm end
    end
    return nil
end

local function livePawnFromCtrl(ctrl)
    if ctrl == nil then return nil end
    local pawn
    pcall(function() pawn = ctrl:K2_GetPawn() end)
    if pawn == nil then return nil end
    local addr
    pcall(function() addr = pawn:GetAddress() end)
    if addr == nil or addr == 0 then return nil end
    return pawn
end

local function presenceRegisterHook()
    local ok, err = pcall(function()
        RegisterHook("/Script/TheIsle.TIPlayerController:SetAdminCred", function(ctrlParam, _bool)
            local self_
            pcall(function() self_ = ctrlParam:get() end)
            if self_ == nil then return end
            local sId
            pcall(function() sId = self_:GetSteamId() end)
            if sId == nil then return end
            local steamStr
            pcall(function() steamStr = sId:ToString() end)
            if steamStr ~= nil and tostring(steamStr) ~= "" then
                presenceUpdate(steamStr)
            end
        end)
    end)
    if ok then log("Presence heartbeat hook registered")
    else log("Presence heartbeat hook FAILED: " .. tostring(err)) end
end

local function presenceStartRefreshTick()
    if LoopInGameThreadWithDelay == nil then return end
    LoopInGameThreadWithDelay(15000, function()
        local gm = findGameMode()
        if gm == nil then return end
        local now = os.time()
        for steam, _ in pairs(presenceRegistry) do
            local ctrl
            pcall(function() ctrl = gm:GetControllerBySteamId(steam) end)
            if ctrl == nil then
                presenceRegistry[steam] = nil
            else
                presenceRegistry[steam].lastSeen = now
            end
        end
    end)
    log("Presence refresh tick started")
end

-- ============================================================
-- Config
-- ============================================================

local config = {
    enabled          = true,
    inputPollSeconds = INPUT_POLL_SECONDS,
}

local function loadConfig()
    local body = readAll(CONFIG_FILE)
    if body == nil then return end
    local enabled = jsonReadBool(body, "enabled")
    if enabled ~= nil then config.enabled = enabled end
    local ips = jsonReadNumber(body, "inputPollSeconds")
    if ips ~= nil then config.inputPollSeconds = ips end
    log(string.format("Config loaded; enabled=%s pollSec=%s",
        tostring(config.enabled), tostring(config.inputPollSeconds)))
end

-- ============================================================
-- Result emitter
-- ============================================================

local function emitResult(id, verb, steam, ok, msg)
    local line = string.format(
        '{"id":"%s","ts":%d,"verb":"%s","steam":"%s","ok":%s,"msg":"%s"}',
        jsonEscape(tostring(id or "")),
        os.time(),
        jsonEscape(tostring(verb or "")),
        jsonEscape(tostring(steam or "")),
        tostring(ok == true),
        jsonEscape(tostring(msg or ""))
    )
    appendLine(RESULTS_FILE, line)
end

-- ============================================================
-- Sub-mod inbox writer
-- ============================================================

local function writeToInbox(modName, cmdId, steam, tokens)
    local inboxPath = "Mods/" .. modName .. "/Saved/inbox.ndjson"
    local tokensJson = "["
    for i, t in ipairs(tokens) do
        if i > 1 then tokensJson = tokensJson .. "," end
        tokensJson = tokensJson .. '"' .. jsonEscape(t) .. '"'
    end
    tokensJson = tokensJson .. "]"
    local line = string.format(
        '{"id":"%s","ts":%d,"steam":"%s","args":%s}',
        jsonEscape(tostring(cmdId or "")),
        os.time(),
        jsonEscape(tostring(steam or "")),
        tokensJson
    )
    local ok = appendLine(inboxPath, line)
    if not ok then
        log(string.format("writeToInbox: failed to write to %s — does Mods/%s/Saved/ exist?", inboxPath, modName))
        return false, "inbox write failed — " .. modName .. "/Saved/ may not exist on disk"
    end
    return true, "queued"
end

-- For DinoStorage legacy cmd.flag format
local function writeToCmdFlag(cmdId, verb, steam, extraArgs)
    local flagPath = "Mods/DinoStorage/Saved/cmd.flag"
    local line = string.format("[%s] %s %s", tostring(cmdId or ""), verb, tostring(steam))
    if extraArgs and extraArgs ~= "" then
        line = line .. " " .. extraArgs
    end
    local ok = appendLine(flagPath, line)
    if not ok then
        log("writeToCmdFlag: failed to write to " .. flagPath .. " — does Mods/DinoStorage/Saved/ exist?")
        return false, "cmd.flag write failed — create Mods/DinoStorage/Saved/ on the server"
    end
    return true, "queued"
end

-- ============================================================
-- Skin helper — parse customizer object from args
-- ============================================================

local SKIN_FIELD_ALIASES = {
    body       = "BodyColor",
    markings   = "MarkingsColor",
    marks      = "MarkingsColor",
    flank      = "FlankColor",
    underbelly = "UnderbellyColor",
    belly      = "UnderbellyColor",
    detail     = "Detail1Color",
    details    = "Detail1Color",
    detail1    = "Detail1Color",
    eyes       = "EyesColor",
    eye        = "EyesColor",
    breed      = "MaleDisplayColor",
    display    = "MaleDisplayColor",
    male       = "MaleDisplayColor",
}

local ALL_COLOR_FIELDS = {
    "BodyColor","MarkingsColor","FlankColor","UnderbellyColor",
    "Detail1Color","EyesColor","MaleDisplayColor"
}

local function applyCustomizerBulk(pawn, customizerObj)
    -- customizerObj is the raw JSON string of the customizer object
    local cdata
    local ok = pcall(function() cdata = pawn:GetCustomizerData() end)
    if not ok or cdata == nil then return false, "no customizer data" end

    for _, field in ipairs(ALL_COLOR_FIELDS) do
        local colorBlock = string.match(customizerObj, '"' .. field .. '"%s*:%s*(%b{})')
        if colorBlock then
            local r = tonumber(string.match(colorBlock, '"[rR]"%s*:%s*(-?%d+%.?%d*)')) or 0
            local g = tonumber(string.match(colorBlock, '"[gG]"%s*:%s*(-?%d+%.?%d*)')) or 0
            local b = tonumber(string.match(colorBlock, '"[bB]"%s*:%s*(-?%d+%.?%d*)')) or 0
            local a = tonumber(string.match(colorBlock, '"[aA]"%s*:%s*(-?%d+%.?%d*)')) or 1.0
            if r == 0 and g == 0 and b == 0 then r, g, b = 0.01, 0.01, 0.01 end
            pcall(function()
                cdata[field].R = r
                cdata[field].G = g
                cdata[field].B = b
                cdata[field].A = a
            end)
        end
    end

    local sv = tonumber(string.match(customizerObj, '"[Ss]kin[Vv]ariation"%s*:%s*(-?%d+%.?%d*)'))
    if sv ~= nil then pcall(function() cdata.SkinVariation = sv end) end
    local pi = tonumber(string.match(customizerObj, '"[Pp]attern[Ii]ndex"%s*:%s*(-?%d+)'))
    if pi ~= nil then pcall(function() cdata.PatternIndex = pi end) end

    local okSet = pcall(function() pawn:SetCustomizerData(cdata) end)
    return okSet, okSet and "ok" or "SetCustomizerData failed"
end

local function applySingleFieldSkin(pawn, fieldAlias, r, g, b)
    local engineField
    if fieldAlias == "all" then
        -- Will be handled by caller iterating all fields
    else
        engineField = SKIN_FIELD_ALIASES[fieldAlias] or fieldAlias
    end

    local cdata
    local ok = pcall(function() cdata = pawn:GetCustomizerData() end)
    if not ok or cdata == nil then return false, "no customizer data" end

    if r == 0 and g == 0 and b == 0 then r, g, b = 0.01, 0.01, 0.01 end

    if fieldAlias == "all" then
        for _, f in ipairs(ALL_COLOR_FIELDS) do
            pcall(function()
                cdata[f].R = r; cdata[f].G = g; cdata[f].B = b; cdata[f].A = 1.0
            end)
        end
    else
        pcall(function()
            cdata[engineField].R = r
            cdata[engineField].G = g
            cdata[engineField].B = b
            cdata[engineField].A = 1.0
        end)
    end

    local okSet = pcall(function() pawn:SetCustomizerData(cdata) end)
    return okSet, okSet and "ok" or "SetCustomizerData failed"
end

-- ============================================================
-- Direct verb handlers
-- ============================================================

local function makeText(message)
    if FText == nil then return message end
    local ok, ft = pcall(function() return FText(message) end)
    if ok and ft ~= nil then return ft end
    return message
end

local function getPlayerPawn(steam)
    local gm = findGameMode()
    if gm == nil then return nil, "no game mode" end
    local ctrl
    pcall(function() ctrl = gm:GetControllerBySteamId(steam) end)
    if ctrl == nil then return nil, "player not online" end
    local pawn = livePawnFromCtrl(ctrl)
    if pawn == nil then return nil, "player has no pawn" end
    return pawn, nil
end

local handlers = {}

handlers.prime = function(steam, argsLine, cmdId)
    local pawn, err = getPlayerPawn(steam)
    if pawn == nil then return false, err end

    local pe
    local ok = pcall(function() pe = pawn:GetEligiblePrimeElderData() end)
    if not ok or pe == nil then return false, "could not read prime data" end

    pe.bPrimeCondition1  = true; pe.bPrimeCondition2  = true
    pe.bPrimeCondition3  = true; pe.bPrimeCondition4  = true
    pe.bPrimeCondition5  = true; pe.bPrimeCondition6  = true
    pe.bPrimeCondition7  = true; pe.bPrimeCondition8  = true
    pe.bPrimeCondition9  = true; pe.bPrimeCondition10 = true
    pe.bIsEligiblePrime  = true

    local okSet = pcall(function() pawn:SetEligiblePrimeElderData(pe) end)
    return okSet, okSet and "prime forced" or "SetEligiblePrimeElderData failed"
end

handlers.unprime = function(steam, argsLine, cmdId)
    local pawn, err = getPlayerPawn(steam)
    if pawn == nil then return false, err end

    local pe
    local ok = pcall(function() pe = pawn:GetEligiblePrimeElderData() end)
    if not ok or pe == nil then return false, "could not read prime data" end

    for i = 1, 10 do pe["bPrimeCondition" .. i] = false end
    pe.bIsEligiblePrime = false

    local okSet = pcall(function() pawn:SetEligiblePrimeElderData(pe) end)
    return okSet, okSet and "prime cleared" or "SetEligiblePrimeElderData failed"
end

handlers.skin = function(steam, argsLine, cmdId)
    local pawn, err = getPlayerPawn(steam)
    if pawn == nil then return false, err end

    -- Check for bulk customizer mode
    local customizerBlock = jsonReadObject(argsLine, "customizer")
    if customizerBlock ~= nil then
        return applyCustomizerBulk(pawn, customizerBlock)
    end

    -- Single-field mode
    local field = jsonReadString(argsLine, "field")
    if field == "reset" then
        -- Delete the SkinMod save file to disable override
        local skinFile = "Mods/SkinMod/Saved/skins/" .. steam .. ".json"
        os.remove(skinFile)
        return true, "skin override removed"
    end

    local r = jsonReadNumber(argsLine, "r") or 0
    local g = jsonReadNumber(argsLine, "g") or 0
    local b = jsonReadNumber(argsLine, "b") or 0

    return applySingleFieldSkin(pawn, field or "body", r, g, b)
end

handlers.mutations = function(steam, argsLine, cmdId)
    local pawn, err = getPlayerPawn(steam)
    if pawn == nil then return false, err end

    local slots = {
        jsonReadString(argsLine, "slot1") or jsonReadString(argsLine, "Slot1") or jsonReadString(argsLine, "MutationSlot1"),
        jsonReadString(argsLine, "slot2") or jsonReadString(argsLine, "Slot2") or jsonReadString(argsLine, "MutationSlot2"),
        jsonReadString(argsLine, "slot3") or jsonReadString(argsLine, "Slot3") or jsonReadString(argsLine, "MutationSlot3"),
        jsonReadString(argsLine, "slot4") or jsonReadString(argsLine, "Slot4") or jsonReadString(argsLine, "MutationSlot4"),
    }

    local liveMut
    local ok = pcall(function() liveMut = pawn.ReplicatedMutationsData end)
    if not ok or liveMut == nil then return false, "could not read mutations" end

    local written = 0
    for i, s in ipairs(slots) do
        if s ~= nil and s ~= "" and s ~= "None" then
            local okF, fn = pcall(function() return FName(s) end)
            if okF and fn ~= nil and type(fn) ~= "string" then
                local okW = pcall(function() liveMut["MutationSlot" .. i] = fn end)
                if okW then written = written + 1 end
            end
        end
    end

    if written > 0 then
        local okSet = pcall(function() pawn:SetReplicatedMutationsData(liveMut, true) end)
        return okSet, string.format("wrote %d mutation slots", written)
    end
    return true, "no valid mutations provided"
end

handlers.teleport = function(steam, argsLine, cmdId)
    local pawn, err = getPlayerPawn(steam)
    if pawn == nil then return false, err end

    local x = jsonReadNumber(argsLine, "x")
    local y = jsonReadNumber(argsLine, "y")
    local z = jsonReadNumber(argsLine, "z")
    local yaw = jsonReadNumber(argsLine, "yaw") or 0

    if x == nil or y == nil or z == nil then return false, "missing x/y/z" end

    local loc = { X = x, Y = y, Z = z }
    local rot = { Pitch = 0, Yaw = yaw, Roll = 0 }
    local ok = pcall(function() pawn:K2_TeleportTo(loc, rot) end)
    return ok, ok and "teleported" or "teleport failed"
end

handlers.kill = function(steam, argsLine, cmdId)
    local pawn, err = getPlayerPawn(steam)
    if pawn == nil then return false, err end
    local ok = pcall(function() pawn:SetHealth(0) end)
    return ok, ok and "killed" or "kill failed"
end

handlers.heal = function(steam, argsLine, cmdId)
    local pawn, err = getPlayerPawn(steam)
    if pawn == nil then return false, err end
    local maxHp
    pcall(function() maxHp = pawn:GetMaxHealth() end)
    local ok = pcall(function() pawn:SetHealth(maxHp or 9999) end)
    return ok, ok and "healed" or "heal failed"
end

handlers.setgrowth = function(steam, argsLine, cmdId)
    local pawn, err = getPlayerPawn(steam)
    if pawn == nil then return false, err end
    local v = jsonReadNumber(argsLine, "value")
    if v == nil then return false, "missing value" end
    v = math.max(0, math.min(1, v))
    local ok = pcall(function() pawn:SetGrowth(v) end)
    return ok, ok and string.format("growth set to %.4f", v) or "setgrowth failed"
end

handlers.setvital = function(steam, argsLine, cmdId)
    local pawn, err = getPlayerPawn(steam)
    if pawn == nil then return false, err end
    local name = jsonReadString(argsLine, "name")
    local value = jsonReadNumber(argsLine, "value")
    if name == nil or value == nil then return false, "missing name or value" end

    local fnMap = {
        health   = "SetHealth",
        stamina  = "SetStamina",
        hunger   = "SetHunger",
        thirst   = "SetThirst",
        oxygen   = "SetOxygen",
        blood    = "SetBloodLoss",
    }
    local fn = fnMap[name:lower()]
    if fn == nil then return false, "unknown vital: " .. name end
    local ok = pcall(function() pawn[fn](pawn, value) end)
    return ok, ok and string.format("%s set to %.2f", name, value) or (fn .. " failed")
end

handlers.notify = function(steam, argsLine, cmdId)
    local gm = findGameMode()
    if gm == nil then return false, "no game mode" end
    local ctrl
    pcall(function() ctrl = gm:GetControllerBySteamId(steam) end)
    if ctrl == nil then return false, "player not online" end
    local msg = jsonReadString(argsLine, "message") or ""
    local text = makeText(msg)
    local ok = pcall(function() ctrl:ClientShowNotification(text) end)
    return ok, ok and "notified" or "ClientShowNotification failed"
end

-- ============================================================
-- Sub-mod routing handlers
-- ============================================================

handlers.bd        = function(steam, argsLine, cmdId)
    local tokensBlock = string.match(argsLine, '"args"%s*:%s*%[([^%]]*)%]')
    local tokens = {}
    if tokensBlock then
        for s in string.gmatch(tokensBlock, '"([^"]*)"') do tokens[#tokens+1] = s end
    end
    return writeToInbox("BodyDrop", cmdId, steam, tokens)
end
handlers.bodydrop  = handlers.bd

handlers.ps        = function(steam, argsLine, cmdId)
    local tokensBlock = string.match(argsLine, '"args"%s*:%s*%[([^%]]*)%]')
    local tokens = {}
    if tokensBlock then
        for s in string.gmatch(tokensBlock, '"([^"]*)"') do tokens[#tokens+1] = s end
    end
    return writeToInbox("PlayerStats", cmdId, steam, tokens)
end
handlers.playerstats = handlers.ps

local DINO_STORAGE_VERBS = {
    dino_store=true, dino_retrieve=true, dino_delete=true, dino_list=true,
    dino_setmax=true, dino_clearmax=true, dino_getmax=true,
}
local function dinoStorageHandler(steam, argsLine, cmdId, verb)
    -- Extract optional args array
    local tokensBlock = string.match(argsLine, '"args"%s*:%s*%[([^%]]*)%]')
    local tokens = {}
    if tokensBlock then
        for s in string.gmatch(tokensBlock, '"([^"]*)"') do tokens[#tokens+1] = s end
    end
    -- Map verb to cmd.flag short verb
    local shortVerb = verb
        :gsub("^dino_", "")
    local extra = table.concat(tokens, " ")
    return writeToCmdFlag(cmdId, shortVerb, steam, extra)
end

for verb, _ in pairs(DINO_STORAGE_VERBS) do
    local v = verb
    handlers[v] = function(steam, argsLine, cmdId)
        return dinoStorageHandler(steam, argsLine, cmdId, v)
    end
end

-- ============================================================
-- Command parser and dispatcher
-- ============================================================

local function parseCommand(line)
    local id    = jsonReadString(line, "id")
    local verb  = jsonReadString(line, "verb")
    local steam = jsonReadString(line, "steam") or ""
    -- argsLine is the full line so handlers can extract nested objects
    return id, verb, steam, line
end

local lastPollAt = 0

local function pollInput()
    if not config.enabled then return end
    local now = os.time()
    if (now - lastPollAt) < config.inputPollSeconds then return end
    lastPollAt = now

    if not fileExists(COMMANDS_FILE) then return end

    local stash = COMMANDS_FILE .. ".processing"
    os.remove(stash)
    os.rename(COMMANDS_FILE, stash)

    local body = readAll(stash)
    if body == nil or body == "" then os.remove(stash); return end

    for line in body:gmatch("[^\n]+") do
        local id, verb, steam, argsLine = parseCommand(line)
        if verb ~= nil then
            local handler = handlers[verb]
            if handler ~= nil then
                -- pcall returns (callSucceeded, ret1, ret2)
                -- handler returns (bool ok, string msg)
                local callOk, hok, hmsg = pcall(handler, steam, argsLine, id)
                if callOk then
                    emitResult(id, verb, steam, hok == true, tostring(hmsg or ""))
                else
                    emitResult(id, verb, steam, false, "error: " .. tostring(hok))
                end
            else
                emitResult(id, verb, steam, false, "unknown verb: " .. tostring(verb))
            end
        end
    end

    os.remove(stash)
end

local function safeCall(label, fn)
    local ok, err = pcall(fn)
    if not ok then log(string.format("safeCall(%s) failed: %s", label, tostring(err))) end
    return ok, err
end

-- ============================================================
-- Boot
-- ============================================================

log(string.format("Loading; version=%s", MOD_VERSION))

presenceRegisterHook()
presenceStartRefreshTick()

if LoopInGameThreadWithDelay ~= nil then
    local bootHandle
    bootHandle = LoopInGameThreadWithDelay(5000, function()
        log(string.format("Boot; version=%s", MOD_VERSION))
        ensureDir(SAVED_DIR)
        local tf = io.open(SAVED_DIR .. "/.keep", "wb")
        if tf then tf:write(""); tf:close()
        else log("WARNING: cannot write to " .. SAVED_DIR .. " — directory creation may have failed!") end
        safeCall("loadConfig", loadConfig)
        if bootHandle ~= nil and CancelDelayedAction ~= nil then
            pcall(function() CancelDelayedAction(bootHandle) end)
        end
    end)

    LoopInGameThreadWithDelay(POLL_INTERVAL_MS, function()
        safeCall("pollInput", pollInput)

        local reload = consumeFlag(RELOAD_FLAG)
        if reload ~= nil and RestartCurrentMod ~= nil then
            log(string.format("RELOAD; token=%s", reload))
            RestartCurrentMod()
        end
    end)
end

log(string.format("Loaded; version=%s", MOD_VERSION))
