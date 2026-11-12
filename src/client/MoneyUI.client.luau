-- MoneyUI: the player's cash on the right side of the screen ("$15.7Sx", green on a dark strip).
-- Counts up / down to the new value when leaderstats.Money changes, pops a little, and shows a
-- floating "+$X" for gains.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))

local player = Players.LocalPlayer
local abbreviate = HeroConfig.Abbreviate

local GREEN = Color3.fromRGB(150, 255, 60)
local OUTLINE = Color3.fromRGB(16, 40, 8)
local FONT = Enum.Font.FredokaOne

local gui = Instance.new("ScreenGui")
gui.Name = "MoneyGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 5
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

-- Dark strip that fades out towards the left.
local strip = Instance.new("Frame")
strip.Name = "Strip"
strip.AnchorPoint = Vector2.new(1, 0.5)
strip.Position = UDim2.new(1, 0, 0.42, 0)
strip.Size = UDim2.fromScale(0.2, 0.065)
strip.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
strip.BackgroundTransparency = 0.35
strip.BorderSizePixel = 0
strip.Parent = gui
local constraint = Instance.new("UISizeConstraint")
constraint.MinSize = Vector2.new(170, 40)
constraint.MaxSize = Vector2.new(330, 70)
constraint.Parent = strip
local fade = Instance.new("UIGradient")
fade.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.35, 0.1),
	NumberSequenceKeypoint.new(1, 0),
})
fade.Parent = strip

local label = Instance.new("TextLabel")
label.Name = "Amount"
label.BackgroundTransparency = 1
label.AnchorPoint = Vector2.new(1, 0.5)
label.Position = UDim2.new(1, -14, 0.5, 0)
label.Size = UDim2.new(0.85, 0, 0.82, 0)
label.Font = FONT
label.TextScaled = true
label.TextXAlignment = Enum.TextXAlignment.Right
label.TextColor3 = GREEN
label.Text = "$0"
label.Parent = strip
local stroke = Instance.new("UIStroke")
stroke.Thickness = 2.5
stroke.Color = OUTLINE
stroke.LineJoinMode = Enum.LineJoinMode.Round
stroke.Parent = label
local scale = Instance.new("UIScale")
scale.Parent = label

-- Count-up ---------------------------------------------------------------------------------------

local shown = Instance.new("NumberValue")
shown.Changed:Connect(function(v)
	label.Text = "$" .. abbreviate(math.max(v, 0))
end)

local function floatGain(amount: number)
	local gain = label:Clone()
	gain:ClearAllChildren()
	local s = stroke:Clone()
	s.Parent = gain
	gain.Name = "Gain"
	gain.Text = "+$" .. abbreviate(amount)
	gain.AnchorPoint = Vector2.new(1, 1)
	gain.Position = UDim2.new(1, -14, 0, 0)
	gain.Size = UDim2.new(0.7, 0, 0.6, 0)
	gain.Parent = strip
	local info = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(gain, info, { Position = UDim2.new(1, -14, 0, -26), TextTransparency = 1 }):Play()
	TweenService:Create(s, info, { Transparency = 1 }):Play()
	task.delay(0.95, function()
		gain:Destroy()
	end)
end

local last: number? = nil

local function onMoney(value: number)
	if last == nil then
		shown.Value = value
	else
		local diff = value - last
		TweenService:Create(shown, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = value }):Play()
		if diff ~= 0 then
			scale.Scale = 1.12
			TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
		if diff > 0 then
			floatGain(diff)
		end
	end
	last = value
end

local stats = player:WaitForChild("leaderstats")
local money = stats:WaitForChild("Money") :: NumberValue
onMoney(money.Value)
money.Changed:Connect(onMoney)
