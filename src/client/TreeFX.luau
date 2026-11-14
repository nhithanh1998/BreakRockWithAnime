-- TreeFX: client-only effects for trees: hit flash, shake, falling leaves, wood chips,
-- floating damage numbers and the fall-over animation when a tree dies.
-- Everything here is local; the server never sees these changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))

local TreeFX = {}

local rng = Random.new()

local fxFolder = Instance.new("Folder")
fxFolder.Name = "ClientFX"
fxFolder.Parent = workspace
TreeFX.Folder = fxFolder

-- Helpers --------------------------------------------------------------------------------------

local function partsOf(tree: Model): { BasePart }
	local list = {}
	for _, d in tree:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(list, d)
		end
	end
	return list
end

local function leafPartsOf(tree: Model): { BasePart }
	local list = {}
	for _, d in tree:GetDescendants() do
		if d:IsA("BasePart") and TreeConfig.LeafPartNames[d.Name] then
			table.insert(list, d)
		end
	end
	return list
end

local function randomPointOn(part: BasePart): Vector3
	local s = part.Size / 2
	return (part.CFrame * CFrame.new(rng:NextNumber(-s.X, s.X), -s.Y, rng:NextNumber(-s.Z, s.Z))).Position
end

-- Tree motion (shake + fall) -------------------------------------------------------------------
-- Tree models have two parts: "Tree" (trunk + leaves) and "Ground" (the dirt mound). Only the
-- Tree part moves; the mound stays put. Models without a "Tree" child (e.g. the chest) move whole.
-- Shakes rotate around the spot where the trunk leaves the mound; the fall hinges on the trunk's
-- front edge. Every motion starts from the pose the part had before any effect touched it, so
-- repeated hits never make the tree drift.

type Motion = {
	tree: Model,
	body: Model, -- the part that moves
	base: CFrame, -- body pivot before any effect
	hinge: Vector3,
	axis: Vector3,
	kind: "shake" | "fall",
	start: number,
	angle: number, -- shake amplitude, radians
	duration: number, -- shake length, seconds
	-- fall only
	dir: Vector3?,
	length: number?, -- hinge to treetop
	floorY: number?,
	impacted: boolean?,
	bodyParts: { BasePart }?,
	groundParts: { BasePart }?,
}

local motions: { [Model]: Motion } = {}
local onImpact: (m: Motion) -> () -- defined with the particles below

local function bodyOf(model: Model): Model
	local body = model:FindFirstChild("Tree")
	return if body and body:IsA("Model") then body else model
end

local function groundOf(model: Model): Model?
	local ground = model:FindFirstChild("Ground")
	return if ground and ground:IsA("Model") then ground else nil
end

local function trunkOf(model: Model, body: Model): BasePart?
	local trunk = model.PrimaryPart
	if trunk and trunk:IsDescendantOf(body) then
		return trunk
	end
	local found = body:FindFirstChild("Trunk", true)
	return if found and found:IsA("BasePart") then found else nil
end

-- Where the trunk comes out of the ground: trunk center (X/Z) at the top of the mound,
-- or at the bottom of the model when it has no mound.
local function basePoint(model: Model, body: Model): Vector3
	local cf, size = body:GetBoundingBox()
	local trunk = trunkOf(model, body)
	local center = if trunk then trunk.Position else cf.Position
	local y = cf.Position.Y - size.Y / 2
	local ground = groundOf(model)
	if ground then
		local gcf, gsize = ground:GetBoundingBox()
		y = math.max(y, gcf.Position.Y + gsize.Y / 2)
	end
	return Vector3.new(center.X, y, center.Z)
end

local function getMotion(model: Model): Motion
	local m = motions[model]
	if m then
		return m
	end
	local body = bodyOf(model)
	local newMotion: Motion = {
		tree = model,
		body = body,
		base = body:GetPivot(),
		hinge = basePoint(model, body),
		axis = Vector3.xAxis,
		kind = "shake",
		start = os.clock(),
		angle = math.rad(TreeConfig.ShakeAngle),
		duration = TreeConfig.ShakeTime,
	}
	motions[model] = newMotion
	return newMotion
end

-- Flat direction the treetop tips towards: away from `fromPos`, random without one.
local function tipDirection(m: Motion, fromPos: Vector3?): Vector3
	local dir = if fromPos then m.hinge - fromPos else Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
	dir = Vector3.new(dir.X, 0, dir.Z)
	return if dir.Magnitude > 1e-3 then dir.Unit else Vector3.zAxis
end

-- Rotating around up x dir tips the top along dir.
local function axisFor(dir: Vector3): Vector3
	return Vector3.yAxis:Cross(dir).Unit
end

local function applyTilt(m: Motion, angle: number, drop: number?)
	local pivot = CFrame.new(m.hinge)
	local cf = pivot * CFrame.fromAxisAngle(m.axis, angle) * pivot:Inverse() * m.base
	if drop and drop > 0 then
		cf -= Vector3.new(0, drop, 0)
	end
	m.body:PivotTo(cf)
end

local function setFade(parts: { BasePart }?, alpha: number)
	if parts then
		for _, p in parts do
			p.LocalTransparencyModifier = alpha
		end
	end
end

local CREAK_TIME = 0.12 -- the tree leans back a hair before it goes
local CREAK_ANGLE = math.rad(3)
local FALL_ANGLE = math.rad(86)
local SINK_DEPTH = 1.5 -- studs the fallen trunk sinks while fading

-- Creak back, accelerate down (like gravity), bounce on impact, rest, then sink + fade.
-- The mound fades last, just before the server removes the model (TreeConfig.FellTime).
local function updateFall(m: Motion, e: number)
	local total = TreeConfig.FellTime
	local fallDur = TreeConfig.FallDuration
	local landAt = CREAK_TIME + fallDur
	local a: number
	if e < CREAK_TIME then
		a = -CREAK_ANGLE * math.sin(e / CREAK_TIME * math.pi / 2)
	elseif e < landAt then
		local t = (e - CREAK_TIME) / fallDur
		a = -CREAK_ANGLE + (FALL_ANGLE + CREAK_ANGLE) * t * t
	else
		if not m.impacted then
			m.impacted = true
			onImpact(m)
		end
		local b = e - landAt
		a = FALL_ANGLE - math.rad(7) * math.exp(-b * 7) * math.abs(math.sin(b * 16))
	end
	local sinkStart = landAt + 0.45
	local sinkK = math.clamp((e - sinkStart) / math.max(total - sinkStart - 0.15, 0.1), 0, 1)
	applyTilt(m, a, sinkK * SINK_DEPTH)
	setFade(m.bodyParts, sinkK)
	setFade(m.groundParts, math.clamp((e - (total - 0.45)) / 0.35, 0, 1))
end

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	for model, m in motions do
		if not model.Parent then
			motions[model] = nil
			continue
		end
		local e = now - m.start
		if m.kind == "shake" then
			if e >= m.duration then
				m.body:PivotTo(m.base)
				motions[model] = nil
			else
				applyTilt(m, m.angle * (1 - e / m.duration) * math.sin(e * 55))
			end
		else
			updateFall(m, e)
		end
	end
end)

-- Works on any Model (trees, the chest, ...). angleDeg / duration default to the tree values.
function TreeFX.Shake(model: Model, fromPos: Vector3?, angleDeg: number?, duration: number?)
	local m = getMotion(model)
	if m.kind == "fall" then
		return
	end
	m.axis = axisFor(tipDirection(m, fromPos))
	m.angle = math.rad(angleDeg or TreeConfig.ShakeAngle)
	m.duration = duration or TreeConfig.ShakeTime
	m.start = os.clock()
end

-- Hit flash ------------------------------------------------------------------------------------

local flashes: { [Model]: Highlight } = {}
local flashInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

function TreeFX.Flash(tree: Model, color: Color3?)
	local h = flashes[tree]
	if not h or not h.Parent then
		local newH = Instance.new("Highlight")
		newH.Name = "HitFlash"
		newH.DepthMode = Enum.HighlightDepthMode.Occluded
		newH.Adornee = bodyOf(tree) -- the mound doesn't flash
		newH.Parent = tree
		flashes[tree] = newH
		tree.Destroying:Once(function()
			flashes[tree] = nil
		end)
		h = newH
	end
	local hl = h :: Highlight
	hl.FillColor = color or TreeConfig.HitFlashColor
	hl.OutlineColor = color or TreeConfig.HitFlashColor
	hl.FillTransparency = 0.25
	hl.OutlineTransparency = 0
	TweenService:Create(hl, flashInfo, { FillTransparency = 1, OutlineTransparency = 1 }):Play()
end

-- Particles (leaves + chips) -------------------------------------------------------------------

type Particle = {
	part: BasePart,
	pos: Vector3,
	vel: Vector3,
	gravity: number,
	drag: number,
	sway: number,
	phase: number,
	spin: Vector3,
	rot: CFrame,
	groundY: number,
	age: number,
	life: number,
	landed: boolean,
	alpha0: number?, -- starting transparency (dust)
}

local particles: { Particle } = {}

local function makeParticlePart(size: Vector3, color: Color3, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.Color = color
	p.Material = material
	p.Parent = fxFolder
	return p
end

local function spawnLeaf(at: Vector3, color: Color3, groundY: number, burst: number)
	local size = Vector3.new(rng:NextNumber(0.35, 0.6), 0.06, rng:NextNumber(0.3, 0.5))
	table.insert(particles, {
		part = makeParticlePart(size, color, Enum.Material.SmoothPlastic),
		pos = at,
		vel = Vector3.new(rng:NextNumber(-1, 1) * burst, rng:NextNumber(0, 1) * burst, rng:NextNumber(-1, 1) * burst),
		gravity = 10,
		drag = 2.5, -- leaves float down
		sway = rng:NextNumber(1, 2.2),
		phase = rng:NextNumber(0, math.pi * 2),
		spin = Vector3.new(rng:NextNumber(-4, 4), rng:NextNumber(-4, 4), rng:NextNumber(-4, 4)),
		rot = CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28)),
		groundY = groundY + size.Y / 2,
		age = 0,
		life = rng:NextNumber(2.2, 3.4),
		landed = false,
	})
end

local function spawnChip(at: Vector3, color: Color3, groundY: number, dir: Vector3)
	local size = Vector3.new(0.25, 0.25, 0.25) * rng:NextNumber(0.7, 1.3)
	local out = (dir + Vector3.new(rng:NextNumber(-0.7, 0.7), rng:NextNumber(0.6, 1.4), rng:NextNumber(-0.7, 0.7))).Unit
	table.insert(particles, {
		part = makeParticlePart(size, color, Enum.Material.Wood),
		pos = at,
		vel = out * rng:NextNumber(14, 22),
		gravity = 70,
		drag = 0.3,
		sway = 0,
		phase = 0,
		spin = Vector3.new(rng:NextNumber(-12, 12), rng:NextNumber(-12, 12), rng:NextNumber(-12, 12)),
		rot = CFrame.identity,
		groundY = groundY + size.Y / 2,
		age = 0,
		life = rng:NextNumber(0.8, 1.2),
		landed = false,
	})
end

local DUST_COLOR = Color3.fromRGB(176, 150, 112)

-- A soft puff kicked up where the falling tree hits the floor.
local function spawnDust(at: Vector3, dir: Vector3)
	local s = rng:NextNumber(0.5, 1.1)
	local side = dir:Cross(Vector3.yAxis)
	local out = side * rng:NextNumber(-1, 1) + dir * rng:NextNumber(-0.3, 0.6)
	local part = makeParticlePart(Vector3.one * s, DUST_COLOR, Enum.Material.SmoothPlastic)
	part.Transparency = 0.35
	table.insert(particles, {
		part = part,
		pos = at,
		vel = out * rng:NextNumber(5, 10) + Vector3.new(0, rng:NextNumber(2, 5), 0),
		gravity = 3,
		drag = 3.5,
		sway = 0,
		phase = 0,
		spin = Vector3.new(rng:NextNumber(-3, 3), rng:NextNumber(-3, 3), rng:NextNumber(-3, 3)),
		rot = CFrame.identity,
		groundY = at.Y - 0.3 + s / 2,
		age = 0,
		life = rng:NextNumber(0.7, 1.1),
		landed = false,
		alpha0 = 0.35,
	})
end

RunService.Heartbeat:Connect(function(dt)
	for i = #particles, 1, -1 do
		local p = particles[i]
		p.age += dt
		if p.age >= p.life then
			p.part:Destroy()
			table.remove(particles, i)
			continue
		end
		if not p.landed then
			p.vel += Vector3.new(0, -p.gravity * dt, 0)
			p.vel *= math.max(0, 1 - p.drag * dt)
			local swayOffset = Vector3.new(math.sin(p.age * 3 + p.phase), 0, math.cos(p.age * 2.3 + p.phase)) * p.sway * dt
			p.pos += p.vel * dt + swayOffset
			p.rot *= CFrame.Angles(p.spin.X * dt, p.spin.Y * dt, p.spin.Z * dt)
			if p.pos.Y <= p.groundY then
				p.pos = Vector3.new(p.pos.X, p.groundY, p.pos.Z)
				p.landed = true
				-- Lie flat-ish on the ground.
				local _, ry, _ = p.rot:ToEulerAnglesYXZ()
				p.rot = CFrame.Angles(0, ry, 0)
			end
			p.part.CFrame = CFrame.new(p.pos) * p.rot
		end
		local fadeFrom = p.life - 0.5
		if p.age > fadeFrom then
			local a0 = p.alpha0 or 0
			p.part.Transparency = a0 + (1 - a0) * (p.age - fadeFrom) / 0.5
		end
	end
end)

local function treeGroundY(tree: Model): number
	local cf, size = tree:GetBoundingBox()
	return cf.Position.Y - size.Y / 2
end

function TreeFX.Leaves(tree: Model, count: number, burst: number?, groundY: number?)
	local leaves = leafPartsOf(tree)
	if #leaves == 0 then
		return
	end
	groundY = groundY or treeGroundY(tree)
	for _ = 1, count do
		local src = leaves[rng:NextInteger(1, #leaves)]
		spawnLeaf(randomPointOn(src), src.Color, groundY :: number, burst or 2)
	end
end

-- The treetop slams into the floor: dust along the trunk's length and a big leaf burst.
onImpact = function(m: Motion)
	local dir = m.dir or Vector3.zAxis
	local floorY = m.floorY or m.hinge.Y
	local length = m.length or 8
	local n = math.clamp(math.floor(length / 1.6), 4, 14)
	for i = 1, n do
		local along = m.hinge + dir * (length * i / n)
		local at = Vector3.new(along.X, floorY + 0.3, along.Z)
		spawnDust(at, dir)
		spawnDust(at, dir)
	end
	TreeFX.Leaves(m.tree, math.floor(TreeConfig.LeavesOnFell * 0.7), 7, floorY)
end

function TreeFX.Chips(tree: Model, hitPos: Vector3, fromPos: Vector3?, count: number)
	local trunkColor = Color3.fromRGB(124, 92, 70)
	for _, p in partsOf(tree) do
		if p.Name == "Trunk" then
			trunkColor = p.Color
			break
		end
	end
	local dir = if fromPos then (fromPos - hitPos) else Vector3.zero
	dir = Vector3.new(dir.X, 0, dir.Z)
	dir = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.zero
	local groundY = treeGroundY(tree)
	for _ = 1, count do
		spawnChip(hitPos, trunkColor, groundY, dir)
	end
end

-- Damage numbers -------------------------------------------------------------------------------

-- Anime / comic "bubble" numbers: chunky LuckiestGuy text with a hot gradient fill, a thick dark
-- outline and a dark copy underneath for depth. Each one punches in oversized at a random tilt,
-- settles, drifts up and to the side, then shrinks away.
-- The billboard is sized in studs (scale), so far-away numbers are small like the world around them;
-- outlines and the shadow offset follow the number's on-screen size.

local DAMAGE_FONT = Enum.Font.LuckiestGuy
local DAMAGE_TOP = Color3.fromRGB(255, 110, 100) -- light red
local DAMAGE_MID = Color3.fromRGB(240, 40, 40)
local DAMAGE_BOTTOM = Color3.fromRGB(170, 10, 15) -- deep red
local DAMAGE_OUTLINE = Color3.fromRGB(60, 8, 10)
local DAMAGE_STUDS = Vector2.new(4.6, 1.9) -- size of a number in the world
local DAMAGE_REF_HEIGHT = 78 -- on-screen height (px) the stroke thicknesses below are made for

local function damageLayer(parent: Instance, text: string, offset: UDim2, zIndex: number): (TextLabel, UIStroke)
	-- offset is in pixels at DAMAGE_REF_HEIGHT; turn it into scale so it shrinks with the number.
	offset = UDim2.fromScale(offset.X.Offset / (DAMAGE_REF_HEIGHT * DAMAGE_STUDS.X / DAMAGE_STUDS.Y), offset.Y.Offset / DAMAGE_REF_HEIGHT)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5) + offset
	label.Size = UDim2.fromScale(1, 1)
	label.Font = DAMAGE_FONT
	label.TextScaled = true
	label.Text = text
	label.ZIndex = zIndex
	label.Parent = parent
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Color = DAMAGE_OUTLINE
	stroke.Parent = label
	return label, stroke
end

function TreeFX.DamageNumber(pos: Vector3, amount: number, color: Color3?)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.1
	anchor.Position = pos + Vector3.new(rng:NextNumber(-1.3, 1.3), rng:NextNumber(0.6, 1.6), rng:NextNumber(-1.3, 1.3))
	anchor.Parent = fxFolder

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(DAMAGE_STUDS.X, DAMAGE_STUDS.Y)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 220
	gui.ClipsDescendants = false
	gui.Parent = anchor

	local tilt = rng:NextNumber(8, 16) * (if rng:NextNumber() < 0.5 then -1 else 1)
	local root = Instance.new("Frame")
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Rotation = tilt
	root.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Scale = 0.2
	scale.Parent = root

	local text = "-" .. HeroConfig.Abbreviate(amount)
	-- Dark copy under the text = the "puffy" 3D bubble edge.
	local shadow, shadowStroke = damageLayer(root, text, UDim2.fromOffset(3, 5), 1)
	shadow.TextColor3 = DAMAGE_OUTLINE
	shadowStroke.Thickness = 5
	local label, stroke = damageLayer(root, text, UDim2.new(), 2)
	label.TextColor3 = Color3.new(1, 1, 1)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = if color
		then ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.7), color)
		else ColorSequence.new({
			ColorSequenceKeypoint.new(0, DAMAGE_TOP),
			ColorSequenceKeypoint.new(0.45, DAMAGE_MID),
			ColorSequenceKeypoint.new(1, DAMAGE_BOTTOM),
		})
	gradient.Parent = label

	-- Outlines are in pixels: keep them in proportion to the number's on-screen size.
	local strokes = { [stroke] = stroke.Thickness, [shadowStroke] = shadowStroke.Thickness }
	local function fitStrokes()
		local k = math.clamp(gui.AbsoluteSize.Y / DAMAGE_REF_HEIGHT, 0.05, 3)
		for s, base in strokes do
			s.Thickness = base * k
		end
	end
	fitStrokes()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitStrokes)

	-- Punch in oversized, settle with a bounce while straightening a bit.
	local punch = TweenService:Create(scale, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1.45 })
	punch.Completed:Once(function()
		TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end)
	punch:Play()
	TweenService:Create(root, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Rotation = tilt * 0.35 }):Play()
	-- Drift up and to one side.
	local side = rng:NextNumber(0.6, 1.6) * (if tilt < 0 then 1 else -1)
	TweenService:Create(gui, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { StudsOffset = Vector3.new(side, 3.4, 0) }):Play()
	-- Shrink + fade out.
	local out = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.6)
	task.delay(0.6, function()
		TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Scale = 0.4 }):Play()
	end)
	for _, t in { label, shadow } do
		TweenService:Create(t, out, { TextTransparency = 1 }):Play()
	end
	for _, s in { stroke, shadowStroke } do
		TweenService:Create(s, out, { Transparency = 1 }):Play()
	end
	task.delay(0.9, function()
		anchor:Destroy()
	end)
end

-- Public combos --------------------------------------------------------------------------------

-- Everything a single hit shows (except the number, which comes from the server).
function TreeFX.Hit(tree: Model, hitPos: Vector3, fromPos: Vector3?)
	if tree:GetAttribute("Dead") then
		return
	end
	TreeFX.Flash(tree)
	TreeFX.Shake(tree, fromPos)
	TreeFX.Leaves(tree, TreeConfig.LeavesPerHit, 2)
	TreeFX.Chips(tree, hitPos, fromPos, 4)
end

function TreeFX.Fell(tree: Model, fromPos: Vector3?)
	if not tree.Parent then
		return
	end
	local m = getMotion(tree)
	if m.kind == "fall" then
		return
	end
	-- Restore the untouched pose first, so the fall starts upright.
	m.body:PivotTo(m.base)
	local dir = tipDirection(m, fromPos)
	local trunk = trunkOf(tree, m.body)
	local radius = if trunk then math.max(trunk.Size.X, trunk.Size.Z) / 2 else 0.5
	local cf, size = m.body:GetBoundingBox()
	local ground = groundOf(tree)

	m.kind = "fall"
	m.dir = dir
	m.axis = axisFor(dir)
	m.hinge += dir * radius -- a cut tree tips over the front edge of its trunk
	m.length = math.max(1, cf.Position.Y + size.Y / 2 - m.hinge.Y)
	m.floorY = treeGroundY(tree)
	m.impacted = false
	m.start = os.clock()
	m.bodyParts = partsOf(m.body)
	m.groundParts = if ground then partsOf(ground) else nil

	-- HP bars ("Info", "InfoAttachment.TreeBar", ...)
	for _, d in tree:GetDescendants() do
		if d:IsA("BillboardGui") then
			d.Enabled = false
		end
	end
	TreeFX.Flash(tree)
	TreeFX.Leaves(tree, math.floor(TreeConfig.LeavesOnFell * 0.3), 3)
end

return TreeFX
