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
	WalkSpeed = 8, -- studs/s
	ModelScale = 1.44, -- heroes chopping trees are this much bigger than the template (1 = template size)
	AttackRange = 2.5, -- studs from the trunk's center at which a hero stops and swings
	MoundGap = 0.4, -- studs between a tree's dirt mound and a hero chopping it (heroes stand outside it)
	SwingCooldown = 0.15, -- seconds between swings (on top of the swing animation)
	-- Swing animations: every swing picks one of these at random (never the same twice in a row).
	-- The damage lands on the animation's "Hit" marker, or at HitFraction of the swing without one.
	ChopAnimations = {
		"rbxassetid://108118702779504",
		"rbxassetid://116941453608539",
		"rbxassetid://140540897077688",
	} :: { string },
	HitFraction = 0.55,
	-- Fallback swing when ChopAnimations is empty. Upload ServerStorage.RBX_ANIMSAVES.mymodel.ChopHorizontal
	-- and put its "rbxassetid://..." here. While empty, that KeyframeSequence is played directly
	-- (works in Studio playtests only).
	ChopAnimation = "",
	ChopKeyframes = "ChopHorizontal",
	-- Run animation (axe run, R6) heroes use instead of the default walk. While empty the
	-- KeyframeSequence RBX_ANIMSAVES.mymodel.HeroRun is played directly (Studio playtests only).
	RunAnimation = "rbxassetid://104469645043314",
	RunKeyframes = "HeroRun",
	RunAnimSpeed = 16, -- studs/s the run animation is made for (its playback speed follows WalkSpeed)
	RaritySpeed = { Common = 1, Uncommon = 1.05, Rare = 1.1, Epic = 1.2, Legendary = 1.35, Mythic = 1.5 } :: { [string]: number },
}

-- Idle animations for R6 heroes (R15 heroes keep Roblox's default idle).
HeroConfig.IdleAnimations = {
	Drop = "rbxassetid://140077308386686", -- a hero that just dropped from a felled tree (DropFX)
	Held = "rbxassetid://113945537027249", -- the small hero a player holds in their hands (HeldHeroService)
}

-- Gradient on the rarity text above heroes (HeroBar) and above hero pads (HeroInfo.Rarity), left to right.
local function gradient(a: Color3, b: Color3): ColorSequence
	return ColorSequence.new(a, b)
end
HeroConfig.RarityGradients = {
	Common = gradient(Color3.fromRGB(190, 190, 190), Color3.fromRGB(255, 255, 255)),
	Uncommon = gradient(Color3.fromRGB(70, 220, 90), Color3.fromRGB(190, 255, 140)),
	Rare = gradient(Color3.fromRGB(50, 130, 255), Color3.fromRGB(120, 225, 255)),
	Epic = gradient(Color3.fromRGB(160, 70, 255), Color3.fromRGB(255, 120, 230)),
	Legendary = gradient(Color3.fromRGB(255, 160, 20), Color3.fromRGB(255, 240, 110)),
	Mythic = gradient(Color3.fromRGB(255, 120, 200), Color3.fromRGB(255, 220, 90)),
} :: { [string]: ColorSequence }

-- Moving gradient on those rarity labels (client RarityGradientFX animates every UIGradient tagged
-- RarityGradientTag, reading its "Rarity" attribute). Colors loop seamlessly across the text:
--   Colors = palette, looped (last blends back into the first)
--   (all rarities sweep at the same RarityGradientSweep speed)
--   Span   = how many palette loops fit across the label at once
local rgb = Color3.fromRGB
HeroConfig.RarityGradientTag = "RarityGradient"
HeroConfig.RarityGradientSweep = 0.3 -- label widths per second the colours move, same for every rarity
HeroConfig.RarityGradientFX = {
	Common = { Span = 0.6, Colors = { rgb(170, 170, 170), rgb(255, 255, 255) } },
	Uncommon = { Span = 0.7, Colors = { rgb(60, 210, 80), rgb(190, 255, 140), rgb(120, 240, 110) } },
	Rare = { Span = 0.8, Colors = { rgb(40, 110, 255), rgb(120, 225, 255), rgb(80, 170, 255) } },
	Epic = { Span = 0.9, Colors = { rgb(150, 60, 255), rgb(255, 120, 230), rgb(200, 90, 255) } },
	Legendary = {
		Span = 1,
		Colors = { rgb(255, 140, 10), rgb(255, 245, 130), rgb(255, 190, 40), rgb(255, 255, 220) },
	},
	Mythic = {
		Span = 1,
		Colors = {
			rgb(255, 80, 80),
			rgb(255, 190, 60),
			rgb(255, 255, 90),
			rgb(90, 255, 140),
			rgb(80, 200, 255),
			rgb(170, 110, 255),
			rgb(255, 110, 220),
		},
	},
} :: { [string]: { Span: number, Colors: { Color3 } } }

-- Sets a rarity label's text and gradient (its UIGradient child, made if missing).
function HeroConfig.PaintRarity(label: TextLabel, rarity: string)
	label.Text = rarity
	label.TextColor3 = Color3.new(1, 1, 1) -- the gradient multiplies this
	local g = label:FindFirstChildOfClass("UIGradient")
	if not g then
		g = Instance.new("UIGradient")
		g.Parent = label
	end
	g.Color = HeroConfig.RarityGradients[rarity] or ColorSequence.new(Color3.new(1, 1, 1))
	g.Rotation = 0
	g.Offset = Vector2.zero
	g:SetAttribute("Rarity", rarity)
	game:GetService("CollectionService"):AddTag(g, HeroConfig.RarityGradientTag)
end

-- Hero pads (plot.HeroSlots.Slot1..Slot9). Without upgrades only the first StartUnlocked pads work.
-- The rest are bought in order (hold E at the next locked pad) for UnlockPrices[slot] Money; the
-- player's "UnlockedSlots" attribute holds how many are open (an upgrade can also just set it).
HeroConfig.Slots = {
	StartUnlocked = 4,
	UnlockPrices = { [5] = 5000, [6] = 25000, [7] = 100000, [8] = 500000, [9] = 2500000 } :: { [number]: number },
	PadHeroHeight = 6.4, -- studs, hair included: height of the hero standing on a pad (a player is ~5.6)
	HoldDuration = 1, -- seconds E must be held on a pad (place / take back / unlock)
	LockedText = "Locked",
	LockedPadColor = Color3.fromRGB(105, 105, 110),
	PriceColor = Color3.fromRGB(90, 255, 60), -- the price shown above a locked pad
}

-- ===================== PAD UPGRADES =====================
-- Each hero pad has its own stat levels (all start at 1), bought in the Upgrade window (press F at a
-- pad with a hero on it; HeroUpgradeUI / HeroSlotService). The hero standing on the pad uses them,
-- whichever hero it is. Saved with the player (DataService "PadLevels").
--   Name     = shown in the window
--   MaxLevel = highest level
--   Value    = function(level, hero) -> the stat at that level
--   Cost     = Money for level L -> L+1 is floor(CostBase * CostGrowth ^ (L - 1))
-- The "Level N" text above a hero (pad billboard and HeroBar) is its Damage level.
HeroConfig.UpgradeOrder = { "Damage", "Speed", "Walk" } :: { string }
HeroConfig.Upgrades = {
	Damage = {
		Name = "Chop Damage",
		MaxLevel = 100,
		CostBase = 150,
		CostGrowth = 1.17,
		-- +15% of the hero's base damage per level.
		Value = function(level: number, hero: string): number
			return math.floor(HeroConfig.ChopDamage(hero) * (1 + 0.15 * (level - 1)))
		end,
	},
	Speed = {
		Name = "Chop Speed",
		MaxLevel = 50,
		CostBase = 250,
		CostGrowth = 1.2,
		-- Swing speed multiplier: +3% of the hero's base speed per level.
		Value = function(level: number, hero: string): number
			return HeroConfig.ChopSpeed(hero) * (1 + 0.03 * (level - 1))
		end,
	},
	Walk = {
		Name = "Walk Speed",
		MaxLevel = 30,
		CostBase = 100,
		CostGrowth = 1.22,
		-- Studs/s: Worker.WalkSpeed at level 1, +0.4 per level (8 -> 19.6 at 30).
		Value = function(level: number, _hero: string): number
			return HeroConfig.Worker.WalkSpeed + 0.4 * (level - 1)
		end,
	},
} :: { [string]: { Name: string, MaxLevel: number, CostBase: number, CostGrowth: number, Value: (number, string) -> number } }

-- ===================== STAT GRADES (REROLL) =====================
-- Each pad's stats also have a grade, F (worst) .. SSS (best), that multiplies the stat. "Reroll" in
-- the Upgrade window (costs RerollCost Money) rolls a new grade for every stat of that pad at once.
-- A pad that was never rerolled is DefaultGrade. Saved with the pad levels.
--   Multiplier  = stat x this at full effect
--   Weight      = roll chance (relative; they don't need to add up to 100)
--   Color       = badge colour; Gradient = name of a RarityGradientFX entry to animate the badge text
--   GradeEffect = per stat, how much of the multiplier applies (1 = all of it): grade 1.5x on a stat
--                 with effect 0.4 gives 1 + 0.5 * 0.4 = 1.2x. Keeps walk speed from going wild.
HeroConfig.GradeOrder = { "F", "E", "D", "C", "B", "A", "S", "SS", "SSS" } :: { string }
HeroConfig.Grades = {
	F = { Multiplier = 0.7, Weight = 28, Color = rgb(150, 150, 150) },
	E = { Multiplier = 0.85, Weight = 22, Color = rgb(170, 120, 80) },
	D = { Multiplier = 1, Weight = 18, Color = rgb(90, 200, 90) },
	C = { Multiplier = 1.15, Weight = 13, Color = rgb(60, 200, 200) },
	B = { Multiplier = 1.3, Weight = 9, Color = rgb(70, 140, 255) },
	A = { Multiplier = 1.5, Weight = 5.5, Color = rgb(170, 90, 255) },
	S = { Multiplier = 1.8, Weight = 2.8, Color = rgb(255, 200, 40), Gradient = "Legendary" },
	SS = { Multiplier = 2.2, Weight = 1.2, Color = rgb(255, 110, 60), Gradient = "Legendary" },
	SSS = { Multiplier = 3, Weight = 0.5, Color = rgb(255, 80, 200), Gradient = "Mythic" },
} :: { [string]: { Multiplier: number, Weight: number, Color: Color3, Gradient: string? } }
HeroConfig.DefaultGrade = "D"
HeroConfig.RerollCost = 2500 -- "Reroll All" (all unlocked stats)
HeroConfig.RerollStatCost = 1000 -- the reroll button on one stat's row
-- Locking stats (lock icon on a grade badge) keeps their grade on the next reroll, but multiplies
-- that reroll's price: by number of locked stats. At least one stat must stay unlocked.
HeroConfig.RerollLockMultipliers = { [0] = 1, [1] = 3, [2] = 10 } :: { [number]: number }

-- Price of a reroll with `locked` stats locked (nil when that many can't be locked).
function HeroConfig.RerollCostFor(locked: number): number?
	local mult = HeroConfig.RerollLockMultipliers[locked]
	return if mult then math.floor(HeroConfig.RerollCost * mult) else nil
end
HeroConfig.GradeEffect = { Damage = 1, Speed = 0.6, Walk = 0.4 } :: { [string]: number }

-- Slot attribute that holds a pad's grade letter for `stat` (e.g. "GradeDamage").
function HeroConfig.GradeAttribute(stat: string): string
	return "Grade" .. stat
end

-- A random grade letter, by Weight.
function HeroConfig.RollGrade(rng: Random): string
	local total = 0
	for _, grade in HeroConfig.GradeOrder do
		total += HeroConfig.Grades[grade].Weight
	end
	local pick = rng:NextNumber() * total
	for _, grade in HeroConfig.GradeOrder do
		pick -= HeroConfig.Grades[grade].Weight
		if pick <= 0 then
			return grade
		end
	end
	return HeroConfig.GradeOrder[1]
end

-- Chance (0..1) of rolling `grade`.
function HeroConfig.GradeChance(grade: string): number
	local total = 0
	for _, g in HeroConfig.GradeOrder do
		total += HeroConfig.Grades[g].Weight
	end
	local def = HeroConfig.Grades[grade]
	return if def and total > 0 then def.Weight / total else 0
end

-- The stat a pad gives its hero: upgrade level value x grade multiplier (scaled by GradeEffect).
function HeroConfig.StatValue(stat: string, level: number, grade: string?, hero: string): number
	local up = HeroConfig.Upgrades[stat]
	local def = HeroConfig.Grades[grade or HeroConfig.DefaultGrade] or HeroConfig.Grades[HeroConfig.DefaultGrade]
	local mult = 1 + (def.Multiplier - 1) * (HeroConfig.GradeEffect[stat] or 1)
	local value = up.Value(level, hero) * mult
	return if stat == "Damage" then math.max(1, math.floor(value)) else value
end

-- Slot attribute that holds a pad's level for `stat` (e.g. "LevelDamage").
function HeroConfig.LevelAttribute(stat: string): string
	return "Level" .. stat
end

-- Money to go from `level` to `level + 1`, or nil at max level.
function HeroConfig.UpgradeCost(stat: string, level: number): number?
	local up = HeroConfig.Upgrades[stat]
	if not up or level >= up.MaxLevel then
		return nil
	end
	return math.floor(up.CostBase * up.CostGrowth ^ (level - 1))
end

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
	{ Name = "Sling Pirate", Rarity = "Common", Template = "SlingPirate", ChopDamage = 5 },
	{ Name = "Taijutsu Ninja", Rarity = "Common", Template = "TaijutsuNinja", ChopDamage = 6 },
	{ Name = "Uzumaki Kid", Rarity = "Uncommon", Template = "UzumakiKid", ChopDamage = 13 },
	{ Name = "Copy Ninja", Rarity = "Rare", Template = "CopyNinja", ChopDamage = 31 },
	{ Name = "Perfect Bioform", Rarity = "Epic", Template = "PerfectBioform", ChopDamage = 195 },
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
