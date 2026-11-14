--!strict
-- Rewards: hands out one reward of the shared reward format (DailyRewardConfig.Reward), used by the
-- 7 Day Login Rewards (DailyRewardService) and the Index zone rewards (IndexService).
--
--   { Kind = "Money", Amount = n }
--   { Kind = "Hero", Name = "<HeroConfig hero name>", Amount = n? }
--   { Kind = "Fertilizer", Amount = n }
--   { Kind = "Fruit", Id = "<FruitConfig Id>", Amount = n? }
--   { Kind = "Material", Key = "<TreeConfig.Materials key>", Amount = n }
--   { Kind = "Potion", Id = "<PotionConfig Id>", Amount = n? }
--
-- Heroes / materials are added to `popups` ({ Stack, Amount, New }) for the hotbar "Added!" popups
-- (Remotes.ItemsAdded); the caller fires them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DailyRewardConfig = require(Shared:WaitForChild("DailyRewardConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local FruitConfig = require(Shared:WaitForChild("FruitConfig"))
local TreeConfig = require(Shared:WaitForChild("TreeConfig"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))
local FruitService = require(script.Parent:WaitForChild("FruitService"))
local PotionService = require(script.Parent:WaitForChild("PotionService"))

local HERO_PREFIX = "Anime:"

type Reward = DailyRewardConfig.Reward

local Rewards = {}

function Rewards.Give(player: Player, reward: Reward, popups: { any })
	local amount = math.max(1, math.floor(reward.Amount or 1))
	if reward.Kind == "Money" then
		ChestService.AddMoney(player, amount)
	elseif reward.Kind == "Hero" and reward.Name then
		local name = HeroConfig.CurrentName(reward.Name)
		if TreeConfig.GetHero(name) then
			local isNew = ChestService.AddItem(player, "Heroes", name, amount)
			table.insert(popups, { Stack = HERO_PREFIX .. name, Amount = amount, New = isNew })
		else
			warn("[Rewards] unknown hero " .. tostring(reward.Name))
		end
	elseif reward.Kind == "Fertilizer" then
		FruitService.AddFertilizer(player, amount)
	elseif reward.Kind == "Fruit" and reward.Id then
		if FruitConfig.Get(reward.Id) then
			FruitService.AddFruit(player, reward.Id, amount)
		else
			warn("[Rewards] unknown fruit " .. tostring(reward.Id))
		end
	elseif reward.Kind == "Material" and reward.Key then
		local isNew = ChestService.AddItem(player, "Inventory", reward.Key, amount)
		table.insert(popups, { Stack = reward.Key, Amount = amount, New = isNew })
	elseif reward.Kind == "Potion" and reward.Id then
		PotionService.Add(player, reward.Id, amount)
	end
end

return Rewards
