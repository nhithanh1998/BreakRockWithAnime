-- InventoryService: selling heroes from the Inventory window (InventoryUI).
--
-- Remotes.InventoryAction (RemoteFunction) -> { ok, message?, earned? }:
--   ("SellHero", heroName, amount)   sells up to `amount` free copies (copies on any pad are kept,
--                                    see HeroPlacement). amount = "All" sells every free copy.
-- Price per copy: HeroConfig SellValue * ShopConfig.HeroSellMultiplier * SellBonus (weather, potions).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local WeatherConfig = require(Shared:WaitForChild("WeatherConfig"))
local PotionConfig = require(Shared:WaitForChild("PotionConfig"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))
local HeroPlacement = require(script.Parent:WaitForChild("HeroPlacement"))

type Result = { ok: boolean, message: string?, earned: number? }

local InventoryService = {}

local MIN_INTERVAL = 0.2 -- seconds between two actions from the same player
local lastAction: { [Player]: number } = {}

function InventoryService.HeroPrice(player: Player, hero: string): number
	local def = HeroConfig.Get(hero)
	if not def then
		return 0
	end
	return math.floor(def.SellValue * ShopConfig.HeroSellMultiplier * WeatherConfig.Mult("SellBonus") * PotionConfig.Mult(player, "SellBonus"))
end

local function sellHero(player: Player, hero: any, amount: any): Result
	if typeof(hero) ~= "string" or not HeroConfig.Get(hero) then
		return { ok = false, message = "Unknown hero" }
	end
	local free = HeroPlacement.Free(player, hero)
	local count = if amount == "All" then free elseif typeof(amount) == "number" then math.floor(amount) else 0
	count = math.clamp(count, 0, free)
	if count <= 0 then
		return { ok = false, message = if HeroPlacement.Owned(player, hero) > 0 then "Take it off its pad first" else "Nothing to sell" }
	end
	local value = (player:FindFirstChild("Heroes") :: Folder):FindFirstChild(hero) :: IntValue
	value.Value -= count
	if value.Value <= 0 then
		value:Destroy()
	end
	local earned = InventoryService.HeroPrice(player, hero) * count
	ChestService.AddMoney(player, earned)
	return { ok = true, earned = earned }
end

local function onAction(player: Player, action: any, a: any, b: any): Result
	local now = os.clock()
	if now - (lastAction[player] or 0) < MIN_INTERVAL then
		return { ok = false, message = "Slow down" }
	end
	lastAction[player] = now
	if action == "SellHero" then
		return sellHero(player, a, b)
	end
	return { ok = false }
end

function InventoryService.Start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:FindFirstChild("InventoryAction") :: RemoteFunction?
	if not remote then
		local r = Instance.new("RemoteFunction")
		r.Name = "InventoryAction"
		r.Parent = remotes
		remote = r
	end
	(remote :: RemoteFunction).OnServerInvoke = onAction
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		lastAction[player] = nil
	end)
end

return InventoryService
