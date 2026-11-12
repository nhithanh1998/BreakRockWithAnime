-- HeroSlotService: the 9 hero pads on each plot (plot.HeroSlots.Slot1..Slot9, each with a "Pad" part
-- and its "InfoGui" billboard).
--
-- The plot owner picks a hero on the hotbar (HotbarUI sends Remotes.HeroSlot("Select", heroName | nil)),
-- then presses E at an empty pad: the hero is placed there and HeroWorkerService spawns it at the
-- HeroGate to chop trees. E at a filled pad takes the hero back.
-- A hero can be placed as many times as the player owns it (player.Heroes.<Name>.Value).
-- Nothing is saved yet: pads are cleared when the plot is released.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))
local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local HeroWorkerService = require(script.Parent:WaitForChild("HeroWorkerService"))

local PROMPT_NAME = "HeroSlotPrompt"
local PROMPT_DISTANCE = 10
local EMPTY_TEXT = "Empty Slot"

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

local function canPlace(state: PlotState, hero: string?): boolean
	return hero ~= nil and HeroConfig.Get(hero) ~= nil and owned(state.owner, hero) > placedCount(state, hero)
end

-- Pad visuals ------------------------------------------------------------------------------------

local function drawGui(slot: Model, hero: string?)
	local pad = slot:FindFirstChild("Pad")
	local gui = pad and pad:FindFirstChild("InfoGui")
	if not gui then
		return
	end
	local nameLabel = gui:FindFirstChild("HeroName") :: TextLabel?
	local rarityLabel = gui:FindFirstChild("Rarity") :: TextLabel?
	local def = hero and HeroConfig.Get(hero)
	if nameLabel then
		nameLabel.Text = if def then def.Name else EMPTY_TEXT
	end
	if rarityLabel then
		-- Remember the template's look so an emptied pad goes back to it.
		if rarityLabel:GetAttribute("DefaultText") == nil then
			rarityLabel:SetAttribute("DefaultText", rarityLabel.Text)
			rarityLabel:SetAttribute("DefaultVisible", rarityLabel.Visible)
		end
		if def then
			rarityLabel.Text = def.Rarity
			rarityLabel.Visible = true
		else
			rarityLabel.Text = rarityLabel:GetAttribute("DefaultText")
			rarityLabel.Visible = false
		end
	end
end

local function getPrompt(slot: Model): ProximityPrompt
	local pad = slot:FindFirstChild("Pad") :: BasePart
	local prompt = pad:FindFirstChild(PROMPT_NAME) :: ProximityPrompt?
	if not prompt then
		local p = Instance.new("ProximityPrompt")
		p.Name = PROMPT_NAME
		p.KeyboardKeyCode = Enum.KeyCode.E
		p.HoldDuration = 0
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
	for i, slot in slotsOf(state.plot) do
		local hero = state.placed[i]
		local prompt = getPrompt(slot)
		drawGui(slot, hero)
		if hero then
			prompt.ActionText = "Take Back"
			prompt.ObjectText = hero
			prompt.Enabled = true
		elseif canPlace(state, choice) then
			prompt.ActionText = "Place Hero"
			prompt.ObjectText = choice :: string
			prompt.Enabled = true
		else
			prompt.ActionText = "Pick a hero (1-9)"
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

local function onPrompt(state: PlotState, index: number, player: Player)
	if player ~= state.owner or states[state.plot] ~= state then
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
	for _, slot in slotsOf(plot) do
		drawGui(slot, nil)
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

function HeroSlotService.Start()
	remote.OnServerEvent:Connect(function(player, action, hero)
		if action ~= "Select" then
			return
		end
		if typeof(hero) == "string" and TreeConfig.GetHero(hero) then
			selected[player] = hero
		else
			selected[player] = nil
		end
		local state = stateOf(player)
		if state then
			refresh(state)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		selected[player] = nil
	end)
end

return HeroSlotService
