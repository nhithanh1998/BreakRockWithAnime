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
-- Material picture order: TreeConfig Materials[x].Image (optional rbxassetid) -> 3D render of Visual.
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

function ItemDisplay.FillViewport(view: ViewportFrame, visual: TreeConfig.Visual)
	view:ClearAllChildren()
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
local PORTRAIT_YAW = math.rad(18) -- turn the camera a little to the side so the face isn't flat

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

-- Draws the hero's model in `view`, framed on the head and shoulders. Skips the work when `view`
-- already shows this hero. Returns false when the hero has no model in ReplicatedStorage.Heros.
function ItemDisplay.FillHeroViewport(view: ViewportFrame, heroName: string): boolean
	if view:GetAttribute("Hero") == heroName and view:FindFirstChildOfClass("WorldModel") then
		return true
	end
	view:ClearAllChildren()
	view:SetAttribute("Hero", nil)
	local template = HeroConfig.GetTemplate(heroName)
	if not template then
		return false
	end

	local model = template:Clone()
	prepareModel(model)
	local world = Instance.new("WorldModel")
	model.Parent = world
	world.Parent = view

	local head = model:FindFirstChild("Head") :: BasePart?
	local root = (model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart or head) :: BasePart?
	local camera = Instance.new("Camera")
	camera.FieldOfView = PORTRAIT_FOV
	if head and root then
		local facing = root.CFrame
		local up = facing.UpVector
		local headHeight = head.Size.Y
		-- Head (with hair / hats) + shoulders: center just below the head, frame about 3 heads tall.
		local focus = head.Position - up * headHeight * 0.3
		local frameHeight = headHeight * 3
		local distance = (frameHeight / 2) / math.tan(math.rad(PORTRAIT_FOV / 2))
		local dir = (CFrame.fromAxisAngle(up, PORTRAIT_YAW) * facing.LookVector).Unit
		camera.CFrame = CFrame.lookAt(focus + dir * distance + up * headHeight * 0.2, focus, up)
	else
		local cf, size = model:GetBoundingBox()
		local distance = (size.Magnitude / 2) / math.tan(math.rad(PORTRAIT_FOV / 2))
		camera.CFrame = CFrame.lookAt(cf.Position + cf.LookVector * distance, cf.Position)
	end
	camera.Parent = view
	view.CurrentCamera = camera
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
	elseif info.visual and heroView then
		-- The full-size view (when the slot has one) so the icon is as big as a hero portrait.
		ItemDisplay.FillViewport(heroView, info.visual)
		heroView.Visible = true
	end
end

return ItemDisplay
