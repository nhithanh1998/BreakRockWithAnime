-- HotbarUI: the hero bar at the bottom of the screen (StarterGui.HotbarGui) and the
-- "Added!" / "New!" frames that pop up above it after taking items out of the chest.
--
-- Hotbar: the player's heroes (player.Heroes, one IntValue per hero = how many they own), highest
-- MinePower (HeroConfig) first, in 9 numbered slots. Keys 1-9 or a click select a slot; the selection is
-- sent to the server (Remotes.HeroSlot "Select") so E at an empty hero pad places that hero. Hovering a
-- slot shows a tooltip.
--
-- Popups: ChestService fires Remotes.ItemsAdded({ {Stack, Amount, New} }) after Take All. Up to
-- MAX_POPUPS frames pop in (a "+N More" frame covers the rest) and hide again after POPUP_TIME.
--
-- The layout lives in StarterGui.HotbarGui so it can be tweaked in Studio; this script only fills it.

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
local slotTemplate = templates:WaitForChild("HeroSlot") :: TextButton
local popupTemplate = templates:WaitForChild("Popup") :: Frame
local moreTemplate = templates:WaitForChild("More") :: Frame

local SLOT_COUNT = 9
local MAX_POPUPS = 7
local POPUP_TIME = 6 -- seconds the popups stay before hiding
local POPUP_STAGGER = 0.05
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

local function bump(button: GuiObject, from: number)
	local scale = button:FindFirstChild("SlotScale") :: UIScale?
	if scale then
		scale.Scale = from
		TweenService:Create(scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
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
	local countLabel = button:FindFirstChild("Count") :: TextLabel
	local gradient = button:FindFirstChildOfClass("UIGradient")
	local hero = slot.hero

	if not hero then
		button.BackgroundColor3 = EMPTY_COLOR
		button.BackgroundTransparency = 0.25
		border.Color = Color3.fromRGB(70, 74, 92)
		border.Thickness = 2
		nameLabel.Visible = false
		valueLabel.Visible = false
		countLabel.Visible = false
		if gradient then
			gradient.Enabled = false
		end
		ItemDisplay.SetPicture(button, { name = "", rarity = "Common", isHero = false, value = 0 })
		return
	end

	local info = ItemDisplay.Info(ItemDisplay.HeroStack(hero))
	local bg = ItemDisplay.SlotColor(info.rarity)
	button.BackgroundColor3 = bg
	button.BackgroundTransparency = 0
	if gradient then
		gradient.Enabled = true
	end
	local selected = hero == selectedHero
	border.Color = if selected then SELECTED_BORDER else bg:Lerp(Color3.new(1, 1, 1), 0.4)
	border.Thickness = if selected then 4 else 3
	nameLabel.Visible = true
	nameLabel.Text = info.name
	valueLabel.Visible = true
	valueLabel.Text = abbreviate(info.value)
	valueLabel.TextColor3 = ItemDisplay.HERO_VALUE_COLOR
	countLabel.Visible = true
	countLabel.Text = "x" .. commas(ownedCount(hero))
	ItemDisplay.SetPicture(button, info)
end

local function sortedHeroes(): { string }
	local list: { string } = {}
	local folder = heroesFolder()
	if folder then
		for _, v in folder:GetChildren() do
			if v:IsA("IntValue") and v.Value > 0 then
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
	local heroes = sortedHeroes()
	if selectedHero and ownedCount(selectedHero) <= 0 then
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

backpackButton.Activated:Connect(function()
	bump(backpackButton, 0.88)
	-- TODO: open the full hero inventory window here.
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
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
render()

-- "Added!" / "New!" popups ------------------------------------------------------------------------

type Received = { Stack: string, Amount: number, New: boolean }

local popupGeneration = 0
local shownPopups: { GuiObject } = {}

local function popIn(frame: GuiObject, delay: number)
	local scale = frame:FindFirstChild("PopScale") :: UIScale
	scale.Scale = 0
	task.delay(delay, function()
		if frame.Parent then
			TweenService:Create(scale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
	end)
end

local function popOut(frame: GuiObject, delay: number)
	local scale = frame:FindFirstChild("PopScale") :: UIScale
	task.delay(delay, function()
		if not frame.Parent then
			return
		end
		local tween = TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Scale = 0 })
		tween.Completed:Once(function()
			frame:Destroy()
		end)
		tween:Play()
	end)
end

-- Also removes frames that are still shrinking away from the previous batch.
local function clearPopups()
	for _, child in popupsFrame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	table.clear(shownPopups)
end

local function makePopup(entry: Received, order: number): Frame
	local info = ItemDisplay.Info(entry.Stack)
	local frame = popupTemplate:Clone()
	frame.Name = entry.Stack
	frame.LayoutOrder = order
	local bg = ItemDisplay.SlotColor(info.rarity)
	frame.BackgroundColor3 = bg;
	(frame:FindFirstChild("Border") :: UIStroke).Color = bg:Lerp(Color3.new(1, 1, 1), 0.4);
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

local function showReceived(received: { Received })
	if typeof(received) ~= "table" or #received == 0 then
		return
	end
	popupGeneration += 1
	clearPopups()
	table.sort(received, popupOrder)

	local count = math.min(#received, MAX_POPUPS)
	for i = 1, count do
		local frame = makePopup(received[i], i)
		frame.Parent = popupsFrame
		table.insert(shownPopups, frame)
		popIn(frame, (i - 1) * POPUP_STAGGER)
	end
	if #received > MAX_POPUPS then
		local frame = moreTemplate:Clone();
		(frame:FindFirstChild("Label") :: TextLabel).Text = ("+%d More"):format(#received - MAX_POPUPS)
		frame.Parent = popupsFrame
		table.insert(shownPopups, frame)
		popIn(frame, count * POPUP_STAGGER)
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

	local generation = popupGeneration
	task.delay(POPUP_TIME, function()
		if generation ~= popupGeneration then
			return -- newer popups replaced these
		end
		for i, frame in shownPopups do
			popOut(frame, (i - 1) * POPUP_STAGGER * 0.5)
		end
		table.clear(shownPopups)
	end)
end

ItemsAdded.OnClientEvent:Connect(showReceived)
