-- MoneyUI: the player's cash on the right side of the screen ("$15.7Sx").
--
-- The layout lives in StarterGui.MoneyGui (src/gui/MoneyGui.model.json) so it can be moved, resized
-- and restyled in Studio; this script only fills it:
--   MoneyGui.Strip.Amount   TextLabel: "$<money>" (needs a UIScale child for the pop)
--   MoneyGui.Strip.Gain     TextLabel template (hidden): cloned for the floating "+$X" on gains
--   MoneyGui.Strip.Coin     the round coin icon on the pill's left (CoinScale UIScale for the bounce)
-- Counts up / down to the new value when leaderstats.Money changes (longer for bigger gains), and
-- the coin bounces on every gain.

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
local coin = strip:FindFirstChild("Coin")
local coinScale = coin and coin:FindFirstChild("CoinScale") :: UIScale?

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
		-- Small changes tick over quickly; big payouts roll up for a bit longer.
		local ratio = if last > 0 then math.abs(diff) / last else 1
		local duration = math.clamp(0.4 + ratio * 0.6, 0.4, 1)
		TweenService:Create(shown, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = value }):Play()
		if diff ~= 0 then
			scale.Scale = 1.12
			TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
		if diff > 0 then
			floatGain(diff)
			if coinScale then
				coinScale.Scale = 1.3
				TweenService:Create(coinScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
			end
		end
	end
	last = value
end

local stats = player:WaitForChild("leaderstats")
local money = stats:WaitForChild("Money") :: NumberValue
onMoney(money.Value)
money.Changed:Connect(onMoney)
