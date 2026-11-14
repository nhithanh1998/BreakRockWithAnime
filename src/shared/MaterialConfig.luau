--!strict
-- MaterialConfig: the materials players carry from the chest to the Farm Stand and sell there, and
-- how much a player can carry.
--
-- Materials are defined once, in TreeConfig.Materials (what trees drop). This module is the sale view
-- of them: id, name, icon, base price (TreeConfig Value), rarity. Only materials can be carried or
-- sold at the stand (heroes never).
--
-- Carrying (CarryService):
--   Standing on the plot's Loot Pad (the "LootPad" mat in front of the TreasureChest) moves materials
--   from the chest onto the player, PerTick every TickInterval seconds, until CarryCapacity.
--   CarryCapacity = Carry.BaseCapacity (+ the Carry Capacity upgrade later, StandUpgradeConfig).
--   What the player carries: player.Carried (an IntValue per material); player attributes
--   "CarryCount" and "CarryCapacity" for the HUD.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))

local MaterialConfig = {}

MaterialConfig.Carry = {
	BaseCapacity = 30, -- materials a player can carry before any upgrade
	PerTick = 3, -- materials picked up per tick while standing on the Loot Pad
	TickInterval = 0.2, -- seconds between ticks
	PadReach = 1.5, -- studs outside the Loot Pad's edge that still count as standing on it
	PadHeight = 6, -- studs above the pad the player's root may be
	FullToastCooldown = 3, -- seconds between two "hands full" / "chest empty" toasts
	-- What the carried stack looks like (CarryService): one box per BoxEvery materials, at most MaxBoxes.
	BoxEvery = 5,
	MaxBoxes = 5,
	BoxSize = Vector3.new(1.5, 0.8, 1),
}

export type Material = {
	Id: string,
	Name: string,
	Icon: string, -- "rbxassetid://..." or "" (then the 3D model is drawn)
	BasePrice: number, -- money per item at the stand before bonuses
	Rarity: string,
	Color: Color3, -- box colour on the carried stack
}

local cache: { [string]: Material } = {}

function MaterialConfig.Get(id: string): Material?
	local hit = cache[id]
	if hit then
		return hit
	end
	local def = TreeConfig.Materials[id]
	if not def then
		return nil
	end
	local icon = def.MaterialImage or ""
	if icon ~= "" and not icon:find("rbxassetid://", 1, true) then
		icon = "rbxassetid://" .. icon
	end
	local m: Material = {
		Id = id,
		Name = def.Name,
		Icon = icon,
		BasePrice = def.Value,
		Rarity = def.Rarity,
		Color = if def.Visual and def.Visual.Color then def.Visual.Color else Color3.fromRGB(150, 110, 70),
	}
	cache[id] = m
	return m
end

function MaterialConfig.IsMaterial(id: string): boolean
	return TreeConfig.Materials[id] ~= nil
end

return MaterialConfig
