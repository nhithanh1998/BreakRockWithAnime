-- FeedbackUI: the window of the Feedback stall (ShopPrompt with Shop = "Feedback", see ShopConfig).
-- Pick a category, give 1-5 stars, write a message and press Send; FeedbackService saves it.
-- Closes with X, after a successful send, or when you walk ShopConfig.CloseDistance away.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ShopConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ShopConfig"))
local FeedbackAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("FeedbackAction") :: RemoteFunction

local player = Players.LocalPlayer
local CONFIG = ShopConfig.Feedback

local FONT = Enum.Font.FredokaOne
local PANEL_COLOR = Color3.fromRGB(38, 40, 50)
local PANEL_STROKE = Color3.fromRGB(78, 80, 92)
local INNER_COLOR = Color3.fromRGB(28, 30, 38)
local ACCENT = Color3.fromRGB(140, 85, 220)
local CLOSE_COLOR = Color3.fromRGB(214, 92, 28)
local GREEN_BUTTON = Color3.fromRGB(36, 132, 66)
local GREY_BUTTON = Color3.fromRGB(80, 82, 92)
local STAR_ON = Color3.fromRGB(255, 205, 50)
local STAR_OFF = Color3.fromRGB(90, 92, 104)
local OK_COLOR = Color3.fromRGB(110, 230, 120)
local ERROR_COLOR = Color3.fromRGB(255, 110, 100)

local CATEGORY_ICONS = { Bug = "🐞", Idea = "💡", Other = "💬" }

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

local function corner(radius: number): UICorner
	return new("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color: Color3, thickness: number, border: boolean?): UIStroke
	return new("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = if border then Enum.ApplyStrokeMode.Border else Enum.ApplyStrokeMode.Contextual,
	})
end

local function text(props: { [string]: any }): TextLabel
	props.BackgroundTransparency = 1
	props.Font = props.Font or FONT
	props.TextScaled = true
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	local label = new("TextLabel", props)
	stroke(Color3.fromRGB(20, 20, 24), 2).Parent = label
	return label
end

local function button(props: { [string]: any }): TextButton
	local b = new("TextButton", {
		AutoButtonColor = true,
		BackgroundColor3 = props.Color,
		Font = FONT,
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
		Text = props.Text,
		Position = props.Position,
		Size = props.Size,
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		Parent = props.Parent,
	}, {
		corner(6),
		new("UIPadding", { PaddingTop = UDim.new(0.18, 0), PaddingBottom = UDim.new(0.18, 0), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
	})
	stroke(props.Color:Lerp(Color3.new(1, 1, 1), 0.25), 2, true).Parent = b
	stroke(Color3.fromRGB(20, 20, 24), 1.5).Parent = b
	return b
end

-- Window ------------------------------------------------------------------------------------------

local gui = new("ScreenGui", {
	Name = "FeedbackGui",
	DisplayOrder = 12,
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Enabled = true,
	Parent = player:WaitForChild("PlayerGui"),
})

local root = new("Frame", {
	Name = "Window",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(520, 430),
	BackgroundColor3 = PANEL_COLOR,
	Visible = false,
	Parent = gui,
}, { corner(10), new("UISizeConstraint", { MaxSize = Vector2.new(520, 430) }) })
stroke(PANEL_STROKE, 3, true).Parent = root
local openScale = new("UIScale", { Parent = root })
-- fit small screens
local fitScale = 1
local function fit()
	local cam = workspace.CurrentCamera
	if cam then
		local vp = cam.ViewportSize
		fitScale = math.min(1, (vp.X - 24) / 520, (vp.Y - 24) / 430)
	end
end
fit()
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		fit()
		if root.Visible then
			openScale.Scale = fitScale
		end
	end)
end

text({ Text = "Feedback", Position = UDim2.fromOffset(20, 12), Size = UDim2.new(1, -90, 0, 38), TextXAlignment = Enum.TextXAlignment.Left, Parent = root })
text({
	Text = "Tell us what you think! Bugs, ideas, anything.",
	Position = UDim2.fromOffset(20, 52),
	Size = UDim2.new(1, -40, 0, 20),
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.fromRGB(200, 190, 230),
	Parent = root,
})
local closeButton = button({ Text = "X", Color = CLOSE_COLOR, Position = UDim2.new(1, -54, 0, 12), Size = UDim2.fromOffset(42, 42), Parent = root })

-- Category
text({ Text = "Type", Position = UDim2.fromOffset(20, 84), Size = UDim2.fromOffset(80, 22), TextXAlignment = Enum.TextXAlignment.Left, Parent = root })
local categoryRow = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(20, 108), Size = UDim2.new(1, -40, 0, 40), Parent = root }, {
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
})
local category = CONFIG.Categories[1]
local categoryButtons: { [string]: TextButton } = {}
local function paintCategories()
	for name, b in categoryButtons do
		b.BackgroundColor3 = if name == category then ACCENT else GREY_BUTTON
	end
end
for i, name in CONFIG.Categories do
	local b = button({ Text = (CATEGORY_ICONS[name] or "") .. " " .. name, Color = GREY_BUTTON, Size = UDim2.new(1 / #CONFIG.Categories, -7, 1, 0), LayoutOrder = i, Parent = categoryRow })
	categoryButtons[name] = b
	b.Activated:Connect(function()
		category = name
		paintCategories()
	end)
end

-- Rating
text({ Text = "Rating", Position = UDim2.fromOffset(20, 158), Size = UDim2.fromOffset(80, 22), TextXAlignment = Enum.TextXAlignment.Left, Parent = root })
local starRow = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(20, 182), Size = UDim2.fromOffset(240, 40), Parent = root }, {
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
})
local rating = 0
local stars: { TextButton } = {}
local function paintStars()
	for i, s in stars do
		s.TextColor3 = if i <= rating then STAR_ON else STAR_OFF
	end
end
for i = 1, 5 do
	local s = new("TextButton", {
		BackgroundTransparency = 1,
		Text = "★",
		Font = FONT,
		TextScaled = true,
		TextColor3 = STAR_OFF,
		Size = UDim2.fromOffset(40, 40),
		LayoutOrder = i,
		Parent = starRow,
	})
	stroke(Color3.fromRGB(20, 20, 24), 1.5).Parent = s
	stars[i] = s
	s.Activated:Connect(function()
		rating = if rating == i then 0 else i
		paintStars()
	end)
end

-- Message
local boxFrame = new("Frame", {
	BackgroundColor3 = INNER_COLOR,
	Position = UDim2.fromOffset(20, 232),
	Size = UDim2.new(1, -40, 0, 118),
	Parent = root,
}, { corner(8) })
stroke(PANEL_STROKE, 2, true).Parent = boxFrame
local box = new("TextBox", {
	BackgroundTransparency = 1,
	ClearTextOnFocus = false,
	MultiLine = true,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	Font = Enum.Font.GothamMedium,
	TextSize = 16,
	TextColor3 = Color3.new(1, 1, 1),
	PlaceholderText = "Write your feedback here...",
	PlaceholderColor3 = Color3.fromRGB(130, 132, 145),
	Text = "",
	Position = UDim2.fromOffset(10, 8),
	Size = UDim2.new(1, -20, 1, -16),
	Parent = boxFrame,
})
local countLabel = text({
	Text = "0/" .. CONFIG.MaxLength,
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -20, 0, 354),
	Size = UDim2.fromOffset(90, 18),
	TextXAlignment = Enum.TextXAlignment.Right,
	TextColor3 = Color3.fromRGB(170, 172, 185),
	Parent = root,
})
box:GetPropertyChangedSignal("Text"):Connect(function()
	local len = utf8.len(box.Text) or #box.Text
	if len > CONFIG.MaxLength then
		box.Text = string.sub(box.Text, 1, (utf8.offset(box.Text, CONFIG.MaxLength + 1) or (#box.Text + 1)) - 1)
		return
	end
	countLabel.Text = ("%d/%d"):format(len, CONFIG.MaxLength)
end)

-- Status + send
local status = text({
	Text = "",
	Position = UDim2.fromOffset(20, 382),
	Size = UDim2.new(1, -200, 0, 28),
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = root,
})
local sendButton = button({ Text = "Send", Color = GREEN_BUTTON, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -20, 0, 376), Size = UDim2.fromOffset(150, 42), Parent = root })

-- Open / close -------------------------------------------------------------------------------------

local current: { prompt: ProximityPrompt?, anchor: BasePart? }? = nil
local busy = false

local function close()
	if not current then
		return
	end
	if current.prompt then
		current.prompt.Enabled = true
	end
	current = nil
	root.Visible = false
	box:ReleaseFocus()
end

local function open(prompt: ProximityPrompt)
	current = { prompt = prompt, anchor = prompt.Parent :: BasePart }
	prompt.Enabled = false
	status.Text = ""
	paintCategories()
	paintStars()
	root.Visible = true
	openScale.Scale = fitScale * 0.6
	TweenService:Create(openScale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = fitScale }):Play()
end

local function setStatus(message: string?, ok: boolean)
	status.Text = message or ""
	status.TextColor3 = if ok then OK_COLOR else ERROR_COLOR
end

sendButton.Activated:Connect(function()
	if busy then
		return
	end
	local message = box.Text
	local len = utf8.len(message) or #message
	if len < CONFIG.MinLength then
		setStatus(("Please write at least %d characters."):format(CONFIG.MinLength), false)
		return
	end
	busy = true
	sendButton.Text = "Sending..."
	sendButton.BackgroundColor3 = GREY_BUTTON
	local ok, result = pcall(function()
		return FeedbackAction:InvokeServer("Send", { Category = category, Rating = rating, Text = message })
	end)
	busy = false
	sendButton.Text = "Send"
	sendButton.BackgroundColor3 = GREEN_BUTTON
	if not ok or typeof(result) ~= "table" then
		setStatus("Couldn't send right now, try again later.", false)
		return
	end
	setStatus(result.message, result.ok == true)
	if result.ok then
		box.Text = ""
		rating = 0
		paintStars()
		task.delay(1.4, function()
			if current and not busy then
				close()
			end
		end)
	end
end)

closeButton.Activated:Connect(close)

-- True when the prompt sits on a plot this player owns (or on no plot at all, e.g. Workspace.Shops).
local function isMine(prompt: ProximityPrompt): boolean
	local inst = prompt.Parent
	while inst and inst ~= workspace do
		local owner = inst:GetAttribute("OwnerUserId")
		if owner ~= nil then
			return owner == Players.LocalPlayer.UserId
		end
		inst = inst.Parent
	end
	return true
end

ProximityPromptService.PromptTriggered:Connect(function(prompt)
	if prompt.Name == "ShopPrompt" and prompt:GetAttribute("Shop") == "Feedback" and isMine(prompt) then
		open(prompt)
	end
end)

-- Walked away: close.
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < 0.25 or not current then
		return
	end
	acc = 0
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local anchor = current.anchor
	if not hrp or (anchor and (hrp.Position - anchor.Position).Magnitude > ShopConfig.CloseDistance) then
		close()
	end
end)
