-- StandCustomers: the customer NPCs of every Farm Stand, on this client only (started by StandClient).
-- The server already decided the sale (StandService): each Remotes.StandEvent
--   ("Customer", site, { id, vip, items, money, ownerId, look })
-- walks one NPC in: from a CustomerSpawn on the sidewalk to the nearest CustomerPath, into the waiting
-- line (QueuePoint_1 = next in line), to a free ServePoint (VIPs: VipQueuePoint_N -> VipServePoint),
-- waits ServeTime, then "+$money" pops at the counter (coins fly to the owner) and it walks off to a
-- CustomerExit holding a crate. items = 0: it found nothing and leaves empty handed ("Sold out!").
-- Looks: the R15 models in ReplicatedStorage.Customers mixed with guests (real players' avatars in
-- ReplicatedStorage.GuestCustomers, CustomerModels on the server) that have "@username" over the head.
-- Light: NPC models come from a pool (clones of those models, reused per model), at most
-- StandConfig.Customers.MaxVisible per stand; above that, or when the line is full, the sale only pops
-- its "+$". When the stand changes level the line is cleared: everyone walks off.
-- Talk (ChatBubble, lines in ChatConfig): a sold-out customer complains and one of the stand's keeper
-- heroes says sorry with an embarrassed pose; buyers and keepers now and then say something happy.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StandConfig = require(Shared:WaitForChild("StandConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local MaterialConfig = require(Shared:WaitForChild("MaterialConfig"))
local ChatConfig = require(Shared:WaitForChild("ChatConfig"))
local StandLayoutConfig = require(Shared:WaitForChild("StandLayoutConfig"))
local ChatBubble = require(script.Parent:WaitForChild("ChatBubble"))

local CFG = StandConfig.Customers
local LINES = ChatConfig.Customer
local KEEPER = ChatConfig.Keeper
local BUBBLE = ChatConfig.Bubble
local CARRY = MaterialConfig.Carry
local WALK_ANIM = "rbxassetid://913402848"
local IDLE_ANIM = "rbxassetid://507766388"
local CRATE_SIZE = Vector3.new(1.4, 0.9, 1)

local player = Players.LocalPlayer
local abbreviate = HeroConfig.Abbreviate

local StandCustomers = {}

type Deps = {
	popup: (BasePart, string, Color3) -> (),
	flyCoins: (Vector3, number) -> (),
	marker: (Instance, string) -> BasePart?,
	standEvent: RemoteEvent,
}

type Npc = {
	model: Model,
	root: BasePart,
	lift: number,
	humanoid: Humanoid,
	walk: AnimationTrack?,
	idle: AnimationTrack?,
	joints: { [string]: Motor6D }, -- Neck, Waist, shoulders, elbows (posed by hand: carry / upset)
	upsetAt: number, -- os.clock() when it found the stand sold out
	crate: BasePart,
	template: string,
	pos: Vector3, -- ground position
	waypoints: { Vector3 },
	mode: string, -- "ToQueue" | "ToServe" | "Serving" | "Leaving"
	data: any,
	site: Instance,
	lane: string, -- "Normal" | "Vip"
	serveIndex: number?,
	face: Vector3?, -- look direction while standing
	entry: Vector3?, -- the sidewalk point it walks through first (until reached)
	extras: { Instance },
	pace: number, -- its own walking speed, x CFG.WalkSpeed (everyone walks a bit differently)
	speedMul: number, -- 0..1 right now: slows down / stops behind others (smoothed)
	side: Vector3, -- sidestep off its route, to walk around others (smoothed, drawn on top of pos)
	moving: boolean, -- last frame (the others read it)
	heading: Vector3?, -- walking direction last frame
	carrying: boolean, -- holds the crate it bought (shown, arms posed)
	looks: { [Instance]: number }, -- visible parts / decals -> their own Transparency (for fading)
	tag: TextLabel?, -- the guest's "@username"
	fade: number, -- 0 = fully shown, 1 = gone (fades in at the spawn, out near the exit)
	bornAt: number, -- os.clock() when it walked in
}

type SiteState = {
	queue: { Npc },
	vipQueue: { Npc },
	serving: { [number]: Npc },
	vipServing: Npc?,
	npcs: { [Npc]: boolean },
	count: number,
}

local deps: Deps
local folder: Folder
local pool: { [string]: { Npc } } = {}
local sites: { [Instance]: SiteState } = {}
local active: { [Npc]: boolean } = {}

-- Markers -------------------------------------------------------------------------------------------------

local function point(site: Instance, name: string): BasePart?
	local m = deps.marker(site, name)
	if m then
		return m
	end
	local markers = site:FindFirstChild("Markers")
	local s = markers and markers:FindFirstChild(name)
	return if s and s:IsA("BasePart") then s else nil
end

local function list(site: Instance, prefix: string): { BasePart }
	local out = {}
	local i = 1
	while true do
		local m = point(site, prefix .. "_" .. i)
		if not m then
			break
		end
		out[i] = m
		i += 1
	end
	return out
end

local function nearest(parts: { BasePart }, to: Vector3): BasePart?
	local best, bestD = nil, math.huge
	for _, p in parts do
		local d = (p.Position - to).Magnitude
		if d < bestD then
			best, bestD = p, d
		end
	end
	return best
end

local function ground(p: BasePart): Vector3
	return p.Position - Vector3.new(0, p.Size.Y / 2, 0)
end

-- Models ----------------------------------------------------------------------------------------------------

local function loadTrack(humanoid: Humanoid, id: string, priority: Enum.AnimationPriority): AnimationTrack?
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animator.Parent = humanoid
	local anim = Instance.new("Animation")
	anim.AnimationId = id
	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(anim)
	end)
	if ok and track then
		track.Looped = true
		track.Priority = priority
		return track
	end
	return nil
end

local function modelsIn(name: string): { Model }
	local f = ReplicatedStorage:FindFirstChild(name)
	local out = {}
	for _, m in if f then f:GetChildren() else {} do
		if m:IsA("Model") and m:FindFirstChild("HumanoidRootPart") then
			table.insert(out, m)
		end
	end
	table.sort(out, function(a, b)
		return a.Name < b.Name
	end)
	return out
end

-- "@username" over a guest's head (stays on the model while it is pooled).
local function nameTag(model: Model, username: string)
	local head = model:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "GuestTag"
	gui.Adornee = head
	gui.Size = UDim2.fromOffset(160, 26)
	gui.StudsOffset = Vector3.new(0, 2.1, 0)
	gui.MaxDistance = 80
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = "@" .. username
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.35
	label.Parent = gui
	gui.Parent = head
end

-- Avatars with the joint upgrade use AnimationConstraints (physics driven): on an anchored root they
-- never move, so animations and hand-made poses would not show. Turn them into Motor6Ds (same parts,
-- same offsets) and drop the ragdoll ball sockets. On a server model this changes this client only.
local function motorize(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BallSocketConstraint") then
			d:Destroy()
		elseif d:IsA("AnimationConstraint") then
			local a0, a1 = d.Attachment0, d.Attachment1
			if a0 and a1 and a0.Parent and a1.Parent and a0.Parent:IsA("BasePart") and a1.Parent:IsA("BasePart") then
				local m = Instance.new("Motor6D")
				m.Name = d.Name
				m.Part0 = a0.Parent :: BasePart
				m.Part1 = a1.Parent :: BasePart
				m.C0 = a0.CFrame
				m.C1 = a1.CFrame
				m.Parent = d.Parent
			end
			d:Destroy()
		end
	end
end

local function newNpc(template: Model): Npc?
	local model = template:Clone()
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		model:Destroy()
		return nil
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = d == root
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	humanoid.EvaluateStateMachine = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	for _, d in model:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	motorize(model)
	local joints: { [string]: Motor6D } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") then
			joints[d.Name] = d
		end
	end
	model:PivotTo(CFrame.new())
	local box, size = model:GetBoundingBox()
	local lift = model:GetPivot().Position.Y - (box.Position.Y - size.Y / 2)
	-- The crate it buys, held out in front with both arms (same spot as the players' carried stack).
	local crate = Instance.new("Part")
	crate.Name = "Crate"
	crate.Size = CRATE_SIZE
	crate.Material = Enum.Material.WoodPlanks
	crate.Color = Color3.fromRGB(176, 120, 64)
	crate.CanCollide = false
	crate.CanQuery = false
	crate.CanTouch = false
	crate.Massless = true
	crate.Transparency = 1
	local torso = (model:FindFirstChild("UpperTorso") or root) :: BasePart
	crate.CFrame = torso.CFrame
		* CFrame.new(0, -torso.Size.Y / 2 + CRATE_SIZE.Y / 2 + CARRY.HoldUp, -(torso.Size.Z / 2 + CRATE_SIZE.Z / 2 + CARRY.HoldOut))
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = torso
	weld.Part1 = crate
	weld.Parent = crate
	crate.Parent = model
	local username = template:GetAttribute("Username")
	if typeof(username) == "string" and username ~= "" then
		nameTag(model, username)
	end
	local looks: { [Instance]: number } = {}
	for _, d in model:GetDescendants() do
		if (d:IsA("BasePart") and d ~= root and d ~= crate) or d:IsA("Decal") then
			looks[d] = (d :: any).Transparency
		end
	end
	local tagGui = model:FindFirstChild("GuestTag", true)
	return {
		model = model,
		root = root,
		lift = lift,
		humanoid = humanoid,
		walk = nil, -- loaded once the model is in the workspace (ensureTracks)
		idle = nil,
		joints = joints,
		upsetAt = 0,
		crate = crate,
		template = template.Name,
		pos = Vector3.zero,
		waypoints = {},
		mode = "ToQueue",
		data = nil,
		site = folder,
		lane = "Normal",
		serveIndex = nil,
		face = nil,
		entry = nil,
		extras = {},
		pace = 1,
		speedMul = 1,
		side = Vector3.zero,
		moving = false,
		heading = nil,
		carrying = false,
		looks = looks,
		tag = if tagGui then tagGui:FindFirstChildOfClass("TextLabel") else nil,
		fade = 0,
		bornAt = 0,
	}
end

-- a = 0: fully shown .. 1: invisible (parts keep their own transparency on top: glasses, etc.)
local function setFade(npc: Npc, a: number)
	if npc.fade == a then
		return
	end
	npc.fade = a
	for d, base in npc.looks do
		(d :: any).Transparency = base + (1 - base) * a
	end
	for _, e in npc.extras do
		if e:IsA("BasePart") then
			e.Transparency = a
		elseif e:IsA("Sparkles") then
			e.Enabled = a < 0.5
		end
	end
	npc.crate.Transparency = if npc.carrying then a else 1
	if npc.tag then
		npc.tag.TextTransparency = a
		npc.tag.TextStrokeTransparency = 0.35 + 0.65 * a
	end
end

-- look (from the server) picks the model: a guest (real player's avatar) GuestChance of the time when
-- there are guests, else one of the ReplicatedStorage.Customers models.
local function takeNpc(look: number): Npc?
	local rng = Random.new(look * 7919 + os.clock() * 1000)
	local guests = modelsIn("GuestCustomers")
	local models = modelsIn("Customers")
	local all = if #guests > 0 and (#models == 0 or rng:NextNumber() < CFG.GuestChance) then guests else models
	if #all == 0 then
		return nil
	end
	local template = all[rng:NextInteger(1, #all)]
	local free = pool[template.Name]
	if free and #free > 0 then
		return table.remove(free)
	end
	return newNpc(template)
end

local function vipDress(npc: Npc)
	local head = npc.model:FindFirstChild("Head") :: BasePart?
	if head then
		local crown = Instance.new("Part")
		crown.Name = "Crown"
		crown.Size = Vector3.new(1, 0.5, 1)
		crown.Color = Color3.fromRGB(255, 205, 60)
		crown.Material = Enum.Material.Neon
		crown.CanCollide = false
		crown.CanQuery = false
		crown.CanTouch = false
		crown.Massless = true
		crown.CFrame = head.CFrame * CFrame.new(0, head.Size.Y / 2 + 0.25, 0)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = head
		weld.Part1 = crown
		weld.Parent = crown
		crown.Parent = npc.model
		table.insert(npc.extras, crown)
	end
	local sparkles = Instance.new("Sparkles")
	sparkles.SparkleColor = Color3.fromRGB(255, 220, 90)
	sparkles.Parent = npc.root
	table.insert(npc.extras, sparkles)
end

local function release(npc: Npc)
	active[npc] = nil
	local s = sites[npc.site]
	if s and s.npcs[npc] then
		s.npcs[npc] = nil
		s.count -= 1
	end
	for _, e in npc.extras do
		e:Destroy()
	end
	table.clear(npc.extras)
	npc.carrying = false
	setFade(npc, 0)
	npc.crate.Transparency = 1
	for _, t in { npc.walk, npc.idle } do
		if t and t.IsPlaying then
			t:Stop(0)
		end
	end
	npc.model.Parent = nil
	local list2 = pool[npc.template]
	if not list2 then
		list2 = {}
		pool[npc.template] = list2
	end
	table.insert(list2, npc)
end

-- Lines -----------------------------------------------------------------------------------------------------

local function stateOf(site: Instance): SiteState
	local s = sites[site]
	if not s then
		s = { queue = {}, vipQueue = {}, serving = {}, vipServing = nil, npcs = {}, count = 0 }
		sites[site] = s
	end
	return s :: SiteState
end

local function walkTo(npc: Npc, points: { Vector3 })
	if npc.entry then
		table.insert(points, 1, npc.entry) -- still walking in along the sidewalk
	end
	npc.waypoints = points
end

local function leave(npc: Npc)
	local site = npc.site
	npc.mode = "Leaving"
	npc.face = nil
	npc.entry = nil
	local exits = list(site, "CustomerExit")
	local paths = list(site, "CustomerPath")
	local exit = if #exits > 0 then exits[math.random(1, #exits)] else nil
	local via = if exit then nearest(paths, exit.Position) else nil
	local pts = {}
	-- from the counter: step aside and walk past the line (not through the people waiting in it), on the
	-- side of the exit
	local line = list(site, if npc.lane == "Vip" then "VipQueuePoint" else "QueuePoint")
	if exit and #line >= 2 then
		local first, last = ground(line[1]), ground(line[#line])
		local along = Vector3.new(last.X - first.X, 0, last.Z - first.Z)
		if along.Magnitude > 0.01 then
			along = along.Unit
			local perp = Vector3.new(-along.Z, 0, along.X)
			local toExit = ground(exit) - npc.pos
			if perp:Dot(toExit) < 0 then
				perp = -perp
			end
			local off = perp * CFG.Avoid.PastLine
			table.insert(pts, npc.pos + off)
			table.insert(pts, last + along * 1.5 + off)
		end
	end
	if via and exit then
		-- the outgoing lane: the CustomerPath point moved sideways onto the exit's line (CustomerExit markers
		-- sit on the outer side of the sidewalk, CustomerSpawn / CustomerPath on the inner side), so people
		-- walking off never run into the ones walking in, and nobody steps onto the road
		local at = ground(via)
		local side = ground(exit) - at
		side = Vector3.new(side.X, 0, side.Z)
		if #paths >= 2 then
			local along = paths[2].Position - paths[1].Position
			along = Vector3.new(along.X, 0, along.Z)
			if along.Magnitude > 0.01 then
				along = along.Unit
				side -= along * side:Dot(along)
			end
		end
		table.insert(pts, at + side)
	elseif via then
		table.insert(pts, ground(via))
	end
	if exit then
		table.insert(pts, ground(exit))
	end
	if #pts == 0 then
		release(npc)
		return
	end
	walkTo(npc, pts)
end

-- Gives every waiting NPC its spot in line and sends the first ones to free counters.
local function advance(site: Instance)
	local s = stateOf(site)
	local serves = list(site, "ServePoint")
	local queuePts = list(site, "QueuePoint")
	for i, sp in serves do
		if not s.serving[i] and #s.queue > 0 then
			local npc = table.remove(s.queue, 1) :: Npc
			s.serving[i] = npc
			npc.mode = "ToServe"
			npc.serveIndex = i
			npc.face = sp.CFrame.LookVector
			walkTo(npc, { ground(sp) })
		end
	end
	for i, npc in s.queue do
		local qp = queuePts[i] or queuePts[#queuePts]
		if qp then
			walkTo(npc, { ground(qp) })
			npc.face = qp.CFrame.LookVector
		end
	end
	local vipServe = point(site, "VipServePoint")
	local vipPts = list(site, "VipQueuePoint")
	if vipServe and not s.vipServing and #s.vipQueue > 0 then
		local npc = table.remove(s.vipQueue, 1) :: Npc
		s.vipServing = npc
		npc.mode = "ToServe"
		npc.face = vipServe.CFrame.LookVector
		walkTo(npc, { ground(vipServe) })
	end
	for i, npc in s.vipQueue do
		local qp = vipPts[i] or vipPts[#vipPts]
		if qp then
			walkTo(npc, { ground(qp) })
			npc.face = qp.CFrame.LookVector
		end
	end
end

-- A speech bubble over the head (above the "@name" tag); goes with the NPC's extras.
local function say(npc: Npc, text: string, time: number?): BillboardGui?
	local head = npc.model:FindFirstChild("Head") :: BasePart?
	if not head then
		return nil
	end
	local gui = ChatBubble.Say(head, text, time, BUBBLE.CustomerOffset)
	table.insert(npc.extras, gui)
	return gui
end

-- Keepers (the heroes on the stand's keeper pads, StandService "PadHero") -----------------------------------
-- Sold out: one of them says sorry and looks embarrassed (keeperPose). Sales: now and then a "thanks".

local sorryAt: { [Instance]: number } = {} -- site -> os.clock() of its last "sorry"
local embarrassed: { [Model]: number } = {} -- keeper -> os.clock() it started

local function keepersOf(site: Instance): { Model }
	local out = {}
	local holder = if site.Parent and site.Parent.Name == StandLayoutConfig.SitesFolder then site else site.Parent
	for _, d in (holder or site):GetDescendants() do
		if d.Name == "PadHero" and d:IsA("Model") and d.Parent and d.Parent.Name:sub(1, 9) == "KeeperPad" then
			table.insert(out, d)
		end
	end
	return out
end

local function keeperSay(site: Instance, lines: { string }, mood: string, time: number?): Model?
	local keepers = keepersOf(site)
	if #keepers == 0 then
		return nil
	end
	local keeper = keepers[math.random(1, #keepers)]
	local head = keeper:FindFirstChild("Head") :: BasePart?
	if not head then
		return nil
	end
	ChatBubble.Say(head, ChatBubble.Line(lines, mood), time, BUBBLE.HeroOffset)
	return keeper
end

local function keeperSorry(site: Instance)
	local now = os.clock()
	if now - (sorryAt[site] or -math.huge) < KEEPER.SorryCooldown then
		return
	end
	sorryAt[site] = now
	local keeper = keeperSay(site, KEEPER.SorryLines, KEEPER.SorryMood, KEEPER.EmbarrassedTime + 0.4)
	if keeper then
		embarrassed[keeper] = now
	end
end

local function showOutcome(npc: Npc)
	local site = npc.site
	local data = npc.data
	local fx = deps.marker(site, "CoinFxPoint")
	if data.items > 0 then
		if fx then
			deps.popup(fx, (if data.vip then "VIP +$" else "+$") .. abbreviate(data.money), if data.vip then Color3.fromRGB(255, 210, 70) else Color3.fromRGB(110, 255, 110))
			if data.ownerId == player.UserId then
				deps.flyCoins(fx.Position, math.clamp(data.items, 1, StandConfig.SaleFxMaxCoins))
			end
		end
		npc.carrying = true -- carries it off with both arms (pose in poseStep)
		npc.crate.Transparency = npc.fade
		if math.random() < LINES.BoughtChance then
			say(npc, ChatBubble.Line(LINES.BoughtLines, LINES.BoughtMood))
		end
		if math.random() < KEEPER.ThanksChance then
			task.delay(0.4, keeperSay, site, KEEPER.ThanksLines, KEEPER.ThanksMood)
		end
	elseif fx then
		deps.popup(fx, "Sold out!", Color3.fromRGB(255, 90, 80))
	end
end

local function finishServing(npc: Npc)
	local s = stateOf(npc.site)
	if npc.lane == "Vip" then
		if s.vipServing == npc then
			s.vipServing = nil
		end
	elseif npc.serveIndex and s.serving[npc.serveIndex] == npc then
		s.serving[npc.serveIndex] = nil
	end
	leave(npc)
	advance(npc.site)
end

-- Sold out: it stays at the counter, shakes its head and slumps (poseStep), says something, then
-- walks off empty handed. A keeper says sorry a moment later.
local function upset(npc: Npc)
	npc.mode = "Upset"
	npc.upsetAt = os.clock()
	say(npc, ChatBubble.Line(LINES.SoldOutLines, LINES.SoldOutMood), CFG.UpsetTime)
	local site = npc.site
	task.delay(0.7, keeperSorry, site)
	task.delay(CFG.UpsetTime, function()
		if active[npc] and npc.mode == "Upset" then
			finishServing(npc)
		end
	end)
end

local function arrived(npc: Npc)
	if npc.mode == "ToServe" then
		npc.mode = "Serving"
		local myNpc = npc
		task.delay(CFG.ServeTime, function()
			if active[myNpc] and myNpc.mode == "Serving" then
				showOutcome(myNpc)
				if myNpc.data.items > 0 then
					finishServing(myNpc)
				else
					upset(myNpc)
				end
			end
		end)
	elseif npc.mode == "Leaving" then
		release(npc)
	end
end

local function onCustomer(site: Instance, data: any)
	local s = stateOf(site)
	local isVip = data.vip == true and point(site, "VipServePoint") ~= nil
	local queuePts = list(site, if isVip then "VipQueuePoint" else "QueuePoint")
	local line = if isVip then s.vipQueue else s.queue
	local spawns = list(site, "CustomerSpawn")
	if s.count >= CFG.MaxVisible or #line >= #queuePts or #spawns == 0 then
		-- no room for one more NPC: just show the sale
		local fx = deps.marker(site, "CoinFxPoint")
		if fx and data.items > 0 then
			deps.popup(fx, "+$" .. abbreviate(data.money), Color3.fromRGB(110, 255, 110))
			if data.ownerId == player.UserId then
				deps.flyCoins(fx.Position, math.clamp(data.items, 1, StandConfig.SaleFxMaxCoins))
			end
		end
		return
	end
	local npc = takeNpc(data.look or 1)
	if not npc then
		return
	end
	local spawn = spawns[math.random(1, #spawns)]
	local entry = nearest(list(site, "CustomerPath"), spawn.Position)
	npc.site = site
	npc.data = data
	npc.lane = if isVip then "Vip" else "Normal"
	npc.mode = "ToQueue"
	npc.serveIndex = nil
	npc.face = nil
	npc.pos = ground(spawn)
	npc.pace = CFG.PaceMin + math.random() * (CFG.PaceMax - CFG.PaceMin)
	npc.speedMul = 1
	npc.side = Vector3.zero
	npc.moving = false
	npc.heading = nil
	npc.entry = if entry then ground(entry) else nil
	npc.waypoints = {}
	npc.carrying = false
	npc.crate.Transparency = 1
	if isVip then
		vipDress(npc)
	end
	npc.bornAt = os.clock()
	setFade(npc, 1) -- fades in as it walks off the spawn (step)
	npc.model.Parent = folder
	-- tracks loaded on a model outside the workspace never advance: load them now, once
	if not npc.walk then
		npc.walk = loadTrack(npc.humanoid, WALK_ANIM, Enum.AnimationPriority.Movement)
	end
	if not npc.idle then
		npc.idle = loadTrack(npc.humanoid, IDLE_ANIM, Enum.AnimationPriority.Idle)
	end
	active[npc] = true
	s.npcs[npc] = true
	s.count += 1
	table.insert(line, npc)
	advance(site) -- its spot in line (walking in along the sidewalk first)
end

-- The stand changed level (markers moved): everyone in line walks off.
local function clearSite(site: Instance)
	local s = sites[site]
	if not s then
		return
	end
	for npc in s.npcs do
		if npc.mode ~= "Leaving" then
			npc.mode = "Leaving"
			leave(npc)
		end
	end
	table.clear(s.queue)
	table.clear(s.vipQueue)
	table.clear(s.serving)
	s.vipServing = nil
end

-- Movement (one loop for all NPCs) ------------------------------------------------------------------------------

-- Walking between people (sidewalk manners): each walking NPC looks at the others in front of it.
--   someone in front going the same way   follow at CFG.Avoid.Gap (no pushing past on a sidewalk)
--   someone standing / coming the other way   step aside (both keep to their right) and slow down
-- The sidestep is drawn on top of the route position (npc.side, at most MaxSide studs), so nobody leaves
-- the sidewalk, and arriving at a spot still uses the route position.
local AVOID = CFG.Avoid

local function avoidance(npc: Npc, dir: Vector3, reach: number, others: { Npc }): (number, number)
	local want, push = 1, 0
	local me = npc.pos + npc.side
	local right = Vector3.new(-dir.Z, 0, dir.X)
	for _, o in others do
		if o == npc or o.site ~= npc.site then
			continue
		end
		local rel = o.pos + o.side - me
		rel = Vector3.new(rel.X, 0, rel.Z)
		local dist = rel.Magnitude
		if dist >= AVOID.Look or dist < 0.01 then
			continue
		end
		local ahead = rel:Dot(dir)
		local lat = rel:Dot(right)
		if ahead <= 0 or math.abs(lat) >= AVOID.Width then
			continue
		end
		if not o.moving and #npc.waypoints == 1 and ahead > reach - 0.5 then
			continue -- it stands past the spot this one stops at (the one in front in the queue)
		end
		local oDir = o.heading
		if oDir and oDir:Dot(dir) > 0.3 and (o.moving or o.mode == npc.mode) then
			-- same way (also one stopped in front, going where this one goes): stay behind it
			want = math.min(want, math.clamp((ahead - AVOID.Gap) / AVOID.Gap, 0, 1))
		else
			-- in the way: step to the side away from it (head-on: both to their right) and slow down
			local away = if o.moving then 1 elseif lat > 0 then -1 else 1
			push += away * (1 - dist / AVOID.Look)
			want = math.min(want, if dist < AVOID.Gap then AVOID.SlowNear else AVOID.SlowFar)
			if o.moving and npc.mode == "Leaving" and o.mode ~= "Leaving" and dist < AVOID.Gap then
				want = 0 -- walking off: wait and let the one coming in pass first
			end
		end
	end
	return want, math.clamp(push, -1, 1)
end

local others: { Npc } = {}

local function step(dt: number)
	table.clear(others)
	for npc in active do
		table.insert(others, npc)
	end
	local blend = math.min(1, dt * AVOID.Smooth)
	for _, npc in others do
		if not active[npc] then
			continue
		end
		local target = npc.waypoints[1]
		local moving = false
		local sideGoal = Vector3.zero
		if target then
			local delta = Vector3.new(target.X - npc.pos.X, target.Y - npc.pos.Y, target.Z - npc.pos.Z)
			local dist = delta.Magnitude
			local flat = Vector3.new(delta.X, 0, delta.Z)
			local dir = if flat.Magnitude > 0.05 then flat.Unit else (npc.heading or Vector3.new(0, 0, -1))
			local want, push = avoidance(npc, dir, dist, others)
			npc.speedMul += (want - npc.speedMul) * blend
			sideGoal = Vector3.new(-dir.Z, 0, dir.X) * (push * AVOID.MaxSide)
			local move = CFG.WalkSpeed * npc.pace * npc.speedMul * dt
			if dist <= move then
				npc.pos = target
				table.remove(npc.waypoints, 1)
				if npc.entry and (target - npc.entry).Magnitude < 0.01 then
					npc.entry = nil
				end
				if #npc.waypoints == 0 then
					npc.speedMul = 1
					arrived(npc)
				end
			elseif npc.speedMul > 0.08 then
				npc.pos += delta.Unit * move
				moving = true
			end
			if flat.Magnitude > 0.05 then
				npc.face = flat.Unit
				npc.heading = flat.Unit
			end
		end
		npc.moving = moving
		npc.side = npc.side:Lerp(sideGoal, math.min(1, dt * (if moving then AVOID.SideIn else AVOID.SideOut)))
		if not active[npc] then
			continue
		end
		if npc.walk then
			if moving and not npc.walk.IsPlaying then
				npc.walk:Play(0.2)
			elseif not moving and npc.walk.IsPlaying then
				npc.walk:Stop(0.3)
			end
			if moving then
				local speed = CFG.WalkSpeed * npc.pace * npc.speedMul
				npc.walk:AdjustSpeed(math.clamp(speed / CFG.WalkAnimSpeed, 0.4, 1.4))
			end
		end
		if npc.idle and not npc.idle.IsPlaying then
			npc.idle:Play(0.2)
		end
		-- fade in after the spawn, out over the last FadeOut studs to the exit (no popping in / out)
		local a = 0
		if npc.mode == "Leaving" and #npc.waypoints > 0 then
			local left = (npc.waypoints[1] - npc.pos).Magnitude
			for i = 2, #npc.waypoints do
				left += (npc.waypoints[i] - npc.waypoints[i - 1]).Magnitude
			end
			a = math.clamp(1 - left / CFG.FadeOut, 0, 1)
		end
		local age = os.clock() - npc.bornAt
		if age < CFG.FadeIn then
			a = math.max(a, 1 - age / CFG.FadeIn)
		end
		setFade(npc, a)
		local at = npc.pos + npc.side + Vector3.new(0, npc.lift, 0)
		local face = npc.face or Vector3.new(0, 0, -1)
		face = Vector3.new(face.X, 0, face.Z)
		npc.model:PivotTo(if face.Magnitude > 0.01 then CFrame.lookAt(at, at + face) else CFrame.new(at))
	end
end

-- Hand-made poses on top of walk / idle, after the Animator each frame (Stepped):
--   carrying (bought something): both arms out in front under the crate (MaterialConfig.Carry.Pose)
--   upset (sold out): head shakes "no", then hangs; shoulders slump, back bends forward
local CARRY_ARMS = {
	RightShoulder = CFrame.fromEulerAnglesYXZ(math.rad(CARRY.Pose.ShoulderPitch), math.rad(CARRY.Pose.ShoulderYaw), 0),
	LeftShoulder = CFrame.fromEulerAnglesYXZ(math.rad(CARRY.Pose.ShoulderPitch), -math.rad(CARRY.Pose.ShoulderYaw), 0),
	RightElbow = CFrame.Angles(math.rad(CARRY.Pose.ElbowBend), 0, 0),
	LeftElbow = CFrame.Angles(math.rad(CARRY.Pose.ElbowBend), 0, 0),
}

-- Keeper embarrassed pose: looks down and to the side, a small bow, right hand scratching the back of the
-- head, left hand fidgeting in front. Blends in and out over the animator's pose. R15 and R6 joints, as
-- Motor6D or AnimationConstraint (both have Transform).
local function joint(model: Model, part: string, name: string): any
	local p = model:FindFirstChild(part)
	local j = p and p:FindFirstChild(name)
	return if j and (j:IsA("Motor6D") or j:IsA("AnimationConstraint")) then j else nil
end

local keeperJoints: { [Model]: { { j: any, pose: (number) -> CFrame } } } = {}

local function keeperRig(model: Model): { { j: any, pose: (number) -> CFrame } }
	local rig = keeperJoints[model]
	if rig then
		return rig
	end
	rig = {}
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") and hrp.Anchored then
		motorize(model) -- anchored keeper: AnimationConstraints would not move
	end
	local function add(j: any, pose: (number) -> CFrame)
		if j then
			table.insert(rig, { j = j, pose = pose })
		end
	end
	local rad = math.rad
	if model:FindFirstChild("UpperTorso") then
		add(joint(model, "Head", "Neck"), function(t)
			return CFrame.Angles(-rad(22), rad(12), rad(10) + math.sin(t * 2.5) * rad(3))
		end)
		add(joint(model, "UpperTorso", "Waist"), function()
			return CFrame.Angles(-rad(14), 0, 0)
		end)
		add(joint(model, "RightUpperArm", "RightShoulder"), function()
			return CFrame.fromEulerAnglesYXZ(rad(155), -rad(25), rad(20))
		end)
		add(joint(model, "RightLowerArm", "RightElbow"), function(t)
			return CFrame.Angles(rad(105) + math.sin(t * 14) * rad(10), 0, 0)
		end)
		add(joint(model, "LeftUpperArm", "LeftShoulder"), function()
			return CFrame.fromEulerAnglesYXZ(rad(25), -rad(20), 0)
		end)
		add(joint(model, "LeftLowerArm", "LeftElbow"), function()
			return CFrame.Angles(rad(60), 0, 0)
		end)
	else
		-- R6: joints point sideways (Z is the arm's forward axis, see CarryPose)
		add(joint(model, "Torso", "Neck"), function()
			return CFrame.Angles(rad(22), 0, rad(12))
		end)
		add(joint(model, "Torso", "Right Shoulder"), function(t)
			return CFrame.Angles(0, 0, rad(150) + math.sin(t * 14) * rad(8))
		end)
		add(joint(model, "Torso", "Left Shoulder"), function()
			return CFrame.Angles(0, 0, -rad(25))
		end)
	end
	keeperJoints[model] = rig
	return rig
end

local function keeperPose()
	local now = os.clock()
	for model, t0 in embarrassed do
		local t = now - t0
		if t > KEEPER.EmbarrassedTime or not model.Parent then
			embarrassed[model] = nil
			keeperJoints[model] = nil
			continue
		end
		-- ease in over 0.3 s, out over the last 0.4 s
		local w = math.clamp(math.min(t / 0.3, (KEEPER.EmbarrassedTime - t) / 0.4), 0, 1)
		w = w * w * (3 - 2 * w)
		for _, r in keeperRig(model) do
			if r.j.Parent then
				r.j.Transform = r.j.Transform:Lerp(r.pose(t), w)
			end
		end
	end
end

local function poseStep()
	keeperPose()
	for npc in active do
		local j = npc.joints
		if npc.carrying then
			for name, cf in CARRY_ARMS do
				local m = j[name]
				if m then
					m.Transform = cf
				end
			end
		elseif npc.mode == "Upset" then
			local t = os.clock() - npc.upsetAt
			local k = math.clamp(t / 0.4, 0, 1) -- eases into the pose
			local shake = math.sin(t * 10) * math.rad(28) * math.clamp(1.4 - t, 0, 1)
			if j.Neck then
				j.Neck.Transform = CFrame.Angles(-math.rad(25) * k, shake, 0)
			end
			if j.Waist then
				j.Waist.Transform = CFrame.Angles(-math.rad(12) * k, 0, 0)
			end
			if j.RightShoulder then
				j.RightShoulder.Transform = CFrame.Angles(math.rad(8) * k, 0, math.rad(6) * k)
			end
			if j.LeftShoulder then
				j.LeftShoulder.Transform = CFrame.Angles(math.rad(8) * k, 0, -math.rad(6) * k)
			end
		end
	end
end

function StandCustomers.Start(d: Deps)
	deps = d
	folder = Instance.new("Folder")
	folder.Name = "StandCustomers"
	folder.Parent = workspace
	d.standEvent.OnClientEvent:Connect(function(kind: string, site: Instance, data: any)
		if kind == "Customer" and typeof(site) == "Instance" and typeof(data) == "table" then
			onCustomer(site, data)
		elseif kind == "LevelUp" and typeof(site) == "Instance" then
			clearSite(site)
		end
	end)
	RunService.Heartbeat:Connect(step)
	RunService.Stepped:Connect(poseStep)
end

return StandCustomers
