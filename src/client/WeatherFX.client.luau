-- WeatherFX: what the weather (WeatherConfig / WeatherService) looks like, client-side only.
--
-- While a weather is on (ReplicatedStorage "Weather"):
--   light / colour   NOT here: LightingController tweens Lighting to the weather's LightingPresets entry.
--                    The ColorCorrection "WeatherTint" here stays neutral; only the lightning flash uses it.
--   particles        around the camera: Rain streaks, Snow flakes, Sand gusts, Gold sparkles, red
--                    Embers rising, Aurora ribbons in the sky, Rainbow arc + sparkles
--   lightning        Thunderstorm: bolts from the sky and a white flash every few seconds
-- Everything fades in / out over FADE seconds.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local WeatherConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeatherConfig"))

local FADE = 2.5
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"

local folder = workspace:FindFirstChild("WeatherFX") or Instance.new("Folder")
folder.Name = "WeatherFX"
folder.Parent = workspace

local function tween(inst: Instance, time: number, props: { [string]: any })
	local tw = TweenService:Create(inst, TweenInfo.new(time, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), props)
	tw:Play()
	return tw
end

local function part(props: { [string]: any }): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	for k, v in props do
		if k ~= "Parent" then
			(p :: any)[k] = v
		end
	end
	p.Parent = props.Parent or folder
	return p
end

-- Lighting --------------------------------------------------------------------------------------------

local tint = Lighting:FindFirstChild("WeatherTint") :: ColorCorrectionEffect?
if not tint then
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "WeatherTint"
	cc.Parent = Lighting
	tint = cc
end
local cc = tint :: ColorCorrectionEffect

-- The weather's colours / light are LightingController's job (LightingPresets). This effect stays
-- neutral and is only used for the lightning flash.
cc.Enabled = true
cc.TintColor = Color3.new(1, 1, 1)
cc.Brightness = 0
cc.Contrast = 0
cc.Saturation = 0

-- Particles ---------------------------------------------------------------------------------------------

-- A box around the camera that the particles come out of; follows the camera every frame.
type Layer = { box: BasePart, offset: Vector3, emitters: { ParticleEmitter }, rates: { number } }
local layers: { Layer } = {}
local extras: { Instance } = {} -- aurora ribbons, rainbow arc, ...
local extraUpdate: ((number) -> ())? = nil

local function layer(size: Vector3, offset: Vector3, emitters: { [string]: any }): Layer
	local box = part({ Name = "WeatherBox", Size = size })
	local l: Layer = { box = box, offset = offset, emitters = {}, rates = {} }
	for _, props in emitters do
		local e = Instance.new("ParticleEmitter")
		e.Rate = 0
		for k, v in props do
			(e :: any)[k] = v
		end
		e.Parent = box
		table.insert(l.emitters, e)
		table.insert(l.rates, props.Rate or 0)
	end
	table.insert(layers, l)
	return l
end

local function numbers(a: number, b: number?): NumberSequence
	return NumberSequence.new({ NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b or a) })
end

local BUILDERS: { [string]: () -> () } = {}

BUILDERS.Rain = function()
	-- Streaks: the sparkle texture stretched tall (Squash > 0 = taller), always upright on screen.
	layer(Vector3.new(90, 1, 90), Vector3.new(0, 35, 0), {
		{
			Texture = SPARKLE,
			Color = ColorSequence.new(Color3.fromRGB(170, 200, 255)),
			LightEmission = 0.4,
			Size = numbers(0.8),
			Squash = numbers(2.6),
			Transparency = numbers(0.1, 0.3),
			Orientation = Enum.ParticleOrientation.FacingCameraWorldUp,
			EmissionDirection = Enum.NormalId.Bottom,
			Speed = NumberRange.new(60, 75),
			Acceleration = Vector3.new(4, 0, 2),
			Lifetime = NumberRange.new(1, 1.2),
			Rate = 1400,
		},
	})
end

BUILDERS.Snow = function()
	layer(Vector3.new(140, 1, 140), Vector3.new(0, 35, 0), {
		{
			Texture = SPARKLE,
			Color = ColorSequence.new(Color3.new(1, 1, 1)),
			LightEmission = 0.6,
			Size = numbers(0.7, 0.45),
			Transparency = numbers(0.1, 0.6),
			EmissionDirection = Enum.NormalId.Bottom,
			Speed = NumberRange.new(5, 9),
			SpreadAngle = Vector2.new(25, 25),
			Acceleration = Vector3.new(1.5, 0, 0.8),
			Rotation = NumberRange.new(0, 360),
			RotSpeed = NumberRange.new(-60, 60),
			Lifetime = NumberRange.new(5, 7),
			Rate = 350,
		},
	})
end

-- Particles that float inside a volume around the camera (Shape = Box).
local function volume(props: { [string]: any }): { [string]: any }
	props.Shape = Enum.ParticleEmitterShape.Box
	props.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	return props
end

BUILDERS.Sand = function()
	layer(Vector3.new(120, 30, 120), Vector3.new(-30, 8, 0), {
		volume({
			Texture = SMOKE,
			Color = ColorSequence.new(Color3.fromRGB(225, 185, 120)),
			Size = numbers(5, 9),
			Transparency = numbers(0.75, 1),
			Speed = NumberRange.new(0, 2),
			Acceleration = Vector3.new(45, 0, 12),
			Lifetime = NumberRange.new(2, 3),
			Rate = 60,
		}),
		volume({
			Texture = SPARKLE,
			Color = ColorSequence.new(Color3.fromRGB(240, 205, 140)),
			Size = numbers(0.2),
			Transparency = numbers(0.2, 0.8),
			Speed = NumberRange.new(0, 1),
			Acceleration = Vector3.new(60, -2, 15),
			Lifetime = NumberRange.new(1.5, 2.5),
			Rate = 220,
		}),
	})
end

BUILDERS.Gold = function()
	layer(Vector3.new(90, 30, 90), Vector3.new(0, 10, 0), {
		volume({
			Texture = SPARKLE,
			Color = ColorSequence.new(Color3.fromRGB(255, 220, 90), Color3.fromRGB(255, 170, 40)),
			LightEmission = 1,
			Size = numbers(0.5, 0),
			Transparency = numbers(0, 1),
			Speed = NumberRange.new(0, 1),
			Acceleration = Vector3.new(0, -1.5, 0),
			Lifetime = NumberRange.new(2, 4),
			Rate = 120,
		}),
	})
end

BUILDERS.Ember = function()
	layer(Vector3.new(90, 6, 90), Vector3.new(0, -2, 0), {
		volume({
			Texture = SPARKLE,
			Color = ColorSequence.new(Color3.fromRGB(255, 80, 60), Color3.fromRGB(255, 160, 60)),
			LightEmission = 1,
			Size = numbers(0.7, 0),
			Transparency = numbers(0, 1),
			Speed = NumberRange.new(1, 3),
			Acceleration = Vector3.new(0.5, 4, 0),
			Lifetime = NumberRange.new(3, 5),
			Rate = 140,
		}),
	})
	-- A big red moon in the sky.
	local moon = part({ Name = "Moon", Shape = Enum.PartType.Ball, Size = Vector3.one * 40, Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 60, 50), Transparency = 1 })
	table.insert(extras, moon)
	tween(moon, FADE, { Transparency = 0.05 })
end

local AURORA_COLORS = { Color3.fromRGB(90, 255, 170), Color3.fromRGB(70, 220, 255), Color3.fromRGB(180, 110, 255), Color3.fromRGB(110, 255, 220) }

BUILDERS.Aurora = function()
	for i, color in AURORA_COLORS do
		local ribbon = part({ Name = "Aurora", Size = Vector3.new(260, 28, 1), Material = Enum.Material.Neon, Color = color, Transparency = 1 })
		ribbon:SetAttribute("Index", i)
		table.insert(extras, ribbon)
		tween(ribbon, FADE, { Transparency = 0.72 })
	end
	extraUpdate = function(t: number)
		local cam = workspace.CurrentCamera.CFrame.Position
		for _, r in extras do
			local i = r:GetAttribute("Index") :: number
			if not i then
				continue
			end
			local wave = math.sin(t * 0.4 + i) * 12
			r.CFrame = CFrame.new(cam.X + wave, cam.Y + 70 + i * 9, cam.Z - 150 + i * 14) * CFrame.Angles(math.rad(-25), math.rad(math.sin(t * 0.25 + i) * 12), math.rad(math.sin(t * 0.3 + i * 2) * 6))
		end
	end
	layer(Vector3.new(90, 30, 90), Vector3.new(0, 12, 0), {
		volume({
			Texture = SPARKLE,
			Color = ColorSequence.new(AURORA_COLORS[1], AURORA_COLORS[3]),
			LightEmission = 1,
			Size = numbers(0.4, 0),
			Transparency = numbers(0, 1),
			Speed = NumberRange.new(0, 1),
			Lifetime = NumberRange.new(2, 4),
			Rate = 90,
		}),
	})
end

local RAINBOW = {
	Color3.fromRGB(255, 70, 70), Color3.fromRGB(255, 150, 50), Color3.fromRGB(255, 230, 60), Color3.fromRGB(90, 230, 90),
	Color3.fromRGB(70, 170, 255), Color3.fromRGB(110, 90, 255), Color3.fromRGB(200, 90, 255),
}

BUILDERS.Rainbow = function()
	-- An arc of 7 bands, made of segments, far in front of where the camera was when it started.
	local cam = workspace.CurrentCamera.CFrame
	local look = Vector3.new(cam.LookVector.X, 0, cam.LookVector.Z)
	look = if look.Magnitude > 0.01 then look.Unit else Vector3.new(0, 0, -1)
	local center = cam.Position + look * 260 - Vector3.new(0, 20, 0)
	local basis = CFrame.lookAt(center, center + look)
	local segments = 28
	for band, color in RAINBOW do
		local radius = 150 - band * 6
		for s = 0, segments - 1 do
			local a0 = math.pi * s / segments
			local a1 = math.pi * (s + 1) / segments
			local p0 = basis:PointToWorldSpace(Vector3.new(math.cos(a0) * radius, math.sin(a0) * radius, 0))
			local p1 = basis:PointToWorldSpace(Vector3.new(math.cos(a1) * radius, math.sin(a1) * radius, 0))
			local seg = part({
				Name = "Rainbow",
				Size = Vector3.new(6, 1, (p1 - p0).Magnitude + 0.5),
				CFrame = CFrame.lookAt((p0 + p1) / 2, p1),
				Material = Enum.Material.Neon,
				Color = color,
			})
			table.insert(extras, seg)
			tween(seg, FADE, { Transparency = 0.35 })
		end
	end
	layer(Vector3.new(90, 30, 90), Vector3.new(0, 10, 0), {
		volume({
			Texture = SPARKLE,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, RAINBOW[1]),
				ColorSequenceKeypoint.new(0.33, RAINBOW[3]),
				ColorSequenceKeypoint.new(0.66, RAINBOW[5]),
				ColorSequenceKeypoint.new(1, RAINBOW[7]),
			}),
			LightEmission = 1,
			Size = numbers(0.5, 0),
			Transparency = numbers(0, 1),
			Speed = NumberRange.new(0, 2),
			Lifetime = NumberRange.new(2, 3.5),
			Rate = 160,
		}),
	})
end

-- Lightning ---------------------------------------------------------------------------------------------

local function lightningBolt()
	local cam = workspace.CurrentCamera.CFrame.Position
	local a = math.random() * math.pi * 2
	local distance = 40 + math.random() * 60
	local ground = Vector3.new(cam.X + math.cos(a) * distance, cam.Y - 10, cam.Z + math.sin(a) * distance)
	local top = ground + Vector3.new(math.random(-15, 15), 140, math.random(-15, 15))
	local points = { top }
	for i = 1, 7 do
		local p = top:Lerp(ground, i / 8) + Vector3.new(math.random(-8, 8), 0, math.random(-8, 8))
		table.insert(points, p)
	end
	table.insert(points, ground)
	local bolt = {}
	for i = 1, #points - 1 do
		local p0, p1 = points[i], points[i + 1]
		local seg = part({
			Name = "Bolt",
			Size = Vector3.new(0.8, 0.8, (p1 - p0).Magnitude),
			CFrame = CFrame.lookAt((p0 + p1) / 2, p1),
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(220, 215, 255),
			Transparency = 0,
		})
		table.insert(bolt, seg)
		tween(seg, 0.35, { Transparency = 1, Size = Vector3.new(0.1, 0.1, seg.Size.Z) })
	end
	-- Flash.
	local base = cc.Brightness
	cc.Brightness = base + 0.45
	tween(cc, 0.3, { Brightness = base })
	task.delay(0.4, function()
		for _, s in bolt do
			s:Destroy()
		end
	end)
end

-- On / off ------------------------------------------------------------------------------------------

local current: string? = nil
local started = 0
local lightningConn: thread? = nil

local function clearEffects()
	for _, l in layers do
		for _, e in l.emitters do
			e.Rate = 0
		end
		local box = l.box
		task.delay(8, function()
			box:Destroy()
		end)
	end
	table.clear(layers)
	for _, x in extras do
		if x:IsA("BasePart") then
			tween(x, FADE, { Transparency = 1 })
		end
		task.delay(FADE + 0.1, function()
			x:Destroy()
		end)
	end
	table.clear(extras)
	extraUpdate = nil
	if lightningConn then
		task.cancel(lightningConn)
		lightningConn = nil
	end
end

local function setWeather(def: WeatherConfig.WeatherDef?)
	local id = def and def.Id
	if id == current then
		return
	end
	current = id
	clearEffects()
	if not def then
		return
	end
	started = os.clock()
	local builder = def.Visual.Particles and BUILDERS[def.Visual.Particles]
	if builder then
		builder()
	end
	-- Fade the particles in.
	for _, l in layers do
		for i, e in l.emitters do
			local target = l.rates[i]
			task.spawn(function()
				local t0 = os.clock()
				while e.Parent and os.clock() - t0 < FADE do
					e.Rate = target * (os.clock() - t0) / FADE
					task.wait(0.1)
				end
				if e.Parent and current == id then
					e.Rate = target
				end
			end)
		end
	end
	if def.Visual.Lightning then
		lightningConn = task.spawn(function()
			while current == id do
				task.wait(3 + math.random() * 5)
				if current == id then
					lightningBolt()
				end
			end
		end)
	end
end

RunService.RenderStepped:Connect(function()
	local cam = workspace.CurrentCamera.CFrame.Position
	for _, l in layers do
		l.box.CFrame = CFrame.new(cam + l.offset)
	end
	for _, x in extras do
		if x.Name == "Moon" and x:IsA("BasePart") then
			-- Ahead of the camera, a bit to the left and well above the horizon.
			local look = workspace.CurrentCamera.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.new(0, 0, -1)
			local left = Vector3.new(flat.Z, 0, -flat.X)
			x.CFrame = CFrame.new(cam + flat * 280 + left * 70 + Vector3.new(0, 95, 0))
		end
	end
	if extraUpdate then
		extraUpdate(os.clock() - started)
	end
end)

local function refresh()
	setWeather(WeatherConfig.Current())
end
ReplicatedStorage:GetAttributeChangedSignal("Weather"):Connect(refresh)
ReplicatedStorage:GetAttributeChangedSignal("WeatherEnds"):Connect(refresh)
refresh()
-- Safety net: end the effects if the end time passes without an update.
task.spawn(function()
	while true do
		task.wait(1)
		refresh()
	end
end)
