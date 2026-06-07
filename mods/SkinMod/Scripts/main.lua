-- SkinMod v001
-- Per-player skin color persistence with auto-restore on login.
-- All commands are Discord-only via the CommandBridge skin verb (direct IPC handler).

local MOD_NAME    = "SkinMod"
local MOD_VERSION = "v001"

local SAVED_DIR   = "Mods/SkinMod/Saved"
local SKINS_DIR   = SAVED_DIR .. "/skins"
local CONFIG_FILE = SAVED_DIR .. "/config.json"
local RELOAD_FLAG = SAVED_DIR .. "/reload.flag"

local POLL_INTERVAL_MS = 3000

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

local function writeAllAtomic(path, body)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb"); if f == nil then return false end
    f:write(body); f:close()
    os.remove(path)
    return os.rename(tmp, path)
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

local function jsonReadBool(body, key)
    local v = string.match(body or "", '"'..key..'"%s*:%s*([%a]+)')
    if v == "true" then return true end
    if v == "false" then return false end
    return nil
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
        if (now - entry.lastSeen) > PRESENCE_EXPIRY_SEC then
            presenceRegistry[steam] = nil
        else
            local ctrl; pcall(function() ctrl = gm:GetControllerBySteamId(steam) end)
            if ctrl == nil then
                presenceRegistry[steam] = nil
            else
                local pawn = livePawnFromCtrl(ctrl)
                results[#results+1] = { controller=ctrl, pawn=pawn, steam=steam }
            end
        end
    end
    return results
end

-- ============================================================
-- Skin helpers
-- ============================================================

local SKIN_FIELD_MAP = {
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

local ALL_FIELDS = {
    "BodyColor","MarkingsColor","FlankColor","UnderbellyColor",
    "Detail1Color","EyesColor","MaleDisplayColor"
}

local VISIBLE_FIELDS = {
    "BodyColor","MarkingsColor","FlankColor","UnderbellyColor"
}

local function parseSkinColor(raw)
    local n = tonumber(raw)
    if n == nil then return nil end
    if n > 1 then return n / 255 end
    return n
end

local function clamp(v)
    return math.max(0, math.min(1, v))
end

local function bumpBlack(r, g, b)
    if r == 0 and g == 0 and b == 0 then return 0.01, 0.01, 0.01 end
    return r, g, b
end

-- Save skin to disk
local function saveSkin(steam, colors)
    local parts = {}
    for field, c in pairs(colors) do
        parts[#parts+1] = string.format('  "%s": {"r":%.6f,"g":%.6f,"b":%.6f,"a":%.6f}',
            field, c.r, c.g, c.b, c.a)
    end
    local body = "{\n" .. table.concat(parts, ",\n") .. "\n}"
    local path = SKINS_DIR .. "/" .. tostring(steam) .. ".json"
    return writeAllAtomic(path, body)
end

-- Delete skin override (reset)
local function deleteSkin(steam)
    local path = SKINS_DIR .. "/" .. tostring(steam) .. ".json"
    return os.remove(path)
end

-- Load skin from disk
local function loadSkin(steam)
    local path = SKINS_DIR .. "/" .. tostring(steam) .. ".json"
    local body = readAll(path)
    if body == nil or body == "" then return nil end
    local out = {}
    for fieldName, colorBlock in body:gmatch('"([%w_]+)"%s*:%s*(%b{})') do
        local r = tonumber(colorBlock:match('"r"%s*:%s*(-?%d+%.?%d*)'))
        local g = tonumber(colorBlock:match('"g"%s*:%s*(-?%d+%.?%d*)'))
        local b = tonumber(colorBlock:match('"b"%s*:%s*(-?%d+%.?%d*)'))
        local a = tonumber(colorBlock:match('"a"%s*:%s*(-?%d+%.?%d*)')) or 1.0
        if r and g and b then out[fieldName] = { r=r, g=g, b=b, a=a } end
    end
    if next(out) == nil then return nil end
    return out
end

-- Apply skin colors to pawn
local function applySkin(pawn, colors)
    if pawn == nil or colors == nil then return false end
    local cdata; pcall(function() cdata = pawn:GetCustomizerData() end)
    if cdata == nil then return false end

    for field, c in pairs(colors) do
        local r, g, b = c.r or 0, c.g or 0, c.b or 0
        r, g, b = bumpBlack(r, g, b)
        pcall(function()
            cdata[field].R = r
            cdata[field].G = g
            cdata[field].B = b
            cdata[field].A = c.a or 1.0
        end)
    end

    local ok = pcall(function() pawn:SetCustomizerData(cdata) end)
    return ok
end

-- ============================================================
-- Auto-restore on pawn change
-- ============================================================

local lastPawnAddr = {}  -- steam -> last applied pawn address

local function autoRestore()
    local players = enumerateOnlinePlayers()
    for _, p in ipairs(players) do
        local saved = loadSkin(p.steam)
        if saved ~= nil and p.pawn ~= nil then
            local addr; pcall(function() addr = p.pawn:GetAddress() end)
            local addrKey = tostring(addr or 0)
            if lastPawnAddr[p.steam] ~= addrKey then
                applySkin(p.pawn, saved)
                lastPawnAddr[p.steam] = addrKey
            end
        end
    end
end

-- ============================================================
-- Pending notifies
-- ============================================================

local pendingNotifies = {}

local function queueNotify(steam, msg)
    pendingNotifies[#pendingNotifies+1] = { steam=steam, msg=msg }
end

local function safeNotify(steam, msg)
    if steam == nil or steam == "" then return end
    local gm = findGameMode(); if gm == nil then return end
    local ctrl; pcall(function() ctrl = gm:GetControllerBySteamId(steam) end)
    if ctrl == nil then return end
    local text = msg
    if FText ~= nil then
        local ok, ft = pcall(function() return FText(msg) end)
        if ok and ft ~= nil then text = ft end
    end
    pcall(function() ctrl:ClientShowNotification(text) end)
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
        ensureDir(SKINS_DIR)
        local testPath = SAVED_DIR .. "/.keep"
        local tf = io.open(testPath, "wb")
        if tf then tf:write(""); tf:close()
        else log("WARNING: cannot write to " .. SAVED_DIR .. " — directory creation may have failed!") end
        if bootHandle ~= nil and CancelDelayedAction ~= nil then
            pcall(function() CancelDelayedAction(bootHandle) end)
        end
    end)

    LoopInGameThreadWithDelay(POLL_INTERVAL_MS, function()
        safeCall("autoRestore",  autoRestore)
        safeCall("drainNotifies",drainNotifies)

        local reload = consumeFlag(RELOAD_FLAG)
        if reload ~= nil and RestartCurrentMod ~= nil then
            log("RELOAD")
            RestartCurrentMod()
        end
    end)
end

log(string.format("Loaded; version=%s", MOD_VERSION))
