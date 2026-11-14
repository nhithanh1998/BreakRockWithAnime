-- HotbarUI: the hero bar at the bottom of the screen (StarterGui.HotbarGui) and the
-- "Added!" / "New!" frames that pop up above it after taking items out of the chest.
--
-- Hotbar: the player's heroes (player.Heroes, one IntValue per hero = how many they own), highest
-- MinePower (HeroConfig) first, in 9 numbered slots (1-9) plus the Backpack button: 10 cells, nothing
-- else (Roblox's default backpack bar is turned off). Keys 1-9 or a click select a slot; the selection is
-- sent to the server (Remotes.HeroSlot "Select") so E at an empty hero pad places that hero, and the
-- server shows the selected hero held in the player's hands (HeroSlotService). Hovering a
-- slot shows a tooltip.
--
-- Popups: ChestService fires Remotes.ItemsAdded({ {Stack, Amount, New} }) after Take All. Up to
-- MAX_POPUPS cards rise in one by one (a "+N More" card covers the rest) once the chest window has
-- closed, and sink away again after POPUP_TIME.
--
-- The layout lives in StarterGui.HotbarGui so it can be tweaked in Studio; this script only fills it.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local ItemDisplay = require(script.Parent:WaitForChild("ItemDisplay"))
local ItemsAdded = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ItemsAdded") :: RemoteEvent
local HeroSlotRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("HeroSlot") :: RemoteEvent

local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui"):WaitForChild("HotbarGui") :: ScreenGui
local bar = gui:WaitForChild("Bar") :: Frame
local slotsFrame = bar:WaitForChild("Slots") :: Frame
local popupsFrame = bar:WaitForChild("Popups") :: Frame
local backpackButton = slotsFrame:WaitForChild("Backpack") :: TextButton
local tooltip = gui:WaitForChild("Tooltip") :: Frame
local templates = ReplicatedStorage:WaitForChild("HotbarTemplates") -- src/gui/HotbarTemplates.model.json
-- The hero slot lives in StarterGui.HotbarGui.Bar.Slots (filled as "Uzumaki Shounen" so it can be
-- designed in Studio). Take it out of the bar and use it as the template for every slot.
local slotTemplate = (slotsFrame:FindFirstChild("HeroSlot") or gui:FindFirstChild("HeroSlot", true)
	or slotsFrame:WaitForChild("HeroSlot")) :: TextButton
slotTemplate.Parent = nil
slotTemplate:SetAttribute("PreviewHero", nil)
local popupTemplate = templates:WaitForChild("Popup") :: Frame
local moreTemplate = templates:WaitForChild("More") :: Frame

local SLOT_COUNT = 9 -- slots 1-9; the 10th cell of the bar is the Backpack button
local MAX_POPUPS = 7
local POPUP_TIME = 6 -- seconds the popups stay before hiding
local POPUP_STAGGER = 0.07
local EMPTY_COLOR = Color3.fromRGB(30, 32, 42)
local SELECTED_BORDER = Color3.fromRGB(255, 255, 255)
local TAG_ADDED = Color3.fromRGB(235, 120, 25)
local TAG_ADDED_BORDER = Color3.fromRGB(120, 50, 10)
local TAG_NEW = Color3.fromRGB(60, 200, 70)
local TAG_NEW_BORDER = Color3.fromRGB(20, 90, 25)

local KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
	[Enum.KeyCode.KeypadOne] = 1,
	[Enum.KeyCode.KeypadTwo] = 2,
	[Enum.KeyCode.KeypadThree] = 3,
	[Enum.KeyCode.KeypadFour] = 4,
	[Enum.KeyCode.KeypadFive] = 5,
	[Enum.KeyCode.KeypadSix] = 6,
	[Enum.KeyCode.KeypadSeven] = 7,
	[Enum.KeyCode.KeypadEight] = 8,
	[Enum.KeyCode.KeypadNine] = 9,
}

-- Our bar replaces Roblox's default tool backpack (the game has no tools).
task.spawn(function()
	for _ = 1, 10 do
		if pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack, false) then
			return
		end
		task.wait(0.5)
	end
end)

local commas = ItemDisplay.Commas
local abbreviate = ItemDisplay.Abbreviate

local SELECTED_SCALE = 1.08 -- the selected slot stands a little bigger than the rest

local function bump(button: GuiObject, from: number)
	local scale = button:FindFirstChild("SlotScale") :: UIScale?
	if scale then
		local rest = if button:GetAttribute("Selected") then SELECTED_SCALE else 1
		scale.Scale = from * rest
		TweenService:Create(scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = rest }):Play()
	end
end

-- Selected look: bigger, white border, a ▼ pointer above it. Eases between states.
local function setSelectedLook(button: GuiObject, selected: boolean)
	local pointer = button:FindFirstChild("Pointer") :: GuiObject?
	if pointer then
		pointer.Visible = selected
	end
	if (button:GetAttribute("Selected") == true) == selected then
		return
	end
	button:SetAttribute("Selected", selected)
	local scale = button:FindFirstChild("SlotScale") :: UIScale?
	if scale then
		local target = if selected then SELECTED_SCALE else 1
		TweenService:Create(scale, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = target }):Play()
	end
end

-- Hero slots -------------------------------------------------------------------------------------

type Slot = { button: TextButton, hero: string? }

local slots: { Slot } = {}
local selectedHero: string? = nil
local hoveredSlot: Slot? = nil
local renderQueued = false
local sentHero: string? = nil

-- Tells the server which hero E at an empty hero pad should place.
local function sendSelection()
	if sentHero ~= selectedHero then
		sentHero = selectedHero
		HeroSlotRemote:FireServer("Select", selectedHero)
	end
end

local function heroesFolder(): Folder?
	return player:FindFirstChild("Heroes") :: Folder?
end

local function ownedCount(hero: string): number
	local folder = heroesFolder()
	local v = folder and folder:FindFirstChild(hero) :: IntValue?
	return if v then v.Value else 0
end

-- How many of each hero stand on my plot's pads: worker pads (HeroSlotService writes each slot's
-- "HeroId") and Farm Stand keeper / helper pads (tag "StandHeroPad", StandService). A copy is on one pad only.
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
			for _, pad in CollectionService:GetTagged("StandHeroPad") do
				local hero = pad:GetAttribute("HeroId")
				if typeof(hero) == "string" and hero ~= "" and pad:IsDescendantOf(plot) then
					counts[hero] = (counts[hero] or 0) + 1
				end
			end
		end
	end
	return counts
end

local placed: { [string]: number } = {} -- refreshed on every render

-- Copies still in the inventory (owned minus the ones on pads): what the bar shows.
local function availableCount(hero: string): number
	return math.max(0, ownedCount(hero) - (placed[hero] or 0))
end

-- Tooltip ----------------------------------------------------------------------------------------

local tipName = tooltip:WaitForChild("ItemName") :: TextLabel
local tipRarity = tooltip:WaitForChild("Rarity") :: TextLabel
local tipPower = tooltip:WaitForChild("Power") :: TextLabel
local tipOwned = tooltip:WaitForChild("Owned") :: TextLabel

local function showTip(slot: Slot)
	local hero = slot.hero
	if not hero then
		tooltip.Visible = false
		return
	end
	local info = ItemDisplay.Info(ItemDisplay.HeroStack(hero))
	tipName.Text = info.name
	tipRarity.Text = info.rarity
	tipRarity.TextColor3 = TreeConfig.RarityColors[info.rarity] or Color3.new(1, 1, 1)
	tipPower.Text = ("Mine Power: %s"):format(abbreviate(info.value))
	tipOwned.Text = ("Owned: x%s"):format(commas(ownedCount(hero)))
	local pos = slot.button.AbsolutePosition
	local size = slot.button.AbsoluteSize
	-- IgnoreGuiInset = true, so absolute positions match the ScreenGui's own space.
	tooltip.Position = UDim2.fromOffset(pos.X + size.X / 2, pos.Y - size.Y * 0.25)
	tooltip.Visible = true
end

local function hideTip(slot: Slot?)
	if slot == nil or hoveredSlot == slot then
		hoveredSlot = nil
		tooltip.Visible = false
	end
end

-- Drawing ----------------------------------------------------------------------------------------

local function drawSlot(slot: Slot)
	local button = slot.button
	local border = button:FindFirstChild("Border") :: UIStroke
	local nameLabel = button:FindFirstChild("ItemName") :: TextLabel
	local valueLabel = button:FindFirstChild("Value") :: TextLabel
	-- Count lives in the CountBadge (dark shadow frame) > Face (lighter top) > Count text.
	local countBadge = button:FindFirstChild("CountBadge") :: GuiObject
	local countLabel = button:FindFirstChild("Count", true) :: TextLabel
	local gradient = button:FindFirstChildOfClass("UIGradient")
	local nameShade = button:FindFirstChild("NameShade") :: GuiObject?
	local hero = slot.hero
	if nameShade then
		nameShade.Visible = hero ~= nil
	end
	-- All 9 slots always show (empty ones dimmed); heroes fill them from the left.
	button.Visible = true

	if not hero then
		button.BackgroundColor3 = EMPTY_COLOR
		button.BackgroundTransparency = 0.25
		border.Color = Color3.fromRGB(70, 74, 92)
		border.Thickness = 2
		nameLabel.Visible = false
		valueLabel.Visible = false
		countBadge.Visible = false
		setSelectedLook(button, false)
		if gradient then
			gradient.Enabled = false
		end
		ItemDisplay.SetPicture(button, { name = "", rarity = "Common", isHero = false, value = 0 })
		return
	end

	local info = ItemDisplay.Info(ItemDisplay.HeroStack(hero))
	ItemDisplay.PaintRarity(button, info.rarity)
	button.BackgroundTransparency = 0
	local selected = hero == selectedHero
	border.Color = if selected then SELECTED_BORDER else ItemDisplay.SlotEdgeColor(info.rarity)
	border.Thickness = if selected then 4 else 3
	setSelectedLook(button, selected)
	nameLabel.Visible = true
	nameLabel.Text = info.name
	valueLabel.Visible = true
	valueLabel.Text = abbreviate(info.value) -- white text on the red pill (HotbarGui)
	-- "x1" on every slot is noise: the badge (right column, under the value pill) only shows
	-- for stacks.
	local count = availableCount(hero)
	countBadge.Visible = count > 1
	countLabel.Text = "x" .. commas(count)
	ItemDisplay.SetPicture(button, info)
end

local function sortedHeroes(): { string }
	local list: { string } = {}
	local folder = heroesFolder()
	if folder then
		for _, v in folder:GetChildren() do
			if v:IsA("IntValue") and availableCount(v.Name) > 0 then
				table.insert(list, v.Name)
			end
		end
	end
	local power: { [string]: number } = {}
	local order: { [string]: number } = {}
	for _, name in list do
		local hero = TreeConfig.GetHero(name)
		power[name] = if hero then hero.MinePower else 0
		order[name] = if hero then TreeConfig.RarityOrder[hero.Rarity] or 99 else 99
	end
	table.sort(list, function(a, b)
		if power[a] ~= power[b] then
			return power[a] > power[b]
		elseif order[a] ~= order[b] then
			return order[a] < order[b]
		end
		return a < b
	end)
	return list
end

local function render()
	renderQueued = false
	placed = placedCounts()
	local heroes = sortedHeroes()
	if selectedHero and availableCount(selectedHero) <= 0 then
		selectedHero = nil
	end
	sendSelection()
	for i, slot in slots do
		slot.hero = heroes[i]
		drawSlot(slot)
	end
	if hoveredSlot then
		showTip(hoveredSlot)
	end
end

local function queueRender()
	if not renderQueued then
		renderQueued = true
		task.defer(render)
	end
end

-- Selection --------------------------------------------------------------------------------------

local function selectSlot(index: number)
	local slot = slots[index]
	if not slot then
		return
	end
	bump(slot.button, 0.88)
	if not slot.hero then
		return
	end
	selectedHero = if selectedHero == slot.hero then nil else slot.hero
	render() -- also sends the selection to the server
end

for i = 1, SLOT_COUNT do
	local button = slotTemplate:Clone()
	button.Name = "Slot" .. i
	button.LayoutOrder = i;
	(button:FindFirstChild("Key") :: TextLabel).Text = tostring(i)
	local slot: Slot = { button = button, hero = nil }
	slots[i] = slot
	button.MouseEnter:Connect(function()
		hoveredSlot = slot
		showTip(slot)
	end)
	button.MouseLeave:Connect(function()
		hideTip(slot)
	end)
	button.Activated:Connect(function()
		selectSlot(i)
	end)
	button.Parent = slotsFrame
end

-- The backpack button (or `) opens/closes the inventory window (InventoryUI watches "Open").
local function toggleBackpack()
	bump(backpackButton, 0.88)
	local inventoryGui = player.PlayerGui:FindFirstChild("InventoryGui")
	if inventoryGui then
		inventoryGui:SetAttribute("Open", inventoryGui:GetAttribute("Open") ~= true)
	end
end

backpackButton.Activated:Connect(toggleBackpack)

-- The server put the last copy of the held hero on a pad: empty the hands.
HeroSlotRemote.OnClientEvent:Connect(function(action, hero)
	if action == "Deselect" and selectedHero == hero then
		selectedHero = nil
		sentHero = nil -- the server already cleared it
		render()
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.Backquote then
		toggleBackpack()
		return
	end
	local index = KEYS[input.KeyCode]
	if index then
		selectSlot(index)
	end
end)

-- Watch player.Heroes -----------------------------------------------------------------------------

local heroConnections: { RBXScriptConnection } = {}

local function watchHeroes(folder: Instance)
	for _, c in heroConnections do
		c:Disconnect()
	end
	table.clear(heroConnections)
	local function hook(v: Instance)
		if v:IsA("IntValue") then
			table.insert(heroConnections, v.Changed:Connect(queueRender))
		end
	end
	for _, v in folder:GetChildren() do
		hook(v)
	end
	table.insert(heroConnections, folder.ChildAdded:Connect(function(v)
		hook(v)
		queueRender()
	end))
	table.insert(heroConnections, folder.ChildRemoved:Connect(queueRender))
	queueRender()
end

player.ChildAdded:Connect(function(c)
	if c.Name == "Heroes" then
		watchHeroes(c)
	end
end)
local existing = heroesFolder()
if existing then
	watchHeroes(existing)
end

-- Heroes put on / taken off my pads change what is left in the bar.
local function watchPlotPart(d: Instance)
	if d:IsA("Model") and d.Parent and d.Parent.Name == "HeroSlots" then
		d:GetAttributeChangedSignal("HeroId"):Connect(queueRender)
	elseif d:IsA("Model") and d.Parent and d.Parent.Name == "Plots" then
		d:GetAttributeChangedSignal("OwnerUserId"):Connect(queueRender)
	end
end
task.spawn(function()
	local plots = workspace:WaitForChild("Plots")
	for _, d in plots:GetDescendants() do
		watchPlotPart(d)
	end
	plots.DescendantAdded:Connect(watchPlotPart)
	queueRender()
end)

-- Farm Stand keeper / helper pads (StandService) change what is left too.
local function watchStandPad(pad: Instance)
	pad:GetAttributeChangedSignal("HeroId"):Connect(queueRender)
end
for _, pad in CollectionService:GetTagged("StandHeroPad") do
	watchStandPad(pad)
end
CollectionService:GetInstanceAddedSignal("StandHeroPad"):Connect(function(pad)
	watchStandPad(pad)
	queueRender()
end)
render()

-- "Added!" / "New!" popups ------------------------------------------------------------------------
-- Each popup is a transparent "slot" frame in Popups' UIListLayout with the card inside it. The
-- slots never move or resize while cards animate, so the row never jumps: a card rises into its
-- slot (slide up + grow) and later sinks out of it, and the slots are removed together at the end.
-- Cards are built one at a time on their turn (each has a 3D view), so a big Take All doesn't
-- stall a single frame.

type Received = { Stack: string, Amount: number, New: boolean }

local POP_IN = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local POP_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local POP_RISE = 0.45 -- cards start this far below their slot (fraction of the card height)
local POP_FROM_SCALE = 0.7
local POP_OUT_SCALE = 0.85
local CHEST_CLOSE_WAIT = 0.5 -- max seconds to wait for the chest panel to finish closing

local popupGeneration = 0
local shownSlots: { Frame } = {}

-- A transparent frame with the template's size / aspect ratio that holds one card in the layout.
local function makeSlot(template: Frame, order: number): Frame
	local slot = Instance.new("Frame")
	slot.Name = "PopupSlot"
	slot.BackgroundTransparency = 1
	slot.BorderSizePixel = 0
	slot.Size = template.Size
	slot.LayoutOrder = order
	local aspect = template:FindFirstChildOfClass("UIAspectRatioConstraint")
	if aspect then
		aspect:Clone().Parent = slot
	end
	slot.Parent = popupsFrame
	return slot
end

-- Puts a built card into its slot and plays it in.
local function popIn(slot: Frame, card: Frame)
	card.AnchorPoint = Vector2.zero
	card.Size = UDim2.fromScale(1, 1)
	card.Position = UDim2.fromScale(0, POP_RISE)
	card.LayoutOrder = 0
	local aspect = card:FindFirstChildOfClass("UIAspectRatioConstraint")
	if aspect then
		aspect:Destroy() -- the slot keeps the shape
	end
	local scale = card:FindFirstChild("PopScale") :: UIScale
	scale.Scale = POP_FROM_SCALE
	card.Parent = slot
	TweenService:Create(card, POP_IN, { Position = UDim2.fromScale(0, 0) }):Play()
	TweenService:Create(scale, POP_IN, { Scale = 1 }):Play()
end

local function popOut(slot: Frame, delay: number, onDone: (() -> ())?)
	task.delay(delay, function()
		local card = slot:FindFirstChildOfClass("Frame")
		if not slot.Parent or not card then
			if onDone then
				onDone()
			end
			return
		end
		local scale = card:FindFirstChild("PopScale") :: UIScale
		TweenService:Create(scale, POP_OUT, { Scale = POP_OUT_SCALE }):Play()
		local tween = TweenService:Create(card, POP_OUT, { Position = UDim2.fromScale(0, POP_RISE * 1.6) })
		tween.Completed:Once(function()
			card.Visible = false
			if onDone then
				onDone()
			end
		end)
		tween:Play()
	end)
end

-- Removes every popup right away (a new Take All replaces the old row).
local function clearPopups()
	for _, child in popupsFrame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	table.clear(shownSlots)
end

local function makePopup(entry: Received): Frame
	local info = ItemDisplay.Info(entry.Stack)
	local frame = popupTemplate:Clone()
	frame.Name = entry.Stack
	ItemDisplay.PaintRarity(frame, info.rarity);
	(frame:FindFirstChild("ItemName") :: TextLabel).Text = info.name
	local valueLabel = frame:FindFirstChild("Value") :: TextLabel
	if info.isHero then
		valueLabel.Text = abbreviate(info.value)
		valueLabel.TextColor3 = ItemDisplay.HERO_VALUE_COLOR
	else
		valueLabel.Text = "$" .. abbreviate(info.value)
		valueLabel.TextColor3 = ItemDisplay.MATERIAL_VALUE_COLOR
	end
	(frame:FindFirstChild("Count") :: TextLabel).Text = "x" .. commas(entry.Amount)
	local tag = frame:FindFirstChild("Tag") :: TextLabel
	tag.Text = if entry.New then "New!" else "Added!"
	tag.BackgroundColor3 = if entry.New then TAG_NEW else TAG_ADDED;
	(tag:FindFirstChild("Border") :: UIStroke).Color = if entry.New then TAG_NEW_BORDER else TAG_ADDED_BORDER
	ItemDisplay.SetPicture(frame, info)
	return frame
end

-- New items first, then heroes, then by rarity.
local function popupOrder(a: Received, b: Received): boolean
	if a.New ~= b.New then
		return a.New
	end
	local ia, ib = ItemDisplay.Info(a.Stack), ItemDisplay.Info(b.Stack)
	if ia.isHero ~= ib.isHero then
		return ia.isHero
	end
	local ra, rb = TreeConfig.RarityOrder[ia.rarity] or 99, TreeConfig.RarityOrder[ib.rarity] or 99
	if ra ~= rb then
		return ra < rb
	end
	return ia.name < ib.name
end

-- Waits (a little) for the chest window to finish its close animation after Take All.
local function waitForChestClosed()
	local chestGui = player.PlayerGui:FindFirstChild("ChestGui")
	local panel = chestGui and chestGui:FindFirstChild("Panel")
	if not panel or not panel:IsA("GuiObject") then
		return
	end
	local start = os.clock()
	while panel.Visible and os.clock() - start < CHEST_CLOSE_WAIT do
		task.wait()
	end
end

local function showReceived(received: { Received })
	if typeof(received) ~= "table" or #received == 0 then
		return
	end
	popupGeneration += 1
	local generation = popupGeneration
	table.sort(received, popupOrder)
	waitForChestClosed()
	if generation ~= popupGeneration then
		return -- a newer Take All arrived meanwhile
	end
	clearPopups()

	-- All slots first (the row's final layout), then the cards one by one.
	local count = math.min(#received, MAX_POPUPS)
	local more = #received > MAX_POPUPS
	for i = 1, count + (if more then 1 else 0) do
		table.insert(shownSlots, makeSlot(if i <= count then popupTemplate else moreTemplate, i))
	end
	for i, slot in shownSlots do
		task.delay((i - 1) * POPUP_STAGGER, function()
			if generation ~= popupGeneration or not slot.Parent then
				return
			end
			local card
			if i <= count then
				card = makePopup(received[i])
			else
				card = moreTemplate:Clone();
				(card:FindFirstChild("Label") :: TextLabel).Text = ("+%d More"):format(#received - MAX_POPUPS)
			end
			popIn(slot, card)
		end)
	end

	-- Bump the hotbar slots of heroes that just arrived (after the Heroes values replicate).
	task.delay(0.15, function()
		for _, entry in received do
			local info = ItemDisplay.Info(entry.Stack)
			if info.isHero then
				for _, slot in slots do
					if slot.hero == info.name then
						bump(slot.button, 1.15)
					end
				end
			end
		end
	end)

	task.delay(POPUP_TIME, function()
		if generation ~= popupGeneration then
			return -- newer popups replaced these
		end
		local slotsOut = table.clone(shownSlots)
		table.clear(shownSlots)
		local left = #slotsOut
		-- Right to left, then the empty slots go all at once so the row never shifts.
		for i = #slotsOut, 1, -1 do
			popOut(slotsOut[i], (#slotsOut - i) * POPUP_STAGGER * 0.6, function()
				left -= 1
				if left == 0 then
					for _, s in slotsOut do
						s:Destroy()
					end
				end
			end)
		end
	end)
end

ItemsAdded.OnClientEvent:Connect(showReceived)
