-- SkillTreeUI: the skill tree window (trees and nodes from Shared.SkillTreeConfig).
--
-- The window is the common UIStyle.Window (header with title + money + red X, Theme colours, global
-- UIScale, UIManager). The panels inside still come from the Studio-editable layout and are moved
-- into the window's Body at start (the layout's own Window frame, TreeTitle and ExitButton are dropped):
--   StarterGui.SkillTreeGui (src/gui/SkillTreeGui.model.json)
--   StarterGui.LeftSidebar (src/gui/LeftSidebar.model.json)
--     Buttons.Upgrades               opens the window (also the K key); its Badge shows how many
--                                    skills can be upgraded right now (requirements met + affordable)
--     Window.ZoneList                one ZoneTab per tree: Core first, then the zones
--     Window.TreeTitle               name of the open tree
--     Window.TreeArea                the tree view: drag (anywhere on the window's background, not
--                                    on ZoneList / Preview) to pan, wheel / pinch to zoom. No frame or buttons.
--       Canvas (UIScale) . Lines / Nodes   connector lines + node buttons of the open tree
--     Window.Preview                 details of the hovered (else selected) node + Upgrade button
--     Window.ExitButton, Window.Money
--   ReplicatedStorage.SkillTreeTemplates (src/gui/SkillTreeTemplates.model.json)
--     ZoneTab, Node, Line            cloned per tree / node / line segment; their colors are
--                                    attributes on the templates (LockedColor, ActiveColor...)
--
-- Nodes sit on the tree's grid (node.Pos = { column, row }). A line runs from every required node
-- to the node needing it: down, across, down. A line is "active" once that requirement is met.
-- Levels come from player.Skills (SkillTreeService); upgrades go through Remotes.SkillAction.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SkillTreeConfig = require(Shared:WaitForChild("SkillTreeConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local ZoneConfig = require(Shared:WaitForChild("ZoneConfig"))
local SkillAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SkillAction") :: RemoteFunction
local Templates = ReplicatedStorage:WaitForChild("SkillTreeTemplates")
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local Theme = require(script.Parent:WaitForChild("Theme"))

type NodeDef = SkillTreeConfig.NodeDef
type TreeDef = SkillTreeConfig.TreeDef

local player = Players.LocalPlayer
local abbreviate = HeroConfig.Abbreviate

local layoutGui = player:WaitForChild("PlayerGui"):WaitForChild("SkillTreeGui") :: ScreenGui
local sidebar = player.PlayerGui:WaitForChild("LeftSidebar") :: ScreenGui
local upgradesButton = sidebar:WaitForChild("Buttons"):WaitForChild("Upgrades") :: GuiButton
local badge = upgradesButton:WaitForChild("Badge") :: GuiObject
local badgeCount = badge:WaitForChild("Count") :: TextLabel
local layout = layoutGui:WaitForChild("Window") :: Frame
local zoneList = layout:WaitForChild("ZoneList") :: ScrollingFrame
local treeArea = layout:WaitForChild("TreeArea") :: Frame
local canvas = treeArea:WaitForChild("Canvas") :: Frame
local canvasScale = canvas:WaitForChild("UIScale") :: UIScale
local linesFrame = canvas:WaitForChild("Lines") :: Frame
local nodesFrame = canvas:WaitForChild("Nodes") :: Frame
local preview = layout:WaitForChild("Preview") :: Frame
local moneyLabel = layout:WaitForChild("Money") :: TextLabel

local pIcon = preview:WaitForChild("Icon") :: ImageLabel
local pIconText = pIcon:WaitForChild("IconText") :: TextLabel
local pTitle = preview:WaitForChild("Title") :: TextLabel
local pBar = preview:WaitForChild("LevelBar") :: Frame
local pFill = pBar:WaitForChild("Fill") :: Frame
local pBarText = pBar:WaitForChild("Text") :: TextLabel
local pEffect = preview:WaitForChild("Effect") :: TextLabel
local pReqs = preview:WaitForChild("Requirements") :: TextLabel
local pMessage = preview:WaitForChild("Message") :: TextLabel
local upgradeButton = preview:WaitForChild("UpgradeButton") :: TextButton

local C = Theme.Color
local PAD = Theme.Space.L

-- Window ---------------------------------------------------------------------------------------------
-- Open / close side effects are defined further down (they need the pan / zoom state).
local onOpened: () -> ()
local onClosed: () -> ()

local win = UIStyle.Window({
	Name = "SkillTreeGui-Window", -- renamed to SkillTreeGui once the layout gui is gone (NoticeUI)
	Title = "SKILL TREE",
	Size = Vector2.new(1100, UIStyle.HEADER + 600),
	PhoneSize = Vector2.new(800, UIStyle.HEADER_PHONE + 380),
	DisplayOrder = 20,
	OnOpen = function()
		onOpened()
	end,
	OnClose = function()
		onClosed()
	end,
})
local gui = win.gui
local window = win.root
local treeTitle = win.title
local headerH = if win.phone then UIStyle.HEADER_PHONE else UIStyle.HEADER

-- Body: zone tabs (left) | tree view (middle) | preview (right).
zoneList.Position = UDim2.fromOffset(PAD, 0)
zoneList.Size = UDim2.new(0.2, -PAD, 1, -PAD)
zoneList.ScrollBarImageColor3 = C.TextDim
zoneList.Parent = win.body

treeArea.Position = UDim2.new(0.2, PAD, 0, 0)
treeArea.Size = UDim2.new(0.53, -PAD * 3, 1, -PAD)
treeArea.BackgroundColor3 = C.SurfaceInset
treeArea.BackgroundTransparency = 0
treeArea.ClipsDescendants = true -- a panned / zoomed tree stays inside its frame
local areaCorner = treeArea:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
areaCorner.CornerRadius = UDim.new(0, Theme.Radius.Card)
areaCorner.Parent = treeArea
treeArea.Parent = win.body

preview.AnchorPoint = Vector2.new(1, 0)
preview.Position = UDim2.new(1, -PAD, 0, 0)
preview.Size = UDim2.new(0.27, 0, 1, -PAD)
preview.BackgroundColor3 = C.SurfaceInset
preview.BackgroundTransparency = 0
;(preview:FindFirstChildOfClass("UICorner") :: UICorner).CornerRadius = UDim.new(0, Theme.Radius.Card)
;(preview:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = C.Stroke
preview.Parent = win.body

-- Money: gold, in the header left of the X.
moneyLabel.AnchorPoint = Vector2.new(1, 0.5)
moneyLabel.Position = UDim2.new(1, -(headerH + Theme.Space.S), 0.5, 0)
moneyLabel.Size = UDim2.fromOffset(if win.phone then 140 else 180, math.floor(headerH * 0.6))
moneyLabel.TextXAlignment = Enum.TextXAlignment.Right
moneyLabel.TextColor3 = C.Accent
moneyLabel.Font = Theme.Font
;(moneyLabel:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = C.Stroke
moneyLabel.Parent = win.header
treeTitle.Size = UDim2.new(1, -(headerH + Theme.Space.S * 2 + moneyLabel.Size.X.Offset + PAD), 1, 0)

-- Level bar + Upgrade button (Theme): green progress, Upgrade = Primary, else Disabled.
pBar.BackgroundColor3 = C.Surface
;(pBar:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = C.Stroke
pFill.BackgroundColor3 = C.Primary
;(pBarText:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = C.Stroke
upgradeButton:SetAttribute("BuyColor", C.Primary)
upgradeButton:SetAttribute("PoorColor", C.Disabled)
upgradeButton:SetAttribute("DisabledColor", C.Disabled)
UIStyle.Button(upgradeButton)

-- The layout's own frame (full-screen backdrop, TreeTitle, ExitButton) is no longer used.
layoutGui:Destroy()
gui.Name = "SkillTreeGui"

local tabTemplate = Templates:WaitForChild("ZoneTab") :: GuiButton
local nodeTemplate = Templates:WaitForChild("Node") :: GuiButton
local lineTemplate = Templates:WaitForChild("Line") :: Frame

-- Template colours (Theme), set on the client's copies: tabs = Secondary when selected; nodes =
-- grey locked, green available, gold maxed, white ring when selected; lines green once met.
tabTemplate:SetAttribute("SelectedColor", C.Secondary)
tabTemplate:SetAttribute("SelectedStroke", C.SecondaryDark)
tabTemplate:SetAttribute("NormalColor", C.SurfaceInset)
tabTemplate:SetAttribute("NormalStroke", C.Stroke)
;(tabTemplate:FindFirstChildOfClass("UICorner") :: UICorner).CornerRadius = UDim.new(0, Theme.Radius.Button)
nodeTemplate:SetAttribute("LockedColor", C.Disabled)
nodeTemplate:SetAttribute("LockedStroke", C.Stroke)
nodeTemplate:SetAttribute("AvailableColor", C.Primary)
nodeTemplate:SetAttribute("AvailableStroke", C.PrimaryDark)
nodeTemplate:SetAttribute("MaxedColor", C.Accent)
nodeTemplate:SetAttribute("MaxedStroke", C.AccentDark)
nodeTemplate:SetAttribute("SelectedStroke", C.Text)
lineTemplate:SetAttribute("ActiveColor", C.Primary)
lineTemplate:SetAttribute("InactiveColor", C.Disabled)

local skills = player:WaitForChild("Skills") :: Folder
local money = player:WaitForChild("leaderstats"):WaitForChild("Money") :: NumberValue

local GREEN = "#" .. C.Primary:ToHex()
local RED = "#" .. C.Danger:ToHex()
local GREY = "#" .. C.TextDim:ToHex()

local currentTree: TreeDef = SkillTreeConfig.Trees[1]
local selectedId: string? = nil
local hoveredId: string? = nil
local tabs: { [string]: GuiButton } = {}
local nodeButtons: { [string]: GuiButton } = {}
local lines: { { frame: Frame, treeId: string, from: string, level: number } } = {}
local busy = false
local dragMoved = false -- the last press on the tree view became a drag: its release is not a click

-- Helpers --------------------------------------------------------------------------------------------

local function attr(inst: Instance, name: string, fallback: any): any
	local v = inst:GetAttribute(name)
	return if v ~= nil then v else fallback
end

local function getLevel(treeId: string, nodeId: string): number
	local v = skills:FindFirstChild(SkillTreeConfig.Key(treeId, nodeId))
	return if v and v:IsA("IntValue") then v.Value else 0
end

-- Icon can be an asset id (image) or text / emoji.
local function setIcon(image: ImageLabel, text: TextLabel, icon: string)
	local isImage = string.find(icon, "^rbxassetid://") ~= nil or string.find(icon, "^https?://") ~= nil
	image.Image = if isImage then icon else ""
	text.Text = if isImage then "" else icon
end

local function treeProgress(tree: TreeDef): (number, number)
	local have, total = 0, 0
	for _, node in tree.Nodes do
		have += getLevel(tree.Id, node.Id)
		total += node.MaxLevel
	end
	return have, total
end

local function gridSize(tree: TreeDef): (number, number)
	local cols, rows = tree.Columns or 0, tree.Rows or 0
	for _, node in tree.Nodes do
		cols = math.max(cols, math.ceil(node.Pos[1]))
		rows = math.max(rows, math.ceil(node.Pos[2]))
	end
	return math.max(cols, 1), math.max(rows, 1)
end

local function cellCenter(tree: TreeDef, node: NodeDef): (number, number)
	local cols, rows = gridSize(tree)
	return (node.Pos[1] - 0.5) / cols, (node.Pos[2] - 0.5) / rows
end

local function flashMessage(text: string, isError: boolean)
	pMessage.Text = text
	pMessage.TextColor3 = if isError then C.Danger else C.Primary
	local stamp = os.clock()
	pMessage:SetAttribute("Stamp", stamp)
	task.delay(2, function()
		if pMessage:GetAttribute("Stamp") == stamp then
			pMessage.Text = ""
		end
	end)
end

-- Tabs -----------------------------------------------------------------------------------------------

local buildTree: (TreeDef) -> ()
local refresh: () -> ()
local resetView: (boolean) -> ()

local function refreshTabs()
	for _, tree in SkillTreeConfig.Trees do
		local tab = tabs[tree.Id]
		if not tab then
			continue
		end
		local selected = tree.Id == currentTree.Id
		local have, total = treeProgress(tree)
		;(tab:FindFirstChild("Progress") :: TextLabel).Text = ("Research %d/%d"):format(have, total)
		tab.BackgroundColor3 = attr(tabTemplate, if selected then "SelectedColor" else "NormalColor", tab.BackgroundColor3)
		local stroke = tab:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = attr(tabTemplate, if selected then "SelectedStroke" else "NormalStroke", stroke.Color)
		end
	end
end

local function buildTabs()
	for i, tree in SkillTreeConfig.Trees do
		local tab = tabTemplate:Clone()
		tab.Name = tree.Id
		tab.LayoutOrder = i
		;(tab:FindFirstChild("Title") :: TextLabel).Text = tree.Name
		local icon = tab:FindFirstChild("Icon") :: ImageLabel
		setIcon(icon, icon:FindFirstChild("IconText") :: TextLabel, SkillTreeConfig.IconOf(tree))
		tab.Activated:Connect(function()
			if currentTree.Id ~= tree.Id then
				buildTree(tree)
			end
		end)
		tab.Parent = zoneList
		tabs[tree.Id] = tab
	end
end

-- Pan / zoom ---------------------------------------------------------------------------------------
-- Canvas (Lines + Nodes) is centred in TreeArea; `pan` moves it (pixels) and its UIScale zooms it
-- (UIScale scales around the AnchorPoint = the canvas centre). Mouse: drag + wheel. Touch: one finger
-- drags, two fingers pinch.

local MIN_ZOOM, MAX_ZOOM = 0.6, 2.5
local WHEEL_ZOOM_STEP = 1.12
local DRAG_THRESHOLD = 8 -- pixels a press must move before it pans instead of clicking a node
local VIEW_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local zoom = 1
local BASE_POSITION = canvas.Position -- from the layout; pan is added to it
local pan = Vector2.zero

local function areaCenter(): Vector2
	return treeArea.AbsolutePosition + treeArea.AbsoluteSize * Vector2.new(BASE_POSITION.X.Scale, BASE_POSITION.Y.Scale)
end

local function inside(gui: GuiObject, p: Vector2): boolean
	local a, size = gui.AbsolutePosition, gui.AbsoluteSize
	return p.X >= a.X and p.Y >= a.Y and p.X <= a.X + size.X and p.Y <= a.Y + size.Y
end

-- Keeps some of the tree on screen: the canvas centre may move at most half the extra (zoomed)
-- size plus a bit past the area's centre.
local function clampPan(p: Vector2, z: number): Vector2
	local limit = treeArea.AbsoluteSize * (math.max(z - 1, 0) / 2 + 0.35)
	return Vector2.new(math.clamp(p.X, -limit.X, limit.X), math.clamp(p.Y, -limit.Y, limit.Y))
end

local function applyView(animate: boolean)
	local position = UDim2.new(BASE_POSITION.X.Scale, pan.X, BASE_POSITION.Y.Scale, pan.Y)
	if animate then
		TweenService:Create(canvasScale, VIEW_TWEEN, { Scale = zoom }):Play()
		TweenService:Create(canvas, VIEW_TWEEN, { Position = position }):Play()
	else
		canvasScale.Scale = zoom
		canvas.Position = position
	end
end

-- Zoom to `newZoom` keeping the point under `screenPos` (default: the area's centre) in place.
local function zoomAt(newZoom: number, screenPos: Vector2?, animate: boolean?)
	newZoom = math.clamp(newZoom, MIN_ZOOM, MAX_ZOOM)
	local offset = (screenPos or areaCenter()) - areaCenter()
	local point = (offset - pan) / zoom -- that point on the unscaled canvas, from its centre
	zoom = newZoom
	pan = clampPan(offset - point * zoom, zoom)
	applyView(animate == true)
end

local function panBy(delta: Vector2)
	pan = clampPan(pan + delta, zoom)
	applyView(false)
end

resetView = function(animate: boolean)
	zoom = 1
	pan = Vector2.zero
	applyView(animate)
end

-- Presses that started inside the tree view: the mouse, and each finger (touch InputObject -> pos).
local mouseDown: Vector2? = nil
local mouseLast: Vector2? = nil
local touches: { [InputObject]: Vector2 } = {}
local touchStart: Vector2? = nil
local pinchDistance: number? = nil

local function touchList(): { Vector2 }
	local list = {}
	for _, pos in touches do
		table.insert(list, pos)
	end
	return list
end

local function releaseAll()
	mouseDown, mouseLast = nil, nil
	table.clear(touches)
	touchStart, pinchDistance = nil, nil
end

-- The window's own panels and buttons keep their input (the zone list scrolls, the preview has the
-- Upgrade button); a press anywhere else on the window, background included, drags the tree.
local ownInput: { GuiObject } = { zoneList, preview, win.header }

local function onTreeBackground(p: Vector2): boolean
	if not window.Visible or not inside(window, p) then
		return false
	end
	for _, gui in ownInput do
		if gui.Visible and inside(gui, p) then
			return false
		end
	end
	return true
end

UserInputService.InputBegan:Connect(function(input)
	local p = Vector2.new(input.Position.X, input.Position.Y)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragMoved = false -- every new press starts as a click
		if onTreeBackground(p) then
			mouseDown, mouseLast = p, p
		end
	elseif input.UserInputType == Enum.UserInputType.Touch then
		if next(touches) == nil then
			dragMoved = false
		end
		if onTreeBackground(p) then
			if next(touches) == nil then
				dragMoved = false
				touchStart = p
			end
			touches[input] = p
			local list = touchList()
			pinchDistance = if #list >= 2 then (list[1] - list[2]).Magnitude else nil
		end
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if not window.Visible then
		return
	end
	local p = Vector2.new(input.Position.X, input.Position.Y)
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		if onTreeBackground(p) then
			-- Zoom on the cursor inside the tree view, on the view's centre elsewhere on the window.
			local step = if input.Position.Z > 0 then WHEEL_ZOOM_STEP else 1 / WHEEL_ZOOM_STEP
			zoomAt(zoom * step, if inside(treeArea, p) then p else nil, false)
		end
	elseif input.UserInputType == Enum.UserInputType.MouseMovement then
		if mouseDown and mouseLast then
			if not dragMoved and (p - mouseDown).Magnitude >= DRAG_THRESHOLD then
				dragMoved = true
				mouseLast = p -- no jump when the drag starts
			end
			if dragMoved then
				panBy(p - mouseLast)
				mouseLast = p
			end
		end
	elseif input.UserInputType == Enum.UserInputType.Touch and touches[input] then
		local before = touchList()
		local old = touches[input]
		local oldCenter = if #before >= 2 then (before[1] + before[2]) / 2 else old
		touches[input] = p
		local list = touchList()
		if #list >= 2 then
			-- Pinch: zoom by the change in finger distance around their midpoint, and pan with it.
			dragMoved = true
			local center = (list[1] + list[2]) / 2
			local distance = (list[1] - list[2]).Magnitude
			if pinchDistance and pinchDistance > 0 then
				zoomAt(zoom * distance / pinchDistance, center, false)
			end
			pinchDistance = distance
			panBy(center - oldCenter)
		else
			if not dragMoved and touchStart and (p - touchStart).Magnitude >= DRAG_THRESHOLD then
				dragMoved = true
				old = p -- no jump when the drag starts
			end
			if dragMoved then
				panBy(p - old)
			end
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouseDown, mouseLast = nil, nil
	elseif input.UserInputType == Enum.UserInputType.Touch and touches[input] then
		touches[input] = nil
		local list = touchList()
		pinchDistance = if #list >= 2 then (list[1] - list[2]).Magnitude else nil
	end
end)

-- Tree -----------------------------------------------------------------------------------------------

local function addSegment(x1: number, y1: number, x2: number, y2: number): Frame
	local t = attr(lineTemplate, "Thickness", 8)
	local seg = lineTemplate:Clone()
	if x1 == x2 then
		seg.Position = UDim2.new(x1, -t / 2, math.min(y1, y2), -t / 2)
		seg.Size = UDim2.new(0, t, math.abs(y2 - y1), t)
	else
		seg.Position = UDim2.new(math.min(x1, x2), -t / 2, y1, -t / 2)
		seg.Size = UDim2.new(math.abs(x2 - x1), t, 0, t)
	end
	seg.Parent = linesFrame
	return seg
end

local function addConnector(tree: TreeDef, from: NodeDef, to: NodeDef, level: number)
	local x1, y1 = cellCenter(tree, from)
	local x2, y2 = cellCenter(tree, to)
	local segs: { Frame }
	if x1 == x2 or y1 == y2 then
		segs = { addSegment(x1, y1, x2, y2) }
	else
		-- Down to just above the child's row, across, then down into the child.
		local _, rows = gridSize(tree)
		local midY = y2 - 0.5 / rows
		if midY <= y1 then
			midY = (y1 + y2) / 2
		end
		segs = { addSegment(x1, y1, x1, midY), addSegment(x1, midY, x2, midY), addSegment(x2, midY, x2, y2) }
	end
	for _, seg in segs do
		table.insert(lines, { frame = seg, treeId = tree.Id, from = from.Id, level = level })
	end
end

local function nodeState(tree: TreeDef, node: NodeDef): string
	local level = getLevel(tree.Id, node.Id)
	if level >= node.MaxLevel then
		return "Maxed"
	end
	if not SkillTreeConfig.RequirementsMet(tree.Id, node, getLevel) then
		return "Locked"
	end
	return "Available"
end

local function refreshNodes()
	local shownId = hoveredId or selectedId
	for _, node in currentTree.Nodes do
		local button = nodeButtons[node.Id]
		if not button then
			continue
		end
		local state = nodeState(currentTree, node)
		local level = getLevel(currentTree.Id, node.Id)
		button.BackgroundColor3 = attr(nodeTemplate, state .. "Color", button.BackgroundColor3)
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke then
			local isSelected = node.Id == selectedId or node.Id == shownId
			stroke.Color = attr(nodeTemplate, if isSelected then "SelectedStroke" else state .. "Stroke", stroke.Color)
			stroke.Thickness = if isSelected then 5 else 3
		end
		;(button:FindFirstChild("Level"):FindFirstChild("Text") :: TextLabel).Text = ("%d/%d"):format(level, node.MaxLevel)
		local lock = button:FindFirstChild("Lock") :: GuiObject?
		if lock then
			lock.Visible = state == "Locked"
		end
		local icon = button:FindFirstChild("Icon") :: ImageLabel
		icon.ImageTransparency = if state == "Locked" then 0.5 else 0
		;(icon:FindFirstChild("IconText") :: TextLabel).TextTransparency = if state == "Locked" then 0.5 else 0
	end
	for _, line in lines do
		local met = getLevel(line.treeId, line.from) >= line.level
		line.frame.BackgroundColor3 = attr(lineTemplate, if met then "ActiveColor" else "InactiveColor", line.frame.BackgroundColor3)
	end
end

-- "Only works in Green Wood" for zone trees, nil for trees that work everywhere.
local function zoneNote(tree: TreeDef): string?
	if not tree.Zone then
		return nil
	end
	local info = ZoneConfig.Get(tree.Zone)
	return ("Only works in %s"):format(if info then info.Name else ("Zone " .. tree.Zone))
end

local function refreshPreview()
	local id = hoveredId or selectedId
	local node = id and SkillTreeConfig.GetNode(currentTree.Id, id)
	upgradeButton.Visible = node ~= nil
	pBar.Visible = node ~= nil
	if not node then
		setIcon(pIcon, pIconText, SkillTreeConfig.IconOf(currentTree))
		pTitle.Text = currentTree.Name
		pEffect.Text = ""
		local note = zoneNote(currentTree)
		pReqs.Text = if note
			then ('Hover or click a skill\n<font color="%s">%s</font>'):format(GREY, note)
			else "Hover or click a skill"
		return
	end

	local level = getLevel(currentTree.Id, node.Id)
	local cost = SkillTreeConfig.Cost(node, level)
	setIcon(pIcon, pIconText, SkillTreeConfig.IconOf(node))
	pTitle.Text = node.Name
	pBarText.Text = ("%d/%d"):format(level, node.MaxLevel)
	pFill.Size = UDim2.fromScale(level / node.MaxLevel, 1)

	local now = SkillTreeConfig.EffectText(node, level)
	if cost then
		local nextText = SkillTreeConfig.EffectText(node, level + 1)
		pEffect.Text = if level > 0
			then ('<font color="%s">%s</font>  →  <font color="%s">%s</font>'):format(GREY, now, GREEN, nextText)
			else ('<font color="%s">%s</font>'):format(GREEN, nextText)
	else
		pEffect.Text = ('<font color="%s">%s</font>'):format(GREEN, now)
	end

	local reqLines = {}
	for _, req in SkillTreeConfig.Requirements(currentTree.Id, node) do
		local have = getLevel(currentTree.Id, req.Node.Id)
		local ok = have >= req.Level
		table.insert(reqLines, ('<font color="%s">%s %s %d/%d</font>'):format(
			if ok then GREEN else RED, if ok then "✓" else "✗", req.Node.Name, math.min(have, req.Level), req.Level))
	end
	local lines = {}
	if node.Info then
		table.insert(lines, ('<font color="%s">%s</font>'):format(GREY, node.Info))
	end
	if #reqLines > 0 then
		table.insert(lines, "Requires:\n" .. table.concat(reqLines, "\n"))
	end
	pReqs.Text = table.concat(lines, "\n")

	local reqsMet = SkillTreeConfig.RequirementsMet(currentTree.Id, node, getLevel)
	if not cost then
		upgradeButton.Text = "Max"
		upgradeButton.BackgroundColor3 = attr(upgradeButton, "DisabledColor", upgradeButton.BackgroundColor3)
	elseif not reqsMet then
		upgradeButton.Text = "Locked"
		upgradeButton.BackgroundColor3 = attr(upgradeButton, "DisabledColor", upgradeButton.BackgroundColor3)
	else
		upgradeButton.Text = "Upgrade $" .. abbreviate(cost)
		upgradeButton.BackgroundColor3 = attr(upgradeButton, if money.Value >= cost then "BuyColor" else "PoorColor", upgradeButton.BackgroundColor3)
	end
end

refresh = function()
	refreshTabs()
	refreshNodes()
	refreshPreview()
end

buildTree = function(tree: TreeDef)
	currentTree = tree
	selectedId = nil
	hoveredId = nil
	for _, child in linesFrame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for _, child in nodesFrame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	table.clear(nodeButtons)
	table.clear(lines)

	treeTitle.Text = "SKILL TREE: " .. string.upper(tree.Name)
	for _, node in tree.Nodes do
		for _, req in SkillTreeConfig.Requirements(tree.Id, node) do
			addConnector(tree, req.Node, node, req.Level)
		end
	end

	for _, node in tree.Nodes do
		local button = nodeTemplate:Clone()
		button.Name = node.Id
		local x, y = cellCenter(tree, node)
		button.Position = UDim2.fromScale(x, y)
		local icon = button:FindFirstChild("Icon") :: ImageLabel
		setIcon(icon, icon:FindFirstChild("IconText") :: TextLabel, SkillTreeConfig.IconOf(node))
		button.MouseEnter:Connect(function()
			hoveredId = node.Id
			refreshNodes()
			refreshPreview()
		end)
		button.MouseLeave:Connect(function()
			if hoveredId == node.Id then
				hoveredId = nil
				refreshNodes()
				refreshPreview()
			end
		end)
		button.Activated:Connect(function()
			if dragMoved then
				return -- the press was used to pan the view
			end
			selectedId = node.Id
			hoveredId = nil
			refreshNodes()
			refreshPreview()
		end)
		button.Parent = nodesFrame
		nodeButtons[node.Id] = button
	end

	resetView(false)
	-- Preview the root (first node) until something is hovered / clicked.
	selectedId = if tree.Nodes[1] then tree.Nodes[1].Id else nil
	refresh()
end

-- Upgrade --------------------------------------------------------------------------------------------

upgradeButton.Activated:Connect(function()
	local id = hoveredId or selectedId
	if busy or not id then
		return
	end
	local treeId = currentTree.Id
	busy = true
	local ok, result = pcall(function()
		return SkillAction:InvokeServer("Upgrade", treeId, id)
	end)
	busy = false
	if not ok or typeof(result) ~= "table" then
		flashMessage("Try again", true)
	elseif result.ok then
		selectedId = id
		flashMessage("Upgraded!", false)
		local button = nodeButtons[id]
		if button and currentTree.Id == treeId then
			local scale = button:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
			scale.Parent = button
			scale.Scale = 1.15
			TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
	else
		flashMessage(result.message or "Can't upgrade", true)
	end
	refresh()
end)

-- Badge ----------------------------------------------------------------------------------------------

-- Skills (all trees) that can be upgraded right now: not maxed, requirements met, affordable.
local function upgradableCount(): number
	local count = 0
	for _, tree in SkillTreeConfig.Trees do
		for _, node in tree.Nodes do
			local cost = SkillTreeConfig.Cost(node, getLevel(tree.Id, node.Id))
			if cost and money.Value >= cost and SkillTreeConfig.RequirementsMet(tree.Id, node, getLevel) then
				count += 1
			end
		end
	end
	return count
end

local function refreshBadge()
	local count = upgradableCount()
	badge.Visible = count > 0
	badgeCount.Text = if count > 99 then "99+" else tostring(count)
end

-- Open / close ---------------------------------------------------------------------------------------

local SINK_WHEEL = "SkillTreeSinkWheel"

-- Runs once the window is visible (UIStyle.Window OnOpen) / hidden (OnClose, whatever closed it:
-- X, the sidebar, K, or UIManager opening another window).
onOpened = function()
	releaseAll()
	-- The mouse wheel zooms the tree, not the game camera behind the window.
	ContextActionService:BindActionAtPriority(SINK_WHEEL, function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseWheel)
	refresh()
end
onClosed = function()
	releaseAll()
	ContextActionService:UnbindAction(SINK_WHEEL)
end

local function toggle()
	if win.IsOpen() then
		win.Close()
	else
		win.Open()
	end
end

upgradesButton.Activated:Connect(toggle)
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.K then
		toggle()
	end
end)

-- Other scripts (NoticeUI) open the window on a node: SkillTreeGui.OpenSkill:Fire(treeId, nodeId).
local openSkill = gui:FindFirstChild("OpenSkill") or Instance.new("BindableEvent")
openSkill.Name = "OpenSkill"
openSkill.Parent = gui
;(openSkill :: BindableEvent).Event:Connect(function(treeId: any, nodeId: any)
	local tree = typeof(treeId) == "string" and SkillTreeConfig.GetTree(treeId)
	if tree and tree.Id ~= currentTree.Id then
		buildTree(tree)
	end
	if tree and typeof(nodeId) == "string" and SkillTreeConfig.GetNode(tree.Id, nodeId) then
		selectedId = nodeId
		hoveredId = nil
	end
	win.Open()
	refresh() -- already open: Open() is a no-op, show the new node anyway
end)

-- Live updates ---------------------------------------------------------------------------------------

local function onMoney()
	moneyLabel.Text = "$" .. abbreviate(money.Value)
	refreshBadge()
	if window.Visible then
		refreshPreview()
	end
end
money.Changed:Connect(onMoney)

local function watchValue(v: Instance)
	if v:IsA("IntValue") then
		v.Changed:Connect(function()
			refreshBadge()
			if window.Visible then
				refresh()
			end
		end)
	end
end
for _, v in skills:GetChildren() do
	watchValue(v)
end
skills.ChildAdded:Connect(function(v)
	watchValue(v)
	refreshBadge()
	if window.Visible then
		refresh()
	end
end)

buildTabs()
buildTree(currentTree)
onMoney()
