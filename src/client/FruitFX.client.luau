-- FruitFX: Devil Fruit skill effects, all client-side (Remotes.FruitFX from HeroWorkerService):
--   (kind, pos, radius?, tree?, hero?)  kind = a FruitConfig Skill FX ("Flame", "Quake", ...) or
--   "<FX>Tick" for a burn tick.
--
-- Every skill has its own look so players can tell them apart:
--   Spring  pink double bounce rings + hearts of sparkles
--   Smoke   grey smoke clouds puffing around the hero
--   Ice     ice spikes burst out of the ground around the tree, then shatter
--   Flame   a pillar of fire on the tree; burning trees keep flames on them
--   Sand    a spinning sand tornado + a sand wave that puffs dust on every tree it reaches
--   Light   a beam of light from the sky onto the tree
--   Magma   red-hot ground cracks + lava chunks flying out + camera shake
--   Quake   white cracks racing over the ground, double shockwave, strong camera shake
-- On top of that the skill's NAME pops up over the hero ("TREMOR!") in the fruit's colours, bigger
-- and shakier for Legendary / Mythic fruits.
--
-- Heroes holding a fruit also get a soft aura in the fruit's colour (working heroes and the copy
-- standing on the pad), so you can see at a glance who has which fruit.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FruitConfig = require(Shared:WaitForChild("FruitConfig"))
local TreeConfig = require(Shared:WaitForChild("TreeConfig"))
local FruitFX = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("FruitFX") :: RemoteEvent

local player = Players.LocalPlayer

local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
local FIRE = "rbxasset://textures/particles/fire_main.dds"
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local FONT = Enum.Font.FredokaOne
local VIEW_DISTANCE = 160 -- skip effects this far from the camera
local TEXT_COOLDOWN = 0.7 -- seconds between two skill names on the same hero

local folder = workspace:FindFirstChild("ClientFX") or Instance.new("Folder")
folder.Name = "ClientFX"
folder.Parent = workspace

-- FX name -> fruit (for the skill name and colours).
local fruitByFX: { [string]: FruitConfig.FruitDef } = {}
for _, def in FruitConfig.Fruits do
	fruitByFX[def.Skill.FX] = def
end

-- Helpers ------------------------------------------------------------------------------------------

local function part(color: Color3, size: Vector3, cf: CFrame, props: { [string]: any }?): BasePart
	local p = Instance.new((props and props.ClassName) or "Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	p.CFrame = cf
	for k, v in props or {} do
		if k ~= "ClassName" then
			(p :: any)[k] = v
		end
	end
	p.Parent = folder
	return p
end

local function tween(inst: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
	local tw = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function later(seconds: number, inst: Instance)
	task.delay(seconds, function()
		if inst.Parent then
			inst:Destroy()
		end
	end)
end

-- A flat disc lying on the ground (cylinders point along X, so turn it up).
local function disc(color: Color3, ground: Vector3, diameter: number, props: { [string]: any }?): BasePart
	local p = part(color, Vector3.new(0.15, diameter, diameter), CFrame.new(ground + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.rad(90)), props)
	p.Shape = Enum.PartType.Cylinder
	return p
end

-- Expanding ring on the ground that fades out.
local function shockwave(color: Color3, ground: Vector3, radius: number, time: number, transparency: number?)
	local ring = disc(color, ground, 1)
	ring.Transparency = transparency or 0.2
	tween(ring, time, { Size = Vector3.new(0.15, radius * 2, radius * 2), Transparency = 1 })
	later(time + 0.05, ring)
end

local function burst(at: Vector3, texture: string, color: Color3, count: number, props: { [string]: any }?)
	local anchor = part(color, Vector3.one * 0.1, CFrame.new(at), { Transparency = 1 })
	local e = Instance.new("ParticleEmitter")
	e.Texture = texture
	e.Color = ColorSequence.new(color)
	e.LightEmission = 0.8
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1) })
	e.Lifetime = NumberRange.new(0.4, 0.9)
	e.Speed = NumberRange.new(6, 14)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Rate = 0
	for k, v in props or {} do
		(e :: any)[k] = v
	end
	e.Parent = anchor
	e:Emit(count)
	later(2, anchor)
end

local function flash(at: Vector3, color: Color3, size: number)
	local ball = part(color, Vector3.one * 0.4, CFrame.new(at), { Shape = Enum.PartType.Ball, Transparency = 0.05 })
	tween(ball, 0.28, { Size = Vector3.one * size, Transparency = 1 })
	later(0.3, ball)
end

local function exclude(tree: Instance?): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local list: { Instance } = { folder }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	if tree then
		table.insert(list, tree)
	end
	local plots = workspace:FindFirstChild("Plots")
	for _, plot in if plots then plots:GetChildren() else {} do
		local workers = plot:FindFirstChild("HeroWorkers")
		if workers then
			table.insert(list, workers)
		end
	end
	params.FilterDescendantsInstances = list
	return params
end

local function groundAt(pos: Vector3, tree: Instance?): Vector3
	local hit = workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -40, 0), exclude(tree))
	return if hit then hit.Position else pos - Vector3.new(0, 2, 0)
end

local function shake(strength: number, at: Vector3, time: number?)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end
	local distance = (hrp.Position - at).Magnitude
	if distance > 70 then
		return
	end
	strength *= 1 - distance / 70
	local duration = time or 0.4
	local camera = workspace.CurrentCamera
	local start = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - start
		if t > duration then
			conn:Disconnect()
			return
		end
		local k = strength * (1 - t / duration)
		camera.CFrame *= CFrame.new((math.random() - 0.5) * k * 0.8, (math.random() - 0.5) * k * 0.8, 0)
			* CFrame.Angles(0, 0, math.rad((math.random() - 0.5) * k * 3))
	end)
end

-- Trees of the same plot around `center` (Sand / Magma / Quake reach them).
local function treesAround(tree: Instance?, center: Vector3, radius: number): { Model }
	local list = {}
	local spawns = tree and tree.Parent
	if not spawns then
		return list
	end
	for _, other in spawns:GetChildren() do
		if other ~= tree and other:IsA("Model") and not other:GetAttribute("Dead") then
			local pos = other:GetPivot().Position
			if (Vector3.new(pos.X, center.Y, pos.Z) - center).Magnitude <= radius then
				table.insert(list, other)
			end
		end
	end
	return list
end

-- Skill name over the hero ------------------------------------------------------------------------------

local lastText: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any -- forgets removed heroes

local function skillText(hero: Model, def: FruitConfig.FruitDef)
	local now = os.clock()
	if lastText[hero] and now - lastText[hero] < TEXT_COOLDOWN then
		return
	end
	lastText[hero] = now
	local head = hero:FindFirstChild("Head") or hero.PrimaryPart or hero:FindFirstChild("HumanoidRootPart")
	if not head or not head:IsA("BasePart") then
		return
	end
	local big = def.Rarity == "Legendary" or def.Rarity == "Mythic"
	local rarityColor = TreeConfig.RarityColors[def.Rarity] or Color3.new(1, 1, 1)
	local gui = Instance.new("BillboardGui")
	gui.Name = "FruitSkillText"
	gui.Adornee = head
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 140
	gui.Size = if big then UDim2.fromScale(11, 3.2) else UDim2.fromScale(8, 2.4)
	gui.StudsOffset = Vector3.new(0, 3.2, 0)
	gui.Parent = folder

	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromScale(1, 1)
	holder.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Scale = 0.2
	scale.Parent = holder

	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Size = UDim2.fromScale(1, 0.68)
	name.Font = FONT
	name.TextScaled = true
	name.Text = def.Skill.Name:upper() .. "!"
	name.TextColor3 = Color3.new(1, 1, 1)
	name.Parent = holder
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = if big then 4 else 3
	stroke.Color = def.Swirl:Lerp(Color3.new(0, 0, 0), 0.6)
	stroke.Parent = name
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(Color3.new(1, 1, 1), def.Color:Lerp(Color3.new(1, 1, 1), 0.15))
	gradient.Rotation = 90
	gradient.Parent = name

	local sub = Instance.new("TextLabel")
	sub.BackgroundTransparency = 1
	sub.Position = UDim2.fromScale(0, 0.66)
	sub.Size = UDim2.fromScale(1, 0.32)
	sub.Font = FONT
	sub.TextScaled = true
	sub.Text = def.Name
	sub.TextColor3 = rarityColor
	sub.Parent = holder
	local subStroke = Instance.new("UIStroke")
	subStroke.Thickness = 2
	subStroke.Color = Color3.fromRGB(20, 20, 24)
	subStroke.Parent = sub

	-- Pop in, float up, fade out.
	tween(scale, 0.22, { Scale = if big then 1.15 else 1 }, Enum.EasingStyle.Back)
	tween(gui, 1.3, { StudsOffset = Vector3.new(0, 5, 0) }, Enum.EasingStyle.Sine)
	if big then
		-- Legendary / Mythic: the name shakes a little.
		local start = os.clock()
		local conn: RBXScriptConnection
		conn = RunService.RenderStepped:Connect(function()
			local t = os.clock() - start
			if t > 0.5 or not holder.Parent then
				conn:Disconnect()
				holder.Rotation = 0
				return
			end
			holder.Rotation = math.sin(t * 60) * 6 * (1 - t / 0.5)
		end)
	end
	task.delay(0.9, function()
		tween(name, 0.4, { TextTransparency = 1 })
		tween(stroke, 0.4, { Transparency = 1 })
		tween(sub, 0.4, { TextTransparency = 1 })
		tween(subStroke, 0.4, { Transparency = 1 })
	end)
	later(1.4, gui)
end

-- The effects ---------------------------------------------------------------------------------------

type Ctx = { pos: Vector3, ground: Vector3, radius: number?, tree: Model?, hero: Model?, def: FruitConfig.FruitDef }

local EFFECTS: { [string]: (Ctx) -> () } = {}

EFFECTS.Spring = function(c)
	local pink = Color3.fromRGB(255, 120, 190)
	flash(c.pos, pink, 3)
	shockwave(pink, c.ground, 4, 0.3)
	task.delay(0.16, function()
		shockwave(Color3.fromRGB(255, 190, 225), c.ground, 6, 0.35)
	end)
	burst(c.pos, SPARKLE, pink, 20, { Speed = NumberRange.new(8, 16) })
end

EFFECTS.Smoke = function(c)
	local grey = Color3.fromRGB(215, 218, 228)
	local at = if c.hero and c.hero.PrimaryPart then c.hero.PrimaryPart.Position else c.pos
	for i = 1, 6 do
		local a = i / 6 * math.pi * 2
		local cloud = part(grey, Vector3.one * 1.5, CFrame.new(at + Vector3.new(math.cos(a) * 1.5, -0.5 + (i % 2) * 0.8, math.sin(a) * 1.5)), {
			Shape = Enum.PartType.Ball,
			Material = Enum.Material.SmoothPlastic,
			Transparency = 0.25,
		})
		tween(cloud, 0.7, { Size = Vector3.one * 4, Transparency = 1, Position = cloud.Position + Vector3.new(math.cos(a) * 2, 1.5, math.sin(a) * 2) })
		later(0.75, cloud)
	end
	burst(at, SMOKE, grey, 16, { LightEmission = 0, Speed = NumberRange.new(3, 7), Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 0) }) })
end

EFFECTS.Ice = function(c)
	local ice = Color3.fromRGB(150, 225, 255)
	local center = if c.tree then c.tree:GetPivot().Position else c.pos
	local ground = Vector3.new(center.X, c.ground.Y, center.Z)
	flash(c.pos, Color3.new(1, 1, 1), 3.5)
	shockwave(Color3.fromRGB(220, 245, 255), ground, 5, 0.4, 0.1)
	for i = 1, 8 do
		local a = i / 8 * math.pi * 2 + math.random() * 0.3
		local height = 2.5 + math.random() * 2
		local base = ground + Vector3.new(math.cos(a) * 2.6, 0, math.sin(a) * 2.6)
		local tilt = CFrame.lookAt(base, base + Vector3.new(math.cos(a), 2.4, math.sin(a)))
		local spike = part(ice, Vector3.new(0.7, 0.7, 0.1), tilt * CFrame.new(0, 0, -0.05), {
			Material = Enum.Material.Glass,
			Transparency = 0.15,
			Reflectance = 0.2,
		})
		-- Grow out along its look direction.
		tween(spike, 0.12, { Size = Vector3.new(0.7, 0.7, height), CFrame = tilt * CFrame.new(0, 0, -height / 2) }, Enum.EasingStyle.Back)
		task.delay(0.55, function()
			tween(spike, 0.25, { Size = Vector3.new(0.1, 0.1, height * 0.6), Transparency = 1 })
			burst(spike.Position, SPARKLE, ice, 3, { Speed = NumberRange.new(4, 8) })
		end)
		later(0.85, spike)
	end
	burst(c.pos, SPARKLE, Color3.new(1, 1, 1), 14)
end

local function treeFire(tree: Model, time: number, size: number)
	local base = tree:GetPivot().Position
	local anchor = part(Color3.new(1, 0.5, 0), Vector3.one * 0.1, CFrame.new(base + Vector3.new(0, 1.5, 0)), { Transparency = 1 })
	local fire = Instance.new("Fire")
	fire.Size = size
	fire.Heat = 12
	fire.Color = Color3.fromRGB(255, 130, 30)
	fire.SecondaryColor = Color3.fromRGB(255, 220, 80)
	fire.Parent = anchor
	task.delay(time, function()
		fire.Enabled = false
	end)
	later(time + 1, anchor)
end

EFFECTS.Flame = function(c)
	local orange = Color3.fromRGB(255, 120, 30)
	local center = if c.tree then c.tree:GetPivot().Position else c.pos
	local ground = Vector3.new(center.X, c.ground.Y, center.Z)
	flash(c.pos, Color3.fromRGB(255, 200, 60), 3)
	local pillar = part(orange, Vector3.new(1, 3, 3), CFrame.new(ground + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, 0, math.rad(90)), { Shape = Enum.PartType.Cylinder, Transparency = 0.2 })
	tween(pillar, 0.35, { Size = Vector3.new(9, 4, 4), CFrame = CFrame.new(ground + Vector3.new(0, 4.5, 0)) * CFrame.Angles(0, 0, math.rad(90)), Transparency = 0.6 })
	task.delay(0.35, function()
		tween(pillar, 0.3, { Size = Vector3.new(10, 0.5, 0.5), Transparency = 1 })
	end)
	later(0.7, pillar)
	shockwave(orange, ground, 3.5, 0.3)
	burst(ground + Vector3.new(0, 1, 0), FIRE, orange, 26, { Speed = NumberRange.new(4, 10), Acceleration = Vector3.new(0, 12, 0) })
	if c.tree then
		treeFire(c.tree, 1.5, 6)
	end
end

EFFECTS.Sand = function(c)
	local sand = Color3.fromRGB(230, 195, 120)
	local center = if c.tree then c.tree:GetPivot().Position else c.pos
	local ground = Vector3.new(center.X, c.ground.Y, center.Z)
	-- Tornado: stacked rings spinning and widening as they go up.
	local rings: { BasePart } = {}
	for i = 0, 5 do
		local r = part(sand, Vector3.new(0.4, 2 + i * 0.9, 2 + i * 0.9), CFrame.new(ground + Vector3.new(0, 0.6 + i * 1.2, 0)) * CFrame.Angles(0, 0, math.rad(90)), {
			Shape = Enum.PartType.Cylinder,
			Material = Enum.Material.Sand,
			Transparency = 0.35 + i * 0.06,
		})
		table.insert(rings, r)
	end
	local start = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - start
		if t > 1 then
			conn:Disconnect()
			for _, r in rings do
				r:Destroy()
			end
			return
		end
		for i, r in rings do
			local k = i - 1
			local wobble = Vector3.new(math.cos(t * 9 + k) * 0.4, 0, math.sin(t * 9 + k) * 0.4)
			r.CFrame = CFrame.new(ground + wobble + Vector3.new(0, 0.6 + k * 1.2 + t * 1.5, 0)) * CFrame.Angles(0, t * 14 + k, math.rad(90))
			r.Transparency = math.min(1, 0.35 + k * 0.06 + t * 0.65)
		end
	end)
	shockwave(sand, ground, c.radius or 8, 0.6, 0.35)
	burst(ground + Vector3.new(0, 1, 0), SMOKE, sand, 20, { LightEmission = 0, Speed = NumberRange.new(5, 12) })
	-- Dust on every tree the sand reaches.
	for _, other in treesAround(c.tree, ground, c.radius or 0) do
		local pos = other:GetPivot().Position
		task.delay(0.15, function()
			burst(pos + Vector3.new(0, 2, 0), SMOKE, sand, 8, { LightEmission = 0, Speed = NumberRange.new(2, 5) })
		end)
	end
end

EFFECTS.Light = function(c)
	local gold = Color3.fromRGB(255, 245, 150)
	local center = if c.tree then c.tree:GetPivot().Position else c.pos
	local ground = Vector3.new(center.X, c.ground.Y, center.Z)
	local height = 40
	local beam = part(gold, Vector3.new(height, 0.3, 0.3), CFrame.new(ground + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.rad(90)), { Shape = Enum.PartType.Cylinder, Transparency = 0.1 })
	tween(beam, 0.12, { Size = Vector3.new(height, 3, 3) })
	task.delay(0.15, function()
		tween(beam, 0.35, { Size = Vector3.new(height, 0.1, 0.1), Transparency = 1 })
	end)
	later(0.55, beam)
	local core = part(Color3.new(1, 1, 1), Vector3.new(height, 0.2, 0.2), beam.CFrame, { Shape = Enum.PartType.Cylinder })
	tween(core, 0.4, { Size = Vector3.new(height, 0.05, 0.05), Transparency = 1 })
	later(0.45, core)
	flash(ground + Vector3.new(0, 1, 0), gold, 5)
	shockwave(gold, ground, 6, 0.35, 0.1)
	burst(ground + Vector3.new(0, 1.5, 0), SPARKLE, gold, 30, { Speed = NumberRange.new(10, 20) })
	-- The hero leaves a quick afterimage flash.
	if c.hero and c.hero.PrimaryPart then
		flash(c.hero.PrimaryPart.Position, gold, 3)
	end
end

local function cracks(color: Color3, ground: Vector3, radius: number, count: number, time: number, width: number)
	for i = 1, count do
		local a = i / count * math.pi * 2 + math.random() * 0.4
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local length = radius * (0.6 + math.random() * 0.4)
		local base = ground + Vector3.new(0, 0.1, 0)
		local crack = part(color, Vector3.new(width, 0.12, 0.1), CFrame.lookAt(base, base + dir))
		tween(crack, time, { Size = Vector3.new(width, 0.12, length), CFrame = CFrame.lookAt(base, base + dir) * CFrame.new(0, 0, -length / 2) }, Enum.EasingStyle.Quart)
		task.delay(time + 0.35, function()
			tween(crack, 0.4, { Transparency = 1 })
		end)
		later(time + 0.8, crack)
	end
end

EFFECTS.Magma = function(c)
	local lava = Color3.fromRGB(255, 90, 20)
	local center = if c.tree then c.tree:GetPivot().Position else c.pos
	local ground = Vector3.new(center.X, c.ground.Y, center.Z)
	local radius = c.radius or 10
	flash(c.pos, Color3.fromRGB(255, 180, 60), 6)
	-- Glowing ground under the blast + cracks.
	local pool = disc(Color3.fromRGB(200, 40, 10), ground, 2)
	pool.Transparency = 0.15
	tween(pool, 0.35, { Size = Vector3.new(0.15, radius * 1.1, radius * 1.1) })
	task.delay(0.6, function()
		tween(pool, 0.5, { Transparency = 1 })
	end)
	later(1.15, pool)
	cracks(lava, ground, radius, 9, 0.3, 0.5)
	shockwave(lava, ground, radius, 0.5, 0.2)
	-- Lava chunks fly out and fall.
	for _ = 1, 10 do
		local chunk = part(lava, Vector3.one * (0.6 + math.random() * 0.6), CFrame.new(ground + Vector3.new(0, 1, 0)), {
			Anchored = false,
			Material = Enum.Material.Neon,
		})
		local a = math.random() * math.pi * 2
		chunk.AssemblyLinearVelocity = Vector3.new(math.cos(a) * (8 + math.random() * 10), 22 + math.random() * 12, math.sin(a) * (8 + math.random() * 10))
		chunk.AssemblyAngularVelocity = Vector3.new(math.random() * 10, math.random() * 10, math.random() * 10)
		later(1.3, chunk)
	end
	burst(ground + Vector3.new(0, 1, 0), FIRE, lava, 40, { Speed = NumberRange.new(10, 22), Acceleration = Vector3.new(0, 8, 0) })
	if c.tree then
		treeFire(c.tree, 1, 8)
	end
	shake(1, ground, 0.45)
end

EFFECTS.Quake = function(c)
	local white = Color3.fromRGB(240, 240, 255)
	local purple = Color3.fromRGB(150, 110, 255)
	local center = if c.tree then c.tree:GetPivot().Position else c.pos
	local ground = Vector3.new(center.X, c.ground.Y, center.Z)
	local radius = c.radius or 12
	-- A "glass ball" crack at the impact.
	local orb = part(white, Vector3.one * 1, CFrame.new(c.pos), { Shape = Enum.PartType.Ball, Material = Enum.Material.Glass, Transparency = 0.3 })
	tween(orb, 0.18, { Size = Vector3.one * 5 }, Enum.EasingStyle.Back)
	task.delay(0.2, function()
		tween(orb, 0.2, { Size = Vector3.one * 7, Transparency = 1 })
	end)
	later(0.45, orb)
	cracks(white, ground, radius, 12, 0.25, 0.35)
	shockwave(white, ground, radius, 0.45, 0.05)
	task.delay(0.15, function()
		shockwave(purple, ground, radius * 1.1, 0.55, 0.3)
	end)
	burst(c.pos, SPARKLE, white, 30, { Speed = NumberRange.new(14, 26) })
	for _, other in treesAround(c.tree, ground, radius) do
		local pos = other:GetPivot().Position
		task.delay(0.2, function()
			flash(pos + Vector3.new(0, 2, 0), white, 3)
		end)
	end
	shake(1.6, ground, 0.6)
end

-- Burn ticks: a few flames on the burning tree.
local function tick(kind: string, c: Ctx)
	if kind == "Flame" and c.tree then
		treeFire(c.tree, 0.9, 4)
		burst(c.pos, FIRE, Color3.fromRGB(255, 130, 30), 6, { Acceleration = Vector3.new(0, 10, 0), Speed = NumberRange.new(2, 5) })
	end
end

FruitFX.OnClientEvent:Connect(function(kind: string, pos: Vector3, radius: number?, tree: Instance?, hero: Instance?)
	if typeof(kind) ~= "string" or typeof(pos) ~= "Vector3" then
		return
	end
	if (workspace.CurrentCamera.CFrame.Position - pos).Magnitude > VIEW_DISTANCE then
		return
	end
	local isTick = kind:sub(-4) == "Tick"
	local base = if isTick then kind:sub(1, -5) else kind
	local def = fruitByFX[base]
	if not def then
		return
	end
	local treeModel = if typeof(tree) == "Instance" and tree:IsA("Model") then tree else nil
	local heroModel = if typeof(hero) == "Instance" and hero:IsA("Model") then hero else nil
	local c: Ctx = { pos = pos, ground = groundAt(pos, treeModel), radius = radius, tree = treeModel, hero = heroModel, def = def }
	if isTick then
		tick(base, c)
		return
	end
	local effect = EFFECTS[base]
	if effect then
		task.spawn(effect, c)
	end
	if heroModel then
		skillText(heroModel, def)
	end
end)

-- Fruit aura on heroes ------------------------------------------------------------------------------------

local AURA = "FruitAura"

local function setAura(model: Model, def: FruitConfig.FruitDef?)
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if not root or not root:IsA("BasePart") then
		return
	end
	local current = root:FindFirstChild(AURA)
	if not def then
		if current then
			current:Destroy()
		end
		return
	end
	if current and current:GetAttribute("Fruit") == def.Id then
		return
	end
	if current then
		current:Destroy()
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = AURA
	attachment:SetAttribute("Fruit", def.Id)
	local e = Instance.new("ParticleEmitter")
	e.Texture = SPARKLE
	e.Color = ColorSequence.new(def.Color, def.Swirl)
	e.LightEmission = 0.7
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	e.Lifetime = NumberRange.new(0.6, 1)
	e.Speed = NumberRange.new(0.5, 1.5)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Acceleration = Vector3.new(0, 2, 0)
	-- Rarer fruits shine more.
	local rank = TreeConfig.RarityOrder[def.Rarity] or 6
	e.Rate = 4 + (6 - rank) * 3
	e.Parent = attachment
	if rank <= 3 then
		local light = Instance.new("PointLight")
		light.Color = def.Color
		light.Range = 6
		light.Brightness = 0.8
		light.Parent = attachment
	end
	attachment.Parent = root
end

local function fruitOfSlot(slot: Instance?): FruitConfig.FruitDef?
	local id = slot and slot:GetAttribute("HeroFruit")
	return if typeof(id) == "string" and id ~= "" then FruitConfig.Get(id) else nil
end

task.spawn(function()
	while true do
		local plots = workspace:FindFirstChild("Plots")
		for _, plot in if plots then plots:GetChildren() else {} do
			local slots = plot:FindFirstChild("HeroSlots")
			if not slots then
				continue
			end
			-- Heroes out chopping.
			local workers = plot:FindFirstChild("HeroWorkers")
			for _, w in if workers then workers:GetChildren() else {} do
				local index = w:GetAttribute("Slot")
				if w:IsA("Model") and typeof(index) == "number" then
					setAura(w, fruitOfSlot(slots:FindFirstChild("Slot" .. index)))
				end
			end
			-- The copy standing on each pad.
			for _, slot in slots:GetChildren() do
				local padHero = slot:FindFirstChild("PadHero")
				if padHero and padHero:IsA("Model") then
					setAura(padHero, fruitOfSlot(slot))
				end
			end
		end
		task.wait(1)
	end
end)
