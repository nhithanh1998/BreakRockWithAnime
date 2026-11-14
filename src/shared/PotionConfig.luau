--!strict
-- PotionConfig: potions the player can drink for a timed boost (PotionService on the server,
-- PotionUI for the active-potion icons, InventoryUI "Other" tab to drink them).
--
-- Each potion:
--   Id       = key (player.Potions.<Id> = how many the player owns, saved)
--   Name     = shown in the UI
--   Desc     = one short line of what it does
--   Buffs    = { Stat = multiplier } while it is active. Stats (same names as WeatherConfig, so the
--              game code reads them in the same places):
--                HeroLuck      chance a felled tree drops a hero          (TreeHitService)
--                MutationLuck  chance a dropped hero is Diamond / ...      (TreeHitService)
--                SizeLuck      chance a dropped hero is Large / Huge / ... (TreeHitService)
--                MaterialDrop  how many materials a felled tree drops      (TreeHitService)
--                HeroDamage    chop damage of your heroes                   (HeroWorkerService)
--                HeroSpeed     swing speed of your heroes                   (HeroWorkerService)
--                ClickDamage   your own axe clicks                          (TreeHitService)
--                SellBonus     money from selling materials and heroes      (ShopService / SkillTreeConfig)
--   Duration = seconds one potion lasts. Drinking another of the same kind ADDS its time (up to
--              MaxStack x Duration); different potions run side by side and multiply.
--   Color    = liquid colour of the bottle / the HUD ring
--   Image    = optional uploaded icon ("rbxassetid://..."); empty = a 3D bottle is drawn
--
-- Active potions: player attribute "PotionEnd_<Id>" = workspace:GetServerTimeNow() when it runs out.
-- The time left is saved (it does not tick while the player is offline).

local PotionConfig = {}

export type PotionDef = {
	Id: string,
	Name: string,
	Desc: string,
	Buffs: { [string]: number },
	Duration: number,
	Color: Color3,
	Rarity: string, -- card colour (TreeConfig.RaritySlotColors)
	Image: string?,
}

local rgb = Color3.fromRGB

PotionConfig.Potions = {
	{ Id = "HeroLuck", Name = "Hero Luck Potion", Desc = "x2 hero drop chance", Buffs = { HeroLuck = 2 }, Duration = 10 * 60, Color = rgb(80, 220, 110), Rarity = "Rare" },
	{ Id = "Material", Name = "Material Potion", Desc = "x2 materials from every tree", Buffs = { MaterialDrop = 2 }, Duration = 10 * 60, Color = rgb(230, 150, 60), Rarity = "Uncommon" },
	{ Id = "ChopSpeed", Name = "Chop Speed Potion", Desc = "x2 hero chop speed", Buffs = { HeroSpeed = 2 }, Duration = 10 * 60, Color = rgb(70, 200, 255), Rarity = "Rare" },
	{ Id = "ChopDamage", Name = "Chop Damage Potion", Desc = "x2 chop damage (heroes + clicks)", Buffs = { HeroDamage = 2, ClickDamage = 2 }, Duration = 10 * 60, Color = rgb(255, 80, 70), Rarity = "Rare" },
	{ Id = "MutationLuck", Name = "Mutation Luck Potion", Desc = "x2 mutation chance", Buffs = { MutationLuck = 2 }, Duration = 10 * 60, Color = rgb(255, 110, 210), Rarity = "Epic" },
	{ Id = "SizeLuck", Name = "Size Luck Potion", Desc = "x2 big hero chance", Buffs = { SizeLuck = 2 }, Duration = 10 * 60, Color = rgb(255, 215, 70), Rarity = "Epic" },
	{ Id = "Money", Name = "Money Potion", Desc = "x2 sell price", Buffs = { SellBonus = 2 }, Duration = 10 * 60, Color = rgb(255, 235, 120), Rarity = "Legendary" },
} :: { PotionDef }

PotionConfig.MaxStack = 6 -- an active potion holds at most this many durations of time
PotionConfig.AttributePrefix = "PotionEnd_"
-- Studio playtests only: players with fewer than this of each potion get topped up on join.
PotionConfig.StudioTestAmount = 3

local byId: { [string]: PotionDef } = {}
for _, def in PotionConfig.Potions do
	byId[def.Id] = def
end

function PotionConfig.Get(id: string): PotionDef?
	return byId[id]
end

local function now(): number
	return workspace:GetServerTimeNow()
end

-- Seconds left on the player's `id` potion (0 = not active). Works on the server and the client.
function PotionConfig.TimeLeft(player: Player, id: string): number
	local ends = player:GetAttribute(PotionConfig.AttributePrefix .. id)
	return if typeof(ends) == "number" then math.max(0, ends - now()) else 0
end

-- Product of every active potion's multiplier for `stat` (1 = none).
function PotionConfig.Mult(player: Player?, stat: string): number
	if not player then
		return 1
	end
	local mult = 1
	for _, def in PotionConfig.Potions do
		local m = def.Buffs[stat]
		if m and PotionConfig.TimeLeft(player, def.Id) > 0 then
			mult *= m
		end
	end
	return mult
end

-- The plot's owner (plots carry an "OwnerUserId" attribute), for boosts that apply to a plot's heroes.
function PotionConfig.MultForPlot(plot: Instance?, stat: string): number
	local owner = plot and plot:GetAttribute("OwnerUserId")
	if typeof(owner) ~= "number" then
		return 1
	end
	return PotionConfig.Mult(game:GetService("Players"):GetPlayerByUserId(owner), stat)
end

function PotionConfig.Clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	if seconds >= 3600 then
		return ("%d:%02d:%02d"):format(seconds // 3600, (seconds // 60) % 60, seconds % 60)
	end
	return ("%d:%02d"):format(seconds // 60, seconds % 60)
end

return PotionConfig
