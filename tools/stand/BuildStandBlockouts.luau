--!nocheck
-- BuildStandBlockouts: authoring module (Studio only, never runs in the game). Rojo syncs it to
-- ServerStorage.StandTools. From the command bar (Edit mode):
--   require(game.ServerStorage.StandTools.BuildStandBlockouts).Levels()   -- ServerStorage.StandModels.FarmStand.Level1..5
--   require(game.ServerStorage.StandTools.BuildStandBlockouts).Site(workspace.Plots.Plot1)   -- site + markers + ramp
--   require(game.ServerStorage.StandTools.BuildStandBlockouts).Road(workspace.Plots.Plot1)   -- road + decor
-- Every call replaces what it built before. Each level is made of copies of the plot's Sell shop
-- (Shops.Sell) as stalls; keeper / helper pads are copies of a worker hero pad (HeroSlots.Slot1),
-- saved as ServerStorage.StandModels.HeroPadTemplate. Keep the "Markers" folder (StandLayoutConfig).
--
-- Local axes of a level model: PrimaryPart "Base" at the centre of the floor, its LookVector (-Z) is
-- the FRONT (customers), +X local is the stand's right as seen from behind the counter.
-- In code below: r = right, f = forward (front), y = up from the floor.

local ServerStorage = game:GetService("ServerStorage")

local Build = {}

local rad = math.rad
local SMOOTH = Enum.Material.SmoothPlastic

local C = {
	wood = Color3.fromRGB(160, 112, 66),
	woodDark = Color3.fromRGB(110, 72, 42),
	woodLight = Color3.fromRGB(205, 160, 105),
	plank = Color3.fromRGB(184, 132, 80),
	red = Color3.fromRGB(214, 52, 48),
	white = Color3.fromRGB(246, 241, 230),
	green = Color3.fromRGB(70, 175, 80),
	greenDark = Color3.fromRGB(40, 120, 55),
	yellow = Color3.fromRGB(250, 200, 50),
	blue = Color3.fromRGB(60, 130, 220),
	purple = Color3.fromRGB(150, 70, 210),
	gold = Color3.fromRGB(240, 190, 60),
	stone = Color3.fromRGB(190, 185, 175),
	cream = Color3.fromRGB(240, 220, 170),
	orange = Color3.fromRGB(240, 130, 40),
	leafGreen = Color3.fromRGB(90, 160, 70),
}

local function P(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, props: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or SMOOTH
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props then
		for k, v in props do
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

local function folder(parent: Instance, name: string): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function model(parent: Instance, name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

-- Level-model space ---------------------------------------------------------------------------------

local G = 0.2 -- top of the 0.4 thick Base = the floor
local function at(r: number, y: number, f: number): CFrame
	return CFrame.new(r, G + y, -f)
end
local FACE_BACK = CFrame.Angles(0, math.pi, 0) -- looks towards the counter from the front

local function M(markers: Instance, name: string, r: number, y: number, f: number, faceBack: boolean?)
	local cf = at(r, y + 0.1, f) * (if faceBack then FACE_BACK else CFrame.identity)
	return P(markers, name, Vector3.new(1.6, 0.2, 1.6), cf, Color3.new(1, 0, 0), Enum.Material.Neon, {
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	})
end

local function disc(parent: Instance, name: string, cf: CFrame, diameter: number, color: Color3, material: Enum.Material?)
	return P(parent, name, Vector3.new(0.3, diameter, diameter), cf * CFrame.Angles(0, 0, rad(90)), color, material or SMOOTH, { CanCollide = false, Shape = Enum.PartType.Cylinder })
end

local function textGui(part: BasePart, face: Enum.NormalId, text: string, color: Color3, bg: Color3?)
	local g = Instance.new("SurfaceGui")
	g.Face = face
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = 40
	g.Parent = part
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = if bg then 0 else 1
	t.BackgroundColor3 = bg or Color3.new()
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.TextColor3 = color
	t.Text = text
	t.Parent = g
	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = Color3.fromRGB(70, 40, 20)
	s.Parent = t
end

local function floatLabel(part: BasePart, text: string, color: Color3)
	local g = Instance.new("BillboardGui")
	g.Name = "PadLabel"
	g.Size = UDim2.fromOffset(160, 40)
	g.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	g.MaxDistance = 60
	g.Parent = part
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.TextColor3 = color
	t.TextStrokeTransparency = 0.3
	t.Text = text
	t.Parent = g
end

-- Stalls: copies of the plot's Sell shop ----------------------------------------------------------------
-- The Sell shop model (Plot1.Shops.Sell, pivot = centre of its 16 x 1 x 16.5 Base, LookVector = front)
-- is the look of every level: level 1 is one stall, bigger levels are bigger / more stalls.
-- Sell shop layout (unscaled, in its pivot space, -Z = front):
local STALL = {
	halfD = 8.26, -- Base half depth
	matZ = -5.9, -- customers stand on the yellow mat
	npcZ = 1.8, -- behind the counter (NPCSpot)
	counterZ = -2.5,
	counterTopY = 4.65, -- top of CounterTop above the pivot
	coinY = 17.7,
	coinZ = 5.4,
	decorFront = 11.2, -- crates reach this far in front
	decorSide = 10.6, -- and this far to the sides
}
local SELL_RED = Color3.fromRGB(220, 40, 40)
local KEEPER_PAD_SCALE = 0.8 -- = StandLayoutConfig.KeeperPadScale

type Stall = {
	r: number,
	scale: number,
	colors: { Color3 }?, -- { stripe, second stripe }
	trim: Color3?, -- accent (gold on the grand stalls)
	sign: string?, -- text on the floating sign (nil = no sign)
	crates: { left: boolean, right: boolean }, -- keep the crate piles on that side
	serves: { number }?, -- serve point offsets along the counter (unscaled studs)
	keeper: boolean?, -- a keeper pad behind this counter
	vip: boolean?, -- this stall is the VIP lane
}

type Level = {
	stalls: { Stall },
	queue: number,
	queueR: number, -- centre of the waiting line (between the stalls that serve)
	vipQueue: number?,
	accessories: number,
	stock: number,
	pads: { string },
}

local ALL_PADS = { "MaterialPrice", "BiggerShelf", "CarryCapacity", "FarmSide", "HelperTraining", "FarmSign" }

local LEVELS: { [number]: Level } = {
	{ -- 1: one Sell-style stall
		stalls = { { r = 0, scale = 1, sign = "Farm Stand", crates = { left = true, right = true }, serves = { 0 }, keeper = true } },
		queue = 3, queueR = 0, accessories = 2, stock = 4,
		pads = { "MaterialPrice", "BiggerShelf", "CarryCapacity" },
	},
	{ -- 2: a bigger stall, green awning, two lanes
		stalls = { { r = 0, scale = 1.3, colors = { Color3.fromRGB(60, 170, 70), C.white }, sign = "Farm Stand", crates = { left = true, right = true }, serves = { -3, 3 }, keeper = true } },
		queue = 5, queueR = 0, accessories = 4, stock = 6,
		pads = { "MaterialPrice", "BiggerShelf", "CarryCapacity", "FarmSide", "HelperTraining" },
	},
	{ -- 3: two red/white stalls side by side (the reference picture), a keeper at each
		stalls = {
			{ r = -8.3, scale = 1, crates = { left = true, right = false }, serves = { -3, 3 }, keeper = true },
			{ r = 8.3, scale = 1, sign = "Farm Stand", crates = { left = false, right = true }, serves = { 0 }, keeper = true },
		},
		queue = 8, queueR = 0, accessories = 6, stock = 8,
		pads = ALL_PADS,
	},
	{ -- 4: market of three stalls: purple VIP stall, blue and yellow stalls
		stalls = {
			{ r = -16.6, scale = 1, colors = { Color3.fromRGB(150, 70, 210), C.white }, trim = C.gold, sign = "VIP", crates = { left = true, right = false }, vip = true },
			{ r = 0, scale = 1, colors = { C.blue, C.white }, sign = "Farm Market", crates = { left = false, right = false }, serves = { -3, 3 }, keeper = true },
			{ r = 16.6, scale = 1, colors = { C.yellow, C.white }, crates = { left = false, right = true }, serves = { -3, 3 }, keeper = true },
		},
		queue = 12, queueR = 8.3, vipQueue = 3, accessories = 8, stock = 10,
		pads = ALL_PADS,
	},
	{ -- 5: grand market: a big gold-trimmed centre stall between a VIP stall and a red stall
		stalls = {
			{ r = -19.6, scale = 1, colors = { Color3.fromRGB(150, 70, 210), C.gold }, trim = C.gold, sign = "VIP", crates = { left = true, right = false }, vip = true },
			{ r = 0, scale = 1.35, colors = { SELL_RED, C.cream }, trim = C.gold, sign = "Grand Farm Market", crates = { left = false, right = false }, serves = { -4.5, 0, 4.5 }, keeper = true },
			{ r = 19.6, scale = 1, crates = { left = false, right = true }, serves = { -4, 0, 4 }, keeper = true },
		},
		queue = 16, queueR = 9.8, vipQueue = 4, accessories = 10, stock = 12,
		pads = ALL_PADS,
	},
}

local SIDEWALK_F = 25 -- local f where the sidewalk starts (site anchor -> road), queues stop before it

local function sellShop(): Model
	local plots = workspace:FindFirstChild("Plots")
	for _, plot in if plots then plots:GetChildren() else {} do
		local shops = plot:FindFirstChild("Shops")
		local sell = shops and shops:FindFirstChild("Sell")
		if sell and sell:IsA("Model") then
			return sell
		end
	end
	error("BuildStandBlockouts: no Shops.Sell model in any plot to copy the stall look from")
end

local function buildStall(parent: Instance, source: Model, s: Stall): Model
	local stall = source:Clone()
	stall.Name = "Stall"
	for k in stall:GetAttributes() do
		stall:SetAttribute(k, nil)
	end
	for _, name in { "NPCSpot", "PromptPart" } do
		local x = stall:FindFirstChild(name)
		if x then
			x:Destroy()
		end
	end
	for _, d in stall:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			d:Destroy()
		end
	end
	local piv = stall:GetPivot()
	-- Crate piles on a side that touches another stall go (they would overlap the neighbour).
	local decor = stall:FindFirstChild("Decor")
	if decor then
		for _, c in decor:GetChildren() do
			if c:IsA("Model") and #c:GetChildren() == 0 then
				c:Destroy()
			elseif c:IsA("Model") and c.Name:find("Crate") then
				local x = piv:PointToObjectSpace(c:GetBoundingBox().Position).X
				if (x > 3 and not s.crates.right) or (x < -3 and not s.crates.left) then
					c:Destroy()
				end
			end
		end
	end
	-- Awning colours (the Sell shop is red / white).
	if s.colors then
		for _, d in stall:GetChildren() do
			if d:IsA("BasePart") and (d.Name == "Awning" or d.Name == "Valance") then
				local isRed = d.Color.R > 0.7 and d.Color.G < 0.3
				d.Color = if isRed then s.colors[1] else s.colors[2]
			end
		end
	end
	if s.trim then
		for _, d in stall:GetChildren() do
			if d:IsA("BasePart") and (d.Name == "SideTrim" or d.Name == "RoofBeam" or d.Name == "CoinRim") then
				d.Color = s.trim
			end
		end
	end
	-- Floating sign: "Sell" -> the stand's name (or no sign at all).
	local anchor = stall:FindFirstChild("SignAnchor")
	local sign = anchor and anchor:FindFirstChild("ShopSign")
	if sign then
		if s.sign then
			for _, t in sign:GetChildren() do
				if t:IsA("TextLabel") then
					t.Text = s.sign
				end
			end
		else
			sign:Destroy()
		end
	end
	stall:PivotTo(CFrame.new())
	if s.scale ~= 1 then
		stall:ScaleTo(s.scale)
	end
	-- Base bottom on the level floor (the stall's Base is 1 stud thick, scaled).
	stall:PivotTo(CFrame.new(s.r, G + 0.5 * s.scale, 0))
	stall.Parent = parent
	return stall
end

local function padTemplate(): Model
	local models = ServerStorage:FindFirstChild("StandModels") or folder(ServerStorage, "StandModels")
	local existing = models:FindFirstChild("HeroPadTemplate")
	if existing then
		existing:Destroy()
	end
	local plots = workspace:FindFirstChild("Plots")
	local plot1 = plots and plots:FindFirstChild("Plot1")
	local slots = plot1 and plot1:FindFirstChild("HeroSlots")
	local slot = slots and slots:FindFirstChild("Slot1")
	assert(slot, "BuildStandBlockouts: Plot1.HeroSlots.Slot1 is the pad template and is missing")
	local t = slot:Clone()
	t.Name = "HeroPadTemplate"
	for k in t:GetAttributes() do
		t:SetAttribute(k, nil)
	end
	for _, d in t:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			d:Destroy()
		end
	end
	for _, c in t:GetChildren() do
		if c:IsA("Model") then
			c:Destroy() -- the idle hero copy on a worker pad
		end
	end
	local pad = t:FindFirstChild("Pad")
	if pad and pad:IsA("BasePart") then
		local default = pad:GetAttribute("DefaultColor")
		if typeof(default) == "Color3" then
			pad.Color = default
		end
		pad:SetAttribute("DefaultColor", nil)
		local info = pad:FindFirstChild("HeroInfo")
		for _, g in if info then info:GetChildren() else {} do
			if g:IsA("BillboardGui") then
				g.Enabled = false
			end
		end
		local empty = pad:FindFirstChild("Empty")
		for _, g in if empty then empty:GetDescendants() else {} do
			if g:IsA("BillboardGui") then
				g.Enabled = true
			elseif g:IsA("TextLabel") and g.Name == "EmptyText" then
				g.RichText = false
				g.Text = "Empty Slot"
			end
		end
	end
	local base = t:FindFirstChild("Base")
	if base and base:IsA("BasePart") then
		t.PrimaryPart = base
	end
	t.Parent = models
	return t
end

-- A copy of the hero pad with its bottom on cf's height, facing like cf.
local function placePad(template: Model, parent: Instance, name: string, cf: CFrame, scale: number): Model
	local pad = template:Clone()
	pad.Name = name
	pad:PivotTo(CFrame.new())
	if scale ~= 1 then
		pad:ScaleTo(scale)
	end
	pad:PivotTo(cf)
	local box, size = pad:GetBoundingBox()
	pad:PivotTo(pad:GetPivot() + Vector3.new(0, cf.Position.Y - (box.Position.Y - size.Y / 2), 0))
	pad.Parent = parent
	return pad
end
Build.PlacePad = placePad

local function addLevel(stand: Instance, level: number, def: Level, source: Model, template: Model): Model
	local m = model(stand, "Level" .. level)
	local body = model(m, "Body")
	local markers = folder(m, "Markers")
	local pads = folder(m, "Pads")

	local maxScale, halfW = 1, 0
	for _, s in def.stalls do
		maxScale = math.max(maxScale, s.scale)
		halfW = math.max(halfW, math.abs(s.r) + STALL.decorSide * s.scale)
	end
	local halfD = STALL.halfD * maxScale
	local base = P(body, "Base", Vector3.new(halfW * 2 - 3, 0.4, halfD * 2), CFrame.new(0, 0, 0), C.plank, Enum.Material.WoodPlanks)
	m.PrimaryPart = base

	local serveN, keeperN = 0, 0
	local mainStall: Stall = def.stalls[1]
	local mainModel: Model? = nil
	for _, s in def.stalls do
		local stallModel = buildStall(body, source, s)
		if s.sign and not s.vip then
			mainStall = s
			mainModel = stallModel
		end
		local sc = s.scale
		local floorY = 1.0 * sc -- top of this stall's Base above the level floor
		for _, off in s.serves or {} do
			serveN += 1
			M(markers, "ServePoint_" .. serveN, s.r + off * sc, floorY - 0.2, -STALL.matZ * sc, true)
		end
		if s.vip then
			M(markers, "VipServePoint", s.r, floorY - 0.2, -STALL.matZ * sc, true)
		end
		if s.keeper then
			keeperN += 1
			local f = -STALL.npcZ * sc
			M(markers, "KeeperSlot_" .. keeperN, s.r, floorY - 0.1, f)
			placePad(template, pads, "KeeperPad_" .. keeperN, at(s.r, floorY, f), KEEPER_PAD_SCALE)
		end
	end

	-- One waiting line in front, snaking in rows parallel to the counters; 1 = next in line.
	local firstRow = -STALL.matZ * maxScale + 3.5
	local maxRows = math.max(1, math.floor((SIDEWALK_F - 2 - firstRow) / 3) + 1)
	local cols = math.max(1, math.ceil(def.queue / maxRows))
	local i, row = 0, 0
	while i < def.queue do
		for c = 0, cols - 1 do
			if i >= def.queue then
				break
			end
			i += 1
			local idx = if row % 2 == 0 then c else cols - 1 - c
			M(markers, "QueuePoint_" .. i, def.queueR + ((cols - 1) / 2 - idx) * 3, 0, firstRow + row * 3, true)
		end
		row += 1
	end
	if def.vipQueue then
		for _, s in def.stalls do
			if s.vip then
				for q = 1, def.vipQueue do
					M(markers, "VipQueuePoint_" .. q, s.r, 0, firstRow + (q - 1) * 3, true)
				end
				P(pads, "VipCarpet", Vector3.new(3, 0.1, def.vipQueue * 3 + 1), at(s.r, 0.05, firstRow + (def.vipQueue - 1) * 1.5), C.purple, Enum.Material.Fabric, { CanCollide = false })
			end
		end
	end

	-- Behind the stand: the helpers' drop point (end of their ramp), the restock mat.
	M(markers, "HelperDropPoint", 1.5, 0, -(halfD + 1.5))
	local restockR = 7.5
	M(markers, "RestockMat", restockR, 0, -(halfD + 3.5))
	local mat = P(pads, "RestockMat", Vector3.new(8, 0.2, 5.5), at(restockR, 0.1, -(halfD + 3.5)), Color3.fromRGB(196, 140, 60), Enum.Material.Fabric, { CanCollide = false })
	textGui(mat, Enum.NormalId.Top, "RESTOCK", Color3.fromRGB(120, 60, 20))

	-- Upgrade pads on the right side (towards the plot gate), columns of 3, 6 studs apart.
	local col0 = halfW + 4
	for p, id in def.pads do
		local col = math.floor((p - 1) / 3)
		local rowN = (p - 1) % 3
		local r, f = col0 + col * 6, 2 - rowN * 6
		M(markers, "UpgradePad_" .. id, r, 0, f)
		local d = disc(pads, "UpgradePad_" .. id, at(r, 0.05, f), 4.6, Color3.fromRGB(80, 230, 90), Enum.Material.Neon)
		floatLabel(d, id, C.white)
		disc(pads, "UpgradeRim", at(r, 0.02, f), 5.4, C.greenDark)
	end

	-- Fame accessory spots around the stalls.
	local roofTop = 13 * maxScale
	local candidates = {
		{ -(halfW - 2), 0, STALL.decorFront * maxScale + 1 },
		{ halfW - 2, 0, STALL.decorFront * maxScale + 1 },
		{ mainStall.r, roofTop + 0.5, 2 },
		{ -(halfW - 3), roofTop - 1.5, -STALL.counterZ * maxScale },
		{ halfW - 3, roofTop - 1.5, -STALL.counterZ * maxScale },
		{ -(halfW + 1.5), 0, -(halfD - 2) },
		{ halfW + 1.5, 0, halfD - 2 },
		{ -(halfW / 2), roofTop + 0.5, 2 },
		{ halfW / 2, roofTop + 0.5, 2 },
		{ -(halfW - 4), 0, firstRow + 9 },
	}
	for a = 1, def.accessories do
		local c = candidates[a]
		M(markers, "AccessorySlot_" .. a, c[1], c[2], c[3])
	end

	-- Goods on the counters, filled in order, spread over the stalls.
	local n = #def.stalls
	local perStall = math.ceil(def.stock / n)
	for s = 1, def.stock do
		local st = def.stalls[(s - 1) % n + 1]
		local k = math.floor((s - 1) / n)
		local span = 10 * st.scale
		local r = st.r - span / 2 + span * (k + 0.5) / perStall
		M(markers, "StockVisual_" .. s, r, (STALL.counterTopY + 0.5) * st.scale - 0.1, -STALL.counterZ * st.scale)
	end

	-- The main stall's coin sign makes room for the stand's billboard (StandClient draws it there).
	if mainModel then
		mainModel.Name = "MainStall"
		for _, name in { "Coin", "CoinInner", "CoinRim", "CoinFace", "CoinPost", "SignAnchor" } do
			local part = mainModel:FindFirstChild(name)
			if part then
				part:Destroy()
			end
		end
	end
	local ms = mainStall.scale
	M(markers, "BillboardAnchor", mainStall.r, (STALL.coinY + 0.5) * ms - 1.5, -STALL.coinZ * ms + 1)
	M(markers, "CoinFxPoint", mainStall.r, 7 * ms, -STALL.counterZ * ms)
	task.wait()
	return m
end

function Build.Levels(): string
	local models = ServerStorage:FindFirstChild("StandModels") or folder(ServerStorage, "StandModels")
	local old = models:FindFirstChild("FarmStand")
	if old then
		old:Destroy()
	end
	local stand = folder(models, "FarmStand")
	local source = sellShop()
	local template = padTemplate()
	local sizes = {}
	for level, def in LEVELS do
		local m = addLevel(stand, level, def, source, template)
		local _, size = (m:FindFirstChild("Body") :: Model):GetBoundingBox()
		table.insert(sizes, ("Level%d body %.1f x %.1f x %.1f"):format(level, size.X, size.Y, size.Z))
	end
	return table.concat(sizes, "\n")
end

-- Site on a plot ---------------------------------------------------------------------------------------

-- World layout around Plot1 (front of the plot = +Z, stairs at x 2.6, plot rim top y = 5).
local SITE_POS = Vector3.new(53, 0.3, 27) -- site anchor; the stand faces +Z (the road)
local RAMP_X = 51.5 -- helper ramp through the front fence, between the posts at x 48.7 and 54.3
local FENCE_Z = 4.95

-- The front fence rails are long single parts: this puts a gap in them between x0 and x1 (and first
-- closes the gap an older build made at x 38.2 .. 42.6).
local function fenceGap(plot: Model, x0: number, x1: number)
	local land = plot:FindFirstChild("Land")
	local fence = land and land:FindFirstChild("Fence")
	if not fence then
		return
	end
	local rails = {}
	for _, d in fence:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "Rail" and math.abs(d.Position.Z - FENCE_Z) < 0.5 and math.abs(d.Size.Z - 0.5) < 0.01 then
			table.insert(rails, d)
		end
	end
	-- re-join pieces split before (same height, touching ends within the old gap)
	for _, a in rails do
		for _, b in rails do
			if a ~= b and a.Parent and b.Parent and math.abs(a.Position.Y - b.Position.Y) < 0.01 then
				local aEnd = a.Position.X + a.Size.X / 2
				local bStart = b.Position.X - b.Size.X / 2
				if math.abs(aEnd - 38.2) < 0.05 and math.abs(bStart - 42.6) < 0.05 then
					local x0a, x1b = a.Position.X - a.Size.X / 2, b.Position.X + b.Size.X / 2
					b.Size = Vector3.new(x1b - x0a, b.Size.Y, b.Size.Z)
					b.CFrame = CFrame.new((x0a + x1b) / 2, b.Position.Y, b.Position.Z)
					a:Destroy()
				end
			end
		end
	end
	for _, d in fence:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "Rail" and math.abs(d.Position.Z - FENCE_Z) < 0.5 then
			local a0, a1 = d.Position.X - d.Size.X / 2, d.Position.X + d.Size.X / 2
			if a0 < x0 and a1 > x1 then
				local left = d:Clone()
				left.Size = Vector3.new(x0 - a0, d.Size.Y, d.Size.Z)
				left.CFrame = CFrame.new((a0 + x0) / 2, d.Position.Y, d.Position.Z)
				left.Parent = d.Parent
				d.Size = Vector3.new(a1 - x1, d.Size.Y, d.Size.Z)
				d.CFrame = CFrame.new((x1 + a1) / 2, d.Position.Y, d.Position.Z)
			end
		end
	end
end

function Build.Site(plot: Model)
	local sites = plot:FindFirstChild("StandSites") or folder(plot, "StandSites")
	local old = sites:FindFirstChild("FarmStand")
	if old then
		old:Destroy()
	end
	local site = model(sites, "FarmStand")
	local anchorCf = CFrame.lookAt(SITE_POS, SITE_POS + Vector3.new(0, 0, 1))
	local anchor = P(site, "Anchor", Vector3.new(2, 0.4, 2), anchorCf, Color3.new(1, 0, 1), SMOOTH, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
	site.PrimaryPart = anchor
	-- Paved plaza under the stand area (largest level + pads), like the brick pavers in the reference.
	P(site, "Plaza", Vector3.new(98, 0.2, 44), CFrame.new(SITE_POS.X - 7, 0.1, 29.5), Color3.fromRGB(214, 196, 160), Enum.Material.Brick)

	-- Site markers (world positions).
	local markers = folder(site, "Markers")
	local function SM(name: string, cf: CFrame)
		P(markers, name, Vector3.new(1.6, 0.2, 1.6), cf + Vector3.new(0, 0.1, 0), Color3.new(1, 0, 0), Enum.Material.Neon, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
	end
	local faceFront = CFrame.Angles(0, math.pi, 0) -- LookVector +Z (towards the plot's front)
	-- Helper pads: a row of three right next to the plot's TreasureChest (chest at x -31, z -33).
	local pads = folder(site, "Pads")
	local template = ServerStorage:FindFirstChild("StandModels") and ServerStorage.StandModels:FindFirstChild("HeroPadTemplate")
	for h, x in { -21, -13.5, -6 } do
		local cf = CFrame.new(x, 5, -33) * faceFront
		SM("HelperSlot_" .. h, cf)
		if template then
			Build.PlacePad(template, pads, "HelperPad_" .. h, cf, 1)
		end
	end
	SM("HelperPickupPoint", CFrame.new(-38.5, 5, -31)) -- left side of the chest (the Loot Pad is in front)
	SM("HelperPath_1", CFrame.new(-41, 5, -20))
	SM("HelperPath_2", CFrame.new(-41, 5, -1)) -- left of the worker pads row
	SM("HelperPath_3", CFrame.new(RAMP_X, 5, -1)) -- behind the worker pads, inside the front fence (z 1.2)
	SM("HelperPath_4", CFrame.new(RAMP_X, 5, 4.6)) -- top of the helper ramp
	SM("HelperPath_5", CFrame.new(RAMP_X, 0.2, 14)) -- bottom of the ramp, behind the stand
	-- Customers walk in on the plot side of the sidewalk (z 54) and out on the road side (z 57).
	SM("CustomerSpawn_1", CFrame.new(SITE_POS.X - 60, 0.6, 54))
	SM("CustomerSpawn_2", CFrame.new(SITE_POS.X + 60, 0.6, 54))
	SM("CustomerPath_1", CFrame.new(SITE_POS.X + 16, 0.6, 54))
	SM("CustomerPath_2", CFrame.new(SITE_POS.X - 16, 0.6, 54))
	SM("CustomerExit_1", CFrame.new(SITE_POS.X - 60, 0.6, 57))
	SM("CustomerExit_2", CFrame.new(SITE_POS.X + 60, 0.6, 57))

	-- Helper ramp from the plot rim down to the back of the stand, through a gap in the front fence.
	local ramp = model(site, "HelperRamp")
	local top, bottom = Vector3.new(RAMP_X, 5, 5.2), Vector3.new(RAMP_X, 0.2, 13.2)
	local mid = (top + bottom) / 2
	local len = (top - bottom).Magnitude
	P(ramp, "Ramp", Vector3.new(3.6, 0.5, len), CFrame.lookAt(mid, bottom), C.plank, Enum.Material.WoodPlanks)
	for _, side in { -1, 1 } do
		local off = Vector3.new(side * 1.9, 1.4, 0)
		P(ramp, "RampRail", Vector3.new(0.3, 0.3, len), CFrame.lookAt(mid + off, bottom + off), C.woodDark, Enum.Material.Wood)
	end
	fenceGap(plot, RAMP_X - 2.2, RAMP_X + 2.2)
	return site
end

-- Loot Pad -------------------------------------------------------------------------------------------------

-- The plot's chest (the loot pile) goes inside the plot (so it is saved and only its owner uses it),
-- and a "LootPad" mat in front of it: players stand on it to pick materials up (CarryService).
function Build.LootPad(plot: Model)
	local chest = plot:FindFirstChild("TreasureChest", true) or workspace:FindFirstChild("TreasureChest")
	assert(chest, "BuildStandBlockouts: no TreasureChest")
	if chest.Parent ~= plot then
		chest.Parent = plot
	end
	local old = plot:FindFirstChild("LootPad")
	if old then
		old:Destroy()
	end
	local front = chest:GetPivot() * CFrame.new(0, 0, -7.5) -- chest LookVector = its front
	local pos = Vector3.new(front.X, 5, front.Z)
	local mat = P(plot, "LootPad", Vector3.new(8, 0.25, 5.5), CFrame.lookAt(pos, pos - chest:GetPivot().LookVector) + Vector3.new(0, 0.125, 0), Color3.fromRGB(240, 190, 60), Enum.Material.Fabric, { CanCollide = false })
	textGui(mat, Enum.NormalId.Top, "COLLECT LOOT", Color3.fromRGB(120, 60, 20))
	P(plot, "LootPadBorder", Vector3.new(9, 0.15, 6.5), mat.CFrame - Vector3.new(0, 0.06, 0), Color3.fromRGB(200, 110, 30), Enum.Material.Fabric, { CanCollide = false })
	return mat
end

-- Road ----------------------------------------------------------------------------------------------------

function Build.Road(plot: Model)
	local old = plot:FindFirstChild("Road")
	if old then
		old:Destroy()
	end
	local road = model(plot, "Road")
	local X0, X1 = -170, 190
	local LEN, CX = X1 - X0, (X0 + X1) / 2
	local asphalt = Color3.fromRGB(42, 42, 46)
	P(road, "Asphalt", Vector3.new(LEN, 0.4, 16), CFrame.new(CX, 0.2, 66), asphalt, Enum.Material.Asphalt)
	-- dashed centre line
	local x = X0 + 3
	while x < X1 - 3 do
		P(road, "Dash", Vector3.new(5, 0.05, 0.5), CFrame.new(x, 0.42, 66), C.white, SMOOTH, { CanCollide = false })
		x += 11
	end
	-- sidewalks + curbs
	for _, z in { 55, 77 } do
		P(road, "Sidewalk", Vector3.new(LEN, 0.6, 6), CFrame.new(CX, 0.3, z), Color3.fromRGB(205, 205, 200), Enum.Material.Concrete)
	end
	for _, z in { 58.15, 73.85 } do
		P(road, "Curb", Vector3.new(LEN, 0.75, 0.3), CFrame.new(CX, 0.37, z), Color3.fromRGB(160, 160, 158), Enum.Material.Concrete)
	end
	task.wait()
	-- street lamps on the far sidewalk
	for lx = X0 + 10, X1 - 10, 40 do
		P(road, "LampPole", Vector3.new(0.6, 12, 0.6), CFrame.new(lx, 6.6, 79), Color3.fromRGB(60, 60, 66), Enum.Material.Metal)
		P(road, "LampArm", Vector3.new(0.4, 0.4, 3), CFrame.new(lx, 12.4, 77.6), Color3.fromRGB(60, 60, 66), Enum.Material.Metal)
		local bulb = P(road, "LampBulb", Vector3.new(1.2, 0.6, 1.2), CFrame.new(lx, 12, 76.2), Color3.fromRGB(255, 230, 170), Enum.Material.Neon)
		local light = Instance.new("SpotLight")
		light.Face = Enum.NormalId.Bottom
		light.Range = 26
		light.Angle = 80
		light.Brightness = 1.5
		light.Color = Color3.fromRGB(255, 220, 160)
		light.Parent = bulb
	end
	-- wooden fence along the plot side of the sidewalk, open in front of the stand (x 4..88)
	local function fenceRun(xa: number, xb: number)
		local mid = (xa + xb) / 2
		for _, y in { 1.6, 2.8 } do
			P(road, "FenceRail", Vector3.new(xb - xa, 0.35, 0.3), CFrame.new(mid, y, 51.5), C.wood, Enum.Material.Wood)
		end
		for fx = xa, xb, 4 do
			P(road, "FencePost", Vector3.new(0.5, 3.4, 0.5), CFrame.new(fx, 1.7, 51.5), C.woodDark, Enum.Material.Wood)
		end
	end
	fenceRun(X0, 0)
	fenceRun(92, X1)
	task.wait()
	-- autumn leaves on the road and sidewalks
	local rng = Random.new(7)
	local leafColors = { Color3.fromRGB(230, 90, 30), Color3.fromRGB(245, 160, 40), Color3.fromRGB(200, 50, 35), Color3.fromRGB(250, 200, 60) }
	local leaves = model(road, "Leaves")
	for n = 1, 260 do
		local lx = rng:NextNumber(X0, X1)
		local lz = rng:NextNumber(52.5, 79.5)
		local y = if lz > 58.3 and lz < 73.7 then 0.43 else 0.62
		P(leaves, "Leaf", Vector3.new(0.9, 0.05, 0.6), CFrame.new(lx, y, lz) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0), leafColors[rng:NextInteger(1, #leafColors)], SMOOTH, { CanCollide = false, CanQuery = false, CanTouch = false })
		if n % 80 == 0 then
			task.wait()
		end
	end
	-- decor along the verge between fence and plot: pumpkins, flowers, bushes, autumn trees
	local decor = model(road, "Decor")
	local function pumpkin(px: number, pz: number, s: number)
		P(decor, "Pumpkin", Vector3.new(s, s * 0.8, s), CFrame.new(px, s * 0.4, pz), C.orange, SMOOTH, { Shape = Enum.PartType.Ball })
		P(decor, "Stem", Vector3.new(0.2, 0.5, 0.2), CFrame.new(px, s * 0.85, pz), C.greenDark, SMOOTH)
	end
	local function flowers(px: number, pz: number)
		for k = 1, 5 do
			local fx, fz = px + rng:NextNumber(-1, 1), pz + rng:NextNumber(-1, 1)
			P(decor, "Stalk", Vector3.new(0.12, 1, 0.12), CFrame.new(fx, 0.5, fz), C.greenDark, SMOOTH, { CanCollide = false })
			P(decor, "Bloom", Vector3.new(0.5, 0.3, 0.5), CFrame.new(fx, 1.05, fz), ({ C.red, C.yellow, C.white, C.purple, Color3.fromRGB(255, 150, 200) })[k], SMOOTH, { CanCollide = false })
		end
	end
	local function bush(px: number, pz: number, s: number)
		P(decor, "Bush", Vector3.new(s, s * 0.8, s), CFrame.new(px, s * 0.4, pz), C.leafGreen, Enum.Material.Grass, { Shape = Enum.PartType.Ball })
	end
	local function tree(px: number, pz: number, color: Color3)
		P(decor, "Trunk", Vector3.new(1.4, 7, 1.4), CFrame.new(px, 3.5, pz), C.woodDark, Enum.Material.Wood)
		P(decor, "Canopy", Vector3.new(7, 5, 7), CFrame.new(px, 8.5, pz), color, Enum.Material.Grass)
		P(decor, "Canopy", Vector3.new(5, 3, 5), CFrame.new(px, 12, pz), color, Enum.Material.Grass)
	end
	for _, spot in { { -12, 48 }, { -40, 47 }, { -75, 48 }, { -110, 47 }, { 100, 48 }, { 130, 47 } } do
		pumpkin(spot[1], spot[2], rng:NextNumber(1.6, 2.6))
		pumpkin(spot[1] + 2, spot[2] + 0.6, rng:NextNumber(1, 1.6))
	end
	for _, spot in { { -20, 49.5 }, { -55, 49.5 }, { -90, 49.5 }, { 96, 49.5 }, { 120, 49.5 }, { 150, 49.5 } } do
		flowers(spot[1], spot[2])
	end
	for _, spot in { { -30, 46 }, { -65, 46 }, { -130, 46 }, { 110, 46 }, { 160, 46 } } do
		bush(spot[1], spot[2], rng:NextNumber(3, 4.5))
	end
	local autumn = { Color3.fromRGB(225, 120, 40), Color3.fromRGB(205, 70, 40), Color3.fromRGB(235, 175, 50) }
	for k, spot in { { -48, 40 }, { -95, 38 }, { -140, 40 }, { 140, 38 }, { -60, 88 }, { -20, 88 }, { 20, 88 }, { -110, 88 } } do
		tree(spot[1], spot[2], autumn[(k - 1) % #autumn + 1])
	end
	-- benches on the far sidewalk, a bus stop sign and a mailbox near the stand
	for _, bx in { -40, 30, 140 } do
		P(decor, "BenchSeat", Vector3.new(5, 0.4, 1.4), CFrame.new(bx, 1.6, 78.6), C.wood, Enum.Material.WoodPlanks)
		P(decor, "BenchBack", Vector3.new(5, 1.4, 0.3), CFrame.new(bx, 2.5, 79.3), C.wood, Enum.Material.WoodPlanks)
		for _, s in { -2, 2 } do
			P(decor, "BenchLeg", Vector3.new(0.3, 1.2, 1.2), CFrame.new(bx + s, 1, 78.6), Color3.fromRGB(60, 60, 66), Enum.Material.Metal)
		end
	end
	P(decor, "MailboxPost", Vector3.new(0.4, 3, 0.4), CFrame.new(94, 1.8, 51), C.woodDark, Enum.Material.Wood)
	P(decor, "Mailbox", Vector3.new(1, 1, 1.8), CFrame.new(94, 3.6, 51), C.red, SMOOTH)
	local sign = P(decor, "StandSign", Vector3.new(6, 2.4, 0.3), CFrame.new(-4, 3.6, 51.2) * CFrame.Angles(0, math.pi, 0), C.red, Enum.Material.Wood)
	textGui(sign, Enum.NormalId.Front, "FARM STAND →", C.white)
	P(decor, "StandSignPost", Vector3.new(0.4, 3, 0.4), CFrame.new(-4, 1.5, 51.2), C.woodDark, Enum.Material.Wood)
	return road
end

function Build.All(plot: Model?)
	local p = plot or workspace.Plots.Plot1
	Build.Levels()
	Build.LootPad(p)
	Build.Site(p)
	Build.Road(p)
end

return Build
