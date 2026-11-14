-- ChestUI: the "Chest" window (StarterGui.ChestGui). Opens from the chest's ProximityPrompt
-- ("E  Loot Chest / Open"), lists what is inside the chest (ChestService "Contents"), shows the
-- stored/capacity bar. Display only: materials leave the chest on the Loot Pad (carried to the
-- Farm Stand), heroes never go in it.
--
-- The layout lives in StarterGui.ChestGui so it can be tweaked in Studio; this script only fills it.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local ItemDisplay = require(script.Parent:WaitForChild("ItemDisplay"))

local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui"):WaitForChild("ChestGui") :: ScreenGui
local panel = gui:WaitForChild("Panel") :: Frame
local grid = panel:WaitForChild("Grid") :: ScrollingFrame
local emptyLabel = panel:WaitForChild("Empty") :: TextLabel
local closeButton = panel:WaitForChild("Close") :: TextButton
local progress = panel:WaitForChild("Progress") :: Frame
local progressFill = progress:WaitForChild("Fill") :: Frame
local progressText = progress:WaitForChild("Amount") :: TextLabel
local openScale = panel:WaitForChild("OpenScale") :: UIScale
local slotTemplate = ReplicatedStorage:WaitForChild("ChestTemplates"):WaitForChild("Slot") :: TextButton
local tooltip = gui:WaitForChild("Tooltip") :: Frame

local HERO_VALUE_COLOR = ItemDisplay.HERO_VALUE_COLOR
local MATERIAL_VALUE_COLOR = ItemDisplay.MATERIAL_VALUE_COLOR
local FILL_OK = Color3.fromRGB(60, 200, 80)
local FILL_WARN = Color3.fromRGB(255, 160, 30)
local FILL_FULL = Color3.fromRGB(235, 60, 50)
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

-- Layout: the panel is sized in code. Width follows the screen; height follows the number of rows
-- (1 to MAX_ROWS, then the grid scrolls), so a nearly empty chest is a small window, not a big
-- empty box. Everything is placed in pixels from the panel width W.
local COLUMNS = 5
local MAX_ROWS = 3
local gridLayout = grid:WaitForChild("UIGridLayout") :: UIGridLayout
local title = panel:WaitForChild("Title") :: TextLabel
local closeShadow = panel:FindFirstChild("CloseShadow") :: Frame?
local shownRows = 1

local function layout(itemCount: number?)
	if itemCount then
		shownRows = math.clamp(math.ceil(itemCount / COLUMNS), 1, MAX_ROWS)
	end
	local screen = gui.AbsoluteSize
	local w = math.floor(math.clamp(screen.X * 0.445, 330, 760))
	local pad = math.floor(w * 0.025)
	local header = math.floor(w * 0.11)
	local barHeight = math.floor(w * 0.065)
	local footer = barHeight + pad * 2

	local gridWidth = w - pad * 2
	local inner = gridWidth - 14 - grid.ScrollBarThickness -- UIPadding left + right
	local gap = math.max(4, math.floor(inner * 0.016))
	local cell = math.floor((inner - gap * (COLUMNS - 1)) / COLUMNS)
	gridLayout.CellPadding = UDim2.fromOffset(gap, gap)
	gridLayout.CellSize = UDim2.fromOffset(cell, cell)

	-- Fit on screen (leave room for the top bar and the hotbar).
	local rows = shownRows
	local function gridHeight(n: number): number
		return n * cell + (n - 1) * gap + 8 -- UIPadding top + bottom
	end
	while rows > 1 and header + gridHeight(rows) + footer > screen.Y * 0.72 do
		rows -= 1
	end
	local gh = gridHeight(rows)
	local h = header + gh + footer

	panel.Size = UDim2.fromOffset(w, h)
	title.Position = UDim2.fromOffset(pad + 4, math.floor(w * 0.025))
	title.Size = UDim2.fromOffset(math.floor(w * 0.4), math.floor(w * 0.065))
	local closeSize = math.floor(w * 0.075)
	closeButton.Position = UDim2.fromOffset(w - pad, math.floor(w * 0.02))
	closeButton.Size = UDim2.fromOffset(closeSize, closeSize)
	if closeShadow then
		-- Darker copy just below the button: its 3D bottom edge.
		closeShadow.Position = UDim2.fromOffset(w - pad, math.floor(w * 0.02) + 4)
		closeShadow.Size = UDim2.fromOffset(closeSize, closeSize)
	end
	grid.Position = UDim2.fromOffset(pad, header)
	grid.Size = UDim2.fromOffset(gridWidth, gh)
	emptyLabel.Position = UDim2.fromOffset(pad * 4, header + math.floor(gh * 0.15))
	emptyLabel.Size = UDim2.fromOffset(w - pad * 8, math.floor(gh * 0.7))
	progress.AnchorPoint = Vector2.new(0.5, 0)
	progress.Position = UDim2.fromOffset(math.floor(w / 2), header + gh + pad)
	progress.Size = UDim2.fromOffset(gridWidth - pad * 2, barHeight)
end
gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	layout()
end)
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

local function close()
	if not openChest then
		return
	end
	openChest = nil
	clearChest()
	hideTip()
	panel.Visible = false
	if hiddenPrompt then
		hiddenPrompt.Enabled = true
		hiddenPrompt = nil
	end
end

-- Shrinks the panel away, then closes it (after Take All; HotbarUI waits for the panel to be gone
-- before it shows the "Added!" list).
local CLOSE_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local closingChest: Model? = nil

local function closeAnimated()
	local chest = openChest
	if not chest or closingChest == chest then
		return
	end
	closingChest = chest
	local tween = TweenService:Create(openScale, CLOSE_TWEEN, { Scale = 0.8 })
	tween.Completed:Once(function()
		if closingChest == chest then
			closingChest = nil
			if openChest == chest then
				close()
			end
		end
	end)
	tween:Play()
end

local function open(chest: Model, prompt: ProximityPrompt?)
	if openChest == chest and closingChest ~= chest then
		return
	end
	closingChest = nil
	close()
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
	panel.Visible = true
	openScale.Scale = 0.85
	TweenService:Create(openScale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
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

closeButton.Activated:Connect(close)

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.Escape then
		close()
	end
end)
