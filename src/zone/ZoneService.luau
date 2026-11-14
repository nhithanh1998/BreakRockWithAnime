-- ZoneService: swaps the chop area's look (plot.Floor.Ground + plot.ChopGround) when the plot's zone changes.
-- Everything outside the chop area (plot.Decorations, plot.Land, ...) is never touched.
--
-- Templates: ServerStorage.ZoneLayouts.ZoneN  (Model, PrimaryPart = "Anchor" at the plot floor center)
--   Anchor            invisible part; snapped onto plot.Floor.Ground at runtime
--   ChopGround        (Folder) grass, leaves, rocks, edges... inside the chop area
--     GroundSurface   (Folder, optional) Texture / Decal / SurfaceAppearance put onto the Ground part
--   Map               (Folder, optional) extra pieces, placed the same way
--   FloorLevel        (Part, optional) where the floor sits in this zone: Ground moves to its height,
--                     so deeper zones = FloorLevel lower. Or use the number attribute FloorDepth (studs).
--                     Plot children with attribute FollowFloor = true (HeroGate) move down with the floor.
--   Positions in the template are relative to the plot's ORIGINAL floor, so walls placed in
--   ChopGround line up with both the rim (fixed) and the lowered floor.
-- Getting out of a deep floor: PitJump (client) raises the player's jump while they stand in the chop area.
-- Editing: put a ZoneN model in Workspace.ZoneEditing to see/edit it in Edit mode.
--   At runtime it replaces the copy in ZoneLayouts, so you never have to drag it back.
-- Optional template attributes: ZoneName, FloorColor, FloorMaterial (Enum.Material name), FloorTileColor,
--   ClockTime, Ambient, OutdoorAmbient, AtmosphereColor, AtmosphereDecay, AtmosphereDensity, AtmosphereHaze
-- A zone without an attribute gets the Ground's original value / the Clear lighting preset back.
-- The lighting ones are only used while there's no weather (LightingController, LightingPresets).

local ServerStorage = game:GetService("ServerStorage")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local MIN_ZONE, MAX_ZONE = 1, 10
local CHOP_FOLDER = "ChopGround" -- plot folder holding the current zone's chop-area decor
local MAP_FOLDER = "ZoneMap"
local SURFACE_FOLDER = "GroundSurface"
local SURFACE_TAG = "ZoneSurface" -- attribute on Ground children that the zone added
local CHECKER_TEXTURE = "rbxassetid://6372755229"

local Layouts = ServerStorage:FindFirstChild("ZoneLayouts")
if not Layouts then
	Layouts = Instance.new("Folder")
	Layouts.Name = "ZoneLayouts"
	Layouts.Parent = ServerStorage
end

local editing = workspace:FindFirstChild("ZoneEditing")
if editing then
	for _, template in ipairs(editing:GetChildren()) do
		local existing = Layouts:FindFirstChild(template.Name)
		if existing then existing:Destroy() end
		template.Parent = Layouts
	end
	editing:Destroy()
end

local ZoneService = {}

-- Original Ground look per plot, so zones that don't set something fall back to it.
local groundDefaults = {}

local function getFolder(plot, name)
	local f = plot:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = plot
	end
	return f
end

local function getDefaults(plot)
	local defaults = groundDefaults[plot]
	if not defaults then
		local ground = plot.Floor.Ground
		local checker = ground:FindFirstChild("Checker")
		local followers = {}
		for _, child in ipairs(plot:GetChildren()) do
			if child:GetAttribute("FollowFloor") and (child:IsA("Model") or child:IsA("BasePart")) then
				followers[child] = child:GetPivot()
			end
		end
		defaults = {
			CFrame = ground.CFrame,
			Color = ground.Color,
			Material = ground.Material,
			Checker = checker and checker:Clone(),
			Followers = followers,
		}
		groundDefaults[plot] = defaults
	end
	return defaults
end

-- Moves the Ground (and FollowFloor children) down by `depth` studs from the original floor.
local function applyDepth(plot, depth, moving)
	local defaults = getDefaults(plot)
	local offset = CFrame.new(0, -depth, 0)
	plot.Floor.Ground.CFrame = offset * defaults.CFrame
	for inst, pivot in pairs(defaults.Followers) do
		if inst.Parent then
			inst:PivotTo(offset * pivot)
		end
	end
	if not moving then
		plot:SetAttribute("FloorDepth", depth)
	end
end

local function applyGround(plot, template, surface)
	local ground = plot.Floor.Ground
	local defaults = getDefaults(plot)

	-- Clear what the previous zone put on the Ground.
	for _, child in ipairs(ground:GetChildren()) do
		if child:GetAttribute(SURFACE_TAG) or child.Name == "Checker" then
			child:Destroy()
		end
	end

	ground.Color = template:GetAttribute("FloorColor") or defaults.Color
	local matName = template:GetAttribute("FloorMaterial")
	local ok, mat = pcall(function()
		return Enum.Material[matName]
	end)
	ground.Material = if matName and ok and mat then mat else defaults.Material

	if surface and #surface:GetChildren() > 0 then
		for _, s in ipairs(surface:GetChildren()) do
			local c = s:Clone()
			c:SetAttribute(SURFACE_TAG, true)
			c.Parent = ground
		end
	else
		local tileColor = template:GetAttribute("FloorTileColor")
		local checker
		if tileColor then
			checker = Instance.new("Texture")
			checker.Texture = CHECKER_TEXTURE
			checker.Face = Enum.NormalId.Top
			checker.StudsPerTileU = 8
			checker.StudsPerTileV = 8
			checker.Transparency = 0.35
			checker.Color3 = tileColor
		elseif defaults.Checker then
			checker = defaults.Checker:Clone()
		end
		if checker then
			checker.Name = "Checker"
			checker.Parent = ground
		end
	end
end

-- The zone's lighting goes onto Lighting as "Zone<Attr>" attributes (nil = preset default);
-- LightingController (client) owns the real Lighting properties and tweens to them when the
-- weather is clear, so zones and weathers never fight over Lighting.
local ZONE_LIGHT_ATTRS = { "ClockTime", "Ambient", "OutdoorAmbient", "AtmosphereColor", "AtmosphereDecay", "AtmosphereDensity", "AtmosphereHaze" }

local function applyLighting(template)
	for _, attr in ipairs(ZONE_LIGHT_ATTRS) do
		Lighting:SetAttribute("Zone" .. attr, template:GetAttribute(attr))
	end
end

-- Moves a cloned layout's folder contents into the plot folder (cleared first).
local function fill(plot, folderName, source)
	local target = getFolder(plot, folderName)
	target:ClearAllChildren()
	if source then
		for _, child in ipairs(source:GetChildren()) do
			child.Parent = target
		end
	end
end

-- Zone template + a clone of it placed on the plot's original floor, and the zone's floor depth.
local function prepare(plot)
	local zone = plot:GetAttribute("Zone") or MIN_ZONE
	local template = Layouts:FindFirstChild("Zone" .. zone)
	if not template then
		warn(("[ZoneService] No layout for Zone%d"):format(zone))
		return nil
	end

	local base = getDefaults(plot).CFrame
	local layout = template:Clone()
	layout:PivotTo(base)

	local depth = template:GetAttribute("FloorDepth")
	local level = layout:FindFirstChild("FloorLevel")
	if level and level:IsA("BasePart") then
		depth = base.Position.Y - level.Position.Y
		level:Destroy()
	end
	depth = if typeof(depth) == "number" then math.max(depth, 0) else 0

	-- "Decor" is the old name of ChopGround; both work.
	local chop = layout:FindFirstChild("ChopGround") or layout:FindFirstChild("Decor")
	local surface = chop and chop:FindFirstChild(SURFACE_FOLDER)
	if surface then surface.Parent = nil end

	return {
		zone = zone,
		template = template,
		layout = layout,
		chop = chop,
		surface = surface,
		depth = depth,
	}
end

local function finish(plot, info)
	plot:SetAttribute("ZoneName", info.template:GetAttribute("ZoneName") or ("Zone " .. info.zone))
	applyGround(plot, info.template, info.surface)
	fill(plot, CHOP_FOLDER, info.chop)
	fill(plot, MAP_FOLDER, info.layout:FindFirstChild("Map"))
	info.layout:Destroy()
end

-- Rebuilds the chop area from the plot's "Zone" attribute at once (server start / new plots).
function ZoneService.Apply(plot)
	local info = prepare(plot)
	if not info then return end
	applyDepth(plot, info.depth)
	applyLighting(info.template)
	finish(plot, info)
end

-- Transition ------------------------------------------------------------------------------------
-- Phases (the server keeps the real state; ZoneTransitionFX on clients animates from attributes):
--   1. Out:   plot "ZoneOutAt"/"ZoneOutTime" -> old trees + decor sink and fade, then are removed.
--   2. Floor: "FloorMoveAt"/"FloorMoveTime"/"FloorFromY"/"FloorToY"/"FloorToColor" -> the floor glides
--             to the new depth (the server moves it too, so heroes and players ride along).
--   3. In:    "ZoneInAt"/"ZoneInTime" -> new decor and trees rise out of the floor.
-- "ZoneBusy" is true from 1 until 3 starts; TreeService grows no trees meanwhile and refills after, and
-- heroes (HeroWorkerService) hide in the HeroGate meanwhile and walk back out after. Phase 2 waits for
-- the plot's "HeroesOutside" to reach 0. "HeroesHold" is true from 1 until phase 3 has finished
-- (heroes stay in the gate while that is set).

local OUT_TIME = 0.9
local HERO_WAIT_MAX = 3 -- extra seconds the floor waits for heroes to get back into the gate
local FLOOR_MIN_TIME, FLOOR_PER_STUD, FLOOR_MAX_TIME = 0.6, 0.06, 2
local IN_TIME = 1.6

local tokens = {}

local function ease(t)
	return t * t * (3 - 2 * t) -- smoothstep
end

local function serverNow()
	return workspace:GetServerTimeNow()
end

local function clearFolder(plot, name)
	local f = plot:FindFirstChild(name)
	if f then f:ClearAllChildren() end
end

-- Plays the zone change; a newer change cancels an older one at its next step.
function ZoneService.Transition(plot)
	local token = (tokens[plot] or 0) + 1
	tokens[plot] = token
	local function alive()
		return tokens[plot] == token and plot.Parent ~= nil
	end

	local info = prepare(plot)
	if not info then return end
	local defaults = getDefaults(plot)
	local ground = plot.Floor.Ground

	-- 1. Out
	plot:SetAttribute("ZoneBusy", true)
	plot:SetAttribute("HeroesHold", true)
	plot:SetAttribute("ZoneOutTime", OUT_TIME)
	plot:SetAttribute("ZoneOutAt", serverNow())
	task.wait(OUT_TIME)
	-- Heroes run back into the HeroGate meanwhile (HeroWorkerService); the floor waits for them.
	local waitStart = os.clock()
	while (plot:GetAttribute("HeroesOutside") or 0) > 0 and os.clock() - waitStart < HERO_WAIT_MAX do
		if not alive() then break end
		task.wait(0.1)
	end
	if not alive() then info.layout:Destroy() return end
	clearFolder(plot, "TreeSpawns")
	clearFolder(plot, CHOP_FOLDER)
	clearFolder(plot, MAP_FOLDER)

	-- 2. Floor
	applyLighting(info.template) -- clients tween to it (LightingController)
	local fromY = ground.Position.Y
	local toY = defaults.CFrame.Position.Y - info.depth
	local dist = math.abs(toY - fromY)
	local duration = math.clamp(FLOOR_MIN_TIME + dist * FLOOR_PER_STUD, FLOOR_MIN_TIME, FLOOR_MAX_TIME)
	local fromDepth = defaults.CFrame.Position.Y - fromY
	plot:SetAttribute("FloorFromY", fromY)
	plot:SetAttribute("FloorToY", toY)
	plot:SetAttribute("FloorToColor", info.template:GetAttribute("FloorColor") or defaults.Color)
	plot:SetAttribute("FloorMoveTime", duration)
	plot:SetAttribute("FloorMoveAt", serverNow())
	local start = os.clock()
	while true do
		local t = math.min((os.clock() - start) / duration, 1)
		if not alive() then info.layout:Destroy() return end
		if dist > 0.01 then
			applyDepth(plot, fromDepth + (info.depth - fromDepth) * ease(t), true)
		end
		if t >= 1 then break end
		RunService.Heartbeat:Wait()
	end
	applyDepth(plot, info.depth)

	-- 3. In
	plot:SetAttribute("ZoneInTime", IN_TIME)
	plot:SetAttribute("ZoneInAt", serverNow())
	finish(plot, info)
	plot:SetAttribute("ZoneBusy", false) -- TreeService grows the new zone's trees now

	-- Heroes come back out once the new decor and trees have settled.
	task.wait(IN_TIME)
	if alive() then
		plot:SetAttribute("HeroesHold", false)
	end
end

-- Changes zone; ZoneLoader's attribute listener plays the transition.
function ZoneService.SetZone(plot, zone)
	plot:SetAttribute("Zone", math.clamp(math.floor(zone), MIN_ZONE, MAX_ZONE))
end

function ZoneService.NextZone(plot)
	ZoneService.SetZone(plot, (plot:GetAttribute("Zone") or MIN_ZONE) + 1)
end

return ZoneService
