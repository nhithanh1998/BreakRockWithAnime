-- DataService: saves / loads each player's progress with DataStoreService (DataStore "PlayerData",
-- key "u_<UserId>").
--
-- Saved:  Money (leaderstats.Money), Inventory + Heroes (IntValues), Axes owned + EquippedAxe,
--         UnlockedSlots (bought hero pads), AutoSell, which heroes stand on which pad, each pad's
--         upgrade levels (PadLevels, HeroSlotService), and skill
--         tree levels (player.Skills, SkillTreeService), UnlockedZones + CurrentZone (Zones board).
--         The plot's TreasureChest contents (Chest; the shared fallback chest is not saved).
--         Devil Fruits: Fertilizer bags, owned fruits (Fruits) and the fruit on each pad (PadFruits).
--         7 Day Login Rewards streak (Daily, DailyRewardService).
--         Potions owned + time left on active ones (Potions / PotionTime, PotionService).
--         Index: found items and claimed zone rewards (IndexFound / IndexClaimed, IndexService).
-- Not saved: trees.
--
-- Load: when the player joins (3 tries). Saved amounts are ADDED to whatever the player already
--   picked up during the load, so nothing gained in the first seconds is lost. If loading fails the
--   player keeps playing but that session is NOT saved, so a broken load can never wipe a save.
-- Save: on leave, every AUTOSAVE_INTERVAL seconds, and when the server shuts down (BindToClose).
-- Player attribute "DataLoaded" = true once their data is in.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))
local ShopService = require(script.Parent:WaitForChild("ShopService"))
local HeroSlotService = require(script.Parent:WaitForChild("HeroSlotService"))
local SkillTreeService = require(script.Parent:WaitForChild("SkillTreeService"))
local FruitService = require(script.Parent:WaitForChild("FruitService"))
local DailyRewardService = require(script.Parent:WaitForChild("DailyRewardService"))
local PotionService = require(script.Parent:WaitForChild("PotionService"))
local IndexService = require(script.Parent:WaitForChild("IndexService"))

local STORE_NAME = "PlayerData"
local DATA_VERSION = 1
local AUTOSAVE_INTERVAL = 120 -- seconds
local RETRIES = 3

export type SaveData = {
	Version: number,
	SavedAt: number,
	Money: number,
	Inventory: { [string]: number },
	Heroes: { [string]: number },
	Axes: { string },
	AxeCopies: { [string]: number }?, -- axe model -> copies owned
	PadAxes: { [string]: string }?, -- slot index (as text) -> axe model held by that pad's hero
	EquippedAxe: string?,
	UnlockedSlots: number?,
	AutoSell: boolean?,
	Placed: { [string]: string }?, -- slot index (as text) -> hero name
	PadLevels: { [string]: { [string]: number } }?, -- slot index (as text) -> stat -> level, "Grade<stat>" -> grade position
	Skills: { [string]: number }?, -- "Tree/Node" -> level
	UnlockedZones: number?, -- highest zone bought on the Zones board (ZoneBoardService)
	CurrentZone: number?, -- zone the plot is set to
	Chest: { [string]: number }?, -- plot chest stack name -> amount (ChestService)
	Fertilizer: number?, -- Devil Fruit fertilizer bags (FruitService)
	Fruits: { [string]: number }?, -- fruit id -> copies owned
	PadFruits: { [string]: string }?, -- slot index (as text) -> fruit id on that pad
	Daily: { Unlocked: number, Claimed: number, LastAt: number? }?, -- 7 Day Login Rewards (DailyRewardService)
	Potions: { [string]: number }?, -- potion id -> owned (PotionService)
	PotionTime: { [string]: number }?, -- potion id -> seconds left on the active one
	IndexFound: { string }?, -- Index stacks found (IndexService)
	IndexClaimed: { [string]: number }?, -- zone (as text) -> claimed milestone mask
}

local DataService = {}

local store: DataStore? = nil
local loaded: { [Player]: boolean } = {}
local saving: { [Player]: boolean } = {}
local placedCache: { [Player]: { [string]: string } } = {}
local levelsCache: { [Player]: { [string]: { [string]: number } } } = {}
local padAxesCache: { [Player]: { [string]: string } } = {}
local padFruitsCache: { [Player]: { [string]: string } } = {}
local chestCache: { [Player]: { [string]: number } } = {}

local function keyFor(player: Player): string
	return "u_" .. player.UserId
end

-- Runs fn up to RETRIES times (DataStore calls can fail / be throttled).
local function withRetries(what: string, fn: () -> any): (boolean, any)
	local lastError: any = nil
	for attempt = 1, RETRIES do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastError = result
		warn(("[DataService] %s failed (try %d/%d): %s"):format(what, attempt, RETRIES, tostring(result)))
		if attempt < RETRIES then
			task.wait(attempt * 2)
		end
	end
	return false, lastError
end

-- Collecting -----------------------------------------------------------------------------------------

local function counts(folder: Instance?): { [string]: number }
	local out = {}
	if folder then
		for _, v in folder:GetChildren() do
			if v:IsA("IntValue") and v.Value > 0 then
				out[v.Name] = v.Value
			end
		end
	end
	return out
end

-- Asks HeroSlotService directly (not PlotService): on leave PlotService may already have let go of
-- the plot while the pads still hold the heroes.
local function placedNow(player: Player): { [string]: string }?
	local placed = HeroSlotService.GetPlacedFor(player)
	if not placed then
		return nil
	end
	local out = {}
	for index, hero in placed do
		out[tostring(index)] = hero
	end
	return out
end

local function levelsNow(player: Player): { [string]: { [string]: number } }?
	local levels = HeroSlotService.GetLevelsFor(player)
	if not levels then
		return nil
	end
	local out = {}
	for index, stats in levels do
		out[tostring(index)] = stats
	end
	return out
end

local function padAxesNow(player: Player): { [string]: string }?
	local axes = HeroSlotService.GetAxesFor(player)
	if not axes then
		return nil
	end
	local out = {}
	for index, model in axes do
		out[tostring(index)] = model
	end
	return out
end

local function padFruitsNow(player: Player): { [string]: string }?
	local fruits = HeroSlotService.GetFruitsFor(player)
	if not fruits then
		return nil
	end
	local out = {}
	for index, id in fruits do
		out[tostring(index)] = id
	end
	return out
end

local function collect(player: Player): SaveData
	local axes = {}
	local axeCopies = {}
	local axesFolder = player:FindFirstChild("Axes")
	if axesFolder then
		for _, v in axesFolder:GetChildren() do
			if v:IsA("BoolValue") and v.Value then
				table.insert(axes, v.Name)
				local n = v:GetAttribute("Copies")
				axeCopies[v.Name] = if typeof(n) == "number" then n else 1
			end
		end
	end
	local unlocked = player:GetAttribute("UnlockedSlots")
	local equipped = player:GetAttribute("EquippedAxe")
	local unlockedZones = player:GetAttribute("UnlockedZones")
	local currentZone = player:GetAttribute("CurrentZone")
	local fertilizer, fruits = FruitService.GetSaveData(player)
	local potions, potionTime = PotionService.GetSaveData(player)
	local indexFound, indexClaimed = IndexService.GetSaveData(player)
	return {
		Version = DATA_VERSION,
		SavedAt = os.time(),
		Money = ChestService.GetMoney(player),
		Inventory = counts(player:FindFirstChild("Inventory")),
		Heroes = counts(player:FindFirstChild("Heroes")),
		Axes = axes,
		AxeCopies = axeCopies,
		PadAxes = padAxesNow(player) or padAxesCache[player],
		EquippedAxe = if typeof(equipped) == "string" then equipped else nil,
		UnlockedSlots = if typeof(unlocked) == "number" then unlocked else nil,
		AutoSell = player:GetAttribute("AutoSell") == true,
		Placed = placedNow(player) or placedCache[player],
		PadLevels = levelsNow(player) or levelsCache[player],
		Skills = counts(player:FindFirstChild("Skills")),
		UnlockedZones = if typeof(unlockedZones) == "number" then unlockedZones else nil,
		CurrentZone = if typeof(currentZone) == "number" then currentZone else nil,
		-- Cache first: once the plot is released its chest is already emptied.
		Chest = chestCache[player] or ChestService.GetContentsFor(player),
		Fertilizer = fertilizer,
		Fruits = fruits,
		PadFruits = padFruitsNow(player) or padFruitsCache[player],
		Daily = DailyRewardService.GetSaveData(player),
		Potions = potions,
		PotionTime = potionTime,
		IndexFound = indexFound,
		IndexClaimed = indexClaimed,
	}
end

-- Applying -------------------------------------------------------------------------------------------

local function apply(player: Player, data: SaveData)
	if typeof(data.Money) == "number" and data.Money > 0 then
		ChestService.AddMoney(player, data.Money)
	end
	for name, amount in data.Inventory or {} do
		if typeof(amount) == "number" and amount > 0 then
			ChestService.AddItem(player, "Inventory", name, amount)
		end
	end
	for name, amount in data.Heroes or {} do
		if typeof(amount) == "number" and amount > 0 then
			ChestService.AddItem(player, "Heroes", HeroConfig.CurrentName(name), amount)
		end
	end
	ShopService.ApplySaved(player, data.Axes or {}, data.EquippedAxe, data.AxeCopies)
	if typeof(data.UnlockedSlots) == "number" then
		local now = player:GetAttribute("UnlockedSlots")
		player:SetAttribute("UnlockedSlots", math.max(data.UnlockedSlots, if typeof(now) == "number" then now else 0))
	end
	if typeof(data.AutoSell) == "boolean" then
		player:SetAttribute("AutoSell", data.AutoSell)
	end
	if typeof(data.UnlockedZones) == "number" then
		local now = player:GetAttribute("UnlockedZones")
		player:SetAttribute("UnlockedZones", math.max(data.UnlockedZones, if typeof(now) == "number" then now else 1))
	end
	if typeof(data.CurrentZone) == "number" and player:GetAttribute("CurrentZone") == nil then
		player:SetAttribute("CurrentZone", data.CurrentZone)
	end
	SkillTreeService.ApplySaved(player, data.Skills)
	if typeof(data.Chest) == "table" then
		local stacks: { [string]: number } = {}
		for name, amount in data.Chest do
			if typeof(name) == "string" and typeof(amount) == "number" and amount > 0 then
				if name:sub(1, 6) == "Anime:" then
					name = "Anime:" .. HeroConfig.CurrentName(name:sub(7))
				end
				stacks[name] = (stacks[name] or 0) + math.floor(amount)
			end
		end
		if next(stacks) then
			ChestService.RestoreContents(player, stacks)
		end
	end
	if typeof(data.PadLevels) == "table" then
		local levels: { [number]: { [string]: number } } = {}
		for index, stats in data.PadLevels do
			local i = tonumber(index)
			if i and typeof(stats) == "table" then
				local clean = {}
				for stat, level in stats do
					if typeof(stat) == "string" and typeof(level) == "number" then
						clean[stat] = math.max(1, math.floor(level))
					end
				end
				levels[i] = clean
			end
		end
		HeroSlotService.RestoreLevels(player, levels)
	end
	if typeof(data.PadAxes) == "table" then
		local padAxes: { [number]: string } = {}
		for index, model in data.PadAxes do
			local i = tonumber(index)
			if i and typeof(model) == "string" then
				padAxes[i] = model
			end
		end
		HeroSlotService.RestoreAxes(player, padAxes)
	end
	FruitService.ApplySaved(player, data.Fertilizer, data.Fruits)
	DailyRewardService.ApplySaved(player, data.Daily)
	PotionService.ApplySaved(player, data.Potions, data.PotionTime)
	IndexService.ApplySaved(player, data.IndexFound, data.IndexClaimed)
	if typeof(data.PadFruits) == "table" then
		local padFruits: { [number]: string } = {}
		for index, id in data.PadFruits do
			local i = tonumber(index)
			if i and typeof(id) == "string" then
				padFruits[i] = id
			end
		end
		HeroSlotService.RestoreFruits(player, padFruits)
	end
	if data.Placed then
		local placed: { [number]: string } = {}
		for index, hero in data.Placed do
			local i = tonumber(index)
			if i and typeof(hero) == "string" then
				placed[i] = HeroConfig.CurrentName(hero)
			end
		end
		HeroSlotService.RestorePlaced(player, placed)
	end
end

-- Load / save ----------------------------------------------------------------------------------------

local function load(player: Player)
	if not store then
		return
	end
	local ok, data = withRetries("load " .. keyFor(player), function()
		return (store :: DataStore):GetAsync(keyFor(player))
	end)
	if not player.Parent then
		return
	end
	if not ok then
		warn(("[DataService] could not load %s; this session will NOT be saved"):format(player.Name))
		player:SetAttribute("DataLoaded", false)
		return
	end
	if typeof(data) == "table" then
		apply(player, data :: SaveData)
	end
	loaded[player] = true
	player:SetAttribute("DataLoaded", true)
end

function DataService.Save(player: Player): boolean
	if not store or not loaded[player] then
		return false
	end
	-- One save at a time per player; a save asked for meanwhile (e.g. on leave) runs right after.
	while saving[player] do
		task.wait(0.1)
	end
	-- The leave-save may have finished while we waited; the plot is cleared by then, so saving
	-- again would drop the heroes on the pads.
	if not loaded[player] then
		return false
	end
	saving[player] = true
	local data = collect(player)
	local ok = withRetries("save " .. keyFor(player), function()
		return (store :: DataStore):UpdateAsync(keyFor(player), function()
			return data
		end)
	end)
	saving[player] = nil
	return ok
end

-- Call before the player's plot is cleared (PlotService.PlotReleased) so the heroes on its pads
-- are still known when the leave-save runs.
function DataService.RememberPlaced(player: Player)
	local placed = placedNow(player)
	if placed then
		placedCache[player] = placed
	end
	local levels = levelsNow(player)
	if levels then
		levelsCache[player] = levels
	end
	local padAxes = padAxesNow(player)
	if padAxes then
		padAxesCache[player] = padAxes
	end
	local padFruits = padFruitsNow(player)
	if padFruits then
		padFruitsCache[player] = padFruits
	end
	-- Keep the first snapshot: a later call (after PlotReleased) would only see the emptied chest.
	local chest = ChestService.GetContentsFor(player)
	if chest and not chestCache[player] then
		chestCache[player] = chest
	end
end

local function onLeave(player: Player)
	DataService.RememberPlaced(player)
	DataService.Save(player)
	-- Same thread, no yield after Save returns: a save waiting in BindToClose sees this and skips.
	loaded[player] = nil
	placedCache[player] = nil
	levelsCache[player] = nil
	padAxesCache[player] = nil
	padFruitsCache[player] = nil
	chestCache[player] = nil
	DailyRewardService.Forget(player)
end

function DataService.Start()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[DataService] DataStores unavailable (in Studio: Game Settings > Security > Enable Studio Access to API Services): " .. tostring(result))
	end

	Players.PlayerAdded:Connect(load)
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
	Players.PlayerRemoving:Connect(onLeave)

	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for _, player in Players:GetPlayers() do
				task.spawn(DataService.Save, player)
				task.wait(0.5) -- spread the requests out
			end
		end
	end)

	game:BindToClose(function()
		local pending = 0
		for _, player in Players:GetPlayers() do
			pending += 1
			task.spawn(function()
				DataService.RememberPlaced(player)
				DataService.Save(player)
				pending -= 1
			end)
		end
		local start = os.clock()
		while pending > 0 and os.clock() - start < 25 do
			task.wait(0.1)
		end
	end)
end

return DataService
