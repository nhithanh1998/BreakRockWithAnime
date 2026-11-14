-- StandLayoutDebug: Studio-only tools to look at Farm Stand layouts. Nothing here runs in a live game.
--
-- From the Studio command bar (Edit mode, or the Server side of a playtest):
--   local D = require(game.ServerScriptService.Server.StandLayoutDebug)
--   D.Preview(3)            -- put Level 3 on every plot's FarmStand site, markers + paths shown
--   D.Preview(3, "FarmStand", false)  -- same, markers hidden (what players see)
--   D.Show(true / false)    -- show / hide markers, labels and paths on every site
--   D.Check()               -- Blueprint Check: prints missing / misnamed / duplicate markers
--   D.Clear()               -- remove the previewed stands
-- In a playtest, set workspace attribute "StandLayoutDebug" = true (before Play) to start with the
-- markers shown.
--
-- Colours: StandLayoutConfig.DebugColors. Each marker gets a label with its name. Paths:
--   blue  = helper route  HelperPickupPoint -> HelperPath_1..N -> HelperDropPoint
--   white = customers     CustomerSpawn -> CustomerPath -> QueuePoint_K..1 -> ServePoint_1, and ServePoint -> CustomerExit

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local StandLayoutConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StandLayoutConfig"))
local StandLayout = require(script.Parent:WaitForChild("StandLayout"))

local StandLayoutDebug = {}

local PATHS_NAME = "DebugPaths"

local function label(marker: BasePart)
	local gui = marker:FindFirstChild("DebugLabel") :: BillboardGui?
	if not gui then
		local g = Instance.new("BillboardGui")
		g.Name = "DebugLabel"
		g.Size = UDim2.fromOffset(150, 22)
		g.StudsOffsetWorldSpace = Vector3.new(0, 2.2, 0)
		g.AlwaysOnTop = true
		g.MaxDistance = 140
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Size = UDim2.fromScale(1, 1)
		t.Font = Enum.Font.GothamBold
		t.TextScaled = true
		t.TextStrokeTransparency = 0.2
		t.Parent = g
		g.Parent = marker
		gui = g
	end
	local t = (gui :: BillboardGui):FindFirstChildOfClass("TextLabel") :: TextLabel
	t.Text = marker.Name
	t.TextColor3 = StandLayoutConfig.DebugColors[StandLayoutConfig.KindOf(marker.Name)] or Color3.new(1, 0, 0)
end

local function paint(container: Instance, on: boolean)
	local folder = container:FindFirstChild(StandLayoutConfig.MarkersFolder)
	if not folder then
		return
	end
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") then
			d.Color = StandLayoutConfig.DebugColors[StandLayoutConfig.KindOf(d.Name)] or Color3.new(1, 0, 0)
			d.Material = Enum.Material.Neon
			label(d)
		end
	end
	StandLayout.SetMarkersVisible(container, on)
end

local function segment(parent: Instance, a: Vector3, b: Vector3, color: Color3)
	local dist = (b - a).Magnitude
	if dist < 0.05 then
		return
	end
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.new(0.25, 0.25, dist)
	p.CFrame = CFrame.lookAt((a + b) / 2, b)
	p.Parent = parent
end

local function polyline(parent: Instance, points: { Vector3 }, color: Color3)
	for i = 1, #points - 1 do
		segment(parent, points[i] + Vector3.new(0, 0.6, 0), points[i + 1] + Vector3.new(0, 0.6, 0), color)
	end
end

local function drawPaths(plot: Instance, standId: string, on: boolean)
	local site = StandLayout.Site(plot, standId)
	if not site then
		return
	end
	local old = site:FindFirstChild(PATHS_NAME)
	if old then
		old:Destroy()
	end
	if not on then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = PATHS_NAME
	local function pos(name: string): Vector3?
		local cf = StandLayout.Get(plot, standId, name)
		return cf and cf.Position
	end
	local function list(prefix: string): { Vector3 }
		local out = {}
		for _, cf in StandLayout.List(plot, standId, prefix) do
			table.insert(out, cf.Position)
		end
		return out
	end
	-- Helper route.
	local route = {}
	table.insert(route, pos("HelperPickupPoint"))
	for _, p in list("HelperPath") do
		table.insert(route, p)
	end
	table.insert(route, pos("HelperDropPoint"))
	polyline(folder, route, StandLayoutConfig.DebugColors.HelperPath)
	-- Helper rest pads -> drop point.
	local drop = pos("HelperDropPoint")
	for _, p in list("HelperSlot") do
		if drop then
			polyline(folder, { p, drop }, StandLayoutConfig.DebugColors.HelperSlot)
		end
	end
	-- Customers: every spawn walks the path to the far end of the queue, down the queue to serve point 1.
	local queue = list("QueuePoint")
	local walk = list("CustomerPath")
	for _, spawnPos in list("CustomerSpawn") do
		local pts = { spawnPos }
		-- nearest path point first, so both directions read right
		table.sort(walk, function(a, b)
			return (a - spawnPos).Magnitude < (b - spawnPos).Magnitude
		end)
		table.insert(pts, walk[1])
		for i = #queue, 1, -1 do
			table.insert(pts, queue[i])
		end
		local serve = pos("ServePoint_1")
		if serve then
			table.insert(pts, serve)
		end
		polyline(folder, pts, StandLayoutConfig.DebugColors.CustomerPath)
	end
	for _, serve in list("ServePoint") do
		for _, exitPos in list("CustomerExit") do
			table.sort(walk, function(a, b)
				return (a - exitPos).Magnitude < (b - exitPos).Magnitude
			end)
			polyline(folder, { serve, walk[1], exitPos }, StandLayoutConfig.DebugColors.CustomerExit)
		end
	end
	local vipQueue = list("VipQueuePoint")
	local vipServe = pos("VipServePoint")
	if vipServe and #vipQueue > 0 then
		local pts = {}
		for i = #vipQueue, 1, -1 do
			table.insert(pts, vipQueue[i])
		end
		table.insert(pts, vipServe)
		polyline(folder, pts, StandLayoutConfig.DebugColors.VipQueuePoint)
	end
	folder.Parent = site
end

local function eachSite(fn: (plot: Instance, standId: string, site: Model) -> ())
	local plots = workspace:FindFirstChild("Plots")
	for _, plot in if plots then plots:GetChildren() else {} do
		for standId in StandLayoutConfig.Stands do
			local site = StandLayout.Site(plot, standId)
			if site then
				fn(plot, standId, site)
			end
		end
	end
end

function StandLayoutDebug.Show(on: boolean)
	assert(RunService:IsStudio(), "StandLayoutDebug is Studio-only")
	eachSite(function(plot, standId, site)
		site:SetAttribute("DebugMarkers", on)
		paint(site, on)
		local placed = StandLayout.Placed(plot, standId)
		if placed then
			paint(placed, on)
		end
		drawPaths(plot, standId, on)
	end)
end

function StandLayoutDebug.Preview(level: number, standId: string?, showMarkers: boolean?)
	assert(RunService:IsStudio(), "StandLayoutDebug is Studio-only")
	local on = showMarkers ~= false
	eachSite(function(plot, id, site)
		if standId == nil or standId == id then
			site:SetAttribute("DebugMarkers", on)
			StandLayout.Place(plot, id, level)
		end
	end)
	StandLayoutDebug.Show(on)
end

function StandLayoutDebug.Clear()
	eachSite(function(plot, standId, site)
		local placed = StandLayout.Placed(plot, standId)
		if placed then
			placed:Destroy()
		end
		drawPaths(plot, standId, false)
		site:SetAttribute("DebugMarkers", nil)
		StandLayout.SetMarkersVisible(site, false)
	end)
end

function StandLayoutDebug.Check(): number
	local issues = StandLayout.CheckAll(false)
	if #issues == 0 then
		print("[Stand Blueprint Check] all stands, levels and sites OK")
	else
		for _, issue in issues do
			warn("[Stand Blueprint Check] " .. issue)
		end
		print(("[Stand Blueprint Check] %d problem(s)"):format(#issues))
	end
	return #issues
end

return StandLayoutDebug
