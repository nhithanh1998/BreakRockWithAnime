-- ItemDisplay: shared helpers for drawing items in the UI (chest window, hotbar, "Added!" popups).
--   ItemDisplay.Info(stack)          -> name / rarity / hero? / value / visual
--   ItemDisplay.Abbreviate(n)        -> "38.1M"
--   ItemDisplay.Commas(n)            -> "1,234"
--   ItemDisplay.FillViewport(view, visual) -> draws the material's studded block
--   ItemDisplay.SetPicture(slot, info)     -> shows hero image / ★ / material block on a slot that
--                                             has "View" (ViewportFrame), "Icon" (TextLabel) and
--                                             optionally "Image" (ImageLabel) children
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
	}
end

function ItemDisplay.SlotColor(rarity: string): Color3
	return TreeConfig.RaritySlotColors[rarity] or Color3.fromRGB(120, 120, 120)
end

-- Material picture: the same studded block that drops from trees.
function ItemDisplay.FillViewport(view: ViewportFrame, visual: TreeConfig.Visual)
	view:ClearAllChildren()
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = Vector3.one * 2
	part.Color = visual.Color
	part.Material = visual.Material
	for _, face in { "Top", "Bottom", "Front", "Back", "Left", "Right" } do
		(part :: any)[face .. "Surface"] = Enum.SurfaceType.Studs
	end
	part.CFrame = CFrame.Angles(0, math.rad(35), 0) * CFrame.Angles(math.rad(-20), 0, 0)
	part.Parent = view
	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 1.6, 5.2), Vector3.zero)
	camera.Parent = view
	view.CurrentCamera = camera
end

function ItemDisplay.SetPicture(slot: Instance, info: ItemInfo)
	local view = slot:FindFirstChild("View") :: ViewportFrame?
	local icon = slot:FindFirstChild("Icon") :: TextLabel?
	local image = slot:FindFirstChild("Image") :: ImageLabel?
	if view then
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
		if info.image and image then
			image.Image = info.image
			image.Visible = true
		elseif icon then
			icon.Visible = true
		end
	elseif info.visual and view then
		ItemDisplay.FillViewport(view, info.visual)
		view.Visible = true
	end
end

return ItemDisplay
