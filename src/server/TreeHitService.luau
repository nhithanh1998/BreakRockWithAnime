-- TreeHitService: turns player clicks into tree damage and hands out drops when a tree falls.
--
-- Client -> server  Remotes.HitTree(tree, hitPosition)
-- Server -> all     Remotes.TreeHit(tree, attacker, damage, hitPosition, felled, fromPosition?)
--                   (shake / leaves / numbers; attacker is nil and fromPosition is the hero for hero hits)
-- Heroes working a HeroSlot hit through TreeHitService.HeroHit; their drops go to the slot's owner.
-- Server -> owner   Remotes.TreeDrops(origin, groundY, drops, chest)                (drops fly into the chest)
--
-- Drops go into the plot's chest the moment the tree falls (ChestService "Contents"); the player
-- moves them into "Inventory" / "Heroes" with Take All. With Auto Sell on, materials are sold for
-- Money instead. When the chest is full, the extra items are lost. Nothing is saved yet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local TreeService = require(script.Parent:WaitForChild("TreeService"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))
local ZoneDrops = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZoneDrops"))
local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))

type Drop = TreeConfig.Drop

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local HitTree = Remotes:WaitForChild("HitTree") :: RemoteEvent
local TreeHit = Remotes:WaitForChild("TreeHit") :: RemoteEvent
local TreeDrops = Remotes:WaitForChild("TreeDrops") :: RemoteEvent

local TreeHitService = {}

local rng = Random.new()
local lastHit: { [Player]: number } = {}

-- Inventory ------------------------------------------------------------------------------------

function TreeHitService.GetItemCount(player: Player, kind: string): number
	local folder = player:FindFirstChild("Inventory")
	local value = folder and folder:FindFirstChild(kind) :: IntValue?
	return if value then value.Value else 0
end

-- Drops ----------------------------------------------------------------------------------------

-- Rolls the zone's drop list (ZoneDrops) for a felled tree.
local function rollDrops(zone: number?, treeType: string?): { Drop }
	local drops: { Drop } = {}
	for _, entry in ZoneDrops.GetDrops(zone, treeType) do
		if rng:NextNumber() < entry.Chance then
			local min = entry.Min or 1
			local amount = rng:NextInteger(min, math.max(min, entry.Max or min))
			local def = TreeConfig.Materials[entry.Item]
			local hero = not def and TreeConfig.GetHero(entry.Item)
			if def then
				table.insert(drops, {
					Kind = entry.Item,
					Name = def.Name,
					Amount = amount,
					Rarity = def.Rarity,
					Chance = entry.Chance,
				})
			elseif hero then
				table.insert(drops, {
					Kind = "Anime",
					Name = hero.Name,
					Amount = amount,
					Rarity = hero.Rarity,
					Chance = entry.Chance,
				})
			end
		end
	end
	return drops
end

-- Without a chest, drops go straight into the player's Inventory / Heroes.
local function grantDrops(player: Player, drops: { Drop })
	for _, drop in drops do
		if drop.Kind == "Anime" then
			ChestService.AddItem(player, "Heroes", drop.Name, drop.Amount)
		else
			ChestService.AddItem(player, "Inventory", drop.Kind, drop.Amount)
		end
	end
end

-- Hits -----------------------------------------------------------------------------------------

local function plotOf(tree: Model): Model?
	local folder = tree.Parent
	if not folder or folder.Name ~= "TreeSpawns" then
		return nil
	end
	local plot = folder.Parent
	return if plot and plot:IsA("Model") then plot else nil
end

local function canHit(player: Player, tree: any): boolean
	if typeof(tree) ~= "Instance" or not tree:IsA("Model") then
		return false
	end
	if not tree:IsDescendantOf(workspace) or tree:GetAttribute("Dead") then
		return false
	end
	if (tree:GetAttribute("HP") or 0) <= 0 then
		return false
	end
	local plot = plotOf(tree)
	if not plot then
		return false
	end
	if TreeConfig.OnlyOwnPlot and plot:GetAttribute("OwnerUserId") ~= player.UserId then
		return false
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return false
	end
	if (root.Position - tree:GetPivot().Position).Magnitude > TreeConfig.MaxHitDistance then
		return false
	end
	return true
end

-- Damages the tree, tells every client, and on a fell hands the drops to `player`.
local function applyHit(player: Player, model: Model, damage: number, hitPos: any, attacker: Player?, fromPos: Vector3?): boolean
	local cf, size = model:GetBoundingBox()
	if typeof(hitPos) ~= "Vector3" or (hitPos - cf.Position).Magnitude > size.Magnitude then
		hitPos = cf.Position
	end

	local felled = TreeService.Damage(model, damage)

	TreeHit:FireAllClients(model, attacker, damage, hitPos, felled, fromPos)

	if felled then
		local plot = plotOf(model)
		local drops = rollDrops(plot and plot:GetAttribute("Zone"), model:GetAttribute("TreeType"))
		local chest = ChestService.GetChest(plot)
		local groundY = cf.Position.Y - size.Y / 2
		if not chest then
			grantDrops(player, drops)
			TreeDrops:FireClient(player, cf.Position, groundY, drops, nil)
			return true
		end
		-- Auto sell turns materials into money right away; only the rest goes in the chest.
		local toStore = if ChestService.IsAutoSell(player) then ChestService.SellMaterials(player, drops) else drops
		local sold: { Drop } = {}
		if toStore ~= drops then
			for _, drop in drops do
				if not table.find(toStore, drop) then
					table.insert(sold, drop)
				end
			end
		end
		-- Only what fits in the chest is kept.
		local room = ChestService.GetRoom(chest)
		local total = 0
		local kept: { Drop } = {}
		for _, drop in toStore do
			local amount = math.min(drop.Amount, room - total)
			if amount > 0 then
				drop.Amount = amount
				total += amount
				table.insert(kept, drop)
			end
		end
		local shown = table.clone(kept)
		table.move(sold, 1, #sold, #shown + 1, shown)
		-- Fire before updating Stored so the client knows these items are still in flight.
		TreeDrops:FireClient(player, cf.Position, groundY, shown, chest)
		if #kept > 0 then
			ChestService.AddDrops(chest, kept)
		end
	end
	return felled
end

local function onHit(player: Player, tree: any, hitPos: any)
	local now = os.clock()
	if now - (lastHit[player] or 0) < TreeConfig.ClickCooldown * 0.8 then
		return
	end
	if not canHit(player, tree) then
		return
	end
	lastHit[player] = now

	local damage = player:GetAttribute("ClickDamage") or TreeConfig.ClickDamage
	applyHit(player, tree :: Model, damage, hitPos, player, nil)
end

-- A hero (HeroWorkerService) swings at a tree on its owner's plot. Returns true if it felled the tree.
function TreeHitService.HeroHit(owner: Player, heroRoot: BasePart, tree: Model, damage: number, hitPos: Vector3): boolean
	if not tree.Parent or tree:GetAttribute("Dead") or (tree:GetAttribute("HP") or 0) <= 0 then
		return false
	end
	local plot = plotOf(tree)
	if not plot or plot:GetAttribute("OwnerUserId") ~= owner.UserId then
		return false
	end
	return applyHit(owner, tree, damage, hitPos, nil, heroRoot.Position)
end

function TreeHitService.Start()
	ZoneDrops.Validate()
	HeroConfig.Validate()
	HitTree.OnServerEvent:Connect(onHit)
	Players.PlayerRemoving:Connect(function(player)
		lastHit[player] = nil
	end)
end

return TreeHitService
