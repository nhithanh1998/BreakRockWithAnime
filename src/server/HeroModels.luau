-- HeroModels: builds the NPC models heroes work with (HeroWorkerService).
--
--   HeroModels.Clone(heroName)            -> model, humanoid, root   (not parented)
--   HeroModels.GiveAxe(model, humanoid)    puts ServerStorage.WoodenAxe in the hero's right hand
--   HeroModels.Anims(humanoid)             -> { Idle, Walk, Hold } animation ids for this rig
--   HeroModels.LoadTrack(humanoid, id, priority, looped) -> AnimationTrack?
--   HeroModels.ChopAnimationId()           -> id for the swing (HeroConfig.Worker.ChopAnimation, or the
--                                             KeyframeSequence registered for Studio playtests)
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
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false
	if not humanoid:FindFirstChildOfClass("Animator") then
		Instance.new("Animator").Parent = humanoid
	end

	for _, d in model:GetDescendants() do
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

function HeroModels.GiveAxe(model: Model, humanoid: Humanoid): Tool?
	local source = ServerStorage:FindFirstChild(AXE_NAME)
	if not source or not source:IsA("Tool") then
		warn(("[HeroModels] ServerStorage.%s (Tool) is missing"):format(AXE_NAME))
		return nil
	end
	local axe = source:Clone()
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

local chopId: string? = nil
local warnedChop = false

function HeroModels.ChopAnimationId(): string?
	local configured = HeroConfig.Worker.ChopAnimation
	if configured and configured ~= "" then
		return configured
	end
	if chopId then
		return chopId
	end
	local saves = ServerStorage:FindFirstChild("RBX_ANIMSAVES")
	local sequence: Instance? = nil
	if saves then
		for _, d in saves:GetDescendants() do
			if d:IsA("KeyframeSequence") and d.Name == HeroConfig.Worker.ChopKeyframes then
				sequence = d
				break
			end
		end
	end
	if not sequence then
		if not warnedChop then
			warnedChop = true
			warn("[HeroModels] no swing animation: set HeroConfig.Worker.ChopAnimation")
		end
		return nil
	end
	local ok, id = pcall(KeyframeSequenceProvider.RegisterKeyframeSequence, KeyframeSequenceProvider, sequence)
	if ok then
		chopId = id
		if not warnedChop then
			warnedChop = true
			warn("[HeroModels] playing the swing from RBX_ANIMSAVES (Studio only). Upload it and set HeroConfig.Worker.ChopAnimation before publishing.")
		end
		return id
	end
	return nil
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
