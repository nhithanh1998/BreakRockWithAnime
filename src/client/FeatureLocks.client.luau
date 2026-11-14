-- FeatureLocks: progressive unlock on the left sidebar. Each button listed in Shared.UnlockConfig
-- with a Zone gets UIStyle.Lock (dark veil + lock + "Zone N") until the player unlocks that zone.
-- Pressing a locked button only gives it a little shake; the window behind does not open.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UnlockConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UnlockConfig"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))

local player = Players.LocalPlayer
local buttons = player:WaitForChild("PlayerGui"):WaitForChild("LeftSidebar"):WaitForChild("Buttons")

local function shake(button: GuiObject)
	local veil = button:FindFirstChild("LockVeil") :: GuiObject?
	if not veil then
		return
	end
	local info = TweenInfo.new(0.05, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 3, true)
	TweenService:Create(veil, info, { Rotation = 6 }):Play()
end

local refreshers: { () -> () } = {}

for feature, req in UnlockConfig.Features do
	if not req.Zone or req.Zone <= 1 then
		continue
	end
	local button = buttons:WaitForChild(feature, 10) :: GuiObject?
	if not button then
		warn("[FeatureLocks] no sidebar button " .. feature)
		continue
	end
	local b = button :: GuiObject
	table.insert(refreshers, UIStyle.Lock(b, UnlockConfig.Text(feature), function()
		return UnlockConfig.IsLocked(player, feature)
	end, function()
		shake(b)
	end))
end

player:GetAttributeChangedSignal("UnlockedZones"):Connect(function()
	for _, refresh in refreshers do
		refresh()
	end
end)
