--!strict
-- SkillTreeConfig: the skill trees shown in StarterGui.SkillTreeGui (SkillTreeUI.client) and
-- upgraded on the server (SkillTreeService).
--
-- Trees: the list on the left of the window, in order. The first one is "Core", the rest are zones.
--   Id      = unique key (saved; don't rename once live)
--   Name    = shown on the tab
--   Icon    = "rbxassetid://123" (image) or plain text / emoji (fallback when Image is empty)
--   Image   = (optional) uploaded image: "rbxassetid://123" or just "123". Wins over Icon when set.
--   Zone   = (optional) zone number; the tree's bonuses only count while the player's plot is in
--             that zone. Trees without Zone (Core) count everywhere.
--   Columns / Rows = grid size of the tree area (optional; defaults to the biggest Pos used)
--   Nodes   = the skills in this tree
--
-- Node:
--   Id          = unique inside its tree (saved; don't rename once live)
--   Name, Icon  = shown on the node and in the preview
--   Image       = (optional) uploaded image id ("rbxassetid://123" or "123"); used instead of Icon when set
--   Pos         = { column, row } in the tree grid; 1,1 is top-left. Fractions are fine (2.5 = between 2 and 3)
--   MaxLevel    = how many times it can be upgraded
--   Cost        = { 100, 500, 2500 } (price of level 1, 2, 3...) or { Base = 100, Growth = 3 }
--                 (level n costs Base * Growth^(n-1))
--   Requires    = what must be done first (ALL of them). Each entry is either
--                   "NodeId"                      -> that node must be MAXED
--                   { Node = "NodeId", Level = 2 } -> that node must be at least level 2
--                 A line is drawn from every required node to this one.
--   Stat, PerLevel = each level adds PerLevel to the player's Stat (see Stats below)
--   Effects     = { { Stat = "X", PerLevel = n }, ... } instead of Stat/PerLevel, for several bonuses
--   Info        = one plain sentence shown in the preview explaining what the skill does
--   Description = (old) replaces the bonus text; "{value}" becomes the bonus at the current / next level
--
-- Stats: every stat becomes a player attribute = Base + the sum of the levels' bonuses (Mode "Max":
-- the biggest single bonus instead, for tiers that replace each other), set by SkillTreeService for
-- the zone the player is in (zone trees only count in their Zone). Gameplay code reads
-- player:GetAttribute("HeroLuck") etc., or SkillTreeConfig.PlayerStat(player, stat, zone).

export type Requirement = string | { Node: string, Level: number? }

export type Effect = { Stat: string, PerLevel: number }

export type NodeDef = {
	Id: string,
	Name: string,
	Icon: string,
	Image: string?,
	Pos: { number },
	MaxLevel: number,
	Cost: { number } | { Base: number, Growth: number },
	Requires: { Requirement }?,
	Stat: string?,
	PerLevel: number?,
	Effects: { Effect }?,
	Info: string?,
	Description: string?,
}

export type TreeDef = {
	Id: string,
	Name: string,
	Icon: string,
	Image: string?,
	Zone: number?,
	Columns: number?,
	Rows: number?,
	Nodes: { NodeDef },
}

export type StatDef = {
	Base: number,
	Format: string, -- string.format pattern ("%s" = the bonus) for the preview
	Mode: ("Add" | "Max")?, -- how levels / nodes combine (default "Add")
}

local TreeConfig = require(script.Parent:WaitForChild("TreeConfig"))
local ZoneDrops = require(script.Parent:WaitForChild("ZoneDrops"))
local ZoneConfig = require(script.Parent:WaitForChild("ZoneConfig"))
local WeatherConfig = require(script.Parent:WaitForChild("WeatherConfig"))
local PotionConfig = require(script.Parent:WaitForChild("PotionConfig"))

local SkillTreeConfig = {}

SkillTreeConfig.Stats = {
	AxeDamage = { Base = 1, Format = "+%s%% axe damage" },
	SwingSpeed = { Base = 1, Format = "+%s%% swing speed" },
	HeroLuck = { Base = 1, Format = "+%s%% hero luck" },
	SellBonus = { Base = 1, Format = "+%s%% sell price" },
	ChestSize = { Base = 0, Format = "+%s chest slots" },
	DropBonus = { Base = 1, Format = "+%s%% material drops" },
	TreeGrowth = { Base = 0, Format = "+%s%% big tree growth" }, -- read by TreeService (TreeConfig.TreeLevels)
	-- Multiply every mutation / size Chance of dropped heroes (HeroConfig.Mutations / Sizes),
	-- read by TreeHitService.
	MutationLuck = { Base = 1, Format = "+%s%% mutation chance" },
	SizeLuck = { Base = 1, Format = "+%s%% big size chance" },

	-- Zone stats: their starting value is the zone's ZoneConfig Base (Base here is only a fallback).
	-- TreeService: trees standing on the plot.
	MaxTrees = { Base = 12, Format = "+%s trees" },
	-- TreeHitService: added to the amount of every guaranteed (100%) material drop of a felled tree.
	ChopYield = { Base = 0, Format = "+%s wood per tree" },
	-- TreeService: chance that a new tree grows one level older (Sapling -> Tree -> Old tree).
	OldTreeChance = { Base = 0, Format = "+%s%% older tree chance" },
	-- TreeHitService: multiplies the chance of non-guaranteed material drops and of the hero drop.
	Luck = { Base = 1, Format = "+%s%% luck" },
	-- TreeHitService: chance a felled tree drops an anime (0.05 = +5 percentage points).
	HeroChance = { Base = 0.2, Format = "+%s%% anime chance" },
	-- Sell price multiplier of the materials that grow in that zone (ChestService / ShopService).
	DropValue = { Base = 1, Format = "x%s drop value", Mode = "Max" },
	-- TreeService: MaxHP multiplier of new trees (then reduced by HPCut).
	TreeHP = { Base = 1, Format = "x%s tree HP", Mode = "Max" },
	HPCut = { Base = 0, Format = "-%s%% tree HP" },
} :: { [string]: StatDef }

-- Percent stats store 0.1 for 10%; the preview multiplies by 100 for these.
SkillTreeConfig.PercentStats = {
	AxeDamage = true,
	SwingSpeed = true,
	HeroLuck = true,
	SellBonus = true,
	DropBonus = true,
	TreeGrowth = true,
	MutationLuck = true,
	SizeLuck = true,
	OldTreeChance = true,
	Luck = true,
	HeroChance = true,
	HPCut = true,
} :: { [string]: boolean }

SkillTreeConfig.Trees = {
	{
		Id = "Core",
		Name = "Core",
		Icon = "⚙️",
		Columns = 4,
		Rows = 4,
		Nodes = {
			{ Id = "Woodcutter", Name = "Woodcutter", Icon = "🪓", Pos = { 2.5, 1 }, MaxLevel = 3,
				Cost = { Base = 100, Growth = 3 }, Stat = "AxeDamage", PerLevel = 0.1 },

			{ Id = "LuckyLeaves", Name = "Lucky Leaves", Icon = "🍀", Pos = { 1, 2 }, MaxLevel = 3,
				Cost = { Base = 400, Growth = 3 }, Requires = { "Woodcutter" }, Stat = "HeroLuck", PerLevel = 0.05 },
			{ Id = "QuickSwing", Name = "Quick Swing", Icon = "💨", Pos = { 2, 2 }, MaxLevel = 3,
				Cost = { Base = 400, Growth = 3 }, Requires = { "Woodcutter" }, Stat = "SwingSpeed", PerLevel = 0.05 },
			{ Id = "MarketSavvy", Name = "Market Savvy", Icon = "💰", Pos = { 3, 2 }, MaxLevel = 3,
				Cost = { Base = 400, Growth = 3 }, Requires = { { Node = "Woodcutter", Level = 1 } }, Stat = "SellBonus", PerLevel = 0.1 },
			{ Id = "DeepPockets", Name = "Deep Pockets", Icon = "🎒", Pos = { 4, 2 }, MaxLevel = 2,
				Cost = { 600, 3000 }, Requires = { "Woodcutter" }, Stat = "ChestSize", PerLevel = 5 },

			{ Id = "FourLeaf", Name = "Four Leaf", Icon = "☘️", Pos = { 1, 3 }, MaxLevel = 3,
				Cost = { Base = 2000, Growth = 3 }, Requires = { "LuckyLeaves" }, Stat = "HeroLuck", PerLevel = 0.1 },
			-- Two requirements: both Quick Swing and Market Savvy must be maxed.
			{ Id = "DoubleChop", Name = "Double Chop", Icon = "⚔️", Pos = { 2.5, 3 }, MaxLevel = 2,
				Cost = { 5000, 25000 }, Requires = { "QuickSwing", "MarketSavvy" }, Stat = "AxeDamage", PerLevel = 0.25 },
			{ Id = "BigChest", Name = "Big Chest", Icon = "🧰", Pos = { 4, 3 }, MaxLevel = 2,
				Cost = { 5000, 20000 }, Requires = { "DeepPockets" }, Stat = "ChestSize", PerLevel = 10 },

			{ Id = "HeroMagnet", Name = "Hero Magnet", Icon = "🧲", Pos = { 1, 4 }, MaxLevel = 1,
				Cost = { 50000 }, Requires = { "FourLeaf" }, Stat = "HeroLuck", PerLevel = 0.25 },
			{ Id = "GoldenEdge", Name = "Golden Edge", Icon = "🌟", Pos = { 2.5, 4 }, MaxLevel = 1,
				Cost = { 100000 }, Requires = { "DoubleChop", { Node = "FourLeaf", Level = 2 } }, Stat = "AxeDamage", PerLevel = 0.5 },
		},
	},
	{
		Id = "Zone1",
		Name = "Green Wood",
		Icon = "🌲",
		Image = "", -- paste an image id here, e.g. "rbxassetid://123456" (empty = use Icon)
		Zone = 1, -- these bonuses only work while the plot is in zone 1
		-- Layout (5 x 4), every branch hangs off Seedling:
		--                      Seedling
		--   Lucky Acorn  Hardwood  Extra Bark            Termites
		--   Golden Acorn Ironwood  Lumber Haul  Thick Forest  Woodpecker
		--   Hero Sprout            Elder Grove               Rotten Core
		Columns = 5,
		Rows = 4,
		Nodes = {
			-- Root
			{ Id = "Seedling", Name = "Seedling", Icon = "🌱", Image = "", Pos = { 3, 1 }, MaxLevel = 3,
				Cost = { Base = 300, Growth = 2.5 }, Stat = "MaxTrees", PerLevel = 1,
				Info = "Plant one more tree on your plot per level." },

			-- Luck branch (column 1): rare drops and animes.
			{ Id = "LuckyAcorn", Name = "Lucky Acorn", Icon = "🌰", Image = "", Pos = { 1, 2 }, MaxLevel = 3,
				Cost = { Base = 400, Growth = 2.5 }, Requires = { { Node = "Seedling", Level = 1 } },
				Stat = "Luck", PerLevel = 0.15,
				Info = "Rare materials and animes drop more often." },
			{ Id = "GoldenAcorn", Name = "Golden Acorn", Icon = "✨", Image = "", Pos = { 1, 3 }, MaxLevel = 3,
				Cost = { Base = 3000, Growth = 2.5 }, Requires = { "LuckyAcorn" }, Stat = "Luck", PerLevel = 0.15,
				Info = "Stacks with Lucky Acorn for even better rare drops and animes." },
			{ Id = "HeroSprout", Name = "Hero Sprout", Icon = "🌟", Image = "", Pos = { 1, 4 }, MaxLevel = 3,
				Cost = { Base = 2000, Growth = 2.5 }, Requires = { "LuckyAcorn" }, Stat = "HeroChance", PerLevel = 0.05,
				Info = "Felled trees have a higher chance to drop an anime (base 20%)." },

			-- Wood quality branch (column 2): worth much more, but trees get tougher. Ironwood replaces Hardwood.
			{ Id = "Hardwood", Name = "Hardwood", Icon = "🔨", Image = "", Pos = { 2, 2 }, MaxLevel = 1,
				Cost = { 15000 }, Requires = { { Node = "Seedling", Level = 1 } },
				Effects = {
					{ Stat = "DropValue", PerLevel = 2.34 },
					{ Stat = "Luck", PerLevel = 0.1 },
					{ Stat = "TreeHP", PerLevel = 1.5 },
				},
				Info = "Green Wood materials sell for much more, but trees are tougher to chop." },
			{ Id = "Ironwood", Name = "Ironwood", Icon = "⛓️", Image = "", Pos = { 2, 3 }, MaxLevel = 1,
				Cost = { 120000 }, Requires = { "Hardwood" },
				Effects = {
					{ Stat = "DropValue", PerLevel = 6.38 },
					{ Stat = "Luck", PerLevel = 0.1 },
					{ Stat = "TreeHP", PerLevel = 4.25 },
				},
				Info = "Upgrades Hardwood: huge sell value, but trees are much tougher." },

			-- Forest branch (columns 3-4): more wood, more trees, older trees.
			{ Id = "ExtraBark", Name = "Extra Bark", Icon = "🍂", Image = "", Pos = { 3, 2 }, MaxLevel = 3,
				Cost = { Base = 500, Growth = 2.5 }, Requires = { "Seedling" }, Stat = "ChopYield", PerLevel = 1,
				Info = "Every felled tree drops 1 more of its main wood per level." },
			{ Id = "LumberHaul", Name = "Lumber Haul", Icon = "🪓", Image = "", Pos = { 3, 3 }, MaxLevel = 3,
				Cost = { Base = 2500, Growth = 2.5 }, Requires = { "ExtraBark" }, Stat = "ChopYield", PerLevel = 1,
				Info = "Even more wood: +1 main wood per felled tree per level." },
			{ Id = "ThickForest", Name = "Thick Forest", Icon = "🌳", Image = "", Pos = { 4, 3 }, MaxLevel = 4,
				Cost = { Base = 2000, Growth = 2.2 }, Requires = { "ExtraBark" }, Stat = "MaxTrees", PerLevel = 1,
				Info = "Your plot grows one more tree per level." },
			{ Id = "ElderGrove", Name = "Elder Grove", Icon = "🌲", Image = "", Pos = { 3, 4 }, MaxLevel = 3,
				Cost = { Base = 8000, Growth = 2.5 }, Requires = { "LumberHaul", "ThickForest" },
				Stat = "OldTreeChance", PerLevel = 0.2,
				Info = "New trees may grow one age older (Sapling > Tree > Old Tree) for bigger drops." },

			-- Weaken branch (column 5): trees have less HP, so they fall faster.
			{ Id = "Termites", Name = "Termites", Icon = "🐜", Image = "", Pos = { 5, 2 }, MaxLevel = 3,
				Cost = { Base = 350, Growth = 2.5 }, Requires = { { Node = "Seedling", Level = 1 } },
				Stat = "HPCut", PerLevel = 0.05,
				Info = "Termites weaken new trees so they fall faster." },
			{ Id = "Woodpecker", Name = "Woodpecker", Icon = "🐦", Image = "", Pos = { 5, 3 }, MaxLevel = 3,
				Cost = { Base = 2500, Growth = 2.5 }, Requires = { "Termites" }, Stat = "HPCut", PerLevel = 0.05,
				Info = "Woodpeckers hollow out trees: even less HP." },
			{ Id = "RottenCore", Name = "Rotten Core", Icon = "🍄", Image = "", Pos = { 5, 4 }, MaxLevel = 2,
				Cost = { 12000, 30000 }, Requires = { "Woodpecker" }, Stat = "HPCut", PerLevel = 0.05,
				Info = "Trees rot from the inside and break with fewer hits." },
		},
	},
	{
		Id = "Zone2",
		Name = "Fruit Grove",
		Icon = "🍎",
		Zone = 2,
		Columns = 3,
		Rows = 3,
		Nodes = {
			{ Id = "Harvest", Name = "Harvest", Icon = "🧺", Pos = { 2, 1 }, MaxLevel = 3,
				Cost = { Base = 5000, Growth = 3 }, Stat = "SellBonus", PerLevel = 0.1 },
			{ Id = "Juicy", Name = "Juicy", Icon = "🍊", Pos = { 1, 2 }, MaxLevel = 3,
				Cost = { Base = 15000, Growth = 3 }, Requires = { "Harvest" }, Stat = "DropBonus", PerLevel = 0.1 },
			{ Id = "Orchard", Name = "Orchard Keeper", Icon = "🍐", Pos = { 3, 2 }, MaxLevel = 1,
				Cost = { 40000 }, Requires = { { Node = "Harvest", Level = 2 } }, Stat = "ChestSize", PerLevel = 10 },
			{ Id = "GoldenFruit", Name = "Golden Fruit", Icon = "🍏", Pos = { 2, 3 }, MaxLevel = 1,
				Cost = { 250000 }, Requires = { "Juicy", "Orchard" }, Stat = "HeroLuck", PerLevel = 0.3 },
			{ Id = "AncientRoots", Name = "Ancient Roots", Icon = "🌲", Pos = { 3, 3 }, MaxLevel = 2,
				Cost = { 30000, 120000 }, Requires = { { Node = "Harvest", Level = 1 } }, Stat = "TreeGrowth", PerLevel = 0.5 },
			-- Mutation / size luck of this map.
			{ Id = "GemHunter", Name = "Gem Hunter", Icon = "💎", Pos = { 1, 3 }, MaxLevel = 5,
				Cost = { Base = 20000, Growth = 2.5 }, Requires = { { Node = "Juicy", Level = 1 } }, Stat = "MutationLuck", PerLevel = 0.1 },
			{ Id = "GiantBlood", Name = "Giant Blood", Icon = "🗿", Pos = { 3, 1 }, MaxLevel = 5,
				Cost = { Base = 20000, Growth = 2.5 }, Requires = { { Node = "Harvest", Level = 1 } }, Stat = "SizeLuck", PerLevel = 0.1 },
		},
	},
} :: { TreeDef }

-- Lookups --------------------------------------------------------------------------------------------

local treeById: { [string]: TreeDef } = {}
local nodeById: { [string]: { [string]: NodeDef } } = {}
for _, tree in SkillTreeConfig.Trees do
	treeById[tree.Id] = tree
	local nodes = {}
	for _, node in tree.Nodes do
		nodes[node.Id] = node
	end
	nodeById[tree.Id] = nodes
end

function SkillTreeConfig.GetTree(treeId: string): TreeDef?
	return treeById[treeId]
end

function SkillTreeConfig.GetNode(treeId: string, nodeId: string): NodeDef?
	local nodes = nodeById[treeId]
	return nodes and nodes[nodeId]
end

-- Name of the IntValue in player.Skills that holds a node's level.
function SkillTreeConfig.Key(treeId: string, nodeId: string): string
	return treeId .. "/" .. nodeId
end

function SkillTreeConfig.SplitKey(key: string): (string?, string?)
	local treeId, nodeId = string.match(key, "^(.-)/(.+)$")
	return treeId, nodeId
end

-- Price of going from `level` to `level + 1` (nil when already maxed).
function SkillTreeConfig.Cost(node: NodeDef, level: number): number?
	if level >= node.MaxLevel then
		return nil
	end
	local cost = node.Cost :: any
	if cost.Base then
		return math.floor(cost.Base * (cost.Growth or 1) ^ level)
	end
	return cost[level + 1] or cost[#cost]
end

export type ResolvedRequirement = { Node: NodeDef, Level: number }

-- Requirements as { Node, Level } pairs (unknown node ids are skipped with a warning).
function SkillTreeConfig.Requirements(treeId: string, node: NodeDef): { ResolvedRequirement }
	local out = {}
	for _, req in node.Requires or {} do
		local id = if typeof(req) == "string" then req else (req :: any).Node
		local other = SkillTreeConfig.GetNode(treeId, id)
		if not other then
			warn(("[SkillTreeConfig] %s.%s requires unknown node %s"):format(treeId, node.Id, tostring(id)))
			continue
		end
		local level = if typeof(req) == "string" then other.MaxLevel else ((req :: any).Level or other.MaxLevel)
		table.insert(out, { Node = other, Level = math.min(level, other.MaxLevel) })
	end
	return out
end

-- getLevel(treeId, nodeId) -> number
function SkillTreeConfig.RequirementsMet(treeId: string, node: NodeDef, getLevel: (string, string) -> number): boolean
	for _, req in SkillTreeConfig.Requirements(treeId, node) do
		if getLevel(treeId, req.Node.Id) < req.Level then
			return false
		end
	end
	return true
end

-- What to draw for a tree / node: its Image (an uploaded asset; a bare number becomes
-- "rbxassetid://<number>") when set, otherwise its Icon (asset id or emoji / text).
function SkillTreeConfig.IconOf(def: { Icon: string, Image: string? }): string
	local image = def.Image
	if image and image ~= "" then
		return if string.match(image, "^%d+$") then "rbxassetid://" .. image else image
	end
	return def.Icon
end

-- The node's bonuses as { Stat, PerLevel } (Effects, or the single Stat / PerLevel).
function SkillTreeConfig.NodeEffects(node: NodeDef): { Effect }
	if node.Effects then
		return node.Effects
	end
	if node.Stat then
		return { { Stat = node.Stat, PerLevel = node.PerLevel or 0 } }
	end
	return {}
end

-- 2.34 -> "2.34", 1.5 -> "1.5", 3 -> "3"
local function shortNumber(n: number): string
	local text = string.format("%.2f", n)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return text
end

-- Preview text for a node's bonus at `level` (e.g. "+20% hero luck").
function SkillTreeConfig.EffectText(node: NodeDef, level: number): string
	if node.Description then
		return (string.gsub(node.Description, "{value}", tostring((node.PerLevel or 0) * level)))
	end
	local parts = {}
	for _, effect in SkillTreeConfig.NodeEffects(node) do
		local total = effect.PerLevel * level
		local def = SkillTreeConfig.Stats[effect.Stat]
		local shown = if SkillTreeConfig.PercentStats[effect.Stat] then math.floor(total * 100 + 0.5) else total
		table.insert(parts, string.format(if def then def.Format else ("+%s " .. effect.Stat), shortNumber(shown)))
	end
	return table.concat(parts, ", ")
end

-- Whether a tree's bonuses count in `zone` (trees without Zone count everywhere).
function SkillTreeConfig.TreeActiveIn(tree: TreeDef, zone: number?): boolean
	return tree.Zone == nil or tree.Zone == (zone or 1)
end

-- A stat's value in `zone`. getLevel(treeId, nodeId) -> number.
function SkillTreeConfig.StatIn(stat: string, zone: number?, getLevel: (string, string) -> number): number
	local def = SkillTreeConfig.Stats[stat]
	local useMax = def ~= nil and def.Mode == "Max"
	-- Start from the zone's base (ZoneConfig Base) when it defines this stat.
	local zoneBase = ZoneConfig.GetBase(zone, stat)
	local total = if typeof(zoneBase) == "number" then zoneBase elseif def then def.Base else 0
	for _, tree in SkillTreeConfig.Trees do
		if not SkillTreeConfig.TreeActiveIn(tree, zone) then
			continue
		end
		for _, node in tree.Nodes do
			for _, effect in SkillTreeConfig.NodeEffects(node) do
				if effect.Stat == stat then
					local level = getLevel(tree.Id, node.Id)
					if level > 0 then
						local value = effect.PerLevel * level
						total = if useMax then math.max(total, value) else total + value
					end
				end
			end
		end
	end
	return total
end

-- The zone the player's plot is in (player "CurrentZone", default 1).
function SkillTreeConfig.CurrentZone(player: Player): number
	local zone = player:GetAttribute("CurrentZone")
	return if typeof(zone) == "number" then math.floor(zone) else 1
end

-- A player's stat in `zone` (default: their current zone), read from player.Skills.
-- Works on the server and the client (player.Skills replicates).
function SkillTreeConfig.PlayerStat(player: Player, stat: string, zone: number?): number
	local skills = player:FindFirstChild("Skills")
	return SkillTreeConfig.StatIn(stat, zone or SkillTreeConfig.CurrentZone(player), function(treeId: string, nodeId: string): number
		local value = skills and skills:FindFirstChild(SkillTreeConfig.Key(treeId, nodeId))
		return if value and value:IsA("IntValue") then value.Value else 0
	end)
end

-- Sell price of one `kind` material for this player: its Value times the DropValue bonus of the
-- zone it grows in (Green Wood's Hardwood / Ironwood boost Green Wood materials, wherever sold).
function SkillTreeConfig.MaterialValue(player: Player, kind: string): number
	local def = TreeConfig.Materials[kind]
	if not def then
		return 0
	end
	local zone = ZoneDrops.MaterialZone(kind)
	local mult = if zone then SkillTreeConfig.PlayerStat(player, "DropValue", zone) else 1
	mult *= WeatherConfig.Mult("SellBonus") -- weather (Golden Hour ...)
	mult *= PotionConfig.Mult(player, "SellBonus") -- Money Potion
	return math.floor(def.Value * mult + 0.5)
end

return SkillTreeConfig
