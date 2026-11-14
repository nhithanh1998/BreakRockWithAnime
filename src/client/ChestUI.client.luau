-- ChestUI: the "Chest" window (StarterGui.ChestGui). Opens from the chest's ProximityPrompt
-- ("E  Loot Chest / Open"), lists what is inside the chest (ChestService "Contents"), shows the
-- stored/capacity bar. Display only: materials leave the chest on the Loot Pad (carried to the
-- Farm Stand), heroes never go in it.
--
-- The window is the common UIStyle.Window (header with title + red X, Theme colours, global UIScale,
-- UIManager). Grid, Empty text, Progress bar and Tooltip still come from the Studio-editable layout
-- (StarterGui.ChestGui) and are moved into the window at start; the layout's own Panel / Title /
-- Close are dropped. The window is renamed ChestGui so HotbarUI still finds it.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local ItemDisplay = require(script.Parent:WaitForChild("ItemDisplay"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local Theme = require(script.Parent:WaitForChild("Theme"))

local player = Players.LocalPlayer
local layoutGui = player:WaitForChild("PlayerGui"):WaitForChild("ChestGui") :: ScreenGui
local layoutPanel = layoutGui:WaitForChild("Panel") :: Frame
local grid = layoutPanel:WaitForChild("Grid") :: ScrollingFrame
local emptyLabel = layoutPanel:WaitForChild("Empty") :: TextLabel
local progress = layoutPanel:WaitForChild("Progress") :: Frame
local progressFill = progress:WaitForChild("Fill") :: Frame
local progressText = progress:WaitForChild("Amount") :: TextLabel
local slotTemplate = ReplicatedStorage:WaitForChild("ChestTemplates"):WaitForChild("Slot") :: TextButton
local tooltip = layoutGui:WaitForChild("Tooltip") :: Frame
local gridLayout = grid:WaitForChild("UIGridLayout") :: UIGridLayout

local C = Theme.Color
local PAD = Theme.Space.L

local HERO_VALUE_COLOR = ItemDisplay.HERO_VALUE_COLOR
local MATERIAL_VALUE_COLOR = ItemDisplay.MATERIAL_VALUE_COLOR
-- Bar: green while there is room, gold when it is getting full, red when (nearly) full.
local FILL_OK = C.Primary
local FILL_WARN = C.Accent
local FILL_FULL = C.Danger
local progressStroke = progress:FindFirstChildOfClass("UIStroke") :: UIStroke

local openChest: Model? = nil
local chestConnections: { RBXScriptConnection } = {}
local slots: { [string]: TextButton } = {}
local renderQueued = false
local hiddenPrompt: ProximityPrompt? = nil

-- Formatting / item info live in ItemDisplay (shared with the hotbar and popups).
local commas = ItemDisplay.Commas
local abbreviate = ItemDisplay.Abbreviate
local itemInfo = ItemDisplay.Info

-- Window -------------------------------------------------------------------------------------------
-- Drawn at a fixed design width (5 columns); the height follows the number of rows (1 to MAX_ROWS,
-- then the grid scrolls), so a nearly empty chest is a small window, not a big empty box.
local COLUMNS = 5
local MAX_ROWS = 3
local BAR_H = 34
local DESIGN_W = 620
local PHONE_W = 560
local GAP = Theme.Space.S

local release: () -> () -- frees the open chest (defined with open / close below)

local function cellSize(w: number): number
	local inner = w - PAD * 2 - 14 - grid.ScrollBarThickness -- grid UIPadding left + right
	return math.floor((inner - GAP * (COLUMNS - 1)) / COLUMNS)
end
local function gridHeight(cell: number, rows: number): number
	return rows * cell + (rows - 1) * GAP + 8 -- grid UIPadding top + bottom
end
local function bodyHeight(cell: number, rows: number): number
	return gridHeight(cell, rows) + PAD + BAR_H + PAD
end

local cellPC, cellPhone = cellSize(DESIGN_W), cellSize(PHONE_W)
local win = UIStyle.Window({
	Name = "ChestGui-Window", -- renamed to ChestGui once the layout gui is gone (HotbarUI)
	Title = "CHEST",
	Size = Vector2.new(DESIGN_W, UIStyle.HEADER + bodyHeight(cellPC, MAX_ROWS)),
	PhoneSize = Vector2.new(PHONE_W, UIStyle.HEADER_PHONE + bodyHeight(cellPhone, MAX_ROWS)),
	DisplayOrder = 10,
	OnClose = function()
		release()
	end,
})
local gui = win.gui
local panel = win.root
local headerH = if win.phone then UIStyle.HEADER_PHONE else UIStyle.HEADER
local designW = if win.phone then PHONE_W else DESIGN_W
local cell = if win.phone then cellPhone else cellPC

gridLayout.CellPadding = UDim2.fromOffset(GAP, GAP)
gridLayout.CellSize = UDim2.fromOffset(cell, cell)
grid.Position = UDim2.fromOffset(PAD, 0)
grid.ScrollBarImageColor3 = C.TextDim
grid.Parent = win.body

emptyLabel.TextColor3 = C.TextDim
emptyLabel.Font = Theme.Font
emptyLabel.AnchorPoint = Vector2.new(0.5, 0)
emptyLabel.Parent = win.body

progress.AnchorPoint = Vector2.new(0.5, 1)
progress.Position = UDim2.new(0.5, 0, 1, -PAD)
progress.Size = UDim2.new(1, -PAD * 2, 0, BAR_H)
progress.BackgroundColor3 = C.SurfaceInset
progressText.Font = Theme.Font
local amountStroke = progressText:FindFirstChildOfClass("UIStroke")
if amountStroke then
	amountStroke.Color = C.Stroke
end
progress.Parent = win.body

-- Tooltip follows the mouse, above the window.
tooltip.BackgroundColor3 = C.SurfaceInset
local tipStroke = tooltip:FindFirstChildOfClass("UIStroke")
if tipStroke then
	tipStroke.Color = C.Stroke
end
tooltip.ZIndex = 50
tooltip.Parent = gui

-- The layout's own panel (title, close button, backdrop) is no longer used.
layoutGui:Destroy()
gui.Name = "ChestGui"

local shownRows = 1
local function layout(itemCount: number?)
	if itemCount then
		shownRows = math.clamp(math.ceil(itemCount / COLUMNS), 1, MAX_ROWS)
	end
	local gh = gridHeight(cell, shownRows)
	panel.Size = UDim2.fromOffset(designW, headerH + bodyHeight(cell, shownRows))
	grid.Size = UDim2.fromOffset(designW - PAD * 2, gh)
	emptyLabel.Position = UDim2.new(0.5, 0, 0, math.floor(gh * 0.15))
	emptyLabel.Size = UDim2.new(0.8, 0, 0, math.floor(gh * 0.7))
end
layout()

-- Tooltip ----------------------------------------------------------------------------------------

local tipName = tooltip:WaitForChild("ItemName") :: TextLabel
local tipRarity = tooltip:WaitForChild("Rarity") :: TextLabel
local tipWorth = tooltip:WaitForChild("Worth") :: TextLabel
local tipFor: string? = nil

local function showTip(stack: string)
	local info = itemInfo(stack)
	local folder = openChest and openChest:FindFirstChild("Contents")
	local v = folder and folder:FindFirstChild(stack) :: IntValue?
	local amount = if v then v.Value else 0
	tipFor = stack
	tipName.Text = info.name
	tipRarity.Text = info.rarity
	tipRarity.TextColor3 = TreeConfig.RarityColors[info.rarity] or Color3.new(1, 1, 1)
	if info.isHero then
		tipWorth.Text = ("Mine Power: %s"):format(abbreviate(info.value))
		tipWorth.TextColor3 = HERO_VALUE_COLOR
	else
		tipWorth.Text = ("Worth: $%s"):format(abbreviate(info.value * amount))
		tipWorth.TextColor3 = MATERIAL_VALUE_COLOR
	end
	tooltip.Visible = true
end

local function hideTip(stack: string?)
	if stack == nil or tipFor == stack then
		tipFor = nil
		tooltip.Visible = false
	end
end

RunService.RenderStepped:Connect(function()
	if tooltip.Visible then
		local m = UserInputService:GetMouseLocation()
		tooltip.Position = UDim2.fromOffset(m.X + 16, m.Y + 8)
	end
end)

-- Slots ------------------------------------------------------------------------------------------

local function makeSlot(stack: string): TextButton
	local info = itemInfo(stack)
	local slot = slotTemplate:Clone()
	slot.Name = stack
	ItemDisplay.PaintRarity(slot, info.rarity)
	local nameLabel = slot:FindFirstChild("ItemName") :: TextLabel
	nameLabel.Text = info.name
	local valueLabel = slot:FindFirstChild("Value") :: TextLabel
	if info.isHero then
		valueLabel.Text = abbreviate(info.value)
		valueLabel.TextColor3 = HERO_VALUE_COLOR
	else
		valueLabel.Text = "$" .. abbreviate(info.value)
		valueLabel.TextColor3 = MATERIAL_VALUE_COLOR
	end
	ItemDisplay.SetPicture(slot, info)
	slot.MouseEnter:Connect(function()
		showTip(stack)
	end)
	slot.MouseLeave:Connect(function()
		hideTip(stack)
	end)
	slot.Parent = grid
	return slot
end

local function sortKey(stack: string): (number, number, string)
	local info = itemInfo(stack)
	return if info.isHero then 0 else 1, TreeConfig.RarityOrder[info.rarity] or 99, info.name
end

local function render()
	renderQueued = false
	local chest = openChest
	if not chest then
		return
	end
	local folder = chest:FindFirstChild("Contents")
	local stacks: { string } = {}
	local amounts: { [string]: number } = {}
	if folder then
		for _, v in folder:GetChildren() do
			if v:IsA("IntValue") and v.Value > 0 then
				table.insert(stacks, v.Name)
				amounts[v.Name] = v.Value
			end
		end
	end
	table.sort(stacks, function(a, b)
		local a1, a2, a3 = sortKey(a)
		local b1, b2, b3 = sortKey(b)
		if a1 ~= b1 then
			return a1 < b1
		elseif a2 ~= b2 then
			return a2 < b2
		end
		return a3 < b3
	end)

	for stack, slot in slots do
		if not amounts[stack] then
			slot:Destroy()
			slots[stack] = nil
			hideTip(stack)
		end
	end
	for i, stack in stacks do
		local slot = slots[stack] or makeSlot(stack)
		slots[stack] = slot
		slot.LayoutOrder = i
		local countLabel = slot:FindFirstChild("Count") :: TextLabel
		countLabel.Text = "x" .. commas(amounts[stack])
	end
	emptyLabel.Visible = #stacks == 0
	if tipFor and amounts[tipFor] then
		showTip(tipFor)
	end

	layout(#stacks)

	local stored = chest:GetAttribute("Stored") or 0
	local capacity = chest:GetAttribute("Capacity") or 0
	progressText.Text = ("%s / %s items"):format(commas(stored), abbreviate(capacity))
	local ratio = if capacity > 0 then math.clamp(stored / capacity, 0, 1) else 0
	-- Green while there is room, orange when it is getting full, red when (nearly) full.
	local color = if ratio >= 0.9 then FILL_FULL elseif ratio >= 0.7 then FILL_WARN else FILL_OK
	progressFill.BackgroundColor3 = color
	progressStroke.Color = color
	-- Never thinner than the bar is tall, so the rounded end stays round.
	local minWidth = progress.AbsoluteSize.Y / math.max(progress.AbsoluteSize.X, 1)
	TweenService:Create(progressFill, TweenInfo.new(0.2), { Size = UDim2.fromScale(math.max(ratio, minWidth), 1) }):Play()
end

local function queueRender()
	if not renderQueued then
		renderQueued = true
		task.defer(render)
	end
end

-- Open / close -----------------------------------------------------------------------------------

local function clearChest()
	for _, c in chestConnections do
		c:Disconnect()
	end
	table.clear(chestConnections)
	for _, slot in slots do
		slot:Destroy()
	end
	table.clear(slots)
end

local function watchContents(chest: Model)
	local folder = chest:FindFirstChild("Contents")
	if not folder then
		return
	end
	local function hook(v: Instance)
		if v:IsA("IntValue") then
			table.insert(chestConnections, v.Changed:Connect(queueRender))
		end
	end
	for _, v in folder:GetChildren() do
		hook(v)
	end
	table.insert(chestConnections, folder.ChildAdded:Connect(function(v)
		hook(v)
		queueRender()
	end))
	table.insert(chestConnections, folder.ChildRemoved:Connect(queueRender))
end

-- Frees the open chest right away (no animation): runs after the window's close tween (OnClose)
-- and when switching straight to another chest.
release = function()
	openChest = nil
	clearChest()
	hideTip()
	if hiddenPrompt then
		hiddenPrompt.Enabled = true
		hiddenPrompt = nil
	end
end

-- Animated close (X, Esc, walking away, chest gone, another window opening). HotbarUI waits for the
-- window to be hidden before it shows the "Added!" list.
local function close()
	if openChest then
		win.Close()
	end
end

local function open(chest: Model, prompt: ProximityPrompt?)
	if openChest == chest and win.IsOpen() then
		return
	end
	release()
	openChest = chest
	watchContents(chest)
	table.insert(chestConnections, chest.ChildAdded:Connect(function(c)
		if c.Name == "Contents" then
			watchContents(chest)
			queueRender()
		end
	end))
	table.insert(chestConnections, chest:GetAttributeChangedSignal("Stored"):Connect(queueRender))
	table.insert(chestConnections, chest:GetAttributeChangedSignal("Capacity"):Connect(queueRender))
	table.insert(chestConnections, chest.Destroying:Connect(close))
	render()
	grid.CanvasPosition = Vector2.zero

	if prompt then
		prompt.Enabled = false
		hiddenPrompt = prompt
	end
	win.Open()
end

-- Close when walking away from the chest.
RunService.Heartbeat:Connect(function()
	local chest = openChest
	if not chest then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or (root.Position - chest:GetPivot().Position).Magnitude > TreeConfig.ChestCloseDistance then
		close()
	end
end)

-- Prompts ----------------------------------------------------------------------------------------

local function ownerOf(chest: Instance): number?
	local node: Instance? = chest.Parent
	while node and node ~= workspace do
		local owner = node:GetAttribute("OwnerUserId")
		if owner ~= nil then
			return owner
		end
		node = node.Parent
	end
	return nil
end

-- Hide the prompt on other players' plot chests (the shared chest is for everyone).
local function setupPrompt(prompt: ProximityPrompt)
	local chest = prompt:FindFirstAncestor("TreasureChest")
	if not chest then
		return
	end
	local function refresh()
		local owner = ownerOf(chest)
		if prompt ~= hiddenPrompt then
			prompt.Enabled = owner == nil or owner == player.UserId
		end
	end
	refresh()
	local plot = chest.Parent
	while plot and plot ~= workspace do
		if plot:GetAttribute("OwnerUserId") ~= nil or plot:IsA("Model") then
			plot:GetAttributeChangedSignal("OwnerUserId"):Connect(refresh)
		end
		plot = plot.Parent
	end
end

for _, d in workspace:GetDescendants() do
	if d:IsA("ProximityPrompt") and d.Name == "LootChestPrompt" then
		setupPrompt(d)
	end
end
workspace.DescendantAdded:Connect(function(d)
	if d:IsA("ProximityPrompt") and d.Name == "LootChestPrompt" then
		setupPrompt(d)
	end
end)

ProximityPromptService.PromptTriggered:Connect(function(prompt)
	if prompt.Name ~= "LootChestPrompt" then
		return
	end
	local chest = prompt:FindFirstAncestor("TreasureChest")
	if chest and chest:IsA("Model") then
		open(chest, prompt)
	end
end)

-- Buttons ----------------------------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.Escape then
		close()
	end
end)
