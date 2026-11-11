--!strict
-- HeroConfig: every anime hero in the game. Edit this list to add / tune heroes.
--
-- Each hero:
--   Name      = shown in the UI, and the name used in ZoneDrops (e.g. { Item = "Naruto", Chance = 0.03 })
--   Rarity    = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic" (slot colour, sorting)
--   Template  = name of the hero's model inside ReplicatedStorage.HeroTemplates
--   MinePower = how strong the hero mines (shown in red on the hotbar / chest / popups;
--               the hotbar puts the highest MinePower first)
--   Image     = optional "rbxassetid://..." picture for the UI (a ★ is shown when missing)
--
-- Which zone/tree drops which hero is set in ZoneDrops.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

export type Rarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic"

export type HeroDef = {
	Name: string,
	Rarity: Rarity,
	Template: string,
	MinePower: number,
	Image: string?,
}

local HeroConfig = {}

-- Folder that holds the hero models named by `Template`.
HeroConfig.TemplateFolder = "HeroTemplates"

HeroConfig.Heroes = {
	{ Name = "Naruto", Rarity = "Rare", Template = "Naruto", MinePower = 1200 },
	{ Name = "Leaf Ninja", Rarity = "Rare", Template = "LeafNinja", MinePower = 1500 },
	{ Name = "Thunder Slayer", Rarity = "Epic", Template = "ThunderSlayer", MinePower = 3125 },
	{ Name = "Flame Pillar", Rarity = "Epic", Template = "FlamePillar", MinePower = 4900 },
	{ Name = "Demon King", Rarity = "Legendary", Template = "DemonKing", MinePower = 38100 },
	{ Name = "Sun God", Rarity = "Mythic", Template = "SunGod", MinePower = 150000 },
} :: { HeroDef }

local byName: { [string]: HeroDef } = {}
for _, hero in HeroConfig.Heroes do
	byName[hero.Name] = hero
end

function HeroConfig.Get(name: string): HeroDef?
	return byName[name]
end

-- The hero's model from ReplicatedStorage.HeroTemplates (not cloned), or nil if it is not there.
function HeroConfig.GetTemplate(name: string): Model?
	local hero = byName[name]
	local folder = ReplicatedStorage:FindFirstChild(HeroConfig.TemplateFolder)
	local model = hero and folder and folder:FindFirstChild(hero.Template)
	return if model and model:IsA("Model") then model else nil
end

-- Warns about config mistakes (duplicate names, missing models). Called once by the server.
function HeroConfig.Validate()
	local seen: { [string]: boolean } = {}
	for _, hero in HeroConfig.Heroes do
		if seen[hero.Name] then
			warn(("[HeroConfig] hero %q is listed twice"):format(hero.Name))
		end
		seen[hero.Name] = true
	end
	local folder = ReplicatedStorage:FindFirstChild(HeroConfig.TemplateFolder)
	if not folder then
		warn(("[HeroConfig] ReplicatedStorage.%s is missing; hero models will not load"):format(HeroConfig.TemplateFolder))
		return
	end
	for _, hero in HeroConfig.Heroes do
		if not folder:FindFirstChild(hero.Template) then
			warn(("[HeroConfig] %s: no model %q in ReplicatedStorage.%s"):format(hero.Name, hero.Template, HeroConfig.TemplateFolder))
		end
	end
end

return HeroConfig
