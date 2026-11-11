-- ChestService: the treasure chest that tree drops fly into.
--
-- A chest is a Model named "TreasureChest" with "Capacity" and "Stored" attributes (item count).
-- Lookup: a TreasureChest inside the plot first, otherwise the shared workspace.TreasureChest.
-- What is inside lives in a "Contents" folder on the chest: one IntValue per stack, named
-- "<Kind>" for materials or "Anime:<Hero name>" for heroes. "Stored" is always their total.
--
-- Players open the chest with its ProximityPrompt ("E  Loot Chest / Open"); the window itself is
-- client-side (ChestUI). From there:
--   Remotes.ChestAction("TakeAll", chest)        -> moves everything into Inventory / Heroes
--   Remotes.ChestAction("SetAutoSell", bool)     -> player "AutoSell" attribute; while on, material
--                                                   drops are sold for Money instead of stored
-- Each client draws the chest's bar/text itself (ChestFX), so the number can count up as items land.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))

type Drop = TreeConfig.Drop

local ChestService = {}

local HERO_PREFIX = "Anime:"

function ChestService.GetChest(plot: Model?): Model?
	if plot then
		local own = plot:FindFirstChild("TreasureChest", true)
		if own and own:IsA("Model") then
			return own
		end
	end
	local shared = workspace:FindFirstChild("TreasureChest")
	if shared and shared:IsA("Model") then
		return shared
	end
	return nil
end

function ChestService.GetRoom(chest: Model): number
	local capacity = chest:GetAttribute("Capacity") or math.huge
	local stored = chest:GetAttribute("Stored") or 0
	return math.max(capacity - stored, 0)
end

local function contents(chest: Model): Folder
	local folder = chest:FindFirstChild("Contents")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Contents"
		folder.Parent = chest
	end
	return folder :: Folder
end

local function recount(chest: Model)
	local total = 0
	for _, v in contents(chest):GetChildren() do
		if v:IsA("IntValue") then
			total += v.Value
		end
	end
	chest:SetAttribute("Stored", total)
end

local function stackName(drop: Drop): string
	return if drop.Kind == "Anime" then HERO_PREFIX .. drop.Name else drop.Kind
end

-- Puts the drops in the chest (the caller already trimmed them to what fits).
function ChestService.AddDrops(chest: Model, drops: { Drop })
	local folder = contents(chest)
	for _, drop in drops do
		local name = stackName(drop)
		local value = folder:FindFirstChild(name) :: IntValue?
		if not value then
			local newValue = Instance.new("IntValue")
			newValue.Name = name
			newValue.Parent = folder
			value = newValue
		end
		(value :: IntValue).Value += drop.Amount
	end
	recount(chest)
end

function ChestService.Reset(chest: Model)
	contents(chest):ClearAllChildren()
	chest:SetAttribute("Stored", 0)
end

-- Only chests that belong to the plot are emptied with it; a shared chest is left alone.
function ChestService.ResetPlot(plot: Model)
	local own = plot:FindFirstChild("TreasureChest", true)
	if own and own:IsA("Model") then
		ChestService.Reset(own)
	end
end

-- Player data -----------------------------------------------------------------------------------

local function getFolder(player: Player, name: string): Folder
	local folder = player:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = player
	end
	return folder :: Folder
end

-- Returns true when the player did not own any of this item before ("New!" popup).
function ChestService.AddItem(player: Player, folderName: string, itemName: string, amount: number): boolean
	local folder = getFolder(player, folderName)
	local value = folder:FindFirstChild(itemName) :: IntValue?
	local isNew = value == nil or value.Value <= 0
	if not value then
		local newValue = Instance.new("IntValue")
		newValue.Name = itemName
		newValue.Parent = folder
		value = newValue
	end
	(value :: IntValue).Value += amount
	return isNew
end

local function money(player: Player): NumberValue
	local stats = getFolder(player, "leaderstats")
	local value = stats:FindFirstChild("Money") :: NumberValue?
	if not value then
		local newValue = Instance.new("NumberValue")
		newValue.Name = "Money"
		newValue.Parent = stats
		value = newValue
	end
	return value :: NumberValue
end

function ChestService.AddMoney(player: Player, amount: number)
	money(player).Value += amount
end

function ChestService.IsAutoSell(player: Player): boolean
	return player:GetAttribute("AutoSell") == true
end

-- Sells the material drops (heroes are never auto-sold). Returns the drops that were not sold.
function ChestService.SellMaterials(player: Player, drops: { Drop }): { Drop }
	local kept: { Drop } = {}
	local earned = 0
	for _, drop in drops do
		local def = drop.Kind ~= "Anime" and TreeConfig.Materials[drop.Kind]
		if def then
			earned += def.Value * drop.Amount
		else
			table.insert(kept, drop)
		end
	end
	if earned > 0 then
		ChestService.AddMoney(player, earned)
	end
	return kept
end

-- Actions ------------------------------------------------------------------------------------------

local function canUse(player: Player, chest: any): boolean
	if typeof(chest) ~= "Instance" or not chest:IsA("Model") or chest.Name ~= "TreasureChest" then
		return false
	end
	if not chest:IsDescendantOf(workspace) then
		return false
	end
	-- A plot chest is only for its owner; the shared fallback chest is for anyone.
	local node: Instance? = chest.Parent
	while node and node ~= workspace do
		local owner = node:GetAttribute("OwnerUserId")
		if owner ~= nil then
			return owner == player.UserId
		end
		node = node.Parent
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return root ~= nil and (root.Position - chest:GetPivot().Position).Magnitude <= TreeConfig.ChestCloseDistance + 10
end

-- Sent to the client after Take All; it pops up the "Added!" / "New!" frames above the hotbar.
export type Received = { Stack: string, Amount: number, New: boolean }

local itemsAdded: RemoteEvent? = nil

function ChestService.TakeAll(player: Player, chest: Model)
	local received: { Received } = {}
	for _, v in contents(chest):GetChildren() do
		if v:IsA("IntValue") and v.Value > 0 then
			local isNew
			if v.Name:sub(1, #HERO_PREFIX) == HERO_PREFIX then
				isNew = ChestService.AddItem(player, "Heroes", v.Name:sub(#HERO_PREFIX + 1), v.Value)
			else
				isNew = ChestService.AddItem(player, "Inventory", v.Name, v.Value)
			end
			table.insert(received, { Stack = v.Name, Amount = v.Value, New = isNew })
		end
	end
	ChestService.Reset(chest)
	if #received > 0 and itemsAdded then
		itemsAdded:FireClient(player, received)
	end
end

-- Turning auto sell on also sells the materials already sitting in the chest.
local function sellChestMaterials(player: Player, chest: Model)
	local earned = 0
	for _, v in contents(chest):GetChildren() do
		local def = v:IsA("IntValue") and TreeConfig.Materials[v.Name]
		if def then
			earned += def.Value * (v :: IntValue).Value
			v:Destroy()
		end
	end
	if earned > 0 then
		ChestService.AddMoney(player, earned)
	end
	recount(chest)
end

local function onAction(player: Player, action: any, arg: any, chest: any)
	if action == "TakeAll" then
		if canUse(player, arg) then
			ChestService.TakeAll(player, arg)
		end
	elseif action == "SetAutoSell" then
		local on = arg == true
		player:SetAttribute("AutoSell", on)
		if on and canUse(player, chest) then
			sellChestMaterials(player, chest)
		end
	end
end

local function setupPrompt(chest: Model)
	if chest:FindFirstChild("LootChestPrompt", true) then
		return
	end
	local anchor = chest.PrimaryPart or chest:FindFirstChild("BaseRed") or chest:FindFirstChildWhichIsA("BasePart", true)
	if not anchor then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "LootChestPrompt"
	prompt.ObjectText = "Loot Chest"
	prompt.ActionText = "Open"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = TreeConfig.ChestPromptDistance
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor
end

local function isChest(inst: Instance): boolean
	return inst:IsA("Model") and inst.Name == "TreasureChest"
end

function ChestService.Start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local chestAction = remotes:WaitForChild("ChestAction") :: RemoteEvent
	chestAction.OnServerEvent:Connect(onAction)
	itemsAdded = remotes:WaitForChild("ItemsAdded") :: RemoteEvent

	for _, d in workspace:GetDescendants() do
		if isChest(d) then
			contents(d :: Model)
			setupPrompt(d :: Model)
		end
	end
	workspace.DescendantAdded:Connect(function(d)
		if isChest(d) then
			task.defer(function()
				contents(d :: Model)
				setupPrompt(d :: Model)
			end)
		end
	end)

	local function onPlayer(player: Player)
		money(player)
		getFolder(player, "Inventory")
		getFolder(player, "Heroes")
		player:SetAttribute("AutoSell", false)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
end

return ChestService
