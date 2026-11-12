-- ZoneService: swaps a plot's decoration layout + surrounding map when its zone changes.
--
-- Templates: ServerStorage.ZoneLayouts.ZoneN  (Model, PrimaryPart = "Anchor" at the plot floor center)
--   Anchor, Decor (folder), Map (folder)
-- Editing: put a ZoneN model in Workspace.ZoneEditing to see/edit it in Edit mode.
--   At runtime it replaces the copy in ZoneLayouts, so you never have to drag it back.
-- Optional template attributes: ZoneName, FloorColor, FloorTileColor, ClockTime, Ambient,
--   OutdoorAmbient, AtmosphereColor, AtmosphereDecay, AtmosphereDensity, AtmosphereHaze

local ServerStorage = game:GetService("ServerStorage")
local Lighting = game:GetService("Lighting")

local MIN_ZONE, MAX_ZONE = 1, 10
local LAYOUT_NAME = "CurrentLayout"
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

local function applyFloor(plot, template)
	local ground = plot.Floor.Ground
	local floorColor = template:GetAttribute("FloorColor")
	if floorColor then ground.Color = floorColor end
	local tileColor = template:GetAttribute("FloorTileColor")
	if tileColor then
		local checker = ground:FindFirstChild("Checker")
		if not checker then
			checker = Instance.new("Texture")
			checker.Name = "Checker"
			checker.Texture = CHECKER_TEXTURE
			checker.Face = Enum.NormalId.Top
			checker.StudsPerTileU = 8
			checker.StudsPerTileV = 8
			checker.Transparency = 0.35
			checker.Parent = ground
		end
		checker.Color3 = tileColor
	end
end

local function applyLighting(template)
	local function set(obj, prop, attr)
		local v = template:GetAttribute(attr)
		if v ~= nil then obj[prop] = v end
	end
	set(Lighting, "ClockTime", "ClockTime")
	set(Lighting, "Ambient", "Ambient")
	set(Lighting, "OutdoorAmbient", "OutdoorAmbient")
	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if atm then
		set(atm, "Color", "AtmosphereColor")
		set(atm, "Decay", "AtmosphereDecay")
		set(atm, "Density", "AtmosphereDensity")
		set(atm, "Haze", "AtmosphereHaze")
	end
end

-- Rebuilds the plot's layout from its "Zone" attribute.
function ZoneService.Apply(plot)
	local zone = plot:GetAttribute("Zone") or MIN_ZONE
	local template = Layouts:FindFirstChild("Zone" .. zone)
	if not template then
		warn(("[ZoneService] No layout for Zone%d"):format(zone))
		return
	end

	local old = plot:FindFirstChild(LAYOUT_NAME)
	if old then old:Destroy() end

	local layout = template:Clone()
	layout.Name = LAYOUT_NAME
	layout:PivotTo(plot.Floor.Ground.CFrame)
	layout.Parent = plot

	plot:SetAttribute("ZoneName", template:GetAttribute("ZoneName") or ("Zone " .. zone))
	applyFloor(plot, template)
	applyLighting(template)
end

-- Changes zone; ZoneLoader's attribute listener calls Apply.
function ZoneService.SetZone(plot, zone)
	plot:SetAttribute("Zone", math.clamp(math.floor(zone), MIN_ZONE, MAX_ZONE))
end

function ZoneService.NextZone(plot)
	ZoneService.SetZone(plot, (plot:GetAttribute("Zone") or MIN_ZONE) + 1)
end

return ZoneService
