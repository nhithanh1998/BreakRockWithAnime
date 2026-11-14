-- ShopService: the Sell and Lumber Axe shops (see ShopConfig).
--
-- Every plot has its own shops in plot.Shops (Models with a "Shop" attribute), so each player uses
-- the shops on their own plot. A Workspace.Shops folder still works too (shared by everyone).
--
-- Each shop model gets a ProximityPrompt "ShopPrompt" (attribute Shop = "Sell" | "LumberAxe") on its
-- "PromptPart"; the client opens the matching window (ShopUI). The window talks to the server through
-- Remotes.ShopAction (RemoteFunction), which answers { ok, message?, earned? }:
--   ("Sell", { [stack] = true })   stack = "<Material key>" or "Anime:<Hero name>"; sells the whole
--                                   stack (heroes on a pad are kept). Must stand near the Sell shop.
--   ("BuyAxe", model)              buys + equips the axe (near the Lumber Axe shop).
--   ("EquipAxe", model)            equips an owned axe (near the Lumber Axe shop).
--   ("BuyAxeCopy", model)          buys one more copy of an owned axe (near the shop, uses stock).
-- Copies: player.Axes.<Model> has a "Copies" attribute (owned = at least 1). Hero pads each hold
-- one copy (HeroSlotService), see ShopService.Copies.
-- Owned axes: player.Axes.<Model> (BoolValue). Equipped: player "EquippedAxe" attribute; it also sets
-- the "ClickDamage" attribute that TreeHitService uses.
-- Stock: ReplicatedStorage.AxeStock.<Model> (IntValue, shared by the whole server), refilled every
-- ShopConfig.RestockInterval seconds; the folder's "NextRestock" attribute is the server time of the
-- next refill. An axe can only be bought when it is in stock and the player's "UnlockedZones" is at
-- least its Zone.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local TreeConfig = require(Shared:WaitForChild("TreeConfig"))
local SkillTreeConfig = require(Shared:WaitForChild("SkillTreeConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local WeatherConfig = require(Shared:WaitForChild("WeatherConfig"))
local PotionConfig = require(Shared:WaitForChild("PotionConfig"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))
local HeroSlotService = require(script.Parent:WaitForChild("HeroSlotService"))
local PlotService = require(script.Parent:WaitForChild("PlotService"))

local HERO_PREFIX = "Anime:"
local STOCK_FOLDER = "AxeStock"
local PROMPT_NAME = "ShopPrompt"

type Result = { ok: boolean, message: string?, earned: number? }

local ShopService = {}

-- Every folder that holds shops: each plot's "Shops" and the old shared Workspace.Shops.
local function shopFolders(): { Instance }
	local list = {}
	local plots = workspace:FindFirstChild("Plots")
	if plots then
		for _, plot in plots:GetChildren() do
			local f = plot:FindFirstChild("Shops")
			if f then
				table.insert(list, f)
			end
		end
	end
	local shared = workspace:FindFirstChild("Shops")
	if shared then
		table.insert(list, shared)
	end
	return list
end

local function shopIn(folder: Instance?, kind: string): Model?
	if folder then
		for _, m in folder:GetChildren() do
			if m:IsA("Model") and m:GetAttribute("Shop") == kind then
				return m
			end
		end
	end
	return nil
end

-- The shop of this kind the player uses: the one on their own plot, else a shared one.
function ShopService.FindShop(player: Player, kind: string): Model?
	local plot = PlotService.GetPlot(player)
	return shopIn(plot and plot:FindFirstChild("Shops"), kind) or shopIn(workspace:FindFirstChild("Shops"), kind)
end

-- Is the player standing near a shop of this kind? (Stops remote calls from across the map.)
local function isNear(player: Player, kind: string): boolean
	local shop = ShopService.FindShop(player, kind)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not shop or not root then
		return false
	end
	local anchor = shop:FindFirstChild("PromptPart")
	local pos = if anchor and anchor:IsA("BasePart") then anchor.Position else shop:GetPivot().Position
	return (root.Position - pos).Magnitude <= ShopConfig.CloseDistance + 8
end

local function folderOf(player: Player, name: string): Folder
	local folder = player:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = player
	end
	return folder :: Folder
end

-- Selling ------------------------------------------------------------------------------------------

local function placedCount(player: Player, hero: string): number
	local plot = PlotService.GetPlot(player)
	local n = 0
	if plot then
		for _, name in HeroSlotService.GetPlaced(plot) do
			if name == hero then
				n += 1
			end
		end
	end
	return n
end

local function sell(player: Player, stacks: any): Result
	if typeof(stacks) ~= "table" then
		return { ok = false, message = "Nothing selected" }
	end
	local earned = 0
	local inventory = folderOf(player, "Inventory")
	local heroes = folderOf(player, "Heroes")
	for stack, picked in stacks do
		if typeof(stack) ~= "string" or picked ~= true then
			continue
		end
		if stack:sub(1, #HERO_PREFIX) == HERO_PREFIX then
			local name = stack:sub(#HERO_PREFIX + 1)
			local def = HeroConfig.Get(name)
			local value = heroes:FindFirstChild(name) :: IntValue?
			if def and value then
				local amount = math.max(0, value.Value - placedCount(player, name))
				earned += math.floor(def.SellValue * ShopConfig.HeroSellMultiplier * WeatherConfig.Mult("SellBonus") * PotionConfig.Mult(player, "SellBonus")) * amount
				value.Value -= amount
				if value.Value <= 0 then
					value:Destroy()
				end
			end
		else
			local def = TreeConfig.Materials[stack]
			local value = inventory:FindFirstChild(stack) :: IntValue?
			if def and value and value.Value > 0 then
				earned += SkillTreeConfig.MaterialValue(player, stack) * value.Value
				value:Destroy()
			end
		end
	end
	if earned <= 0 then
		return { ok = false, message = "Nothing to sell" }
	end
	ChestService.AddMoney(player, earned)
	return { ok = true, earned = earned }
end

-- Stock --------------------------------------------------------------------------------------------

local stockFolder: Folder = (function()
	local f = ReplicatedStorage:FindFirstChild(STOCK_FOLDER)
	if not f then
		f = Instance.new("Folder")
		f.Name = STOCK_FOLDER
		f.Parent = ReplicatedStorage
	end
	return f :: Folder
end)()

local function stockValue(model: string): IntValue
	local v = stockFolder:FindFirstChild(model) :: IntValue?
	if not v then
		local newValue = Instance.new("IntValue")
		newValue.Name = model
		newValue.Parent = stockFolder
		v = newValue
	end
	return v :: IntValue
end

local function restock()
	for _, def in ShopConfig.Axes do
		local range = def.Stock
		stockValue(def.Model).Value = math.random(range[1], range[2])
	end
end

-- Restocks line up with the clock (every RestockInterval seconds since the epoch).
local function nextRestockTime(now: number): number
	local interval = ShopConfig.RestockInterval
	return (math.floor(now / interval) + 1) * interval
end

local function unlockedZones(player: Player): number
	local n = player:GetAttribute("UnlockedZones")
	return if typeof(n) == "number" then n else 1
end

-- Axes ---------------------------------------------------------------------------------------------

local function owns(player: Player, model: string): boolean
	local v = folderOf(player, "Axes"):FindFirstChild(model)
	return v ~= nil and v:IsA("BoolValue") and v.Value
end

-- Makes sure the player owns `model` with at least `copies` copies (default 1).
local function giveAxe(player: Player, model: string, copies: number?)
	local folder = folderOf(player, "Axes")
	local v = folder:FindFirstChild(model) :: BoolValue?
	if not v then
		local newValue = Instance.new("BoolValue")
		newValue.Name = model
		newValue.Parent = folder
		v = newValue
	end
	(v :: BoolValue).Value = true
	local now = (v :: BoolValue):GetAttribute("Copies")
	local have = if typeof(now) == "number" then now else 0
	;(v :: BoolValue):SetAttribute("Copies", math.max(have, copies or 1, 1))
end

-- How many copies of `model` the player has (0 when not owned).
function ShopService.Copies(player: Player, model: string): number
	if not owns(player, model) then
		return 0
	end
	local v = folderOf(player, "Axes"):FindFirstChild(model) :: BoolValue
	local n = v:GetAttribute("Copies")
	return if typeof(n) == "number" then math.max(1, n) else 1
end

local function equip(player: Player, model: string)
	local def = ShopConfig.GetAxe(model)
	if def then
		player:SetAttribute("EquippedAxe", model)
		player:SetAttribute("ClickDamage", def.Damage)
	end
end

local function buyAxe(player: Player, model: any): Result
	local def = typeof(model) == "string" and ShopConfig.GetAxe(model)
	if not def then
		return { ok = false, message = "Unknown axe" }
	end
	if owns(player, def.Model) then
		equip(player, def.Model)
		return { ok = true }
	end
	if unlockedZones(player) < def.Zone then
		return { ok = false, message = ("Unlock Zone %d first!"):format(def.Zone) }
	end
	local stock = stockValue(def.Model)
	if stock.Value <= 0 then
		return { ok = false, message = "Out of stock! Wait for the restock" }
	end
	if not ChestService.SpendMoney(player, def.Price) then
		return { ok = false, message = ("Need %s more Cash!"):format(HeroConfig.Abbreviate(math.ceil(def.Price - ChestService.GetMoney(player)))) }
	end
	stock.Value -= 1
	giveAxe(player, def.Model)
	equip(player, def.Model)
	return { ok = true }
end

local function buyAxeCopy(player: Player, model: any): Result
	local def = typeof(model) == "string" and ShopConfig.GetAxe(model)
	if not def or not owns(player, def.Model) then
		return { ok = false, message = "Buy the axe first" }
	end
	local stock = stockValue(def.Model)
	if stock.Value <= 0 then
		return { ok = false, message = "Out of stock! Wait for the restock" }
	end
	if not ChestService.SpendMoney(player, def.Price) then
		return { ok = false, message = ("Need %s more Cash!"):format(HeroConfig.Abbreviate(math.ceil(def.Price - ChestService.GetMoney(player)))) }
	end
	stock.Value -= 1
	giveAxe(player, def.Model, ShopService.Copies(player, def.Model) + 1)
	return { ok = true, message = ("%s x%d!"):format(def.Name, ShopService.Copies(player, def.Model)) }
end

local function equipAxe(player: Player, model: any): Result
	if typeof(model) ~= "string" or not ShopConfig.GetAxe(model) or not owns(player, model) then
		return { ok = false, message = "You don't own that axe" }
	end
	equip(player, model)
	return { ok = true }
end

-- Wiring -------------------------------------------------------------------------------------------

local function onAction(player: Player, action: any, arg: any): Result
	if action == "Sell" then
		if not isNear(player, "Sell") then
			return { ok = false, message = "Go to the Sell shop" }
		end
		return sell(player, arg)
	elseif action == "BuyAxe" or action == "EquipAxe" or action == "BuyAxeCopy" then
		if not isNear(player, "LumberAxe") then
			return { ok = false, message = "Go to the Lumber Axe shop" }
		end
		if action == "BuyAxeCopy" then
			return buyAxeCopy(player, arg)
		end
		return if action == "BuyAxe" then buyAxe(player, arg) else equipAxe(player, arg)
	end
	return { ok = false }
end

local function setupShop(shop: Model)
	local kind = shop:GetAttribute("Shop")
	local texts = typeof(kind) == "string" and ShopConfig.Shops[kind]
	local anchor = shop:FindFirstChild("PromptPart") or shop.PrimaryPart
	if not texts or not anchor or anchor:FindFirstChild(PROMPT_NAME) then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PROMPT_NAME
	prompt:SetAttribute("Shop", kind)
	prompt.ObjectText = texts.ObjectText
	prompt.ActionText = texts.ActionText
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = ShopConfig.PromptDistance
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor
end

local function onPlayer(player: Player)
	giveAxe(player, ShopConfig.StartAxe)
	equip(player, ShopConfig.StartAxe)
end

-- Saved data (DataService): owned axes + the equipped one + copies per axe.
function ShopService.ApplySaved(player: Player, axes: { any }, equipped: any, copies: any)
	for _, model in axes do
		if typeof(model) == "string" and ShopConfig.GetAxe(model) then
			local n = typeof(copies) == "table" and copies[model]
			giveAxe(player, model, if typeof(n) == "number" then math.floor(n) else 1)
		end
	end
	if typeof(equipped) == "string" and owns(player, equipped) then
		equip(player, equipped)
	end
end

function ShopService.Start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:FindFirstChild("ShopAction") :: RemoteFunction?
	if not remote then
		local newRemote = Instance.new("RemoteFunction")
		newRemote.Name = "ShopAction"
		newRemote.Parent = remotes
		remote = newRemote
	end
	(remote :: RemoteFunction).OnServerInvoke = onAction

	restock()
	task.spawn(function()
		while true do
			local at = nextRestockTime(workspace:GetServerTimeNow())
			stockFolder:SetAttribute("NextRestock", at)
			task.wait(math.max(0.1, at - workspace:GetServerTimeNow()))
			restock()
		end
	end)

	local function watchFolder(folder: Instance)
		for _, m in folder:GetChildren() do
			if m:IsA("Model") then
				setupShop(m)
			end
		end
		folder.ChildAdded:Connect(function(m)
			if m:IsA("Model") then
				task.defer(setupShop, m)
			end
		end)
	end
	local folders = shopFolders()
	for _, folder in folders do
		watchFolder(folder)
	end
	if #folders == 0 then
		warn("[ShopService] no shops: put a Shops folder in each plot")
	end
	-- Plots added later (more plots in the future) get their shops set up too.
	local plots = workspace:FindFirstChild("Plots")
	if plots then
		plots.ChildAdded:Connect(function(plot)
			local f = plot:WaitForChild("Shops", 10)
			if f then
				watchFolder(f)
			end
		end)
	end

	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
end

return ShopService
