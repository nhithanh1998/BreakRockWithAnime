-- StandLayout: reads the markers of Farm Stand level models / plot sites (StandLayoutConfig), checks
-- them (Blueprint Check), and puts a level model on a plot's site.
--
--   StandLayout.LevelModel(standId, level) -> Model?        template in ServerStorage.StandModels
--   StandLayout.Site(plot, standId) -> Model?                plot.StandSites.<StandId>
--   StandLayout.Place(plot, standId, level) -> Model?        clones the level onto the site (replaces the old one)
--   StandLayout.Markers(container) -> { [name] = Instance }  every marker in container.Markers
--   StandLayout.MarkerCFrame(marker) -> CFrame               world CFrame of a Part / Attachment marker
--   StandLayout.Get(plot, standId, name) -> CFrame?          a marker of the placed stand, or of the site
--   StandLayout.Count(container, prefix) -> number           how many "<prefix>_N" markers (1..N, no gaps)
--   StandLayout.CheckLevel(standId, level) -> { string }      problems with a level model (empty = fine)
--   StandLayout.CheckSite(site, standId) -> { string }        problems with a site
--   StandLayout.CheckAll(warnThem: boolean?) -> { string }    every stand, every level, every plot site
--   StandLayout.SetMarkersVisible(container, on)             markers show / hide (Studio debug)

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StandLayoutConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StandLayoutConfig"))

local StandLayout = {}

local function isMarker(inst: Instance): boolean
	return inst:IsA("BasePart") or inst:IsA("Attachment")
end

function StandLayout.LevelModel(standId: string, level: number): Model?
	local stand = StandLayoutConfig.Stands[standId]
	local layout = stand and stand.Levels[level]
	local models = ServerStorage:FindFirstChild(StandLayoutConfig.ModelsFolder)
	local folder = models and models:FindFirstChild(standId)
	local model = layout and folder and folder:FindFirstChild(layout.Model)
	return if model and model:IsA("Model") then model else nil
end

function StandLayout.Site(plot: Instance, standId: string): Model?
	local sites = plot:FindFirstChild(StandLayoutConfig.SitesFolder)
	local site = sites and sites:FindFirstChild(standId)
	return if site and site:IsA("Model") then site else nil
end

function StandLayout.Markers(container: Instance): { [string]: Instance }
	local out = {}
	local folder = container:FindFirstChild(StandLayoutConfig.MarkersFolder)
	if folder then
		for _, d in folder:GetDescendants() do
			if isMarker(d) and not (d:IsA("Attachment") and d.Parent and d.Parent:IsA("Attachment")) then
				out[d.Name] = d
			end
		end
	end
	return out
end

function StandLayout.MarkerCFrame(marker: Instance): CFrame
	if marker:IsA("Attachment") then
		return marker.WorldCFrame
	end
	return (marker :: BasePart).CFrame
end

function StandLayout.Placed(plot: Instance, standId: string): Model?
	local site = StandLayout.Site(plot, standId)
	local placed = site and site:FindFirstChild(StandLayoutConfig.PlacedName)
	return if placed and placed:IsA("Model") then placed else nil
end

function StandLayout.Get(plot: Instance, standId: string, name: string): CFrame?
	local placed = StandLayout.Placed(plot, standId)
	local marker = placed and StandLayout.Markers(placed)[name]
	if not marker then
		local site = StandLayout.Site(plot, standId)
		marker = site and StandLayout.Markers(site)[name]
	end
	return if marker then StandLayout.MarkerCFrame(marker) else nil
end

function StandLayout.Count(container: Instance, prefix: string): number
	local markers = StandLayout.Markers(container)
	local n = 0
	while markers[("%s_%d"):format(prefix, n + 1)] do
		n += 1
	end
	return n
end

-- Ordered list of CFrames "<prefix>_1".."<prefix>_N" from the placed stand (or the site).
function StandLayout.List(plot: Instance, standId: string, prefix: string): { CFrame }
	local out = {}
	local i = 1
	while true do
		local cf = StandLayout.Get(plot, standId, ("%s_%d"):format(prefix, i))
		if not cf then
			break
		end
		table.insert(out, cf)
		i += 1
	end
	return out
end

function StandLayout.SetMarkersVisible(container: Instance, on: boolean)
	local folder = container:FindFirstChild(StandLayoutConfig.MarkersFolder)
	if not folder then
		return
	end
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") then
			d.Transparency = if on then 0.35 else 1
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = d.Name == "RestockMat" or d.Name:sub(1, 11) == "UpgradePad_"
			for _, g in d:GetChildren() do
				if g:IsA("BillboardGui") and g.Name == "DebugLabel" then
					g.Enabled = on
				end
			end
		end
	end
end

-- Blueprint Check -------------------------------------------------------------------------------------

local KNOWN_KINDS: { [string]: boolean } = {}
for kind in StandLayoutConfig.DebugColors do
	KNOWN_KINDS[kind] = true
end

-- Names that appear twice, unknown names and spacing problems in a Markers folder.
local function checkFolder(container: Instance, where: string, issues: { string })
	local folder = container:FindFirstChild(StandLayoutConfig.MarkersFolder)
	if not folder then
		table.insert(issues, ("%s: no '%s' folder"):format(where, StandLayoutConfig.MarkersFolder))
		return
	end
	local seen: { [string]: boolean } = {}
	for _, d in folder:GetDescendants() do
		if not isMarker(d) then
			continue
		end
		if seen[d.Name] then
			table.insert(issues, ("%s: marker '%s' appears more than once"):format(where, d.Name))
		end
		seen[d.Name] = true
		if not KNOWN_KINDS[StandLayoutConfig.KindOf(d.Name)] then
			table.insert(issues, ("%s: unknown marker name '%s' (typo?)"):format(where, d.Name))
		end
	end
end

local function spacing(markers: { [string]: Instance }, test: (string) -> boolean, min: number, what: string, where: string, issues: { string })
	local list = {}
	for name, m in markers do
		if test(name) then
			table.insert(list, { name = name, pos = StandLayout.MarkerCFrame(m).Position })
		end
	end
	for i = 1, #list do
		for j = i + 1, #list do
			local a, b = list[i], list[j]
			local flat = Vector3.new(a.pos.X - b.pos.X, 0, a.pos.Z - b.pos.Z).Magnitude
			if flat < min - 0.01 then
				table.insert(issues, ("%s: %s '%s' and '%s' are %.1f studs apart (min %g)"):format(where, what, a.name, b.name, flat, min))
			end
		end
	end
end

local function isPad(name: string): boolean
	return name == "RestockMat" or name:match("^KeeperSlot_") ~= nil or name:match("^HelperSlot_") ~= nil or name:match("^UpgradePad_") ~= nil
end

function StandLayout.CheckLevel(standId: string, level: number): { string }
	local issues = {}
	local where = ("%s Level %d"):format(standId, level)
	local stand = StandLayoutConfig.Stands[standId]
	local layout = stand and stand.Levels[level]
	if not layout then
		return { where .. ": not in StandLayoutConfig" }
	end
	local model = StandLayout.LevelModel(standId, level)
	if not model then
		return { ("%s: model ServerStorage.%s.%s.%s is missing"):format(where, StandLayoutConfig.ModelsFolder, standId, layout.Model) }
	end
	if not model.PrimaryPart then
		table.insert(issues, where .. ": model has no PrimaryPart (set it to the Base part)")
	end
	checkFolder(model, where, issues)
	local markers = StandLayout.Markers(model)
	local required: { [string]: boolean } = {}
	for _, name in StandLayoutConfig.RequiredLevelMarkers(layout) do
		required[name] = true
		if not markers[name] then
			table.insert(issues, ("%s: missing marker '%s'"):format(where, name))
		end
	end
	-- Numbered markers beyond what the config asks for (config and model disagree).
	for name in markers do
		local prefix, n = name:match("^(%a+)_(%d+)$")
		if prefix and n and not required[name] and prefix ~= "HelperPath" then
			table.insert(issues, ("%s: extra marker '%s' (config wants fewer %s)"):format(where, name, prefix))
		end
	end
	spacing(markers, isPad, StandLayoutConfig.MinPadSpacing, "pads", where, issues)
	spacing(markers, function(n)
		return n:match("^ServePoint_") ~= nil or n == "VipServePoint"
	end, StandLayoutConfig.MinServeSpacing, "serve points", where, issues)
	spacing(markers, function(n)
		return n:match("QueuePoint_") ~= nil
	end, StandLayoutConfig.MinQueueSpacing, "queue points", where, issues)
	-- Footprint: the model's size must fit the configured footprint.
	local _, size = model:GetBoundingBox()
	local fp = layout.Footprint
	local body = model:FindFirstChild("Body")
	if body and body:IsA("Model") then
		_, size = body:GetBoundingBox()
	end
	if size.X > fp.X + 0.5 or size.Z > fp.Z + 0.5 then
		table.insert(issues, ("%s: body is %.0f x %.0f studs, footprint allows %.0f x %.0f"):format(where, size.X, size.Z, fp.X, fp.Z))
	end
	return issues
end

function StandLayout.CheckSite(site: Instance, standId: string): { string }
	local issues = {}
	local where = site:GetFullName()
	local stand = StandLayoutConfig.Stands[standId]
	if not stand then
		return { where .. ": unknown stand id '" .. standId .. "'" }
	end
	if not site:FindFirstChild(StandLayoutConfig.AnchorName) then
		table.insert(issues, ("%s: no '%s' part"):format(where, StandLayoutConfig.AnchorName))
	end
	checkFolder(site, where, issues)
	for prefix, need in stand.SiteMarkers do
		local markers = StandLayout.Markers(site)
		local have = if markers[prefix] then 1 else StandLayout.Count(site, prefix)
		if have < need then
			table.insert(issues, ("%s: needs %d '%s' marker(s), has %d"):format(where, need, prefix, have))
		end
	end
	return issues
end

function StandLayout.CheckAll(warnThem: boolean?): { string }
	local all = {}
	for standId, stand in StandLayoutConfig.Stands do
		for level in stand.Levels do
			for _, issue in StandLayout.CheckLevel(standId, level) do
				table.insert(all, issue)
			end
		end
		local plots = workspace:FindFirstChild("Plots")
		for _, plot in if plots then plots:GetChildren() else {} do
			local site = StandLayout.Site(plot, standId)
			if not site then
				table.insert(all, ("%s: no site %s.%s"):format(plot:GetFullName(), StandLayoutConfig.SitesFolder, standId))
				continue
			end
			for _, issue in StandLayout.CheckSite(site, standId) do
				table.insert(all, issue)
			end
		end
	end
	if warnThem then
		for _, issue in all do
			warn("[StandLayout] " .. issue)
		end
	end
	return all
end

-- Placing -------------------------------------------------------------------------------------------

function StandLayout.Place(plot: Instance, standId: string, level: number): Model?
	local site = StandLayout.Site(plot, standId)
	local template = StandLayout.LevelModel(standId, level)
	local anchor = site and site:FindFirstChild(StandLayoutConfig.AnchorName) :: BasePart?
	if not (site and template and anchor and template.PrimaryPart) then
		warn(("[StandLayout] can't place %s level %d on %s"):format(standId, level, plot:GetFullName()))
		return nil
	end
	local old = site:FindFirstChild(StandLayoutConfig.PlacedName)
	if old then
		old:Destroy()
	end
	local model = template:Clone()
	model.Name = StandLayoutConfig.PlacedName
	model:SetAttribute("StandId", standId)
	model:SetAttribute("Level", level)
	model:PivotTo(anchor.CFrame)
	StandLayout.SetMarkersVisible(model, site:GetAttribute("DebugMarkers") == true)
	model.Parent = site
	return model
end

return StandLayout
