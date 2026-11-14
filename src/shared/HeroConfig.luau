--!strict
-- HeroConfig: every anime hero in the game. Edit this list to add / tune heroes.
--
-- Each hero:
--   Name      = shown in the UI, and the name used in ZoneDrops (e.g. { Item = "Uzumaki Shounen", Chance = 0.03 })
--   Rarity    = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic" (slot colour, sorting)
--   Template  = name of the hero's model inside ReplicatedStorage.HeroTemplates
--   (Power is NOT set here: it lives in HeroConfig.Power, by position in the list. Power IS the
--    hero's chop damage: one axe swing on a tree deals Power (before pad upgrades / grade / axe).
--    Shown on the hotbar / chest / popups / InfoBars, and the hotbar puts the highest Power first.
--    Code reads it as hero.MinePower.)
--   AnimeImage = uploaded hero icon ("rbxassetid://123" or just "123"); empty = draw the 3D model
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
	SellValue: number, -- Money per copy at the Sell shop (x ShopConfig.HeroSellMultiplier)
	AnimeImage: string?, -- normalized "rbxassetid://..." (nil when empty)
	ChopSpeed: number?,
	-- Set on mutated / sized heroes only (see MUTATIONS & SIZES below):
	Base: string?, -- the plain hero's name (e.g. "Sling Scout" for "Diamond Huge Sling Scout")
	Mutation: string?, -- "Diamond" | "Emerald" | ... (nil = no mutation)
	Size: string?, -- "Large" | "Huge" | ... (nil = Normal)
	WalkMult: number?, -- walk speed multiplier from mutation x size
	Scale: number?, -- body size multiplier of the chopping copy (1 = Normal)
	PadScale: number?, -- body size multiplier of the copy standing on the pad
}

-- One row of the hero list below (MinePower comes from HeroConfig.Power).
type HeroEntry = {
	Name: string,
	Rarity: Rarity,
	Template: string,
	Sell: (number | string)?, -- sell price; "1.2K" style works. Without it: its Power.
	AnimeImage: string?,
	ChopSpeed: number?,
}

local HeroConfig = {}

-- Folder that holds the hero models named by `Template`.
HeroConfig.TemplateFolder = "Heros"
-- Model used when a hero's Template is not in the folder yet (so every hero can still work a slot).
HeroConfig.FallbackTemplate = "UzumakiShounen"
-- The bars above heroes and trees are shared templates in ReplicatedStorage.<BarFolder>:
-- HeroBar (name / rarity / level / power, HeroModels) and TreeBar (name / HP, TreeService).
-- Edit them there; every hero / tree gets a clone on spawn.
HeroConfig.BarFolder = "InfoBars"
HeroConfig.BarAboveHead = 2 -- studs between the top of the head and the bar's centre

-- Heroes placed on a plot's HeroSlots walk out of the HeroGate and chop trees (HeroWorkerService).
HeroConfig.Worker = {
	WalkSpeed = 8, -- studs/s
	-- Heroes chopping trees are sized by the plot owner's body height, not the template's size:
	-- body = HeightRatio x the player's body (0.5 = half as tall). Bigger sizes multiply this by their
	-- Scale (HeroConfig.Sizes). Only the spawned copy is scaled, so templates in ReplicatedStorage.Heros
	-- stay at their catalog size.
	HeightRatio = 0.5,
	-- Extra studs a bigger hero stands away from the trunk, per +1 of its size Scale (so a Titanic
	-- hero doesn't stand inside the tree).
	SizeReach = 1.2,
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
	-- R15 heroes (ChopAnimations above are R6) pick from these instead: 2 quick swings + 1 charged swing.
	-- Built by tools/BuildChopR15.luau into ServerStorage.RBX_ANIMSAVES.SaiyanWarrior. Until an entry of
	-- ChopAnimationsR15 holds its uploaded "rbxassetid://...", the KeyframeSequence named at the same
	-- index of ChopKeyframesR15 is played directly (works in Studio playtests only).
	ChopAnimationsR15 = {
		"rbxassetid://95909094562468", -- ChopR15_LightA: quick horizontal slash
		"rbxassetid://126898210983268", -- ChopR15_LightB: quick diagonal chop
		"rbxassetid://97801689050382", -- ChopR15_Heavy: charged swing
	} :: { string },
	ChopKeyframesR15 = { "ChopR15_LightA", "ChopR15_LightB", "ChopR15_Heavy" } :: { string },
	-- Damage multiplier of each R15 swing (same order): the charged swing hits twice as hard.
	ChopDamageMultR15 = { 1, 1, 2 } :: { number },
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
	-- Run animation for R15 heroes (replaces Roblox's default walk on them).
	RunAnimationR15 = "rbxassetid://109710881284083",
	RunAnimSpeed = 8, -- studs/s at which the run animation plays at 1x (= WalkSpeed, so a level 1 hero runs at normal speed; faster heroes play it faster)
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
	HeroConfig.PaintRarityGradient(label, rarity)
end

-- Gives any label (e.g. a hero's name) the moving gradient of `rarity`, keeping its text. Hero
-- billboards show the rarity this way instead of a separate "Rarity" line.
function HeroConfig.PaintRarityGradient(label: TextLabel, rarity: string)
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
	-- The hero standing on a pad is scaled so its body (hats / hair not counted) is as tall as the
	-- plot owner's body; PadHeroHeight is used when the owner has no character yet (R6 player = 5).
	PadHeroHeight = 5,
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
		-- Studs/s: Worker.WalkSpeed at level 1, +0.4 per level (8 -> 19.6 at 30), x the hero's
		-- mutation / size walk bonus (HeroConfig.WalkMultiplier).
		Value = function(level: number, hero: string): number
			return (HeroConfig.Worker.WalkSpeed + 0.4 * (level - 1)) * HeroConfig.WalkMultiplier(hero)
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

-- The other way round: "1.3K" -> 1300, "15.3M" -> 15300000, "1.9T", 250 -> 250. Accepts any unit
-- Abbreviate writes (K M B T Qd Qi Sx Sp Oc No Dc, any case; "Qa" = Qd too), commas and spaces.
-- Returns nil for text it can't read.
-- An uploaded image id from a config ("rbxassetid://123", "123" or 123) as "rbxassetid://123";
-- nil when empty, so the UI falls back to drawing the 3D model.
function HeroConfig.AssetId(value: (string | number)?): string?
	if value == nil then
		return nil
	end
	local text = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then
		return nil
	end
	if text:match("^%d+$") then
		return "rbxassetid://" .. text
	end
	return text
end

local UNIT_VALUES: { [string]: number } = { qa = 1e15 }
for _, unit in UNITS do
	UNIT_VALUES[unit[2]:lower()] = unit[1]
end
function HeroConfig.ParseNumber(value: number | string): number?
	if typeof(value) == "number" then
		return value
	end
	if typeof(value) ~= "string" then
		return nil
	end
	local text = value:gsub("[,%s]", "")
	local num, unit = text:match("^([%d%.]+)(%a*)$")
	local n = num and tonumber(num)
	if not n then
		return nil
	end
	if unit == "" then
		return n
	end
	local mult = UNIT_VALUES[unit:lower()]
	return if mult then n * mult else nil
end

-- ===================== POWER =====================
-- Mine Power by POSITION in the hero list below: the 1st hero gets Power[1], the 2nd Power[2], ...
-- To re-order heroes, just move their lines in HERO_LIST; these numbers stay where they are.
-- Write plain numbers (195) or text tiers ("1.3K", "15.3M", "1.9T"; see HeroConfig.ParseNumber).
-- Power is the hero's chop damage per swing (HeroConfig.ChopDamage). The hotbar sorts by Power
-- (highest first). Sell price is each hero's own `Sell` in HERO_LIST below (not its Power).
HeroConfig.Power = {
	--zone1
	5,
	6,
	13,
	31,
	195,
	--zone2
	"1.3K",
	"3.5K",
	"7.8K",
	"20K",
	"48K",
	"61K",
	"125K",
	"307K",
	--zone3
	"325K",
	"785K",
	"2M",
	"5M",
	"12M",
	"15.3M",
	"30.5M",
	"38.2M",
	"77.3M",
	--zone4
	"78.1M",
	"195.5M",
	"488.2M",
	"1.2B",
	"1.5B",
	"3.1B",
	"7.8B",
	"9.5B",
	"19.5B",
	"48.8B",
	--zone5
	"49.5B",
	"65B",
	"122.1B",
	"305.2B",
	"381.5B",
	"762.9B",
	"953.7B",
	"1.9T",
	"2.4T",
	"4.8T",
	"11.9T"


} :: { number | string }

-- Hero list. Order matters: a hero's Power is HeroConfig.Power[its position].
-- Sell prices: each hero is worth about (Money a tree gives) / (its chance per tree) x 0.4 / heroes
-- in the zone, so every hero adds the same small share and selling all heroes from a zone earns
-- ~40% of what its materials do (zone 1 ~15 / tree, zone 2 ~150 / tree). Rarer = bigger payout.
local HERO_LIST: { HeroEntry } = {
	-- Zone 1 (Green Wood)                                                         drop share
	{ Name = "Kabuto Boy", Rarity = "Common", Template = "KabutoBoy", Sell = 35, AnimeImage = "rbxassetid://76748798917325" }, -- 45%
	{ Name = "Taijutsu Ninja", Rarity = "Common", Template = "TaijutsuNinja", Sell = 60, AnimeImage = "rbxassetid://86879870146891" }, -- 25%
	{ Name = "Dragon Kid", Rarity = "Uncommon", Template = "DragonKid", Sell = 85, AnimeImage = "rbxassetid://140552811606478" }, -- 18%
	{ Name = "Copy Sensei", Rarity = "Rare", Template = "CopySensei", Sell = 170, AnimeImage = "rbxassetid://72876779059670" }, -- 9%
	{ Name = "Green Beetle", Rarity = "Epic", Template = "GreenBeetle", Sell = 500, AnimeImage = "rbxassetid://114514644383243" }, -- 3%
	-- Zone 2 (Orchard Valley)
	{ Name = "Mystic Servant", Rarity = "Common", Template = "MysticServant", Sell = 200, AnimeImage = "rbxassetid://91988318238562" }, -- 45.02%
	{ Name = "Uzumaki Kid", Rarity = "Uncommon", Template = "UzumakiKid", Sell = 350, AnimeImage = "rbxassetid://129376399913384" }, -- 26%
	{ Name = "Flame Fist", Rarity = "Rare", Template = "FlameFist", Sell = 600, AnimeImage = "rbxassetid://84800553799012" }, -- 15%
	{ Name = "Sin Captain", Rarity = "Rare", Template = "SinCaptain", Sell = "1.2K", AnimeImage = "rbxassetid://73841309208420" }, -- 7.6%
	{ Name = "Whale Island Kid", Rarity = "Epic", Template = "WhaleIslandKid", Sell = "2.5K", AnimeImage = "rbxassetid://110713314490351" }, -- 3.7%
	{ Name = "Water Swordman", Rarity = "Epic", Template = "WaterSwordsman", Sell = "5.5K", AnimeImage = "rbxassetid://72971443145371" }, -- 1.7%
	{ Name = "Star Brawler", Rarity = "Legendary", Template = "StarBrawler", Sell = "13K", AnimeImage = "rbxassetid://80282275912995" }, -- 0.7%
	{ Name = "Marine Grandpa", Rarity = "Mythic", Template = "MarineGrandpa", Sell = "33K", AnimeImage = "rbxassetid://89773245024998" }, -- 0.28%
	-- Zone 3 (Orchard Valley)
}

HeroConfig.Heroes = {} :: { HeroDef }
local byName: { [string]: HeroDef } = {}
for index, entry in HERO_LIST do
	local power = HeroConfig.ParseNumber(HeroConfig.Power[index] or 0) or 0
	local hero: HeroDef = {
		Name = entry.Name,
		Rarity = entry.Rarity,
		Template = entry.Template,
		MinePower = power,
		SellValue = if entry.Sell ~= nil then HeroConfig.ParseNumber(entry.Sell) or power else power,
		AnimeImage = HeroConfig.AssetId(entry.AnimeImage),
		ChopSpeed = entry.ChopSpeed,
	}
	table.insert(HeroConfig.Heroes, hero)
	byName[hero.Name] = hero
end

-- ===================== MUTATIONS & SIZES =====================
-- Every hero that drops from a tree rolls ONE mutation and ONE size (TreeHitService). A mutated /
-- sized hero is its own item, named "<Mutation> <Size> <Hero>" (e.g. "Diamond Huge Sling Scout",
-- "Rainbow Sling Scout", "Titanic Sling Scout"): it stacks, sells, saves and stands on pads like any
-- hero, and HeroConfig.Get(thatName) gives its boosted stats.
--
--   Chance    = percent per hero drop at luck x1. Whatever is left up to 100% is "no mutation" /
--               Normal size. Luck (player attributes MutationLuck / SizeLuck from the skill trees)
--               multiplies every Chance, so the plain result gets rarer.
--   Damage    = chop damage (Power) multiplier
--   ChopSpeed = swing speed multiplier (kept small on purpose)
--   Walk      = walk speed multiplier (kept small on purpose)
--   Sell      = sell price multiplier
--   Color     = name colour / sparkle colour (Rainbow uses Colors: a cycling palette)
-- Mutation and size multipliers stack: Rainbow (x20) Titanic (x7.59) = x151.8 damage.
export type MutationDef = {
	Chance: number,
	Damage: number,
	ChopSpeed: number,
	Walk: number,
	Sell: number,
	Color: Color3,
	Colors: { Color3 }?,
}
HeroConfig.MutationOrder = { "Diamond", "Emerald", "Rainbow" } :: { string }
HeroConfig.Mutations = {
	Diamond = { Chance = 4, Damage = 3, ChopSpeed = 1.1, Walk = 1.06, Sell = 3, Color = rgb(110, 220, 255) },
	Emerald = { Chance = 2, Damage = 5, ChopSpeed = 1.15, Walk = 1.09, Sell = 5, Color = rgb(60, 235, 110) },
	Rainbow = {
		Chance = 0.5, Damage = 20, ChopSpeed = 1.3, Walk = 1.15, Sell = 20, Color = rgb(255, 255, 255),
		Colors = { rgb(255, 80, 80), rgb(255, 190, 60), rgb(255, 255, 90), rgb(90, 255, 140), rgb(80, 200, 255), rgb(170, 110, 255), rgb(255, 110, 220) },
	},
} :: { [string]: MutationDef }

--   Scale    = body size of the chopping hero vs Normal (Normal = Worker.HeightRatio of the player)
--   PadScale = body size of the hero standing on its pad vs Normal (kept small so pads don't overlap)
export type SizeDef = {
	Chance: number,
	Damage: number,
	ChopSpeed: number,
	Walk: number,
	Sell: number,
	Scale: number,
	PadScale: number,
	Color: Color3,
}
HeroConfig.SizeOrder = { "Large", "Huge", "Colossal", "Gigantic", "Titanic" } :: { string }
HeroConfig.Sizes = {
	Large = { Chance = 15, Damage = 1.5, ChopSpeed = 1, Walk = 1.02, Sell = 1.5, Scale = 1.25, PadScale = 1.05, Color = rgb(230, 230, 230) },
	Huge = { Chance = 3.5, Damage = 2.25, ChopSpeed = 1, Walk = 1.04, Sell = 2.25, Scale = 1.5, PadScale = 1.1, Color = rgb(255, 210, 70) },
	Colossal = { Chance = 0.975, Damage = 3.38, ChopSpeed = 1, Walk = 1.06, Sell = 3.38, Scale = 1.8, PadScale = 1.15, Color = rgb(255, 140, 50) },
	Gigantic = { Chance = 0.315, Damage = 5.06, ChopSpeed = 1, Walk = 1.08, Sell = 5.06, Scale = 2.15, PadScale = 1.2, Color = rgb(255, 80, 70) },
	Titanic = { Chance = 0.126, Damage = 7.59, ChopSpeed = 1, Walk = 1.1, Sell = 7.59, Scale = 2.6, PadScale = 1.3, Color = rgb(255, 90, 190) },
} :: { [string]: SizeDef }

-- ===================== SIZE BADGE =====================
-- A sized hero shows its size ("HUGE", "GIGANTIC" ...) as a pill of its own just above the hero's
-- billboard (HeroBar above heroes, HeroInfo above pads), apart from the name, so it is easy to tell
-- at a glance. The pill's gradient moves like the rarity gradients (RarityGradientFX animates it;
-- same Span / Colors format as HeroConfig.RarityGradientFX).
HeroConfig.SizeBadgeFX = {
	Large = { Span = 0.8, Colors = { rgb(150, 165, 190), rgb(255, 255, 255), rgb(195, 210, 230) } },
	Huge = { Span = 1, Colors = { rgb(255, 160, 0), rgb(255, 245, 140), rgb(255, 200, 30), rgb(255, 255, 215) } },
	Colossal = { Span = 1, Colors = { rgb(255, 95, 10), rgb(255, 205, 70), rgb(255, 140, 30), rgb(255, 235, 150) } },
	Gigantic = { Span = 1, Colors = { rgb(190, 0, 30), rgb(255, 90, 40), rgb(255, 190, 60), rgb(255, 40, 90) } },
	Titanic = {
		Span = 1.2,
		Colors = { rgb(150, 50, 255), rgb(255, 80, 200), rgb(90, 210, 255), rgb(255, 150, 240), rgb(120, 90, 255) },
	},
} :: { [string]: { Span: number, Colors: { Color3 } } }
for id, fx in HeroConfig.SizeBadgeFX do
	HeroConfig.RarityGradientFX[id] = fx -- RarityGradientFX looks gradients up by their "Rarity" attribute
end
HeroConfig.SizeBadgeName = "SizeBadge"
HeroConfig.SizeBadgeHeight = 0.75 -- studs
HeroConfig.SizeBadgeGap = 0.1 -- studs between the badge and the billboard text under it
local BADGE_OUTLINE = rgb(30, 20, 40)

-- The hero's name without its size ("Diamond Huge Sling Scout" -> "Diamond Sling Scout"): the size is
-- on the badge instead.
function HeroConfig.DisplayName(def: HeroDef): string
	if def.Base then
		return HeroConfig.VariantName(def.Base, def.Mutation, nil)
	end
	return def.Name
end

-- Draws (or, size = nil, removes) the size badge of the billboard `source`: a BillboardGui named
-- SizeBadgeName next to it (same attachment, same settings) whose bottom sits `topStuds` (+ gap) above
-- `source`'s centre, i.e. just over its top line of text. `font` = font of the text.
function HeroConfig.PaintSizeBadge(source: BillboardGui, topStuds: number, size: string?, font: Font?)
	local parent = source.Parent
	if not parent then
		return
	end
	local badge = parent:FindFirstChild(HeroConfig.SizeBadgeName)
	if not size or not HeroConfig.Sizes[size] then
		if badge then
			badge:Destroy()
		end
		return
	end
	if badge and badge:GetAttribute("Size") == size then
		(badge :: BillboardGui).Enabled = source.Enabled
		return
	end
	if badge then
		badge:Destroy()
	end
	local text = string.upper(size)
	local h = HeroConfig.SizeBadgeHeight
	local gui = Instance.new("BillboardGui")
	gui.Name = HeroConfig.SizeBadgeName
	gui:SetAttribute("Size", size)
	gui.Adornee = source.Adornee
	gui.AlwaysOnTop = source.AlwaysOnTop
	gui.LightInfluence = source.LightInfluence
	gui.Brightness = source.Brightness
	gui.MaxDistance = source.MaxDistance
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ClipsDescendants = false
	gui.Active = false
	gui.Enabled = source.Enabled
	gui.Size = UDim2.fromScale(#text * h * 0.58 + h * 1.1, h)
	gui.StudsOffsetWorldSpace = source.StudsOffsetWorldSpace
	gui.StudsOffset = source.StudsOffset + Vector3.new(0, topStuds + HeroConfig.SizeBadgeGap + h / 2, 0)

	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.Size = UDim2.fromScale(1, 1)
	pill.BackgroundColor3 = Color3.new(1, 1, 1) -- the gradient multiplies this
	pill.BorderSizePixel = 0
	pill.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = pill
	local outline = Instance.new("UIStroke")
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	outline.Color = BADGE_OUTLINE
	outline.Thickness = 2.5
	outline.Parent = pill
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(HeroConfig.SizeBadgeFX[size].Colors[1], HeroConfig.SizeBadgeFX[size].Colors[2])
	g:SetAttribute("Rarity", size)
	g.Parent = pill
	game:GetService("CollectionService"):AddTag(g, HeroConfig.RarityGradientTag)

	local label = Instance.new("TextLabel")
	label.Name = "SizeText"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.52)
	label.Size = UDim2.fromScale(0.86, 0.8)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	if font then
		label.FontFace = font
	else
		label.Font = Enum.Font.FredokaOne
	end
	label.ZIndex = 2
	label.Parent = pill
	local stroke = Instance.new("UIStroke")
	stroke.Color = BADGE_OUTLINE
	stroke.Thickness = 2.5
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label

	gui.Parent = parent
end

-- Weighted roll over `order` with each Chance x luck; nil = the plain result. Also returns the
-- chance (0..1) of what was picked, plain result included.
local function rollTier(rng: Random, order: { string }, defs: { [string]: { Chance: number } }, luck: number, boost: { [string]: number }?): (string?, number)
	luck = math.max(0, luck)
	local pick = rng:NextNumber() * 100
	local used = 0
	for i = #order, 1, -1 do -- rarest first, so they still fit when luck pushes the total past 100%
		local id = order[i]
		local chance = math.min(defs[id].Chance * luck * (if boost then boost[id] or 1 else 1), 100 - used)
		if chance > 0 and pick < used + chance then
			return id, chance / 100
		end
		used += math.max(0, chance)
	end
	return nil, math.max(0, 100 - used) / 100
end

-- Chance (0..1) of each result at `luck` (plain result under the key "None"), for UIs.
local function tierChances(order: { string }, defs: { [string]: { Chance: number } }, luck: number): { [string]: number }
	local out = {}
	local used = 0
	for i = #order, 1, -1 do
		local id = order[i]
		local chance = math.max(0, math.min(defs[id].Chance * math.max(0, luck), 100 - used))
		out[id] = chance / 100
		used += chance
	end
	out.None = math.max(0, 100 - used) / 100
	return out
end

function HeroConfig.MutationChances(luck: number?): { [string]: number }
	return tierChances(HeroConfig.MutationOrder, HeroConfig.Mutations, luck or 1)
end

function HeroConfig.SizeChances(luck: number?): { [string]: number }
	return tierChances(HeroConfig.SizeOrder, HeroConfig.Sizes, luck or 1)
end

-- Rolls a mutation and a size. Returns (mutation?, size?, chance of that exact combination 0..1).
-- mutationBoost = extra chance multiplier for single mutations (weather, e.g. { Diamond = 3 }).
function HeroConfig.RollVariant(rng: Random, mutationLuck: number?, sizeLuck: number?, mutationBoost: { [string]: number }?): (string?, string?, number)
	local mutation, mChance = rollTier(rng, HeroConfig.MutationOrder, HeroConfig.Mutations, mutationLuck or 1, mutationBoost)
	local size, sChance = rollTier(rng, HeroConfig.SizeOrder, HeroConfig.Sizes, sizeLuck or 1)
	return mutation, size, mChance * sChance
end

-- "Diamond Huge Sling Scout" from ("Sling Scout", "Diamond", "Huge"); plain parts are left out.
function HeroConfig.VariantName(base: string, mutation: string?, size: string?): string
	local name = base
	if size and HeroConfig.Sizes[size] then
		name = size .. " " .. name
	end
	if mutation and HeroConfig.Mutations[mutation] then
		name = mutation .. " " .. name
	end
	return name
end

-- The other way round: "Diamond Huge Sling Scout" -> ("Sling Scout", "Diamond", "Huge").
-- A name that is a plain hero is never split (so a hero may be called "Diamond ..." safely).
function HeroConfig.SplitVariant(name: string): (string, string?, string?)
	if byName[name] then
		return name, nil, nil
	end
	local rest, mutation, size = name, nil, nil
	for _, id in HeroConfig.MutationOrder do
		if rest:sub(1, #id + 1) == id .. " " then
			mutation = id
			rest = rest:sub(#id + 2)
			break
		end
	end
	for _, id in HeroConfig.SizeOrder do
		if rest:sub(1, #id + 1) == id .. " " then
			size = id
			rest = rest:sub(#id + 2)
			break
		end
	end
	return rest, mutation, size
end

local variantCache: { [string]: HeroDef } = {}

-- The hero called `name`: a plain hero, or a mutated / sized one ("Diamond Huge Sling Scout") with
-- its Power, sell price and speed already multiplied.
function HeroConfig.Get(name: string): HeroDef?
	local plain = byName[name]
	if plain then
		return plain
	end
	local cached = variantCache[name]
	if cached then
		return cached
	end
	local base, mutation, size = HeroConfig.SplitVariant(name)
	local def = byName[base]
	if not def or (not mutation and not size) then
		return nil
	end
	local m = mutation and HeroConfig.Mutations[mutation]
	local s = size and HeroConfig.Sizes[size]
	local function mult(field: string): number
		return (if m then (m :: any)[field] else 1) * (if s then (s :: any)[field] else 1)
	end
	local baseSpeed = def.ChopSpeed or HeroConfig.Worker.RaritySpeed[def.Rarity] or 1
	local variant: HeroDef = {
		Name = name,
		Rarity = def.Rarity,
		Template = def.Template,
		MinePower = def.MinePower * mult("Damage"),
		SellValue = math.floor(def.SellValue * mult("Sell")),
		AnimeImage = def.AnimeImage,
		ChopSpeed = baseSpeed * mult("ChopSpeed"),
		Base = base,
		Mutation = mutation,
		Size = size,
		WalkMult = mult("Walk"),
		Scale = if s then s.Scale else 1,
		PadScale = if s then s.PadScale else 1,
	}
	variantCache[name] = variant
	return variant
end

-- Walk speed multiplier of a hero (mutation x size; 1 for plain heroes).
function HeroConfig.WalkMultiplier(name: string): number
	local def = HeroConfig.Get(name)
	return if def and def.WalkMult then def.WalkMult else 1
end

-- Mutations that were taken out of the game: a saved "Gold Huge Sling Scout" loads as "Huge Sling Scout".
-- (DataService maps saved Heroes / Placed / chest heroes through HeroConfig.CurrentName.)
HeroConfig.RemovedMutations = { "Gold", "Ruby" } :: { string }

function HeroConfig.CurrentName(name: string): string
	if not byName[name] then
		for _, id in HeroConfig.RemovedMutations do
			if name:sub(1, #id + 1) == id .. " " then
				return name:sub(#id + 2)
			end
		end
	end
	return name
end

-- The hero's model from ReplicatedStorage.Heros (not cloned), or nil if it is not there.
function HeroConfig.GetTemplate(name: string): Model?
	local hero = HeroConfig.Get(name)
	local folder = ReplicatedStorage:FindFirstChild(HeroConfig.TemplateFolder)
	local model = hero and folder and folder:FindFirstChild(hero.Template)
	return if model and model:IsA("Model") then model else nil
end

-- Damage one axe swing of this hero deals to a tree (before pad upgrades): its Power.
function HeroConfig.ChopDamage(name: string): number
	local hero = HeroConfig.Get(name)
	if not hero then
		return 1
	end
	return math.max(1, math.floor(hero.MinePower))
end

-- Swing animation speed multiplier for this hero.
function HeroConfig.ChopSpeed(name: string): number
	local hero = HeroConfig.Get(name)
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
	for index, value in HeroConfig.Power do
		if not HeroConfig.ParseNumber(value) then
			warn(("[HeroConfig] Power[%d] = %q is not a number or text tier like \"1.3K\" (used as 0)"):format(index, tostring(value)))
		end
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
