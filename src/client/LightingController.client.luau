--!strict
-- LightingController: owns the world's look on the client and tweens it between LightingPresets.
--
-- Which preset:
--   1. ReplicatedStorage attribute "LightingPreset" (string), if set (events / testing)
--   2. the current weather's Visual.Lighting (WeatherConfig), or the weather's Id
--   3. "Clear" (no weather). Only here the zone's lighting attributes count (ZoneService puts them on
--      Lighting as ZoneClockTime, ZoneAmbient, ZoneOutdoorAmbient, ZoneAtmosphereColor/Decay/Density/Haze).
--
-- Everything is tweened over LightingPresets.TweenTime. Sky settings that can't be tweened (stars,
-- textures, ...) switch halfway, while the change is least noticeable.
-- Weather particles / lightning stay in WeatherFX; this script only does light and colour.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeatherConfig = require(Shared:WaitForChild("WeatherConfig"))
local LightingPresets = require(Shared:WaitForChild("LightingPresets"))

-- Effects ------------------------------------------------------------------------------------------------

local function get(className: string, name: string): any
	local inst = Lighting:FindFirstChild(name)
	if inst and inst.ClassName == className then
		return inst
	end
	local created = Instance.new(className :: any)
	created.Name = name
	created.Parent = Lighting
	return created
end

local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") or get("Atmosphere", "Atmosphere")
local grade = get("ColorCorrectionEffect", "WeatherGrade")
local bloom = get("BloomEffect", "Bloom")
local sunRays = get("SunRaysEffect", "SunRays")
local dof = get("DepthOfFieldEffect", "DepthOfField")
bloom.Enabled = true
sunRays.Enabled = true
grade.Enabled = true

-- One Sky only: the one marked MainSky (else the last one, which is what Roblox draws). Others are
-- taken out on this client so the look never depends on which one Roblox picks.
local function pickSky(): Sky
	local skies = {}
	for _, c in Lighting:GetChildren() do
		if c:IsA("Sky") then
			table.insert(skies, c)
		end
	end
	local main: Sky? = nil
	for _, s in skies do
		if s:GetAttribute("MainSky") then
			main = s
		end
	end
	main = main or skies[#skies]
	if not main then
		local s = Instance.new("Sky")
		s.Parent = Lighting
		return s
	end
	for _, s in skies do
		if s ~= main then
			s.Parent = nil
		end
	end
	return main
end
local sky = pickSky()

-- Zone overrides (Clear only) -------------------------------------------------------------------------------

local ZONE_ATTRS = {
	ZoneClockTime = { "Lighting", "ClockTime" },
	ZoneAmbient = { "Lighting", "Ambient" },
	ZoneOutdoorAmbient = { "Lighting", "OutdoorAmbient" },
	ZoneAtmosphereColor = { "Atmosphere", "Color" },
	ZoneAtmosphereDecay = { "Atmosphere", "Decay" },
	ZoneAtmosphereDensity = { "Atmosphere", "Density" },
	ZoneAtmosphereHaze = { "Atmosphere", "Haze" },
}

local function zoneSignature(): string
	local parts = {}
	for attr in ZONE_ATTRS do
		table.insert(parts, attr .. "=" .. tostring(Lighting:GetAttribute(attr)))
	end
	table.sort(parts)
	return table.concat(parts, ";")
end

-- Applying -----------------------------------------------------------------------------------------------------

local TARGETS: { [string]: Instance } = {
	Lighting = Lighting,
	Atmosphere = atmosphere,
	Grade = grade,
	Bloom = bloom,
	SunRays = sunRays,
	DepthOfField = dof,
}

local tweens: { Tween } = {}
local token = 0

local function presetName(): string
	local forced = ReplicatedStorage:GetAttribute("LightingPreset")
	if typeof(forced) == "string" and forced ~= "" and LightingPresets.Presets[forced] then
		return forced
	end
	local w = WeatherConfig.Current()
	if w then
		local name = w.Visual.Lighting or w.Id
		return if LightingPresets.Presets[name] then name else "Clear"
	end
	return "Clear"
end

local function apply(name: string, time: number)
	token += 1
	local mine = token
	for _, tw in tweens do
		tw:Cancel()
	end
	table.clear(tweens)

	local p = LightingPresets.Resolve(name)
	if name == "Clear" then
		for attr, where in ZONE_ATTRS do
			local v = Lighting:GetAttribute(attr)
			if v ~= nil then
				p[where[1]][where[2]] = v
			end
		end
	end

	local d = p.DepthOfField
	local wantDof = (d.FarIntensity or 0) > 0 or (d.NearIntensity or 0) > 0
	if wantDof then
		dof.Enabled = true
	end

	local info = TweenInfo.new(time, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	for group, inst in TARGETS do
		local goals = p[group]
		if time <= 0 then
			for k, v in goals do
				(inst :: any)[k] = v
			end
		else
			local tw = TweenService:Create(inst, info, goals)
			tw:Play()
			table.insert(tweens, tw)
		end
	end

	-- Sky (not tweenable) and turning DOF off: halfway through.
	local function finishSwitch()
		if token ~= mine then
			return
		end
		for k, v in p.Sky do
			(sky :: any)[k] = v
		end
		if not wantDof then
			dof.Enabled = false
		end
	end
	if time <= 0 then
		finishSwitch()
	else
		task.delay(time / 2, finishSwitch)
	end
end

-- Watching ---------------------------------------------------------------------------------------------

local current = ""
local currentZone = ""

local function refresh(instant: boolean?)
	local name = presetName()
	local zone = if name == "Clear" then zoneSignature() else ""
	if name == current and zone == currentZone then
		return
	end
	current = name
	currentZone = zone
	apply(name, if instant then 0 else LightingPresets.TweenTime)
end

for _, attr in { "Weather", "WeatherEnds", "LightingPreset" } do
	ReplicatedStorage:GetAttributeChangedSignal(attr):Connect(function()
		refresh()
	end)
end
for attr in ZONE_ATTRS do
	Lighting:GetAttributeChangedSignal(attr):Connect(function()
		refresh()
	end)
end

refresh(true)

-- A weather ends on time even if no attribute changes.
while true do
	task.wait(1)
	refresh()
end
