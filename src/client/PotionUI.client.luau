-- PotionUI: the potions you have running (PotionConfig) as "buff rings" in the top-right corner, to
-- the left of the weather icon (WeatherGui.Weather).
--
--   * Only running potions show. Each one is a round icon with a ring that empties clockwise as its
--     time runs out (two half rings masked by UIGradients, updated twice a second, no Heartbeat), and
--     the time left under it. The last 30 seconds: red time, blinking ring.
--   * At most MAX_SHOWN icons; the rest fold into a "+N" chip. Tapping the chip shows them all
--     (tap again to fold).
--   * Hover (tap on touch screens) shows the potion's name, what it does and the time left.
-- Potions are drunk from the inventory's "Other" tab (InventoryUI).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local PotionConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PotionConfig"))
local ItemDisplay = require(script.Parent:WaitForChild("ItemDisplay"))
local Theme = require(script.Parent:WaitForChild("Theme"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local FONT = Theme.Font
local STROKE = Theme.Color.Stroke
local PANEL = Theme.Color.Surface
local GAP = 8
local PER_ROW = 4
local MAX_SHOWN = 3 -- icons before the "+N" chip
local RING = 3 -- px, ring thickness
local ENDING = 30 -- seconds: the last ones turn red

local function new(className: string, props: { [string]: any }): any
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function textStroke(parent: Instance, thickness: number)
	new("UIStroke", { Thickness = thickness, Color = STROKE, Parent = parent })
end

local gui = new("ScreenGui", { Name = "PotionGui", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 5, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = playerGui })

-- Row anchored top-right, level with the top of the weather widget; its right edge follows the
-- widget's left edge. Icons fill from the right and wrap downwards.
local row = new("Frame", { Name = "Active", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -90, 0.3, 0), Size = UDim2.fromOffset(400, 80), Parent = gui })
local grid = new("UIGridLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	FillDirectionMaxCells = PER_ROW,
	StartCorner = Enum.StartCorner.TopRight,
	HorizontalAlignment = Enum.HorizontalAlignment.Right,
	VerticalAlignment = Enum.VerticalAlignment.Top,
	SortOrder = Enum.SortOrder.LayoutOrder,
	CellPadding = UDim2.fromOffset(GAP, GAP),
	CellSize = UDim2.fromOffset(44, 60),
	Parent = row,
})

local tooltip = new("TextLabel", {
	Name = "Tooltip",
	AnchorPoint = Vector2.new(0.5, 0),
	Size = UDim2.fromOffset(230, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = PANEL,
	BackgroundTransparency = 0.08,
	Font = FONT,
	TextSize = 16,
	TextWrapped = true,
	RichText = true,
	TextColor3 = Theme.Color.Text,
	Visible = false,
	ZIndex = 20,
	Parent = gui,
})
new("UICorner", { CornerRadius = UDim.new(0, Theme.Radius.Button), Parent = tooltip })
new("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = tooltip })
textStroke(tooltip, 1.5)

-- Icon size: a little smaller than the weather widget, never under 36 px (thumb) or over 56.
local function sizePx(): number
	local weather = playerGui:FindFirstChild("WeatherGui")
	local widget = weather and weather:FindFirstChild("Weather")
	local w = if widget and widget:IsA("GuiObject") and widget.AbsoluteSize.X > 0 then widget.AbsoluteSize.X else 56
	return math.clamp(math.floor(w * 0.8), 36, 56)
end

local function cellHeight(s: number): number
	return math.floor(s * 1.4)
end

-- Line the row up with the weather widget (top-aligned, just left of it).
local function place(cells: number)
	local weather = playerGui:FindFirstChild("WeatherGui")
	local widget = weather and weather:FindFirstChild("Weather")
	local s = sizePx()
	-- Both ScreenGuis ignore the GUI inset; relative positions, so the top-bar inset never puts the
	-- row out of line.
	local rightGap = 16
	local top = UDim.new(0.3, 0)
	if widget and widget:IsA("GuiObject") then
		-- The widget is anchored at its bottom-right corner: its top = Position.Y - its height.
		rightGap = -widget.Position.X.Offset + widget.AbsoluteSize.X + GAP
		top = UDim.new(widget.Position.Y.Scale, widget.Position.Y.Offset - widget.Size.Y.Offset)
	end
	row.AnchorPoint = Vector2.new(1, 0)
	row.Position = UDim2.new(UDim.new(1, -rightGap), top)
	local rows = math.max(1, math.ceil(cells / PER_ROW))
	grid.CellSize = UDim2.fromOffset(s, cellHeight(s))
	row.Size = UDim2.fromOffset(PER_ROW * (s + GAP), rows * (cellHeight(s) + GAP))
end

-- Countdown ring ---------------------------------------------------------------------------------
-- Two clipped halves of a ring stroke. Each stroke's UIGradient is opaque on one side of a line
-- through the centre; rotating it uncovers the arc. Opaque half-plane at rotation r = the arc
-- [r - 180, r] degrees, clockwise from 12 o'clock.

local HALF_MASK = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.499, 0),
	NumberSequenceKeypoint.new(0.5, 1),
	NumberSequenceKeypoint.new(1, 1),
})

type Ring = { set: (fraction: number) -> (), strokes: { UIStroke } }

local function makeRing(parent: GuiObject, color: Color3): Ring
	-- Faint full ring behind (the "track").
	local track = new("Frame", { Name = "Track", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = parent })
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = track })
	new("UIStroke", { Thickness = RING, Color = color, Transparency = 0.75, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = track })

	local strokes: { UIStroke } = {}
	local gradients: { UIGradient } = {}
	for i, side in { 0.5, 0 } do -- 1 = right half (0-180), 2 = left half (180-360)
		local clip = new("Frame", {
			Name = if i == 1 then "Right" else "Left",
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			-- A ring stroke sits outside the frame: let the clip reach RING px past it.
			Position = UDim2.new(side, if side == 0 then -RING else 0, 0, -RING),
			Size = UDim2.new(0.5, RING, 1, RING * 2),
			Parent = parent,
		})
		-- The whole ring, the icon's size, shifted so only this side's half shows inside the clip.
		local circle = new("Frame", { BackgroundTransparency = 1, Parent = clip })
		new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = circle })
		local stroke = new("UIStroke", { Thickness = RING, Color = color, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = circle })
		local gradient = new("UIGradient", { Transparency = HALF_MASK, Parent = stroke })
		table.insert(strokes, stroke)
		table.insert(gradients, gradient)
		local function fit()
			local size = parent.AbsoluteSize
			circle.Size = UDim2.fromOffset(size.X, size.Y)
			circle.Position = UDim2.fromOffset(if side == 0 then RING else -size.X / 2, RING)
		end
		parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
		fit()
	end

	local function set(fraction: number)
		local p = math.clamp(fraction, 0, 1)
		gradients[1].Rotation = math.min(p, 0.5) * 360
		gradients[2].Rotation = 180 + math.max(0, p - 0.5) * 360
	end
	set(1)
	return { set = set, strokes = strokes }
end

-- Icons ------------------------------------------------------------------------------------------

type Icon = { frame: Frame, button: GuiButton, time: TextLabel, ring: Ring }
local icons: { [string]: Icon } = {}
local hovered: string? = nil
local expanded = false

local function showTip(id: string?, frame: GuiObject?)
	hovered = id
	local def = id and PotionConfig.Get(id)
	if not def or not frame then
		tooltip.Visible = false
		return
	end
	tooltip.Text = ('<font color="#%s">%s</font>\n%s\n%s left'):format(def.Color:ToHex(), def.Name, def.Desc, PotionConfig.Clock(PotionConfig.TimeLeft(player, def.Id)))
	-- Below the icon: the row sits near the top of the screen. Kept inside the screen's right edge.
	local view = gui.AbsoluteSize
	local x = frame.AbsolutePosition.X + frame.AbsoluteSize.X / 2
	x = math.min(x, view.X - 115 - 8)
	tooltip.Position = UDim2.fromOffset(x, frame.AbsolutePosition.Y + frame.AbsoluteSize.Y + 8)
	tooltip.Visible = true
end

local function isTouch(): boolean
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

local function popIn(frame: GuiObject)
	local scale = new("UIScale", { Scale = 0.3, Parent = frame })
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function makeIcon(def: PotionConfig.PotionDef, order: number): Icon
	local frame = new("Frame", { Name = def.Id, BackgroundTransparency = 1, LayoutOrder = order, Parent = row })
	local button = new("TextButton", {
		Name = "Icon",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.15,
		Parent = frame,
	})
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = button })
	local view = new("ViewportFrame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.78, 0.78), Parent = button })
	ItemDisplay.FillPotionViewport(view, def.Id)
	local ring = makeRing(button, def.Color)
	local time = new("TextLabel", {
		Name = "Time",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(1.5, 0, 0.26, 0),
		Font = FONT,
		TextScaled = true,
		TextColor3 = Theme.Color.Text,
		Text = "",
		Parent = frame,
	})
	textStroke(time, 2)
	button.MouseEnter:Connect(function()
		showTip(def.Id, button)
	end)
	button.MouseLeave:Connect(function()
		if hovered == def.Id then
			showTip(nil, nil)
		end
	end)
	button.Activated:Connect(function()
		if isTouch() then
			showTip(if hovered == def.Id then nil else def.Id, button)
		end
	end)
	popIn(frame)
	return { frame = frame, button = button, time = time, ring = ring }
end

-- "+N" chip: folds the icons past MAX_SHOWN.
local more = new("TextButton", {
	Name = "More",
	AutoButtonColor = false,
	LayoutOrder = 1000,
	BackgroundTransparency = 1,
	Text = "",
	Visible = false,
	Parent = row,
})
local moreFace = new("TextLabel", {
	Name = "Face",
	BackgroundColor3 = PANEL,
	BackgroundTransparency = 0.15,
	Font = FONT,
	TextScaled = true,
	TextColor3 = Theme.Color.Text,
	Text = "+1",
	Parent = more,
})
new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = moreFace })
new("UIStroke", { Thickness = RING, Color = Theme.Color.Secondary, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = moreFace })
new("UIPadding", { PaddingTop = UDim.new(0.22, 0), PaddingBottom = UDim.new(0.22, 0), PaddingLeft = UDim.new(0.15, 0), PaddingRight = UDim.new(0.15, 0), Parent = moreFace })
textStroke(moreFace, 2)

local refresh: () -> ()

more.Activated:Connect(function()
	expanded = not expanded
	showTip(nil, nil)
	refresh()
end)

refresh = function()
	local s = sizePx()
	local active = 0
	for i, def in PotionConfig.Potions do
		local left = PotionConfig.TimeLeft(player, def.Id)
		local icon = icons[def.Id]
		if left > 0 then
			active += 1
			if not icon then
				icon = makeIcon(def, i)
				icons[def.Id] = icon
			end
			local it = icon :: Icon
			it.button.Size = UDim2.fromOffset(s, s)
			-- Folded away past MAX_SHOWN (unless the list is open).
			it.frame.Visible = expanded or active <= MAX_SHOWN
			it.time.Text = PotionConfig.Clock(left)
			-- One full ring = one potion's duration (stacked time keeps it full).
			it.ring.set(left / def.Duration)
			local ending = left <= ENDING
			it.time.TextColor3 = if ending then Color3.fromRGB(255, 110, 110) else Theme.Color.Text
			local blink = if ending and math.floor(left * 2) % 2 == 0 then 0.6 else 0
			for _, stroke in it.ring.strokes do
				stroke.Transparency = blink
			end
			if hovered == def.Id then
				if it.frame.Visible then
					showTip(def.Id, it.button)
				else
					showTip(nil, nil)
				end
			end
		elseif icon then
			if hovered == def.Id then
				showTip(nil, nil)
			end
			icon.frame:Destroy()
			icons[def.Id] = nil
		end
	end
	local folded = active - MAX_SHOWN
	if folded <= 0 then
		expanded = false
	end
	more.Visible = folded > 0
	moreFace.Size = UDim2.fromOffset(s, s)
	moreFace.Text = if expanded then "-" else "+" .. folded
	local cells = if expanded then active + 1 else math.min(active, MAX_SHOWN) + (if folded > 0 then 1 else 0)
	place(cells)
end

for _, def in PotionConfig.Potions do
	player:GetAttributeChangedSignal(PotionConfig.AttributePrefix .. def.Id):Connect(refresh)
end
task.spawn(function()
	while true do
		refresh()
		task.wait(0.5)
	end
end)
