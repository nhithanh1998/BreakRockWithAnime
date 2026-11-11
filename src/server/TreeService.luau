-- TreeService: keeps an owned plot's floor stocked with choppable trees.
--
-- Templates: ReplicatedStorage.Tress.Map<Zone> (falls back to Map1). Each template is a Model with
--   "HP"/"MaxHP" attributes and an optional "Info" BillboardGui (TextLabel + HPBar.Fill/TextLabel).
--   Optional template attribute "SpawnWeight" (default 1) makes a tree more or less common.
-- Trees go into the plot's "TreeSpawns" folder, at random spots on Floor.Ground.
-- When a tree's HP reaches 0 (TreeService.Damage, or any script setting the "HP" attribute)
--   it is removed and a new one grows back after CONFIG.RespawnDelay seconds.
-- When the plot's "Zone" attribute changes, all trees are replaced with the new zone's trees.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CONFIG = {
	TemplateFolder = "Tress",
	MaxTrees = 12,
	RespawnDelay = 4, -- seconds
	EdgeMargin = 6, -- studs kept clear from the floor's edges (walls)
	MinSpacing = 9, -- studs between tree centers
	MaxAttempts = 30, -- random spots tried per tree
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
}

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
		for _, child in folder:GetChildren() do
			if child:IsA("Model") then
				table.insert(list, child)
			end
		end
	end
	return list
end

local function pickTemplate(plot: Model): Model?
	local list = templatesFor(plot)
	local total = 0
	for _, t in list do
		total += t:GetAttribute("SpawnWeight") or 1
	end
	if total <= 0 then
		return nil
	end
	local roll = rng:NextNumber(0, total)
	for _, t in list do
		roll -= t:GetAttribute("SpawnWeight") or 1
		if roll <= 0 then
			return t
		end
	end
	return list[#list]
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
	return offset
end

local function findSpot(state: PlotState, template: Model): Vector3?
	local ground = state.plot:FindFirstChild("Floor") and state.plot.Floor:FindFirstChild("Ground")
	if not ground then
		warn(("[TreeService] %s has no Floor.Ground"):format(state.plot.Name))
		return nil
	end

	local _, size = template:GetBoundingBox()
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
			if Vector2.new(p.X - pos.X, p.Z - pos.Z).Magnitude < CONFIG.MinSpacing then
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
			text.Text = ("%d/%d"):format(hp, maxHp)
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
		task.delay(CONFIG.RespawnDelay, function()
			if state.active then
				fill(state)
			end
		end)
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
	tree:SetAttribute("HP", tree:GetAttribute("MaxHP") or tree:GetAttribute("HP") or 1)
	tree:SetAttribute("TreeType", template.Name)
	tree:PivotTo(CFrame.new(pos + Vector3.new(0, bottomOffset(template), 0)) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0))

	tree:GetAttributeChangedSignal("HP"):Connect(function()
		updateInfo(tree)
		if (tree:GetAttribute("HP") or 0) <= 0 and state.alive[tree] then
			felledEvent:Fire(tree, state.plot)
			tree:Destroy()
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
	while state.active and state.count < CONFIG.MaxTrees do
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
	}
	states[plot] = state

	table.insert(
		state.connections,
		plot:GetAttributeChangedSignal("Zone"):Connect(function()
			clear(state)
			fill(state)
		end)
	)

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

-- Deals damage to a tree. Returns true if this hit felled it.
function TreeService.Damage(tree: Model, amount: number): boolean
	local hp = tree:GetAttribute("HP")
	if not hp or hp <= 0 then
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

return TreeService
