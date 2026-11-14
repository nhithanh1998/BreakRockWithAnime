--!strict
-- StandLayoutConfig: where everything of a Farm Stand stands, per stand and per level.
--
-- Nothing in the code holds a Vector3 for a stand: every position comes from a MARKER (a Part or an
-- Attachment) named by the conventions below. Markers live in a folder named "Markers":
--   * in each level model: ServerStorage.StandModels.<StandId>.Level<N>.Markers   (move with the level)
--   * in the plot's site:  plot.StandSites.<StandId>.Markers                       (same for every level:
--     the chest pickup, the helper route to the stand, where customers walk in / out on the road)
-- The level model's PrimaryPart ("Base") is pivoted onto the site's "Anchor" part, so level markers are
-- relative to it. Markers are invisible while playing; StandLayoutDebug shows them in Studio.
--
-- Marker names ("_N" = 1..count, numbered from the counter outwards):
--   KeeperSlot_N        Stand Keeper pad: a hero serving at the counter, facing the customers
--   HelperDropPoint     helpers put the materials into the stand here (behind the counter)
--   ServePoint_N        a customer stands here to buy (one lane each)
--   QueuePoint_N        waiting line, 1 = next in line (nearest the counter) ... K = the far end
--   VipServePoint / VipQueuePoint_N   the VIP lane (levels that have one)
--   RestockMat          players stand here to put their carried materials into the stand
--   UpgradePad_<Id>     one pad per stand upgrade (StandUpgradeConfig ids)
--   AccessorySlot_N     where a Fame accessory shows (its model depends on the accessory level)
--   BillboardAnchor     the stand's billboard
--   StockVisual_N       goods on the shelf, shown in order as the stock fills up
--   CoinFxPoint         where the "+$" pops when a customer pays
-- Site markers:
--   HelperSlot_1..3     Helper pads: next to the plot's chest, where helper heroes rest between trips
--   HelperPickupPoint   helpers take materials from the chest here
--   HelperPath_N        waypoints chest -> stand (walked backwards on the way back)
--   CustomerSpawn_N, CustomerPath_N, CustomerExit_N   customers come in from the road and leave again

local StandLayoutConfig = {}

-- Folder names.
StandLayoutConfig.ModelsFolder = "StandModels" -- in ServerStorage
StandLayoutConfig.SitesFolder = "StandSites" -- in each plot
StandLayoutConfig.MarkersFolder = "Markers"
StandLayoutConfig.AnchorName = "Anchor" -- part in the site the level model is pivoted onto
StandLayoutConfig.PlacedName = "Stand" -- the placed level model inside the site

StandLayoutConfig.HelperSlots = 3 -- helper pads per stand (site markers next to the chest), same at every level
-- Keeper / helper pads are copies of this model (a worker hero pad: Base + Pad with Empty / HeroInfo
-- billboards), in ServerStorage.StandModels. Keeper pads are scaled down to fit behind the counter.
StandLayoutConfig.PadTemplate = "HeroPadTemplate"
StandLayoutConfig.KeeperPadScale = 0.8
StandLayoutConfig.MinPadSpacing = 6 -- studs between the centres of any two pads (keeper / helper / upgrade / restock)
StandLayoutConfig.MinServeSpacing = 4 -- studs between two ServePoints (customers must not overlap)
StandLayoutConfig.MinQueueSpacing = 2.5 -- studs between two QueuePoints

-- Debug colours per marker kind (StandLayoutDebug).
StandLayoutConfig.DebugColors = {
	KeeperSlot = Color3.fromRGB(255, 210, 40),
	HelperSlot = Color3.fromRGB(80, 200, 255),
	HelperDropPoint = Color3.fromRGB(40, 120, 255),
	HelperPickupPoint = Color3.fromRGB(40, 120, 255),
	HelperPath = Color3.fromRGB(120, 170, 255),
	ServePoint = Color3.fromRGB(60, 220, 90),
	QueuePoint = Color3.fromRGB(170, 240, 120),
	VipServePoint = Color3.fromRGB(230, 90, 255),
	VipQueuePoint = Color3.fromRGB(240, 170, 255),
	CustomerSpawn = Color3.fromRGB(255, 255, 255),
	CustomerPath = Color3.fromRGB(200, 200, 200),
	CustomerExit = Color3.fromRGB(120, 120, 120),
	RestockMat = Color3.fromRGB(255, 140, 30),
	UpgradePad = Color3.fromRGB(255, 70, 70),
	AccessorySlot = Color3.fromRGB(255, 120, 200),
	BillboardAnchor = Color3.fromRGB(255, 255, 140),
	StockVisual = Color3.fromRGB(160, 110, 60),
	CoinFxPoint = Color3.fromRGB(255, 230, 0),
} :: { [string]: Color3 }

export type LevelLayout = {
	Model: string, -- name of the level model in StandModels.<StandId>
	KeeperSlots: number,
	ServePoints: number,
	QueuePoints: number,
	VipQueuePoints: number?, -- with a VIP lane (VipServePoint + this many VipQueuePoint_N)
	AccessorySlots: number,
	StockVisuals: number,
	UpgradePads: { string }, -- StandUpgradeConfig ids that have a pad at this level
	BillboardStyle: string, -- "Small" | "Medium" | "Large" | "Deluxe" | "Grand" (StandClient)
	StarKeeperSlot: number?, -- this keeper slot is the star slot (bigger hero bonus)
	Footprint: Vector3, -- size the level may take (checked against the site's "Footprint" part)
}

export type StandLayout = {
	Levels: { LevelLayout },
	SiteMarkers: { [string]: number }, -- site marker prefix -> how many (at least)
}

local BASE_PADS: { string } = {} -- the stand's upgrades are billboard buttons now (StandUpgradeConfig Board)

StandLayoutConfig.Stands = {
	FarmStand = {
		SiteMarkers = { HelperSlot = 3, HelperPickupPoint = 1, HelperPath = 2, CustomerSpawn = 2, CustomerPath = 2, CustomerExit = 2 },
		Levels = {
			{ -- 1: one stall like the Sell shop
				Model = "Level1",
				KeeperSlots = 1,
				ServePoints = 1,
				QueuePoints = 3,
				AccessorySlots = 2,
				StockVisuals = 4,
				UpgradePads = BASE_PADS,
				BillboardStyle = "Small",
				Footprint = Vector3.new(22, 24, 22),
			},
			{ -- 2: a bigger stall, green awning
				Model = "Level2",
				KeeperSlots = 1,
				ServePoints = 2,
				QueuePoints = 5,
				AccessorySlots = 4,
				StockVisuals = 6,
				UpgradePads = { "MaterialPrice", "BiggerShelf", "CarryCapacity", "FarmSide", "HelperTraining" },
				BillboardStyle = "Medium",
				Footprint = Vector3.new(29, 31, 28),
			},
			{ -- 3: two red/white stalls side by side
				Model = "Level3",
				KeeperSlots = 2,
				ServePoints = 3,
				QueuePoints = 8,
				AccessorySlots = 6,
				StockVisuals = 8,
				UpgradePads = { "MaterialPrice", "BiggerShelf", "CarryCapacity", "FarmSide", "HelperTraining", "FarmSign" },
				BillboardStyle = "Large",
				Footprint = Vector3.new(39, 24, 22),
			},
			{ -- 4: three stalls (VIP, blue, yellow)
				Model = "Level4",
				KeeperSlots = 2,
				ServePoints = 4,
				QueuePoints = 12,
				VipQueuePoints = 3,
				AccessorySlots = 8,
				StockVisuals = 10,
				UpgradePads = { "MaterialPrice", "BiggerShelf", "CarryCapacity", "FarmSide", "HelperTraining", "FarmSign" },
				BillboardStyle = "Deluxe",
				Footprint = Vector3.new(55, 24, 22),
			},
			{ -- 5: grand market: big gold centre stall, VIP stall, red stall
				Model = "Level5",
				KeeperSlots = 2,
				ServePoints = 6,
				QueuePoints = 16,
				VipQueuePoints = 4,
				AccessorySlots = 10,
				StockVisuals = 12,
				UpgradePads = { "MaterialPrice", "BiggerShelf", "CarryCapacity", "FarmSide", "HelperTraining", "FarmSign" },
				BillboardStyle = "Grand",
				StarKeeperSlot = 1, -- KeeperSlot_1 is the star podium: bigger bonus (StandConfig.StarSlotBonus)
				Footprint = Vector3.new(61, 32, 25),
			},
		},
	},
} :: { [string]: StandLayout }

-- The marker names a level model must have (exact names), in a stable order.
function StandLayoutConfig.RequiredLevelMarkers(layout: LevelLayout): { string }
	local list = { "HelperDropPoint", "RestockMat", "BillboardAnchor", "CoinFxPoint" }
	local function numbered(prefix: string, n: number)
		for i = 1, n do
			table.insert(list, ("%s_%d"):format(prefix, i))
		end
	end
	numbered("KeeperSlot", layout.KeeperSlots)
	numbered("ServePoint", layout.ServePoints)
	numbered("QueuePoint", layout.QueuePoints)
	numbered("AccessorySlot", layout.AccessorySlots)
	numbered("StockVisual", layout.StockVisuals)
	if layout.VipQueuePoints then
		table.insert(list, "VipServePoint")
		numbered("VipQueuePoint", layout.VipQueuePoints)
	end
	for _, id in layout.UpgradePads do
		table.insert(list, "UpgradePad_" .. id)
	end
	return list
end

-- The marker kind (DebugColors key) of a marker name: "QueuePoint_3" -> "QueuePoint".
function StandLayoutConfig.KindOf(name: string): string
	return (name:match("^(.-)_[%w]+$") or name)
end

return StandLayoutConfig
