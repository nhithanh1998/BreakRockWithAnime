--!strict
-- HeroConfig: every anime hero in the game. Edit this list to add / tune heroes.
--
-- Each hero:
--   Name      = shown in the UI, and the name used in ZoneDrops (e.g. { Item = "Uzumaki Kid", Chance = 0.03 })
--   Rarity    = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic" (slot colour, sorting)
--   Template  = name of the hero's model inside ReplicatedStorage.HeroTemplates
--   (Power is NOT set here: it lives in HeroConfig.Power, by position in the list. It is how strong
--    the hero mines, shown in red on the hotbar / chest / popups, and the hotbar puts the
--    highest Power first. Code reads it as hero.MinePower.)
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

-- One row of the hero list below (MinePower comes from HeroConfig.Power).
type HeroEntry = {
	Name: string,
	Rarity: Rarity,
	Template: string,
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
	AttackRange = 2.5, -- studs from the trunk's center at which a hero stops and swings
	SwingCooldown = 0.15, -- seconds between swings (on top of the swing animation)
	-- Swing animation. Upload ServerStorage.RBX_ANIMSAVES.mymodel.ChopHorizontal and put its
	-- "rbxassetid://..." here. While empty, that KeyframeSequence is played directly (works in
	-- Studio playtests only). The swing's damage lands on its "Hit" marker.
	ChopAnimation = "",
	ChopKeyframes = "ChopHorizontal",
	RaritySpeed = { Common = 1, Uncommon = 1.05, Rare = 1.1, Epic = 1.2, Legendary = 1.35, Mythic = 1.5 } :: { [string]: number },
}

-- Hero pads (plot.HeroSlots.Slot1..Slot9). Without upgrades only the first StartUnlocked pads work.
-- The rest are bought in order (hold E at the next locked pad) for UnlockPrices[slot] Money; the
-- player's "UnlockedSlots" attribute holds how many are open (an upgrade can also just set it).
HeroConfig.Slots = {
	StartUnlocked = 4,
	UnlockPrices = { [5] = 5000, [6] = 25000, [7] = 100000, [8] = 500000, [9] = 2500000 } :: { [number]: number },
	HoldDuration = 1, -- seconds E must be held on a pad (place / take back / unlock)
	LockedText = "Locked",
	LockedPadColor = Color3.fromRGB(105, 105, 110),
	PriceColor = Color3.fromRGB(90, 255, 60), -- the price shown above a locked pad
}

-- 1234 -> "1.2K", 47700000000 -> "47.7B", 1.57e22 -> "15.7Sx".
local UNITS = {
	{ 1e33, "Dc" },
	{ 1e30, "No" },
	{ 1e27, "Oc" },
	{ 1e24, "Sp" },
	{ 1e21, "Sx" },
	{ 1e18, "Qi" },
	{ 1e15, "Qd" },
	{ 1e12, "T" },
	{ 1e9, "B" },
	{ 1e6, "M" },
	{ 1e3, "K" },
}
function HeroConfig.Abbreviate(n: number): string
	for _, unit in UNITS do
		if n >= unit[1] then
			local v = math.floor(n / unit[1] * 10) / 10
			local text = if v >= 100 or v == math.floor(v) then ("%d"):format(math.floor(v)) else ("%.1f"):format(v)
			return text .. unit[2]
		end
	end
	return tostring(math.floor(n))
end

-- ===================== POWER =====================
-- Mine Power by POSITION in the hero list below: the 1st hero gets Power[1], the 2nd Power[2], ...
-- To re-order heroes, just move their lines in HERO_LIST; these numbers stay where they are.
-- The hotbar sorts by Power (highest first), ChopDamage defaults to Power / 100, and sell value
-- is Power * ShopConfig.HeroSellMultiplier.
HeroConfig.Power = {
	250, -- position 1
	350, -- position 2
	700, -- position 3
	1500, -- position 4
	3500, -- position 5
} :: { number }

-- Hero list. Order matters: a hero's Power is HeroConfig.Power[its position].
local HERO_LIST: { HeroEntry } = {
	-- Zone 1 (Green Wood)
	{ Name = "Sling Pirate", Rarity = "Common", Template = "SlingPirate" },
	{ Name = "Taijutsu Ninja", Rarity = "Common", Template = "TaijutsuNinja" },
	{ Name = "Uzumaki Kid", Rarity = "Uncommon", Template = "UzumakiKid" },
	{ Name = "Copy Ninja", Rarity = "Rare", Template = "CopyNinja" },
	{ Name = "Perfect Bioform", Rarity = "Epic", Template = "PerfectBioform" },
}

HeroConfig.Heroes = {} :: { HeroDef }
local byName: { [string]: HeroDef } = {}
for index, entry in HERO_LIST do
	local hero: HeroDef = {
		Name = entry.Name,
		Rarity = entry.Rarity,
		Template = entry.Template,
		MinePower = HeroConfig.Power[index] or 0,
		Image = entry.Image,
		ChopDamage = entry.ChopDamage,
		ChopSpeed = entry.ChopSpeed,
	}
	table.insert(HeroConfig.Heroes, hero)
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
	if #HeroConfig.Power < #HeroConfig.Heroes then
		warn(("[HeroConfig] %d heroes but only %d Power values; heroes after position %d get Power 0"):format(#HeroConfig.Heroes, #HeroConfig.Power, #HeroConfig.Power))
	elseif #HeroConfig.Power > #HeroConfig.Heroes then
		warn(("[HeroConfig] %d Power values but only %d heroes; the extra values are unused"):format(#HeroConfig.Power, #HeroConfig.Heroes))
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
