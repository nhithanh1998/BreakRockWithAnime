-- ItemDisplay: shared helpers for drawing items in the UI (chest window, hotbar, "Added!" popups).
--   ItemDisplay.Info(stack)          -> name / rarity / hero? / value / visual
--   ItemDisplay.Abbreviate(n)        -> "38.1M"
--   ItemDisplay.Commas(n)            -> "1,234"
--   ItemDisplay.FillViewport(view, visual) -> draws the material (block / ball / log / gem by
--                                             Visual.Shape), framed to fill most of the view
--   ItemDisplay.FillHeroViewport(view, heroName) -> head-and-shoulders render of the hero's model
--                                             (ReplicatedStorage.Heros); false if it has no model
--   ItemDisplay.SetPicture(slot, info)     -> shows the hero model / hero image / ★ / material block on
--                                             a slot. Children it uses: "View" (ViewportFrame, material
--                                             block), "Icon" (TextLabel), and optionally "HeroView"
--                                             (ViewportFrame for the hero model; "View" is used when
--                                             missing) and "Image" (ImageLabel, HeroConfig Image)
--
-- Hero picture order: model -> HeroConfig Image -> ★.
-- Material picture order: TreeConfig Materials[x].Image (optional rbxassetid) -> the voxel model in
-- ReplicatedStorage.DropModels.<key> (same as the drop in the world) -> 3D render of Visual.
-- Materials use the full-size "HeroView" when the slot has one, so the icon fills the card.
--
-- A "stack" is "<Material key>" or "Anime:<Hero name>", the same names ChestService uses.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))

local ItemDisplay = {}

ItemDisplay.HERO_PREFIX = "Anime:"
ItemDisplay.HERO_VALUE_COLOR = Color3.fromRGB(255, 40, 40)
ItemDisplay.MATERIAL_VALUE_COLOR = Color3.fromRGB(80, 255, 60)

export type ItemInfo = {
	name: string,
	rarity: string,
	isHero: boolean,
	value: number, -- sell value (material) or MinePower (hero)
	visual: TreeConfig.Visual?,
	image: string?,
	key: string?, -- material key (TreeConfig.Materials / ReplicatedStorage.DropModels name)
}

function ItemDisplay.Commas(n: number): string
	local s = tostring(math.floor(n))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

-- Same as HeroConfig.Abbreviate (one place for the K / M / B / ... / Sx units).
ItemDisplay.Abbreviate = HeroConfig.Abbreviate

function ItemDisplay.HeroStack(name: string): string
	return ItemDisplay.HERO_PREFIX .. name
end

function ItemDisplay.Info(stack: string): ItemInfo
	local prefix = ItemDisplay.HERO_PREFIX
	if stack:sub(1, #prefix) == prefix then
		local name = stack:sub(#prefix + 1)
		local hero = TreeConfig.GetHero(name)
		return {
			name = name,
			rarity = if hero then hero.Rarity else "Rare",
			isHero = true,
			value = if hero then hero.MinePower else 0,
			image = hero and hero.Image,
		}
	end
	local def = TreeConfig.Materials[stack]
	return {
		name = if def then def.Name else stack,
		rarity = if def then def.Rarity else "Common",
		isHero = false,
		value = if def then def.Value else 0,
		visual = def and def.Visual,
		image = def and (def :: any).Image,
		key = stack,
	}
end

function ItemDisplay.SlotColor(rarity: string): Color3
	return TreeConfig.RaritySlotColors[rarity] or Color3.fromRGB(120, 120, 120)
end

-- Material picture: a 3D icon of the drop, shaped by Visual.Shape, filling ~ICON_FILL of the view.
local ICON_FOV = 30
local ICON_FILL = 0.8 -- share of the view's height the bounding sphere takes up (the item itself is a bit smaller)

local function studs(part: BasePart)
	for _, face in { "Top", "Bottom", "Front", "Back", "Left", "Right" } do
		(part :: any)[face .. "Surface"] = Enum.SurfaceType.Studs
	end
end

local function iconPart(visual: TreeConfig.Visual): BasePart
	local part = Instance.new("Part")
	part.Anchored = true
	part.Color = visual.Color
	part.Material = visual.Material
	local shape = visual.Shape
	if shape == "Ball" then
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.one * 2
		part.CFrame = CFrame.Angles(0, math.rad(30), 0)
	elseif shape == "Cylinder" then
		-- A short log lying on its side.
		part.Shape = Enum.PartType.Cylinder
		part.Size = Vector3.new(2.4, 1.5, 1.5)
		part.CFrame = CFrame.Angles(0, math.rad(35), 0) * CFrame.Angles(0, 0, math.rad(12))
	elseif shape == "Gem" then
		-- A diamond: a cube stood on its corner, shiny.
		part.Size = Vector3.one * 1.6
		part.Material = Enum.Material.SmoothPlastic
		part.Reflectance = 0.25
		part.CFrame = CFrame.Angles(0, math.rad(45), 0) * CFrame.Angles(math.rad(35), 0, math.rad(45))
		local light = Instance.new("PointLight")
		light.Color = visual.Color
		light.Brightness = 2
		light.Range = 6
		light.Parent = part
	else
		part.Size = Vector3.one * 2
		studs(part)
		part.CFrame = CFrame.Angles(0, math.rad(35), 0) * CFrame.Angles(math.rad(-20), 0, 0)
	end
	return part
end

-- Fixed lighting for material icons, so a card's colour never tints the item.
local function lightView(view: ViewportFrame)
	view.Ambient = Color3.fromRGB(190, 190, 190)
	view.LightColor = Color3.new(1, 1, 1)
	view.LightDirection = Vector3.new(-0.4, -1, -0.6)
	view.ImageTransparency = 0
	view.ImageColor3 = Color3.new(1, 1, 1)
end

-- The material's custom voxel model (ReplicatedStorage.DropModels.<key>, the same model the drops
-- use in the world), prepared once: anchored, no physics, its invisible "Root" left out of sight.
local preparedModels: { [string]: Model | false } = {}

local function dropModel(key: string): Model?
	local cached = preparedModels[key]
	if cached ~= nil then
		return cached or nil
	end
	local folder = ReplicatedStorage:FindFirstChild("DropModels")
	local template = folder and folder:FindFirstChild(key)
	if not template or not template:IsA("Model") then
		if folder then
			preparedModels[key] = false -- don't cache a miss while the folder is still replicating
		end
		return nil
	end
	local model = template:Clone()
	for _, d in model:GetDescendants() do
		if d:IsA("BaseScript") or d:IsA("Sound") or d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	preparedModels[key] = model
	return model
end

-- Draws the material's voxel model in `view`, filling ~ICON_FILL of it. False without a model.
local function fillModelViewport(view: ViewportFrame, key: string): boolean
	local template = dropModel(key)
	if not template then
		return false
	end
	local model = template:Clone()
	-- Centre the visible parts at the origin, turned a little so it reads as 3D.
	local box, size = model:GetBoundingBox()
	model:PivotTo(CFrame.Angles(0, math.rad(-25), 0) * box:ToObjectSpace(model:GetPivot()))
	model.Parent = view
	local radius = math.max(size.Magnitude / 2, 0.1)
	local distance = radius / math.tan(math.rad(ICON_FOV / 2)) / ICON_FILL
	local camera = Instance.new("Camera")
	camera.FieldOfView = ICON_FOV
	local dir = Vector3.new(0, 0.35, 1).Unit
	camera.CFrame = CFrame.lookAt(dir * distance, Vector3.zero)
	camera.Parent = view
	view.CurrentCamera = camera
	return true
end

-- Material picture: the DropModels voxel model when there is one, otherwise the 3D icon of Visual.
function ItemDisplay.FillViewport(view: ViewportFrame, visual: TreeConfig.Visual?, key: string?)
	view:ClearAllChildren()
	view:SetAttribute("Hero", nil)
	lightView(view)
	if key and fillModelViewport(view, key) then
		return
	end
	if not visual then
		return
	end
	local part = iconPart(visual)
	part.Parent = view
	-- Frame the part's bounding sphere so it fills ICON_FILL of the view's height.
	local radius = part.Size.Magnitude / 2
	local distance = radius / math.tan(math.rad(ICON_FOV / 2)) / ICON_FILL
	local camera = Instance.new("Camera")
	camera.FieldOfView = ICON_FOV
	local dir = Vector3.new(0, 0.3, 1).Unit
	-- Aim a little above the part so it sits just below the card's middle, clear of the name.
	camera.CFrame = CFrame.lookAt(dir * distance + Vector3.new(0, 0.25, 0), Vector3.new(0, 0.25, 0))
	camera.Parent = view
	view.CurrentCamera = camera
end

-- Hero portrait ---------------------------------------------------------------------------------------

local PORTRAIT_FOV = 30
local PORTRAIT_YAW = 0 -- radians the camera turns to the side (0 = hero looks straight at you)
local PORTRAIT_HEADS = 2.8 -- the card is this many heads tall (smaller = bigger hero)
-- Heads the view's center sits above the head's center (bigger = hero lower). -0.3 puts the hero
-- 0.42 heads = 15% of the card higher than 0.12 did.
local PORTRAIT_LIFT = -0.3

local function prepareModel(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BaseScript") or d:IsA("Sound") or d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end
end

-- Outline around the hero: flat STROKE_COLOR copies of the model behind it, each nudged
-- STROKE_SCALE of the card's size in one of these directions (so it grows with the card).
local STROKE_SCALE = 0.018 -- 0.018 = about 2.3px on a 130px card
local STROKE_COLOR = Color3.fromRGB(38, 24, 66) -- deep purple
local STROKE_DIRS = {
	Vector2.new(1, 0),
	Vector2.new(-1, 0),
	Vector2.new(0, 1),
	Vector2.new(0, -1),
	Vector2.new(0.7071, 0.7071),
	Vector2.new(-0.7071, 0.7071),
	Vector2.new(0.7071, -0.7071),
	Vector2.new(-0.7071, -0.7071),
}

-- Turns a model copy into a flat white silhouette (colours, textures and clothes removed), so the
-- stroke layer can tint it any colour with ImageColor3.
local function whiten(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("Decal") or d:IsA("Clothing") or d:IsA("ShirtGraphic") or d:IsA("BodyColors") or d:IsA("SurfaceAppearance") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Color = Color3.new(1, 1, 1)
			d.Material = Enum.Material.SmoothPlastic
			d.Reflectance = 0
			if d:IsA("MeshPart") then
				d.TextureID = ""
			end
		elseif d:IsA("SpecialMesh") then
			d.TextureId = ""
			d.VertexColor = Vector3.one
		end
	end
end

-- A full-size ViewportFrame inside `view` showing `model` through a copy of `camera`, moved by
-- `offset` (a share of the view's size).
local function layer(view: ViewportFrame, name: string, model: Model, camera: Camera, zIndex: number, offset: Vector2): ViewportFrame
	local frame = Instance.new("ViewportFrame")
	frame.Name = name
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.Position = UDim2.fromScale(offset.X, offset.Y)
	frame.ZIndex = zIndex
	local world = Instance.new("WorldModel")
	model.Parent = world
	world.Parent = frame
	local cam = camera:Clone()
	cam.Parent = frame
	frame.CurrentCamera = cam
	frame.Parent = view
	return frame
end

-- Draws the hero's model in `view`, framed on the head and shoulders, with an outline.
-- Skips the work when `view` already shows this hero. Returns false when the hero has no model in
-- ReplicatedStorage.Heros. The model is drawn in child ViewportFrames ("Main" on top of the
-- "Stroke" copies); `view` itself stays empty.
function ItemDisplay.FillHeroViewport(view: ViewportFrame, heroName: string): boolean
	if view:GetAttribute("Hero") == heroName and view:FindFirstChild("Main") then
		return true
	end
	view:ClearAllChildren()
	view.CurrentCamera = nil
	view:SetAttribute("Hero", nil)
	local template = HeroConfig.GetTemplate(heroName)
	if not template then
		return false
	end

	local model = template:Clone()
	prepareModel(model)

	local head = model:FindFirstChild("Head") :: BasePart?
	local root = (model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart or head) :: BasePart?
	local camera = Instance.new("Camera")
	camera.FieldOfView = PORTRAIT_FOV
	if head and root then
		local facing = root.CFrame
		local up = facing.UpVector
		local headHeight = head.Size.Y
		-- Head (with hair / hats) + shoulders, PORTRAIT_HEADS tall, shifted by PORTRAIT_LIFT.
		local focus = head.Position + up * headHeight * PORTRAIT_LIFT
		local frameHeight = headHeight * PORTRAIT_HEADS
		local distance = (frameHeight / 2) / math.tan(math.rad(PORTRAIT_FOV / 2))
		local dir = (CFrame.fromAxisAngle(up, PORTRAIT_YAW) * facing.LookVector).Unit
		-- Camera level with the focus: straight on, no looking down.
		camera.CFrame = CFrame.lookAt(focus + dir * distance, focus, up)
	else
		local cf, size = model:GetBoundingBox()
		local distance = (size.Magnitude / 2) / math.tan(math.rad(PORTRAIT_FOV / 2))
		camera.CFrame = CFrame.lookAt(cf.Position + cf.LookVector * distance, cf.Position)
	end

	for i, d in STROKE_DIRS do
		local copy = model:Clone()
		whiten(copy)
		local stroke = layer(view, "Stroke" .. i, copy, camera, view.ZIndex, d * STROKE_SCALE)
		-- White ambient and no directional light: the silhouette is flat white, then tinted.
		stroke.Ambient = Color3.new(1, 1, 1)
		stroke.LightColor = Color3.new(0, 0, 0)
		stroke.ImageColor3 = STROKE_COLOR
	end
	layer(view, "Main", model, camera, view.ZIndex + 1, Vector2.zero)
	camera:Destroy()
	view:SetAttribute("Hero", heroName)
	return true
end

-- Slot picture ----------------------------------------------------------------------------------------

function ItemDisplay.SetPicture(slot: Instance, info: ItemInfo)
	local view = slot:FindFirstChild("View") :: ViewportFrame?
	local heroView = (slot:FindFirstChild("HeroView") or view) :: ViewportFrame?
	local icon = slot:FindFirstChild("Icon") :: TextLabel?
	local image = slot:FindFirstChild("Image") :: ImageLabel?
	local heroName = if info.isHero then info.name else nil

	-- Clear what this item doesn't use (a hero view showing the same hero is kept as is).
	if heroView and (heroView:GetAttribute("Hero") ~= heroName or heroName == nil) then
		heroView:ClearAllChildren()
		heroView:SetAttribute("Hero", nil)
	end
	if heroView then
		heroView.Visible = false
	end
	if view and view ~= heroView then
		view:ClearAllChildren()
		view.Visible = false
	end
	if icon then
		icon.Visible = false
	end
	if image then
		image.Visible = false
	end
	if info.isHero then
		if heroView and ItemDisplay.FillHeroViewport(heroView, info.name) then
			heroView.Visible = true
		elseif info.image and image then
			image.Image = info.image
			image.Visible = true
		elseif icon then
			icon.Visible = true
		end
	elseif info.image and image then
		image.Image = info.image
		image.Visible = true
	elseif (info.visual or info.key) and heroView then
		-- The full-size view (when the slot has one) so the icon is as big as a hero portrait.
		ItemDisplay.FillViewport(heroView, info.visual, info.key)
		heroView.Visible = true
	end
end

return ItemDisplay
