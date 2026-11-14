-- StandUI: the Farm Stand window. Opens from the stand's "Manage Stand" prompt (StandPrompt, F) or the
-- UPGRADE button on its billboard (StandClient sets StandGui attribute "Open" = stand id).
--
-- Shows the stand's level, the total bonus of the keeper heroes and, for the next level, every stat before -> after (StandStats breakdown
-- from the server: Remotes.StandAction "Preview"), the keeper slots and the cost. UPGRADE buys it
-- ("Upgrade"); the window then shows the new level. At max level it says MAX.
-- Tabs: Stand (the above) and Helpers (each helper pad: hero, rarity, carry per trip, speed and what it
-- is doing). Later steps add Upgrades / Fame tabs.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local StandConfig = require(Shared:WaitForChild("StandConfig"))
local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local UIManager = require(script.Parent:WaitForChild("UIManager"))
local Theme = require(script.Parent:WaitForChild("Theme"))
local action = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("StandAction") :: RemoteFunction

local player = Players.LocalPlayer
local abbreviate = HeroConfig.Abbreviate

local FONT = Theme.Font
local PANEL = Theme.Color.Surface
local ROW = Theme.Color.SurfaceInset
local GREEN = Theme.Color.Primary
local GREY = Theme.Color.Disabled
local UP = Color3.fromRGB(110, 255, 120)
local TAB_ON = Theme.Color.Secondary
local DESIGN_SIZE = Vector2.new(460, 506) -- the panel's size at scale 1

local STAT_ROWS = {
	{ stat = "MaxStock", label = "Max Stock", fmt = function(v: number)
		return abbreviate(v)
	end },
	{ stat = "CustomersPerMinute", label = "Customers / min", fmt = function(v: number)
		return tostring(v)
	end },
	{ stat = "MaxItemsPerCustomer", label = "Items / customer", fmt = function(v: number)
		return tostring(v)
	end },
	{ stat = "PriceMultiplier", label = "Sell price", fmt = function(v: number)
		return ("x%.2f"):format(v)
	end },
}

local gui = Instance.new("ScreenGui")
gui.Name = "StandGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 8
gui.Parent = player:WaitForChild("PlayerGui")

local function make(class: string, props: { [string]: any }): any
	local i = Instance.new(class)
	for k, v in props do
		(i :: any)[k] = v
	end
	return i
end

local function text(props: { [string]: any }): TextLabel
	local l = make("TextLabel", { BackgroundTransparency = 1, Font = FONT, TextScaled = true, TextColor3 = Color3.new(1, 1, 1) })
	for k, v in props do
		(l :: any)[k] = v
	end
	make("UIStroke", { Thickness = 2, Color = Color3.fromRGB(15, 15, 20), Parent = l })
	return l
end

local function round(parent: Instance, r: number)
	make("UICorner", { CornerRadius = UDim.new(0, r), Parent = parent })
end

local panel = make("Frame", {
	Name = "Panel",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.45), -- a little high: clears the hotbar on PC
	Size = UDim2.fromOffset(DESIGN_SIZE.X, DESIGN_SIZE.Y),
	BackgroundColor3 = PANEL,
	Visible = false,
	Parent = gui,
})
UIStyle.Panel(panel)
local scale = make("UIScale", { Parent = panel })

-- Fits the fixed-size panel on any screen (phones in landscape are ~375 px tall).
local function fitScale(): number
	local view = gui.AbsoluteSize
	if view.X <= 0 or view.Y <= 0 then
		return 1
	end
	-- Phones hide the hotbar while a window is open (UIManager): use 86% of the height.
	-- PC keeps the hotbar, so stay inside 78% and clear it.
	local maxH = if Theme.IsPhone() then 0.86 else 0.78
	return math.min(1, view.X * 0.92 / DESIGN_SIZE.X, view.Y * maxH / DESIGN_SIZE.Y)
end
gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	if panel.Visible then
		scale.Scale = fitScale()
	end
end)

-- Same window header as every other window: title on the panel, red X top-right.
local header = make("Frame", { Size = UDim2.new(1, 0, 0, 64), BackgroundTransparency = 1, Parent = panel })
local title = text({ Position = UDim2.fromOffset(18, 10), Size = UDim2.new(1, -90, 0, 44), TextXAlignment = Enum.TextXAlignment.Left, Text = "FARM STAND", Parent = header })
local close = make("TextButton", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 12), Size = UDim2.fromOffset(40, 40), BackgroundColor3 = Color3.fromRGB(220, 70, 60), Text = "", Parent = header })
round(close, 10)
text({ Size = UDim2.fromScale(1, 1), Text = "X", Parent = close })
UIStyle.Close(close)

-- Tabs: Stand (level / stats / upgrade) and Helpers (the 3 helper pads).
local tabs = make("Frame", { Position = UDim2.fromOffset(18, 72), Size = UDim2.new(1, -36, 0, 36), BackgroundTransparency = 1, Parent = panel })
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), Parent = tabs })
local function tabButton(name: string): TextButton
	local b = make("TextButton", { Name = name, Size = UDim2.new(0.5, -4, 1, 0), BackgroundColor3 = ROW, Text = "", Parent = tabs })
	round(b, 8)
	UIStyle.Button(b)
	text({ Size = UDim2.fromScale(1, 0.8), Position = UDim2.fromScale(0, 0.1), Text = name, Parent = b })
	return b
end
local standTab = tabButton("Stand")
local helpersTab = tabButton("Helpers")
local standPage = make("Frame", { Position = UDim2.fromOffset(0, 44), Size = UDim2.new(1, 0, 1, -44), BackgroundTransparency = 1, Parent = panel })
local helpersPage = make("Frame", { Position = UDim2.fromOffset(0, 44), Size = UDim2.new(1, 0, 1, -44), BackgroundTransparency = 1, Visible = false, Parent = panel })

local levelLine = text({ Position = UDim2.fromOffset(18, 74), Size = UDim2.new(1, -36, 0, 34), Text = "Level 1  ->  Level 2", TextColor3 = Color3.fromRGB(255, 220, 90), Parent = standPage })

local rowsFrame = make("Frame", { Position = UDim2.fromOffset(18, 116), Size = UDim2.new(1, -36, 0, 210), BackgroundTransparency = 1, Parent = standPage })
make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = rowsFrame })

type Row = { name: TextLabel, now: TextLabel, arrow: TextLabel, nxt: TextLabel }
local rows: { [string]: Row } = {}
local function addRow(key: string, labelText: string, order: number)
	local f = make("Frame", { Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = ROW, LayoutOrder = order, Parent = rowsFrame })
	round(f, 8)
	local name = text({ Position = UDim2.fromOffset(10, 5), Size = UDim2.new(0.5, -10, 1, -10), TextXAlignment = Enum.TextXAlignment.Left, Text = labelText, Parent = f })
	local now = text({ Position = UDim2.new(0.5, 0, 0, 5), Size = UDim2.new(0.2, 0, 1, -10), Text = "", Parent = f })
	local arrow = text({ Position = UDim2.new(0.7, 0, 0, 5), Size = UDim2.new(0.08, 0, 1, -10), Text = ">", TextColor3 = Color3.fromRGB(180, 180, 190), Parent = f })
	local nxt = text({ Position = UDim2.new(0.78, 0, 0, 5), Size = UDim2.new(0.2, 0, 1, -10), Text = "", TextColor3 = UP, Parent = f })
	rows[key] = { name = name, now = now, arrow = arrow, nxt = nxt }
end
for i, r in STAT_ROWS do
	addRow(r.stat, r.label, i)
end
addRow("KeeperSlots", "Keeper slots", #STAT_ROWS + 1)

-- Total bonus from the keeper heroes (their rarity, StandConfig.RarityBonus).
local heroLine = text({ Position = UDim2.fromOffset(18, 330), Size = UDim2.new(1, -36, 0, 28), Text = "", TextColor3 = Color3.fromRGB(255, 210, 120), Parent = standPage })

local upgrade = make("TextButton", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -18), Size = UDim2.new(1, -36, 0, 62), BackgroundColor3 = GREEN, Text = "", AutoButtonColor = true, Parent = standPage })
round(upgrade, 12)
make("UIStroke", { Thickness = 3, Color = Theme.Color.PrimaryDark, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = upgrade })
local upgradeLabel = text({ Size = UDim2.fromScale(1, 1), Text = "UPGRADE", Parent = upgrade })
local pressScale = make("UIScale", { Parent = upgrade })
UIStyle.Button(upgrade)

-- At max level the button is replaced by a small gold MAX badge.
local maxBadge = make("Frame", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -24), Size = UDim2.fromOffset(150, 46), BackgroundColor3 = Theme.Color.Accent, Visible = false, Parent = standPage })
round(maxBadge, 23)
make("UIStroke", { Thickness = 3, Color = Theme.Color.AccentDark, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = maxBadge })
text({ Size = UDim2.fromScale(1, 0.8), Position = UDim2.fromScale(0, 0.1), Text = "MAX", Parent = maxBadge })

-- Helpers page: one card per helper pad.
local helperTitle = text({ Position = UDim2.fromOffset(18, 74), Size = UDim2.new(1, -36, 0, 30), Text = "Helpers carry materials from the chest", TextColor3 = Color3.fromRGB(255, 220, 90), Parent = helpersPage })
type HelperRow = { name: TextLabel, info: TextLabel, state: TextLabel }
local helperRows: { HelperRow } = {}
for i = 1, 3 do
	local f = make("Frame", { Position = UDim2.fromOffset(18, 110 + (i - 1) * 76), Size = UDim2.new(1, -36, 0, 68), BackgroundColor3 = ROW, Parent = helpersPage })
	round(f, 10)
	local name = text({ Position = UDim2.fromOffset(12, 6), Size = UDim2.new(0.68, -12, 0, 30), TextXAlignment = Enum.TextXAlignment.Left, Text = "", Parent = f })
	local info = text({ Position = UDim2.fromOffset(12, 38), Size = UDim2.new(1, -24, 0, 24), TextXAlignment = Enum.TextXAlignment.Left, Text = "", TextColor3 = Color3.fromRGB(200, 205, 220), Parent = f })
	local state = text({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 8), Size = UDim2.new(0.32, 0, 0, 26), TextXAlignment = Enum.TextXAlignment.Right, Text = "", Parent = f })
	helperRows[i] = { name = name, info = info, state = state }
end
local helperTotal = text({ Position = UDim2.fromOffset(18, 342), Size = UDim2.new(1, -36, 0, 28), Text = "", TextColor3 = Color3.fromRGB(255, 210, 120), Parent = helpersPage })
text({ Position = UDim2.fromOffset(18, 376), Size = UDim2.new(1, -36, 0, 24), Text = "Hold a hero and press E on a helper pad next to the chest", TextColor3 = Color3.fromRGB(170, 175, 190), Parent = helpersPage })

local PHASE_TEXT = {
	Idle = { "Resting", Color3.fromRGB(180, 180, 190) },
	ToPickup = { "To the chest", Color3.fromRGB(120, 200, 255) },
	Carrying = { "Carrying", Color3.fromRGB(255, 200, 80) },
	Dropping = { "Restocking", Color3.fromRGB(110, 255, 120) },
	Returning = { "Going home", Color3.fromRGB(120, 200, 255) },
}

local currentTab = "Stand"
local function showTab(name: string)
	currentTab = name
	standPage.Visible = name == "Stand"
	helpersPage.Visible = name == "Helpers"
	standTab.BackgroundColor3 = if name == "Stand" then TAB_ON else ROW
	helpersTab.BackgroundColor3 = if name == "Helpers" then TAB_ON else ROW
end
showTab("Stand")

local openStand: string? = nil
local preview: any = nil
local busy = false

local function money(): number
	local stats = player:FindFirstChild("leaderstats")
	local v = stats and stats:FindFirstChild("Money")
	return if v and v:IsA("ValueBase") then (v :: any).Value else 0
end

local function drawHelpers()
	local total, working = 0, 0
	for i, row in helperRows do
		local h = preview.helpers and preview.helpers[i]
		if h and h.hero then
			row.name.Text = ("%s  (%s)"):format(h.hero, h.rarity or "?")
			HeroConfig.PaintRarity(row.name, h.rarity or "Common")
			row.info.Text = ("Carries %d per trip  -  speed %s"):format(h.carry or 0, tostring(h.speed or 0))
			local p = PHASE_TEXT[h.phase or "Idle"] or PHASE_TEXT.Idle
			row.state.Text = p[1]
			row.state.TextColor3 = p[2]
			total += h.carry or 0
			if h.phase ~= "Idle" then
				working += 1
			end
		else
			row.name.Text = ("Helper slot %d: empty"):format(i)
			row.name.TextColor3 = Color3.fromRGB(170, 175, 190)
			row.info.Text = "Put a hero on this pad to carry materials for you"
			row.state.Text = ""
		end
	end
	helperTotal.Text = ("Total: %d materials per round  -  %d working"):format(total, working)
	helperTitle.Text = "Helpers carry materials from the chest"
end

local function draw()
	if not preview then
		return
	end
	drawHelpers()
	local def = StandConfig.Stands[preview.standId]
	title.Text = string.upper(if def then def.Name else "Farm Stand")
	local maxed = preview.next == nil
	levelLine.Text = if maxed then ("Level %d  (MAX)"):format(preview.level) else ("Level %d  ->  Level %d"):format(preview.level, preview.level + 1)
	for _, r in STAT_ROWS do
		local row = rows[r.stat]
		local now = preview.current[r.stat]
		local nxt = preview.next and preview.next[r.stat]
		row.now.Text = r.fmt(now and now.Final or 0)
		row.nxt.Text = if nxt then r.fmt(nxt.Final) else "-"
		-- Maxed: no "next" column, just the value.
		row.arrow.Visible = not maxed
		row.nxt.Visible = not maxed
		row.nxt.TextColor3 = if nxt and now and nxt.Final > now.Final then UP else Color3.fromRGB(200, 200, 210)
	end
	local cpm = preview.current.CustomersPerMinute
	local stock = preview.current.MaxStock
	local heroCpm = if cpm then cpm.Heroes else 0
	local heroStock = if stock then stock.Heroes else 0
	heroLine.Text = if heroCpm > 0 or heroStock > 0
		then ("Keeper heroes: +%s customers/min  +%s max stock"):format(tostring(heroCpm), abbreviate(heroStock))
		else "Put heroes on the keeper pads for bonus customers and stock"
	local keepers = rows.KeeperSlots
	keepers.now.Text = tostring(preview.keeperSlots or 0)
	keepers.nxt.Text = if preview.nextKeeperSlots then tostring(preview.nextKeeperSlots) else "-"
	keepers.arrow.Visible = not maxed
	keepers.nxt.Visible = not maxed
	keepers.nxt.TextColor3 = if preview.nextKeeperSlots and preview.nextKeeperSlots > (preview.keeperSlots or 0) then UP else Color3.fromRGB(200, 200, 210)
	upgrade.Visible = not maxed
	maxBadge.Visible = maxed
	if maxed then
		upgradeLabel.Text = "MAX LEVEL"
	else
		local cost = preview.cost or 0
		upgradeLabel.Text = ("UPGRADE  $%s"):format(abbreviate(cost))
		upgrade.BackgroundColor3 = if money() >= cost then GREEN else GREY
	end
end

local function load(standId: string)
	local ok, result = pcall(action.InvokeServer, action, "Preview", standId)
	if ok and typeof(result) == "table" and result.ok then
		preview = result.preview
		draw()
	end
end

local function setOpen(standId: string?)
	openStand = standId
	if standId then
		panel.Visible = true
		local target = fitScale()
		scale.Scale = target * 0.85
		TweenService:Create(scale, Theme.Tween.Open, { Scale = target }):Play()
		load(standId)
	else
		panel.Visible = false
	end
	gui:SetAttribute("Open", standId)
end

-- One window at a time; dims the world, hides the HUD on phones (UIManager).
UIManager.Register("Stand", panel, function()
	setOpen(nil)
end)

close.Activated:Connect(function()
	setOpen(nil)
end)
standTab.Activated:Connect(function()
	showTab("Stand")
end)
helpersTab.Activated:Connect(function()
	showTab("Helpers")
	if openStand then
		load(openStand) -- fresh helper states
	end
end)

upgrade.Activated:Connect(function()
	if busy or not openStand or not preview or not preview.next then
		return
	end
	busy = true
	pressScale.Scale = 0.92
	TweenService:Create(pressScale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	upgradeLabel.Text = "..."
	local ok, result = pcall(action.InvokeServer, action, "Upgrade", openStand)
	if ok and typeof(result) == "table" and result.ok and result.preview then
		preview = result.preview
	end
	draw()
	busy = false
end)

gui:GetAttributeChangedSignal("Open"):Connect(function()
	local want = gui:GetAttribute("Open")
	if typeof(want) == "string" and want ~= openStand then
		setOpen(want)
	elseif want == nil and openStand then
		setOpen(nil)
	end
end)

ProximityPromptService.PromptTriggered:Connect(function(prompt)
	if prompt.Name == "StandPrompt" then
		local standId = prompt:GetAttribute("StandId")
		if typeof(standId) == "string" then
			setOpen(standId)
		end
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.Escape and openStand then
		setOpen(nil)
	end
end)

-- Money changes: the UPGRADE button turns green / grey.
task.spawn(function()
	local stats = player:WaitForChild("leaderstats")
	local v = stats:WaitForChild("Money") :: ValueBase
	(v :: any).Changed:Connect(function()
		if openStand then
			draw()
		end
	end)
end)
