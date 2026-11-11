-- DropFX: client-only visuals for tree drops. Items pop out of the felled tree, land around it
-- with a name / amount / chance label, then fly into the plot's chest (ChestFX bumps its count as
-- each one lands). The server has already added them to the inventory; this is purely the show.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local ChestFX = require(script.Parent:WaitForChild("ChestFX"))

type Drop = TreeConfig.Drop

local DropFX = {}

local rng = Random.new()
local player = Players.LocalPlayer

local fxFolder = workspace:FindFirstChild("ClientFX") or Instance.new("Folder")
fxFolder.Name = "ClientFX"
fxFolder.Parent = workspace

local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local function basePart(): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	return p
end

local function rarityColor(rarity: string): Color3
	return TreeConfig.RarityColors[rarity] or Color3.new(1, 1, 1)
end

-- Builds the 3D item. Returns the part and the half-height used to rest it on the ground.
local function buildVisual(drop: Drop): (Part, number)
	local p = basePart()
	if drop.Kind == "Anime" then
		-- Glowing hero card.
		p.Size = Vector3.new(1.4, 1.9, 0.2)
		p.Material = Enum.Material.Neon
		p.Color = rarityColor(drop.Rarity)
		local light = Instance.new("PointLight")
		light.Color = p.Color
		light.Range = 10
		light.Brightness = 2
		light.Parent = p
		return p, p.Size.Y / 2
	end

	local def = TreeConfig.Materials[drop.Kind]
	local v = def and def.Visual
	if not v then
		p.Size = Vector3.one
		return p, 0.5
	end
	-- Always a square block with classic studs on every face (Minecraft-style item cube).
	p.Shape = Enum.PartType.Block
	p.Size = v.Size
	p.Color = v.Color
	p.Material = v.Material
	p.TopSurface = Enum.SurfaceType.Studs
	p.BottomSurface = Enum.SurfaceType.Studs
	p.FrontSurface = Enum.SurfaceType.Studs
	p.BackSurface = Enum.SurfaceType.Studs
	p.LeftSurface = Enum.SurfaceType.Studs
	p.RightSurface = Enum.SurfaceType.Studs
	if v.Shape == "Gem" then
		local light = Instance.new("PointLight")
		light.Color = v.Color
		light.Range = 8
		light.Brightness = 1.5
		light.Parent = p
	end
	return p, math.max(v.Size.Y, v.Size.Z) / 2
end

local function buildLabel(drop: Drop, adornee: BasePart): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(190, 46)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2.2, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 150
	gui.Adornee = adornee

	-- UIScale has to sit on a GuiObject, not on the BillboardGui itself.
	local root = Instance.new("Frame")
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = gui

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(1, 0.58)
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = if drop.Kind == "Anime" then rarityColor(drop.Rarity) else Color3.new(1, 1, 1)
	title.Text = ("%s%s (x%d)"):format(if drop.Kind == "Anime" then "★ " else "", drop.Name, drop.Amount)
	title.Parent = root
	local s1 = Instance.new("UIStroke")
	s1.Thickness = 2
	s1.Parent = title

	local chance = Instance.new("TextLabel")
	chance.BackgroundTransparency = 1
	chance.Position = UDim2.fromScale(0, 0.58)
	chance.Size = UDim2.fromScale(1, 0.42)
	chance.Font = Enum.Font.FredokaOne
	chance.TextScaled = true
	chance.TextColor3 = rarityColor(drop.Rarity)
	local pct = drop.Chance * 100
	chance.Text = if pct >= 10 then ("%d%%"):format(math.floor(pct + 0.5)) else ("%.2f%%"):format(pct)
	chance.Parent = root
	local s2 = Instance.new("UIStroke")
	s2.Thickness = 1.5
	s2.Parent = chance

	local scale = Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = root
	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	gui.Parent = adornee
	return gui
end

-- Expanding ring + sparkles for rare drops.
local function burst(pos: Vector3, color: Color3)
	local ring = basePart()
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.2
	ring.Size = Vector3.new(0.2, 1, 1)
	ring.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = fxFolder
	local info = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(ring, info, { Size = Vector3.new(0.05, 9, 9), Transparency = 1 }):Play()

	local holder = basePart()
	holder.Transparency = 1
	holder.Size = Vector3.one
	holder.Position = pos
	holder.Parent = fxFolder
	local att = Instance.new("Attachment")
	att.Parent = holder
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = SPARKLE_TEXTURE
	pe.Color = ColorSequence.new(color)
	pe.LightEmission = 1
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	pe.Lifetime = NumberRange.new(0.4, 0.8)
	pe.Speed = NumberRange.new(10, 18)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Rate = 0
	pe.Parent = att
	pe:Emit(24)

	task.delay(1, function()
		ring:Destroy()
		holder:Destroy()
	end)
end

local function findGround(pos: Vector3, fallbackY: number): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { fxFolder }
	if player.Character then
		table.insert(exclude, player.Character)
	end
	-- Skip trees (the felled one is still falling) so items land on the floor, not in leaves.
	for _ = 1, 5 do
		params.FilterDescendantsInstances = exclude
		local result = workspace:Raycast(pos + Vector3.new(0, 15, 0), Vector3.new(0, -40, 0), params)
		if not result then
			break
		end
		local inst: Instance? = result.Instance
		local tree: Instance? = nil
		while inst and inst ~= workspace do
			if inst.Parent and inst.Parent.Name == "TreeSpawns" then
				tree = inst
				break
			end
			inst = inst.Parent
		end
		if not tree then
			if math.abs(result.Position.Y - fallbackY) < 12 then
				return result.Position.Y
			end
			break
		end
		table.insert(exclude, tree)
	end
	return fallbackY
end

local function playDrop(drop: Drop, origin: Vector3, groundY: number, index: number, chest: Model?)
	local part, halfHeight = buildVisual(drop)
	local angle = rng:NextNumber(0, math.pi * 2)
	local dist = rng:NextNumber(TreeConfig.DropSpread.Min, TreeConfig.DropSpread.Max)
	local target = origin + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
	local restY = findGround(target, groundY) + halfHeight + 0.4
	target = Vector3.new(target.X, restY, target.Z)
	local spin = CFrame.Angles(rng:NextNumber(0, 6.28), 0, 0)
	-- Blocks stay axis-aligned and just spin around Y, like Minecraft item drops.
	local shapeTilt = CFrame.identity

	part.CFrame = CFrame.new(origin)
	part.Parent = fxFolder

	-- 1) Arc out of the tree.
	local arcTime = 0.55
	local arcHeight = rng:NextNumber(5, 8)
	local t0 = os.clock()
	while true do
		local t = math.min((os.clock() - t0) / arcTime, 1)
		local pos = origin:Lerp(target, t) + Vector3.new(0, 4 * arcHeight * t * (1 - t), 0)
		part.CFrame = CFrame.new(pos) * CFrame.Angles(0, t * 12, 0) * spin * shapeTilt
		if t >= 1 then
			break
		end
		RunService.Heartbeat:Wait()
	end

	-- 2) Land: label, rare burst.
	buildLabel(drop, part)
	if TreeConfig.FancyRarities[drop.Rarity] then
		burst(target, rarityColor(drop.Rarity))
	end

	-- 3) Bob + spin on the ground.
	local hold = TreeConfig.DropHoldTime + index * 0.06
	local landAt = os.clock()
	while os.clock() - landAt < hold do
		local e = os.clock() - landAt
		local bob = math.sin(e * 4) * 0.25
		part.CFrame = CFrame.new(target + Vector3.new(0, bob, 0)) * CFrame.Angles(0, e * 2, 0) * shapeTilt
		RunService.Heartbeat:Wait()
	end

	-- 4) Fly into the chest (or into the player when there is no chest).
	local label = part:FindFirstChildOfClass("BillboardGui")
	if label then
		label:Destroy()
	end
	local startPos = part.Position
	local startSize = part.Size
	local flyTime = 0.35
	local arc = 2
	if chest then
		local dist = (ChestFX.GetMouth(chest) - startPos).Magnitude
		flyTime = math.clamp(dist / TreeConfig.ChestFlySpeed, TreeConfig.ChestFlyTime.Min, TreeConfig.ChestFlyTime.Max)
		arc = math.clamp(dist * 0.25, 4, 18)
	end
	local f0 = os.clock()
	while true do
		local goal: Vector3
		if chest then
			if not chest.Parent then
				break
			end
			goal = ChestFX.GetMouth(chest)
		else
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not root then
				break
			end
			goal = root.Position
		end
		local t = math.min((os.clock() - f0) / flyTime, 1)
		local eased = t * t
		local pos = startPos:Lerp(goal, eased) + Vector3.new(0, math.sin(t * math.pi) * arc, 0)
		part.Size = startSize * (1 - 0.6 * eased)
		part.CFrame = CFrame.new(pos) * CFrame.Angles(0, t * 10, 0) * shapeTilt
		if t >= 1 then
			break
		end
		RunService.Heartbeat:Wait()
	end
	part:Destroy()
	if chest then
		ChestFX.Arrive(chest, drop.Amount, startPos)
	end
end

function DropFX.Play(origin: Vector3, groundY: number, drops: { Drop }, chest: Model?)
	if chest then
		local total = 0
		for _, drop in drops do
			total += drop.Amount
		end
		ChestFX.AddInFlight(chest, total)
	end
	for i, drop in drops do
		task.delay((i - 1) * 0.07, playDrop, drop, origin, groundY, i, chest)
	end
end

return DropFX
