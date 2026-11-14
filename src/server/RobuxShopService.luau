-- RobuxShopService: the server side of the Shop hub (client/ShopHubUI). Items: Shared.ShopCatalog.
--
--   Developer Products  potions (ShopCatalog.PotionProducts) and the Exclusive Hero Chest
--                       (ShopCatalog.HeroChest.ProductIds). Their handlers go into
--                       FruitService.ProductHandlers: the game has ONE ProcessReceipt (FruitService),
--                       which already waits for the save, saves after granting and skips repeats.
--                       Fertilizer packs stay in FruitService (FruitConfig.FertilizerProducts).
--   Game Passes         player attribute "Pass_<Id>" = true when owned (checked on join with
--                       UserOwnsGamePassAsync, set right away after a purchase in the game).
--
-- The client calls MarketplaceService:PromptProductPurchase / PromptGamePassPurchase itself; ids of
-- 0 are "not on sale yet" and are never prompted.
--
-- Remotes.RobuxShopResult (RemoteEvent, server -> client): (kind, data) after a purchase is granted
--   ("Chest", { heroes = { name, ... } })   for the chest reveal
--   ("Potion", { id = potionId, amount = n })

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShopCatalog = require(Shared:WaitForChild("ShopCatalog"))
local PotionConfig = require(Shared:WaitForChild("PotionConfig"))
local FruitService = require(script.Parent:WaitForChild("FruitService"))
local PotionService = require(script.Parent:WaitForChild("PotionService"))
local Rewards = require(script.Parent:WaitForChild("Rewards"))

local RobuxShopService = {}

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local resultRemote = Remotes:FindFirstChild("RobuxShopResult") :: RemoteEvent?
if not resultRemote then
	local r = Instance.new("RemoteEvent")
	r.Name = "RobuxShopResult"
	r.Parent = Remotes
	resultRemote = r
end

local rng = Random.new()

local function passAttribute(id: string): string
	return "Pass_" .. id
end

-- One weighted pick from the chest pool.
local function rollChest(): string
	local total = 0
	for _, e in ShopCatalog.HeroChest.Pool do
		total += e.Weight
	end
	local r = rng:NextNumber() * total
	for _, e in ShopCatalog.HeroChest.Pool do
		r -= e.Weight
		if r <= 0 then
			return e.Hero
		end
	end
	return ShopCatalog.HeroChest.Pool[#ShopCatalog.HeroChest.Pool].Hero
end

local function addHandler(productId: number, handler: (Player) -> boolean)
	if productId <= 0 then
		return -- not on sale yet
	end
	if FruitService.ProductHandlers[productId] then
		warn(("[RobuxShopService] ProductId %d is used twice"):format(productId))
		return
	end
	FruitService.ProductHandlers[productId] = handler
end

local function registerProducts()
	-- Potions
	for potionId, byAmount in ShopCatalog.PotionProducts do
		if not PotionConfig.Get(potionId) then
			warn("[RobuxShopService] unknown potion in ShopCatalog: " .. potionId)
			continue
		end
		for amount, productId in byAmount do
			addHandler(productId, function(player: Player): boolean
				if not PotionService.Add(player, potionId, amount) then
					return false
				end
				(resultRemote :: RemoteEvent):FireClient(player, "Potion", { id = potionId, amount = amount })
				return true
			end)
		end
	end
	-- Exclusive Hero Chest
	for count, productId in ShopCatalog.HeroChest.ProductIds do
		addHandler(productId, function(player: Player): boolean
			local heroes = {}
			local popups = {}
			for _ = 1, count do
				local hero = rollChest()
				table.insert(heroes, hero)
				Rewards.Give(player, { Kind = "Hero", Name = hero, Amount = 1 } :: any, popups)
			end
			local itemsAdded = Remotes:FindFirstChild("ItemsAdded") :: RemoteEvent?
			if itemsAdded and #popups > 0 then
				itemsAdded:FireClient(player, popups)
			end
			(resultRemote :: RemoteEvent):FireClient(player, "Chest", { heroes = heroes })
			return true
		end)
	end
end

local function checkPasses(player: Player)
	for _, pass in ShopCatalog.GamePasses do
		if ShopCatalog.OnSale(pass.GamePassId) then
			local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, pass.GamePassId)
			if ok and owns and player.Parent then
				player:SetAttribute(passAttribute(pass.Id), true)
			end
		end
	end
end

-- True when the player owns the game pass with ShopCatalog Id `id` (other features read this).
function RobuxShopService.OwnsPass(player: Player, id: string): boolean
	return player:GetAttribute(passAttribute(id)) == true
end

function RobuxShopService.Start()
	registerProducts()

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, purchased)
		if not purchased then
			return
		end
		for _, pass in ShopCatalog.GamePasses do
			if pass.GamePassId == gamePassId then
				player:SetAttribute(passAttribute(pass.Id), true)
			end
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		task.spawn(checkPasses, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(checkPasses, player)
	end
end

return RobuxShopService
