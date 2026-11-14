-- FruitModels: builds the 3D pieces of the Devil Fruit feature from parts (server and client).
--
--   FruitModels.Fruit(def, size)   -> Model: Devil Fruit of 6 ridged lobes (alternating shades of
--                                     def.Color) with a curled def.Swirl line on each, a curled stem
--                                     and two leaves. Pivot = its center. ~95 parts.
--   FruitModels.Greenhouse(w, d, h) -> Model: walk-in studded-wood greenhouse (glass walls / roof,
--                                     double door, sign, lanterns, plants, fireflies) around the
--                                     planter (FruitService adds it to every DevilGarden).
--   FruitModels.Garden(size?)      -> Model "DevilGarden" (size = outer width in studs, default 14): voxel planter (frame, posts with glowing
--                                     caps, soil "Bed", dirt mound) + sign. Pivot = ground center,
--                                     front = -Z of the pivot. The tree grows on top of "Bed".
--   FruitModels.Tree(def)          -> Model: a small devil tree (trunk + leaf blocks) whose pivot is
--                                     the bottom of the trunk, ~9 studs tall at scale 1.
--   FruitModels.Bag()              -> Model: a fertilizer bag (for the cutscene / icons).

local FruitModels = {}

local function part(props: { [string]: any }): BasePart
	local p = Instance.new(props.ClassName or "Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		if k ~= "ClassName" and k ~= "Parent" then
			(p :: any)[k] = v
		end
	end
	if props.Parent then
		p.Parent = props.Parent
	end
	return p
end

-- Fruit ---------------------------------------------------------------------------------------------

local function ellipsoid(props: { [string]: any }): BasePart
	local p = part(props)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	return p
end

local LOBES = 6

-- Devil Fruit: LOBES ridged lobes (alternating light / dark shade, so every segment reads crisply)
-- around a core, each lobe carrying a curled swirl in def.Swirl, a pale ring on top and a curled green
-- stem with two leaves. ~s wide, ~1.1 s tall (+ stem). Pivot = its center.
function FruitModels.Fruit(def: any, size: number?): Model
	local s = size or 2
	local model = Instance.new("Model")
	model.Name = def.Id or "Fruit"
	local light = def.Color:Lerp(Color3.new(1, 1, 1), 0.12)
	local dark = def.Color:Lerp(Color3.new(0, 0, 0), 0.1)
	local swirl = def.Swirl

	local core = ellipsoid({
		Name = "Body",
		Size = Vector3.new(s * 0.86, s * 0.98, s * 0.86),
		Color = dark,
		Material = Enum.Material.SmoothPlastic,
		Parent = model,
	})
	model.PrimaryPart = core

	-- Lobe radii (lobe space: X = outward, Y = up, Z = sideways) and distance from the axis.
	local rx, ry, rz = s * 0.25, s * 0.5, s * 0.29
	local dist = s * 0.26
	for i = 0, LOBES - 1 do
		local a = i / LOBES * math.pi * 2
		local frame = CFrame.Angles(0, -a, 0) * CFrame.new(dist, 0, 0) -- lobe center, X pointing out
		ellipsoid({
			Name = "Lobe",
			Size = Vector3.new(rx * 2, ry * 2, rz * 2),
			Color = if i % 2 == 0 then light else def.Color,
			Material = Enum.Material.SmoothPlastic,
			CFrame = frame,
			Parent = model,
		})
		-- Swirl: a line curling in to the lobe's middle ("@"), lying on its surface, thinning as it goes.
		local points: { Vector3 } = {}
		local normals: { Vector3 } = {}
		local steps = 13
		for k = 0, steps do
			local f = k / steps
			local theta = f * math.pi * 3 + (if i % 2 == 0 then 0 else math.pi)
			local r = 0.66 * (1 - f * 0.88)
			local y = math.cos(theta) * r * 0.62 + 0.04 -- in units of the lobe radius
			local z = math.sin(theta) * r * 0.82
			local x = math.sqrt(math.max(0.02, 1 - y * y - z * z))
			points[k] = Vector3.new(x * rx, y * ry, z * rz)
			normals[k] = Vector3.new(x / rx, y / ry, z / rz).Unit
		end
		for k = 0, steps - 1 do
			local p0, p1 = points[k], points[k + 1]
			local mid = (p0 + p1) / 2 + normals[k] * s * 0.008
			local w = s * (0.075 - (k / steps) * 0.035)
			part({
				Name = "Swirl",
				Size = Vector3.new(w, s * 0.025, (p1 - p0).Magnitude + w * 0.8),
				Color = swirl,
				Material = Enum.Material.SmoothPlastic,
				-- Z along the line, Y = the surface normal (lies flat on the lobe).
				CFrame = frame * CFrame.lookAt(mid, p1 + normals[k] * s * 0.008, normals[k]),
				Parent = model,
			})
		end
	end

	-- Pale dimple ring on top where the stem comes out.
	part({
		Name = "TopRing",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(s * 0.06, s * 0.36, s * 0.36),
		Color = light:Lerp(Color3.new(1, 1, 1), 0.25),
		Material = Enum.Material.SmoothPlastic,
		CFrame = CFrame.new(0, s * 0.5, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Parent = model,
	})
	-- Curled stem: a few short segments bending over.
	local stemColor = Color3.fromRGB(90, 190, 80)
	local at = CFrame.new(0, s * 0.5, 0)
	for k = 0, 3 do
		local seg = s * 0.11
		at = at * CFrame.Angles(0, 0, math.rad(if k == 0 then 8 else 28))
		part({
			Name = "Stem",
			Size = Vector3.new(s * 0.075, seg, s * 0.075),
			Color = stemColor:Lerp(Color3.new(0, 0, 0), k * 0.06),
			Material = Enum.Material.SmoothPlastic,
			CFrame = at * CFrame.new(0, seg / 2, 0),
			Parent = model,
		})
		at = at * CFrame.new(0, seg * 0.9, 0)
	end
	-- Two leaves: flat ellipsoids tilted out from the stem, with a darker centre vein.
	local leafColor = Color3.fromRGB(110, 215, 90)
	for _, yaw in { 40, -150 } do
		local base = CFrame.new(0, s * 0.53, 0) * CFrame.Angles(0, math.rad(yaw), 0) * CFrame.Angles(math.rad(26), 0, math.rad(8))
		local len, wid = s * 0.42, s * 0.2
		local leafCf = base * CFrame.new(0, 0, -len / 2)
		ellipsoid({ Name = "Leaf", Size = Vector3.new(wid, s * 0.035, len), Color = leafColor, Material = Enum.Material.SmoothPlastic, CFrame = leafCf, Parent = model })
		part({ Name = "Vein", Size = Vector3.new(s * 0.02, s * 0.04, len * 0.8), Color = leafColor:Lerp(Color3.new(0, 0, 0), 0.3), Material = Enum.Material.SmoothPlastic, CFrame = leafCf * CFrame.new(0, s * 0.006, 0), Parent = model })
	end
	return model
end

-- Devil tree ------------------------------------------------------------------------------------------

function FruitModels.Tree(def: any?): Model
	local model = Instance.new("Model")
	model.Name = "DevilTree"
	local bark = Color3.fromRGB(120, 80, 50)
	local leaf = if def then def.Color:Lerp(Color3.fromRGB(60, 200, 90), 0.65) else Color3.fromRGB(60, 210, 110)
	local root = part({ Name = "Root", Size = Vector3.new(0.2, 0.2, 0.2), Transparency = 1, CFrame = CFrame.new(), Parent = model })
	model.PrimaryPart = root
	-- Trunk: stacked blocks, a little crooked.
	for i = 0, 4 do
		part({
			Name = "Trunk",
			Size = Vector3.new(1.6 - i * 0.12, 1.6, 1.6 - i * 0.12),
			Color = bark:Lerp(Color3.new(0, 0, 0), i * 0.04),
			Material = Enum.Material.Wood,
			CFrame = CFrame.new(math.sin(i * 0.9) * 0.25, 0.8 + i * 1.5, 0) * CFrame.Angles(0, math.rad(i * 9), 0),
			Parent = model,
		})
	end
	-- Crown: leaf blocks around the top.
	local crown = {
		Vector3.new(0, 8.4, 0), Vector3.new(2, 7.6, 0.4), Vector3.new(-2, 7.7, -0.3), Vector3.new(0.3, 7.5, 2),
		Vector3.new(-0.4, 7.6, -2), Vector3.new(1.4, 9.1, -1.2), Vector3.new(-1.3, 9, 1.3), Vector3.new(0, 10, 0),
	}
	for i, pos in crown do
		part({
			Name = "Leaves",
			Size = Vector3.one * (if i == 1 then 3.2 else 2.4),
			Color = leaf:Lerp(Color3.new(1, 1, 1), (i % 3) * 0.08),
			Material = Enum.Material.SmoothPlastic,
			CFrame = CFrame.new(pos) * CFrame.Angles(0, math.rad(i * 23), math.rad(i * 7)),
			Parent = model,
		})
	end
	return model
end

-- Fertilizer bag ------------------------------------------------------------------------------------

function FruitModels.Bag(): Model
	local model = Instance.new("Model")
	model.Name = "FertilizerBag"
	local sack = part({
		Name = "Sack",
		Size = Vector3.new(1.6, 2, 1),
		Color = Color3.fromRGB(150, 95, 200),
		Material = Enum.Material.Fabric,
		Parent = model,
	})
	model.PrimaryPart = sack
	part({ Name = "Neck", Size = Vector3.new(0.9, 0.4, 0.7), Color = Color3.fromRGB(120, 70, 170), Material = Enum.Material.Fabric, CFrame = CFrame.new(0, 1.15, 0), Parent = model })
	part({ Name = "Tie", Size = Vector3.new(1, 0.15, 0.8), Color = Color3.fromRGB(255, 210, 60), Material = Enum.Material.SmoothPlastic, CFrame = CFrame.new(0, 1, 0), Parent = model })
	local label = part({ Name = "Label", Size = Vector3.new(1, 0.9, 0.05), Color = Color3.fromRGB(110, 230, 120), Material = Enum.Material.SmoothPlastic, CFrame = CFrame.new(0, -0.1, -0.52), Parent = model })
	-- A swirl dot on the label (the fruit pattern).
	part({ Name = "Swirl", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.05, 0.5, 0.5), Color = Color3.fromRGB(40, 120, 60), CFrame = label.CFrame * CFrame.new(0, 0, -0.04) * CFrame.Angles(0, math.rad(90), 0), Parent = model })
	return model
end

-- Garden (planter on the plot) ------------------------------------------------------------------------

local FRAME = Color3.fromRGB(245, 200, 80)
local FRAME_DARK = Color3.fromRGB(215, 160, 60)
local SOIL = Color3.fromRGB(70, 50, 45)
local DIRT = Color3.fromRGB(125, 80, 60)
local GLOW = Color3.fromRGB(90, 255, 220)

local function studs(p: BasePart)
	p.TopSurface = Enum.SurfaceType.Studs
end

function FruitModels.Garden(size: number?): Model
	local model = Instance.new("Model")
	model.Name = "DevilGarden"
	local W = size or 14 -- outer size
	local H = 1.6 -- frame height
	local T = 1.4 -- frame thickness

	local base = part({ Name = "Base", Size = Vector3.new(W, 0.4, W), Color = FRAME_DARK, Material = Enum.Material.SmoothPlastic, CFrame = CFrame.new(0, 0.2, 0), CanCollide = true, CanQuery = true, Parent = model })
	model.PrimaryPart = base
	-- Frame: four walls.
	for _, side in { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } } do
		local alongX = side[1] == 0
		local wall = part({
			Name = "Frame",
			Size = if alongX then Vector3.new(W, H, T) else Vector3.new(T, H, W - T * 2),
			Color = FRAME,
			Material = Enum.Material.SmoothPlastic,
			CFrame = CFrame.new(side[1] * (W - T) / 2, H / 2 + 0.4, side[2] * (W - T) / 2),
			CanCollide = true,
			CanQuery = true,
			Parent = model,
		})
		studs(wall)
	end
	-- Soil bed inside the frame (the tree grows on top of it).
	local bed = part({
		Name = "Bed",
		Size = Vector3.new(W - T * 2, H - 0.3, W - T * 2),
		Color = SOIL,
		Material = Enum.Material.Ground,
		CFrame = CFrame.new(0, (H - 0.3) / 2 + 0.4, 0),
		CanCollide = true,
		CanQuery = true,
		Parent = model,
	})
	-- Dirt mound in the middle.
	part({ Name = "Mound", Size = Vector3.new(4, 0.6, 4), Color = DIRT, Material = Enum.Material.Ground, CFrame = bed.CFrame * CFrame.new(0, bed.Size.Y / 2 + 0.3, 0), Parent = model })
	part({ Name = "Mound", Size = Vector3.new(2.4, 0.5, 2.4), Color = DIRT:Lerp(Color3.new(0, 0, 0), 0.1), Material = Enum.Material.Ground, CFrame = bed.CFrame * CFrame.new(0, bed.Size.Y / 2 + 0.85, 0), Parent = model })
	-- Corner posts with glowing caps.
	for _, c in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local x, z = c[1] * (W / 2 - 0.9), c[2] * (W / 2 - 0.9)
		local post = part({ Name = "Post", Size = Vector3.new(1.8, 3.2, 1.8), Color = FRAME, Material = Enum.Material.SmoothPlastic, CFrame = CFrame.new(x, 2, z), CanCollide = true, CanQuery = true, Parent = model })
		studs(post)
		local cap = part({ Name = "Cap", Size = Vector3.new(1.2, 1.2, 1.2), Color = GLOW, Material = Enum.Material.Neon, CFrame = CFrame.new(x, 4.2, z) * CFrame.Angles(0, math.rad(45), 0), Parent = model })
		local light = Instance.new("PointLight")
		light.Color = GLOW
		light.Range = 8
		light.Brightness = 1.2
		light.Parent = cap
	end
	-- Sign in front (front = -Z).
	local sign = part({ Name = "SignAnchor", Size = Vector3.new(0.2, 0.2, 0.2), Transparency = 1, CFrame = CFrame.new(0, 7.5, 0), Parent = model })
	local gui = Instance.new("BillboardGui")
	gui.Name = "Sign"
	gui.Size = UDim2.fromScale(10, 2.6)
	gui.LightInfluence = 0
	gui.MaxDistance = 120
	gui.Parent = sign
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(1, 0.65)
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.Text = "DEVIL TREE"
	title.TextColor3 = Color3.fromRGB(190, 120, 255)
	title.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(30, 10, 50)
	stroke.Parent = title
	local sub = title:Clone()
	sub.Name = "Sub"
	sub.Position = UDim2.fromScale(0, 0.62)
	sub.Size = UDim2.fromScale(1, 0.38)
	sub.Text = "Grow Devil Fruits!"
	sub.TextColor3 = Color3.new(1, 1, 1)
	sub.Parent = gui
	-- Prompt anchor in the middle of the front wall.
	part({ Name = "PromptPart", Size = Vector3.new(1, 1, 1), Transparency = 1, CFrame = CFrame.new(0, 2, -(W / 2)), Parent = model })
	return model
end

-- Greenhouse (walk-in, around the planter) -------------------------------------------------------------

local WOOD = Color3.fromRGB(214, 128, 58) -- warm natural pine, studded
local WOOD_DARK = Color3.fromRGB(160, 92, 45)
local WOOD_BROWN = Color3.fromRGB(115, 75, 50) -- planter boxes / pots
local GLASS = Color3.fromRGB(195, 232, 248) -- milky light-blue panes
local TILE = Color3.fromRGB(196, 122, 92) -- terracotta floor
local LEAF = Color3.fromRGB(70, 175, 95)
local LEAF_LIGHT = Color3.fromRGB(110, 200, 110)
local BUD = Color3.fromRGB(235, 255, 170) -- soft glowing buds
local WARM = Color3.fromRGB(255, 205, 140) -- lantern light
local IRON = Color3.fromRGB(45, 45, 50)

local function studsAll(p: BasePart)
	p.TopSurface = Enum.SurfaceType.Studs
	p.FrontSurface = Enum.SurfaceType.Studs
	p.BackSurface = Enum.SurfaceType.Studs
	p.LeftSurface = Enum.SurfaceType.Studs
	p.RightSurface = Enum.SurfaceType.Studs
end

-- Model "Greenhouse": a walk-in studded-wood greenhouse with milky glass walls, a pitched glass roof
-- (ridge along Z, so the front is a tall gable), a double door that opens (models "DoorLeft" /
-- "DoorRight", see FruitUI), a "DEVIL GARDEN" board with two lanterns, planter boxes and steps out
-- front, vine columns, hanging pots, a tiled floor and a few fireflies.
-- `width` = outer X, `depth` = outer Z, `height` = wall height (ridge = height + width * 0.32).
-- Pivot = floor center (floor top = 0, the ground outside is expected ~1 stud lower), front = -Z.
-- Front-side parts have the attribute Front = true (the cutscene hides them locally).
-- Attribute RoofTop = height of the ridge above the pivot.
function FruitModels.Greenhouse(width: number, depth: number, height: number): Model
	local model = Instance.new("Model")
	model.Name = "Greenhouse"
	local W, D, H = width, depth, height
	local P = 1.4 -- post / beam thickness
	local R = W * 0.32 -- roof rise
	local hx, hz = W / 2, D / 2
	local DW, DH = 8, 10.5 -- door opening
	local root = part({ Name = "Root", Size = Vector3.one * 0.2, Transparency = 1, CFrame = CFrame.new(), Parent = model })
	model.PrimaryPart = root
	model:SetAttribute("RoofTop", H + R)

	local function mark(p: Instance, front: boolean?)
		if front then
			p:SetAttribute("Front", true)
		end
	end
	local function block(name: string, size: Vector3, cf: CFrame, color: Color3, props: { [string]: any }?, front: boolean?, parent: Instance?): BasePart
		local p = part({ Name = name, Size = size, CFrame = cf, Color = color, Material = Enum.Material.SmoothPlastic, Parent = parent or model })
		studsAll(p)
		for k, v in props or {} do
			(p :: any)[k] = v
		end
		mark(p, front)
		return p
	end
	local function wood(name: string, size: Vector3, cf: CFrame, front: boolean?, dark: boolean?): BasePart
		return block(name, size, cf, if dark then WOOD_DARK else WOOD, { CanCollide = true }, front)
	end
	local function glass(name: string, size: Vector3, cf: CFrame, front: boolean?, className: string?): BasePart
		local p = part({
			Name = name,
			ClassName = className,
			Size = size,
			CFrame = cf,
			Color = GLASS,
			Material = Enum.Material.SmoothPlastic,
			Transparency = 0.55,
			Reflectance = 0.08,
			CastShadow = false,
			CanCollide = true,
			Parent = model,
		})
		studsAll(p)
		mark(p, front)
		return p
	end
	-- Roof height above the floor at a given x (under the slopes).
	local function roofAt(x: number): number
		return H + R * (1 - math.abs(x) / hx)
	end

	-- Floor: terracotta tiles (top = 0) + one wooden step out the front door.
	block("Floor", Vector3.new(W, 1, D), CFrame.new(0, -0.55, 0), TILE, { CanCollide = true })
	block("Step", Vector3.new(DW + 3, 0.5, 2.4), CFrame.new(0, -0.8, -hz - 1.2), WOOD_DARK, { CanCollide = true }, true)

	-- Walls: posts at `stops` along one side, a bottom + top beam, glass panes between the posts
	-- (the bay between door[1] and door[2] is left open for the door).
	local function wallRun(alongX: boolean, fixed: number, stops: { number }, front: boolean, door: { number }?)
		local function at(s: number, y: number): Vector3
			return if alongX then Vector3.new(s, y, fixed) else Vector3.new(fixed, y, s)
		end
		local function sized(len: number, y: number, thick: number): Vector3
			return if alongX then Vector3.new(len, y, thick) else Vector3.new(thick, y, len)
		end
		for _, s in stops do
			wood("Post", Vector3.new(P, H, P), CFrame.new(at(s, H / 2)), front)
		end
		local first, last = stops[1], stops[#stops]
		wood("Beam", sized(last - first + P, P, P), CFrame.new(at((first + last) / 2, H - P / 2)), front)
		for i = 1, #stops - 1 do
			local a, b = stops[i], stops[i + 1]
			local len = b - a - P
			local mid = (a + b) / 2
			if door and a == door[1] and b == door[2] then
				-- Lintel + glass transom over the door.
				wood("Lintel", sized(len, P, P), CFrame.new(at(mid, DH + P / 2)), front)
				glass("Transom", sized(len, H - P - DH - P, 0.3), CFrame.new(at(mid, (DH + P + H - P) / 2)), front)
			else
				wood("Sill", sized(len, P, P), CFrame.new(at(mid, P / 2)), front, true)
				glass("Glass", sized(len, H - P * 2, 0.3), CFrame.new(at(mid, H / 2)), front)
			end
		end
	end
	local ix, iz = hx - P / 2, hz - P / 2 -- post centerlines
	local doorX = DW / 2 + P / 2
	wallRun(true, -iz, { -ix, -(ix + doorX) / 2, -doorX, doorX, (ix + doorX) / 2, ix }, true, { -doorX, doorX })
	wallRun(true, iz, { -ix, -ix / 2, 0, ix / 2, ix }, false)
	local sideStops = { -iz, -iz / 3, iz / 3, iz }
	wallRun(false, -ix, sideStops, false)
	wallRun(false, ix, sideStops, false)

	-- Roof: ridge along Z, two glass slopes with rafters over every post line, glass gables front & back.
	local slopeLen = math.sqrt(hx * hx + R * R) + 1
	local tilt = math.atan2(R, hx)
	wood("Ridge", Vector3.new(P, P, D + 1.6), CFrame.new(0, H + R, 0))
	for _, dir in { -1, 1 } do
		local cf = CFrame.new(dir * hx / 2, H + R / 2, 0) * CFrame.Angles(0, 0, -dir * tilt) * CFrame.new(dir * 0.5, 0, 0)
		glass("RoofGlass", Vector3.new(slopeLen, 0.3, D), cf)
		for _, z in { -iz - 0.4, -iz / 3, iz / 3, iz + 0.4 } do
			wood("Rafter", Vector3.new(slopeLen, P, P), cf * CFrame.new(0, 0.5, z), z < -iz + 0.1)
		end
	end
	for _, zSide in { -1, 1 } do
		local z = zSide * iz
		local front = zSide == -1
		glass("Gable", Vector3.new(0.3, R, hx), CFrame.new(-hx / 2, H + R / 2, z) * CFrame.Angles(0, math.rad(90), 0), front, "WedgePart")
		glass("Gable", Vector3.new(0.3, R, hx), CFrame.new(hx / 2, H + R / 2, z) * CFrame.Angles(0, math.rad(-90), 0), front, "WedgePart")
		-- Two studs in the gable, over the door posts.
		for _, x in { -doorX, doorX } do
			local top = roofAt(x)
			wood("GableStud", Vector3.new(P, top - H, P), CFrame.new(x, (H + top) / 2, z), front)
		end
	end
	-- Ridge finials.
	for _, zSide in { -1, 1 } do
		wood("Finial", Vector3.new(1.6, 1.6, 1.6), CFrame.new(0, H + R + 1, zSide * (hz + 0.4)) * CFrame.Angles(0, math.rad(45), 0), zSide == -1, true)
	end

	-- Board over the door: "DEVIL GARDEN".
	local boardCf = CFrame.new(0, H + 1.4, -hz - 0.3)
	wood("BoardFrame", Vector3.new(15, 4, 0.5), boardCf * CFrame.new(0, 0, 0.3), true, true)
	local board = block("Board", Vector3.new(14, 3.2, 0.4), boardCf, Color3.fromRGB(40, 62, 70), nil, true)
	local surface = Instance.new("SurfaceGui")
	surface.Name = "BoardText"
	surface.Face = Enum.NormalId.Front
	surface.LightInfluence = 0
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.PixelsPerStud = 40
	surface.Parent = board
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 1)
	text.Font = Enum.Font.FredokaOne
	text.TextSize = 86
	text.Text = "DEVIL GARDEN"
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Parent = surface
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(150, 225, 255))
	grad.Rotation = 90
	grad.Parent = text
	local textStroke = Instance.new("UIStroke")
	textStroke.Color = Color3.fromRGB(15, 35, 55)
	textStroke.Thickness = 4
	textStroke.Parent = text

	-- Two lanterns hanging under the board.
	for _, x in { -2.8, 2.8 } do
		local top = H - P
		part({ Name = "Chain", Size = Vector3.new(0.2, 1.6, 0.2), Color = IRON, Material = Enum.Material.Metal, CFrame = CFrame.new(x, top - 0.8, -iz - 0.9), Parent = model }):SetAttribute("Front", true)
		local lcf = CFrame.new(x, top - 2.7, -iz - 0.9)
		block("LanternCap", Vector3.new(1.6, 0.4, 1.6), lcf * CFrame.new(0, 1.3, 0), IRON, nil, true)
		block("LanternBase", Vector3.new(1.4, 0.4, 1.4), lcf * CFrame.new(0, -1.3, 0), IRON, nil, true)
		for _, c in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
			part({ Name = "LanternBar", Size = Vector3.new(0.2, 2.3, 0.2), Color = IRON, Material = Enum.Material.Metal, CFrame = lcf * CFrame.new(c[1] * 0.6, 0, c[2] * 0.6), Parent = model }):SetAttribute("Front", true)
		end
		local flame = part({ Name = "LanternLight", Size = Vector3.new(1, 2, 1), Color = WARM, Material = Enum.Material.Neon, Transparency = 0.1, CastShadow = false, CFrame = lcf, Parent = model })
		flame:SetAttribute("Front", true)
		local light = Instance.new("PointLight")
		light.Color = WARM
		light.Range = 14
		light.Brightness = 1.2
		light.Parent = flame
	end

	-- Double door (hinged on the door posts, opens outwards). FruitUI swings it open when you come close.
	local inner = DW / 2 - 0.05
	local leafW, leafH, leafT = inner - 0.1, DH - 0.2, 0.4
	for _, side in { -1, 1 } do
		local leaf = Instance.new("Model")
		leaf.Name = if side == -1 then "DoorLeft" else "DoorRight"
		local hingeCf = CFrame.new(side * inner, 0, -iz)
		local hinge = part({ Name = "Hinge", Size = Vector3.one * 0.2, Transparency = 1, CFrame = hingeCf, Parent = leaf })
		leaf.PrimaryPart = hinge
		leaf:SetAttribute("OpenDir", -side) -- +1 = turn left leaf so it swings out (towards -Z)
		mark(leaf, true)
		local out = -side -- leaf extends from the hinge towards the middle
		local function lp(name: string, size: Vector3, x: number, y: number, color: Color3, isGlass: boolean?)
			local p = block(name, size, hingeCf * CFrame.new(out * x, y, 0), color, if isGlass then { Transparency = 0.5, CastShadow = false } else nil, true, leaf)
			return p
		end
		lp("Stile", Vector3.new(0.8, leafH, leafT), 0.4, leafH / 2 + 0.1, WOOD)
		lp("Stile", Vector3.new(0.8, leafH, leafT), leafW - 0.4, leafH / 2 + 0.1, WOOD)
		lp("Rail", Vector3.new(leafW - 1.6, 0.8, leafT), leafW / 2, 0.5, WOOD)
		lp("Rail", Vector3.new(leafW - 1.6, 0.8, leafT), leafW / 2, leafH * 0.4, WOOD)
		lp("Rail", Vector3.new(leafW - 1.6, 0.8, leafT), leafW / 2, leafH - 0.3, WOOD)
		lp("Panel", Vector3.new(leafW - 1.6, leafH * 0.4 - 1.2, leafT * 0.6), leafW / 2, leafH * 0.2 + 0.3, WOOD_DARK)
		lp("DoorGlass", Vector3.new(leafW - 1.6, leafH * 0.6 - 1.3, 0.2), leafW / 2, leafH * 0.7 - 0.05, GLASS, true)
		local handle = lp("Handle", Vector3.new(0.25, 1.2, 0.35), leafW - 1.1, leafH * 0.45, IRON)
		handle.CFrame = handle.CFrame * CFrame.new(0, 0, -0.35)
		for _, d in leaf:GetDescendants() do
			if d:IsA("BasePart") then
				d.CanCollide = false
			end
		end
		leaf.Parent = model
	end

	-- Planter boxes either side of the step, with little sprouts (a few with glowing buds).
	local function sprout(at: CFrame, tall: number, glow: boolean, front: boolean, parent: Instance?)
		for k = 0, tall - 1 do
			block("Sprout", Vector3.new(0.8, 0.8, 0.8), at * CFrame.new(0, 0.4 + k * 0.8, 0) * CFrame.Angles(0, math.rad(k * 20), 0), if k % 2 == 0 then LEAF else LEAF_LIGHT, nil, front, parent)
		end
		local top = at * CFrame.new(0, tall * 0.8 + 0.3, 0)
		if glow then
			local b = part({ Name = "Bud", Size = Vector3.new(0.7, 0.7, 0.7), Color = BUD, Material = Enum.Material.Neon, CastShadow = false, CFrame = top, Parent = parent or model })
			mark(b, front)
		else
			block("SproutLeaf", Vector3.new(1.3, 0.4, 1.3), top * CFrame.Angles(0, math.rad(45), 0), LEAF_LIGHT, nil, front, parent)
		end
	end
	for _, side in { -1, 1 } do
		local boxLen = hx - doorX - 2.6
		local cx = side * (doorX + 1.6 + boxLen / 2)
		local boxCf = CFrame.new(cx, -0.1, -hz - 1.6)
		block("PlanterBox", Vector3.new(boxLen, 1.8, 2.4), boxCf, WOOD_BROWN, { CanCollide = true }, true)
		block("PlanterSoil", Vector3.new(boxLen - 0.6, 0.2, 1.8), boxCf * CFrame.new(0, 0.9, 0), SOIL, nil, true)
		local count = math.max(2, math.floor(boxLen / 2.2))
		for i = 1, count do
			local x = -boxLen / 2 + (i - 0.5) * boxLen / count
			sprout(boxCf * CFrame.new(x, 0.9, 0), if i % 2 == 0 then 2 else 1, i % 3 == 1, true)
		end
	end

	-- Vine columns in the four inside corners: a brick pot and a zig-zag stack of leaf cubes.
	for _, c in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local base = CFrame.new(c[1] * (hx - 3.2), 0, c[2] * (hz - 3.2))
		local front = c[2] == -1
		block("VinePot", Vector3.new(3, 2, 3), base * CFrame.new(0, 1, 0), WOOD_BROWN, { CanCollide = true }, front)
		block("VineSoil", Vector3.new(2.4, 0.2, 2.4), base * CFrame.new(0, 2.05, 0), SOIL, nil, front)
		local tall = 7
		for k = 0, tall - 1 do
			local wiggle = if k % 2 == 0 then 0.35 else -0.35
			block("Vine", Vector3.new(1.6, 1.6, 1.6), base * CFrame.new(wiggle * c[1], 2.9 + k * 1.45, wiggle * c[2]) * CFrame.Angles(0, math.rad(k * 15), 0), if k % 2 == 0 then LEAF else LEAF_LIGHT, nil, front)
			if k == 2 or k == 5 then
				local b = part({ Name = "Bud", Size = Vector3.new(0.9, 0.9, 0.9), Color = BUD, Material = Enum.Material.Neon, CastShadow = false, CFrame = base * CFrame.new(-wiggle * c[1] * 2.6, 2.9 + k * 1.45, 0.5), Parent = model })
				mark(b, front)
				if k == 5 then
					local light = Instance.new("PointLight")
					light.Color = BUD
					light.Range = 9
					light.Brightness = 0.6
					light.Parent = b
				end
			end
		end
	end

	-- Two hanging pots from the roof, leaves drooping over the edge.
	for _, spot in { Vector2.new(-hx * 0.62, hz * 0.45), Vector2.new(hx * 0.62, -hz * 0.3) } do
		local top = roofAt(spot.X) - 0.3
		local potY = H - 3.5
		part({ Name = "Cord", Size = Vector3.new(0.2, top - potY, 0.2), Color = IRON, Material = Enum.Material.Metal, CFrame = CFrame.new(spot.X, (top + potY) / 2, spot.Y), Parent = model })
		local pot = CFrame.new(spot.X, potY - 0.9, spot.Y)
		block("HangingPot", Vector3.new(2, 1.8, 2), pot, WOOD_BROWN)
		for i = 0, 7 do
			local a = i / 8 * math.pi * 2
			local out = Vector3.new(math.cos(a), 0, math.sin(a))
			block("HangingLeaf", Vector3.new(0.7, 0.7, 1.4), CFrame.lookAt(pot.Position + out * 1.3 + Vector3.new(0, 0.9, 0), pot.Position + out * 2.4 + Vector3.new(0, 0.1, 0)), if i % 2 == 0 then LEAF else LEAF_LIGHT)
			if i % 2 == 0 then
				block("Trail", Vector3.new(0.6, 0.6, 0.6), CFrame.new(pot.Position + out * 1.9 + Vector3.new(0, -0.6 - (i % 4) * 0.5, 0)), LEAF)
			end
		end
	end

	-- Doormat on the threshold.
	part({ Name = "Doormat", Size = Vector3.new(5, 0.1, 2.4), Color = Color3.fromRGB(150, 90, 60), Material = Enum.Material.Fabric, CFrame = CFrame.new(0, 0.05, -hz + 2), Parent = model })

	-- A few fireflies drifting in and around the greenhouse.
	local volume = part({ Name = "Fireflies", Size = Vector3.new(W + 6, H * 0.75, D + 6), Transparency = 1, CastShadow = false, CFrame = CFrame.new(0, H * 0.45, 0), Parent = model })
	local flies = Instance.new("ParticleEmitter")
	flies.Name = "Fireflies"
	flies.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	flies.Shape = Enum.ParticleEmitterShape.Box
	flies.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	flies.Rate = 3
	flies.Lifetime = NumberRange.new(4, 7)
	flies.Speed = NumberRange.new(0.4, 1.2)
	flies.SpreadAngle = Vector2.new(180, 180)
	flies.Acceleration = Vector3.new(0, 0.15, 0)
	flies.Drag = 0.3
	flies.RotSpeed = NumberRange.new(-40, 40)
	flies.LightEmission = 1
	flies.Brightness = 2
	flies.Color = ColorSequence.new(Color3.fromRGB(255, 235, 130), Color3.fromRGB(190, 255, 140))
	flies.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(0.5, 0.35), NumberSequenceKeypoint.new(1, 0.2) })
	-- Twinkle: fade in, blink a couple of times, fade out.
	flies.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.12, 0.1),
		NumberSequenceKeypoint.new(0.3, 0.75),
		NumberSequenceKeypoint.new(0.45, 0.05),
		NumberSequenceKeypoint.new(0.65, 0.7),
		NumberSequenceKeypoint.new(0.8, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	flies.Parent = volume

	return model
end

return FruitModels
