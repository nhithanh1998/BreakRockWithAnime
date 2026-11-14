-- StandClient: what players see on every Farm Stand (StandService on the server).
--
--   Billboard   at the placed stand's BillboardAnchor marker: name, stock n/max, customers a minute and,
--               for the owner, the upgrade buttons (StandUpgradeConfig.BoardOrder: CAPACITY+, FAME+, each
--               "Lv n/20 $cost" or MAX). Size and colours follow the level's BillboardStyle (StandLayoutConfig).
--               Reads the site attributes (Stock, MaxStock, PriceMin, PriceMax, CustomersPerMinute,
--               Level, StandName, OwnerUserId), so it updates live.
--   Goods       small crates at the StockVisual_N markers, as many as the stock fill (local parts).
--   Customers   StandCustomers (customer NPCs) uses this script's popup ("+$X" rising from CoinFxPoint)
--               and coins flying to the owner with a ping, when an NPC pays at the counter.
--   Level up    "LevelUp": the new level model rises with a bounce, confetti, sounds, "LEVEL UP!",
--               new keeper pads sparkle. The billboard grows with the level (BillboardStyle).
--   Restock FX  "Restock" (owner only): boxes fly from the player into the counter, "+N stock" pops,
--               a tick sound that pitches up while the player keeps restocking.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StandLayoutConfig = require(Shared:WaitForChild("StandLayoutConfig"))
local StandConfig = require(Shared:WaitForChild("StandConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local StandUpgradeConfig = require(Shared:WaitForChild("StandUpgradeConfig"))
local standAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("StandAction") :: RemoteFunction
local standEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("StandEvent") :: RemoteEvent

local player = Players.LocalPlayer
local abbreviate = HeroConfig.Abbreviate

local FONT = Enum.Font.FredokaOne
local SALE_SOUND = "rbxasset://sounds/electronicpingshort.wav"

-- Billboard styles: size in studs and colours.
local STYLES = {
	Small = { W = 9, H = 5.6, Title = Color3.fromRGB(150, 98, 52), Border = Color3.fromRGB(110, 70, 36), Panel = Color3.fromRGB(255, 246, 222) },
	Medium = { W = 10.5, H = 6.4, Title = Color3.fromRGB(70, 150, 70), Border = Color3.fromRGB(40, 100, 45), Panel = Color3.fromRGB(250, 248, 230) },
	Large = { W = 12, H = 7.2, Title = Color3.fromRGB(200, 50, 45), Border = Color3.fromRGB(140, 30, 30), Panel = Color3.fromRGB(255, 246, 228) },
	Deluxe = { W = 13.5, H = 8, Title = Color3.fromRGB(60, 110, 210), Border = Color3.fromRGB(240, 190, 60), Panel = Color3.fromRGB(250, 248, 238) },
	Grand = { W = 15, H = 8.8, Title = Color3.fromRGB(150, 60, 200), Border = Color3.fromRGB(255, 205, 70), Panel = Color3.fromRGB(255, 250, 235) },
}

local guiFolder = Instance.new("Folder")
guiFolder.Name = "StandBillboards"
guiFolder.Parent = player:WaitForChild("PlayerGui")
local goodsFolder = Instance.new("Folder")
goodsFolder.Name = "StandGoods"
goodsFolder.Parent = workspace

local function label(props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = FONT
	l.TextScaled = true
	l.TextColor3 = Color3.fromRGB(90, 55, 25)
	for k, v in props do
		(l :: any)[k] = v
	end
	return l
end

local function stroke(parent: Instance, color: Color3, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Parent = parent
	return s
end

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(r, 0)
	c.Parent = parent
end

-- Markers --------------------------------------------------------------------------------------------------

local function marker(site: Instance, name: string): BasePart?
	local placed = site:FindFirstChild(StandLayoutConfig.PlacedName)
	local markers = placed and placed:FindFirstChild(StandLayoutConfig.MarkersFolder)
	local m = markers and markers:FindFirstChild(name)
	return if m and m:IsA("BasePart") then m else nil
end

local function styleOf(site: Instance): { W: number, H: number, Title: Color3, Border: Color3, Panel: Color3 }
	local standId = site.Name
	local layout = StandLayoutConfig.Stands[standId]
	local level = site:GetAttribute("Level")
	local def = layout and layout.Levels[if typeof(level) == "number" then level else 1]
	return STYLES[if def then def.BillboardStyle else "Small"] or STYLES.Small
end

-- Billboard ------------------------------------------------------------------------------------------------

type UpgradeButton = { id: string, button: TextButton, name: TextLabel, info: TextLabel, scale: UIScale }
type Board = { gui: BillboardGui, title: TextLabel, stock: TextLabel, customers: TextLabel, buttons: { UpgradeButton }, buttonRow: Frame, styleKey: string }

local boards: { [Instance]: Board } = {}

local BUTTON_H = 2.2 -- studs under the board for the upgrade buttons (owner only)
local MAXED = Color3.fromRGB(120, 120, 128)
local POOR = Color3.fromRGB(150, 140, 130)

local function money(): number
	local stats = player:FindFirstChild("leaderstats")
	local v = stats and stats:FindFirstChild("Money")
	return if v and v:IsA("ValueBase") then (v :: any).Value else 0
end

local function darker(c: Color3, k: number): Color3
	return Color3.new(c.R * k, c.G * k, c.B * k)
end

local function buildBoard(site: Instance): Board?
	local anchor = marker(site, "BillboardAnchor")
	if not anchor then
		return nil
	end
	local style = styleOf(site)
	local gui = Instance.new("BillboardGui")
	gui.Name = site:GetFullName()
	gui.Adornee = anchor
	gui.Size = UDim2.new(style.W, 0, style.H + BUTTON_H, 0)
	gui.Active = true
	gui.LightInfluence = 0
	gui.MaxDistance = 160
	gui.ResetOnSpawn = false
	gui.Parent = guiFolder
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.fromScale(1, style.H / (style.H + BUTTON_H))
	body.Parent = gui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.fromScale(0.5, 1)
	panel.Size = UDim2.fromScale(1, 0.8)
	panel.BackgroundColor3 = style.Panel
	panel.Parent = body
	corner(panel, 0.12)
	stroke(panel, style.Border, 3)

	local plate = Instance.new("Frame")
	plate.Name = "Title"
	plate.AnchorPoint = Vector2.new(0.5, 0)
	plate.Position = UDim2.fromScale(0.5, 0)
	plate.Size = UDim2.fromScale(0.62, 0.3)
	plate.BackgroundColor3 = style.Title
	plate.ZIndex = 2
	plate.Parent = body
	corner(plate, 0.3)
	stroke(plate, style.Border, 3)
	local title = label({ Size = UDim2.fromScale(0.94, 0.8), Position = UDim2.fromScale(0.03, 0.1), TextColor3 = Color3.new(1, 1, 1), ZIndex = 3, Parent = plate })
	stroke(title, Color3.fromRGB(60, 35, 15), 2)

	-- row: crate + stock n/max
	local crate = Instance.new("Frame")
	crate.Position = UDim2.fromScale(0.2, 0.4)
	crate.Size = UDim2.fromScale(0.12, 0.2)
	crate.BackgroundColor3 = Color3.fromRGB(176, 120, 64)
	crate.Parent = body
	corner(crate, 0.15)
	stroke(crate, Color3.fromRGB(100, 62, 30), 2)
	local band = Instance.new("Frame")
	band.AnchorPoint = Vector2.new(0, 0.5)
	band.Position = UDim2.fromScale(0, 0.5)
	band.Size = UDim2.fromScale(1, 0.18)
	band.BorderSizePixel = 0
	band.BackgroundColor3 = Color3.fromRGB(120, 78, 38)
	band.Parent = crate
	local stock = label({ Position = UDim2.fromScale(0.36, 0.38), Size = UDim2.fromScale(0.5, 0.24), TextXAlignment = Enum.TextXAlignment.Left, Parent = body })
	local customers = label({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.7), Size = UDim2.fromScale(0.86, 0.15), TextColor3 = Color3.fromRGB(200, 120, 40), Parent = body })

	-- Upgrade buttons (owner only), StandUpgradeConfig.BoardOrder left to right.
	local row = Instance.new("Frame")
	row.Name = "Upgrades"
	row.AnchorPoint = Vector2.new(0.5, 1)
	row.Position = UDim2.fromScale(0.5, 1)
	row.Size = UDim2.fromScale(1, BUTTON_H / (style.H + BUTTON_H) * 0.94)
	row.BackgroundTransparency = 1
	row.Visible = false
	row.Parent = gui
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Padding = UDim.new(0.03, 0)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = row
	local buttons: { UpgradeButton } = {}
	for i, id in StandUpgradeConfig.BoardOrder do
		local def = StandUpgradeConfig.Get(id)
		if not def then
			continue
		end
		local button = Instance.new("TextButton")
		button.Name = id
		button.LayoutOrder = i
		button.Size = UDim2.fromScale(0.47, 1)
		button.BackgroundColor3 = def.Color
		button.Text = ""
		button.AutoButtonColor = true
		button.Parent = row
		corner(button, 0.25)
		stroke(button, darker(def.Color, 0.6), 2)
		local scale = Instance.new("UIScale")
		scale.Parent = button
		local name = label({ Position = UDim2.fromScale(0.05, 0.06), Size = UDim2.fromScale(0.9, 0.5), TextColor3 = Color3.new(1, 1, 1), Text = string.upper(def.Name) .. "+", Parent = button })
		stroke(name, darker(def.Color, 0.45), 1.5)
		local info = label({ Position = UDim2.fromScale(0.05, 0.56), Size = UDim2.fromScale(0.9, 0.38), TextColor3 = Color3.fromRGB(255, 245, 200), Parent = button })
		stroke(info, darker(def.Color, 0.45), 1.2)
		local busy = false
		button.Activated:Connect(function()
			if busy then
				return
			end
			busy = true
			scale.Scale = 0.9
			TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
			pcall(standAction.InvokeServer, standAction, "BuyUpgrade", site.Name, id)
			busy = false
		end)
		table.insert(buttons, { id = id, button = button, name = name, info = info, scale = scale })
	end

	return { gui = gui, title = title, stock = stock, customers = customers, buttons = buttons, buttonRow = row, styleKey = "" }
end

local function drawBoard(site: Instance, board: Board)
	local stockN = site:GetAttribute("Stock") or 0
	local maxN = site:GetAttribute("MaxStock") or 0
	local cpm = site:GetAttribute("CustomersPerMinute") or 0
	board.title.Text = string.upper(tostring(site:GetAttribute("StandName") or "Farm Stand"))
	board.stock.Text = ("%s/%s"):format(abbreviate(stockN), abbreviate(maxN))
	board.stock.TextColor3 = if maxN > 0 and stockN >= maxN then Color3.fromRGB(220, 60, 50) else Color3.fromRGB(90, 55, 25)
	board.customers.Text = ("%s customers a minute"):format(tostring(cpm))
	local mine = site:GetAttribute("OwnerUserId") == player.UserId
	board.buttonRow.Visible = mine
	if not mine then
		return
	end
	local cash = money()
	for _, b in board.buttons do
		local def = StandUpgradeConfig.Get(b.id)
		if not def then
			continue
		end
		local level = site:GetAttribute("Upgrade_" .. b.id) or 0
		local cost = StandUpgradeConfig.NextCost(b.id, level)
		if cost then
			b.info.Text = ("Lv %d/%d  $%s"):format(level, StandUpgradeConfig.MaxLevel(b.id), abbreviate(cost))
			b.button.BackgroundColor3 = if cash >= cost then def.Color else POOR
		else
			b.info.Text = "MAX"
			b.button.BackgroundColor3 = MAXED
		end
	end
end

-- Goods on the shelf ----------------------------------------------------------------------------------------

local function drawGoods(site: Instance)
	local key = site:GetFullName()
	local f = goodsFolder:FindFirstChild(key)
	if not f then
		local nf = Instance.new("Folder")
		nf.Name = key
		nf.Parent = goodsFolder
		f = nf
	end
	local stockN = site:GetAttribute("Stock") or 0
	local maxN = math.max(1, site:GetAttribute("MaxStock") or 1)
	local slots = {}
	local i = 1
	while true do
		local m = marker(site, "StockVisual_" .. i)
		if not m then
			break
		end
		slots[i] = m
		i += 1
	end
	local show = if stockN > 0 and #slots > 0 then math.clamp(math.ceil(stockN / maxN * #slots), 1, #slots) else 0
	for n, m in slots do
		local crate = f:FindFirstChild("Goods" .. n) :: BasePart?
		if n <= show then
			if not crate or (crate.Position - m.Position).Magnitude > 0.5 then
				if crate then
					crate:Destroy()
				end
				local c = Instance.new("Part")
				c.Name = "Goods" .. n
				c.Anchored = true
				c.CanCollide = false
				c.CanQuery = false
				c.CanTouch = false
				c.Size = Vector3.new(1.3, 0.7, 1)
				c.Material = Enum.Material.WoodPlanks
				c.Color = Color3.fromRGB(176, 120, 64)
				c.CFrame = m.CFrame + Vector3.new(0, 0.35, 0)
				c.Parent = f
				local top = Instance.new("Part")
				top.Name = "Fill"
				top.Anchored = true
				top.CanCollide = false
				top.CanQuery = false
				top.CanTouch = false
				top.Size = Vector3.new(1.1, 0.3, 0.8)
				top.Color = Color3.fromRGB(240, 170, 70)
				top.CFrame = c.CFrame + Vector3.new(0, 0.45, 0)
				top.Parent = c
				c.Size = Vector3.new(0.4, 0.2, 0.3)
				TweenService:Create(c, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = Vector3.new(1.3, 0.7, 1) }):Play()
			end
		elseif crate then
			crate:Destroy()
		end
	end
end

-- Sites ---------------------------------------------------------------------------------------------------------

local function refreshSite(site: Instance)
	local board = boards[site]
	local style = styleOf(site)
	local anchor = marker(site, "BillboardAnchor")
	local key = tostring(style.W) .. tostring(anchor)
	if board and (board.styleKey ~= key or board.gui.Adornee ~= anchor or not board.gui.Parent) then
		board.gui:Destroy()
		boards[site] = nil
		board = nil
	end
	if not board then
		local b = buildBoard(site)
		if b then
			b.styleKey = key
			boards[site] = b
			board = b
		end
	end
	if board then
		drawBoard(site, board)
	end
	drawGoods(site)
end

local function watchSite(site: Instance)
	if not site:IsA("Model") or not StandConfig.Stands[site.Name] then
		return
	end
	site.AttributeChanged:Connect(function()
		refreshSite(site)
	end)
	site.ChildAdded:Connect(function(c)
		if c.Name == StandLayoutConfig.PlacedName then
			c:WaitForChild(StandLayoutConfig.MarkersFolder, 10)
			task.wait()
			refreshSite(site)
		end
	end)
	refreshSite(site)
end

local function watchPlot(plot: Instance)
	local sites = plot:WaitForChild(StandLayoutConfig.SitesFolder, 30)
	if not sites then
		return
	end
	for _, site in sites:GetChildren() do
		watchSite(site)
	end
	sites.ChildAdded:Connect(watchSite)
end

-- Money changes: the upgrade buttons turn coloured / grey.
task.spawn(function()
	local stats = player:WaitForChild("leaderstats")
	local v = stats:WaitForChild("Money") :: ValueBase
	(v :: any).Changed:Connect(function()
		for site, board in boards do
			drawBoard(site, board)
		end
	end)
end)

task.spawn(function()
	local plots = workspace:WaitForChild("Plots")
	for _, plot in plots:GetChildren() do
		task.spawn(watchPlot, plot)
	end
	plots.ChildAdded:Connect(function(plot)
		task.spawn(watchPlot, plot)
	end)
end)

-- Sale FX ---------------------------------------------------------------------------------------------------------

local function popup(at: BasePart, text: string, color: Color3)
	local g = Instance.new("BillboardGui")
	g.Adornee = at
	g.Size = UDim2.fromScale(6, 1.6)
	g.LightInfluence = 0
	g.MaxDistance = 100
	g.Parent = guiFolder
	local l = label({ Size = UDim2.fromScale(1, 1), Text = text, TextColor3 = color, Parent = g })
	local s = stroke(l, Color3.fromRGB(30, 30, 30), 2)
	g.StudsOffsetWorldSpace = Vector3.new(0, 0, 0)
	local info = TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(g, info, { StudsOffsetWorldSpace = Vector3.new(0, 3, 0) }):Play()
	task.delay(0.5, function()
		local fade = TweenInfo.new(0.6)
		TweenService:Create(l, fade, { TextTransparency = 1 }):Play()
		TweenService:Create(s, fade, { Transparency = 1 }):Play()
	end)
	task.delay(1.2, function()
		g:Destroy()
	end)
end

local function flyCoins(from: Vector3, count: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	for i = 1, count do
		task.delay((i - 1) * 0.06, function()
			local coin = Instance.new("Part")
			coin.Shape = Enum.PartType.Cylinder
			coin.Size = Vector3.new(0.15, 0.9, 0.9)
			coin.Color = Color3.fromRGB(250, 200, 50)
			coin.Material = Enum.Material.Neon
			coin.Anchored = true
			coin.CanCollide = false
			coin.CanQuery = false
			coin.CanTouch = false
			coin.Parent = goodsFolder
			local start = from + Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
			local t0 = os.clock()
			local duration = 0.55
			local conn
			conn = RunService.RenderStepped:Connect(function()
				local t = math.min((os.clock() - t0) / duration, 1)
				local goal = if root.Parent then root.Position else start
				local p = start:Lerp(goal, t * t) + Vector3.new(0, math.sin(t * math.pi) * 3, 0)
				coin.CFrame = CFrame.new(p) * CFrame.Angles(0, t * 12, math.rad(90))
				if t >= 1 then
					conn:Disconnect()
					coin:Destroy()
				end
			end)
		end)
	end
	local sound = Instance.new("Sound")
	sound.SoundId = SALE_SOUND
	sound.Volume = 0.35
	sound.PlaybackSpeed = 1.2
	sound.Parent = guiFolder
	sound:Play()
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
end

-- Restock: boxes fly from the player into the counter, one "tick" sound per batch, pitched up while
-- the player keeps restocking.
local restockStreak = 0
local lastRestock = 0

local function flyBoxes(to: Vector3, count: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	for i = 1, count do
		task.delay((i - 1) * 0.04, function()
			local box = Instance.new("Part")
			box.Size = Vector3.new(0.8, 0.6, 0.8)
			box.Material = Enum.Material.WoodPlanks
			box.Color = Color3.fromRGB(176, 120, 64)
			box.Anchored = true
			box.CanCollide = false
			box.CanQuery = false
			box.CanTouch = false
			box.Parent = goodsFolder
			local start = root.Position + Vector3.new(0, 1.5, 0)
			local t0 = os.clock()
			local duration = 0.35
			local conn
			conn = RunService.RenderStepped:Connect(function()
				local t = math.min((os.clock() - t0) / duration, 1)
				local p = start:Lerp(to, t) + Vector3.new(0, math.sin(t * math.pi) * 2.5, 0)
				box.CFrame = CFrame.new(p) * CFrame.Angles(t * 4, t * 6, 0)
				box.Size = Vector3.new(0.8, 0.6, 0.8) * (1 - 0.4 * t)
				if t >= 1 then
					conn:Disconnect()
					box:Destroy()
				end
			end)
		end)
	end
	local now = os.clock()
	restockStreak = if now - lastRestock < 0.6 then math.min(restockStreak + 1, 12) else 0
	lastRestock = now
	local sound = Instance.new("Sound")
	sound.SoundId = SALE_SOUND
	sound.Volume = 0.25
	sound.PlaybackSpeed = 0.8 + restockStreak * 0.05
	sound.Parent = guiFolder
	sound:Play()
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
end

-- Level up: the new level model rises out of the ground with a bounce, confetti bursts, a "LEVEL UP!"
-- pops, and the keeper pads the new level adds sparkle for a few seconds.
local function playSound(id: string, volume: number, speed: number)
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = volume
	sound.PlaybackSpeed = speed
	sound.Parent = guiFolder
	sound:Play()
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
end

local function confetti(at: Vector3)
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.new(1, 1, 1)
	holder.Position = at
	holder.Parent = goodsFolder
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 90, 80)),
		ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 220, 70)),
		ColorSequenceKeypoint.new(0.66, Color3.fromRGB(90, 220, 110)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(90, 160, 255)),
	})
	emitter.Size = NumberSequence.new(0.8, 0.2)
	emitter.Lifetime = NumberRange.new(1, 1.8)
	emitter.Speed = NumberRange.new(18, 30)
	emitter.SpreadAngle = Vector2.new(70, 70)
	emitter.Acceleration = Vector3.new(0, -30, 0)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-200, 200)
	emitter.LightEmission = 0.6
	emitter.Enabled = false
	emitter.Parent = holder
	emitter:Emit(120)
	task.delay(3, function()
		holder:Destroy()
	end)
end

local function sparklePad(pad: Instance)
	local part = pad:FindFirstChild("Pad")
	if not part or not part:IsA("BasePart") then
		return
	end
	local s = Instance.new("Sparkles")
	s.SparkleColor = Color3.fromRGB(255, 230, 90)
	s.Parent = part
	task.delay(5, function()
		s:Destroy()
	end)
end

local function levelUpFx(site: Instance, level: number, old: number)
	-- wait for the new level model to arrive
	local placed: Instance? = nil
	local t0 = os.clock()
	while os.clock() - t0 < 3 do
		local p = site:FindFirstChild(StandLayoutConfig.PlacedName)
		if p and p:GetAttribute("Level") == level then
			placed = p
			break
		end
		task.wait(0.05)
	end
	if not placed or not placed:IsA("Model") then
		return
	end
	local model = placed :: Model
	local home = model:GetPivot()
	local _, size = model:GetBoundingBox()
	confetti(home.Position + Vector3.new(0, size.Y * 0.6, 0))
	playSound(SALE_SOUND, 0.6, 0.6)
	task.delay(0.15, playSound, SALE_SOUND, 0.6, 0.9)
	task.delay(0.3, playSound, SALE_SOUND, 0.6, 1.2)
	-- rise out of the ground with a little overshoot
	local depth = math.min(size.Y * 0.5, 8)
	local start = os.clock()
	local duration = 0.6
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local t = math.min((os.clock() - start) / duration, 1)
		if not model.Parent then
			conn:Disconnect()
			return
		end
		local eased = TweenService:GetValue(t, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		model:PivotTo(home - Vector3.new(0, depth * (1 - eased), 0))
		if t >= 1 then
			conn:Disconnect()
			model:PivotTo(home)
		end
	end)
	local fx = marker(site, "CoinFxPoint")
	if fx then
		popup(fx, ("LEVEL UP!  Lv %d"):format(level), Color3.fromRGB(255, 220, 70))
	end
	-- keeper pads this level adds
	local layout = StandLayoutConfig.Stands[site.Name]
	local before = layout and layout.Levels[old] and layout.Levels[old].KeeperSlots or 0
	local pads = model:FindFirstChild("Pads")
	for i = before + 1, 8 do
		local pad = pads and pads:FindFirstChild("KeeperPad_" .. i)
		if pad then
			sparklePad(pad)
		end
	end
end

standEvent.OnClientEvent:Connect(function(kind: string, site: Instance, money: number?, items: number?, ownerId: number?)
	if typeof(site) ~= "Instance" then
		return
	end
	if kind == "LevelUp" then
		task.spawn(levelUpFx, site, money or 1, items or 1) -- ("LevelUp", site, level, oldLevel)
		return
	end
	local fx = marker(site, "CoinFxPoint")
	if not fx then
		return
	end
	if kind == "Sale" then
		popup(fx, "+$" .. abbreviate(money or 0), Color3.fromRGB(110, 255, 110))
		if ownerId == player.UserId then
			flyCoins(fx.Position, math.clamp(items or 1, 1, StandConfig.SaleFxMaxCoins))
		end
	elseif kind == "Restock" then
		local n = money or 0 -- ("Restock", site, amount)
		popup(fx, "+" .. n .. " stock", Color3.fromRGB(255, 200, 80))
		flyBoxes(fx.Position, math.clamp(n, 1, 4))
	elseif kind == "NoStock" then
		popup(fx, "Out of stock!", Color3.fromRGB(255, 90, 80))
	end
end)

-- Customer NPCs (they use the same popup / coins).
require(script.Parent:WaitForChild("StandCustomers")).Start({
	popup = popup,
	flyCoins = flyCoins,
	marker = marker,
	standEvent = standEvent,
})
