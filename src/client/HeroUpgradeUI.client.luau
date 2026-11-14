-- HeroUpgradeUI: the windows for a hero pad.
--
-- Opened by clicking / tapping the "UPGRADE" plaque built onto the front of each of your pads that
-- has a hero (made here, see Pad plaques below). Every window is laid out at a fixed design size and
-- scaled to fit the screen, so it works on phones too. Three windows, one shown at a time:
--
--   Upgrade Hero  the hero (picture, name, rarity) and one row per stat in HeroConfig.UpgradeOrder:
--                 grade badge, level / max, level bar, value now -> next level, buy button
--                 (Remotes.HeroUpgrade(slot, stat)). Buttons "AXE" and "REROLL STATS" open the others.
--   Stat Reroll   per stat: grade (F..SSS, HeroConfig.Grades), its bonus %, a lock toggle and a
--                 reroll button for just that stat (HeroUpgrade(slot, "RerollStat", stat),
--                 HeroConfig.RerollStatCost). "Reroll All" rolls every unlocked stat
--                 (HeroUpgrade(slot, "Reroll", lockedStats)) for HeroConfig.RerollCostFor(locks).
--                 At least one stat stays unlocked. Locks are remembered per pad while you play.
--   Hero Axe      your owned axes (ShopService copies): pick one for this pad's hero
--                 (HeroUpgrade(slot, "EquipAxe", model)); each copy can only be on one pad. The hero
--                 holds it and deals ShopConfig HeroBoost x Chop Damage. "Unequip" takes it off.
--   Hero Fruit    your Devil Fruits (player.Fruits, grown at the Devil Tree): pick one for this pad's
--                 hero (HeroUpgrade(slot, "EquipFruit", id)); one pad per copy. Boost x Chop Damage
--                 plus its passive skill (FruitConfig). "Unequip" takes it off.
--
-- Values come from the slot's attributes ("LevelDamage", "GradeDamage", "HeroAxe" ...), so the
-- windows update by themselves. X on a sub window goes back to Upgrade Hero; everything closes when
-- you walk CLOSE_DISTANCE studs away from the pad or the hero leaves it.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local FruitConfig = require(Shared:WaitForChild("FruitConfig"))
local ItemDisplay = require(script.Parent:WaitForChild("ItemDisplay"))
local HeroUpgrade = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("HeroUpgrade") :: RemoteFunction

local player = Players.LocalPlayer
local abbreviate = HeroConfig.Abbreviate

local CLOSE_DISTANCE = 45 -- studs from the pad before the windows close by themselves
local PANEL_MAX_DISTANCE = 60 -- the pad plaques show their button within this many studs
local FONT = Enum.Font.FredokaOne
local PANEL_COLOR = Color3.fromRGB(38, 40, 50)
local PANEL_STROKE = Color3.fromRGB(78, 80, 92)
local ROW_COLOR = Color3.fromRGB(28, 30, 38)
local CLOSE_COLOR = Color3.fromRGB(214, 92, 28)
local GREEN_BUTTON = Color3.fromRGB(36, 132, 66)
local GREY_BUTTON = Color3.fromRGB(80, 82, 92)
local GOLD_BUTTON = Color3.fromRGB(190, 140, 30)
local AXE_BUTTON = Color3.fromRGB(200, 110, 30)
local FRUIT_BUTTON = Color3.fromRGB(150, 70, 220)
local OK_COLOR = Color3.fromRGB(90, 255, 90)
local BAD_COLOR = Color3.fromRGB(255, 90, 90)
local NEXT_COLOR = Color3.fromRGB(90, 255, 60)
local REROLL_COLOR = Color3.fromRGB(150, 70, 220)
local BADGE_BG = Color3.fromRGB(16, 16, 20)
local INFO_COLOR = Color3.fromRGB(175, 178, 190)
local PLUS_COLOR = Color3.fromRGB(90, 255, 90)
local MINUS_COLOR = Color3.fromRGB(255, 95, 95)
-- Colour of each stat's name and level bar.
local STAT_COLORS = {
	Damage = Color3.fromRGB(255, 95, 80),
	Speed = Color3.fromRGB(255, 200, 60),
	Walk = Color3.fromRGB(90, 190, 255),
} :: { [string]: Color3 }

-- Helpers ----------------------------------------------------------------------------------------

local function new(className: string, props: { [string]: any }, children: { Instance }?): any
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function corner(radius: number): UICorner
	return new("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color: Color3, thickness: number, border: boolean?): UIStroke
	return new("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = if border then Enum.ApplyStrokeMode.Border else Enum.ApplyStrokeMode.Contextual,
	})
end

local function text(props: { [string]: any }): TextLabel
	props.BackgroundTransparency = 1
	props.Font = props.Font or FONT
	props.TextScaled = true
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	local thickness = props.StrokeThickness or 2
	props.StrokeThickness = nil
	local label = new("TextLabel", props)
	stroke(Color3.fromRGB(20, 20, 24), thickness).Parent = label
	return label
end

local function button(props: { [string]: any }): TextButton
	local b = new("TextButton", {
		AutoButtonColor = true,
		BackgroundColor3 = props.Color,
		Font = FONT,
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
		Text = props.Text,
		Position = props.Position,
		Size = props.Size,
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		Parent = props.Parent,
	}, {
		corner(4),
		new("UIPadding", { PaddingTop = UDim.new(0.18, 0), PaddingBottom = UDim.new(0.18, 0), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }),
	})
	local border = stroke(props.Color:Lerp(Color3.new(1, 1, 1), 0.25), 2, true)
	border.Name = "Border"
	border.Parent = b
	stroke(Color3.fromRGB(20, 20, 24), 1.5).Parent = b
	return b
end

local function setButtonColor(b: TextButton, color: Color3)
	b.BackgroundColor3 = color
	local border = b:FindFirstChild("Border") :: UIStroke?
	if border then
		border.Color = color:Lerp(Color3.new(1, 1, 1), 0.25)
	end
end

local function pop(inst: GuiObject, from: number)
	local scale = inst:FindFirstChildOfClass("UIScale") or new("UIScale", { Parent = inst })
	scale.Scale = from
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function formatValue(stat: string, value: number): string
	if stat == "Speed" then
		return ("x%.2f"):format(value)
	elseif stat == "Walk" then
		return ("%.1f"):format(value)
	end
	return abbreviate(value)
end

local function getMoney(): number
	local stats = player:FindFirstChild("leaderstats")
	local money = stats and stats:FindFirstChild("Money")
	return if money and (money:IsA("NumberValue") or money:IsA("IntValue")) then money.Value else 0
end

local function message(m: any): string
	return if typeof(m) == "string" then m else ""
end

-- Windows ----------------------------------------------------------------------------------------

local gui = new("ScreenGui", {
	Name = "HeroUpgradeGui",
	DisplayOrder = 12,
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = player:WaitForChild("PlayerGui"),
})

-- Every window is laid out at DESIGN_SIZE pixels and scaled to fit the screen (title above and toast
-- below included), so it is as big as it can be on a phone and never runs off the edge.
local DESIGN_SIZE = Vector2.new(560, 320)
local MAX_SCALE = 1.35

type Window = { root: Frame, scale: UIScale, toast: TextLabel }
local windows: { Window } = {}

local function fitScale(): number
	local screen = gui.AbsoluteSize
	if screen.X <= 0 or screen.Y <= 0 then
		return 1
	end
	-- Height needs room for the title (~15% above) and the toast (~13% below).
	return math.min(screen.X * 0.94 / DESIGN_SIZE.X, screen.Y * 0.9 / (DESIGN_SIZE.Y * 1.28), MAX_SCALE)
end
gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	for _, w in windows do
		w.scale.Scale = fitScale()
	end
end)

-- A window with a gradient title above it and a toast line under it.
local function makeWindow(name: string, title: string, gradient: ColorSequence): Window
	local root = new("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromOffset(DESIGN_SIZE.X, DESIGN_SIZE.Y),
		BackgroundColor3 = PANEL_COLOR,
		BackgroundTransparency = 0.08,
		Visible = false,
		Parent = gui,
	}, { corner(6) })
	stroke(PANEL_STROKE, 2, true).Parent = root
	local scale = new("UIScale", { Name = "Fit", Scale = fitScale(), Parent = root })
	local titleLabel = text({
		Name = "Title",
		Text = title,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, -0.005),
		Size = UDim2.fromScale(0.6, 0.15),
		StrokeThickness = 3,
		Parent = root,
	})
	new("UIGradient", { Color = gradient, Rotation = 90, Parent = titleLabel })
	local toast = text({
		Name = "Toast",
		Text = "",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 1.03),
		Size = UDim2.fromScale(0.7, 0.1),
		TextTransparency = 1,
		Parent = root,
	})
	;(toast:FindFirstChildOfClass("UIStroke") :: UIStroke).Transparency = 1
	local w: Window = { root = root, scale = scale, toast = toast }
	table.insert(windows, w)
	return w
end

local function showToast(w: Window, msg: string, color: Color3)
	local s = w.toast:FindFirstChildOfClass("UIStroke") :: UIStroke
	w.toast.Text = msg
	w.toast.TextColor3 = color
	w.toast.TextTransparency = 0
	s.Transparency = 0
	local info = TweenInfo.new(0.5, Enum.EasingStyle.Linear, Enum.EasingDirection.In, 0, false, 1.2)
	TweenService:Create(w.toast, info, { TextTransparency = 1 }):Play()
	TweenService:Create(s, info, { Transparency = 1 }):Play()
end

-- Shows one window (popping in), hides the others.
local function show(w: Window)
	for _, other in windows do
		other.root.Visible = other == w
	end
	local target = fitScale()
	w.scale.Scale = target * 0.9
	TweenService:Create(w.scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = target }):Play()
end

-- The hero column on the left of a window: picture, name, rarity. Returns the card and a fill(def).
local function heroCard(parent: Frame, pictureHeight: number): (Frame, (any) -> ())
	local card = new("Frame", {
		Name = "Hero",
		Position = UDim2.fromScale(0.03, 0.06),
		Size = UDim2.fromScale(0.28, 0.88),
		BackgroundColor3 = ROW_COLOR,
		Parent = parent,
	}, { corner(6) })
	local picture = new("Frame", {
		Name = "Picture",
		Position = UDim2.fromScale(0.07, 0.03),
		Size = UDim2.fromScale(0.86, pictureHeight),
		BackgroundColor3 = GREY_BUTTON,
		Parent = card,
	}, { corner(6) })
	stroke(Color3.fromRGB(20, 20, 24), 2, true).Parent = picture
	local viewport = new("ViewportFrame", {
		Name = "View",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Ambient = Color3.fromRGB(200, 200, 200),
		LightColor = Color3.new(1, 1, 1),
		Parent = picture,
	})
	local y = 0.03 + pictureHeight + 0.01
	local nameLabel = text({ Name = "HeroName", Text = "", Position = UDim2.fromScale(0.05, y), Size = UDim2.fromScale(0.9, 0.1), Parent = card })
	local rarityLabel = text({ Name = "Rarity", Text = "", Position = UDim2.fromScale(0.1, y + 0.1), Size = UDim2.fromScale(0.8, 0.08), Parent = card })
	return card, function(def)
		nameLabel.Text = def.Name
		HeroConfig.PaintRarity(rarityLabel, def.Rarity) -- tagged: RarityGradientFX animates it
		picture.BackgroundColor3 = ItemDisplay.SlotColor(def.Rarity)
		ItemDisplay.FillHeroViewport(viewport, def.Name)
	end
end

-- A grade box: the letter in its colour (animated gradient for the top grades).
type GradeBox = { frame: GuiObject, letter: TextLabel, gradient: UIGradient }
local function gradeBox(frame: GuiObject): GradeBox
	local border = stroke(Color3.new(1, 1, 1), 2.5, true)
	border.Name = "Border"
	border.Parent = frame
	local letter = text({ Name = "Letter", Text = "", Position = UDim2.fromScale(0.08, 0.12), Size = UDim2.fromScale(0.84, 0.76), StrokeThickness = 2.5, Parent = frame })
	local gradient = new("UIGradient", { Enabled = false, Parent = letter })
	return { frame = frame, letter = letter, gradient = gradient }
end

local function paintGrade(box: GradeBox, grade: string)
	local def = HeroConfig.Grades[grade]
	box.letter.Text = grade
	local border = box.frame:FindFirstChild("Border") :: UIStroke?
	if border then
		border.Color = def.Color
	end
	if def.Gradient then
		box.letter.TextColor3 = Color3.new(1, 1, 1)
		box.gradient.Enabled = true
		box.gradient:SetAttribute("Rarity", def.Gradient)
		CollectionService:AddTag(box.gradient, HeroConfig.RarityGradientTag) -- RarityGradientFX animates it
	else
		box.letter.TextColor3 = def.Color
		box.gradient.Enabled = false
		CollectionService:RemoveTag(box.gradient, HeroConfig.RarityGradientTag)
	end
end

-- What the windows are showing.
local current: { slot: Model, index: number, pad: BasePart, hero: string, connections: { RBXScriptConnection } }? = nil
local busy = false
local rolling = false -- grade boxes are flickering (reroll animation): leave them alone

local function levelOf(slot: Model, stat: string): number
	local level = slot:GetAttribute(HeroConfig.LevelAttribute(stat))
	return if typeof(level) == "number" then level else 1
end

local function gradeOf(slot: Model, stat: string): string
	local grade = slot:GetAttribute(HeroConfig.GradeAttribute(stat))
	return if typeof(grade) == "string" and HeroConfig.Grades[grade] then grade else HeroConfig.DefaultGrade
end

local function axeOf(slot: Model): string?
	local axe = slot:GetAttribute("HeroAxe")
	return if typeof(axe) == "string" and ShopConfig.GetAxe(axe) then axe else nil
end

local function fruitOf(slot: Model): string?
	local fruit = slot:GetAttribute("HeroFruit")
	return if typeof(fruit) == "string" and FruitConfig.Get(fruit) then fruit else nil
end

-- The stat as the hero gets it (level x grade, the axe and fruit for damage, the fruit's skill for
-- speed / walk). Same as HeroWorkerService.
local function statValue(slot: Model, stat: string, level: number, hero: string): number
	local value = HeroConfig.StatValue(stat, level, gradeOf(slot, stat), hero)
	local fruitId = fruitOf(slot)
	local fruit = fruitId and FruitConfig.Get(fruitId)
	if stat == "Damage" then
		local axe = axeOf(slot)
		local def = axe and ShopConfig.GetAxe(axe)
		if def then
			value = math.max(1, math.floor(value * def.HeroBoost))
		end
		if fruit then
			value = math.max(1, math.floor(value * fruit.Boost))
		end
	elseif fruit and stat == "Speed" and fruit.Skill.Speed then
		value *= fruit.Skill.Speed
	elseif fruit and stat == "Walk" and fruit.Skill.Walk then
		value *= fruit.Skill.Walk
	end
	return value
end

-- Locked stats per pad (slot model -> stat -> true), kept while the game runs.
local locks: { [Model]: { [string]: boolean } } = {}

local function locksFor(slot: Model): { [string]: boolean }
	locks[slot] = locks[slot] or {}
	return locks[slot]
end

local function lockList(slot: Model): { string }
	local list = {}
	for _, stat in HeroConfig.UpgradeOrder do
		if locksFor(slot)[stat] then
			table.insert(list, stat)
		end
	end
	return list
end

-- ===================== Upgrade Hero =====================

local upgradeWin = makeWindow("Upgrade", "Upgrade Hero!", ColorSequence.new(Color3.fromRGB(255, 240, 120), Color3.fromRGB(255, 150, 30)))
local close = button({ Text = "X", Color = CLOSE_COLOR, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(0.975, 0.035), Size = UDim2.fromScale(0.065, 0.115), Parent = upgradeWin.root })

local upgradeCard, fillUpgradeCard = heroCard(upgradeWin.root, 0.44)
local axeButton = button({ Text = "", Color = AXE_BUTTON, Position = UDim2.fromScale(0.07, 0.67), Size = UDim2.fromScale(0.42, 0.14), Parent = upgradeCard })
axeButton.Name = "Axe"
local fruitButton = button({ Text = "FRUIT", Color = FRUIT_BUTTON, Position = UDim2.fromScale(0.51, 0.67), Size = UDim2.fromScale(0.42, 0.14), Parent = upgradeCard })
fruitButton.Name = "Fruit"
local rerollOpen = button({ Text = "REROLL STATS", Color = REROLL_COLOR, Position = UDim2.fromScale(0.07, 0.83), Size = UDim2.fromScale(0.86, 0.14), Parent = upgradeCard })
rerollOpen.Name = "RerollStats"

type Row = { stat: string, level: TextLabel, fill: Frame, value: TextLabel, buy: TextButton, grade: GradeBox }
local rows: { Row } = {}
local list = new("Frame", {
	Name = "Stats",
	Position = UDim2.fromScale(0.33, 0.17),
	Size = UDim2.fromScale(0.64, 0.79),
	BackgroundTransparency = 1,
	Parent = upgradeWin.root,
}, {
	new("UIListLayout", { Padding = UDim.new(0.04, 0), SortOrder = Enum.SortOrder.LayoutOrder }),
})
local rowHeight = (1 - 0.04 * (#HeroConfig.UpgradeOrder - 1)) / #HeroConfig.UpgradeOrder

-- ===================== Stat Reroll =====================

local rerollWin = makeWindow("StatReroll", "Stat Reroll", ColorSequence.new(Color3.fromRGB(170, 255, 120), Color3.fromRGB(40, 200, 70)))
local rerollBack = button({ Text = "X", Color = CLOSE_COLOR, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(0.975, 0.035), Size = UDim2.fromScale(0.065, 0.115), Parent = rerollWin.root })
local rerollCard, fillRerollCard = heroCard(rerollWin.root, 0.6)
local bestChance = text({
	Name = "Best",
	Text = ("SSS chance: %.1f%%"):format(HeroConfig.GradeChance("SSS") * 100),
	TextColor3 = Color3.fromRGB(255, 205, 60),
	Position = UDim2.fromScale(0.06, 0.86),
	Size = UDim2.fromScale(0.88, 0.09),
	Parent = rerollCard,
})
bestChance.Name = "Best"
text({
	Name = "Info",
	Text = "Rerolling gives a stat a new grade, F (worst) to SSS (best).\nLock your good stats to keep them on Reroll All.",
	TextColor3 = INFO_COLOR,
	Position = UDim2.fromScale(0.33, 0.06),
	Size = UDim2.fromScale(0.56, 0.12),
	StrokeThickness = 1.5,
	Parent = rerollWin.root,
})

type RerollRow = { stat: string, grade: GradeBox, bonus: TextLabel, lock: TextButton, reroll: TextButton }
local rerollRows: { RerollRow } = {}
local rerollList = new("Frame", {
	Name = "Stats",
	Position = UDim2.fromScale(0.33, 0.21),
	Size = UDim2.fromScale(0.64, 0.54),
	BackgroundTransparency = 1,
	Parent = rerollWin.root,
}, {
	new("UIListLayout", { Padding = UDim.new(0.05, 0), SortOrder = Enum.SortOrder.LayoutOrder }),
})
local rerollRowHeight = (1 - 0.05 * (#HeroConfig.UpgradeOrder - 1)) / #HeroConfig.UpgradeOrder
local rerollAll = button({ Text = "", Color = GREEN_BUTTON, Position = UDim2.fromScale(0.4, 0.79), Size = UDim2.fromScale(0.5, 0.15), Parent = rerollWin.root })
rerollAll.Name = "RerollAll"

-- ===================== Hero Axe =====================

local axeWin = makeWindow("HeroAxe", "Hero Axe", ColorSequence.new(Color3.fromRGB(255, 220, 120), Color3.fromRGB(230, 120, 30)))
local axeBack = button({ Text = "X", Color = CLOSE_COLOR, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(0.975, 0.035), Size = UDim2.fromScale(0.065, 0.115), Parent = axeWin.root })
local axeInfo = text({
	Name = "Info",
	Text = "",
	RichText = true,
	TextColor3 = INFO_COLOR,
	Position = UDim2.fromScale(0.04, 0.05),
	Size = UDim2.fromScale(0.82, 0.1),
	TextXAlignment = Enum.TextXAlignment.Left,
	StrokeThickness = 1.5,
	Parent = axeWin.root,
})
local axeGrid = new("ScrollingFrame", {
	Name = "Grid",
	Position = UDim2.fromScale(0.03, 0.18),
	Size = UDim2.fromScale(0.94, 0.62),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = Color3.fromRGB(120, 122, 132),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	ScrollingDirection = Enum.ScrollingDirection.Y,
	Parent = axeWin.root,
}, {
	new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 12), PaddingBottom = UDim.new(0, 4) }),
})
local axeLayout = new("UIGridLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = axeGrid })
local function sizeAxeCells()
	-- 5 cards per row, sized in pixels (scale cell sizes collapse in an auto-sized ScrollingFrame).
	local width = axeGrid.AbsoluteSize.X / math.max(axeWin.scale.Scale, 0.01) - 16 - axeGrid.ScrollBarThickness
	local gap = math.max(4, math.floor(width * 0.02))
	local cell = math.max(20, math.floor((width - gap * 4) / 5))
	axeLayout.CellPadding = UDim2.fromOffset(gap, gap)
	axeLayout.CellSize = UDim2.fromOffset(cell, math.floor(cell * 1.15))
end
axeGrid:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizeAxeCells)
sizeAxeCells()
local unequip = button({ Text = "UNEQUIP", Color = GREY_BUTTON, Position = UDim2.fromScale(0.03, 0.83), Size = UDim2.fromScale(0.28, 0.13), Parent = axeWin.root })
unequip.Name = "Unequip"
text({
	Name = "Hint",
	Text = "Buy more copies at the Lumber Axe shop (+1 on an owned axe)",
	TextColor3 = INFO_COLOR,
	Position = UDim2.fromScale(0.34, 0.85),
	Size = UDim2.fromScale(0.62, 0.09),
	StrokeThickness = 1.5,
	Parent = axeWin.root,
})

-- ===================== Hero Fruit =====================

local fruitWin = makeWindow("HeroFruit", "Hero Fruit", ColorSequence.new(Color3.fromRGB(230, 170, 255), Color3.fromRGB(150, 70, 230)))
local fruitBack = button({ Text = "X", Color = CLOSE_COLOR, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(0.975, 0.035), Size = UDim2.fromScale(0.065, 0.115), Parent = fruitWin.root })
local fruitInfo = text({
	Name = "Info",
	Text = "",
	RichText = true,
	TextColor3 = INFO_COLOR,
	Position = UDim2.fromScale(0.04, 0.05),
	Size = UDim2.fromScale(0.82, 0.1),
	TextXAlignment = Enum.TextXAlignment.Left,
	StrokeThickness = 1.5,
	Parent = fruitWin.root,
})
local fruitGrid = new("Frame", {
	Name = "Grid",
	Position = UDim2.fromScale(0.03, 0.18),
	Size = UDim2.fromScale(0.94, 0.62),
	BackgroundTransparency = 1,
	Parent = fruitWin.root,
}, {
	new("UIGridLayout", { CellSize = UDim2.fromScale(0.235, 0.48), CellPadding = UDim2.fromScale(0.02, 0.04), SortOrder = Enum.SortOrder.LayoutOrder }),
})
local fruitUnequip = button({ Text = "UNEQUIP", Color = GREY_BUTTON, Position = UDim2.fromScale(0.03, 0.83), Size = UDim2.fromScale(0.28, 0.13), Parent = fruitWin.root })
fruitUnequip.Name = "Unequip"
local fruitSkill = text({
	Name = "Hint",
	Text = "Grow Devil Fruits at the Devil Tree on your plot",
	RichText = true,
	TextColor3 = INFO_COLOR,
	Position = UDim2.fromScale(0.34, 0.83),
	Size = UDim2.fromScale(0.62, 0.13),
	StrokeThickness = 1.5,
	Parent = fruitWin.root,
})

local function ownedFruits(): { [string]: number }
	local out = {}
	local folder = player:FindFirstChild("Fruits")
	for _, v in if folder then folder:GetChildren() else {} do
		if v:IsA("IntValue") and v.Value > 0 and FruitConfig.Get(v.Name) then
			out[v.Name] = v.Value
		end
	end
	return out
end

local function fruitsUsedElsewhere(slot: Model): { [string]: number }
	local used = {}
	local slots = slot.Parent
	for _, other in if slots then slots:GetChildren() else {} do
		if other ~= slot and other:IsA("Model") then
			local f = other:GetAttribute("HeroFruit")
			if typeof(f) == "string" and f ~= "" then
				used[f] = (used[f] or 0) + 1
			end
		end
	end
	return used
end

-- Axes: owned copies, and how many other pads use each ------------------------------------------

local function ownedAxes(): { [string]: number }
	local out = {}
	local folder = player:FindFirstChild("Axes")
	for _, v in if folder then folder:GetChildren() else {} do
		if v:IsA("BoolValue") and v.Value and ShopConfig.GetAxe(v.Name) then
			local n = v:GetAttribute("Copies")
			out[v.Name] = if typeof(n) == "number" then math.max(1, n) else 1
		end
	end
	return out
end

local function axesUsedElsewhere(slot: Model): { [string]: number }
	local used = {}
	local slots = slot.Parent
	for _, other in if slots then slots:GetChildren() else {} do
		if other ~= slot and other:IsA("Model") then
			local axe = other:GetAttribute("HeroAxe")
			if typeof(axe) == "string" and axe ~= "" then
				used[axe] = (used[axe] or 0) + 1
			end
		end
	end
	return used
end

local axeViewport = ItemDisplay.FillAxeViewport

-- Drawing ----------------------------------------------------------------------------------------

local function redrawUpgrade(slot: Model, hero: string, money: number)
	local axe = axeOf(slot)
	local axeDef = axe and ShopConfig.GetAxe(axe)
	axeButton.Text = if axeDef then ("%s x%s"):format(axeDef.Name, tostring(axeDef.HeroBoost)) else "AXE"
	local fruitId = fruitOf(slot)
	local fruitDef = fruitId and FruitConfig.Get(fruitId)
	fruitButton.Text = if fruitDef then fruitDef.Name else "FRUIT"
	for _, row in rows do
		local up = HeroConfig.Upgrades[row.stat]
		local level = levelOf(slot, row.stat)
		local cost = HeroConfig.UpgradeCost(row.stat, level)
		paintGrade(row.grade, gradeOf(slot, row.stat))
		row.level.Text = ("Lv %d/%d"):format(level, up.MaxLevel)
		row.fill.Size = UDim2.fromScale(math.clamp(level / up.MaxLevel, 0, 1), 1)
		local now = formatValue(row.stat, statValue(slot, row.stat, level, hero))
		if cost then
			row.value.Text = ('%s <font color="#%s">→ %s</font>'):format(now, NEXT_COLOR:ToHex(), formatValue(row.stat, statValue(slot, row.stat, level + 1, hero)))
			row.buy.Text = "$" .. abbreviate(cost)
			setButtonColor(row.buy, if money >= cost then GREEN_BUTTON else GREY_BUTTON)
		else
			row.value.Text = now
			row.buy.Text = "MAX"
			setButtonColor(row.buy, GOLD_BUTTON)
		end
	end
end

local function redrawReroll(slot: Model, money: number)
	local slotLocks = locksFor(slot)
	local locked = lockList(slot)
	local allCost = HeroConfig.RerollCostFor(#locked) or 0
	rerollAll.Text = if #locked > 0
		then ("Reroll All  $%s (%d🔒)"):format(abbreviate(allCost), #locked)
		else "Reroll All  $" .. abbreviate(allCost)
	setButtonColor(rerollAll, if money >= allCost then GREEN_BUTTON else GREY_BUTTON)
	for _, row in rerollRows do
		local grade = gradeOf(slot, row.stat)
		local isLocked = slotLocks[row.stat] == true
		if not rolling or isLocked then
			paintGrade(row.grade, grade)
			local def = HeroConfig.Grades[grade]
			local pct = (def.Multiplier - 1) * (HeroConfig.GradeEffect[row.stat] or 1) * 100
			row.bonus.Text = if math.abs(pct) < 0.05 then "0%" else ("%+.0f%%"):format(pct)
			row.bonus.TextColor3 = if pct > 0.05 then PLUS_COLOR elseif pct < -0.05 then MINUS_COLOR else Color3.new(1, 1, 1)
		end
		row.lock.Text = if isLocked then "🔒" else "🔓"
		row.lock.TextTransparency = if isLocked then 0 else 0.55
		setButtonColor(row.lock, if isLocked then GOLD_BUTTON else BADGE_BG)
		row.reroll.Text = "$" .. abbreviate(HeroConfig.RerollStatCost)
		setButtonColor(row.reroll, if isLocked or money < HeroConfig.RerollStatCost then GREY_BUTTON else GREEN_BUTTON)
	end
end

-- Axe cards are rebuilt only when something they show changed.
local axeSignature = ""
local function redrawAxes(slot: Model, hero: string)
	local equippedAxe = axeOf(slot)
	local owned = ownedAxes()
	local used = axesUsedElsewhere(slot)
	local def = equippedAxe and ShopConfig.GetAxe(equippedAxe)
	local damage = statValue(slot, "Damage", levelOf(slot, "Damage"), hero)
	axeInfo.Text = if def
		then ('%s holds <font color="#FFC83C">%s</font> (x%s damage) - Chop Damage <font color="#5AFF3C">%s</font>'):format(hero, def.Name, tostring(def.HeroBoost), abbreviate(damage))
		else ('%s has the basic axe - Chop Damage <font color="#5AFF3C">%s</font>'):format(hero, abbreviate(damage))
	unequip.Visible = def ~= nil

	local parts = { equippedAxe or "-" }
	for i, axe in ShopConfig.Axes do
		if owned[axe.Model] then
			table.insert(parts, ("%s:%d:%d"):format(axe.Model, owned[axe.Model], used[axe.Model] or 0))
		end
	end
	local signature = table.concat(parts, "|")
	if signature == axeSignature then
		return
	end
	axeSignature = signature

	for _, c in axeGrid:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local any = false
	for order, axe in ShopConfig.Axes do
		local copies = owned[axe.Model]
		if not copies then
			continue
		end
		any = true
		local free = copies - (used[axe.Model] or 0)
		local isOn = axe.Model == equippedAxe
		local color = ItemDisplay.SlotColor(axe.Rarity)
		local card = new("TextButton", {
			Name = axe.Model,
			Text = "",
			AutoButtonColor = true,
			LayoutOrder = order,
			BackgroundColor3 = color,
			Parent = axeGrid,
		}, { corner(5) })
		stroke(if isOn then NEXT_COLOR else color:Lerp(Color3.new(1, 1, 1), 0.35), if isOn then 3.5 else 2, true).Parent = card
		local view = new("ViewportFrame", { Name = "View", BackgroundTransparency = 1, Position = UDim2.fromScale(0, 0.15), Size = UDim2.fromScale(1, 0.5), Parent = card })
		axeViewport(view, axe.Model)
		text({ Name = "NameLabel", Text = axe.Name, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.03), Size = UDim2.fromScale(0.92, 0.16), ZIndex = 3, Parent = card })
		text({ Name = "Boost", Text = ("x%s DMG"):format(tostring(axe.HeroBoost)), TextColor3 = NEXT_COLOR, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.64), Size = UDim2.fromScale(0.9, 0.15), ZIndex = 3, Parent = card })
		text({
			Name = "Free",
			Text = if isOn then "Equipped" else ("Free %d/%d"):format(math.max(free, 0), copies),
			TextColor3 = if isOn then Color3.new(1, 1, 1) elseif free > 0 then Color3.fromRGB(255, 220, 90) else MINUS_COLOR,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0.81),
			Size = UDim2.fromScale(0.8, 0.14),
			ZIndex = 3,
			Parent = card,
		})
		if isOn then
			new("Frame", { Name = "Tint", BackgroundColor3 = NEXT_COLOR, BackgroundTransparency = 0.78, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = card }, { corner(5) })
		elseif free <= 0 then
			new("Frame", { Name = "Shade", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.5, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = card }, { corner(5) })
		end
		card.Activated:Connect(function()
			local showing = current
			if busy or not showing or isOn then
				return
			end
			if free <= 0 then
				showToast(axeWin, "All copies are on other heroes! Buy another at the shop", BAD_COLOR)
				return
			end
			busy = true
			pop(card, 0.9)
			local ok, msg = HeroUpgrade:InvokeServer(showing.index, "EquipAxe", axe.Model)
			busy = false
			if current == showing then
				showToast(axeWin, message(msg), if ok then OK_COLOR else BAD_COLOR)
			end
		end)
	end
	if not any then
		text({ Name = "None", Text = "You don't own any axes yet. Buy them at the Lumber Axe shop!", TextColor3 = INFO_COLOR, Size = UDim2.fromScale(1, 0.2), Parent = axeGrid })
	end
end

-- Fruit cards: one per fruit (unowned ones dark), rebuilt only when something they show changed.
local fruitSignature = ""
local function redrawFruits(slot: Model, hero: string)
	local equipped = fruitOf(slot)
	local owned = ownedFruits()
	local used = fruitsUsedElsewhere(slot)
	local def = equipped and FruitConfig.Get(equipped)
	local damage = statValue(slot, "Damage", levelOf(slot, "Damage"), hero)
	fruitInfo.Text = if def
		then ('%s ate <font color="#C88CFF">%s</font> (%s) - Chop Damage <font color="#5AFF3C">%s</font>'):format(hero, def.Name, FruitConfig.BoostText(def), abbreviate(damage))
		else ('%s has no Devil Fruit - Chop Damage <font color="#5AFF3C">%s</font>'):format(hero, abbreviate(damage))
	fruitUnequip.Visible = def ~= nil
	if def then
		fruitSkill.Text = ("<b>%s:</b> %s"):format(def.Skill.Name, def.Skill.Desc)
	end

	local parts = { equipped or "-" }
	for _, f in FruitConfig.Fruits do
		table.insert(parts, ("%s:%d:%d"):format(f.Id, owned[f.Id] or 0, used[f.Id] or 0))
	end
	local signature = table.concat(parts, "|")
	if signature == fruitSignature then
		return
	end
	fruitSignature = signature

	for _, c in fruitGrid:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	for order, f in FruitConfig.Fruits do
		local copies = owned[f.Id] or 0
		local free = copies - (used[f.Id] or 0)
		local isOn = f.Id == equipped
		local color = ItemDisplay.SlotColor(f.Rarity)
		local card = new("TextButton", {
			Name = f.Id,
			Text = "",
			AutoButtonColor = true,
			LayoutOrder = order,
			BackgroundColor3 = color,
			Parent = fruitGrid,
		}, { corner(5) })
		stroke(if isOn then NEXT_COLOR else color:Lerp(Color3.new(1, 1, 1), 0.35), if isOn then 3.5 else 2, true).Parent = card
		local view = new("ViewportFrame", { Name = "View", BackgroundTransparency = 1, Position = UDim2.fromScale(0.15, 0.16), Size = UDim2.fromScale(0.7, 0.46), Parent = card })
		ItemDisplay.FillFruitViewport(view, f.Id)
		if copies <= 0 then
			view.ImageColor3 = Color3.new(0, 0, 0)
			view.ImageTransparency = 0.25
		end
		text({ Name = "NameLabel", Text = f.Name, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.03), Size = UDim2.fromScale(0.92, 0.15), ZIndex = 3, Parent = card })
		text({ Name = "Boost", Text = FruitConfig.BoostText(f), TextColor3 = NEXT_COLOR, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.63), Size = UDim2.fromScale(0.9, 0.15), ZIndex = 3, Parent = card })
		text({
			Name = "Free",
			Text = if isOn then "Equipped" elseif copies <= 0 then "Not owned" else ("Free %d/%d"):format(math.max(free, 0), copies),
			TextColor3 = if isOn then Color3.new(1, 1, 1) elseif free > 0 then Color3.fromRGB(255, 220, 90) else MINUS_COLOR,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0.8),
			Size = UDim2.fromScale(0.8, 0.15),
			ZIndex = 3,
			Parent = card,
		})
		if isOn then
			new("Frame", { Name = "Tint", BackgroundColor3 = NEXT_COLOR, BackgroundTransparency = 0.78, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = card }, { corner(5) })
		elseif free <= 0 then
			new("Frame", { Name = "Shade", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.5, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = card }, { corner(5) })
		end
		card.MouseEnter:Connect(function()
			fruitSkill.Text = ("<b>%s:</b> %s"):format(f.Skill.Name, f.Skill.Desc)
		end)
		card.Activated:Connect(function()
			fruitSkill.Text = ("<b>%s:</b> %s"):format(f.Skill.Name, f.Skill.Desc)
			local showing = current
			if busy or not showing or isOn then
				return
			end
			if copies <= 0 then
				showToast(fruitWin, "Grow this fruit at the Devil Tree first!", BAD_COLOR)
				return
			end
			if free <= 0 then
				showToast(fruitWin, "All copies are on other heroes!", BAD_COLOR)
				return
			end
			busy = true
			pop(card, 0.9)
			local ok, msg = HeroUpgrade:InvokeServer(showing.index, "EquipFruit", f.Id)
			busy = false
			if current == showing then
				showToast(fruitWin, message(msg), if ok then OK_COLOR else BAD_COLOR)
			end
		end)
	end
end

local function redraw()
	if not current then
		return
	end
	local money = getMoney()
	redrawUpgrade(current.slot, current.hero, money)
	redrawReroll(current.slot, money)
	redrawAxes(current.slot, current.hero)
	redrawFruits(current.slot, current.hero)
end

-- Upgrade rows -------------------------------------------------------------------------------------

for order, stat in HeroConfig.UpgradeOrder do
	local up = HeroConfig.Upgrades[stat]
	if not up then
		continue
	end
	local color = STAT_COLORS[stat] or Color3.new(1, 1, 1)
	local frame = new("Frame", {
		Name = stat,
		LayoutOrder = order,
		Size = UDim2.fromScale(1, rowHeight),
		BackgroundColor3 = ROW_COLOR,
		Parent = list,
	}, { corner(6) })
	-- Grade badge on the left (tap: Stat Reroll window).
	local badge = new("TextButton", {
		Name = "Grade",
		Text = "",
		AutoButtonColor = true,
		Position = UDim2.fromScale(0.02, 0.14),
		Size = UDim2.fromScale(0.11, 0.72),
		BackgroundColor3 = BADGE_BG,
		Parent = frame,
	}, { corner(6) })
	local grade = gradeBox(badge)
	text({ Name = "StatName", Text = up.Name, TextColor3 = color, Position = UDim2.fromScale(0.16, 0.08), Size = UDim2.fromScale(0.29, 0.36), TextXAlignment = Enum.TextXAlignment.Left, Parent = frame })
	local levelLabel = text({ Name = "Level", Text = "", Position = UDim2.fromScale(0.46, 0.12), Size = UDim2.fromScale(0.2, 0.28), TextXAlignment = Enum.TextXAlignment.Right, Parent = frame })
	local bar = new("Frame", {
		Name = "Bar",
		Position = UDim2.fromScale(0.16, 0.5),
		Size = UDim2.fromScale(0.5, 0.12),
		BackgroundColor3 = Color3.fromRGB(16, 16, 20),
		ClipsDescendants = true,
		Parent = frame,
	}, { corner(4) })
	local fill = new("Frame", { Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = color, BorderSizePixel = 0, Parent = bar }, { corner(4) })
	local valueLabel = text({ Name = "Value", Text = "", RichText = true, Position = UDim2.fromScale(0.16, 0.66), Size = UDim2.fromScale(0.5, 0.28), TextXAlignment = Enum.TextXAlignment.Left, Parent = frame })
	local buy = button({ Text = "", Color = GREEN_BUTTON, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(0.97, 0.5), Size = UDim2.fromScale(0.28, 0.7), Parent = frame })
	buy.Name = "Buy"

	table.insert(rows, { stat = stat, level = levelLabel, fill = fill, value = valueLabel, buy = buy, grade = grade })
	badge.Activated:Connect(function()
		if current then
			show(rerollWin)
		end
	end)
	buy.Activated:Connect(function()
		local showing = current
		if busy or not showing then
			return
		end
		busy = true
		local ok, msg = HeroUpgrade:InvokeServer(showing.index, stat)
		busy = false
		if current ~= showing then
			return
		end
		pop(buy, 0.9)
		if ok then
			pop(frame, 1.04)
		end
		showToast(upgradeWin, message(msg), if ok then OK_COLOR else BAD_COLOR)
		redraw()
	end)
end

-- Reroll rows ------------------------------------------------------------------------------------

-- Flickers the grade boxes of `stats` through random grades, then shows the real ones.
local function rollAnimation(showing: any, stats: { [string]: boolean })
	rolling = true
	local rng = Random.new()
	for _ = 1, 10 do
		for _, row in rerollRows do
			if stats[row.stat] then
				paintGrade(row.grade, HeroConfig.GradeOrder[rng:NextInteger(1, #HeroConfig.GradeOrder)])
			end
		end
		task.wait(0.05)
	end
	rolling = false
	if current ~= showing then
		return
	end
	redraw()
	for _, row in rerollRows do
		if stats[row.stat] then
			pop(row.grade.frame, 1.35)
		end
	end
end

for order, stat in HeroConfig.UpgradeOrder do
	local up = HeroConfig.Upgrades[stat]
	if not up then
		continue
	end
	local color = STAT_COLORS[stat] or Color3.new(1, 1, 1)
	local frame = new("Frame", {
		Name = stat,
		LayoutOrder = order,
		Size = UDim2.fromScale(1, rerollRowHeight),
		BackgroundColor3 = ROW_COLOR,
		Parent = rerollList,
	}, { corner(6) })
	text({ Name = "StatName", Text = up.Name, TextColor3 = color, Position = UDim2.fromScale(0.03, 0.18), Size = UDim2.fromScale(0.34, 0.64), TextXAlignment = Enum.TextXAlignment.Left, Parent = frame })
	local gradeFrame = new("Frame", {
		Name = "Grade",
		Position = UDim2.fromScale(0.38, 0.1),
		Size = UDim2.fromScale(0.12, 0.8),
		BackgroundColor3 = BADGE_BG,
		Parent = frame,
	}, { corner(6) })
	local grade = gradeBox(gradeFrame)
	local bonusFrame = new("Frame", {
		Name = "Bonus",
		Position = UDim2.fromScale(0.52, 0.1),
		Size = UDim2.fromScale(0.17, 0.8),
		BackgroundColor3 = BADGE_BG,
		Parent = frame,
	}, { corner(6) })
	stroke(Color3.fromRGB(70, 72, 82), 1.5, true).Parent = bonusFrame
	local bonus = text({ Name = "Text", Text = "", Position = UDim2.fromScale(0.08, 0.18), Size = UDim2.fromScale(0.84, 0.64), Parent = bonusFrame })
	local lock = button({ Text = "🔓", Color = BADGE_BG, Position = UDim2.fromScale(0.71, 0.1), Size = UDim2.fromScale(0.1, 0.8), Parent = frame })
	lock.Name = "Lock"
	local reroll = button({ Text = "", Color = GREEN_BUTTON, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(0.98, 0.1), Size = UDim2.fromScale(0.15, 0.8), Parent = frame })
	reroll.Name = "Reroll"

	table.insert(rerollRows, { stat = stat, grade = grade, bonus = bonus, lock = lock, reroll = reroll })
	lock.Activated:Connect(function()
		local showing = current
		if not showing or rolling then
			return
		end
		local slotLocks = locksFor(showing.slot)
		if not slotLocks[stat] and #lockList(showing.slot) + 1 >= #HeroConfig.UpgradeOrder then
			showToast(rerollWin, "Can't lock every stat!", BAD_COLOR)
			return
		end
		slotLocks[stat] = if slotLocks[stat] then nil else true
		pop(lock, if slotLocks[stat] then 1.2 else 0.9)
		redraw()
	end)
	reroll.Activated:Connect(function()
		local showing = current
		if busy or rolling or not showing then
			return
		end
		if locksFor(showing.slot)[stat] then
			showToast(rerollWin, "Unlock it first!", BAD_COLOR)
			return
		end
		busy = true
		local ok, msg = HeroUpgrade:InvokeServer(showing.index, "RerollStat", stat)
		busy = false
		if current ~= showing then
			return
		end
		pop(reroll, 0.9)
		if not ok then
			showToast(rerollWin, message(msg), BAD_COLOR)
			return
		end
		rollAnimation(showing, { [stat] = true })
		showToast(rerollWin, message(msg), OK_COLOR)
	end)
end

rerollAll.Activated:Connect(function()
	local showing = current
	if busy or rolling or not showing then
		return
	end
	busy = true
	local ok, msg = HeroUpgrade:InvokeServer(showing.index, "Reroll", lockList(showing.slot))
	busy = false
	if current ~= showing then
		return
	end
	pop(rerollAll, 0.9)
	if not ok then
		showToast(rerollWin, message(msg), BAD_COLOR)
		return
	end
	local stats = {}
	for _, stat in HeroConfig.UpgradeOrder do
		stats[stat] = not locksFor(showing.slot)[stat]
	end
	rollAnimation(showing, stats)
	showToast(rerollWin, message(msg), OK_COLOR)
end)

-- Axe window buttons ------------------------------------------------------------------------------

unequip.Activated:Connect(function()
	local showing = current
	if busy or not showing then
		return
	end
	busy = true
	local ok, msg = HeroUpgrade:InvokeServer(showing.index, "EquipAxe", "")
	busy = false
	if current == showing then
		showToast(axeWin, message(msg), if ok then OK_COLOR else BAD_COLOR)
	end
end)

fruitUnequip.Activated:Connect(function()
	local showing = current
	if busy or not showing then
		return
	end
	busy = true
	local ok, msg = HeroUpgrade:InvokeServer(showing.index, "EquipFruit", "")
	busy = false
	if current == showing then
		showToast(fruitWin, message(msg), if ok then OK_COLOR else BAD_COLOR)
	end
end)

-- Opening / closing -------------------------------------------------------------------------------

local function closeWindow()
	if current then
		for _, c in current.connections do
			c:Disconnect()
		end
	end
	current = nil
	for _, w in windows do
		w.root.Visible = false
	end
end
close.Activated:Connect(closeWindow)
rerollBack.Activated:Connect(function()
	show(upgradeWin)
end)
axeBack.Activated:Connect(function()
	show(upgradeWin)
end)
fruitBack.Activated:Connect(function()
	show(upgradeWin)
end)
fruitButton.Activated:Connect(function()
	if current then
		fruitSignature = ""
		redraw()
		show(fruitWin)
	end
end)
rerollOpen.Activated:Connect(function()
	if current then
		show(rerollWin)
	end
end)
axeButton.Activated:Connect(function()
	if current then
		axeSignature = ""
		redraw()
		show(axeWin)
	end
end)

-- Another window (a shop, ...) opened from a prompt: get out of its way.
ProximityPromptService.PromptTriggered:Connect(function()
	if current then
		closeWindow()
	end
end)

local function slotNumber(slot: Instance): number?
	return tonumber(slot.Name:match("^Slot(%d+)$"))
end

local function open(slot: Model)
	local pad = slot:FindFirstChild("Pad")
	local index = slotNumber(slot)
	if not (pad and pad:IsA("BasePart") and index) then
		return
	end
	local hero = slot:GetAttribute("HeroId")
	local def = typeof(hero) == "string" and HeroConfig.Get(hero)
	if not def then
		return
	end
	closeWindow()
	local connections = {}
	current = { slot = slot, index = index, pad = pad, hero = def.Name, connections = connections }

	fillUpgradeCard(def)
	fillRerollCard(def)
	axeSignature = ""
	fruitSignature = ""

	table.insert(connections, slot.AttributeChanged:Connect(function(name)
		if name == "HeroId" and slot:GetAttribute("HeroId") ~= def.Name then
			closeWindow() -- the hero left the pad (or another took its place)
		else
			redraw()
		end
	end))
	local stats = player:FindFirstChild("leaderstats")
	local money = stats and stats:FindFirstChild("Money")
	if money and money:IsA("ValueBase") then
		table.insert(connections, (money :: any).Changed:Connect(redraw))
	end
	-- Other pads' axes and the owned copies change what the Axe window offers.
	local slots = slot.Parent
	for _, other in if slots then slots:GetChildren() else {} do
		if other ~= slot and other:IsA("Model") then
			table.insert(connections, other:GetAttributeChangedSignal("HeroAxe"):Connect(redraw))
			table.insert(connections, other:GetAttributeChangedSignal("HeroFruit"):Connect(redraw))
		end
	end
	local fruits = player:FindFirstChild("Fruits")
	if fruits then
		table.insert(connections, fruits.ChildAdded:Connect(redraw))
		for _, v in fruits:GetChildren() do
			if v:IsA("IntValue") then
				table.insert(connections, v.Changed:Connect(redraw))
			end
		end
	end
	local axes = player:FindFirstChild("Axes")
	if axes then
		table.insert(connections, axes.DescendantAdded:Connect(redraw))
		for _, v in axes:GetChildren() do
			table.insert(connections, v.AttributeChanged:Connect(redraw))
		end
	end

	redraw()
	show(upgradeWin)
end

-- Pad plaques ------------------------------------------------------------------------------------
-- An "UPGRADE" plaque built onto the front edge of each of your pads that has a hero: a gold-rimmed
-- slanted board leaning out of the pad (local parts, only you see them) with a SurfaceGui button on
-- it. Click / tap it to open the window. Shows the pad's Damage level.

local PLAQUE_WIDTH = 0.85 -- of the pad's width
local PLAQUE_DEPTH = 2.1 -- studs, along the slope
local PLAQUE_TILT = 40 -- degrees the face is turned up from facing straight out (90 = lying flat)
local RIM = 0.18 -- studs of gold rim around the board
local PIXELS_PER_STUD = 70
local RIM_COLOR = Color3.fromRGB(255, 196, 40) -- same gold as the pads' trim
local BOARD_COLOR = Color3.fromRGB(30, 32, 40)

local signs = Instance.new("Folder")
signs.Name = "PadUpgradeSigns"
signs.Parent = workspace

type Plaque = { model: Model, board: BasePart, gui: SurfaceGui, connections: { RBXScriptConnection } }
local plaques: { [Model]: Plaque } = {}

local function part(name: string, size: Vector3, cf: CFrame, color: Color3, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

local function buildPlaque(slot: Model, pad: BasePart): Plaque
	local model = Instance.new("Model")
	model.Name = slot.Name

	-- A slanted board leaning against the pad's front side (the side its hero faces): its low edge on
	-- the ground in front, its high edge at the pad's top edge, its face turned out and up.
	local look = pad.CFrame.LookVector
	local out = Vector3.new(look.X, 0, look.Z)
	out = if out.Magnitude > 0.01 then out.Unit else Vector3.new(0, 0, -1)
	local up = Vector3.yAxis
	local tilt = math.rad(PLAQUE_TILT)
	local normal = out * math.cos(tilt) + up * math.sin(tilt) -- the face the player reads
	local along = up * math.cos(tilt) - out * math.sin(tilt) -- low edge -> high edge
	local width = pad.Size.X * PLAQUE_WIDTH
	local groundY = pad.Position.Y - pad.Size.Y / 2
	-- High edge at the pad's top edge, or higher when the board is too tall to fit under it.
	local highY = math.max(groundY + pad.Size.Y, groundY + 0.1 + PLAQUE_DEPTH * math.cos(tilt))
	local highEdge = pad.Position + out * (pad.Size.Z / 2 + 0.12)
	highEdge = Vector3.new(highEdge.X, highY, highEdge.Z)
	local center = highEdge - along * (PLAQUE_DEPTH / 2)
	-- Part axes: Y = the face, X = down the slope, Z = across. A Top-face SurfaceGui runs its width
	-- along -Z and its height along +X, so this reads upright to someone standing in front.
	local x = -along
	local z = x:Cross(normal)
	local cf = CFrame.fromMatrix(center, x, normal, z)

	local rim = part("Rim", Vector3.new(PLAQUE_DEPTH + RIM * 2, 0.2, width + RIM * 2), cf * CFrame.new(0, -0.05, 0), RIM_COLOR, model)
	rim.Material = Enum.Material.Neon
	rim.Transparency = 0.1
	local board = part("Board", Vector3.new(PLAQUE_DEPTH, 0.2, width), cf, BOARD_COLOR, model)
	board.CanQuery = true
	model.Parent = signs

	local gui = new("SurfaceGui", {
		Name = "PadUpgrade_" .. slot.Name,
		Adornee = board,
		Face = Enum.NormalId.Top,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = PIXELS_PER_STUD,
		LightInfluence = 0,
		MaxDistance = PANEL_MAX_DISTANCE,
		ResetOnSpawn = false,
		Active = true,
	})
	local btn = button({ Text = "", Color = GREEN_BUTTON, Position = UDim2.fromScale(0.04, 0.08), Size = UDim2.fromScale(0.92, 0.84), Parent = gui })
	btn.Name = "Upgrade"
	btn:FindFirstChildOfClass("UIPadding"):Destroy()
	text({ Name = "Label", Text = "UPGRADE", Position = UDim2.fromScale(0.06, 0.08), Size = UDim2.fromScale(0.88, 0.5), StrokeThickness = 3, Parent = btn })
	local levelLabel = text({ Name = "Level", Text = "", Position = UDim2.fromScale(0.1, 0.6), Size = UDim2.fromScale(0.8, 0.3), TextColor3 = Color3.fromRGB(220, 255, 210), Parent = btn })

	local plaque: Plaque = { model = model, board = board, gui = gui, connections = {} }
	local function update()
		local hero = slot:GetAttribute("HeroId")
		local show = slot:GetAttribute("Unlocked") ~= false and typeof(hero) == "string" and HeroConfig.Get(hero) ~= nil
		model.Parent = if show then signs else nil
		gui.Enabled = show
		levelLabel.Text = ("Damage Lv %d"):format(levelOf(slot, "Damage"))
	end
	table.insert(plaque.connections, slot.AttributeChanged:Connect(update))
	table.insert(plaque.connections, btn.Activated:Connect(function()
		pop(btn, 0.9)
		if current and current.slot == slot then
			closeWindow()
		else
			open(slot)
		end
	end))
	gui.Parent = player:WaitForChild("PlayerGui") -- SurfaceGuis only get clicks from PlayerGui
	update()
	return plaque
end

local function clearPlaques()
	for slot, plaque in plaques do
		for _, c in plaque.connections do
			c:Disconnect()
		end
		plaque.gui:Destroy()
		plaque.model:Destroy()
		plaques[slot] = nil
	end
end

-- Keeps one plaque per pad of the plot this player owns (plots are claimed after joining).
local myPlot: Instance? = nil
local function syncPlaques()
	local plots = workspace:FindFirstChild("Plots")
	local found: Instance? = nil
	if plots then
		for _, plot in plots:GetChildren() do
			if plot:GetAttribute("OwnerUserId") == player.UserId then
				found = plot
				break
			end
		end
	end
	if found ~= myPlot then
		clearPlaques()
		myPlot = found
	end
	local slots = found and found:FindFirstChild("HeroSlots")
	if not slots then
		return
	end
	for _, slot in slots:GetChildren() do
		local pad = slot:FindFirstChild("Pad")
		if slot:IsA("Model") and slotNumber(slot) and pad and pad:IsA("BasePart") and not plaques[slot] then
			plaques[slot] = buildPlaque(slot, pad)
		end
	end
end
task.spawn(function()
	while true do
		syncPlaques()
		task.wait(1)
	end
end)

-- Walked away: close.
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < 0.25 or not current then
		return
	end
	acc = 0
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp or not current.pad.Parent or (hrp.Position - current.pad.Position).Magnitude > CLOSE_DISTANCE then
		closeWindow()
	end
end)
