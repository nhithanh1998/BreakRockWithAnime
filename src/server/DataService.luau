-- DataService: saves / loads each player's progress with DataStoreService (DataStore "PlayerData",
-- key "u_<UserId>").
--
-- Saved:  Money (leaderstats.Money), Inventory + Heroes (IntValues), Axes owned + EquippedAxe,
--         UnlockedSlots (bought hero pads), AutoSell, and which heroes stand on which pad.
-- Not saved: the shared TreasureChest's contents (it isn't anyone's) and trees.
--
-- Load: when the player joins (3 tries). Saved amounts are ADDED to whatever the player already
--   picked up during the load, so nothing gained in the first seconds is lost. If loading fails the
--   player keeps playing but that session is NOT saved, so a broken load can never wipe a save.
-- Save: on leave, every AUTOSAVE_INTERVAL seconds, and when the server shuts down (BindToClose).
-- Player attribute "DataLoaded" = true once their data is in.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local ChestService = require(script.Parent:WaitForChild("ChestService"))
local ShopService = require(script.Parent:WaitForChild("ShopService"))
local HeroSlotService = require(script.Parent:WaitForChild("HeroSlotService"))

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
	EquippedAxe: string?,
	UnlockedSlots: number?,
	AutoSell: boolean?,
	Placed: { [string]: string }?, -- slot index (as text) -> hero name
}

local DataService = {}

local store: DataStore? = nil
local loaded: { [Player]: boolean } = {}
local saving: { [Player]: boolean } = {}
local placedCache: { [Player]: { [string]: string } } = {}

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

local function collect(player: Player): SaveData
	local axes = {}
	local axesFolder = player:FindFirstChild("Axes")
	if axesFolder then
		for _, v in axesFolder:GetChildren() do
			if v:IsA("BoolValue") and v.Value then
				table.insert(axes, v.Name)
			end
		end
	end
	local unlocked = player:GetAttribute("UnlockedSlots")
	local equipped = player:GetAttribute("EquippedAxe")
	return {
		Version = DATA_VERSION,
		SavedAt = os.time(),
		Money = ChestService.GetMoney(player),
		Inventory = counts(player:FindFirstChild("Inventory")),
		Heroes = counts(player:FindFirstChild("Heroes")),
		Axes = axes,
		EquippedAxe = if typeof(equipped) == "string" then equipped else nil,
		UnlockedSlots = if typeof(unlocked) == "number" then unlocked else nil,
		AutoSell = player:GetAttribute("AutoSell") == true,
		Placed = placedNow(player) or placedCache[player],
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
			ChestService.AddItem(player, "Heroes", name, amount)
		end
	end
	ShopService.ApplySaved(player, data.Axes or {}, data.EquippedAxe)
	if typeof(data.UnlockedSlots) == "number" then
		local now = player:GetAttribute("UnlockedSlots")
		player:SetAttribute("UnlockedSlots", math.max(data.UnlockedSlots, if typeof(now) == "number" then now else 0))
	end
	if typeof(data.AutoSell) == "boolean" then
		player:SetAttribute("AutoSell", data.AutoSell)
	end
	if data.Placed then
		local placed: { [number]: string } = {}
		for index, hero in data.Placed do
			local i = tonumber(index)
			if i and typeof(hero) == "string" then
				placed[i] = hero
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
	local placed = placedNow(player)	if placed then
		placedCache[player] = placed
	end
end

local function onLeave(player: Player)
	DataService.RememberPlaced(player)
	DataService.Save(player)
	-- Same thread, no yield after Save returns: a save waiting in BindToClose sees this and skips.
	loaded[player] = nil
	placedCache[player] = nil
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
