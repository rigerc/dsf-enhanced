-- The DSF menu's offline tests (run.sh runs them). Stock Lua 5.1 loads dsfmenu.lua and
-- dsfmenu_trainer.lua with stand-ins for what they use in the game: DriverNGHook's ImGui binding
-- (sol_ImGui, 2023 build, as strict about argument types and counts), the controller
-- (controlHandler), the game's file system (HDD: writable, the game folder read only) and the game
-- systems the trainer calls. Then it drives the F2 menus, the settings windows and the controller
-- menu in both its window and HUD styles, and checks what they draw and call.
-- arg[1] = dsfmenu.lua, arg[2] = the UserLuaScripts folder, arg[3] = the HDD: folder; the current
-- folder is the game folder (dsf_enhanced.ini).
local script, userdir = arg[1], arg[2]
local depth, calls, clicks = 0, {}, {}
local function rec(s) calls[#calls + 1] = s end

ImGuiCond = { FirstUseEver = 4, Always = 1 }
ImGuiWindowFlags = { NoCollapse = 32, AlwaysAutoResize = 64 }
ImGuiTreeNodeFlags = { DefaultOpen = 32 }
-- Strict like DriverNGHook 2023's sol_ImGui: exact types and counts, value-first returns
local function sig(name, n, ...)
    local want = { ... }
    return function(...)
        local got = select("#", ...)
        local ok = false
        for _, types in ipairs(want) do
            if #types == got then
                ok = true
                for i, t in ipairs(types) do
                    if type((select(i, ...))) ~= t then ok = false end
                end
                if ok then break end
            end
        end
        if not ok then
            local ts = {}
            for i = 1, got do ts[i] = type((select(i, ...))) end
            error("sol: no matching function call takes this number of arguments and the specified types ("
                .. name .. "(" .. table.concat(ts, ",") .. "))", 2)
        end
        return n(...)
    end
end
local S, N, B = "string", "number", "boolean"
local closing = {}
ImGui = {
    Begin = sig("Begin", function(name, open, flags)
        if closing[name] then return false, false end
        depth = depth + 1; rec("Begin " .. name); return true, true
    end, { S, B, N }),
    End = sig("End", function() depth = depth - 1; rec("End") end, {}),
    MenuItem = sig("MenuItem", function(label, shortcut, selected, enabled)
        rec("Item " .. label)
        local hit = clicks[label] == true and enabled ~= false
        if selected == nil then return hit end
        if hit then selected = not selected end
        return selected, hit
    end, { S }, { S, S }, { S, S, B }, { S, S, B, B }),
    Text = sig("Text", function(s) rec("Text " .. s) end, { S }),
    TextDisabled = sig("TextDisabled", function(s) rec("Dim " .. s) end, { S }),
    TextWrapped = sig("TextWrapped", function(s) rec("Wrap " .. s) end, { S }),
    TextColored = sig("TextColored", function(r, g, b, a, s) rec("Col " .. s) end, { N, N, N, N, S }),
    Separator = sig("Separator", function() end, {}),
    SameLine = sig("SameLine", function() end, {}),
    Button = sig("Button", function(label) rec("Button " .. label); return clicks[label] == true end, { S }),
    Checkbox = sig("Checkbox", function(label, v)
        if clicks[label] then return not v, true end
        return v, false
    end, { S, B }),
    SliderFloat = sig("SliderFloat", function(label, v, lo, hi, fmt)
        if clicks.slider then return clicks.slider, true end
        return v, false
    end, { S, N, N, N }, { S, N, N, N, S }),
    SliderInt = sig("SliderInt", function(label, v, lo, hi)
        assert(v == math.floor(v), "SliderInt needs a whole number")
        if clicks[label] then return clicks[label], true end
        return v, false
    end, { S, N, N, N }, { S, N, N, N, S }),
    RadioButton = sig("RadioButton", function(label, active)
        rec("Radio " .. label .. (active and " *" or ""))
        return clicks[label] == true
    end, { S, B }),
    CollapsingHeader = sig("CollapsingHeader", function(label, flags) rec("Header " .. label); return true end, { S }, { S, N }),
    IsItemHovered = sig("IsItemHovered", function() return true end, {}),
    SetTooltip = sig("SetTooltip", function(t) rec("Tip " .. t) end, { S }),
    BeginMenu = sig("BeginMenu", function(label) rec("Menu " .. label); return true end, { S }, { S, B }),
    EndMenu = sig("EndMenu", function() end, {}),
    SetNextWindowSize = sig("SetNextWindowSize", function() end, { N, N }, { N, N, N }),
    SetNextWindowPos = sig("SetNextWindowPos", function() end, { N, N }, { N, N, N }),
}
local funcs = {}
function ImGui_AddUpdateFunction(name, f, always) funcs[name] = f end
function ImGui_RemoveUpdateFunction(name) funcs[name] = nil end
UserLuaMediaPath = userdir .. "/"
function user_open(name) dofile(UserLuaMediaPath .. name) end
file = { getmodifytime = function(p) return "t1" end }
local _dofile = dofile
dofile = function(p) return _dofile((p:gsub("\\", "/"))) end
local _open = io.open
local hdd = arg[3]
io.open = function(p, m)
    local hddPath = p:match("^HDD:(.*)$")
    if hddPath then
        return _open(hdd .. "/" .. hddPath:gsub("\\", "/"), m)
    end
    if m:find("[wa+]") then
        return nil, p .. ": No such file or directory"   -- the game's own folder is read-only to Lua
    end
    return _open((p:gsub("\\", "/")), m)
end

-- game side
local speed = 1.0
simulation = { setSpeed = function(v) speed = v end, getSpeed = function() return speed end }
local getawayActive, stops, mission = true, 0, false
Getaway = { IsAGetawayActive = function() return getawayActive end,
    StopAll = function() assert(not gameStatus.simulationPaused, "stopped while paused"); getawayActive = false; stops = stops + 1 end }
function isMissionActive() return mission end
local removedFns = {}
function removeUserUpdateFunction(name) removedFns[name] = true end
garage = { enable = function() end }
local hud = { shown = 0, lines = {} }
local hud8 = { shown = 0, lines = {}, icons = {} }
local prompt = { shown = 0, text = "", sets = 0 }
feedbackSystem = { menusMaster = { clearPrimaryTextPrompt = function() end, clearSecondaryTextPrompt = function() end,
    blockHintButton = function(b) assert(b == false) end,
    masterSetVariable = function(name, v)
        if name == "iHelicopter_Text" then hud.shown = v elseif name == "iControls_Display" then hud8.shown = v
        elseif name == "iPrompt_Secondary_Display" then prompt.shown = v; prompt.sets = prompt.sets + 1 end
    end,
    masterSetTextVariable = function(name, text)
        assert(type(text) == "string", name)
        local n = name:match("^helicopter_line_(%d)$")
        local c = name:match("^controls_string_line_(%d)$")
        local b = name:match("^controls_button_line_(%d)$")
        if name == "prompt_secondary" then prompt.text = text return end
        if name == "prompt_secondary_button" then return end
        assert(n or c or b, name)
        if n then hud.lines[tonumber(n)] = text elseif c then hud8.lines[tonumber(c)] = text else hud8.icons[tonumber(b)] = text end
    end } }
local sounds, soundPaused = {}, false
OneShotSound = { Play = function(name) sounds[#sounds + 1] = name end }
Sound = { SimulationPause = function() soundPaused = true end, SimulationResume = function() soundPaused = false end,
    TurnOff = function() end }
Menu = { HideUI = 0, ShowMaster = 1 }
local felonyEnded = 0
felony_feedback = { endFelony = function() felonyEnded = felonyEnded + 1 end }
Chase = { IsAChaseActive = function() return false end }
felony_getaway = { getCurrentHeatLevel = function() return 3 end }
felony_rework = { allowFelonyICrashCam = true, allowFelonyFreeDriveICrashCam = true,
    felonyCrimeCommitted = true, reportedOffenderGameVehicleSet = true, offenderGameVehicleReported = true }
function felony_rework.FelonyRework_clearFelonyCrimes() felony_rework.felonyCrimeCommitted = false end
function felony_rework.FelonyRework_clearReportedOffenderGameVehicle() felony_rework.reportedOffenderGameVehicleSet = false end
function felony_rework.FelonyRework_clearStoredOffenderGameVehicle() felony_rework.storedCleared = true end
local repaired, flipped = 0, 0
GameVehicleResource = {
    resetDamage = function(gv) assert(gv.model_id == 62); repaired = repaired + 1 end,
    selfRight = function(gv) error("boom from the game") end,
}
local wp = 500
-- the game's control handler: a fake pad, and the control-state stack
local pad = {}
local states, activeState = {}, "Player"
controlHandler = {
    getStatus = function(self, action) assert(self == controlHandler); return pad[action] and "Pressed" or "NotPressed", pad[action] and 1 or 0 end,
    registerState = function(self, id, name, b) assert(id == 0); states[name] = b end,
    setState = function(self, name) assert(states[name], "unregistered state"); activeState = name end,
    resetState = function(self, name) activeState = "Player" end,
    removeState = function(self, name, id) states[name] = nil end,
}
local function callback(action) states[activeState][action].JustPressed[1]() end
gameStatus = { simulationPaused = false }
local pauses = 0
-- like the game seems to: resuming puts back the speed from before the pause
local pausedSpeed
simulation.pause = function() gameStatus.simulationPaused = true; pauses = pauses + 1; pausedSpeed = speed end
simulation.start = function() gameStatus.simulationPaused = false; speed = pausedSpeed end
local vrepairs = 0
VEdit = { ResetVehicleDamage = function() assert(not gameStatus.simulationPaused, "repaired while paused"); vrepairs = vrepairs + 1 end }
g_NetworkTime = 100
ProfileSettings = { GetWillpower = function() return wp end, SetWillpower = function(v) wp = v end }
localPlayer = { localID = 0, currentVehicle = { gameVehicle = { model_id = 62 } } }

dofile(UserLuaMediaPath .. "felonyrework\\felonyreworkconfig.txt")
user_open("dsfmenu.lua")
assert(DSFMenu and funcs.DSFMenu, "not registered")

local _print = print
print = function(m) if tostring(m):find("ERROR") then error("logged: " .. tostring(m)) end _print(m) end
local function frame()
    for _, name in ipairs({ "File", "View", "World", "Game", "Utilities", "Help" }) do DSFMenu.menu(name) end
    local blocked = funcs.DSFMenu()
    assert(depth == 0, "Begin/End unbalanced: " .. depth)
    checked = (checked and checked <= #calls) and checked or 1
    for i = checked, #calls do assert(not calls[i]:find("error:"), calls[i]) end
    checked = #calls + 1
    return blocked
end

frame()
clicks["Felony Rework settings"] = true; frame(); clicks = {}
assert(DSFMenu.showFelony == true)
assert(frame() == true, "settings window should block input")
-- untick crash cam and roadblocks, save
clicks["Crash cam in felonies##FelonyICrashCam"] = true
clicks["Roadblocks##Roadblocks"] = true
frame(); clicks = {}
assert(FelonyReworkConfig_FelonyICrashCam == false and felony_rework.allowFelonyICrashCam == false)
assert(FelonyReworkConfig_Roadblocks == false)
clicks["Save"] = true; frame(); clicks = {}
-- speed, repair, flip (the flip raises in the game function)
clicks.slider = 0.25; frame(); clicks = {}
assert(speed == 0.25, "speed " .. speed)
clicks["Repair car"] = true; frame(); clicks = {}
assert(vrepairs == 1, "F2 repair uses VEdit")
clicks["Put car back on its wheels"] = true; frame(); clicks = {}
assert(DSFMenu.note:find("Flip upright failed"), DSFMenu.note)
DSFMenu.showStatus = true; frame()
-- status text
local seen = false
for _, c in ipairs(calls) do if c:find("Getaway, felony level 3") then seen = true end end
assert(seen, "status text")
-- reload path
file.getmodifytime = function() return "t2" end
for i = 1, 121 do frame() end
closing["DSF status"] = true; frame(); closing = {}
assert(DSFMenu.showStatus == false, "status window should close")
closing["Felony Rework settings"] = true; frame(); closing = {}
assert(DSFMenu.showFelony == false, "settings window should close")
DSFMenu.note = "100% done"; frame()
local escaped = false
for _, c in ipairs(calls) do if c:find("100%% done", 1, true) then escaped = true end end
assert(escaped, "percent not escaped")
-- Willpower below 0 is set back to 0 with the setting on, left alone with it off
wp = -250; for i = 1, 31 do frame() end
assert(wp == 0, "wp " .. wp)
FelonyReworkConfig_NoNegativeWillpower = false
wp = -250; for i = 1, 31 do frame() end
assert(wp == -250, "wp should stay with the setting off")
FelonyReworkConfig_NoNegativeWillpower = true
wp = 500

-- DSF Enhanced window: read, edit four kinds, save; only those lines change
calls = {}
clicks["DSF Enhanced settings"] = true; frame(); clicks = {}
assert(DSFMenu.showEnh == true)
assert(frame() == true, "DSF Enhanced window should block input")
local tip = false
for _, c in ipairs(calls) do if c:find("^Tip Forces D3D9 windowed") then tip = true end end
assert(tip, "tooltip from the ini comment")
local vsyncWas = DSFMenu.enh.values["Display.RemoveVSync"] == "1"
clicks["Turn off V-sync##Display.RemoveVSync"] = true
clicks["Traffic radius in m (game: 350)##Quality.TrafficSpawnRadius"] = 420
clicks["2048##Shadows.ShadowMapSize2048"] = true
frame(); clicks = {}
clicks.slider = -0.5  -- every SliderFloat in this frame: the LOD bias and the three scales
frame(); clicks = {}
assert(DSFMenu.enhEdits["Display.RemoveVSync"] == not vsyncWas)
assert(DSFMenu.enhEdits["Quality.TrafficSpawnRadius"] == 420)
assert(DSFMenu.enhEdits["Shadows.ShadowMapSize"] == 2048)
-- a key the file doesn't have
DSFMenu.enhEdits["Replay.DisableFilmEffect"] = nil
local before = io.open("dsf_enhanced.ini", "rb"):read("*a")
assert(DSFMenu.saveEnh())
local after = io.open("dsf_enhanced.ini", "rb"):read("*a")
print("--- ini diff lines:")
local a, b = {}, {}
for l in before:gmatch("([^\n]*)\n") do a[#a + 1] = l end
for l in after:gmatch("([^\n]*)\n") do b[#b + 1] = l end
print("lines before " .. #a .. ", after " .. #b)
assert(next(DSFMenu.enhEdits) == nil, "edits cleared after save")
assert(DSFMenu.enh.values["Display.RemoveVSync"] == (vsyncWas and "0" or "1"))
assert(DSFMenu.enh.values["Quality.TrafficSpawnRadius"] == "420")
assert(DSFMenu.enh.values["Shadows.ShadowMapSize"] == "2048")
assert(DSFMenu.enh.values["Quality.TextureLODBias"] == "-0.50")
-- keys the file lacks: one in an existing section, one whose section isn't there
local t = io.open("dsf_enhanced.ini", "rb"):read("*a")
t = t:gsub("CockpitPassengers=1\r?\n", ""):gsub("%[Replay%]\r?\n", ""):gsub("DisableFilmEffect=1\r?\n", "")
local f = _open("dsf_enhanced.ini", "wb"); f:write(t); f:close()
DSFMenu.readEnh()
assert(DSFMenu.enh.values["Quality.CockpitPassengers"] == nil and DSFMenu.enh.values["Replay.DisableFilmEffect"] == nil)
DSFMenu.enhEdits["Quality.CockpitPassengers"] = false
DSFMenu.enhEdits["Replay.DisableFilmEffect"] = true
assert(DSFMenu.saveEnh())
assert(DSFMenu.enh.values["Quality.CockpitPassengers"] == "0", "inserted into [Quality]")
assert(DSFMenu.enh.values["Replay.DisableFilmEffect"] == "1", "new [Replay] section")
local t2 = io.open("dsf_enhanced.ini", "rb"):read("*a")
assert(t2:find("0 keeps them hidden.\r\nCockpitPassengers=0\r\n", 1, true), "at the end of [Quality]")
assert(not t2:find("[^\r]\n"), "CRLF kept on every line")
assert(t2:find("\r\n%[Replay%]\r\nDisableFilmEffect=1\r\n$"), "appended at the end")
-- without the link a save fails and leaves the file alone
os.rename(hdd .. "/DSFMenu/dsf_enhanced.ini", hdd .. "/DSFMenu/dsf_enhanced.ini.off")
local t3 = io.open("dsf_enhanced.ini", "rb"):read("*a")
DSFMenu.enhEdits["Display.RemoveVSync"] = false
assert(DSFMenu.saveEnh() == false and DSFMenu.note:find("is missing"), DSFMenu.note)
assert(io.open("dsf_enhanced.ini", "rb"):read("*a") == t3, "unchanged without the link")
-- a copy in place of the link is refused
local c = _open(hdd .. "/DSFMenu/dsf_enhanced.ini", "wb"); c:write("[Display]\r\nRemoveVSync=1\r\n"); c:close()
assert(DSFMenu.saveEnh() == false and DSFMenu.note:find("isn't a link"), DSFMenu.note)
assert(io.open("dsf_enhanced.ini", "rb"):read("*a") == t3, "unchanged with a copy")
-- controller menu
local function tick(n) for i = 1, n or 1 do g_NetworkTime = g_NetworkTime + 1 / 60; frame() end end
local function seen(text) for _, c in ipairs(calls) do if c:find(text, 1, true) then return true end end return false end
local function selected() calls = {}; tick(); for _, c in ipairs(calls) do local t = c:match("^Col > (.*)$") if t then return t end end end
local function selectRow(text)
    for i = 1, 80 do
        local t = selected()
        if t and t:find(text, 1, true) == 1 then return end
        callback("Menu_Down"); tick(10)
    end
    error("row not found: " .. text)
end
local function openPage(text) selectRow(text); callback("Menu_Select"); tick(10) end
local function openMenu() pad.DPad_Up = true; tick(40); pad.DPad_Up = nil; assert(DSFMenu.pad.open, "open") end

-- game stand-ins the trainer uses
local gvA = localPlayer.currentVehicle.gameVehicle
gvA.speed = 20
local log = {}
local function note(s) log[#log + 1] = s end
GameVehicleResource.setDisableAllDamage = function(gv, on) note("damage " .. tostring(gv.model_id) .. " " .. tostring(on)) end
GameVehicleResource.setVehicleIsGhost = function(gv, on) note("ghost " .. tostring(on)) end
GameVehicleResource.explode = function(t) note("explode " .. tostring(t.gameVehicle.model_id)) end
civilianTraffic = { setTrafficOnOff = function(on) note("traffic " .. tostring(on)) end }
scoreSystem = { willpowerReward = function(v, kind) note("wp " .. v .. " " .. kind) end,
    stopAbilityDrain = function(id, on) note("drain " .. tostring(on)) end }
vec = { vector = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
function alignMatrix(pos, heading) return { pos = pos, heading = heading } end
zapcontroller = { ZapCameraGetTargetHeading = function() return 1.5 end, ZapCameraGetTargetPos = function() return vec.vector(1, 2, 3, 1) end }
localPlayer.currentVehicle.teleport = function(self, m) note(string.format("teleport %.1f %.1f", m.pos.x, m.pos.z)) end
vehicleStats = { [62] = { Picture1 = "dodge_challanger", Year = 1970 }, [130] = { Picture1 = "amc_pacer", Year = 1980 },
    [124] = { ModelName = "159 Ti", ManufacturerName = "Alfa Romeo", Year = 2009 }, [999] = { ModelName = "ID:12" } }
local loaded = {}
TrafficSpooler = { IsMissionVehicleLoaded = function(id) return loaded[id] == true end,
    RequestMissionVehicle = function(id) note("request " .. id); loaded[id] = true end }
zap = { zapSwap = { carSwapTriggered = function(plr, id) note("swap " .. id) end } }
-- the game's spooler: accepts a request and calls back once the car is in (spoolLoads)
local spoolAccepts, spoolCallback = true, nil
spooling = { requestToSpoolVehicle = function(id, cb) note("spool " .. id); if spoolAccepts then spoolCallback = cb end; return spoolAccepts end }
local zapInput = true
-- the player-car slot: loads a few frames after it's set
local playerModel, playerFrames = nil, 0
TrafficSpooler.ReleaseMissionVehicle = function(id) note("release " .. id); loaded[id] = nil end
TrafficSpooler.SetAsPlayerVehicle = function(id) note("player " .. id); playerModel, playerFrames = id, 0 end
TrafficSpooler.IsPlayerVehicleLoaded = function() playerFrames = playerFrames + 1; return playerModel ~= nil and playerFrames > 3 end
vehicleManager = { spawnVehicle = function(params) note("spawn " .. params.modelID); return { gameVehicle = { model_id = params.modelID } } end }
GameVehicleResource.setCharacterSpoolingEntityIndex = function() end
zapcontroller.EnableZapInput = function(on) zapInput = on end
local interesting, patrols = true, true
InterestingVehicleManager = { IsEnabled = function() return interesting end, Enable = function(on) interesting = on end }
PatrollingVehicleManager = { IsEnabled = function() return patrols end, Enable = function(on) patrols = on end }
local task
function localPlayer.getTaskObject(self) return task end
localPlayer.primaryFelony = {}
localPlayer.challenge = { endScreen = function(t, params) note("endscreen " .. params.rating); params.callback() end }
progressionSystem = { challengeComplete = function() note("complete") end, challengeFailed = function() note("failed") end }

DSFMenu.showEnh, DSFMenu.showFelony = false, false
DSFMenu.speed = 0.25; speed = 0.25
assert(DSFMenu.padStyle == "hud", "HUD style by default")
DSFMenu.padStyle = "window"   -- these tests read the ImGui window
assert(DSFTrainer and DSFTrainer.pages and DSFMenu.api, "trainer loaded")
pad.DPad_Up = true; tick(20); assert(not DSFMenu.pad.open, "opens only after half a second")
tick(20); pad.DPad_Up = nil
assert(DSFMenu.pad.open, "open after holding D-pad up")
assert(activeState == "dsfMenuPad" and gameStatus.simulationPaused and pauses == 1, "own control state, game paused")
calls = {}; tick(); assert(seen("Begin DSF menu (controller)") and seen("> Cheats  >"), "drawn, Cheats selected")
assert(seen("Boost, no damage"), "the selected row's description")
-- the still-held Menu_Up (D-pad up) from opening doesn't move the selection
pad.Menu_Up = true; DSFMenu.pad.last.Menu_Up = true; tick(); pad.Menu_Up = nil; tick()
assert(DSFMenu.pad.sel.main == 1, "held button ignored")
-- one press seen both ways counts once
callback("Menu_Down"); pad.Menu_Down = true; tick(); pad.Menu_Down = nil; tick(10)
assert(DSFMenu.pad.sel.main == 2, "deduped, sel " .. DSFMenu.pad.sel.main)
-- World: game speed, left twice through callbacks, right through polling; not applied while open
openPage("World"); assert(DSFMenu.pad.page == "world")
assert(selected():find("^Game speed"), "speed first")
callback("Menu_Left"); tick(10); callback("Menu_Left"); tick(10)
pad.Menu_Right = true; tick(); pad.Menu_Right = nil; tick(10)
assert(math.abs(DSFMenu.pad.speedTarget - 0.2) < 1e-6, "target " .. tostring(DSFMenu.pad.speedTarget))
assert(math.abs(speed - 0.25) < 1e-6, "not applied while the menu is open")
-- B back; Vehicle -> Repair: closes, the game resumes, repaired, the new speed sticks
callback("Menu_Cancel"); tick(10); assert(DSFMenu.pad.page == "main")
openPage("Vehicle"); selectRow("Repair car")
callback("Menu_Select"); tick(10)
assert(not DSFMenu.pad.open and not gameStatus.simulationPaused, "closed for the repair")
assert(vrepairs == 2, "repaired after closing " .. vrepairs)
assert(math.abs(speed - 0.2) < 1e-6, "speed after closing " .. speed)
-- reopen: the speed shown is the game's, closing without a change keeps it
openMenu(); openPage("World")
calls = {}; tick(); assert(seen("[0.20]"), "speed from the game")
callback("Menu_Start"); tick(10); assert(not DSFMenu.pad.open and math.abs(speed - 0.2) < 1e-6, "kept " .. speed)
-- Settings: Felony Rework -> Willpower setting off, save with X
openMenu(); openPage("Felony Rework settings"); assert(DSFMenu.pad.page == "felony")
selectRow("Willpower never goes below 0")
callback("Menu_Right"); tick(10); assert(FelonyReworkConfig_NoNegativeWillpower == false, "toggled")
callback("Menu_ExtraFirst"); tick(10); assert(DSFMenu.note:find("Saved"), DSFMenu.note)
FelonyReworkConfig_NoNegativeWillpower = true
-- DSF Enhanced: the traffic radius goes up a step
callback("Menu_Cancel"); tick(10); assert(DSFMenu.pad.page == "main")
openPage("DSF Enhanced settings"); assert(DSFMenu.pad.page == "enh", DSFMenu.pad.page)
selectRow("Traffic radius")
local radius = DSFMenu.enh.values["Quality.TrafficSpawnRadius"]
callback("Menu_Right"); tick(10)
assert(DSFMenu.enhEdits["Quality.TrafficSpawnRadius"] == tonumber(radius) + 10 or DSFMenu.enhEdits["Quality.TrafficSpawnRadius"] == 500, "radius step")
calls = {}; tick(); assert(seen(" *]"), "marked as changed")
-- LB pages up; B, B closes; the game resumes and the player's controls come back
callback("Menu_Shoulder_L1"); tick(10)
callback("Menu_Cancel"); tick(10); callback("Menu_Cancel"); tick(10)
assert(not DSFMenu.pad.open and activeState == "Player" and states.dsfMenuPad == nil, "closed, state removed")
assert(gameStatus.simulationPaused == false, "resumed")
-- doesn't open while the game is paused (its own menus, cutscenes)
gameStatus.simulationPaused = true; pad.DPad_Up = true; tick(60); pad.DPad_Up = nil; tick()
assert(not DSFMenu.pad.open, "not over the game's pause"); gameStatus.simulationPaused = false
-- closes by itself after two minutes untouched
openMenu()
for i = 1, 121 do tick(60) end
assert(not DSFMenu.pad.open and gameStatus.simulationPaused == false, "idle close")

-- clear wanted level: not in a mission; in free roam it ends the getaway and forgets the report
mission = true
assert(DSFMenu.clearWanted() == false and stops == 0 and DSFMenu.note:find("not during a mission"))
mission = false
assert(DSFMenu.clearWanted() == true and stops == 1 and not getawayActive and felonyEnded == 1)
assert(removedFns.bustedCountdown and removedFns.escapeCountdown, "countdowns removed")
assert(felony_getaway.clearAllSearchingCops == true and next(felony_getaway.goalCallbacks) == nil)
assert(felony_rework.felonyCrimeCommitted == false and felony_rework.reportedOffenderGameVehicleSet == false
    and felony_rework.offenderGameVehicleReported == false and felony_rework.storedCleared, "crimes and report cleared")
assert(DSFMenu.note:find("getaway ended, crimes and reports forgotten"), DSFMenu.note)
-- from the controller menu (Mission page): closes it, then clears once the game runs
getawayActive = true
openMenu(); openPage("Mission and wanted level"); selectRow("Clear wanted level")
calls = {}; tick(); assert(seen("closes the menu"), "says it closes the menu")
callback("Menu_Select"); tick(10)
assert(not DSFMenu.pad.open and stops == 2 and not getawayActive, "cleared after closing")
-- the F2 Game menu item
getawayActive = true
clicks["Clear wanted level"] = true; frame(); clicks = {}
assert(stops == 3 and not getawayActive, "F2 item")

-- trainer: no damage follows the car through a Shift and comes off when switched off
openMenu(); openPage("Cheats"); selectRow("No damage")
callback("Menu_Select"); tick(10); assert(DSFTrainer.on.noDamage, "on")
assert(#log == 0, "nothing applied while paused")
callback("Menu_Start"); tick(40)
assert(log[#log] == "damage 62 true", table.concat(log, ", ") .. " | on=" .. tostring(DSFTrainer.on.noDamage))
local gvB = { model_id = 130, speed = 0 }
localPlayer.currentVehicle.gameVehicle = gvB; log = {}; tick(40)
assert(log[1] == "damage 62 false" and log[2] == "damage 130 true", table.concat(log, ", "))
localPlayer.currentVehicle.gameVehicle = gvA
openMenu(); openPage("Cheats"); selectRow("No damage"); log = {}
callback("Menu_Select"); tick(10); assert(not DSFTrainer.on.noDamage and log[1] == "damage 62 false", table.concat(log, ", "))
-- Willpower: right raises the amount, A pays it at once
selectRow("Willpower"); callback("Menu_Right"); tick(10); log = {}
callback("Menu_Select"); tick(10); assert(log[1] == "wp 15000 Token", tostring(log[1]))
callback("Menu_Start"); tick(10)
-- horn boost (closed menu only)
DSFTrainer.on.hornBoost = true; gvA.speed = 20; pad.Vehicle_Horn = true; tick(5); pad.Vehicle_Horn = nil
assert(gvA.speed > 20, "boosted " .. gvA.speed); DSFTrainer.on.hornBoost = nil
-- no traffic: applied while on, put back once when off
DSFTrainer.on.noTraffic = true; log = {}; tick(40); assert(log[#log] == "traffic false", tostring(log[#log]))
DSFTrainer.pages.traffic()[2].set(false); assert(log[#log] == "traffic true")
-- cars: the game's list, named and sorted; LB/RB jump; swap waits for the model
openMenu(); openPage("Cars")
calls = {}; tick(); assert(seen("[Alfa Romeo 159 Ti (2009)]"), "first car by name")
callback("Menu_Right"); tick(10); calls = {}; tick(); assert(seen("[Amc Pacer (1980)]"), "next car")
callback("Menu_Shoulder_R1"); tick(10); calls = {}; tick(); assert(seen("[Model 999]"), "jump 10 wraps (4 cars: 2 + 10 -> 4)")
local names = {}
for _, c in ipairs(DSFTrainer.cars) do names[#names + 1] = c.name end
assert(table.concat(names, "|") == "Alfa Romeo 159 Ti (2009)|Amc Pacer (1980)|Dodge Challenger (1970)|Model 999", table.concat(names, "|"))
callback("Menu_Left"); tick(10)  -- 4 -> 3, the Dodge
calls = {}; tick(); assert(seen("[Dodge Challenger (1970)]"), "the Dodge")
gvA.model_id = 1   -- not the Dodge, which the mock car starts as
selectRow("Swap into it"); log = {}
callback("Menu_Select"); tick(10); tick(10)
assert(log[1] == "player 62" and log[2] == "swap 62" and DSFMenu.note == "Car swap: done", table.concat(log, ", "))
tick(60); assert(#log == 2, "swapped once: " .. table.concat(log, ", "))
-- a second swap from the car the first one gave: that car's model is only in the player slot,
-- so it's kept loaded as a mission car first, and released a few seconds after the swap
gvA.model_id = 62; loaded[62] = nil
openMenu(); openPage("Cars"); selectRow("Car")
for i = 1, 4 do calls = {}; tick(); if seen("[Amc Pacer") then break end callback("Menu_Right"); tick(10) end
selectRow("Swap into it"); log = {}
callback("Menu_Select"); tick(10); tick(10)
assert(log[1] == "request 62" and log[2] == "player 130" and log[3] == "swap 130", table.concat(log, ", "))
assert(DSFMenu.note == "Car swap: done", DSFMenu.note)
tick(60 * 4); assert(log[4] == "release 62", table.concat(log, ", "))
-- the current car can't be kept loaded: the swap doesn't go ahead
gvA.model_id = 130; loaded[130] = nil
TrafficSpooler.RequestMissionVehicle = function(id) note("request " .. id) end
openMenu(); openPage("Cars"); selectRow("Car")
for i = 1, 4 do calls = {}; tick(); if seen("[Dodge") then break end callback("Menu_Right"); tick(10) end
selectRow("Swap into it"); log = {}
callback("Menu_Select"); tick(10); tick(60 * 21)
assert(log[1] == "request 130" and log[2] == "release 130" and #log == 2, table.concat(log, ", "))
assert(DSFMenu.note:find("can't keep your current car loaded"), DSFMenu.note)
TrafficSpooler.RequestMissionVehicle = function(id) note("request " .. id); loaded[id] = true end
gvA.model_id = 62; loaded[62] = true
-- spawn (Shift view): the game's spooler, which calls back once the car is in
localPlayer.inZap = true; loaded[124] = nil
openMenu(); openPage("Cars"); selectRow("Car")
for i = 1, 4 do calls = {}; tick(); if seen("[Alfa Romeo") then break end callback("Menu_Right"); tick(10) end
selectRow("Spawn it"); log = {}
callback("Menu_Select"); tick(10)
assert(log[1] == "spool 124" and #log == 1 and DSFMenu.note:find("loading the car"), table.concat(log, ", "))
spoolCallback(); assert(log[2] == "spawn 124" and DSFMenu.note == "Spawn car: done", table.concat(log, ", "))
-- the spooler refuses: a mission-car request, watched until the car is in
spoolAccepts = false
openMenu(); openPage("Cars"); selectRow("Spawn it"); log = {}
callback("Menu_Select"); tick(10); tick(10)
assert(log[1] == "spool 124" and log[2] == "request 124" and log[3] == "spawn 124", table.concat(log, ", "))
-- a car that never loads: 20 seconds of the game running, the menu's time doesn't count
TrafficSpooler.RequestMissionVehicle = function(id) note("request " .. id) end
loaded[124] = nil
openMenu(); openPage("Cars"); selectRow("Spawn it"); log = {}
callback("Menu_Select"); tick(10)
openMenu(); tick(60 * 30); callback("Menu_Start"); tick(10)
assert(DSFMenu.note:find("loading the car"), "still waiting after the menu's 30 s: " .. DSFMenu.note)
tick(60 * 21); assert(DSFMenu.note == "Spawn car: the car didn't load", DSFMenu.note)
TrafficSpooler.RequestMissionVehicle = function(id) note("request " .. id); loaded[id] = true end
spoolAccepts = true
localPlayer.inZap = nil
-- opens with Menu_Up alone (Shift reports D-pad up only as that); Shift input off while open
localPlayer.inZap = true
-- Shift slows the game's clock: the hold counts frames, so it opens with the clock standing still
pad.Menu_Up = true; for i = 1, 40 do frame() end; pad.Menu_Up = nil
assert(DSFMenu.pad.open and zapInput == false, "opened in Shift (clock still), Shift input off")
callback("Menu_Start"); tick(10); assert(zapInput == true, "Shift input back")
localPlayer.inZap = nil
-- teleport: closes, then moves the car
openMenu(); openPage("Teleport"); selectRow("Hunter's Point garage"); log = {}
callback("Menu_Select"); tick(10); assert(log[1] == "teleport 466.6 3499.9", tostring(log[1]))
-- mission: complete runs the end screen and progression
task = { coreData = { instance = { challenge = {} }, agent = { matrix = {} } } }
openMenu(); openPage("Mission and wanted level"); selectRow("Complete mission"); log = {}
callback("Menu_Select"); tick(10); assert(log[1] == "endscreen PASS" and log[2] == "complete", table.concat(log, ", "))
task = nil

-- F2 -> Trainer: every page as a submenu, no errors
calls = {}; DSFMenu.menu("Trainer")
assert(seen("Menu Cheats") and seen("Menu Teleport") and seen("Menu World"), "submenus")
assert(seen("Item No collision##cheats5") and seen("Button Apply##cheats7"), "rows")
for _, c in ipairs(calls) do assert(not c:find("Error", 1, true), c) end
clicks["No collision##cheats5"] = true; DSFMenu.menu("Trainer"); clicks = {}
assert(DSFTrainer.on.noCollision, "toggled from F2")
-- HUD styles: game frozen at speed 0 with the sound paused; first the 3-row layout
DSFMenu.padStyle = "hud3"
speed = 0.5; Menu.HideUI = 1; sounds = {}
DSFMenu.pad.sel.main = 1   -- the menu remembers the last row; start at the top
openMenu()
assert(speed == 0 and soundPaused and not gameStatus.simulationPaused, "frozen at speed 0, not paused")
assert(Menu.HideUI == 0 and hud.shown == 1, "HUD shown")
tick()
assert(hud.lines[1] == "[  Cheats  [>]  ]" and hud.lines[2] == "Vehicle  [>]" and hud.lines[3] == "Cars  [>]", table.concat(hud.lines, " | "))
assert(hud.lines[4]:find("^DSF menu   1/") and hud.lines[5] == "Boost, no damage, no collision, Willpower", hud.lines[4] .. " | " .. hud.lines[5])
callback("Menu_Down"); tick(10)
assert(hud.lines[2] == "[  Vehicle  [>]  ]" and sounds[#sounds] == "Menu_Move", hud.lines[2])
for i = 1, 3 do callback("Menu_Down"); tick(10) end
assert(hud.lines[1] == "Traffic and people  [>]" and hud.lines[2] == "[  Teleport  [>]  ]", table.concat(hud.lines, " | "))
local function hudFind(text, lines, n)
    for i = 1, 60 do
        for l = 1, n do if lines[l]:find("[  " .. text, 1, true) == 1 then return end end
        callback("Menu_Down"); tick(10)
    end
    error("hud row " .. text)
end
selectRow2 = function(text) hudFind(text, hud.lines, DSFMenu.padStyle == "hud3" and 3 or 5) end
selectRow2("Menu style")
local first = hud.lines[5]; tick(200); assert(#first <= 49 and hud.lines[5] ~= first and #hud.lines[5] <= 49, first .. " -> " .. hud.lines[5])
selectRow2("Cars"); callback("Menu_Select"); tick(10)
callback("Menu_Down"); callback("Menu_Up"); tick(10)
assert(hud.lines[1]:find("^Car:  < .+ %(%d+%) >$"), hud.lines[1])   -- a value row reads < value >
DSFMenu.api.setNote("100% ready"); tick()
assert(hud.lines[4] == "100 ready", "note without the percent sign: " .. hud.lines[4])
tick(200); assert(hud.lines[4]:find("^Cars   %d/4$"), hud.lines[4])   -- the page and position; Back counts
callback("Menu_Start"); tick(10)
assert(not DSFMenu.pad.open and hud.shown == 0 and hud.lines[1] == "", "panel hidden")
assert(math.abs(speed - 0.5) < 1e-6 and not soundPaused and Menu.HideUI == 1, "restored: speed " .. speed)
Menu.HideUI = 0

-- the default HUD: five rows, the page and description on the secondary prompt line
DSFMenu.padStyle = "hud"; DSFMenu.pad.sel.main = 1; prompt.sets = 0
openMenu(); tick()
assert(hud.lines[1] == "[  Cheats  [>]  ]" and hud.lines[4] == "Traffic and people  [>]" and hud.lines[5] == "Teleport  [>]", table.concat(hud.lines, " | "))
assert(prompt.shown == 1 and prompt.text:find("^DSF menu  1/%d+  %-  Boost, no damage"), prompt.text)
tick(30); assert(prompt.sets == 1, "the prompt's display switch set once, not every frame: " .. prompt.sets)
for i = 1, 5 do callback("Menu_Down"); tick(10) end
assert(hud.lines[1] == "[  Mission and wanted level  [>]  ]" and hud.lines[2] == "World  [>]", table.concat(hud.lines, " | "))
DSFMenu.api.setNote("Saved"); tick(); assert(prompt.text == "Saved", prompt.text)
tick(200); assert(prompt.text:find("^DSF menu  6/"), prompt.text)
-- Menu style: A cycles HUD -> HUD 3 rows -> Window -> HUD, and the choice is saved
selectRow2("Menu style"); callback("Menu_Select"); tick(10)
assert(DSFMenu.padStyle == "hud3" and prompt.shown == 0, "3 rows, prompt line off")
local saved = io.open(hdd .. "/DSFMenu/menu_style.txt", "rb"):read("*a"); assert(saved == "hud3", saved)
callback("Menu_Select"); tick(10)
assert(DSFMenu.padStyle == "window" and hud.shown == 0, "window, panel off")
calls = {}; tick(); assert(seen("Begin DSF menu (controller)"), "window drawn")
callback("Menu_Select"); tick(10); assert(DSFMenu.padStyle == "hud")
callback("Menu_Start"); tick(10); assert(hud.shown == 0 and hud.lines[1] == "" and prompt.shown == 0 and prompt.text == "", "closed: panel and prompt cleared")
-- a reload reads the saved style; the old 8-row style (the controls panel) becomes the HUD and its panel is cleared
local f = _open(hdd .. "/DSFMenu/menu_style.txt", "wb"); f:write("hud3"); f:close()
DSFMenu.padStyle = nil; user_open("dsfmenu.lua"); assert(DSFMenu.padStyle == "hud3", tostring(DSFMenu.padStyle))
hud8.shown, hud8.lines[1] = 1, "x"
DSFMenu.padStyle = "hud8"; user_open("dsfmenu.lua")
assert(DSFMenu.padStyle == "hud" and hud8.shown == 0 and hud8.lines[1] == "", "hud8 gone, controls panel cleared")
local f2 = _open(hdd .. "/DSFMenu/menu_style.txt", "wb"); f2:write("hud8"); f2:close()
DSFMenu.padStyle = nil; user_open("dsfmenu.lua"); assert(DSFMenu.padStyle == "hud", tostring(DSFMenu.padStyle))
print("mock run ok; note: " .. DSFMenu.note)
