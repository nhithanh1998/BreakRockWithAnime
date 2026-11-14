-- DailyRewardUI: the "7 DAY LOGIN REWARDS!" window (rules and rewards in Shared.DailyRewardConfig,
-- server side in DailyRewardService).
--
-- Left: the Day 7 prize hero, "LOGIN REWARDS" and the subtitle. Right: the title, "x/7 Days",
-- the "Next Claim" timer, CLAIM ALL and one card per day (4 on the first row, the rest under it;
-- a Big day stretches over the free columns). A card is CLAIMED (green ✓), CLAIM! (gold, pulsing,
-- click to claim) or LOCKED (dark, 🔒).
--
-- Opens from the "Daily" button in StarterGui.LeftSidebar.Buttons (src/gui/LeftSidebar.model.json; its Badge
-- = days ready to claim) and by itself after joining when something can be claimed
-- (DailyRewardConfig.OpenOnJoin). State comes from the player attributes DailyUnlocked /
-- DailyClaimed / DailyNextAt / DailyReady; claims go through Remotes.DailyRewardAction.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DailyRewardConfig = require(Shared:WaitForChild("DailyRewardConfig"))
local FruitConfig = require(Shared:WaitForChild("FruitConfig"))
local TreeConfig = require(Shared:WaitForChild("TreeConfig"))
local ItemDisplay = require(script.Parent:WaitForChild("ItemDisplay"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local Theme = require(script.Parent:WaitForChild("Theme"))
local UIManager = require(script.Parent:WaitForChild("UIManager"))
local DailyRewardAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DailyRewardAction") :: RemoteFunction

type Reward = DailyRewardConfig.Reward

local player = Players.LocalPlayer
local MAX = DailyRewardConfig.MaxDays

local WIDTH, HEIGHT = 1000, 500
local FONT = Theme.Font
local BG_TOP = Color3.fromRGB(58, 34, 96)
local BG_BOTTOM = Color3.fromRGB(24, 20, 44)
local GOLD = Theme.Color.Accent
local GOLD_DARK = Theme.Color.AccentDark
local GREEN = Color3.fromRGB(70, 210, 90)
local GREEN_BUTTON = Theme.Color.Primary
local CLOSE_COLOR = Theme.Color.Danger
local DARK = Color3.fromRGB(16, 14, 22)
local ERROR_COLOR = Color3.fromRGB(255, 110, 100)

-- UI helpers ------------------------------------------------------------------------------------------

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
	local thickness = props.StrokeThickness or 2
	props.StrokeThickness = nil
	props.BackgroundTransparency = 1
	props.Font = props.Font or FONT
	props.TextScaled = true
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	local label = new("TextLabel", props)
	stroke(DARK, thickness).Parent = label
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
		ZIndex = props.ZIndex or 1,
		Parent = props.Parent,
	}, {
		corner(props.Radius or 8),
		new("UIPadding", { PaddingTop = UDim.new(0.18, 0), PaddingBottom = UDim.new(0.18, 0), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
	})
	stroke(props.Color:Lerp(Color3.new(1, 1, 1), 0.35), 2, true).Parent = b
	stroke(DARK, 1.5).Parent = b
	UIStyle.Button(b)
	return b
end

local function formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local h, m, s = seconds // 3600, (seconds % 3600) // 60, seconds % 60
	if h > 0 then
		return ("%dh, %dm, %ds"):format(h, m, s)
	elseif m > 0 then
		return ("%dm, %ds"):format(m, s)
	end
	return ("%ds"):format(s)
end

-- Reward pictures -------------------------------------------------------------------------------------

local function rewardRarity(reward: Reward): string?
	if reward.Kind == "Hero" and reward.Name then
		local hero = TreeConfig.GetHero(reward.Name)
		return hero and hero.Rarity
	elseif reward.Kind == "Fruit" and reward.Id then
		local fruit = FruitConfig.Get(reward.Id)
		return fruit and fruit.Rarity
	elseif reward.Kind == "Material" and reward.Key then
		return ItemDisplay.Info(reward.Key).rarity
	end
	return nil
end

local function rewardName(reward: Reward): string
	local amount = reward.Amount or 1
	if reward.Kind == "Money" then
		return "x" .. ItemDisplay.Abbreviate(amount) .. " Money"
	elseif reward.Kind == "Fertilizer" then
		return ("x%d %s"):format(amount, FruitConfig.FertilizerName)
	elseif reward.Kind == "Hero" then
		return reward.Name or "?"
	elseif reward.Kind == "Fruit" and reward.Id then
		local fruit = FruitConfig.Get(reward.Id)
		return if fruit then fruit.Name else reward.Id
	elseif reward.Kind == "Material" and reward.Key then
		return ("x%d %s"):format(amount, ItemDisplay.Info(reward.Key).name)
	end
	return "?"
end

-- Draws the reward inside `holder` (a ViewportFrame for heroes / fruits / materials, an emoji for
-- money and fertilizer).
local function drawReward(holder: Frame, reward: Reward, zIndex: number)
	holder:ClearAllChildren()
	local emoji = if reward.Kind == "Money" then "💰" elseif reward.Kind == "Fertilizer" then "🧪" else nil
	if emoji then
		new("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Text = emoji,
			TextScaled = true,
			Font = FONT,
			ZIndex = zIndex,
			Parent = holder,
		})
		return
	end
	local view = new("ViewportFrame", {
		Name = "View",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex,
		Parent = holder,
	})
	if reward.Kind == "Hero" and reward.Name then
		ItemDisplay.FillHeroViewport(view, reward.Name)
	elseif reward.Kind == "Fruit" and reward.Id then
		ItemDisplay.FillFruitViewport(view, reward.Id)
	elseif reward.Kind == "Potion" and reward.Id then
		ItemDisplay.FillPotionViewport(view, reward.Id)
	elseif reward.Kind == "Material" and reward.Key then
		local info = ItemDisplay.Info(reward.Key)
		if info.image then
			ItemDisplay.ShowImage(view, info.image)
		else
			ItemDisplay.FillViewport(view, info.visual, reward.Key)
		end
	end
end

-- Window ------------------------------------------------------------------------------------------

local gui = new("ScreenGui", {
	Name = "DailyRewardGui",
	DisplayOrder = 13,
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = player:WaitForChild("PlayerGui"),
})

local root = new("Frame", {
	Name = "Window",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(WIDTH, HEIGHT),
	BackgroundColor3 = Color3.new(1, 1, 1),
	Visible = false,
	Parent = gui,
}, {
	corner(14),
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(BG_TOP, BG_BOTTOM) }),
})
stroke(GOLD, 4, true).Parent = root
local openScale = new("UIScale", { Parent = root })

local fitScale = 1
local function fit()
	local cam = workspace.CurrentCamera
	if cam then
		local vp = cam.ViewportSize
		fitScale = math.min(1, (vp.X - 24) / WIDTH, (vp.Y - 24) / HEIGHT)
	end
end
fit()
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		fit()
		if root.Visible then
			openScale.Scale = fitScale
		end
	end)
end

-- Gold bands along the top and bottom edge (the "banner" look).
for _, y in { 0, 1 } do
	new("Frame", {
		AnchorPoint = Vector2.new(0, y),
		Position = UDim2.fromScale(0, y),
		Size = UDim2.new(1, 0, 0, 6),
		BackgroundColor3 = GOLD,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = root,
	}, { new("UIGradient", { Color = ColorSequence.new(GOLD_DARK, GOLD) }) })
end

-- Left: the Day 7 prize ---------------------------------------------------------------------------------

local left = new("Frame", {
	Name = "Showcase",
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(16, 16),
	Size = UDim2.fromOffset(360, HEIGHT - 32),
	ClipsDescendants = true,
	Parent = root,
})
local showcase = new("Frame", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(10, 0),
	Size = UDim2.new(1, -20, 0, 330),
	ZIndex = 2,
	Parent = left,
})
local glow = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(300, 300),
	BackgroundColor3 = GOLD,
	BackgroundTransparency = 0.75,
	ZIndex = 1,
	Parent = showcase,
}, { corner(150), new("UIGradient", { Transparency = NumberSequence.new(0.2, 1) }) })
text({
	Text = "LOGIN",
	Position = UDim2.fromOffset(4, 300),
	Size = UDim2.fromOffset(200, 54),
	TextXAlignment = Enum.TextXAlignment.Left,
	StrokeThickness = 3,
	ZIndex = 3,
	Parent = left,
})
local rewardsTag = new("Frame", {
	Position = UDim2.fromOffset(70, 350),
	Size = UDim2.fromOffset(120, 28),
	BackgroundColor3 = DARK,
	ZIndex = 3,
	Parent = left,
}, { corner(4) })
text({ Text = "REWARDS", Size = UDim2.fromScale(1, 1), ZIndex = 4, Parent = rewardsTag })
local subtitleBox = new("Frame", {
	Position = UDim2.fromOffset(0, 388),
	Size = UDim2.new(1, 0, 0, 76),
	BackgroundColor3 = DARK,
	BackgroundTransparency = 0.25,
	ZIndex = 3,
	Parent = left,
}, { corner(8), new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }) })
text({
	Text = DailyRewardConfig.Subtitle,
	Size = UDim2.fromScale(1, 1),
	TextXAlignment = Enum.TextXAlignment.Left,
	TextWrapped = true,
	ZIndex = 4,
	Parent = subtitleBox,
})

-- The showcase draws the first reward of the last (biggest) day.
local bigDay = DailyRewardConfig.Days[MAX]
drawReward(showcase, bigDay.Rewards[1], 2)

-- Right: header ---------------------------------------------------------------------------------------

local RIGHT_X = 392
local RIGHT_W = WIDTH - RIGHT_X - 16

-- Gold banner behind the header and the cards (drawn under everything else on the right).
local goldPanel = new("Frame", {
	Name = "GoldPanel",
	Position = UDim2.fromOffset(RIGHT_X - 12, 10),
	Size = UDim2.new(1, -(RIGHT_X - 12) - 10, 1, -20),
	BackgroundColor3 = Color3.new(1, 1, 1),
	ZIndex = 0,
	Parent = root,
}, {
	corner(10),
	new("UIGradient", {
		Rotation = 100,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(196, 140, 28)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(232, 182, 52)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(176, 120, 22)),
		}),
	}),
})
stroke(Color3.fromRGB(255, 226, 120), 2, true).Parent = goldPanel

local title = text({
	Text = "",
	RichText = true,
	Position = UDim2.fromOffset(RIGHT_X, 18),
	Size = UDim2.fromOffset(RIGHT_W - 70, 42),
	TextXAlignment = Enum.TextXAlignment.Left,
	StrokeThickness = 3.5,
	Parent = root,
})
do
	-- "7 DAY" in gold, the rest white.
	local first, rest = DailyRewardConfig.Title:match("^(%S+%s+%S+)%s+(.*)$")
	title.Text = if first
		then ('<font color="#FFD447">%s</font> %s'):format(first, rest)
		else DailyRewardConfig.Title
end
local closeButton = button({
	Text = "X",
	Color = CLOSE_COLOR,
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -14, 0, 14),
	Size = UDim2.fromOffset(48, 48),
	Parent = root,
})
UIStyle.Close(closeButton)

-- Dark pill: [🗓 x/7 Days] Next Claim: <gold time>
local infoPill = new("Frame", {
	Position = UDim2.fromOffset(RIGHT_X, 66),
	Size = UDim2.fromOffset(380, 36),
	BackgroundColor3 = Color3.fromRGB(22, 20, 26),
	Parent = root,
}, {
	corner(18),
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
	new("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 12) }),
})
stroke(Color3.fromRGB(70, 60, 40), 2, true).Parent = infoPill
local daysChip = new("Frame", {
	Size = UDim2.fromOffset(118, 28),
	BackgroundColor3 = Color3.fromRGB(48, 44, 56),
	LayoutOrder = 1,
	Parent = infoPill,
}, { corner(14), new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4) }) })
local daysLabel = text({ Text = "🗓 0/7 Days", Size = UDim2.fromScale(1, 1), Parent = daysChip })
local timerLabel = text({
	Text = "",
	RichText = true,
	Size = UDim2.fromOffset(230, 22),
	LayoutOrder = 2,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = infoPill,
})
local claimAllButton = button({
	Text = "CLAIM ALL",
	Color = GREEN_BUTTON,
	Radius = 18,
	Position = UDim2.fromOffset(RIGHT_X + 392, 65),
	Size = UDim2.fromOffset(150, 38),
	Parent = root,
})
new("UIGradient", {
	Rotation = 90,
	Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(170, 200, 170)),
	Parent = claimAllButton,
})
local messageLabel = text({
	Text = "",
	TextColor3 = ERROR_COLOR,
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, RIGHT_X, 1, -4),
	Size = UDim2.fromOffset(RIGHT_W, 16),
	ZIndex = 8,
	Parent = root,
})

-- Right: day cards ------------------------------------------------------------------------------------
-- Dark cards with a gold-brown edge. Currency days (and the Big day) have a large "Day N" sticking
-- out of the top edge and a big lock over the picture; hero days have a small "Day N" in the corner and
-- a small lock beside the hero. Locked pictures are greyed out.

local GRID_TOP = 128
local COLS = 4
local GAP = 10
local ROW_GAP = 14
local CARD_W = (RIGHT_W - GAP * (COLS - 1)) / COLS
local CARD_H = (HEIGHT - GRID_TOP - 24 - ROW_GAP) / 2

local CARD_TOP = Color3.fromRGB(50, 44, 38)
local CARD_BOTTOM = Color3.fromRGB(18, 16, 16)
local CARD_EDGE = Color3.fromRGB(96, 70, 30)
local DAY_GOLD = Color3.fromRGB(255, 214, 90)
local NAME_GREY = Color3.fromRGB(200, 198, 204)
local DIM = Color3.fromRGB(105, 105, 115)

type Card = {
	frame: TextButton,
	stroke: UIStroke,
	status: TextLabel,
	check: TextLabel,
	lock: TextLabel,
	picture: Frame,
	extras: Frame,
	big: boolean,
	pulse: Tween?,
}
local cards: { Card } = {}

-- Text emojis inside reward pictures get this name so tint() can grey them out.
local function markEmojis(holder: Instance)
	for _, d in holder:GetDescendants() do
		if d:IsA("TextLabel") then
			d.Name = "Emoji"
		end
	end
end

-- Greys a reward picture out (locked) or shows it in full color.
local function tint(holder: Instance, dim: boolean)
	local color = if dim then DIM else Color3.new(1, 1, 1)
	for _, d in holder:GetDescendants() do
		if d:IsA("ViewportFrame") or d:IsA("ImageLabel") then
			d.ImageColor3 = color
		elseif d:IsA("TextLabel") and d.Name == "Emoji" then
			d.TextTransparency = if dim then 0.5 else 0
		elseif d:IsA("TextLabel") and d.Name == "Amount" then
			d.TextColor3 = if dim then NAME_GREY:Lerp(DIM, 0.5) else Color3.new(1, 1, 1)
		end
	end
end

local function makeCard(day: number, def: DailyRewardConfig.Day, col: number, row: number, span: number)
	local main = def.Rewards[1]
	local bigLabel = def.Big == true or (main ~= nil and main.Kind ~= "Hero")
	local frame = new("TextButton", {
		Name = "Day" .. day,
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Position = UDim2.fromOffset(RIGHT_X + col * (CARD_W + GAP), GRID_TOP + row * (CARD_H + ROW_GAP)),
		Size = UDim2.fromOffset(CARD_W * span + GAP * (span - 1), CARD_H),
		Parent = root,
	}, {
		corner(8),
		new("UIGradient", { Rotation = 90, Color = ColorSequence.new(CARD_TOP, CARD_BOTTOM) }),
	})
	local cardStroke = stroke(CARD_EDGE, 2.5, true)
	cardStroke.Parent = frame

	-- Soft diagonal sheen across the top half.
	new("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.9,
		Size = UDim2.new(1, 0, 0.55, 0),
		ZIndex = 1,
		Parent = frame,
	}, {
		corner(8),
		new("UIGradient", {
			Rotation = 60,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.3),
				NumberSequenceKeypoint.new(0.5, 0.85),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}),
	})

	-- Day label
	if bigLabel then
		text({
			Text = "Day " .. day,
			TextColor3 = DAY_GOLD,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, 2),
			Size = UDim2.fromOffset(96, 30),
			StrokeThickness = 3,
			ZIndex = 9,
			Parent = frame,
		})
	else
		text({
			Text = "Day " .. day,
			Position = UDim2.fromOffset(9, 6),
			Size = UDim2.fromOffset(64, 22),
			TextXAlignment = Enum.TextXAlignment.Left,
			StrokeThickness = 2.5,
			ZIndex = 9,
			Parent = frame,
		})
	end

	-- Rarity glow + main reward picture
	local picH = CARD_H * 0.46
	local picTop = if bigLabel then 22 else 20
	local rarity = main and rewardRarity(main)
	if rarity then
		new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, picTop),
			Size = UDim2.fromOffset(picH * 1.15, picH),
			BackgroundColor3 = ItemDisplay.SlotColor(rarity),
			BackgroundTransparency = 0.55,
			ZIndex = 1,
			Parent = frame,
		}, {
			corner(math.floor(picH / 2)),
			new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(0.4, 1) }),
		})
	end
	local picture = new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, picTop),
		Size = UDim2.fromOffset(math.min(CARD_W - 20, picH * 1.15), picH),
		ZIndex = 2,
		Parent = frame,
	})
	if main then
		drawReward(picture, main, 2)
		markEmojis(picture)
	end
	text({
		Text = if main then rewardName(main) else "",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, picTop + picH - 8),
		Size = UDim2.new(1, -12, 0, 17),
		TextColor3 = NAME_GREY,
		ZIndex = 4,
		Parent = frame,
	})

	-- Extra rewards: small icons with their amount
	local extras = new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, picTop + picH + 12),
		Size = UDim2.new(1, -10, 0, 22),
		ZIndex = 2,
		Parent = frame,
	}, {
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for i = 2, #def.Rewards do
		local reward = def.Rewards[i]
		local chip = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(50, 22), LayoutOrder = i, ZIndex = 2, Parent = extras })
		local icon = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(22, 22), ZIndex = 2, Parent = chip })
		drawReward(icon, reward, 2)
		markEmojis(icon)
		local amountText = if reward.Kind == "Money" then ItemDisplay.Abbreviate(reward.Amount or 1) else tostring(reward.Amount or 1)
		text({
			Name = "Amount",
			Text = "x" .. amountText,
			Position = UDim2.fromOffset(24, 5),
			Size = UDim2.fromOffset(26, 13),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 3,
			Parent = chip,
		})
		-- Hover tip: full name of the extra reward
		local tip = text({ Text = rewardName(reward), Visible = false, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0, -2), Size = UDim2.fromOffset(140, 16), ZIndex = 10, Parent = chip })
		chip.MouseEnter:Connect(function()
			tip.Visible = true
		end)
		chip.MouseLeave:Connect(function()
			tip.Visible = false
		end)
	end

	-- Lock: big over the picture on currency / Big days, small beside the hero on hero days.
	local lockSize = if bigLabel then picH * 0.6 else 20
	local lock = text({
		Text = "🔒",
		AnchorPoint = if bigLabel then Vector2.new(0.5, 0.5) else Vector2.new(1, 0.5),
		Position = if bigLabel then UDim2.new(0.5, 0, 0, picTop + picH * 0.5) else UDim2.new(1, -8, 0, picTop + picH * 0.62),
		Size = UDim2.fromOffset(lockSize, lockSize),
		ZIndex = 6,
		Parent = frame,
	})
	local check = text({
		Text = "✓", -- not "✔": that one is drawn as an emoji and ignores TextColor3
		TextColor3 = GREEN,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0, picTop + picH * 0.62),
		Size = UDim2.fromOffset(24, 24),
		StrokeThickness = 2.5,
		ZIndex = 6,
		Parent = frame,
	})
	local status = text({
		Text = "LOCKED",
		RichText = true,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -5),
		Size = UDim2.new(1, -16, 0, 21),
		ZIndex = 6,
		StrokeThickness = 3,
		Parent = frame,
	})

	local card: Card = {
		frame = frame,
		stroke = cardStroke,
		status = status,
		check = check,
		lock = lock,
		picture = picture,
		extras = extras,
		big = def.Big == true,
	}
	cards[day] = card
	return card
end

do
	local col, row = 0, 0
	for day, def in DailyRewardConfig.Days do
		if col >= COLS then
			col, row = 0, row + 1
		end
		local span = if def.Big then COLS - col else 1
		makeCard(day, def, col, row, span)
		col += span
	end
end

-- Sidebar button --------------------------------------------------------------------------------------

local sidebar = player.PlayerGui:WaitForChild("LeftSidebar") :: ScreenGui
local sidebarButtons = sidebar:WaitForChild("Buttons")
local openButton = sidebarButtons:WaitForChild("Daily") :: GuiButton
local badge = openButton:FindFirstChild("Badge") :: GuiObject?
local badgeCount = badge and badge:FindFirstChild("Count") :: TextLabel?

-- State -----------------------------------------------------------------------------------------------

local busy = false

local function unlocked(): number
	local n = player:GetAttribute("DailyUnlocked")
	return if typeof(n) == "number" then n else 0
end

local function claimedMask(): number
	local n = player:GetAttribute("DailyClaimed")
	return if typeof(n) == "number" then n else 0
end

local function claimableCount(): number
	if player:GetAttribute("DailyReady") ~= true then
		return 0
	end
	local count = 0
	local mask = claimedMask()
	for d = 1, math.min(unlocked(), MAX) do
		if not DailyRewardConfig.IsClaimed(mask, d) then
			count += 1
		end
	end
	return count
end

local function setPulse(card: Card, on: boolean)
	if on and not card.pulse then
		card.stroke.Color = GOLD
		card.stroke.Thickness = 3
		local tween = TweenService:Create(card.stroke, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Thickness = 5 })
		tween:Play()
		card.pulse = tween
	elseif not on and card.pulse then
		card.pulse:Cancel()
		card.pulse = nil
		card.stroke.Color = CARD_EDGE
		card.stroke.Thickness = 2.5
	end
end

local STRIPES = '<font color="#6E6A78">//////</font>'
local function statusText(card: Card, word: string, color: string): string
	local body = ('<font color="%s">%s</font>'):format(color, word)
	return if card.big then ("%s  %s  %s"):format(STRIPES, body, STRIPES) else body
end

local function refresh()
	local n = unlocked()
	local mask = claimedMask()
	local claimable = claimableCount()
	local isReady = player:GetAttribute("DailyReady") == true
	local claimedCount = 0
	for day, card in cards do
		local isClaimed = DailyRewardConfig.IsClaimed(mask, day)
		local isOpen = day <= n
		if isClaimed then
			claimedCount += 1
		end
		card.check.Visible = isClaimed
		card.lock.Visible = not isOpen
		tint(card.picture, not isOpen)
		tint(card.extras, not isOpen)
		if isClaimed then
			card.status.Text = statusText(card, "CLAIMED", "#46D25A")
		elseif isOpen and isReady then
			card.status.Text = statusText(card, "CLAIM!", "#FFD447")
		elseif isOpen then
			-- State not loaded yet: don't promise a claim the server may refuse.
			card.status.Text = statusText(card, "...", "#FFFFFF")
		else
			card.status.Text = statusText(card, "LOCKED", "#FFFFFF")
		end
		setPulse(card, isOpen and not isClaimed and isReady)
	end
	daysLabel.Text = ("🗓 %d/%d Days"):format(claimedCount, MAX)
	-- One CTA at a time: a single ready day is claimed on its (pulsing) card; CLAIM ALL only shows
	-- when there are several.
	claimAllButton.Visible = claimable > 1
	if badge then
		badge.Visible = claimable > 0
	end
	if badgeCount then
		badgeCount.Text = tostring(claimable)
	end
end

local function updateTimer()
	local nextAt = player:GetAttribute("DailyNextAt")
	if player:GetAttribute("DailyReady") ~= true then
		timerLabel.Text = "Loading..."
		return
	end
	if typeof(nextAt) ~= "number" then
		timerLabel.Text = ""
		return
	end
	local left = nextAt - workspace:GetServerTimeNow()
	local allDone = unlocked() >= MAX and claimableCount() == 0
	local caption = if allDone then "New streak" elseif unlocked() >= MAX then "Streak full" else "Next Claim"
	if unlocked() >= MAX and not allDone then
		timerLabel.Text = '<font color="#FFC83C">Claim your rewards!</font>'
	elseif left <= 0 then
		timerLabel.Text = caption .. ': <font color="#FFC83C">unlocking...</font>'
	else
		timerLabel.Text = ('%s: <font color="#FFC83C">%s</font>'):format(caption, formatTime(left))
	end
end

-- Open / close ----------------------------------------------------------------------------------------

local function open()
	if root.Visible then
		return
	end
	refresh()
	updateTimer()
	messageLabel.Text = ""
	root.Visible = true
	openScale.Scale = fitScale * 0.85
	TweenService:Create(openScale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = fitScale }):Play()
end

local function close()
	root.Visible = false
end

-- One window at a time; dims the world, hides the HUD on phones (UIManager).
UIManager.Register("Daily", root, close)

local function showMessage(message: string?)
	messageLabel.Text = message or ""
	if message then
		task.delay(3, function()
			if messageLabel.Text == message then
				messageLabel.Text = ""
			end
		end)
	end
end

local function popCard(day: number)
	local card = cards[day]
	if not card then
		return
	end
	local scale = card.frame:FindFirstChildOfClass("UIScale") or new("UIScale", { Parent = card.frame })
	scale.Scale = 1.12
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function claim(action: string, day: number?)
	if busy then
		return
	end
	busy = true
	local ok, result = pcall(function()
		return DailyRewardAction:InvokeServer(action, day)
	end)
	busy = false
	if not ok or typeof(result) ~= "table" then
		showMessage("Couldn't claim right now, try again.")
		return
	end
	if result.ok then
		showMessage(nil)
		for _, d in result.claimed or {} do
			popCard(d)
		end
	else
		showMessage(result.message)
	end
	refresh()
end

for day, card in cards do
	card.frame.Activated:Connect(function()
		local isOpen = day <= unlocked()
		if isOpen and not DailyRewardConfig.IsClaimed(claimedMask(), day) then
			claim("Claim", day)
		elseif not isOpen then
			showMessage(("Day %d unlocks after you log in on %d more day(s)."):format(day, day - unlocked()))
		end
	end)
end
claimAllButton.Activated:Connect(function()
	claim("ClaimAll")
end)
closeButton.Activated:Connect(close)
local sidebarOpen = openButton :: GuiButton
sidebarOpen.Activated:Connect(function()
	if root.Visible then
		close()
	else
		open()
	end
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.Escape and root.Visible then
		close()
	end
end)

-- Live updates ---------------------------------------------------------------------------------------

local openedOnJoin = false
local function onStateChanged()
	refresh()
	updateTimer()
	if DailyRewardConfig.OpenOnJoin and not openedOnJoin and claimableCount() > 0 then
		openedOnJoin = true
		task.delay(2, open) -- let the loading / zone intro settle first
	end
end
for _, name in { "DailyUnlocked", "DailyClaimed", "DailyNextAt", "DailyReady" } do
	player:GetAttributeChangedSignal(name):Connect(onStateChanged)
end
onStateChanged()

-- Slow spin of the showcase glow + the timer, only while the window is open.
task.spawn(function()
	while true do
		task.wait(1)
		if root.Visible then
			updateTimer()
			glow.Rotation = (glow.Rotation + 6) % 360
		end
	end
end)
