-- InventoryUI: the inventory window (StarterGui.InventoryGui), opened by the hotbar's backpack
-- button or the ` key (HotbarUI toggles the InventoryGui "Open" attribute).
--
-- Shows everything the player owns:
--   heroes    - player.Heroes (IntValue per hero = how many owned); count shown = copies not on a pad
--   materials - player.Inventory (IntValue per TreeConfig.Materials key)
-- Tabs: Panel.Tabs.All / Heroes / Materials. Panel.Search.Box filters by name.
-- Cards are clones of InventoryGui.Templates.ItemSlot, drawn with ItemDisplay.
-- Panel.EquipBest fills the hero pads with the strongest heroes and axes (HeroSlotService).
--
-- The layout lives in StarterGui.InventoryGui (edited in Studio); this script only fills it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local ItemDisplay = require(script.Parent:WaitForChild("ItemDisplay"))

local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui"):WaitForChild("InventoryGui") :: ScreenGui
local panel = gui:WaitForChild("Panel") :: Frame
local panelScale = panel:WaitForChild("UIScale") :: UIScale
local closeButton = panel:WaitForChild("Close") :: TextButton
local tabsFrame = panel:WaitForChild("Tabs") :: Frame
local searchBox = (panel:WaitForChild("Search") :: Frame):WaitForChild("Box") :: TextBox
local grid = panel:WaitForChild("Grid") :: ScrollingFrame
local emptyLabel = panel:WaitForChild("Empty") :: TextLabel
local slotTemplate = (gui:WaitForChild("Templates") :: Folder):WaitForChild("ItemSlot") :: TextButton

-- Hero portraits fill the whole card (under the name / count), not just the smaller "View" box.
if not slotTemplate:FindFirstChild("HeroView") then
	local heroView = Instance.new("ViewportFrame")
	heroView.Name = "HeroView"
	heroView.BackgroundTransparency = 1
	heroView.Size = UDim2.fromScale(1, 1)
	heroView.ZIndex = 1
	heroView.Visible = false
	heroView.Parent = slotTemplate
end

local TAB_ON_BG = Color3.fromRGB(45, 180, 60)
local TAB_ON_STROKE = Color3.fromRGB(25, 110, 35)
local TAB_OFF_BG = Color3.fromRGB(70, 75, 88)
local TAB_OFF_STROKE = Color3.fromRGB(115, 120, 132)
local SCREEN_FILL_X = 0.92 -- largest share of the screen the panel may cover
local SCREEN_FILL_Y = 0.86

local commas = ItemDisplay.Commas
local abbreviate = ItemDisplay.Abbreviate

type Tab = "All" | "Heroes" | "Materials"
type Entry = { stack: string, info: ItemDisplay.ItemInfo, amount: number, onPad: number }

local currentTab: Tab = "All"
local isOpen = false
local renderQueued = false
local cards: { [string]: TextButton } = {}

local function press(button: GuiObject)
	local scale = button:FindFirstChild("Press") :: UIScale?
	if scale then
		scale.Scale = 0.88
		TweenService:Create(scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
end

-- Data -------------------------------------------------------------------------------------------

-- How many of each hero stand on my plot's pads (HeroSlotService writes each slot's "HeroId").
local function placedCounts(): { [string]: number }
	local counts = {}
	local plots = workspace:FindFirstChild("Plots")
	for _, plot in if plots then plots:GetChildren() else {} do
		if plot:GetAttribute("OwnerUserId") == player.UserId then
			local pads = plot:FindFirstChild("HeroSlots")
			for _, slot in if pads then pads:GetChildren() else {} do
				local hero = slot:GetAttribute("HeroId")
				if typeof(hero) == "string" and hero ~= "" then
					counts[hero] = (counts[hero] or 0) + 1
				end
			end
		end
	end
	return counts
end

local function entries(): { Entry }
	local list: { Entry } = {}
	if currentTab ~= "Materials" then
		local heroes = player:FindFirstChild("Heroes")
		local placed = placedCounts()
		for _, v in if heroes then heroes:GetChildren() else {} do
			if v:IsA("IntValue") and v.Value > 0 then
				-- Only copies not standing on a pad are listed; fully placed heroes are hidden.
				local available = v.Value - math.min(v.Value, placed[v.Name] or 0)
				if available > 0 then
					local stack = ItemDisplay.HeroStack(v.Name)
					table.insert(list, { stack = stack, info = ItemDisplay.Info(stack), amount = available, onPad = 0 })
				end
			end
		end
	end
	if currentTab ~= "Heroes" then
		local inventory = player:FindFirstChild("Inventory")
		for _, v in if inventory then inventory:GetChildren() else {} do
			if v:IsA("IntValue") and v.Value > 0 and TreeConfig.Materials[v.Name] then
				table.insert(list, { stack = v.Name, info = ItemDisplay.Info(v.Name), amount = v.Value, onPad = 0 })
			end
		end
	end

	local query = searchBox.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
	if query ~= "" then
		local filtered = {}
		for _, e in list do
			if e.info.name:lower():find(query, 1, true) then
				table.insert(filtered, e)
			end
		end
		list = filtered
	end

	-- Heroes first, then materials; rarest first, then most valuable / powerful, then by name.
	table.sort(list, function(a, b)
		if a.info.isHero ~= b.info.isHero then
			return a.info.isHero
		end
		local ra = TreeConfig.RarityOrder[a.info.rarity] or 99
		local rb = TreeConfig.RarityOrder[b.info.rarity] or 99
		if ra ~= rb then
			return ra < rb
		end
		if a.info.value ~= b.info.value then
			return a.info.value > b.info.value
		end
		return a.info.name < b.info.name
	end)
	return list
end

-- Drawing ----------------------------------------------------------------------------------------

local function drawCard(card: TextButton, e: Entry)
	local info = e.info
	local bg = ItemDisplay.SlotColor(info.rarity)
	card.BackgroundColor3 = bg
	local stroke = card:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = bg:Lerp(Color3.new(1, 1, 1), 0.4)
	end
	(card:FindFirstChild("ItemName") :: TextLabel).Text = info.name
	local count = card:FindFirstChild("Count") :: TextLabel
	count.Text = "x" .. commas(e.amount)
	count.Visible = true
	-- No "E" badge in the inventory: placed heroes are simply not listed.
	local equipped = card:FindFirstChild("Equipped") :: TextLabel?
	if equipped then
		equipped.Visible = false
	end
	ItemDisplay.SetPicture(card, info)
end

local function render()
	renderQueued = false
	if not isOpen then
		return
	end
	local list = entries()
	local keep: { [string]: boolean } = {}
	for i, e in list do
		keep[e.stack] = true
		local card = cards[e.stack]
		if not card then
			card = slotTemplate:Clone()
			card.Name = e.stack
			card.Visible = true
			cards[e.stack] = card
			card.Parent = grid
		end
		card.LayoutOrder = i
		drawCard(card, e)
	end
	for stack, card in cards do
		if not keep[stack] then
			card:Destroy()
			cards[stack] = nil
		end
	end
	emptyLabel.Visible = #list == 0
end

local function queueRender()
	if not renderQueued then
		renderQueued = true
		task.defer(render)
	end
end

-- Tabs & search ----------------------------------------------------------------------------------

local function styleTabs()
	for _, tab in tabsFrame:GetChildren() do
		if tab:IsA("GuiButton") then
			local on = tab.Name == currentTab
			tab.BackgroundColor3 = if on then TAB_ON_BG else TAB_OFF_BG
			tab.BackgroundTransparency = if on then 0 else 0.3
			local stroke = tab:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Color = if on then TAB_ON_STROKE else TAB_OFF_STROKE
			end
		end
	end
end

for _, name in { "All", "Heroes", "Materials" } do
	local tab = tabsFrame:FindFirstChild(name) :: GuiButton?
	if tab then
		tab.Activated:Connect(function()
			press(tab)
			if currentTab ~= name then
				currentTab = name :: Tab
				styleTabs()
				grid.CanvasPosition = Vector2.zero
				render()
			end
		end)
	else
		warn(("InventoryUI: InventoryGui.Panel.Tabs.%s is missing"):format(name))
	end
end

searchBox:GetPropertyChangedSignal("Text"):Connect(queueRender)

-- Open / close -----------------------------------------------------------------------------------

-- Shrink the panel to fit small screens (it is laid out in pixels).
local function fitScale(): number
	local camera = workspace.CurrentCamera
	local view = if camera then camera.ViewportSize else Vector2.new(1920, 1080)
	local size = panel.Size
	local w, h = math.max(size.X.Offset, 1), math.max(size.Y.Offset, 1)
	return math.min(1, view.X * SCREEN_FILL_X / w, view.Y * SCREEN_FILL_Y / h)
end

local function setOpen(open: boolean)
	if open == isOpen then
		return
	end
	isOpen = open
	gui:SetAttribute("Open", open)
	if open then
		panel.Visible = true
		local target = fitScale()
		panelScale.Scale = target * 0.85
		TweenService:Create(panelScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = target }):Play()
		styleTabs()
		render()
	else
		searchBox:ReleaseFocus()
		panel.Visible = false
	end
end

gui:GetAttributeChangedSignal("Open"):Connect(function()
	setOpen(gui:GetAttribute("Open") == true)
end)

closeButton.Activated:Connect(function()
	press(closeButton)
	setOpen(false)
end)

-- Equip Best (Panel.EquipBest, designed in Studio; its text is in "Label"): the server puts the
-- strongest heroes on the open pads and the best axes on the strongest of them (HeroSlotService).
-- The label shows the answer for a moment.
local equipBestButton = panel:FindFirstChild("EquipBest") :: TextButton?
if equipBestButton then
	local button = equipBestButton
	local label = (button:FindFirstChild("Label") or button) :: TextLabel
	local idleText = label.Text
	local idleColor = label.TextColor3
	local busy = false
	-- Longer answers shrink to fit the button instead of spilling out (never bigger than the
	-- size set in Studio).
	if not label.TextScaled then
		local limit = Instance.new("UITextSizeConstraint")
		limit.MaxTextSize = label.TextSize
		limit.Parent = label
		label.TextScaled = true
	end
	button.Visible = true
	button.Activated:Connect(function()
		if busy then
			return
		end
		busy = true
		press(button)
		label.Text = "..."
		local upgradeRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("HeroUpgrade") :: RemoteFunction
		local ok, success, message = pcall(upgradeRemote.InvokeServer, upgradeRemote, 0, "EquipBest")
		label.Text = if ok and typeof(message) == "string" then message else "Try again"
		label.TextColor3 = if ok and success then idleColor else Color3.fromRGB(255, 150, 150)
		task.wait(1.5)
		label.Text = idleText
		label.TextColor3 = idleColor
		busy = false
	end)
end

local function onViewportChanged()
	if isOpen then
		panelScale.Scale = fitScale()
	end
end
local function hookCamera()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(onViewportChanged)
	end
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCamera)
hookCamera()

-- Watch player.Heroes / player.Inventory ---------------------------------------------------------

local watched: { [Instance]: { RBXScriptConnection } } = {}

local function watchFolder(folder: Instance)
	if watched[folder] then
		return
	end
	local conns: { RBXScriptConnection } = {}
	watched[folder] = conns
	local function hook(v: Instance)
		if v:IsA("IntValue") then
			table.insert(conns, v.Changed:Connect(queueRender))
		end
	end
	for _, v in folder:GetChildren() do
		hook(v)
	end
	table.insert(conns, folder.ChildAdded:Connect(function(v)
		hook(v)
		queueRender()
	end))
	table.insert(conns, folder.ChildRemoved:Connect(queueRender))
	table.insert(conns, folder.Destroying:Connect(function()
		for _, c in conns do
			c:Disconnect()
		end
		watched[folder] = nil
	end))
	queueRender()
end

local function maybeWatch(c: Instance)
	if c.Name == "Heroes" or c.Name == "Inventory" then
		watchFolder(c)
	end
end
player.ChildAdded:Connect(maybeWatch)
for _, c in player:GetChildren() do
	maybeWatch(c)
end

-- Re-render when a hero is placed on / removed from a pad (slot "HeroId" attribute changes).
local function watchSlot(slot: Instance)
	slot:GetAttributeChangedSignal("HeroId"):Connect(queueRender)
end
local function watchSlots(pads: Instance)
	for _, slot in pads:GetChildren() do
		watchSlot(slot)
	end
	pads.ChildAdded:Connect(function(slot)
		watchSlot(slot)
		queueRender()
	end)
	pads.ChildRemoved:Connect(queueRender)
end
local function watchPlot(plot: Instance)
	local hooked = false
	local function tryHook()
		if hooked then
			return
		end
		local pads = plot:FindFirstChild("HeroSlots")
		if pads then
			hooked = true
			watchSlots(pads)
		end
	end
	tryHook()
	plot.ChildAdded:Connect(function(c)
		if c.Name == "HeroSlots" then
			tryHook()
		end
	end)
	plot:GetAttributeChangedSignal("OwnerUserId"):Connect(queueRender)
end
task.spawn(function()
	local plots = workspace:WaitForChild("Plots")
	for _, plot in plots:GetChildren() do
		watchPlot(plot)
	end
	plots.ChildAdded:Connect(watchPlot)
end)

panel.Visible = false
gui:SetAttribute("Open", false)
