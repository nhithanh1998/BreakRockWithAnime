-- StandCustomers: the customer NPCs of every Farm Stand, on this client only (started by StandClient).
-- The server already decided the sale (StandService): each Remotes.StandEvent
--   ("Customer", site, { id, vip, items, money, ownerId, look })
-- walks one NPC in: from a CustomerSpawn on the sidewalk to the nearest CustomerPath, into the waiting
-- line (QueuePoint_1 = next in line), to a free ServePoint (VIPs: VipQueuePoint_N -> VipServePoint),
-- waits ServeTime, then "+$money" pops at the counter (coins fly to the owner) and it walks off to a
-- CustomerExit holding a crate. items = 0: it found nothing and leaves empty handed ("Sold out!").
-- Light: NPC models come from a pool (ReplicatedStorage.CustomerModels clones, reused), at most
-- StandConfig.Customers.MaxVisible per stand; above that, or when the line is full, the sale only pops
-- its "+$". When the stand changes level the line is cleared: everyone walks off.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StandConfig = require(Shared:WaitForChild("StandConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))

local CFG = StandConfig.Customers
local WALK_ANIM = "rbxassetid://913402848"
local HOLD_ANIM = "rbxassetid://507768375"
local IDLE_ANIM = "rbxassetid://507766388"

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
	walk: AnimationTrack?,
	hold: AnimationTrack?,
	idle: AnimationTrack?,
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

local function templates(): { Model }
	local f = ReplicatedStorage:FindFirstChild("CustomerModels")
	local out = {}
	for _, m in if f then f:GetChildren() else {} do
		if m:IsA("Model") then
			table.insert(out, m)
		end
	end
	table.sort(out, function(a, b)
		return a.Name < b.Name
	end)
	return out
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
	model:PivotTo(CFrame.new())
	local box, size = model:GetBoundingBox()
	local lift = model:GetPivot().Position.Y - (box.Position.Y - size.Y / 2)
	local crate = Instance.new("Part")
	crate.Name = "Crate"
	crate.Size = Vector3.new(1.4, 1, 1.1)
	crate.Material = Enum.Material.WoodPlanks
	crate.Color = Color3.fromRGB(176, 120, 64)
	crate.CanCollide = false
	crate.CanQuery = false
	crate.CanTouch = false
	crate.Massless = true
	crate.Transparency = 1
	crate.CFrame = root.CFrame * CFrame.new(0, 0.2, -root.Size.Z / 2 - 0.75)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = crate
	weld.Parent = crate
	crate.Parent = model
	return {
		model = model,
		root = root,
		lift = lift,
		walk = loadTrack(humanoid, WALK_ANIM, Enum.AnimationPriority.Movement),
		hold = loadTrack(humanoid, HOLD_ANIM, Enum.AnimationPriority.Action),
		idle = loadTrack(humanoid, IDLE_ANIM, Enum.AnimationPriority.Idle),
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
	}
end

local function takeNpc(look: number): Npc?
	local all = templates()
	if #all == 0 then
		return nil
	end
	local template = all[(look - 1) % #all + 1]
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
	npc.crate.Transparency = 1
	for _, t in { npc.walk, npc.hold, npc.idle } do
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
	if via then
		table.insert(pts, ground(via) + Vector3.new(0, 0, 3)) -- the outgoing lane, a bit further out
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
		npc.crate.Transparency = 0
		if npc.hold then
			npc.hold:Play(0.2)
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

local function arrived(npc: Npc)
	if npc.mode == "ToServe" then
		npc.mode = "Serving"
		local myNpc = npc
		task.delay(CFG.ServeTime, function()
			if active[myNpc] and myNpc.mode == "Serving" then
				showOutcome(myNpc)
				finishServing(myNpc)
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
	npc.entry = if entry then ground(entry) else nil
	npc.waypoints = {}
	npc.crate.Transparency = 1
	if isVip then
		vipDress(npc)
	end
	npc.model.Parent = folder
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

local function step(dt: number)
	for npc in active do
		local target = npc.waypoints[1]
		local moving = false
		if target then
			local delta = Vector3.new(target.X - npc.pos.X, target.Y - npc.pos.Y, target.Z - npc.pos.Z)
			local dist = delta.Magnitude
			local move = CFG.WalkSpeed * dt
			if dist <= move then
				npc.pos = target
				table.remove(npc.waypoints, 1)
				if npc.entry and (target - npc.entry).Magnitude < 0.01 then
					npc.entry = nil
				end
				if #npc.waypoints == 0 then
					arrived(npc)
				end
			else
				npc.pos += delta.Unit * move
				moving = true
			end
			local flat = Vector3.new(delta.X, 0, delta.Z)
			if flat.Magnitude > 0.05 then
				npc.face = flat.Unit
			end
		end
		if not active[npc] then
			continue
		end
		if npc.walk then
			if moving and not npc.walk.IsPlaying then
				npc.walk:Play(0.15)
			elseif not moving and npc.walk.IsPlaying then
				npc.walk:Stop(0.2)
			end
		end
		if npc.idle and not npc.idle.IsPlaying then
			npc.idle:Play(0.2)
		end
		local at = npc.pos + Vector3.new(0, npc.lift, 0)
		local face = npc.face or Vector3.new(0, 0, -1)
		face = Vector3.new(face.X, 0, face.Z)
		npc.model:PivotTo(if face.Magnitude > 0.01 then CFrame.lookAt(at, at + face) else CFrame.new(at))
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
end

return StandCustomers
