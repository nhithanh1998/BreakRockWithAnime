-- TreeService: keeps an owned plot's floor stocked with choppable trees.
--
-- Templates: ReplicatedStorage.Trees.Map<Zone> (falls back to Map1). Each template is a Model; its
--   "HP"/"MaxHP" are set on spawn from TreeConfig.TreeHP, by level and zone. The HP bar is ONE shared
--   template, ReplicatedStorage.InfoBars.TreeBar, cloned onto each tree on spawn (addBar: trunk
--   InfoAttachment 2 studs above the tree, "Lv N. Name"); the client (TreeClient) draws it.
--   An old-style "Info" BillboardGui (HPBar.Fill/TextLabel) still works.
--   Optional template attribute "SpawnWeight" (default 1) makes a tree more or less common.
--   Only templates listed in the zone's ZoneDrops Trees are spawned.
-- Zone base stats (ZoneConfig Base) + the owner's zone skill tree: MaxTrees, RespawnTime,
--   TreeLevelWeights, OldTreeChance
--   bumps a new tree one level older, TreeHP / HPCut scale its MaxHP.
-- Trees go into the plot's "TreeSpawns" folder, at random spots on Floor.Ground.
-- When a tree's HP reaches 0 (TreeService.Damage, or any script setting the "HP" attribute)
--   it gets the "Dead" attribute, is removed TreeConfig.FellTime later (clients play the fall
--   animation meanwhile), and a new one grows back after the zone's RespawnTime.
-- Upkeep: ONE scan loop for every plot (every SCAN_INTERVAL seconds, no Heartbeat, no loop per tree)
--   grows back felled trees whose RespawnTime is up and ticks burning trees (TreeService.Burn). Big
--   scans are split into batches of SCAN_BATCH with a task.wait() between them so no frame stalls.
-- Zone changes: ZoneService sets the plot's "ZoneBusy", removes the old trees, and clears "ZoneBusy" once the
--   new floor is in place; the new zone's trees grow then.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local ZoneDrops = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZoneDrops"))
local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))
local SkillTreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SkillTreeConfig"))
local ZoneConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZoneConfig"))

local CONFIG = {
	TemplateFolder = "Trees",
	-- MaxTrees / RespawnTime / tree level weights: per zone, ZoneConfig Base.
	EdgeMargin = 6, -- studs kept clear from the floor's edges (walls)
	MinSpacing = 9, -- studs between tree centers
	MaxAttempts = 30, -- random spots tried per tree
	ModelScale = 1.2, -- spawned trees are this much bigger than their template (1 = template size)
	BarAboveTop = 2, -- studs between the top of the tree and the centre of its HP bar
	ScanInterval = 1, -- seconds between two upkeep scans (respawns, burns)
	ScanBatch = 25, -- work items per frame during a scan; the rest waits for the next frame
}

local TreeService = {}

local felledEvent = Instance.new("BindableEvent")
TreeService.TreeFelled = felledEvent.Event -- (tree, plot)

type PlotState = {
	plot: Model,
	folder: Instance,
	alive: { [Model]: true },
	count: number,
	active: boolean,
	connections: { RBXScriptConnection },
	respawnAt: { number }, -- os.clock() times at which a felled tree may grow back
}

-- A burning tree (TreeService.Burn): `tick` runs once per scan until `ends`.
type Burn = { ends: number, tick: (tree: Model) -> () }
local burns: { [Model]: Burn } = {}

local states: { [Model]: PlotState } = {}
local rng = Random.new()
local bottomOffsetCache: { [Model]: number } = {}

local function templatesFor(plot: Model): { Model }
	local root = ReplicatedStorage:FindFirstChild(CONFIG.TemplateFolder)
	if not root then
		return {}
	end
	local zone = plot:GetAttribute("Zone") or 1
	local folder = root:FindFirstChild("Map" .. zone) or root:FindFirstChild("Map1")
	local list = {}
	if folder then
		-- Only trees that the zone configures in ZoneDrops grow there.
		for _, child in folder:GetChildren() do
			if child:IsA("Model") and ZoneDrops.GrowsIn(zone, child.Name) then
				table.insert(list, child)
			end
		end
	end
	return list
end

-- Level weight of a template for this plot (zone TreeLevelWeights, boosted by the owner's TreeGrowth).
local function levelWeight(plot: Model, template: Model, growth: number): number
	local cfg = TreeConfig.TreeLevels
	local zone = plot:GetAttribute("Zone")
	local level = ZoneDrops.GetLevel(zone, template.Name)
	local weights = ZoneConfig.GetBase(zone, "TreeLevelWeights") or cfg.Weights
	local base = weights[level] or 0
	local boost = cfg.Boost[level] or 0
	return base * (1 + growth * boost) * (template:GetAttribute("SpawnWeight") or 1)
end

local function ownerOf(plot: Model): Player?
	local userId = plot:GetAttribute("OwnerUserId")
	return if typeof(userId) == "number" then Players:GetPlayerByUserId(userId) else nil
end

-- The plot owner's skill tree stat for the plot's zone (zone trees only count in their own zone).
local function ownerStat(plot: Model, stat: string): number
	local owner = ownerOf(plot)
	if owner then
		return SkillTreeConfig.PlayerStat(owner, stat, plot:GetAttribute("Zone") or 1)
	end
	-- No owner: the zone's base value.
	return SkillTreeConfig.StatIn(stat, plot:GetAttribute("Zone") or 1, function(): number
		return 0
	end)
end

local function ownerGrowth(plot: Model): number
	return ownerStat(plot, "TreeGrowth")
end

-- How many trees this plot keeps standing (zone MaxTrees + the owner's skills).
local function maxTrees(plot: Model): number
	return math.floor(ownerStat(plot, "MaxTrees"))
end

-- OldTreeChance: the picked tree may grow one level older, if its family has that level here.
local function maybeOlder(plot: Model, list: { Model }, picked: Model): Model
	local chance = ownerStat(plot, "OldTreeChance")
	if chance <= 0 or rng:NextNumber() >= chance then
		return picked
	end
	local zone = plot:GetAttribute("Zone")
	local want = ZoneDrops.GetLevel(zone, picked.Name) + 1
	for _, t in list do
		if ZoneDrops.GetLevel(zone, t.Name) == want then
			return t
		end
	end
	return picked
end

-- Picks a tree family (all equally likely), then one of its levels by weight.
local function pickTemplate(plot: Model): Model?
	local zone = plot:GetAttribute("Zone")
	local families: { [any]: { Model } } = {}
	local familyList = {}
	for _, t in templatesFor(plot) do
		local def = ZoneDrops.GetTree(zone, t.Name)
		if def then
			if not families[def] then
				families[def] = {}
				table.insert(familyList, def)
			end
			table.insert(families[def], t)
		end
	end
	if #familyList == 0 then
		return nil
	end
	local list = families[familyList[rng:NextInteger(1, #familyList)]]

	local growth = ownerGrowth(plot)
	local total = 0
	for _, t in list do
		total += levelWeight(plot, t, growth)
	end
	if total <= 0 then
		return maybeOlder(plot, list, list[rng:NextInteger(1, #list)])
	end
	local roll = rng:NextNumber(0, total)
	for _, t in list do
		roll -= levelWeight(plot, t, growth)
		if roll <= 0 then
			return maybeOlder(plot, list, t)
		end
	end
	return maybeOlder(plot, list, list[#list])
end

-- Distance from the template's pivot down to the bottom of its bounding box,
-- so trees always stand exactly on the ground.
local function bottomOffset(template: Model): number
	local cached = bottomOffsetCache[template]
	if cached then
		return cached
	end
	local cf, size = template:GetBoundingBox()
	local offset = template:GetPivot().Position.Y - (cf.Position.Y - size.Y / 2)
	bottomOffsetCache[template] = offset
	return offset * CONFIG.ModelScale
end

local function findSpot(state: PlotState, template: Model): Vector3?
	local ground = state.plot:FindFirstChild("Floor") and state.plot.Floor:FindFirstChild("Ground")
	if not ground then
		warn(("[TreeService] %s has no Floor.Ground"):format(state.plot.Name))
		return nil
	end

	local _, templateSize = template:GetBoundingBox()
	local size = templateSize * CONFIG.ModelScale
	local halfX = ground.Size.X / 2 - CONFIG.EdgeMargin
	local halfZ = ground.Size.Z / 2 - CONFIG.EdgeMargin

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ground, state.folder }

	for _ = 1, CONFIG.MaxAttempts do
		local local_ = CFrame.new(rng:NextNumber(-halfX, halfX), ground.Size.Y / 2, rng:NextNumber(-halfZ, halfZ))
		local pos = (ground.CFrame * local_).Position

		local spaced = true
		for tree in state.alive do
			local p = tree:GetPivot().Position
			if Vector2.new(p.X - pos.X, p.Z - pos.Z).Magnitude < CONFIG.MinSpacing * CONFIG.ModelScale then
				spaced = false
				break
			end
		end

		if spaced then
			-- Reject spots blocked by props, decorations or players.
			local boxCFrame = CFrame.new(pos + Vector3.new(0, size.Y / 2 + 0.2, 0))
			local hits = workspace:GetPartBoundsInBox(boxCFrame, Vector3.new(size.X, size.Y, size.Z), params)
			if #hits == 0 then
				return pos
			end
		end
	end
	return nil
end

-- "OldOakTree" -> "Old Oak Tree"
local function displayName(name: string): string
	return (name:gsub("(%l)(%u)", "%1 %2"))
end

-- Every tree gets its HP bar from ONE shared template, ReplicatedStorage.InfoBars.TreeBar (edit it
-- there, not on the tree models): an "InfoAttachment" on the trunk (PrimaryPart), CONFIG.BarAboveTop
-- studs above the top of the tree, with the bar cloned into it and "Lv N. Name" written on it.
-- Call after the tree is scaled and placed.
local function addBar(tree: Model, template: Model, level: number)
	for _, d in tree:GetDescendants() do
		if d.Name == "InfoAttachment" and d:IsA("Attachment") then
			d:Destroy() -- a leftover copy on an old template; the shared one wins
		end
	end
	local folder = ReplicatedStorage:FindFirstChild(HeroConfig.BarFolder)
	local source = folder and folder:FindFirstChild("TreeBar")
	local trunk = tree.PrimaryPart or tree:FindFirstChildWhichIsA("BasePart", true)
	if not source or not source:IsA("BillboardGui") or not trunk then
		warn(("[TreeService] ReplicatedStorage.%s.TreeBar or a trunk is missing; %s gets no HP bar"):format(HeroConfig.BarFolder, tree.Name))
		return
	end
	local cf, size = tree:GetBoundingBox()
	local above = Vector3.new(cf.X, cf.Y + size.Y / 2 + CONFIG.BarAboveTop, cf.Z)
	local attachment = Instance.new("Attachment")
	attachment.Name = "InfoAttachment"
	attachment.Position = trunk.CFrame:PointToObjectSpace(above)
	attachment.Parent = trunk
	local bar = source:Clone()
	local nameLabel = bar:FindFirstChild("TreeName", true)
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = ("Lv%d. %s"):format(level, displayName(template.Name))
	end
	bar.Parent = attachment
end

local function updateInfo(tree: Model)
	local info = tree:FindFirstChild("Info")
	if not info then
		return
	end
	local hp = math.max(tree:GetAttribute("HP") or 0, 0)
	local maxHp = math.max(tree:GetAttribute("MaxHP") or 1, 1)
	local bar = info:FindFirstChild("HPBar")
	if bar then
		local fill = bar:FindFirstChild("Fill")
		if fill then
			fill.Size = UDim2.fromScale(hp / maxHp, 1)
		end
		local text = bar:FindFirstChild("TextLabel")
		if text then
			text.Text = ("%s/%s"):format(HeroConfig.Abbreviate(hp), HeroConfig.Abbreviate(maxHp))
		end
	end
end

local fill: (state: PlotState) -> ()

local function onTreeGone(state: PlotState, tree: Model)
	if not state.alive[tree] then
		return
	end
	state.alive[tree] = nil
	state.count -= 1
	if state.active then
		-- Grown back by the upkeep scan (no timer per tree).
		local respawnTime = ZoneConfig.GetBase(state.plot:GetAttribute("Zone"), "RespawnTime") or 4
		table.insert(state.respawnAt, os.clock() + respawnTime)
	end
end

local function spawnTree(state: PlotState): boolean
	local template = pickTemplate(state.plot)
	if not template then
		warn(("[TreeService] No tree templates for %s"):format(state.plot.Name))
		return false
	end
	local pos = findSpot(state, template)
	if not pos then
		return false
	end

	local tree = template:Clone()
	pcall(tree.ScaleTo, tree, tree:GetScale() * CONFIG.ModelScale)
	-- Trees never use physics (clients animate shakes / falls locally). Anchor everything so loose
	-- pieces like the Ground mound can't fall apart, even if a template forgot to anchor them.
	for _, d in tree:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	-- HP from TreeConfig.TreeHP, by the tree's level and the plot's zone.
	local zone = state.plot:GetAttribute("Zone")
	local level = ZoneDrops.GetLevel(zone, template.Name)
	local maxHp = TreeConfig.MaxHP(zone, level)
	-- Owner's zone skill tree: TreeHP multiplies (Hardwood / Ironwood), HPCut takes a share off.
	local hpMult = ownerStat(state.plot, "TreeHP") * math.max(0.05, 1 - ownerStat(state.plot, "HPCut"))
	maxHp = math.max(1, math.floor(maxHp * hpMult))
	tree:SetAttribute("MaxHP", maxHp)
	tree:SetAttribute("HP", maxHp)
	tree:SetAttribute("TreeType", template.Name)
	tree:PivotTo(CFrame.new(pos + Vector3.new(0, bottomOffset(template), 0)) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0))
	addBar(tree, template, level)

	tree:GetAttributeChangedSignal("HP"):Connect(function()
		updateInfo(tree)
		if (tree:GetAttribute("HP") or 0) <= 0 and state.alive[tree] and not tree:GetAttribute("Dead") then
			-- Keep the tree around for a moment so clients can play the fall animation.
			tree:SetAttribute("Dead", true)
			felledEvent:Fire(tree, state.plot)
			task.delay(TreeConfig.FellTime, function()
				if tree.Parent then
					tree:Destroy()
				end
			end)
		end
	end)
	tree.Destroying:Connect(function()
		onTreeGone(state, tree)
	end)

	updateInfo(tree)
	state.alive[tree] = true
	state.count += 1
	tree.Parent = state.folder
	return true
end

fill = function(state: PlotState)
	-- ZoneService is swapping the zone: it removes the old trees and clears ZoneBusy when the new floor is ready.
	if state.plot:GetAttribute("ZoneBusy") then
		return
	end
	while state.active and state.count < maxTrees(state.plot) do
		if not spawnTree(state) then
			break -- no room right now; the next felled tree triggers another try
		end
	end
end

local function clear(state: PlotState)
	local trees = {}
	for tree in state.alive do
		table.insert(trees, tree)
	end
	for _, tree in trees do
		state.alive[tree] = nil
		tree:Destroy()
	end
	state.count = 0
end

function TreeService.StartPlot(plot: Model)
	if states[plot] then
		return
	end
	local folder = plot:FindFirstChild("TreeSpawns")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "TreeSpawns"
		folder.Parent = plot
	end
	folder:ClearAllChildren()

	local state: PlotState = {
		plot = plot,
		folder = folder,
		alive = {},
		count = 0,
		active = true,
		connections = {},
		respawnAt = {},
	}
	states[plot] = state

	table.insert(
		state.connections,
		plot:GetAttributeChangedSignal("ZoneBusy"):Connect(function()
			if not plot:GetAttribute("ZoneBusy") and state.active then
				fill(state)
			end
		end)
	)

	-- Buying Seedling / Thick Forest grows the extra trees right away.
	local owner = ownerOf(plot)
	if owner then
		table.insert(
			state.connections,
			owner:GetAttributeChangedSignal("MaxTrees"):Connect(function()
				if state.active then
					fill(state)
				end
			end)
		)
	end

	fill(state)
end

function TreeService.StopPlot(plot: Model)
	local state = states[plot]
	if not state then
		return
	end
	states[plot] = nil
	state.active = false
	for _, c in state.connections do
		c:Disconnect()
	end
	clear(state)
end

-- Sets a tree on fire: `onTick(tree)` runs once per upkeep scan (every ScanInterval seconds) until
-- `duration` runs out or the tree dies. Burning an already burning tree only refreshes the end time
-- (the first burn's onTick keeps running). Returns true if it was refreshed.
function TreeService.Burn(tree: Model, duration: number, onTick: (tree: Model) -> ()): boolean
	local burn = burns[tree]
	if burn then
		burn.ends = os.clock() + duration
		return true
	end
	burns[tree] = { ends = os.clock() + duration, tick = onTick }
	return false
end

-- Deals damage to a tree. Returns true if this hit felled it.
function TreeService.Damage(tree: Model, amount: number): boolean
	local hp = tree:GetAttribute("HP")
	if not hp or hp <= 0 or tree:GetAttribute("Dead") then
		return false
	end
	local newHp = math.max(hp - amount, 0)
	tree:SetAttribute("HP", newHp)
	return newHp <= 0
end

function TreeService.GetTrees(plot: Model): { Model }
	local state = states[plot]
	local list = {}
	if state then
		for tree in state.alive do
			table.insert(list, tree)
		end
	end
	return list
end

-- Upkeep scan --------------------------------------------------------------------------------------

local function treeAlive(tree: Model): boolean
	return tree.Parent ~= nil and not tree:GetAttribute("Dead") and (tree:GetAttribute("HP") or 0) > 0
end

-- Takes the respawns that are due out of the plot's list; true if at least one was.
local function takeDueRespawns(state: PlotState, now: number): boolean
	local due = false
	for i = #state.respawnAt, 1, -1 do
		if state.respawnAt[i] <= now then
			table.remove(state.respawnAt, i)
			due = true
		end
	end
	return due
end

local function scan()
	local now = os.clock()
	local done = 0
	local function step()
		done += 1
		if done % CONFIG.ScanBatch == 0 then
			task.wait() -- spread big scans over several frames
		end
	end

	-- Plots with trees to grow back. A refill can spawn several trees: one batch item each plot.
	local plots: { PlotState } = {}
	for _, state in states do
		if state.active and takeDueRespawns(state, now) then
			table.insert(plots, state)
		end
	end
	for _, state in plots do
		if state.active and states[state.plot] == state then
			fill(state)
		end
		step()
	end

	-- Burning trees: one tick each, ended ones dropped.
	local burning: { Model } = {}
	for tree in burns do
		table.insert(burning, tree)
	end
	for _, tree in burning do
		local burn = burns[tree]
		if burn then
			if not treeAlive(tree) or now >= burn.ends then
				burns[tree] = nil
			else
				task.spawn(burn.tick, tree) -- an error in one tick can't stop the scan
			end
		end
		step()
	end
end

task.spawn(function()
	while true do
		task.wait(CONFIG.ScanInterval)
		local ok, err = pcall(scan)
		if not ok then
			warn("[TreeService] upkeep scan failed: " .. tostring(err))
		end
	end
end)

return TreeService
