-- Theme: the design tokens every UI script reads (colours, type sizes, radii, spacing, motion).
-- One font (FredokaOne), five main colours. Rarity colours stay in Shared.TreeConfig.RarityColors.
--
--   local Theme = require(script.Parent:WaitForChild("Theme"))
--   button.BackgroundColor3 = Theme.Color.Primary
--   if Theme.IsPhone() then ... end

local UserInputService = game:GetService("UserInputService")

local Theme = {}

Theme.Font = Enum.Font.FredokaOne

-- The 5 main colours (+ the darker shade each one uses for its lip / stroke).
Theme.Color = {
	-- 1. Surface (neutral): window and slot backgrounds.
	Surface = Color3.fromRGB(30, 33, 48), -- #1E2130 window body
	SurfaceInset = Color3.fromRGB(21, 23, 34), -- #151722 slots, lists
	Stroke = Color3.fromRGB(11, 12, 18), -- #0B0C12 borders
	Text = Color3.fromRGB(255, 255, 255),
	TextDim = Color3.fromRGB(160, 166, 186),
	-- 2. Primary green: the one main action of a screen (Buy, Claim, Open).
	Primary = Color3.fromRGB(47, 191, 91), -- #2FBF5B
	PrimaryDark = Color3.fromRGB(30, 138, 62), -- #1E8A3E
	-- 3. Secondary blue: tabs, navigation, info.
	Secondary = Color3.fromRGB(59, 168, 255), -- #3BA8FF
	SecondaryDark = Color3.fromRGB(30, 100, 170),
	-- 4. Accent gold: money, premium, MAX.
	Accent = Color3.fromRGB(255, 201, 60), -- #FFC93C
	AccentDark = Color3.fromRGB(170, 120, 20),
	-- 5. Danger red: close, warnings, notification dots.
	Danger = Color3.fromRGB(239, 75, 60), -- #EF4B3C
	DangerDark = Color3.fromRGB(150, 35, 25),
	-- Disabled / not affordable.
	Disabled = Color3.fromRGB(90, 92, 102),
}

-- Type scale at the 1280x720 design size (px). Never below Small on screen.
Theme.Text = {
	Huge = 48, -- big numbers
	Title = 32,
	Header = 24,
	Body = 18,
	Small = 14, -- minimum
}

Theme.Radius = {
	Chip = 8,
	Button = 12,
	Card = 16,
	Window = 20,
}

Theme.Space = { XS = 4, S = 8, M = 12, L = 16, XL = 24 }

Theme.Icon = { S = 20, M = 28, L = 40, XL = 56 }

Theme.TouchMin = 44 -- px, smallest tap target on phones (40 for the X)

-- Motion
Theme.Tween = {
	Open = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	Close = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
	Press = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Hover = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
}

-- A touch device without a keyboard on a small screen (phones, small tablets in landscape).
function Theme.IsPhone(): boolean
	local camera = workspace.CurrentCamera
	local view = if camera then camera.ViewportSize else Vector2.new(1920, 1080)
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and math.min(view.X, view.Y) < 600
end

-- Global UI scale -----------------------------------------------------------------------------------
-- Every window built with UIStyle.Window shares this rule, so one number decides how big the UI is.
-- Windows are drawn at a design size (px) and a UIScale fits them into this part of the screen:
Theme.WindowFit = {
	Phone = Vector2.new(0.9, 0.86),
	PC = Vector2.new(0.62, 0.78),
}
Theme.MaxScale = 1.25 -- never blow a window up more than this on big monitors

function Theme.ViewSize(): Vector2
	local camera = workspace.CurrentCamera
	return if camera then camera.ViewportSize else Vector2.new(1280, 720)
end

-- The UIScale that fits a window drawn at `design` px into the screen.
function Theme.FitScale(design: Vector2): number
	local view = Theme.ViewSize()
	local fit = if Theme.IsPhone() then Theme.WindowFit.Phone else Theme.WindowFit.PC
	return math.min(Theme.MaxScale, view.X * fit.X / design.X, view.Y * fit.Y / design.Y)
end

-- Calls `fn` now and every time the screen size changes (rotation, window resize).
function Theme.OnViewChanged(fn: () -> ()): RBXScriptConnection
	fn()
	local camera = workspace.CurrentCamera :: Camera
	return camera:GetPropertyChangedSignal("ViewportSize"):Connect(fn)
end

return Theme
