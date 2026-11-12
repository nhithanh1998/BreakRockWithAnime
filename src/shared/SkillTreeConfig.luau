--!strict
-- SkillTreeConfig: the skill trees shown in StarterGui.SkillTreeGui (SkillTreeUI.client) and
-- upgraded on the server (SkillTreeService).
--
-- Trees: the list on the left of the window, in order. The first one is "Core", the rest are zones.
--   Id      = unique key (saved; don't rename once live)
--   Name    = shown on the tab
--   Icon    = "rbxassetid://123" (image) or plain text / emoji
--   Columns / Rows = grid size of the tree area (optional; defaults to the biggest Pos used)
--   Nodes   = the skills in this tree
--
-- Node:
--   Id          = unique inside its tree (saved; don't rename once live)
--   Name, Icon  = shown on the node and in the preview
--   Pos         = { column, row } in the tree grid; 1,1 is top-left. Fractions are fine (2.5 = between 2 and 3)
--   MaxLevel    = how many times it can be upgraded
--   Cost        = { 100, 500, 2500 } (price of level 1, 2, 3...) or { Base = 100, Growth = 3 }
--                 (level n costs Base * Growth^(n-1))
--   Requires    = what must be done first (ALL of them). Each entry is either
--                   "NodeId"                      -> that node must be MAXED
--                   { Node = "NodeId", Level = 2 } -> that node must be at least level 2
--                 A line is drawn from every required node to this one.
--   Stat, PerLevel = each level adds PerLevel to the player's Stat (see Stats below)
--   Description = preview text; "{value}" becomes the bonus at the current / next level
--
-- Stats: every stat becomes a player attribute = Base + the sum of the levels' bonuses, set by
-- SkillTreeService. HeroLuck is already read by TreeHitService; the others are ready for gameplay
-- code to read with player:GetAttribute("AxeDamage") etc.

export type Requirement = string | { Node: string, Level: number? }

export type NodeDef = {
	Id: string,
	Name: string,
	Icon: string,
	Pos: { number },
	MaxLevel: number,
	Cost: { number } | { Base: number, Growth: number },
	Requires: { Requirement }?,
	Stat: string?,
	PerLevel: number?,
	Description: string?,
}

export type TreeDef = {
	Id: string,
	Name: string,
	Icon: string,
	Columns: number?,
	Rows: number?,
	Nodes: { NodeDef },
}

export type StatDef = {
	Base: number,
	Format: string, -- string.format pattern for one bonus value in the preview
}

local SkillTreeConfig = {}

SkillTreeConfig.Stats = {
	AxeDamage = { Base = 1, Format = "+%d%% axe damage" },
	SwingSpeed = { Base = 1, Format = "+%d%% swing speed" },
	HeroLuck = { Base = 1, Format = "+%d%% hero luck" },
	SellBonus = { Base = 1, Format = "+%d%% sell price" },
	ChestSize = { Base = 0, Format = "+%d chest slots" },
	DropBonus = { Base = 1, Format = "+%d%% material drops" },
	TreeGrowth = { Base = 0, Format = "+%d%% big tree growth" }, -- read by TreeService (TreeConfig.TreeLevels)
} :: { [string]: StatDef }

-- Percent stats store 0.1 for 10%; the preview multiplies by 100 for these.
SkillTreeConfig.PercentStats = {
	AxeDamage = true,
	SwingSpeed = true,
	HeroLuck = true,
	SellBonus = true,
	DropBonus = true,
	TreeGrowth = true,
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
		Columns = 3,
		Rows = 3,
		Nodes = {
			{ Id = "Sapling", Name = "Sapling", Icon = "🌱", Pos = { 2, 1 }, MaxLevel = 3,
				Cost = { Base = 250, Growth = 2.5 }, Stat = "DropBonus", PerLevel = 0.05 },
			{ Id = "Barkskin", Name = "Barkskin", Icon = "🪵", Pos = { 1, 2 }, MaxLevel = 3,
				Cost = { Base = 800, Growth = 2.5 }, Requires = { "Sapling" }, Stat = "AxeDamage", PerLevel = 0.05 },
			{ Id = "Seeker", Name = "Seeker", Icon = "🔍", Pos = { 3, 2 }, MaxLevel = 3,
				Cost = { Base = 800, Growth = 2.5 }, Requires = { "Sapling" }, Stat = "HeroLuck", PerLevel = 0.05 },
			{ Id = "Overgrowth", Name = "Overgrowth", Icon = "🌳", Pos = { 2, 3 }, MaxLevel = 2,
				Cost = { 6000, 30000 }, Requires = { "Barkskin", "Seeker" }, Stat = "DropBonus", PerLevel = 0.15 },
			{ Id = "FertileSoil", Name = "Fertile Soil", Icon = "🌿", Pos = { 1, 3 }, MaxLevel = 3,
				Cost = { Base = 1500, Growth = 2.5 }, Requires = { { Node = "Sapling", Level = 1 } }, Stat = "TreeGrowth", PerLevel = 0.2 },
		},
	},
	{
		Id = "Zone2",
		Name = "Fruit Grove",
		Icon = "🍎",
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

-- Preview text for a node's bonus at `level` (e.g. "+20% hero luck").
function SkillTreeConfig.EffectText(node: NodeDef, level: number): string
	local stat = node.Stat
	local total = (node.PerLevel or 0) * level
	if node.Description then
		return (string.gsub(node.Description, "{value}", tostring(total)))
	end
	if not stat then
		return ""
	end
	local def = SkillTreeConfig.Stats[stat]
	local shown = if SkillTreeConfig.PercentStats[stat] then math.floor(total * 100 + 0.5) else total
	return string.format(if def then def.Format else ("+%s " .. stat), shown)
end

return SkillTreeConfig
