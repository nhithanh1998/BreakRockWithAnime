-- SkillTreeService: skill levels + upgrades for the skill trees (Shared.SkillTreeConfig).
--
-- Levels live in player.Skills as IntValues named "<TreeId>/<NodeId>" (replicated, so the client
-- UI just reads them). Saved / loaded by DataService.
--
-- Remotes.SkillAction (RemoteFunction):
--   ("Upgrade", treeId, nodeId) -> { ok = true } | { ok = false, message = "..." }
--     Checks max level, requirements and money (ChestService.SpendMoney) on the server.
--
-- Stats: after any change every SkillTreeConfig.Stats entry is written as a player attribute
-- (Base + bonuses), e.g. player:GetAttribute("HeroLuck").

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SkillTreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SkillTreeConfig"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))

type Result = { ok: boolean, message: string? }

local SkillTreeService = {}

local function folderOf(player: Player): Folder
	local folder = player:FindFirstChild("Skills")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Skills"
		folder.Parent = player
	end
	return folder :: Folder
end

function SkillTreeService.GetLevel(player: Player, treeId: string, nodeId: string): number
	local value = folderOf(player):FindFirstChild(SkillTreeConfig.Key(treeId, nodeId))
	return if value and value:IsA("IntValue") then value.Value else 0
end

local function setLevel(player: Player, treeId: string, nodeId: string, level: number)
	local folder = folderOf(player)
	local key = SkillTreeConfig.Key(treeId, nodeId)
	local value = folder:FindFirstChild(key) :: IntValue?
	if not value then
		local newValue = Instance.new("IntValue")
		newValue.Name = key
		newValue.Parent = folder
		value = newValue
	end
	(value :: IntValue).Value = level
end

-- Sum of every node's bonus per stat.
function SkillTreeService.GetStat(player: Player, stat: string): number
	local def = SkillTreeConfig.Stats[stat]
	local total = if def then def.Base else 0
	for _, tree in SkillTreeConfig.Trees do
		for _, node in tree.Nodes do
			if node.Stat == stat and node.PerLevel then
				total += node.PerLevel * SkillTreeService.GetLevel(player, tree.Id, node.Id)
			end
		end
	end
	return total
end

local function applyStats(player: Player)
	for stat in SkillTreeConfig.Stats do
		player:SetAttribute(stat, SkillTreeService.GetStat(player, stat))
	end
end

local function upgrade(player: Player, treeId: any, nodeId: any): Result
	if typeof(treeId) ~= "string" or typeof(nodeId) ~= "string" then
		return { ok = false, message = "Bad request" }
	end
	local node = SkillTreeConfig.GetNode(treeId, nodeId)
	if not node then
		return { ok = false, message = "Unknown skill" }
	end
	local level = SkillTreeService.GetLevel(player, treeId, nodeId)
	local cost = SkillTreeConfig.Cost(node, level)
	if not cost then
		return { ok = false, message = "Already maxed" }
	end
	local getLevel = function(t: string, n: string): number
		return SkillTreeService.GetLevel(player, t, n)
	end
	if not SkillTreeConfig.RequirementsMet(treeId, node, getLevel) then
		return { ok = false, message = "Requirements not met" }
	end
	if not ChestService.SpendMoney(player, cost) then
		return { ok = false, message = "Not enough money" }
	end
	setLevel(player, treeId, nodeId, level + 1)
	applyStats(player)
	return { ok = true }
end

local function onAction(player: Player, action: any, ...: any): Result
	if action == "Upgrade" then
		return upgrade(player, ...)
	end
	return { ok = false, message = "Unknown action" }
end

-- From DataService: { ["Tree/Node"] = level }. Unknown nodes are dropped, levels clamped to MaxLevel.
function SkillTreeService.ApplySaved(player: Player, saved: { [string]: any }?)
	for key, level in saved or {} do
		if typeof(key) ~= "string" or typeof(level) ~= "number" then
			continue
		end
		local treeId, nodeId = SkillTreeConfig.SplitKey(key)
		local node = treeId and nodeId and SkillTreeConfig.GetNode(treeId, nodeId)
		if node then
			local now = SkillTreeService.GetLevel(player, treeId :: string, nodeId :: string)
			setLevel(player, treeId :: string, nodeId :: string, math.clamp(math.max(now, math.floor(level)), 0, node.MaxLevel))
		end
	end
	applyStats(player)
end

local function onPlayer(player: Player)
	folderOf(player)
	applyStats(player)
end

function SkillTreeService.Start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:WaitForChild("SkillAction") :: RemoteFunction
	remote.OnServerInvoke = onAction

	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
end

return SkillTreeService
