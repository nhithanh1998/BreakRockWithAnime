-- StandUpgradeUI: the Farm Stand upgrade pads (StandUpgradeConfig, StandService on the server).
--
--   Pad card    Standing on one of your stand's upgrade pads (UpgradePad_<Id> marker, within
--               StandUpgradeConfig.PadReach) opens a card: name, what it does, "Lv 2 -> 3" (or MAX),
--               the stat before -> after (Remotes.StandAction "UpgradeInfo") and a BUY $X button
--               ("BuyUpgrade"). Walking off the pad closes it.
--   Pad labels  each pad's floating label shows its name, level / max and next cost (site attributes
--               "Upgrade_<Id>"), for every stand.
--   Map props   bought upgrades show on the map: Farm Sign = a roadside sign by each walk-in point
--               (bigger per level), Farm Side = flower planters at the front of the stand (more per level).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UIStyle = require(script.Parent:WaitForChild("UIStyle"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StandUpgradeConfig = require(Shared:WaitForChild("StandUpgradeConfig"))
local StandLayoutConfig = require(Shared:WaitForChild("StandLayoutConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local UIManager = require(script.Parent:WaitForChild("UIManager"))
local action = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("StandAction") :: RemoteFunction

local player = Players.LocalPlayer
local abbreviate = HeroConfig.Abbreviate
local FONT = Enum.Font.FredokaOne

local STAT_NAMES = {
	CustomersPerMinute = "Customers / min",
	MaxItemsPerCustomer = "Items / customer",
	PriceMultiplier = "Sell price",
	MaxStock = "Max stock",
	Carry = "Carry capacity",
	Helper = "Helpers",
}

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

-- Card ------------------------------------------------------------------------------------------------------

local gui = make("ScreenGui", { Name = "StandUpgradeGui", ResetOnSpawn = false, DisplayOrder = 7, Parent = player:WaitForChild("PlayerGui") })
local card = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -130),
	Size = UDim2.fromOffset(380, 196),
	BackgroundColor3 = Color3.fromRGB(38, 40, 50),
	Visible = false,
	Parent = gui,
})
make("UICorner", { CornerRadius = UDim.new(0, 14), Parent = card })
local cardStroke = make("UIStroke", { Thickness = 4, Color = Color3.new(1, 1, 1), ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = card })
local cardScale = make("UIScale", { Parent = card })
local title = text({ Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -28, 0, 34), TextXAlignment = Enum.TextXAlignment.Left, Parent = card })
local desc = text({ Position = UDim2.fromOffset(14, 42), Size = UDim2.new(1, -28, 0, 22), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = Color3.fromRGB(200, 205, 220), Parent = card })
local levelText = text({ Position = UDim2.fromOffset(14, 70), Size = UDim2.new(1, -28, 0, 26), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = Color3.fromRGB(255, 220, 90), Parent = card })
local statText = text({ Position = UDim2.fromOffset(14, 98), Size = UDim2.new(1, -28, 0, 26), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = Color3.fromRGB(110, 255, 120), Parent = card })
local buy = make("TextButton", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -12), Size = UDim2.new(1, -28, 0, 50), BackgroundColor3 = Color3.fromRGB(45, 180, 60), Text = "", Parent = card })
make("UICorner", { CornerRadius = UDim.new(0, 10), Parent = buy })
make("UIStroke", { Thickness = 3, Color = Color3.fromRGB(25, 110, 35), ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = buy })
UIStyle.Button(buy)
local buyText = text({ Size = UDim2.fromScale(1, 0.8), Position = UDim2.fromScale(0, 0.1), Text = "BUY", Parent = buy })

local openPad: { standId: string, id: string }? = nil
local info: any = nil
local busy = false

local function money(): number
	local stats = player:FindFirstChild("leaderstats")
	local v = stats and stats:FindFirstChild("Money")
	return if v and v:IsA("ValueBase") then (v :: any).Value else 0
end

local function fmt(stat: string, v: any): string
	if typeof(v) == "string" then
		return v
	elseif typeof(v) ~= "number" then
		return "-"
	elseif stat == "PriceMultiplier" then
		return ("x%.2f"):format(v)
	end
	return abbreviate(v)
end

local function drawCard()
	if not info then
		return
	end
	local def = StandUpgradeConfig.Get(info.id)
	title.Text = info.name
	desc.Text = info.desc
	cardStroke.Color = if def then def.Color else Color3.new(1, 1, 1)
	local maxed = info.level >= info.maxLevel
	levelText.Text = if maxed then ("Lv %d  (MAX)"):format(info.level) else ("Lv %d  ->  Lv %d"):format(info.level, info.level + 1)
	local name = STAT_NAMES[info.stat] or info.stat
	statText.Text = if maxed then ("%s: %s"):format(name, fmt(info.stat, info.before)) else ("%s: %s  ->  %s"):format(name, fmt(info.stat, info.before), fmt(info.stat, info.after))
	if maxed then
		buyText.Text = "MAX"
		buy.BackgroundColor3 = Color3.fromRGB(90, 92, 102)
	else
		buyText.Text = ("BUY  $%s"):format(abbreviate(info.cost or 0))
		buy.BackgroundColor3 = if money() >= (info.cost or 0) then Color3.fromRGB(45, 180, 60) else Color3.fromRGB(90, 92, 102)
	end
end

local function openCard(standId: string, id: string)
	openPad = { standId = standId, id = id }
	local ok, result = pcall(action.InvokeServer, action, "UpgradeInfo", standId, id)
	if not openPad or openPad.id ~= id then
		return
	end
	if ok and typeof(result) == "table" and result.ok then
		info = result
		card.Visible = true
		cardScale.Scale = 0.7
		TweenService:Create(cardScale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		drawCard()
	end
end

local function closeCard()
	openPad = nil
	info = nil
	card.Visible = false
end

-- One window at a time; dims the world, hides the HUD on phones (UIManager).
UIManager.Register("StandUpgrade", card, closeCard)

buy.Activated:Connect(function()
	if busy or not openPad or not info or info.level >= info.maxLevel then
		return
	end
	busy = true
	buyText.Text = "..."
	local pad = openPad
	local ok, result = pcall(action.InvokeServer, action, "BuyUpgrade", pad.standId, pad.id)
	if ok and typeof(result) == "table" and result.ok then
		info = result
		cardScale.Scale = 1.08
		TweenService:Create(cardScale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
	drawCard()
	busy = false
end)

task.spawn(function()
	local v = player:WaitForChild("leaderstats"):WaitForChild("Money") :: ValueBase
	(v :: any).Changed:Connect(function()
		if info then
			drawCard()
		end
	end)
end)

-- Which pad am I standing on? ---------------------------------------------------------------------------------

local function mySites(): { Instance }
	local out = {}
	local plots = workspace:FindFirstChild("Plots")
	for _, plot in if plots then plots:GetChildren() else {} do
		local sites = plot:FindFirstChild(StandLayoutConfig.SitesFolder)
		for _, site in if sites then sites:GetChildren() else {} do
			if site:GetAttribute("OwnerUserId") == player.UserId then
				table.insert(out, site)
			end
		end
	end
	return out
end

task.spawn(function()
	while true do
		task.wait(0.2)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local found: { standId: string, id: string }? = nil
		if root then
			for _, site in mySites() do
				local placed = site:FindFirstChild(StandLayoutConfig.PlacedName)
				local markers = placed and placed:FindFirstChild(StandLayoutConfig.MarkersFolder)
				for _, m in if markers then markers:GetChildren() else {} do
					local id = m.Name:match("^UpgradePad_(.+)$")
					if id and m:IsA("BasePart") then
						local d = root.Position - m.Position
						if Vector3.new(d.X, 0, d.Z).Magnitude <= StandUpgradeConfig.PadReach and math.abs(d.Y) < 8 then
							found = { standId = site.Name, id = id }
						end
					end
				end
			end
		end
		if found and (not openPad or openPad.id ~= found.id or openPad.standId ~= found.standId) then
			task.spawn(openCard, found.standId, found.id)
		elseif not found and openPad then
			closeCard()
		end
	end
end)

-- Pad labels and map props ------------------------------------------------------------------------------------

local propsFolder = Instance.new("Folder")
propsFolder.Name = "StandUpgradeProps"
propsFolder.Parent = workspace

local function marker(site: Instance, name: string): BasePart?
	local placed = site:FindFirstChild(StandLayoutConfig.PlacedName)
	local markers = placed and placed:FindFirstChild(StandLayoutConfig.MarkersFolder)
	local m = markers and markers:FindFirstChild(name)
	if not m then
		local siteMarkers = site:FindFirstChild(StandLayoutConfig.MarkersFolder)
		m = siteMarkers and siteMarkers:FindFirstChild(name)
	end
	return if m and m:IsA("BasePart") then m else nil
end

local function drawLabels(site: Instance)
	local placed = site:FindFirstChild(StandLayoutConfig.PlacedName)
	local pads = placed and placed:FindFirstChild("Pads")
	for _, p in if pads then pads:GetChildren() else {} do
		local id = p.Name:match("^UpgradePad_(.+)$")
		local def = id and StandUpgradeConfig.Get(id)
		local labelGui = p:FindFirstChild("PadLabel")
		local label = labelGui and labelGui:FindFirstChildOfClass("TextLabel")
		if def and label then
			local level = site:GetAttribute("Upgrade_" .. id) or 0
			local cost = StandUpgradeConfig.NextCost(id, level)
			label.RichText = true
			label.Text = ("%s\n<font color=\"#FFE066\">Lv %d/%d%s</font>"):format(
				def.Name,
				level,
				StandUpgradeConfig.MaxLevel(id),
				if cost then ("  $%s"):format(abbreviate(cost)) else "  MAX"
			)
			;(labelGui :: BillboardGui).Size = UDim2.fromOffset(200, 54)
		end
	end
end

local function part(props: { [string]: any }): Part
	local p = make("Part", { Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false, TopSurface = Enum.SurfaceType.Smooth, BottomSurface = Enum.SurfaceType.Smooth })
	for k, v in props do
		(p :: any)[k] = v
	end
	return p
end

local function drawProps(site: Instance)
	local key = site:GetFullName()
	local old = propsFolder:FindFirstChild(key)
	if old then
		old:Destroy()
	end
	local f = make("Folder", { Name = key, Parent = propsFolder })
	-- Farm Sign: a roadside sign at each walk-in point, on the plaza side of the sidewalk.
	local signLevel = site:GetAttribute("Upgrade_FarmSign") or 0
	if signLevel > 0 then
		for i = 1, 4 do
			local m = marker(site, "CustomerPath_" .. i)
			if not m then
				break
			end
			local s = 1 + 0.15 * signLevel
			local base = m.Position + Vector3.new(0, -m.Position.Y, -4.5)
			part({ Size = Vector3.new(0.5, 4 * s, 0.5), Position = base + Vector3.new(-1.6 * s, 2 * s, 0), Color = Color3.fromRGB(110, 72, 42), Material = Enum.Material.Wood, Parent = f })
			part({ Size = Vector3.new(0.5, 4 * s, 0.5), Position = base + Vector3.new(1.6 * s, 2 * s, 0), Color = Color3.fromRGB(110, 72, 42), Material = Enum.Material.Wood, Parent = f })
			local board = part({ Size = Vector3.new(4.4 * s, 2 * s, 0.3), CFrame = CFrame.new(base + Vector3.new(0, 4.2 * s, 0)) * CFrame.Angles(0, math.pi, 0), Color = Color3.fromRGB(214, 52, 48), Material = Enum.Material.Wood, Parent = f })
			local sg = make("SurfaceGui", { Face = Enum.NormalId.Front, SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud, PixelsPerStud = 40, Parent = board })
			text({ Size = UDim2.fromScale(1, 1), Text = ("FARM STAND\n%s"):format(string.rep("*", signLevel)), Parent = sg })
		end
	end
	-- Farm Side: flower planters at the front corners of the stand, more per level.
	local sideLevel = site:GetAttribute("Upgrade_FarmSide") or 0
	if sideLevel > 0 then
		local colors = { Color3.fromRGB(255, 90, 110), Color3.fromRGB(255, 220, 70), Color3.fromRGB(180, 110, 255), Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 150, 60) }
		for side = 1, 2 do
			local m = marker(site, "AccessorySlot_" .. side)
			if m then
				local look = m.CFrame
				for k = 1, sideLevel do
					local pos = (look * CFrame.new((k - 1) * 2.2 * (if side == 1 then 1 else -1), 0, 0)).Position
					local groundY = pos.Y - m.Size.Y / 2
					part({ Size = Vector3.new(1.8, 0.9, 1.8), Position = Vector3.new(pos.X, groundY + 0.45, pos.Z), Color = Color3.fromRGB(120, 80, 50), Material = Enum.Material.WoodPlanks, Parent = f })
					part({ Shape = Enum.PartType.Ball, Size = Vector3.new(1.6, 1.6, 1.6), Position = Vector3.new(pos.X, groundY + 1.4, pos.Z), Color = Color3.fromRGB(80, 160, 70), Material = Enum.Material.Grass, Parent = f })
					for c = 1, 3 do
						local a = c * 2.1
						part({ Shape = Enum.PartType.Ball, Size = Vector3.new(0.5, 0.5, 0.5), Position = Vector3.new(pos.X + math.cos(a) * 0.6, groundY + 2, pos.Z + math.sin(a) * 0.6), Color = colors[(k + c) % #colors + 1], Parent = f })
					end
				end
			end
		end
	end
end

local function watchSite(site: Instance)
	local function redraw()
		drawLabels(site)
		drawProps(site)
		if openPad and openPad.standId == site.Name then
			task.spawn(openCard, openPad.standId, openPad.id)
		end
	end
	site.AttributeChanged:Connect(function(name)
		if name:match("^Upgrade_") or name == "Level" then
			redraw()
		end
	end)
	site.ChildAdded:Connect(function(c)
		if c.Name == StandLayoutConfig.PlacedName then
			c:WaitForChild("Pads", 10)
			task.wait(0.2)
			redraw()
		end
	end)
	redraw()
end

task.spawn(function()
	local plots = workspace:WaitForChild("Plots")
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
	for _, plot in plots:GetChildren() do
		task.spawn(watchPlot, plot)
	end
	plots.ChildAdded:Connect(function(plot)
		task.spawn(watchPlot, plot)
	end)
end)
