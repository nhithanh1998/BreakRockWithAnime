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
--   ItemDisplay.ShowImage(view, image)    -> an uploaded icon in a ViewportFrame (ImageLabel "Picture")
--   ItemDisplay.ShowAxeImage(view, model)  -> ShowImage with the axe's AxeImage; false when it has none
--
-- Uploaded icons win over 3D models (a model in a ViewportFrame is much heavier to draw):
-- Hero picture order: HeroConfig AnimeImage -> model -> ★.
-- Material picture order: TreeConfig Materials[x].MaterialImage -> the voxel model in
-- ReplicatedStorage.DropModels.<key> (same as the drop in the world) -> 3D render of Visual.
-- Axe picture order: ShopConfig.Axes[x].AxeImage -> the model in ReplicatedStorage.Axes.
-- Materials use the full-size "HeroView" when the slot has one, so the icon fills the card.
--
-- A "stack" is "<Material key>" or "Anime:<Hero name>", the same names ChestService uses.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))
local ShopConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ShopConfig"))
local FruitConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FruitConfig"))
local FruitModels = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FruitModels"))
local PotionConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PotionConfig"))

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
			image = hero and hero.AnimeImage,
		}
	end
	local def = TreeConfig.Materials[stack]
	return {
		name = if def then def.Name else stack,
		rarity = if def then def.Rarity else "Common",
		isHero = false,
		value = if def then def.Value else 0,
		visual = def and def.Visual,
		image = def and def.MaterialImage,
		key = stack,
	}
end

function ItemDisplay.SlotColor(rarity: string): Color3
	return TreeConfig.RaritySlotColors[rarity] or Color3.fromRGB(120, 120, 120)
end

-- Uploaded icons ------------------------------------------------------------------------------------

-- Shows `image` filling `view` (instead of a 3D model). Tint it through the "Picture" child: a
-- ViewportFrame's ImageColor3 / ImageTransparency don't reach GUI children.
function ItemDisplay.ShowImage(view: ViewportFrame, image: string)
	view:ClearAllChildren()
	view.CurrentCamera = nil
	local label = Instance.new("ImageLabel")
	label.Name = "Picture"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.ScaleType = Enum.ScaleType.Fit
	label.Image = image
	label.ZIndex = view.ZIndex
	label.Parent = view
end

-- The axe's uploaded icon in `view`. False when ShopConfig has no AxeImage for it (draw the model).
function ItemDisplay.ShowAxeImage(view: ViewportFrame, model: string): boolean
	local axe = ShopConfig.GetAxe(model)
	local image = axe and axe.AxeImage
	if not image then
		return false
	end
	ItemDisplay.ShowImage(view, image)
	return true
end

-- Devil Fruit picture: its FruitImage, or the 3D fruit (FruitModels) turned a little. Skips the work
-- when `view` already shows this fruit.
function ItemDisplay.FillFruitViewport(view: ViewportFrame, fruitId: string)
	if view:GetAttribute("Fruit") == fruitId and #view:GetChildren() > 0 then
		return
	end
	view:ClearAllChildren()
	view:SetAttribute("Fruit", fruitId)
	local def = FruitConfig.Get(fruitId)
	if not def then
		return
	end
	if def.FruitImage then
		ItemDisplay.ShowImage(view, def.FruitImage)
		return
	end
	view.Ambient = Color3.fromRGB(200, 200, 200)
	view.LightColor = Color3.new(1, 1, 1)
	view.LightDirection = Vector3.new(-0.5, -1, -0.7)
	local model = FruitModels.Fruit(def, 2)
	model:PivotTo(CFrame.Angles(math.rad(10), math.rad(-20), 0))
	model.Parent = view
	local camera = Instance.new("Camera")
	camera.FieldOfView = 30
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 0.3, 5.6), Vector3.new(0, 0.1, 0))
	camera.Parent = view
	view.CurrentCamera = camera
end

-- Material picture: a 3D icon of the drop, shaped by Visual.Shape, filling ICON_FILL of the view.
local ICON_FOV = 30
local ICON_FILL = 0.92 -- share of the view the item's widest / tallest side takes up (1 = touches the edges)

-- Puts `camera` on the line `dir` (unit, from the item towards the camera) so the box `boxCFrame` /
-- `size` just fits ICON_FILL of the view, whichever side (width / height) is the tight one.
-- Uses the 8 corners of the box seen in perspective, not its bounding sphere (that left the item
-- much smaller than the card).
local function fitCamera(view: ViewportFrame, camera: Camera, boxCFrame: CFrame, size: Vector3, dir: Vector3)
	local center = boxCFrame.Position
	local look = CFrame.lookAt(center + dir, center)
	local right, up, back = look.RightVector, look.UpVector, look.LookVector * -1
	local tanY = math.tan(math.rad(ICON_FOV / 2)) * ICON_FILL
	local abs = view.AbsoluteSize
	local aspect = if abs.X > 0 and abs.Y > 0 then abs.X / abs.Y else 1
	local tanX = tanY * aspect
	local distance = 0.1
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local corner = boxCFrame:PointToWorldSpace(size * 0.5 * Vector3.new(sx, sy, sz)) - center
				local depth = corner:Dot(back) -- towards the camera
				distance = math.max(distance, math.abs(corner:Dot(up)) / tanY + depth, math.abs(corner:Dot(right)) / tanX + depth)
			end
		end
	end
	camera.FieldOfView = ICON_FOV
	camera.CFrame = CFrame.lookAt(center + dir * distance, center)
end

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

-- Axes ----------------------------------------------------------------------------------------------

-- Axe picture: its AxeImage, or the model in ReplicatedStorage.Axes tilted a little. Skips the work
-- when `view` already shows this axe.
function ItemDisplay.FillAxeViewport(view: ViewportFrame, model: string)
	if view:GetAttribute("Axe") == model then
		return
	end
	view:ClearAllChildren()
	view:SetAttribute("Axe", model)
	if ItemDisplay.ShowAxeImage(view, model) then
		return
	end
	local axes = ReplicatedStorage:FindFirstChild("Axes")
	local source = axes and axes:FindFirstChild(model)
	if not source or not source:IsA("Model") then
		return
	end
	local m = source:Clone()
	for _, d in m:GetDescendants() do
		if d:IsA("LayerCollector") then
			d:Destroy()
		end
	end
	local bbox, size = m:GetBoundingBox()
	m:PivotTo(CFrame.Angles(0, 0, math.rad(-28)) * bbox:ToObjectSpace(m:GetPivot()))
	m.Parent = view
	local fov = 40
	local reach = math.max(size.X, size.Y) * 0.45
	local camera = Instance.new("Camera")
	camera.FieldOfView = fov
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 0.2, reach / math.tan(math.rad(fov / 2))), Vector3.new(0, 0.2, 0))
	camera.Parent = view
	view.CurrentCamera = camera
end

-- Potions -------------------------------------------------------------------------------------------

-- A blocky potion bottle (studded glass cube, coloured liquid, neck and cork), pivot = its centre.
function ItemDisplay.PotionModel(color: Color3): Model
	local model = Instance.new("Model")
	model.Name = "Potion"
	local function block(name: string, size: Vector3, cf: CFrame, c: Color3, props: { [string]: any }?): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.CanCollide = false
		p.Size = size
		p.CFrame = cf
		p.Color = c
		p.Material = Enum.Material.SmoothPlastic
		studs(p)
		for k, v in props or {} do
			(p :: any)[k] = v
		end
		p.Parent = model
		return p
	end
	local liquid = block("Liquid", Vector3.new(1.7, 1.45, 1.7), CFrame.new(0, -0.35, 0), color)
	model.PrimaryPart = liquid
	block("Glass", Vector3.new(2, 2, 2), CFrame.new(0, -0.2, 0), Color3.fromRGB(220, 240, 255), { Transparency = 0.6 })
	block("Shine", Vector3.new(0.3, 0.9, 0.12), CFrame.new(-0.6, 0.05, -1.02), Color3.new(1, 1, 1), { Transparency = 0.25 })
	block("Neck", Vector3.new(0.9, 0.6, 0.9), CFrame.new(0, 1.1, 0), Color3.fromRGB(220, 240, 255), { Transparency = 0.5 })
	block("Cork", Vector3.new(1, 0.55, 1), CFrame.new(0, 1.6, 0), Color3.fromRGB(150, 100, 60))
	block("Label", Vector3.new(1.2, 0.7, 0.1), CFrame.new(0, -0.35, -1.02), Color3.fromRGB(250, 240, 210))
	block("Mark", Vector3.new(0.5, 0.35, 0.1), CFrame.new(0, -0.35, -1.06), color:Lerp(Color3.new(0, 0, 0), 0.3))
	return model
end

-- Potion picture: its uploaded Image, or the 3D bottle in its colour. Skips the work when `view`
-- already shows this potion.
function ItemDisplay.FillPotionViewport(view: ViewportFrame, potionId: string)
	if view:GetAttribute("Potion") == potionId and #view:GetChildren() > 0 then
		return
	end
	view:ClearAllChildren()
	view:SetAttribute("Potion", potionId)
	local def = PotionConfig.Get(potionId)
	if not def then
		return
	end
	if def.Image and def.Image ~= "" then
		ItemDisplay.ShowImage(view, def.Image)
		return
	end
	lightView(view)
	local model = ItemDisplay.PotionModel(def.Color)
	model:PivotTo(CFrame.Angles(0, math.rad(-25), 0))
	model.Parent = view
	local camera = Instance.new("Camera")
	camera.Parent = view
	view.CurrentCamera = camera
	local cf, size = model:GetBoundingBox()
	fitCamera(view, camera, cf, size, Vector3.new(0.25, 0.35, -1).Unit)
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
	local box = model:GetBoundingBox()
	model:PivotTo(CFrame.Angles(0, math.rad(-25), 0) * box:ToObjectSpace(model:GetPivot()))
	model.Parent = view
	local turned, size = model:GetBoundingBox()
	local camera = Instance.new("Camera")
	fitCamera(view, camera, turned, size, Vector3.new(0, 0.35, 1).Unit)
	camera.Parent = view
	view.CurrentCamera = camera
	return true
end

-- Material picture: the DropModels voxel model when there is one, otherwise the 3D icon of Visual.
function ItemDisplay.FillViewport(view: ViewportFrame, visual: TreeConfig.Visual?, key: string?)
	view:ClearAllChildren()
	view:SetAttribute("Hero", nil)
	lightView(view)
	local def = key and TreeConfig.Materials[key]
	if def and def.MaterialImage then
		ItemDisplay.ShowImage(view, def.MaterialImage)
		return
	end
	if key and fillModelViewport(view, key) then
		return
	end
	if not visual then
		return
	end
	local part = iconPart(visual)
	part.Parent = view
	local camera = Instance.new("Camera")
	fitCamera(view, camera, part.CFrame, part.Size, Vector3.new(0, 0.3, 1).Unit)
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
local PORTRAIT_AMBIENT = Color3.fromRGB(215, 215, 215) -- fill light on the hero (higher = brighter shadows)

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
	if view:GetAttribute("Hero") == heroName and (view:FindFirstChild("Main") or view:FindFirstChild("Picture")) then
		return true
	end
	view:ClearAllChildren()
	view.CurrentCamera = nil
	view:SetAttribute("Hero", nil)
	-- Uploaded portrait (outline baked in) instead of the model.
	local hero = HeroConfig.Get(heroName)
	if hero and hero.AnimeImage then
		ItemDisplay.ShowImage(view, hero.AnimeImage)
		view:SetAttribute("Hero", heroName)
		return true
	end
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
	local main = layer(view, "Main", model, camera, view.ZIndex + 1, Vector2.zero)
	-- Bright, from the front: the default ViewportFrame light (grey, from behind the hero) left
	-- the face and clothes in shadow.
	main.Ambient = PORTRAIT_AMBIENT
	main.LightColor = Color3.new(1, 1, 1)
	main.LightDirection = (camera.CFrame.LookVector + Vector3.new(0, -0.6, 0)).Unit
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
	elseif info.image and heroView then
		-- The full-size view, so the icon is as big as a hero portrait.
		ItemDisplay.ShowImage(heroView, info.image)
		heroView.Visible = true
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
