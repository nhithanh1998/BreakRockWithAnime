--!strict
-- IndexService: the Index (collection book) on the server (rules and rewards in Shared.IndexConfig).
--
-- Player data:
--   player.IndexFound.<stack> (BoolValue) = the player has found that item (IndexConfig stack names).
--     Marked whenever an item reaches the player: drops of their trees (TreeHitService calls
--     IndexService.DiscoverDrops, so auto-sold materials count too) and everything added to their
--     Heroes / Inventory (ChestService.ItemAddedHook: chest Take All, rewards, the save loading).
--   player attribute "IndexClaimed_<zone>" = bit mask of the zone's claimed milestones.
-- Saved by DataService as IndexFound = { stack } and IndexClaimed = { ["<zone>"] = mask }.
--
-- Remotes.IndexAction (RemoteFunction):
--   ("Claim", zone, milestone) -> { ok, message }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local IndexConfig = require(Shared:WaitForChild("IndexConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local TreeConfig = require(Shared:WaitForChild("TreeConfig"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))
local Rewards = require(script.Parent:WaitForChild("Rewards"))

type Drop = TreeConfig.Drop

local IndexService = {}

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local actionRemote = Remotes:FindFirstChild("IndexAction") :: RemoteFunction?
if not actionRemote then
	local r = Instance.new("RemoteFunction")
	r.Name = "IndexAction"
	r.Parent = Remotes
	actionRemote = r
end

local busy: { [Player]: boolean } = {}

local function foundFolder(player: Player): Folder
	local folder = player:FindFirstChild(IndexConfig.FoundFolder)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = IndexConfig.FoundFolder
		folder.Parent = player
	end
	return folder :: Folder
end

local function plainHero(name: string): string
	local base = HeroConfig.SplitVariant(HeroConfig.CurrentName(name))
	return base
end

-- Marks one index stack as found.
function IndexService.Discover(player: Player, stack: string)
	local folder = foundFolder(player)
	if not folder:FindFirstChild(stack) then
		local v = Instance.new("BoolValue")
		v.Name = stack
		v.Value = true
		v.Parent = folder
	end
end

-- True if the player has found this item before (folder = "Heroes" / "Inventory").
function IndexService.IsFound(player: Player, folderName: string, itemName: string): boolean
	local stack = IndexConfig.StackFor(folderName, itemName, plainHero)
	local folder = player:FindFirstChild(IndexConfig.FoundFolder)
	return stack ~= nil and folder ~= nil and folder:FindFirstChild(stack) ~= nil
end

-- Marks the item a player just got (folder = "Heroes" / "Inventory", as in ChestService.AddItem).
function IndexService.DiscoverItem(player: Player, folderName: string, itemName: string)
	local stack = IndexConfig.StackFor(folderName, itemName, plainHero)
	if stack then
		IndexService.Discover(player, stack)
	end
end

-- Marks every drop of a felled tree (heroes and materials, before any auto-sell).
function IndexService.DiscoverDrops(player: Player, drops: { Drop })
	for _, drop in drops do
		if drop.Kind == "Anime" then
			IndexService.DiscoverItem(player, "Heroes", drop.Name)
		else
			IndexService.DiscoverItem(player, "Inventory", drop.Kind)
		end
	end
end

local function claim(player: Player, zone: any, index: any): { [string]: any }
	if typeof(zone) ~= "number" or typeof(index) ~= "number" then
		return { ok = false, message = "Bad request" }
	end
	local milestones = IndexConfig.Rewards[zone]
	local milestone = milestones and milestones[index]
	if not milestone then
		return { ok = false, message = "No such reward" }
	end
	if player:GetAttribute("DataLoaded") == nil then
		return { ok = false, message = "Still loading your data, try again in a moment." }
	end
	if busy[player] then
		return { ok = false }
	end
	local mask = IndexConfig.ClaimedMask(player, zone)
	if IndexConfig.IsClaimed(mask, index) then
		return { ok = false, message = "Already claimed" }
	end
	local found = IndexConfig.FoundIn(player, zone)
	local need = IndexConfig.Needed(zone, milestone)
	if found < need then
		return { ok = false, message = ("Find %d more first!"):format(need - found) }
	end
	busy[player] = true
	player:SetAttribute(IndexConfig.ClaimedPrefix .. tostring(zone), IndexConfig.SetClaimed(mask, index))
	local popups = {}
	for _, reward in milestone.Rewards do
		Rewards.Give(player, reward, popups)
	end
	local itemsAdded = Remotes:FindFirstChild("ItemsAdded") :: RemoteEvent?
	if #popups > 0 and itemsAdded then
		itemsAdded:FireClient(player, popups)
	end
	busy[player] = nil
	return { ok = true, message = "Reward claimed!" }
end

-- Saved data (DataService) ---------------------------------------------------------------------------

function IndexService.GetSaveData(player: Player): ({ string }, { [string]: number })
	local found = {}
	local folder = player:FindFirstChild(IndexConfig.FoundFolder)
	for _, v in if folder then folder:GetChildren() else {} do
		table.insert(found, v.Name)
	end
	local claimed = {}
	for zone in IndexConfig.Rewards do
		local mask = IndexConfig.ClaimedMask(player, zone)
		if mask ~= 0 then
			claimed[tostring(zone)] = mask
		end
	end
	return found, claimed
end

-- Merged with whatever was found / claimed during the load.
function IndexService.ApplySaved(player: Player, found: any, claimed: any)
	if typeof(found) == "table" then
		for _, stack in found do
			if typeof(stack) == "string" then
				IndexService.Discover(player, stack)
			end
		end
	end
	if typeof(claimed) == "table" then
		for zoneText, mask in claimed do
			local zone = tonumber(zoneText)
			if zone and typeof(mask) == "number" then
				player:SetAttribute(IndexConfig.ClaimedPrefix .. tostring(zone), bit32.bor(IndexConfig.ClaimedMask(player, zone), mask))
			end
		end
	end
end

-- Start ---------------------------------------------------------------------------------------------

function IndexService.Start()
	ChestService.ItemAddedHook = IndexService.DiscoverItem
	;(actionRemote :: RemoteFunction).OnServerInvoke = function(player, action, zone, index)
		if action == "Claim" then
			return claim(player, zone, index)
		end
		return { ok = false, message = "Bad request" }
	end
	local function onPlayer(player: Player)
		foundFolder(player)
		-- Items already owned (e.g. given before this started) count as found.
		for _, folderName in { "Heroes", "Inventory" } do
			local folder = player:FindFirstChild(folderName)
			for _, v in if folder then folder:GetChildren() else {} do
				if v:IsA("IntValue") and v.Value > 0 then
					IndexService.DiscoverItem(player, folderName, v.Name)
				end
			end
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		busy[player] = nil
	end)
end

return IndexService
