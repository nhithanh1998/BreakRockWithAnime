-- StandUpgradeUI: the Farm Stand upgrade pads (StandUpgradeConfig, StandService on the server).
--
--   Pad card    Standing on one of your stand's upgrade pads (UpgradePad_<Id> marker, within
--               StandUpgradeConfig.PadReach) opens a card: name, what it does, "Lv 2 -> 3" (or MAX),
--               the stat before -> after (Remotes.StandAction "UpgradeInfo") and a BUY $X button
--               ("BuyUpgrade"). Walking off the pad closes it. The card is the common UIStyle.Window
--               (title = upgrade name, red X, Theme colours), sitting low on the screen so the stand
--               stays visible. Closed with X, it stays closed until you step off the pad.
--   Pad labels  each pad's floating label shows its name, level / max and next cost (site attributes
--               "Upgrade_<Id>"), for every stand.
--   Map props   bought upgrades show on the map: Farm Sign = a roadside sign by each walk-in point
--               (bigger per level), Farm Side = flower planters at the front of the stand (more per level).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local Theme = require(script.Parent:WaitForChild("Theme"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StandUpgradeConfig = require(Shared:WaitForChild("StandUpgradeConfig"))
local StandLayoutConfig = require(Shared:WaitForChild("StandLayoutConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local action = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("StandAction") :: RemoteFunction

local player = Players.LocalPlayer
local abbreviate = HeroConfig.Abbreviate
local FONT = Theme.Font
local C = Theme.Color

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
	local l = make("TextLabel", { BackgroundTransparency = 1, Font = FONT, TextScaled = true, TextColor3 = C.Text })
	for k, v in props do
		(l :: any)[k] = v
	end
	make("UIStroke", { Thickness = 2, Color = C.Stroke, Parent = l })
	return l
end

-- Card ------------------------------------------------------------------------------------------------------
-- The common window, sat low on the screen (above the hotbar) so the stand and the pad stay in view.

local PAD = Theme.Space.L
local BODY_H = 164

local openPad: { standId: string, id: string }? = nil
local info: any = nil
local busy = false
-- "<standId>/<id>" of the pad whose card the player closed (X, or another window opened): it stays
-- closed until they step off that pad.
local dismissed: string? = nil
local closingByCode = false -- the close came from walking off, not from the player

local function padKey(pad: { standId: string, id: string }): string
	return pad.standId .. "/" .. pad.id
end

local win = UIStyle.Window({
	Name = "StandUpgradeGui",
	Title = "UPGRADE",
	Size = Vector2.new(440, UIStyle.HEADER + BODY_H),
	PhoneSize = Vector2.new(400, UIStyle.HEADER_PHONE + BODY_H),
	DisplayOrder = 12,
	OnClose = function()
		if closingByCode then
			closingByCode = false -- walked off: openPad is already cleared (or is a new pad by now)
			return
		end
		if openPad then
			dismissed = padKey(openPad)
		end
		openPad = nil
		info = nil
	end,
})
win.root.AnchorPoint = Vector2.new(0.5, 1)
win.root.Position = UDim2.new(0.5, 0, 1, if win.phone then -12 else -130)

local title = win.title
local headerH = if win.phone then UIStyle.HEADER_PHONE else UIStyle.HEADER
-- The upgrade's own colour (StandUpgradeConfig Color), as a strip under the title.
local colorBar = make("Frame", {
	Name = "ColorBar",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, PAD, 1, -2),
	Size = UDim2.new(1, -(PAD * 2 + headerH), 0, 4),
	BorderSizePixel = 0,
	BackgroundColor3 = C.Accent,
	Parent = win.header,
})
make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = colorBar })

local body = win.body
local desc = text({ Position = UDim2.fromOffset(PAD, 6), Size = UDim2.new(1, -PAD * 2, 0, 22), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.TextDim, Parent = body })
local levelText = text({ Position = UDim2.fromOffset(PAD, 32), Size = UDim2.new(1, -PAD * 2, 0, 26), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.Accent, Parent = body })
local statText = text({ Position = UDim2.fromOffset(PAD, 62), Size = UDim2.new(1, -PAD * 2, 0, 26), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.Primary, Parent = body })
local buy = make("TextButton", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -PAD), Size = UDim2.new(1, -PAD * 2, 0, 52), BackgroundColor3 = C.Primary, Text = "", Parent = body })
make("UICorner", { CornerRadius = UDim.new(0, Theme.Radius.Button), Parent = buy })
make("UIStroke", { Thickness = 3, Color = C.PrimaryDark, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = buy })
UIStyle.Button(buy)
local buyStroke = buy:FindFirstChildOfClass("UIStroke") :: UIStroke
local buyText = text({ Size = UDim2.fromScale(1, 0.8), Position = UDim2.fromScale(0, 0.1), Text = "BUY", Parent = buy })

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
	title.Text = string.upper(info.name)
	desc.Text = info.desc
	colorBar.BackgroundColor3 = if def then def.Color else C.Accent
	local maxed = info.level >= info.maxLevel
	levelText.Text = if maxed then ("Lv %d  (MAX)"):format(info.level) else ("Lv %d  ->  Lv %d"):format(info.level, info.level + 1)
	local name = STAT_NAMES[info.stat] or info.stat
	statText.Text = if maxed then ("%s: %s"):format(name, fmt(info.stat, info.before)) else ("%s: %s  ->  %s"):format(name, fmt(info.stat, info.before), fmt(info.stat, info.after))
	-- Buy = Primary green when affordable; MAX / too poor = Disabled grey (Theme).
	local canBuy = not maxed and money() >= (info.cost or 0)
	buyText.Text = if maxed then "MAX" else ("BUY  $%s"):format(abbreviate(info.cost or 0))
	buy.BackgroundColor3 = if canBuy then C.Primary else C.Disabled
	buyStroke.Color = if canBuy then C.PrimaryDark else C.Stroke
end

local function openCard(standId: string, id: string)
	openPad = { standId = standId, id = id }
	local ok, result = pcall(action.InvokeServer, action, "UpgradeInfo", standId, id)
	if not openPad or openPad.id ~= id then
		return
	end
	if ok and typeof(result) == "table" and result.ok then
		info = result
		drawCard()
		win.Open() -- pops in; a no-op when already open (moved to another pad / refreshed)
	end
end

local function closeCard()
	openPad = nil
	info = nil
	if win.IsOpen() then
		closingByCode = true
		win.Close()
	end
end

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
		-- Small pop of the whole card on a successful buy.
		local s = win.scale.Scale
		win.scale.Scale = s * 1.06
		TweenService:Create(win.scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = s }):Play()
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
		if not found or padKey(found) ~= dismissed then
			dismissed = nil -- stepped off (or onto another pad): a closed card may open again
		end
		if found and not dismissed and (not openPad or openPad.id ~= found.id or openPad.standId ~= found.standId) then
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
