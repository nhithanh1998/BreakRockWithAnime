--!strict
-- DailyRewardConfig: the 7 Day Login Rewards (DailyRewardService on the server, DailyRewardUI on the
-- client).
--
-- How it works:
--   * Each new calendar day (UTC, DayLength seconds) the player is in the game unlocks the next day of
--     the streak: Day 1 on the first visit, Day 2 on the next day they play, and so on. Missing a day
--     does NOT reset the streak (ResetIfMissed = false) - it just waits for them.
--   * Unlocked days can be claimed one by one or all at once (CLAIM ALL).
--   * Once all 7 days are claimed, the next new day starts again from Day 1 (Loop = true).
--
-- Reward kinds (Rewards = list, a day can give several):
--   { Kind = "Money", Amount = n }
--   { Kind = "Hero", Name = "<HeroConfig hero name>", Amount = n? }
--   { Kind = "Fertilizer", Amount = n }              Devil Fertilizer bags (FruitService)
--   { Kind = "Fruit", Id = "<FruitConfig Id>", Amount = n? }
--   { Kind = "Material", Key = "<TreeConfig.Materials key>", Amount = n }
--   { Kind = "Potion", Id = "<PotionConfig Id>", Amount = n? }
-- The FIRST reward of a day is the big picture on its card; the rest are small icons under it.

export type Reward = {
	Kind: "Money" | "Hero" | "Fertilizer" | "Fruit" | "Material" | "Potion",
	Amount: number?,
	Name: string?,
	Id: string?,
	Key: string?,
}

export type Day = {
	Rewards: { Reward },
	Big: boolean?, -- drawn as the wide "biggest prize" card (Day 7)
}

local DailyRewardConfig = {}

DailyRewardConfig.DayLength = 24 * 60 * 60 -- one "day" in seconds (days roll over at UTC midnight)
DailyRewardConfig.StudioDayLength = 60 -- in Studio a day lasts this long, to test the streak quickly
DailyRewardConfig.ResetIfMissed = false -- true: skipping a whole day starts the streak over at Day 1
DailyRewardConfig.Loop = true -- after Day 7 is claimed, the next day starts a new streak at Day 1
DailyRewardConfig.OpenOnJoin = true -- open the window by itself when the player has something to claim

DailyRewardConfig.Title = "7 DAY LOGIN REWARDS!"
DailyRewardConfig.Subtitle = "Log in every day to claim a new reward. Day 7 has the biggest prize!"

-- Balance these to your economy (zone 1 trees give ~15 money each).
DailyRewardConfig.Days = {
	{ Rewards = { { Kind = "Money", Amount = 500 }, { Kind = "Fertilizer", Amount = 1 } } },
	{ Rewards = { { Kind = "Hero", Name = "Copy Sensei" }, { Kind = "Money", Amount = 1000 } } },
	{ Rewards = { { Kind = "Money", Amount = 2500 } } },
	{ Rewards = { { Kind = "Fruit", Id = "Ice" }, { Kind = "Fertilizer", Amount = 3 } } },
	{ Rewards = { { Kind = "Money", Amount = 10000 } } },
	{ Rewards = { { Kind = "Hero", Name = "Whale Island Kid" }, { Kind = "Fertilizer", Amount = 3 } } },
	{
		Big = true,
		Rewards = {
			{ Kind = "Hero", Name = "Star Brawler" },
			{ Kind = "Fruit", Id = "Flame" },
			{ Kind = "Money", Amount = 25000 },
			{ Kind = "Fertilizer", Amount = 5 },
		},
	},
} :: { Day }

DailyRewardConfig.MaxDays = #DailyRewardConfig.Days

-- Claimed days are kept as a bit mask (bit d-1 = Day d claimed).
function DailyRewardConfig.IsClaimed(mask: number, day: number): boolean
	return bit32.btest(mask, bit32.lshift(1, day - 1))
end

function DailyRewardConfig.SetClaimed(mask: number, day: number): number
	return bit32.bor(mask, bit32.lshift(1, day - 1))
end

return DailyRewardConfig
