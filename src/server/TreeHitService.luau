-- TreeHitService: turns player clicks into tree damage and hands out drops when a tree falls.
--
-- Client -> server  Remotes.HitTree(tree, hitPosition)
-- Server -> all     Remotes.TreeHit(tree, attacker, damage, hitPosition, felled, fromPosition?)
--                   (shake / leaves / numbers; attacker is nil and fromPosition is the hero for hero hits)
-- Heroes working a HeroSlot hit through TreeHitService.HeroHit; their drops go to the slot's owner.
-- Server -> owner   Remotes.TreeDrops(origin, groundY, drops, chest)                (materials fly into the chest, heroes to the player)
--
-- Drops go into the plot's chest the moment the tree falls (ChestService "Contents"); the player
-- moves them into "Inventory" / "Heroes" with Take All and sells materials at the Sell shop.
-- When the chest is full, the extra items are lost. Nothing is saved yet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local TreeService = require(script.Parent:WaitForChild("TreeService"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))
local IndexService = require(script.Parent:WaitForChild("IndexService"))
local ZoneDrops = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZoneDrops"))
local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))
local SkillTreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SkillTreeConfig"))
local ZoneConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZoneConfig"))
local WeatherConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeatherConfig"))
local PotionConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PotionConfig"))

type Drop = TreeConfig.Drop

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local HitTree = Remotes:WaitForChild("HitTree") :: RemoteEvent
local TreeHit = Remotes:WaitForChild("TreeHit") :: RemoteEvent
local TreeDrops = Remotes:WaitForChild("TreeDrops") :: RemoteEvent
local ItemsAdded = Remotes:WaitForChild("ItemsAdded") :: RemoteEvent

local HERO_PREFIX = "Anime:"

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

-- A skill tree stat for the zone the tree is in (zone trees only count in their own zone).
local function statIn(player: Player?, stat: string, zone: number?, default: number): number
	if not player then
		return default
	end
	return SkillTreeConfig.PlayerStat(player, stat, zone or 1)
end

-- A player luck attribute (skill trees) times the weather's buff for it (WeatherConfig) and the
-- player's active potions (PotionConfig).
local function luckOf(player: Player?, stat: string): number
	local value = player and player:GetAttribute(stat)
	return (if typeof(value) == "number" then value else 1) * WeatherConfig.Mult(stat) * PotionConfig.Mult(player, stat)
end

-- A hero drop of `heroName`: rolls its mutation and size (HeroConfig.RollVariant, boosted by the
-- player's MutationLuck / SizeLuck) and names it after them ("Diamond Huge Sling Scout").
local function heroDrop(heroName: string, amount: number, chance: number, player: Player?): Drop?
	local base = TreeConfig.GetHero(heroName)
	if not base then
		return nil
	end
	local mutation, size, variantChance = HeroConfig.RollVariant(rng, luckOf(player, "MutationLuck"), luckOf(player, "SizeLuck"), WeatherConfig.MutationBoost())
	return {
		Kind = "Anime",
		Name = HeroConfig.VariantName(base.Name, mutation, size),
		Amount = amount,
		Rarity = base.Rarity,
		Chance = chance * variantChance, -- chance of this exact hero + mutation + size per tree
		Mutation = mutation,
		Size = size,
	}
end

-- One roll for the zone's hero drop (ZoneConfig Base HeroChance + skills, ZoneDrops Heroes), boosted by the player's
-- "HeroLuck" attribute (multiplier, default 1). The hero then rolls its mutation and size.
local function rollHero(zone: number?, player: Player?): Drop?
	local def = ZoneDrops.GetZone(zone)
	local heroes = def.Heroes
	if not heroes or #heroes == 0 then
		return nil
	end
	local luck = luckOf(player, "HeroLuck") -- skills x weather
	-- Zone base HeroChance + Hero Sprout, then multiplied by Luck.
	local base = statIn(player, "HeroChance", zone, ZoneConfig.GetBase(zone, "HeroChance") or 0)
	local chance = math.clamp(base * luck * statIn(player, "Luck", zone, 1), 0, 1)
	if rng:NextNumber() >= chance then
		return nil
	end
	local total = 0
	for _, entry in heroes do
		total += entry.Weight
	end
	local roll = rng:NextNumber(0, total)
	local picked = heroes[#heroes]
	for _, entry in heroes do
		roll -= entry.Weight
		if roll <= 0 then
			picked = entry
			break
		end
	end
	return heroDrop(picked.Item, 1, chance * picked.Weight / total, player)
end

-- Rolls the zone's drop list (ZoneDrops) for a felled tree.
local function rollDrops(zone: number?, treeType: string?, player: Player?): { Drop }
	local drops: { Drop } = {}
	local hero = rollHero(zone, player)
	if hero then
		table.insert(drops, hero)
	end
	-- Zone skill tree: Luck boosts the non-guaranteed drops, ChopYield adds to the guaranteed wood.
	local luck = statIn(player, "Luck", zone, 1) * WeatherConfig.Mult("DropLuck")
	local yield = math.floor(statIn(player, "ChopYield", zone, 0))
	for _, entry in ZoneDrops.GetDrops(zone, treeType) do
		local guaranteed = entry.Chance >= 1
		local chance = if guaranteed then 1 else math.min(1, entry.Chance * luck)
		if rng:NextNumber() < chance then
			local min = entry.Min or 1
			local amount = rng:NextInteger(min, math.max(min, entry.Max or min))
			local def = TreeConfig.Materials[entry.Item]
			if def and guaranteed then
				amount += yield
			end
			if def then
				amount = math.max(1, math.floor(amount * PotionConfig.Mult(player, "MaterialDrop"))) -- Material Potion
			end
			local hero = not def and TreeConfig.GetHero(entry.Item)
			if def then
				table.insert(drops, {
					Kind = entry.Item,
					Name = def.Name,
					Amount = amount,
					Rarity = def.Rarity,
					Chance = chance,
				})
			elseif hero then
				-- Each copy rolls its own mutation / size.
				for _ = 1, amount do
					local drop = heroDrop(hero.Name, 1, chance, player)
					if drop then
						table.insert(drops, drop)
					end
				end
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
	-- Zone swap playing (ZoneService): no chopping until the new floor is up.
	if plot:GetAttribute("ZoneBusy") then
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
		local drops = rollDrops(plot and plot:GetAttribute("Zone"), model:GetAttribute("TreeType"), player)
		-- A hero the player never had (not owned, not in the Index) is "New" (client: cutscene). Checked
		-- before DiscoverDrops marks it found.
		local owned = player:FindFirstChild("Heroes")
		for _, drop in drops do
			if drop.Kind == "Anime" then
				drop.New = not IndexService.IsFound(player, "Heroes", drop.Name)
					and not (owned and owned:FindFirstChild(drop.Name))
			end
		end
		IndexService.DiscoverDrops(player, drops) -- found in the Index (even if auto-sold right away)
		local chest = ChestService.GetChest(plot)
		local groundY = cf.Position.Y - size.Y / 2
		-- Heroes always go straight into player.Heroes (with the "Added!" / "New!" popup).
		local heroes: { Drop } = {}
		local materials: { Drop } = {}
		for _, drop in drops do
			table.insert(if drop.Kind == "Anime" then heroes else materials, drop)
		end
		if #heroes > 0 then
			grantDrops(player, heroes)
			local popups = {}
			for _, drop in heroes do
				table.insert(popups, { Stack = HERO_PREFIX .. drop.Name, Amount = drop.Amount, New = drop.New == true })
			end
			-- After the drop has popped out (and its cutscene, if any) so the popup doesn't spoil it.
			task.delay(TreeConfig.HeroPopupDelay, function()
				if player.Parent then
					ItemsAdded:FireClient(player, popups)
				end
			end)
		end
		if not chest then
			grantDrops(player, materials)
			TreeDrops:FireClient(player, cf.Position, groundY, drops, nil)
			return true
		end
		-- Materials fly into the chest (the plot's loot pile); from there they are carried to the
		-- Farm Stand. Only what fits in the chest is kept.
		local room = ChestService.GetRoom(chest)
		local total = 0
		local kept: { Drop } = {}
		for _, drop in materials do
			local amount = math.min(drop.Amount, room - total)
			if amount > 0 then
				drop.Amount = amount
				total += amount
				table.insert(kept, drop)
			end
		end
		for _, drop in heroes do
			table.insert(kept, drop)
		end
		-- Fire before updating Stored so the client knows these items are still in flight.
		TreeDrops:FireClient(player, cf.Position, groundY, kept, chest)
		ChestService.AddDrops(chest, kept) -- skips the heroes
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

	local damage = math.floor(
		(player:GetAttribute("ClickDamage") or TreeConfig.ClickDamage) * WeatherConfig.Mult("ClickDamage") * PotionConfig.Mult(player, "ClickDamage")
	)
	applyHit(player, tree :: Model, damage, hitPos, player, nil)
end

-- A hero (HeroWorkerService) swings at a tree on its owner's plot. Returns true if it felled the tree.
-- `heroRoot` = the hero's root part, or its position (workers pass their logical position).
function TreeHitService.HeroHit(owner: Player, heroRoot: BasePart | Vector3, tree: Model, damage: number, hitPos: Vector3): boolean
	if not tree.Parent or tree:GetAttribute("Dead") or (tree:GetAttribute("HP") or 0) <= 0 then
		return false
	end
	local plot = plotOf(tree)
	if not plot or plot:GetAttribute("OwnerUserId") ~= owner.UserId then
		return false
	end
	local from = if typeof(heroRoot) == "Vector3" then heroRoot else (heroRoot :: BasePart).Position
	return applyHit(owner, tree, damage, hitPos, nil, from)
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
