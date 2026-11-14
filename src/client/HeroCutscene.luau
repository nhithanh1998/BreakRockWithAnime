-- HeroCutscene: a short cinematic when a rare hero (TreeConfig.CutsceneRarities) drops from a tree.
--
-- Timeline (seconds, Mythic runs a bit longer):
--   0.0  CHARGE  letterbox bars slide in, the world desaturates, a pillar of light in the rarity
--                colour grows out of the felled tree while the camera dollies in and shakes harder.
--   1.6  FLASH   white flash, shockwave ring on the ground, colours come back tinted; the hero
--                appears in the pillar's place playing its idle, with spinning light rays behind.
--        CLOSE   low-angle close-up on the hero, slow push in.
--   3.0  ORBIT   camera sweeps around the hero while "LEGENDARY!" slams in, the name types out,
--                power and drop chance fade in underneath.
--   6.0  OUTRO   fade to black, gameplay camera / GUI / controls come back, fade in.
-- Click / tap / Space skips to the outro (after a short moment so it isn't skipped by accident).
--
-- Usage (TreeClient): local waitDone = HeroCutscene.Play(drop, origin, groundY)
-- Cutscenes queue up; waitDone() yields until this one has finished (DropFX waits on it before
-- the drops pop out of the tree). Purely client-side visuals.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TreeConfig = require(Shared:WaitForChild("TreeConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local DropFX = require(script.Parent:WaitForChild("DropFX"))

type Drop = TreeConfig.Drop

local HeroCutscene = {}

-- Speed of the cutscene clock (debugging / slow motion): 0 freezes it, 0.5 is half speed.
HeroCutscene.TimeScale = 1

local player = Players.LocalPlayer

local FONT = Enum.Font.FredokaOne
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local HERO_SCALE = 1 -- full size in the cutscene (DropFX shows them at 0.75)
local SKIP_AFTER = 0.8 -- seconds before a click can skip
local RENDER_NAME = "HeroCutsceneCamera"

-- Phase lengths in seconds (multiplied by LONGER for Mythic).
local T_CHARGE = 1.6
local T_CLOSE = 1.4
local T_ORBIT = 3.0
local T_OUTRO = 0.45
local FALL_TIME = 0.4 -- the hero shoots down the pillar this long before the impact
local FALL_HEIGHT = 12 -- studs above the ground it starts from
local LONGER = { Mythic = 1.2, Legendary = 1.1 } :: { [string]: number }

local fxFolder = workspace:FindFirstChild("ClientFX") or Instance.new("Folder")
fxFolder.Name = "ClientFX"
fxFolder.Parent = workspace

-- Helpers ------------------------------------------------------------------------------------------

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

local function easeInOut(x: number): number
	x = clamp01(x)
	return if x < 0.5 then 4 * x * x * x else 1 - (-2 * x + 2) ^ 3 / 2
end

local function easeOut(x: number): number
	return 1 - (1 - clamp01(x)) ^ 3
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function tween(inst: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
	local tw = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function new(className: string, props: { [string]: any }): any
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function neonPart(color: Color3, props: { [string]: any }?): Part
	local p = new("Part", {
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Material = Enum.Material.Neon,
		Color = color,
		Shape = Enum.PartType.Cylinder,
	})
	for k, v in props or {} do
		(p :: any)[k] = v
	end
	return p
end

local function playSound(id: string, volume: number)
	if id == "" then
		return
	end
	local s = new("Sound", { SoundId = id, Volume = volume, Parent = workspace })
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
	task.delay(10, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

local function rarityRank(rarity: string): number
	return TreeConfig.RarityOrder[rarity] or 99 -- lower = rarer
end

-- The rarest hero in `drops` that gets a cutscene, or nil.
function HeroCutscene.Pick(drops: { Drop }): Drop?
	local best: Drop? = nil
	for _, drop in drops do
		if drop.Kind == "Anime" and TreeConfig.CutsceneRarities[drop.Rarity] then
			if best == nil or rarityRank(drop.Rarity) < rarityRank(best.Rarity) then
				best = drop
			end
		end
	end
	return best
end

-- Player GUI / controls ------------------------------------------------------------------------------

local function getControls(): any
	local ok, controls = pcall(function()
		local module = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 2)
		return module and (require(module :: ModuleScript) :: any):GetControls()
	end)
	return if ok then controls else nil
end

-- Hides every other ScreenGui; returns a function that shows them again.
local function hideGuis(except: ScreenGui): () -> ()
	local hidden: { ScreenGui } = {}
	for _, g in player:WaitForChild("PlayerGui"):GetChildren() do
		if g:IsA("ScreenGui") and g ~= except and g.Enabled then
			g.Enabled = false
			table.insert(hidden, g)
		end
	end
	return function()
		for _, g in hidden do
			if g.Parent then
				g.Enabled = true
			end
		end
	end
end

-- The cutscene ----------------------------------------------------------------------------------------

type Ui = {
	gui: ScreenGui,
	barTop: Frame,
	barBottom: Frame,
	flash: Frame,
	fade: Frame,
	title: TextLabel,
	titleScale: UIScale,
	name: TextLabel,
	info: TextLabel,
	hint: TextLabel,
}

local function buildUi(drop: Drop, color: Color3): Ui
	local gui = new("ScreenGui", {
		Name = "HeroCutsceneGui",
		DisplayOrder = 100,
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	local function bar(anchorY: number): Frame
		return new("Frame", {
			AnchorPoint = Vector2.new(0, anchorY),
			Position = UDim2.fromScale(0, anchorY),
			Size = UDim2.fromScale(1, 0),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BorderSizePixel = 0,
			ZIndex = 5,
			Parent = gui,
		})
	end
	local barTop = bar(0)
	local barBottom = bar(1)

	local function cover(c: Color3): Frame
		return new("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = c,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ZIndex = 20,
			Parent = gui,
		})
	end
	local flash = cover(Color3.new(1, 1, 1))
	local fade = cover(Color3.new(0, 0, 0))

	local titleText = string.upper(drop.Rarity) .. "!"
	local title = new("TextLabel", {
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.62),
		Size = UDim2.fromScale(0.7, 0.13),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = titleText,
		TextColor3 = Color3.new(1, 1, 1),
		TextScaled = true,
		TextTransparency = 1,
		Rotation = -3,
		ZIndex = 10,
		Parent = gui,
	})
	new("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(0.45, color:Lerp(Color3.new(1, 1, 1), 0.35)),
			ColorSequenceKeypoint.new(1, color),
		}),
		Rotation = 90,
		Parent = title,
	})
	local titleStroke = new("UIStroke", {
		Color = color:Lerp(Color3.new(0, 0, 0), 0.75),
		Thickness = 5,
		Transparency = 1,
		Parent = title,
	})
	local titleScale = new("UIScale", { Scale = 3, Parent = title })
	-- Keep the stroke in step with the text's fade.
	title:GetPropertyChangedSignal("TextTransparency"):Connect(function()
		titleStroke.Transparency = title.TextTransparency
	end)

	local function sub(y: number, h: number, text: string, textColor: Color3): TextLabel
		local label = new("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, y),
			Size = UDim2.fromScale(0.6, h),
			BackgroundTransparency = 1,
			Font = FONT,
			Text = text,
			TextColor3 = textColor,
			TextScaled = true,
			TextTransparency = 1,
			ZIndex = 10,
			Parent = gui,
		})
		local stroke = new("UIStroke", { Thickness = 2.5, Transparency = 1, Parent = label })
		label:GetPropertyChangedSignal("TextTransparency"):Connect(function()
			stroke.Transparency = label.TextTransparency
		end)
		return label
	end
	local hero = HeroConfig.Get(drop.Name)
	local power = if hero then HeroConfig.Abbreviate(hero.MinePower) else "?"
	-- The name without its size ("Diamond Huge X" -> "Diamond X"), in the rarity's moving gradient; the
	-- size gets a line of its own under the info line.
	local name = sub(0.735, 0.075, if hero then HeroConfig.DisplayName(hero) else drop.Name, Color3.new(1, 1, 1))
	if hero then
		HeroConfig.PaintRarityGradient(name, hero.Rarity)
	end
	name.MaxVisibleGraphemes = 0
	local info = sub(0.8, 0.045, ("Power %s   •   %s chance"):format(power, DropFX.FormatChance(drop.Chance)), color:Lerp(Color3.new(1, 1, 1), 0.25))
	local sizeLabel: TextLabel? = nil
	if hero and hero.Size and HeroConfig.SizeBadgeFX[hero.Size] then
		local label = sub(0.857, 0.05, string.upper(hero.Size), Color3.new(1, 1, 1))
		HeroConfig.PaintRarityGradient(label, hero.Size) -- SizeBadgeFX colours, animated like rarities
		sizeLabel = label
	end

	local hint = new("TextLabel", {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -10),
		Size = UDim2.fromScale(0.2, 0.03),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = if UserInputService.TouchEnabled then "Tap to skip" else "Click to skip",
		TextColor3 = Color3.fromRGB(170, 170, 170),
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTransparency = 1,
		ZIndex = 6,
		Parent = gui,
	})

	gui.Parent = player:WaitForChild("PlayerGui")
	return {
		gui = gui,
		barTop = barTop,
		barBottom = barBottom,
		flash = flash,
		fade = fade,
		title = title,
		titleScale = titleScale,
		name = name,
		info = info,
		size = sizeLabel,
		hint = hint,
	}
end

local function run(drop: Drop, origin: Vector3, groundY: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local color = DropFX.RarityColor(drop.Rarity)
	local long = LONGER[drop.Rarity] or 1
	local tCharge = T_CHARGE * long
	local tReveal = tCharge -- flash + hero appears
	local tOrbit = tReveal + T_CLOSE
	local tOutro = tOrbit + T_ORBIT * long
	local tEnd = tOutro + T_OUTRO

	-- Staging: the hero stands where the tree was, facing the player's side.
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local fromPos = if root then root.Position else camera.CFrame.Position
	local flat = Vector3.new(fromPos.X - origin.X, 0, fromPos.Z - origin.Z)
	local dir = if flat.Magnitude > 0.1 then flat.Unit else Vector3.zAxis
	local side = dir:Cross(Vector3.yAxis).Unit
	local up = Vector3.yAxis
	local feet = Vector3.new(origin.X, groundY, origin.Z)
	local shakeSeed = math.random() * 100

	-- Saved state ------------------------------------------------------------------------------
	local oldType = camera.CameraType
	local oldFov = camera.FieldOfView
	local controls = getControls()
	if controls then
		pcall(controls.Disable, controls)
	end
	local ui = buildUi(drop, color)
	local showGuis = hideGuis(ui.gui)
	local cleanup: { Instance } = { ui.gui }

	-- Lighting -----------------------------------------------------------------------------------
	local cc = new("ColorCorrectionEffect", { Name = "HeroCutsceneCC", Parent = Lighting })
	local bloom = new("BloomEffect", { Name = "HeroCutsceneBloom", Intensity = 0.3, Size = 28, Threshold = 0.92, Parent = Lighting })
	local sunRays = new("SunRaysEffect", { Name = "HeroCutsceneSunRays", Intensity = 0, Spread = 0.7, Parent = Lighting })
	local dof = new("DepthOfFieldEffect", {
		Name = "HeroCutsceneDOF",
		FarIntensity = 0,
		NearIntensity = 0,
		FocusDistance = 20,
		InFocusRadius = 10,
		Parent = Lighting,
	})
	table.insert(cleanup, cc)
	table.insert(cleanup, bloom)
	table.insert(cleanup, sunRays)
	table.insert(cleanup, dof)

	-- Coloured vignette: the screen edges glow in a deep shade of the rarity colour (not black), and
	-- close in with every heartbeat during the charge.
	local vignette = new("CanvasGroup", {
		Name = "Vignette",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		ZIndex = 4,
		Parent = ui.gui,
	})
	local edgeColor = color:Lerp(Color3.new(0, 0, 0), 0.3)
	local edgeFade = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1) })
	for _, e in { { 0, 0, 0.32, 1, 0 }, { 1, 0, 0.32, 1, 180 }, { 0, 0, 1, 0.38, 90 }, { 0, 1, 1, 0.38, 270 } } do
		local f = new("Frame", {
			AnchorPoint = Vector2.new(e[1], e[2]),
			Position = UDim2.fromScale(e[1], e[2]),
			Size = UDim2.fromScale(e[3], e[4]),
			BackgroundColor3 = edgeColor,
			BorderSizePixel = 0,
			Parent = vignette,
		})
		new("UIGradient", { Rotation = e[5], Transparency = edgeFade, Parent = f })
	end

	-- Opening: letterbox in, colours get punchier and lean towards the rarity colour.
	tween(ui.barTop, 0.5, { Size = UDim2.fromScale(1, 0.11) })
	tween(ui.barBottom, 0.5, { Size = UDim2.fromScale(1, 0.11) })
	tween(ui.hint, 0.4, { TextTransparency = 0.3 })
	tween(dof, tCharge, { FarIntensity = 0.15 }, Enum.EasingStyle.Sine)
	playSound(TreeConfig.CutsceneSounds.Charge or "", 0.8)

	-- Charge: pillar of light + inward sparkles at the tree.
	local pillar = neonPart(color, { Transparency = 0.15, Size = Vector3.new(0.1, 1.5, 1.5) })
	pillar.Parent = fxFolder
	table.insert(cleanup, pillar)
	local baseRing = neonPart(color, { Transparency = 0.35, Size = Vector3.new(0.15, 3, 3) })
	baseRing.CFrame = CFrame.new(feet + up * 0.1) * CFrame.Angles(0, 0, math.pi / 2)
	baseRing.Parent = fxFolder
	table.insert(cleanup, baseRing)
	local chargeAtt = new("Attachment", { Parent = baseRing })
	local chargeEmitter = new("ParticleEmitter", {
		Texture = SPARKLE_TEXTURE,
		Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.4), color),
		LightEmission = 1,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) }),
		Lifetime = NumberRange.new(0.6, 1.1),
		Rate = 60,
		Speed = NumberRange.new(10, 18),
		SpreadAngle = Vector2.new(25, 25),
		EmissionDirection = Enum.NormalId.Right, -- the cylinder's X axis points up
		Parent = chargeAtt,
	})

	-- State filled in at the reveal.
	local heroHeight = 5
	local head: BasePart? = nil
	local heroVisual: DropFX.HeroVisual? = nil
	local highlight: Highlight? = nil
	local tFall = tReveal - FALL_TIME
	local spawned = false
	local revealed = false
	local nextBeat = 0.2
	local pulse = 0
	local orbitStarted = false
	local outroStarted = false
	local finished = false
	local t = 0
	local shake = 0

	local function heroFocus(heightShare: number): Vector3
		return feet + up * heroHeight * heightShare
	end

	-- The hero, as a glowing silhouette, shoots down the pillar of light.
	local function spawnHero()
		spawned = true
		local visual = DropFX.BuildHero(drop, HERO_SCALE)
		if not visual then
			return
		end
		heroVisual = visual
		heroHeight = visual.height
		visual.model.Parent = fxFolder
		table.insert(cleanup, visual.model)
		DropFX.PlayIdle(visual)
		head = visual.model:FindFirstChild("Head") :: BasePart?
		highlight = new("Highlight", {
			FillColor = Color3.new(1, 1, 1),
			FillTransparency = 0,
			OutlineColor = color:Lerp(Color3.new(1, 1, 1), 0.35),
			OutlineTransparency = 0,
			-- Drawn through the pillar while falling; normal again after the impact.
			DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
			Parent = visual.model,
		})
	end

	local function placeFallingHero()
		local visual = heroVisual
		if not visual then
			return
		end
		local k = clamp01((t - tFall) / FALL_TIME)
		local height = FALL_HEIGHT * (1 - k * k) -- accelerates into the ground
		local rootPos = feet + up * (visual.bottom + height)
		visual.model:PivotTo(CFrame.lookAt(rootPos, rootPos + dir))
	end

	local function reveal()
		revealed = true
		playSound(TreeConfig.CutsceneSounds.Reveal or "", 1)
		-- Impact: flash, then a bright, saturated grade with a touch of the rarity colour.
		ui.flash.BackgroundColor3 = Color3.new(1, 1, 1):Lerp(color, 0.15)
		ui.flash.BackgroundTransparency = 0
		tween(ui.flash, 0.55, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		cc.Saturation = 0.4
		cc.Contrast = 0.12
		cc.Brightness = 0.25
		cc.TintColor = Color3.new(1, 1, 1):Lerp(color, 0.08)
		tween(cc, 1.4, { Brightness = 0.05, Saturation = 0.3 })
		bloom.Intensity = 1
		bloom.Threshold = 0.9
		tween(bloom, 1.4, { Intensity = 0.4 })
		sunRays.Intensity = 0.3
		tween(sunRays, 1.6, { Intensity = 0.08 })
		vignette.GroupTransparency = 0.3
		tween(vignette, 1.2, { GroupTransparency = 0.7 })
		dof.FarIntensity = 0.3
		shake = 1.3

		-- The silhouette fades to the real hero; the coloured outline stays a while longer.
		placeFallingHero()
		if highlight then
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
			tween(highlight, 0.8, { FillTransparency = 1 })
			task.delay(2.2, function()
				if highlight and highlight.Parent then
					tween(highlight, 1, { OutlineTransparency = 1 })
				end
			end)
		end
		-- Dust / sparks thrown out from the landing spot.
		local dustAtt = new("Attachment", { Parent = baseRing })
		local dust = new("ParticleEmitter", {
			Texture = SPARKLE_TEXTURE,
			Color = ColorSequence.new(Color3.new(1, 1, 1), color),
			LightEmission = 0.8,
			Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) }),
			Transparency = NumberSequence.new(0, 1),
			Lifetime = NumberRange.new(0.5, 0.9),
			Speed = NumberRange.new(18, 30),
			SpreadAngle = Vector2.new(180, 15),
			Drag = 4,
			EmissionDirection = Enum.NormalId.Right,
			Enabled = false,
			Parent = dustAtt,
		})
		dust:Emit(60)

		-- Pillar bursts outward and fades; shockwave ring on the ground.
		chargeEmitter.Enabled = false
		tween(pillar, 0.45, { Size = Vector3.new(pillar.Size.X, 14, 14), Transparency = 1 })
		tween(baseRing, 0.7, { Size = Vector3.new(0.15, 34, 34), Transparency = 1 }, Enum.EasingStyle.Quart)
		local wave = neonPart(Color3.new(1, 1, 1), { Transparency = 0.2, Size = Vector3.new(0.12, 4, 4) })
		wave.CFrame = CFrame.new(feet + up * 0.15) * CFrame.Angles(0, 0, math.pi / 2)
		wave.Parent = fxFolder
		table.insert(cleanup, wave)
		tween(wave, 0.9, { Size = Vector3.new(0.12, 46, 46), Transparency = 1 }, Enum.EasingStyle.Quart)

		-- Aura around the landed hero.
		local visual = heroVisual
		if visual then
			local glow = new("PointLight", { Color = color, Range = 18, Brightness = 3, Parent = visual.root })
			tween(glow, 1.5, { Brightness = 1.2 })
			local auraAtt = new("Attachment", { Position = Vector3.new(0, -visual.bottom + 0.2, 0), Parent = visual.root })
			new("ParticleEmitter", {
				Texture = SPARKLE_TEXTURE,
				Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.5), color),
				LightEmission = 1,
				Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) }),
				Transparency = NumberSequence.new(0.1, 1),
				Lifetime = NumberRange.new(1, 1.8),
				Rate = 30,
				Speed = NumberRange.new(1.5, 4),
				SpreadAngle = Vector2.new(70, 70),
				EmissionDirection = Enum.NormalId.Top,
				Parent = auraAtt,
			})
			local shine = DropFX.BuildShine(visual.root, drop.Rarity, heroHeight * 2.2, heroHeight / 2 - visual.bottom)
			table.insert(cleanup, shine)
		end
	end

	local function startOrbit()
		orbitStarted = true
		-- Title slams in, name types out, info fades in.
		ui.title.TextTransparency = 0
		ui.titleScale.Scale = 3
		tween(ui.titleScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		shake = math.max(shake, 0.5)
		task.delay(0.35, function()
			if outroStarted then
				return
			end
			local graphemes = utf8.len(ui.name.Text) or #ui.name.Text
			tween(ui.name, math.min(0.05 * graphemes, 0.8), { MaxVisibleGraphemes = graphemes }, Enum.EasingStyle.Linear)
			ui.name.TextTransparency = 0
		end)
		task.delay(0.9, function()
			if not outroStarted then
				tween(ui.info, 0.4, { TextTransparency = 0 })
				if ui.size then
					-- The size line pops in after the info line.
					local pop = Instance.new("UIScale")
					pop.Scale = 1.8
					pop.Parent = ui.size
					tween(ui.size, 0.3, { TextTransparency = 0 })
					tween(pop, 0.4, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
				end
			end
		end)
	end

	local function startOutro()
		outroStarted = true
		t = math.max(t, tOutro)
		tween(ui.fade, T_OUTRO * 0.8, { BackgroundTransparency = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end

	-- Skip ---------------------------------------------------------------------------------------
	local skipConn = UserInputService.InputBegan:Connect(function(input, _processed)
		if t < SKIP_AFTER or outroStarted then
			return
		end
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.Return
			or input.KeyCode == Enum.KeyCode.ButtonA then
			startOutro()
		end
	end)

	-- The player's own character would block the shots: hide it locally while the cutscene runs.
	local bodyParts: { BasePart | Decal } = {}
	if character then
		for _, d in character:GetDescendants() do
			if d:IsA("BasePart") or d:IsA("Decal") then
				table.insert(bodyParts, d)
			end
		end
	end
	local function setBodyHidden(hidden: boolean)
		for _, p in bodyParts do
			if p.Parent then
				p.LocalTransparencyModifier = if hidden then 1 else 0
			end
		end
	end

	-- Anything between the camera and the hero (pad heroes, fences, signs) is hidden locally.
	local MAX_OCCLUDER = 40 -- studs; bigger parts (ground, walls of the map) are left alone
	local occluders: { [BasePart]: boolean } = {}
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local function clearView(from: Vector3, to: Vector3)
		local ignore: { Instance } = { fxFolder }
		if character then
			table.insert(ignore, character)
		end
		for _ = 1, 8 do
			rayParams.FilterDescendantsInstances = ignore
			local hit = workspace:Raycast(from, to - from, rayParams)
			if not hit then
				return
			end
			local part = hit.Instance
			table.insert(ignore, part)
			if part:IsA("BasePart") and part.Size.Magnitude <= MAX_OCCLUDER then
				local model = part:FindFirstAncestorOfClass("Model")
				local group: { Instance } = if model and model ~= workspace and model:FindFirstChildOfClass("Humanoid")
					then model:GetDescendants()
					else { part }
				for _, d in group do
					if d:IsA("BasePart") and not occluders[d] then
						occluders[d] = true
						d.LocalTransparencyModifier = 1
					end
				end
			end
		end
	end

	-- Characters (pad heroes, hero workers, other players) that stand on screen in front of the
	-- hero are hidden too, so the stage is clear.
	local actors: { Model } = {}
	for _, h in workspace:GetDescendants() do
		if h:IsA("Humanoid") then
			local m = h.Parent
			if m and m:IsA("Model") and m ~= character and not m:IsDescendantOf(fxFolder) then
				table.insert(actors, m)
			end
		end
	end
	local hiddenActors: { [Model]: boolean } = {}
	local function clearActors(camPos: Vector3, target: Vector3)
		local targetDist = (target - camPos).Magnitude
		for _, m in actors do
			if not m.Parent or hiddenActors[m] then
				continue
			end
			local pos = m:GetPivot().Position
			local dist = (pos - camPos).Magnitude
			if dist < targetDist - 1.5 then
				local _, onScreen = camera:WorldToViewportPoint(pos)
				if onScreen or dist < 6 then
					hiddenActors[m] = true
					for _, d in m:GetDescendants() do
						if d:IsA("BasePart") and not occluders[d] then
							occluders[d] = true
						end
					end
				end
			end
		end
	end

	-- Camera ---------------------------------------------------------------------------------------
	camera.CameraType = Enum.CameraType.Scriptable
	local startCf = camera.CFrame
	local startFov = camera.FieldOfView

	local function shot(): (Vector3, Vector3, number)
		if t < tReveal then
			-- Wide dolly in towards the growing pillar.
			local a = easeInOut(t / tCharge)
			local from = feet + dir * 30 + up * 15 + side * 7
			local to = feet + dir * 17 + up * 5 + side * 3
			local pos = from:Lerp(to, a)
			local look = feet + up * lerp(9, 5, a)
			-- Blend from where the player's camera was during the first moment.
			local blend = easeOut(t / 0.5)
			pos = startCf.Position:Lerp(pos, blend)
			look = (startCf.Position + startCf.LookVector * 20):Lerp(look, blend)
			-- Tilt up to follow the hero shooting down the pillar.
			local visual = heroVisual
			if visual then
				local k = clamp01((t - tFall) / FALL_TIME)
				look = look:Lerp(visual.root.Position, 0.7 * (1 - k * k))
			end
			return pos, look, lerp(startFov, 52, a)
		elseif t < tOrbit then
			-- Low-angle close-up, slow push in.
			local b = easeOut((t - tReveal) / T_CLOSE)
			local h = heroHeight
			local pos = feet + dir * lerp(h * 1.15, h * 0.85, b) + up * h * 0.3 + side * lerp(h * 0.35, h * 0.15, b)
			local look = if head then head.Position - up * h * 0.05 else heroFocus(0.78)
			return pos, look, lerp(48, 42, b)
		else
			-- Orbit around the hero, rising.
			local c = (t - tOrbit) / (tOutro - tOrbit)
			local e = easeOut(c)
			local h = heroHeight
			local angle = lerp(-1.0, 0.7, e)
			local around = CFrame.Angles(0, angle, 0):VectorToWorldSpace(dir)
			local pos = feet + around * lerp(h * 1.5, h * 2.1, e) + up * lerp(h * 0.25, h * 0.65, e)
			return pos, heroFocus(0.6), lerp(46, 52, e)
		end
	end

	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
		dt *= HeroCutscene.TimeScale
		t += dt
		if not spawned and t >= tFall and not outroStarted then
			spawnHero()
		end
		if spawned and not revealed then
			placeFallingHero()
		end
		if not revealed and t >= tReveal and not outroStarted then
			reveal()
		end
		if not orbitStarted and t >= tOrbit and not outroStarted then
			startOrbit()
		end
		if not outroStarted and t >= tOutro then
			startOutro()
		end
		if t >= tEnd then
			finished = true
		end

		-- Charge: the pillar grows and everything throbs to a heartbeat that keeps speeding up.
		local fovKick = 0
		if not revealed and not outroStarted then
			local a = clamp01(t / tCharge)
			if t >= nextBeat then
				pulse = 1
				nextBeat += lerp(0.55, 0.13, a)
			end
			pulse = math.max(pulse - dt * 5, 0)
			local height = lerp(2, 70, easeInOut(a))
			local width = lerp(1.2, 3.2, a) + pulse * 1.4
			pillar.Size = Vector3.new(height, width, width)
			pillar.CFrame = CFrame.new(feet + up * height / 2) * CFrame.Angles(0, 0, math.pi / 2)
			-- Thinner glow while the hero shoots down it, so the silhouette reads.
			pillar.Transparency = if spawned then 0.6 else 0.25 - 0.2 * pulse
			local ringSize = lerp(3, 9, a) + pulse * 2.5
			baseRing.Size = Vector3.new(0.15, ringSize, ringSize)
			-- Bright and colourful, never dark: a rarity tint that swells with each beat.
			cc.Saturation = lerp(0.15, 0.3, a)
			cc.Contrast = lerp(0.05, 0.18, a)
			cc.Brightness = 0.03 + 0.12 * pulse
			cc.TintColor = Color3.new(1, 1, 1):Lerp(color, 0.03 + 0.06 * a + 0.05 * pulse)
			bloom.Intensity = 0.25 + 0.25 * a + 0.4 * pulse
			sunRays.Intensity = 0.04 + 0.1 * pulse
			vignette.GroupTransparency = math.clamp(lerp(0.85, 0.5, a) - 0.2 * pulse, 0.3, 1)
			fovKick = -3 * pulse
			shake = 0.06 + 0.3 * a * a + 0.25 * pulse
		else
			shake = math.max(shake - dt * 1.6, 0.03)
		end

		local pos, look, fov = shot()
		fov += fovKick
		-- Handheld shake.
		local n = t * 18
		local offset = Vector3.new(
			math.noise(n, shakeSeed, 0),
			math.noise(n, shakeSeed, 10),
			math.noise(n, shakeSeed, 20)
		) * shake * 0.6
		camera.CFrame = CFrame.lookAt(pos + offset, look + offset * 0.5)
		camera.FieldOfView = fov
		dof.FocusDistance = (look - pos).Magnitude
		-- Set every frame: the default camera scripts also write LocalTransparencyModifier.
		setBodyHidden(t > 0.35)
		if t > 0.35 then
			clearView(pos, look)
			clearActors(pos, feet + up * heroHeight * 0.5)
			for p in occluders do
				p.LocalTransparencyModifier = 1
			end
		end
	end)

	while not finished do
		task.wait()
	end

	-- Restore ------------------------------------------------------------------------------------
	RunService:UnbindFromRenderStep(RENDER_NAME)
	skipConn:Disconnect()
	setBodyHidden(false)
	for p in occluders do
		p.LocalTransparencyModifier = 0
	end
	camera.CameraType = oldType
	camera.FieldOfView = oldFov
	if controls then
		pcall(controls.Enable, controls)
	end
	showGuis()
	for _, inst in cleanup do
		if inst ~= ui.gui then
			inst:Destroy()
		end
	end
	-- Fade back in, bars slide away, then drop the GUI.
	ui.title.Visible = false
	ui.name.Visible = false
	ui.info.Visible = false
	if ui.size then
		ui.size.Visible = false
	end
	ui.hint.Visible = false
	vignette.Visible = false
	tween(ui.fade, 0.4, { BackgroundTransparency = 1 })
	tween(ui.barTop, 0.4, { Size = UDim2.fromScale(1, 0) })
	tween(ui.barBottom, 0.4, { Size = UDim2.fromScale(1, 0) })
	task.delay(0.45, function()
		ui.gui:Destroy()
	end)
end

-- Queue ------------------------------------------------------------------------------------------

type Job = { drop: Drop, origin: Vector3, groundY: number, done: boolean, event: BindableEvent }
local queue: { Job } = {}
local running = false

local function runQueue()
	running = true
	while #queue > 0 do
		local job = table.remove(queue, 1) :: Job
		local ok, err = pcall(run, job.drop, job.origin, job.groundY)
		if not ok then
			warn("[HeroCutscene]", err)
			-- Never leave the player stuck with a scripted camera.
			pcall(RunService.UnbindFromRenderStep, RunService, RENDER_NAME)
			local camera = workspace.CurrentCamera
			if camera then
				camera.CameraType = Enum.CameraType.Custom
			end
			local controls = getControls()
			if controls then
				pcall(controls.Enable, controls)
			end
		end
		job.done = true
		job.event:Fire()
	end
	running = false
end

-- Plays the cutscene for `drop` (after any that are already playing). Returns a function that
-- yields until this cutscene has finished.
function HeroCutscene.Play(drop: Drop, origin: Vector3, groundY: number): () -> ()
	local job: Job = { drop = drop, origin = origin, groundY = groundY, done = false, event = Instance.new("BindableEvent") }
	table.insert(queue, job)
	if not running then
		task.spawn(runQueue)
	end
	return function()
		if not job.done then
			job.event.Event:Wait()
		end
	end
end

return HeroCutscene
