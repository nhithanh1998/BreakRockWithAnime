--!strict
-- One shared "feel" for every button in the game: it grows a little on hover, shrinks on press
-- and springs back on release. It works on any GuiButton in PlayerGui, including ones built later
-- in code, so individual UI scripts do not need their own hover/press code.
--
-- Skipped:
--   * buttons with the attribute NoPressFX = true (opt out)
--   * buttons that already own a UIScale made by another script (their script animates it)
--   * very large buttons (backdrops, full-screen click catchers)
--   * invisible click areas (no background, no text, no image)

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local HOVER_SCALE = 1.05
local PRESS_SCALE = 0.93
local SCALE_NAME = "PressFX"
local MAX_SCREEN_SHARE = 0.35 -- buttons wider or taller than this share of the screen are skipped

local HOVER_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RELEASE_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local hooked: { [GuiButton]: boolean } = {}

local function isClickArea(button: GuiButton): boolean
	if button.BackgroundTransparency < 0.95 then
		return false
	end
	if button:IsA("TextButton") and button.Text ~= "" and button.TextTransparency < 1 then
		return false
	end
	if button:IsA("ImageButton") and button.Image ~= "" and button.ImageTransparency < 1 then
		return false
	end
	-- A transparent button can still be a real button if it has visible children (icon, label).
	for _, child in button:GetChildren() do
		if child:IsA("GuiObject") and child.Visible then
			return false
		end
	end
	return true
end

local function tooBig(button: GuiButton): boolean
	local screen = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
	local size = button.AbsoluteSize
	return size.X > screen.X * MAX_SCREEN_SHARE or size.Y > screen.Y * MAX_SCREEN_SHARE
end

-- Decided on first touch, not at hook time: sizes and children are only final once shown.
local function getScale(button: GuiButton): UIScale?
	if button:GetAttribute("NoPressFX") or tooBig(button) or isClickArea(button) then
		return nil
	end
	local scale: UIScale? = nil
	for _, child in button:GetChildren() do
		if child:IsA("UIScale") then
			if child.Name ~= SCALE_NAME then
				return nil -- another script owns this button's scale
			end
			scale = child
		end
	end
	if not scale then
		local made = Instance.new("UIScale")
		made.Name = SCALE_NAME
		made.Parent = button
		scale = made
	end
	return scale
end

local function hook(button: GuiButton)
	if hooked[button] then
		return
	end
	hooked[button] = true
	local hovering = false
	local pressed = false

	local function play(target: number, info: TweenInfo)
		local scale = getScale(button)
		if scale then
			TweenService:Create(scale, info, { Scale = target }):Play()
		end
	end

	button.MouseEnter:Connect(function()
		hovering = true
		if not pressed then
			play(HOVER_SCALE, HOVER_INFO)
		end
	end)
	button.MouseLeave:Connect(function()
		hovering = false
		pressed = false
		play(1, HOVER_INFO)
	end)
	button.MouseButton1Down:Connect(function()
		pressed = true
		play(PRESS_SCALE, PRESS_INFO)
	end)
	button.MouseButton1Up:Connect(function()
		pressed = false
		play(if hovering then HOVER_SCALE else 1, RELEASE_INFO)
		-- A click often hides the button (Close, tabs that swap pages) and then MouseLeave never
		-- fires, so it would stay enlarged next time. Check shortly after whether the mouse is
		-- really still on it.
		task.delay(0.3, function()
			if not hovering or pressed then
				return
			end
			local mouse = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
			local stillOver = false
			for _, obj in playerGui:GetGuiObjectsAtPosition(mouse.X, mouse.Y) do
				if obj == button or obj:IsDescendantOf(button) then
					stillOver = true
					break
				end
			end
			if not stillOver then
				hovering = false
				play(1, HOVER_INFO)
			end
		end)
	end)
	-- Touch has no MouseLeave: settle back to 1 after the tap.
	button.TouchTap:Connect(function()
		pressed = false
		hovering = false
		play(1, RELEASE_INFO)
	end)
	-- Another script added its own UIScale later: step aside, two UIScales on one object clash.
	button.ChildAdded:Connect(function(child)
		if child:IsA("UIScale") and child.Name ~= SCALE_NAME then
			local mine = button:FindFirstChild(SCALE_NAME)
			if mine then
				mine:Destroy()
			end
		end
	end)
	button.Destroying:Connect(function()
		hooked[button] = nil
	end)
end

for _, d in playerGui:GetDescendants() do
	if d:IsA("GuiButton") then
		hook(d)
	end
end
playerGui.DescendantAdded:Connect(function(d)
	if d:IsA("GuiButton") then
		hook(d)
	end
end)
