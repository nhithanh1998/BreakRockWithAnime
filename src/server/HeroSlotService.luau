-- HeroSlotService: the 9 hero pads on each plot (plot.HeroSlots.Slot1..Slot9, each with a "Pad" part
-- and its "Empty" / "HeroInfo" billboards).
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
-- Upgrades: each pad has stat levels (HeroConfig.Upgrades: Damage / Speed / Walk), shown on the slot
-- as attributes "LevelDamage" etc. The client's Upgrade window (HeroUpgradeUI, opened from the
-- plaque on the pad) buys them through Remotes.HeroUpgrade (RemoteFunction: slotIndex, stat -> ok,
-- message). Levels stay with the pad when heroes change.
-- Grades: each pad stat also has a grade F..SSS (HeroConfig.Grades), slot attributes "GradeDamage"
-- etc. HeroUpgrade(slotIndex, "Reroll", lockedStats?) rolls them again, except the stats in
-- lockedStats (a list of stat names), for HeroConfig.RerollCostFor(#locked).
-- Stored in the same per-pad table as the levels, as "Grade<stat>" = position in GradeOrder.
-- HeroUpgrade(slotIndex, "RerollStat", stat) rolls just that stat for HeroConfig.RerollStatCost.
-- Axes: HeroUpgrade(slotIndex, "EquipAxe", model | "") gives the pad's hero a copy of an owned axe
-- (ShopService.Copies; each copy goes to one pad) or takes it off. Slot attribute "HeroAxe";
-- the hero holds it and deals ShopConfig HeroBoost x damage (HeroWorkerService). Saved per pad.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))
local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local HeroWorkerService = require(script.Parent:WaitForChild("HeroWorkerService"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))
local HeldHeroService = require(script.Parent:WaitForChild("HeldHeroService"))
local HeroModels = require(script.Parent:WaitForChild("HeroModels"))
local ShopConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ShopConfig"))

-- ShopService requires this module, so it is looked up lazily (when an axe is equipped).
local function axeCopies(player: Player, model: string): number
	local ShopService = require(script.Parent:WaitForChild("ShopService")) :: any
	return ShopService.Copies(player, model)
end

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
local upgradeRemote = Remotes:FindFirstChild("HeroUpgrade") :: RemoteFunction?
if not upgradeRemote then
	local rf = Instance.new("RemoteFunction")
	rf.Name = "HeroUpgrade"
	rf.Parent = Remotes
	upgradeRemote = rf
end

type PlotState = {
	plot: Model,
	owner: Player,
	placed: { [number]: string }, -- slot index -> hero name
	levels: { [number]: { [string]: number } }, -- slot index -> stat -> level (missing = 1), and "Grade<stat>" -> grade position
	axes: { [number]: string }, -- slot index -> axe model its hero holds
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

-- Upgrade levels ---------------------------------------------------------------------------------

local function levelOf(state: PlotState, index: number, stat: string): number
	local levels = state.levels[index]
	return levels and levels[stat] or 1
end

-- Grade letter of a pad stat (DefaultGrade when never rerolled).
local function gradeIn(levels: { [string]: number }?, stat: string): string
	local position = levels and levels[HeroConfig.GradeAttribute(stat)]
	return position and HeroConfig.GradeOrder[position] or HeroConfig.DefaultGrade
end

-- Mirrors a pad's levels and grades onto its slot (attributes) so clients and HeroWorkerService can
-- read them.
local function writeLevels(slot: Model, levels: { [string]: number }?)
	for stat in HeroConfig.Upgrades do
		slot:SetAttribute(HeroConfig.LevelAttribute(stat), levels and levels[stat] or 1)
		slot:SetAttribute(HeroConfig.GradeAttribute(stat), gradeIn(levels, stat))
	end
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

-- Each pad has two billboards: Pad.Empty.BillboardGui ("EmptyText") for an empty or locked pad, and
-- Pad.HeroInfo.BillboardGui (HeroName / Level / Rarity / Power) for a pad with a hero on it.
-- Only one of them is shown at a time; their positions are set in Studio.
local function billboard(pad: Instance, attachment: string): BillboardGui?
	local a = pad:FindFirstChild(attachment)
	local gui = a and a:FindFirstChildOfClass("BillboardGui")
	return gui
end

-- The damage the pad's hero deals per swing (its Power x the pad's Damage level and grade, x the axe's
-- HeroBoost), read from the slot attributes writeLevels / "HeroAxe" keep up to date.
local function padDamage(slot: Model, hero: string): number
	local level = slot:GetAttribute(HeroConfig.LevelAttribute("Damage"))
	local grade = slot:GetAttribute(HeroConfig.GradeAttribute("Damage"))
	local value = HeroConfig.StatValue(
		"Damage",
		if typeof(level) == "number" then level else 1,
		if typeof(grade) == "string" then grade else nil,
		hero
	)
	local axe = slot:GetAttribute("HeroAxe")
	local def = typeof(axe) == "string" and axe ~= "" and ShopConfig.GetAxe(axe)
	if def then
		value = math.max(1, math.floor(value * def.HeroBoost))
	end
	return value
end

local function drawGui(slot: Model, hero: string?, locked: boolean?)
	-- Clients read this (e.g. the Sell window keeps heroes that stand on a pad).
	slot:SetAttribute("HeroId", if hero and not locked then hero else "")
	local pad = slot:FindFirstChild("Pad")
	if not pad then
		return
	end
	local def = if hero and not locked then HeroConfig.Get(hero) else nil

	local empty = billboard(pad, "Empty")
	if empty then
		empty.Enabled = def == nil
		local text = empty:FindFirstChild("EmptyText") :: TextLabel?
		if text then
			if text:GetAttribute("DefaultText") == nil then
				text:SetAttribute("DefaultText", text.Text)
			end
			if locked then
				-- Locked pads show their unlock price (green) under "Locked".
				local index = slotIndex(slot)
				local price = index and HeroConfig.Slots.UnlockPrices[index]
				text.RichText = true
				text.Text = if price
					then ('%s\n<font color="#%s">$%s</font>'):format(
						HeroConfig.Slots.LockedText,
						HeroConfig.Slots.PriceColor:ToHex(),
						HeroConfig.Abbreviate(price)
					)
					else HeroConfig.Slots.LockedText
			else
				text.Text = text:GetAttribute("DefaultText")
			end
		end
	end

	local info = billboard(pad, "HeroInfo")
	if info then
		info.Enabled = def ~= nil
		if def then
			local nameLabel = info:FindFirstChild("HeroName") :: TextLabel?
			if nameLabel then
				nameLabel.Text = def.Name
			end
			local levelLabel = info:FindFirstChild("Level") :: TextLabel?
			if levelLabel then
				local level = slot:GetAttribute(HeroConfig.LevelAttribute("Damage"))
				levelLabel.Text = "Level " .. tostring(if typeof(level) == "number" then level else 1)
			end
			local rarityLabel = info:FindFirstChild("Rarity") :: TextLabel?
			if rarityLabel then
				HeroConfig.PaintRarity(rarityLabel, def.Rarity)
			end
			local powerLabel = info:FindFirstChild("Power") :: TextLabel?
			if powerLabel then
				powerLabel.Text = HeroConfig.Abbreviate(padDamage(slot, def.Name))
			end
		end
	end
end

-- A copy of the placed hero standing idle on top of the pad with its axe (the working copy is out
-- chopping trees). Rebuilt only when the pad's hero changes.
-- Body height of the plot owner's character (HeroConfig.Slots.PadHeroHeight without one).
local function ownerHeight(owner: Player?): number
	local character = owner and owner.Character
	local height = if character then HeroModels.BodyHeight(character) else 0
	return if height > 1 then height else HeroConfig.Slots.PadHeroHeight
end

local function drawPadHero(slot: Model, hero: string?, owner: Player?)
	local current = slot:FindFirstChild(PAD_HERO_NAME)
	local axe = slot:GetAttribute("HeroAxe")
	axe = if typeof(axe) == "string" and axe ~= "" then axe else nil
	if current and hero and current:GetAttribute("Hero") == hero and current:GetAttribute("Axe") == axe then
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
	HeroModels.HideBar(model) -- the pad's HeroInfo billboard already names it
	humanoid.EvaluateStateMachine = false
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff

	-- Body as tall as the owner's body (the axe gets the same factor so it stays in proportion).
	local factor = 1
	local height = HeroModels.BodyHeight(model)
	if height > 0 then
		local before = model:GetScale()
		if pcall(model.ScaleTo, model, before * ownerHeight(owner) / height) then
			factor = model:GetScale() / before
		end
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

	model:SetAttribute("Axe", axe)
	HeroModels.GiveAxe(model, humanoid, factor, axe)
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
		writeLevels(slot, state.levels[i])
		slot:SetAttribute("HeroAxe", state.axes[i] or "")
		drawPad(slot, locked)
		if locked then
			-- Pads can get locked again (e.g. an upgrade is reset): send its hero home.
			if state.placed[i] then
				state.placed[i] = nil
				HeroWorkerService.Despawn(state.plot, i)
			end
			drawGui(slot, nil, true)
			drawPadHero(slot, nil, state.owner)
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
		drawPadHero(slot, hero, state.owner)
		drawGui(slot, hero)
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

-- Upgrading --------------------------------------------------------------------------------------

local function upgrade(state: PlotState, index: number, stat: string): (boolean, string)
	local slot = slotsOf(state.plot)[index]
	if not slot or index > unlockedCount(state.owner) then
		return false, "Locked pad"
	end
	if not state.placed[index] then
		return false, "No hero on this pad"
	end
	local level = levelOf(state, index, stat)
	local cost = HeroConfig.UpgradeCost(stat, level)
	if not cost then
		return false, "Max level!"
	end
	if not ChestService.SpendMoney(state.owner, cost) then
		local short = cost - ChestService.GetMoney(state.owner)
		return false, ("Need %s more Cash!"):format(HeroConfig.Abbreviate(math.ceil(short)))
	end
	state.levels[index] = state.levels[index] or {}
	state.levels[index][stat] = level + 1
	writeLevels(slot, state.levels[index])
	drawGui(slot, state.placed[index])
	HeroWorkerService.ApplyLevels(state.plot, index)
	return true, ("%s Lv %d!"):format(HeroConfig.Upgrades[stat].Name, level + 1)
end

local rerollRng = Random.new()

-- Rolls a new grade for every stat of the pad that isn't locked.
local function reroll(state: PlotState, index: number, locked: { [string]: boolean }): (boolean, string)
	local slot = slotsOf(state.plot)[index]
	if not slot or index > unlockedCount(state.owner) then
		return false, "Locked pad"
	end
	if not state.placed[index] then
		return false, "No hero on this pad"
	end
	local lockCount = 0
	for _ in locked do
		lockCount += 1
	end
	local cost = HeroConfig.RerollCostFor(lockCount)
	if not cost or lockCount >= #HeroConfig.UpgradeOrder then
		return false, "Can't lock every stat"
	end
	if not ChestService.SpendMoney(state.owner, cost) then
		local short = cost - ChestService.GetMoney(state.owner)
		return false, ("Need %s more Cash!"):format(HeroConfig.Abbreviate(math.ceil(short)))
	end
	local levels = state.levels[index] or {}
	state.levels[index] = levels
	local rolled = {}
	for _, stat in HeroConfig.UpgradeOrder do
		if locked[stat] then
			table.insert(rolled, gradeIn(levels, stat) .. "🔒") -- kept
			continue
		end
		local grade = HeroConfig.RollGrade(rerollRng)
		levels[HeroConfig.GradeAttribute(stat)] = table.find(HeroConfig.GradeOrder, grade)
		table.insert(rolled, grade)
	end
	writeLevels(slot, levels)
	drawGui(slot, state.placed[index])
	HeroWorkerService.ApplyLevels(state.plot, index)
	return true, "Rerolled: " .. table.concat(rolled, " / ")
end

-- Rolls a new grade for one stat of the pad.
local function rerollStat(state: PlotState, index: number, stat: string): (boolean, string)
	local slot = slotsOf(state.plot)[index]
	if not slot or index > unlockedCount(state.owner) then
		return false, "Locked pad"
	end
	if not state.placed[index] then
		return false, "No hero on this pad"
	end
	local cost = HeroConfig.RerollStatCost
	if not ChestService.SpendMoney(state.owner, cost) then
		local short = cost - ChestService.GetMoney(state.owner)
		return false, ("Need %s more Cash!"):format(HeroConfig.Abbreviate(math.ceil(short)))
	end
	local levels = state.levels[index] or {}
	state.levels[index] = levels
	local grade = HeroConfig.RollGrade(rerollRng)
	levels[HeroConfig.GradeAttribute(stat)] = table.find(HeroConfig.GradeOrder, grade)
	writeLevels(slot, levels)
	drawGui(slot, state.placed[index])
	HeroWorkerService.ApplyLevels(state.plot, index)
	return true, ("%s: %s"):format(HeroConfig.Upgrades[stat].Name, grade)
end

-- Copies of `model` this plot's pads hold, not counting pad `except`.
local function axesInUse(state: PlotState, model: string, except: number?): number
	local n = 0
	for i, m in state.axes do
		if m == model and i ~= except then
			n += 1
		end
	end
	return n
end

-- Gives the pad's hero a copy of `model` ("" = take the axe off).
local function equipAxe(state: PlotState, index: number, model: string): (boolean, string)
	local slot = slotsOf(state.plot)[index]
	if not slot or index > unlockedCount(state.owner) then
		return false, "Locked pad"
	end
	if model == "" then
		state.axes[index] = nil
	else
		local def = ShopConfig.GetAxe(model)
		if not def then
			return false, "Unknown axe"
		end
		if not state.placed[index] then
			return false, "No hero on this pad"
		end
		local copies = axeCopies(state.owner, model)
		if copies <= 0 then
			return false, "You don't own that axe"
		end
		if axesInUse(state, model, index) >= copies then
			return false, "No free copy! Buy another at the Lumber Axe shop"
		end
		state.axes[index] = model
	end
	slot:SetAttribute("HeroAxe", state.axes[index] or "")
	drawPadHero(slot, state.placed[index], state.owner)
	drawGui(slot, state.placed[index])
	HeroWorkerService.ApplyLevels(state.plot, index)
	local def = state.axes[index] and ShopConfig.GetAxe(state.axes[index])
	return true, if def then ("%s equipped!"):format(def.Name) else "Axe removed"
end

-- Saved pads (DataService) -----------------------------------------------------------------------

-- Placements loaded before the player's plot was set up wait here.
local pendingPlaced: { [Player]: { [number]: string } } = {}
local pendingLevels: { [Player]: { [number]: { [string]: number } } } = {}
local pendingAxes: { [Player]: { [number]: string } } = {}

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
	local state: PlotState = { plot = plot, owner = owner, placed = {}, levels = {}, axes = {}, connections = {} }
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
	local levels = pendingLevels[owner]
	if levels then
		pendingLevels[owner] = nil
		state.levels = levels
	end
	local axes = pendingAxes[owner]
	if axes then
		pendingAxes[owner] = nil
		for index, model in axes do
			if ShopConfig.GetAxe(model) and axesInUse(state, model, index) < axeCopies(owner, model) then
				state.axes[index] = model
			end
		end
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
		writeLevels(slot, nil)
		slot:SetAttribute("HeroAxe", "")
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

-- Pad levels of the plot this player owns (slot index -> stat -> level), or nil without a plot.
function HeroSlotService.GetLevelsFor(player: Player): { [number]: { [string]: number } }?
	local state = stateOf(player)
	if not state then
		return nil
	end
	local out = {}
	for index, levels in state.levels do
		out[index] = table.clone(levels)
	end
	return out
end

-- Saved pad levels, from DataService. Applied now if the plot is ready, otherwise when it is set up.
function HeroSlotService.RestoreLevels(player: Player, levels: { [number]: { [string]: number } })
	local state = stateOf(player)
	if state then
		for index, stats in levels do
			state.levels[index] = stats
		end
		refresh(state)
		for index in levels do
			HeroWorkerService.ApplyLevels(state.plot, index)
		end
	else
		pendingLevels[player] = levels
	end
end

-- Axes on the pads of the plot this player owns (slot index -> axe model), or nil without a plot.
function HeroSlotService.GetAxesFor(player: Player): { [number]: string }?
	local state = stateOf(player)
	return if state then table.clone(state.axes) else nil
end

-- Saved pad axes, from DataService (after the owned axes are applied). Copies the player doesn't
-- have any more are dropped.
local function applyAxes(state: PlotState, axes: { [number]: string })
	for index, model in axes do
		if ShopConfig.GetAxe(model) and axesInUse(state, model, index) < axeCopies(state.owner, model) then
			state.axes[index] = model
		end
	end
	refresh(state)
	for index in axes do
		HeroWorkerService.ApplyLevels(state.plot, index)
	end
end

function HeroSlotService.RestoreAxes(player: Player, axes: { [number]: string })
	local state = stateOf(player)
	if state then
		applyAxes(state, axes)
	else
		pendingAxes[player] = axes
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
	upgradeRemote.OnServerInvoke = function(player, index, stat, lockList)
		local action = stat
		if typeof(index) ~= "number" or typeof(action) ~= "string" then
			return false, "Bad request"
		end
		if action == "RerollStat" or action == "EquipAxe" then
			local state = stateOf(player)
			if not state then
				return false, "No plot"
			end
			if action == "EquipAxe" then
				return equipAxe(state, math.floor(index), if typeof(lockList) == "string" then lockList else "")
			end
			if typeof(lockList) ~= "string" or not HeroConfig.Upgrades[lockList] then
				return false, "Bad request"
			end
			return rerollStat(state, math.floor(index), lockList)
		end
		if not (HeroConfig.Upgrades[stat] or stat == "Reroll") then
			return false, "Bad request"
		end
		local state = stateOf(player)
		if not state then
			return false, "No plot"
		end
		if stat == "Reroll" then
			-- Only real stat names count as locks (each once).
			local locked: { [string]: boolean } = {}
			if typeof(lockList) == "table" then
				for _, name in lockList do
					if typeof(name) == "string" and HeroConfig.Upgrades[name] then
						locked[name] = true
					end
				end
			end
			return reroll(state, math.floor(index), locked)
		end
		return upgrade(state, math.floor(index), stat)
	end
	Players.PlayerRemoving:Connect(function(player)
		selected[player] = nil
		pendingPlaced[player] = nil
		pendingLevels[player] = nil
		pendingAxes[player] = nil
	end)
end

return HeroSlotService
