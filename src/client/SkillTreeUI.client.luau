-- SkillTreeUI: the skill tree window (trees and nodes from Shared.SkillTreeConfig).
--
-- Layout lives in Studio-editable instances; this script only clones / fills them:
--   StarterGui.SkillTreeGui (src/gui/SkillTreeGui.model.json)
--   StarterGui.LeftSidebar (src/gui/LeftSidebar.model.json)
--     Buttons.Upgrades               opens the window (also the K key); its Badge shows how many
--                                    skills can be upgraded right now (requirements met + affordable)
--     Window.ZoneList                one ZoneTab per tree: Core first, then the zones
--     Window.TreeTitle               name of the open tree
--     Window.TreeArea.Lines / Nodes  connector lines + node buttons of the open tree
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

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SkillTreeConfig = require(Shared:WaitForChild("SkillTreeConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local SkillAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SkillAction") :: RemoteFunction
local Templates = ReplicatedStorage:WaitForChild("SkillTreeTemplates")

type NodeDef = SkillTreeConfig.NodeDef
type TreeDef = SkillTreeConfig.TreeDef

local player = Players.LocalPlayer
local abbreviate = HeroConfig.Abbreviate

local gui = player:WaitForChild("PlayerGui"):WaitForChild("SkillTreeGui") :: ScreenGui
local sidebar = player.PlayerGui:WaitForChild("LeftSidebar") :: ScreenGui
local upgradesButton = sidebar:WaitForChild("Buttons"):WaitForChild("Upgrades") :: GuiButton
local badge = upgradesButton:WaitForChild("Badge") :: GuiObject
local badgeCount = badge:WaitForChild("Count") :: TextLabel
local window = gui:WaitForChild("Window") :: Frame
local zoneList = window:WaitForChild("ZoneList") :: ScrollingFrame
local treeTitle = window:WaitForChild("TreeTitle") :: TextLabel
local treeArea = window:WaitForChild("TreeArea") :: Frame
local linesFrame = treeArea:WaitForChild("Lines") :: Frame
local nodesFrame = treeArea:WaitForChild("Nodes") :: Frame
local preview = window:WaitForChild("Preview") :: Frame
local exitButton = window:WaitForChild("ExitButton") :: GuiButton
local moneyLabel = window:WaitForChild("Money") :: TextLabel

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

local tabTemplate = Templates:WaitForChild("ZoneTab") :: GuiButton
local nodeTemplate = Templates:WaitForChild("Node") :: GuiButton
local lineTemplate = Templates:WaitForChild("Line") :: Frame

local skills = player:WaitForChild("Skills") :: Folder
local money = player:WaitForChild("leaderstats"):WaitForChild("Money") :: NumberValue

local GREEN = "#7CFF5A"
local RED = "#FF6B6B"
local GREY = "#B4B8C4"

local currentTree: TreeDef = SkillTreeConfig.Trees[1]
local selectedId: string? = nil
local hoveredId: string? = nil
local tabs: { [string]: GuiButton } = {}
local nodeButtons: { [string]: GuiButton } = {}
local lines: { { frame: Frame, treeId: string, from: string, level: number } } = {}
local busy = false

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
	pMessage.TextColor3 = if isError then Color3.fromRGB(255, 115, 115) else Color3.fromRGB(124, 255, 90)
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
		setIcon(icon, icon:FindFirstChild("IconText") :: TextLabel, tree.Icon)
		tab.Activated:Connect(function()
			if currentTree.Id ~= tree.Id then
				buildTree(tree)
			end
		end)
		tab.Parent = zoneList
		tabs[tree.Id] = tab
	end
end

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

local function refreshPreview()
	local id = hoveredId or selectedId
	local node = id and SkillTreeConfig.GetNode(currentTree.Id, id)
	upgradeButton.Visible = node ~= nil
	pBar.Visible = node ~= nil
	if not node then
		setIcon(pIcon, pIconText, currentTree.Icon)
		pTitle.Text = currentTree.Name
		pEffect.Text = ""
		pReqs.Text = "Hover or click a skill"
		return
	end

	local level = getLevel(currentTree.Id, node.Id)
	local cost = SkillTreeConfig.Cost(node, level)
	setIcon(pIcon, pIconText, node.Icon)
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
	pReqs.Text = if #reqLines > 0 then "Requires:\n" .. table.concat(reqLines, "\n") else ""

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

	treeTitle.Text = tree.Name
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
		setIcon(icon, icon:FindFirstChild("IconText") :: TextLabel, node.Icon)
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
			selectedId = node.Id
			hoveredId = nil
			refreshNodes()
			refreshPreview()
		end)
		button.Parent = nodesFrame
		nodeButtons[node.Id] = button
	end

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

local function setOpen(open: boolean)
	window.Visible = open
	sidebar.Enabled = not open
	if open then
		refresh()
	end
end

upgradesButton.Activated:Connect(function()
	setOpen(not window.Visible)
end)
exitButton.Activated:Connect(function()
	setOpen(false)
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.K then
		setOpen(not window.Visible)
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
	setOpen(true)
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
setOpen(false)
