-- Tar: remembers /tar commands typed in chat and repeats the last one.
--
-- Targeting by name is protected (TargetUnit is secure-only), so an addon
-- can't target for you directly. Two secure routes are used instead:
--   * a general macro (default "TarAgain") whose body is rewritten to the last
--     /tar line you typed, so pressing it runs that exact command;
--   * a hidden SecureActionButton (TarRepeatButton) with type="macro" and the
--     same macrotext, for the keybinding and for /click TarRepeatButton.
-- Both can only be changed out of combat; a command typed in combat is queued
-- and applied when combat ends.

local ADDON = ...
local MAX_HISTORY = 10
local DEFAULT_MACRO = "TarAgain"
local MACRO_ICONS = { "Ability_Hunter_SniperShot", "INV_Misc_QuestionMark", 134400 }

BINDING_HEADER_TAR = "Tar"
_G["BINDING_NAME_CLICK TarRepeatButton:LeftButton"] = "Repeat last /tar"

local db
local pending          -- line waiting for combat to end
local captureHooked = {}

local function say(msg)
    print("|cff66ccffTar|r: " .. msg)
end

local function inCombat()
    return InCombatLockdown and InCombatLockdown()
end

-- Commands that target by name. Built from the client's own slash lists so
-- localized aliases count too.
local targetCmds = {}
local function addCmds(prefix)
    local i = 1
    while true do
        local c = _G[prefix .. i]
        if not c then break end
        targetCmds[c:lower()] = true
        i = i + 1
    end
end
addCmds("SLASH_TARGET")
addCmds("SLASH_TARGET_EXACT")
for _, c in ipairs({ "/tar", "/target", "/targetexact" }) do
    targetCmds[c] = true
end

-- Returns a normalized "/cmd args" line if text is a by-name target command.
local function parseTargetLine(text)
    if type(text) ~= "string" then return nil end
    local cmd, rest = text:match("^%s*(/%S+)%s*(.-)%s*$")
    if not cmd or rest == "" then return nil end
    if not targetCmds[cmd:lower()] then return nil end
    return cmd:lower() .. " " .. rest
end

---------------------------------------------------------------------------
-- Secure repeat button
---------------------------------------------------------------------------
local button = CreateFrame("Button", "TarRepeatButton", UIParent, "SecureActionButtonTemplate")
button:SetSize(1, 1)
button:EnableMouse(false)
-- Both directions so /click and keybinds work whatever ActionButtonUseKeyDown
-- is set to; the secure template only acts on the matching one.
button:RegisterForClicks("AnyUp", "AnyDown")
button:SetAttribute("type", "macro")

---------------------------------------------------------------------------
-- Macro
---------------------------------------------------------------------------
local function macroName()
    return (db and db.macroName) or DEFAULT_MACRO
end

local function writeMacro(line, create)
    if not GetMacroIndexByName or not CreateMacro then return false, "macro API unavailable" end
    local name = macroName()
    local idx = GetMacroIndexByName(name)
    if idx and idx > 0 then
        local ok, res = pcall(EditMacro, idx, name, nil, line)
        return ok and res ~= nil, ok and nil or tostring(res)
    end
    if not create then return false, "no macro" end
    local ok, res
    for _, icon in ipairs(MACRO_ICONS) do
        ok, res = pcall(CreateMacro, name, icon, line, false)
        if ok and res then return true end
    end
    return false, ok and "macro slots full?" or tostring(res)
end

---------------------------------------------------------------------------
-- Apply / record
---------------------------------------------------------------------------
local function apply(line, quiet)
    if inCombat() then
        if pending ~= line and not quiet then
            say("in combat; will update to |cffffff00" .. line .. "|r when combat ends.")
        end
        pending = line
        return
    end
    pending = nil
    button:SetAttribute("macrotext", line)
    local ok, err = writeMacro(line, db.autoCreate)
    if not ok and db.debug then say("macro not updated: " .. tostring(err)) end
end

local function record(line)
    local h = db.history
    for i = #h, 1, -1 do
        if h[i] == line then table.remove(h, i) end
    end
    table.insert(h, 1, line)
    while #h > MAX_HISTORY do table.remove(h) end
    db.last = line
    apply(line)
end

local function onHistoryLine(_, text)
    if issecretvalue and issecretvalue(text) then
        if db and db.debug then say("chat line was secret; skipped") end
        return
    end
    if db and db.debug then say("saw chat line: " .. tostring(text)) end
    local line = parseTargetLine(text)
    if line and db then record(line) end
end

-- Every line sent from a chat edit box is added to its up-arrow history,
-- slash commands included. Post-hooking AddHistoryLine sees the text without
-- tainting the edit box (which would break /tar itself).
local function hookEditBox(eb)
    if eb and not captureHooked[eb] and eb.AddHistoryLine then
        hooksecurefunc(eb, "AddHistoryLine", onHistoryLine)
        captureHooked[eb] = true
    end
end

local function hookAllEditBoxes()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        hookEditBox(_G["ChatFrame" .. i .. "EditBox"])
    end
end

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------
local function listHistory()
    if #db.history == 0 then
        say("no /tar commands recorded yet. Type one, e.g. |cffffff00/tar Hogger|r.")
    else
        say("recent targets (|cffffff00/retar N|r to make one current):")
        for i, l in ipairs(db.history) do
            print(string.format("  %s%d. %s", i == 1 and "|cff00ff00" or "", i, l))
        end
    end
    print("  Macro: |cffffff00" .. macroName() .. "|r  |  /click TarRepeatButton  |  keybind under Key Bindings > AddOns > Tar")
    print("  /retar macro - create the macro  |  /retar clear  |  /retar debug")
end

SLASH_TARRETAR1 = "/retar"
SlashCmdList.TARRETAR = function(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$")
    local cmd = msg:lower()
    local n = tonumber(msg)
    if n then
        local line = db.history[n]
        if not line then say("no entry " .. n) return end
        record(line)
        say("current: |cffffff00" .. line .. "|r")
    elseif cmd == "macro" then
        if inCombat() then say("can't create macros in combat.") return end
        local line = db.last or "/tar "
        local ok, err = writeMacro(line, true)
        if ok then
            say("macro |cffffff00" .. macroName() .. "|r ready. Open /macro (General tab) and drag it to a bar.")
        else
            say("couldn't create macro: " .. tostring(err))
        end
    elseif cmd == "clear" then
        wipe(db.history)
        db.last = nil
        say("history cleared.")
    elseif cmd == "debug" then
        db.debug = not db.debug
        say("debug " .. (db.debug and "on" or "off"))
    else
        listHistory()
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        TarDB = TarDB or {}
        db = TarDB
        db.history = db.history or {}
        if db.autoCreate == nil then db.autoCreate = true end
        hookAllEditBoxes()
    elseif event == "PLAYER_LOGIN" then
        hookAllEditBoxes()
        if db.last and not inCombat() then
            button:SetAttribute("macrotext", db.last)
        elseif db.last then
            pending = db.last
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pending then
            local line = pending
            apply(line, true)
            say("updated to |cffffff00" .. line .. "|r.")
        end
    end
end)
