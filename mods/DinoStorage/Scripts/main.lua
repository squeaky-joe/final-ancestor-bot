-- DinoStorage v001
-- Store/retrieve dino state across respawns.
-- All commands are Discord-only via IPC (cmd.flag).
-- IPC verbs: store, retrieve, delete, list

local MOD_NAME    = "DinoStorage"
local MOD_VERSION = "v001"

local SAVED_DIR     = "Mods/DinoStorage/Saved"
local STORED_DIR    = SAVED_DIR .. "/stored"
local INDEX_FILE    = SAVED_DIR .. "/storage.json"
local CMD_FLAG      = SAVED_DIR .. "/cmd.flag"
local CONFIG_FILE   = SAVED_DIR .. "/config.json"
local RELOAD_FLAG   = SAVED_DIR .. "/reload.flag"
local RESULTS_FILE  = "Mods/CommandBridge/Saved/results.ndjson"

local POLL_INTERVAL_MS   = 3000
local STORE_DELAY_MS     = 3000
local RETRIEVE_DELAY_MS  = 3000
local DEFERRED_MS        = 500

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

local function writeAllAtomic(path, body)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb"); if f == nil then return false end
    f:write(body); f:close()
    os.remove(path)
    return os.rename(tmp, path)
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

local ADMIN_STEAM_IDS = {}

local config = {
    maxSlotsPerPlayer = 1,
}

local function loadConfig()
    local body = readAll(CONFIG_FILE)
    if body == nil then return end
    local max = jsonReadNumber(body, "maxSlotsPerPlayer")
    if max ~= nil then config.maxSlotsPerPlayer = math.floor(max) end
    -- Admin IDs from JSON array
    local adminBlock = string.match(body or "", '"adminSteamIds"%s*:%s*%[(.-)%]')
    if adminBlock then
        for s in adminBlock:gmatch('"([^"]+)"') do
            ADMIN_STEAM_IDS[s] = true
        end
    end
    log("Config loaded")
end

local function isAdmin(steam)
    return steam ~= nil and ADMIN_STEAM_IDS[tostring(steam)] == true
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

local function safeNotify(steam, msg)
    if steam == nil or steam == "" then return false end
    local gm = findGameMode(); if gm == nil then return false end
    local ctrl; pcall(function() ctrl = gm:GetControllerBySteamId(steam) end)
    if ctrl == nil then return false end
    local text = msg
    if FText ~= nil then
        local ok, ft = pcall(function() return FText(msg) end)
        if ok and ft ~= nil then text = ft end
    end
    local ok = pcall(function() ctrl:ClientShowNotification(text) end)
    return ok
end

-- ============================================================
-- Pending notifies
-- ============================================================

local pendingNotifies = {}  -- { steam, msg }

local function queueNotify(steam, msg)
    pendingNotifies[#pendingNotifies+1] = { steam = steam, msg = msg }
end

local function drainNotifies()
    if #pendingNotifies == 0 then return end
    local drain = pendingNotifies
    pendingNotifies = {}
    for _, n in ipairs(drain) do
        pcall(function() safeNotify(n.steam, n.msg) end)
    end
end

-- ============================================================
-- State capture
-- ============================================================

local function captureState(pawn, steam)
    local state = {}

    -- Growth
    pcall(function() state.growth = pawn:GetGrowth() end)

    -- Vitals
    pcall(function() state.health    = pawn:GetHealth() end)
    pcall(function() state.stamina   = pawn:GetStamina() end)
    pcall(function() state.hunger    = pawn:GetHunger() end)
    pcall(function() state.thirst    = pawn:GetThirst() end)
    pcall(function() state.oxygen    = pawn:GetOxygen() end)
    pcall(function() state.blood     = pawn:GetBlood() end)
    pcall(function() state.lockedDamage = pawn:GetLockedDamage() end)
    pcall(function() state.food      = pawn:GetFoodValue() end)
    pcall(function() state.waterLevel = pawn:GetWaterLevel() end)
    pcall(function() state.rottenValue = pawn:GetRottenValue() end)

    -- Max vitals
    pcall(function() state.maxHunger   = pawn:GetMaxHunger() end)
    pcall(function() state.maxThirst   = pawn:GetMaxThirst() end)
    pcall(function() state.maxStamina  = pawn:GetMaxStamina() end)
    pcall(function() state.maxFoodValue = pawn:GetMaxFoodValue() end)

    -- Gender
    pcall(function() state.isFemale = pawn.bIsFemale end)

    -- Class path
    local fullName
    pcall(function() fullName = pawn:GetClass():GetFullName() end)
    if fullName then
        -- Strip "BlueprintGeneratedClass /Game/..." prefix to just the path
        state.classPath = string.match(fullName, "^%S+%s+(.+)$") or fullName
    end

    -- Prime data
    local pe; pcall(function() pe = pawn:GetEligiblePrimeElderData() end)
    if pe ~= nil then
        state.isPrime = pe.bIsEligiblePrime
        state.primeData = {
            eligible = pe.bIsEligiblePrime,
            cond1=pe.bPrimeCondition1, cond2=pe.bPrimeCondition2,
            cond3=pe.bPrimeCondition3, cond4=pe.bPrimeCondition4,
            cond5=pe.bPrimeCondition5, cond6=pe.bPrimeCondition6,
            cond7=pe.bPrimeCondition7, cond8=pe.bPrimeCondition8,
            cond9=pe.bPrimeCondition9, cond10=pe.bPrimeCondition10,
        }
    end

    -- Elder stacks
    pcall(function() state.elderStacks = pawn:GetElderReplicationStacks() end)

    -- Mutations
    local rmData; pcall(function() rmData = pawn.ReplicatedMutationsData end)
    if rmData ~= nil then
        state.mutations = {}
        local slots = {
            "MutationSlot1","MutationSlot2","MutationSlot3","MutationSlot4",
            "ParentMutationSlot1","ParentMutationSlot2","ParentMutationSlot3","ParentMutationSlot4",
            "ElderMutationSlot1A","ElderMutationSlot1B",
            "ElderMutationSlot2A","ElderMutationSlot2B",
            "ElderMutationSlot3A","ElderMutationSlot3B",
            "ElderMutationSlot4A","ElderMutationSlot4B",
        }
        for _, slot in ipairs(slots) do
            local raw; pcall(function() raw = rmData[slot] end)
            local s = ""
            if raw ~= nil then pcall(function() s = raw:ToString() end) end
            state.mutations[slot] = (s == "None" or s == nil) and "" or s
        end
    end

    -- Quest unlock list
    state.unlockRequiredMutations = {}
    local mrData; pcall(function() mrData = pawn.MutationsRequirementsData end)
    if mrData ~= nil then
        local arr; pcall(function() arr = mrData.UnlockRequiredMutations end)
        if arr ~= nil then
            local n; pcall(function() n = #arr end)
            if type(n) == "number" then
                for i = 1, n do
                    local raw; pcall(function() raw = arr[i] end)
                    local s; if raw ~= nil then pcall(function() s = raw:ToString() end) end
                    if type(s) == "string" and s ~= "" and s ~= "None" then
                        state.unlockRequiredMutations[#state.unlockRequiredMutations+1] = s
                    end
                end
            end
        end
    end

    -- Nutrients
    local nutr; pcall(function() nutr = pawn.NutrientsStruct end)
    if nutr ~= nil then
        state.nutrients = {
            carbValue       = nutr.CarbValue,
            proteinValue    = nutr.ProteinValue,
            lipidValue      = nutr.LipidValue,
            bonesValue      = nutr.BonesValue,
            cannibalValue   = nutr.CannibalValue,
            magyValue       = nutr.MagyValue,
            rottenFleshValue = nutr.RottenFleshValue,
            mushroomsValue  = nutr.MushroomsValue,
            bMalnutrition   = nutr.bMalnutrition,
        }
    end

    -- Skin
    local cdata; pcall(function() cdata = pawn:GetCustomizerData() end)
    if cdata ~= nil then
        local function col(f)
            local c = cdata[f]
            if c == nil then return nil end
            return { r=c.R, g=c.G, b=c.B, a=c.A }
        end
        state.skin = {
            body       = col("BodyColor"),
            markings   = col("MarkingsColor"),
            flank      = col("FlankColor"),
            underbelly = col("UnderbellyColor"),
            detail1    = col("Detail1Color"),
            eyes       = col("EyesColor"),
            maleDisplay = col("MaleDisplayColor"),
            skinVariation = cdata.SkinVariation,
            patternIndex  = cdata.PatternIndex,
        }
    end

    -- Location
    local loc; pcall(function() loc = pawn:K2_GetActorLocation() end)
    if loc ~= nil then state.location = { x=loc.X, y=loc.Y, z=loc.Z } end
    local rot; pcall(function() rot = pawn:K2_GetActorRotation() end)
    if rot ~= nil then state.rotation = { pitch=rot.Pitch, yaw=rot.Yaw, roll=rot.Roll } end

    state.capturedAt = os.time()
    return state
end

-- ============================================================
-- JSON serializer
-- ============================================================

local function colorJson(c)
    if c == nil then return '{"r":0.01,"g":0.01,"b":0.01,"a":1.0}' end
    return string.format('{"r":%.6f,"g":%.6f,"b":%.6f,"a":%.6f}',
        c.r or 0, c.g or 0, c.b or 0, c.a or 1)
end

local function boolStr(v)
    return (v == true) and "true" or "false"
end

local function numStr(v, fmt)
    if v == nil then return "null" end
    return string.format(fmt or "%.6f", v)
end

local function writeStateJson(state, slot)
    local mut = state.mutations or {}
    local skin = state.skin or {}
    local pd = state.primeData or {}
    local nutr = state.nutrients or {}
    local loc = state.location or { x=0, y=0, z=0 }
    local rot = state.rotation or { pitch=0, yaw=0, roll=0 }

    local unlockParts = {}
    for _, name in ipairs(state.unlockRequiredMutations or {}) do
        unlockParts[#unlockParts+1] = '"'..jsonEscape(name)..'"'
    end

    local lines = {
        '{',
        string.format('  "version": 1,'),
        string.format('  "slot": "%s",', jsonEscape(slot or "default")),
        string.format('  "capturedAt": %d,', state.capturedAt or 0),
        string.format('  "classPath": "%s",', jsonEscape(state.classPath or "")),
        string.format('  "growth": %s,', numStr(state.growth)),
        string.format('  "health": %s,', numStr(state.health)),
        string.format('  "stamina": %s,', numStr(state.stamina)),
        string.format('  "hunger": %s,', numStr(state.hunger)),
        string.format('  "thirst": %s,', numStr(state.thirst)),
        string.format('  "oxygen": %s,', numStr(state.oxygen)),
        string.format('  "blood": %s,', numStr(state.blood)),
        string.format('  "lockedDamage": %s,', numStr(state.lockedDamage, "%.6f")),
        string.format('  "food": %s,', numStr(state.food)),
        string.format('  "waterLevel": %s,', numStr(state.waterLevel)),
        string.format('  "rottenValue": %s,', numStr(state.rottenValue)),
        string.format('  "maxHunger": %s,', numStr(state.maxHunger)),
        string.format('  "maxFoodValue": %s,', numStr(state.maxFoodValue)),
        string.format('  "maxThirst": %s,', numStr(state.maxThirst)),
        string.format('  "maxStamina": %s,', numStr(state.maxStamina)),
        string.format('  "isFemale": %s,', boolStr(state.isFemale)),
        string.format('  "isPrime": %s,', boolStr(state.isPrime)),
        string.format('  "elderStacks": %d,', math.floor(state.elderStacks or 0)),
        string.format('  "unlockRequiredMutations": [%s],', table.concat(unlockParts, ",")),
        '  "nutrients": {',
        string.format('    "carbValue": %s, "proteinValue": %s, "lipidValue": %s,',
            numStr(nutr.carbValue), numStr(nutr.proteinValue), numStr(nutr.lipidValue)),
        string.format('    "bonesValue": %s, "cannibalValue": %s, "magyValue": %s,',
            numStr(nutr.bonesValue), numStr(nutr.cannibalValue), numStr(nutr.magyValue)),
        string.format('    "rottenFleshValue": %s, "mushroomsValue": %s,',
            numStr(nutr.rottenFleshValue), numStr(nutr.mushroomsValue)),
        string.format('    "bMalnutrition": %s', boolStr(nutr.bMalnutrition)),
        '  },',
        '  "primeData": {',
        string.format('    "eligible": %s,', boolStr(pd.eligible)),
        string.format('    "cond1": %s, "cond2": %s, "cond3": %s, "cond4": %s, "cond5": %s,',
            boolStr(pd.cond1), boolStr(pd.cond2), boolStr(pd.cond3), boolStr(pd.cond4), boolStr(pd.cond5)),
        string.format('    "cond6": %s, "cond7": %s, "cond8": %s, "cond9": %s, "cond10": %s',
            boolStr(pd.cond6), boolStr(pd.cond7), boolStr(pd.cond8), boolStr(pd.cond9), boolStr(pd.cond10)),
        '  },',
        '  "mutations": {',
        string.format('    "Slot1": "%s", "Slot2": "%s", "Slot3": "%s", "Slot4": "%s",',
            jsonEscape(mut.MutationSlot1 or ""), jsonEscape(mut.MutationSlot2 or ""),
            jsonEscape(mut.MutationSlot3 or ""), jsonEscape(mut.MutationSlot4 or "")),
        string.format('    "ParentSlot1": "%s", "ParentSlot2": "%s", "ParentSlot3": "%s", "ParentSlot4": "%s",',
            jsonEscape(mut.ParentMutationSlot1 or ""), jsonEscape(mut.ParentMutationSlot2 or ""),
            jsonEscape(mut.ParentMutationSlot3 or ""), jsonEscape(mut.ParentMutationSlot4 or "")),
        string.format('    "ElderSlot1A": "%s", "ElderSlot1B": "%s", "ElderSlot2A": "%s", "ElderSlot2B": "%s",',
            jsonEscape(mut.ElderMutationSlot1A or ""), jsonEscape(mut.ElderMutationSlot1B or ""),
            jsonEscape(mut.ElderMutationSlot2A or ""), jsonEscape(mut.ElderMutationSlot2B or "")),
        string.format('    "ElderSlot3A": "%s", "ElderSlot3B": "%s", "ElderSlot4A": "%s", "ElderSlot4B": "%s"',
            jsonEscape(mut.ElderMutationSlot3A or ""), jsonEscape(mut.ElderMutationSlot3B or ""),
            jsonEscape(mut.ElderMutationSlot4A or ""), jsonEscape(mut.ElderMutationSlot4B or "")),
        '  },',
        '  "skin": {',
        string.format('    "maleDisplay": %s,', colorJson(skin.maleDisplay)),
        string.format('    "markings": %s,', colorJson(skin.markings)),
        string.format('    "body": %s,', colorJson(skin.body)),
        string.format('    "flank": %s,', colorJson(skin.flank)),
        string.format('    "underbelly": %s,', colorJson(skin.underbelly)),
        string.format('    "detail1": %s,', colorJson(skin.detail1)),
        string.format('    "eyes": %s,', colorJson(skin.eyes)),
        string.format('    "skinVariation": %s,', numStr(skin.skinVariation, "%.6f")),
        string.format('    "patternIndex": %d', math.floor(skin.patternIndex or 0)),
        '  },',
        string.format('  "location": {"x":%.4f,"y":%.4f,"z":%.4f},', loc.x, loc.y, loc.z),
        string.format('  "rotation": {"pitch":%.4f,"yaw":%.4f,"roll":%.4f}', rot.pitch, rot.yaw, rot.roll),
        '}',
    }
    return table.concat(lines, "\n")
end

-- ============================================================
-- JSON deserializer
-- ============================================================

local function readStateJson(body)
    if body == nil or body == "" then return nil end
    local state = {}

    state.classPath  = jsonReadString(body, "classPath")
    state.growth     = jsonReadNumber(body, "growth")
    state.health     = jsonReadNumber(body, "health")
    state.stamina    = jsonReadNumber(body, "stamina")
    state.hunger     = jsonReadNumber(body, "hunger")
    state.thirst     = jsonReadNumber(body, "thirst")
    state.oxygen     = jsonReadNumber(body, "oxygen")
    state.blood      = jsonReadNumber(body, "blood")
    state.lockedDamage = jsonReadNumber(body, "lockedDamage")
    state.food       = jsonReadNumber(body, "food")
    state.waterLevel = jsonReadNumber(body, "waterLevel")
    state.rottenValue = jsonReadNumber(body, "rottenValue")
    state.maxHunger  = jsonReadNumber(body, "maxHunger")
    state.maxFoodValue = jsonReadNumber(body, "maxFoodValue")
    state.maxThirst  = jsonReadNumber(body, "maxThirst")
    state.maxStamina = jsonReadNumber(body, "maxStamina")
    state.isFemale   = jsonReadBool(body, "isFemale")
    state.isPrime    = jsonReadBool(body, "isPrime")
    state.elderStacks = math.floor(jsonReadNumber(body, "elderStacks") or 0)
    state.capturedAt = jsonReadNumber(body, "capturedAt")
    state.slot       = jsonReadString(body, "slot") or "default"

    -- Unlock list
    state.unlockRequiredMutations = {}
    local unlockBlock = string.match(body, '"unlockRequiredMutations"%s*:%s*%[(.-)%]')
    if unlockBlock then
        for name in unlockBlock:gmatch('"([^"]+)"') do
            state.unlockRequiredMutations[#state.unlockRequiredMutations+1] = name
        end
    end

    -- Prime data
    local pdBlock = string.match(body, '"primeData"%s*:%s*(%b{})')
    if pdBlock then
        state.primeData = {
            eligible = jsonReadBool(pdBlock,"eligible"),
            cond1=jsonReadBool(pdBlock,"cond1"), cond2=jsonReadBool(pdBlock,"cond2"),
            cond3=jsonReadBool(pdBlock,"cond3"), cond4=jsonReadBool(pdBlock,"cond4"),
            cond5=jsonReadBool(pdBlock,"cond5"), cond6=jsonReadBool(pdBlock,"cond6"),
            cond7=jsonReadBool(pdBlock,"cond7"), cond8=jsonReadBool(pdBlock,"cond8"),
            cond9=jsonReadBool(pdBlock,"cond9"), cond10=jsonReadBool(pdBlock,"cond10"),
        }
    end

    -- Mutations
    local mutBlock = string.match(body, '"mutations"%s*:%s*(%b{})')
    if mutBlock then
        state.mutations = {
            MutationSlot1 = jsonReadString(mutBlock,"Slot1") or "",
            MutationSlot2 = jsonReadString(mutBlock,"Slot2") or "",
            MutationSlot3 = jsonReadString(mutBlock,"Slot3") or "",
            MutationSlot4 = jsonReadString(mutBlock,"Slot4") or "",
            ParentMutationSlot1 = jsonReadString(mutBlock,"ParentSlot1") or "",
            ParentMutationSlot2 = jsonReadString(mutBlock,"ParentSlot2") or "",
            ParentMutationSlot3 = jsonReadString(mutBlock,"ParentSlot3") or "",
            ParentMutationSlot4 = jsonReadString(mutBlock,"ParentSlot4") or "",
            ElderMutationSlot1A = jsonReadString(mutBlock,"ElderSlot1A") or "",
            ElderMutationSlot1B = jsonReadString(mutBlock,"ElderSlot1B") or "",
            ElderMutationSlot2A = jsonReadString(mutBlock,"ElderSlot2A") or "",
            ElderMutationSlot2B = jsonReadString(mutBlock,"ElderSlot2B") or "",
            ElderMutationSlot3A = jsonReadString(mutBlock,"ElderSlot3A") or "",
            ElderMutationSlot3B = jsonReadString(mutBlock,"ElderSlot3B") or "",
            ElderMutationSlot4A = jsonReadString(mutBlock,"ElderSlot4A") or "",
            ElderMutationSlot4B = jsonReadString(mutBlock,"ElderSlot4B") or "",
        }
    end

    -- Nutrients
    local nutrBlock = string.match(body, '"nutrients"%s*:%s*(%b{})')
    if nutrBlock then
        state.nutrients = {
            carbValue    = jsonReadNumber(nutrBlock,"carbValue") or 0,
            proteinValue = jsonReadNumber(nutrBlock,"proteinValue") or 0,
            lipidValue   = jsonReadNumber(nutrBlock,"lipidValue") or 0,
            bonesValue   = jsonReadNumber(nutrBlock,"bonesValue") or 0,
            cannibalValue = jsonReadNumber(nutrBlock,"cannibalValue") or 0,
            magyValue    = jsonReadNumber(nutrBlock,"magyValue") or 0,
            rottenFleshValue = jsonReadNumber(nutrBlock,"rottenFleshValue") or 0,
            mushroomsValue = jsonReadNumber(nutrBlock,"mushroomsValue") or 0,
            bMalnutrition = jsonReadBool(nutrBlock,"bMalnutrition"),
        }
    end

    -- Skin
    local skinBlock = string.match(body, '"skin"%s*:%s*(%b{})')
    if skinBlock then
        local function parseColor(key)
            local cb = string.match(skinBlock, '"'..key..'"%s*:%s*(%b{})')
            if cb == nil then return nil end
            return {
                r = tonumber(string.match(cb,'"r"%s*:%s*(-?%d+%.?%d*)')) or 0,
                g = tonumber(string.match(cb,'"g"%s*:%s*(-?%d+%.?%d*)')) or 0,
                b = tonumber(string.match(cb,'"b"%s*:%s*(-?%d+%.?%d*)')) or 0,
                a = tonumber(string.match(cb,'"a"%s*:%s*(-?%d+%.?%d*)')) or 1,
            }
        end
        state.skin = {
            body       = parseColor("body"),
            markings   = parseColor("markings"),
            flank      = parseColor("flank"),
            underbelly = parseColor("underbelly"),
            detail1    = parseColor("detail1"),
            eyes       = parseColor("eyes"),
            maleDisplay = parseColor("maleDisplay"),
            skinVariation = jsonReadNumber(skinBlock,"skinVariation"),
            patternIndex  = math.floor(jsonReadNumber(skinBlock,"patternIndex") or 0),
        }
    end

    return state
end

-- ============================================================
-- Storage file operations
-- ============================================================

local function playerDir(steam)
    return STORED_DIR .. "/" .. tostring(steam)
end

local function slotFile(steam, slot)
    return playerDir(steam) .. "/" .. (slot or "default") .. ".json"
end

local function saveState(steam, slot, state)
    local body = writeStateJson(state, slot)
    local path = slotFile(steam, slot)
    ensureDir(playerDir(steam))
    return writeAllAtomic(path, body)
end

local function loadState(steam, slot)
    local path = slotFile(steam, slot or "default")
    local body = readAll(path)
    if body == nil then return nil end
    return readStateJson(body)
end

local function deleteSlot(steam, slot)
    local path = slotFile(steam, slot or "default")
    return os.remove(path)
end

local function listSlots(steam)
    local slots = {}
    local indexBody = readAll(INDEX_FILE)
    if indexBody == nil then return slots end
    -- Extract just the entries array to avoid matching the outer wrapper object,
    -- which contains all users' data and would cause cross-user leakage.
    local entriesBlock = string.match(indexBody, '"entries"%s*:%s*(%b[])')
    if entriesBlock == nil then return slots end
    local steamStr = tostring(steam)
    for entry in entriesBlock:gmatch('%b{}') do
        if jsonReadString(entry, "steam") == steamStr then
            slots[#slots+1] = {
                slot      = jsonReadString(entry, "slot") or "default",
                classPath = jsonReadString(entry, "classPath") or "",
                growth    = jsonReadNumber(entry, "growth") or 0,
                capturedAt = jsonReadNumber(entry, "capturedAt") or 0,
            }
        end
    end
    return slots
end

-- Rebuild index from all stored state files by scanning presenceRegistry
-- (we can't enumerate the FS, so we rebuild from known steams)
local function updateIndex(steam, slot, state, remove)
    local indexBody = readAll(INDEX_FILE) or '{"schema":4,"entries":[]}'
    -- Remove old entry for this (steam, slot)
    local entries = {}
    for entry in indexBody:gmatch('%b{}') do
        local s = jsonReadString(entry, "steam")
        local sl = jsonReadString(entry, "slot") or "default"
        if not (s == tostring(steam) and sl == slot) then
            -- keep
            local cp = jsonReadString(entry,"classPath")
            if cp ~= nil then -- filter out the root object
                entries[#entries+1] = entry
            end
        end
    end
    if not remove and state ~= nil then
        local newEntry = string.format(
            '{"steam":"%s","slot":"%s","classPath":"%s","growth":%.6f,"capturedAt":%d}',
            jsonEscape(tostring(steam)), jsonEscape(slot),
            jsonEscape(state.classPath or ""), state.growth or 0, state.capturedAt or 0
        )
        entries[#entries+1] = newEntry
    end
    local newIndex = '{"schema":4,"entries":[\n' .. table.concat(entries, ",\n") .. '\n]}'
    writeAllAtomic(INDEX_FILE, newIndex)
end

-- ============================================================
-- State restoration
-- ============================================================

local function applyColor(cdata, field, c)
    if c == nil then return end
    local r, g, b = c.r or 0, c.g or 0, c.b or 0
    if r == 0 and g == 0 and b == 0 then r, g, b = 0.01, 0.01, 0.01 end
    pcall(function()
        cdata[field].R = r
        cdata[field].G = g
        cdata[field].B = b
        cdata[field].A = c.a or 1.0
    end)
end

local function applyState(pawn, steam, state)
    if pawn == nil or state == nil then return false, "nil pawn or state" end

    -- 1. Growth (first pass) — will wipe vitals but we re-apply later
    if state.growth ~= nil then
        pcall(function() pawn:SetGrowth(state.growth) end)
    end

    -- 2. Staged mutation apply (parent + elder slots, no UFunction per-slot)
    local mut = state.mutations or {}
    local rmData; pcall(function() rmData = pawn.ReplicatedMutationsData end)
    if rmData ~= nil then
        local parentSlots = {"ParentMutationSlot1","ParentMutationSlot2","ParentMutationSlot3","ParentMutationSlot4"}
        local elderSlots  = {"ElderMutationSlot1A","ElderMutationSlot1B",
                              "ElderMutationSlot2A","ElderMutationSlot2B",
                              "ElderMutationSlot3A","ElderMutationSlot3B",
                              "ElderMutationSlot4A","ElderMutationSlot4B"}
        for _, slot in ipairs(parentSlots) do
            local s = mut[slot]
            if s and s ~= "" then
                local okF, fn = pcall(function() return FName(s) end)
                if okF and fn ~= nil then
                    pcall(function() rmData[slot] = fn end)
                end
            end
        end
        for _, slot in ipairs(elderSlots) do
            local s = mut[slot]
            if s and s ~= "" then
                local okF, fn = pcall(function() return FName(s) end)
                if okF and fn ~= nil then
                    pcall(function() rmData[slot] = fn end)
                end
            end
        end
        pcall(function() pawn:SetReplicatedMutationsData(rmData, true) end)
    end

    -- 3. Nutrients
    local nutr = state.nutrients
    if nutr ~= nil then
        local nutrStruct; pcall(function() nutrStruct = pawn.NutrientsStruct end)
        if nutrStruct ~= nil then
            pcall(function()
                nutrStruct.CarbValue        = nutr.carbValue or 0
                nutrStruct.ProteinValue     = nutr.proteinValue or 0
                nutrStruct.LipidValue       = nutr.lipidValue or 0
                nutrStruct.BonesValue       = nutr.bonesValue or 0
                nutrStruct.MagyValue        = nutr.magyValue or 0
                nutrStruct.MushroomsValue   = nutr.mushroomsValue or 0
                -- Always zero debuff-causing nutrients immediately on restore
                nutrStruct.CannibalValue    = 0.0
                nutrStruct.RottenFleshValue = 0.0
                nutrStruct.bMalnutrition    = false
                pawn:SetNutrientsStruct(nutrStruct, true)
            end)
        end
    end

    -- 4. Prime data
    if state.isPrime then
        local pe; pcall(function() pe = pawn:GetEligiblePrimeElderData() end)
        if pe ~= nil then
            for i = 1, 10 do pe["bPrimeCondition"..i] = true end
            pe.bIsEligiblePrime = true
            pcall(function() pawn:SetEligiblePrimeElderData(pe) end)
        end
    elseif state.primeData ~= nil then
        local pd = state.primeData
        local pe; pcall(function() pe = pawn:GetEligiblePrimeElderData() end)
        if pe ~= nil then
            for i = 1, 10 do pe["bPrimeCondition"..i] = pd["cond"..i] == true end
            pe.bIsEligiblePrime = pd.eligible == true
            pcall(function() pawn:SetEligiblePrimeElderData(pe) end)
        end
    end

    -- 5. Unlock required mutations (write BEFORE deferred slot apply)
    if state.unlockRequiredMutations and #state.unlockRequiredMutations > 0 then
        local liveMR; pcall(function() liveMR = pawn.MutationsRequirementsData end)
        if liveMR ~= nil then
            local arr; pcall(function() arr = liveMR.UnlockRequiredMutations end)
            if arr ~= nil then
                local currentN = 0; pcall(function() currentN = #arr end)
                currentN = type(currentN)=="number" and currentN or 0
                local existing = {}
                for i = 1, currentN do
                    local raw; pcall(function() raw = arr[i] end)
                    if raw ~= nil then
                        local s; pcall(function() s = raw:ToString() end)
                        if type(s)=="string" then existing[s]=true end
                    end
                end
                local added = 0
                for _, name in ipairs(state.unlockRequiredMutations) do
                    if not existing[name] then
                        local okW = pcall(function() arr[currentN+1+added] = FName(name) end)
                        if okW then added = added + 1 end
                    end
                end
                if added > 0 then
                    pcall(function() pawn:SetMutationRequirementsData(liveMR) end)
                end
            end
        end
    end

    -- 6. Elder replication stacks
    if state.elderStacks and state.elderStacks > 0 then
        pcall(function() pawn:SetElderReplicationStacks(state.elderStacks) end)
    end

    -- 7. Re-apply vitals (after any growth changes wiped them)
    local function setVital(fn, val)
        if val ~= nil then pcall(function() pawn[fn](pawn, val) end) end
    end
    setVital("SetHealth",  state.health)
    setVital("SetStamina", state.stamina)
    setVital("SetOxygen",  state.oxygen)
    -- Fill hunger/thirst/food/water immediately so there is no window between now and
    -- the deferred block where the game can stamp dehydration or starvation conditions.
    pcall(function() pawn:SetHunger(9999.0) end)
    pcall(function() pawn:SetThirst(9999.0) end)
    pcall(function() pawn:SetFoodValue(9999.0) end)
    pcall(function() pawn:SetWaterLevel(9999.0) end)
    -- Fill blood to max, zero locked damage and rotten value to prevent muscle spasms/vomiting
    pcall(function() pawn:SetBlood(9999.0) end)
    pcall(function() pawn:SetLockedDamage(0.0) end)
    pcall(function() pawn:SetRottenValue(0.0) end)

    -- 8. Skin
    if state.skin ~= nil then
        local cdata; pcall(function() cdata = pawn:GetCustomizerData() end)
        if cdata ~= nil then
            local sk = state.skin
            applyColor(cdata,"BodyColor",       sk.body)
            applyColor(cdata,"MarkingsColor",   sk.markings)
            applyColor(cdata,"FlankColor",      sk.flank)
            applyColor(cdata,"UnderbellyColor", sk.underbelly)
            applyColor(cdata,"Detail1Color",    sk.detail1)
            applyColor(cdata,"EyesColor",       sk.eyes)
            applyColor(cdata,"MaleDisplayColor",sk.maleDisplay)
            if sk.skinVariation ~= nil then
                pcall(function() cdata.SkinVariation = sk.skinVariation end)
            end
            if sk.patternIndex ~= nil then
                pcall(function() cdata.PatternIndex = sk.patternIndex end)
            end
            pcall(function() pawn:SetCustomizerData(cdata) end)
        end
    end

    -- 9. Deferred: write active mutation slots 1-4 via field-write (500ms)
    local steamSnap = tostring(steam)
    local slotsSnap = {
        { num=1, str=mut.MutationSlot1 },
        { num=2, str=mut.MutationSlot2 },
        { num=3, str=mut.MutationSlot3 },
        { num=4, str=mut.MutationSlot4 },
    }

    if LoopInGameThreadWithDelay ~= nil then
        local handle
        handle = LoopInGameThreadWithDelay(DEFERRED_MS, function()
            if handle ~= nil and CancelDelayedAction ~= nil then
                pcall(function() CancelDelayedAction(handle) end)
            end

            local gm2 = findGameMode(); if gm2 == nil then return end
            local ctrl2; pcall(function() ctrl2 = gm2:GetControllerBySteamId(steamSnap) end)
            if ctrl2 == nil then return end
            local pawn2 = livePawnFromCtrl(ctrl2)
            if pawn2 == nil then return end

            -- Re-write unlock list as defensive second pass
            if state.unlockRequiredMutations and #state.unlockRequiredMutations > 0 then
                local liveMR2; pcall(function() liveMR2 = pawn2.MutationsRequirementsData end)
                if liveMR2 ~= nil then
                    local arr2; pcall(function() arr2 = liveMR2.UnlockRequiredMutations end)
                    if arr2 ~= nil then
                        local n2 = 0; pcall(function() n2 = #arr2 end)
                        n2 = type(n2)=="number" and n2 or 0
                        local ex2 = {}
                        for i = 1, n2 do
                            local raw2; pcall(function() raw2 = arr2[i] end)
                            if raw2 then
                                local s2; pcall(function() s2 = raw2:ToString() end)
                                if type(s2)=="string" then ex2[s2]=true end
                            end
                        end
                        local added2 = 0
                        for _, name in ipairs(state.unlockRequiredMutations) do
                            if not ex2[name] then
                                local okW2 = pcall(function() arr2[n2+1+added2] = FName(name) end)
                                if okW2 then added2=added2+1 end
                            end
                        end
                        if added2 > 0 then
                            pcall(function() pawn2:SetMutationRequirementsData(liveMR2) end)
                        end
                    end
                end
            end

            -- Active slots via field-write
            local liveMut2; pcall(function() liveMut2 = pawn2.ReplicatedMutationsData end)
            if liveMut2 == nil then return end
            local written = 0
            for _, slot in ipairs(slotsSnap) do
                local s = slot.str
                if s ~= nil and s ~= "" and s ~= "None"
                    and not s:find('["\\]') and not s:find("FNameUserdata") then
                    local okF, fn = pcall(function() return FName(s) end)
                    if okF and fn ~= nil and type(fn) ~= "string" then
                        local fieldName = "MutationSlot" .. slot.num
                        local okW = pcall(function() liveMut2[fieldName] = fn end)
                        if okW then written = written + 1 end
                    end
                end
            end
            if written > 0 then
                pcall(function() pawn2:SetReplicatedMutationsData(liveMut2, true) end)
            end

            -- Final growth and vitals re-apply
            if state.growth ~= nil then
                pcall(function() pawn2:SetGrowth(state.growth) end)
            end
            if state.health   ~= nil then pcall(function() pawn2:SetHealth(state.health) end) end
            if state.stamina  ~= nil then pcall(function() pawn2:SetStamina(state.stamina) end) end

            -- Fill hunger, thirst, food value, and water level to max (game clamps to actual max)
            pcall(function() pawn2:SetHunger(9999.0) end)
            pcall(function() pawn2:SetThirst(9999.0) end)
            pcall(function() pawn2:SetFoodValue(9999.0) end)
            pcall(function() pawn2:SetWaterLevel(9999.0) end)

            -- Fill all diet nutrients to full and clear malnutrition
            local nutr; pcall(function() nutr = pawn2.NutrientsStruct end)
            if nutr ~= nil then
                pcall(function()
                    -- Fill normal diet nutrients to max
                    nutr.CarbValue        = 9999.0
                    nutr.ProteinValue     = 9999.0
                    nutr.LipidValue       = 9999.0
                    nutr.BonesValue       = 9999.0
                    nutr.MagyValue        = 9999.0
                    nutr.MushroomsValue   = 9999.0
                    -- Zero debuff-causing nutrients (rotten flesh = food poisoning, cannibal = spasms/infertility)
                    nutr.RottenFleshValue = 0.0
                    nutr.CannibalValue    = 0.0
                    nutr.bMalnutrition    = false
                    pawn2:SetNutrientsStruct(nutr, true)
                end)
            end

            -- Fill blood to max, zero locked damage and rotten value to prevent muscle spasms/vomiting
            pcall(function() pawn2:SetBlood(9999.0) end)
            pcall(function() pawn2:SetLockedDamage(0.0) end)
            pcall(function() pawn2:SetRottenValue(0.0) end)

            queueNotify(steamSnap, "Dino restored! Stats, hunger, thirst, and diets filled.")
        end)
    end

    return true, "restore initiated"
end

-- ============================================================
-- Command handlers
-- ============================================================

-- Returns (ok, msg) so IPC callers get a real status.
local function cmdStore(steam, slot)
    slot = slot or "default"
    local gm = findGameMode()
    if gm == nil then return false, "Server not ready." end
    local ctrl; pcall(function() ctrl = gm:GetControllerBySteamId(steam) end)
    if ctrl == nil then return false, "You must be logged into the server." end
    local pawn = livePawnFromCtrl(ctrl)
    if pawn == nil then return false, "You need a live dino to park." end

    -- Growth gate: 75%+ required
    local growth = 0
    pcall(function() growth = pawn:GetGrowth() end)
    if growth < 0.75 then
        local pct = math.floor(growth * 100)
        return false, string.format("Your dino must be at least 75%% growth to park. Currently %d%%.", pct)
    end

    local state = captureState(pawn, steam)
    if state.classPath == nil then
        return false, "Could not read dino state."
    end

    if saveState(steam, slot, state) then
        updateIndex(steam, slot, state, false)
        queueNotify(steam, string.format("Dino parked in slot '%s'. Returning to spawn in 3 seconds...", slot))
        -- Deferred kill
        if LoopInGameThreadWithDelay ~= nil then
            local killHandle
            local steamSnap = tostring(steam)
            killHandle = LoopInGameThreadWithDelay(STORE_DELAY_MS, function()
                if killHandle ~= nil and CancelDelayedAction ~= nil then
                    pcall(function() CancelDelayedAction(killHandle) end)
                end
                local gm2 = findGameMode(); if gm2 == nil then return end
                local ctrl2; pcall(function() ctrl2 = gm2:GetControllerBySteamId(steamSnap) end)
                if ctrl2 == nil then return end
                local pawn2 = livePawnFromCtrl(ctrl2); if pawn2 == nil then return end
                -- Zero growth before killing so the corpse left behind is tiny
                pcall(function() pawn2:SetGrowth(0) end)
                pcall(function() pawn2:SetHealth(0) end)
            end)
        end
        local species = (state.classPath:match("BP_(.-)%.") or "dino"):gsub("_C$","")
        return true, string.format("**%s** parked in slot '%s' (%.0f%% growth). Returning to spawn shortly.", species, slot, growth * 100)
    else
        return false, "Failed to save dino state to disk."
    end
end

-- Returns (ok, msg) so IPC callers get a real status.
local function cmdRetrieve(steam, slot)
    slot = slot or "default"

    -- Check player is online before queuing
    local gm = findGameMode()
    if gm == nil then return false, "Server not ready." end
    local ctrl; pcall(function() ctrl = gm:GetControllerBySteamId(steam) end)
    if ctrl == nil then return false, "You must be logged into the server." end

    local state = loadState(steam, slot)
    if state == nil then
        return false, string.format("No parked dino found in slot '%s'.", slot)
    end

    -- Species match: player must already be playing the correct species
    local pawn = livePawnFromCtrl(ctrl)
    if pawn == nil then
        local storedSpecies = (state.classPath and state.classPath:match("BP_(.-)%.") or "dino"):gsub("_C$","")
        return false, string.format("You need a live dino to retrieve into. Spawn as %s first.", storedSpecies)
    end
    local liveFull; pcall(function() liveFull = pawn:GetClass():GetFullName() end)
    local liveClass = liveFull and (string.match(liveFull, "^%S+%s+(.+)$") or liveFull) or ""
    local storedClass = state.classPath or ""
    if liveClass ~= storedClass then
        local liveSpecies = (liveClass:match("BP_(.-)%.") or "unknown"):gsub("_C$","")
        local storedSpecies = (storedClass:match("BP_(.-)%.") or "dino"):gsub("_C$","")
        return false, string.format("Species mismatch: you are playing as %s but this slot contains %s.", liveSpecies, storedSpecies)
    end

    local species = (state.classPath and state.classPath:match("BP_(.-)%.") or "dino"):gsub("_C$","")
    queueNotify(steam, string.format("Retrieving %s from slot '%s'. Spawn the same species now!", species, slot))

    -- Deferred apply
    if LoopInGameThreadWithDelay ~= nil then
        local steamSnap = tostring(steam)
        local retrieveHandle
        retrieveHandle = LoopInGameThreadWithDelay(RETRIEVE_DELAY_MS, function()
            if retrieveHandle ~= nil and CancelDelayedAction ~= nil then
                pcall(function() CancelDelayedAction(retrieveHandle) end)
            end
            local gm2 = findGameMode(); if gm2 == nil then return end
            local ctrl2; pcall(function() ctrl2 = gm2:GetControllerBySteamId(steamSnap) end)
            if ctrl2 == nil then return end
            local pawn2 = livePawnFromCtrl(ctrl2)
            if pawn2 == nil then
                queueNotify(steamSnap, "No live dino found — spawn your " .. species .. " first.")
                return
            end
            applyState(pawn2, steamSnap, state)
        end)
    end

    return true, string.format("Retrieving **%s** from slot '%s'. Spawn the same species now!", species, slot)
end

local function cmdStoreInfo(steam)
    local slots = listSlots(steam)
    if #slots == 0 then
        queueNotify(steam, "You have no stored dinos.")
        return
    end
    local parts = {}
    for _, s in ipairs(slots) do
        local species = (s.classPath:match("BP_(.-)%.") or "unknown"):gsub("_C$","")
        parts[#parts+1] = string.format("%s: %s (%.0f%%)", s.slot, species, (s.growth or 0)*100)
    end
    queueNotify(steam, "Stored: " .. table.concat(parts, " | "))
end

-- ============================================================
-- IPC: cmd.flag polling (DinoStorage legacy format)
-- ============================================================

local function emitResult(id, steam, tokens, ok, msg)
    local tokensJson = "["
    for i, t in ipairs(tokens) do
        if i > 1 then tokensJson = tokensJson .. "," end
        tokensJson = tokensJson .. '"' .. jsonEscape(t) .. '"'
    end
    tokensJson = tokensJson .. "]"
    local line = string.format(
        '{"id":"%s","ts":%d,"source":"DinoStorage","steam":"%s","args":%s,"ok":%s,"msg":"%s"}',
        jsonEscape(tostring(id or "")), os.time(),
        jsonEscape(tostring(steam)), tokensJson,
        tostring(ok == true), jsonEscape(tostring(msg or ""))
    )
    appendLine(RESULTS_FILE, line)
end

local function pollCmdFlag()
    if not fileExists(CMD_FLAG) then return end
    local stash = CMD_FLAG .. ".processing"
    os.remove(stash)
    os.rename(CMD_FLAG, stash)
    local body = readAll(stash)
    if body == nil or body == "" then os.remove(stash); return end

    for line in body:gmatch("[^\n]+") do
        -- Format: [id] verb steam [extra...]
        local cmdId, verb, rest = line:match("^%[([^%]]*)%]%s+(%S+)%s*(.*)")
        if cmdId == nil then
            verb, rest = line:match("^(%S+)%s*(.*)")
            cmdId = ""
        end

        if verb ~= nil then
            local tokens = {}
            for tok in (rest or ""):gmatch("%S+") do tokens[#tokens+1] = tok end
            local steam = tokens[1] or ""
            local extraArgs = {}
            for i = 2, #tokens do extraArgs[#extraArgs+1] = tokens[i] end

            local ok = false; local msg = "unknown verb"

            if verb == "store" then
                local slot = extraArgs[1] or "default"
                ok, msg = cmdStore(steam, slot)
                ok = ok == true
            elseif verb == "retrieve" then
                local slot = extraArgs[1] or "default"
                ok, msg = cmdRetrieve(steam, slot)
                ok = ok == true
            elseif verb == "delete" then
                local slot = extraArgs[1] or "default"
                deleteSlot(steam, slot)
                updateIndex(steam, slot, nil, true)
                ok = true; msg = "slot deleted"
            elseif verb == "rename" then
                local oldSlot = extraArgs[1] or "default"
                local newSlot = extraArgs[2]
                if newSlot == nil or newSlot == "" then
                    ok = false; msg = "missing new slot name"
                else
                    local oldPath = slotFile(steam, oldSlot)
                    if not fileExists(oldPath) then
                        ok = false; msg = "slot not found: " .. oldSlot
                    else
                        local newPath = slotFile(steam, newSlot)
                        if fileExists(newPath) then
                            ok = false; msg = "a slot named '" .. newSlot .. "' already exists"
                        else
                            local renameOk = os.rename(oldPath, newPath)
                            if renameOk then
                                local state = loadState(steam, newSlot)
                                if state then
                                    updateIndex(steam, oldSlot, nil, true)
                                    updateIndex(steam, newSlot, state, false)
                                end
                                ok = true; msg = string.format("renamed '%s' to '%s'", oldSlot, newSlot)
                            else
                                ok = false; msg = "rename failed"
                            end
                        end
                    end
                end
            elseif verb == "connected" then
                local gm = findGameMode()
                if gm == nil then
                    ok = false; msg = "Server not ready."
                else
                    local ctrl; pcall(function() ctrl = gm:GetControllerBySteamId(steam) end)
                    if ctrl ~= nil then
                        ok = true; msg = "online"
                    else
                        ok = false; msg = "You are not connected to the server."
                    end
                end
            elseif verb == "list" then
                local slots = listSlots(steam)
                local listJson = "["
                for i, s in ipairs(slots) do
                    if i > 1 then listJson = listJson .. "," end
                    local state = loadState(steam, s.slot)
                    local mut = (state and state.mutations) or {}
                    local mutJson = string.format(
                        '{"Slot1":"%s","Slot2":"%s","Slot3":"%s","Slot4":"%s",' ..
                        '"ParentSlot1":"%s","ParentSlot2":"%s","ParentSlot3":"%s","ParentSlot4":"%s",' ..
                        '"ElderSlot1A":"%s","ElderSlot1B":"%s","ElderSlot2A":"%s","ElderSlot2B":"%s",' ..
                        '"ElderSlot3A":"%s","ElderSlot3B":"%s","ElderSlot4A":"%s","ElderSlot4B":"%s"}',
                        jsonEscape(mut.MutationSlot1 or ""), jsonEscape(mut.MutationSlot2 or ""),
                        jsonEscape(mut.MutationSlot3 or ""), jsonEscape(mut.MutationSlot4 or ""),
                        jsonEscape(mut.ParentMutationSlot1 or ""), jsonEscape(mut.ParentMutationSlot2 or ""),
                        jsonEscape(mut.ParentMutationSlot3 or ""), jsonEscape(mut.ParentMutationSlot4 or ""),
                        jsonEscape(mut.ElderMutationSlot1A or ""), jsonEscape(mut.ElderMutationSlot1B or ""),
                        jsonEscape(mut.ElderMutationSlot2A or ""), jsonEscape(mut.ElderMutationSlot2B or ""),
                        jsonEscape(mut.ElderMutationSlot3A or ""), jsonEscape(mut.ElderMutationSlot3B or ""),
                        jsonEscape(mut.ElderMutationSlot4A or ""), jsonEscape(mut.ElderMutationSlot4B or "")
                    )
                    listJson = listJson .. string.format(
                        '{"slot":"%s","classPath":"%s","growth":%.6f,"capturedAt":%d,"mutations":%s}',
                        jsonEscape(s.slot), jsonEscape(s.classPath), s.growth, s.capturedAt, mutJson
                    )
                end
                listJson = listJson .. "]"
                ok = true; msg = listJson
            end

            emitResult(cmdId, steam, tokens, ok, msg)
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
        -- Create Saved/ and stored/ subdirectory if they don't exist
        ensureDir(SAVED_DIR)
        ensureDir(STORED_DIR)
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
        safeCall("drainNotifies", drainNotifies)
        safeCall("pollCmdFlag",   pollCmdFlag)

        local reload = consumeFlag(RELOAD_FLAG)
        if reload ~= nil and RestartCurrentMod ~= nil then
            log("RELOAD")
            RestartCurrentMod()
        end
    end)
end

log(string.format("Loaded; version=%s", MOD_VERSION))
