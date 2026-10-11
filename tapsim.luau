-- Tap Simulator: Reborn hub (Rayfield Gen2)
--   Farming:  auto tap, auto rebirth, auto gem upgrades, auto mining
--   Hatching: auto hatch, hide hatch animation
--   Utils:    auto claim quests, auto Tap Chests, auto dig site, unlock + teleport to worlds
-- Every action fires the same remote the game's own UI uses, and every list
-- (rebirth buttons, upgrades, eggs, quests) is read from the account's own data
-- with the game's own config modules, so it matches whatever this account owns.
-- Taps: the server accepts ~8.3/s (0.12s spacing) and silently drops the rest.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = ReplicatedStorage.RemoteServices
local TapRequested = Remotes.TapService.RE.TapRequested
local TapResult = Remotes.TapService.RE.TapResult
local RebirthRequested = Remotes.RebirthService.RE.RebirthRequested
local RebirthResult = Remotes.RebirthService.RE.RebirthResult

local UnlockSkill = Remotes.SkillTreeService.RF.Unlock
local ClaimQuest = Remotes.QuestService.RF.ClaimQuest
local ClaimChest = Remotes.TapChestService.RF.Claim
local EggHatchRequested = Remotes.EggService.RE.EggHatchRequested
local EggHatchResult = Remotes.EggService.RE.EggHatchResult
local MachineCraftRequested = Remotes.MachineService.RE.MachineCraftRequested
local MachineCraftResult = Remotes.MachineService.RE.MachineCraftResult

local DataController = require(ReplicatedStorage.Controllers:FindFirstChild("DataController", true))
local RebirthButtonConfig = require(ReplicatedStorage.Shared.Progression.RebirthButtonConfig)
local RebirthConfig = require(ReplicatedStorage.Shared.Progression.RebirthConfig)
local SkillTreeConfig = require(ReplicatedStorage.Shared.Progression.SkillTreeConfig)
local SkillTreeFormula = require(ReplicatedStorage.Shared.Progression.SkillTreeFormula)
local SkillTreeRequirements = require(ReplicatedStorage.Shared.Progression.SkillTreeRequirements)
local QuestConfig = require(ReplicatedStorage.Shared.Quests.QuestConfig)
local QuestVisibility = require(ReplicatedStorage.Shared.Quests.QuestVisibility)
local TapChestConfig = require(ReplicatedStorage.Shared.Game.TapChestConfig)
local LaunchEggConfig = require(ReplicatedStorage.Shared.Pets.LaunchEggConfig)
local EggPricing = require(ReplicatedStorage.Shared.Pets.EggPricing)
local GamepassPerks = require(ReplicatedStorage.Shared.Monetization.GamepassPerks)
local BoostFormula = require(ReplicatedStorage.Shared.Items.BoostFormula)
local HatchRenderer = require(ReplicatedStorage.Modules.Client.Pets.HatchRenderer)
local MachineConfig = require(ReplicatedStorage.Shared.Pets.MachineConfig)
local MasteryFormula = require(ReplicatedStorage.Shared.Progression.MasteryFormula)
local EnchantFormula = require(ReplicatedStorage.Shared.Pets.EnchantFormula)
local BreakableConfig = require(ReplicatedStorage.Shared.Game.BreakableConfig)
local IslandRegions = require(ReplicatedStorage.Shared.Progression.IslandRegions)
local DigConfig = require(ReplicatedStorage.Shared.Minigames.DigConfig)
local DigWorld = require(ReplicatedStorage.Shared.Minigames.DigWorld)
local MiningModules = ReplicatedStorage.Shared.Minigames.Mining
local MiningConfig = require(MiningModules.MiningConfig)
local MiningWorld = require(MiningModules.MiningWorld)
local MineSave = require(MiningModules.MineSave)
local OreTypes = require(MiningModules.OreTypes)
local CollectionService = game:GetService("CollectionService")

local MIN_INTERVAL = 0.12 -- server tap cap
local REBIRTH_COOLDOWN = 1 -- seconds between rebirth requests
local MAX_LABEL = "Max"

local MAIN_TREE = "Main" -- display name for SkillTreeConfig.Origin
local DIRECTIONS = { "N", "S", "NE", "NW", "SE", "SW" }

local cfg = {
	enabled = false,
	rate = 8,
	autoRebirth = false,
	rebirthChoice = MAX_LABEL,
	autoUpgrade = false,
	upgradeTrees = {},
	autoClaimQuests = false,
	autoChest = false,
	chestTeleport = true,
	autoHatch = false,
	hatchEgg = nil,
	hideHatchAnimation = false,
	autoGolden = false,
	goldenPets = {},
	craftCount = 6,
	hideCraftAnimation = true,
	autoBreak = false,
	autoEquipBest = false,
	equipMode = "Clicks",
	autoDig = false,
	autoUnlockWorlds = false,
	autoMine = false,
	autoSellOres = true,
	autoBuyPickaxe = true,
	autoBuyBackpack = true,
	priorityOres = {},
	onlyPriorityOres = false,
}
local stats = {
	sent = 0,
	accepted = 0,
	crits = 0,
	earned = 0,
	rebirthsDone = 0,
	upgradesBought = 0,
	questsClaimed = 0,
	chestsOpened = 0,
	chestCoins = 0,
	eggsHatched = 0,
	eggCoinsSpent = 0,
	goldenCrafts = 0,
	goldenMade = 0,
	goldenFailed = 0,
	chestsBroken = 0,
	digs = 0,
	blocksMined = 0,
	miningCoinsEarned = 0,
}
local seq = 5000000 + math.random(0, 1000000)
local alive = true

-- Chest claims and golden crafts hop the character somewhere and back; auto hatch
-- parks it at an egg. While a hop is in progress (travelLock > 0) nothing else moves
-- the character, so the hops never fight each other.
local travelLock = 0

-- True while auto break is standing at a breakable: taps go out even with Auto Tap off,
-- since taps are what damage breakables.
local breakingNow = false

-- Most sections live in their own do-block (Luau allows 200 locals per scope);
-- the few functions handed to getgenv().__TapAC for testing are collected here.
local exports = {}

-- STATE is provided by live-reload; fall back to a plain shim when run elsewhere.
local STATE = STATE or {
	onCleanup = function() end,
	connect = function(sig, fn) return sig:Connect(fn) end,
	alive = function() return alive end,
}

local function getData()
	local replica = DataController:GetReplica()
	return replica and replica.Data
end

local function abbreviate(n)
	local suffixes = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx" }
	local i = 1
	while n >= 1000 and i < #suffixes do
		n /= 1000
		i += 1
	end
	if i == 1 then return tostring(math.floor(n)) end
	return (string.format("%.2f", n):gsub("%.?0+$", "")) .. suffixes[i]
end

-- How many rebirth buttons this account has unlocked in its current world.
local function unlockedOptionCount(data)
	local world = data.Progression.World or "Main"
	local unlocked = RebirthButtonConfig.GetUnlockedCount(data.Upgrades.RebirthButtons or 0, world)
	return RebirthButtonConfig.GetOptionCount(unlocked, world)
end

-- Dropdown labels ("Max", "+1", "+5", ...) and label -> button index.
local labelToIndex = {}
local function buildOptions(count)
	table.clear(labelToIndex)
	local options = { MAX_LABEL }
	for i = 1, count do
		local label = "+" .. abbreviate(RebirthConfig.GetAmountFromIndex(i))
		labelToIndex[label] = i
		table.insert(options, label)
	end
	return options
end

local function selectedIndex(count)
	if cfg.rebirthChoice == MAX_LABEL then return count end
	local i = labelToIndex[cfg.rebirthChoice]
	return i and math.min(i, count) or count
end

-- Gem upgrade trees, in menu order. SkillTreeConfig.Origin is the main tree.
local function upgradeTreeNames()
	local names = { MAIN_TREE }
	local extra = {}
	for key in pairs(SkillTreeConfig) do
		if key ~= "Origin" then table.insert(extra, key) end
	end
	table.sort(extra)
	for _, key in ipairs(extra) do table.insert(names, key) end
	return names
end

-- Walks the gem upgrade tree with the same reachability rules as the game's
-- SkillTreeController: a node is reachable when its parent is owned (or is an
-- origin), and a sub-tree's nodes only count once its category tile is opened.
-- Returns every reachable, unowned node with its price and what blocks it.
local function scanUpgrades(data)
	local unlocked = (data.SkillTree and data.SkillTree.Unlocked) or {}
	local results = {}
	local seen = {}
	local seenTree = { Origin = true }

	local function walk(node, reachable, tree, treeOpen)
		if seen[node] then return end
		seen[node] = true
		local owned = unlocked[node.Name] == true

		if reachable and not owned and not node.Origin then
			local entry = {
				name = node.Name,
				tree = node.Category and (node.Tree or tree) or tree,
				price = node.Category and 0 or SkillTreeFormula.GetPrice(data, node.Name),
				isCategory = node.Category == true,
				treeOpen = node.Category or treeOpen,
				island = SkillTreeRequirements.GetLockedIsland(data, node),
				shop = SkillTreeRequirements.GetLockedShop(data, node),
			}
			table.insert(results, entry)
		end

		local passes = owned or node.Origin == true
		local sub = node.Tree and SkillTreeConfig[node.Tree]
		if sub and not seenTree[node.Tree] and (reachable or passes) then
			seenTree[node.Tree] = true
			-- A category tile must itself be opened before its sub-tree can be bought.
			walk(sub, true, node.Tree, not node.Category or owned)
		end
		for _, dir in ipairs(DIRECTIONS) do
			if node[dir] then walk(node[dir], passes, tree, treeOpen) end
		end
	end

	walk(SkillTreeConfig.Origin, true, MAIN_TREE, true)
	table.sort(results, function(a, b)
		if a.price ~= b.price then return a.price < b.price end
		return a.name < b.name
	end)
	return results
end

local function isBuyable(entry)
	return entry.treeOpen and entry.island == nil and entry.shop == nil
end

local function treeSelected(tree)
	return table.find(cfg.upgradeTrees, tree) ~= nil
end

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()

local window = Rayfield:CreateWindow({
	name = "Tap Simulator",
	subtitle = "Auto Farm",
	theme = "ember",
	sidebarLayout = true,
	configuration = { autoSave = true, autoLoad = true, fileName = "TapSimAutoClicker" },
})

STATE.onCleanup(function()
	alive = false
	if not window.unloaded then window:Unload() end
end)

-- Rayfield runs button callbacks on a thread that lacks the rights its Notify needs,
-- so notifications are queued and shown from this script's own thread instead.
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

-- Pages down the sidebar, each split into two columns of cards. Pages and columns
-- are made up front; every feature below adds its card to the column it belongs in.
-- (Columns take toggles, sliders, dropdowns, buttons, text and stats; keybinds and
-- consoles only go full width, under the columns.)
-- Columns are narrow, so cards stay lean: no description lines under controls
-- (they wrap into tall blocks) and one-line compact stats.
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
				return handle
			end
		end,
	})
end

-- A text row showing a number abbreviated (2.63Qa), for values whose full digits
-- would overflow a stat tile. Same :Set(number) as a stat.
local function bigNumber(column, name)
	local handle = column:CreateText({ name = name, text = "0" })
	return {
		Set = function(_, value)
			local text = abbreviate(tonumber(value) or 0)
			pcall(function()
				if handle.text ~= text then handle:Set(text) end
			end)
		end,
	}
end

local function twoColumns(tab)
	local grid = tab:CreateGroup()
	return lean(grid:CreateGroup({ direction = "column" })), lean(grid:CreateGroup({ direction = "column" }))
end

window:CreateSection({ name = "Main" })
local homeTab = window:CreateTab({ name = "Home" })
window:CreateSection({ name = "Farming" })
local autoTab = window:CreateTab({ name = "Automation" })
local petsPage = window:CreateTab({ name = "Pets" })
local craftTab = window:CreateTab({ name = "Crafting" })
local gamesTab = window:CreateTab({ name = "Minigames" })
window:CreateSection({ name = "Other" })
local settingsTab = window:CreateTab({ name = "Settings" })

local homeLeft, homeRight = twoColumns(homeTab)
local autoLeft, autoRight = twoColumns(autoTab)
local petsLeft, petsRight = twoColumns(petsPage)
local craftLeft, craftRight = twoColumns(craftTab)
local gamesLeft, gamesRight = twoColumns(gamesTab)
local settingsLeft, settingsRight = twoColumns(settingsTab)

-- One shared activity log on Home for everything the automations do.
local activityLog = homeTab:CreateConsole({ name = "Activity", height = 170, follow = true, maxLines = 150 })
local function activity(tag, line)
	pcall(function() activityLog:Append(("%s  [%s] %s"):format(os.date("%H:%M:%S"), tag, line)) end)
end

---------------------------------------------------------------- Home

homeLeft:CreateSection({ name = "Account" })
local coinsStat = bigNumber(homeLeft, "Coins")
local rebirthStat = bigNumber(homeLeft, "Rebirths")
local gemsStat = bigNumber(homeLeft, "Gems")
local homeMiningStat = bigNumber(homeLeft, "Mining coins")

homeRight:CreateSection({ name = "Running" })
local runningText = homeRight:CreateText({ name = "Automations", text = "-" })

---------------------------------------------------------------- Automation: Auto Click

local main = autoLeft
main:CreateSection({ name = "Auto Click" })

local tapToggle = main:CreateToggle({
	name = "Auto Tap",
	description = "Taps at the max speed the server accepts.",
	flag = "AutoTap",
	callback = function(v) cfg.enabled = v end,
})

main:CreateSlider({
	name = "Taps per second",
	description = "Server cap is ~8.3/s. Higher values are wasted.",
	range = { 1, 8 },
	increment = 0.5,
	value = 8,
	suffix = " /s",
	flag = "TapRate",
	callback = function(v) cfg.rate = v end,
})

main:CreateToggle({
	name = "Auto Break Chests",
	description = "Goes to the small tap chests around your islands (and your island breakable) and taps them open.",
	flag = "AutoBreak",
	callback = function(v) cfg.autoBreak = v end,
})

local cpsStat = main:CreateStat({ name = "Taps / s", value = 0 })
local critStat = main:CreateStat({ name = "Crits", value = 0 })
local brokenStat = main:CreateStat({ name = "Chests broken", value = 0 })
local earnedStat = bigNumber(main, "Coins earned")

---------------------------------------------------------------- Settings

settingsLeft:CreateSection({ name = "General" })
settingsLeft:CreateToggle({
	name = "Anti-AFK",
	description = "Stops the 20 minute idle kick.",
	value = true,
	flag = "AntiAFK",
	callback = function(v)
		pcall(function()
			for _, c in ipairs(getconnections(Players.LocalPlayer.Idled)) do
				if v then c:Disable() else c:Enable() end
			end
		end)
	end,
})

settingsTab:CreateKeybind({
	name = "Auto Tap key",
	description = "Turns Auto Tap on and off.",
	value = Enum.KeyCode.F,
	flag = "ToggleKey",
	callback = function() tapToggle:Set(not tapToggle.value) end,
})

---------------------------------------------------------------- Automation: Rebirth

local rebirthTab = autoLeft
rebirthTab:CreateSection({ name = "Rebirth" })

local initialData = getData()
local knownCount = initialData and unlockedOptionCount(initialData) or 1

rebirthTab:CreateToggle({
	name = "Auto Rebirth",
	description = "Rebirths as soon as you can afford the chosen amount.",
	flag = "AutoRebirth",
	callback = function(v) cfg.autoRebirth = v end,
})

local amountDropdown = rebirthTab:CreateDropdown({
	name = "Amount",
	description = "Max = your biggest unlocked button. The list updates when you unlock more.",
	options = buildOptions(knownCount),
	value = MAX_LABEL,
	flag = "RebirthAmount",
	callback = function(choice)
		cfg.rebirthChoice = (type(choice) == "string" and choice ~= "") and choice or MAX_LABEL
	end,
})

local targetText = rebirthTab:CreateText({ name = "Target", text = "-" })
local doneStat = bigNumber(rebirthTab, "Rebirths gained")

---------------------------------------------------------------- Automation: Gem Upgrades

local upgradeTab = autoRight
upgradeTab:CreateSection({ name = "Gem Upgrades" })

local allTrees = upgradeTreeNames()
cfg.upgradeTrees = table.clone(allTrees)

local buyCheapest -- defined below, used by the button

upgradeTab:CreateToggle({
	name = "Auto Upgrade",
	description = "Buys gem upgrades cheapest first, as soon as you can afford them.",
	flag = "AutoUpgrade",
	callback = function(v) cfg.autoUpgrade = v end,
})

upgradeTab:CreateDropdown({
	name = "Trees",
	description = "Which trees to spend gems on. New trees are opened for free.",
	multiSelect = true,
	options = allTrees,
	value = allTrees,
	flag = "UpgradeTrees",
	callback = function(selected)
		cfg.upgradeTrees = type(selected) == "table" and selected or {}
	end,
})

upgradeTab:CreateButton({
	name = "Buy all now",
	callback = function()
		task.spawn(function()
			local bought = 0
			while buyCheapest() do
				bought += 1
				task.wait(0.35)
			end
			notify("Upgrades", ("Bought %d upgrade(s)."):format(bought))
		end)
	end,
})

local upgradesStat = upgradeTab:CreateStat({ name = "Bought", value = 0 })
local nextUpgradeText = upgradeTab:CreateText({ name = "Next upgrade", text = "-" })
local upgradeList = upgradeTab:CreateText({ name = "Available", text = "-" })

local buying = false
local retryAfter = {} -- node name -> os.clock() before which a rejected node is skipped

-- Buys the cheapest affordable upgrade in the selected trees.
-- Returns true when something was bought, false when nothing is affordable.
function buyCheapest()
	if buying then return false end
	local data = getData()
	if not data then return false end
	local gems = data.Currencies.Gems or 0
	for _, entry in ipairs(scanUpgrades(data)) do
		if isBuyable(entry) and treeSelected(entry.tree) and os.clock() >= (retryAfter[entry.name] or 0) then
			if entry.price > gems then return false end -- sorted by price, nothing cheaper left
			buying = true
			local ok, res = pcall(function() return UnlockSkill:InvokeServer({ Name = entry.name }) end)
			buying = false
			if ok and type(res) == "table" and res.Success then
				stats.upgradesBought += 1
				return true
			end
			local reason = ok and type(res) == "table" and res.Reason
			if reason == "RateLimited" or reason == "Locked" or reason == "NotReady" then
				task.wait(1) -- transient, try the same node again
			else
				retryAfter[entry.name] = os.clock() + 30
			end
			return false
		end
	end
	return false
end

local function describeUpgrades(data)
	local gems = data.Currencies.Gems or 0
	local lines, nextUp = {}, nil
	local waitingIslands = {}
	for _, entry in ipairs(scanUpgrades(data)) do
		if not treeSelected(entry.tree) then continue end
		local label = entry.isCategory and ("Open %s tree"):format(entry.name) or entry.name
		if entry.island then
			waitingIslands[entry.island] = (waitingIslands[entry.island] or 0) + 1
		elseif entry.shop then
			table.insert(lines, ("[locked] %s - needs %s"):format(label, tostring(entry.shop)))
		elseif entry.treeOpen then
			local status = entry.price <= gems and "BUY" or ("need %s more"):format(abbreviate(entry.price - gems))
			table.insert(lines, ("%s  %s - %s gems (%s)"):format(entry.price <= gems and "+" or " ", label, abbreviate(entry.price), status))
			nextUp = nextUp or entry
		end
	end
	for island, n in pairs(waitingIslands) do
		table.insert(lines, ("[%s] %d upgrade(s) unlock with this island"):format(island, n))
	end
	if #lines == 0 then lines = { "Nothing left to buy in the selected trees." } end
	if #lines > 5 then
		local more = #lines - 4
		lines = { lines[1], lines[2], lines[3], lines[4], ("...and %d more"):format(more) }
	end
	return table.concat(lines, "\n"), nextUp
end

task.spawn(function()
	local lastListed = nil
	while STATE.alive() and alive do
		task.wait(0.5)
		if cfg.autoUpgrade then
			if buyCheapest() then task.wait(0.35) end
		end
		local data = getData()
		if data then
			local text, nextUp = describeUpgrades(data)
			pcall(function()
				if text ~= lastListed then
					lastListed = text
					upgradeList:Set(text)
				end
				local body = nextUp
						and ("%s - %s gems"):format(nextUp.isCategory and ("Open " .. nextUp.name .. " tree") or nextUp.name, abbreviate(nextUp.price))
					or "Nothing affordable yet"
				if nextUpgradeText.text ~= body then nextUpgradeText:Set(body) end
			end)
		end
	end
end)

---------------------------------------------------------------- Farming: Mining
do

-- The Crystal Cave mine (MiningService). Enter() at the mine portal on Crystal Cave
-- starts a session. The mine is a grid (20 x 25 deep x 20) whose ore in every cell
-- is MiningConfig.Ore(seed, x, y, z); the server tracks mined cells (state.Removed,
-- decoded with MineSave.Decode). A block can be hit once it is exposed (top layer,
-- or next to a mined cell) and only from close by ("Move closer to the block"), so
-- the character is pinned in the empty cell beside its target while swinging -
-- otherwise it falls down the shaft between hits. Ore goes straight into the bag;
-- what doesn't fit drops and is picked up from close by. Selling needs the Sell pad,
-- buying the Shop pad (MineArea.MiningFacilities); a bought tool is equipped by the
-- server. The mine resets every 30 minutes with a new seed.

local MiningRF = Remotes.MiningService.RF
local PORTAL_SEARCH_RADIUS = 600 -- studs around the Crystal egg to stream in while looking for the portal
local RESYNC_EVERY = 30 -- blocks between full state refreshes

local mine = {
	active = false, -- this script is running a mining session (and holds travelLock)
	state = nil,
	removed = nil,
	marker = nil,
	dims = nil,
	pin = nil, -- CFrame the character is held at while mining
	skip = {},
	sinceSync = 0,
}

-- Hold the character still while mining, so it doesn't fall away from its block.
STATE.connect(RunService.Heartbeat, function()
	local pin = mine.pin
	if not pin then return end
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
		root.CFrame = pin
	end
end)
STATE.onCleanup(function() mine.pin = nil end)

-- Priority ore choices, most valuable first: "Thunder Stone - 650" -> "Thunder Stone".
local oreLabelToName = {}
local oreOptions = {}
do
	local ores = {}
	for _, ore in pairs(OreTypes.ByName) do table.insert(ores, ore) end
	table.sort(ores, function(a, b) return a.value > b.value end)
	for _, ore in ipairs(ores) do
		local label = ("%s - %s"):format(ore.name, abbreviate(ore.value))
		oreLabelToName[label] = ore.name
		table.insert(oreOptions, label)
	end
end

-- Ore per cell for the current seed, worked out once per cell.
local oreCache = { seed = nil, cells = {} }
local function oreAt(seed, x, y, z)
	if oreCache.seed ~= seed then
		oreCache.seed, oreCache.cells = seed, {}
	end
	local key = MiningConfig.Key(x, y, z)
	local cell = oreCache.cells[key]
	if not cell then
		local ore, blockStats = MiningConfig.Ore(seed, x, y, z)
		cell = { name = ore.name, value = ore.value, need = blockStats.pickaxeRequirement or 0 }
		oreCache.cells[key] = cell
	end
	return cell
end

local function mergeMineState(s)
	if type(s) ~= "table" or not mine.state then return end
	local oldSeed = mine.state.Seed
	for k, v in pairs(s) do mine.state[k] = v end
	if s.Removed and mine.dims then
		mine.removed = MineSave.Decode(s.Removed, mine.dims[1], mine.dims[2], mine.dims[3])
	end
	if mine.state.Seed ~= oldSeed then mine.skip = {} end
end

local function syncMine()
	local ok, st = pcall(function() return MiningRF.State:InvokeServer() end)
	if not ok or type(st) ~= "table" or not st.Active then return false end
	local marker = MiningWorld.Marker()
	if not marker then return false end
	local x, y, z = MiningConfig.Dimensions(marker)
	if mine.state and mine.state.Seed ~= st.Seed then mine.skip = {} end
	mine.state, mine.marker, mine.dims = st, marker, { x, y, z }
	mine.removed = MineSave.Decode(st.Removed, x, y, z)
	mine.sinceSync = 0
	return true
end

local function inMineBounds(x, y, z)
	local dims = mine.dims
	return x >= 0 and x < dims[1] and y >= 0 and y < dims[2] and z >= 0 and z < dims[3]
end

-- The portal is a "Teleport" part on Crystal Cave that only exists once streamed in.
local function findMinePortal()
	local portal = MiningWorld.Portal()
	if portal then return portal end
	local eggs = workspace:FindFirstChild("Eggs")
	local egg = eggs and eggs:FindFirstChild("Crystal")
	local anchor = egg and egg:GetPivot().Position
	if not anchor then return nil end
	pcall(function() Players.LocalPlayer:RequestStreamAroundAsync(anchor, 5) end)
	local islands = workspace:FindFirstChild("Ts2Islands")
	local island = islands and islands:FindFirstChild("Crystal Cave")
	local decor = island and island:FindFirstChild("Decor")
	local trees = decor and decor:FindFirstChild("Trees")
	if trees then
		for _, model in ipairs(trees:GetChildren()) do
			local pos = model:GetPivot().Position
			if (pos - anchor).Magnitude < PORTAL_SEARCH_RADIUS then
				pcall(function() Players.LocalPlayer:RequestStreamAroundAsync(pos, 5) end)
				portal = MiningWorld.Portal()
				if portal then return portal end
			end
		end
	end
	return MiningWorld.Portal()
end

local miningStatus -- UI, created below

local function setMiningStatus(text)
	pcall(function()
		if miningStatus.text ~= text then miningStatus:Set(text) end
	end)
end

local function logMining(line)
	activity("Mine", line)
end

local function enterMine()
	if Players.LocalPlayer:GetAttribute("MiningActive") == true then return syncMine() end
	local data = getData()
	if not (data and data.Progression.UnlockedIslands["Crystal Cave"]) then
		setMiningStatus("Unlock Crystal Cave to use the mine")
		return false
	end
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return false end

	setMiningStatus("Going to the mine")
	local portal = findMinePortal()
	if not portal then
		pcall(function() Remotes.IslandService.RF.Travel:InvokeServer({ Island = "Crystal Cave", Source = "Menu" }) end)
		task.wait(0.5)
		portal = findMinePortal()
	end
	if not portal then
		setMiningStatus("Couldn't find the mine portal")
		return false
	end
	root.AssemblyLinearVelocity = Vector3.zero
	character:PivotTo(portal.CFrame)
	task.wait(0.5)
	local ok, st = pcall(function() return MiningRF.Enter:InvokeServer() end)
	if not ok or type(st) ~= "table" or not st.Active then
		setMiningStatus("Server said: " .. tostring(type(st) == "table" and (st.Error or st.Reason) or st))
		return false
	end
	task.wait(0.5)
	return syncMine()
end

local function standOnPad(name)
	local pad = MiningWorld.Part(name)
	if not pad then return false end
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	mine.pin = nil
	root.AssemblyLinearVelocity = Vector3.zero
	character:PivotTo(pad.CFrame * CFrame.new(0, pad.Size.Y / 2 + 3, 0))
	task.wait(0.4)
	return true
end

local function sellOres()
	if not standOnPad("Sell") then return false end
	local ok, st = pcall(function() return MiningRF.Sell:InvokeServer() end)
	if ok and type(st) == "table" and not st.Error then
		stats.miningCoinsEarned += st.Sold or 0
		mergeMineState(st)
		logMining(("Sold ores for %s"):format(abbreviate(st.Sold or 0)))
		return true
	end
	return false
end

local function owns(map, index)
	return type(map) == "table" and (map[index] == true or map[tostring(index)] == true)
end

-- Buys (or equips) the best pickaxe and backpack the balance allows, on the Shop pad.
local function buyMiningUpgrades()
	local st = mine.state
	if not st then return end
	local balance = st.Balance or 0
	local actions = {}
	local function pick(list, current, owned, buyAction, equipAction)
		for i = #list, (current or 1) + 1, -1 do
			if owns(owned, i) then
				table.insert(actions, { equipAction, list[i].Name })
				return
			end
			if balance >= list[i].Price then
				balance -= list[i].Price
				table.insert(actions, { buyAction, list[i].Name })
				return
			end
		end
	end
	if cfg.autoBuyPickaxe then pick(MiningConfig.Tools, st.Tool, st.OwnedTools, "BuyTool", "EquipTool") end
	if cfg.autoBuyBackpack then pick(MiningConfig.Bags, st.Backpack, st.OwnedBackpacks, "BuyStorage", "EquipStorage") end
	if #actions == 0 or not standOnPad("Shop") then return end
	for _, action in ipairs(actions) do
		local ok, reply = pcall(function() return MiningRF.Purchase:InvokeServer(action[1], action[2]) end)
		if ok and type(reply) == "table" and not reply.Error then
			mergeMineState(reply)
			logMining(((action[1]:sub(1, 3) == "Buy") and "Bought " or "Equipped ") .. action[2])
		end
	end
end

local function collectMineDrops()
	local st = mine.state
	if not (st and type(st.Drops) == "table" and mine.marker) then return end
	for key, drop in pairs(st.Drops) do
		if (st.Count or 0) >= (st.Capacity or 0) then break end
		local x, y, z = tostring(key):match("^(%d+):(%d+):(%d+)$")
		x, y, z = tonumber(x), tonumber(y), tonumber(z)
		if x then
			mine.pin = CFrame.new(MiningConfig.Position(mine.marker, x, y, z) + Vector3.new(0, 2, 0))
			task.wait(0.3)
			local ok, reply = pcall(function() return MiningRF.CollectDrop:InvokeServer(st.Id, key) end)
			if ok and type(reply) == "table" and not reply.Error then
				mergeMineState(reply.State or reply)
				st.Drops[key] = nil
			end
		end
	end
	mine.pin = nil
end

-- The empty cell next to (x, y, z) closest to us, to stand in while hitting it.
local function mineStandFor(x, y, z)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local best, bestDist = nil, math.huge
	for _, n in ipairs(MiningConfig.Neighbors) do
		local nx, ny, nz = x + n.X, y + n.Y, z + n.Z
		local open = (ny == -1) or (inMineBounds(nx, ny, nz) and mine.removed[MiningConfig.Key(nx, ny, nz)])
		if open then
			local pos = MiningConfig.Position(mine.marker, nx, ny, nz)
			local dist = root and (root.Position - pos).Magnitude or 0
			if dist < bestDist then best, bestDist = pos, dist end
		end
	end
	return best
end

-- The next block to hit. With priority ores chosen: the first block of the shortest
-- dig (through blocks the pickaxe can break) to the nearest priority ore. Otherwise,
-- or when none is reachable, the most valuable exposed block.
local function nextMineBlock()
	local st, removed, dims = mine.state, mine.removed, mine.dims
	local seed = st.Seed
	local tool = MiningConfig.Tools[st.Tool] or MiningConfig.Tools[1]
	local wanted = {}
	for _, name in ipairs(cfg.priorityOres) do wanted[name] = true end
	local hasPriority = next(wanted) ~= nil

	local function usable(x, y, z, key)
		return not removed[key] and not mine.skip[key] and oreAt(seed, x, y, z).need <= tool.Power
	end

	local frontier = {}
	for x = 0, dims[1] - 1 do
		for y = 0, dims[2] - 1 do
			for z = 0, dims[3] - 1 do
				local key = MiningConfig.Key(x, y, z)
				if usable(x, y, z, key) and MiningConfig.Exposed(removed, x, y, z) then
					table.insert(frontier, { x = x, y = y, z = z, key = key })
				end
			end
		end
	end

	if hasPriority then
		local seen, prev = {}, {}
		local queue, head = {}, 1
		for _, cell in ipairs(frontier) do
			seen[cell.key] = true
			table.insert(queue, cell)
		end
		while head <= #queue do
			local cell = queue[head]
			head += 1
			if wanted[oreAt(seed, cell.x, cell.y, cell.z).name] then
				local first = cell
				while prev[first.key] do first = prev[first.key] end
				return first, cell
			end
			for _, n in ipairs(MiningConfig.Neighbors) do
				local nx, ny, nz = cell.x + n.X, cell.y + n.Y, cell.z + n.Z
				if inMineBounds(nx, ny, nz) then
					local nk = MiningConfig.Key(nx, ny, nz)
					if not seen[nk] and usable(nx, ny, nz, nk) then
						seen[nk] = true
						prev[nk] = cell
						table.insert(queue, { x = nx, y = ny, z = nz, key = nk })
					end
				end
			end
		end
		if cfg.onlyPriorityOres then return nil end
	end

	local best, bestValue = nil, -1
	for _, cell in ipairs(frontier) do
		local value = oreAt(seed, cell.x, cell.y, cell.z).value
		if value > bestValue then best, bestValue = cell, value end
	end
	return best, best
end

-- Swings at one block until it breaks. Returns "broken", "full", "skip" or "stopped".
local function mineBlock(cell)
	local st = mine.state
	local stand = mineStandFor(cell.x, cell.y, cell.z)
	if not stand then return "skip" end
	mine.pin = CFrame.new(stand)
	task.wait(0.1) -- let the server see us next to it
	local tool = MiningConfig.Tools[st.Tool] or MiningConfig.Tools[1]
	local tooFar = 0
	for _ = 1, 80 do
		if not cfg.autoMine or not STATE.alive() then return "stopped" end
		local sent = os.clock()
		local ok, reply = pcall(function() return MiningRF.Hit:InvokeServer(st.Id, cell.x, cell.y, cell.z) end)
		if not ok or type(reply) ~= "table" then return "skip" end
		if reply.State then mergeMineState(reply.State) end
		if reply.Error then
			local message = tostring(reply.Error)
			if message:lower():find("full") then return "full" end
			if message:lower():find("closer") and tooFar < 3 then
				tooFar += 1
				mine.pin = CFrame.new(stand)
				task.wait(0.2)
			else
				setMiningStatus("Server said: " .. message)
				return "skip"
			end
		elseif reply.Broken then
			mine.removed[cell.key] = true
			stats.blocksMined += 1
			if type(reply.Drop) == "table" and reply.Drop.Id then
				mine.state.Drops = mine.state.Drops or {}
				mine.state.Drops[reply.Drop.Id] = reply.Drop
			end
			return "broken", reply
		end
		local remaining = tool.Interval - (os.clock() - sent)
		if remaining > 0 then task.wait(remaining) end
	end
	return "skip"
end

local function handleFullBag()
	mine.pin = nil
	if not cfg.autoSellOres then
		setMiningStatus("Bag full - turn on Auto Sell Ores")
		task.wait(2)
		syncMine()
		return
	end
	setMiningStatus("Selling")
	sellOres()
	buyMiningUpgrades()
	collectMineDrops()
	syncMine()
end

local function stopMining(reason)
	mine.pin = nil
	if mine.active then
		pcall(function() MiningRF.Leave:InvokeServer() end)
		mine.active = false
		travelLock -= 1
	end
	setMiningStatus(reason or "Off")
end

STATE.connect(Remotes.MiningService.RE.MineReset.OnClientEvent, function()
	if mine.active then task.defer(syncMine) end
end)

local mineTab = gamesRight
mineTab:CreateSection({ name = "Mining" })

mineTab:CreateToggle({
	name = "Auto Mine",
	description = "Goes into the Crystal Cave mine and mines nonstop. Other teleport features pause while it runs.",
	flag = "AutoMine",
	callback = function(v) cfg.autoMine = v end,
})

mineTab:CreateDropdown({
	name = "Priority",
	description = "Digs straight toward these first, breaking whatever is in the way.",
	multiSelect = true,
	options = oreOptions,
	value = {},
	placeholder = "Pick ores",
	flag = "PriorityOres",
	callback = function(selected)
		local names = {}
		for _, label in ipairs(type(selected) == "table" and selected or {}) do
			if oreLabelToName[label] then table.insert(names, oreLabelToName[label]) end
		end
		cfg.priorityOres = names
	end,
})

mineTab:CreateToggle({
	name = "Only mine priority ores",
	description = "Off: when no priority ore is reachable it mines the most valuable blocks instead.",
	flag = "OnlyPriorityOres",
	callback = function(v) cfg.onlyPriorityOres = v end,
})

mineTab:CreateToggle({
	name = "Auto Sell Ores",
	description = "Sells at the Sell pad whenever the bag is full, then goes back down.",
	value = true,
	flag = "AutoSellOres",
	callback = function(v) cfg.autoSellOres = v end,
})

mineTab:CreateToggle({
	name = "Auto Buy Pickaxe",
	description = "Buys the best pickaxe you can afford after selling.",
	value = true,
	flag = "AutoBuyPickaxe",
	callback = function(v) cfg.autoBuyPickaxe = v end,
})

mineTab:CreateToggle({
	name = "Auto Buy Backpack",
	description = "Buys the biggest backpack you can afford after selling.",
	value = true,
	flag = "AutoBuyBackpack",
	callback = function(v) cfg.autoBuyBackpack = v end,
})

miningStatus = mineTab:CreateText({ name = "Status", text = "Off" })
local gearText = mineTab:CreateText({ name = "Gear", text = "-" })
local miningCoinsStat = mineTab:CreateStat({ name = "Mining coins", value = 0 })
local blocksStat = mineTab:CreateStat({ name = "Blocks mined", value = 0 })
local miningEarnedStat = mineTab:CreateStat({ name = "Earned", value = 0 })

task.spawn(function()
	while STATE.alive() and alive do
		if not cfg.autoMine then
			if mine.active then stopMining("Off") end
			task.wait(0.5)
			continue
		end

		if not mine.active then
			if travelLock > 0 then
				setMiningStatus("Waiting for another hop to finish")
				task.wait(0.5)
				continue
			end
			travelLock += 1
			mine.active = true
			mine.skip = {}
			if not enterMine() then
				mine.active = false
				travelLock -= 1
				task.wait(5)
				continue
			end
		end

		if Players.LocalPlayer:GetAttribute("MiningActive") ~= true or not mine.state then
			mine.pin = nil
			if not enterMine() then task.wait(3) end
			continue
		end

		local st = mine.state
		if (st.Count or 0) >= (st.Capacity or math.huge) then
			handleFullBag()
			continue
		end

		local cell, target = nextMineBlock()
		if not cell then
			mine.pin = nil
			setMiningStatus(#cfg.priorityOres > 0 and "No priority ores left - waiting for the mine to reset" or "Nothing left to mine - waiting for the reset")
			task.wait(3)
			syncMine()
			continue
		end

		local ore = oreAt(st.Seed, cell.x, cell.y, cell.z)
		local goal = oreAt(st.Seed, target.x, target.y, target.z)
		setMiningStatus(cell == target and ("Mining " .. ore.name) or ("Digging to " .. goal.name .. " (" .. ore.name .. ")"))

		local result, reply = mineBlock(cell)
		if result == "full" then
			handleFullBag()
		elseif result == "skip" then
			mine.skip[cell.key] = true
		elseif result == "broken" and reply and table.find(cfg.priorityOres, tostring(reply.Ore)) then
			logMining(("Found %s (+%s)"):format(tostring(reply.Ore), tostring(reply.Awarded or "?")))
		end

		mine.sinceSync += 1
		if mine.sinceSync >= RESYNC_EVERY then syncMine() end
	end
end)

-- Gear and numbers, from the live session or the saved mining data.
task.spawn(function()
	while STATE.alive() and alive do
		task.wait(1)
		local st = mine.active and mine.state or nil
		local saved = (getData() or {}).Mining or {}
		local toolIndex = st and st.Tool or saved.Tool or 1
		local bagIndex = st and st.Backpack or saved.Backpack or 1
		local tool = MiningConfig.Tools[toolIndex]
		local bag = MiningConfig.Bags[bagIndex]
		local count = st and st.Count
		local gear = ("%s | %s%s"):format(
			tool and tool.Name or "?",
			bag and bag.Name or "?",
			count and (" " .. count .. "/" .. tostring(st.Capacity or (bag and bag.Capacity) or "?")) or ""
		)
		pcall(function()
			if gearText.text ~= gear then gearText:Set(gear) end
			miningCoinsStat:Set(st and st.Balance or saved.Coins or 0)
			blocksStat:Set(stats.blocksMined)
			miningEarnedStat:Set(stats.miningCoinsEarned)
		end)
	end
end)
exports.mine = mine
end

---------------------------------------------------------------- Utils: Quests
do

-- Same rule as the game's QuestController.countReady: shown in the quest list,
-- not auto-claimed by the server, goal reached, and not claimed yet.
local function scanQuests(data)
	local ready, active = {}, {}
	for id, state in pairs(data.Quests or {}) do
		local def = QuestConfig.Definitions[id]
		if def and state.Claimed ~= true and def.AutoClaim ~= true and QuestVisibility.IsShown(data, id) then
			local amount = state.Amount or 0
			local entry = { id = id, text = def.Description or id, amount = amount, goal = def.Goal or 1 }
			if state.Completed == true or entry.goal <= amount then
				table.insert(ready, entry)
			else
				table.insert(active, entry)
			end
		end
	end
	table.sort(ready, function(a, b) return a.id < b.id end)
	table.sort(active, function(a, b) return a.amount / a.goal > b.amount / b.goal end)
	return ready, active
end

local questTab = autoRight
questTab:CreateSection({ name = "Quests" })

questTab:CreateToggle({
	name = "Auto Claim Quests",
	description = "Claims every finished quest the moment it completes.",
	flag = "AutoClaimQuests",
	callback = function(v) cfg.autoClaimQuests = v end,
})

local questRetryAfter = {}
local function claimReadyQuests()
	local data = getData()
	if not data then return 0 end
	local claimed = 0
	for _, quest in ipairs((scanQuests(data))) do
		if os.clock() >= (questRetryAfter[quest.id] or 0) then
			local ok, res = pcall(function() return ClaimQuest:InvokeServer({ Quest = quest.id }) end)
			if ok and type(res) == "table" and res.Success then
				claimed += 1
				stats.questsClaimed += 1
				activity("Quest", "Claimed: " .. quest.text)
			else
				questRetryAfter[quest.id] = os.clock() + 15
			end
			task.wait(0.4)
		end
	end
	return claimed
end

questTab:CreateButton({
	name = "Claim all now",
	callback = function()
		task.spawn(function()
			local n = claimReadyQuests()
			notify("Quests", n > 0 and ("Claimed %d quest(s)."):format(n) or "Nothing ready to claim.")
		end)
	end,
})

local questsStat = questTab:CreateStat({ name = "Claimed", value = 0 })
local questList = questTab:CreateText({ name = "Your quests", text = "-" })

local function describeQuests(data)
	local ready, active = scanQuests(data)
	local lines = {}
	for _, q in ipairs(ready) do
		table.insert(lines, ("+ %s  READY"):format(q.text))
	end
	for _, q in ipairs(active) do
		table.insert(lines, ("  %s  %s / %s"):format(q.text, abbreviate(q.amount), abbreviate(q.goal)))
	end
	if #lines == 0 then lines = { "No open quests right now." } end
	return table.concat(lines, "\n")
end

task.spawn(function()
	local lastListed = nil
	while STATE.alive() and alive do
		task.wait(1)
		if cfg.autoClaimQuests then claimReadyQuests() end
		local data = getData()
		if data then
			local text = describeQuests(data)
			pcall(function()
				if text ~= lastListed then
					lastListed = text
					questList:Set(text)
				end
				questsStat:Set(stats.questsClaimed)
			end)
		end
	end
end)
exports.describeQuests = describeQuests
end

---------------------------------------------------------------- Utils: Chests
do

-- Tap Chests: one per island, 6 hour cooldown, Data.TapChests[id] = ready time.
-- The server only pays out within TapChestConfig.ClaimReach of the chest, so
-- we step in front of it, claim, and step back to where we were.

local function chestModel(id)
	for _, model in ipairs(CollectionService:GetTagged(TapChestConfig.Tag)) do
		if model:GetAttribute(TapChestConfig.Attributes.Id) == id and model:IsDescendantOf(workspace) then
			return model
		end
	end
	return nil
end

local function chestStates(data)
	local now = workspace:GetServerTimeNow()
	local unlockedIslands = (data.Progression and data.Progression.UnlockedIslands) or {}
	local list = {}
	for id, chest in pairs(TapChestConfig.Chests) do
		table.insert(list, {
			id = id,
			island = chest.Island,
			unlocked = unlockedIslands[chest.Island] == true,
			readyIn = TapChestConfig.GetReadyAt(data, id) - now,
		})
	end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end

local chestRetryAfter = {}
local function claimChest(id)
	local model = chestModel(id)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (model and root and humanoid and humanoid.Health > 0) then return false end

	local front = model:GetAttribute(TapChestConfig.Attributes.Front)
	local size = model:GetAttribute(TapChestConfig.Attributes.Size)
	local inReach = (root.Position - front.Position).Magnitude <= TapChestConfig.ClaimReach - 5

	local returnTo = nil
	if not inReach then
		if not cfg.chestTeleport or travelLock > 0 then return false end
		travelLock += 1
		returnTo = character:GetPivot()
		local spot = front.Position + front.LookVector * (size.Z * 0.5 + 6) + Vector3.new(0, 3, 0)
		root.AssemblyLinearVelocity = Vector3.zero
		character:PivotTo(CFrame.lookAt(spot, Vector3.new(front.Position.X, spot.Y, front.Position.Z)))
		task.wait(0.6) -- let the server see the new position
	end

	local ok, res = pcall(function() return ClaimChest:InvokeServer(id) end)
	if returnTo then
		if character.Parent then
			task.wait(0.3)
			root.AssemblyLinearVelocity = Vector3.zero
			character:PivotTo(returnTo)
		end
		travelLock -= 1
	end

	if ok and type(res) == "table" and res.Success then
		stats.chestsOpened += 1
		if type(res.Coins) == "number" then stats.chestCoins += res.Coins end
		activity("Chest", ("Opened %s chest for %s coins"):format(id, abbreviate(res.Coins or 0)))
		return true
	end
	chestRetryAfter[id] = os.clock() + 60
	return false
end

local chestTab = autoRight
chestTab:CreateSection({ name = "Tap Chests" })

chestTab:CreateToggle({
	name = "Auto Chest",
	description = "Opens every Tap Chest on your unlocked islands as soon as it is ready.",
	flag = "AutoChest",
	callback = function(v) cfg.autoChest = v end,
})

chestTab:CreateToggle({
	name = "Teleport to chest",
	description = "Hop to the chest, claim, and hop back. Off = only claims when you walk up to it.",
	value = true,
	flag = "ChestTeleport",
	callback = function(v) cfg.chestTeleport = v end,
})

local chestsStat = chestTab:CreateStat({ name = "Opened", value = 0 })
local chestCoinsStat = bigNumber(chestTab, "Coins from chests")
local chestList = chestTab:CreateText({ name = "Chests", text = "-" })

task.spawn(function()
	local lastListed = nil
	while STATE.alive() and alive do
		task.wait(1)
		local data = getData()
		if not data then continue end
		local states = chestStates(data)

		if cfg.autoChest then
			for _, chest in ipairs(states) do
				if chest.unlocked and chest.readyIn <= 0 and os.clock() >= (chestRetryAfter[chest.id] or 0) then
					claimChest(chest.id)
					task.wait(0.5)
				end
			end
		end

		local lines = {}
		for _, chest in ipairs(states) do
			local status
			if not chest.unlocked then
				status = "island locked"
			elseif chest.readyIn <= 0 then
				status = "READY"
			else
				status = "ready in " .. TapChestConfig.FormatCountdown(chest.readyIn)
			end
			table.insert(lines, ("%s  %s"):format(chest.island, status))
		end
		local text = table.concat(lines, "\n")
		pcall(function()
			if text ~= lastListed then
				lastListed = text
				chestList:Set(text)
			end
			chestsStat:Set(stats.chestsOpened)
			chestCoinsStat:Set(stats.chestCoins)
		end)
	end
end)
exports.chestStates = chestStates
end

---------------------------------------------------------------- Utils: Dig Site
do

-- DigService: RF.Begin() opens a dig {Id, Round, Remaining, Reward}; RF.Hit(Id,
-- Sequence, serverTime) answers with the next Round or {Complete, Reward, Amount}.
-- Each round is a cursor sweeping a bar, and DigConfig.Cursor(round, time) says
-- exactly where it is; a swing counts when it sits within Center ± Width/2. A hit
-- takes 1 off Remaining but a miss adds 2 back, so we only swing once the cursor is
-- well inside the window, checked every frame: each dig ends in its minimum number
-- of hits (~2s). The server allows 10 digs an hour, inside Autumn's Digsite.DigZone.

local DigRF = Remotes.DigService.RF
local DIG_AIM = 0.4 -- swing within 80% of the half-window, leaving room for frame timing

local digSession = nil -- the open dig, cancelled if the script is reloaded mid-dig
STATE.onCleanup(function()
	local id = digSession
	if id then task.spawn(function() pcall(function() DigRF.Cancel:InvokeServer(id) end) end) end
end)

local function digAllowance(data)
	return DigConfig.Allowance(data.Digging or { WindowStart = 0, Completed = 0 }, workspace:GetServerTimeNow())
end

local function prettyReward(name)
	return (tostring(name):gsub("(%l)(%u)", "%1 %2"))
end

-- Plays one dig to the end. Returns the completion reply, or nil and why not.
local function playDig()
	local ok, session = pcall(function() return DigRF.Begin:InvokeServer() end)
	if not ok or type(session) ~= "table" then return nil, "no reply" end
	if session.Error then return nil, session.Error end
	if not (session.Id and session.Round) then return nil, "no session" end
	digSession = session.Id

	local round, lastSwing = session.Round, 0
	local deadline = os.clock() + 30
	while STATE.alive() and os.clock() < deadline do
		local now = workspace:GetServerTimeNow()
		if now >= round.Epoch and now - lastSwing >= DigConfig.MinHitInterval
			and math.abs(DigConfig.Cursor(round, now) - round.Center) <= round.Width * DIG_AIM then
			lastSwing = now
			local okHit, reply = pcall(function() return DigRF.Hit:InvokeServer(session.Id, round.Sequence, now) end)
			if not okHit or type(reply) ~= "table" then break end
			if reply.Complete then
				digSession = nil
				return reply
			end
			if reply.Error then
				if reply.Error ~= "TooSoon" then break end
			elseif reply.Round then
				round = reply.Round
			end
		end
		RunService.Heartbeat:Wait()
	end

	local id = digSession
	digSession = nil
	if id then pcall(function() DigRF.Cancel:InvokeServer(id) end) end
	return nil, "dig did not finish"
end

local digTab = gamesLeft
digTab:CreateSection({ name = "Dig Site" })

digTab:CreateToggle({
	name = "Auto Dig",
	description = "Hops to the Autumn dig site, plays every dig you have with zero misses, and hops back.",
	flag = "AutoDig",
	callback = function(v) cfg.autoDig = v end,
})

local digStatus = digTab:CreateText({ name = "Status", text = "-" })
local digsStat = digTab:CreateStat({ name = "Digs done", value = 0 })

local function setDigStatus(text)
	pcall(function()
		if digStatus.text ~= text then digStatus:Set(text) end
	end)
end

-- One trip: into the dig zone, every dig that's available back to back, then back out.
local function digTrip(available)
	local site = DigWorld.GetSite()
	local zone = site and site:FindFirstChild("DigZone")
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (zone and root) then return end

	travelLock += 1
	local returnTo = nil
	if not DigWorld.Contains(zone, character) then
		returnTo = character:GetPivot()
		root.AssemblyLinearVelocity = Vector3.zero
		character:PivotTo(zone.CFrame * CFrame.new(0, 3, 0))
		task.wait(0.4) -- let the server see the new position
	end

	for n = 1, available do
		if not cfg.autoDig or not STATE.alive() then break end
		setDigStatus(("Digging %d / %d"):format(n, available))
		local reply, why = playDig()
		if not reply then
			setDigStatus("Server said: " .. tostring(why))
			break
		end
		stats.digs += 1
		activity("Dig", ("%s x%s"):format(prettyReward(reply.Reward), tostring(reply.Amount or 1)))
		pcall(function() digsStat:Set(stats.digs) end)
		task.wait(0.2)
	end

	if returnTo and character.Parent then
		root.AssemblyLinearVelocity = Vector3.zero
		character:PivotTo(returnTo)
	end
	travelLock -= 1
end

task.spawn(function()
	while STATE.alive() and alive do
		task.wait(1)
		local data = getData()
		if not data then continue end
		local unlocked = (data.Progression and data.Progression.UnlockedIslands) or {}
		local available, refill = digAllowance(data)

		if not unlocked.Autumn then
			setDigStatus("Unlock Autumn to use the dig site")
		elseif cfg.autoDig and available > 0 and travelLock == 0 then
			digTrip(available)
		elseif available > 0 then
			setDigStatus(("%d dig%s ready"):format(available, available == 1 and "" or "s"))
		else
			setDigStatus("All 10 digs used, refill in " .. TapChestConfig.FormatCountdown(refill))
		end
	end
end)
exports.digAllowance = digAllowance
end

---------------------------------------------------------------- Hatching: Eggs
do -- (Eggs and Worlds share one block: Worlds lands next to eggs with standNextToEgg)

-- Hatching: EggService.RE.EggHatchRequested({Egg, Count, Auto, Seq}); the reply
-- comes on EggHatchResult with the same Seq. The server only hatches when you
-- stand within ~9 studs of the egg (Error = "TooFar") and holds each reply for
-- the hatch animation (~2.4s), so we send one request and wait for its answer.

local HATCH_REACH = 9

-- Eggs this account can hatch: zone and island unlocked, and present in the map.
local function availableEggs(data)
	local zones = (data.Progression and data.Progression.UnlockedZones) or {}
	local islands = (data.Progression and data.Progression.UnlockedIslands) or {}
	local eggs = {}
	for name, def in pairs(LaunchEggConfig) do
		if type(def) == "table" and type(def.Price) == "number" and def.Price > 0
			and workspace:FindFirstChild("Eggs") and workspace.Eggs:FindFirstChild(name)
			and (def.Zone == nil or zones[def.Zone] == true)
			and (def.Island == nil or islands[def.Island] == true) then
			table.insert(eggs, { name = name, price = def.Price })
		end
	end
	table.sort(eggs, function(a, b) return a.price < b.price end)
	return eggs
end

local eggLabelToName = {}
local function eggOptions(eggs)
	table.clear(eggLabelToName)
	local options = {}
	for _, egg in ipairs(eggs) do
		local label = ("%s - %s"):format(egg.name, abbreviate(egg.price))
		eggLabelToName[label] = egg.name
		table.insert(options, label)
	end
	return options
end

-- Same choice as the game's own auto hatch: 8 with the pass, else 3, else 1.
local function pickHatchCount(data, egg)
	local def = LaunchEggConfig[egg]
	if not def then return nil end
	local coins = data.Currencies.Coins or 0
	local canOcto = GamepassPerks.Has(data, "x8Egg") or BoostFormula.HasType(data, "OctoHatch")
	if canOcto and EggPricing.GetTotal(data, egg, def.Price, 8) <= coins then return 8 end
	if EggPricing.GetTotal(data, egg, def.Price, 3) <= coins then return 3 end
	if EggPricing.GetUnitPrice(data, egg, def.Price) <= coins then return 1 end
	return nil
end

local function eggDistance(model)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return math.huge end
	return (root.Position - model:GetPivot().Position).Magnitude
end

-- Far islands are not streamed in until you are near them, so the ground (and the
-- egg's own parts) may not exist yet on this client: ask for the area first.
local function streamAround(position)
	pcall(function() Players.LocalPlayer:RequestStreamAroundAsync(position, 5) end)
end

-- Puts the character on solid ground right next to the egg, facing it.
local function standNextToEgg(model)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	streamAround(model:GetPivot().Position)
	local center = model:GetPivot().Position
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, model }

	local toward = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z)
	local base = toward.Magnitude > 0.1 and toward.Unit or Vector3.new(0, 0, 1)
	for step = 0, 7 do
		local dir = CFrame.Angles(0, math.rad(45 * step), 0):VectorToWorldSpace(base)
		local spot = center + dir * 7
		local hit = workspace:Raycast(Vector3.new(spot.X, center.Y + 15, spot.Z), Vector3.new(0, -40, 0), params)
		if hit and math.abs(hit.Position.Y - center.Y) < 10 then
			local stand = hit.Position + Vector3.new(0, 3, 0)
			root.AssemblyLinearVelocity = Vector3.zero
			character:PivotTo(CFrame.lookAt(stand, Vector3.new(center.X, stand.Y, center.Z)))
			return true
		end
	end
	return false
end

-- Hide hatch animation: the EggController draws every normal hatch with
-- HatchRenderer:Play(egg, result, onDone, receipt). Skipping it is enough to hide
-- the cut-scene, but onDone must still run or the controller thinks a hatch is
-- still playing and blocks the next one. Secret pets use SecretHatchRenderer and
-- keep their reveal. The original is kept in getgenv so a reload never wraps a wrapper.
getgenv().__TapAC_HatchPlay = getgenv().__TapAC_HatchPlay or HatchRenderer.Play
local originalHatchPlay = getgenv().__TapAC_HatchPlay
HatchRenderer.Play = function(self, egg, result, onDone, ...)
	if cfg.hideHatchAnimation then
		if type(onDone) == "function" then task.defer(onDone) end
		return
	end
	return originalHatchPlay(self, egg, result, onDone, ...)
end
STATE.onCleanup(function() HatchRenderer.Play = originalHatchPlay end)

local eggTab = petsLeft
eggTab:CreateSection({ name = "Auto Hatch" })

local initialEggs = initialData and availableEggs(initialData) or {}
local knownEggCount = #initialEggs
local initialEggOptions = eggOptions(initialEggs)
local defaultEggLabel = initialEggOptions[#initialEggOptions] -- most expensive unlocked egg
cfg.hatchEgg = defaultEggLabel and eggLabelToName[defaultEggLabel]

eggTab:CreateToggle({
	name = "Auto Hatch",
	description = "Takes you to the chosen egg and hatches it nonstop, 3 at a time when you can afford it.",
	flag = "AutoHatch",
	callback = function(v) cfg.autoHatch = v end,
})

local eggDropdown = eggTab:CreateDropdown({
	name = "Egg",
	description = "Only eggs on islands you have unlocked. Updates as you unlock more.",
	options = initialEggOptions,
	value = defaultEggLabel,
	flag = "HatchEgg",
	callback = function(choice)
		cfg.hatchEgg = type(choice) == "string" and eggLabelToName[choice] or cfg.hatchEgg
	end,
})

eggTab:CreateToggle({
	name = "Hide hatch animation",
	description = "Skips the egg opening animation, for auto and manual hatches. Secret pets still get their reveal.",
	flag = "HideHatchAnimation",
	callback = function(v) cfg.hideHatchAnimation = v end,
})

local hatchStatus = eggTab:CreateText({ name = "Status", text = "Idle" })
local eggsStat = eggTab:CreateStat({ name = "Hatched", value = 0 })
local eggSpentStat = bigNumber(eggTab, "Coins spent")

local function setHatchStatus(text)
	pcall(function()
		if hatchStatus.text ~= text then hatchStatus:Set(text) end
	end)
end

local hatchSeq = 7000000
local hatchReplies = {}
STATE.connect(EggHatchResult.OnClientEvent, function(r)
	if type(r) == "table" and type(r.Seq) == "number" then
		hatchReplies[r.Seq] = r
	end
end)

local function hatchOnce(data, egg)
	local model = workspace.Eggs:FindFirstChild(egg)
	if not model then
		setHatchStatus(egg .. " egg is not in the map")
		return 2
	end

	if travelLock > 0 then
		setHatchStatus("Paused while visiting a chest or machine")
		return 0.5
	end

	-- Go to the egg first, so turning Auto Hatch on or picking another egg
	-- moves you there straight away, even while still saving up for it.
	if eggDistance(model) > HATCH_REACH then
		if not standNextToEgg(model) then
			setHatchStatus("Couldn't find ground next to the egg")
			return 3
		end
		task.wait(0.5) -- let the server see the new position
	end

	local count = pickHatchCount(data, egg)
	if not count then
		setHatchStatus(("Saving up: %s costs %s"):format(egg, abbreviate(LaunchEggConfig[egg].Price)))
		return 1
	end

	hatchSeq += 1
	local seq = hatchSeq
	setHatchStatus(("Hatching %dx %s"):format(count, egg))
	EggHatchRequested:FireServer({ Egg = egg, Count = count, Auto = false, Seq = seq })

	local deadline = os.clock() + 10
	while hatchReplies[seq] == nil and os.clock() < deadline and STATE.alive() do
		task.wait(0.05)
	end
	local reply = hatchReplies[seq]
	hatchReplies[seq] = nil
	if not reply then return 1 end

	if reply.Success then
		local pets = type(reply.Pets) == "table" and reply.Pets or {}
		stats.eggsHatched += #pets
		if type(reply.Spent) == "number" then stats.eggCoinsSpent += reply.Spent end
		local names = {}
		for _, pet in ipairs(pets) do
			table.insert(names, ("%s (%s%s)%s"):format(
				tostring(pet.Name),
				tostring(pet.Rarity),
				type(pet.OneIn) == "number" and (", 1 in " .. abbreviate(pet.OneIn)) or "",
				pet.AutoDeleted and " [deleted]" or ""
			))
		end
		activity("Egg", ("%dx %s: %s"):format(#pets, egg, table.concat(names, ", ")))
		return 0
	end

	if reply.Error == "TooFar" then
		standNextToEgg(model)
		return 0.5
	end
	setHatchStatus("Server said: " .. tostring(reply.Error or reply.Reason or "no"))
	return 2
end

task.spawn(function()
	while STATE.alive() and alive do
		local data = getData()
		local pause = 0.25
		if data then
			-- Keep the egg list in step with newly unlocked islands and zones.
			local eggs = availableEggs(data)
			if #eggs ~= knownEggCount then
				knownEggCount = #eggs
				pcall(function() eggDropdown:Refresh(eggOptions(eggs)) end)
			end

			if cfg.autoHatch and cfg.hatchEgg then
				pause = hatchOnce(data, cfg.hatchEgg)
			elseif not cfg.autoHatch then
				setHatchStatus("Idle")
			end
			pcall(function()
				eggsStat:Set(stats.eggsHatched)
				eggSpentStat:Set(stats.eggCoinsSpent)
			end)
		end
		task.wait(pause)
	end
end)

---------------------------------------------------------------- Utils: Worlds

-- Islands unlock for free the moment you set foot on one: the server answers the
-- landing with IslandUnlockResult {Action = "WalkIn"} and takes no coins, so
-- "unlock all" just lands on each locked island in order. Travelling to Spawn or an
-- island you own uses the game's own IslandService.RF.Travel, which puts you on
-- that island's arrival spot. (This sits after the Eggs code to reuse standNextToEgg.)

local IslandConfig = require(ReplicatedStorage.Shared.Progression.IslandConfig)
local IslandRF = Remotes.IslandService.RF
local SPAWN = "Spawn"

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

local function islandUnlocked(island)
	if island == SPAWN then return true end
	local data = getData()
	return data ~= nil and data.Progression.UnlockedIslands[island] == true
end

-- Every island has eggs on it; standing next to one is a safe landing spot.
local function landOn(island)
	local eggs = workspace:FindFirstChild("Eggs")
	if not eggs then return false end
	for _, egg in ipairs(eggs:GetChildren()) do
		local ok, region = pcall(IslandRegions.Resolve, egg:GetPivot().Position)
		if ok and region == island and standNextToEgg(egg) then return true end
	end
	return false
end

local function travelTo(world)
	if islandUnlocked(world) then
		local ok, reply = pcall(function() return IslandRF.Travel:InvokeServer({ Island = world, Source = "Menu" }) end)
		if ok and type(reply) == "table" and reply.Success then return true end
	end
	-- Not owned yet (or the travel was refused): land there directly, which also unlocks it.
	return landOn(world)
end

-- The first island (in unlock order) that is still locked, with its price.
local function nextLockedIsland()
	for _, world in ipairs(worldOrder()) do
		if not islandUnlocked(world) then
			local def = IslandConfig.Islands[world]
			return world, def and def.Price or 0
		end
	end
	return nil
end

-- Lands on each locked island in order. The walk-in unlock only happens once you
-- hold the island's price in coins (it is not spent), and each island needs the one
-- before it, so this stops at the first island you can't afford yet.
local function unlockAllWorlds()
	local unlockedNow = {}
	local character = Players.LocalPlayer.Character
	local returnTo = character and character:GetPivot()
	travelLock += 1
	local stoppedAt, reason = nil, nil
	while true do
		local island, price = nextLockedIsland()
		if not island then break end
		local data = getData()
		if not data or (data.Currencies.Coins or 0) < price then
			stoppedAt, reason = island, ("needs %s coins"):format(abbreviate(price))
			break
		end
		if landOn(island) then
			local deadline = os.clock() + 4
			repeat task.wait(0.2) until islandUnlocked(island) or os.clock() > deadline
		end
		if not islandUnlocked(island) then
			stoppedAt, reason = island, "the server did not unlock it"
			break
		end
		table.insert(unlockedNow, island)
	end
	if returnTo and character.Parent then
		character:PivotTo(returnTo)
	end
	travelLock -= 1
	return unlockedNow, stoppedAt, reason
end

local worldTab = gamesLeft
worldTab:CreateSection({ name = "Islands" })

worldTab:CreateButton({
	name = "Unlock all worlds",
	description = "Lands on every island you can unlock - landing unlocks it, coins are not spent - then brings you back.",
	callback = function()
		task.spawn(function()
			if travelLock > 0 then
				notify("Worlds", "Busy with another hop, try again in a second.")
				return
			end
			local unlockedNow, stoppedAt, reason = unlockAllWorlds()
			local parts = {}
			if #unlockedNow > 0 then table.insert(parts, "Unlocked: " .. table.concat(unlockedNow, ", ")) end
			if stoppedAt then table.insert(parts, ("%s %s"):format(stoppedAt, reason)) end
			notify("Worlds", #parts > 0 and table.concat(parts, ". ") or "Every world is already unlocked.")
		end)
	end,
})

worldTab:CreateToggle({
	name = "Auto Unlock Worlds",
	description = "Unlocks the next island by itself as soon as you have enough coins for it.",
	flag = "AutoUnlockWorlds",
	callback = function(v) cfg.autoUnlockWorlds = v end,
})

local worldStatus = worldTab:CreateText({ name = "Teleport", text = "-" })

local worldButtons = worldTab:CreateGroup()
for _, world in ipairs(worldOrder()) do
	worldButtons:CreateButton({
		name = world,
		callback = function()
			task.spawn(function()
				if travelLock > 0 then
					notify("Teleport", "Busy with another hop, try again in a second.")
					return
				end
				if not travelTo(world) then
					notify("Teleport", "Couldn't reach " .. world .. ".")
				end
			end)
		end,
	})
end

task.spawn(function()
	while STATE.alive() and alive do
		local data = getData()
		local island, price = nextLockedIsland()
		local coins = data and data.Currencies.Coins or 0

		if cfg.autoUnlockWorlds and island and coins >= price and travelLock == 0 then
			local unlockedNow = unlockAllWorlds()
			if #unlockedNow > 0 then notify("Worlds", "Unlocked: " .. table.concat(unlockedNow, ", ")) end
			island, price = nextLockedIsland()
		end

		local text
		if not island then
			text = "All worlds unlocked. Note: Auto Hatch pulls you back to its egg."
		else
			text = ("Next: %s - %s / %s coins"):format(island, abbreviate(coins), abbreviate(price))
		end
		pcall(function()
			if worldStatus.text ~= text then worldStatus:Set(text) end
		end)
		task.wait(2)
	end
end)
exports.availableEggs = availableEggs
exports.unlockAllWorlds = unlockAllWorlds
exports.travelTo = travelTo
exports.nextLockedIsland = nextLockedIsland
end

---------------------------------------------------------------- Crafting
do

-- Golden/Diamond craft and the Rainbow fuse machine (MachineService). See the
-- comments on each part; all requests only work standing inside the machine's zone.

local ALL_PETS = "All pets"
local CRAFT_GAP = 0.45
local CRAFTS_PER_TRIP = 30
local craftUsed = {}
cfg.machines = {}

local gameCraftHandlers = {}
for _, conn in ipairs(getconnections(MachineCraftResult.OnClientEvent)) do
	if conn.Function ~= nil then table.insert(gameCraftHandlers, conn) end
end
STATE.onCleanup(function()
	for _, conn in ipairs(gameCraftHandlers) do pcall(function() conn:Enable() end) end
end)

local lastReply = {}
STATE.connect(MachineCraftResult.OnClientEvent, function(r)
	if type(r) == "table" and r.Machine and r.Action then lastReply[r.Machine .. r.Action] = r end
end)

local function machineRequest(args, hide)
	if hide then
		for _, conn in ipairs(gameCraftHandlers) do pcall(function() conn:Disable() end) end
	end
	local slot = args.Machine .. args.Action
	lastReply[slot] = nil
	MachineCraftRequested:FireServer(args)
	local deadline = os.clock() + 5
	while lastReply[slot] == nil and os.clock() < deadline do task.wait(0.03) end
	if hide then
		task.wait(0.1)
		for _, conn in ipairs(gameCraftHandlers) do pcall(function() conn:Enable() end) end
	end
	return lastReply[slot]
end

local function spareByName(data, tier)
	local equipped = {}
	for _, id in ipairs(data.Pets.Equipped or {}) do equipped[id] = true end
	local byName = {}
	for id, pet in pairs(data.Pets.Owned) do
		if pet.Tier == tier and pet.Locked ~= true and pet.Frozen == nil and not equipped[id] and not craftUsed[id] then
			byName[pet.Name] = byName[pet.Name] or {}
			table.insert(byName[pet.Name], { id = id, power = pet.Power or 0 })
		end
	end
	for _, list in pairs(byName) do
		table.sort(list, function(a, b) return a.power < b.power end)
	end
	return byName
end

local function nameOptions(data, tier)
	local names = {}
	for _, pet in pairs(data.Pets.Owned) do
		if pet.Tier == tier and not table.find(names, pet.Name) then table.insert(names, pet.Name) end
	end
	table.sort(names)
	table.insert(names, 1, ALL_PETS)
	return names
end

local function pickBatch(data, tier, selected, need, take)
	local all = table.find(selected, ALL_PETS) ~= nil
	local bestName, bestList = nil, nil
	for name, list in pairs(spareByName(data, tier)) do
		if (all or table.find(selected, name)) and #list >= need and (not bestList or #list > #bestList) then
			bestName, bestList = name, list
		end
	end
	if not bestName then return nil end
	local ids = {}
	for i = 1, math.min(take, #bestList) do ids[i] = bestList[i].id end
	return bestName, ids
end

local function machineZone(pointName, anchor, island)
	local function find()
		local data = getData()
		local unlocked = (data and data.Progression.UnlockedIslands) or {}
		local islandRoot = workspace:FindFirstChild("Ts2Islands")
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local best, bestDist = nil, math.huge
		for _, part in ipairs(CollectionService:GetTagged("InteractionPoint")) do
			if part.Name == pointName and part:IsA("BasePart") then
				local partIsland = nil
				if islandRoot and part:IsDescendantOf(islandRoot) then
					local node = part
					while node.Parent ~= islandRoot do node = node.Parent end
					partIsland = node.Name
				end
				if partIsland == nil or unlocked[partIsland] then
					local dist = root and (root.Position - part.Position).Magnitude or 0
					if dist < bestDist then best, bestDist = part, dist end
				end
			end
		end
		return best
	end
	local zone = find()
	if zone then return zone end
	local position = anchor and anchor()
	if position then
		pcall(function() Players.LocalPlayer:RequestStreamAroundAsync(position, 5) end)
		zone = find()
		if zone then return zone end
	end
	if island then
		pcall(function() Remotes.IslandService.RF.Travel:InvokeServer({ Island = island, Source = "Menu" }) end)
		task.wait(0.5)
		zone = find()
	end
	return zone
end

local function modelPosition(getModel)
	return function()
		local ok, model = pcall(getModel)
		return ok and model and model:GetPivot().Position or nil
	end
end

local function insideZone(root, part)
	local offset = part.CFrame:PointToObjectSpace(root.Position)
	local half = part.Size / 2
	return math.abs(offset.X) <= half.X and math.abs(offset.Z) <= half.Z and math.abs(offset.Y) <= half.Y + 4
end

local function atMachine(findZone, work)
	if travelLock > 0 then return false, "busy" end
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return false, "no character" end
	travelLock += 1
	local start = character:GetPivot()
	local ok, err = pcall(function()
		local zone = findZone()
		if not zone then error("Machine not found", 0) end
		if not insideZone(root, zone) then
			root.AssemblyLinearVelocity = Vector3.zero
			character:PivotTo(zone.CFrame * CFrame.new(0, -zone.Size.Y / 2 + 3, 0))
			task.wait(0.6)
		end
		work()
	end)
	if character.Parent and (root.Position - start.Position).Magnitude > 5 then
		root.AssemblyLinearVelocity = Vector3.zero
		character:PivotTo(start)
	end
	travelLock -= 1
	return ok, err
end

local function textSetter(handle)
	return function(text)
		pcall(function()
			if handle.text ~= text then handle:Set(text) end
		end)
	end
end

-- Golden (1-6 Normal -> Golden) and Diamond (1-5 Golden -> Diamond) chance machines.
local function chanceMachine(spec)
	local config = MachineConfig[spec.key]
	local state = { auto = false, pets = {}, count = #config.Chances, hide = true, made = 0, status = "Off" }
	cfg.machines[spec.key] = state

	local function chance(data, count)
		local base = config.Chances[count]
		if type(base) ~= "number" then return 0 end
		local ok, value = pcall(function()
			local withBonus = base
			if spec.key == "Golden" then
				withBonus += math.floor(MasteryFormula.GetBonus(data, "MachineGoldenChance") * 100 + 0.5)
			end
			return EnchantFormula.ApplyCraftChance(data, withBonus)
		end)
		return math.clamp(ok and value or base, 0, 100)
	end

	local chanceOptions = {}
	for count = 1, #config.Chances do
		local pct = initialData and chance(initialData, count) or config.Chances[count]
		table.insert(chanceOptions, ("%d%% - %d pet%s"):format(math.floor(pct + 0.5), count, count == 1 and "" or "s"))
	end
	local defaultChance = chanceOptions[#chanceOptions]
	for _, label in ipairs(chanceOptions) do
		if label:match("^100%%") then defaultChance = label break end
	end
	local function countFromLabel(label)
		return tonumber(type(label) == "string" and label:match("(%d+) pet") or nil)
	end
	state.count = countFromLabel(defaultChance) or #config.Chances

	local card = spec.column
	card:CreateSection({ name = spec.title })
	card:CreateToggle({ name = "Auto " .. spec.title, description = spec.blurb, flag = spec.flags.auto, callback = function(v) state.auto = v end })
	local knownNames = initialData and nameOptions(initialData, config.SourceTier) or { ALL_PETS }
	local petsDropdown = card:CreateDropdown({
		name = "Pets",
		description = ("Your %s pets. Equipped, locked and frozen ones are never used."):format(config.SourceTier),
		multiSelect = true,
		options = knownNames,
		value = {},
		placeholder = "Pick pets",
		flag = spec.flags.pets,
		callback = function(selected) state.pets = type(selected) == "table" and selected or {} end,
	})
	card:CreateDropdown({
		name = "Chance",
		description = "More pets per craft = higher chance. A failed craft still uses up the pets.",
		options = chanceOptions,
		value = defaultChance,
		flag = spec.flags.chance,
		callback = function(choice) state.count = countFromLabel(choice) or state.count end,
	})
	card:CreateToggle({ name = "Hide craft animation", value = true, flag = spec.flags.hide, callback = function(v) state.hide = v end })
	local setStatus = textSetter(card:CreateText({ name = "Status", text = "Off" }))
	local madeStat = card:CreateStat({ name = spec.madeLabel, value = 0 })
	local function setState(text) state.status = text setStatus(text) end

	local function trip(data)
		if #state.pets == 0 then setState("Pick which pets to use") return end
		if not pickBatch(data, config.SourceTier, state.pets, state.count, state.count) then
			setState(("Waiting for %d spare copies of a chosen pet"):format(state.count))
			return
		end
		if travelLock > 0 then return end
		local ok, err = atMachine(function() return machineZone(spec.point, spec.anchor, spec.island) end, function()
			local crafts = 0
			local name, ids = pickBatch(getData() or data, config.SourceTier, state.pets, state.count, state.count)
			while name and crafts < CRAFTS_PER_TRIP and state.auto and STATE.alive() do
				local pct = math.floor(chance(data, #ids) + 0.5)
				setState(("Crafting %dx %s (%d%%)"):format(#ids, name, pct))
				for _, id in ipairs(ids) do craftUsed[id] = true end
				local reply = machineRequest({ Action = "Craft", Machine = spec.key, PetIds = ids }, state.hide)
				if reply and reply.Success then
					crafts += 1
					if reply.Crafted then
						state.made += 1
						local pet = type(reply.Pet) == "table" and reply.Pet or {}
						activity(spec.short, ("Made %s %s (%d%%)"):format(tostring(pet.Tier or config.TargetTier), tostring(pet.Name or name), pct))
					else
						activity(spec.short, ("Failed: %dx %s lost (%d%%)"):format(#ids, name, pct))
					end
				else
					for _, id in ipairs(ids) do craftUsed[id] = nil end
					local reason = reply and reply.Reason
					if reason ~= "Please wait before crafting again." then
						setState("Server said: " .. tostring(reason or "no reply"))
						break
					end
				end
				task.wait(CRAFT_GAP)
				name, ids = pickBatch(getData() or data, config.SourceTier, state.pets, state.count, state.count)
			end
		end)
		if not ok and err ~= "busy" then setState(tostring(err)) end
	end

	task.spawn(function()
		while STATE.alive() and alive do
			task.wait(1)
			local data = getData()
			if not data then continue end
			local names = nameOptions(data, config.SourceTier)
			if #names ~= #knownNames then
				knownNames = names
				pcall(function() petsDropdown:Refresh(names) end)
			end
			for id in pairs(craftUsed) do
				if data.Pets.Owned[id] == nil then craftUsed[id] = nil end
			end
			if state.auto then trip(data) else setState("Off") end
			pcall(function() madeStat:Set(state.made) end)
		end
	end)
end

chanceMachine({
	key = "Golden", title = "Golden Craft", short = "Golden", column = craftLeft, point = "Golden",
	anchor = modelPosition(function() return workspace.GoldenMachine end),
	blurb = "Hops to a Golden Machine, turns your chosen Normal pets golden, and hops back.",
	madeLabel = "Made",
	flags = { auto = "AutoGolden", pets = "GoldenPets", chance = "GoldenChance", hide = "HideCraftAnimation" },
})

chanceMachine({
	key = "Diamond", title = "Diamond Craft", short = "Diamond", column = craftLeft, point = "Diamond", island = "Crystal Cave",
	anchor = modelPosition(function() return workspace.DiamondMachine end),
	blurb = "Hops to the Diamond Machine (Crystal Cave), turns your chosen Golden pets into Diamond, and hops back.",
	madeLabel = "Made",
	flags = { auto = "AutoDiamond", pets = "DiamondPets", chance = "DiamondChance", hide = "HideDiamondAnimation" },
})

-- Rainbow: {Machine="Shiny", Action="Start", PetIds} fuses 2-5 Diamond pets of one kind
-- (2 = 5h ... 5 = 30s), up to 3 at once in Data.Machines.Shiny.Queue[id] = {EndTime};
-- {Action="Claim", CraftId} collects one once its EndTime has passed.
do
	local SHINY = MachineConfig.Shiny
	local rainbow = { auto = false, claim = true, pets = {}, size = 0, hide = true, made = 0, status = "Off" }
	cfg.machines.Rainbow = rainbow

	local function duration(seconds)
		if seconds >= 3600 then return (("%.1fh"):format(seconds / 3600):gsub("%.0h", "h")) end
		if seconds >= 60 then return ("%dm"):format(math.floor(seconds / 60)) end
		return ("%ds"):format(seconds)
	end

	local FASTEST = "Fastest" -- as many as a kind has, 2 to 5
	local sizeOptions = { FASTEST }
	for count = #SHINY.Durations, SHINY.MinPets, -1 do
		table.insert(sizeOptions, ("%d pets - %s"):format(count, duration(SHINY.Durations[count])))
	end
	local function batchSize()
		if rainbow.size == 0 then return SHINY.MinPets, #SHINY.Durations end
		return rainbow.size, rainbow.size
	end

	local function queueEntries(data)
		local list = {}
		local queue = data.Machines and data.Machines.Shiny and data.Machines.Shiny.Queue or {}
		for id, entry in pairs(queue) do
			table.insert(list, { id = id, endTime = type(entry) == "table" and entry.EndTime or 0 })
		end
		table.sort(list, function(a, b) return a.endTime < b.endTime end)
		return list
	end

	local card = craftRight
	card:CreateSection({ name = "Rainbow Craft" })
	card:CreateToggle({
		name = "Auto Rainbow Craft",
		description = "Hops to the Rainbow Machine (Shadow Realm) and keeps all 3 fuse slots busy with your chosen Diamond pets.",
		flag = "AutoRainbow",
		callback = function(v) rainbow.auto = v end,
	})
	card:CreateToggle({
		name = "Auto claim finished",
		description = "Collects finished Rainbow pets, even with Auto Rainbow Craft off.",
		value = true,
		flag = "AutoClaimRainbow",
		callback = function(v) rainbow.claim = v end,
	})
	local knownNames = initialData and nameOptions(initialData, SHINY.SourceTier) or { ALL_PETS }
	local petsDropdown = card:CreateDropdown({
		name = "Pets",
		description = "Your Diamond pets. Each fuse uses 2-5 of one kind. Equipped, locked and frozen ones are never used.",
		multiSelect = true,
		options = knownNames,
		value = {},
		placeholder = "Pick pets",
		flag = "RainbowPets",
		callback = function(selected) rainbow.pets = type(selected) == "table" and selected or {} end,
	})
	local sizeDropdown = card:CreateDropdown({
		name = "Fuse size",
		description = "More pets = much faster: 5 pets take 30 seconds, 2 pets take 5 hours.",
		options = sizeOptions,
		value = FASTEST,
		flag = "RainbowSize",
		callback = function(choice)
			rainbow.size = (type(choice) == "string" and tonumber(choice:match("^(%d+) pets"))) or 0
		end,
	})
	-- A saved choice that is no longer an option shows as empty; put the default back
	-- once the saved config has been applied.
	task.delay(1.5, function()
		pcall(function()
			local current = sizeDropdown.value and sizeDropdown.value[1]
			if not (current and table.find(sizeOptions, current)) then sizeDropdown:Set(FASTEST) end
		end)
	end)
	card:CreateToggle({ name = "Hide craft animation", value = true, flag = "HideRainbowAnimation", callback = function(v) rainbow.hide = v end })
	local setStatus = textSetter(card:CreateText({ name = "Status", text = "Off" }))
	local setQueue = textSetter(card:CreateText({ name = "Fuse slots", text = "-" }))
	local madeStat = card:CreateStat({ name = "Claimed", value = 0 })
	local function setState(text) rainbow.status = text setStatus(text) end

	local function findZone()
		return machineZone("Rainbow", modelPosition(function()
			return workspace.Ts2Islands["Shadow Realm"].Folder.RainbowMachine
		end), "Shadow Realm")
	end

	local function visit(ready)
		return atMachine(findZone, function()
			for _, entry in ipairs(ready) do
				local reply = machineRequest({ Machine = "Shiny", Action = "Claim", CraftId = entry.id }, rainbow.hide)
				if reply and reply.Success then
					rainbow.made += 1
					local pet = type(reply.Pet) == "table" and reply.Pet or {}
					activity("Rainbow", "Claimed Rainbow " .. tostring(pet.Name or "pet"))
				else
					activity("Rainbow", "Claim failed: " .. tostring(reply and reply.Reason or "no reply"))
				end
				task.wait(CRAFT_GAP)
			end
			local data = getData()
			local free = data and (SHINY.MaxQueue - #queueEntries(data)) or 0
			local need, take = batchSize()
			while rainbow.auto and free > 0 and STATE.alive() do
				local name, ids = pickBatch(getData() or data, SHINY.SourceTier, rainbow.pets, need, take)
				if not name then break end
				setState(("Starting %dx %s"):format(#ids, name))
				for _, id in ipairs(ids) do craftUsed[id] = true end
				local reply = machineRequest({ Machine = "Shiny", Action = "Start", PetIds = ids }, rainbow.hide)
				if reply and reply.Success then
					free -= 1
					activity("Rainbow", ("Started %dx %s (ready in %s)"):format(#ids, name, duration(SHINY.Durations[#ids] or 0)))
				else
					for _, id in ipairs(ids) do craftUsed[id] = nil end
					setState("Server said: " .. tostring(reply and reply.Reason or "no reply"))
					break
				end
				task.wait(CRAFT_GAP)
			end
		end)
	end

	task.spawn(function()
		while STATE.alive() and alive do
			task.wait(2)
			local data = getData()
			if not data then continue end
			local names = nameOptions(data, SHINY.SourceTier)
			if #names ~= #knownNames then
				knownNames = names
				pcall(function() petsDropdown:Refresh(names) end)
			end
			local now = workspace:GetServerTimeNow()
			local queue = queueEntries(data)
			local ready = {}
			for _, entry in ipairs(queue) do
				if entry.endTime <= now then table.insert(ready, entry) end
			end
			local need, take = batchSize()
			local canStart = rainbow.auto and #rainbow.pets > 0 and #queue < SHINY.MaxQueue
				and pickBatch(data, SHINY.SourceTier, rainbow.pets, need, take) ~= nil
			if ((rainbow.claim and #ready > 0) or canStart) and travelLock == 0 then
				local ok, err = visit(ready)
				if not ok and err ~= "busy" then setState(tostring(err)) end
				data = getData() or data
				queue = queueEntries(data)
			end
			local slots = {}
			now = workspace:GetServerTimeNow()
			for i, entry in ipairs(queue) do
				local left = entry.endTime - now
				table.insert(slots, ("%d. %s"):format(i, left <= 0 and "Ready to claim" or ("ready in " .. TapChestConfig.FormatCountdown(left))))
			end
			setQueue(#slots > 0 and table.concat(slots, "\n") or ("All %d slots free"):format(SHINY.MaxQueue))
			if not rainbow.auto then
				setState(rainbow.claim and "Off (still claiming finished pets)" or "Off")
			elseif #rainbow.pets == 0 then
				setState("Pick which Diamond pets to use")
			elseif #queue >= SHINY.MaxQueue then
				setState("All 3 slots busy")
			elseif not pickBatch(data, SHINY.SourceTier, rainbow.pets, need, take) then
				setState(("Waiting for %d spare Diamond copies of a chosen pet"):format(need))
			end
			pcall(function() madeStat:Set(rainbow.made) end)
		end
	end)
end

end

---------------------------------------------------------------- Hatching: Pets
do

-- Equip best: PetService.RE.PetActionRequested({Action="EquipBest", Mode=...}), the
-- inventory's own "Best" button. The server picks the team, so we only re-send it
-- when the pet collection changes (hatch, craft, delete) or the mode changes.

local PetActionRequested = Remotes.PetService.RE.PetActionRequested
local PetActionResult = Remotes.PetService.RE.PetActionResult
local EQUIP_MODES = { "Clicks", "Gems", "Luck" }
local EQUIP_MIN_GAP = 3

local petsTab = petsRight
petsTab:CreateSection({ name = "Pets" })

local equipNow -- set below; the toggle and dropdown trigger an immediate re-equip

petsTab:CreateToggle({
	name = "Auto Equip Best",
	description = "Re-equips your best pets whenever you get new ones.",
	flag = "AutoEquipBest",
	callback = function(v)
		cfg.autoEquipBest = v
		if v and equipNow then equipNow() end
	end,
})

petsTab:CreateDropdown({
	name = "Best for",
	description = "Which stat the team is picked for, same as the inventory's Best button.",
	options = EQUIP_MODES,
	value = "Clicks",
	flag = "EquipMode",
	callback = function(choice)
		if type(choice) == "string" and table.find(EQUIP_MODES, choice) then
			cfg.equipMode = choice
			if cfg.autoEquipBest and equipNow then equipNow() end
		end
	end,
})

local teamMultiplierStat = petsTab:CreateStat({ name = "Team multiplier", prefix = "x", value = 0 })
local teamText = petsTab:CreateText({ name = "Equipped", text = "-" })

STATE.connect(PetActionResult.OnClientEvent, function(r)
	if type(r) == "table" and r.Action == "EquipBest" and r.Success and type(r.PowerMultiplier) == "number" then
		pcall(function() teamMultiplierStat:Set(r.PowerMultiplier) end)
	end
end)

-- Cheap fingerprint of the collection: changes on any hatch, craft or delete.
local function petsSignature(data)
	local count, power = 0, 0
	for _, pet in pairs(data.Pets.Owned) do
		count += 1
		power += pet.Power or 0
	end
	return count .. ":" .. power
end

local lastEquipAt, lastSignature = 0, nil
function equipNow()
	lastSignature = nil -- forces the next tick to send
end

task.spawn(function()
	while STATE.alive() and alive do
		task.wait(1)
		local data = getData()
		if not data then continue end

		if cfg.autoEquipBest then
			local signature = petsSignature(data) .. ":" .. cfg.equipMode
			if signature ~= lastSignature and os.clock() - lastEquipAt >= EQUIP_MIN_GAP then
				lastSignature, lastEquipAt = signature, os.clock()
				PetActionRequested:FireServer({ Action = "EquipBest", Mode = cfg.equipMode })
			end
		end

		local names = {}
		for _, id in ipairs(data.Pets.Equipped or {}) do
			local pet = data.Pets.Owned[id]
			if pet then
				table.insert(names, (pet.Tier ~= "Normal" and (pet.Tier .. " ") or "") .. tostring(pet.Name))
			end
		end
		local body = #names > 0 and table.concat(names, ", ") or "Nothing equipped"
		pcall(function()
			if teamText.text ~= body then teamText:Set(body) end
		end)
	end
end)
end

---------------------------------------------------------------- Farming: Auto Break
do

-- Breakables (tagged "Breakable": the 10 HP ClickerChests, plus each player's own
-- island breakable) take damage from taps: every tap the server accepts hits the
-- nearest breakable within BreakableConfig.TapRange (14 studs). So breaking one is
-- standing next to it while taps go out; the server pays out on BreakableService.RE.Rewarded.

local BREAK_STAND = 6 -- studs from the breakable's edge
local LocalUserId = Players.LocalPlayer.UserId

local function breakableTargets(data)
	local unlocked = (data.Progression and data.Progression.UnlockedIslands) or {}
	local attrs = BreakableConfig.Attributes
	local targets = {}
	for _, model in ipairs(CollectionService:GetTagged(BreakableConfig.Tag)) do
		local rest = model:GetAttribute(attrs.Rest)
		local owner = model:GetAttribute(attrs.Owner)
		if typeof(rest) == "CFrame" and model:IsDescendantOf(workspace)
			and (model:GetAttribute(attrs.Health) or 0) > 0
			and not model:GetAttribute(attrs.Broken) and not model:GetAttribute(attrs.Despawned)
			and (owner == nil or owner == LocalUserId) then
			local ok, island = pcall(IslandRegions.Resolve, rest.Position)
			island = ok and island or nil
			if island == nil or island == "Spawn" or unlocked[island] then
				table.insert(targets, { model = model, rest = rest })
			end
		end
	end
	return targets
end

local function breakableAlive(model)
	local attrs = BreakableConfig.Attributes
	return model.Parent ~= nil and (model:GetAttribute(attrs.Health) or 0) > 0
		and not model:GetAttribute(attrs.Broken) and not model:GetAttribute(attrs.Despawned)
end

-- Stand on the ground right next to the breakable, facing it.
local function standNextToBreakable(target)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	local center = target.rest.Position
	pcall(function() Players.LocalPlayer:RequestStreamAroundAsync(center, 5) end)
	local size = target.model:GetAttribute(BreakableConfig.Attributes.Size)
	local reach = (typeof(size) == "Vector3" and math.max(size.X, size.Z) * 0.5 or 2) + BREAK_STAND
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, target.model }

	local toward = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z)
	local base = toward.Magnitude > 0.1 and toward.Unit or target.rest.LookVector
	for step = 0, 7 do
		local dir = CFrame.Angles(0, math.rad(45 * step), 0):VectorToWorldSpace(base)
		local spot = center + dir * reach
		local hit = workspace:Raycast(Vector3.new(spot.X, center.Y + 12, spot.Z), Vector3.new(0, -30, 0), params)
		if hit and math.abs(hit.Position.Y - center.Y) < 8 then
			local stand = hit.Position + Vector3.new(0, 3, 0)
			root.AssemblyLinearVelocity = Vector3.zero
			character:PivotTo(CFrame.lookAt(stand, Vector3.new(center.X, stand.Y, center.Z)))
			return true
		end
	end
	return false
end

STATE.connect(Remotes.BreakableService.RE.Rewarded.OnClientEvent, function()
	stats.chestsBroken += 1
end)

-- One round: break every reachable breakable, nearest first, then go back.
local function breakRound(data)
	if travelLock > 0 then return end
	local targets = breakableTargets(data)
	if #targets == 0 then return end
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	travelLock += 1
	local returnTo = character:GetPivot()
	local skipped = {}
	while cfg.autoBreak and STATE.alive() do
		local nearest, nearestDist = nil, math.huge
		for _, target in ipairs(breakableTargets(getData() or data)) do
			if not skipped[target.model] then
				local dist = (root.Position - target.rest.Position).Magnitude
				if dist < nearestDist then nearest, nearestDist = target, dist end
			end
		end
		if not nearest then break end

		if standNextToBreakable(nearest) then
			breakingNow = true
			-- Island breakables roam (hop a few studs at a time), so follow the
			-- current rest spot; give up only once the health stops dropping.
			local attrs = BreakableConfig.Attributes
			local size = nearest.model:GetAttribute(attrs.Size)
			local lastHealth = nearest.model:GetAttribute(attrs.Health)
			local lastProgress = os.clock()
			while breakableAlive(nearest.model) and cfg.autoBreak and os.clock() - lastProgress < 3 do
				local rest = nearest.model:GetAttribute(attrs.Rest)
				if typeof(rest) == "CFrame" and typeof(size) == "Vector3"
					and not BreakableConfig.InRange(root.Position, rest, size) then
					nearest.rest = rest
					standNextToBreakable(nearest)
				end
				local health = nearest.model:GetAttribute(attrs.Health)
				if health ~= lastHealth then
					lastHealth, lastProgress = health, os.clock()
				end
				task.wait(0.1)
			end
			breakingNow = false
		end
		if breakableAlive(nearest.model) then skipped[nearest.model] = true end
		task.wait(0.15)
	end
	breakingNow = false

	if character.Parent then
		root.AssemblyLinearVelocity = Vector3.zero
		character:PivotTo(returnTo)
	end
	travelLock -= 1
end

task.spawn(function()
	while STATE.alive() and alive do
		task.wait(1)
		local data = getData()
		if data and cfg.autoBreak then breakRound(data) end
	end
end)
exports.breakableTargets = breakableTargets
end

---------------------------------------------------------------- Settings: Performance
do

-- PC load and staying online. Everything here is undone when switched off (or when
-- the script is reloaded): rendering comes back, the FPS cap goes back to what it
-- was, and every effect the boost turned off is turned back on.
-- Auto reconnect rejoins the game when the client is kicked or disconnected, and
-- queues the hub to load again in the new server from a copy of this script in the
-- executor workspace (HUB_FILE).

local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")
local HUB_FILE = "TapSimHub.luau"

local card = settingsRight
card:CreateSection({ name = "Performance" })

-- Disable 3D rendering: the world stops drawing (white screen); the game keeps running.
card:CreateToggle({
	name = "No 3D render",
	flag = "No3DRendering",
	callback = function(v) pcall(function() RunService:Set3dRenderingEnabled(not v) end) end,
})
STATE.onCleanup(function() pcall(function() RunService:Set3dRenderingEnabled(true) end) end)

-- FPS cap.
local okCap, originalCap = pcall(getfpscap)
if not okCap or type(originalCap) ~= "number" then originalCap = 60 end
local capOn, capValue = false, 30
local function applyCap()
	pcall(setfpscap, capOn and capValue or originalCap)
end
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
	range = { 5, 240 },
	increment = 5,
	value = 30,
	suffix = " fps",
	flag = "FpsLimit",
	callback = function(v)
		capValue = v
		applyCap()
	end,
})
STATE.onCleanup(function() pcall(setfpscap, originalCap) end)

-- FPS boost: particles, trails, beams, smoke/fire/sparkles and post effects off,
-- shadows off. Originals are remembered per instance and put back on switch-off.
local boosted = {} -- [instance] = { [property] = original value }
local boostConnection = nil
local boostOn = false

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
					if i % 3000 == 0 then task.wait() end -- spread big maps over a few frames
				end
			end
		end)
		boostConnection = workspace.DescendantAdded:Connect(function(inst)
			if boostOn then boostInstance(inst) end
		end)
		activity("Settings", "FPS boost on")
	else
		if boostConnection then
			boostConnection:Disconnect()
			boostConnection = nil
		end
		for inst, saved in pairs(boosted) do
			for prop, value in pairs(saved) do
				pcall(function() inst[prop] = value end)
			end
		end
		table.clear(boosted)
		activity("Settings", "FPS boost off, effects restored")
	end
end

card:CreateToggle({
	name = "FPS Boost",
	flag = "FpsBoost",
	callback = function(v) setBoost(v) end,
})
STATE.onCleanup(function() setBoost(false) end)

-- Auto reconnect.
card:CreateSection({ name = "Connection" })

local reconnectOn = false
local rejoining = false

-- Queues this hub to load again after the rejoin, once the new server is ready.
local function queueHub()
	local ok, exists = pcall(isfile, HUB_FILE)
	if not (ok and exists) then return false end
	local loader = ([[
if not game:IsLoaded() then game.Loaded:Wait() end
game:GetService("ReplicatedStorage"):WaitForChild("RemoteServices", 120)
task.wait(8)
loadstring(readfile(%q))()
]]):format(HUB_FILE)
	return (pcall(queue_on_teleport, loader))
end

-- Callbacks only ask for a rejoin; the loop below (the script's own thread) does it.
local rejoinReason = nil
local function rejoin(reason)
	rejoinReason = rejoinReason or reason
end

task.spawn(function()
	while STATE.alive() and not rejoinReason do task.wait(0.25) end
	if not STATE.alive() then return end
	rejoining = true
	local queued = queueHub()
	activity("Reconnect", ("%s - rejoining%s"):format(rejoinReason, queued and ", hub will reload" or ""))
	while STATE.alive() do
		pcall(function() TeleportService:Teleport(game.PlaceId, Players.LocalPlayer) end)
		task.wait(10) -- keep trying until the teleport goes through
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

-- A kick or disconnect shows Roblox's error prompt and sets GuiService's error message.
STATE.connect(GuiService.ErrorMessageChanged, function(message)
	if reconnectOn and not rejoining and type(message) == "string" and message ~= "" then
		rejoin("Disconnected: " .. message)
	end
end)
task.spawn(function()
	pcall(function()
		local overlay = game:GetService("CoreGui"):WaitForChild("RobloxPromptGui", 10):WaitForChild("promptOverlay", 10)
		STATE.connect(overlay.ChildAdded, function(child)
			if reconnectOn and not rejoining and child.Name == "ErrorPrompt" then
				rejoin("Kicked")
			end
		end)
	end)
end)

exports.performance = { setBoost = setBoost, boosted = boosted, queueHub = queueHub }
end

---------------------------------------------------------------- tapping

STATE.connect(TapResult.OnClientEvent, function(r)
	if type(r) ~= "table" then return end
	stats.accepted += 1
	if r.Critical then stats.crits += 1 end
	if type(r.Amount) == "number" then stats.earned += r.Amount end
end)

-- Pacing on Heartbeat with a running deadline, so the rate holds steady
-- instead of drifting the way a task.wait loop does.
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
	stats.sent += 1
	TapRequested:FireServer({ Auto = false, ClientSequence = seq })
end)

---------------------------------------------------------------- rebirthing

local rebirthPending = false
STATE.connect(RebirthResult.OnClientEvent, function(r)
	rebirthPending = false
	if type(r) == "table" and r.Success and type(r.Amount) == "number" then
		stats.rebirthsDone += r.Amount
	end
end)

task.spawn(function()
	local lastFire = 0
	while STATE.alive() and alive do
		task.wait(0.25)
		local data = getData()
		if not data then continue end

		-- Keep the dropdown in sync with what this account has unlocked.
		local count = unlockedOptionCount(data)
		if count ~= knownCount then
			knownCount = count
			pcall(function() amountDropdown:Refresh(buildOptions(count)) end)
			if not labelToIndex[cfg.rebirthChoice] then cfg.rebirthChoice = MAX_LABEL end
		end

		local index = selectedIndex(count)
		local amount = RebirthConfig.GetAmountFromIndex(index)
		local price = RebirthConfig.GetPrice(amount, data.Statistics.Rebirths)
		local coins = data.Currencies.Coins

		pcall(function()
			local title = ("Target: +%s rebirths"):format(abbreviate(amount))
			local body = ("%s%s / %s coins (%d%%)"):format(
				cfg.rebirthChoice == MAX_LABEL and "Max button - " or "",
				abbreviate(coins),
				abbreviate(math.ceil(price)),
				math.floor(math.clamp(coins / price * 100, 0, 100))
			)
			if targetText.name ~= title then targetText:SetTitle(title) end
			if targetText.text ~= body then targetText:Set(body) end
		end)

		local now = os.clock()
		if cfg.autoRebirth and coins >= price and not rebirthPending and now - lastFire >= REBIRTH_COOLDOWN then
			lastFire = now
			rebirthPending = true
			RebirthRequested:FireServer({ Index = index })
			task.delay(3, function() rebirthPending = false end) -- never wedge on a lost reply
		end
	end
end)

---------------------------------------------------------------- stats refresh

task.spawn(function()
	local lastAccepted, lastT = 0, os.clock()
	while STATE.alive() and alive do
		task.wait(1)
		local now = os.clock()
		local rate = (stats.accepted - lastAccepted) / (now - lastT)
		lastAccepted, lastT = stats.accepted, now
		local data = getData()
		pcall(function()
			if data then
				coinsStat:Set(data.Currencies.Coins)
				rebirthStat:Set(data.Statistics.Rebirths)
				gemsStat:Set(data.Currencies.Gems or 0)
			end
			upgradesStat:Set(stats.upgradesBought)
			cpsStat:Set(math.floor(rate * 10 + 0.5) / 10)
			earnedStat:Set(stats.earned)
			critStat:Set(stats.crits)
			brokenStat:Set(stats.chestsBroken)
			doneStat:Set(stats.rebirthsDone)
			if data and data.Mining then homeMiningStat:Set(data.Mining.Coins or 0) end
		end)

		-- Home "Running" card: every automation that is on.
		local machines = cfg.machines or {}
		local running = {}
		local function add(on, label)
			if on then table.insert(running, label) end
		end
		add(cfg.enabled, ("Auto Tap (%.1f/s)"):format(rate))
		add(cfg.autoBreak, "Auto Break")
		add(cfg.autoRebirth, "Auto Rebirth")
		add(cfg.autoUpgrade, "Auto Upgrade")
		add(cfg.autoClaimQuests, "Auto Quests")
		add(cfg.autoChest, "Auto Chest")
		add(cfg.autoHatch, "Auto Hatch (" .. tostring(cfg.hatchEgg) .. ")")
		add(cfg.autoEquipBest, "Equip Best (" .. tostring(cfg.equipMode) .. ")")
		add(machines.Golden and machines.Golden.auto, "Golden Craft")
		add(machines.Diamond and machines.Diamond.auto, "Diamond Craft")
		add(machines.Rainbow and machines.Rainbow.auto, "Rainbow Craft")
		add(cfg.autoDig, "Auto Dig")
		add(cfg.autoMine, "Auto Mine")
		add(cfg.autoUnlockWorlds, "Auto Unlock Worlds")
		local body = #running > 0 and table.concat(running, "\n") or "Nothing is on"
		pcall(function()
			if runningText.text ~= body then runningText:Set(body) end
		end)
	end
end)

exports.window = window
exports.cfg = cfg
exports.stats = stats
exports.tapToggle = tapToggle
exports.amountDropdown = amountDropdown
exports.scanUpgrades = scanUpgrades
exports.describeUpgrades = describeUpgrades
exports.notify = notify
getgenv().__TapAC = exports

window:Notify({ title = "Tap Simulator hub loaded", content = "Home, Automation, Pets, Crafting and Minigames are ready." })
