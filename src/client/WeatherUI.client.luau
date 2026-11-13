-- WeatherUI: shows the server weather (WeatherConfig / WeatherService).
--
--   Announcement  when a weather starts: big "⛈️ THUNDERSTORM!" in the weather's colour, its
--                 description and buffs, popping in for a few seconds in the middle of the screen.
--   Icon          a round badge right under the money strip (MoneyGui.Strip) with the weather's
--                 emoji and a countdown below it (time left, red in the last 30 s; or, with SHOW_NEXT,
--                 time until the next random weather while the sky is clear).
--                 Hover (tap on touch screens) shows a tooltip: name, description, buffs, time.
--   Ended toast   "Thunderstorm is over" for a moment when it ends.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local WeatherConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeatherConfig"))

local player = Players.LocalPlayer
local FONT = Enum.Font.FredokaOne
local STROKE = Color3.fromRGB(20, 20, 26)
local SHOW_NEXT = true -- "Random Weather In 12:34" while the sky is clear (false = weather is a surprise)

local function new(className: string, props: { [string]: any }, children: { Instance }?): any
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	for _, c in children or {} do
		c.Parent = inst
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function stroke(thickness: number, color: Color3?): UIStroke
	return new("UIStroke", { Thickness = thickness, Color = color or STROKE })
end

local function label(props: { [string]: any }): TextLabel
	props.BackgroundTransparency = 1
	props.Font = FONT
	props.TextScaled = true
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	local t = props.StrokeThickness or 2
	props.StrokeThickness = nil
	local l = new("TextLabel", props)
	stroke(t).Parent = l
	return l
end

local function tween(inst: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?)
	local tw = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return ("%d:%02d"):format(seconds // 60, seconds % 60)
end

local gui = new("ScreenGui", { Name = "WeatherGui", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 5, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = player:WaitForChild("PlayerGui") })

-- Icon (under the money strip) ---------------------------------------------------------------------

local CLEAR_ICON = "🌤️"
local CLEAR_COLOR = Color3.fromRGB(150, 160, 180)
local PANEL = Color3.fromRGB(28, 30, 40)

local widget = new("Frame", { Name = "Weather", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0.5, 0), Size = UDim2.fromOffset(52, 72), Parent = gui })
local iconButton = new("TextButton", {
	Name = "Icon",
	AutoButtonColor = false,
	Text = "",
	Size = UDim2.fromScale(1, 1),
	SizeConstraint = Enum.SizeConstraint.RelativeXX, -- square, as wide as the widget
	BackgroundColor3 = PANEL,
	BackgroundTransparency = 0.15,
	Parent = widget,
}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
local iconStroke = stroke(3, CLEAR_COLOR)
iconStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
iconStroke.Parent = iconButton
local iconScale = new("UIScale", { Parent = iconButton })
local iconEmoji = new("TextLabel", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.68, 0.68), Font = FONT, TextScaled = true, Text = CLEAR_ICON, Parent = iconButton })
local countdown = label({ Name = "Time", Text = "", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.fromScale(1.7, 0.27), StrokeThickness = 2, Parent = widget })

-- Tooltip: opens to the left of the icon.
local tooltip = new("Frame", {
	Name = "Tooltip",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(0, -10, 0, 0),
	Size = UDim2.fromOffset(250, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = PANEL,
	BackgroundTransparency = 0.08,
	Visible = false,
	ZIndex = 10,
	Parent = widget,
}, {
	new("UICorner", { CornerRadius = UDim.new(0, 10) }),
	new("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 10), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
})
local tipStroke = stroke(2, CLEAR_COLOR)
tipStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
tipStroke.Parent = tooltip

local function tipText(order: number, size: number, color: Color3?): TextLabel
	local t = new("TextLabel", {
		LayoutOrder = order,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = FONT,
		TextSize = size,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = color or Color3.new(1, 1, 1),
		Text = "",
		ZIndex = 11,
		Parent = tooltip,
	})
	stroke(1.5).Parent = t
	return t
end
local tipTitle = tipText(1, 20)
local tipDesc = tipText(2, 14, Color3.fromRGB(215, 220, 235))
local tipBuffs = tipText(3, 15)
local tipTime = tipText(4, 15, Color3.fromRGB(235, 240, 255))

local hovering, pinned = false, false
local function showTooltip()
	tooltip.Visible = hovering or pinned
end
iconButton.MouseEnter:Connect(function()
	hovering = true
	showTooltip()
end)
iconButton.MouseLeave:Connect(function()
	hovering = false
	showTooltip()
end)
iconButton.Activated:Connect(function() -- touch screens have no hover: tap toggles it
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		pinned = not pinned
		showTooltip()
	end
end)

-- Follow the money strip: the icon sits right under it, right-aligned with the "$" amount.
task.spawn(function()
	local moneyGui = player:WaitForChild("PlayerGui"):WaitForChild("MoneyGui", 15)
	local strip = if moneyGui then moneyGui:WaitForChild("Strip", 5) :: Frame? else nil
	if not strip then
		return -- keep the fallback position
	end
	local function place()
		local pos, size = strip.AbsolutePosition, strip.AbsoluteSize
		local s = math.clamp(size.Y * 1.05, 42, 72)
		widget.Size = UDim2.fromOffset(s, s * 1.37)
		widget.Position = UDim2.fromOffset(pos.X + size.X - 14, pos.Y + size.Y + 6)
	end
	strip:GetPropertyChangedSignal("AbsolutePosition"):Connect(place)
	strip:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
	place()
end)

local function pop()
	iconScale.Scale = 0.5
	tween(iconScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
end

-- Announcement ----------------------------------------------------------------------------------------

local function announce(def: WeatherConfig.WeatherDef)
	local holder = new("Frame", { Name = "Announce", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.3), Size = UDim2.fromScale(0.7, 0.26), Parent = gui })
	local scale = new("UIScale", { Scale = 0.3, Parent = holder })
	local title = label({ Text = ("%s %s!"):format(def.Icon, def.Name:upper()), Size = UDim2.fromScale(1, 0.48), StrokeThickness = 5, Parent = holder })
	new("UIGradient", { Color = ColorSequence.new(Color3.new(1, 1, 1), def.Color), Rotation = 90, Parent = title })
	local desc = label({ Text = def.Desc, Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromScale(1, 0.2), StrokeThickness = 3, Parent = holder })
	local buffs = label({ Text = table.concat(WeatherConfig.BuffLines(def), "   •   "), TextColor3 = def.Color:Lerp(Color3.new(1, 1, 1), 0.4), Position = UDim2.fromScale(0, 0.74), Size = UDim2.fromScale(1, 0.18), StrokeThickness = 3, Parent = holder })
	tween(scale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	-- A little wobble on the title.
	local start = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - start
		if t > 0.8 or not title.Parent then
			conn:Disconnect()
			title.Rotation = 0
			return
		end
		title.Rotation = math.sin(t * 30) * 4 * (1 - t / 0.8)
	end)
	task.delay(4.5, function()
		for _, l in { title, desc, buffs } do
			tween(l, 0.6, { TextTransparency = 1 })
			tween(l:FindFirstChildOfClass("UIStroke") :: UIStroke, 0.6, { Transparency = 1 })
		end
		tween(holder, 0.6, { Position = UDim2.fromScale(0.5, 0.24) })
		task.wait(0.7)
		holder:Destroy()
	end)
end

local function endedToast(def: WeatherConfig.WeatherDef)
	local t = label({ Text = ("%s %s is over"):format(def.Icon, def.Name), AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 12), Size = UDim2.fromOffset(360, 30), StrokeThickness = 2.5, Parent = gui })
	task.delay(2.5, function()
		tween(t, 0.5, { TextTransparency = 1 })
		tween(t:FindFirstChildOfClass("UIStroke") :: UIStroke, 0.5, { Transparency = 1 })
		task.wait(0.6)
		t:Destroy()
	end)
end

-- State --------------------------------------------------------------------------------------------------

local shown: WeatherConfig.WeatherDef? = nil

local function applyLook(def: WeatherConfig.WeatherDef?)
	if def then
		iconEmoji.Text = def.Icon
		iconEmoji.TextTransparency = 0
		iconStroke.Color = def.Color
		tipStroke.Color = def.Color
		tipTitle.Text = ("%s %s"):format(def.Icon, def.Name)
		tipTitle.TextColor3 = def.Color:Lerp(Color3.new(1, 1, 1), 0.3)
		tipDesc.Text = def.Desc
		tipBuffs.Text = "• " .. table.concat(WeatherConfig.BuffLines(def), "\n• ")
		tipBuffs.TextColor3 = def.Color:Lerp(Color3.new(1, 1, 1), 0.5)
		tipBuffs.Visible = true
	else
		iconEmoji.Text = CLEAR_ICON
		iconEmoji.TextTransparency = 0.25
		iconStroke.Color = CLEAR_COLOR
		tipStroke.Color = CLEAR_COLOR
		tipTitle.Text = CLEAR_ICON .. " Clear Sky"
		tipTitle.TextColor3 = Color3.new(1, 1, 1)
		tipDesc.Text = "No weather right now. A random weather will roll in soon and boost your heroes!"
		tipBuffs.Visible = false
	end
end
applyLook(nil)

local function refresh()
	local def = WeatherConfig.Current()
	if def ~= shown then
		local old = shown
		shown = def
		applyLook(def)
		pop()
		if def then
			announce(def)
		elseif old then
			endedToast(old)
		end
	end
end
ReplicatedStorage:GetAttributeChangedSignal("Weather"):Connect(refresh)
ReplicatedStorage:GetAttributeChangedSignal("WeatherEnds"):Connect(refresh)

-- Timers.
task.spawn(function()
	while true do
		refresh()
		local now = workspace:GetServerTimeNow()
		if shown then
			local ends = ReplicatedStorage:GetAttribute("WeatherEnds")
			local left = if typeof(ends) == "number" then ends - now else 0
			countdown.Text = clock(left)
			countdown.TextColor3 = if left <= 30 then Color3.fromRGB(255, 110, 110) else Color3.new(1, 1, 1)
			tipTime.Text = "⏳ Ends in " .. clock(left)
		else
			local nextAt = ReplicatedStorage:GetAttribute("WeatherNext")
			countdown.TextColor3 = Color3.fromRGB(200, 210, 230)
			if SHOW_NEXT and typeof(nextAt) == "number" and nextAt > now then
				countdown.Text = clock(nextAt - now)
				tipTime.Text = "🌦️ Next weather in " .. clock(nextAt - now)
			else
				countdown.Text = ""
				tipTime.Text = "🌦️ Next weather: soon"
			end
		end
		task.wait(0.25)
	end
end)
refresh()
