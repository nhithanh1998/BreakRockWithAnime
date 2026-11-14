-- UnlockConfig: progressive unlock of the sidebar features (client/FeatureLocks draws the locks).
--
-- A feature with `Zone = n` shows a lock and "Zone n" on its sidebar button until the player has
-- unlocked that zone (player attribute "UnlockedZones", ZoneBoardService; starts at 1).
-- Zone = nil (or 1) = open from the start.
--
-- !! TO DECIDE !! Every feature is open for now: the zone each one should unlock at is a game
-- design call that hasn't been made yet. Fill in the numbers below, e.g. Upgrades = { Zone = 2 }.
-- Only the client UI is locked; the server does not block anything yet.

local UnlockConfig = {}

export type Requirement = { Zone: number? }

-- Keys = button names in StarterGui.LeftSidebar.Buttons.
UnlockConfig.Features = {
	Shop = {}, -- the Robux shop is never locked
	Upgrades = {},
	Index = {},
	Daily = {},
} :: { [string]: Requirement }

local function unlockedZones(player: Player): number
	local n = player:GetAttribute("UnlockedZones")
	return if typeof(n) == "number" then n else 1
end

-- True while `feature` is still locked for `player`.
function UnlockConfig.IsLocked(player: Player, feature: string): boolean
	local req = UnlockConfig.Features[feature]
	return req ~= nil and req.Zone ~= nil and unlockedZones(player) < req.Zone
end

-- The text under the lock ("Zone 3").
function UnlockConfig.Text(feature: string): string
	local req = UnlockConfig.Features[feature]
	return if req and req.Zone then ("Zone %d"):format(req.Zone) else ""
end

return UnlockConfig
