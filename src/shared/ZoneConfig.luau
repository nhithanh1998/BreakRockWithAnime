--!strict
-- ZoneConfig: the zones a player can unlock and travel to from the Zones board on their plot
-- (plot.ZoneBoard.Board, drawn by ZoneBoardUI, handled by ZoneBoardService).
--
-- Zones are unlocked in order: only the next one (UnlockedZones + 1) can be bought, for its Price.
-- Unlocked zones can be swapped to for free at any time.
-- What grows / drops in each zone is in ZoneDrops.luau; the map layout is ServerStorage.ZoneLayouts.ZoneN.

export type ZoneInfo = {
	Name: string,
	Price: number, -- Money to unlock (zone 1 is always unlocked)
	Color: Color3, -- row accent colour on the board
}

local ZoneConfig = {}

ZoneConfig.Zones = {
	[1] = { Name = "Green Wood", Price = 0, Color = Color3.fromRGB(80, 190, 70) },
	[2] = { Name = "Orchard Valley", Price = 25000, -- ~15-20 min of zone 1 with a few upgraded heroes Color = Color3.fromRGB(235, 120, 40) },
} :: { [number]: ZoneInfo }

-- Shown as a greyed-out row under the last zone; set to nil to hide it.
ZoneConfig.ComingSoonText = "More Zones Soon!"

function ZoneConfig.Count(): number
	return #ZoneConfig.Zones
end

function ZoneConfig.Get(zone: number): ZoneInfo?
	return ZoneConfig.Zones[zone]
end

return ZoneConfig
