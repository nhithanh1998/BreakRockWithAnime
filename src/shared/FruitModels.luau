-- FruitModels: builds the 3D pieces of the Devil Fruit feature from parts (server and client).
--
--   FruitModels.Fruit(def, size)   -> Model: Devil Fruit of 6 ridged lobes (alternating shades of
--                                     def.Color) with a curled def.Swirl line on each, a curled stem
--                                     and two leaves. Pivot = its center. ~95 parts.
--   FruitModels.Greenhouse(w, h)   -> Model: wooden frame + glass walls / pitched roof around the
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

-- Greenhouse (around the planter) ---------------------------------------------------------------------

local WOOD = Color3.fromRGB(205, 140, 75)
local WOOD_DARK = Color3.fromRGB(165, 105, 55)
local GLASS = Color3.fromRGB(205, 240, 255)

-- Model "Greenhouse": wooden frame with glass walls and a pitched glass roof. `width` = outer size,
-- `height` = wall height (the roof ridge is `height + width * 0.3`). Pivot = ground center, front = -Z.
-- Parts of the front wall have the attribute Front = true (the cutscene hides them locally).
function FruitModels.Greenhouse(width: number, height: number): Model
	local model = Instance.new("Model")
	model.Name = "Greenhouse"
	local W, H = width, height
	local P = 1.2 -- post / beam thickness
	local R = W * 0.3 -- roof rise
	local half = W / 2
	local root = part({ Name = "Root", Size = Vector3.one * 0.2, Transparency = 1, CFrame = CFrame.new(), Parent = model })
	model.PrimaryPart = root

	local function wood(name: string, size: Vector3, cf: CFrame, front: boolean?, dark: boolean?)
		local p = part({ Name = name, Size = size, CFrame = cf, Color = if dark then WOOD_DARK else WOOD, Material = Enum.Material.WoodPlanks, CanCollide = true, Parent = model })
		studs(p)
		if front then
			p:SetAttribute("Front", true)
		end
		return p
	end
	local function glass(name: string, size: Vector3, cf: CFrame, front: boolean?, className: string?)
		local p = part({
			Name = name,
			ClassName = className,
			Size = size,
			CFrame = cf,
			Color = GLASS,
			Material = Enum.Material.Glass,
			Transparency = 0.72,
			Reflectance = 0.1,
			CastShadow = false,
			CanCollide = true,
			Parent = model,
		})
		if front then
			p:SetAttribute("Front", true)
		end
		return p
	end

	-- Posts: corners + the middle of every wall.
	local inner = half - P / 2
	for _, c in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 }, { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } } do
		wood("Post", Vector3.new(P, H, P), CFrame.new(c[1] * inner, H / 2, c[2] * inner), c[2] == -1 and c[1] == 0, c[1] ~= 0 and c[2] ~= 0)
	end
	-- Walls: bottom + top beams and two glass panes each. Side = which wall (front = -Z).
	for _, side in { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } } do
		local alongX = side[1] == 0
		local front = side[2] == -1
		local offset = Vector3.new(side[1] * inner, 0, side[2] * inner)
		local beamSize = if alongX then Vector3.new(W, P * 0.8, P) else Vector3.new(P, P * 0.8, W)
		wood("Beam", beamSize, CFrame.new(offset + Vector3.new(0, P * 0.4, 0)), front, true)
		wood("Beam", beamSize, CFrame.new(offset + Vector3.new(0, H - P * 0.4, 0)), front)
		wood("Beam", beamSize * Vector3.new(if alongX then 1 else 0.6, 0.5, if alongX then 0.6 else 1), CFrame.new(offset + Vector3.new(0, H * 0.55, 0)), front, true)
		local paneW = half - P * 1.5
		for k = -1, 1, 2 do
			local along = (half / 2) * k
			local pos = offset + (if alongX then Vector3.new(along, H / 2, 0) else Vector3.new(0, H / 2, along))
			glass("Glass", if alongX then Vector3.new(paneW, H - P, 0.2) else Vector3.new(0.2, H - P, paneW), CFrame.new(pos), front)
		end
	end
	-- Roof: ridge along X, two glass slopes with rafters, glass gables at the ends.
	local slope = math.sqrt(half * half + R * R)
	local tilt = math.atan2(R, half)
	wood("Ridge", Vector3.new(W + P, P, P), CFrame.new(0, H + R, 0))
	for _, dir in { -1, 1 } do
		-- Slope center halfway between the wall top (z = dir * half) and the ridge (z = 0).
		local cf = CFrame.new(0, H + R / 2, dir * half / 2) * CFrame.Angles(dir * tilt, 0, 0)
		glass("RoofGlass", Vector3.new(W, 0.2, slope), cf)
		for _, x in { -inner, -half / 2, 0, half / 2, inner } do
			wood("Rafter", Vector3.new(P * 0.7, P * 0.7, slope + P * 0.5), cf * CFrame.new(x, 0.3, 0))
		end
	end
	for _, x in { -inner, inner } do
		-- Two wedges per gable, each rising towards the ridge.
		glass("Gable", Vector3.new(0.2, R, half), CFrame.new(x, H + R / 2, -half / 2), false, "WedgePart")
		glass("Gable", Vector3.new(0.2, R, half), CFrame.new(x, H + R / 2, half / 2) * CFrame.Angles(0, math.pi, 0), false, "WedgePart")
	end
	-- Glowing lamps hanging under the ridge.
	for _, x in { -half / 2, half / 2 } do
		local lamp = part({ Name = "Lamp", Size = Vector3.new(0.9, 0.9, 0.9), Color = GLOW, Material = Enum.Material.Neon, CFrame = CFrame.new(x, H + R - 1.2, 0) * CFrame.Angles(0, math.rad(45), 0), Parent = model })
		local light = Instance.new("PointLight")
		light.Color = GLOW
		light.Range = 12
		light.Brightness = 0.8
		light.Parent = lamp
	end
	return model
end

return FruitModels
