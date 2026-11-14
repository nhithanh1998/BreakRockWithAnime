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
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local MIN_ZONE, MAX_ZONE = 1, 10
local CHOP_FOLDER = "ChopGround" -- plot folder holding the current zone's chop-area decor
local MAP_FOLDER = "ZoneMap"
local SURFACE_FOLDER = "GroundSurface"
local SURFACE_TAG = "ZoneSurface" -- attribute on Ground children that the zone added
local CHECKER_TEXTURE = "rbxassetid://6372755229"
local STAGING_FOLDER = "ZoneStaging" -- ReplicatedStorage folder: the next layout waits here so clients preload it

local Layouts = ServerStorage:FindFirstChild("ZoneLayouts")
if not Layouts then
	Layouts = Instance.new("Folder")
	Layouts.Name = "ZoneLayouts"
	Layouts.Parent = ServerStorage
end

local Staging = ReplicatedStorage:FindFirstChild(STAGING_FOLDER)
if not Staging then
	Staging = Instance.new("Folder")
	Staging.Name = STAGING_FOLDER
	Staging.Parent = ReplicatedStorage
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
		defaults = {
			CFrame = ground.CFrame,
			Color = ground.Color,
			Material = ground.Material,
			Checker = checker and checker:Clone(),
		}
		groundDefaults[plot] = defaults
	end
	return defaults
end

-- Moves the Ground down by `depth` studs from the original floor.
local function applyDepth(plot, depth)
	local defaults = getDefaults(plot)
	plot.Floor.Ground.CFrame = CFrame.new(0, -depth, 0) * defaults.CFrame
	plot:SetAttribute("FloorDepth", depth)
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

-- Moves a cloned layout's folder contents into the plot folder (cleared first), all at once.
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

-- Zone each plot shows right now, so a swap back to it before the transition ran is skipped.
local appliedZone = {}

-- Rebuilds the chop area from the plot's "Zone" attribute at once (server start / new plots).
function ZoneService.Apply(plot)
	local info = prepare(plot)
	if not info then return end
	applyDepth(plot, info.depth)
	applyLighting(info.template)
	finish(plot, info)
	appliedZone[plot] = info.zone
end

-- Transition --------------------------------------------------------------------------------------
-- The server keeps the real state; ZoneTransitionFX on clients animates from these plot attributes:
--   SwapAt / SwapOutTime / LiftFromY
--                the old trees sink into the floor and fade, the old decor fades out (floor stays put).
--   LiftToY      the Ground's height in the new zone. Set before the new decor arrives (in batches), so
--                clients keep it hidden and place it on the floor as they show it.
--   LiftMoveAt / LiftMoveTime
--                the floor glides from LiftFromY to LiftToY (up or down, by the zone's depth) and the new
--                decor fades in. The real Ground only moves when the glide is over (so the server's own
--                replication never shows a jump on clients).
--   ZoneFreeze   true from SwapAt until the floor stops: players of this plot (owner + anyone standing on
--                the floor) can't move or chop meanwhile, and ride the floor.
--   ZoneInAt / ZoneInTime
--                set when the floor stops; the new trees grow out of it.
-- "ZoneBusy" is true from SwapAt until the floor stops; TreeService grows no trees meanwhile and refills
-- after, TreeHitService refuses hits. "HeroesHold" stays set IN_TIME longer: heroes (HeroWorkerService)
-- stop and idle where they stand, glued to the floor (they ride it on clients), then go back to work.
-- Only one transition runs per plot; a swap during one runs right after it, to the latest zone.

local OUT_TIME = 0.9
local MOVE_BASE = 0.8 -- seconds of floor glide, + MOVE_PER_STUD per stud of height change
local MOVE_PER_STUD = 0.05
local MOVE_MAX = 2.2
local IN_TIME = 1.6
local BATCH = 30 -- instances moved / destroyed per frame while swapping the map

local running = {}
local pending = {}

local function serverNow()
	return workspace:GetServerTimeNow()
end

local function waitUntil(serverTime)
	local left = serverTime - serverNow()
	if left > 0 then
		task.wait(left)
	end
end

-- Destroys a folder's contents a few per frame instead of all in one frame: at most BATCH instances or
-- CLEAR_PARTS parts per frame (a tree can have hundreds of parts; clients remove them all in that frame).
local CLEAR_PARTS = 600
local function clearBatched(folder)
	if not folder then return end
	local done, parts = 0, 0
	for _, child in ipairs(folder:GetChildren()) do
		if child.Parent == folder then
			for _, d in ipairs(child:GetDescendants()) do
				if d:IsA("BasePart") then parts += 1 end
			end
			child:Destroy()
			done += 1
			if done % BATCH == 0 or parts >= CLEAR_PARTS then
				parts = 0
				task.wait()
			end
		end
	end
end

-- Moves `source`'s contents into `target` a few per frame. Sub-folders are rebuilt one level at a time,
-- so one huge folder doesn't arrive in a single frame either.
local function moveBatched(source, target, counter)
	for _, child in ipairs(source:GetChildren()) do
		if child:IsA("Folder") and #child:GetChildren() > 0 then
			local folder = Instance.new("Folder")
			folder.Name = child.Name
			for k, v in pairs(child:GetAttributes()) do
				folder:SetAttribute(k, v)
			end
			folder.Parent = target
			moveBatched(child, folder, counter)
		else
			child.Parent = target
		end
		counter.n += 1
		if counter.n % BATCH == 0 then
			task.wait()
		end
	end
end

local function fillBatched(plot, folderName, source)
	local target = getFolder(plot, folderName)
	clearBatched(target)
	if source then
		moveBatched(source, target, { n = 0 })
	end
end

local function endTransition(plot)
	local staged = Staging:FindFirstChild(plot.Name)
	if staged then staged:Destroy() end
	if plot.Parent == nil then return end
	plot:SetAttribute("ZoneBusy", false)
	plot:SetAttribute("ZoneFreeze", false)
	plot:SetAttribute("HeroesHold", false)
end

local function runTransition(plot)
	local zone = plot:GetAttribute("Zone") or MIN_ZONE
	if appliedZone[plot] == zone then return end
	local info = prepare(plot)
	if not info then return end

	local ground = plot.Floor.Ground
	local fromY = ground.Position.Y

	-- 1. Old trees sink, old decor fades. Heroes idle, tree growth and chopping stop, players freeze.
	plot:SetAttribute("ZoneBusy", true)
	plot:SetAttribute("HeroesHold", true)
	plot:SetAttribute("ZoneFreeze", true)
	plot:SetAttribute("LiftMoveAt", nil)
	plot:SetAttribute("LiftToY", nil)
	plot:SetAttribute("LiftFromY", fromY)
	plot:SetAttribute("SwapOutTime", OUT_TIME)
	local startedAt = serverNow()
	plot:SetAttribute("SwapAt", startedAt) -- last: clients start on this one

	-- Meanwhile the new layout waits in ReplicatedStorage, so clients receive and preload it
	-- (ZoneTransitionFX) while the old trees go away, instead of when it has to show.
	local old = Staging:FindFirstChild(plot.Name)
	if old then old:Destroy() end
	info.layout.Name = plot.Name
	info.layout.Parent = Staging

	waitUntil(startedAt + OUT_TIME)
	if plot.Parent == nil then
		info.layout:Destroy()
		return
	end

	-- 2. Old map out, new ground look, new map in (hidden on clients) -- spread over frames.
	clearBatched(plot:FindFirstChild("TreeSpawns"))
	clearBatched(plot:FindFirstChild(CHOP_FOLDER))
	clearBatched(plot:FindFirstChild(MAP_FOLDER))
	applyLighting(info.template) -- clients tween to it (LightingController)
	plot:SetAttribute("ZoneName", info.template:GetAttribute("ZoneName") or ("Zone " .. info.zone))
	applyGround(plot, info.template, info.surface)
	local toY = (CFrame.new(0, -info.depth, 0) * getDefaults(plot).CFrame).Position.Y
	plot:SetAttribute("LiftToY", toY) -- before the new decor arrives: clients hide it
	if info.chop then
		fillBatched(plot, CHOP_FOLDER, info.chop)
	end
	local map = info.layout:FindFirstChild("Map")
	if map then
		fillBatched(plot, MAP_FOLDER, map)
	end
	info.layout:Destroy()
	appliedZone[plot] = info.zone
	if plot.Parent == nil then return end

	-- 3. The floor glides to its new height (clients animate it); the real Ground moves at the end.
	local moveTime = math.min(MOVE_BASE + math.abs(toY - fromY) * MOVE_PER_STUD, MOVE_MAX)
	plot:SetAttribute("LiftMoveTime", moveTime)
	plot:SetAttribute("LiftMoveAt", serverNow())
	task.wait(moveTime)
	if plot.Parent == nil then return end
	applyDepth(plot, info.depth)

	-- 4. Done: trees grow (TreeService), players move again; heroes go back to work once the trees have settled.
	plot:SetAttribute("ZoneInTime", IN_TIME)
	plot:SetAttribute("ZoneInAt", serverNow())
	plot:SetAttribute("ZoneBusy", false)
	plot:SetAttribute("ZoneFreeze", false)
	task.wait(IN_TIME)
	if plot.Parent ~= nil then
		plot:SetAttribute("HeroesHold", false)
	end
end

-- Plays the zone change. A change while one is playing is played right after it (latest zone only).
function ZoneService.Transition(plot)
	if running[plot] then
		pending[plot] = true
		return
	end
	running[plot] = true
	repeat
		pending[plot] = nil
		local ok, err = pcall(runTransition, plot)
		if not ok then
			warn("[ZoneService] transition failed: " .. tostring(err))
			endTransition(plot)
		end
	until not pending[plot] or plot.Parent == nil
	running[plot] = nil
	pending[plot] = nil
	if plot.Parent == nil then
		appliedZone[plot] = nil
		groundDefaults[plot] = nil
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
