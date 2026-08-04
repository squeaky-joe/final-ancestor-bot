-- PrimeNotify v005
-- Popup notifications when players complete quest conditions toward prime eligibility.
-- Tracks each player's prime condition count; notifies on every new condition
-- gained and with a special message when they hit eligibility (5+).
--
-- Improvements over v004:
-- - Added IPC endpoint for Discord bot to retrieve player prime progress
-- - Enhanced condition descriptions with specific requirements
-- - Better error handling and robustness

local MOD_NAME    = "PrimeNotify"
local MOD_VERSION = "v005"

local SAVED_DIR   = "Mods/PrimeNotify/Saved"
local CONFIG_FILE = SAVED_DIR .. "/config.json"
local RELOAD_FLAG = SAVED_DIR .. "/reload.flag"
local INBOX_PATH   = SAVED_DIR .. "/inbox.ndjson"
local RESULTS_FILE = "Mods/CommandBridge/Saved/results.ndjson"

local POLL_INTERVAL_MS = 5000  -- check prime conditions every 5s

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

local function jsonReadString(body, key)
    return string.match(body or "", '"' .. key .. '"%s*:%s*"([^"]*)"')
end

local function jsonEscape(s)
    if s == nil then return "" end
    s = tostring(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return s
end

-- ============================================================
-- Config
-- ============================================================

local config = {
    enabled           = true,
    notifyEachCondition = true,  -- notify on every individual condition gain
    eligibilityThreshold = 5,    -- conditions needed for prime eligibility
    enableDetailedTracking = true, -- track individual conditions for detailed notifications
    showProgressInChat = false,   -- optionally show progress in chat (not just notifications)
}

local function loadConfig()
    local body = readAll(CONFIG_FILE)
    if body == nil then return end
    local e = jsonReadBool(body, "enabled")
    if e ~= nil then config.enabled = e end
    local ec = jsonReadBool(body, "notifyEachCondition")
    if ec ~= nil then config.notifyEachCondition = ec end
    local dt = jsonReadBool(body, "enableDetailedTracking")
    if dt ~= nil then config.enableDetailedTracking = dt end
    local sp = jsonReadBool(body, "showProgressInChat")
    if sp ~= nil then config.showProgressInChat = sp end
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
    if steam == nil or steam == "" or msg == nil or msg == "" then return end
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
-- Prime condition tracker with enhanced zone tracking
-- ============================================================

-- steam -> { condCount, wasEligible, lastNotifiedCount, zoneCounts }
local primeState = {}

-- steam -> { [conditionIndex] = true/false } for detailed tracking
local conditionState = {}

-- Track which conditions have been notified to prevent duplicates
local notifiedConditions = {}

-- Enhanced Prime Condition Descriptions with specific requirements
-- These are the 10 official prime conditions in The Isle Evrima:
CONDITION_NAMES = {
    [1]  = "Visit a Sanctuary as Juvenile",
    [2]  = "Get Nested In",
    [3]  = "Visit Mass Migration Zone", 
    [4]  = "Get Perfect Diet (1% of each)",
    [5]  = "Visit 2 Migration Zones",
    [6]  = "Visit 4 Patrol Zones",
    [7]  = "Never be infertile",
    [8]  = "Never get muscle spasms",
    [9]  = "Raise children to subadult",
    [10] = "Be a Hypsi, Troodon, Beipi, Dryo or Deino"
}

CONDITION_DESCRIPTIONS = {
    [1]  = "Visit any Sanctuary Zone (marked by a blue circle) as a juvenile dinosaur",
    [2]  = "Successfully nest in a structure like a cave or building",
    [3]  = "Visit a Mass Migration Zone (this condition is not available in current version)",
    [4]  = "Maintain a perfect diet without eating anything other than your species' preferred food",
    [5]  = "Visit at least 2 different Migration Zones (marked by an orange circle)",
    [6]  = "Visit at least 4 different Patrol Zones (marked by a yellow circle)",
    [7]  = "Never become infertile during your life cycle",
    [8]  = "Never get muscle spasms during your life cycle",
    [9]  = "Successfully raise at least one baby dinosaur of your species to subadult stage",
    [10] = "Your dinosaur species must be one of: Hypsi, Troodon, Beipi, Dryo or Deino"
}

local function countConditions(pe)
    if pe == nil then return 0 end
    local count = 0
    for i = 1, 10 do
        if pe["bPrimeCondition"..i] == true then count = count + 1 end
    end
    return count
end

-- Function to get player progress - this is the new IPC endpoint that Discord bot will call
local function getPlayerProgress(steam)
    local gm = findGameMode()
    if gm == nil then 
        -- Return minimal data when game mode not found
        return {
            conditionsMet = 0,
            totalConditions = 10,
            isEligible = false,
            conditions = {},
            zoneCounts = { migration = 0, patrol = 0, sanctuary = 0 }
        }
    end
    
    local ctrl; pcall(function() ctrl = gm:GetControllerBySteamId(steam) end)
    if ctrl == nil then 
        -- Return minimal data when player not found
        return {
            conditionsMet = 0,
            totalConditions = 10,
            isEligible = false,
            conditions = {},
            zoneCounts = { migration = 0, patrol = 0, sanctuary = 0 }
        }
    end
    
    local pawn = livePawnFromCtrl(ctrl)
    if pawn == nil then 
        -- Return minimal data when pawn not found
        return {
            conditionsMet = 0,
            totalConditions = 10,
            isEligible = false,
            conditions = {},
            zoneCounts = { migration = 0, patrol = 0, sanctuary = 0 }
        }
    end
    
    local pe
    local ok = pcall(function() pe = pawn:GetEligiblePrimeElderData() end)
    if not ok or pe == nil then 
        -- Return minimal data when prime data can't be read
        return {
            conditionsMet = 0,
            totalConditions = 10,
            isEligible = false,
            conditions = {},
            zoneCounts = { migration = 0, patrol = 0, sanctuary = 0 }
        }
    end
    
    local condCount = countConditions(pe)
    local isEligible = pe.bIsEligiblePrime == true
    
    local progress = {
        conditionsMet = condCount,
        totalConditions = 10,
        isEligible = isEligible,
        conditions = {},
        zoneCounts = { migration = 0, patrol = 0, sanctuary = 0 }
    }
    
    -- Get current zone counts (we'll use a simplified approach since we don't have full tracking in this mod)
    -- This would normally be tracked in the zoneTracker but we're providing basic info
    for i = 1, 10 do
        local completed = pe["bPrimeCondition"..i] == true
        progress.conditions[i] = {
            index = i,
            name = CONDITION_NAMES[i] or ("condition "..i),
            description = CONDITION_DESCRIPTIONS[i] or "",
            completed = completed
        }
    end
    
    return progress
end

-- ============================================================
-- IPC — serve prime_progress requests routed from CommandBridge
-- ============================================================

local function encodeProgressJson(progress)
    local condsJson = "["
    for i, c in ipairs(progress.conditions) do
        if i > 1 then condsJson = condsJson .. "," end
        condsJson = condsJson .. string.format(
            '{"index":%d,"name":"%s","description":"%s","completed":%s}',
            c.index, jsonEscape(c.name), jsonEscape(c.description), tostring(c.completed == true)
        )
    end
    condsJson = condsJson .. "]"

    return string.format(
        '{"conditionsMet":%d,"totalConditions":%d,"isEligible":%s,"zoneCounts":{"migration":%d,"patrol":%d,"sanctuary":%d},"conditions":%s}',
        progress.conditionsMet, progress.totalConditions, tostring(progress.isEligible == true),
        progress.zoneCounts.migration, progress.zoneCounts.patrol, progress.zoneCounts.sanctuary,
        condsJson
    )
end

local function emitIpcResult(id, steam, ok, msg)
    local line = string.format(
        '{"id":"%s","ts":%d,"source":"PrimeNotify","steam":"%s","ok":%s,"msg":"%s"}',
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

        local callOk, progress = pcall(getPlayerProgress, steam)
        if callOk then
            emitIpcResult(id, steam, true, encodeProgressJson(progress))
        else
            emitIpcResult(id, steam, false, "error: " .. tostring(progress))
        end
    end

    os.remove(stash)
end

local function checkPrimeConditions()
    if not config.enabled then return end

    local players = enumerateOnlinePlayers()
    for _, p in ipairs(players) do
        if p.pawn ~= nil then
            local pe
            local ok = pcall(function() pe = p.pawn:GetEligiblePrimeElderData() end)
            if not ok or pe == nil then
                -- Skip players that we can't access prime data for
                goto continue_prime
            end

            local condCount = countConditions(pe)
            local isEligible = pe.bIsEligiblePrime == true
            
            -- Get previous state
            local prev = primeState[p.steam]
            
            if prev == nil then
                -- First time seeing this player; record state without notifying
                primeState[p.steam] = { 
                    condCount = condCount, 
                    wasEligible = isEligible,
                    lastNotifiedCount = 0
                }
                conditionState[p.steam] = {}
                for i = 1, 10 do
                    conditionState[p.steam][i] = pe["bPrimeCondition"..i] == true
                end
            else
                -- Check for newly gained conditions (count-based approach)
                if config.notifyEachCondition and condCount > prev.condCount then
                    -- Only notify about new conditions since last notification
                    local newConditions = 0
                    
                    -- If we have detailed tracking enabled, we can be more precise
                    if config.enableDetailedTracking and conditionState[p.steam] ~= nil then
                        for i = 1, 10 do
                            local current = pe["bPrimeCondition"..i] == true
                            local previous = conditionState[p.steam][i]
                            
                            if current and not previous then
                                -- This is a newly gained condition
                                newConditions = newConditions + 1
                                local name = CONDITION_NAMES[i] or ("condition "..i)
                                local desc = CONDITION_DESCRIPTIONS[i] or ""
                                
                                -- Notify with detailed information
                                queueNotify(p.steam, string.format(
                                    "[Prime] Quest complete: %s (%d/10 conditions)\n%s",
                                    name, condCount, desc
                                ))
                                
                                -- Track that we've notified about this specific condition
                                notifiedConditions[p.steam..":"..i] = true
                            end
                        end
                    else
                        -- Fallback to simple notification
                        queueNotify(p.steam, string.format(
                            "[Prime] You completed a prime condition! %d / 10 conditions met%s",
                            condCount,
                            condCount >= config.eligibilityThreshold and " - you are now eligible!" or ""
                        ))
                    end
                    
                    -- Also notify about the overall count if not already notified for this count level
                    if prev.lastNotifiedCount < condCount then
                        queueNotify(p.steam, string.format(
                            "[Prime] You completed a prime condition! %d / 10 conditions met%s",
                            condCount,
                            condCount >= config.eligibilityThreshold and " - you are now eligible!" or ""
                        ))
                    end
                end

                -- Detect prime eligibility crossing threshold
                if isEligible and not prev.wasEligible then
                    queueNotify(p.steam,
                        "[Prime] You have reached prime eligibility! " ..
                        "Visit your mutation menu and select a prime mutation in slot 4 " ..
                        "when you reach 75% growth. Congratulations!"
                    )
                end

                -- Update state
                primeState[p.steam] = { 
                    condCount = condCount, 
                    wasEligible = isEligible,
                    lastNotifiedCount = condCount
                }
                
                -- Update detailed condition tracking
                if config.enableDetailedTracking then
                    for i = 1, 10 do
                        conditionState[p.steam][i] = pe["bPrimeCondition"..i] == true
                    end
                end
            end
        end
        ::continue_prime::
    end
end

-- Also hook into pawn change to reset tracked state
-- (new pawn = new life = conditions may have reset)
local lastPawnAddr = {}

local function checkPawnChanges()
    local players = enumerateOnlinePlayers()
    for _, p in ipairs(players) do
        if p.pawn ~= nil then
            local addr; pcall(function() addr = p.pawn:GetAddress() end)
            local addrKey = tostring(addr or 0)
            if lastPawnAddr[p.steam] ~= addrKey then
                -- New pawn — reset state so we re-baseline without notifying
                primeState[p.steam] = nil
                conditionState[p.steam] = nil
                notifiedConditions[p.steam] = nil
                lastPawnAddr[p.steam] = addrKey
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
        safeCall("checkPawnChanges", checkPawnChanges)
        safeCall("checkPrimeConditions", checkPrimeConditions)
        safeCall("drainNotifies", drainNotifies)
        safeCall("pollInbox", pollInbox)

        local reload = consumeFlag(RELOAD_FLAG)
        if reload ~= nil and RestartCurrentMod ~= nil then
            log("RELOAD"); RestartCurrentMod()
        end
    end)
end

log(string.format("Loaded; version=%s", MOD_VERSION))