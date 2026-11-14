-- NoticeUI: the popup that drops down from the top of the screen ("NEW EQUIPMENT!" style).
--
-- Two kinds of notice:
--   Restock  When the Lumber Axe shop restocks (AxeStock "NextRestock" changes, every
--            ShopConfig.RestockInterval), shows the best axe in stock that the player can buy in
--            their unlocked zones (an axe they don't own first). "GO TO SHOP" draws a guide line
--            to the Lumber Axe shop on their plot.
--   Upgrade  When the player's money first reaches the cost of a skill they can upgrade
--            (requirements met, not maxed), once per skill level. "UPGRADE" opens the skill tree
--            on that skill (SkillTreeGui.OpenSkill, from SkillTreeUI).
-- Notices queue up; each one closes itself after SHOW_TIME seconds (the orange bar) or with X.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local SkillTreeConfig = require(Shared:WaitForChild("SkillTreeConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))

local player = Players.LocalPlayer
local abbreviate = HeroConfig.Abbreviate

local SHOW_TIME = 8 -- seconds a notice stays up
local GUIDE_TIME = 45 -- seconds the "go to shop" line stays (or until you reach the shop)
local JOIN_QUIET = 10 -- seconds after joining: skills already affordable then are not announced

local FONT = Enum.Font.FredokaOne
local DARK = Color3.fromRGB(20, 22, 28)
local PANEL = Color3.fromRGB(28, 30, 38)
local GREEN = Color3.fromRGB(90, 215, 60)
local PRICE_GREEN = Color3.fromRGB(124, 255, 90)
local EXTRA_BLUE = Color3.fromRGB(110, 220, 255)
local NAME_BLUE = Color3.fromRGB(200, 235, 255)
local SUB_GREY = Color3.fromRGB(190, 194, 205)
local BAR_ORANGE = Color3.fromRGB(255, 170, 30)

-- UI helpers ------------------------------------------------------------------------------------------

local function new(className: string, props: { [string]: any }, children: { Instance }?): any
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function corner(r: number): UICorner
	return new("UICorner", { CornerRadius = UDim.new(0, r) })
end

local function stroke(color: Color3, thickness: number, border: boolean?): UIStroke
	return new("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = if border then Enum.ApplyStrokeMode.Border else Enum.ApplyStrokeMode.Contextual,
	})
end

local function label(props: { [string]: any }): TextLabel
	props.BackgroundTransparency = 1
	props.Font = FONT
	props.TextScaled = true
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	local t = props.Stroke or 2
	props.Stroke = nil
	local l = new("TextLabel", props)
	stroke(DARK, t).Parent = l
	return l
end

-- Popup -----------------------------------------------------------------------------------------------

local gui = new("ScreenGui", {
	Name = "NoticeGui",
	DisplayOrder = 20,
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = player:WaitForChild("PlayerGui"),
})

local HIDDEN = UDim2.new(0.5, 0, 0, -260)
local SHOWN = UDim2.new(0.5, 0, 0, 12)

local root = new("Frame", {
	Name = "Notice",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = HIDDEN,
	Size = UDim2.fromOffset(600, 230),
	BackgroundColor3 = PANEL,
	Visible = false,
	Parent = gui,
}, {
	corner(18),
	new("UISizeConstraint", { MaxSize = Vector2.new(600, 230) }),
	new("UIAspectRatioConstraint", { AspectRatio = 600 / 230 }),
})
stroke(DARK, 5, true).Parent = root
-- Shrink with the screen (phones): never wider than 92% of it.
local function fitWidth()
	local w = gui.AbsoluteSize.X
	root.Size = UDim2.fromOffset(math.min(600, w * 0.92), math.min(600, w * 0.92) * 230 / 600)
end
gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitWidth)
fitWidth()

local header = new("Frame", {
	Name = "Header",
	Size = UDim2.fromScale(1, 0.27),
	BackgroundColor3 = Color3.new(1, 1, 1),
	Parent = root,
}, {
	corner(16),
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(40, 140, 255), Color3.fromRGB(120, 200, 255)),
	}),
})
-- Square off the header's bottom corners.
new("Frame", {
	Size = UDim2.fromScale(1, 0.4),
	Position = UDim2.fromScale(0, 0.6),
	BorderSizePixel = 0,
	BackgroundColor3 = Color3.new(1, 1, 1),
	Parent = header,
}, {
	new("UIGradient", { Color = ColorSequence.new(Color3.fromRGB(40, 140, 255), Color3.fromRGB(120, 200, 255)) }),
})
local title = label({
	Name = "Title",
	Text = "NEW EQUIPMENT!",
	TextColor3 = Color3.new(1, 1, 1),
	Position = UDim2.fromScale(0.035, 0.14),
	Size = UDim2.fromScale(0.7, 0.72),
	ZIndex = 2,
	Stroke = 3,
	Parent = header,
})

local closeButton = new("TextButton", {
	Name = "Close",
	Text = "X",
	Font = FONT,
	TextScaled = true,
	TextColor3 = Color3.new(1, 1, 1),
	BackgroundColor3 = Color3.fromRGB(220, 30, 30),
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -10, 0.5, 0),
	Size = UDim2.fromScale(0.09, 0.82),
	ZIndex = 3,
	Parent = header,
}, {
	corner(10),
	new("UIAspectRatioConstraint", { AspectRatio = 1.1 }),
	new("UIPadding", { PaddingTop = UDim.new(0.18, 0), PaddingBottom = UDim.new(0.18, 0) }),
})
UIStyle.Close(closeButton)
stroke(DARK, 3, true).Parent = closeButton
stroke(DARK, 2).Parent = closeButton

local iconBox = new("Frame", {
	Name = "Icon",
	Position = UDim2.fromScale(0.035, 0.34),
	Size = UDim2.fromScale(0.235, 0.6),
	BackgroundColor3 = Color3.new(1, 1, 1),
	Parent = root,
}, {
	corner(14),
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(150, 215, 255), Color3.fromRGB(40, 140, 240)),
		Rotation = 90,
	}),
})
stroke(DARK, 3, true).Parent = iconBox
local viewport = new("ViewportFrame", {
	Name = "View",
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
	Ambient = Color3.fromRGB(200, 200, 200),
	LightColor = Color3.new(1, 1, 1),
	Parent = iconBox,
})
local iconImage = new("ImageLabel", {
	Name = "Image",
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(0.8, 0.8),
	Position = UDim2.fromScale(0.1, 0.1),
	ScaleType = Enum.ScaleType.Fit,
	Parent = iconBox,
})
local iconText = new("TextLabel", {
	Name = "Emoji",
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(0.8, 0.8),
	Position = UDim2.fromScale(0.1, 0.1),
	TextScaled = true,
	Font = Enum.Font.GothamBold,
	Text = "",
	Parent = iconBox,
})

local subtitle = label({
	Name = "Subtitle",
	Text = "YOU CAN NOW BUY",
	TextColor3 = SUB_GREY,
	Position = UDim2.fromScale(0.31, 0.35),
	Size = UDim2.fromScale(0.62, 0.11),
	Parent = root,
})
local nameLabel = label({
	Name = "ItemName",
	Text = "",
	TextColor3 = NAME_BLUE,
	Position = UDim2.fromScale(0.31, 0.47),
	Size = UDim2.fromScale(0.64, 0.19),
	Stroke = 3,
	Parent = root,
})
local priceLabel = label({
	Name = "Price",
	Text = "",
	TextColor3 = PRICE_GREEN,
	Position = UDim2.fromScale(0.31, 0.72),
	Size = UDim2.fromScale(0.13, 0.11),
	AutomaticSize = Enum.AutomaticSize.None,
	Parent = root,
})
local extraLabel = label({
	Name = "Extra",
	Text = "",
	TextColor3 = EXTRA_BLUE,
	Position = UDim2.fromScale(0.45, 0.72),
	Size = UDim2.fromScale(0.2, 0.11),
	Parent = root,
})

local actionButton = new("TextButton", {
	Name = "Action",
	Text = "UPGRADE",
	Font = FONT,
	TextScaled = true,
	TextColor3 = Color3.new(1, 1, 1),
	BackgroundColor3 = GREEN,
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.fromScale(0.965, 0.63),
	Size = UDim2.fromScale(0.27, 0.26),
	Parent = root,
}, {
	corner(10),
	new("UIPadding", {
		PaddingTop = UDim.new(0.16, 0),
		PaddingBottom = UDim.new(0.16, 0),
		PaddingLeft = UDim.new(0.06, 0),
		PaddingRight = UDim.new(0.06, 0),
	}),
})
stroke(DARK, 3, true).Parent = actionButton
stroke(DARK, 2.5).Parent = actionButton

local barBack = new("Frame", {
	Name = "Timer",
	Position = UDim2.fromScale(0.035, 0.94),
	Size = UDim2.fromScale(0.93, 0.025),
	BackgroundColor3 = Color3.fromRGB(55, 58, 70),
	BorderSizePixel = 0,
	Parent = root,
}, { corner(4) })
local barFill = new("Frame", {
	Name = "Fill",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = BAR_ORANGE,
	BorderSizePixel = 0,
	Parent = barBack,
}, { corner(4) })

-- Icons -----------------------------------------------------------------------------------------------

local function axeIcon(model: string)
	viewport:ClearAllChildren()
	iconImage.Image = ""
	iconText.Text = ""
	local def = ShopConfig.GetAxe(model)
	if def and def.AxeImage then
		iconImage.Image = def.AxeImage
		return
	end
	local axes = ReplicatedStorage:FindFirstChild("Axes")
	local source = axes and axes:FindFirstChild(model)
	if not source or not source:IsA("Model") then
		return
	end
	local m = source:Clone()
	local bbox, size = m:GetBoundingBox()
	m:PivotTo(CFrame.Angles(0, 0, math.rad(-28)) * bbox:ToObjectSpace(m:GetPivot()))
	m.Parent = viewport
	local fov = 40
	local reach = math.max(size.X, size.Y) * 0.5
	local camera = new("Camera", { FieldOfView = fov, Parent = viewport })
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 0, reach / math.tan(math.rad(fov / 2))), Vector3.zero)
	viewport.CurrentCamera = camera
end

local function textIcon(icon: string)
	viewport:ClearAllChildren()
	local isImage = string.find(icon, "^rbxassetid://") ~= nil or string.find(icon, "^https?://") ~= nil
	iconImage.Image = if isImage then icon else ""
	iconText.Text = if isImage then "" else icon
end

-- Queue -----------------------------------------------------------------------------------------------

type Notice = {
	key: string, -- same key replaces a queued one (e.g. two restocks while a notice is up)
	title: string,
	subtitle: string,
	name: string,
	price: string,
	extra: string,
	button: string,
	axe: string?,
	icon: string?,
	onAction: () -> (),
}

local queue: { Notice } = {}
local showing = false
local closeNow: BindableEvent = Instance.new("BindableEvent")
local current: Notice? = nil

local function present(n: Notice)
	title.Text = n.title
	subtitle.Text = n.subtitle
	nameLabel.Text = n.name
	priceLabel.Text = n.price
	extraLabel.Text = n.extra
	actionButton.Text = n.button
	if n.axe then
		axeIcon(n.axe)
	else
		textIcon(n.icon or "")
	end
	-- Put the extra text right after the price.
	task.defer(function()
		local w = priceLabel.TextBounds.X / math.max(1, root.AbsoluteSize.X)
		extraLabel.Position = UDim2.fromScale(0.31 + math.max(0.05, w) + 0.02, 0.72)
	end)
end

local function run()
	if showing then
		return
	end
	showing = true
	while #queue > 0 do
		local n = table.remove(queue, 1) :: Notice
		current = n
		present(n)
		root.Position = HIDDEN
		root.Visible = true
		barFill.Size = UDim2.fromScale(1, 1)
		TweenService:Create(root, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = SHOWN }):Play()
		local bar = TweenService:Create(barFill, TweenInfo.new(SHOW_TIME, Enum.EasingStyle.Linear), { Size = UDim2.fromScale(0, 1) })
		bar:Play()
		local done = false
		local c1 = bar.Completed:Connect(function()
			done = true
		end)
		local c2 = closeNow.Event:Connect(function()
			done = true
		end)
		while not done do
			task.wait()
		end
		c1:Disconnect()
		c2:Disconnect()
		bar:Cancel()
		current = nil
		local out = TweenService:Create(root, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = HIDDEN })
		out:Play()
		out.Completed:Wait()
		root.Visible = false
		task.wait(0.25)
	end
	showing = false
end

local function push(n: Notice)
	for i, q in queue do
		if q.key == n.key then
			queue[i] = n
			return
		end
	end
	table.insert(queue, n)
	task.spawn(run)
end

closeButton.Activated:Connect(function()
	closeNow:Fire()
end)
actionButton.Activated:Connect(function()
	local n = current
	closeNow:Fire()
	if n then
		n.onAction()
	end
end)

-- Guide line to the Lumber Axe shop ---------------------------------------------------------------------

local function myShop(kind: string): BasePart?
	local function find(folder: Instance?): BasePart?
		if not folder then
			return nil
		end
		for _, m in folder:GetChildren() do
			if m:IsA("Model") and m:GetAttribute("Shop") == kind then
				local p = m:FindFirstChild("PromptPart") or m.PrimaryPart
				if p and p:IsA("BasePart") then
					return p
				end
			end
		end
		return nil
	end
	local plots = workspace:FindFirstChild("Plots")
	if plots then
		for _, plot in plots:GetChildren() do
			if plot:GetAttribute("OwnerUserId") == player.UserId then
				local p = find(plot:FindFirstChild("Shops"))
				if p then
					return p
				end
			end
		end
	end
	return find(workspace:FindFirstChild("Shops"))
end

local guide: { Instance } = {}
local guideConn: RBXScriptConnection? = nil

local function clearGuide()
	for _, inst in guide do
		inst:Destroy()
	end
	table.clear(guide)
	if guideConn then
		guideConn:Disconnect()
		guideConn = nil
	end
end

local function guideTo(target: BasePart)
	clearGuide()
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local a0 = new("Attachment", { Name = "NoticeGuide", Parent = root })
	local a1 = new("Attachment", { Name = "NoticeGuide", Position = Vector3.new(0, 2, 0), Parent = target })
	local beam = new("Beam", {
		Attachment0 = a0,
		Attachment1 = a1,
		Color = ColorSequence.new(Color3.fromRGB(255, 220, 60)),
		Width0 = 1.2,
		Width1 = 1.2,
		FaceCamera = true,
		LightEmission = 1,
		Texture = "rbxasset://textures/particles/sparkles_main.dds",
		TextureMode = Enum.TextureMode.Wrap,
		TextureLength = 3,
		TextureSpeed = 2,
		Transparency = NumberSequence.new(0.15),
		Parent = root,
	})
	guide = { a0, a1, beam }
	local started = os.clock()
	guideConn = RunService.Heartbeat:Connect(function()
		if not a0.Parent or os.clock() - started > GUIDE_TIME then
			clearGuide()
		elseif (root.Position - target.Position).Magnitude <= ShopConfig.PromptDistance then
			clearGuide()
		end
	end)
end

-- Restock notice --------------------------------------------------------------------------------------

local function unlockedZones(): number
	local n = player:GetAttribute("UnlockedZones")
	return if typeof(n) == "number" then n else 1
end

local function owns(model: string): boolean
	local axes = player:FindFirstChild("Axes")
	local v = axes and axes:FindFirstChild(model)
	return v ~= nil and v:IsA("BoolValue") and v.Value
end

local function stockOf(stock: Instance, model: string): number
	local v = stock:FindFirstChild(model)
	return if v and v:IsA("IntValue") then v.Value else 0
end

local function onRestock(stock: Instance)
	-- Best axe in stock for the player's zones: one they don't own beats one they do; then the priciest.
	local best: ShopConfig.AxeDef? = nil
	local bestNew = false
	local count = 0
	for _, def in ShopConfig.Axes do
		if def.Price <= 0 or def.Zone > unlockedZones() or stockOf(stock, def.Model) <= 0 then
			continue
		end
		count += 1
		local isNew = not owns(def.Model)
		if not best or (isNew and not bestNew) or (isNew == bestNew and def.Price > best.Price) then
			best, bestNew = def, isNew
		end
	end
	if not best then
		return
	end
	local def = best :: ShopConfig.AxeDef
	push({
		key = "Restock",
		title = "SHOP RESTOCKED!",
		subtitle = if count > 1 then ("%d AXES IN STOCK - VISIT THE SHOP"):format(count) else "BACK IN STOCK - VISIT THE SHOP",
		name = string.upper(def.Name),
		price = "$" .. abbreviate(def.Price),
		extra = ("+%s dmg  x%d left"):format(abbreviate(def.Damage), stockOf(stock, def.Model)),
		button = "GO TO SHOP",
		axe = def.Model,
		onAction = function()
			local target = myShop("LumberAxe")
			if target then
				guideTo(target)
			end
		end,
	})
end

task.spawn(function()
	local stock = ReplicatedStorage:WaitForChild("AxeStock")
	-- NextRestock changes right after every restock. The first value is already there when we join.
	stock:GetAttributeChangedSignal("NextRestock"):Connect(function()
		task.wait(0.5) -- let the new stock values replicate
		onRestock(stock)
	end)
end)

-- Skill upgrade notice --------------------------------------------------------------------------------

local skills = player:WaitForChild("Skills")
local money = player:WaitForChild("leaderstats"):WaitForChild("Money") :: NumberValue
local joinedAt = os.clock()
local announced: { [string]: boolean } = {} -- "Tree/Node#level" already shown (or affordable at join)

local function getLevel(treeId: string, nodeId: string): number
	local v = skills:FindFirstChild(SkillTreeConfig.Key(treeId, nodeId))
	return if v and v:IsA("IntValue") then v.Value else 0
end

local function skillWindowOpen(): boolean
	local g = player.PlayerGui:FindFirstChild("SkillTreeGui")
	local w = g and g:FindFirstChild("Window")
	return w ~= nil and (w :: GuiObject).Visible
end

local function checkSkills()
	local quiet = os.clock() - joinedAt < JOIN_QUIET
	local best: { tree: SkillTreeConfig.TreeDef, node: SkillTreeConfig.NodeDef, level: number, cost: number }? = nil
	for _, tree in SkillTreeConfig.Trees do
		for _, node in tree.Nodes do
			local level = getLevel(tree.Id, node.Id)
			local cost = SkillTreeConfig.Cost(node, level)
			if not cost or money.Value < cost or not SkillTreeConfig.RequirementsMet(tree.Id, node, getLevel) then
				continue
			end
			local key = ("%s#%d"):format(SkillTreeConfig.Key(tree.Id, node.Id), level)
			if announced[key] then
				continue
			end
			announced[key] = true
			if not quiet and (not best or cost > best.cost) then
				best = { tree = tree, node = node, level = level, cost = cost }
			end
		end
	end
	if not best or skillWindowOpen() then
		return
	end
	local b = best :: any
	push({
		key = "Skill",
		title = "NEW UPGRADE!",
		subtitle = "YOU CAN NOW UPGRADE",
		name = ("%s  LV %d"):format(string.upper(b.node.Name), b.level + 1),
		price = "$" .. abbreviate(b.cost),
		extra = SkillTreeConfig.EffectText(b.node, b.level + 1),
		button = "UPGRADE",
		icon = SkillTreeConfig.IconOf(b.node),
		onAction = function()
			local g = player.PlayerGui:FindFirstChild("SkillTreeGui")
			local open = g and g:FindFirstChild("OpenSkill")
			if open and open:IsA("BindableEvent") then
				open:Fire(b.tree.Id, b.node.Id)
			end
		end,
	})
end

money.Changed:Connect(checkSkills)
skills.ChildAdded:Connect(function(v)
	if v:IsA("IntValue") then
		v.Changed:Connect(checkSkills)
	end
	checkSkills()
end)
for _, v in skills:GetChildren() do
	if v:IsA("IntValue") then
		v.Changed:Connect(checkSkills)
	end
end
checkSkills()
task.delay(JOIN_QUIET + 0.1, checkSkills)
