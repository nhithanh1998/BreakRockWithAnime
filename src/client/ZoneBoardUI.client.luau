-- ZoneBoardUI: draws the "Zones" panel floating at the back of every plot, facing into the plot.
-- It is drawn on plot.ZoneBoardSpot (invisible Part, Front face toward the plot): move / resize that
-- part in Studio to move / resize the panel (the layout scales with the part's width). Keep its
-- CanQuery on: the buttons only get clicks through raycasts onto it.
--
-- The SurfaceGui lives in PlayerGui with Adornee = the spot, so its buttons get clicks. Each board
-- shows its plot owner's zones from the plot attributes "Zone" and "UnlockedZones"
-- (ZoneBoardService). Only the owner's own board has working buttons:
--   current zone            -> "Current"
--   other unlocked zones    -> "Swap"       (Remotes.ZoneAction "Travel")
--   next zone               -> "Unlock $X"  (Remotes.ZoneAction "Unlock")
--   zones after that        -> "Locked"
-- Zones and prices are in Shared/ZoneConfig.luau.
-- Colours / font / radii come from the shared Theme (it stays a world board, not a UIStyle.Window):
--   Current = Primary green, Swap = Secondary blue, Unlock = Accent gold (Disabled grey when too
--   poor), Locked = Disabled.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ZoneConfig = require(Shared:WaitForChild("ZoneConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local ZoneAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ZoneAction") :: RemoteFunction

local Theme = require(script.Parent:WaitForChild("Theme"))
local C = Theme.Color

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Plots = workspace:WaitForChild("Plots")

local FONT = Theme.Font
local PANEL_WIDTH_PX = 648 -- the layout below is made for this width; height follows the spot's shape
local ROW_HEIGHT = 112 -- big rows: the board is read from a few studs away
local MESSAGE_TIME = 2

local COLORS = {
	Panel = C.Surface,
	Title = C.Accent,
	Row = C.SurfaceInset,
	RowLocked = C.SurfaceInset,
	LockedText = C.TextDim,
	Current = C.Primary,
	CurrentDark = C.PrimaryDark,
	Swap = C.Secondary,
	SwapDark = C.SecondaryDark,
	Unlock = C.Accent,
	UnlockDark = C.AccentDark,
	Locked = C.Disabled,
	LockedDark = C.Stroke,
	Text = C.Text,
	Stroke = C.Stroke,
	Bad = C.Danger,
	Good = C.Primary,
}

type Board = {
	plot: Model,
	gui: SurfaceGui,
	list: ScrollingFrame,
	message: TextLabel,
	messageToken: number,
	busy: boolean,
	connections: { RBXScriptConnection },
}

local boards: { [Model]: Board } = {}

-- Helpers ----------------------------------------------------------------------------------------

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function stroke(parent: Instance, color: Color3, thickness: number, border: boolean?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	if border then
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	end
	s.Parent = parent
	return s
end

local function label(parent: Instance, text: string, size: number): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = FONT
	l.Text = text
	l.TextSize = size
	l.TextColor3 = COLORS.Text
	l.Parent = parent
	stroke(l, COLORS.Stroke, 3)
	return l
end

local function money(): number
	local stats = player:FindFirstChild("leaderstats")
	local value = stats and stats:FindFirstChild("Money")
	return if value and value:IsA("ValueBase") then (value :: any).Value else 0
end

local function ownsPlot(plot: Model): boolean
	return plot:GetAttribute("OwnerUserId") == player.UserId
end

local function showMessage(board: Board, text: string, color: Color3)
	board.messageToken += 1
	local token = board.messageToken
	board.message.Text = text
	board.message.TextColor3 = color
	board.message.Visible = true
	task.delay(MESSAGE_TIME, function()
		if board.messageToken == token then
			board.message.Visible = false
		end
	end)
end

-- Building ---------------------------------------------------------------------------------------

local function buildGui(plot: Model, spot: BasePart): Board
	local gui = Instance.new("SurfaceGui")
	gui.Name = "ZoneBoard_" .. plot.Name
	gui.Adornee = spot
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = PANEL_WIDTH_PX / math.max(spot.Size.X, 1)
	gui.LightInfluence = 0
	gui.MaxDistance = 300
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ResetOnSpawn = false

	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = COLORS.Panel
	panel.BackgroundTransparency = 0.12 -- solid enough that the text reads against the world behind
	panel.BorderSizePixel = 0
	panel.Parent = gui
	corner(panel, Theme.Radius.Window * 2) -- board pixels are ~2x screen pixels
	stroke(panel, C.Stroke, 6, true)

	local title = label(panel, "ZONES", 88)
	title.Size = UDim2.new(1, 0, 0, 110)
	title.Position = UDim2.fromOffset(0, 8)
	title.TextColor3 = COLORS.Title
	local titleStroke = title:FindFirstChildOfClass("UIStroke")
	if titleStroke then
		titleStroke.Thickness = 5
	end

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.fromOffset(24, 125)
	list.Size = UDim2.new(1, -48, 1, -205)
	list.ScrollBarThickness = 10
	list.ScrollBarImageColor3 = C.TextDim
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 12)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 16)
	pad.Parent = list

	local message = label(panel, "", 46)
	message.Size = UDim2.new(1, -40, 0, 60)
	message.Position = UDim2.new(0, 20, 1, -72)
	message.Visible = false

	return {
		plot = plot,
		gui = gui,
		list = list,
		message = message,
		messageToken = 0,
		busy = false,
		connections = {},
	}
end

local function send(board: Board, action: string, zone: number)
	if board.busy then
		return
	end
	board.busy = true
	local ok, result, msg = pcall(function()
		return ZoneAction:InvokeServer(action, zone)
	end)
	board.busy = false
	if not ok then
		showMessage(board, "Try again!", COLORS.Bad)
	elseif result then
		local info = ZoneConfig.Get(zone)
		showMessage(board, if action == "Unlock" then ("Unlocked %s!"):format(info and info.Name or "zone") else ("Welcome to %s!"):format(info and info.Name or "zone"), COLORS.Good)
	elseif msg then
		showMessage(board, msg, COLORS.Bad)
	end
end

local function makeButton(row: Frame, text: string, color: Color3, dark: Color3, active: boolean): TextButton
	local button = Instance.new("TextButton")
	button.Name = "Action"
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, -12, 0.5, 0)
	button.Size = UDim2.fromOffset(220, 76)
	button.BackgroundColor3 = color
	button.AutoButtonColor = active
	button.Active = active
	button.Font = FONT
	button.Text = text
	button.TextSize = 38
	button.TextScaled = false
	button.TextColor3 = COLORS.Text
	button.ZIndex = 3
	button.Parent = row
	corner(button, Theme.Radius.Button)
	stroke(button, dark, 3, true)
	local textStroke = stroke(button, COLORS.Stroke, 2)
	textStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	if active then
		local scale = Instance.new("UIScale")
		scale.Parent = button
		local info = TweenInfo.new(0.12)
		button.MouseEnter:Connect(function()
			TweenService:Create(scale, info, { Scale = 1.06 }):Play()
		end)
		button.MouseLeave:Connect(function()
			TweenService:Create(scale, info, { Scale = 1 }):Play()
		end)
	end
	return button
end

local function makeRow(board: Board, zone: number, info: ZoneConfig.ZoneInfo?, state: string)
	local row = Instance.new("Frame")
	row.Name = "Zone" .. zone
	row.LayoutOrder = zone
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundColor3 = if state == "Locked" or state == "Soon" then COLORS.RowLocked else COLORS.Row
	row.BorderSizePixel = 0
	row.Parent = board.list
	corner(row, Theme.Radius.Card)
	if state == "Current" then
		stroke(row, COLORS.Current, 5, true)
	else
		stroke(row, COLORS.Stroke, 2, true)
	end

	-- Coloured badge with the zone number (or ? for locked / coming soon).
	local badge = Instance.new("Frame")
	badge.Size = UDim2.fromOffset(ROW_HEIGHT - 20, ROW_HEIGHT - 20)
	badge.Position = UDim2.fromOffset(10, 10)
	badge.BackgroundColor3 = if info and state ~= "Locked" then info.Color else COLORS.Locked
	badge.Parent = row
	corner(badge, Theme.Radius.Button)
	stroke(badge, COLORS.Stroke, 2, true)
	local badgeText = label(badge, if state == "Soon" then "?" else tostring(zone), 52)
	badgeText.Size = UDim2.fromScale(1, 1)

	local nameText = if state == "Soon" then (ZoneConfig.ComingSoonText or "") elseif state == "Locked" then "???" else (info :: ZoneConfig.ZoneInfo).Name
	local name = label(row, nameText, 48)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Position = UDim2.fromOffset(ROW_HEIGHT + 6, 0)
	name.Size = UDim2.new(1, -(ROW_HEIGHT + 6 + 240), 1, 0)
	name.TextScaled = true
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = 48
	limit.MinTextSize = 26
	limit.Parent = name
	if state == "Locked" or state == "Soon" then
		name.TextColor3 = COLORS.LockedText
	end

	local mine = ownsPlot(board.plot)
	if state == "Current" then
		makeButton(row, "Current", COLORS.Current, COLORS.CurrentDark, false)
	elseif state == "Swap" then
		local button = makeButton(row, "Swap", COLORS.Swap, COLORS.SwapDark, mine)
		if mine then
			button.Activated:Connect(function()
				send(board, "Travel", zone)
			end)
		end
	elseif state == "Unlock" then
		local price = (info :: ZoneConfig.ZoneInfo).Price
		local poor = mine and money() < price
		local button = makeButton(row, "Unlock $" .. HeroConfig.Abbreviate(price), if poor then COLORS.Locked else COLORS.Unlock, if poor then COLORS.LockedDark else COLORS.UnlockDark, mine)
		if poor then
			button.TextColor3 = C.Accent
		end
		if mine then
			button.Activated:Connect(function()
				send(board, "Unlock", zone)
			end)
		end
	elseif state == "Locked" then
		makeButton(row, "Locked", COLORS.Locked, COLORS.LockedDark, false)
	end
end

local function render(board: Board)
	for _, child in board.list:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local plot = board.plot
	local current = plot:GetAttribute("Zone") or 1
	local unlocked = plot:GetAttribute("UnlockedZones") or 1
	for zone = 1, ZoneConfig.Count() do
		local state
		if zone == current then
			state = "Current"
		elseif zone <= unlocked then
			state = "Swap"
		elseif zone == unlocked + 1 then
			state = "Unlock"
		else
			state = "Locked"
		end
		makeRow(board, zone, ZoneConfig.Get(zone), state)
	end
	if ZoneConfig.ComingSoonText then
		makeRow(board, ZoneConfig.Count() + 1, nil, "Soon")
	end
end

-- Plots ------------------------------------------------------------------------------------------

local function removeBoard(plot: Model)
	local board = boards[plot]
	if not board then
		return
	end
	boards[plot] = nil
	for _, c in board.connections do
		c:Disconnect()
	end
	board.gui:Destroy()
end

local function addBoard(plot: Instance)
	if not plot:IsA("Model") or boards[plot] then
		return
	end
	local spot = plot:WaitForChild("ZoneBoardSpot", 30)
	if not spot or not spot:IsA("BasePart") or boards[plot] then
		return
	end
	-- SurfaceGui clicks are raycasts onto the adornee: the spot must be queryable.
	spot.CanQuery = true
	local board = buildGui(plot, spot)
	boards[plot] = board
	render(board)
	-- Unlocking changes "UnlockedZones" and "Zone" together: rebuild the rows once, not per attribute.
	local renderQueued = false
	for _, attr in { "Zone", "UnlockedZones", "OwnerUserId" } do
		table.insert(board.connections, plot:GetAttributeChangedSignal(attr):Connect(function()
			if renderQueued then
				return
			end
			renderQueued = true
			task.defer(function()
				renderQueued = false
				if boards[plot] == board then
					render(board)
				end
			end)
		end))
	end
	table.insert(board.connections, plot.AncestryChanged:Connect(function()
		if not plot:IsDescendantOf(workspace) then
			removeBoard(plot)
		end
	end))
	board.gui.Parent = playerGui
end

-- Re-colour the unlock price when the player's money changes enough to afford it.
local function watchMoney()
	local stats = player:WaitForChild("leaderstats", 30)
	local value = stats and stats:WaitForChild("Money", 30)
	if not value then
		return
	end
	local couldAfford: boolean? = nil
	value.Changed:Connect(function()
		for plot, board in boards do
			if ownsPlot(plot) then
				local unlocked = plot:GetAttribute("UnlockedZones") or 1
				local info = ZoneConfig.Get(unlocked + 1)
				local can = info ~= nil and money() >= info.Price
				if can ~= couldAfford then
					couldAfford = can
					render(board)
				end
			end
		end
	end)
end

for _, plot in Plots:GetChildren() do
	task.spawn(addBoard, plot)
end
Plots.ChildAdded:Connect(addBoard)
task.spawn(watchMoney)
