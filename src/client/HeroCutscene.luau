-- HeroCutscene: a short cinematic when a rare hero (TreeConfig.CutsceneRarities) drops from a tree.
--
-- Four phases, shown as a segmented progress bar in the top letterbox bar (the running phase's
-- segment fills up) with a one-line caption in the bottom bar:
--
--   1 SIGNAL  letterbox bars slide in, a pale pillar of light grows out of the felled tree while
--             the camera dollies in. Nothing is known yet: the title reads "???".
--   2 RARITY  the pillar climbs the rarity ladder one tier at a time ("EPIC?" -> "LEGENDARY?" ...),
--             every tier with its own colour, punch and shockwave. A "?" behind the tier means it
--             may still go higher; every tier lasts equally long, so the last one can't be told
--             apart until it locks ("LEGENDARY!") - the very moment the hero lands.
--   3 WHO?    the hero stands there as a black silhouette inside the light. "???" for its name,
--             "Power ???", question marks circling it, a heartbeat that keeps speeding up while
--             the camera creeps around to its front. The last moment everything rushes inwards.
--   4 REVEAL  white flash, the silhouette burns away, the name decodes out of scrambled glyphs,
--             power counts up; low-angle close-up, then an orbit around the hero.
--     OUTRO   fade to black, gameplay camera / GUI / controls come back, fade in.
--
-- Click / tap / Space: before the reveal it jumps straight to the REVEAL (so the hero is never
-- missed), after it it skips to the outro.
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
local SKIP_COOLDOWN = 0.5 -- real seconds between two skips (reveal, then outro)
local RENDER_NAME = "HeroCutsceneCamera"

-- Phase lengths in seconds. Rarer heroes run longer by themselves: one T_STEP per ladder tier.
local T_SIGNAL = 1.2
local T_STEP = 0.65 -- per rarity tier of the climb
local T_MYSTERY = 1.9 -- the silhouette with its "???"
local T_RUSH = 0.35 -- end of the mystery: everything rushes in towards the flash
local T_CLOSE = 1.1
local T_ORBIT = 2.4
local T_OUTRO = 0.45
local FALL_TIME = 0.4 -- the hero shoots down the pillar this long before the impact
local FALL_HEIGHT = 12 -- studs above the ground it starts from

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local UNKNOWN_COLOR = Color3.fromRGB(205, 220, 240) -- the pillar before any rarity shows

local PHASES = {
	{ Label = "SIGNAL", Caption = "Something stirs inside the tree..." },
	{ Label = "RARITY", Caption = "The rarity keeps rising..." },
	{ Label = "WHO?", Caption = "Who could it be?" },
	{ Label = "REVEAL", Caption = "A new hero appears!" },
}
local MYSTERY_NAME = "???"
local MYSTERY_SCALE = 1.6 -- the big "???" over the silhouette (TextScaled stops at 100 px, this goes on top)
local MARK_COUNT = 7 -- question marks circling the silhouette
local MYSTERY_INFO = "Power ???   •   ??? chance"
local SCRAMBLE = { "?", "#", "?", "%", "&", "?", "@", "$", "?", "!" } -- glyphs of a name not decoded yet
local SCRAMBLE_EVERY = 0.045 -- seconds between two reshuffles

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

local function playSound(id: string?, volume: number, speed: number?)
	if not id or id == "" then
		return
	end
	local s = new("Sound", { SoundId = id, Volume = volume, PlaybackSpeed = speed or 1, Parent = workspace })
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

-- The tiers the RARITY phase climbs through, lowest first, ending at `rarity`: every cutscene
-- rarity up to it (Mythic -> { "Epic", "Legendary", "Mythic" }).
local function rarityLadder(rarity: string): { string }
	local ladder: { string } = {}
	for r, enabled in TreeConfig.CutsceneRarities do
		if enabled and r ~= rarity and rarityRank(r) > rarityRank(rarity) then
			table.insert(ladder, r)
		end
	end
	table.sort(ladder, function(a, b)
		return rarityRank(a) > rarityRank(b)
	end)
	table.insert(ladder, rarity)
	return ladder
end

-- "Sling Scout" -> { "S", "l", "i", ... } (whole characters, also for non-ASCII names).
local function splitGlyphs(text: string): { string }
	local glyphs: { string } = {}
	if utf8.len(text) then
		for _, code in utf8.codes(text) do
			table.insert(glyphs, utf8.char(code))
		end
	else
		for i = 1, #text do
			table.insert(glyphs, string.sub(text, i, i))
		end
	end
	return glyphs
end

-- The rarest hero in `drops` that gets a cutscene, or nil: only a hero the player never had before
-- (Drop.New, set by the server) of a cutscene rarity (TreeConfig.CutsceneRarities: Legendary and up).
function HeroCutscene.Pick(drops: { Drop }): Drop?
	local best: Drop? = nil
	for _, drop in drops do
		if drop.Kind == "Anime" and drop.New == true and TreeConfig.CutsceneRarities[drop.Rarity] then
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

type Segment = { label: TextLabel, scale: UIScale, fill: Frame }

type Ui = {
	gui: ScreenGui,
	hud: Frame, -- every text of the cutscene (hidden in one go at the end)
	barTop: Frame,
	barBottom: Frame,
	flash: Frame,
	fade: Frame,
	title: TextLabel,
	titleScale: UIScale,
	titleGradient: UIGradient,
	titleStroke: UIStroke,
	mystery: TextLabel, -- the big "???" over the silhouette
	mysteryScale: UIScale,
	mysteryGradient: UIGradient,
	mysteryStroke: UIStroke,
	name: TextLabel,
	nameScale: UIScale,
	info: TextLabel,
	infoScale: UIScale,
	size: TextLabel?,
	sizeScale: UIScale?,
	hint: TextLabel,
	tracker: CanvasGroup,
	segments: { Segment },
	caption: TextLabel,
}

local function buildUi(hero: HeroConfig.HeroDef?): Ui
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
			BackgroundColor3 = BLACK,
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
	local flash = cover(WHITE)
	local fade = cover(BLACK)

	local hud = new("Frame", {
		Name = "Hud",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 10,
		Parent = gui,
	})

	-- Rarity line: "???" -> "EPIC?" -> "LEGENDARY!" (painted by the cutscene as it climbs).
	local title = new("TextLabel", {
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.62),
		Size = UDim2.fromScale(0.7, 0.13),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = MYSTERY_NAME,
		TextColor3 = WHITE,
		TextScaled = true,
		TextTransparency = 1,
		Rotation = -3,
		ZIndex = 10,
		Parent = hud,
	})
	local titleGradient = new("UIGradient", { Rotation = 90, Parent = title })
	local titleStroke = new("UIStroke", { Thickness = 5, Transparency = 1, Parent = title })
	local titleScale = new("UIScale", { Scale = 1, Parent = title })
	-- Keep the stroke in step with the text's fade.
	title:GetPropertyChangedSignal("TextTransparency"):Connect(function()
		titleStroke.Transparency = title.TextTransparency
	end)

	-- The big "???" across the silhouette's face during the WHO? phase.
	local mystery = new("TextLabel", {
		Name = "Mystery",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.36),
		Size = UDim2.fromScale(0.5, 0.14),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = MYSTERY_NAME,
		TextColor3 = WHITE,
		TextScaled = true,
		TextTransparency = 1,
		ZIndex = 9,
		Parent = hud,
	})
	local mysteryGradient = new("UIGradient", { Rotation = 90, Parent = mystery })
	local mysteryStroke = new("UIStroke", { Thickness = 6, Transparency = 1, Parent = mystery })
	local mysteryScale = new("UIScale", { Scale = MYSTERY_SCALE, Parent = mystery })
	mystery:GetPropertyChangedSignal("TextTransparency"):Connect(function()
		mysteryStroke.Transparency = mystery.TextTransparency
	end)

	local function sub(y: number, h: number, text: string, textColor: Color3): (TextLabel, UIScale)
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
			Parent = hud,
		})
		local stroke = new("UIStroke", { Thickness = 2.5, Transparency = 1, Parent = label })
		label:GetPropertyChangedSignal("TextTransparency"):Connect(function()
			stroke.Transparency = label.TextTransparency
		end)
		return label, new("UIScale", { Parent = label })
	end
	-- The name ("???" until the reveal) in the rarity's moving gradient, without its size
	-- ("Diamond Huge X" -> "Diamond X"): the size gets a line of its own under the info line.
	local name, nameScale = sub(0.735, 0.075, MYSTERY_NAME, WHITE)
	if hero then
		HeroConfig.PaintRarityGradient(name, hero.Rarity)
	end
	local info, infoScale = sub(0.8, 0.045, MYSTERY_INFO, WHITE)
	local sizeLabel: TextLabel? = nil
	local sizeScale: UIScale? = nil
	if hero and hero.Size and HeroConfig.SizeBadgeFX[hero.Size] then
		local label, scale = sub(0.857, 0.05, string.upper(hero.Size), WHITE)
		HeroConfig.PaintRarityGradient(label, hero.Size) -- SizeBadgeFX colours, animated like rarities
		sizeLabel = label
		sizeScale = scale
	end

	local hint = new("TextLabel", {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -10),
		Size = UDim2.fromScale(0.2, 0.03),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = "",
		TextColor3 = Color3.fromRGB(170, 170, 170),
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTransparency = 1,
		ZIndex = 6,
		Parent = hud,
	})

	-- Phase tracker in the top bar: one segment per phase, the running one fills up.
	local tracker = new("CanvasGroup", {
		Name = "Phases",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.058),
		Size = UDim2.fromScale(0.56, 0.07),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		ZIndex = 6,
		Parent = hud,
	})
	local segments: { Segment } = {}
	local gap = 0.02
	local width = (1 - gap * (#PHASES - 1)) / #PHASES
	for i, phase in PHASES do
		local seg = new("Frame", {
			Position = UDim2.fromScale((i - 1) * (width + gap), 0),
			Size = UDim2.fromScale(width, 1),
			BackgroundTransparency = 1,
			Parent = tracker,
		})
		local label = new("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.36),
			Size = UDim2.fromScale(1, 0.66),
			BackgroundTransparency = 1,
			Font = FONT,
			Text = phase.Label,
			TextColor3 = WHITE,
			TextScaled = true,
			TextTransparency = 0.6,
			Parent = seg,
		})
		new("UITextSizeConstraint", { MaxTextSize = 26, Parent = label })
		local track = new("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.fromScale(1, 0.16),
			BackgroundColor3 = WHITE,
			BackgroundTransparency = 0.78,
			BorderSizePixel = 0,
			Parent = seg,
		})
		new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = track })
		local fill = new("Frame", {
			Size = UDim2.fromScale(0, 1),
			BackgroundColor3 = WHITE,
			BorderSizePixel = 0,
			Visible = false,
			Parent = track,
		})
		new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fill })
		table.insert(segments, { label = label, scale = new("UIScale", { Parent = label }), fill = fill })
	end

	-- What is going on, in the bottom bar.
	local caption = new("TextLabel", {
		Name = "Caption",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.945),
		Size = UDim2.fromScale(0.5, 0.042),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = "",
		TextColor3 = Color3.fromRGB(235, 235, 235),
		TextScaled = true,
		TextTransparency = 1,
		ZIndex = 6,
		Parent = hud,
	})
	new("UITextSizeConstraint", { MaxTextSize = 30, Parent = caption })

	gui.Parent = player:WaitForChild("PlayerGui")
	return {
		gui = gui,
		hud = hud,
		barTop = barTop,
		barBottom = barBottom,
		flash = flash,
		fade = fade,
		title = title,
		titleScale = titleScale,
		titleGradient = titleGradient,
		titleStroke = titleStroke,
		mystery = mystery,
		mysteryScale = mysteryScale,
		mysteryGradient = mysteryGradient,
		mysteryStroke = mysteryStroke,
		name = name,
		nameScale = nameScale,
		info = info,
		infoScale = infoScale,
		size = sizeLabel,
		sizeScale = sizeScale,
		hint = hint,
		tracker = tracker,
		segments = segments,
		caption = caption,
	}
end

-- One of the question marks circling the silhouette: a label on the HUD that follows a point in
-- the world (drawn over everything, the silhouette's highlight included).
type Mark = {
	label: TextLabel,
	stroke: UIStroke,
	studs: number, -- height in the world
	angle: number, -- where on its circle it starts
	speed: number, -- radians per second around the hero
	radius: number, -- circle radius, in hero heights
	y: number, -- height above the hero's middle, in hero heights
}

local function run(drop: Drop, origin: Vector3, groundY: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local color = DropFX.RarityColor(drop.Rarity)
	local hero = HeroConfig.Get(drop.Name)
	local fullName = if hero then HeroConfig.DisplayName(hero) else drop.Name
	local glyphs = splitGlyphs(fullName)
	local hiddenName = {} -- "?????? ???????": the name's shape, nothing more
	for i, g in glyphs do
		hiddenName[i] = if g == " " then " " else "?"
	end
	local chanceText = DropFX.FormatChance(drop.Chance)
	local touch = UserInputService.TouchEnabled

	-- Timeline (cutscene clock `t`).
	local ladder = rarityLadder(drop.Rarity)
	local tSignal = T_SIGNAL -- the climb starts
	local tLock = tSignal + #ladder * T_STEP -- rarity locked = the hero lands
	local tFall = tLock - FALL_TIME
	local tReveal = tLock + T_MYSTERY
	local tOrbit = tReveal + T_CLOSE
	local tOutro = tOrbit + T_ORBIT
	local tEnd = tOutro + T_OUTRO
	local phaseStart = { 0, tSignal, tLock, tReveal, tOutro } -- [i] .. [i + 1] = phase i
	local tDecode = tReveal + 0.15 -- the name starts decoding
	local decodeTime = math.min(0.25 + 0.06 * #glyphs, 0.9)
	local tCount = tReveal + 0.5 -- power starts counting up
	local countTime = 0.6
	local tSize = tReveal + 1.0 -- the size line pops in

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
	local ui = buildUi(hero)
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

	-- Coloured vignette: the screen edges glow in a deep shade of the current colour (not black),
	-- and close in with every heartbeat.
	local vignette = new("CanvasGroup", {
		Name = "Vignette",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		ZIndex = 4,
		Parent = ui.gui,
	})
	local edges: { Frame } = {}
	local edgeFade = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1) })
	for _, e in { { 0, 0, 0.32, 1, 0 }, { 1, 0, 0.32, 1, 180 }, { 0, 0, 1, 0.38, 90 }, { 0, 1, 1, 0.38, 270 } } do
		local f = new("Frame", {
			AnchorPoint = Vector2.new(e[1], e[2]),
			Position = UDim2.fromScale(e[1], e[2]),
			Size = UDim2.fromScale(e[3], e[4]),
			BorderSizePixel = 0,
			Parent = vignette,
		})
		new("UIGradient", { Rotation = e[5], Transparency = edgeFade, Parent = f })
		table.insert(edges, f)
	end

	-- Opening: letterbox in, the phase tracker and the skip hint fade in.
	tween(ui.barTop, 0.5, { Size = UDim2.fromScale(1, 0.11) })
	tween(ui.barBottom, 0.5, { Size = UDim2.fromScale(1, 0.11) })
	ui.hint.Text = if touch then "Tap to reveal" else "Click to reveal"
	tween(ui.hint, 0.4, { TextTransparency = 0.3 })
	task.delay(0.25, function()
		tween(ui.tracker, 0.35, { GroupTransparency = 0 })
	end)
	tween(dof, tLock, { FarIntensity = 0.15 }, Enum.EasingStyle.Sine)
	playSound(TreeConfig.CutsceneSounds.Charge, 0.8)

	-- Pillar of light + inward sparkles at the tree.
	local pillar = neonPart(UNKNOWN_COLOR, { Transparency = 0.15, Size = Vector3.new(0.1, 1.5, 1.5) })
	pillar.Parent = fxFolder
	table.insert(cleanup, pillar)
	local baseRing = neonPart(UNKNOWN_COLOR, { Transparency = 0.35, Size = Vector3.new(0.15, 3, 3) })
	baseRing.CFrame = CFrame.new(feet + up * 0.1) * CFrame.Angles(0, 0, math.pi / 2)
	baseRing.Parent = fxFolder
	table.insert(cleanup, baseRing)
	local chargeAtt = new("Attachment", { Parent = baseRing })
	local chargeEmitter = new("ParticleEmitter", {
		Texture = SPARKLE_TEXTURE,
		LightEmission = 1,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) }),
		Lifetime = NumberRange.new(0.6, 1.1),
		Rate = 60,
		Speed = NumberRange.new(10, 18),
		SpreadAngle = Vector2.new(25, 25),
		EmissionDirection = Enum.NormalId.Right, -- the cylinder's X axis points up
		Parent = chargeAtt,
	})

	-- State ----------------------------------------------------------------------------------------
	local heroHeight = 5
	local head: BasePart? = nil
	local heroVisual: DropFX.HeroVisual? = nil
	local highlight: Highlight? = nil
	local marks: { Mark } = {}
	local cur = UNKNOWN_COLOR -- colour on screen right now, eases towards `target`
	local target = UNKNOWN_COLOR
	local phase = 0
	local step = 0 -- ladder tiers shown so far
	local titleShown = false
	local mysteryShown = false
	local spawned = false
	local locked = false
	local revealed = false
	local orbitStarted = false
	local outroStarted = false
	local finished = false
	local nameDone = false
	local countStarted = false
	local countDone = false
	local sizeShown = false
	local lastScramble = -1
	local nextBeat = 0.2
	local pulse = 0 -- 1 on every heartbeat, decays
	local kick = 0 -- 1 on every rarity tier, decays (extra zoom punch)
	local t = 0
	local shake = 0

	local function heroFocus(heightShare: number): Vector3
		return feet + up * heroHeight * heightShare
	end

	-- Everything in the world that carries the current colour.
	local function paintWorld(c: Color3)
		pillar.Color = c
		baseRing.Color = c
		chargeEmitter.Color = ColorSequence.new(c:Lerp(WHITE, 0.4), c)
		local edge = c:Lerp(BLACK, 0.3)
		for _, f in edges do
			f.BackgroundColor3 = edge
		end
		if highlight then
			highlight.OutlineColor = c:Lerp(WHITE, 0.35)
		end
	end
	paintWorld(cur)

	local function paintTitle(text: string, c: Color3)
		ui.title.Text = text
		ui.titleGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, WHITE),
			ColorSequenceKeypoint.new(0.45, c:Lerp(WHITE, 0.35)),
			ColorSequenceKeypoint.new(1, c),
		})
		ui.titleStroke.Color = c:Lerp(BLACK, 0.75)
		ui.title.TextTransparency = 0
	end

	local function punch(scale: UIScale, from: number, time: number?)
		scale.Scale = from
		tween(scale, time or 0.35, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end

	local function flashScreen(c: Color3, transparency: number, time: number)
		ui.flash.BackgroundColor3 = WHITE:Lerp(c, 0.2)
		ui.flash.BackgroundTransparency = transparency
		tween(ui.flash, time, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end

	-- Shockwave ring on the ground.
	local function ringWave(c: Color3, size: number, time: number)
		local wave = neonPart(c, { Transparency = 0.2, Size = Vector3.new(0.12, 4, 4) })
		wave.CFrame = CFrame.new(feet + up * 0.15) * CFrame.Angles(0, 0, math.pi / 2)
		wave.Parent = fxFolder
		table.insert(cleanup, wave)
		tween(wave, time, { Size = Vector3.new(0.12, size, size), Transparency = 1 }, Enum.EasingStyle.Quart)
	end

	local function setPhase(i: number)
		if phase >= i then
			return
		end
		phase = i
		punch(ui.segments[i].scale, 1.35, 0.4)
		ui.caption.Text = PHASES[i].Caption
		ui.caption.TextTransparency = 1
		tween(ui.caption, 0.3, { TextTransparency = 0.05 })
	end
	setPhase(1)

	-- Phase 1: the title shows up as "???".
	local function showUnknownTitle()
		titleShown = true
		if step == 0 then
			paintTitle(MYSTERY_NAME, UNKNOWN_COLOR)
			ui.title.Rotation = 0
			punch(ui.titleScale, 0.4, 0.4)
		end
	end

	-- Phase 2: one tier up the ladder. "EPIC?" = it may still go higher.
	local function climbStep(i: number)
		setPhase(2)
		local tier = ladder[i]
		local c = DropFX.RarityColor(tier)
		target = c
		paintTitle(string.upper(tier) .. "?", c)
		ui.title.Rotation = if i % 2 == 0 then 3 else -3
		punch(ui.titleScale, 1.75)
		flashScreen(c, 0.5, 0.3)
		ringWave(c, 16 + 6 * i, 0.6)
		pulse = 1
		kick = 1
		playSound(TreeConfig.CutsceneSounds.Step, 0.8, 1 + 0.12 * (i - 1))
	end

	-- The hero, as a black silhouette, shoots down the pillar of light.
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
			FillColor = BLACK,
			FillTransparency = 0,
			OutlineColor = cur:Lerp(WHITE, 0.35),
			OutlineTransparency = 0,
			-- Drawn through the light around it until the reveal.
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

	-- Question marks circling the silhouette.
	local function spawnMarks()
		for i = 1, MARK_COUNT do
			local label = new("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundTransparency = 1,
				Font = FONT,
				Text = "?",
				TextColor3 = WHITE,
				TextScaled = true,
				Visible = false,
				ZIndex = 8,
				Parent = ui.hud,
			})
			new("UIGradient", { Rotation = 90, Color = ColorSequence.new(WHITE, color:Lerp(WHITE, 0.25)), Parent = label })
			local stroke = new("UIStroke", { Thickness = 2.5, Color = color:Lerp(BLACK, 0.75), Parent = label })
			local pop = new("UIScale", { Scale = 0, Parent = label })
			task.delay(i * 0.06, function()
				if pop.Parent then
					tween(pop, 0.35, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
				end
			end)
			table.insert(marks, {
				label = label,
				stroke = stroke,
				studs = heroHeight * (0.2 + 0.12 * math.random()),
				angle = i / MARK_COUNT * math.pi * 2,
				speed = (if i % 2 == 0 then 1 else -1) * (1.1 + 0.7 * math.random()),
				radius = 0.55 + 0.2 * math.random(),
				y = -0.3 + 0.7 * math.random(),
			})
		end
	end

	-- Call after the camera is placed. `rush` pulls them in before the reveal; after it they fly
	-- apart and fade. The ones behind the hero are dimmer.
	local function updateMarks(rush: number)
		if #marks == 0 then
			return
		end
		local h = heroHeight
		local center = heroFocus(0.5)
		local burst = if revealed then easeOut((t - tReveal) / 0.5) else 0
		local pull = 1 - 0.6 * rush * rush
		local pixelsPerStud = camera.ViewportSize.Y / (2 * math.tan(math.rad(camera.FieldOfView) / 2)) -- at depth 1
		local heroDepth = camera:WorldToViewportPoint(center).Z
		for _, m in marks do
			local a = m.angle + t * m.speed
			local r = h * m.radius * pull * (1 + 3 * burst)
			local world = center + Vector3.new(
				math.cos(a) * r,
				h * m.y * pull + math.sin(t * 2 + m.angle) * h * 0.06 + burst * h * 0.5,
				math.sin(a) * r
			)
			local point = camera:WorldToViewportPoint(world)
			if point.Z > 0.5 then
				local size = m.studs * pixelsPerStud / point.Z
				local dim = if point.Z > heroDepth then 0.5 else 0
				local transparency = 1 - (1 - dim) * (1 - burst)
				m.label.Visible = true
				m.label.Position = UDim2.fromOffset(point.X, point.Y)
				m.label.Size = UDim2.fromOffset(size, size)
				m.label.Rotation = math.sin(t * 3 + m.angle) * 14
				m.label.TextTransparency = transparency
				m.stroke.Transparency = transparency
			else
				m.label.Visible = false
			end
		end
		if burst >= 1 then
			for _, m in marks do
				m.label:Destroy()
			end
			table.clear(marks)
		end
	end

	-- A moment after the lock: the big "???" stamps itself over the silhouette.
	local function showMystery()
		mysteryShown = true
		ui.mysteryGradient.Color = ColorSequence.new(WHITE, color:Lerp(WHITE, 0.45))
		ui.mysteryStroke.Color = color:Lerp(BLACK, 0.8)
		ui.mystery.TextTransparency = 0
		ui.mysteryScale.Scale = MYSTERY_SCALE * 2.4
		tween(ui.mysteryScale, 0.35, { Scale = MYSTERY_SCALE }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end

	-- Phase 3: the rarity locks as the hero lands. It stays a silhouette: "???".
	local function lock()
		locked = true
		setPhase(3)
		cur = color
		target = color
		paintWorld(color)
		paintTitle(string.upper(drop.Rarity) .. "!", color)
		ui.title.Rotation = -3
		punch(ui.titleScale, 2.6, 0.45)
		flashScreen(color, 0.1, 0.45) -- also hides the cut to the next shot
		playSound(TreeConfig.CutsceneSounds.Lock, 1)
		shake = 1.3
		pulse = 1
		nextBeat = tLock + 0.35

		-- Impact: dust thrown out from the landing spot, shockwave on the ground.
		placeFallingHero()
		local dustAtt = new("Attachment", { Parent = baseRing })
		local dust = new("ParticleEmitter", {
			Texture = SPARKLE_TEXTURE,
			Color = ColorSequence.new(WHITE, color),
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
		ringWave(WHITE, 46, 0.9)
		chargeEmitter.Rate = 25
		chargeEmitter.Speed = NumberRange.new(4, 9)

		-- The unknown hero's card: question marks where its name and numbers will be.
		spawnMarks()
		ui.name.Text = table.concat(hiddenName)
		ui.name.TextTransparency = 0
		punch(ui.nameScale, 2.2, 0.4)
		ui.info.Text = MYSTERY_INFO
		ui.info.TextColor3 = color:Lerp(WHITE, 0.25)
		tween(ui.info, 0.4, { TextTransparency = 0 })
	end

	-- Phase 4: the silhouette burns away.
	local function reveal()
		revealed = true
		setPhase(4)
		cur = color
		target = color
		paintWorld(color)
		ui.hint.Text = if touch then "Tap to skip" else "Click to skip"
		playSound(TreeConfig.CutsceneSounds.Reveal, 1)
		-- White flash, then a bright, saturated grade with a touch of the rarity colour.
		flashScreen(color, 0, 0.55)
		cc.Saturation = 0.4
		cc.Contrast = 0.12
		cc.Brightness = 0.25
		cc.TintColor = WHITE:Lerp(color, 0.08)
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
		pulse = 0

		-- The big "???" blows up and is gone.
		tween(ui.mysteryScale, 0.35, { Scale = MYSTERY_SCALE * 3 })
		tween(ui.mystery, 0.3, { TextTransparency = 1 })

		-- Card: the rarity line punches again; the name and numbers decode in the render loop.
		ui.title.Rotation = -3
		punch(ui.titleScale, 1.35)
		ui.name.Rotation = 0
		ui.nameScale.Scale = 1

		-- The silhouette turns white-hot and fades to the real hero; its outline stays a while longer.
		if highlight then
			highlight.FillColor = WHITE
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
			tween(highlight, 0.8, { FillTransparency = 1 })
			task.delay(2.2, function()
				if highlight and highlight.Parent then
					tween(highlight, 1, { OutlineTransparency = 1 })
				end
			end)
		end

		-- The light bursts outward and fades; shockwave ring on the ground.
		chargeEmitter.Enabled = false
		local w = pillar.Size.Y
		tween(pillar, 0.45, { Size = Vector3.new(pillar.Size.X, w * 3.5, w * 3.5), Transparency = 1 })
		tween(baseRing, 0.7, { Size = Vector3.new(0.15, 34, 34), Transparency = 1 }, Enum.EasingStyle.Quart)
		ringWave(WHITE, 46, 0.9)

		-- Sparks thrown out of the hero, then a steady aura and the spinning rays behind it.
		local visual = heroVisual
		if visual then
			local burstAtt = new("Attachment", { Position = Vector3.new(0, heroHeight / 2 - visual.bottom, 0), Parent = visual.root })
			local sparks = new("ParticleEmitter", {
				Texture = SPARKLE_TEXTURE,
				Color = ColorSequence.new(WHITE, color),
				LightEmission = 1,
				Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.1), NumberSequenceKeypoint.new(1, 0) }),
				Transparency = NumberSequence.new(0, 1),
				Lifetime = NumberRange.new(0.5, 1),
				Speed = NumberRange.new(14, 28),
				SpreadAngle = Vector2.new(180, 180),
				Drag = 3,
				Enabled = false,
				Parent = burstAtt,
			})
			sparks:Emit(70)
			local glow = new("PointLight", { Color = color, Range = 18, Brightness = 3, Parent = visual.root })
			tween(glow, 1.5, { Brightness = 1.2 })
			local auraAtt = new("Attachment", { Position = Vector3.new(0, -visual.bottom + 0.2, 0), Parent = visual.root })
			new("ParticleEmitter", {
				Texture = SPARKLE_TEXTURE,
				Color = ColorSequence.new(color:Lerp(WHITE, 0.5), color),
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

	-- The name resolves left to right out of scrambled glyphs; power counts up; the size pops in.
	local function updateCard()
		if not nameDone and t >= tDecode then
			local k = (t - tDecode) / decodeTime
			if k >= 1 then
				nameDone = true
				ui.name.Text = fullName
				punch(ui.nameScale, 1.25, 0.3)
			elseif t - lastScramble >= SCRAMBLE_EVERY or t < lastScramble then
				lastScramble = t
				local shown = math.floor(k * #glyphs)
				local out = table.create(#glyphs)
				for i, g in glyphs do
					out[i] = if i <= shown or g == " " then g else SCRAMBLE[math.random(#SCRAMBLE)]
				end
				ui.name.Text = table.concat(out)
			end
		end
		if not countDone and t >= tCount then
			if not countStarted then
				countStarted = true
				punch(ui.infoScale, 1.3, 0.3)
			end
			local k = (t - tCount) / countTime
			local power = "?"
			if hero then
				power = HeroConfig.Abbreviate(hero.MinePower * easeOut(k))
			end
			ui.info.Text = ("Power %s   •   %s chance"):format(power, chanceText)
			ui.info.TextTransparency = 0
			countDone = k >= 1
		end
		if not sizeShown and t >= tSize then
			sizeShown = true
			if ui.size and ui.sizeScale then
				tween(ui.size, 0.3, { TextTransparency = 0 })
				punch(ui.sizeScale, 1.8, 0.4)
			end
		end
	end

	local function startOutro()
		outroStarted = true
		t = math.max(t, tOutro)
		tween(ui.fade, T_OUTRO * 0.8, { BackgroundTransparency = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end

	-- Skip ---------------------------------------------------------------------------------------
	-- The first press jumps to the reveal (the render loop catches up on every step in between),
	-- the next one ends the cutscene.
	local lastSkip = 0
	local skipConn = UserInputService.InputBegan:Connect(function(input, _processed)
		if t < SKIP_AFTER or outroStarted or os.clock() - lastSkip < SKIP_COOLDOWN then
			return
		end
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.Return
			or input.KeyCode == Enum.KeyCode.ButtonA then
			lastSkip = os.clock()
			if revealed then
				startOutro()
			else
				t = math.max(t, tReveal)
			end
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

	-- Looks from the hero back to where the camera wants to be. Small things in between (pad heroes,
	-- fences, signs) are hidden locally; a wall or the ground can't be, so the camera stops just in
	-- front of it instead of ending up inside. Returns where the camera may stand.
	local MAX_OCCLUDER = 40 -- studs; bigger parts (ground, walls of the map) block the camera
	local occluders: { [BasePart]: boolean } = {}
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local function clearView(pos: Vector3, subject: Vector3): Vector3
		local ignore: { Instance } = { fxFolder }
		if character then
			table.insert(ignore, character)
		end
		local offset = pos - subject
		if offset.Magnitude < 0.5 then
			return pos
		end
		for _ = 1, 8 do
			rayParams.FilterDescendantsInstances = ignore
			local hit = workspace:Raycast(subject, offset, rayParams)
			if not hit then
				return pos
			end
			local part = hit.Instance
			table.insert(ignore, part)
			if part.Transparency >= 0.95 then
				continue -- invisible (triggers, barriers): nothing in the way
			end
			if part.Size.Magnitude > MAX_OCCLUDER then
				local dist = (hit.Position - subject).Magnitude
				return subject + offset.Unit * math.max(dist - 1, 1.5)
			end
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
		return pos
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
	local function clearActors(camPos: Vector3, lookAt: Vector3)
		local targetDist = (lookAt - camPos).Magnitude
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

	-- One shot per phase; the flashes at the lock and at the reveal hide the cuts.
	local function shot(rush: number): (Vector3, Vector3, number)
		if not locked then
			-- SIGNAL + RARITY: wide dolly in towards the growing pillar.
			local a = easeInOut(t / tLock)
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
			return pos, look, lerp(startFov, 52, a) - 4 * kick
		elseif not revealed then
			-- WHO?: low, from the silhouette's side, creeping around to its front and closing in.
			local e = easeInOut((t - tLock) / T_MYSTERY)
			local h = heroHeight
			local around = CFrame.Angles(0, lerp(1.15, 0.3, e), 0):VectorToWorldSpace(dir)
			local pos = feet + around * lerp(h * 2.1, h * 1.5, e) + up * lerp(h * 0.2, h * 0.34, e)
			return pos, heroFocus(0.6), lerp(50, 45, e) - 8 * rush * rush
		elseif t < tOrbit then
			-- REVEAL: low-angle close-up, slow push in.
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

		-- Timeline. In order, so a skip that jumps the clock ahead still goes through every step.
		if not outroStarted then
			if not titleShown and t >= 0.35 then
				showUnknownTitle()
			end
			while step < #ladder and t >= tSignal + step * T_STEP do
				step += 1
				climbStep(step)
			end
			if not spawned and t >= tFall then
				spawnHero()
			end
			if spawned and not locked then
				placeFallingHero()
			end
			if not locked and t >= tLock then
				lock()
			end
			if not mysteryShown and t >= tLock + 0.15 then
				showMystery()
			end
			if not revealed and t >= tReveal then
				reveal()
			end
			if not orbitStarted and t >= tOrbit then
				orbitStarted = true
				shake = math.max(shake, 0.4)
			end
			if t >= tOutro then
				startOutro()
			end
		end
		if t >= tEnd then
			finished = true
		end

		pulse = math.max(pulse - dt * 5, 0)
		kick = math.max(kick - dt * 4, 0)
		local fovKick = 0
		local rush = 0
		if not revealed then
			-- The colour on screen eases to the current tier's.
			if cur ~= target then
				cur = cur:Lerp(target, 1 - math.exp(-dt * 10))
				paintWorld(cur)
			end
			if not locked then
				-- SIGNAL + RARITY: the pillar grows and everything throbs to a heartbeat that keeps
				-- speeding up.
				local a = clamp01(t / tLock)
				if t >= nextBeat then
					pulse = 1
					nextBeat += lerp(0.55, 0.16, a)
				end
				-- Shoots up fast (a beacon right from the start), then keeps creeping higher.
				local height = lerp(2, 70, 1 - (1 - a) ^ 2.5)
				local width = lerp(1.2, 3.2, a) + pulse * 1.4
				pillar.Size = Vector3.new(height, width, width)
				pillar.CFrame = CFrame.new(feet + up * height / 2) * CFrame.Angles(0, 0, math.pi / 2)
				-- Thinner glow while the hero shoots down it, so the silhouette reads.
				pillar.Transparency = if spawned then 0.6 else 0.25 - 0.2 * pulse
				local ringSize = lerp(3, 9, a) + pulse * 2.5
				baseRing.Size = Vector3.new(0.15, ringSize, ringSize)
				-- Bright and colourful, never dark: a tint that swells with each beat.
				cc.Saturation = lerp(0.15, 0.3, a)
				cc.Contrast = lerp(0.05, 0.18, a)
				cc.Brightness = 0.03 + 0.12 * pulse
				cc.TintColor = WHITE:Lerp(cur, 0.03 + 0.06 * a + 0.05 * pulse)
				bloom.Intensity = 0.25 + 0.25 * a + 0.4 * pulse
				sunRays.Intensity = 0.04 + 0.1 * pulse
				vignette.GroupTransparency = math.clamp(lerp(0.85, 0.5, a) - 0.2 * pulse, 0.3, 1)
				fovKick = -3 * pulse
				shake = 0.06 + 0.3 * a * a + 0.25 * pulse
				-- The unknown title breathes with the beat.
				if step == 0 and titleShown then
					ui.title.Rotation = math.sin(t * 7) * 2
				end
			else
				-- WHO?: the silhouette stands in a wide column of light, the world washed in the
				-- rarity colour. The heartbeat races, then everything rushes in.
				local m = clamp01((t - tLock) / T_MYSTERY)
				rush = clamp01((t - (tReveal - T_RUSH)) / T_RUSH)
				if t >= nextBeat then
					pulse = 1
					nextBeat += lerp(0.5, 0.12, m)
				end
				local h = heroHeight
				local width = h * 1.05 + pulse * 0.9 - h * 0.5 * rush
				pillar.Size = Vector3.new(70, width, width)
				pillar.CFrame = CFrame.new(feet + up * 35) * CFrame.Angles(0, 0, math.pi / 2)
				pillar.Transparency = 0.8 - 0.12 * pulse - 0.3 * rush
				local ringSize = h * 1.6 + pulse * 2 - h * 0.6 * rush
				baseRing.Size = Vector3.new(0.15, ringSize, ringSize)
				baseRing.Transparency = 0.35
				cc.Saturation = 0.1
				cc.Contrast = 0.2
				cc.Brightness = 0.02 + 0.08 * pulse + 0.35 * rush * rush
				cc.TintColor = WHITE:Lerp(cur, 0.16 + 0.05 * pulse)
				bloom.Intensity = 0.45 + 0.35 * pulse + 0.6 * rush
				sunRays.Intensity = 0.05 + 0.1 * pulse
				vignette.GroupTransparency = math.clamp(0.42 - 0.15 * pulse - 0.2 * rush, 0.1, 1)
				fovKick = -2.5 * pulse
				shake = math.max(shake - dt * 1.6, 0.05 + 0.18 * m * m + 0.15 * pulse + 0.45 * rush)
				-- The question marks throb with the beat and wobble (once their pop-in is over), and
				-- swell in the final rush.
				if t >= tLock + 0.45 then
					ui.nameScale.Scale = 1 + 0.08 * pulse
				end
				if t >= tLock + 0.55 then
					ui.mysteryScale.Scale = MYSTERY_SCALE * (1 + 0.1 * pulse + 0.25 * rush * rush)
				end
				ui.mystery.Rotation = math.sin(t * 5) * 3
			end
		else
			shake = math.max(shake - dt * 1.6, 0.03)
			updateCard()
		end

		-- Phase tracker: done segments full, the running one fills up.
		for i, seg in ui.segments do
			local k = clamp01((t - phaseStart[i]) / (phaseStart[i + 1] - phaseStart[i]))
			seg.fill.Visible = k > 0
			seg.fill.Size = UDim2.fromScale(k, 1)
			seg.fill.BackgroundColor3 = cur
			seg.label.TextColor3 = if i < phase then cur:Lerp(WHITE, 0.35) else WHITE
			seg.label.TextTransparency = if i == phase then 0 elseif i < phase then 0.15 else 0.6
		end

		local pos, look, fov = shot(rush)
		fov += fovKick
		-- Keep the view of the hero clear. Eased in while the shot still blends out of the player's
		-- own camera, so the cutscene never starts with a jump.
		local clear = clearView(pos, feet + up * math.max(heroHeight * 0.6, 3))
		pos = pos:Lerp(clear, easeOut(t / 0.5))
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
			clearActors(pos, feet + up * heroHeight * 0.5)
		end
		for p in occluders do
			p.LocalTransparencyModifier = 1
		end
		updateMarks(rush)
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
	ui.hud.Visible = false
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
