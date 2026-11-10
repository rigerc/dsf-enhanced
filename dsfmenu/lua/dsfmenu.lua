-- DSF menu: fills DriverNGHook's F2 menu bar (File, View, World, Game, Utilities) and adds
-- Felony Rework and DSF Enhanced settings windows.
--
-- Loaded from bootstrap.lua's Init. DriverNGHook's driverNGHookMenu.lua calls DSFMenu.menu(name)
-- inside each of its menus. Saving this file reloads it in game (checked every 2 s).
--
-- Rules that keep a mistake here from breaking ImGui's frame:
--  - every game call goes through try(), which never raises;
--  - menu callbacks draw only items, text and sliders (no Begin/End pairs of their own);
--  - a window's body runs in pcall between its Begin and End.

DSFMenu = DSFMenu or {}
local M = DSFMenu

M.showFelony = M.showFelony or false
M.showStatus = M.showStatus or false
M.showEnh = M.showEnh or false
M.speed = M.speed or 1.0
M.note = M.note or ""

local function log(msg)
    print("[DSFMenu] " .. msg)
end

local function setNote(msg)
    M.note = msg
    M.noteSerial = (M.noteSerial or 0) + 1   -- the HUD menu shows a new note for a few seconds
    log(msg)
end

-- Each distinct error goes to Driver.log once (an error in a drawn menu repeats every frame).
M.loggedErrors = M.loggedErrors or {}
local function logError(where, err)
    local msg = where .. ": " .. tostring(err)
    M.lastError = msg
    if not M.loggedErrors[msg] then
        M.loggedErrors[msg] = true
        log("ERROR " .. msg)
    end
    return msg
end

-- Calls f(...) and returns its results, or nil and logs the error.
local function try(f, ...)
    local ok, a, b = pcall(f, ...)
    if ok then
        return a, b
    end
    logError("game call", a)
    return nil
end

local function userPath(name)
    return (UserLuaMediaPath or "Common\\UserLuaScripts\\") .. name
end

-- The game's Lua can read the game folder but write only to its HDD: device, the folder
-- Documents\Ubisoft\Driver San Francisco. DSFMenu\ there holds links to the files the menu saves
-- (symlinks under Proton, hard links on Windows), so a write through HDD: lands in the game's file.
local LINK_DIR = "HDD:DSFMenu\\"

-- Writes newText to the game's file through its link, if the link shows the same text as the game's
-- file (oldText, just read from it): a copy instead of a link would keep the change to itself.
local function writeThroughLink(linkName, oldText, newText)
    local link = LINK_DIR .. linkName
    local f = io.open(link, "rb")
    if f == nil then
        return false, "the game can't write its own folder, and " .. link .. " (a link to the file) is missing"
    end
    local seen = f:read("*a")
    f:close()
    if seen ~= oldText then
        return false, link .. " isn't a link to the game's file (its text differs)"
    end
    f = io.open(link, "wb")
    if f == nil then
        return false, "can't write " .. link
    end
    f:write(newText)
    f:close()
    return true
end

-------------------------------------------------------------------------------------------
-- Felony Rework settings

local FELONY_CONFIG = "felonyrework\\felonyreworkconfig.txt"

-- when = "live": takes effect at once; "restart": loads a part of the mod at startup;
-- "copcar": the next time you get into an emergency vehicle; "mission": the next mission start.
M.felonySettings = {
    { group = "Felony system" },
    { key = "Roadblocks", text = "Roadblocks", when = "restart" },
    { key = "PursuitTermination", text = "Call off a getaway at very high Willpower", when = "live" },
    { key = "NoNegativeWillpower", text = "Willpower never goes below 0 (penalties take at most what you have)", when = "live",
      def = true },
    { key = "FelonyMusic", text = "Mission music in free-roam felonies", when = "restart" },
    { key = "Rubberbanding", text = "Rubber-banding for chasers in free-roam getaways", when = "live" },
    { group = "Crime system" },
    { key = "CrimeTracking", text = "Crime system", when = "restart" },
    { key = "CrimeTrackingReports", text = "Citizens report your car", when = "live" },
    { group = "Felony nightmares" },
    { key = "FelonyNightmares", text = "Nightmares during felonies", when = "restart" },
    { key = "FelonyNightmaresAlwaysOn", text = "A nightmare in every felony", when = "live" },
    { group = "Police and drivers" },
    { key = "PatrolManager", text = "Patrol density varies (0-3 cars)", when = "restart" },
    { key = "RadioScanner", text = "Police radio in emergency vehicles", when = "copcar" },
    { key = "DisableTannerForCops", text = "Police cars keep their own driver", when = "live" },
    { key = "DisableTanner", text = "All cars keep their own driver", when = "live" },
    { key = "DisableCopCommentary", text = "No conversations in police cars", when = "live" },
    { group = "Cameras" },
    { key = "CopDashCam", text = "Dash cam in a police car's hood view", when = "copcar" },
    { key = "FelonyICrashCam", text = "Crash cam in felonies", when = "live" },
    { key = "FelonyFreeDriveICrashCam", text = "Crash cam in free-roam felonies", when = "live" },
    { group = "Missions" },
    { key = "ExtremeSurvival", text = "\"Railroad cops\" in Classic Survival (infinite mass)", when = "mission" },
    { group = "Experimental" },
    { key = "ParkedVehicles", text = "Parked police cars at stations", when = "restart" },
    { key = "PoliceRightOfWay", text = "Traffic pulls over for cops", when = "live" },
    { key = "SearchingCops", text = "Cops search for you after losing you", when = "live" },
}

local WHEN_TEXT = {
    restart = "after a restart",
    copcar = "next emergency vehicle",
    mission = "next mission",
}

local function felonyInstalled()
    return type(felony_rework) == "table" or FelonyReworkConfigLoaded == true
end

local function felonyGet(key)
    return rawget(_G, "FelonyReworkConfig_" .. key)
end

local function felonySet(key, value)
    rawset(_G, "FelonyReworkConfig_" .. key, value)
    -- Felony only ever switches these on (felonyrework.lua), so switch them off here.
    if type(felony_rework) == "table" then
        if key == "FelonyICrashCam" and not value then
            felony_rework.allowFelonyICrashCam = false
        elseif key == "FelonyFreeDriveICrashCam" and not value then
            felony_rework.allowFelonyFreeDriveICrashCam = false
        end
    end
    M.felonyDirty = true
end

-- Writes the current values into the config file, keeping its comments and layout.
function M.saveFelony()
    local path = userPath(FELONY_CONFIG)
    local f = io.open(path, "rb")
    if f == nil then
        setNote("Can't read " .. path)
        return false
    end
    local text = f:read("*a")
    f:close()
    local original = text

    local count = 0
    text = string.gsub(text, "(FelonyReworkConfig_(%w+)%s*=%s*)(%a+)", function(prefix, key, old)
        local value = felonyGet(key)
        if type(value) ~= "boolean" then
            return nil
        end
        count = count + 1
        return prefix .. tostring(value)
    end)

    local ok, err = writeThroughLink("felonyreworkconfig.txt", original, text)
    if not ok then
        setNote("Felony settings not saved: " .. err)
        return false
    end
    M.felonyDirty = false
    setNote("Saved " .. count .. " Felony settings")
    return true
end

-- Reads the config file again (the values; a part that loads at startup still needs a restart).
function M.reloadFelony()
    local ok, err = pcall(dofile, userPath(FELONY_CONFIG))
    if ok then
        M.felonyDirty = false
        setNote("Felony settings read from the file")
    else
        setNote("Can't read the Felony settings: " .. tostring(err))
    end
end

local function felonyStatusText()
    if not felonyInstalled() then
        return "Felony Rework isn't loaded"
    end
    local getaway = try(function() return Getaway.IsAGetawayActive() end)
    local chase = try(function() return Chase.IsAChaseActive() end)
    if getaway then
        local heat = try(function() return felony_getaway.getCurrentHeatLevel() end)
        return "Getaway, felony level " .. tostring(heat or "?")
    elseif chase then
        return "Chase (you are the cop)"
    end
    return "No felony"
end

-------------------------------------------------------------------------------------------
-- Willpower: with Felony's NoNegativeWillpower setting, a penalty can't take Willpower below 0.
-- felony_getaway.lua limits each penalty; this check catches anything else, in missions too.

local function willpower()
    return try(function() return ProfileSettings.GetWillpower() end)
end

local function noNegativeWillpower()
    return felonyInstalled() and felonyGet("NoNegativeWillpower") ~= false
end

local wpFrames = 0
local function checkWillpower()
    wpFrames = wpFrames + 1
    if wpFrames < 30 then
        return
    end
    wpFrames = 0
    if not noNegativeWillpower() then
        return
    end
    local wp = willpower()
    if type(wp) == "number" and wp < 0 then
        try(function() ProfileSettings.SetWillpower(0) end)
        log("Willpower was " .. tostring(wp) .. ", set to 0")
    end
end

-------------------------------------------------------------------------------------------
-- DSF Enhanced settings: dsf_enhanced.ini in the game folder. DSF Enhanced reads it once, at
-- startup, so a saved change takes effect the next time the game starts.

local ENH_INI = "dsf_enhanced.ini"

-- kind: "bool" (1/0), "int" or "float" (a slider from lo to hi), "choice" (one of the values).
-- def is DSF Enhanced's value when the key isn't in the file. The tooltips are the file's comments.
M.enhSettings = {
    { group = "Display" },
    { section = "Display", key = "BorderlessWindowed", text = "Borderless window", kind = "bool", def = 0 },
    { section = "Display", key = "RemoveVSync", text = "Turn off V-sync", kind = "bool", def = 0 },
    { section = "Ultrawide", key = "Enabled", text = "Ultrawide support", kind = "bool", def = 1 },
    { section = "Ultrawide", key = "FOVScaling", text = "Wider field of view on wide screens", kind = "bool", def = 1 },
    { section = "Ultrawide", key = "CinematicDrawPatch", text = "Fit cutscene videos to the screen", kind = "bool", def = 1 },
    { group = "Textures" },
    { section = "Quality", key = "AnisotropicFiltering", text = "Anisotropic filtering", kind = "choice",
      values = { 0, 2, 4, 8, 16 }, labels = { [0] = "Game" }, def = 16 },
    { section = "Quality", key = "ForceTrilinearFiltering", text = "At least trilinear filtering", kind = "bool", def = 0 },
    { section = "Quality", key = "ForceHighestMip", text = "Keep full-resolution textures", kind = "bool", def = 0 },
    { section = "Quality", key = "TextureLODBias", text = "Texture sharpness (negative is sharper)", kind = "float",
      lo = -3.0, hi = 3.0, fmt = "%.2f", def = 0.0, step = 0.25 },
    { group = "Detail and draw distance" },
    { section = "Quality", key = "VehicleFullDetail", text = "Traffic at full detail out to the draw distance", kind = "bool", def = 0 },
    { section = "Quality", key = "VehicleLODThresholdScale", text = "Car detail switch (lower is farther; when the above is off)",
      kind = "float", lo = 0.25, hi = 2.0, fmt = "%.2f", def = 1.0, step = 0.05 },
    { section = "Quality", key = "VehicleDrawDistance", text = "Car draw distance in m (0 = game's)", kind = "int",
      lo = 0, hi = 3000, def = 0, step = 100 },
    { section = "Quality", key = "MapDetailLODThresholdScale", text = "World detail switch (lower is farther)", kind = "float",
      lo = 0.25, hi = 2.0, fmt = "%.2f", def = 1.0, step = 0.05 },
    { section = "Quality", key = "LODEngineThresholdScale", text = "Terrain and people detail switch (lower is farther)",
      kind = "float", lo = 0.25, hi = 2.0, fmt = "%.2f", def = 1.0, step = 0.05 },
    { section = "Quality", key = "ImposterDrawDistance", text = "Distant buildings draw distance (-1 = game's)", kind = "int",
      lo = -1, hi = 7000, def = 2800, step = 100 },
    { section = "Shadows", key = "ShadowMapSize", text = "Shadow resolution", kind = "choice",
      values = { 0, 1024, 1536, 2048, 3072, 4096 }, labels = { [0] = "Game" }, def = 0 },
    { section = "Quality", key = "CockpitPassengers", text = "Show passengers in in-car views", kind = "bool", def = 1 },
    { group = "Traffic" },
    { section = "Quality", key = "TrafficSpawnRadius", text = "Traffic radius in m (game: 350)", kind = "int",
      lo = 350, hi = 500, def = 350, step = 10 },
    { section = "Quality", key = "PreloadAllTrafficVehiclePools", text = "Preload every traffic car model", kind = "bool", def = 0 },
    -- DLAA works under Valve's Proton 11.0; other Proton 11 builds crash on the first DLAA frame
    -- (docs/dlss5-dlaa.md, "Linux and Proton").
    { group = "DLAA (NVIDIA DLSS anti-aliasing; Proton 11.0 only; F11 turns it off and on)" },
    { section = "DLAA", key = "Enable", text = "DLAA", kind = "bool", def = 0 },
    { section = "DLAA", key = "Preset", text = "Model (L: sharper, twice the GPU time)", kind = "choice",
      values = { "K", "L" }, def = "K" },
    { section = "DLAA", key = "MipBias", text = "Texture sharpening with DLAA (0 if textures shimmer)", kind = "float",
      lo = -3.0, hi = 0.0, fmt = "%.2f", def = -1.0, step = 0.25 },
    { group = "Startup, garage, replays" },
    { section = "Startup", key = "SkipLegalScreen", text = "Skip the legal screen", kind = "bool", def = 1 },
    { section = "Startup", key = "SuppressUbisoftServerLostPrompt", text = "Hide \"Ubisoft server lost\"", kind = "bool", def = 1 },
    { section = "Garage", key = "UpDownSwitchesMaker", text = "Up/Down switch the maker in the garage", kind = "bool", def = 1 },
    { section = "Replay", key = "DisableFilmEffect", text = "No old-film look in replays", kind = "bool", def = 0 },
    { group = "Mods and logging" },
    { section = "Files", key = "Redirect", text = "File redirects for mods (dsf_enhanced\\redirect)", kind = "bool", def = 1 },
    { section = "General", key = "Log", text = "Write dsf_enhanced.log", kind = "bool", def = 1 },
    { section = "General", key = "TrafficDiagnostics", text = "Log frame rate and traffic every 2 s", kind = "bool", def = 0 },
}

M.enhEdits = M.enhEdits or {}

local function enhId(s)
    return s.section .. "." .. s.key
end

-- Splits text into lines (without their line ends); returns the lines and the line end used.
local function splitLines(text)
    local eol = text:find("\r\n", 1, true) and "\r\n" or "\n"
    local lines = {}
    if text:sub(-1) ~= "\n" then
        text = text .. "\n"
    end
    for line in text:gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("\r$", ""))
    end
    return lines, eol
end

-- Wraps a long comment for a tooltip.
local function wrap(text, width)
    local out, len = {}, 0
    for word in text:gmatch("%S+") do
        if len > 0 and len + 1 + #word > width then
            out[#out + 1] = "\n"
            len = 0
        elseif len > 0 then
            out[#out + 1] = " "
            len = len + 1
        end
        out[#out + 1] = word
        len = len + #word
    end
    return table.concat(out)
end

-- Reads the values and the comment above each key.
function M.readEnh()
    local f = io.open(ENH_INI, "rb")
    if f == nil then
        M.enh = { missing = true }
        return false
    end
    local text = f:read("*a")
    f:close()
    local values, desc = {}, {}
    local section, comments = "", {}
    for _, line in ipairs((splitLines(text))) do
        local sec = line:match("^%s*%[(.-)%]")
        local comment = line:match("^%s*;%s?(.*)$")
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if sec then
            section, comments = sec, {}
        elseif comment then
            comments[#comments + 1] = comment
        elseif key then
            values[section .. "." .. key] = value
            if #comments > 0 then
                desc[section .. "." .. key] = wrap(table.concat(comments, " "), 70)
            end
            comments = {}
        else
            comments = {}
        end
    end
    M.enh = { values = values, desc = desc }
    M.enhEdits = {}
    return true
end

-- The value DSF Enhanced will use: an unsaved edit, else the file's, else its default.
local function enhGet(s)
    local id = enhId(s)
    if M.enhEdits[id] ~= nil then
        return M.enhEdits[id]
    end
    local raw = M.enh and M.enh.values and M.enh.values[id]
    if type(s.def) == "string" then
        return (raw and raw ~= "") and raw:upper() or s.def
    end
    local n = raw and tonumber(raw)
    if s.kind == "bool" then
        if n == nil then return s.def ~= 0 end
        return n ~= 0
    end
    return n or s.def
end

local function enhFormat(s, v)
    if type(v) == "string" then
        return v
    elseif s.kind == "bool" then
        return v and "1" or "0"
    elseif s.kind == "float" then
        return string.format(s.fmt or "%.2f", v)
    end
    return string.format("%d", math.floor(v + 0.5))
end

local function enhSet(s, v)
    M.enhEdits[enhId(s)] = v
end

local function enhDirtyCount()
    local n = 0
    for _ in pairs(M.enhEdits) do n = n + 1 end
    return n
end

-- Writes the edited values into dsf_enhanced.ini, keeping every other line as it is. A key the
-- file doesn't have goes at the end of its section (or a new section at the end of the file).
function M.saveEnh()
    local f = io.open(ENH_INI, "rb")
    if f == nil then
        setNote("Can't read " .. ENH_INI)
        return false
    end
    local text = f:read("*a")
    f:close()
    local original = text
    local lines, eol = splitLines(text)

    local pending = {}
    for _, s in ipairs(M.enhSettings) do
        if s.key and M.enhEdits[enhId(s)] ~= nil then
            pending[enhId(s)] = { s = s, value = enhFormat(s, M.enhEdits[enhId(s)]) }
        end
    end

    local section, sectionEnd = "", {}
    for i, line in ipairs(lines) do
        local sec = line:match("^%s*%[(.-)%]")
        if sec then
            section = sec
            sectionEnd[section] = i
        else
            local prefix, key = line:match("^(%s*([%w_]+)%s*=%s*)")
            local p = key and pending[section .. "." .. key]
            if p then
                lines[i] = prefix .. p.value
                pending[section .. "." .. key] = nil
            end
            if line:match("%S") then
                sectionEnd[section] = i
            end
        end
    end

    -- keys the file lacks, inserted from the bottom up so the line numbers stay right
    local inserts, appended = {}, {}
    for _, p in pairs(pending) do
        local at = sectionEnd[p.s.section]
        if at then
            inserts[#inserts + 1] = { at = at, line = p.s.key .. "=" .. p.value }
        else
            appended[p.s.section] = appended[p.s.section] or {}
            table.insert(appended[p.s.section], p.s.key .. "=" .. p.value)
        end
    end
    table.sort(inserts, function(a, b) return a.at > b.at end)
    for _, ins in ipairs(inserts) do
        table.insert(lines, ins.at + 1, ins.line)
    end
    for sec, keys in pairs(appended) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = "[" .. sec .. "]"
        for _, l in ipairs(keys) do lines[#lines + 1] = l end
    end

    local ok, err = writeThroughLink(ENH_INI, original, table.concat(lines, eol) .. eol)
    if not ok then
        setNote("DSF Enhanced settings not saved: " .. err)
        return false
    end
    local count = enhDirtyCount()
    M.readEnh()
    setNote("Saved " .. count .. " DSF Enhanced settings; restart the game to use them")
    return true
end

-------------------------------------------------------------------------------------------
-- Clear wanted level: ends a getaway the way Felony's "fine paid" does, without the fine, and
-- forgets the crimes and the reported car of Felony's crime system. Not during a mission: its
-- getaways belong to the mission.

function M.clearWanted()
    if try(function() return isMissionActive() end) then
        setNote("Clear wanted level: not during a mission")
        return false
    end
    local done = {}
    if try(function() return Getaway.IsAGetawayActive() end) then
        try(function() Getaway.StopAll() end)
        for _, name in ipairs({ "bustedCountdown", "escapeCountdown", "warningCountdown" }) do
            try(function() removeUserUpdateFunction(name) end)
        end
        try(function() garage.enable(true, true) end)
        try(function() feedbackSystem.menusMaster.clearPrimaryTextPrompt() end)
        try(function() feedbackSystem.menusMaster.clearSecondaryTextPrompt() end)
        try(function() feedbackSystem.menusMaster.blockHintButton(false) end)
        try(function() felony_feedback.endFelony() end)
        local fg = rawget(_G, "felony_getaway")
        if type(fg) == "table" then
            fg.ticketPaid, fg.finePrompt, fg.finePaidCallback = false, false, false
            fg.clearAllSearchingCops = true   -- Felony's searching cops give up
            fg.goalCallbacks = {}
        end
        done[#done + 1] = "getaway ended"
    end
    local fr = rawget(_G, "felony_rework")
    if type(fr) == "table" and type(fr.FelonyRework_clearFelonyCrimes) == "function" then
        try(fr.FelonyRework_clearFelonyCrimes)
        if fr.reportedOffenderGameVehicleSet and type(fr.FelonyRework_clearReportedOffenderGameVehicle) == "function" then
            try(fr.FelonyRework_clearReportedOffenderGameVehicle)
        end
        if type(fr.FelonyRework_clearStoredOffenderGameVehicle) == "function" then
            try(fr.FelonyRework_clearStoredOffenderGameVehicle)
        end
        fr.offenderGameVehicleReported = false
        fr.reportInProgress = false
        done[#done + 1] = "crimes and reports forgotten"
    end
    setNote(#done > 0 and ("Wanted level cleared: " .. table.concat(done, ", ")) or "Not wanted")
    return true
end

-------------------------------------------------------------------------------------------
-- Game speed

local function reportedSpeed()
    return try(function() return simulation.getSpeed() end)
end

local function setSpeed(value)
    local ok, err = pcall(function() simulation.setSpeed(value) end)
    if ok then
        M.speed = value
        local now = reportedSpeed()
        setNote(string.format("Game speed %.2f (the game reports %s)", value, tostring(now)))
    else
        setNote("simulation.setSpeed failed: " .. tostring(err))
    end
end

-------------------------------------------------------------------------------------------
-- The player's car

local function playerVehicle()
    local lp = rawget(_G, "localPlayer")
    if lp and lp.currentVehicle then
        return lp.currentVehicle.gameVehicle
    end
    return nil
end

-- The game's garage and pause menu repair the player's car with VEdit.ResetVehicleDamage.
local function repairCar(gv)
    if type(rawget(_G, "VEdit")) == "table" and VEdit.ResetVehicleDamage then
        VEdit.ResetVehicleDamage()
    else
        GameVehicleResource.resetDamage(gv)
    end
end

local function onPlayerVehicle(label, fn)
    local gv = playerVehicle()
    if gv == nil then
        setNote(label .. ": you're not in a car")
        return
    end
    local ok, err = pcall(fn, gv)
    setNote(ok and (label .. ": done") or (label .. " failed: " .. tostring(err)))
end

-------------------------------------------------------------------------------------------
-- Menu contents, called by driverNGHookMenu.lua inside each menu

-- ImGui's Text functions treat their text as a printf format: double any % in text we didn't write
local function esc(text)
    return (tostring(text):gsub("%%", "%%%%"))
end

local function noteLine()
    if M.note ~= "" then
        ImGui.Separator()
        ImGui.TextDisabled(esc(M.note))
    end
end

-- ImGui here is the sol_ImGui binding of DriverNGHook's 2023 build (the one Felony Rework ships).
-- Pointer arguments come back as values, value first: Checkbox -> value, pressed;
-- SliderFloat -> value, used; MenuItem(label, shortcut, selected[, enabled]) -> selected, activated,
-- and its shortcut must be a string. Begin(name, open, flags) -> open, shouldDraw: End is needed
-- whenever open is true; when the window was just closed the binding has already called End.
local function menuItem(label, selected, enabled)
    if selected == nil and enabled == nil then
        return ImGui.MenuItem(label)
    end
    local _, activated = ImGui.MenuItem(label, "", selected == true, enabled ~= false)
    return activated
end

local menus = {}

function menus.File()
    if menuItem("Save Felony settings to its config file", false, felonyInstalled()) then
        M.saveFelony()
    end
    if menuItem("Read Felony settings from its config file", false, felonyInstalled()) then
        M.reloadFelony()
    end
    ImGui.Separator()
    local dirty = enhDirtyCount()
    if menuItem("Save DSF Enhanced settings (" .. dirty .. " changed)", false, dirty > 0) then
        M.saveEnh()
    end
    if menuItem("Read DSF Enhanced settings from dsf_enhanced.ini") then
        M.readEnh()
        setNote(M.enh.missing and (ENH_INI .. " not found") or ("Read " .. ENH_INI))
    end
    noteLine()
end

function menus.View()
    if menuItem("Felony Rework settings", M.showFelony) then
        M.showFelony = not M.showFelony
    end
    if menuItem("DSF Enhanced settings", M.showEnh) then
        M.showEnh = not M.showEnh
    end
    if menuItem("Status overlay (speed, felony, Willpower)", M.showStatus) then
        M.showStatus = not M.showStatus
    end
end

function menus.World()
    ImGui.Text("Game speed")
    local value, changed = ImGui.SliderFloat("##speed", M.speed, 0.05, 1.0, "%.2f")
    if changed then
        setSpeed(value)
    end
    if menuItem("Normal (1.0)") then setSpeed(1.0) end
    if menuItem("Half (0.5)") then setSpeed(0.5) end
    if menuItem("Quarter (0.25)") then setSpeed(0.25) end
    if menuItem("Tenth (0.1)") then setSpeed(0.1) end
    ImGui.TextDisabled(esc("The game reports " .. tostring(reportedSpeed())))
    noteLine()
end

function menus.Game()
    ImGui.Text(esc(felonyStatusText()))
    if menuItem("Clear wanted level") then
        M.clearWanted()
    end
    if menuItem("Felony Rework settings...", M.showFelony, felonyInstalled()) then
        M.showFelony = not M.showFelony
    end
end

function menus.Utilities()
    local gv = playerVehicle()
    local model = gv and try(function() return gv.model_id end)
    ImGui.Text(esc(gv and ("Your car: model " .. tostring(model)) or "Not in a car"))
    if menuItem("Repair car", false, gv ~= nil) then
        onPlayerVehicle("Repair", repairCar)
    end
    if menuItem("Put car back on its wheels", false, gv ~= nil) then
        onPlayerVehicle("Flip upright", function(v) GameVehicleResource.selfRight(v) end)
    end
    noteLine()
end

function M.menu(name)
    local f = menus[name]
    if f then
        local ok, err = pcall(f)
        if not ok then
            ImGui.TextColored(1, 0.4, 0.4, 1, esc("DSF menu error: " .. logError("menu " .. name, err)))
        end
    end
end

-------------------------------------------------------------------------------------------
-- Windows

local function drawFelonyWindow()
    ImGui.SetNextWindowSize(520, 560, ImGuiCond.FirstUseEver)
    local open, draw = ImGui.Begin("Felony Rework settings", true, ImGuiWindowFlags.NoCollapse)
    if not open then
        M.showFelony = false
        return
    end
    if draw then
        local ok, err = pcall(function()
            if not felonyInstalled() then
                ImGui.TextWrapped("Felony Rework isn't loaded.")
                return
            end
            ImGui.TextWrapped("Changes apply at once unless marked. Save writes them to "
                .. "felonyreworkconfig.txt so they stay after a restart.")
            if ImGui.Button("Save") then M.saveFelony() end
            ImGui.SameLine()
            if ImGui.Button("Read from file") then M.reloadFelony() end
            ImGui.SameLine()
            ImGui.TextDisabled(M.felonyDirty and "unsaved changes" or "saved")

            for _, s in ipairs(M.felonySettings) do
                if s.group then
                    ImGui.Separator()
                    ImGui.TextColored(0.95, 0.75, 0.35, 1.0, s.group)
                else
                    local value = felonyGet(s.key)
                    -- a setting newer than the config the game loaded at startup: its default
                    if value == nil and s.def ~= nil then
                        value = s.def
                    end
                    if type(value) == "boolean" then
                        local v, pressed = ImGui.Checkbox(s.text .. "##" .. s.key, value)
                        if pressed then
                            felonySet(s.key, v)
                        end
                        if WHEN_TEXT[s.when] then
                            ImGui.SameLine()
                            ImGui.TextDisabled("(" .. WHEN_TEXT[s.when] .. ")")
                        end
                    else
                        ImGui.TextDisabled(s.text .. ": not set")
                    end
                end
            end
            if M.note ~= "" then
                ImGui.Separator()
                ImGui.TextDisabled(esc(M.note))
            end
        end)
        if not ok then
            ImGui.TextWrapped(esc("Error: " .. logError("settings window", err)))
        end
    end
    ImGui.End()
end

local function tooltip(id)
    local d = M.enh and M.enh.desc and M.enh.desc[id]
    if d and ImGui.IsItemHovered() then
        ImGui.SetTooltip(esc(d))
    end
end

local function drawEnhSetting(s)
    local id = enhId(s)
    local v = enhGet(s)
    local label = s.text .. "##" .. id
    if s.kind == "bool" then
        local nv, pressed = ImGui.Checkbox(label, v)
        if pressed then enhSet(s, nv) end
        tooltip(id)
    elseif s.kind == "int" then
        local nv, used = ImGui.SliderInt(label, math.floor(v + 0.5), s.lo, s.hi)
        if used then enhSet(s, nv) end
        tooltip(id)
    elseif s.kind == "float" then
        local nv, used = ImGui.SliderFloat(label, v, s.lo, s.hi, s.fmt or "%.2f")
        if used then enhSet(s, nv) end
        tooltip(id)
    elseif s.kind == "choice" then
        ImGui.Text(esc(s.text))
        tooltip(id)
        for _, opt in ipairs(s.values) do
            ImGui.SameLine()
            local name = (s.labels and s.labels[opt]) or tostring(opt)
            if ImGui.RadioButton(name .. "##" .. id .. opt, v == opt) then
                enhSet(s, opt)
            end
        end
    end
    if M.enhEdits[id] ~= nil then
        ImGui.SameLine()
        ImGui.TextColored(0.95, 0.75, 0.35, 1.0, "changed")
    end
end

local function drawEnhWindow()
    if M.enh == nil then
        M.readEnh()
    end
    ImGui.SetNextWindowSize(560, 620, ImGuiCond.FirstUseEver)
    local open, draw = ImGui.Begin("DSF Enhanced settings", true, ImGuiWindowFlags.NoCollapse)
    if not open then
        M.showEnh = false
        return
    end
    if draw then
        local ok, err = pcall(function()
            if M.enh.missing then
                ImGui.TextWrapped("dsf_enhanced.ini isn't in the game folder, so DSF Enhanced isn't installed "
                    .. "or uses its built-in values.")
                return
            end
            ImGui.TextWrapped("DSF Enhanced reads dsf_enhanced.ini when the game starts: save, then restart the "
                .. "game. Hover over a setting for its description.")
            local dirty = enhDirtyCount()
            if ImGui.Button("Save") then M.saveEnh() end
            ImGui.SameLine()
            if ImGui.Button("Undo changes") then
                M.readEnh()
                setNote("DSF Enhanced settings read from " .. ENH_INI)
            end
            ImGui.SameLine()
            ImGui.TextDisabled(dirty > 0 and (dirty .. " unsaved") or "saved")

            local shown = true
            for _, s in ipairs(M.enhSettings) do
                if s.group then
                    shown = ImGui.CollapsingHeader(s.group, ImGuiTreeNodeFlags.DefaultOpen)
                elseif shown then
                    drawEnhSetting(s)
                end
            end
            if M.note ~= "" then
                ImGui.Separator()
                ImGui.TextDisabled(esc(M.note))
            end
        end)
        if not ok then
            ImGui.TextWrapped(esc("Error: " .. logError("DSF Enhanced window", err)))
        end
    end
    ImGui.End()
end

local function drawStatusWindow()
    ImGui.SetNextWindowPos(10, 40, ImGuiCond.FirstUseEver)
    local flags = ImGuiWindowFlags.NoCollapse + ImGuiWindowFlags.AlwaysAutoResize
    local open, draw = ImGui.Begin("DSF status", true, flags)
    if not open then
        M.showStatus = false
        return
    end
    if draw then
        local ok, err = pcall(function()
            ImGui.Text(esc("Game speed " .. tostring(reportedSpeed())))
            ImGui.Text(esc(felonyStatusText()))
            ImGui.Text(esc("Willpower " .. tostring(willpower())))
        end)
        if not ok then
            ImGui.Text(esc("Error: " .. logError("status window", err)))
        end
    end
    ImGui.End()
end

-------------------------------------------------------------------------------------------
-- Reload this file when it changes

local SELF = "dsfmenu.lua"
local TRAINER = "dsfmenu_trainer.lua"   -- loaded by this file, so a change to either reloads both
local function modifyTimes()
    local a = try(function() return file.getmodifytime(userPath(SELF)) end)
    local b = try(function() return file.getmodifytime(userPath(TRAINER)) end)
    return tostring(a) .. "|" .. tostring(b)
end
if M.selfTime == nil then
    M.selfTime = modifyTimes()
end
local frames = 0

local function checkReload()
    frames = frames + 1
    if frames < 120 then
        return
    end
    frames = 0
    local t = modifyTimes()
    if t ~= M.selfTime then
        M.selfTime = t
        log("reloading " .. SELF)
        user_open(SELF)
    end
end

-------------------------------------------------------------------------------------------
-- Controller menu: hold D-pad up while driving (it does nothing else in free roam). The game
-- pauses, and the menu takes the pad through a control state of its own, so A doesn't Shift and
-- B doesn't brake. D-pad: move and change; A: select; B: back (closes on the first page);
-- X: save; LB/RB: a page up/down; Start: close.

local PAD_STATE = "dsfMenuPad"
local OPEN_HOLD_FRAMES = 30  -- frames D-pad up is held to open (about a third of a second; frames,
                             -- not g_NetworkTime: Shift slows the game's clock down)
local ROWS = 16              -- rows shown at once
local DEDUPE_FRAMES = 6      -- a press seen both as a callback and by polling counts once
local IDLE_FRAMES = 60 * 120 -- closes itself (and resumes the game) after this long untouched

-- action -> what it does in the menu
local PAD_KEYS = {
    Menu_Up = "up", Menu_Down = "down", Menu_Left = "left", Menu_Right = "right",
    Menu_Select = "select", Menu_Cancel = "back", Menu_Back = "back", Menu_ExtraFirst = "save",
    Menu_Shoulder_L1 = "pageup", Menu_Shoulder_R1 = "pagedown", Menu_Start = "close",
}

M.pad = M.pad or { open = false, page = "main", sel = {}, top = {}, last = {}, fired = {} }
local P = M.pad
-- "hud": drawn in the game's HUD (as Snoopii's Mod Menu does): five rows in the helicopter text
-- panel, the description on the secondary prompt line; "hud3": three rows, the page and the
-- description on the panel's last two lines; "window": an ImGui window.
-- The choice is kept in HDD:DSFMenu\menu_style.txt (Documents\Ubisoft\Driver San Francisco).
local STYLE_FILE = "HDD:DSFMenu\\menu_style.txt"
local STYLES = { hud = "HUD", hud3 = "HUD, 3 rows", window = "Window" }
local STYLE_NEXT = { hud = "hud3", hud3 = "window", window = "hud" }
if M.padStyle ~= nil and not STYLES[M.padStyle] then
    M.padStyle = "hud"   -- a style that's gone (hud8: the controls panel shows one line, bottom left)
    pcall(function()
        feedbackSystem.menusMaster.masterSetVariable("iControls_Display", 0)
        for line = 1, 8 do
            feedbackSystem.menusMaster.masterSetTextVariable("controls_string_line_" .. line, "")
        end
    end)
end
if M.padStyle == nil then
    M.padStyle = "hud"
    pcall(function()
        local f = io.open(STYLE_FILE, "rb")
        if f then
            local saved = (f:read("*a") or ""):match("%a+%d*")
            f:close()
            if saved and STYLES[saved] then M.padStyle = saved end   -- hud8 (gone) stays hud
        end
    end)
end

-- The game's own menu sounds.
local function sound(name)
    pcall(function() OneShotSound.Play(name, false) end)
end
P.frame = P.frame or 0

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function onOff(v)
    return v and "On" or "Off"
end

local function padDown(action)
    local ok, state = pcall(controlHandler.getStatus, controlHandler, action)
    return ok and state ~= nil and state ~= "NotPressed" and state ~= "JustReleased"
end

local function gamePaused()
    local gs = rawget(_G, "gameStatus")
    return type(gs) == "table" and gs.simulationPaused == true
end

-- Rows of a page: { text, value, act = function(dir) } with dir -1/+1 (left/right) or 0 (A);
-- { header = text } rows are titles the selection skips; { page = name } rows open a page.
local pages = {}

-- Runs fn once the menu has closed and the game runs again (a paused car isn't repaired or
-- moved, and a speed set while paused doesn't stick).
local function later(fn)
    P.after = P.after or {}
    P.after[#P.after + 1] = fn
    M.closePad()
end

-- Rows the trainer's pages share with this file. Trainer rows (dsfmenu_trainer.lua, at its top):
-- get/set (on/off), value/step/run (a value), run/closes (an action), desc (a line about the row).
local function speedRow()
    return { text = "Game speed", padOnly = true, desc = "Set when the menu closes; A puts it back to 1.0",
        value = function() return string.format("%.2f", P.speedTarget or M.speed) end,
        step = function(d)
            local speed = P.speedTarget or M.speed
            P.speedTarget = clamp(math.floor((speed + 0.05 * d) * 20 + 0.5) / 20, 0.05, 1.0)
        end,
        run = function() P.speedTarget = 1.0 end }
end

local function repairRow()
    return { text = "Repair car", desc = "Repairs it as the garage does", closes = true,
        run = function() onPlayerVehicle("Repair", repairCar) end }
end

local function flipRow()
    return { text = "Put car back on its wheels", closes = true,
        run = function() onPlayerVehicle("Flip upright", function(v) GameVehicleResource.selfRight(v) end) end }
end

local function clearWantedRow()
    return { text = "Clear wanted level", desc = "Ends the getaway without a fine; forgets Felony's crimes and reports",
        closes = true, run = function() M.clearWanted() end }
end

-- A trainer row as the controller menu's: { text, value = string, act = function(dir) }.
local function padRow(r)
    if r.header or r.page or r.act then
        return r
    end
    local row = { text = r.text, jump = r.jump, desc = r.desc }
    if r.closes then
        row.desc = (r.desc and (r.desc .. "; ") or "") .. "closes the menu"
    end
    local function run()
        if r.closes then
            later(r.run)
        else
            r.run()
        end
    end
    if r.get then
        row.kind = "toggle"
        row.value = onOff(r.get())
        row.act = function() r.set(not r.get()) end
    elseif r.step then
        row.kind = "value"
        row.value = r.value()
        row.act = function(d)
            if d ~= 0 then
                r.step(d)
            elseif r.run then
                run()
            end
        end
    elseif r.run then
        row.act = function(d) if d == 0 then run() end end
    end
    return row
end

-- The first page: the trainer's categories (dsfmenu_trainer.lua), then the settings.
function pages.main()
    local rows = {}
    local T = rawget(_G, "DSFTrainer")
    if type(T) == "table" and T.order then
        for _, key in ipairs(T.order) do
            rows[#rows + 1] = { text = T.titles[key], page = key, desc = T.descs[key] }
        end
    else
        rows[#rows + 1] = { header = "The trainer (dsfmenu_trainer.lua) isn't loaded" }
    end
    rows[#rows + 1] = { header = "Settings" }
    rows[#rows + 1] = { text = "Menu style", value = STYLES[M.padStyle] or M.padStyle,
        desc = "A switches: HUD 5 rows, HUD 3 rows, overlay window (kept for next time)",
        act = function(d)
            if d ~= 0 then return end
            M.hideHudPanel()
            M.padStyle = STYLE_NEXT[M.padStyle] or "hud"
            pcall(function()
                local f = io.open(STYLE_FILE, "wb")
                if f then f:write(M.padStyle); f:close() end
            end)
        end }
    rows[#rows + 1] = { text = "Status overlay", value = onOff(M.showStatus), desc = "Game speed, felony and Willpower",
        act = function() M.showStatus = not M.showStatus end }
    if felonyInstalled() then
        rows[#rows + 1] = { text = "Felony Rework settings", page = "felony" }
    end
    rows[#rows + 1] = { text = "DSF Enhanced settings", page = "enh" }
    rows[#rows + 1] = { text = "Close", act = function(d) if d == 0 then M.closePad() end end }
    rows[#rows + 1] = { header = felonyStatusText() .. "   Willpower " .. tostring(willpower()) }
    return "DSF menu", rows
end

function pages.felony()
    local rows = {}
    rows[#rows + 1] = { text = "Save (X)", value = M.felonyDirty and "unsaved changes" or "saved",
        act = function(d) if d == 0 then M.saveFelony() end end }
    for _, s in ipairs(M.felonySettings) do
        if s.group then
            rows[#rows + 1] = { header = s.group }
        else
            local v = felonyGet(s.key)
            if v == nil then v = s.def end
            if type(v) == "boolean" then
                local value = onOff(v) .. (WHEN_TEXT[s.when] and ("  (" .. WHEN_TEXT[s.when] .. ")") or "")
                rows[#rows + 1] = { text = s.text, value = value, act = function()
                    felonySet(s.key, not v)
                end }
            end
        end
    end
    rows[#rows + 1] = { text = "Back", act = function(d) if d == 0 then P.page = "main" end end }
    return "Felony Rework", rows
end

local function enhValueText(s, v)
    if s.kind == "bool" then
        return onOff(v)
    elseif s.kind == "choice" then
        return (s.labels and s.labels[v]) or tostring(v)
    end
    return enhFormat(s, v)
end

local function enhStep(s, d)
    local v = enhGet(s)
    if s.kind == "bool" then
        enhSet(s, not v)
    elseif s.kind == "choice" then
        local at = 1
        for i, opt in ipairs(s.values) do
            if opt == v then at = i end
        end
        at = at + (d == 0 and 1 or d)
        if at < 1 then at = #s.values elseif at > #s.values then at = 1 end
        enhSet(s, s.values[at])
    elseif d ~= 0 then
        local step = s.step or ((s.hi - s.lo) / 20)
        local nv = clamp(v + step * d, s.lo, s.hi)
        if s.kind == "int" then
            nv = math.floor(nv + 0.5)
        else
            nv = math.floor(nv / step + 0.5) * step
        end
        enhSet(s, nv)
    end
end

function pages.enh()
    if M.enh == nil then
        M.readEnh()
    end
    local rows = {}
    if M.enh.missing then
        rows[#rows + 1] = { header = "dsf_enhanced.ini isn't in the game folder" }
    else
        local dirty = enhDirtyCount()
        rows[#rows + 1] = { text = "Save (X), used after a restart", value = dirty > 0 and (dirty .. " unsaved") or "saved",
            act = function(d) if d == 0 then M.saveEnh() end end }
        rows[#rows + 1] = { text = "Undo changes", act = function(d)
            if d == 0 then M.readEnh(); setNote("DSF Enhanced settings read from " .. ENH_INI) end
        end }
        for _, s in ipairs(M.enhSettings) do
            if s.group then
                rows[#rows + 1] = { header = s.group }
            else
                local mark = M.enhEdits[enhId(s)] ~= nil and " *" or ""
                rows[#rows + 1] = { text = s.text, value = enhValueText(s, enhGet(s)) .. mark,
                    act = function(d) enhStep(s, d) end }
            end
        end
    end
    rows[#rows + 1] = { text = "Back", act = function(d) if d == 0 then P.page = "main" end end }
    return "DSF Enhanced (restart to apply)", rows
end

local function pageRows()
    local f = pages[P.page]
    if f then
        return f()
    end
    local T = rawget(_G, "DSFTrainer")
    if type(T) == "table" and T.pages and T.pages[P.page] then
        local rows = {}
        for _, r in ipairs(T.pages[P.page]()) do
            rows[#rows + 1] = padRow(r)
        end
        rows[#rows + 1] = { text = "Back", act = function(d) if d == 0 then P.page = "main" end end }
        return T.titles[P.page] or P.page, rows
    end
    P.page = "main"
    return pages.main()
end

-- the nearest selectable row from i in direction dir (wrapping)
local function selectable(rows, i, dir)
    local n = #rows
    for _ = 1, n do
        if i < 1 then i = n elseif i > n then i = 1 end
        if not rows[i].header then return i end
        i = i + dir
    end
    return 1
end

function M.padInput(key)
    if not P.open then return end
    if P.fired[key] and P.frame - P.fired[key] < DEDUPE_FRAMES then return end
    P.fired[key] = P.frame
    P.idle = 0
    local ok, err = pcall(function()
        local _, rows = pageRows()
        local sel = selectable(rows, P.sel[P.page] or 1, 1)
        local row = rows[sel]
        if key == "up" or key == "down" then
            sel = selectable(rows, sel + (key == "up" and -1 or 1), key == "up" and -1 or 1)
            sound("Menu_Move")
        elseif key == "pageup" or key == "pagedown" then
            local dir = key == "pageup" and -1 or 1
            if row.jump and row.act and row.value then
                row.act(dir * row.jump)   -- a long list: LB/RB jump through it
            else
                sel = selectable(rows, clamp(sel + dir * (ROWS - 2), 1, #rows), dir)
            end
        elseif key == "left" or key == "right" then
            if row.act and row.value then
                row.act(key == "left" and -1 or 1)
                sound("Menu_Move")
            end
        elseif key == "select" then
            if row.page then
                P.sel[P.page] = sel
                P.page = row.page
                sound("Menu_Select")
                return
            elseif row.act then
                sound("Menu_Select")
                row.act(0)
            end
        elseif key == "save" then
            if P.page == "felony" then M.saveFelony() elseif P.page == "enh" then M.saveEnh() end
        elseif key == "back" then
            if P.page == "main" then M.closePad() else P.page = "main"; sound("Menu_Back") end
            return
        elseif key == "close" then
            M.closePad()
            return
        end
        P.sel[P.page] = sel
    end)
    if not ok then
        setNote("Controller menu: " .. logError("controller menu " .. key, err))
    end
end

local function bindings()
    local b = {}
    for action, key in pairs(PAD_KEYS) do
        b[action] = { JustPressed = { [1] = function() DSFMenu.padInput(key) end } }
    end
    return b
end

function M.openPad()
    if P.open then return end
    P.open, P.page, P.idle = true, "main", 0
    P.last = {}
    P.speedTarget = nil
    P.speedBefore = reportedSpeed()
    if type(P.speedBefore) == "number" then
        M.speed = P.speedBefore
    end
    for action in pairs(PAD_KEYS) do
        P.last[action] = padDown(action)   -- a button already held doesn't count as a press
    end
    P.state = pcall(function()
        controlHandler:registerState(localPlayer.localID, PAD_STATE, bindings())
        controlHandler:setState(PAD_STATE)
    end)
    P.paused, P.frozen, P.hud = false, false, M.padStyle == "hud" or M.padStyle == "hud3"
    P.hudNoteSerial, P.hudNoteFrame = M.noteSerial, nil   -- the HUD shows only notes from now on
    if P.hud then
        -- as Snoopii's menu does: game speed 0 and the sound paused, so the HUD keeps drawing
        P.frozen = pcall(function()
            simulation.setSpeed(0)
            Sound.SimulationPause()
        end)
        P.hideUIWas = try(function() return Menu.HideUI end)
        try(function()
            Menu.HideUI = 0
            Menu.ShowMaster = 1
        end)
    elseif not gamePaused() then
        P.paused = pcall(function() simulation.pause() end)
    end
    P.zapInputOff = false
    if localPlayer.inZap then
        P.zapInputOff = pcall(function() zapcontroller.EnableZapInput(false) end)
    end
    sound("Menu_Select")
    log("controller menu open (" .. M.padStyle .. ", control state " .. tostring(P.state) .. ", paused "
        .. tostring(P.paused) .. ", frozen " .. tostring(P.frozen) .. ")")
end

function M.closePad()
    if not P.open then return end
    P.open = false
    if P.state then
        try(function()
            controlHandler:resetState(PAD_STATE)
            controlHandler:removeState(PAD_STATE, localPlayer.localID)
        end)
        P.state = false
    end
    if P.paused then
        try(function() simulation.start() end)
        P.paused = false
    end
    if P.frozen then
        try(function() Sound.SimulationResume() end)
        P.frozen = false
    end
    if P.hud then
        M.hideHudPanel()
        if P.hideUIWas ~= nil then
            local was = P.hideUIWas
            try(function() Menu.HideUI = was end)
        end
        P.hud = false
    end
    if P.zapInputOff then
        try(function() zapcontroller.EnableZapInput(true) end)
        P.zapInputOff = false
    end
    sound("HUD_EB_Photo_In")
    -- the game speed: the one picked in the menu, else the one from before. Set now and again a
    -- couple of frames later, in case resuming puts the speed from before the pause back.
    local target = P.speedTarget or P.speedBefore
    P.after = P.after or {}
    if type(target) == "number" then
        local function applySpeed(final)
            local now = reportedSpeed()
            if type(now) ~= "number" or math.abs(now - target) > 0.001 then
                try(function() simulation.setSpeed(target) end)
            end
            M.speed = target
            if final and P.speedTarget then
                setNote(string.format("Game speed %.2f (the game reports %s)", target, tostring(reportedSpeed())))
            end
        end
        applySpeed(false)
        table.insert(P.after, 1, function() applySpeed(true) end)
    end
    P.afterFrame = P.frame + 2
    log("controller menu closed")
end

local function runAfterClose()
    if P.after and #P.after > 0 and P.frame >= (P.afterFrame or 0) then
        local tasks = P.after
        P.after = {}
        for _, task in ipairs(tasks) do
            local ok, err = pcall(task)
            if not ok then
                setNote("Failed: " .. logError("after the controller menu", err))
            end
        end
        P.speedTarget = nil
    end
end

-- polling: D-pad up held opens the menu; while it's open, presses the callbacks may miss
local function pollPad()
    P.frame = P.frame + 1
    if type(rawget(_G, "controlHandler")) ~= "table" then return end
    if not P.open then
        runAfterClose()
        -- D-pad up reports as DPad_Up while driving; in other control states (Shift) it may only
        -- report as Menu_Up, so either one counts
        local up = padDown("DPad_Up") or padDown("Menu_Up")
        local lp = rawget(_G, "localPlayer")
        if type(lp) == "table" and lp.inZap then
            -- diagnostic: which up actions report in Shift, once per press
            local pressed = up or padDown("Zap_Up")
            if pressed and not P.shiftLogged then
                P.shiftLogged = true
                log(string.format("Shift: DPad_Up %s, Menu_Up %s, Zap_Up %s, paused %s", tostring(padDown("DPad_Up")),
                    tostring(padDown("Menu_Up")), tostring(padDown("Zap_Up")), tostring(gamePaused())))
            elseif not pressed then
                P.shiftLogged = false
            end
        end
        if up and not gamePaused() and lp then
            P.holdFrames = (P.holdFrames or 0) + 1
            if P.holdFrames >= OPEN_HOLD_FRAMES then
                P.holdFrames = nil
                M.openPad()
            end
        else
            P.holdFrames = nil
        end
        return
    end
    P.idle = (P.idle or 0) + 1
    if P.idle > IDLE_FRAMES then
        setNote("Controller menu closed after two minutes untouched")
        M.closePad()
        return
    end
    for action, key in pairs(PAD_KEYS) do
        local down = padDown(action)
        if down and not P.last[action] then
            M.padInput(key)
        end
        P.last[action] = down
    end
end

local function drawPadMenu()
    local okRows, title, rows = pcall(pageRows)
    if not okRows then
        setNote("Controller menu: " .. logError("controller menu page " .. tostring(P.page), title))
        P.page = "main"
        title, rows = pages.main()
    end
    local sel = selectable(rows, P.sel[P.page] or 1, 1)
    P.sel[P.page] = sel
    local top = P.top[P.page] or 1
    if sel < top then top = sel elseif sel >= top + ROWS then top = sel - ROWS + 1 end
    top = clamp(top, 1, math.max(1, #rows - ROWS + 1))
    P.top[P.page] = top

    ImGui.SetNextWindowPos(80, 80, ImGuiCond.FirstUseEver)
    local flags = ImGuiWindowFlags.NoCollapse + ImGuiWindowFlags.AlwaysAutoResize
    local open, draw = ImGui.Begin("DSF menu (controller)", true, flags)
    if not open then
        M.closePad()
        return
    end
    if draw then
        local ok, err = pcall(function()
            ImGui.TextColored(0.95, 0.75, 0.35, 1.0, esc(title))
            ImGui.Separator()
            ImGui.TextDisabled(top > 1 and "  ..." or " ")
            for i = top, math.min(#rows, top + ROWS - 1) do
                local r = rows[i]
                if r.header then
                    ImGui.TextColored(0.95, 0.75, 0.35, 1.0, esc(r.header))
                else
                    local line = (i == sel and "> " or "  ") .. r.text .. (r.page and "  >" or "")
                        .. (r.value and ("   [" .. r.value .. "]") or "")
                    if i == sel then
                        ImGui.TextColored(1.0, 1.0, 0.4, 1.0, esc(line))
                    else
                        ImGui.Text(esc(line))
                    end
                end
            end
            ImGui.TextDisabled(top + ROWS - 1 < #rows and "  ..." or " ")
            ImGui.Separator()
            local desc = rows[sel] and rows[sel].desc
            ImGui.TextColored(0.75, 0.85, 1.0, 1.0, esc(desc or " "))
            ImGui.TextDisabled("D-pad: move, change   A: select   B: back   X: save   LB/RB: page   Start: close")
            if M.note ~= "" then
                ImGui.TextDisabled(esc(M.note))
            end
        end)
        if not ok then
            ImGui.Text(esc("Error: " .. logError("controller menu", err)))
        end
    end
    ImGui.End()
end

-------------------------------------------------------------------------------------------

-------------------------------------------------------------------------------------------
-- The controller menu in the game's HUD: the helicopter text panel's five lines. Lines 1-3 show
-- the page three rows at a time, the selected one in [ ]; line 4 the page and position, or a new
-- note for a few seconds; line 5 the selected row's description, scrolling when it's long.

-- The helicopter text panel has five lines. hud: five rows, the description (or a new note) on the
-- secondary prompt line; hud3: three rows, then the page or a note, then the description.
local HUD_LAYOUTS = {
    hud = { panel = "iHelicopter_Text", line = "helicopter_line_", lines = 5, rows = 5, prompt = true },
    hud3 = { panel = "iHelicopter_Text", line = "helicopter_line_", lines = 5, rows = 3 },
}
local HUD_WIDTH = 49
local PROMPT_WIDTH = 72

-- The prompt's display switch is set only when it changes: setting it may replay its animation.
local promptShown = nil
local function promptSet(text)
    local mm = feedbackSystem.menusMaster
    mm.masterSetTextVariable("prompt_secondary_button", "")
    mm.masterSetTextVariable("prompt_secondary", (tostring(text):gsub("%%", "")))
    local show = text ~= "" and 1 or 0
    if show ~= promptShown then
        mm.masterSetVariable("iPrompt_Secondary_Display", show)
        promptShown = show
    end
end

local function hudSet(layout, line, text)
    -- % would start an icon code in the HUD's text
    feedbackSystem.menusMaster.masterSetTextVariable(layout.line .. line, (tostring(text):gsub("%%", "")))
end

function M.hideHudPanel()
    pcall(function()
        for line = 1, 5 do
            hudSet(HUD_LAYOUTS.hud, line, "")
        end
        feedbackSystem.menusMaster.masterSetVariable("iHelicopter_Text", 0)
    end)
    pcall(promptSet, "")
end

local function hudRowText(r)
    if r.header then
        return "-  " .. r.header .. "  -"
    end
    local text = r.text
    if r.value then
        text = text .. (r.kind == "value" and (":  < " .. r.value .. " >") or (":  " .. r.value))
    end
    if r.page then
        text = text .. "  [>]"
    end
    return text
end

local function drawPadHud()
    local okRows, title, rows = pcall(pageRows)
    if not okRows then
        setNote("Controller menu: " .. logError("controller menu page " .. tostring(P.page), title))
        P.page = "main"
        title, rows = pages.main()
    end
    local layout = HUD_LAYOUTS[M.padStyle] or HUD_LAYOUTS.hud
    local hudRows = layout.rows
    local sel = selectable(rows, P.sel[P.page] or 1, 1)
    P.sel[P.page] = sel
    local top = math.floor((sel - 1) / hudRows) * hudRows + 1

    local ok, err = pcall(function()
        feedbackSystem.menusMaster.masterSetVariable(layout.panel, 1)
        for i = 0, hudRows - 1 do
            local r = rows[top + i]
            local text = r and hudRowText(r) or ""
            if r and top + i == sel then
                text = "[  " .. text .. "  ]"
            end
            hudSet(layout, i + 1, text)
        end
        -- line 4: a new note for about three seconds, else the page and position
        if M.noteSerial ~= P.hudNoteSerial then
            P.hudNoteSerial, P.hudNoteFrame = M.noteSerial, P.frame
        end
        local count, at = 0, 0
        for i, r in ipairs(rows) do
            if not r.header then
                count = count + 1
                if i == sel then at = count end
            end
        end
        local fresh = M.note ~= "" and P.hudNoteFrame and P.frame - P.hudNoteFrame < 180
        local status = fresh and M.note or (title .. "   " .. at .. "/" .. count)
        if not layout.prompt then
            hudSet(layout, hudRows + 1, status)
        end
        -- line 5: the description, scrolled when it's longer than the panel
        local desc = rows[sel] and rows[sel].desc or ""
        if P.hudDescRow ~= tostring(P.page) .. sel then
            P.hudDescRow, P.hudDescFrame = tostring(P.page) .. sel, P.frame
        end
        if layout.prompt then
            -- one line: a new note, else the page and the description
            desc = fresh and M.note or (title .. "  " .. at .. "/" .. count .. (desc ~= "" and ("  -  " .. desc) or ""))
        end
        local width = layout.prompt and PROMPT_WIDTH or HUD_WIDTH
        if #desc > width then
            local loop = #desc - width + 1
            local tick = math.floor((P.frame - P.hudDescFrame) / 8)
            local cycle = loop + 24   -- a pause at each end
            local pos = tick % cycle - 12
            pos = math.max(0, math.min(loop - 1, pos))
            desc = desc:sub(pos + 1, pos + width)
        end
        if layout.prompt then
            promptSet(desc)
        else
            hudSet(layout, hudRows + 2, desc)
        end
    end)
    if not ok then
        logError("controller menu HUD", err)
    end
end

-------------------------------------------------------------------------------------------
-- F2 -> Trainer: the trainer's pages as submenus (rows as in dsfmenu_trainer.lua).

local function runRow(r)
    local ok, err = pcall(r.run)
    if not ok then
        setNote(r.text .. " failed: " .. logError("trainer " .. r.text, err))
    end
end

local function drawTrainerRow(r, id)
    if r.header then
        ImGui.Separator()
        ImGui.TextDisabled(esc(r.header))
        return
    elseif r.padOnly then
        return
    elseif r.get then
        local on = r.get() == true
        if menuItem(r.text .. "##" .. id, on) then
            r.set(not on)
        end
    elseif r.step then
        ImGui.Text(esc(r.text .. ": " .. tostring(r.value())))
        ImGui.SameLine()
        if ImGui.Button("<##" .. id) then r.step(-1) end
        ImGui.SameLine()
        if ImGui.Button(">##" .. id) then r.step(1) end
        if r.jump then
            ImGui.SameLine()
            if ImGui.Button("<<##" .. id) then r.step(-r.jump) end
            ImGui.SameLine()
            if ImGui.Button(">>##" .. id) then r.step(r.jump) end
        end
        if r.run then
            ImGui.SameLine()
            if ImGui.Button("Apply##" .. id) then runRow(r) end
        end
    elseif r.run then
        if menuItem(r.text .. "##" .. id) then
            runRow(r)
        end
    end
    if r.desc and ImGui.IsItemHovered() then
        ImGui.SetTooltip(esc(r.desc))
    end
end

function menus.Trainer()
    local T = rawget(_G, "DSFTrainer")
    if type(T) ~= "table" or not T.order then
        ImGui.TextDisabled("The trainer (dsfmenu_trainer.lua) isn't loaded")
        return
    end
    for _, key in ipairs(T.order) do
        if ImGui.BeginMenu(T.titles[key]) then
            local ok, err = pcall(function()
                for i, r in ipairs(T.pages[key]()) do
                    drawTrainerRow(r, key .. i)
                end
            end)
            if not ok then
                ImGui.TextColored(1, 0.4, 0.4, 1, esc("Error: " .. logError("trainer " .. key, err)))
            end
            ImGui.EndMenu()
        end
    end
    noteLine()
end

-- What dsfmenu_trainer.lua gets from this file.
M.api = {
    try = try, log = log, setNote = setNote, playerVehicle = playerVehicle, onPlayerVehicle = onPlayerVehicle,
    reportedSpeed = reportedSpeed, gamePaused = gamePaused, padDown = padDown,
    padOpen = function() return P.open end,
    speedRow = speedRow, repairRow = repairRow, flipRow = flipRow, clearWantedRow = clearWantedRow,
}

-------------------------------------------------------------------------------------------

local function update()
    checkReload()
    checkWillpower()
    local T = rawget(_G, "DSFTrainer")
    if type(T) == "table" and T.step then
        local okT, errT = pcall(T.step)
        if not okT then
            logError("trainer", errT)
        end
    end
    local ok, err = pcall(pollPad)
    if not ok then
        logError("controller menu input", err)
    end
    if P.open then
        if HUD_LAYOUTS[M.padStyle] then
            drawPadHud()
        else
            drawPadMenu()
        end
    end
    if M.showFelony then
        drawFelonyWindow()
    end
    if M.showEnh then
        drawEnhWindow()
    end
    if M.showStatus then
        drawStatusWindow()
    end
    -- true blocks game input and shows the mouse cursor while a settings window is open
    return M.showFelony or M.showEnh
end

-- Overwrites the entry on a reload. No remove first: a reload runs inside DriverNGHook's loop over
-- these entries, and Lua allows changing an existing key there but not adding a removed one back.
ImGui_AddUpdateFunction("DSFMenu", update, true)
log("loaded")
local okTrainer, errTrainer = pcall(user_open, TRAINER)
if not okTrainer then
    logError("loading " .. TRAINER, errTrainer)
end
