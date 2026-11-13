-- HeroModels: builds the NPC models heroes work with (HeroWorkerService).
--
--   HeroModels.Clone(heroName)            -> model, humanoid, root   (not parented)
--   HeroModels.GiveAxe(model, humanoid)    puts ServerStorage.WoodenAxe in the hero's right hand
--   HeroModels.Anims(humanoid)             -> { Idle, Walk, Hold } animation ids for this rig
--   HeroModels.LoadTrack(humanoid, id, priority, looped) -> AnimationTrack?
--   HeroModels.ChopAnimationId()           -> id for the swing (HeroConfig.Worker.ChopAnimation, or the
--                                             KeyframeSequence registered for Studio playtests)
--   HeroModels.RunAnimationId()            -> id for the run (HeroConfig.Worker.RunAnimation, same fallback)
--
-- The template's "Animate" LocalScript is removed (it never runs on an NPC); its idle / walk / toolnone
-- ids are kept as attributes on the Humanoid. Every part is made non-collidable and non-queryable so
-- heroes never block players or their clicks on trees.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))

local AXE_NAME = "WoodenAxe"

-- Roblox default animations, used when a template has no Animate script.
local DEFAULTS = {
	[Enum.HumanoidRigType.R6] = {
		Idle = "rbxassetid://180435792",
		Walk = "rbxassetid://180426354",
		Hold = "rbxassetid://182393478",
	},
	[Enum.HumanoidRigType.R15] = {
		Idle = "rbxassetid://507766388",
		Walk = "rbxassetid://913402848",
		Hold = "rbxassetid://507768375",
	},
}

local HeroModels = {}

local function templateFor(heroName: string): Model?
	local model = HeroConfig.GetTemplate(heroName)
	if model then
		return model
	end
	local folder = ReplicatedStorage:FindFirstChild(HeroConfig.TemplateFolder)
	local fallback = folder and folder:FindFirstChild(HeroConfig.FallbackTemplate)
	return if fallback and fallback:IsA("Model") then fallback else nil
end

local function animId(animate: Instance?, child: string): string?
	local value = animate and animate:FindFirstChild(child)
	local anim = value and value:FindFirstChildOfClass("Animation")
	return if anim and anim.AnimationId ~= "" then anim.AnimationId else nil
end

-- Sparkles in the mutation's colour around a mutated hero (Rainbow cycles through its palette), and
-- the name on its bar tinted the same. Particles instead of a Highlight: a client can only show 31
-- Highlights at once and a plot can have many mutated heroes.
function HeroModels.AddMutationFX(model: Model, root: BasePart, heroName: string)
	local def = HeroConfig.Get(heroName)
	local mutation = def and def.Mutation and HeroConfig.Mutations[def.Mutation]
	if not def or not mutation then
		return
	end
	model:SetAttribute("Mutation", def.Mutation)
	local colors = mutation.Colors
	local sequence: ColorSequence
	if colors and #colors > 1 then
		local points = {}
		for i, c in colors do
			table.insert(points, ColorSequenceKeypoint.new((i - 1) / (#colors - 1), c))
		end
		sequence = ColorSequence.new(points)
	else
		sequence = ColorSequence.new(mutation.Color)
	end
	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Name = "MutationSparkles"
	sparkles.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkles.Color = sequence
	sparkles.LightEmission = 0.8
	sparkles.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	sparkles.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	sparkles.Lifetime = NumberRange.new(0.8, 1.4)
	sparkles.Rate = 6
	sparkles.Speed = NumberRange.new(0.5, 1.5)
	sparkles.SpreadAngle = Vector2.new(180, 180)
	sparkles.Parent = root

	local attachment = root:FindFirstChild("InfoAttachment")
	local bar = attachment and attachment:FindFirstChild("HeroBar")
	local container = bar and bar:FindFirstChild("Container")
	local nameLabel = container and container:FindFirstChild("HeroName")
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.TextColor3 = mutation.Color
	end
end

-- The size badge ("HUGE", ...) of a sized hero, just above the top line of its HeroBar. The bar's
-- Container stacks its labels in the middle (UIListLayout), so its text reaches half the stack's
-- height above the bar's centre.
local function drawSizeBadge(root: BasePart, size: string)
	local attachment = root:FindFirstChild("InfoAttachment")
	local bar = attachment and attachment:FindFirstChild("HeroBar")
	local container = bar and bar:FindFirstChild("Container")
	if not bar or not bar:IsA("BillboardGui") or not container or not container:IsA("GuiObject") then
		return
	end
	local layout = container:FindFirstChildOfClass("UIListLayout")
	local stack, count = 0, 0
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") and child.Visible then
			stack += child.Size.Y.Scale
			count += 1
		end
	end
	if layout then
		stack += layout.Padding.Scale * math.max(0, count - 1)
	end
	local containerStuds = bar.Size.Y.Scale * container.Size.Y.Scale
	local nameLabel = container:FindFirstChild("HeroName")
	local font = if nameLabel and nameLabel:IsA("TextLabel") then nameLabel.FontFace else nil
	HeroConfig.PaintSizeBadge(bar, stack * containerStuds / 2, size, font)
end

function HeroModels.Clone(heroName: string): (Model?, Humanoid?, BasePart?)
	local template = templateFor(heroName)
	if not template then
		warn(("[HeroModels] no model for hero %q"):format(heroName))
		return nil, nil, nil
	end
	local model = template:Clone()
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root then
		warn(("[HeroModels] %s has no Humanoid / HumanoidRootPart"):format(template.Name))
		model:Destroy()
		return nil, nil, nil
	end

	local animate = model:FindFirstChild("Animate")
	humanoid:SetAttribute("IdleAnim", animId(animate, "idle"))
	humanoid:SetAttribute("WalkAnim", animId(animate, "walk"))
	humanoid:SetAttribute("HoldAnim", animId(animate, "toolnone"))
	if animate then
		animate:Destroy()
	end

	model.PrimaryPart = root
	model:SetAttribute("Hero", heroName)

	-- The bar above the hero (HumanoidRootPart.InfoAttachment.HeroBar): name, rarity, power.
	local def = HeroConfig.Get(heroName)
	local container = def and root:FindFirstChild("InfoAttachment")
	container = container and container:FindFirstChild("HeroBar")
	container = container and container:FindFirstChild("Container")
	if def and container then
		local nameLabel = container:FindFirstChild("HeroName")
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Text = HeroConfig.DisplayName(def) -- the size goes on its own badge (drawSizeBadge)
		end
		local levelLabel = container:FindFirstChild("Level")
		if levelLabel and levelLabel:IsA("TextLabel") then
			levelLabel.Text = "Level 1" -- workers overwrite this with their pad's Damage level (HeroWorkerService)
		end
		local rarityLabel = container:FindFirstChild("Rarity")
		if rarityLabel and rarityLabel:IsA("TextLabel") then
			HeroConfig.PaintRarity(rarityLabel, def.Rarity)
		end
		local power = container:FindFirstChild("Power")
		local powerLabel = power and power:FindFirstChildOfClass("TextLabel")
		if powerLabel then
			powerLabel.Text = HeroConfig.Abbreviate(def.MinePower)
		end
	end
	HeroModels.AddMutationFX(model, root, heroName)
	if def and def.Size then
		model:SetAttribute("Size", def.Size)
		drawSizeBadge(root, def.Size)
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	-- Model:ScaleTo already resizes every part and updates the R15 scale values (HeadScale ...).
	-- With automatic scaling on, the Humanoid applies HeadScale to the head AGAIN once the model is
	-- in the workspace, so the head ends up scale^2 (tiny on small heroes, huge on big ones).
	humanoid.AutomaticScalingEnabled = false
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false
	if not humanoid:FindFirstChildOfClass("Animator") then
		Instance.new("Animator").Parent = humanoid
	end

	-- A stray "HeadWeld" (left in some templates, e.g. SlingPirate, or added later) pins the head out
	-- of place and fights the Neck: remove it now and whenever one shows up again.
	local function stripHeadWeld(d: Instance)
		if d.Name == "HeadWeld" and d:IsA("JointInstance") then
			task.defer(function()
				if d.Parent then
					d:Destroy()
				end
			end)
		end
	end
	model.DescendantAdded:Connect(stripHeadWeld)

	for _, d in model:GetDescendants() do
		if d.Name == "HeadWeld" and d:IsA("JointInstance") then
			d:Destroy()
			continue
		end
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Anchored = false
			d.Massless = d ~= root
		elseif d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end
	return model, humanoid, root
end

-- Writes "Level N" and the Power (its chop damage, upgrades / grade / axe included) on the bar above
-- the hero (HumanoidRootPart.InfoAttachment.HeroBar.Container).
function HeroModels.DrawBar(model: Model, level: number, power: number)
	local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	local attachment = root and root:FindFirstChild("InfoAttachment")
	local bar = attachment and attachment:FindFirstChild("HeroBar")
	local container = bar and bar:FindFirstChild("Container")
	if not container then
		return
	end
	local levelLabel = container:FindFirstChild("Level")
	if levelLabel and levelLabel:IsA("TextLabel") then
		levelLabel.Text = "Level " .. tostring(level)
	end
	local frame = container:FindFirstChild("Power")
	local powerLabel = frame and frame:FindFirstChildOfClass("TextLabel")
	if powerLabel then
		powerLabel.Text = HeroConfig.Abbreviate(power)
	end
end

-- Height of a character's body: its parts from the top of the head to the feet, without hats, hair,
-- tools or the HumanoidRootPart (0 when it has no such parts).
function HeroModels.BodyHeight(model: Model): number
	local top, bottom = -math.huge, math.huge
	for _, d in model:GetDescendants() do
		if
			d:IsA("BasePart")
			and d.Name ~= "HumanoidRootPart"
			and not d:FindFirstAncestorOfClass("Accessory")
			and not d:FindFirstAncestorOfClass("Tool")
		then
			local half = d.Size / 2
			local cf = d.CFrame
			-- Vertical half-extent of the (possibly rotated) part.
			local h = math.abs(cf.RightVector.Y) * half.X + math.abs(cf.UpVector.Y) * half.Y + math.abs(cf.LookVector.Y) * half.Z
			top = math.max(top, cf.Position.Y + h)
			bottom = math.min(bottom, cf.Position.Y - h)
		end
	end
	return if top > bottom then top - bottom else 0
end

-- Body height of a player's character; HeroConfig.Slots.PadHeroHeight when it isn't loaded yet.
function HeroModels.PlayerBodyHeight(player: Player?): number
	local character = player and player.Character
	local height = if character then HeroModels.BodyHeight(character) else 0
	return if height > 1 then height else HeroConfig.Slots.PadHeroHeight
end

-- Scales a CLONE so its body is `height` studs tall (the templates in ReplicatedStorage are never
-- touched, so a new catalog model works at any size). Returns the factor applied (for the axe).
function HeroModels.ScaleToHeight(model: Model, height: number): number
	local current = HeroModels.BodyHeight(model)
	if current <= 0 or height <= 0 then
		return 1
	end
	local before = model:GetScale()
	if pcall(model.ScaleTo, model, before * height / current) then
		return model:GetScale() / before
	end
	return 1
end

-- Hides the bar above the hero (for copies that already have a label nearby, e.g. on a pad).
function HeroModels.HideBar(model: Model)
	local root = model.PrimaryPart
	local attachment = root and root:FindFirstChild("InfoAttachment")
	local bar = attachment and attachment:FindFirstChild("HeroBar")
	if bar and bar:IsA("BillboardGui") then
		bar.Enabled = false
	end
	local badge = attachment and attachment:FindFirstChild(HeroConfig.SizeBadgeName)
	if badge and badge:IsA("BillboardGui") then
		badge.Enabled = false
	end
end

-- Resizes every part of a tool around its Handle by `factor` (Tools are not Models, so no ScaleTo).
local function scaleTool(tool: Tool, factor: number)
	local handle = tool:FindFirstChild("Handle") :: BasePart?
	if not handle or factor == 1 then
		return
	end
	local origin = handle.CFrame
	local parts = {}
	for _, d in tool:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, { part = d, rel = origin:ToObjectSpace(d.CFrame) })
		end
	end
	for _, entry in parts do
		local part, rel = entry.part, entry.rel
		part.Size *= factor
		part.CFrame = origin * (rel - rel.Position + rel.Position * factor)
		for _, c in part:GetChildren() do
			if c:IsA("SpecialMesh") then
				c.Scale *= factor
				c.Offset *= factor
			elseif c:IsA("Attachment") then
				c.Position *= factor
			end
		end
	end
	tool.Grip = tool.Grip - tool.Grip.Position + tool.Grip.Position * factor
end

-- `scale` resizes the axe to match a hero that was scaled (Model:ScaleTo) away from its template size.
-- The shop axe models (ReplicatedStorage.Axes.<Model>) are the same design as the hero tool
-- ServerStorage.WoodenAxe at SHOP_MODEL_SCALE x the size, with their "Handle" being the tool's
-- "Shaft". So a shop axe becomes a hero tool by shrinking it and gripping its shaft the way the
-- tool grips its own: Grip = (shaft offset from the tool's Handle)^-1 * tool.Grip.
local SHOP_MODEL_SCALE = 2

local function toolFromShopAxe(axeModel: string, factor: number): Tool?
	local base = ServerStorage:FindFirstChild(AXE_NAME)
	local axes = ReplicatedStorage:FindFirstChild("Axes")
	local source = axes and axes:FindFirstChild(axeModel)
	if not base or not base:IsA("Tool") or not source or not source:IsA("Model") then
		return nil
	end
	local baseHandle = base:FindFirstChild("Handle") :: BasePart?
	local baseShaft = base:FindFirstChild("Shaft", true) :: BasePart?
	if not baseHandle or not baseShaft then
		return nil
	end
	local m = source:Clone()
	local shaft = m:FindFirstChild("Handle") :: BasePart?
	if not shaft then
		m:Destroy()
		return nil
	end
	for _, d in m:GetDescendants() do
		if d:IsA("LayerCollector") then
			d:Destroy() -- e.g. the shop's RarityLabel billboard
		end
	end
	pcall(m.ScaleTo, m, m:GetScale() * factor / SHOP_MODEL_SCALE)

	local tool = Instance.new("Tool")
	tool.Name = axeModel
	tool.RequiresHandle = true
	local rel = baseHandle.CFrame:ToObjectSpace(baseShaft.CFrame)
	rel = rel - rel.Position + rel.Position * factor
	tool.Grip = rel:Inverse() * base.Grip
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d ~= shaft then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = shaft
			weld.Part1 = d
			weld.Parent = d
		end
	end
	shaft.Name = "Handle"
	shaft.Parent = tool
	m.Name = "Axe"
	m.PrimaryPart = nil
	m.Parent = tool
	return tool
end

-- Gives the hero an axe and equips it. `axeModel` = a shop axe (ShopConfig.Axes Model) to hold;
-- nil = the default ServerStorage.WoodenAxe.
function HeroModels.GiveAxe(model: Model, humanoid: Humanoid, scale: number?, axeModel: string?): Tool?
	if axeModel then
		local tool = toolFromShopAxe(axeModel, if scale and scale > 0 then scale else 1)
		if tool then
			for _, d in tool:GetDescendants() do
				if d:IsA("BasePart") then
					d.Anchored = false
					d.CanCollide = false
					d.CanTouch = false
					d.CanQuery = false
					d.Massless = true
				end
			end
			tool.CanBeDropped = false
			tool:SetAttribute("HeroAxe", true)
			tool.Parent = model
			humanoid:EquipTool(tool)
			return tool
		end
	end
	local source = ServerStorage:FindFirstChild(AXE_NAME)
	if not source or not source:IsA("Tool") then
		warn(("[HeroModels] ServerStorage.%s (Tool) is missing"):format(AXE_NAME))
		return nil
	end
	local axe = source:Clone()
	axe:SetAttribute("HeroAxe", true)
	if scale and scale > 0 then
		scaleTool(axe, scale)
	end
	for _, d in axe:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true
		end
	end
	axe.CanBeDropped = false
	axe.Parent = model
	humanoid:EquipTool(axe)
	return axe
end

function HeroModels.Anims(humanoid: Humanoid): { Idle: string, Walk: string, Hold: string }
	local defaults = DEFAULTS[humanoid.RigType] or DEFAULTS[Enum.HumanoidRigType.R6]
	return {
		Idle = humanoid:GetAttribute("IdleAnim") or defaults.Idle,
		Walk = humanoid:GetAttribute("WalkAnim") or defaults.Walk,
		Hold = humanoid:GetAttribute("HoldAnim") or defaults.Hold,
	}
end

-- An uploaded animation id from HeroConfig.Worker[configKey], or else the KeyframeSequence named
-- HeroConfig.Worker[keyframesKey] in ServerStorage.RBX_ANIMSAVES registered on the fly (Studio only).
local resolved: { [string]: string } = {}
local warned: { [string]: boolean } = {}
local failed: { [string]: boolean } = {} -- KeyframeSequences that are missing / failed to register

-- name -> KeyframeSequence in ServerStorage.RBX_ANIMSAVES, built once (the folder is large).
local keyframesByName: { [string]: KeyframeSequence }? = nil
local function keyframeIndex(): { [string]: KeyframeSequence }
	if keyframesByName then
		return keyframesByName
	end
	local index: { [string]: KeyframeSequence } = {}
	local saves = ServerStorage:FindFirstChild("RBX_ANIMSAVES")
	if saves then
		for _, d in saves:GetDescendants() do
			if d:IsA("KeyframeSequence") and not index[d.Name] then
				index[d.Name] = d
			end
		end
	end
	keyframesByName = index
	return index
end

-- `configured` when set, else the KeyframeSequence `keyframes` in RBX_ANIMSAVES registered for this
-- session. `setting` names the config entry to fill in (for the warnings).
local function resolveAnimation(configured: string?, keyframes: string?, what: string, setting: string): string?
	if configured and configured ~= "" then
		return configured
	end
	if not keyframes or keyframes == "" then
		return nil
	end
	if resolved[keyframes] then
		return resolved[keyframes]
	end
	if failed[keyframes] then
		return nil -- already looked (and warned): don't rescan RBX_ANIMSAVES on every hero spawn
	end
	local sequence = keyframeIndex()[keyframes]
	if not sequence then
		failed[keyframes] = true
		if not warned[keyframes] then
			warned[keyframes] = true
			warn(("[HeroModels] no %s animation: set HeroConfig.Worker.%s"):format(what, setting))
		end
		return nil
	end
	local ok, id = pcall(KeyframeSequenceProvider.RegisterKeyframeSequence, KeyframeSequenceProvider, sequence)
	if ok then
		resolved[keyframes] = id
		if not warned[keyframes] then
			warned[keyframes] = true
			warn(("[HeroModels] playing the %s %s from RBX_ANIMSAVES (Studio only). Upload it and set HeroConfig.Worker.%s before publishing."):format(what, keyframes, setting))
		end
		return id
	end
	failed[keyframes] = true
	return nil
end

local function animationFromConfig(configKey: string, keyframesKey: string, what: string): string?
	local worker = HeroConfig.Worker :: any
	return resolveAnimation(worker[configKey], worker[keyframesKey], what, configKey)
end

function HeroModels.ChopAnimationId(): string?
	return animationFromConfig("ChopAnimation", "ChopKeyframes", "swing")
end

-- Every swing animation to pick from for this rig: R15 heroes use HeroConfig.Worker.ChopAnimationsR15
-- (or their KeyframeSequences); R6 heroes HeroConfig.Worker.ChopAnimations, else the single fallback.
-- Second result: each swing's damage multiplier (HeroConfig.Worker.ChopDamageMultR15; 1 for R6).
function HeroModels.ChopAnimationIds(humanoid: Humanoid?): ({ string }, { number })
	local list, mults = {}, {}
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R15 then
		local worker = HeroConfig.Worker
		local ids = worker.ChopAnimationsR15 or {}
		local names = worker.ChopKeyframesR15 or {}
		local damage = worker.ChopDamageMultR15 or {}
		for i = 1, math.max(#ids, #names) do
			local id = resolveAnimation(ids[i], names[i], "R15 swing", ("ChopAnimationsR15[%d]"):format(i))
			if id then
				table.insert(list, id)
				table.insert(mults, damage[i] or 1)
			end
		end
		return list, mults
	end
	for _, id in HeroConfig.Worker.ChopAnimations or {} do
		if id ~= "" then
			table.insert(list, id)
		end
	end
	if #list == 0 then
		local id = HeroModels.ChopAnimationId()
		if id then
			table.insert(list, id)
		end
	end
	for _ in list do
		table.insert(mults, 1)
	end
	return list, mults
end

-- R15 rigs use HeroConfig.Worker.RunAnimationR15; R6 (or no humanoid) RunAnimation / RunKeyframes.
function HeroModels.RunAnimationId(humanoid: Humanoid?): string?
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R15 then
		local id = (HeroConfig.Worker :: any).RunAnimationR15
		return if id and id ~= "" then id else nil
	end
	return animationFromConfig("RunAnimation", "RunKeyframes", "run")
end

function HeroModels.LoadTrack(humanoid: Humanoid, id: string?, priority: Enum.AnimationPriority, looped: boolean): AnimationTrack?
	if not id or id == "" then
		return nil
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = id
	local ok, track = pcall(animator.LoadAnimation, animator, anim)
	if not ok or not track then
		warn(("[HeroModels] could not load animation %s: %s"):format(id, tostring(track)))
		return nil
	end
	track.Priority = priority
	track.Looped = looped
	return track
end

return HeroModels
