--!strict
-- FruitConfig: Devil Fruits. Edit this file to add / tune fruits.
--
-- How it works:
--   Fertilizer (a bag) -> put it in the Devil Tree on your plot (E "Grow") -> a tree grows in a
--   cutscene and drops ONE random fruit (Chance below) -> the fruit goes to player.Fruits.<Id>.
--   A fruit is given to a hero pad (Upgrade window "FRUIT", or EQUIP on the reveal): the pad's hero
--   gets the fruit's Boost on chop damage and its passive Skill. Each copy can be on one pad.
--
-- Each fruit:
--   Id         = key (saved; don't rename once live)
--   Name       = shown in the UI
--   Rarity     = TreeConfig rarity (colours / sorting)
--   Chance     = weight when a tree grows a fruit (they don't have to add up to 100)
--   Boost      = chop damage multiplier for the hero holding it
--   Color / Swirl = colours of the 3D fruit (body / swirl pattern)
--   FruitImage = uploaded icon ("rbxassetid://123" or "123"); empty = 3D fruit in a ViewportFrame
--   Skill      = passive skill, triggered by the hero's swings:
--     Name, Desc  = shown in the UI
--     Speed       = swing speed multiplier (always on)
--     Walk        = walk speed multiplier (always on)
--     Chance      = chance per swing to trigger   } use one of these two
--     Every       = triggers every N-th swing     }
--     Mult        = the triggering swing deals Damage x Mult
--     Hits        = extra hits on the same tree (each = the swing's damage)
--     Radius      = studs: every other tree this close also takes Share x the swing's damage
--     Share       = see Radius
--     BurnShare   = the tree burns for BurnShare x the swing's damage every second ...
--     BurnTime    = ... for this many seconds
--     FX          = client effect: "Spring" | "Smoke" | "Ice" | "Flame" | "Sand" | "Light" | "Magma" | "Quake"

local HeroConfig = require(script.Parent:WaitForChild("HeroConfig"))

export type Skill = {
	Name: string,
	Desc: string,
	Speed: number?,
	Walk: number?,
	Chance: number?,
	Every: number?,
	Mult: number?,
	Hits: number?,
	Radius: number?,
	Share: number?,
	BurnShare: number?,
	BurnTime: number?,
	FX: string,
}

export type FruitDef = {
	Id: string,
	Name: string,
	Rarity: string,
	Chance: number,
	Boost: number,
	Color: Color3,
	Swirl: Color3,
	FruitImage: string?,
	Skill: Skill,
}

local FruitConfig = {}

FruitConfig.Fruits = {
	{
		Id = "Spring", Name = "Spring Fruit", Rarity = "Common", Chance = 30, Boost = 1.15,
		Color = Color3.fromRGB(255, 140, 190), Swirl = Color3.fromRGB(200, 60, 130), FruitImage = "",
		Skill = { Name = "Double Swing", Desc = "15% chance to hit twice", Chance = 0.15, Hits = 1, FX = "Spring" },
	},
	{
		Id = "Smoke", Name = "Smoke Fruit", Rarity = "Common", Chance = 26, Boost = 1.15,
		Color = Color3.fromRGB(225, 228, 235), Swirl = Color3.fromRGB(150, 155, 170), FruitImage = "",
		Skill = { Name = "Smoke Dash", Desc = "+15% swing speed, +25% walk speed", Speed = 1.15, Walk = 1.25, FX = "Smoke" },
	},
	{
		Id = "Ice", Name = "Ice Fruit", Rarity = "Uncommon", Chance = 18, Boost = 1.3,
		Color = Color3.fromRGB(150, 220, 255), Swirl = Color3.fromRGB(60, 140, 230), FruitImage = "",
		Skill = { Name = "Frost Chain", Desc = "Every 4th swing deals x3 damage", Every = 4, Mult = 3, FX = "Ice" },
	},
	{
		Id = "Flame", Name = "Flame Fruit", Rarity = "Rare", Chance = 11, Boost = 1.5,
		Color = Color3.fromRGB(255, 120, 40), Swirl = Color3.fromRGB(200, 40, 20), FruitImage = "",
		Skill = { Name = "Wildfire", Desc = "Hits burn the tree: 25% damage per second for 4s", Chance = 1, BurnShare = 0.25, BurnTime = 4, FX = "Flame" },
	},
	{
		Id = "Sand", Name = "Sand Fruit", Rarity = "Rare", Chance = 8, Boost = 1.5,
		Color = Color3.fromRGB(235, 200, 120), Swirl = Color3.fromRGB(170, 120, 60), FruitImage = "",
		Skill = { Name = "Sandstorm", Desc = "20% chance: 60% damage to every tree within 18 studs", Chance = 0.2, Radius = 18, Share = 0.6, FX = "Sand" },
	},
	{
		Id = "Light", Name = "Light Fruit", Rarity = "Epic", Chance = 4.5, Boost = 1.9,
		Color = Color3.fromRGB(255, 240, 120), Swirl = Color3.fromRGB(230, 170, 30), FruitImage = "",
		Skill = { Name = "Flash Step", Desc = "+35% swing speed, +60% walk speed, 10% chance to hit twice", Speed = 1.35, Walk = 1.6, Chance = 0.1, Hits = 1, FX = "Light" },
	},
	{
		Id = "Magma", Name = "Magma Fruit", Rarity = "Legendary", Chance = 2, Boost = 2.6,
		Color = Color3.fromRGB(140, 30, 25), Swirl = Color3.fromRGB(255, 110, 20), FruitImage = "",
		Skill = { Name = "Eruption", Desc = "Every 6th swing: x4 damage + 100% to trees within 20 studs", Every = 6, Mult = 4, Radius = 20, Share = 1, FX = "Magma" },
	},
	{
		Id = "Quake", Name = "Quake Fruit", Rarity = "Mythic", Chance = 0.5, Boost = 3.5,
		Color = Color3.fromRGB(245, 245, 250), Swirl = Color3.fromRGB(120, 90, 200), FruitImage = "",
		Skill = { Name = "Tremor", Desc = "25% chance: x5 damage + 75% to trees within 25 studs", Chance = 0.25, Mult = 5, Radius = 25, Share = 0.75, FX = "Quake" },
	},
} :: { FruitDef }

-- Fertilizer ---------------------------------------------------------------------------------------

FruitConfig.FertilizerName = "Devil Fertilizer"
FruitConfig.FertilizerPerGrow = 1
-- Robux packs (Developer Products). Create them on the Creator Dashboard and paste the ids here;
-- a pack with ProductId 0 shows "Soon" and can't be bought.
FruitConfig.FertilizerProducts = {
	{ Amount = 1, ProductId = 0, Robux = 49 },
	{ Amount = 5, ProductId = 0, Robux = 199 },
	{ Amount = 15, ProductId = 0, Robux = 499 },
} :: { { Amount: number, ProductId: number, Robux: number } }
-- Studio playtests only: players with less than this get topped up on join (for testing).
FruitConfig.StudioTestFertilizer = 10

-- Devil Tree on the plot ---------------------------------------------------------------------------

-- The Devil Tree is part of the plot layout: Plot1 has a model "DevilGarden" on its own bump-out right of
-- the hero pads (like the shops on the left; ground in Land.Rim, fence in Land.Fence), facing the pads.
-- It is used as is; move / restyle it in Studio (keep a part named "Bed", the tree grows on top of it,
-- and "PromptPart" for the E prompt). A plot without one gets a garden built here, relative to the
-- plot's pivot (studs; Y is found by a ray down onto the ground).
FruitConfig.GardenOffset = Vector3.new(70.55, 0, 80.05)
FruitConfig.GardenYaw = 90 -- degrees the garden turns relative to the plot (its front faces the pads)
FruitConfig.GardenSize = 16 -- outer width in studs
-- Walk-in greenhouse around the planter (FruitModels.Greenhouse), centered on the garden's pivot:
-- X = width (across the front), Y = wall height (the roof goes higher), Z = depth (front to back).
-- A garden that already has a "Greenhouse" model (e.g. built into the place) keeps it.
FruitConfig.GreenhouseSize = Vector3.new(33, 14, 24)
FruitConfig.PromptDistance = 12
FruitConfig.CloseDistance = 22 -- the Devil Tree window closes when you walk this far away
FruitConfig.GrowCooldown = 1 -- seconds between grows (server)

-- Lookups --------------------------------------------------------------------------------------------

local byId: { [string]: FruitDef } = {}
local totalChance = 0
for _, fruit in FruitConfig.Fruits do
	fruit.FruitImage = HeroConfig.AssetId(fruit.FruitImage)
	byId[fruit.Id] = fruit
	totalChance += fruit.Chance
end
FruitConfig.TotalChance = totalChance

function FruitConfig.Get(id: string): FruitDef?
	return byId[id]
end

-- Share of grows that give this fruit (0..1).
function FruitConfig.ChanceOf(id: string): number
	local def = byId[id]
	return if def and totalChance > 0 then def.Chance / totalChance else 0
end

function FruitConfig.Roll(rng: Random): FruitDef
	local pick = rng:NextNumber() * totalChance
	for _, fruit in FruitConfig.Fruits do
		pick -= fruit.Chance
		if pick <= 0 then
			return fruit
		end
	end
	return FruitConfig.Fruits[1]
end

-- "x1.5 DMG" style text for the boost.
function FruitConfig.BoostText(def: FruitDef): string
	return ("x%s DMG"):format(tostring(def.Boost))
end

return FruitConfig
