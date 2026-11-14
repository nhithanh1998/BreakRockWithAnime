-- SlotPromptUI: draws the hero pad prompts (ProximityPrompt "HeroSlotPrompt", Style = Custom, made by
-- HeroSlotService) and the shop prompts ("ShopPrompt", ShopService): a dark panel with a green key square, the ObjectText small and grey on top and
-- the ActionText big and white below ("Empty Slot" / "Place Awakened Shrine King").
-- Holding the key fills the square; the action happens once the hold completes (HoldDuration).
-- "Unlock Slot For 5K Cash!" shows the price in green. Only the plot's owner sees the prompts.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

-- Prompts drawn by this script (all Style = Custom): hero pads, the shops, the Devil Tree (FruitService)
-- and the Farm Stand's "Manage Stand" (StandService).
local PROMPT_NAMES = { HeroSlotPrompt = true, ShopPrompt = true, FruitPrompt = true, StandPrompt = true }

local PANEL_COLOR = Color3.fromRGB(22, 24, 30)
local PANEL_STROKE = Color3.fromRGB(70, 72, 82)
local KEY_COLOR = Color3.fromRGB(34, 110, 58)
local KEY_STROKE = Color3.fromRGB(80, 210, 120)
local KEY_FILL = Color3.fromRGB(90, 225, 130)
local OBJECT_COLOR = Color3.fromRGB(190, 192, 200)
local ACTION_COLOR = Color3.fromRGB(255, 255, 255)
local PRICE_COLOR = "#5BE36B"

local HEIGHT = 66 -- design height in pixels (layout below is in pixels at this size)
local HEIGHT_STUDS = 1.98 -- real height in the world: the panel gets smaller the further away it is
local KEY_SIZE = 46
local TEXT_LEFT = 12 + KEY_SIZE + 14
local OBJECT_SIZE = 15
local ACTION_SIZE = 21
local OBJECT_FONT = Enum.Font.GothamMedium
local ACTION_FONT = Enum.Font.GothamBold

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- True when the prompt sits on a plot this player owns (or on no plot at all).
local function isMine(prompt: ProximityPrompt): boolean
	local inst = prompt.Parent
	while inst and inst ~= workspace do
		local owner = inst:GetAttribute("OwnerUserId")
		if owner ~= nil then
			return owner == player.UserId
		end
		inst = inst.Parent
	end
	return true
end

local function keyText(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType): string
	if inputType == Enum.ProximityPromptInputType.Touch then
		return "TAP"
	elseif inputType == Enum.ProximityPromptInputType.Gamepad then
		return (prompt.GamepadKeyCode.Name:gsub("^Button", ""))
	end
	local text = UserInputService:GetStringForKeyCode(prompt.KeyboardKeyCode)
	return if text ~= "" then text else prompt.KeyboardKeyCode.Name
end

-- "Unlock Slot For 5K Cash!" -> price part in green.
local function richAction(text: string): string
	local head, price = text:match("^(.-)(%S+ Cash!)$")
	if head and price then
		return ("%s<font color=\"%s\">%s</font>"):format(head, PRICE_COLOR, price)
	end
	return text
end

local function label(parent: Instance, font: Enum.Font, size: number, color: Color3, y: number): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = font
	l.TextSize = size
	l.TextColor3 = color
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.Position = UDim2.fromOffset(TEXT_LEFT, y)
	l.Size = UDim2.new(1, -TEXT_LEFT - 12, 0, size + 4)
	l.Parent = parent
	return l
end

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function stroke(parent: Instance, color: Color3, thickness: number, transparency: number)
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency
	s.Parent = parent
end

local function textWidth(text: string, size: number, font: Enum.Font): number
	return TextService:GetTextSize(text, size, font, Vector2.new(2000, 100)).X
end

local function build(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType): () -> ()
	local connections: { RBXScriptConnection } = {}

	local gui = Instance.new("BillboardGui")
	gui.Name = "SlotPrompt"
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.StudsOffset = Vector3.new(0, 1.2, 0)
	gui.Adornee = prompt.Parent :: Instance
	gui.Active = inputType == Enum.ProximityPromptInputType.Touch

	-- The billboard is sized in studs (shrinks with distance); the panel is laid out in pixels at a
	-- HEIGHT-px design size and scaled to whatever the billboard currently covers on screen.
	local holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Parent = gui
	local fit = Instance.new("UIScale")
	fit.Name = "Fit"
	fit.Parent = holder
	table.insert(connections, RunService.RenderStepped:Connect(function()
		fit.Scale = math.max(gui.AbsoluteSize.Y / HEIGHT, 0.01)
	end))

	local panel = Instance.new("TextButton")
	panel.Name = "Panel"
	panel.Text = ""
	panel.AutoButtonColor = false
	panel.Active = gui.Active
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BackgroundTransparency = 0.18
	panel.Size = UDim2.fromScale(1, 1)
	panel.Parent = holder
	corner(panel, 8)
	stroke(panel, PANEL_STROKE, 1.5, 0.35)
	local scale = Instance.new("UIScale")
	scale.Scale = 0.6
	scale.Parent = panel

	local key = Instance.new("Frame")
	key.Name = "Key"
	key.AnchorPoint = Vector2.new(0, 0.5)
	key.Position = UDim2.new(0, 12, 0.5, 0)
	key.Size = UDim2.fromOffset(KEY_SIZE, KEY_SIZE)
	key.BackgroundColor3 = KEY_COLOR
	key.ClipsDescendants = true
	key.Parent = panel
	corner(key, 4)
	stroke(key, KEY_STROKE, 2, 0)

	-- Fills up from the bottom while the key is held.
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 1)
	fill.Position = UDim2.fromScale(0, 1)
	fill.Size = UDim2.fromScale(1, 0)
	fill.BackgroundColor3 = KEY_FILL
	fill.BackgroundTransparency = 0.35
	fill.BorderSizePixel = 0
	fill.Parent = key

	local keyLabel = Instance.new("TextLabel")
	keyLabel.BackgroundTransparency = 1
	keyLabel.Size = UDim2.fromScale(1, 1)
	keyLabel.Font = ACTION_FONT
	keyLabel.TextColor3 = ACTION_COLOR
	keyLabel.Text = keyText(prompt, inputType)
	keyLabel.TextSize = if #keyLabel.Text > 1 then 15 else 24
	keyLabel.ZIndex = 2
	keyLabel.Parent = key

	local objectLabel = label(panel, OBJECT_FONT, OBJECT_SIZE, OBJECT_COLOR, 10)
	local actionLabel = label(panel, ACTION_FONT, ACTION_SIZE, ACTION_COLOR, 30)
	actionLabel.RichText = true

	local function updateText()
		objectLabel.Text = prompt.ObjectText
		actionLabel.Text = richAction(prompt.ActionText)
		local hasObject = prompt.ObjectText ~= ""
		objectLabel.Visible = hasObject
		actionLabel.Position = UDim2.fromOffset(TEXT_LEFT, if hasObject then 30 else (HEIGHT - ACTION_SIZE - 4) / 2)
		local width = math.max(textWidth(prompt.ObjectText, OBJECT_SIZE, OBJECT_FONT), textWidth(prompt.ActionText, ACTION_SIZE, ACTION_FONT))
		local designWidth = math.max(TEXT_LEFT + width + 18, 200)
		holder.Size = UDim2.fromOffset(designWidth, HEIGHT)
		gui.Size = UDim2.fromScale(designWidth / HEIGHT * HEIGHT_STUDS, HEIGHT_STUDS)
		fit.Scale = math.max(gui.AbsoluteSize.Y / HEIGHT, 0.01)
	end
	updateText()
	table.insert(connections, prompt:GetPropertyChangedSignal("ObjectText"):Connect(updateText))
	table.insert(connections, prompt:GetPropertyChangedSignal("ActionText"):Connect(updateText))

	local fillTween: Tween? = nil
	local function setFill(target: number, time: number)
		if fillTween then
			fillTween:Cancel()
		end
		fillTween = TweenService:Create(fill, TweenInfo.new(time, Enum.EasingStyle.Linear), { Size = UDim2.fromScale(1, target) })
		fillTween:Play()
	end
	table.insert(connections, prompt.PromptButtonHoldBegan:Connect(function()
		setFill(1, prompt.HoldDuration)
	end))
	table.insert(connections, prompt.PromptButtonHoldEnded:Connect(function()
		setFill(0, 0.12)
	end))
	table.insert(connections, prompt.Triggered:Connect(function()
		setFill(0, 0.12)
		scale.Scale = 1.12
		TweenService:Create(scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end))

	-- Touch: hold the panel itself.
	if gui.Active then
		table.insert(connections, panel.InputBegan:Connect(function(input)
			local t = input.UserInputType
			if (t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1) and input.UserInputState ~= Enum.UserInputState.Change then
				prompt:InputHoldBegin()
			end
		end))
		table.insert(connections, panel.InputEnded:Connect(function(input)
			local t = input.UserInputType
			if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
				prompt:InputHoldEnd()
			end
		end))
	end

	gui.Parent = playerGui -- billboards render straight from PlayerGui
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	return function()
		for _, c in connections do
			c:Disconnect()
		end
		gui:Destroy()
	end
end

ProximityPromptService.PromptShown:Connect(function(prompt, inputType)
	if not PROMPT_NAMES[prompt.Name] or prompt.Style ~= Enum.ProximityPromptStyle.Custom or not isMine(prompt) then
		return
	end
	local cleanup = build(prompt, inputType)
	prompt.PromptHidden:Wait()
	cleanup()
end)
