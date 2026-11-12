-- TreeClient: click / tap trees to chop them.
-- Plays hit effects right away (prediction) and asks the server to deal the damage; the server's
-- answer brings the damage number, the fall animation and the drops.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))
local TreeFX = require(script.Parent:WaitForChild("TreeFX"))
local DropFX = require(script.Parent:WaitForChild("DropFX"))
local ChestFX = require(script.Parent:WaitForChild("ChestFX"))
local TargetRing = require(script.Parent:WaitForChild("TargetRing"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local HitTree = Remotes:WaitForChild("HitTree") :: RemoteEvent
local TreeHit = Remotes:WaitForChild("TreeHit") :: RemoteEvent
local TreeDrops = Remotes:WaitForChild("TreeDrops") :: RemoteEvent

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local lastClick = 0
local holding = false
local holdScreenPos: Vector2? = nil

-- Finding the tree under the cursor ------------------------------------------------------------

local function treeFromPart(inst: Instance?): Model?
	while inst and inst ~= workspace do
		local parent = inst.Parent
		if parent and parent.Name == "TreeSpawns" and inst:IsA("Model") then
			return inst
		end
		inst = parent
	end
	return nil
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function raycastScreen(screenPos: Vector2): (Model?, Vector3?)
	local exclude: { Instance } = { TreeFX.Folder }
	if player.Character then
		table.insert(exclude, player.Character)
	end
	rayParams.FilterDescendantsInstances = exclude
	local ray = camera:ScreenPointToRay(screenPos.X, screenPos.Y)
	local result = workspace:Raycast(ray.Origin, ray.Direction * 500, rayParams)
	if not result then
		return nil, nil
	end
	return treeFromPart(result.Instance), result.Position
end

local function canChop(tree: Model): boolean
	if tree:GetAttribute("Dead") or (tree:GetAttribute("HP") or 0) <= 0 then
		return false
	end
	if TreeConfig.OnlyOwnPlot then
		local plot = tree.Parent and tree.Parent.Parent
		if not plot or plot:GetAttribute("OwnerUserId") ~= player.UserId then
			return false
		end
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or (root.Position - tree:GetPivot().Position).Magnitude > TreeConfig.MaxHitDistance then
		return false
	end
	return true
end

local function myPosition(): Vector3?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return root and root.Position
end

-- Chopping -------------------------------------------------------------------------------------

local function tryChop(screenPos: Vector2)
	local now = os.clock()
	if now - lastClick < TreeConfig.ClickCooldown then
		return
	end
	local tree, hitPos = raycastScreen(screenPos)
	if not tree or not hitPos or not canChop(tree) then
		return
	end
	lastClick = now
	TreeFX.Hit(tree, hitPos, myPosition())
	TargetRing.MarkHit(tree)
	HitTree:FireServer(tree, hitPos)
end

-- Hover outline (mouse only) -------------------------------------------------------------------

local hover = Instance.new("Highlight")
hover.Name = "TreeHover"
hover.FillTransparency = 1
hover.OutlineColor = TreeConfig.HoverOutlineColor
hover.OutlineTransparency = 0.35
hover.DepthMode = Enum.HighlightDepthMode.Occluded
hover.Enabled = false
hover.Parent = TreeFX.Folder

RunService.RenderStepped:Connect(function()
	if holding and holdScreenPos then
		tryChop(holdScreenPos)
	end
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		return
	end
	local mouse = UserInputService:GetMouseLocation()
	-- GetMouseLocation includes the top bar inset; ViewportPointToRay expects exactly that.
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	local exclude: { Instance } = { TreeFX.Folder }
	if player.Character then
		table.insert(exclude, player.Character)
	end
	rayParams.FilterDescendantsInstances = exclude
	local result = workspace:Raycast(ray.Origin, ray.Direction * 500, rayParams)
	local tree = result and treeFromPart(result.Instance)
	if tree and canChop(tree) then
		hover.Adornee = tree
		hover.Enabled = true
	else
		hover.Enabled = false
		hover.Adornee = nil
	end
end)

-- Input ----------------------------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		tryChop(pos)
		if TreeConfig.HoldToChop then
			holding = true
			holdScreenPos = pos
		end
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if not holding then
		return
	end
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
		holdScreenPos = Vector2.new(input.Position.X, input.Position.Y)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		holding = false
		holdScreenPos = nil
	end
end)

-- HP bars --------------------------------------------------------------------------------------
-- Tree templates carry InfoAttachment.TreeBar.Container.HPFill: the green bar, with a dark "Empty"
-- frame inside it that covers the lost HP from the right, and "HPDisplay" ("1.2K/2K"). Drawn here on
-- the client (from the tree's HP / MaxHP attributes) so the bar can slide smoothly.

local BAR_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function drawBar(tree: Model, animate: boolean)
	local fill = tree:FindFirstChild("HPFill", true)
	local empty = fill and fill:FindFirstChild("Empty")
	if not fill or not empty or not empty:IsA("GuiObject") then
		return
	end
	local hp = math.max(tree:GetAttribute("HP") or 0, 0)
	local maxHp = math.max(tree:GetAttribute("MaxHP") or 1, 1)
	local ratio = math.clamp(hp / maxHp, 0, 1)
	empty.AnchorPoint = Vector2.new(1, 0)
	empty.Position = UDim2.fromScale(1, 0)
	empty.ZIndex = 2
	empty.Visible = ratio < 1
	local goal = UDim2.fromScale(1 - ratio, 1)
	if animate then
		TweenService:Create(empty, BAR_TWEEN, { Size = goal }):Play()
	else
		empty.Size = goal
	end
	local text = fill:FindFirstChild("HPDisplay")
	if text and text:IsA("TextLabel") then
		text.Text = ("%s/%s"):format(HeroConfig.Abbreviate(hp), HeroConfig.Abbreviate(maxHp))
		text.ZIndex = 3
	end
end

local barBound: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function bindBar(tree: Instance)
	if not tree:IsA("Model") or barBound[tree] then
		return
	end
	barBound[tree] = true
	drawBar(tree, false)
	task.delay(0.5, drawBar, tree, false) -- in case the bar arrived after the model
	tree:GetAttributeChangedSignal("HP"):Connect(function()
		drawBar(tree, true)
	end)
	tree:GetAttributeChangedSignal("MaxHP"):Connect(function()
		drawBar(tree, false)
	end)
end

local function isTree(inst: Instance): boolean
	return inst:IsA("Model") and inst.Parent ~= nil and inst.Parent.Name == "TreeSpawns"
end

for _, d in workspace:GetDescendants() do
	if isTree(d) then
		bindBar(d)
	end
end
workspace.DescendantAdded:Connect(function(d)
	if isTree(d) then
		-- The bar's GUI streams in with the tree; give it a moment.
		task.defer(bindBar, d)
	end
end)

-- Server results -------------------------------------------------------------------------------

TreeHit.OnClientEvent:Connect(function(tree: Model?, attacker: Player?, damage: number, hitPos: Vector3, felled: boolean, heroPos: Vector3?)
	if not tree or not tree.Parent then
		return
	end
	local fromPos: Vector3? = heroPos -- set when a hero (not a player) made the hit
	local attackerRoot = attacker and attacker.Character and attacker.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if attackerRoot then
		fromPos = attackerRoot.Position
	end
	-- Our own hits were already shown when we clicked.
	if attacker ~= player and not felled then
		TreeFX.Hit(tree, hitPos, fromPos)
	end
	TreeFX.DamageNumber(hitPos, damage)
	if not felled then
		TargetRing.MarkHit(tree)
	end
	if felled then
		TreeFX.Fell(tree, fromPos)
	end
end)

TreeDrops.OnClientEvent:Connect(function(origin: Vector3, groundY: number, drops, chest: Model?)
	DropFX.Play(origin, groundY, drops, chest)
end)

ChestFX.Start()
TargetRing.Start()
