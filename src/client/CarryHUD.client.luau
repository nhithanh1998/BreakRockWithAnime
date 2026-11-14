-- CarryHUD: small pill on the right, under the money, showing how many materials the player carries
-- ("CarryCount" / "CarryCapacity" player attributes, CarryService) with a fill bar. It pops and
-- shows "+N" when materials are picked up, turns red when full and hides while carrying nothing.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

local FONT = Enum.Font.FredokaOne
local FILL = Color3.fromRGB(240, 180, 50)
local FULL = Color3.fromRGB(235, 70, 60)

local gui = Instance.new("ScreenGui")
gui.Name = "CarryHUD"
gui.ResetOnSpawn = false
gui.DisplayOrder = 5
gui.Parent = player:WaitForChild("PlayerGui")

local pill = Instance.new("Frame")
pill.Name = "Pill"
pill.AnchorPoint = Vector2.new(1, 0)
pill.Position = UDim2.new(1, -16, 0.5, 40)
pill.Size = UDim2.fromOffset(190, 38)
pill.BackgroundColor3 = Color3.fromRGB(30, 32, 40)
pill.BackgroundTransparency = 0.15
pill.Visible = false
pill.Parent = gui
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(1, 0)
corner.Parent = pill
local stroke = Instance.new("UIStroke")
stroke.Thickness = 2.5
stroke.Color = Color3.fromRGB(255, 255, 255)
stroke.Transparency = 0.2
stroke.Parent = pill
local scale = Instance.new("UIScale")
scale.Parent = pill

local barBack = Instance.new("Frame")
barBack.Name = "Bar"
barBack.AnchorPoint = Vector2.new(0, 0.5)
barBack.Position = UDim2.new(0, 44, 0.5, 0)
barBack.Size = UDim2.new(1, -56, 0, 20)
barBack.BackgroundColor3 = Color3.fromRGB(60, 62, 72)
barBack.Parent = pill
local barCorner = Instance.new("UICorner")
barCorner.CornerRadius = UDim.new(1, 0)
barCorner.Parent = barBack
local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = FILL
fill.Parent = barBack
local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(1, 0)
fillCorner.Parent = fill

local function text(props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = FONT
	l.TextScaled = true
	l.TextColor3 = Color3.new(1, 1, 1)
	for k, v in props do
		(l :: any)[k] = v
	end
	local s = Instance.new("UIStroke")
	s.Thickness = 2
	s.Color = Color3.fromRGB(20, 20, 26)
	s.Parent = l
	return l
end

-- A little crate as the icon.
local icon = Instance.new("Frame")
icon.AnchorPoint = Vector2.new(0, 0.5)
icon.Position = UDim2.new(0, 10, 0.5, 0)
icon.Size = UDim2.fromOffset(26, 22)
icon.BackgroundColor3 = Color3.fromRGB(176, 120, 64)
icon.Parent = pill
local iconCorner = Instance.new("UICorner")
iconCorner.CornerRadius = UDim.new(0, 4)
iconCorner.Parent = icon
local iconStroke = Instance.new("UIStroke")
iconStroke.Thickness = 2
iconStroke.Color = Color3.fromRGB(100, 62, 30)
iconStroke.Parent = icon
local band = Instance.new("Frame")
band.AnchorPoint = Vector2.new(0.5, 0.5)
band.Position = UDim2.fromScale(0.5, 0.5)
band.Size = UDim2.new(1, 0, 0, 4)
band.BackgroundColor3 = Color3.fromRGB(100, 62, 30)
band.BorderSizePixel = 0
band.Parent = icon

local amount = text({ Name = "Amount", Size = UDim2.fromScale(1, 1), Text = "0/0", ZIndex = 2, Parent = barBack })
local gain = text({ Name = "Gain", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0, -4), Size = UDim2.fromOffset(120, 26), TextColor3 = FILL, Text = "", Visible = false, Parent = pill })

local lastCount = 0
local gainId = 0

local function draw(animate: boolean)
	local count = player:GetAttribute("CarryCount")
	local capacity = player:GetAttribute("CarryCapacity")
	count = if typeof(count) == "number" then count else 0
	capacity = if typeof(capacity) == "number" and capacity > 0 then capacity else 1
	pill.Visible = count > 0
	amount.Text = ("%d/%d"):format(count, capacity)
	local full = count >= capacity
	fill.BackgroundColor3 = if full then FULL else FILL
	local ratio = math.clamp(count / capacity, 0, 1)
	if animate then
		TweenService:Create(fill, TweenInfo.new(0.15), { Size = UDim2.fromScale(ratio, 1) }):Play()
	else
		fill.Size = UDim2.fromScale(ratio, 1)
	end
	local delta = count - lastCount
	lastCount = count
	if animate and delta ~= 0 then
		scale.Scale = if delta > 0 then 1.12 else 0.92
		TweenService:Create(scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		if delta > 0 then
			gainId += 1
			local id = gainId
			gain.Text = "+" .. delta
			gain.Visible = true
			gain.Position = UDim2.new(0.5, 0, 0, -4)
			gain.TextTransparency = 0
			TweenService:Create(gain, TweenInfo.new(0.6), { Position = UDim2.new(0.5, 0, 0, -22), TextTransparency = 1 }):Play()
			task.delay(0.6, function()
				if gainId == id then
					gain.Visible = false
				end
			end)
		end
	end
end

player:GetAttributeChangedSignal("CarryCount"):Connect(function()
	draw(true)
end)
player:GetAttributeChangedSignal("CarryCapacity"):Connect(function()
	draw(true)
end)
lastCount = (function()
	local c = player:GetAttribute("CarryCount")
	return if typeof(c) == "number" then c else 0
end)()
draw(false)
