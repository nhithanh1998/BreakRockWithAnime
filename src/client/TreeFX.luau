-- TreeFX: client-only effects for trees: hit flash, shake, falling leaves, wood chips,
-- floating damage numbers and the fall-over animation when a tree dies.
-- Everything here is local; the server never sees these changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))

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
-- Every motion rotates the tree around the bottom-center of its bounding box, starting from the
-- pivot it had before any effect touched it, so repeated hits never make the tree drift.

type Motion = {
	tree: Model,
	base: CFrame,
	bottom: Vector3,
	axis: Vector3,
	kind: "shake" | "fall",
	start: number,
	angle: number, -- shake amplitude, radians
	duration: number, -- shake length, seconds
	parts: { BasePart }?,
}

local motions: { [Model]: Motion } = {}

local function getMotion(tree: Model): Motion
	local m = motions[tree]
	if m then
		return m
	end
	local cf, size = tree:GetBoundingBox()
	local newMotion: Motion = {
		tree = tree,
		base = tree:GetPivot(),
		bottom = cf.Position - Vector3.new(0, size.Y / 2, 0),
		axis = Vector3.xAxis,
		kind = "shake",
		start = os.clock(),
		angle = math.rad(TreeConfig.ShakeAngle),
		duration = TreeConfig.ShakeTime,
	}
	motions[tree] = newMotion
	return newMotion
end

local function tiltAxis(m: Motion, fromPos: Vector3?): Vector3
	local dir = if fromPos then m.bottom - fromPos else Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
	dir = Vector3.new(dir.X, 0, dir.Z)
	if dir.Magnitude < 1e-3 then
		dir = Vector3.zAxis
	end
	-- Rotating around up x dir tips the top of the tree along dir (away from the hit).
	return Vector3.yAxis:Cross(dir.Unit).Unit
end

local function applyTilt(m: Motion, angle: number)
	local pivot = CFrame.new(m.bottom)
	m.tree:PivotTo(pivot * CFrame.fromAxisAngle(m.axis, angle) * pivot:Inverse() * m.base)
end

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	for tree, m in motions do
		if not tree.Parent then
			motions[tree] = nil
			continue
		end
		local e = now - m.start
		if m.kind == "shake" then
			local t = m.duration
			if e >= t then
				tree:PivotTo(m.base)
				motions[tree] = nil
			else
				local k = 1 - e / t
				applyTilt(m, m.angle * k * math.sin(e * 55))
			end
		else
			-- Fall: ease-in topple, small bounce, then fade out.
			local fallTime = TreeConfig.FellTime * 0.6
			local a: number
			if e < fallTime then
				local t = e / fallTime
				a = math.rad(88) * t * t
			else
				local b = e - fallTime
				a = math.rad(88) - math.rad(6) * math.exp(-b * 10) * math.abs(math.sin(b * 25))
			end
			applyTilt(m, a)
			local fadeStart = TreeConfig.FellTime * 0.55
			if e > fadeStart and m.parts then
				local alpha = math.clamp((e - fadeStart) / (TreeConfig.FellTime * 0.4), 0, 1)
				for _, p in m.parts do
					p.LocalTransparencyModifier = alpha
				end
			end
		end
	end
end)

-- Works on any Model (trees, the chest, ...). angleDeg / duration default to the tree values.
function TreeFX.Shake(model: Model, fromPos: Vector3?, angleDeg: number?, duration: number?)
	local m = getMotion(model)
	if m.kind == "fall" then
		return
	end
	m.axis = tiltAxis(m, fromPos)
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
		newH.Adornee = tree
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
			p.part.Transparency = (p.age - fadeFrom) / 0.5
		end
	end
end)

local function treeGroundY(tree: Model): number
	local cf, size = tree:GetBoundingBox()
	return cf.Position.Y - size.Y / 2
end

function TreeFX.Leaves(tree: Model, count: number, burst: number?)
	local leaves = leafPartsOf(tree)
	if #leaves == 0 then
		return
	end
	local groundY = treeGroundY(tree)
	for _ = 1, count do
		local src = leaves[rng:NextInteger(1, #leaves)]
		spawnLeaf(randomPointOn(src), src.Color, groundY, burst or 2)
	end
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

function TreeFX.DamageNumber(pos: Vector3, amount: number, color: Color3?)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.1
	anchor.Position = pos + Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(0, 1), rng:NextNumber(-1, 1))
	anchor.Parent = fxFolder

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(140, 44)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 200
	gui.Parent = anchor

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = "-" .. tostring(math.floor(amount + 0.5))
	label.TextColor3 = color or Color3.fromRGB(255, 70, 70)
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Parent = label

	-- Pop in, float up, fade.
	local scale = Instance.new("UIScale")
	scale.Scale = 0.3
	scale.Parent = label
	TweenService:Create(scale, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	TweenService:Create(gui, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { StudsOffset = Vector3.new(0, 3, 0) }):Play()
	local fade = TweenInfo.new(0.35, Enum.EasingStyle.Linear, Enum.EasingDirection.In, 0, false, 0.45)
	TweenService:Create(label, fade, { TextTransparency = 1 }):Play()
	TweenService:Create(stroke, fade, { Transparency = 1 }):Play()
	task.delay(0.85, function()
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
	tree:PivotTo(m.base)
	m.kind = "fall"
	m.axis = tiltAxis(m, fromPos)
	m.start = os.clock()
	m.parts = partsOf(tree)

	local info = tree:FindFirstChild("Info")
	if info and info:IsA("BillboardGui") then
		info.Enabled = false
	end
	TreeFX.Flash(tree)
	TreeFX.Leaves(tree, TreeConfig.LeavesOnFell, 6)
end

return TreeFX
