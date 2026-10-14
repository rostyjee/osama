-- Tap Simulator: Reborn - light hub for Xeno (Rayfield Gen2)
-- Xeno can't reach the game's live modules: its require gives fresh copies that can't load
-- the account's data, and its getgc / getconnections / debug.getupvalue are stubs. So this
-- hub never reads the account's data. It works from what Xeno does have - the game's config
-- modules (copies, after Xeno's UnlockModule), the map, leaderstats and the remotes - and
-- learns the rest from the server's replies (a refused claim says why).
--   Farming:  Auto Tap, Auto Break
--   Pets:     Auto Hatch (count steps down until the server takes it), auto-delete at hatch
--   Utils:    quests, Tap Chests, index rewards, potions, island teleport
--   Settings: Anti-AFK, No 3D render, FPS limit, FPS boost, auto reconnect
-- Taps: the server accepts ~8.3/s (0.12s spacing) and silently drops the rest.
-- The full hub (TapSimHub.luau, Real) and this one mark the player when they start, and an
-- older copy of either stops when it sees a newer one, so the two never run together.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local player = Players.LocalPlayer

local Remotes = ReplicatedStorage:WaitForChild("RemoteServices", 60)
local TapRequested = Remotes.TapService.RE.TapRequested
local TapResult = Remotes.TapService.RE.TapResult
local EggHatchRequested = Remotes.EggService.RE.EggHatchRequested
local EggHatchResult = Remotes.EggService.RE.EggHatchResult
local AutoDeleteRequested = Remotes.EggService.RE.AutoDeleteRequested
local ClaimQuest = Remotes.QuestService.RF.ClaimQuest
local ClaimChest = Remotes.TapChestService.RF.Claim
local Travel = Remotes.IslandService.RF.Travel
local UseBoost = Remotes.BoostService.RF.Use
local ClaimIndex = Remotes.PetIndexService.RE.ClaimAllRequested
local BreakableRewarded = Remotes.BreakableService.RE.Rewarded

-- Xeno only lets its scripts require a game module once it's unlocked (UnlockModule); the
-- configs all live under ReplicatedStorage.Shared, which unlocks in no time. An unlocked
-- module can't be required by the game's own scripts any more (opening eggs by hand broke),
-- so every module is locked again as soon as the configs are loaded - the copies we hold
-- keep working. On an executor without UnlockModule, require works as it is.
local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
local unlockedModules = {}
if type(UnlockModule) == "function" then
	for _, inst in ipairs(Shared:GetDescendants()) do
		if inst:IsA("ModuleScript") and pcall(UnlockModule, inst) then table.insert(unlockedModules, inst) end
	end
end
local function config(path)
	local inst = Shared
	for part in path:gmatch("[^%.]+") do inst = inst:WaitForChild(part, 10) end
	return require(inst)
end
local loaded, configs = pcall(function()
	return {
		LaunchEggConfig = config("Pets.LaunchEggConfig"),
		LaunchPetConfig = config("Pets.LaunchPetConfig"),
		HatchRulesConfig = config("Pets.HatchRulesConfig"),
		TapChestConfig = config("Game.TapChestConfig"),
		QuestConfig = config("Quests.QuestConfig"),
		BreakableConfig = config("Game.BreakableConfig"),
		IslandRegions = config("Progression.IslandRegions"),
		IslandConfig = config("Progression.IslandConfig"),
		BoostConfig = config("Items.BoostConfig"),
	}
end)
local relocked = 0
if type(LockModule) == "function" then
	for _, inst in ipairs(unlockedModules) do
		if pcall(LockModule, inst) then relocked += 1 end
	end
end
if not loaded then error("[TapSimXeno] couldn't load the game's configs: " .. tostring(configs), 0) end
local LaunchEggConfig = configs.LaunchEggConfig
local LaunchPetConfig = configs.LaunchPetConfig
local HatchRulesConfig = configs.HatchRulesConfig
local TapChestConfig = configs.TapChestConfig
local QuestConfig = configs.QuestConfig
local BreakableConfig = configs.BreakableConfig
local IslandRegions = configs.IslandRegions
local IslandConfig = configs.IslandConfig
local BoostConfig = configs.BoostConfig

local MIN_INTERVAL = 0.12 -- server tap cap
local HATCH_REACH = 9
local SPAWN = "Spawn"
local HUB_FILE = "TapSimXeno.luau"

local cfg = {
	enabled = false,
	rate = 8,
	autoBreak = false,
	autoHatch = false,
	hatchEgg = nil,
	hatchMode = "Auto",
	hideHatchScreen = false,
	autoDelete = false,
	deleteRarities = {},
	deleteTiers = false,
	autoQuests = false,
	autoChest = false,
	autoIndex = false,
	autoPotions = false,
	potions = {},
}
local stats = {
	accepted = 0,
	earned = 0,
	crits = 0,
	broken = 0,
	hatched = 0,
	hatchSpent = 0,
	quests = 0,
	chests = 0,
	chestCoins = 0,
	potions = 0,
}
-- The server only takes a tap whose ClientSequence is above the last one it took, so the
-- count starts from server time (10 per second, above the ~8/s taps can run at): every new
-- copy - after a reload, a rejoin, or the other hub - starts above whatever came before.
local seq = math.floor(workspace:GetServerTimeNow() * 10)
local alive = true

-- Hatching, chest trips, breaking and teleports all move the character; while one holds it
-- (travelLock > 0) the others wait.
local travelLock = 0
local breakingNow = false -- taps go out while breaking, even with Auto Tap off

-- Islands this account is known to own: Spawn, wherever it stands, and wherever a travel
-- went through. (The account's own list is in its data, which Xeno can't read.)
local knownIslands = { [SPAWN] = true }
local function noteIsland(island)
	if type(island) == "string" and island ~= "" then knownIslands[island] = true end
end
noteIsland(player:GetAttribute("CurrentIsland"))

---------------------------------------------------------------- lifetime

-- One copy at a time: a new copy shuts the old one down (through getgenv on the same
-- executor, through the player mark across executors and against the full hub).
local genv = type(getgenv) == "function" and getgenv() or _G
local STATE = (function(host)
	local cleanups = {}
	local state = {}
	function state.onCleanup(fn) table.insert(cleanups, fn) end
	function state.connect(signal, fn)
		local connection = signal:Connect(fn)
		table.insert(cleanups, function() connection:Disconnect() end)
		return connection
	end
	function state.alive() return alive and (host == nil or host.alive()) end
	function state.shutdown()
		if not alive then return end
		alive = false
		for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
	end
	if host then host.onCleanup(state.shutdown) end
	return state
end)(STATE)
if genv.__TapAC_Shutdown then pcall(genv.__TapAC_Shutdown) end
genv.__TapAC_Shutdown = STATE.shutdown
do
	local token = game:GetService("HttpService"):GenerateGUID(false)
	player:SetAttribute("TapAC_Owner", token)
	STATE.connect(player:GetAttributeChangedSignal("TapAC_Owner"), function()
		if player:GetAttribute("TapAC_Owner") ~= token then STATE.shutdown() end
	end)
end

---------------------------------------------------------------- helpers

local function abbreviate(n)
	local suffixes = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
	local i = 1
	while n >= 1000 and i < #suffixes do
		n /= 1000
		i += 1
	end
	if i == 1 then return tostring(math.floor(n)) end
	return (string.format("%.2f", n):gsub("%.?0+$", "")) .. suffixes[i]
end

-- RequestStreamAroundAsync can hang for good despite its timeout, so it runs on its own
-- thread and we wait at most `seconds` for it.
local function requestStream(position, seconds)
	local done = false
	task.spawn(function()
		pcall(function() player:RequestStreamAroundAsync(position, seconds or 5) end)
		done = true
	end)
	local deadline = os.clock() + (seconds or 5)
	while not done and os.clock() < deadline do task.wait(0.1) end
end

-- A RemoteFunction call with a deadline (a reply that never comes would freeze the caller,
-- and whatever it holds). Returns like pcall: ok, reply - or false, "no reply".
local function invoke(remote, ...)
	local args = table.pack(...)
	local result = nil
	task.spawn(function()
		result = table.pack(pcall(remote.InvokeServer, remote, table.unpack(args, 1, args.n)))
	end)
	local deadline = os.clock() + 10
	while not result and os.clock() < deadline do task.wait() end
	if not result then return false, "no reply" end
	return table.unpack(result, 1, result.n)
end

-- Runs `work` holding the character, and always lets go. Returns like pcall.
local function hop(work)
	travelLock += 1
	local ok, err = pcall(work)
	travelLock -= 1
	return ok, err
end

local function character()
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if root and humanoid and humanoid.Health > 0 then return char, root end
	return nil, nil
end

local function currentIsland()
	local island = player:GetAttribute("CurrentIsland")
	return type(island) == "string" and island or SPAWN
end
STATE.connect(player:GetAttributeChangedSignal("CurrentIsland"), function()
	noteIsland(player:GetAttribute("CurrentIsland"))
end)

-- The game's own travel (puts you on the island's arrival spot). Returns ok, reason.
local function travelTo(island)
	local ok, reply = invoke(Travel, { Island = island, Source = "Menu" })
	if ok and type(reply) == "table" and reply.Success then
		noteIsland(island)
		return true
	end
	local reason = type(reply) == "table" and (reply.Reason or reply.Error) or reply
	return false, tostring(reason or "refused")
end

-- Spawn, then every island in unlock order.
local function worldOrder()
	local islands = {}
	for name, def in pairs(IslandConfig.Islands) do
		table.insert(islands, { name = name, order = def.Order or math.huge })
	end
	table.sort(islands, function(a, b) return a.order < b.order end)
	local names = { SPAWN }
	for _, island in ipairs(islands) do table.insert(names, island.name) end
	return names
end

-- Stands the character on solid ground `distance` studs from `center`, facing it.
local function standNear(center, distance, ignore)
	local char, root = character()
	if not root then return false end
	requestStream(center)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char, ignore }
	local toward = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z)
	local base = toward.Magnitude > 0.1 and toward.Unit or Vector3.new(0, 0, 1)
	for step = 0, 7 do
		local dir = CFrame.Angles(0, math.rad(45 * step), 0):VectorToWorldSpace(base)
		local spot = center + dir * distance
		local hit = workspace:Raycast(Vector3.new(spot.X, center.Y + 15, spot.Z), Vector3.new(0, -40, 0), params)
		if hit and math.abs(hit.Position.Y - center.Y) < 10 then
			local stand = hit.Position + Vector3.new(0, 3, 0)
			root.AssemblyLinearVelocity = Vector3.zero
			char:PivotTo(CFrame.lookAt(stand, Vector3.new(center.X, stand.Y, center.Z)))
			return true
		end
	end
	return false
end

-- Takes the character back to where a trip started (streaming that spot in first, in case
-- the trip went to another island).
local function goBack(returnTo)
	local char, root = character()
	if not (char and returnTo) then return end
	requestStream(returnTo.Position, 3)
	root.AssemblyLinearVelocity = Vector3.zero
	char:PivotTo(returnTo)
end

local function leaderstat(name)
	local folder = player:FindFirstChild("leaderstats")
	local value = folder and folder:FindFirstChild(name)
	return value and value:IsA("ValueBase") and value.Value or nil
end

---------------------------------------------------------------- window

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()

local window = Rayfield:CreateWindow({
	name = "Tap Simulator",
	subtitle = "Xeno Lite",
	theme = "ember",
	sidebarLayout = true,
	-- One settings file per account, so a fresh account starts with everything off.
	configuration = { autoSave = true, autoLoad = true, fileName = "TapSimXeno_" .. player.UserId },
})
STATE.onCleanup(function()
	alive = false
	if not window.unloaded then window:Unload() end
end)

local notifyQueue = {}
local function notify(title, content)
	table.insert(notifyQueue, { title = title, content = content })
end
task.spawn(function()
	while STATE.alive() and alive do
		local item = table.remove(notifyQueue, 1)
		if item then
			pcall(function() window:Notify(item) end)
		else
			task.wait(0.2)
		end
	end
end)

-- Card text, stats and the activity log are painted by one thread of their own (the latest
-- update per card wins), so a feature thread never waits on the window.
local screen = { pending = {}, log = {} }
function screen.route(handle)
	for _, method in ipairs({ "Set", "SetTitle" }) do
		local paint = handle[method]
		if type(paint) == "function" then
			rawset(handle, method, function(self, ...)
				local calls = screen.pending[self] or {}
				screen.pending[self] = calls
				calls[method] = { paint = paint, args = table.pack(...) }
			end)
		end
	end
	return handle
end
task.spawn(function()
	while STATE.alive() and alive do
		task.wait(0.1)
		local pending, lines = screen.pending, screen.log
		screen.pending, screen.log = {}, {}
		for handle, calls in pairs(pending) do
			for _, call in pairs(calls) do pcall(call.paint, handle, table.unpack(call.args, 1, call.args.n)) end
		end
		for _, paint in ipairs(lines) do pcall(paint) end
	end
end)

-- Columns are narrow: no description lines under controls, one-line stats. Every saved
-- setting is recorded with its starting value, for "Reset settings".
local savedSettings = {}
local function lean(group)
	return setmetatable({}, {
		__index = function(_, method)
			local fn = group[method]
			if type(fn) ~= "function" then return fn end
			return function(_, props, ...)
				if type(props) == "table" then
					props.description = nil
					if method == "CreateStat" then props.compact = true end
				end
				local handle = fn(group, props, ...)
				if method == "CreateGroup" then return lean(handle) end
				if (method == "CreateText" or method == "CreateStat") and type(handle) == "table" then
					screen.route(handle)
				end
				if type(props) == "table" and props.flag and handle then
					local default = props.value
					if default == nil and method == "CreateToggle" then default = false end
					if default ~= nil then table.insert(savedSettings, { handle = handle, default = default }) end
				end
				return handle
			end
		end,
	})
end

local function setText(handle, text)
	pcall(function()
		if handle.text ~= text then handle:Set(text) end
	end)
end

local function bigNumber(column, name)
	local handle = column:CreateText({ name = name, text = "0" })
	return { Set = function(_, value) setText(handle, abbreviate(tonumber(value) or 0)) end }
end

local function twoColumns(tab)
	local grid = tab:CreateGroup()
	return lean(grid:CreateGroup({ direction = "column" })), lean(grid:CreateGroup({ direction = "column" }))
end

window:CreateSection({ name = "Main" })
local homeTab = window:CreateTab({ name = "Home" })
window:CreateSection({ name = "Farming" })
local farmTab = window:CreateTab({ name = "Farming" })
local petsTab = window:CreateTab({ name = "Pets" })
local utilsTab = window:CreateTab({ name = "Utils" })
window:CreateSection({ name = "Other" })
local settingsTab = window:CreateTab({ name = "Settings" })

local homeLeft, homeRight = twoColumns(homeTab)
local farmLeft, farmRight = twoColumns(farmTab)
local petsLeft, petsRight = twoColumns(petsTab)
local utilsLeft, utilsRight = twoColumns(utilsTab)
local settingsLeft, settingsRight = twoColumns(settingsTab)

local activityLog = homeTab:CreateConsole({ name = "Activity", height = 170, follow = true, maxLines = 150 })
local function activity(tag, line)
	local text = ("%s  [%s] %s"):format(os.date("%H:%M:%S"), tag, tostring(line))
	table.insert(screen.log, function() activityLog:Append(text) end)
end

-- Runs a feature's loop and starts it again if it ever errors.
local function forever(name, body)
	task.spawn(function()
		while STATE.alive() and alive do
			local ok, err = pcall(body)
			if ok then return end
			warn(("[TapSimXeno] %s stopped: %s"):format(name, tostring(err)))
			activity("Error", ("%s: %s - restarting it"):format(name, tostring(err)))
			task.wait(3)
		end
	end)
end

---------------------------------------------------------------- Home

homeLeft:CreateSection({ name = "Account" })
local rebirthsStat = bigNumber(homeLeft, "Rebirths")
local eggsStat = bigNumber(homeLeft, "Eggs hatched (all time)")
local islandText = homeLeft:CreateText({ name = "Island", text = currentIsland() })

homeRight:CreateSection({ name = "Running" })
local runningText = homeRight:CreateText({ name = "Automations", text = "-" })
homeRight:CreateText({
	name = "Xeno Lite",
	text = "Xeno can't read your account data, so there is no Auto Full, crafting or pet cleanup here. Everything else works from the server's replies.",
})

---------------------------------------------------------------- Farming: tapping + breaking

farmLeft:CreateSection({ name = "Auto Tap" })
local tapToggle = farmLeft:CreateToggle({
	name = "Auto Tap",
	flag = "AutoTap",
	callback = function(v) cfg.enabled = v end,
})
farmLeft:CreateSlider({
	name = "Taps per second",
	range = { 1, 8 },
	increment = 0.5,
	value = 8,
	suffix = " /s",
	flag = "TapRate",
	callback = function(v) cfg.rate = v end,
})
local cpsStat = farmLeft:CreateStat({ name = "Taps / s", value = 0 })
local critStat = farmLeft:CreateStat({ name = "Crits", value = 0 })
local earnedStat = bigNumber(farmLeft, "Coins from taps")

STATE.connect(TapResult.OnClientEvent, function(r)
	if type(r) ~= "table" then return end
	stats.accepted += 1
	if r.Critical then stats.crits += 1 end
	if type(r.Amount) == "number" then stats.earned += r.Amount end
end)

-- Pacing on Heartbeat with a running deadline, so the rate holds steady.
local nextTap = os.clock()
STATE.connect(RunService.Heartbeat, function()
	if not (cfg.enabled or breakingNow) then
		nextTap = os.clock()
		return
	end
	local interval = math.max(1 / cfg.rate, MIN_INTERVAL)
	local now = os.clock()
	if now < nextTap then return end
	nextTap = math.max(nextTap + interval, now - interval) -- no catch-up bursts
	seq += 1
	TapRequested:FireServer({ Auto = false, ClientSequence = seq })
end)

do
-- Breakables (tagged in BreakableConfig): every tap the server accepts hits the nearest one
-- within reach, so breaking one is standing next to it while taps go out. Only ones on
-- islands this account is known to own are visited; one whose health doesn't drop is skipped.

local BREAK_STAND = 6
local BREAK_TARGET_MAX = 15 -- seconds on one breakable per round
local BREAK_ROUND_MAX = 30 -- seconds a whole round may hold the character
local BREAK_REST_AFTER_LONG = 20
local attrs = BreakableConfig.Attributes

farmRight:CreateSection({ name = "Auto Break" })
farmRight:CreateToggle({
	name = "Auto Break Chests",
	flag = "AutoBreak",
	callback = function(v) cfg.autoBreak = v end,
})
local brokenStat = farmRight:CreateStat({ name = "Broken", value = 0 })

STATE.connect(BreakableRewarded.OnClientEvent, function()
	stats.broken += 1
end)

local function breakableAlive(model)
	return model.Parent ~= nil and (model:GetAttribute(attrs.Health) or 0) > 0
		and not model:GetAttribute(attrs.Broken) and not model:GetAttribute(attrs.Despawned)
end

local function targets()
	local list = {}
	local here = currentIsland()
	for _, model in ipairs(CollectionService:GetTagged(BreakableConfig.Tag)) do
		local rest = model:GetAttribute(attrs.Rest)
		local owner = model:GetAttribute(attrs.Owner)
		if typeof(rest) == "CFrame" and model:IsDescendantOf(workspace) and breakableAlive(model)
			and (owner == nil or owner == player.UserId) then
			local ok, island = pcall(IslandRegions.Resolve, rest.Position)
			island = ok and island or nil
			if island == nil or island == here or knownIslands[island] then
				table.insert(list, { model = model, rest = rest })
			end
		end
	end
	return list
end

local function breakRound()
	if travelLock > 0 then return end
	local char, root = character()
	if not root then return end
	if #targets() == 0 then return end
	local returnTo = char:GetPivot()
	hop(function()
		local skipped = {}
		local roundEnds = os.clock() + BREAK_ROUND_MAX
		while cfg.autoBreak and STATE.alive() and os.clock() < roundEnds do
			local nearest, nearestDist = nil, math.huge
			for _, target in ipairs(targets()) do
				if not skipped[target.model] then
					local dist = (root.Position - target.rest.Position).Magnitude
					if dist < nearestDist then nearest, nearestDist = target, dist end
				end
			end
			if not nearest then break end

			local size = nearest.model:GetAttribute(attrs.Size)
			local reach = (typeof(size) == "Vector3" and math.max(size.X, size.Z) * 0.5 or 2) + BREAK_STAND
			if standNear(nearest.rest.Position, reach, nearest.model) then
				breakingNow = true
				local lastHealth = nearest.model:GetAttribute(attrs.Health)
				local lastProgress = os.clock()
				local targetEnds = math.min(os.clock() + BREAK_TARGET_MAX, roundEnds)
				while breakableAlive(nearest.model) and cfg.autoBreak and os.clock() - lastProgress < 3
					and os.clock() < targetEnds do
					-- Island breakables roam a few studs at a time: follow the current spot.
					local rest = nearest.model:GetAttribute(attrs.Rest)
					if typeof(rest) == "CFrame" and typeof(size) == "Vector3"
						and not BreakableConfig.InRange(root.Position, rest, size) then
						nearest.rest = rest
						standNear(rest.Position, reach, nearest.model)
					end
					local health = nearest.model:GetAttribute(attrs.Health)
					if health ~= lastHealth then lastHealth, lastProgress = health, os.clock() end
					task.wait(0.1)
				end
				breakingNow = false
			end
			if breakableAlive(nearest.model) then skipped[nearest.model] = true end
			task.wait(0.15)
		end
		breakingNow = false
		goBack(returnTo)
	end)
	breakingNow = false
end

forever("Auto Break", function()
	local nextRound = 0
	while STATE.alive() and alive do
		task.wait(1)
		if cfg.autoBreak and os.clock() >= nextRound then
			local started = os.clock()
			breakRound()
			if os.clock() - started > 10 then nextRound = os.clock() + BREAK_REST_AFTER_LONG end
		end
		brokenStat:Set(stats.broken)
	end
end)
end

---------------------------------------------------------------- Pets: hatching

do
-- Eggs come from two places: the config copy (with price and island - though the game may
-- fill parts of that table in while it runs, which a copy never sees) and the map
-- (workspace.Eggs, only what's streamed in around you; its island is worked out from where
-- it stands). The list grows as more eggs load in, e.g. after a teleport. Which eggs this
-- account owns is in its data, so a locked egg just gets the server's no, shown in Status.
-- Every config egg names a Zone; eggs in the Forest and Winter zones are left out (those
-- zones can't be unlocked any more), and so is the developers' Test egg.
local DEAD_ZONES = { Forest = true, Winter = true }
local skipEggs = { Test = true }
for name, def in pairs(LaunchEggConfig) do
	if type(def) == "table" and DEAD_ZONES[def.Zone] then skipEggs[name] = true end
end
local eggInfo = {} -- name -> { price = number?, island = string?, pets = table? }
local function addEgg(name, price, island, pets)
	local info = eggInfo[name]
	if not info then
		info = {}
		eggInfo[name] = info
	end
	if type(price) == "number" and price > 0 then info.price = price end
	if type(island) == "string" and info.island == nil then info.island = island end
	if type(pets) == "table" and info.pets == nil then info.pets = pets end
end
local configEggs = 0
for name, def in pairs(LaunchEggConfig) do
	if type(name) == "string" and type(def) == "table" and not skipEggs[name]
		and type(def.Price) == "number" and def.Price > 0 then
		configEggs += 1
		addEgg(name, def.Price, def.Island or SPAWN, def.Pets)
	end
end
local function scanMapEggs()
	local folder = workspace:FindFirstChild("Eggs")
	if not folder then return end
	for _, model in ipairs(folder:GetChildren()) do
		if not skipEggs[model.Name] and (not eggInfo[model.Name] or eggInfo[model.Name].island == nil) then
			local okPivot, pivot = pcall(model.GetPivot, model)
			local okIsland, island = false, nil
			if okPivot then okIsland, island = pcall(IslandRegions.Resolve, pivot.Position) end
			addEgg(model.Name, nil, okIsland and island or nil, nil)
		end
	end
end
scanMapEggs()

local eggLabelToName = {}
local function eggList()
	local list = {}
	for name, info in pairs(eggInfo) do table.insert(list, { name = name, price = info.price }) end
	table.sort(list, function(a, b)
		if (a.price ~= nil) ~= (b.price ~= nil) then return a.price ~= nil end
		if a.price and b.price and a.price ~= b.price then return a.price < b.price end
		return a.name < b.name
	end)
	table.clear(eggLabelToName)
	local options = {}
	for _, egg in ipairs(list) do
		local label = egg.price and ("%s - %s"):format(egg.name, abbreviate(egg.price)) or egg.name
		eggLabelToName[label] = egg.name
		table.insert(options, label)
	end
	return options, list
end
local eggOptions, eggsSorted = eggList()
cfg.hatchEgg = eggsSorted[1] and eggsSorted[1].name

-- What this run could see, for troubleshooting: TapSimXeno_debug.txt in the workspace folder.
do
	local lines = {
		"executor: " .. (type(identifyexecutor) == "function" and tostring((identifyexecutor())) or "?"),
		("modules unlocked %d, locked again %d"):format(#unlockedModules, relocked),
	}
	local keys = 0
	for key, value in pairs(LaunchEggConfig) do
		keys += 1
		if type(value) == "table" then
			table.insert(lines, ("  %s: zone %s, island %s, price %s%s"):format(tostring(key), tostring(value.Zone),
				tostring(value.Island), tostring(value.Price), skipEggs[key] and " (left out)" or ""))
		end
	end
	table.insert(lines, 2, ("LaunchEggConfig: %d keys, %d eggs used; eggs listed: %d"):format(keys, configEggs, #eggOptions))
	local onMap = {}
	local folder = workspace:FindFirstChild("Eggs")
	for _, model in ipairs(folder and folder:GetChildren() or {}) do table.insert(onMap, model.Name) end
	table.insert(lines, "on the map: " .. table.concat(onMap, ", "))
	pcall(writefile, "TapSimXeno_debug.txt", table.concat(lines, "\n"))
	activity("Hub", ("Eggs: %d from the config, %d listed (more appear as islands load)"):format(configEggs, #eggOptions))
end

-- Count: 8 needs the x8 pass, 3 needs the coins for 3. Auto starts at 8 and steps down
-- each time the server says no; once a minute it tries one step up again.
local COUNTS = { 8, 3, 1 }
local MODES = { "Auto (8 / 3 / 1)", "3 at a time", "1 at a time" }
local MODE_START = { [MODES[1]] = 1, [MODES[2]] = 2, [MODES[3]] = 3 }
cfg.hatchMode = MODES[1]

local eggTab = petsLeft
eggTab:CreateSection({ name = "Auto Hatch" })
eggTab:CreateToggle({
	name = "Auto Hatch",
	flag = "AutoHatch",
	callback = function(v) cfg.autoHatch = v end,
})
-- (A saved choice may come back before its egg is listed, or with the price missing from
-- its label: the egg name is the label up to " - ".)
local eggDropdown = eggTab:CreateDropdown({
	name = "Egg",
	options = eggOptions,
	value = eggOptions[1],
	flag = "HatchEgg",
	callback = function(choice)
		if type(choice) == "string" and choice ~= "" then
			cfg.hatchEgg = eggLabelToName[choice] or choice:match("^(.-) %- ") or choice
		end
	end,
})

-- New eggs streamed in (after a teleport, or walking around) join the list.
task.spawn(function()
	local known = #eggOptions
	while STATE.alive() and alive do
		task.wait(3)
		scanMapEggs()
		local options = eggList()
		if #options ~= known then
			known = #options
			pcall(function() eggDropdown:Refresh(options) end)
		end
	end
end)
eggTab:CreateDropdown({
	name = "How many",
	options = MODES,
	value = MODES[1],
	flag = "HatchMode",
	callback = function(choice)
		if type(choice) == "string" and MODE_START[choice] then cfg.hatchMode = choice end
	end,
})
-- (Experimental) The game's own hatch module can't be reached from Xeno, so this hides
-- the hatch screens instead of skipping the animation - and only while Auto Hatch runs, so
-- the egg menus are all there again the moment it stops (hatching by hand is never touched).
local HATCH_GUIS = { "HatchScreen", "Hatching", "Egg Opening Stuff" }
local hiddenGuis = {}
local function showHatchGuis()
	for gui in pairs(hiddenGuis) do pcall(function() gui.Enabled = true end) end
	table.clear(hiddenGuis)
end
eggTab:CreateToggle({
	name = "Hide hatch screen (beta)",
	flag = "HideHatchScreen",
	callback = function(v) cfg.hideHatchScreen = v end,
})
STATE.onCleanup(showHatchGuis)
task.spawn(function()
	while STATE.alive() and alive do
		task.wait(0.25)
		if cfg.hideHatchScreen and cfg.autoHatch then
			for _, name in ipairs(HATCH_GUIS) do
				local gui = player.PlayerGui:FindFirstChild(name)
				if gui and gui:IsA("ScreenGui") and gui.Enabled then
					hiddenGuis[gui] = true
					gui.Enabled = false
				end
			end
		elseif next(hiddenGuis) then
			showHatchGuis()
		end
	end
end)

local hatchStatus = eggTab:CreateText({ name = "Status", text = "Idle" })
local hatchedStat = eggTab:CreateStat({ name = "Hatched", value = 0 })
local spentStat = bigNumber(eggTab, "Coins spent")

-- Hatch requests carry a Seq only to match their reply. It has to stay small: a Seq past
-- 32 bits comes back as nil and the reply can't be matched.
local hatchSeq = 7000000 + math.random(0, 1000000)
local waitingSeq, hatchReply = nil, nil
STATE.connect(EggHatchResult.OnClientEvent, function(r)
	if type(r) == "table" and waitingSeq ~= nil and r.Seq == waitingSeq then hatchReply = r end
end)

local countIndex, mode, stepUpAt = 1, nil, 0

local function eggModel(egg)
	local folder = workspace:FindFirstChild("Eggs")
	return folder and folder:FindFirstChild(egg)
end

-- Far eggs aren't streamed in until you're near them: travel to the egg's island first
-- (also when already on it - the arrival spot is where its eggs are).
local function fetchEgg(egg)
	local info = eggInfo[egg]
	local island = info and info.island or SPAWN
	setText(hatchStatus, ("Going to %s for the %s egg"):format(island, egg))
	local ok, reason = travelTo(island)
	if not ok and currentIsland() ~= island then
		return nil, ("Can't go to %s (%s) - is it unlocked?"):format(island, reason)
	end
	local folder = workspace:WaitForChild("Eggs", 8)
	local model = folder and folder:WaitForChild(egg, 8)
	return model, model == nil and (egg .. " egg didn't load") or nil
end

local function hatchOnce(egg)
	if travelLock > 0 then
		setText(hatchStatus, "Paused while another trip holds the character")
		return 0.5
	end
	local _, root = character()
	if not root then return 1 end

	local model = eggModel(egg)
	if not model then
		local why
		hop(function() model, why = fetchEgg(egg) end)
		if not model then
			setText(hatchStatus, why or "Egg not found")
			return 10
		end
	end
	if (root.Position - model:GetPivot().Position).Magnitude > HATCH_REACH then
		if not standNear(model:GetPivot().Position, 7, model) then
			setText(hatchStatus, "Couldn't find ground next to the egg")
			return 3
		end
		task.wait(0.5) -- let the server see the new position
	end

	-- Mode changed, or a minute at a lower count: try one step up again.
	local start = MODE_START[cfg.hatchMode] or 1
	if mode ~= cfg.hatchMode then
		mode, countIndex = cfg.hatchMode, start
	elseif countIndex > start and os.clock() >= stepUpAt then
		countIndex -= 1
	end
	local count = COUNTS[countIndex]

	hatchSeq += 1
	waitingSeq, hatchReply = hatchSeq, nil
	setText(hatchStatus, ("Hatching %dx %s"):format(count, egg))
	EggHatchRequested:FireServer({ Egg = egg, Count = count, Auto = false, Seq = hatchSeq })
	local deadline = os.clock() + 10
	while hatchReply == nil and os.clock() < deadline and STATE.alive() do task.wait(0.05) end
	local reply = hatchReply
	waitingSeq, hatchReply = nil, nil
	if not reply then return 1 end

	if reply.Success then
		local pets = type(reply.Pets) == "table" and reply.Pets or {}
		stats.hatched += #pets
		if type(reply.Spent) == "number" then stats.hatchSpent += reply.Spent end
		local names = {}
		for _, pet in ipairs(pets) do
			table.insert(names, ("%s (%s)%s"):format(tostring(pet.Name), tostring(pet.Rarity), pet.AutoDeleted and " [deleted]" or ""))
		end
		activity("Egg", ("%dx %s: %s"):format(#pets, egg, table.concat(names, ", ")))
		return 0
	end
	if reply.Error == "TooFar" then
		standNear(model:GetPivot().Position, 7, model)
		return 0.5
	end
	local reason = tostring(reply.Error or reply.Reason or "no")
	if countIndex < #COUNTS then
		-- Can't do this many (no pass / not enough coins for it): one step down, right away.
		countIndex += 1
		stepUpAt = os.clock() + 60
		return 0
	end
	setText(hatchStatus, ("Server said: %s (%s)"):format(reason, egg))
	return 2
end

forever("Auto Hatch", function()
	while STATE.alive() and alive do
		local pause = 0.25
		if cfg.autoHatch and cfg.hatchEgg then
			pause = hatchOnce(cfg.hatchEgg)
		elseif not cfg.autoHatch then
			setText(hatchStatus, "Idle")
		end
		hatchedStat:Set(stats.hatched)
		spentStat:Set(stats.hatchSpent)
		task.wait(pause)
	end
end)

-- Auto-delete at hatch: the game's own per-egg list, set from the rarities picked here.
-- The account's current list can't be read, so this list replaces it for the egg being
-- hatched. Secret pets are never on it.
local SECRET_RANK = HatchRulesConfig.RarityRank["Secret I"] or 6
local TIERS = { "Normal", "Golden", "Diamond", "Shiny" }
local rarities = {}
for rarity, rank in pairs(HatchRulesConfig.RarityRank) do
	if type(rank) == "number" and rank < SECRET_RANK then table.insert(rarities, { name = rarity, rank = rank }) end
end
table.sort(rarities, function(a, b) return a.rank < b.rank end)
local rarityOptions = {}
for _, r in ipairs(rarities) do table.insert(rarityOptions, r.name) end

local deleteTab = petsRight
deleteTab:CreateSection({ name = "Auto-delete at hatch" })
deleteTab:CreateToggle({
	name = "Auto-delete",
	flag = "AutoDelete",
	callback = function(v) cfg.autoDelete = v end,
})
deleteTab:CreateDropdown({
	name = "Rarities to delete",
	multiSelect = true,
	options = rarityOptions,
	value = {},
	placeholder = "Pick rarities",
	flag = "DeleteRarities",
	callback = function(selected)
		cfg.deleteRarities = type(selected) == "table" and selected or {}
	end,
})
deleteTab:CreateToggle({
	name = "Golden and up too",
	flag = "DeleteTiers",
	callback = function(v) cfg.deleteTiers = v end,
})
local deleteText = deleteTab:CreateText({ name = "Hatch egg list", text = "Off" })

-- nil when the egg's pets aren't known (an egg only seen on the map): then nothing is sent,
-- so the egg's list in the game stays as it is.
local function deleteEntries(egg)
	local info = eggInfo[egg]
	if not (info and type(info.pets) == "table") then return nil, nil end
	local entries, names = {}, {}
	local wanted = {}
	for _, rarity in ipairs(cfg.deleteRarities) do wanted[rarity] = true end
	for name in pairs(info.pets) do
		local pet = LaunchPetConfig[name]
		if pet and wanted[pet.Rarity] then
			table.insert(names, name)
			for _, tier in ipairs(cfg.deleteTiers and TIERS or { "Normal" }) do
				table.insert(entries, HatchRulesConfig.AutoDeleteKey(name, tier))
			end
		end
	end
	table.sort(names)
	return entries, names
end

-- Sends the list whenever the egg or the picks change (and again every 10 minutes, in case
-- it was changed in the game's own menu).
forever("Auto-delete", function()
	local sent, sentAt = nil, 0
	while STATE.alive() and alive do
		task.wait(1)
		local egg = cfg.hatchEgg
		local entries, names = nil, nil
		if cfg.autoDelete and egg then entries, names = deleteEntries(egg) end
		if cfg.autoDelete and egg and not entries then
			setText(deleteText, egg .. ": its pets aren't known here, the game's own list stays")
		elseif cfg.autoDelete and egg then
			local signature = egg .. "|" .. table.concat(entries, ",")
			if signature ~= sent or os.clock() - sentAt > 600 then
				AutoDeleteRequested:FireServer({ Egg = egg, Entries = entries })
				if signature ~= sent then
					activity("Auto-delete", ("%s egg: %s"):format(egg, #names > 0 and table.concat(names, ", ") or "nothing"))
				end
				sent, sentAt = signature, os.clock()
			end
			setText(deleteText, ("%s: %s"):format(egg, #names > 0 and table.concat(names, ", ") or "nothing picked"))
		else
			setText(deleteText, "Off")
		end
	end
end)
end

---------------------------------------------------------------- Utils: quests

do
-- Every quest in the config is tried in turn; the server only pays finished ones. Its
-- replies steer the retries: AlreadyClaimed rests the quest for 30 minutes, Cooldown means
-- "too fast" (pause a few seconds), anything else (not finished) retries in a minute.
local questIds = {}
for id, def in pairs(QuestConfig.Definitions) do
	if type(def) == "table" and def.AutoClaim ~= true then table.insert(questIds, id) end
end
table.sort(questIds)
local questRetry = {}

utilsLeft:CreateSection({ name = "Quests" })
utilsLeft:CreateToggle({
	name = "Auto Claim Quests",
	flag = "AutoQuests",
	callback = function(v) cfg.autoQuests = v end,
})
local questsStat = utilsLeft:CreateStat({ name = "Claimed", value = 0 })

forever("Quests", function()
	local i = 0
	while STATE.alive() and alive do
		task.wait(1.2)
		if cfg.autoQuests and #questIds > 0 then
			-- Next quest that is due.
			local id = nil
			for _ = 1, #questIds do
				i = i % #questIds + 1
				if os.clock() >= (questRetry[questIds[i]] or 0) then
					id = questIds[i]
					break
				end
			end
			if id then
				local ok, res = invoke(ClaimQuest, { Quest = id })
				if ok and type(res) == "table" and res.Success then
					stats.quests += 1
					local def = QuestConfig.Definitions[id]
					activity("Quest", "Claimed: " .. tostring(def and def.Description or id))
					questRetry[id] = os.clock() + 30
				elseif ok and type(res) == "table" and res.Error == "AlreadyClaimed" then
					questRetry[id] = os.clock() + 1800
				elseif ok and type(res) == "table" and res.Error == "Cooldown" then
					questRetry[id] = os.clock() + 3
					task.wait(3)
				else
					questRetry[id] = os.clock() + 60
				end
			end
		end
		questsStat:Set(stats.quests)
	end
end)
end

---------------------------------------------------------------- Utils: Tap Chests

do
-- One Tap Chest per island, a few hours' cooldown. When it's ready is in the account's data,
-- so each chest is visited in turn: travel to its island, step in front, claim, come back.
-- A claim pays out (next try after the cooldown) or the chest's own countdown is read off
-- its sign; failing that it's tried again in 20 minutes. Locked islands rest for 30.
local CHEST_COOLDOWN = (type(TapChestConfig.Cooldown) == "number" and TapChestConfig.Cooldown) or 6 * 3600
local chestIds = {}
for id in pairs(TapChestConfig.Chests) do table.insert(chestIds, id) end
table.sort(chestIds)
local chestNext = {}
local chestNote = {}

utilsLeft:CreateSection({ name = "Tap Chests" })
utilsLeft:CreateToggle({
	name = "Auto Chest",
	flag = "AutoChest",
	callback = function(v) cfg.autoChest = v end,
})
local chestsStat = utilsLeft:CreateStat({ name = "Opened", value = 0 })
local chestCoinsStat = bigNumber(utilsLeft, "Coins from chests")
local chestText = utilsLeft:CreateText({ name = "Chests", text = "-" })

local function chestModel(id)
	for _, model in ipairs(CollectionService:GetTagged(TapChestConfig.Tag)) do
		if model:GetAttribute(TapChestConfig.Attributes.Id) == id and model:IsDescendantOf(workspace) then
			return model
		end
	end
	return nil
end

-- Seconds in a countdown text ("1:23:45", "23:45", "1h 2m", "5m 3s"), or nil. Anything
-- outside (0, cooldown] is taken as a misread.
local function secondsIn(text)
	local left
	local h, m, s = text:match("(%d+):(%d%d):(%d%d)")
	if h then
		left = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
	else
		m, s = text:match("(%d+):(%d%d)")
		if m then
			left = tonumber(m) * 60 + tonumber(s)
		else
			local hours, minutes, seconds = text:match("(%d+)h"), text:match("(%d+)m"), text:match("(%d+)s")
			if hours or minutes or seconds then
				left = (tonumber(hours) or 0) * 3600 + (tonumber(minutes) or 0) * 60 + (tonumber(seconds) or 0)
			end
		end
	end
	if left and left > 0 and left <= CHEST_COOLDOWN then return left end
	return nil
end

-- The countdown from the server's refusal, else from the chest's own sign.
local function countdownOf(model, reason)
	local left = secondsIn(reason)
	if left then return left end
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("TextLabel") and inst.Text ~= "" then
			left = secondsIn(inst.Text)
			if left then return left end
		end
	end
	return nil
end

local function visitChest(id)
	local _, root = character()
	if not root or travelLock > 0 then return end
	local chest = TapChestConfig.Chests[id]
	local island = chest and chest.Island or SPAWN
	hop(function()
		local char = player.Character
		local returnTo = char:GetPivot()
		local model = chestModel(id)
		if not model then
			-- Not streamed in: travel to its island (or its arrival spot, if already on it).
			local ok, reason = travelTo(island)
			if not ok and currentIsland() ~= island then
				chestNext[id] = os.clock() + 1800
				chestNote[id] = "island locked?"
				activity("Chest", ("%s: can't go to %s (%s), trying again in 30 min"):format(id, island, reason))
				return
			end
		end
		local deadline = os.clock() + 6
		while not model and os.clock() < deadline do
			task.wait(0.2)
			model = chestModel(id)
		end
		local front = model and model:GetAttribute(TapChestConfig.Attributes.Front)
		local size = model and model:GetAttribute(TapChestConfig.Attributes.Size)
		if not (typeof(front) == "CFrame" and typeof(size) == "Vector3") then
			chestNext[id] = os.clock() + 300
			chestNote[id] = "didn't load"
			goBack(returnTo)
			return
		end
		local spot = front.Position + front.LookVector * (size.Z * 0.5 + 6) + Vector3.new(0, 3, 0)
		root.AssemblyLinearVelocity = Vector3.zero
		char:PivotTo(CFrame.lookAt(spot, Vector3.new(front.Position.X, spot.Y, front.Position.Z)))
		task.wait(0.6) -- let the server see the new position
		local ok, res = invoke(ClaimChest, id)
		if ok and type(res) == "table" and res.Success then
			stats.chests += 1
			if type(res.Coins) == "number" then stats.chestCoins += res.Coins end
			activity("Chest", ("Opened %s chest for %s coins"):format(id, abbreviate(res.Coins or 0)))
			chestNext[id] = os.clock() + CHEST_COOLDOWN
			chestNote[id] = "opened"
		else
			local reason = type(res) == "table" and tostring(res.Reason or res.Error or "no") or tostring(res)
			if reason:find("Slow down", 1, true) then
				chestNext[id] = os.clock() + 5
			elseif reason:find("closer", 1, true) then
				chestNext[id] = os.clock() + 60
				chestNote[id] = "couldn't get close"
			else
				local left = countdownOf(model, reason)
				chestNext[id] = os.clock() + (left and left + 5 or 1200)
				chestNote[id] = left and "cooldown" or reason
			end
		end
		task.wait(0.3)
		goBack(returnTo)
	end)
end

forever("Tap Chests", function()
	while STATE.alive() and alive do
		task.wait(2)
		if cfg.autoChest then
			for _, id in ipairs(chestIds) do
				if os.clock() >= (chestNext[id] or 0) and travelLock == 0 then
					visitChest(id)
					task.wait(0.5)
				end
			end
		end
		local lines = {}
		for _, id in ipairs(chestIds) do
			local wait = (chestNext[id] or 0) - os.clock()
			local when = chestNext[id] == nil and "not tried yet"
				or wait <= 0 and "due"
				or ("next try in %dm"):format(math.ceil(wait / 60))
			table.insert(lines, ("%s: %s%s"):format(id, when, chestNote[id] and (" (" .. chestNote[id] .. ")") or ""))
		end
		setText(chestText, table.concat(lines, "\n"))
		chestsStat:Set(stats.chests)
		chestCoinsStat:Set(stats.chestCoins)
	end
end)
end

---------------------------------------------------------------- Utils: index + potions

do
utilsRight:CreateSection({ name = "Rewards" })
utilsRight:CreateToggle({
	name = "Auto claim index rewards",
	flag = "AutoIndex",
	callback = function(v) cfg.autoIndex = v end,
})

-- Potions: a picked potion is drunk, then again once it has run out (its duration from the
-- config). A no from the server (none left) rests that potion for 5 minutes.
local potionNames = {}
for name, def in pairs(BoostConfig.Definitions) do
	if type(def) == "table" and type(def.Duration) == "number" then table.insert(potionNames, name) end
end
table.sort(potionNames)
utilsRight:CreateToggle({
	name = "Auto potions",
	flag = "AutoPotions",
	callback = function(v) cfg.autoPotions = v end,
})
utilsRight:CreateDropdown({
	name = "Potions",
	multiSelect = true,
	options = potionNames,
	value = {},
	placeholder = "Pick potions",
	flag = "Potions",
	callback = function(selected)
		cfg.potions = type(selected) == "table" and selected or {}
	end,
})
local potionsStat = utilsRight:CreateStat({ name = "Potions used", value = 0 })

local potionNext = {}
forever("Rewards", function()
	local indexAt = 0
	while STATE.alive() and alive do
		task.wait(5)
		if cfg.autoIndex and os.clock() >= indexAt then
			indexAt = os.clock() + 120
			ClaimIndex:FireServer()
		end
		if cfg.autoPotions then
			for _, name in ipairs(cfg.potions) do
				if os.clock() >= (potionNext[name] or 0) then
					local ok, res = invoke(UseBoost, name)
					if ok and type(res) == "table" and res.Success then
						stats.potions += 1
						local def = BoostConfig.Definitions[name]
						potionNext[name] = os.clock() + math.max((def and def.Duration or 600) - 5, 30)
						activity("Potion", "Drank " .. name)
					else
						potionNext[name] = os.clock() + 300
					end
					task.wait(0.5)
				end
			end
		end
		potionsStat:Set(stats.potions)
	end
end)
end

---------------------------------------------------------------- Utils: teleport

do
utilsRight:CreateSection({ name = "Teleport" })
local teleportText = utilsRight:CreateText({ name = "Teleport", text = "-" })
local buttons = utilsRight:CreateGroup()
for _, island in ipairs(worldOrder()) do
	buttons:CreateButton({
		name = island,
		callback = function()
			task.spawn(function()
				if travelLock > 0 then
					notify("Teleport", "Busy with another trip, try again in a second.")
					return
				end
				hop(function()
					local ok, reason = travelTo(island)
					setText(teleportText, ok and ("On " .. island) or ("%s: %s"):format(island, reason))
				end)
			end)
		end,
	})
end
end

---------------------------------------------------------------- Settings

settingsLeft:CreateSection({ name = "General" })
-- Xeno's getconnections is a stub, so the idle kick is answered with a virtual click.
local antiAfkOn = false
STATE.connect(player.Idled, function()
	if not antiAfkOn then return end
	pcall(function()
		local VirtualUser = game:GetService("VirtualUser")
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.zero)
	end)
end)
settingsLeft:CreateToggle({
	name = "Anti-AFK",
	value = true,
	flag = "AntiAFK",
	callback = function(v) antiAfkOn = v end,
})

-- Reset settings: two clicks within 5 seconds; the reset runs on the script's own thread.
do
	local armedUntil, requested = 0, false
	settingsLeft:CreateButton({
		name = "Reset settings",
		callback = function()
			if os.clock() <= armedUntil then
				armedUntil, requested = 0, true
			else
				armedUntil = os.clock() + 5
				notify("Reset settings", "Click again within 5 seconds to turn everything off.")
			end
		end,
	})
	task.spawn(function()
		while STATE.alive() and alive do
			task.wait(0.2)
			if requested then
				requested = false
				local count = 0
				for _, entry in ipairs(savedSettings) do
					if pcall(function() entry.handle:Set(entry.default) end) then count += 1 end
				end
				activity("Settings", ("Reset %d settings to defaults"):format(count))
				notify("Reset settings", "Everything is back to defaults (automations off).")
			end
		end
	end)
end

settingsTab:CreateKeybind({
	name = "Auto Tap key",
	value = Enum.KeyCode.F,
	flag = "ToggleKey",
	callback = function() tapToggle:Set(not tapToggle.value) end,
})

do
-- PC load and staying online. Everything is undone when switched off or when the hub stops.
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")
local card = settingsRight
card:CreateSection({ name = "Performance" })

card:CreateToggle({
	name = "No 3D render",
	flag = "No3DRendering",
	callback = function(v) pcall(function() RunService:Set3dRenderingEnabled(not v) end) end,
})
STATE.onCleanup(function() pcall(function() RunService:Set3dRenderingEnabled(true) end) end)

-- Taps go out at most once a frame, so the cap starts at 15.
local MIN_FPS = 15
local okCap, originalCap = false, nil
if type(getfpscap) == "function" then okCap, originalCap = pcall(getfpscap) end
if not okCap or type(originalCap) ~= "number" or originalCap <= 0 then originalCap = 60 end
local capOn, capValue = false, 30
local function setCap(fps)
	if type(setfpscap) == "function" then pcall(setfpscap, fps) end
end
local function applyCap() setCap(capOn and capValue or originalCap) end
card:CreateToggle({
	name = "Limit FPS",
	flag = "LimitFps",
	callback = function(v)
		capOn = v
		applyCap()
	end,
})
card:CreateSlider({
	name = "FPS limit",
	range = { MIN_FPS, 240 },
	increment = 5,
	value = 30,
	suffix = " fps",
	flag = "FpsLimit",
	callback = function(v)
		capValue = math.max(v, MIN_FPS)
		applyCap()
	end,
})
STATE.onCleanup(function() setCap(originalCap) end)

-- FPS boost: particles, trails, beams, smoke/fire/sparkles and post effects off, shadows off.
-- Originals are remembered per instance and put back on switch-off; entries for effects
-- that left the game are swept out every 30 seconds.
local boosted = {}
task.spawn(function()
	while STATE.alive() and alive do
		task.wait(30)
		for inst in pairs(boosted) do
			if not inst:IsDescendantOf(game) then boosted[inst] = nil end
		end
	end
end)
local boostConnection, boostOn = nil, false
local function remember(inst, prop, value)
	local saved = boosted[inst]
	if not saved then
		saved = {}
		boosted[inst] = saved
	end
	if saved[prop] == nil then saved[prop] = inst[prop] end
	inst[prop] = value
end
local function boostInstance(inst)
	pcall(function()
		if inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam") or inst:IsA("Smoke")
			or inst:IsA("Fire") or inst:IsA("Sparkles") or inst:IsA("PostEffect") then
			if inst.Enabled then remember(inst, "Enabled", false) end
		elseif inst:IsA("BasePart") and inst.CastShadow then
			remember(inst, "CastShadow", false)
		end
	end)
end
local function setBoost(on)
	if on == boostOn then return end
	boostOn = on
	if on then
		pcall(function() remember(Lighting, "GlobalShadows", false) end)
		pcall(function() remember(workspace.Terrain, "Decoration", false) end)
		pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
		task.spawn(function()
			for _, root in ipairs({ Lighting, workspace }) do
				for i, inst in ipairs(root:GetDescendants()) do
					if not boostOn then return end
					boostInstance(inst)
					if i % 3000 == 0 then task.wait() end
				end
			end
		end)
		boostConnection = workspace.DescendantAdded:Connect(function(inst)
			if boostOn then boostInstance(inst) end
		end)
	else
		if boostConnection then
			boostConnection:Disconnect()
			boostConnection = nil
		end
		for inst, saved in pairs(boosted) do
			for prop, value in pairs(saved) do pcall(function() inst[prop] = value end) end
		end
		table.clear(boosted)
	end
end
card:CreateToggle({
	name = "FPS Boost",
	flag = "FpsBoost",
	callback = function(v) setBoost(v) end,
})
STATE.onCleanup(function() setBoost(false) end)

-- Auto reconnect: rejoins on a kick or disconnect, and queues this hub to load again in
-- the new server from its copy in the workspace folder.
card:CreateSection({ name = "Connection" })
local queueOnTeleport = (type(queue_on_teleport) == "function" and queue_on_teleport)
	or (type(queueonteleport) == "function" and queueonteleport) or nil
local reconnectOn, rejoining, rejoinReason = false, false, nil

local function queueHub()
	if not (queueOnTeleport and type(isfile) == "function" and type(readfile) == "function") then return false end
	local ok, exists = pcall(isfile, HUB_FILE)
	if not (ok and exists) then return false end
	-- Shares the autoexec loaders' flag (an attribute both executors see).
	local loader = ([[
if not game:IsLoaded() then game.Loaded:Wait() end
local Players = game:GetService("Players")
local player = Players.LocalPlayer or Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
if player:GetAttribute("TapAC_Loading") then return end
player:SetAttribute("TapAC_Loading", true)
game:GetService("ReplicatedStorage"):WaitForChild("RemoteServices", 120)
task.wait(8)
loadstring(readfile(%q))()
]]):format(HUB_FILE)
	return (pcall(queueOnTeleport, loader))
end

local function rejoin(reason) rejoinReason = rejoinReason or reason end
task.spawn(function()
	while STATE.alive() and not rejoinReason do task.wait(0.25) end
	if not STATE.alive() then return end
	rejoining = true
	local queued = queueHub()
	activity("Reconnect", ("%s - rejoining%s"):format(rejoinReason, queued and ", hub will reload" or ""))
	while STATE.alive() do
		pcall(function() TeleportService:Teleport(game.PlaceId, player) end)
		task.wait(10)
	end
end)

card:CreateToggle({
	name = "Auto reconnect",
	flag = "AutoReconnect",
	callback = function(v) reconnectOn = v end,
})
card:CreateButton({
	name = "Rejoin now",
	callback = function() rejoin("Rejoin pressed") end,
})
STATE.connect(GuiService.ErrorMessageChanged, function(message)
	if reconnectOn and not rejoining and type(message) == "string" and message ~= "" then
		rejoin("Disconnected: " .. message)
	end
end)
end

---------------------------------------------------------------- stats refresh

forever("Stats", function()
	local lastAccepted, lastT = 0, os.clock()
	while STATE.alive() and alive do
		task.wait(1)
		local now = os.clock()
		local rate = (stats.accepted - lastAccepted) / (now - lastT)
		lastAccepted, lastT = stats.accepted, now
		cpsStat:Set(math.floor(rate * 10 + 0.5) / 10)
		critStat:Set(stats.crits)
		earnedStat:Set(stats.earned)
		rebirthsStat:Set(leaderstat("Rebirths") or 0)
		eggsStat:Set(leaderstat("Eggs") or 0)
		setText(islandText, currentIsland())

		local running = {}
		local function add(on, label) if on then table.insert(running, label) end end
		add(cfg.enabled, ("Auto Tap (%.1f/s)"):format(rate))
		add(cfg.autoBreak, "Auto Break")
		add(cfg.autoHatch, "Auto Hatch (" .. tostring(cfg.hatchEgg) .. ")")
		add(cfg.autoDelete, "Auto-delete at hatch")
		add(cfg.autoQuests, "Auto Quests")
		add(cfg.autoChest, "Auto Chest")
		add(cfg.autoIndex, "Index rewards")
		add(cfg.autoPotions, "Auto potions")
		setText(runningText, #running > 0 and table.concat(running, "\n") or "Nothing is on")
	end
end)

genv.__TapXeno = { window = window, cfg = cfg, stats = stats, knownIslands = knownIslands, travelTo = travelTo }
activity("Hub", ("Xeno Lite running (%s)"):format(type(identifyexecutor) == "function" and tostring((identifyexecutor())) or "executor"))
window:Notify({ title = "Tap Simulator Xeno Lite loaded", content = "Farming, Pets, Utils and Settings are ready." })
