-- ZoneTransitionFX: animates zone changes on every plot from the attributes ZoneService sets.
--   SwapAt / SwapOutTime / LiftFromY
--       "out": the old trees sink into the floor (with a little twist) and fade, the old decor fades out.
--       The floor stays where it is.
--   LiftToY
--       the Ground's height in the new zone. The new decor arrives hidden, placed on the floor as it is now.
--   LiftMoveAt / LiftMoveTime
--       the floor glides from LiftFromY to LiftToY (sine in-out), up or down depending on the zone's depth;
--       the new decor rides along and fades in. Idle heroes ride it too (HeroMotion reads ZoneLift).
--   ZoneFreeze
--       while set, the local player can't move or chop if this is their plot or they stood on its floor;
--       a player on the floor rides it (their character is moved with it every frame).
--   ZoneInAt / ZoneInTime
--       new trees grow out of the floor (wave from the center out). They start fully under the opaque
--       floor, so they need no fade (no Transparency writes: trees have hundreds of parts each).
-- ReplicatedStorage.ZoneStaging: the next layout waits there during "out"; it is preloaded here.
-- Everything here is visual and local; the server already holds the real positions, and each animation
-- ends exactly on them. All moved parts go through ONE workspace:BulkMoveTo per frame (cheap on mobile),
-- and a part is only rewritten when its offset really changed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ContentProvider = game:GetService("ContentProvider")

local ZoneLift = require(script.Parent:WaitForChild("ZoneLift"))

local Plots = workspace:WaitForChild("Plots")
local Staging = ReplicatedStorage:WaitForChild("ZoneStaging")

local player = Players.LocalPlayer

-- PlayerModule controls when the place has them (it may not: then the Humanoid is frozen instead).
-- Never waited on: a missing PlayerModule must not stop the whole transition from playing.
local controls: any = nil
do
	local scripts = player:FindFirstChildOfClass("PlayerScripts")
	local module = scripts and scripts:FindFirstChild("PlayerModule")
	if module and module:IsA("ModuleScript") then
		local ok, pm = pcall(require, module)
		if ok and pm and pm.GetControls then
			controls = pm:GetControls()
		end
	end
end

local LIFT_FOLDERS = { "ChopGround", "ZoneMap", "TreeSpawns" }
local DECOR_FOLDERS = { ChopGround = true, ZoneMap = true }

local TREE_OUT_TWIST = math.rad(35) -- old trees turn this much while sinking
local TREE_SINK_SHARE = 1.05 -- old trees sink this share of their height
local NEW_FADE_UNTIL = 0.6 -- share of the move by which the new decor is fully visible
local CARRY_ABOVE = 14 -- studs above the floor top that still count as "standing on the floor"
local FREEZE_MAX = 20 -- seconds; safety net if the plot never clears ZoneFreeze
-- Transparency writes are the expensive part (trees have hundreds of parts each): visibility is
-- quantized to these steps, so a part's Transparency is rewritten only a handful of times per fade.
local TREE_VIS_STEP = 0.2
local DECOR_VIS_STEP = 0.1
local OUT_TREE_STAGGER = 0.5 -- share of the "out" time: old trees sink in a wave from the center out

local IN_TREE_DELAY, IN_TREE_STAGGER, IN_TREE_TIME = 0.1, 0.45, 0.7
local TREE_TWIST = math.rad(50)
local IN_TREE_SINK = 1.03 -- new trees start this share of their height under the floor (fully hidden by it)

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

-- Easing ---------------------------------------------------------------------------------------

local function sineInOut(t: number): number
	return 0.5 - 0.5 * math.cos(math.pi * t)
end

local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local function backOut(t: number): number
	local c1 = 1.4
	local c3 = c1 + 1
	local u = t - 1
	return 1 + c3 * u * u * u + c1 * u * u
end

-- Seconds since a server timestamp attribute, or nil.
local function since(plot: Instance, attr: string): number?
	local at = plot:GetAttribute(attr)
	if typeof(at) ~= "number" then
		return nil
	end
	return serverNow() - at
end

local function groundOf(plot: Instance): BasePart?
	local floor = plot:FindFirstChild("Floor")
	local ground = floor and floor:FindFirstChild("Ground")
	return if ground and ground:IsA("BasePart") then ground else nil
end

-- Calls fn for each movable item under a container (folders are opened up).
local function eachItem(container: Instance, fn: (PVInstance) -> ())
	for _, child in container:GetChildren() do
		if child:IsA("Folder") then
			eachItem(child, fn)
		elseif child:IsA("Model") or child:IsA("BasePart") then
			fn(child :: PVInstance)
		end
	end
end

-- Preload ----------------------------------------------------------------------------------------
-- Meshes / textures of the next layout download while the old trees go away.

local function preload(layout: Instance)
	task.spawn(function()
		ContentProvider:PreloadAsync({ layout })
	end)
end

Staging.ChildAdded:Connect(preload)
for _, child in Staging:GetChildren() do
	preload(child)
end

-- Floor swap -------------------------------------------------------------------------------------

type Fade = { inst: Instance, t: number }
type Gui = { gui: BillboardGui, enabled: boolean }
type LiftItem = {
	inst: PVInstance,
	refY: number, -- floor Y at which the item stands at its real (server) spot
	parts: { BasePart },
	bases: { CFrame }, -- real CFrame of each part
	fades: { Fade },
	guis: { Gui },
	visible: number, -- last applied (quantized) visibility
	visStep: number,
	key: number?, -- last applied pose (nil = must be rewritten)
	isNew: boolean,
	isTree: boolean,
	sink: number,
	delay: number, -- share of the "out" phase before this old tree starts sinking (wave)
	pivot: CFrame,
	delta: CFrame, -- last applied offset from the real spot
	conn: RBXScriptConnection?,
	-- tree budget (see "Tree budget")
	isAnim: boolean,
	lastWrite: number,
	wantY: number,
	wantPhase: number,
}
type Lift = {
	plot: Instance,
	ground: BasePart,
	groundBase: CFrame, -- ground CFrame with its Y at 0
	fromY: number,
	out: number,
	start: number, -- os.clock() of the swap start
	toY: number?,
	moveStart: number?,
	move: number,
	items: { [Instance]: LiftItem },
	conns: { RBXScriptConnection },
	done: boolean,
}

local lifts: { [Instance]: Lift } = {}

-- Reused every frame: one BulkMoveTo for every moving part of every lift.
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}
local moveCount = 0

local function flushMoves()
	if moveCount > 0 then
		workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(moveParts)
		table.clear(moveCFrames)
		moveCount = 0
	end
end

-- Tree budget ------------------------------------------------------------------------------------
-- Moving a part costs the engine several microseconds no matter how it is moved, and trees have hundreds
-- of parts each (a whole forest is thousands). So trees (old ones sinking, new ones growing) are re-posed
-- under a per-frame part budget: every frame the trees that waited longest go first, the rest keep their
-- last pose one more frame. Each write jumps straight to the pose for "now", so nothing lags behind; with
-- few trees everything still moves every frame. Floor + decor are not budgeted (they must stay together).
local TREE_PART_BUDGET = 700

local frameNo = 0
local wantTrees: { any } = {} -- trees whose pose changed this frame (LiftItem or TreeAnim)
local placeItem: (item: any, y: number, phase: number) -> ()
local poseTree: (a: any, progress: number) -> ()

local function byLastWrite(a: any, b: any): boolean
	return a.lastWrite < b.lastWrite
end

local function queueTree(job: any)
	table.insert(wantTrees, job)
end

local function processTrees()
	local n = #wantTrees
	if n == 0 then
		return
	end
	if n > 1 then
		table.sort(wantTrees, byLastWrite)
	end
	local budget = TREE_PART_BUDGET
	for _, job in wantTrees do
		if budget <= 0 then
			break -- always at least one tree per frame
		end
		budget -= #job.parts
		job.lastWrite = frameNo
		if job.isAnim then
			poseTree(job, job.want)
		else
			placeItem(job, job.wantY, job.wantPhase)
		end
	end
	table.clear(wantTrees)
end

local function collect(item: LiftItem, d: Instance)
	if d:IsA("BasePart") then
		table.insert(item.parts, d)
		table.insert(item.bases, d.CFrame)
		if d.Transparency < 1 then -- an invisible part stays invisible: nothing to fade
			table.insert(item.fades, { inst = d, t = d.Transparency })
		end
	elseif d:IsA("Decal") or d:IsA("Texture") then
		if (d :: any).Transparency < 1 then
			table.insert(item.fades, { inst = d, t = (d :: any).Transparency })
		end
	elseif d:IsA("BillboardGui") then
		table.insert(item.guis, { gui = d, enabled = d.Enabled })
	end
end

local function setVisible(item: LiftItem, visible: number)
	-- Only rewritten when the quantized visibility changes (a few times per fade, not every frame).
	local step = item.visStep
	visible = math.clamp(math.floor(visible / step + 0.5) * step, 0, 1)
	if visible == item.visible then
		return
	end
	item.visible = visible
	for _, f in item.fades do
		if f.inst.Parent then
			(f.inst :: any).Transparency = 1 - (1 - f.t) * visible
		end
	end
	for _, g in item.guis do
		if g.gui.Parent then
			g.gui.Enabled = g.enabled and visible >= 0.99
		end
	end
end

-- Floor height (server Y of the Ground's center) at os.clock() `now`, and the phase:
-- 0..1 old stuff goes away, 1 waiting for the server, 2..3 the floor moves.
local function liftState(l: Lift, now: number): (number, number)
	if l.moveStart and l.toY then
		local u = math.clamp((now - l.moveStart) / l.move, 0, 1)
		return l.fromY + (l.toY - l.fromY) * sineInOut(u), 2 + u
	end
	local t = now - l.start
	return l.fromY, math.clamp(t / l.out, 0, 1)
end

-- 0..1: how far this old tree has sunk, from the "out" phase and its place in the wave.
local function treeOutProgress(item: LiftItem, phase: number): number
	return math.clamp((math.min(phase, 1) - item.delay) / (1 - OUT_TREE_STAGGER), 0, 1)
end

local function itemVisibility(item: LiftItem, phase: number): number
	if item.isNew then
		if phase < 2 then
			return 0
		end
		return smooth((phase - 2) / NEW_FADE_UNTIL)
	end
	if phase >= 1 then
		return 0
	end
	if item.isTree then
		return 1 - smooth((treeOutProgress(item, phase) - 0.25) / 0.6) -- sink first, fade on the way down
	end
	return 1 - smooth(phase)
end

-- Pose key of an item: off + u * 1000 (u = how far an old tree has sunk, squared).
local function itemPose(item: LiftItem, y: number, phase: number): (number, number, number)
	local off = y - item.refY
	local u = 0
	if item.isTree and not item.isNew then
		u = treeOutProgress(item, phase)
		u *= u
		off -= item.sink * u
	end
	return off, u, off + u * 1000
end

-- Queues the item's parts for this frame's BulkMoveTo when its pose changed.
placeItem = function(item: LiftItem, y: number, phase: number)
	local off, u, key = itemPose(item, y, phase)
	if item.key == nil or math.abs(key - item.key) > 1e-4 then
		item.key = key
		local delta = CFrame.new(0, off, 0)
		if u > 0 then
			local p = item.pivot
			delta = delta * (p * CFrame.Angles(0, u * TREE_OUT_TWIST, 0) * p:Inverse())
		end
		item.delta = delta
		for i, part in item.parts do
			if part.Parent then
				moveCount += 1
				moveParts[moveCount] = part
				moveCFrames[moveCount] = delta * item.bases[i]
			end
		end
	end
	setVisible(item, itemVisibility(item, phase))
end

local function addItem(l: Lift, inst: PVInstance, isNew: boolean, isTree: boolean)
	if l.items[inst] then
		return
	end
	local toY = l.toY or l.plot:GetAttribute("LiftToY")
	local refY = if isNew and typeof(toY) == "number" then toY else l.fromY
	local item: LiftItem = {
		inst = inst,
		refY = refY,
		parts = {},
		bases = {},
		fades = {},
		guis = {},
		visible = 1,
		visStep = if isTree then TREE_VIS_STEP else DECOR_VIS_STEP,
		key = nil,
		isNew = isNew,
		isTree = isTree,
		sink = 0,
		delay = 0,
		pivot = inst:GetPivot(),
		delta = CFrame.identity,
		conn = nil,
		isAnim = false,
		lastWrite = 0,
		wantY = 0,
		wantPhase = 0,
	}
	collect(item, inst)
	for _, d in inst:GetDescendants() do
		collect(item, d)
	end
	if isTree then
		if inst:IsA("Model") then
			local cf, size = inst:GetBoundingBox()
			item.sink = size.Y * TREE_SINK_SHARE
			item.pivot = CFrame.new(cf.X, cf.Y - size.Y / 2, cf.Z)
		else
			item.sink = (inst :: BasePart).Size.Y * TREE_SINK_SHARE
		end
		-- Wave from the floor's center out: looks nicer and spreads the per-tree work over frames.
		local g = l.ground
		local p = item.pivot.Position
		local d = Vector2.new(p.X - g.Position.X, p.Z - g.Position.Z).Magnitude
		local maxD = Vector2.new(g.Size.X, g.Size.Z).Magnitude / 2
		item.delay = math.clamp(d / maxD, 0, 1) * OUT_TREE_STAGGER
	end
	-- Parts that stream in later arrive at their real spot: remember it, and put just that part into the
	-- item's current pose / visibility right away (not the whole item again).
	item.conn = inst.DescendantAdded:Connect(function(d)
		if l.done then
			return
		end
		local nFades = #item.fades
		collect(item, d)
		if d:IsA("BasePart") then
			d.CFrame = item.delta * d.CFrame
		end
		local f = item.fades[nFades + 1]
		if f then
			(f.inst :: any).Transparency = 1 - (1 - f.t) * item.visible
		end
		if d:IsA("BillboardGui") then
			d.Enabled = d.Enabled and item.visible >= 0.99
		end
	end)
	l.items[inst] = item
	local y, phase = liftState(l, os.clock())
	placeItem(item, y, phase)
	setVisible(item, itemVisibility(item, phase))
end

local function watchLiftFolder(l: Lift, container: Instance, isDecor: boolean)
	table.insert(l.conns, container.ChildAdded:Connect(function(child)
		if l.done then
			return
		end
		-- Arrivals after LiftToY are the new zone's decor: hidden, they ride the floor and fade in.
		-- New trees are not part of the lift (they grow in on ZoneInAt).
		local isNew = l.toY ~= nil or l.plot:GetAttribute("LiftToY") ~= nil
		if not isDecor and isNew then
			return
		end
		if child:IsA("Folder") then
			watchLiftFolder(l, child, isDecor)
			eachItem(child, function(item)
				addItem(l, item, isNew, not isDecor)
			end)
		elseif child:IsA("Model") or child:IsA("BasePart") then
			addItem(l, child :: PVInstance, isNew, not isDecor)
		end
	end))
	for _, child in container:GetChildren() do
		if child:IsA("Folder") then
			watchLiftFolder(l, child, isDecor)
		end
	end
end

-- Local player: freeze, ride along ----------------------------------------------------------------

type Rider = {
	plot: Instance,
	carry: number?,
	started: number,
	humanoid: Humanoid?,
	walkSpeed: number,
	jumpPower: number,
	jumpHeight: number,
}
local rider: Rider? = nil

local function rootPart(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Height of the root above the Ground's center, if the player stands on this floor.
local function heightOnFloor(ground: BasePart): number?
	local root = rootPart()
	if not root then
		return nil
	end
	local rel = ground.CFrame:PointToObjectSpace(root.Position)
	if math.abs(rel.X) > ground.Size.X / 2 or math.abs(rel.Z) > ground.Size.Z / 2 then
		return nil
	end
	local above = rel.Y - ground.Size.Y / 2
	if above < -2 or above > CARRY_ABOVE then
		return nil
	end
	return root.Position.Y - ground.Position.Y
end

local function unfreeze()
	local r = rider
	if not r then
		return
	end
	rider = nil
	if controls then
		controls:Enable()
	end
	local h = r.humanoid
	if h and h.Parent then
		h.WalkSpeed = r.walkSpeed
		h.JumpPower = r.jumpPower
		h.JumpHeight = r.jumpHeight
	end
	player:SetAttribute("ZoneFrozen", nil)
end

local function freeze(plot: Instance, ground: BasePart)
	if rider then
		unfreeze()
	end
	local carry = heightOnFloor(ground)
	local mine = plot:GetAttribute("OwnerUserId") == player.UserId
	if not carry and not mine then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	rider = {
		plot = plot,
		carry = carry,
		started = os.clock(),
		humanoid = humanoid,
		walkSpeed = if humanoid then humanoid.WalkSpeed else 16,
		jumpPower = if humanoid then humanoid.JumpPower else 50,
		jumpHeight = if humanoid then humanoid.JumpHeight else 7.2,
	}
	if controls then
		controls:Disable()
	end
	player:SetAttribute("ZoneFrozen", true) -- TreeClient doesn't chop while set
	if humanoid then
		humanoid:Move(Vector3.zero)
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0
	end
end

-- Keeps the character at the same height above the moving floor.
local function carryRider(l: Lift, y: number)
	local r = rider
	if not r or r.plot ~= l.plot or not r.carry then
		return
	end
	local character = player.Character
	local root = rootPart()
	if not character or not root then
		return
	end
	local dy = (y + r.carry) - root.Position.Y
	if math.abs(dy) > 0.001 then
		character:PivotTo(character:GetPivot() + Vector3.new(0, dy, 0))
	end
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
end

-- Lift lifecycle -------------------------------------------------------------------------------------

local function endLift(l: Lift)
	if l.done then
		return
	end
	l.done = true
	for _, c in l.conns do
		c:Disconnect()
	end
	-- Everything ends exactly on the server's positions.
	for _, item in l.items do
		if item.conn then
			item.conn:Disconnect()
		end
		if item.inst.Parent then
			for i, part in item.parts do
				if part.Parent then
					moveCount += 1
					moveParts[moveCount] = part
					moveCFrames[moveCount] = item.bases[i]
				end
			end
			item.visible = -1
			setVisible(item, 1)
		end
	end
	flushMoves()
	table.clear(l.items)
	if l.ground.Parent then
		l.ground.CFrame = l.groundBase + Vector3.new(0, l.toY or l.fromY, 0)
	end
	if lifts[l.plot] == l then
		lifts[l.plot] = nil
		ZoneLift.Clear(l.plot)
	end
	if rider and rider.plot == l.plot and l.plot:GetAttribute("ZoneFreeze") ~= true then
		unfreeze()
	end
end

local function startLift(plot: Instance)
	local elapsed = since(plot, "SwapAt")
	local ground = groundOf(plot)
	local fromY = plot:GetAttribute("LiftFromY")
	if not elapsed or not ground or typeof(fromY) ~= "number" then
		return
	end
	local out = plot:GetAttribute("SwapOutTime") or 0.9
	local old = lifts[plot]
	if old then
		endLift(old)
	end
	if elapsed > out + 15 then
		return -- long over (joined late)
	end
	local cf = ground.CFrame
	local l: Lift = {
		plot = plot,
		ground = ground,
		groundBase = cf - Vector3.new(0, cf.Position.Y, 0), -- keeps X / Z: only the height is animated
		fromY = fromY,
		out = out,
		start = os.clock() - elapsed,
		toY = nil,
		moveStart = nil,
		move = plot:GetAttribute("LiftMoveTime") or 1.2,
		items = {},
		conns = {},
		done = false,
	}
	lifts[plot] = l
	ZoneLift.Set(plot, ground, function(clock: number): number
		local y = liftState(l, clock)
		return y
	end)
	for _, name in LIFT_FOLDERS do
		local folder = plot:FindFirstChild(name)
		if folder then
			local isDecor = DECOR_FOLDERS[name] == true
			eachItem(folder, function(item)
				addItem(l, item, false, not isDecor)
			end)
			watchLiftFolder(l, folder, isDecor)
		end
	end
	if plot:GetAttribute("ZoneFreeze") then
		freeze(plot, ground)
	end
end

local function onMove(plot: Instance)
	local l = lifts[plot]
	local elapsed = since(plot, "LiftMoveAt")
	local toY = plot:GetAttribute("LiftToY")
	if not l or not elapsed or typeof(toY) ~= "number" then
		return
	end
	l.toY = toY
	l.move = plot:GetAttribute("LiftMoveTime") or l.move
	l.moveStart = os.clock() - elapsed
end

local function onToY(plot: Instance)
	local l = lifts[plot]
	local toY = plot:GetAttribute("LiftToY")
	if l and typeof(toY) == "number" then
		l.toY = toY
	end
end

-- visual = true: items too (before rendering). false: only floor + rider (before physics).
local function stepLift(l: Lift, now: number, visual: boolean)
	if not l.ground.Parent or not l.plot.Parent then
		endLift(l)
		return
	end
	local y, phase = liftState(l, now)
	-- Written every step: the server's own Ground replication must never show through.
	l.ground.CFrame = l.groundBase + Vector3.new(0, y, 0)
	if visual then
		for inst, item in l.items do
			if inst.Parent then
				if not item.isTree then
					placeItem(item, y, phase)
				elseif item.visible > 0 then -- a faded-out old tree is not moved any more
					local _, _, key = itemPose(item, y, phase)
					if item.key == nil or math.abs(key - item.key) > 1e-4 then
						item.wantY, item.wantPhase = y, phase
						queueTree(item)
					end
				end
			else
				if item.conn then
					item.conn:Disconnect()
				end
				l.items[inst] = nil
			end
		end
	end
	carryRider(l, y)
	if phase >= 3 then
		endLift(l)
	end
end

-- Trees growing in after the swap (ZoneInAt) --------------------------------------------------------

-- The new trees start fully under the (opaque) floor, so they need no fade: only one BulkMoveTo entry
-- per part per frame, and no Transparency writes at all (those are what made the grow-in hitch).
type PartState = { part: BasePart, cf: CFrame }
type TreeAnim = {
	inst: Instance,
	parts: { PartState },
	guis: { Gui },
	pivot: CFrame,
	sink: number,
	minY: number,
	maxY: number,
	start: number,
	duration: number,
	key: number?, -- last applied progress (nil = never posed)
	delta: CFrame, -- last applied offset from the real spot
	conn: RBXScriptConnection?,
	-- tree budget
	isAnim: boolean,
	lastWrite: number,
	want: number,
}

local treeAnims: { [Instance]: TreeAnim } = {}

local function measure(a: TreeAnim, part: BasePart, cf: CFrame)
	local half = part.Size.Y / 2
	a.minY = math.min(a.minY, cf.Position.Y - half)
	a.maxY = math.max(a.maxY, cf.Position.Y + half)
	a.sink = (a.maxY - a.minY) * IN_TREE_SINK
	local p = a.pivot.Position
	a.pivot = CFrame.new(p.X, a.minY, p.Z)
end

local function addTreePart(a: TreeAnim, d: Instance, streamed: boolean)
	if d:IsA("BasePart") then
		local cf = d.CFrame
		table.insert(a.parts, { part = d, cf = cf })
		if streamed then
			d.CFrame = a.delta * cf -- joins the tree's current pose at once (no pop above the floor)
		else
			measure(a, d, cf)
		end
	elseif d:IsA("BillboardGui") then
		-- HP bar: hidden while the tree is still under the floor.
		table.insert(a.guis, { gui = d, enabled = d.Enabled })
		d.Enabled = false
	end
end

local function stopTree(a: TreeAnim)
	if a.conn then
		a.conn:Disconnect()
	end
	for _, g in a.guis do
		if g.gui.Parent then
			g.gui.Enabled = g.enabled
		end
	end
	treeAnims[a.inst] = nil
end

-- progress 0 = hidden in the floor, 1 = in place.
poseTree = function(a: TreeAnim, progress: number)
	a.key = progress
	local delta = CFrame.new(0, -(1 - progress) * a.sink, 0)
	local twist = (1 - progress) * TREE_TWIST
	if twist ~= 0 then
		delta = delta * (a.pivot * CFrame.Angles(0, twist, 0) * a.pivot:Inverse())
	end
	a.delta = delta
	for _, s in a.parts do
		if s.part.Parent then
			moveCount += 1
			moveParts[moveCount] = s.part
			moveCFrames[moveCount] = delta * s.cf
		end
	end
end

local function treeProgress(a: TreeAnim, now: number): number
	local t = (now - a.start) / a.duration
	return if t >= 1 then 1 elseif t <= 0 then 0 else backOut(t)
end

-- Queues the tree for this frame's budget when its pose changed; done once it was drawn in place.
local function stepTree(a: TreeAnim, now: number)
	if not a.inst.Parent then
		stopTree(a)
		return
	end
	local progress = treeProgress(a, now)
	if a.key ~= nil and math.abs(progress - a.key) < 1e-4 then
		if progress == 1 then
			stopTree(a)
		end
		return -- still waiting for its turn in the wave: nothing changed
	end
	a.want = progress
	queueTree(a)
end

local function startTree(inst: Instance, start: number)
	if treeAnims[inst] or not (inst:IsA("Model") or inst:IsA("BasePart")) then
		return
	end
	local a: TreeAnim = {
		inst = inst,
		parts = {},
		guis = {},
		pivot = (inst :: PVInstance):GetPivot(),
		sink = 0,
		minY = math.huge,
		maxY = -math.huge,
		start = start,
		duration = IN_TREE_TIME,
		key = nil,
		delta = CFrame.identity,
		isAnim = true,
		lastWrite = 0,
		want = 0,
	}
	addTreePart(a, inst, false)
	for _, d in inst:GetDescendants() do
		addTreePart(a, d, false)
	end
	-- Parts that stream in mid-animation join it in its current pose.
	a.conn = inst.DescendantAdded:Connect(function(d)
		addTreePart(a, d, true)
	end)
	treeAnims[inst] = a
	-- First pose right away, outside the budget: the tree must never be drawn at its real spot first.
	a.lastWrite = frameNo
	poseTree(a, treeProgress(a, os.clock()))
	flushMoves()
end

local function waveDelay(plot: Instance, inst: Instance, stagger: number): number
	local ground = groundOf(plot)
	if not ground then
		return 0
	end
	local pos = (inst :: PVInstance):GetPivot().Position
	local d = Vector2.new(pos.X - ground.Position.X, pos.Z - ground.Position.Z).Magnitude
	local maxD = Vector2.new(ground.Size.X, ground.Size.Z).Magnitude / 2
	return math.clamp(d / maxD, 0, 1) * stagger
end

local function onTreeAdded(plot: Instance, item: Instance)
	local elapsed = since(plot, "ZoneInAt")
	local window = (plot:GetAttribute("ZoneInTime") or 1.6) + 1
	if not elapsed or elapsed > window then
		return
	end
	local begin = os.clock() - elapsed
	startTree(item, begin + IN_TREE_DELAY + waveDelay(plot, item, IN_TREE_STAGGER))
end

-- Wiring -----------------------------------------------------------------------------------------

local function hookPlot(plot: Instance)
	plot:GetAttributeChangedSignal("SwapAt"):Connect(function()
		startLift(plot)
	end)
	plot:GetAttributeChangedSignal("LiftToY"):Connect(function()
		onToY(plot)
	end)
	plot:GetAttributeChangedSignal("LiftMoveAt"):Connect(function()
		onMove(plot)
	end)
	plot:GetAttributeChangedSignal("ZoneFreeze"):Connect(function()
		if plot:GetAttribute("ZoneFreeze") ~= true and rider and rider.plot == plot then
			unfreeze()
		end
	end)
	local function hookTrees(folder: Instance)
		if folder.Name == "TreeSpawns" then
			folder.ChildAdded:Connect(function(child)
				onTreeAdded(plot, child)
			end)
		end
	end
	plot.ChildAdded:Connect(hookTrees)
	for _, child in plot:GetChildren() do
		hookTrees(child)
	end
	-- Joined mid-transition.
	if plot:GetAttribute("SwapAt") and plot:GetAttribute("ZoneBusy") then
		startLift(plot)
		onMove(plot)
	end
end

for _, plot in Plots:GetChildren() do
	hookPlot(plot)
end
Plots.ChildAdded:Connect(hookPlot)
Plots.ChildRemoved:Connect(function(plot)
	local l = lifts[plot]
	if l then
		endLift(l)
	end
	if rider and rider.plot == plot then
		unfreeze()
	end
end)

player.CharacterRemoving:Connect(function()
	if rider then
		rider.carry = nil
	end
end)

-- Before rendering: floor, decor, trees (one BulkMoveTo for all of it). HeroMotion reads the same
-- floor height (ZoneLift) in the same frame, so heroes stand exactly on what is drawn.
RunService.PreRender:Connect(function()
	local now = os.clock()
	frameNo += 1
	for _, l in lifts do
		stepLift(l, now, true)
	end
	for _, a in treeAnims do
		stepTree(a, now)
	end
	processTrees() -- trees under the per-frame part budget
	flushMoves()
end)

-- Before physics: the floor and the rider again, so the character stands on the floor it sees.
RunService.PreSimulation:Connect(function()
	local now = os.clock()
	for _, l in lifts do
		stepLift(l, now, false)
	end
	if rider and now - rider.started > FREEZE_MAX then
		unfreeze()
	end
end)
