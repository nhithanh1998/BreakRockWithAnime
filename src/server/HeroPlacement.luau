-- HeroPlacement: how many copies of a hero a player has standing on pads, across every kind of pad.
--
-- A player owns N copies of a hero (player.Heroes.<Name>.Value). Every copy can stand on exactly one
-- pad at a time, whatever the kind:
--   Worker pads      (chop trees, HeroSlotService)
--   Stand Keeper pads (serve at a Farm Stand, StandService)
--   Helper pads      (carry materials from the chest to the stand, StandService)
-- So placing a hero anywhere, or selling copies, must check CountPlaced against the copies owned.
--
-- Each pad system registers a counter: HeroPlacement.Register("Worker", fn(player) -> { [hero] = n }).
-- Systems never require each other, they only go through here.

local HeroPlacement = {}

type Counter = (Player) -> { [string]: number }

local counters: { [string]: Counter } = {}

function HeroPlacement.Register(kind: string, counter: Counter)
	counters[kind] = counter
end

-- hero name -> copies on any pad.
function HeroPlacement.AllPlaced(player: Player): { [string]: number }
	local total: { [string]: number } = {}
	for _, counter in counters do
		local ok, counts = pcall(counter, player)
		if ok and typeof(counts) == "table" then
			for hero, n in counts do
				total[hero] = (total[hero] or 0) + n
			end
		end
	end
	return total
end

function HeroPlacement.CountPlaced(player: Player, hero: string): number
	return HeroPlacement.AllPlaced(player)[hero] or 0
end

function HeroPlacement.Owned(player: Player, hero: string): number
	local heroes = player:FindFirstChild("Heroes")
	local v = heroes and heroes:FindFirstChild(hero)
	return if v and v:IsA("IntValue") then v.Value else 0
end

-- Copies not standing on any pad (free to place somewhere or to sell).
function HeroPlacement.Free(player: Player, hero: string): number
	return math.max(0, HeroPlacement.Owned(player, hero) - HeroPlacement.CountPlaced(player, hero))
end

return HeroPlacement
