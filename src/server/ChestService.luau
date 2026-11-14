-- ChestService: the treasure chest that material drops fly into (the plot's loot pile).
--
-- A chest is a Model named "TreasureChest" with "Capacity" and "Stored" attributes (item count).
-- Lookup: a TreasureChest inside the plot first, otherwise the shared workspace.TreasureChest.
-- What is inside lives in a "Contents" folder on the chest: one IntValue per material stack, named
-- "<Material key>". "Stored" is always their total. Heroes never go in the chest: they drop straight
-- into player.Heroes (TreeHitService).
--
-- Materials leave the chest only to be carried to the Farm Stand (Loot Pad / helpers, see
-- ChestService.TakeMaterials). Nothing is sold from here any more.
-- Players open the chest with its ProximityPrompt ("E  Loot Chest / Open") to see what is inside;
-- the window is client-side (ChestUI) and only displays.
-- Each client draws the chest's bar/text itself (ChestFX), so the number can count up as items land.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))

type Drop = TreeConfig.Drop

local ChestService = {}

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

-- Puts the material drops in the chest (the caller already trimmed them to what fits). Hero drops
-- are skipped: heroes go straight to player.Heroes.
function ChestService.AddDrops(chest: Model, drops: { Drop })
	local folder = contents(chest)
	for _, drop in drops do
		if drop.Kind == "Anime" then
			continue
		end
		local name = drop.Kind
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

-- Saving the plot chest ---------------------------------------------------------------------------

local pendingContents: { [Player]: { [string]: number } } = {}
local chestReady: { [Player]: boolean } = {} -- plot claimed and its chest already reset

Players.PlayerRemoving:Connect(function(player)
	task.defer(function()
		pendingContents[player] = nil
		chestReady[player] = nil
	end)
end)

-- The chest inside the plot this player owns (found via the player's "Plot" attribute, which stays
-- set while PlotReleased runs). Never the shared chest.
local function ownChest(player: Player): Model?
	local plotName = player:GetAttribute("Plot")
	local plots = workspace:FindFirstChild("Plots")
	local plot = typeof(plotName) == "string" and plots and plots:FindFirstChild(plotName)
	if not plot then
		return nil
	end
	local own = plot:FindFirstChild("TreasureChest", true)
	return if own and own:IsA("Model") then own else nil
end

-- Stack name -> amount in the player's plot chest, or nil without one.
function ChestService.GetContentsFor(player: Player): { [string]: number }?
	local chest = ownChest(player)
	if not chest then
		return nil
	end
	local out = {}
	for _, v in contents(chest):GetChildren() do
		if v:IsA("IntValue") and v.Value > 0 then
			out[v.Name] = v.Value
		end
	end
	return out
end

local function addStacks(chest: Model, stacks: { [string]: number })
	local folder = contents(chest)
	for name, amount in stacks do
		local value = folder:FindFirstChild(name) :: IntValue?
		if not value then
			local newValue = Instance.new("IntValue")
			newValue.Name = name
			newValue.Parent = folder
			value = newValue
		end
		(value :: IntValue).Value += amount
	end
	recount(chest)
end

-- Puts saved stacks back into the player's plot chest (now, or once their plot is set up).
function ChestService.RestoreContents(player: Player, stacks: { [string]: number })
	local chest = ownChest(player)
	if chest and chestReady[player] then
		addStacks(chest, stacks)
	else
		pendingContents[player] = stacks
	end
end

-- Called right after the plot's chest was reset for its new owner.
function ChestService.SetupPlot(plot: Model, player: Player)
	chestReady[player] = true
	local stacks = pendingContents[player]
	pendingContents[player] = nil
	local own = plot:FindFirstChild("TreasureChest", true)
	if stacks and own and own:IsA("Model") then
		addStacks(own, stacks)
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

-- Called after every AddItem with (player, folderName, itemName); IndexService sets it to mark the
-- item as found in the Index (a hook, so ChestService doesn't depend on IndexService).
ChestService.ItemAddedHook = nil :: ((Player, string, string) -> ())?

-- Returns true when the player did not own any of this item before ("New!" popup).
function ChestService.AddItem(player: Player, folderName: string, itemName: string, amount: number): boolean
	local hook = ChestService.ItemAddedHook
	if hook and amount > 0 then
		hook(player, folderName, itemName)
	end
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

function ChestService.GetMoney(player: Player): number
	return money(player).Value
end

-- Takes `amount` if the player has it. Returns false (and takes nothing) otherwise.
function ChestService.SpendMoney(player: Player, amount: number): boolean
	local value = money(player)
	if amount < 0 or value.Value < amount then
		return false
	end
	value.Value -= amount
	return true
end

-- Puts materials back into a chest (e.g. what a helper carried but the stand could not take).
function ChestService.PutMaterials(chest: Model, stacks: { [string]: number })
	local clean = {}
	for id, n in stacks do
		if TreeConfig.Materials[id] and n > 0 then
			clean[id] = math.floor(n)
		end
	end
	if next(clean) then
		addStacks(chest, clean)
	end
end

-- Taking materials out ----------------------------------------------------------------------------

-- Removes up to `max` materials from the chest, rarest-value stacks last (cheap ones go first), and
-- returns what was taken as { [Material key] = amount }. The single place materials leave a chest,
-- so the Loot Pad and the helpers can never take the same items twice (server runs one at a time).
function ChestService.TakeMaterials(chest: Model, max: number): { [string]: number }
	local taken: { [string]: number } = {}
	if max <= 0 then
		return taken
	end
	local stacks = {}
	for _, v in contents(chest):GetChildren() do
		if v:IsA("IntValue") and v.Value > 0 and TreeConfig.Materials[v.Name] then
			table.insert(stacks, v)
		end
	end
	table.sort(stacks, function(a, b)
		return TreeConfig.Materials[a.Name].Value < TreeConfig.Materials[b.Name].Value
	end)
	local left = math.floor(max)
	for _, v in stacks do
		if left <= 0 then
			break
		end
		local n = math.min(v.Value, left)
		v.Value -= n
		left -= n
		taken[v.Name] = (taken[v.Name] or 0) + n
		if v.Value <= 0 then
			v:Destroy()
		end
	end
	recount(chest)
	return taken
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
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
end

return ChestService
