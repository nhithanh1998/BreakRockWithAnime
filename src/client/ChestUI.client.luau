-- ChestUI: the "Chest" window (StarterGui.ChestGui). Opens from the chest's ProximityPrompt
-- ("E  Loot Chest / Open"), lists what is inside the chest (ChestService "Contents"), shows the
-- stored/capacity bar and sends Take All / Auto Sell to the server.
--
-- The layout lives in StarterGui.ChestGui so it can be tweaked in Studio; this script only fills it.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local ChestAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ChestAction") :: RemoteEvent

local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui"):WaitForChild("ChestGui") :: ScreenGui
local panel = gui:WaitForChild("Panel") :: Frame
local grid = panel:WaitForChild("Grid") :: ScrollingFrame
local emptyLabel = panel:WaitForChild("Empty") :: TextLabel
local closeButton = panel:WaitForChild("Close") :: TextButton
local takeAllButton = panel:WaitForChild("TakeAll") :: TextButton
local autoSellButton = panel:WaitForChild("AutoSell") :: TextButton
local progress = panel:WaitForChild("Progress") :: Frame
local progressFill = progress:WaitForChild("Fill") :: Frame
local progressText = progress:WaitForChild("Amount") :: TextLabel
local openScale = panel:WaitForChild("OpenScale") :: UIScale
local slotTemplate = gui:WaitForChild("Templates"):WaitForChild("Slot") :: TextButton
local tooltip = gui:WaitForChild("Tooltip") :: Frame

local HERO_PREFIX = "Anime:"
local HERO_VALUE_COLOR = Color3.fromRGB(255, 40, 40)
local MATERIAL_VALUE_COLOR = Color3.fromRGB(80, 255, 60)
local AUTO_SELL_OFF = Color3.fromRGB(150, 112, 26)
local AUTO_SELL_ON = Color3.fromRGB(205, 160, 30)

local openChest: Model? = nil
local chestConnections: { RBXScriptConnection } = {}
local slots: { [string]: TextButton } = {}
local renderQueued = false
local hiddenPrompt: ProximityPrompt? = nil

-- Formatting -------------------------------------------------------------------------------------

local function commas(n: number): string
	local s = tostring(math.floor(n))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

local function abbreviate(n: number): string
	local units = { { 1e15, "Qd" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, u in units do
		if n >= u[1] then
			local v = n / u[1]
			local text = if v >= 100 or v == math.floor(v) then ("%d"):format(math.floor(v)) else ("%.1f"):format(v)
			return text .. u[2]
		end
	end
	return tostring(math.floor(n))
end

-- Grid sizing: 5 square cells per row, sized from the grid's width (scale cell sizes don't work
-- well inside an auto-sized ScrollingFrame).
local COLUMNS = 5
local gridLayout = grid:WaitForChild("UIGridLayout") :: UIGridLayout
local function sizeCells()
	local width = grid.AbsoluteSize.X - 14 - grid.ScrollBarThickness
	local gap = math.floor(width * 0.016)
	local cell = math.floor((width - gap * (COLUMNS - 1)) / COLUMNS)
	gridLayout.CellPadding = UDim2.fromOffset(gap, gap)
	gridLayout.CellSize = UDim2.fromOffset(cell, cell)
end
grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizeCells)
sizeCells()

-- Item info --------------------------------------------------------------------------------------

type ItemInfo = {
	name: string,
	rarity: string,
	isHero: boolean,
	value: number, -- sell value (material) or power (hero)
	visual: TreeConfig.Visual?,
}

local function itemInfo(stack: string): ItemInfo
	if stack:sub(1, #HERO_PREFIX) == HERO_PREFIX then
		local name = stack:sub(#HERO_PREFIX + 1)
		local hero = TreeConfig.GetHero(name)
		return {
			name = name,
			rarity = if hero then hero.Rarity else "Rare",
			isHero = true,
			value = if hero then hero.Power else 0,
		}
	end
	local def = TreeConfig.Materials[stack]
	return {
		name = if def then def.Name else stack,
		rarity = if def then def.Rarity else "Common",
		isHero = false,
		value = if def then def.Value else 0,
		visual = def and def.Visual,
	}
end

-- Material picture: the same studded block that drops from trees.
local function fillViewport(view: ViewportFrame, visual: TreeConfig.Visual)
	view:ClearAllChildren()
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = Vector3.one * 2
	part.Color = visual.Color
	part.Material = visual.Material
	for _, face in { "Top", "Bottom", "Front", "Back", "Left", "Right" } do
		(part :: any)[face .. "Surface"] = Enum.SurfaceType.Studs
	end
	part.CFrame = CFrame.Angles(0, math.rad(35), 0) * CFrame.Angles(math.rad(-20), 0, 0)
	part.Parent = view
	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 1.6, 5.2), Vector3.zero)
	camera.Parent = view
	view.CurrentCamera = camera
end

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
		tipWorth.Text = ("Power: %s"):format(abbreviate(info.value))
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
	local bg = TreeConfig.RaritySlotColors[info.rarity] or Color3.fromRGB(120, 120, 120)
	slot.BackgroundColor3 = bg
	local border = slot:FindFirstChild("Border") :: UIStroke?
	if border then
		border.Color = bg:Lerp(Color3.new(1, 1, 1), 0.4)
	end
	local nameLabel = slot:FindFirstChild("ItemName") :: TextLabel
	nameLabel.Text = info.name
	local valueLabel = slot:FindFirstChild("Value") :: TextLabel
	if info.isHero then
		valueLabel.Text = abbreviate(info.value)
		valueLabel.TextColor3 = HERO_VALUE_COLOR
		local heroIcon = slot:FindFirstChild("Icon") :: TextLabel
		heroIcon.Visible = true
	else
		valueLabel.Text = "$" .. abbreviate(info.value)
		valueLabel.TextColor3 = MATERIAL_VALUE_COLOR
		if info.visual then
			fillViewport(slot:FindFirstChild("View") :: ViewportFrame, info.visual)
		end
	end
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

	local stored = chest:GetAttribute("Stored") or 0
	local capacity = chest:GetAttribute("Capacity") or 0
	progressText.Text = ("%s/%s Items"):format(commas(stored), abbreviate(capacity))
	local ratio = if capacity > 0 then math.clamp(stored / capacity, 0, 1) else 0
	TweenService:Create(progressFill, TweenInfo.new(0.2), { Size = UDim2.fromScale(math.max(ratio, 0.01), 1) }):Play()
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

local function open(chest: Model, prompt: ProximityPrompt?)
	if openChest == chest then
		return
	end
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

local function press(button: GuiButton)
	local scale = button:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = button
	scale.Scale = 0.9
	TweenService:Create(scale, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function drawAutoSell()
	local on = player:GetAttribute("AutoSell") == true
	autoSellButton.Text = if on then "Auto Sell: ON" else "Auto Sell"
	autoSellButton.BackgroundColor3 = if on then AUTO_SELL_ON else AUTO_SELL_OFF
end

closeButton.Activated:Connect(close)

takeAllButton.Activated:Connect(function()
	press(takeAllButton)
	if openChest then
		ChestAction:FireServer("TakeAll", openChest)
	end
end)

autoSellButton.Activated:Connect(function()
	press(autoSellButton)
	ChestAction:FireServer("SetAutoSell", player:GetAttribute("AutoSell") ~= true, openChest)
end)

player:GetAttributeChangedSignal("AutoSell"):Connect(drawAutoSell)
drawAutoSell()

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.Escape then
		close()
	end
end)
