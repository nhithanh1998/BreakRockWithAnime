-- HeroSlotService: the 9 hero pads on each plot (plot.HeroSlots.Slot1..Slot9, each with a "Pad" part
-- and its "InfoGui" billboard).
--
-- The plot owner picks a hero on the hotbar (HotbarUI sends Remotes.HeroSlot("Select", heroName | nil)),
-- then presses E at an empty pad: the hero is placed there and HeroWorkerService spawns it at the
-- HeroGate to chop trees. E at a filled pad takes the hero back.
-- A hero can be placed as many times as the player owns it (player.Heroes.<Name>.Value).
-- Nothing is saved yet: pads are cleared when the plot is released.
-- Only the first HeroConfig.Slots.StartUnlocked pads are unlocked; the owner's "UnlockedSlots"
-- attribute raises that. Locked pads are grey and say "Locked"; holding E at the next one buys it
-- for HeroConfig.Slots.UnlockPrices[slot] Money. Each slot's "Unlocked" attribute mirrors this.
-- Prompts use Style = Custom (drawn by SlotPromptUI on the client) and must be held for
-- HeroConfig.Slots.HoldDuration seconds.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))
local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local HeroWorkerService = require(script.Parent:WaitForChild("HeroWorkerService"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))
local HeldHeroService = require(script.Parent:WaitForChild("HeldHeroService"))
local HeroModels = require(script.Parent:WaitForChild("HeroModels"))

local PROMPT_NAME = "HeroSlotPrompt"
local PROMPT_DISTANCE = 10
local EMPTY_TEXT = "Empty Slot"
local PAD_HERO_NAME = "PadHero" -- idle copy of the placed hero standing on the pad, axe in hand

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local HeroSlotRemote = Remotes:FindFirstChild("HeroSlot") :: RemoteEvent?
if not HeroSlotRemote then
	local remote = Instance.new("RemoteEvent")
	remote.Name = "HeroSlot"
	remote.Parent = Remotes
	HeroSlotRemote = remote
end
local remote = HeroSlotRemote :: RemoteEvent

type PlotState = {
	plot: Model,
	owner: Player,
	placed: { [number]: string }, -- slot index -> hero name
	connections: { RBXScriptConnection },
}

local HeroSlotService = {}

local states: { [Model]: PlotState } = {}
local selected: { [Player]: string } = {}

local function slotIndex(slot: Instance): number?
	return tonumber(slot.Name:match("^Slot(%d+)$"))
end

local function slotsOf(plot: Model): { [number]: Model }
	local list = {}
	local folder = plot:FindFirstChild("HeroSlots")
	if folder then
		for _, slot in folder:GetChildren() do
			local i = slotIndex(slot)
			if i and slot:IsA("Model") and slot:FindFirstChild("Pad") then
				list[i] = slot
			end
		end
	end
	return list
end

local function owned(player: Player, hero: string): number
	local folder = player:FindFirstChild("Heroes")
	local value = folder and folder:FindFirstChild(hero) :: IntValue?
	return if value then value.Value else 0
end

local function placedCount(state: PlotState, hero: string): number
	local n = 0
	for _, name in state.placed do
		if name == hero then
			n += 1
		end
	end
	return n
end

-- How many pads (Slot1..SlotN) this player has unlocked.
local function unlockedCount(player: Player?): number
	local n = player and player:GetAttribute("UnlockedSlots")
	return if typeof(n) == "number" then math.max(0, math.floor(n)) else HeroConfig.Slots.StartUnlocked
end

local function canPlace(state: PlotState, hero: string?): boolean
	return hero ~= nil and HeroConfig.Get(hero) ~= nil and owned(state.owner, hero) > placedCount(state, hero)
end

-- Pad visuals ------------------------------------------------------------------------------------

local function drawPad(slot: Model, locked: boolean)
	slot:SetAttribute("Unlocked", not locked)
	local pad = slot:FindFirstChild("Pad")
	if not pad or not pad:IsA("BasePart") then
		return
	end
	-- Remember the template's colour so an unlocked pad goes back to it.
	if pad:GetAttribute("DefaultColor") == nil then
		pad:SetAttribute("DefaultColor", pad.Color)
	end
	pad.Color = if locked then HeroConfig.Slots.LockedPadColor else pad:GetAttribute("DefaultColor")
end

-- The "Power" row above a filled pad: power icon + the hero's power (red), centered, where the
-- "Income" label sits. Made on first use, styled like the "Income" label.
local function powerRow(gui: Instance, income: TextLabel): Frame
	local row = gui:FindFirstChild("Power") :: Frame?
	if row then
		return row
	end
	local frame = Instance.new("Frame")
	frame.Name = "Power"
	frame.BackgroundTransparency = 1
	frame.AnchorPoint = income.AnchorPoint
	frame.Position = income.Position
	frame.Size = income.Size
	frame.Visible = false
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0.02, 0)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Image = HeroConfig.Slots.PowerIcon
	icon.SizeConstraint = Enum.SizeConstraint.RelativeYY
	icon.Size = UDim2.fromScale(0.85, 0.85)
	icon.LayoutOrder = 1
	icon.Parent = frame
	local text = income:Clone()
	for name in text:GetAttributes() do
		text:SetAttribute(name, nil)
	end
	text.Name = "Value"
	text.AnchorPoint = Vector2.zero
	text.Position = UDim2.new()
	text.Size = UDim2.fromScale(0.55, 1)
	text.TextScaled = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextColor3 = income:GetAttribute("DefaultColor") or income.TextColor3
	text.Visible = true
	text.LayoutOrder = 2
	text.Parent = frame
	frame.Parent = gui
	return frame
end

local function drawGui(slot: Model, hero: string?, locked: boolean?)
	-- Clients read this (e.g. the Sell window keeps heroes that stand on a pad).
	slot:SetAttribute("HeroId", if hero and not locked then hero else "")
	local pad = slot:FindFirstChild("Pad")
	local gui = pad and pad:FindFirstChild("InfoGui")
	if not gui then
		return
	end
	local nameLabel = gui:FindFirstChild("HeroName") :: TextLabel?
	local rarityLabel = gui:FindFirstChild("Rarity") :: TextLabel?
	local def = hero and HeroConfig.Get(hero)
	if nameLabel then
		nameLabel.Text = if locked then HeroConfig.Slots.LockedText elseif def then def.Name else EMPTY_TEXT
	end
	if rarityLabel then
		-- Remember the template's look so an emptied pad goes back to it.
		if rarityLabel:GetAttribute("DefaultText") == nil then
			rarityLabel:SetAttribute("DefaultText", rarityLabel.Text)
			rarityLabel:SetAttribute("DefaultVisible", rarityLabel.Visible)
		end
		if def then
			HeroConfig.PaintRarity(rarityLabel, def.Rarity)
			rarityLabel.Visible = true
		else
			rarityLabel.Text = rarityLabel:GetAttribute("DefaultText")
			rarityLabel.Visible = false
		end
	end
	-- Locked pads show their unlock price (in the "Income" label, green) under "Locked".
	local priceLabel = gui:FindFirstChild("Income") :: TextLabel?
	if priceLabel then
		if priceLabel:GetAttribute("DefaultText") == nil then
			priceLabel:SetAttribute("DefaultText", priceLabel.Text)
			priceLabel:SetAttribute("DefaultColor", priceLabel.TextColor3)
			priceLabel:SetAttribute("DefaultVisible", priceLabel.Visible)
		end
		local index = tonumber(slot.Name:match("%d+"))
		local price = locked and index and HeroConfig.Slots.UnlockPrices[index]
		if price then
			priceLabel.Text = "$" .. HeroConfig.Abbreviate(price)
			priceLabel.TextColor3 = HeroConfig.Slots.PriceColor
			priceLabel.Visible = true
		else
			priceLabel.Text = priceLabel:GetAttribute("DefaultText")
			priceLabel.TextColor3 = priceLabel:GetAttribute("DefaultColor")
			priceLabel.Visible = priceLabel:GetAttribute("DefaultVisible")
		end
	end

	local filled = def ~= nil and not locked
	-- Level (no upgrades yet: the slot's "Level" attribute, default 1).
	local levelLabel = gui:FindFirstChild("Level") :: TextLabel?
	if levelLabel then
		local level = slot:GetAttribute("Level")
		levelLabel.Text = "Level " .. tostring(if typeof(level) == "number" then level else 1)
		levelLabel.Visible = filled
	end
	-- Power, in place of the (hidden) Income label.
	if priceLabel then
		local row = powerRow(gui, priceLabel)
		row.Visible = filled
		if filled then
			priceLabel.Visible = false;
			(row:FindFirstChild("Value") :: TextLabel).Text = HeroConfig.Abbreviate((def :: any).MinePower)
		end
	end
	-- Above the pad hero's head while one stands there, at the template's height otherwise.
	if gui:IsA("BillboardGui") and pad:IsA("BasePart") then
		if gui:GetAttribute("DefaultOffset") == nil then
			gui:SetAttribute("DefaultOffset", gui.StudsOffset)
		end
		if filled then
			local y = pad.Size.Y / 2 + HeroConfig.Slots.PadHeroHeight + HeroConfig.Slots.InfoGap + gui.Size.Y.Scale / 2
			gui.StudsOffset = Vector3.new(0, y, 0)
		else
			gui.StudsOffset = gui:GetAttribute("DefaultOffset")
		end
	end
end

-- A copy of the placed hero standing idle on top of the pad with its axe (the working copy is out
-- chopping trees). Rebuilt only when the pad's hero changes.
local function drawPadHero(slot: Model, hero: string?)
	local current = slot:FindFirstChild(PAD_HERO_NAME)
	if current and hero and current:GetAttribute("Hero") == hero then
		return
	end
	if current then
		current:Destroy()
	end
	local pad = slot:FindFirstChild("Pad")
	if not hero or not pad or not pad:IsA("BasePart") then
		return
	end
	local model, humanoid, root = HeroModels.Clone(hero)
	if not model or not humanoid or not root then
		return
	end
	model.Name = PAD_HERO_NAME
	HeroModels.HideBar(model) -- the pad's InfoGui already names it
	humanoid.EvaluateStateMachine = false
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff

	-- As tall as a player.
	local height = model:GetExtentsSize().Y
	if height > 0 then
		pcall(model.ScaleTo, model, model:GetScale() * HeroConfig.Slots.PadHeroHeight / height)
	end

	-- Feet on the pad's top face, facing the way the pad faces.
	local look = Vector3.new(pad.CFrame.LookVector.X, 0, pad.CFrame.LookVector.Z)
	look = if look.Magnitude > 0.01 then look.Unit else Vector3.new(0, 0, -1)
	local top = pad.Position + Vector3.new(0, pad.Size.Y / 2, 0)
	model:PivotTo(CFrame.lookAt(top, top + look))
	local box, size = model:GetBoundingBox()
	model:PivotTo(model:GetPivot() + Vector3.new(0, top.Y - (box.Position.Y - size.Y / 2), 0))
	root.Anchored = true
	model.Parent = slot

	HeroModels.GiveAxe(model, humanoid)
	local anims = HeroModels.Anims(humanoid)
	local idle = HeroModels.LoadTrack(humanoid, anims.Idle, Enum.AnimationPriority.Core, true)
	local hold = HeroModels.LoadTrack(humanoid, anims.Hold, Enum.AnimationPriority.Action, true)
	if idle then
		idle:Play()
	end
	if hold then
		hold:Play()
	end
end

local function getPrompt(slot: Model): ProximityPrompt
	local pad = slot:FindFirstChild("Pad") :: BasePart
	local prompt = pad:FindFirstChild(PROMPT_NAME) :: ProximityPrompt?
	if not prompt then
		local p = Instance.new("ProximityPrompt")
		p.Name = PROMPT_NAME
		p.KeyboardKeyCode = Enum.KeyCode.E
		p.Style = Enum.ProximityPromptStyle.Custom
		p.HoldDuration = HeroConfig.Slots.HoldDuration
		p.MaxActivationDistance = PROMPT_DISTANCE
		p.RequiresLineOfSight = false
		p.Enabled = false
		p.Parent = pad
		prompt = p
	end
	return prompt :: ProximityPrompt
end

local function refresh(state: PlotState)
	local choice = selected[state.owner]
	local unlocked = unlockedCount(state.owner)
	for i, slot in slotsOf(state.plot) do
		local prompt = getPrompt(slot)
		local locked = i > unlocked
		drawPad(slot, locked)
		if locked then
			-- Pads can get locked again (e.g. an upgrade is reset): send its hero home.
			if state.placed[i] then
				state.placed[i] = nil
				HeroWorkerService.Despawn(state.plot, i)
			end
			drawGui(slot, nil, true)
			drawPadHero(slot, nil)
			local price = HeroConfig.Slots.UnlockPrices[i]
			if price then
				prompt.ActionText = ("Unlock Slot For %s Cash!"):format(HeroConfig.Abbreviate(price))
				prompt.ObjectText = if i == unlocked + 1 then "Locked Slot" else ("Unlock Slot %d first"):format(i - 1)
				prompt.Enabled = true
			else
				prompt.Enabled = false -- no price set: can only be opened by an upgrade
			end
			continue
		end
		local hero = state.placed[i]
		drawGui(slot, hero)
		drawPadHero(slot, hero)
		if hero then
			prompt.ActionText = "Take Back " .. hero
			prompt.ObjectText = hero
			prompt.Enabled = true
		elseif canPlace(state, choice) then
			prompt.ActionText = "Place " .. (choice :: string)
			prompt.ObjectText = EMPTY_TEXT
			prompt.Enabled = true
		elseif choice and HeroConfig.Get(choice) then
			-- Holding a hero whose copies are all on pads already.
			prompt.ActionText = "No " .. choice .. " left to place"
			prompt.ObjectText = EMPTY_TEXT
			prompt.Enabled = true
		else
			prompt.ActionText = "Pick a hero (1-0)"
			prompt.ObjectText = EMPTY_TEXT
			prompt.Enabled = true
		end
	end
end

-- Placing ----------------------------------------------------------------------------------------

local function place(state: PlotState, index: number, hero: string)
	state.placed[index] = hero
	HeroWorkerService.Spawn(state.plot, index, hero, state.owner)
end

local function takeBack(state: PlotState, index: number)
	state.placed[index] = nil
	HeroWorkerService.Despawn(state.plot, index)
end

-- Shows `text` on the pad's prompt for a moment (e.g. not enough cash), then the normal text again.
local function flashPrompt(state: PlotState, slot: Model, text: string)
	getPrompt(slot).ObjectText = text
	task.delay(1.5, function()
		if states[state.plot] == state then
			refresh(state)
		end
	end)
end

-- Buys the next locked pad.
local function tryUnlock(state: PlotState, index: number, slot: Model)
	local player = state.owner
	local unlocked = unlockedCount(player)
	local price = HeroConfig.Slots.UnlockPrices[index]
	if index ~= unlocked + 1 or not price then
		return
	end
	if not ChestService.SpendMoney(player, price) then
		local short = price - ChestService.GetMoney(player)
		flashPrompt(state, slot, ("Need %s more Cash!"):format(HeroConfig.Abbreviate(math.ceil(short))))
		return
	end
	player:SetAttribute("UnlockedSlots", index) -- refreshes the pads
end

local function onPrompt(state: PlotState, index: number, player: Player)
	if player ~= state.owner or states[state.plot] ~= state then
		return
	end
	if index > unlockedCount(player) then
		local slot = slotsOf(state.plot)[index]
		if slot then
			tryUnlock(state, index, slot)
		end
		return
	end
	if state.placed[index] then
		takeBack(state, index)
	else
		local hero = selected[player]
		if not canPlace(state, hero) then
			return
		end
		place(state, index, hero :: string)
		-- The last copy went onto the pad: it leaves the player's hands.
		if not canPlace(state, hero) then
			selected[player] = nil
			HeldHeroService.Set(player, nil)
			remote:FireClient(player, "Deselect", hero)
		end
	end
	refresh(state)
end

-- Saved pads (DataService) -----------------------------------------------------------------------

-- Placements loaded before the player's plot was set up wait here.
local pendingPlaced: { [Player]: { [number]: string } } = {}

-- Puts saved heroes back on their pads (only pads that are open and heroes the player still owns).
local function restorePlaced(state: PlotState, placed: { [number]: string })
	local slots = slotsOf(state.plot)
	local unlocked = unlockedCount(state.owner)
	for index, hero in placed do
		if slots[index] and index <= unlocked and not state.placed[index] and canPlace(state, hero) then
			place(state, index, hero)
		end
	end
	refresh(state)
end

-- Plots ------------------------------------------------------------------------------------------

function HeroSlotService.SetupPlot(plot: Model, owner: Player)
	HeroSlotService.ResetPlot(plot)
	local state: PlotState = { plot = plot, owner = owner, placed = {}, connections = {} }
	states[plot] = state
	for i, slot in slotsOf(plot) do
		table.insert(state.connections, getPrompt(slot).Triggered:Connect(function(player)
			onPrompt(state, i, player)
		end))
	end
	-- An upgrade unlocked (or re-locked) pads.
	table.insert(state.connections, owner:GetAttributeChangedSignal("UnlockedSlots"):Connect(function()
		refresh(state)
	end))
	-- Owned counts change (new heroes from the chest): prompts may become usable.
	local function watch(folder: Instance)
		table.insert(state.connections, folder.DescendantAdded:Connect(function()
			refresh(state)
		end))
		for _, v in folder:GetChildren() do
			if v:IsA("IntValue") then
				table.insert(state.connections, v.Changed:Connect(function()
					refresh(state)
				end))
			end
		end
	end
	local heroes = owner:FindFirstChild("Heroes")
	if heroes then
		watch(heroes)
	else
		table.insert(state.connections, owner.ChildAdded:Connect(function(c)
			if c.Name == "Heroes" then
				watch(c)
				refresh(state)
			end
		end))
	end
	refresh(state)
	local pending = pendingPlaced[owner]
	if pending then
		pendingPlaced[owner] = nil
		restorePlaced(state, pending)
	end
end

function HeroSlotService.ResetPlot(plot: Model)
	local state = states[plot]
	states[plot] = nil
	if state then
		for _, c in state.connections do
			c:Disconnect()
		end
	end
	HeroWorkerService.DespawnPlot(plot)
	-- A free plot shows the starting layout: first StartUnlocked pads open, the rest locked.
	for i, slot in slotsOf(plot) do
		local locked = i > HeroConfig.Slots.StartUnlocked
		drawPad(slot, locked)
		drawGui(slot, nil, locked)
		drawPadHero(slot, nil)
		local prompt = slot.Pad:FindFirstChild(PROMPT_NAME)
		if prompt then
			prompt:Destroy()
		end
	end
end

-- The heroes placed on a plot (slot index -> hero name).
function HeroSlotService.GetPlaced(plot: Model): { [number]: string }
	local state = states[plot]
	return if state then table.clone(state.placed) else {}
end

local function stateOf(player: Player): PlotState?
	for _, state in states do
		if state.owner == player then
			return state
		end
	end
	return nil
end

-- The heroes on the pads of the plot this player owns (slot index -> hero name), or nil when they
-- have no set-up plot. Works until the plot is reset, even if PlotService already let go of it.
function HeroSlotService.GetPlacedFor(player: Player): { [number]: string }?
	local state = stateOf(player)
	return if state then table.clone(state.placed) else nil
end

-- Saved placements (slot index -> hero name), from DataService. Applied now if the player's plot is
-- ready, otherwise as soon as it is set up.
function HeroSlotService.RestorePlaced(player: Player, placed: { [number]: string })
	local state = stateOf(player)
	if state then
		restorePlaced(state, placed)
	else
		pendingPlaced[player] = placed
	end
end

function HeroSlotService.Start()
	HeldHeroService.Start()
	-- Free plots show the locked pads too, not only claimed ones.
	local plots = workspace:FindFirstChild("Plots")
	if plots then
		for _, plot in plots:GetChildren() do
			if plot:IsA("Model") and not states[plot] then
				HeroSlotService.ResetPlot(plot)
			end
		end
	end
	remote.OnServerEvent:Connect(function(player, action, hero)
		if action ~= "Select" then
			return
		end
		if typeof(hero) == "string" and TreeConfig.GetHero(hero) and owned(player, hero) > 0 then
			selected[player] = hero
		else
			selected[player] = nil
		end
		HeldHeroService.Set(player, selected[player])
		local state = stateOf(player)
		if state then
			refresh(state)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		selected[player] = nil
		pendingPlaced[player] = nil
	end)
end

return HeroSlotService
