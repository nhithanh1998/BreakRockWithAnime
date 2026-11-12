-- DropFX: client-only visuals for tree drops. Items pop out of the felled tree, land around it
-- with a name / amount / chance label, then fly into the plot's chest (ChestFX bumps its count as
-- each one lands). The server has already added them to the inventory; this is purely the show.
--
-- Materials are studded blocks; heroes are their real model (ReplicatedStorage.Heros, HeroConfig
-- Template) playing the default idle animation and facing the camera. Every drop that lands gets a
-- spinning light burst behind it in its rarity colour (bigger / more rays for rarer items), and a
-- label: white name, chance below in the rarity colour.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TreeConfig = require(Shared:WaitForChild("TreeConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local ChestFX = require(script.Parent:WaitForChild("ChestFX"))

type Drop = TreeConfig.Drop

local DropFX = {}

local rng = Random.new()
local player = Players.LocalPlayer

local fxFolder = workspace:FindFirstChild("ClientFX") or Instance.new("Folder")
fxFolder.Name = "ClientFX"
fxFolder.Parent = workspace

local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

-- Roblox's default idle animations (the hero templates' own Animate scripts are not used here).
local DEFAULT_IDLE = {
	[Enum.HumanoidRigType.R6] = "rbxassetid://180435571",
	[Enum.HumanoidRigType.R15] = "rbxassetid://507766388",
}
local HERO_SCALE = 0.75 -- dropped heroes are a bit smaller than players

-- Light burst size (studs) per rarity; materials use MATERIAL_SHINE of it.
local SHINE_SIZE = { Common = 7, Uncommon = 7.8, Rare = 8.8, Epic = 10, Legendary = 11.5, Mythic = 13 }
local MATERIAL_SHINE = 0.5

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

-- Common 1 .. Mythic 6
local function rarityTier(rarity: string): number
	return 7 - (TreeConfig.RarityOrder[rarity] or 6)
end

-- 9 -> "9.00%", 22 -> "22.0%", 0.4 -> "0.400%" (three significant digits).
local function formatChance(chance: number): string
	local pct = chance * 100
	if pct >= 100 then
		return "100%"
	elseif pct <= 0 then
		return "0%"
	end
	local decimals = math.clamp(2 - math.floor(math.log10(pct)), 0, 4)
	return ("%." .. decimals .. "f%%"):format(pct)
end

-- Heroes ---------------------------------------------------------------------------------------------

type HeroVisual = { model: Model, root: BasePart, humanoid: Humanoid, bottom: number, height: number }

local function heroTemplate(name: string): Model?
	local model = HeroConfig.GetTemplate(name)
	if model then
		return model
	end
	local folder = ReplicatedStorage:FindFirstChild(HeroConfig.TemplateFolder)
	local fallback = folder and folder:FindFirstChild(HeroConfig.FallbackTemplate)
	return if fallback and fallback:IsA("Model") then fallback else nil
end

-- The hero's own model, held by its anchored root (the limbs stay free so the idle animation plays).
local function buildHero(drop: Drop): HeroVisual?
	local template = heroTemplate(drop.Name)
	if not template then
		return nil
	end
	local model = template:Clone()
	local root = model:FindFirstChild("HumanoidRootPart")
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid then
		model:Destroy()
		return nil
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.Anchored = d == root
		elseif d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	model.PrimaryPart = root
	model:ScaleTo(HERO_SCALE)
	local cf, size = model:GetBoundingBox()
	return {
		model = model,
		root = root,
		humanoid = humanoid,
		bottom = root.Position.Y - (cf.Position.Y - size.Y / 2),
		height = size.Y,
	}
end

-- Default idle, looped. Call after the model is in the workspace.
local function playIdle(hero: HeroVisual)
	local humanoid = hero.humanoid
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animator.Parent = humanoid
	local anim = Instance.new("Animation")
	anim.AnimationId = DEFAULT_IDLE[humanoid.RigType] or DEFAULT_IDLE[Enum.HumanoidRigType.R6]
	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(anim)
	end)
	if ok and track then
		track.Looped = true
		track.Priority = Enum.AnimationPriority.Idle
		track:Play(0)
	end
end

-- Light burst -------------------------------------------------------------------------------------

local SHINE_SPIN = 18 -- degrees per second, always the same way
local SHINE_BEHIND = 1.6 -- studs the burst sits behind the item, along the line from the camera

local SHINE_PIXELS = 40 -- SurfaceGui resolution per stud

-- The burst is a flat, invisible part with a SurfaceGui (not a BillboardGui: billboards always draw
-- over 3D models, so the item would be hidden behind its own light). Every frame the panel is moved
-- just behind the item's centre on the line from the camera and turned to face the camera.
type Shine = { part: BasePart, spin: GuiObject, adornee: BasePart, y: number }
local shines: { Shine } = {}

RunService.RenderStepped:Connect(function(dt)
	local cam = workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else Vector3.zero
	for i = #shines, 1, -1 do
		local s = shines[i]
		if s.part.Parent == nil or s.adornee.Parent == nil then
			s.part:Destroy()
			table.remove(shines, i)
			continue
		end
		s.spin.Rotation = (s.spin.Rotation + SHINE_SPIN * dt) % 360
		local center = s.adornee.Position + Vector3.new(0, s.y, 0)
		local away = center - camPos
		if away.Magnitude > 0.1 then
			local pos = center + away.Unit * SHINE_BEHIND
			s.part.CFrame = CFrame.lookAt(pos, camPos) -- Front face towards the camera
		end
	end
end)

-- Spinning rays + a soft glow, drawn just behind the item's centre. Destroy the returned part to
-- remove it (it also goes away by itself when the item does).
local function buildShine(adornee: BasePart, rarity: string, studs: number, yOffset: number): BasePart
	local color = rarityColor(rarity)
	local bright = color:Lerp(Color3.new(1, 1, 1), 0.3)
	local tier = rarityTier(rarity)

	local panel = basePart()
	panel.Name = "Shine"
	panel.Transparency = 1
	panel.Size = Vector3.new(studs, studs, 0.05)
	panel.CFrame = CFrame.new(adornee.Position + Vector3.new(0, yOffset, 0))

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = SHINE_PIXELS
	gui.LightInfluence = 0
	gui.MaxDistance = 150
	gui.Parent = panel

	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(1, 1)
	holder.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = holder

	local glow = Instance.new("Frame")
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.Size = UDim2.fromScale(0.45, 0.45)
	glow.BackgroundColor3 = color
	glow.BackgroundTransparency = 0.5
	glow.BorderSizePixel = 0
	glow.Parent = holder
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = glow

	-- Each bar is two opposite rays; long and short ones alternate. Rarer = more rays.
	local spin = Instance.new("Frame")
	spin.BackgroundTransparency = 1
	spin.Size = UDim2.fromScale(1, 1)
	spin.Parent = holder
	local bars = 4 + tier
	for i = 1, bars do
		local long = i % 2 == 1
		local ray = Instance.new("Frame")
		ray.AnchorPoint = Vector2.new(0.5, 0.5)
		ray.Position = UDim2.fromScale(0.5, 0.5)
		ray.Size = UDim2.fromScale(if long then 0.13 else 0.09, if long then 1 else 0.7)
		ray.Rotation = (i - 1) * 180 / bars
		ray.BackgroundColor3 = Color3.new(1, 1, 1)
		ray.BorderSizePixel = 0
		local g = Instance.new("UIGradient")
		g.Rotation = 90
		g.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, color),
			ColorSequenceKeypoint.new(0.5, bright),
			ColorSequenceKeypoint.new(1, color),
		})
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, 0.55),
			NumberSequenceKeypoint.new(0.42, 0.1),
			NumberSequenceKeypoint.new(0.5, 0),
			NumberSequenceKeypoint.new(0.58, 0.1),
			NumberSequenceKeypoint.new(0.8, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Parent = ray
		ray.Parent = spin
	end

	local sparkle = Instance.new("ImageLabel")
	sparkle.BackgroundTransparency = 1
	sparkle.AnchorPoint = Vector2.new(0.5, 0.5)
	sparkle.Position = UDim2.fromScale(0.5, 0.5)
	sparkle.Size = UDim2.fromScale(0.6, 0.6)
	sparkle.Image = SPARKLE_TEXTURE
	sparkle.ImageColor3 = bright
	sparkle.ImageTransparency = 0.15
	sparkle.Parent = holder

	panel.Parent = fxFolder
	table.insert(shines, { part = panel, spin = spin, adornee = adornee, y = yOffset })
	TweenService:Create(scale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	return panel
end

-- Materials --------------------------------------------------------------------------------------

-- Builds a material's studded block. Returns the part and the half-height used to rest it on the ground.
local function buildBlock(drop: Drop): (Part, number)
	local p = basePart()
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

-- Name (white) with the chance under it in the rarity colour.
local function buildLabel(drop: Drop, adornee: BasePart, yOffset: number): BillboardGui
	local isHero = drop.Kind == "Anime"
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = if isHero then UDim2.fromOffset(230, 58) else UDim2.fromOffset(200, 50)
	gui.StudsOffsetWorldSpace = Vector3.new(0, yOffset, 0)
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
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Text = if isHero and drop.Amount <= 1 then drop.Name else ("%s (x%d)"):format(drop.Name, drop.Amount)
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
	chance.Text = formatChance(drop.Chance)
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
		-- A tree's dirt mound ("Ground") counts as ground, so drops stand on it instead of in it.
		local mound = tree and tree:FindFirstChild("Ground")
		local onMound = mound ~= nil and result.Instance:IsDescendantOf(mound)
		if not tree or onMound then
			if math.abs(result.Position.Y - fallbackY) < 12 then
				return result.Position.Y
			end
			break
		end
		-- Trunk / leaves: look through them (the felled one is still falling).
		local body = tree:FindFirstChild("Tree")
		table.insert(exclude, body or tree)
	end
	return fallbackY
end

-- Yaw that turns a hero at `pos` towards the camera.
local function facingCamera(pos: Vector3): CFrame
	local cam = workspace.CurrentCamera
	local look = if cam then Vector3.new(cam.CFrame.Position.X, pos.Y, cam.CFrame.Position.Z) else pos + Vector3.zAxis
	if (look - pos).Magnitude < 0.05 then
		return CFrame.new(pos)
	end
	return CFrame.lookAt(pos, look)
end

local function playDrop(drop: Drop, origin: Vector3, groundY: number, index: number, chest: Model?)
	local hero = if drop.Kind == "Anime" then buildHero(drop) else nil
	local part: BasePart, halfHeight: number, labelY: number, shineY: number, shineStuds: number
	local baseShine = SHINE_SIZE[drop.Rarity] or SHINE_SIZE.Common
	if hero then
		part = hero.root
		halfHeight = hero.bottom -- root height above the feet
		labelY = hero.height - hero.bottom + 1
		shineY = hero.height / 2 - hero.bottom
		shineStuds = baseShine
	else
		local block, h = buildBlock(drop)
		part = block
		halfHeight = h + 0.4
		labelY = 2.2
		shineY = 0
		shineStuds = baseShine * MATERIAL_SHINE
	end
	local visual: Instance = if hero then hero.model else part
	local function place(cf: CFrame)
		if hero then
			hero.model:PivotTo(cf)
		else
			part.CFrame = cf
		end
	end

	local angle = rng:NextNumber(0, math.pi * 2)
	local dist = rng:NextNumber(TreeConfig.DropSpread.Min, TreeConfig.DropSpread.Max)
	local target = origin + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
	local restY = findGround(target, groundY) + halfHeight
	target = Vector3.new(target.X, restY, target.Z)
	-- Blocks tumble; heroes only turn around Y.
	local spin = if hero then CFrame.identity else CFrame.Angles(rng:NextNumber(0, 6.28), 0, 0)

	place(CFrame.new(origin))
	visual.Parent = fxFolder
	if hero then
		playIdle(hero)
	end

	-- 1) Arc out of the tree.
	local arcTime = 0.55
	local arcHeight = rng:NextNumber(5, 8)
	local t0 = os.clock()
	while true do
		local t = math.min((os.clock() - t0) / arcTime, 1)
		local pos = origin:Lerp(target, t) + Vector3.new(0, 4 * arcHeight * t * (1 - t), 0)
		place(CFrame.new(pos) * CFrame.Angles(0, t * 12, 0) * spin)
		if t >= 1 then
			break
		end
		RunService.Heartbeat:Wait()
	end

	-- 2) Land: light burst behind it, label, ring + sparkles for rare drops.
	local shine = buildShine(part, drop.Rarity, shineStuds, shineY)
	buildLabel(drop, part, labelY)
	if TreeConfig.FancyRarities[drop.Rarity] then
		burst(target - Vector3.new(0, halfHeight - 0.3, 0), rarityColor(drop.Rarity))
	end

	-- 3) On the ground: heroes stand facing the camera, blocks bob + spin.
	local hold = TreeConfig.DropHoldTime + index * 0.06
	local landAt = os.clock()
	while os.clock() - landAt < hold do
		local e = os.clock() - landAt
		if hero then
			place(facingCamera(target))
		else
			local bob = math.sin(e * 4) * 0.25
			place(CFrame.new(target + Vector3.new(0, bob, 0)) * CFrame.Angles(0, e * 2, 0))
		end
		RunService.Heartbeat:Wait()
	end

	-- 4) Fly into the chest (or into the player when there is no chest).
	shine:Destroy()
	local label = part:FindFirstChild("Label")
	if label then
		label:Destroy()
	end
	local startPos = part.Position
	local startSize = part.Size
	local startRot = if hero then facingCamera(startPos).Rotation else CFrame.identity
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
		local shrink = 1 - 0.6 * eased
		if hero then
			hero.model:ScaleTo(HERO_SCALE * math.max(shrink, 0.05))
			place(CFrame.new(pos) * startRot * CFrame.Angles(0, t * 10, 0))
		else
			part.Size = startSize * shrink
			place(CFrame.new(pos) * CFrame.Angles(0, t * 10, 0))
		end
		if t >= 1 then
			break
		end
		RunService.Heartbeat:Wait()
	end
	visual:Destroy()
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
