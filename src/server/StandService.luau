-- StandService: the Farm Stand on each plot (StandLayoutConfig / StandLayout) and its hero pads.
--
-- Layout: on start it runs the Blueprint Check (warns about every missing / misnamed / duplicate
-- marker, per stand and level) and puts each plot's stand on its site, at the owner's saved level.
-- Markers stay hidden unless the Studio-only workspace attribute "StandLayoutDebug" is true (then
-- StandLayoutDebug shows them).
--
-- Selling: each stand has a Level and a Stock (material id -> amount). Its stats come from
-- StandStats (StandConfig: MaxStock, CustomersPerMinute, MaxItemsPerCustomer, PriceMultiplier).
-- A customer walks up every ~60 / CustomersPerMinute seconds (randomised by CustomerJitter), buys
-- 1..MaxItemsPerCustomer random items from the stock (or leaves when it is empty) and the owner gets
-- material price x PriceMultiplier for each. Stock comes in through StandService.AddStock: the owner
-- standing on the stand's Restock mat moves their carried materials in (StandConfig.Restock, up to
-- MaxStock, the rest stays carried), and later the helpers. Clients read the site attributes (Stock, MaxStock, CustomersPerMinute, PriceMin,
-- PriceMax, Level, StandName, OwnerUserId) for the billboard and get Remotes.StandEvent
-- ("Customer", site, { id, vip, items, money, ownerId, look }) for each customer (CustomerClient walks
-- an NPC in; items = 0 means it found no stock) and ("LevelUp", site, level, oldLevel) for the effects.
-- The money is given the moment the customer arrives; the NPC only shows it.
--
-- Levels: Remotes.StandAction (RemoteFunction) -> { ok, message?, preview? }
--   ("Preview", standId)   current and next level stats (StandStats.Breakdown), cost, keeper slots
--   ("UpgradeInfo", standId, upgradeId)  an upgrade pad's level, cost and its stat before -> after
--   ("BuyUpgrade", standId, upgradeId)   buys the next level (must stand on that pad, pad must exist at
--                          this stand level). Levels are saved per stand (StandUpgradeConfig effects
--                          go through StandStats; Carry Capacity sets the owner's "CarryBonus").
--   ("Upgrade", standId)   pays StandConfig UpgradeCost and goes up a level: the level model is swapped,
--                          stock / fame / helpers stay, keepers stay on the same slot number (slots the
--                          new level lacks send their hero back). Must be near the stand.
-- The "Manage Stand" prompt (StandPrompt, key F) at the counter opens StandUI.
--
-- Hero pads (copies of a worker pad, ServerStorage.StandModels.HeroPadTemplate):
--   Keeper pads  KeeperPad_N  behind the counters (placed stand's "Pads" folder, at KeeperSlot_N)
--   Helper pads  HelperPad_1..3  next to the plot's chest (site's "Pads" folder, at HelperSlot_N)
-- They work like worker pads: hold a hero on the hotbar (HeroSlotService selection) and press E on an
-- empty pad to place it, E on a filled pad takes it back. Each copy of a hero stands on one pad only,
-- whatever the kind (HeroPlacement). A placed hero stands idle on the pad. A keeper adds its rarity
-- bonus to the stand (StandConfig.RarityBonus via StandStats: customers / min and max stock, the
-- star slot x StarSlotBonus), shows it on the pad and waves at customers now and then. Helpers carry
-- in a later step. Pad models get attribute HeroId (hero name or "") and tag "StandHeroPad", so clients
-- can count the copies on them.
-- Saved per stand (DataService "Stands"): Level, Stock, which hero is on which keeper / helper pad.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StandLayoutConfig = require(Shared:WaitForChild("StandLayoutConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local StandLayout = require(script.Parent:WaitForChild("StandLayout"))
local HeroPlacement = require(script.Parent:WaitForChild("HeroPlacement"))
local HeroSlotService = require(script.Parent:WaitForChild("HeroSlotService"))
local HeroModels = require(script.Parent:WaitForChild("HeroModels"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))
local ToastService = require(script.Parent:WaitForChild("ToastService"))
local StandConfig = require(Shared:WaitForChild("StandConfig"))
local StandStats = require(Shared:WaitForChild("StandStats"))
local MaterialConfig = require(Shared:WaitForChild("MaterialConfig"))
local StandUpgradeConfig = require(Shared:WaitForChild("StandUpgradeConfig"))
local CarryService = require(script.Parent:WaitForChild("CarryService"))

local StandService = {}

local PROMPT_NAME = "HeroSlotPrompt" -- same name as worker pads: SlotPromptUI draws it
local PROMPT_DISTANCE = 10
local PAD_TAG = "StandHeroPad"
local PAD_HERO_NAME = "PadHero"
local PADS_FOLDER = "Pads"
local MANAGE_PROMPT = "StandPrompt"

type Kind = "Keeper" | "Helper"
local KINDS: { Kind } = { "Keeper", "Helper" }
local LABEL: { [Kind]: string } = { Keeper = "Keeper Slot", Helper = "Helper Slot" }

type StandPads = {
	Keeper: { [number]: string }, -- keeper pad index -> hero
	Helper: { [number]: string }, -- helper pad index -> hero
	Level: number,
	Stock: { [string]: number }, -- material id -> amount for sale
	NextCustomer: number, -- os.clock() when the next customer walks up (0 = not scheduled yet)
	Restocking: boolean?, -- the owner is putting materials in from the Restock mat right now
	Trips: { [number]: Trip }, -- helper pad index -> its trip (not saved: helpers start resting)
	Upgrades: { [string]: number }, -- upgrade id -> level (StandUpgradeConfig)
}

type Trip = {
	hero: string,
	phase: string, -- "Idle" | "ToPickup" | "Carrying" | "Dropping" | "Returning"
	phaseEnd: number, -- os.clock() when the phase is over
	nextCheck: number, -- Idle: os.clock() of the next look for work
	carrying: { [string]: number }?,
}
type PlotState = {
	plot: Model,
	owner: Player,
	stands: { [string]: StandPads },
	connections: { RBXScriptConnection },
}

local states: { [Model]: PlotState } = {}
local pending: { [Player]: { [string]: StandPads } } = {}


-- Pads ---------------------------------------------------------------------------------------------

local function padTemplate(): Model?
	local models = ServerStorage:FindFirstChild(StandLayoutConfig.ModelsFolder)
	local t = models and models:FindFirstChild(StandLayoutConfig.PadTemplate)
	return if t and t:IsA("Model") then t else nil
end

-- Where the pads of a kind live: the placed stand (keepers move with the level) or the site (helpers).
local function padHolder(plot: Instance, standId: string, kind: Kind): Instance?
	local holder = if kind == "Keeper" then StandLayout.Placed(plot, standId) else StandLayout.Site(plot, standId)
	if not holder then
		return nil
	end
	local f = holder:FindFirstChild(PADS_FOLDER)
	if not f then
		local nf = Instance.new("Folder")
		nf.Name = PADS_FOLDER
		nf.Parent = holder
		f = nf
	end
	return f
end

local function markerPrefix(kind: Kind): string
	return if kind == "Keeper" then "KeeperSlot" else "HelperSlot"
end

-- index -> pad model, creating missing pads at their markers from the template.
local function padsOf(plot: Instance, standId: string, kind: Kind): { [number]: Model }
	local out = {}
	local holder = padHolder(plot, standId, kind)
	if not holder then
		return out
	end
	local markers = StandLayout.List(plot, standId, markerPrefix(kind))
	for i, cf in markers do
		local name = ("%sPad_%d"):format(kind, i)
		local pad = holder:FindFirstChild(name)
		if not pad then
			local template = padTemplate()
			if not template then
				continue
			end
			local m = template:Clone()
			m.Name = name
			m:PivotTo(CFrame.new())
			if kind == "Keeper" and StandLayoutConfig.KeeperPadScale ~= 1 then
				m:ScaleTo(StandLayoutConfig.KeeperPadScale)
			end
			m:PivotTo(cf)
			local box, size = m:GetBoundingBox()
			m:PivotTo(m:GetPivot() + Vector3.new(0, (cf.Position.Y - 0.1) - (box.Position.Y - size.Y / 2), 0))
			m.Parent = holder
			pad = m
		end
		if pad:IsA("Model") and pad:FindFirstChild("Pad") then
			pad:SetAttribute("PadKind", kind)
			pad:SetAttribute("PadIndex", i)
			pad:SetAttribute("StandId", standId)
			if pad:GetAttribute("HeroId") == nil then
				pad:SetAttribute("HeroId", "")
			end
			CollectionService:AddTag(pad, PAD_TAG)
			out[i] = pad
		end
	end
	return out
end

-- The pad's two billboards (same as worker pads): Pad.Empty (empty) and Pad.HeroInfo (with a hero).
local function billboard(pad: Instance, attachment: string): BillboardGui?
	local a = pad:FindFirstChild(attachment)
	for _, child in if a then a:GetChildren() else {} do
		if child:IsA("BillboardGui") and child.Name ~= HeroConfig.SizeBadgeName then
			return child
		end
	end
	return nil
end

local function drawGui(padModel: Model, kind: Kind, hero: string?)
	padModel:SetAttribute("HeroId", hero or "")
	local pad = padModel:FindFirstChild("Pad")
	if not pad then
		return
	end
	local def = if hero then HeroConfig.Get(hero) else nil
	local empty = billboard(pad, "Empty")
	if empty then
		empty.Enabled = def == nil
		local text = empty:FindFirstChild("EmptyText")
		if text and text:IsA("TextLabel") then
			text.RichText = false
			text.Text = "Empty Slot"
		end
	end
	local info = billboard(pad, "HeroInfo")
	if info then
		info.Enabled = def ~= nil
		local nameLabel = info:FindFirstChild("HeroName")
		HeroConfig.PaintSizeBadge(
			info,
			info.Size.Y.Scale / 2,
			if def then def.Size else nil,
			if nameLabel and nameLabel:IsA("TextLabel") then nameLabel.FontFace else nil
		)
		if def then
			if nameLabel and nameLabel:IsA("TextLabel") then
				nameLabel.Text = HeroConfig.DisplayName(def)
				HeroConfig.PaintRarityGradient(nameLabel, def.Rarity)
			end
			for _, hidden in { "Level", "Rarity" } do
				local l = info:FindFirstChild(hidden)
				if l and l:IsA("GuiObject") then
					l.Visible = false
				end
			end
			local power = info:FindFirstChild("Power")
			if power and power:IsA("TextLabel") then
				if kind == "Keeper" and hero then
					power.Text = ("+%s/min  +%s stock"):format(
						tostring(StandStats.KeeperBonus(hero, "CustomersPerMinute")),
						tostring(StandStats.KeeperBonus(hero, "MaxStock"))
					)
				else
					power.Text = kind
				end
			end
		end
	end
end

-- The placed hero, standing idle on the pad and facing the way the pad faces.
-- Keepers wave at the customers now and then (StandConfig.KeeperWave), while the model exists.
local function startWaving(model: Model, humanoid: Humanoid)
	local cfg = StandConfig.KeeperWave
	local track = HeroModels.LoadTrack(humanoid, cfg.AnimationId, Enum.AnimationPriority.Action, false)
	if not track then
		return
	end
	task.spawn(function()
		local rng = Random.new()
		while model.Parent do
			task.wait(rng:NextNumber(cfg.Min, cfg.Max))
			if model.Parent then
				track:Play(0.2)
			end
		end
	end)
end

local function drawPadHero(padModel: Model, hero: string?, owner: Player?, kind: Kind?)
	local current = padModel:FindFirstChild(PAD_HERO_NAME)
	if current and hero and current:GetAttribute("Hero") == hero then
		return
	end
	if current then
		current:Destroy()
	end
	local pad = padModel:FindFirstChild("Pad")
	if not hero or not pad or not pad:IsA("BasePart") then
		return
	end
	local model, humanoid, root = HeroModels.Clone(hero)
	if not model or not humanoid or not root then
		return
	end
	model.Name = PAD_HERO_NAME
	model:SetAttribute("Hero", hero)
	HeroModels.HideBar(model)
	humanoid.EvaluateStateMachine = false
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	local def = HeroConfig.Get(hero)
	local padScale = if def and def.PadScale then def.PadScale else 1
	HeroModels.ScaleToHeight(model, HeroModels.PlayerBodyHeight(owner) * padScale)
	local look = Vector3.new(pad.CFrame.LookVector.X, 0, pad.CFrame.LookVector.Z)
	look = if look.Magnitude > 0.01 then look.Unit else Vector3.new(0, 0, -1)
	local top = pad.Position + Vector3.new(0, pad.Size.Y / 2, 0)
	model:PivotTo(CFrame.lookAt(top, top + look))
	local box, size = model:GetBoundingBox()
	model:PivotTo(model:GetPivot() + Vector3.new(0, top.Y - (box.Position.Y - size.Y / 2), 0))
	root.Anchored = true
	model.Parent = padModel
	local idle = HeroModels.LoadTrack(humanoid, HeroModels.Anims(humanoid).Idle, Enum.AnimationPriority.Core, true)
	if idle then
		idle:Play()
	end
	if kind == "Keeper" then
		startWaving(model, humanoid)
	end
end

local function clearPad(padModel: Model, kind: Kind)
	drawGui(padModel, kind, nil)
	drawPadHero(padModel, nil)
	local pad = padModel:FindFirstChild("Pad")
	local prompt = pad and pad:FindFirstChild(PROMPT_NAME)
	if prompt then
		prompt:Destroy()
	end
end

-- Prompts --------------------------------------------------------------------------------------------

local publish: (Instance, string, StandPads?, Player?) -> () -- defined with the stock code below
local applyCarryBonus: (PlotState) -> () -- defined with the upgrade pads below

local onPrompt: (PlotState, string, Kind, number, Player) -> ()

local function getPrompt(state: PlotState, standId: string, kind: Kind, index: number, padModel: Model): ProximityPrompt
	local pad = padModel:FindFirstChild("Pad") :: BasePart
	local prompt = pad:FindFirstChild(PROMPT_NAME) :: ProximityPrompt?
	if not prompt or prompt:GetAttribute("Owner") ~= state.owner.UserId then
		if prompt then
			prompt:Destroy()
		end
		local p = Instance.new("ProximityPrompt")
		p.Name = PROMPT_NAME
		p.KeyboardKeyCode = Enum.KeyCode.E
		p.Style = Enum.ProximityPromptStyle.Custom
		p.HoldDuration = HeroConfig.Slots.HoldDuration
		p.MaxActivationDistance = PROMPT_DISTANCE
		p.RequiresLineOfSight = false
		p:SetAttribute("Owner", state.owner.UserId)
		p.Parent = pad
		table.insert(state.connections, p.Triggered:Connect(function(player)
			onPrompt(state, standId, kind, index, player)
		end))
		prompt = p
	end
	return prompt :: ProximityPrompt
end

local function refresh(state: PlotState)
	if states[state.plot] ~= state then
		return
	end
	local owner = state.owner
	local choice = HeroSlotService.GetSelected(owner)
	for standId in StandLayoutConfig.Stands do
		local stand = state.stands[standId]
		for _, kind in KINDS do
			for i, padModel in padsOf(state.plot, standId, kind) do
				local hero = stand[kind][i]
				drawGui(padModel, kind, hero)
				drawPadHero(padModel, hero, owner, kind)
				local prompt = getPrompt(state, standId, kind, i, padModel)
				prompt.Enabled = true
				if hero then
					prompt.ObjectText = LABEL[kind]
					prompt.ActionText = "Take Back " .. hero
				elseif choice and HeroConfig.Get(choice) and HeroPlacement.Free(owner, choice) > 0 then
					prompt.ObjectText = LABEL[kind]
					prompt.ActionText = "Place " .. choice
				elseif choice and HeroConfig.Get(choice) then
					prompt.ObjectText = LABEL[kind]
					prompt.ActionText = "No " .. choice .. " left to place"
				else
					prompt.ObjectText = LABEL[kind]
					prompt.ActionText = "Pick a hero (1-0)"
				end
			end
		end
	end
end

onPrompt = function(state: PlotState, standId: string, kind: Kind, index: number, player: Player)
	if player ~= state.owner or states[state.plot] ~= state then
		return
	end
	local list = state.stands[standId][kind]
	if list[index] then
		list[index] = nil
	else
		local hero = HeroSlotService.GetSelected(player)
		if not hero or not HeroConfig.Get(hero) or HeroPlacement.Free(player, hero) <= 0 then
			return
		end
		if not padsOf(state.plot, standId, kind)[index] then
			return
		end
		list[index] = hero
		if HeroPlacement.Free(player, hero) <= 0 then
			HeroSlotService.Deselect(player, hero) -- the last free copy left the player's hands
		end
	end
	if kind == "Keeper" then
		publish(state.plot, standId, state.stands[standId], state.owner) -- keeper bonus changed the stats
	end
	refresh(state)
	HeroSlotService.RefreshFor(player) -- worker pads: one copy more / less is free
end

local function stateOf(player: Player): PlotState?
	for _, state in states do
		if state.owner == player then
			return state
		end
	end
	return nil
end

-- Stock, stats, selling ----------------------------------------------------------------------------------

local rng = Random.new()

local function stockCount(stand: StandPads): number
	local n = 0
	for _, v in stand.Stock do
		n += v
	end
	return n
end

local function statsOf(standId: string, stand: StandPads): { [string]: number }
	return StandStats.Compute({ StandId = standId, Level = stand.Level, Keepers = table.clone(stand.Keeper), Upgrades = stand.Upgrades })
end

-- Writes what clients show (billboard, goods on the shelf) as attributes on the site.
publish = function(plot: Instance, standId: string, stand: StandPads?, owner: Player?)
	local site = StandLayout.Site(plot, standId)
	if not site then
		return
	end
	local level = if stand then stand.Level else 1
	local stats = if stand then statsOf(standId, stand) else StandStats.Compute({ StandId = standId, Level = 1 })
	local def = StandConfig.Level(standId, level)
	local low, high = math.huge, 0
	if stand then
		for id, n in stand.Stock do
			if n > 0 then
				local price = StandStats.PriceOf(id, stats.PriceMultiplier)
				low = math.min(low, price)
				high = math.max(high, price)
			end
		end
	end
	site:SetAttribute("OwnerUserId", if owner then owner.UserId else 0)
	site:SetAttribute("StandName", if def then def.Name else standId)
	site:SetAttribute("Level", level)
	site:SetAttribute("MaxLevel", StandConfig.MaxLevel(standId))
	site:SetAttribute("Stock", if stand then stockCount(stand) else 0)
	site:SetAttribute("MaxStock", stats.MaxStock)
	site:SetAttribute("CustomersPerMinute", stats.CustomersPerMinute)
	site:SetAttribute("MaxItemsPerCustomer", stats.MaxItemsPerCustomer)
	site:SetAttribute("PriceMultiplier", stats.PriceMultiplier)
	site:SetAttribute("PriceMin", if high > 0 then low else 0)
	site:SetAttribute("PriceMax", high)
	for id in StandUpgradeConfig.Upgrades do
		site:SetAttribute("Upgrade_" .. id, if stand then stand.Upgrades[id] or 0 else 0)
	end
end

local standEvent: RemoteEvent

-- One customer walks up: buys 1..MaxItemsPerCustomer random items from the stock (or leaves when
-- there is none) and the owner gets the money.
local customerId = 0

-- A VIP shows up now and then at levels with a VIP lane (StandLayoutConfig VipQueuePoints): buys more
-- and pays more (StandConfig.Vip). Fame tiers will raise the chance later.
local function rollVip(standId: string, stand: StandPads): boolean
	local layout = StandLayoutConfig.Stands[standId]
	local level = layout and layout.Levels[stand.Level]
	return level ~= nil and level.VipQueuePoints ~= nil and rng:NextNumber() < StandConfig.Vip.Chance
end

-- Tells every client a customer came: they walk an NPC in, it pays at the counter (or leaves empty
-- handed) and walks off carrying what it bought (CustomerClient). The sale itself is done already.
local function announceCustomer(site: Instance?, owner: Player, vip: boolean, items: number, money: number)
	if not site then
		return
	end
	customerId += 1
	standEvent:FireAllClients("Customer", site, {
		id = customerId,
		vip = vip,
		items = items,
		money = money,
		ownerId = owner.UserId,
		look = rng:NextInteger(1, 1000), -- which customer model / colours
	})
end

local function serveCustomer(state: PlotState, standId: string, stand: StandPads)
	local stats = statsOf(standId, stand)
	local site = StandLayout.Site(state.plot, standId)
	local total = stockCount(stand)
	local vip = rollVip(standId, stand)
	if total <= 0 then
		announceCustomer(site, state.owner, vip, 0, 0)
		ToastService.SendThrottled(state.owner, "OutOfStock_" .. standId, "Your Farm Stand is out of stock! Restock it", "Bad", StandConfig.OutOfStockToastCooldown)
		return
	end
	local maxItems = math.max(1, stats.MaxItemsPerCustomer)
	if vip then
		maxItems = math.max(1, math.floor(maxItems * StandConfig.Vip.ItemsMultiplier))
	end
	local want = math.min(rng:NextInteger(if vip then math.ceil(maxItems / 2) else 1, maxItems), total)
	local bought: { [string]: number } = {}
	local money = 0
	for _ = 1, want do
		-- pick an item, each in proportion to how many are in stock
		local roll = rng:NextInteger(1, total)
		for id, n in stand.Stock do
			roll -= n
			if roll <= 0 then
				stand.Stock[id] = n - 1
				if stand.Stock[id] <= 0 then
					stand.Stock[id] = nil
				end
				bought[id] = (bought[id] or 0) + 1
				money += StandStats.PriceOf(id, stats.PriceMultiplier)
				break
			end
		end
		total -= 1
	end
	if vip then
		money = math.floor(money * StandConfig.Vip.PriceMultiplier)
	end
	ChestService.AddMoney(state.owner, money)
	publish(state.plot, standId, stand, state.owner)
	announceCustomer(site, state.owner, vip, want, money)
end

local function scheduleNext(standId: string, stand: StandPads, now: number)
	local cpm = statsOf(standId, stand).CustomersPerMinute
	local j = StandConfig.CustomerJitter
	local wait = if cpm > 0 then 60 / cpm * rng:NextNumber(1 - j, 1 + j) else math.huge
	stand.NextCustomer = now + wait
end

-- Puts materials into a stand's stock, up to its MaxStock. Returns what went in. (Restock mat, helpers.)
function StandService.AddStock(player: Player, standId: string, stacks: { [string]: number }): { [string]: number }
	local state = stateOf(player)
	local stand = state and state.stands[standId]
	local added = {}
	if not state or not stand then
		return added
	end
	local room = statsOf(standId, stand).MaxStock - stockCount(stand)
	for id, n in stacks do
		local amount = math.min(math.floor(n), room)
		if amount > 0 and MaterialConfig.IsMaterial(id) then
			stand.Stock[id] = (stand.Stock[id] or 0) + amount
			room -= amount
			added[id] = amount
		end
	end
	publish(state.plot, standId, stand, state.owner)
	return added
end

-- Restock mat ----------------------------------------------------------------------------------------

local RESTOCK = StandConfig.Restock

-- The mat the player stands on: the visual "RestockMat" part in the placed stand (its size is the
-- area), else the marker with a 4 stud square.
local function restockArea(plot: Instance, standId: string): (CFrame?, Vector3?)
	local placed = StandLayout.Placed(plot, standId)
	local pads = placed and placed:FindFirstChild(PADS_FOLDER)
	local mat = pads and pads:FindFirstChild("RestockMat")
	if mat and mat:IsA("BasePart") then
		return mat.CFrame, mat.Size
	end
	local cf = StandLayout.Get(plot, standId, "RestockMat")
	return cf, if cf then Vector3.new(4, 0.2, 4) else nil
end

local function onRestockMat(player: Player, cf: CFrame, size: Vector3): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return false
	end
	local rel = cf:PointToObjectSpace(root.Position)
	return math.abs(rel.X) <= size.X / 2 + RESTOCK.Reach and math.abs(rel.Z) <= size.Z / 2 + RESTOCK.Reach and rel.Y >= -1 and rel.Y <= RESTOCK.Height
end

-- One tick on the mat: carried materials -> stock (dearest first), up to MaxStock. What does not fit
-- stays on the player.
local function restockTick(state: PlotState, standId: string, stand: StandPads)
	local owner = state.owner
	local cf, size = restockArea(state.plot, standId)
	if not cf or not size or not onRestockMat(owner, cf, size) then
		stand.Restocking = nil
		return
	end
	local carried = CarryService.Count(owner)
	if carried <= 0 then
		if stand.Restocking then
			stand.Restocking = nil
			ToastService.Send(owner, "Stand restocked!", "Good")
		end
		return
	end
	local maxStock = statsOf(standId, stand).MaxStock
	local room = maxStock - stockCount(stand)
	if room <= 0 then
		ToastService.SendThrottled(owner, "StandFull_" .. standId, ("Stand is full! (%d/%d) Upgrade it to hold more"):format(stockCount(stand), maxStock), "Bad", RESTOCK.FullToastCooldown)
		return
	end
	local taken = CarryService.Take(owner, math.min(RESTOCK.PerTick, room))
	local added = StandService.AddStock(owner, standId, taken)
	-- Anything AddStock refused goes back on the player (never lost).
	local back = {}
	local n = 0
	for id, amount in taken do
		local extra = amount - (added[id] or 0)
		if extra > 0 then
			back[id] = extra
		end
		n += added[id] or 0
	end
	if next(back) then
		CarryService.Add(owner, back)
	end
	if n > 0 then
		stand.Restocking = true
		local site = StandLayout.Site(state.plot, standId)
		if site then
			standEvent:FireClient(owner, "Restock", site, n)
		end
		if stockCount(stand) >= maxStock and CarryService.Count(owner) > 0 then
			ToastService.SendThrottled(owner, "StandFull_" .. standId, ("Stand is full! (%d/%d) The rest stays with you"):format(stockCount(stand), maxStock), "Bad", RESTOCK.FullToastCooldown)
		end
	end
end

-- Room left in a stand's stock.
function StandService.StockRoom(player: Player, standId: string): number
	local state = stateOf(player)
	local stand = state and state.stands[standId]
	if not stand then
		return 0
	end
	return math.max(0, statsOf(standId, stand).MaxStock - stockCount(stand))
end

-- Puts the stand's level model on the site (keeper pads come with it); keepers on pads the new level
-- doesn't have go back to the inventory.
local function setLevel(state: PlotState, standId: string, level: number)
	local stand = state.stands[standId]
	level = math.clamp(math.floor(level), 1, math.max(1, StandConfig.MaxLevel(standId)))
	stand.Level = level
	if StandLayout.Site(state.plot, standId) then
		local placed = StandLayout.Placed(state.plot, standId)
		if not placed or placed:GetAttribute("Level") ~= level then
			StandLayout.Place(state.plot, standId, level)
		end
	end
	local pads = padsOf(state.plot, standId, "Keeper")
	for index in stand.Keeper do
		if not pads[index] then
			stand.Keeper[index] = nil
		end
	end
	-- "Manage Stand" prompt at the counter (StandUI opens on the client).
	local placed = StandLayout.Placed(state.plot, standId)
	local markers = placed and placed:FindFirstChild(StandLayoutConfig.MarkersFolder)
	local at = markers and markers:FindFirstChild("CoinFxPoint")
	if at and at:IsA("BasePart") and not at:FindFirstChild(MANAGE_PROMPT) then
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = MANAGE_PROMPT
		prompt.ObjectText = StandConfig.Stands[standId].Name
		prompt.ActionText = "Manage Stand"
		prompt.KeyboardKeyCode = Enum.KeyCode.F
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 16
		prompt.RequiresLineOfSight = false
		prompt:SetAttribute("StandId", standId)
		prompt.Parent = at
	end
	publish(state.plot, standId, stand, state.owner)
end

-- Upgrading the stand ----------------------------------------------------------------------------------

local UPGRADE_REACH = 80 -- studs from the stand the upgrade can be bought (billboard button / window)
local MIN_ACTION_INTERVAL = 0.3
local lastAction: { [Player]: number } = {}

-- The helper pads for the window: one entry per pad (hero or nil, carry per trip, speed, what it does).
local function helpersInfo(stand: StandPads): { any }
	local out = {}
	for i = 1, StandLayoutConfig.HelperSlots do
		local hero = stand.Helper[i]
		local entry: { [string]: any } = { index = i }
		if hero then
			local st = StandStats.HelperStats(hero, stand.Upgrades)
			local def = HeroConfig.Get(hero)
			entry.hero = hero
			entry.rarity = if def then def.Rarity else nil
			entry.carry = st.Carry
			entry.speed = math.floor(st.Speed * 10 + 0.5) / 10
			entry.phase = if stand.Trips[i] then stand.Trips[i].phase else "Idle"
		end
		table.insert(out, entry)
	end
	return out
end

local function previewOf(standId: string, stand: StandPads)
	local nextLevel = stand.Level + 1
	local nextDef = StandConfig.Level(standId, nextLevel)
	local keepers = table.clone(stand.Keeper)
	local layout = StandLayoutConfig.Stands[standId]
	local function keeperSlots(level: number): number
		local l = layout and layout.Levels[level]
		return if l then l.KeeperSlots else 0
	end
	return {
		standId = standId,
		level = stand.Level,
		maxLevel = StandConfig.MaxLevel(standId),
		current = StandStats.Breakdown({ StandId = standId, Level = stand.Level, Keepers = keepers, Upgrades = stand.Upgrades }),
		next = if nextDef then StandStats.Breakdown({ StandId = standId, Level = nextLevel, Keepers = keepers, Upgrades = stand.Upgrades }) else nil,
		keeperSlots = keeperSlots(stand.Level),
		nextKeeperSlots = if nextDef then keeperSlots(nextLevel) else nil,
		cost = if nextDef then nextDef.UpgradeCost else nil,
		stock = stockCount(stand),
		helpers = helpersInfo(stand),
	}
end

local function near(player: Player, plot: Instance, standId: string): boolean
	local site = StandLayout.Site(plot, standId)
	local anchor = site and site:FindFirstChild(StandLayoutConfig.AnchorName)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return anchor ~= nil and root ~= nil and (root.Position - (anchor :: BasePart).Position).Magnitude <= UPGRADE_REACH
end

local function upgradeStand(player: Player, standId: string)
	local state = stateOf(player)
	local stand = state and state.stands[standId]
	if not state or not stand then
		return { ok = false, message = "No stand" }
	end
	if not near(player, state.plot, standId) then
		return { ok = false, message = "Go to your Farm Stand" }
	end
	local nextDef = StandConfig.Level(standId, stand.Level + 1)
	if not nextDef then
		return { ok = false, message = "Max level!" }
	end
	local cost = nextDef.UpgradeCost or 0
	if not ChestService.SpendMoney(player, cost) then
		local short = math.ceil(cost - ChestService.GetMoney(player))
		ToastService.Send(player, ("Not enough money! Need $%s more"):format(HeroConfig.Abbreviate(short)), "Bad")
		return { ok = false, message = ("Need $%s more"):format(HeroConfig.Abbreviate(short)) }
	end
	local old = stand.Level
	setLevel(state, standId, old + 1)
	refresh(state) -- keeper pads of the new level (kept heroes stand on the same slot number)
	local site = StandLayout.Site(state.plot, standId)
	if site then
		standEvent:FireAllClients("LevelUp", site, stand.Level, old)
	end
	ToastService.Send(player, ("%s upgraded to Level %d!"):format(StandConfig.Stands[standId].Name, stand.Level), "Good")
	return { ok = true, preview = previewOf(standId, stand) }
end

-- Upgrade pads -------------------------------------------------------------------------------------------

-- The owner's CarryCapacity bonus from the Carry Capacity upgrade(s) of all their stands.
applyCarryBonus = function(state: PlotState)
	local bonus = 0
	for _, stand in state.stands do
		for id, level in stand.Upgrades do
			local def = StandUpgradeConfig.Get(id)
			if def and def.Effect.Kind == "Carry" then
				bonus += (def.Effect.PerLevel or 0) * level
			end
		end
	end
	state.owner:SetAttribute("CarryBonus", bonus)
end

-- Before / after of one upgrade for its window: the stat it changes (or carry / helper numbers).
local function upgradeInfo(player: Player, standId: string, id: string)
	local state = stateOf(player)
	local stand = state and state.stands[standId]
	local def = StandUpgradeConfig.Get(id)
	if not stand or not def then
		return { ok = false, message = "No such upgrade" }
	end
	local level = stand.Upgrades[id] or 0
	local maxLevel = StandUpgradeConfig.MaxLevel(id)
	local nextUps = table.clone(stand.Upgrades)
	nextUps[id] = math.min(level + 1, maxLevel)
	local kind = def.Effect.Kind
	local before, after
	if kind == "Flat" or kind == "Percent" then
		local stat = def.Effect.Stat :: string
		local keepers = table.clone(stand.Keeper)
		before = StandStats.Compute({ StandId = standId, Level = stand.Level, Keepers = keepers, Upgrades = stand.Upgrades })[stat]
		after = StandStats.Compute({ StandId = standId, Level = stand.Level, Keepers = keepers, Upgrades = nextUps })[stat]
	elseif kind == "Carry" then
		before = CarryService.Capacity(player)
		after = before + (def.Effect.PerLevel or 0)
	elseif kind == "Helper" then
		local probe = "" -- base helper (no rarity bonus) to show the training alone
		local a = StandStats.HelperStats(probe, stand.Upgrades)
		local b = StandStats.HelperStats(probe, nextUps)
		before = ("%d / trip, speed %.1f"):format(a.Carry, a.Speed)
		after = ("%d / trip, speed %.1f"):format(b.Carry, b.Speed)
	end
	return {
		ok = true,
		id = id,
		name = def.Name,
		desc = def.Desc,
		level = level,
		maxLevel = maxLevel,
		cost = StandUpgradeConfig.NextCost(id, level),
		stat = def.Effect.Stat or kind,
		before = before,
		after = if level < maxLevel then after else nil,
	}
end

local function nearPad(player: Player, plot: Instance, standId: string, id: string): boolean
	local cf = StandLayout.Get(plot, standId, "UpgradePad_" .. id)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not cf or not root then
		return false
	end
	local d = root.Position - cf.Position
	return Vector3.new(d.X, 0, d.Z).Magnitude <= StandUpgradeConfig.PadReach + 2 and math.abs(d.Y) < 10
end

local function buyUpgrade(player: Player, standId: string, id: string)
	local state = stateOf(player)
	local stand = state and state.stands[standId]
	local def = StandUpgradeConfig.Get(id)
	if not state or not stand or not def then
		return { ok = false, message = "No such upgrade" }
	end
	-- the pad must exist at this stand level, and the player must stand at it
	local layout = StandLayoutConfig.Stands[standId]
	local levelLayout = layout and layout.Levels[stand.Level]
	if not levelLayout or not table.find(levelLayout.UpgradePads, id) then
		return { ok = false, message = "Upgrade your stand to unlock this" }
	end
	if not nearPad(player, state.plot, standId, id) then
		return { ok = false, message = "Stand on the upgrade pad" }
	end
	local level = stand.Upgrades[id] or 0
	local cost = StandUpgradeConfig.NextCost(id, level)
	if not cost then
		return { ok = false, message = "MAX level" }
	end
	if not ChestService.SpendMoney(player, cost) then
		local short = math.ceil(cost - ChestService.GetMoney(player))
		ToastService.Send(player, ("Not enough money! Need $%s more"):format(HeroConfig.Abbreviate(short)), "Bad")
		return { ok = false, message = ("Need $%s more"):format(HeroConfig.Abbreviate(short)) }
	end
	stand.Upgrades[id] = level + 1
	if def.Effect.Kind == "Carry" then
		applyCarryBonus(state)
	end
	publish(state.plot, standId, stand, state.owner)
	local site = StandLayout.Site(state.plot, standId)
	if site then
		standEvent:FireAllClients("UpgradeBought", site, id, level + 1)
	end
	ToastService.Send(player, ("%s upgraded to Lv %d!"):format(def.Name, level + 1), "Good")
	return upgradeInfo(player, standId, id)
end

local function onAction(player: Player, action: any, standId: any, arg: any): any
	local now = os.clock()
	if now - (lastAction[player] or 0) < MIN_ACTION_INTERVAL then
		return { ok = false, message = "Slow down" }
	end
	lastAction[player] = now
	if typeof(standId) ~= "string" or not StandConfig.Stands[standId] then
		return { ok = false, message = "Bad request" }
	end
	if action == "Preview" then
		local state = stateOf(player)
		local stand = state and state.stands[standId]
		return if stand then { ok = true, preview = previewOf(standId, stand) } else { ok = false, message = "No stand" }
	elseif action == "Upgrade" then
		return upgradeStand(player, standId)
	elseif action == "UpgradeInfo" and typeof(arg) == "string" then
		return upgradeInfo(player, standId, arg)
	elseif action == "BuyUpgrade" and typeof(arg) == "string" then
		return buyUpgrade(player, standId, arg)
	end
	return { ok = false, message = "Bad request" }
end

-- Helpers ---------------------------------------------------------------------------------------------------
-- Each helper pad with a hero runs its own trip on a timer (the server never moves a model; clients
-- animate each leg from Remotes.StandEvent "HelperLeg"):
--   Idle      resting on its pad. Starts when the chest has materials and stock < ResumeBelow x MaxStock
--             (helper N waits (N - 1) x Stagger first, so they don't leave together).
--   ToPickup  walking to the chest (HelperPickupPoint).
--   Carrying  materials taken from the chest (only what the stand still has room for, minus what the
--             other helpers already carry), walking HelperPath_1..N to the stand's HelperDropPoint.
--   Dropping  DropTime at the stand, then the materials go into the stock (what no longer fits goes
--             back into the chest, nothing is lost or doubled). Then back to the chest for more, or:
--   Returning walking back to its pad, then Idle.

local HELPER = StandConfig.Helper

local function pointOf(plot: Instance, standId: string, name: string): Vector3?
	local cf = StandLayout.Get(plot, standId, name)
	return if cf then cf.Position else nil
end

local function helperRoute(plot: Instance, standId: string): ({ Vector3 }?, Vector3?, Vector3?)
	local pickup = pointOf(plot, standId, "HelperPickupPoint")
	local drop = pointOf(plot, standId, "HelperDropPoint")
	if not pickup or not drop then
		return nil, nil, nil
	end
	local path = {}
	for _, cf in StandLayout.List(plot, standId, "HelperPath") do
		table.insert(path, cf.Position)
	end
	return path, pickup, drop
end

local function reversed(list: { Vector3 }): { Vector3 }
	local out = {}
	for i = #list, 1, -1 do
		table.insert(out, list[i])
	end
	return out
end

local function concat(...: { Vector3 }): { Vector3 }
	local out = {}
	for _, list in { ... } do
		for _, p in list do
			table.insert(out, p)
		end
	end
	return out
end

local function pathLength(points: { Vector3 }): number
	local d = 0
	for i = 2, #points do
		d += (points[i] - points[i - 1]).Magnitude
	end
	return d
end

local function helperPad(plot: Instance, standId: string, index: number): Model?
	return padsOf(plot, standId, "Helper")[index]
end

local function startLeg(state: PlotState, standId: string, index: number, trip: Trip, phase: string, points: { Vector3 }, speed: number, now: number)
	trip.phase = phase
	local duration = pathLength(points) / math.max(speed, 0.1)
	trip.phaseEnd = now + duration
	local site = StandLayout.Site(state.plot, standId)
	if site then
		local carried = 0
		for _, n in trip.carrying or {} do
			carried += n
		end
		standEvent:FireAllClients("HelperLeg", site, index, points, duration, carried)
	end
end

local function chestOf(plot: Instance): Model?
	local chest = plot:FindFirstChild("TreasureChest", true)
	return if chest and chest:IsA("Model") then chest else nil
end

-- Materials the other helpers of this stand are bringing right now (so nobody overfills the stand).
local function inTransit(stand: StandPads, except: number): number
	local n = 0
	for i, trip in stand.Trips do
		if i ~= except then
			for _, amount in trip.carrying or {} do
				n += amount
			end
		end
	end
	return n
end

local function setAway(state: PlotState, standId: string, index: number, away: boolean)
	local pad = helperPad(state.plot, standId, index)
	if pad then
		pad:SetAttribute("Away", away)
	end
end

-- Back on the pad (or the hero was taken off it): materials still carried go back into the chest.
local function endTrip(state: PlotState, standId: string, index: number, trip: Trip)
	local chest = chestOf(state.plot)
	if trip.carrying and chest then
		ChestService.PutMaterials(chest, trip.carrying)
	end
	trip.carrying = nil
	trip.phase = "Idle"
	trip.phaseEnd = 0
	setAway(state, standId, index, false)
	local site = StandLayout.Site(state.plot, standId)
	if site then
		standEvent:FireAllClients("HelperIdle", site, index)
	end
end

local function helperTick(state: PlotState, standId: string, stand: StandPads, index: number, now: number)
	local hero = stand.Helper[index]
	local trip = stand.Trips[index]
	if not hero then
		if trip then
			if trip.phase ~= "Idle" then
				endTrip(state, standId, index, trip)
			end
			stand.Trips[index] = nil
		end
		return
	end
	if not trip or trip.hero ~= hero then
		if trip and trip.phase ~= "Idle" then
			endTrip(state, standId, index, trip)
		end
		trip = { hero = hero, phase = "Idle", phaseEnd = 0, nextCheck = now + (index - 1) * HELPER.Stagger }
		stand.Trips[index] = trip
	end
	local t = trip :: Trip
	local stats = StandStats.HelperStats(hero, stand.Upgrades)
	local maxStock = statsOf(standId, stand).MaxStock
	local chest = chestOf(state.plot)
	local chestHas = chest ~= nil and (chest:GetAttribute("Stored") or 0) > 0
	local path, pickup, drop = helperRoute(state.plot, standId)
	local home = pointOf(state.plot, standId, "HelperSlot_" .. index)
	if not path or not pickup or not drop or not home then
		return
	end

	if t.phase == "Idle" then
		if now < t.nextCheck then
			return
		end
		t.nextCheck = now + 0.5
		local stock = stockCount(stand) + inTransit(stand, index)
		if chestHas and stock < HELPER.ResumeBelow * maxStock then
			setAway(state, standId, index, true)
			startLeg(state, standId, index, t, "ToPickup", { home, pickup }, stats.Speed, now)
		end
	elseif now < t.phaseEnd then
		return
	elseif t.phase == "ToPickup" then
		local room = maxStock - stockCount(stand) - inTransit(stand, index)
		local taken = if chest and room > 0 then ChestService.TakeMaterials(chest, math.min(stats.Carry, room)) else {}
		if next(taken) == nil then
			startLeg(state, standId, index, t, "Returning", { pickup, home }, stats.Speed, now)
		else
			t.carrying = taken
			-- a short stop at the chest, then the walk to the stand
			local points = concat({ pickup, pickup }, path, { drop })
			startLeg(state, standId, index, t, "Carrying", points, stats.Speed, now)
			t.phaseEnd += HELPER.PickupTime
		end
	elseif t.phase == "Carrying" then
		t.phase = "Dropping"
		t.phaseEnd = now + HELPER.DropTime
	elseif t.phase == "Dropping" then
		local carried = t.carrying or {}
		local added = StandService.AddStock(state.owner, standId, carried)
		local back, n = {}, 0
		for id, amount in carried do
			local extra = amount - (added[id] or 0)
			if extra > 0 then
				back[id] = extra
			end
			n += added[id] or 0
		end
		if chest and next(back) then
			ChestService.PutMaterials(chest, back)
		end
		t.carrying = nil
		local site = StandLayout.Site(state.plot, standId)
		if site and n > 0 then
			standEvent:FireAllClients("HelperDrop", site, index, n)
		end
		local backPath = concat({ drop }, reversed(path), { pickup })
		local stillRoom = stockCount(stand) + inTransit(stand, index) < maxStock
		if chestHas and stillRoom then
			startLeg(state, standId, index, t, "ToPickup", backPath, stats.Speed, now)
		else
			startLeg(state, standId, index, t, "Returning", concat(backPath, { home }), stats.Speed, now)
		end
	elseif t.phase == "Returning" then
		endTrip(state, standId, index, t)
		t.nextCheck = now + 1
	end
end

-- Plots ------------------------------------------------------------------------------------------------

local function emptyStands(): { [string]: StandPads }
	local out = {}
	for standId in StandLayoutConfig.Stands do
		out[standId] = { Keeper = {}, Helper = {}, Level = 1, Stock = {}, NextCustomer = 0, Trips = {}, Upgrades = {} }
	end
	return out
end

-- Puts saved data back: level, stock, and heroes on the pads (only copies still free, only pads
-- that exist at that level).
local function applySaved(state: PlotState, saved: { [string]: StandPads })
	for standId, data in saved do
		local stand = state.stands[standId]
		if not stand then
			continue
		end
		for id, lv in data.Upgrades do
			stand.Upgrades[id] = math.max(stand.Upgrades[id] or 0, lv)
		end
		applyCarryBonus(state)
		setLevel(state, standId, data.Level)
		for id, n in data.Stock do
			stand.Stock[id] = (stand.Stock[id] or 0) + n
		end
		for _, kind in KINDS do
			local existing = padsOf(state.plot, standId, kind)
			for index, hero in data[kind] do
				if existing[index] and not stand[kind][index] and HeroConfig.Get(hero) and HeroPlacement.Free(state.owner, hero) > 0 then
					stand[kind][index] = hero
				end
			end
		end
		publish(state.plot, standId, stand, state.owner)
	end
end

function StandService.ResetPlot(plot: Model)
	local state = states[plot]
	if state then
		-- helpers on the way: their materials go back into the chest
		for standId, stand in state.stands do
			for index, trip in stand.Trips do
				if trip.phase ~= "Idle" then
					endTrip(state, standId, index, trip)
				end
			end
		end
	end
	states[plot] = nil
	if state then
		for _, c in state.connections do
			c:Disconnect()
		end
	end
	for standId in StandLayoutConfig.Stands do
		for _, kind in KINDS do
			for _, padModel in padsOf(plot, standId, kind) do
				clearPad(padModel, kind)
			end
		end
		publish(plot, standId, nil, nil)
	end
end

function StandService.SetupPlot(plot: Model, owner: Player)
	StandService.ResetPlot(plot)
	local state: PlotState = { plot = plot, owner = owner, stands = emptyStands(), connections = {} }
	states[plot] = state
	for standId in StandLayoutConfig.Stands do
		setLevel(state, standId, 1)
	end
	applyCarryBonus(state)
	table.insert(state.connections, HeroSlotService.SelectionChanged:Connect(function(player)
		if player == owner then
			refresh(state)
		end
	end))
	table.insert(state.connections, HeroSlotService.PadsRefreshed:Connect(function(player)
		if player == owner then
			refresh(state)
		end
	end))
	local function watchHeroes(folder: Instance)
		table.insert(state.connections, folder.ChildAdded:Connect(function()
			refresh(state)
		end))
		table.insert(state.connections, folder.ChildRemoved:Connect(function()
			refresh(state)
		end))
	end
	local heroes = owner:FindFirstChild("Heroes")
	if heroes then
		watchHeroes(heroes)
	end
	local saved = pending[owner]
	if saved then
		pending[owner] = nil
		applySaved(state, saved)
	end
	refresh(state)
end

-- Saving -------------------------------------------------------------------------------------------------

export type SaveStand = {
	Level: number?,
	Stock: { [string]: number }?, -- material id -> amount in the stand
	Keepers: { [string]: string }?, -- keeper pad index (as text) -> hero
	Helpers: { [string]: string }?, -- helper pad index (as text) -> hero
	Upgrades: { [string]: number }?, -- upgrade id -> level
}
export type SaveStands = { [string]: SaveStand }

function StandService.GetSaveData(player: Player): SaveStands?
	local state = stateOf(player)
	if not state then
		return nil
	end
	local out: SaveStands = {}
	for standId, stand in state.stands do
		local keepers, helpers, stock = {}, {}, {}
		for i, hero in stand.Keeper do
			keepers[tostring(i)] = hero
		end
		for i, hero in stand.Helper do
			helpers[tostring(i)] = hero
		end
		for id, n in stand.Stock do
			if n > 0 then
				stock[id] = n
			end
		end
		out[standId] = { Level = stand.Level, Stock = stock, Keepers = keepers, Helpers = helpers, Upgrades = table.clone(stand.Upgrades) }
	end
	return out
end

function StandService.ApplySaved(player: Player, data: any)
	if typeof(data) ~= "table" then
		return
	end
	local saved: { [string]: StandPads } = {}
	for standId, entry in data do
		if typeof(standId) ~= "string" or not StandLayoutConfig.Stands[standId] or typeof(entry) ~= "table" then
			continue
		end
		local stand: StandPads = { Keeper = {}, Helper = {}, Level = 1, Stock = {}, NextCustomer = 0, Trips = {}, Upgrades = {} }
		if typeof(entry.Level) == "number" then
			stand.Level = math.max(1, math.floor(entry.Level))
		end
		if typeof(entry.Upgrades) == "table" then
			for id, lv in entry.Upgrades do
				if typeof(id) == "string" and typeof(lv) == "number" and StandUpgradeConfig.Get(id) then
					stand.Upgrades[id] = math.clamp(math.floor(lv), 0, StandUpgradeConfig.MaxLevel(id))
				end
			end
		end
		if typeof(entry.Stock) == "table" then
			for id, n in entry.Stock do
				if typeof(id) == "string" and typeof(n) == "number" and n > 0 and MaterialConfig.IsMaterial(id) then
					stand.Stock[id] = math.floor(n)
				end
			end
		end
		for field, kind in { Keepers = "Keeper", Helpers = "Helper" } do
			local list = entry[field]
			if typeof(list) == "table" then
				for index, hero in list do
					local i = tonumber(index)
					if i and typeof(hero) == "string" then
						stand[kind :: Kind][i] = HeroConfig.CurrentName(hero)
					end
				end
			end
		end
		saved[standId] = stand
	end
	local state = stateOf(player)
	if state then
		applySaved(state, saved)
		refresh(state)
		HeroSlotService.RefreshFor(player)
	else
		pending[player] = saved
	end
end

-- Start ------------------------------------------------------------------------------------------------

function StandService.Start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local existing = remotes:FindFirstChild("StandEvent") :: RemoteEvent?
	if not existing then
		local r = Instance.new("RemoteEvent")
		r.Name = "StandEvent"
		r.Parent = remotes
		existing = r
	end
	standEvent = existing :: RemoteEvent
	local actionRemote = remotes:FindFirstChild("StandAction") :: RemoteFunction?
	if not actionRemote then
		local r = Instance.new("RemoteFunction")
		r.Name = "StandAction"
		r.Parent = remotes
		actionRemote = r
	end
	(actionRemote :: RemoteFunction).OnServerInvoke = onAction

	StandLayout.CheckAll(true)
	for _, kind in KINDS do
		HeroPlacement.Register(kind, function(player: Player)
			local counts: { [string]: number } = {}
			local state = stateOf(player)
			for _, stand in if state then state.stands else {} do
				for _, hero in stand[kind] do
					counts[hero] = (counts[hero] or 0) + 1
				end
			end
			return counts
		end)
	end
	local plots = workspace:FindFirstChild("Plots")
	for _, plot in if plots then plots:GetChildren() else {} do
		for standId in StandLayoutConfig.Stands do
			local site = StandLayout.Site(plot, standId)
			if site then
				site:SetAttribute("DebugMarkers", nil) -- left over from a Studio preview
				StandLayout.SetMarkersVisible(site, false)
				if not states[plot] then
					StandLayout.Place(plot, standId, 1)
					for _, kind in KINDS do
						for _, padModel in padsOf(plot, standId, kind) do
							clearPad(padModel, kind)
						end
					end
					publish(plot, standId, nil, nil)
				end
			end
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		pending[player] = nil
		lastAction[player] = nil
	end)

	-- Helpers: every trip is a timer per helper pad (helperTick).
	task.spawn(function()
		while true do
			task.wait(0.1)
			local now = os.clock()
			for _, state in states do
				for standId, stand in state.stands do
					for index = 1, StandLayoutConfig.HelperSlots do
						local ok, err = pcall(helperTick, state, standId, stand, index, now)
						if not ok then
							warn("[StandService] helper: " .. tostring(err))
						end
					end
				end
			end
		end
	end)

	-- Restock mats: the owner standing on one puts carried materials into that stand.
	task.spawn(function()
		while true do
			task.wait(RESTOCK.Interval)
			for _, state in states do
				for standId, stand in state.stands do
					local ok, err = pcall(restockTick, state, standId, stand)
					if not ok then
						warn("[StandService] restock: " .. tostring(err))
					end
				end
			end
		end
	end)

	-- Customers: each stand gets its next customer after a random wait around 60 / CustomersPerMinute.
	task.spawn(function()
		while true do
			task.wait(0.25)
			local now = os.clock()
			for _, state in states do
				for standId, stand in state.stands do
					if stand.NextCustomer == 0 then
						scheduleNext(standId, stand, now)
					elseif now >= stand.NextCustomer then
						local ok, err = pcall(serveCustomer, state, standId, stand)
						if not ok then
							warn("[StandService] " .. tostring(err))
						end
						scheduleNext(standId, stand, now)
					end
				end
			end
		end
	end)

	if RunService:IsStudio() then
		if workspace:GetAttribute("StandLayoutDebug") == true then
			require(script.Parent:WaitForChild("StandLayoutDebug")).Show(true)
		end
		-- Studio-only test hook (command bar runs in another script context, so it goes through an
		-- instance): ServerStorage.StandDebugAddStock:Invoke(player, "FarmStand", { OakBark = 20 })
		local hook = Instance.new("BindableFunction")
		hook.Name = "StandDebugAddStock"
		hook.OnInvoke = function(player, standId, stacks)
			return StandService.AddStock(player, standId, stacks)
		end
		hook.Parent = ServerStorage
	end
end

return StandService
