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
			nameLabel.Text = def.Name
		end
		local levelLabel = container:FindFirstChild("Level")
		if levelLabel and levelLabel:IsA("TextLabel") then
			levelLabel.Text = "Level 1" -- no hero upgrades yet
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
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
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

-- Hides the bar above the hero (for copies that already have a label nearby, e.g. on a pad).
function HeroModels.HideBar(model: Model)
	local root = model.PrimaryPart
	local attachment = root and root:FindFirstChild("InfoAttachment")
	local bar = attachment and attachment:FindFirstChild("HeroBar")
	if bar and bar:IsA("BillboardGui") then
		bar.Enabled = false
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
function HeroModels.GiveAxe(model: Model, humanoid: Humanoid, scale: number?): Tool?
	local source = ServerStorage:FindFirstChild(AXE_NAME)
	if not source or not source:IsA("Tool") then
		warn(("[HeroModels] ServerStorage.%s (Tool) is missing"):format(AXE_NAME))
		return nil
	end
	local axe = source:Clone()
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

local function animationFromConfig(configKey: string, keyframesKey: string, what: string): string?
	local worker = HeroConfig.Worker :: any
	local configured = worker[configKey]
	if configured and configured ~= "" then
		return configured
	end
	if resolved[configKey] then
		return resolved[configKey]
	end
	local saves = ServerStorage:FindFirstChild("RBX_ANIMSAVES")
	local sequence: Instance? = nil
	if saves then
		for _, d in saves:GetDescendants() do
			if d:IsA("KeyframeSequence") and d.Name == worker[keyframesKey] then
				sequence = d
				break
			end
		end
	end
	if not sequence then
		if not warned[configKey] then
			warned[configKey] = true
			warn(("[HeroModels] no %s animation: set HeroConfig.Worker.%s"):format(what, configKey))
		end
		return nil
	end
	local ok, id = pcall(KeyframeSequenceProvider.RegisterKeyframeSequence, KeyframeSequenceProvider, sequence)
	if ok then
		resolved[configKey] = id
		if not warned[configKey] then
			warned[configKey] = true
			warn(("[HeroModels] playing the %s from RBX_ANIMSAVES (Studio only). Upload it and set HeroConfig.Worker.%s before publishing."):format(what, configKey))
		end
		return id
	end
	return nil
end

function HeroModels.ChopAnimationId(): string?
	return animationFromConfig("ChopAnimation", "ChopKeyframes", "swing")
end

function HeroModels.RunAnimationId(): string?
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
