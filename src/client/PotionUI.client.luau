-- PotionUI: the potions you have running (PotionConfig), as round icons with a countdown in the
-- bottom-right corner, to the left of the weather icon (WeatherGui.Weather): up to PER_ROW icons per
-- row, further ones stack on a row above (so they never run into the hotbar).
-- Hover (tap on touch screens) shows the potion's name, what it does and the time left.
-- Potions are drunk from the inventory's "Other" tab (InventoryUI).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local PotionConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PotionConfig"))
local ItemDisplay = require(script.Parent:WaitForChild("ItemDisplay"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local FONT = Enum.Font.FredokaOne
local STROKE = Color3.fromRGB(20, 20, 26)
local PANEL = Color3.fromRGB(28, 30, 40)
local GAP = 8
local PER_ROW = 4

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

-- Row anchored bottom-right; its right edge follows the weather widget's left edge.
local row = new("Frame", { Name = "Active", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -90, 1, -16), Size = UDim2.fromOffset(400, 80), Parent = gui })
local grid = new("UIGridLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	FillDirectionMaxCells = PER_ROW,
	StartCorner = Enum.StartCorner.BottomRight,
	HorizontalAlignment = Enum.HorizontalAlignment.Right,
	VerticalAlignment = Enum.VerticalAlignment.Bottom,
	SortOrder = Enum.SortOrder.LayoutOrder,
	CellPadding = UDim2.fromOffset(GAP, GAP),
	CellSize = UDim2.fromOffset(56, 77),
	Parent = row,
})

local tooltip = new("TextLabel", {
	Name = "Tooltip",
	AnchorPoint = Vector2.new(0.5, 1),
	Size = UDim2.fromOffset(230, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = PANEL,
	BackgroundTransparency = 0.08,
	Font = FONT,
	TextSize = 16,
	TextWrapped = true,
	RichText = true,
	TextColor3 = Color3.new(1, 1, 1),
	Visible = false,
	ZIndex = 20,
	Parent = gui,
})
new("UICorner", { CornerRadius = UDim.new(0, 10), Parent = tooltip })
new("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = tooltip })
textStroke(tooltip, 1.5)

local function sizePx(): number
	local weather = playerGui:FindFirstChild("WeatherGui")
	local widget = weather and weather:FindFirstChild("Weather")
	if widget and widget:IsA("GuiObject") and widget.AbsoluteSize.X > 0 then
		return widget.AbsoluteSize.X
	end
	return 56
end

-- Line the row up with the weather widget (same size, just left of it).
local function place()
	local weather = playerGui:FindFirstChild("WeatherGui")
	local widget = weather and weather:FindFirstChild("Weather")
	local s = sizePx()
	-- Same corner offsets as the weather widget (both ScreenGuis ignore the GUI inset), shifted left
	-- by its width. Relative positions, so the top-bar inset never puts the row out of line.
	local rightGap = 16
	local bottomGap = 16
	if widget and widget:IsA("GuiObject") then
		rightGap = -widget.Position.X.Offset + widget.AbsoluteSize.X + GAP
		bottomGap = -widget.Position.Y.Offset
	end
	row.AnchorPoint = Vector2.new(1, 1)
	row.Position = UDim2.new(1, -rightGap, 1, -bottomGap)
	local rows = math.ceil(#PotionConfig.Potions / PER_ROW)
	grid.CellSize = UDim2.fromOffset(s, s * 1.37)
	row.Size = UDim2.fromOffset(PER_ROW * (s + GAP), rows * (s * 1.37 + GAP))
end

type Icon = { frame: Frame, time: TextLabel, ring: UIStroke }
local icons: { [string]: Icon } = {}
local hovered: string? = nil

local function showTip(id: string?, frame: GuiObject?)
	hovered = id
	local def = id and PotionConfig.Get(id)
	if not def or not frame then
		tooltip.Visible = false
		return
	end
	tooltip.Text = ('<font color="#%s">%s</font>\n%s\n%s left'):format(def.Color:ToHex(), def.Name, def.Desc, PotionConfig.Clock(PotionConfig.TimeLeft(player, def.Id)))
	tooltip.Position = UDim2.fromOffset(frame.AbsolutePosition.X + frame.AbsoluteSize.X / 2, frame.AbsolutePosition.Y - 8)
	tooltip.Visible = true
end

local function makeIcon(def: PotionConfig.PotionDef, order: number): Icon
	local s = sizePx()
	local frame = new("Frame", { Name = def.Id, BackgroundTransparency = 1, LayoutOrder = order, Size = UDim2.fromOffset(s, s * 1.37), Parent = row })
	local button = new("TextButton", {
		Name = "Icon",
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromOffset(s, s),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.15,
		Parent = frame,
	})
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = button })
	local ring = new("UIStroke", { Thickness = 3, Color = def.Color, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = button })
	local view = new("ViewportFrame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.8, 0.8), Parent = button })
	ItemDisplay.FillPotionViewport(view, def.Id)
	local time = new("TextLabel", {
		Name = "Time",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(1.6, 0, 0.27, 0),
		Font = FONT,
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
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
		if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
			showTip(if hovered == def.Id then nil else def.Id, button)
		end
	end)
	-- Pop in.
	local scale = new("UIScale", { Scale = 0.3, Parent = frame })
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	return { frame = frame, time = time, ring = ring }
end

local function refresh()
	place()
	for i, def in PotionConfig.Potions do
		local left = PotionConfig.TimeLeft(player, def.Id)
		local icon = icons[def.Id]
		if left > 0 then
			if not icon then
				icon = makeIcon(def, i)
				icons[def.Id] = icon
			end
			local s = sizePx()
			icon.frame.Size = UDim2.fromOffset(s, s * 1.37)
			local button = icon.frame:FindFirstChild("Icon") :: GuiObject?
			if button then
				button.Size = UDim2.fromOffset(s, s)
			end
			icon.time.Text = PotionConfig.Clock(left)
			-- Last 30 seconds: the timer turns red and the ring blinks.
			local ending = left <= 30
			icon.time.TextColor3 = if ending then Color3.fromRGB(255, 110, 110) else Color3.new(1, 1, 1)
			icon.ring.Transparency = if ending and math.floor(left * 2) % 2 == 0 then 0.6 else 0
			if hovered == def.Id and button then
				showTip(def.Id, button)
			end
		elseif icon then
			if hovered == def.Id then
				showTip(nil, nil)
			end
			icon.frame:Destroy()
			icons[def.Id] = nil
		end
	end
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
