-- DSF menu trainer: cheats, vehicle, cars, traffic and people, teleports, mission, world and HUD
-- options for the controller menu (hold D-pad up) and F2 -> Trainer. Loaded by dsfmenu.lua, which
-- passes its helpers in DSFMenu.api; saving this file reloads it in game.
--
-- The options follow the ones in Snoopii's Mod Menu (FireBoyd78, Olanov, McNally and others); this
-- is a separate implementation on the game's Lua API.
--
-- A page is a list of rows:
--   { header = text }                              a title, not selectable
--   { text, page = name }                          opens another page
--   { text, get = fn, set = fn(on) }               on/off
--   { text, run = fn, closes = bool }              an action; closes = the controller menu closes
--                                                  and it runs once the game runs again
--   { text, value = fn, step = fn(dir), run = fn } a value: left/right change it, A (or Apply) runs
-- desc is a line shown for the selected row.

local api = DSFMenu.api
DSFTrainer = DSFTrainer or {}
local T = DSFTrainer
T.on = T.on or {}          -- the persistent toggles that are on
T.applied = T.applied or {}
T.values = T.values or {}  -- picker positions
local try, setNote = api.try, api.setNote

local function lp()
    return rawget(_G, "localPlayer")
end

local function car()
    return api.playerVehicle()
end

-- 1..n, wrapping round (steps of 10 too)
local function clampIndex(i, n)
    if n < 1 then return 1 end
    return (i - 1) % n + 1
end

-- A picker over a list: T.values[id] is the position.
local function picker(id, list, label)
    return {
        value = function()
            local items = type(list) == "function" and list() or list
            local i = clampIndex(T.values[id] or 1, #items)
            T.values[id] = i
            local item = items[i]
            return item == nil and "-" or (label and label(item) or tostring(item))
        end,
        step = function(dir)
            local items = type(list) == "function" and list() or list
            T.values[id] = clampIndex((T.values[id] or 1) + dir, #items)
        end,
        current = function()
            local items = type(list) == "function" and list() or list
            return items[clampIndex(T.values[id] or 1, #items)]
        end,
    }
end

-------------------------------------------------------------------------------------------
-- Persistent toggles: while on, apply runs every half second (the game turns some of them back,
-- and a Shift changes the car); off runs once when switched off. car = true: they go on the
-- player's car, and come off the previous one when it changes.

local TOGGLES = {
    noDamage = { car = true,
        apply = function(gv) GameVehicleResource.setDisableAllDamage(gv, true) end,
        off = function(gv) GameVehicleResource.setDisableAllDamage(gv, false) end },
    noCollision = { car = true,
        apply = function(gv) GameVehicleResource.setVehicleIsGhost(gv, true) end,
        off = function(gv) GameVehicleResource.setVehicleIsGhost(gv, false) end },
    infiniteMass = { car = true,
        apply = function(gv) GameVehicleResource.setInfiniteMass(gv, true) end,
        off = function(gv) GameVehicleResource.setInfiniteMass(gv, false) end },
    infiniteAbility = {
        apply = function() scoreSystem.stopAbilityDrain(lp().localID, true) end,
        off = function() scoreSystem.stopAbilityDrain(lp().localID, false) end },
    noTraffic = {
        apply = function() civilianTraffic.setTrafficOnOff(false) end,
        off = function() civilianTraffic.setTrafficOnOff(true) end },
    stoppedTraffic = {
        apply = function() civilianTraffic.setTrafficStoppedOnOff(true); Sound.TurnOff("CivHorns", true) end,
        off = function() civilianTraffic.setTrafficStoppedOnOff(false); Sound.TurnOff("CivHorns", false) end },
    abandonedTraffic = {
        apply = function() civilianTraffic.setTrafficAbandonedOnOff(true); Sound.TurnOff("CivHorns", true) end,
        off = function() civilianTraffic.setTrafficAbandonedOnOff(false); Sound.TurnOff("CivHorns", false) end },
    noTrafficEvents = {
        apply = function() TrafficEventsManager.SetEnable(false) end,
        off = function() TrafficEventsManager.SetEnable(true) end },
    noSuspicious = {
        apply = function() felony_suspiciousVehicleManager.enableSuspiciousVehicles(false) end,
        off = function() felony_suspiciousVehicleManager.enableSuspiciousVehicles(true) end },
    noPeds = {
        apply = function() characterManager.DisablePeds() end,
        off = function() characterManager.EnablePeds() end },
    randomPedSize = {
        apply = function() characterManager.setPedestrianScaleFactor(1) end,
        off = function() characterManager.setPedestrianScaleFactor(0) end },
    hideMinimap = {
        apply = function() lp().minimapSupport:hide() end,
        off = function() lp().minimapSupport:show() end },
    jerichoAlleyway = {
        apply = function()
            propSystem.disablePropType("DO_NOT_USE_shutter_A", "DO_NOT_USE_shutter_B", "DO_NOT_USE_Wall_A")
            Atlas.JerichoAlleyWayActive(true)
        end,
        off = function() propSystem.reenableAllPropTypes(); Atlas.JerichoAlleyWayActive(false) end },
    keepSpeed = {
        apply = function()
            local p = lp()
            if p and not p.inZap then
                local now = api.reportedSpeed()
                if type(now) == "number" and math.abs(now - DSFMenu.speed) > 0.001 then
                    simulation.setSpeed(DSFMenu.speed)
                end
            end
        end,
        off = function() end },
}

local function toggleRow(key, text, desc)
    return {
        text = text, desc = desc,
        get = function() return T.on[key] == true end,
        set = function(on)
            T.on[key] = on or nil
            if not on then
                T.turnOff(key)
            end
        end,
    }
end

function T.turnOff(key)
    local t = TOGGLES[key]
    local was = T.applied[key]
    T.applied[key] = nil
    if t and was then
        if t.car then
            if type(was) == "table" then try(t.off, was) end
        else
            try(t.off)
        end
    end
end

local function stepToggles()
    for key, t in pairs(TOGGLES) do
        if T.on[key] then
            if t.car then
                local gv = car()
                local was = T.applied[key]
                if was and was ~= gv and type(was) == "table" then
                    try(t.off, was)         -- the previous car (a Shift)
                    T.applied[key] = nil
                end
                if gv then
                    try(t.apply, gv)
                    T.applied[key] = gv
                end
            else
                try(t.apply)
                T.applied[key] = true
            end
        end
    end
end

-------------------------------------------------------------------------------------------
-- The horn: boost (hold) and explosive horn (press). Not while a menu has the pad.

local hornWasDown = false
local function stepHorn()
    local down = api.padDown("Vehicle_Horn")
    local pressed = down and not hornWasDown
    hornWasDown = down
    if api.padOpen() then return end
    local gv = car()
    if not gv then return end
    if T.on.hornBoost and down then
        try(function()
            local speed = gv.speed
            if speed < 120 then   -- metres a second
                gv.speed = speed < 5 and 10 or speed * 1.04
            end
        end)
    end
    if T.on.boomHorn and pressed then
        try(function()
            GameVehicleResource.explode({ gameVehicle = gv, offset = vec.vector(0.25, -1, 0.25, 0), range = 1.5,
                strength = 2.5, disableVisual = false, disablePanelDetach = false })
        end)
    end
end

-------------------------------------------------------------------------------------------
-- Cars: the game's own list (vehicleStats), named from their picture name and year.

local function prettyName(id, s)
    local name = type(s.Picture1) == "string" and s.Picture1 or nil
    if name then
        name = name:gsub("challanger", "challenger"):gsub("_", " ")
        name = name:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end)
    elseif type(s.ModelName) == "string" and not s.ModelName:find("^ID:") then
        name = ((type(s.ManufacturerName) == "string" and not s.ManufacturerName:find("^ID:")) and (s.ManufacturerName .. " ") or "")
            .. s.ModelName
    else
        name = "Model " .. id
    end
    if s.Year then
        name = name .. " (" .. tostring(s.Year) .. ")"
    end
    return name
end

local function carList()
    if T.cars and #T.cars > 0 then return T.cars end
    local cars = {}
    local stats = rawget(_G, "vehicleStats")
    if type(stats) == "table" then
        for id, s in pairs(stats) do
            if type(id) == "number" and type(s) == "table" then
                cars[#cars + 1] = { id = id, name = prettyName(id, s) }
            end
        end
        table.sort(cars, function(a, b) return a.name < b.name end)
    end
    T.cars = cars
    return cars
end

-- Loads a model, then runs fn. asPlayer (a car swap): into the player-car slot
-- (TrafficSpooler.SetAsPlayerVehicle, as the game's debug spawner does), which loads it even when
-- the mission-car slots are full (Felony's patrols and roadblocks take them). Otherwise the game's
-- spooler (spooling.requestToSpoolVehicle calls back once the car is in), else a mission-car
-- request we watch. Gives up after 20 seconds of the game running: no time counts while it's
-- paused or the menu is open (nothing loads then).
local function loadedNow(id)
    return try(function() return TrafficSpooler.IsMissionVehicleLoaded(id) end) == true
end

local function finishPending(p)
    if p.done then return end
    p.done = true
    if T.pending == p then T.pending = nil end
    local ok, err = pcall(p.fn)
    if not ok then
        setNote(p.label .. " failed: " .. tostring(err))
    elseif not p.quiet then
        setNote(p.label .. ": done")
    end
end

-- Waits (in stepPending) until check() is true, then runs fn.
local function waitFor(label, check, fn, quiet)
    if check() then
        fn()
        return nil
    end
    local p = { label = label, check = check, fn = fn, waited = 0, quiet = quiet }
    T.pending = p
    setNote(label .. ": loading the car...")
    return p
end

local function whenLoaded(modelID, label, fn, asPlayer)
    if loadedNow(modelID) then
        return fn()
    end
    if asPlayer then
        try(function() TrafficSpooler.SetAsPlayerVehicle(modelID) end)
        waitFor(label, function()
            return loadedNow(modelID) or try(function() return TrafficSpooler.IsPlayerVehicleLoaded() end) == true
        end, fn)
    else
        local p = waitFor(label, function() return loadedNow(modelID) end, fn)
        if p then
            local accepted = try(function()
                return spooling.requestToSpoolVehicle(modelID, function() finishPending(p) end)
            end)
            if not accepted and not p.done then
                try(function() TrafficSpooler.RequestMissionVehicle(modelID) end)
            end
        end
    end
end

-- A model we keep loaded (as a mission car) for a swap, released a few seconds after it.
local function release(id)
    try(function() TrafficSpooler.ReleaseMissionVehicle(id) end)
end

local lastTime
local function stepPending()
    local now = rawget(_G, "g_NetworkTime")
    local dt = (type(now) == "number" and type(lastTime) == "number") and math.max(0, math.min(1, now - lastTime)) or 0
    lastTime = now
    if api.gamePaused() or api.padOpen() then return end
    local r = T.releaseLater
    if r then
        r.waited = r.waited + dt
        if r.waited > 3 then
            T.releaseLater = nil
            release(r.id)
        end
    end
    local p = T.pending
    if not p or p.done then return end
    p.waited = p.waited + dt
    if p.check() then
        finishPending(p)
    elseif p.waited > 20 then
        T.pending = nil
        p.done = true
        if p.onTimeout then
            p.onTimeout()
        else
            setNote(p.label .. ": the car didn't load")
        end
    end
end

-- Car swap. The new model goes into the player-car slot (TrafficSpooler.SetAsPlayerVehicle), the
-- only slot free when Felony's cars fill the mission ones. That slot also keeps the car you drive
-- loaded when it came from the last swap (T.playerSlotModel): moving the slot then would free the
-- model of the car you're in, and the game crashed. So that model is first kept loaded as a
-- mission car, and released a few seconds after the swap.
local function swapCar(modelID)
    local gv = car()
    if not gv then setNote("Car swap: you're not in a car") return end
    local current = try(function() return gv.model_id end)
    if current == modelID then setNote("Car swap: that's the car you're in") return end
    local function doSwap()
        pcall(function() zapWeaponSupport.enableZapWeapons(true) end)
        zap.zapSwap.carSwapTriggered(localPlayer, modelID)
        localPlayer.currentVehicle.model_id = modelID
        T.playerSlotModel = modelID
        if T.pinned then
            T.releaseLater = { id = T.pinned, waited = 0 }
            T.pinned = nil
        end
    end
    local function startSwap()
        whenLoaded(modelID, "Car swap", doSwap, true)
    end
    if current ~= nil and current == T.playerSlotModel and not loadedNow(current) then
        try(function() TrafficSpooler.RequestMissionVehicle(current) end)
        T.pinned = current
        local p = waitFor("Car swap", function() return loadedNow(current) end, startSwap, true)
        if p then
            p.onTimeout = function()
                T.pinned = nil
                release(current)
                setNote("Car swap: can't keep your current car loaded to swap again; Shift into another car first")
            end
        end
    else
        startSwap()
    end
end

-- Spawns a car where the Shift cursor is (only in the Shift view).
local function spawnCar(modelID)
    local p = lp()
    if not (p and p.inZap) then setNote("Spawn car: Shift out first, it spawns at the Shift cursor") return end
    local position = zapcontroller.ZapCameraGetTargetPos()
    local heading = zapcontroller.ZapCameraGetTargetHeading()
    whenLoaded(modelID, "Spawn car", function()
        local vehicle = vehicleManager.spawnVehicle({ position = position, heading = heading, modelID = modelID,
            snapToTerrain = true, shader = { [0] = math.random(1, 8) } })
        vehicle.owner = "Script"
        for seat = 1, 3 do   -- no passengers
            GameVehicleResource.setCharacterSpoolingEntityIndex(vehicle.gameVehicle, seat, -1)
        end
    end)
end

-------------------------------------------------------------------------------------------
-- Teleports: the car, or the Shift cursor in the Shift view.

local function teleport(pos)
    local p = lp()
    if p.inZap then
        zapcontroller.setActionPoinTracking(pos, 0, 0, p.localID)
    elseif p.currentVehicle then
        p.currentVehicle:teleport(alignMatrix(pos, zapcontroller.ZapCameraGetTargetHeading()))
    else
        error("not in a car")
    end
end

local PLACES = {
    { "Hunter's Point garage", 466.608, 8.471, 3499.921 },
    { "Downtown garage", 96.049, 18.123, 1036.892 },
    { "\"Blast from the past\" garage", -3583.903, 7.530, -5075.558, unlock = true },
    { "Postcard location", -384.717, 63.107, -94.092 },
    { "Olanov's glitchy area", -2697.041, 129.811, 3646.430 },
}

local function missionTarget()
    local task = lp():getTaskObject()
    if not task then return nil end
    for _, t in pairs(task.namedTasks or {}) do
        if t.dynamicTargets and t.dynamicTargets[1] then
            return t.dynamicTargets[1].position
        end
    end
    return nil
end

-------------------------------------------------------------------------------------------
-- Mission: complete, fail, quit.

local function endMission(rating)
    local task = lp():getTaskObject()
    if not task then setNote("No mission is running") return end
    local core = task.coreData
    local agent = core.agent
    if lp().primaryFelony.getawayGameVehicle then
        felony_chase.endScreenVehicle = felony_chase.takeOwnershipOfGetaway()
    end
    local params = { vehicle = agent or felony_chase.endScreenVehicle or lp().currentVehicle, rating = rating }
    params.callback = function()
        local matrix = agent and agent.matrix
        if rating == "PASS" then
            progressionSystem.challengeComplete(core.instance, matrix)
        else
            progressionSystem.challengeFailed(core.instance, matrix)
        end
    end
    if rating ~= "PASS" then
        BackSeatDriver.Clear()
        lp():resetCameraMode()
        Chase.StopAll()
    end
    local data = core.instance.challenge.taskCompleteData
    if data then
        params.cameraShots = cardSystem.cameraShots[2]
        params.successReason = data["Success reason"]
        params.failReason = data["Failure reason"]
        params.inCarCompletion = data["In-car completion"]
        params.inCarReward = data["In-car reward"]
        params.passCondition = data["Pass condition"]
        params.passReward = data["Pass reward"]
    end
    lp().challenge.endScreen(task, params)
end

-------------------------------------------------------------------------------------------
-- Lists

local LIGHTS = { "Headlights", "DippedHeadlights", "High", "FogLights", "DaytimeRunning", "Brakes", "Reverse",
    "LeftIndicator", "RightIndicator", "Siren" }
local TRAFFIC_SETS = { "Chapter 1", "Chapter 2", "Chapter 3", "Chapter 4", "Chapter 5", "Chapter 6", "Chapter 7",
    "Chapter 8", "Chapter 2 God", "Chase traffic 1", "Chase traffic 2", "Chase traffic 3", "Chase traffic 5",
    "Challenge traffic", "Challenge traffic heavy", "DeactivatingBombs", "Epilogue", "Exposition", "Exposition Drive",
    "Exposition Chase", "Exposition Bullrun", "Exposition Shift", "Mind Control" }
local CIVILIAN_POTS = { "Free Drive Pot 01", "Free Drive Pot 02", "Free Drive Pot 03", "Free Drive Pot 04",
    "Free Drive Pot 05", "Free Drive Pot 06", "Free Drive Pot 07" }
local CITY_LOCKS = { "completelyUnlocked", "CityLockingLevel1", "CityLockingLevel2", "CityLockingLevel3",
    "CityLockingLevel4", "CityLockingLevel11_Exposition_Part1", "CityLockingLevel12_Exposition_Part2",
    "CityLockingLevel_Ambulance", "CityLockingLevel_WAKEUP", "CityLockingLevel_Epilogue" }

local function moods()
    if T.moods and #T.moods > 0 then return T.moods end
    local list = {}
    local ms = rawget(_G, "moodSystem")
    if type(ms) == "table" and type(ms.moodGroups) == "table" then
        for name in pairs(ms.moodGroups) do list[#list + 1] = tostring(name) end
        table.sort(list)
    end
    T.moods = list
    return list
end

local lightPick = picker("light", LIGHTS)
local trafficPick = picker("trafficSet", TRAFFIC_SETS)
local potPick = picker("pot", CIVILIAN_POTS)
local cityPick = picker("city", CITY_LOCKS)
local moodPick = picker("mood", moods)
local carPick = picker("car", carList, function(c) return c.name end)
T.values.lightOn = T.values.lightOn == nil and true or T.values.lightOn
T.values.willpower = T.values.willpower or 10000
T.values.dirt = T.values.dirt or 0
T.values.imposter = T.values.imposter or 2800

local function onCar(label, fn)
    return function() api.onPlayerVehicle(label, fn) end
end

-------------------------------------------------------------------------------------------
-- Pages

T.pages = {}
T.titles = {
    cheats = "Cheats", vehicle = "Vehicle", cars = "Cars", traffic = "Traffic and people",
    teleport = "Teleport", mission = "Mission and wanted level", world = "World", hud = "HUD",
}
T.order = { "cheats", "vehicle", "cars", "traffic", "teleport", "mission", "world", "hud" }
T.descs = {
    cheats = "Boost, no damage, no collision, Willpower", vehicle = "Repair, lights, siren, panels, explode",
    cars = "Swap your car, spawn one at the Shift cursor", traffic = "Traffic and pedestrian settings",
    teleport = "Garages, places, the mission checkpoint", mission = "Complete, fail or quit; lose the cops",
    world = "Game speed, weather, city unlock, draw distance", hud = "Minimap and UI",
}

function T.pages.cheats()
    return {
        toggleRow("hornBoost", "Horn boost", "Hold the horn to speed up"),
        toggleRow("boomHorn", "Explosive horn", "The horn sets off an explosion at your car"),
        toggleRow("infiniteAbility", "Infinite Shift ability", "The ability bar doesn't drain"),
        toggleRow("noDamage", "No damage", "Your car takes no damage"),
        toggleRow("noCollision", "No collision", "Your car goes through cars and objects"),
        toggleRow("infiniteMass", "Infinite mass", "Your car pushes everything out of its way"),
        { text = "Willpower", desc = "A adds (or takes) this much; left/right change it",
            value = function()
                local v = T.values.willpower
                return (v >= 0 and "+" or "") .. tostring(v) .. "   (you have " .. tostring(try(function()
                    return ProfileSettings.GetWillpower() end)) .. ")"
            end,
            step = function(dir)
                local v = T.values.willpower
                local mag = math.abs(v) >= 100000 and 50000 or math.abs(v) >= 10000 and 5000 or 1000
                T.values.willpower = math.max(-1000000, math.min(8000000, v + dir * mag))   -- the game's Lua numbers are floats: literals stop at 8388606
            end,
            run = function()
                scoreSystem.willpowerReward(T.values.willpower, "Token")
                setNote("Willpower " .. (T.values.willpower >= 0 and "+" or "") .. T.values.willpower)
            end },
    }
end

function T.pages.vehicle()
    return {
        api.repairRow(),
        api.flipRow(),
        { text = "Stop instantly", desc = "Your car stops dead", closes = true,
            run = onCar("Stop", function(gv) gv.speed = 0 end) },
        { text = "Siren", desc = "A switches it on or off (cars with a siren)",
            value = function() return T.values.siren and "On" or "Off" end,
            step = function() T.values.siren = not T.values.siren end,
            run = onCar("Siren", function(gv) GameVehicleResource.setSiren(gv, T.values.siren == true) end) },
        { text = "Light", desc = "Left/right pick a light; A switches it on or off (as Light state says)",
            value = function() return lightPick.value() .. (T.values.lightOn and " on" or " off") end,
            step = lightPick.step,
            run = onCar("Light", function(gv)
                GameVehicleResource.setLights({ gameVehicle = gv, LightType = lightPick.current(), State = T.values.lightOn })
            end) },
        { text = "Light state", desc = "What the Light row does: on or off",
            value = function() return T.values.lightOn and "On" or "Off" end,
            step = function() T.values.lightOn = not T.values.lightOn end },
        { text = "Dirt", desc = "How dirty your car is; A applies",
            value = function() return string.format("%.1f", T.values.dirt) end,
            step = function(dir) T.values.dirt = math.max(0, math.min(2, T.values.dirt + dir * 0.1)) end,
            run = onCar("Dirt", function(gv) GameVehicleResource.setDirtValue({ gameVehicle = gv, dirt = T.values.dirt }) end) },
        { text = "Open all panels", desc = "Doors, bonnet and boot open", closes = true,
            run = onCar("Open panels", function(gv) GameVehicleResource.forceOpenPanels({ gameVehicle = gv }) end) },
        { text = "Remove all panels", desc = "Doors, bonnet, boot and bumpers come off", closes = true,
            run = onCar("Remove panels", function(gv) GameVehicleResource.removeAllPanels(gv) end) },
        { text = "Remove all wheels", closes = true,
            run = onCar("Remove wheels", function(gv) GameVehicleResource.detachWheel(gv, false) end) },
        { text = "Explode", desc = "Blows up your car", closes = true,
            run = onCar("Explode", function(gv)
                GameVehicleResource.explode({ gameVehicle = gv, offset = 2, range = 2, strength = 10,
                    disableVisual = false, disablePanelDetach = false })
            end) },
    }
end

function T.pages.cars()
    local n = #carList()
    return {
        { text = "Car", desc = n > 0 and (n .. " cars: left/right pick one, LB/RB jump 10") or "The game's car list isn't loaded yet",
            value = carPick.value, step = carPick.step, jump = 10 },
        { text = "Swap into it", desc = "Your car becomes the one picked above", closes = true,
            run = function() local c = carPick.current() if c then swapCar(c.id) end end },
        { text = "Spawn it at the Shift cursor", desc = "In the Shift view: spawns the car picked above", closes = true,
            run = function() local c = carPick.current() if c then spawnCar(c.id) end end },
    }
end

function T.pages.traffic()
    return {
        { header = "Traffic" },
        toggleRow("noTraffic", "No traffic", "No civilian cars"),
        toggleRow("stoppedTraffic", "Stopped traffic", "Civilian cars stand still"),
        toggleRow("abandonedTraffic", "Abandoned traffic", "Civilian cars without drivers"),
        toggleRow("noTrafficEvents", "No traffic events", "No crashes, breakdowns and the like in traffic"),
        toggleRow("noSuspicious", "No suspicious vehicles", "In a police car: no suspects to chase"),
        { text = "Interesting vehicles", desc = "Rare and special cars in traffic",
            get = function() return try(function() return InterestingVehicleManager.IsEnabled() end) == true end,
            set = function(on) try(function() InterestingVehicleManager.Enable(on) end) end },
        { text = "Police patrols", desc = "Police cars on patrol (Felony Rework manages them too)",
            get = function() return try(function() return PatrollingVehicleManager.IsEnabled() end) == true end,
            set = function(on) try(function() PatrollingVehicleManager.Enable(on) end) end },
        { text = "No special trailers", desc = "Mission trailers don't show up in traffic",
            get = function() return T.values.noTrailers == true end,
            set = function(on)
                T.values.noTrailers = on
                try(function()
                    civilianTraffic.setTrafficOnOff(false)
                    if on then
                        TrafficSpooler.ExcludeTrailerModel(131)
                        TrafficSpooler.ExcludeTrailerModel(289)
                    else
                        TrafficSpooler.ClearExcludedTrailerModelList()
                    end
                    civilianTraffic.setTrafficOnOff(true)
                end)
            end },
        { text = "Traffic set", desc = "A loads the traffic of that chapter or mission", closes = true,
            value = trafficPick.value, step = trafficPick.step, jump = 5,
            run = function() spooling.spoolTraffic(trafficPick.current()) end },
        { header = "Pedestrians" },
        toggleRow("noPeds", "No pedestrians", "Nobody on the pavements"),
        toggleRow("randomPedSize", "Random pedestrian sizes", "Newly spawned pedestrians get random sizes"),
        { text = "Convicts", desc = "Pedestrians are escaped convicts (fewer of them)",
            get = function() return T.values.convicts == true end,
            set = function(on)
                T.values.convicts = on
                try(function()
                    if on then
                        characterManager.EnableEscapedConvicts()
                        characterManager.SetPedestrianDensityMultiplier(0.15)
                    else
                        characterManager.DisableEscapedConvicts()
                        characterManager.SetPedestrianDensityMultiplier(1)
                    end
                end)
            end },
        { text = "Civilian set", desc = "A loads that set of civilian cars", value = potPick.value, step = potPick.step,
            run = function() GameVehicleResource.SetCivilianPot(potPick.current()) end },
    }
end

function T.pages.teleport()
    local rows = {}
    for _, place in ipairs(PLACES) do
        rows[#rows + 1] = { text = place[1], closes = true,
            desc = place.unlock and "Unlocks the whole city first" or "Your car, or the Shift cursor in the Shift view",
            run = function()
                if place.unlock then
                    CityLockManager.CityLockState = "completelyUnlocked"
                    CityLockManager.CityLockActive = true
                end
                teleport(vec.vector(place[2], place[3], place[4], 1))
                setNote("Teleported: " .. place[1])
            end }
    end
    rows[#rows + 1] = { text = "Mission checkpoint", desc = "The current mission's next target", closes = true,
        run = function()
            local pos = missionTarget()
            if not pos then setNote("No mission target to go to") return end
            teleport(pos)
            setNote("Teleported to the mission target")
        end }
    return rows
end

function T.pages.mission()
    return {
        api.clearWantedRow(),
        { text = "Stop chase", desc = "Ends a chase where you're the cop", closes = true,
            run = function() Chase.StopAll(); setNote("Chase stopped") end },
        { text = "Complete mission", desc = "Passes the current mission, race or activity", closes = true,
            run = function() endMission("PASS") end },
        { text = "Fail mission", desc = "Fails the current mission, race or activity", closes = true,
            run = function() endMission("FAIL") end },
        { text = "Quit mission", desc = "Quits the current mission, race or activity", closes = true,
            run = function() quitMission() end },
    }
end

function T.pages.world()
    return {
        api.speedRow(),
        toggleRow("keepSpeed", "Keep game speed", "Puts your speed back when the game changes it (not while Shifting)"),
        { text = "Weather", desc = "A applies that mood (time of day, weather, grade)", closes = true,
            value = moodPick.value, step = moodPick.step,
            run = function()
                moodSystem.clearMoods()
                moodSystem.applyMood(moodPick.current())
            end },
        { text = "City unlock", desc = "A sets which parts of the city are open", value = cityPick.value, step = cityPick.step,
            run = function()
                CityLockManager.CityLockState = cityPick.current()
                CityLockManager.CityLockActive = true
            end },
        { text = "Building draw distance", desc = "Distant buildings (imposters), 0-7000; A applies",
            value = function() return tostring(T.values.imposter) end,
            step = function(dir) T.values.imposter = math.max(0, math.min(7000, T.values.imposter + dir * 100)) end,
            run = function() performance.SetImposterDistance(T.values.imposter) end },
        { text = "Reset level props", desc = "Props, particles and fragments back as they were", closes = true,
            run = function() simulation.resetLevel() end },
        toggleRow("jerichoAlleyway", "Open Jericho's alleyway", "Opens the alleyway from the prologue chase"),
    }
end

function T.pages.hud()
    return {
        toggleRow("hideMinimap", "Hide minimap", "The minimap stays hidden"),
        { text = "Hide UI", desc = "Hides the whole HUD (switch it off to bring it back)",
            get = function() return T.values.hideUI == true end,
            set = function(on) T.values.hideUI = on; try(function() Menu.HideUI = on and 1 or 0 end) end },
    }
end

-------------------------------------------------------------------------------------------
-- Every frame (dsfmenu.lua's update). Toggles and the horn wait while the game is paused or the
-- controller menu is open.

local frames = 0
function T.step()
    stepPending()
    if api.gamePaused() or api.padOpen() or not lp() then   -- the HUD menu freezes the game at speed 0
        return
    end
    stepHorn()
    frames = frames + 1
    if frames >= 30 then
        frames = 0
        stepToggles()
    end
end

api.log("trainer loaded")
