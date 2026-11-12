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
--   ChopDamage = optional damage per axe swing when the hero works a HeroSlot (default MinePower / 100)
--   ChopSpeed  = optional swing speed multiplier (default by rarity, see Worker.RaritySpeed)
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
	ChopDamage: number?,
	ChopSpeed: number?,
}

local HeroConfig = {}

-- Folder that holds the hero models named by `Template`.
HeroConfig.TemplateFolder = "Heros"
-- Model used when a hero's Template is not in the folder yet (so every hero can still work a slot).
HeroConfig.FallbackTemplate = "UzumakiKid"

-- Heroes placed on a plot's HeroSlots walk out of the HeroGate and chop trees (HeroWorkerService).
HeroConfig.Worker = {
	WalkSpeed = 12, -- studs/s
	AttackRange = 5, -- studs from the trunk's center at which a hero stops and swings
	SwingCooldown = 0.15, -- seconds between swings (on top of the swing animation)
	-- Swing animation. Upload ServerStorage.RBX_ANIMSAVES.mymodel.ChopHorizontal and put its
	-- "rbxassetid://..." here. While empty, that KeyframeSequence is played directly (works in
	-- Studio playtests only). The swing's damage lands on its "Hit" marker.
	ChopAnimation = "",
	ChopKeyframes = "ChopHorizontal",
	RaritySpeed = { Common = 1, Uncommon = 1.05, Rare = 1.1, Epic = 1.2, Legendary = 1.35, Mythic = 1.5 } :: { [string]: number },
}

HeroConfig.Heroes = {
	{ Name = "Naruto", Rarity = "Rare", Template = "UzumakiKid", MinePower = 1200 },
	{ Name = "Leaf Ninja", Rarity = "Rare", Template = "CopyNinja", MinePower = 1500 },
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

-- The hero's model from ReplicatedStorage.Heros (not cloned), or nil if it is not there.
function HeroConfig.GetTemplate(name: string): Model?
	local hero = byName[name]
	local folder = ReplicatedStorage:FindFirstChild(HeroConfig.TemplateFolder)
	local model = hero and folder and folder:FindFirstChild(hero.Template)
	return if model and model:IsA("Model") then model else nil
end

-- Damage one axe swing of this hero deals to a tree.
function HeroConfig.ChopDamage(name: string): number
	local hero = byName[name]
	if not hero then
		return 1
	end
	return hero.ChopDamage or math.max(1, math.floor(hero.MinePower / 100))
end

-- Swing animation speed multiplier for this hero.
function HeroConfig.ChopSpeed(name: string): number
	local hero = byName[name]
	if not hero then
		return 1
	end
	return hero.ChopSpeed or HeroConfig.Worker.RaritySpeed[hero.Rarity] or 1
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
			warn(("[HeroConfig] %s: no model %q in ReplicatedStorage.%s (using %s for now)"):format(hero.Name, hero.Template, HeroConfig.TemplateFolder, HeroConfig.FallbackTemplate))
		end
	end
end

return HeroConfig
