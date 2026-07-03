-- PrimeNotify v001
-- Popup notifications when players complete quest conditions toward prime eligibility.
-- Tracks each player's prime condition count; notifies on every new condition
-- gained and with a special message when they hit eligibility (5+).

local MOD_NAME    = "PrimeNotify"
local MOD_VERSION = "v001"

local SAVED_DIR   = "Mods/PrimeNotify/Saved"
local CONFIG_FILE = SAVED_DIR .. "/config.json"
local RELOAD_FLAG = SAVED_DIR .. "/reload.flag"

local POLL_INTERVAL_MS = 5000  -- check prime conditions every 5s

local function log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(msg)))
end

-- ============================================================
-- File helpers
-- ============================================================

local function readAll(path)
    local f = io.open(path, "rb"); if f == nil then return nil end
    local body = f:read("*a"); f:close(); return body
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
    enabled           = true,
    notifyEachCondition = true,  -- notify on every individual condition gain
    eligibilityThreshold = 5,    -- conditions needed for prime eligibility
}

local function loadConfig()
    local body = readAll(CONFIG_FILE)
    if body == nil then return end
    local e = jsonReadBool(body, "enabled")
    if e ~= nil then config.enabled = e end
    local ec = jsonReadBool(body, "notifyEachCondition")
    if ec ~= nil then config.notifyEachCondition = ec end
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
-- Notification helper
-- ============================================================

local pendingNotifies = {}

local function queueNotify(steam, msg)
    pendingNotifies[#pendingNotifies+1] = { steam=steam, msg=msg }
end

local function drainNotifies()
    if #pendingNotifies == 0 then return end
    local drain = pendingNotifies
    pendingNotifies = {}
    local gm = findGameMode()
    if gm == nil then return end
    for _, n in ipairs(drain) do
        pcall(function()
            local ctrl; pcall(function() ctrl = gm:GetControllerBySteamId(n.steam) end)
            if ctrl == nil then return end
            local text = n.msg
            if FText ~= nil then
                local ok, ft = pcall(function() return FText(n.msg) end)
                if ok and ft ~= nil then text = ft end
            end
            ctrl:ClientShowNotification(text)
        end)
    end
end

-- ============================================================
-- Prime condition tracker
-- ============================================================

-- steam -> { condCount, wasEligible }
local primeState = {}

local CONDITION_NAMES = {
    [1]  = "Visit a sanctuary zone",
    [2]  = "Prime condition 2",
    [3]  = "Perfect diet achieved",
    [4]  = "Prime condition 4",
    [5]  = "Prime condition 5",
    [6]  = "Prime condition 6",
    [7]  = "Breeding milestone",
    [8]  = "Breeding milestone 2",
    [9]  = "Per-life objective",
    [10] = "Lifetime objective",
}

local function countConditions(pe)
    local count = 0
    for i = 1, 10 do
        if pe["bPrimeCondition"..i] == true then count = count + 1 end
    end
    return count
end

local function checkPrimeConditions()
    if not config.enabled then return end

    local players = enumerateOnlinePlayers()
    for _, p in ipairs(players) do
        if p.pawn ~= nil then
            local pe
            local ok = pcall(function() pe = p.pawn:GetEligiblePrimeElderData() end)
            if ok and pe ~= nil then
                local condCount = countConditions(pe)
                local isEligible = pe.bIsEligiblePrime == true
                local prev = primeState[p.steam]

                if prev == nil then
                    -- First time seeing this player; record state without notifying
                    primeState[p.steam] = { condCount=condCount, wasEligible=isEligible }
                else
                    -- Detect newly gained conditions
                    if config.notifyEachCondition and condCount > prev.condCount then
                        queueNotify(p.steam, string.format(
                            "[Prime] You completed a prime condition! %d / 10 conditions met%s",
                            condCount,
                            condCount >= config.eligibilityThreshold and " - you are now eligible!" or ""
                        ))
                    end

                    -- Detect prime eligibility crossing threshold
                    if isEligible and not prev.wasEligible then
                        queueNotify(p.steam,
                            "[Prime] You have reached prime eligibility! " ..
                            "Visit your mutation menu and select a prime mutation in slot 4 " ..
                            "when you reach 75% growth. Congratulations!"
                        )
                    end

                    primeState[p.steam] = { condCount=condCount, wasEligible=isEligible }
                end
            end
        end
    end
end

-- Also hook into pawn change to reset tracked state
-- (new pawn = new life = conditions may have reset)
local lastPawnAddr = {}

-- Declared here so both checkPawnChanges and checkPrimeConditionsDetailed can see it.
-- Lua locals are only visible after their declaration point in the chunk.
local perConditionState = {}

local function checkPawnChanges()
    local players = enumerateOnlinePlayers()
    for _, p in ipairs(players) do
        if p.pawn ~= nil then
            local addr; pcall(function() addr = p.pawn:GetAddress() end)
            local addrKey = tostring(addr or 0)
            if lastPawnAddr[p.steam] ~= addrKey then
                -- New pawn — reset state so we re-baseline without notifying
                primeState[p.steam] = nil
                perConditionState[p.steam] = nil
                lastPawnAddr[p.steam] = addrKey
            end
        end
    end
end

-- Per-condition detailed tracking variant (more precise)
-- Stores the full 10-bool vector per player so we can identify exactly which
-- condition was newly gained. Runs alongside the count-based check.
local function checkPrimeConditionsDetailed()
    if not config.notifyEachCondition then return end
    if not config.enabled then return end

    local players = enumerateOnlinePlayers()
    for _, p in ipairs(players) do
        if p.pawn ~= nil then
            local pe; pcall(function() pe = p.pawn:GetEligiblePrimeElderData() end)
            if pe ~= nil then
                local current = {}
                for i = 1, 10 do current[i] = pe["bPrimeCondition"..i] == true end

                local prev = perConditionState[p.steam]
                if prev == nil then
                    perConditionState[p.steam] = current
                else
                    for i = 1, 10 do
                        if current[i] and not prev[i] then
                            local condCount = countConditions(pe)
                            local name = CONDITION_NAMES[i] or ("condition "..i)
                            queueNotify(p.steam, string.format(
                                "[Prime] Quest complete: %s (%d/10 conditions)", name, condCount
                            ))
                        end
                    end
                    perConditionState[p.steam] = current
                end
            end
        end
    end
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
        safeCall("checkPawnChanges",            checkPawnChanges)
        safeCall("checkPrimeConditions",        checkPrimeConditions)
        safeCall("checkPrimeConditionsDetailed",checkPrimeConditionsDetailed)
        safeCall("drainNotifies",               drainNotifies)

        local reload = consumeFlag(RELOAD_FLAG)
        if reload ~= nil and RestartCurrentMod ~= nil then
            log("RELOAD"); RestartCurrentMod()
        end
    end)
end

log(string.format("Loaded; version=%s", MOD_VERSION))
