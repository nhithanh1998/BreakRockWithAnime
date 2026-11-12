-- MoneyUI: the player's cash on the right side of the screen ("$15.7Sx").
--
-- The layout lives in StarterGui.MoneyGui (src/gui/MoneyGui.model.json) so it can be moved, resized
-- and restyled in Studio; this script only fills it:
--   MoneyGui.Strip.Amount   TextLabel: "$<money>" (needs a UIScale child for the pop)
--   MoneyGui.Strip.Gain     TextLabel template (hidden): cloned for the floating "+$X" on gains
-- Counts up / down to the new value when leaderstats.Money changes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))

local player = Players.LocalPlayer
local abbreviate = HeroConfig.Abbreviate

local gui = player:WaitForChild("PlayerGui"):WaitForChild("MoneyGui") :: ScreenGui
local strip = gui:WaitForChild("Strip") :: Frame
local label = strip:WaitForChild("Amount") :: TextLabel
local gainTemplate = strip:WaitForChild("Gain") :: TextLabel
local scale = label:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
scale.Parent = label

-- Count-up ---------------------------------------------------------------------------------------

local shown = Instance.new("NumberValue")
shown.Changed:Connect(function(v)
	label.Text = "$" .. abbreviate(math.max(v, 0))
end)

local function floatGain(amount: number)
	local gain = gainTemplate:Clone()
	gain.Name = "GainPopup"
	gain.Text = "+$" .. abbreviate(amount)
	gain.Visible = true
	gain.Parent = strip
	local start = gain.Position
	local info = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(gain, info, { Position = start - UDim2.fromOffset(0, 26), TextTransparency = 1 }):Play()
	local s = gain:FindFirstChildOfClass("UIStroke")
	if s then
		TweenService:Create(s, info, { Transparency = 1 }):Play()
	end
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
