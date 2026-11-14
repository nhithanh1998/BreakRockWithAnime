-- UIStyle: the shared look of the game's windows (the style the chest / inventory windows set).
--
--   UIStyle.Button(button)   3D button: rounded corners, a soft top-to-bottom gloss and a darker
--                            "lip" just under it (a sibling frame that follows the button), so it
--                            looks like it can be pressed. Buttons inside a UIListLayout / UIGridLayout
--                            get no lip (it would take a layout cell) — only the corners and gloss.
--   UIStyle.Close(button)    the red X button of every window (UIStyle.Button + red colours).
--   UIStyle.Panel(frame)     window body: 14 px corners and a dark border.
--   UIStyle.Window(opts)     the common window template: ScreenGui + panel + header (title, X) + body,
--                            fit to the screen with Theme.FitScale, pop-in / pop-out tweens,
--                            registered with UIManager (one window at a time).
--   UIStyle.Lock(btn, ...)   "locked feature" cover: dark veil, lock and "Zone N" (progressive unlock).
--   UIStyle.Label(...)       a label in the game font with the dark outline.
--
-- Safe to call more than once on the same instance.

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent:WaitForChild("Theme"))
local UIManager = require(script.Parent:WaitForChild("UIManager"))

local UIStyle = {}

UIStyle.CORNER = 10 -- buttons
UIStyle.PANEL_CORNER = 14
UIStyle.LIP = 4 -- px the lip shows under a button
UIStyle.CLOSE_COLOR = Theme.Color.Danger
UIStyle.CLOSE_DARK = Theme.Color.DangerDark
UIStyle.CLOSE_MIN = 40 -- px, smallest X button (touch target)
UIStyle.PANEL_BORDER = Theme.Color.Stroke

local LAYOUTS = { "UIListLayout", "UIGridLayout", "UITableLayout", "UIPageLayout" }

local function inLayout(parent: Instance): boolean
	for _, name in LAYOUTS do
		if parent:FindFirstChildOfClass(name) then
			return true
		end
	end
	return false
end

local function darken(c: Color3): Color3
	return c:Lerp(Color3.new(0, 0, 0), 0.45)
end

-- Rounds a corner up to at least `radius` px (keeps scale-based / bigger corners as they are).
local function ensureCorner(inst: GuiObject, radius: number)
	local corner = inst:FindFirstChildOfClass("UICorner")
	if not corner then
		corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, radius)
		corner.Parent = inst
	elseif corner.CornerRadius.Scale == 0 and corner.CornerRadius.Offset < radius then
		corner.CornerRadius = UDim.new(0, radius)
	end
end

local function addLip(button: GuiObject)
	local parent = button.Parent
	if not parent or not parent:IsA("GuiBase2d") or inLayout(parent) then
		return
	end
	local lip = Instance.new("Frame")
	lip.Name = button.Name .. "Lip"
	lip.BorderSizePixel = 0
	lip.Active = false
	local corner = button:FindFirstChildOfClass("UICorner")
	if corner then
		corner:Clone().Parent = lip
	end
	for _, c in button:GetChildren() do
		if c:IsA("UIAspectRatioConstraint") or c:IsA("UISizeConstraint") then
			c:Clone().Parent = lip
		end
	end
	local function sync()
		lip.AnchorPoint = button.AnchorPoint
		lip.Position = button.Position + UDim2.fromOffset(0, UIStyle.LIP)
		lip.Size = button.Size
		lip.Rotation = button.Rotation
		lip.ZIndex = button.ZIndex - 1
		lip.Visible = button.Visible
		lip.BackgroundColor3 = darken(button.BackgroundColor3)
		lip.BackgroundTransparency = button.BackgroundTransparency
	end
	sync()
	for _, prop in { "AnchorPoint", "Position", "Size", "Rotation", "ZIndex", "Visible", "BackgroundColor3", "BackgroundTransparency" } do
		button:GetPropertyChangedSignal(prop):Connect(sync)
	end
	button.AncestryChanged:Connect(function()
		if button.Parent then
			lip.Parent = button.Parent
		else
			lip.Parent = nil
		end
	end)
	button.Destroying:Connect(function()
		lip:Destroy()
	end)
	lip.Parent = parent
end

function UIStyle.Button(button: GuiObject)
	if button:GetAttribute("Styled") then
		return
	end
	button:SetAttribute("Styled", true)
	ensureCorner(button, UIStyle.CORNER)
	if not button:FindFirstChildOfClass("UIGradient") then
		local gloss = Instance.new("UIGradient")
		gloss.Name = "Gloss"
		gloss.Rotation = 90
		gloss.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(205, 205, 205))
		gloss.Parent = button
	end
	if button.Parent then
		addLip(button)
	else
		-- Built before being parented: add the lip once it lands somewhere.
		local conn: RBXScriptConnection
		conn = button.AncestryChanged:Connect(function()
			if button.Parent then
				conn:Disconnect()
				addLip(button)
			end
		end)
	end
end

function UIStyle.Close(button: GuiObject)
	button.BackgroundColor3 = UIStyle.CLOSE_COLOR
	for _, s in button:GetChildren() do
		if s:IsA("UIStroke") and s.ApplyStrokeMode == Enum.ApplyStrokeMode.Border then
			s.Color = UIStyle.CLOSE_DARK
		end
	end
	-- Thumb-sized on phones: never smaller than 40x40 px (added before Button so the lip copies it).
	if not button:FindFirstChildOfClass("UISizeConstraint") then
		local c = Instance.new("UISizeConstraint")
		c.MinSize = Vector2.new(UIStyle.CLOSE_MIN, UIStyle.CLOSE_MIN)
		c.Parent = button
	end
	UIStyle.Button(button)
end

function UIStyle.Panel(frame: GuiObject)
	ensureCorner(frame, UIStyle.PANEL_CORNER)
	local border: UIStroke? = nil
	for _, s in frame:GetChildren() do
		if s:IsA("UIStroke") and s.ApplyStrokeMode == Enum.ApplyStrokeMode.Border then
			border = s
		end
	end
	if not border then
		local s = Instance.new("UIStroke")
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		s.Parent = frame
		border = s
	end
	local b = border :: UIStroke
	b.Color = UIStyle.PANEL_BORDER
	b.Thickness = math.max(b.Thickness, 3)
end

-- Window template ------------------------------------------------------------------------------------

export type WindowOptions = {
	Name: string, -- ScreenGui name ("ShopHubGui") and UIManager name
	Title: string,
	Size: Vector2, -- design size on PC (px, before the UIScale)
	PhoneSize: Vector2?, -- design size on phones (defaults to Size); smaller = bigger text on phones
	DisplayOrder: number?,
	OnOpen: (() -> ())?,
	OnClose: (() -> ())?,
}

export type Window = {
	gui: ScreenGui,
	root: Frame,
	header: Frame,
	title: TextLabel,
	close: TextButton,
	body: Frame,
	scale: UIScale,
	phone: boolean,
	Open: () -> (),
	Close: () -> (),
	IsOpen: () -> boolean,
}

UIStyle.HEADER = 56 -- px (design) on PC
UIStyle.HEADER_PHONE = 44

-- A label in the game's font with the dark outline every text uses.
function UIStyle.Label(text: string, size: number, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Theme.Font
	l.Text = text
	l.TextSize = size
	l.TextColor3 = color or Theme.Color.Text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextWrapped = true
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Color.Stroke
	stroke.Thickness = 1.5
	stroke.Parent = l
	return l
end

function UIStyle.Window(opts: WindowOptions): Window
	local player = game:GetService("Players").LocalPlayer
	local phone = Theme.IsPhone()
	local design = if phone and opts.PhoneSize then opts.PhoneSize else opts.Size
	local headerH = if phone then UIStyle.HEADER_PHONE else UIStyle.HEADER

	local gui = Instance.new("ScreenGui")
	gui.Name = opts.Name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = opts.DisplayOrder or 12

	local root = Instance.new("Frame")
	root.Name = "Window"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, if phone then 0.5 else 0.46) -- PC: clears the hotbar
	root.Size = UDim2.fromOffset(design.X, design.Y)
	root.BackgroundColor3 = Theme.Color.Surface
	root.Visible = false
	root.Active = true -- clicks on the window never reach the world
	root.Parent = gui
	ensureCorner(root, Theme.Radius.Window)
	UIStyle.Panel(root)

	local scale = Instance.new("UIScale")
	scale.Parent = root

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, headerH)
	header.Parent = root

	local title = UIStyle.Label(opts.Title, if phone then Theme.Text.Header else Theme.Text.Title)
	title.Name = "Title"
	title.Position = UDim2.fromOffset(Theme.Space.L, 0)
	title.Size = UDim2.new(1, -(headerH + Theme.Space.L * 2), 1, 0)
	title.TextWrapped = false
	title.Parent = header

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, -Theme.Space.S, 0.5, 0)
	close.Size = UDim2.fromOffset(headerH - Theme.Space.S, headerH - Theme.Space.S)
	close.Font = Theme.Font
	close.Text = "X"
	close.TextSize = Theme.Text.Header
	close.TextColor3 = Theme.Color.Text
	close.AutoButtonColor = true
	close.Parent = header
	UIStyle.Close(close)

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(0, headerH)
	body.Size = UDim2.new(1, 0, 1, -headerH)
	body.ClipsDescendants = true
	body.Parent = root

	local target = 1
	local function fit()
		target = Theme.FitScale(design)
		if root.Visible then
			scale.Scale = target
		end
	end
	Theme.OnViewChanged(fit)

	local closing = false
	local function doClose()
		if not root.Visible or closing then
			return
		end
		closing = true
		local t = TweenService:Create(scale, Theme.Tween.Close, { Scale = target * 0.85 })
		t:Play()
		t.Completed:Wait()
		root.Visible = false
		closing = false
		if opts.OnClose then
			opts.OnClose()
		end
	end
	local function doOpen()
		if root.Visible and not closing then
			return
		end
		fit()
		scale.Scale = target * 0.85
		root.Visible = true
		TweenService:Create(scale, Theme.Tween.Open, { Scale = target }):Play()
		if opts.OnOpen then
			opts.OnOpen()
		end
	end
	local function closeAsync()
		task.spawn(doClose)
	end
	close.Activated:Connect(closeAsync)

	local win: Window = {
		gui = gui,
		root = root,
		header = header,
		title = title,
		close = close,
		body = body,
		scale = scale,
		phone = phone,
		Open = doOpen,
		Close = closeAsync,
		IsOpen = function()
			return root.Visible
		end,
	}
	gui.Parent = player:WaitForChild("PlayerGui")
	UIManager.Register(opts.Name, root, closeAsync)
	return win
end

-- Progressive unlock -----------------------------------------------------------------------------------

-- Covers `button` with a dark veil, a lock and `text` ("Zone 3") while `isLocked()` is true. Call the
-- returned `refresh` when the condition may have changed. A press on a locked button is eaten by
-- the veil and calls `onLockedPress` (e.g. a toast "Unlocks in Zone 3").
function UIStyle.Lock(button: GuiObject, text: string, isLocked: () -> boolean, onLockedPress: (() -> ())?): () -> ()
	local veil = button:FindFirstChild("LockVeil") :: TextButton?
	if not veil then
		local v = Instance.new("TextButton")
		v.Name = "LockVeil"
		v.Size = UDim2.fromScale(1, 1)
		v.BackgroundColor3 = Color3.new(0, 0, 0)
		v.BackgroundTransparency = 0.35
		v.Text = ""
		v.AutoButtonColor = false
		v.ZIndex = button.ZIndex + 10
		local corner = button:FindFirstChildOfClass("UICorner")
		if corner then
			corner:Clone().Parent = v
		end
		local lock = Instance.new("TextLabel")
		lock.Name = "Lock"
		lock.BackgroundTransparency = 1
		lock.Position = UDim2.fromScale(0, 0.05)
		lock.Size = UDim2.fromScale(1, 0.5)
		lock.Font = Theme.Font
		lock.Text = "🔒"
		lock.TextScaled = true
		lock.ZIndex = v.ZIndex + 1
		lock.Parent = v
		local req = Instance.new("TextLabel")
		req.Name = "Requirement"
		req.BackgroundTransparency = 1
		req.Position = UDim2.fromScale(0.05, 0.58)
		req.Size = UDim2.fromScale(0.9, 0.32)
		req.Font = Theme.Font
		req.TextScaled = true
		req.TextColor3 = Theme.Color.Accent
		req.ZIndex = v.ZIndex + 1
		local stroke = Instance.new("UIStroke")
		stroke.Color = Theme.Color.Stroke
		stroke.Thickness = 1.5
		stroke.Parent = req
		req.Parent = v
		v.Activated:Connect(function()
			local cb = v:GetAttribute("HasCallback") and onLockedPress
			if cb then
				cb()
			end
		end)
		v.Parent = button
		veil = v
	end
	local v = veil :: TextButton
	v:SetAttribute("HasCallback", onLockedPress ~= nil);
	(v:FindFirstChild("Requirement") :: TextLabel).Text = text
	local function refresh()
		v.Visible = isLocked()
	end
	refresh()
	return refresh
end

return UIStyle
