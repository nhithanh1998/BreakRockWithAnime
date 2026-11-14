--!strict
-- WeatherConfig: server-wide weather events. Edit this file to add / tune weathers.
--
-- Schedule: every Interval seconds (default 1 hour) ONE random weather (by Weight) happens, at a
-- random moment inside that hour, for Duration seconds (default 5 min). Never the same one twice in a
-- row. Everyone in the server gets its buffs while it lasts (WeatherService on the server).
--
-- Each weather:
--   Id, Name, Icon (emoji in the UI), Color (UI / effects), Weight (how often it is picked)
--   Desc     = one line shown in the announcement
--   Buffs    = { Stat = multiplier }   stats: see WeatherConfig.Stats below
--   Mutation = { MutationName = multiplier }  extra chance for that one hero mutation (HeroConfig)
--   Visual   = client effects: Particles ("Rain" | "Snow" | "Sand" | "Gold" | "Ember" | "Aurora" |
--              "Rainbow") and Lightning (WeatherFX); Lighting = preset name in LightingPresets
--              (LightingController; default = the weather's Id)
--
-- State (replicated): ReplicatedStorage attributes "Weather" (Id or ""), "WeatherEnds" and
-- "WeatherNext" (workspace:GetServerTimeNow() times). WeatherConfig.Mult(stat) reads them, so the
-- same numbers work on the server and the client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type Visual = {
	Particles: string?,
	Lighting: string?, -- LightingPresets name
	Lightning: boolean?,
}

export type WeatherDef = {
	Id: string,
	Name: string,
	Icon: string,
	Color: Color3,
	Weight: number,
	Desc: string,
	Buffs: { [string]: number },
	Mutation: { [string]: number }?,
	Visual: Visual,
}

local WeatherConfig = {}

WeatherConfig.Interval = 60 * 60 -- one weather per hour
WeatherConfig.Duration = 5 * 60 -- lasting 5 minutes
-- Studio playtests: a weather comes quickly so it can be tested.
WeatherConfig.Studio = { FirstDelay = 15, Interval = 4 * 60, Duration = 90 }

-- Buffable stats, the label the UI shows, and where they apply.
WeatherConfig.Stats = {
	HeroLuck = "Hero Luck", -- chance a tree drops a hero (TreeHitService)
	MutationLuck = "Mutation Luck", -- chance a dropped hero is Diamond / Emerald / Rainbow
	SizeLuck = "Size Luck", -- chance a dropped hero is Large / Huge / ...
	DropLuck = "Drop Luck", -- chance of the non-guaranteed material drops
	HeroDamage = "Hero Damage", -- chop damage of heroes on pads (HeroWorkerService)
	HeroSpeed = "Hero Speed", -- swing speed of heroes on pads
	HeroWalk = "Hero Walk", -- walk speed of heroes on pads
	ClickDamage = "Click Damage", -- your own axe clicks
	SellBonus = "Sell Price", -- money from selling materials and heroes
} :: { [string]: string }
-- Display order of the buffs.
WeatherConfig.StatOrder = { "HeroLuck", "MutationLuck", "SizeLuck", "DropLuck", "HeroDamage", "HeroSpeed", "HeroWalk", "ClickDamage", "SellBonus" }

WeatherConfig.Weathers = {
	{
		Id = "Rain", Name = "Rain", Icon = "🌧️", Color = Color3.fromRGB(90, 160, 255), Weight = 30,
		Desc = "Soft wet wood: heroes chop faster and trees drop more!",
		Buffs = { HeroSpeed = 1.25, DropLuck = 1.5 },
		Visual = { Particles = "Rain", Lighting = "Rain" },
	},
	{
		Id = "Thunder", Name = "Thunderstorm", Icon = "⛈️", Color = Color3.fromRGB(170, 140, 255), Weight = 20,
		Desc = "Charged heroes hit harder and mutations spark up!",
		Buffs = { HeroDamage = 1.5, MutationLuck = 2 },
		Visual = { Particles = "Rain", Lighting = "Storm", Lightning = true },
	},
	{
		Id = "Snow", Name = "Snowfall", Icon = "❄️", Color = Color3.fromRGB(190, 235, 255), Weight = 18,
		Desc = "Frozen heroes: Diamond mutations x3 and bigger sizes!",
		Buffs = { SizeLuck = 1.5 },
		Mutation = { Diamond = 3 },
		Visual = { Particles = "Snow", Lighting = "Snow" },
	},
	{
		Id = "Sandstorm", Name = "Sandstorm", Icon = "🌪️", Color = Color3.fromRGB(235, 195, 110), Weight = 12,
		Desc = "The wind carries heroes: Huge sizes x2 and faster walking!",
		Buffs = { SizeLuck = 2, HeroWalk = 1.3 },
		Visual = { Particles = "Sand", Lighting = "Sandstorm" },
	},
	{
		Id = "Golden", Name = "Golden Hour", Icon = "☀️", Color = Color3.fromRGB(255, 205, 60), Weight = 10,
		Desc = "Everything shines: sell for x2 and your axe hits x2!",
		Buffs = { SellBonus = 2, ClickDamage = 2 },
		Visual = { Particles = "Gold", Lighting = "Golden" },
	},
	{
		Id = "BloodMoon", Name = "Blood Moon", Icon = "🌕", Color = Color3.fromRGB(255, 70, 70), Weight = 6,
		Desc = "Heroes go berserk: x2 damage and x2 hero luck!",
		Buffs = { HeroDamage = 2, HeroLuck = 2 },
		Visual = { Particles = "Ember", Lighting = "BloodMoon" },
	},
	{
		Id = "Aurora", Name = "Aurora", Icon = "🌌", Color = Color3.fromRGB(110, 255, 200), Weight = 3,
		Desc = "Magic skies: Emerald mutations x3, mutation luck x3!",
		Buffs = { MutationLuck = 3, HeroLuck = 1.5 },
		Mutation = { Emerald = 3 },
		Visual = { Particles = "Aurora", Lighting = "Aurora" },
	},
	{
		Id = "Rainbow", Name = "Rainbow Storm", Icon = "🌈", Color = Color3.fromRGB(255, 120, 220), Weight = 1,
		Desc = "LEGENDARY WEATHER! Rainbow mutations x5 and everything boosted!",
		Buffs = { MutationLuck = 2, HeroLuck = 2, HeroDamage = 1.5, HeroSpeed = 1.25, SellBonus = 1.5 },
		Mutation = { Rainbow = 5 },
		Visual = { Particles = "Rainbow", Lighting = "Rainbow" },
	},
} :: { WeatherDef }

-- Lookups --------------------------------------------------------------------------------------------

local byId: { [string]: WeatherDef } = {}
for _, w in WeatherConfig.Weathers do
	byId[w.Id] = w
end

function WeatherConfig.Get(id: string?): WeatherDef?
	return if id then byId[id] else nil
end

-- Picks a weather by Weight, never `except`.
function WeatherConfig.Roll(rng: Random, except: string?): WeatherDef
	local total = 0
	for _, w in WeatherConfig.Weathers do
		if w.Id ~= except then
			total += w.Weight
		end
	end
	local pick = rng:NextNumber() * total
	for _, w in WeatherConfig.Weathers do
		if w.Id ~= except then
			pick -= w.Weight
			if pick <= 0 then
				return w
			end
		end
	end
	return WeatherConfig.Weathers[1]
end

-- Timing (Studio playtests use the short Studio numbers).
function WeatherConfig.Timing(): (number, number, number?)
	if RunService:IsStudio() then
		local s = WeatherConfig.Studio
		return s.Interval, s.Duration, s.FirstDelay
	end
	return WeatherConfig.Interval, WeatherConfig.Duration, nil
end

-- The weather going on right now, or nil.
function WeatherConfig.Current(): WeatherDef?
	local id = ReplicatedStorage:GetAttribute("Weather")
	local ends = ReplicatedStorage:GetAttribute("WeatherEnds")
	if typeof(id) ~= "string" or id == "" or typeof(ends) ~= "number" then
		return nil
	end
	if workspace:GetServerTimeNow() >= ends then
		return nil
	end
	return byId[id]
end

-- Multiplier for `stat` from the weather going on (1 without weather).
function WeatherConfig.Mult(stat: string): number
	local w = WeatherConfig.Current()
	return if w then w.Buffs[stat] or 1 else 1
end

-- Extra chance multipliers per hero mutation from the weather (nil without one).
function WeatherConfig.MutationBoost(): { [string]: number }?
	local w = WeatherConfig.Current()
	return w and w.Mutation
end

-- "Hero Damage x1.5" style lines for the UI.
function WeatherConfig.BuffLines(w: WeatherDef): { string }
	local lines = {}
	for _, stat in WeatherConfig.StatOrder do
		local m = w.Buffs[stat]
		if m then
			table.insert(lines, ("%s x%s"):format(WeatherConfig.Stats[stat] or stat, tostring(m)))
		end
	end
	for mutation, m in w.Mutation or {} do
		table.insert(lines, ("%s Mutation x%s"):format(mutation, tostring(m)))
	end
	return lines
end

return WeatherConfig
