-- HeroWorkerService: heroes placed on a plot's HeroSlots walk out of the plot's HeroGate holding an
-- axe and chop the plot's trees: pick a random tree, walk to it, swing until it falls, pick another.
--
--   HeroWorkerService.Spawn(plot, slotIndex, heroName, owner)
--   HeroWorkerService.Despawn(plot, slotIndex)
--   HeroWorkerService.DespawnPlot(plot)
--
-- Workers live in plot.HeroWorkers as "Slot<index>" (attributes Hero, OwnerUserId, Slot).
-- Spawn point: plot.HeroGate.HeroSpawn; they first walk to HeroGate.HeroExit.
-- Walking uses Movement (anchored root, CFrame every Heartbeat on plot.Floor / plot.HeroGate),
-- not Humanoid:MoveTo, so heroes glide smoothly instead of stuttering between waypoints.
-- A hero chops once it is within ATTACK_RANGE studs of the trunk (measured from the trunk's center).
-- Models / axe / default animations come from HeroModels. Swing: HeroModels.ChopAnimationId(),
-- played at the hero's ChopSpeed; its ChopPower (HeroConfig.ChopDamage) lands on the animation's "Hit"
-- marker, or near the end of the swing if the marker never fires (e.g. the animation failed to load).
-- Trees a worker fells give drops to the slot's owner, exactly like their own clicks (TreeHitService.HeroHit).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))
local TreeService = require(script.Parent:WaitForChild("TreeService"))
local TreeHitService = require(script.Parent:WaitForChild("TreeHitService"))
local HeroModels = require(script.Parent:WaitForChild("HeroModels"))
local Movement = require(script.Parent:WaitForChild("Movement"))

local ATTACK_RANGE = HeroConfig.Worker.AttackRange or 5 -- studs from the trunk's center at which a hero stops and chops
local MIN_SURFACE_GAP = 1 -- never stand closer than this to the trunk's surface (thick trunks)
local RANGE_SLACK = 1.5 -- extra studs allowed when checking "still in range" before each swing
local STUCK_TIME = 1.5 -- seconds without progress before giving up on a walk
local GROUND_RAY_OFFSET = 2 -- raycast from just above the root so the gate's arch never counts as ground
local WALK_ANIM_SPEED = 14.5 -- walk speed the walk animation was made for
local RETARGET_PAUSE = 0.35

type Worker = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	owner: Player,
	plot: Model,
	slot: number,
	hero: string,
	alive: boolean,
	target: Model?,
	tracks: { [string]: AnimationTrack },
	spawnCFrame: CFrame,
	exit: Vector3?,
	movement: any,
}

local HeroWorkerService = {}

local workersByPlot: { [Model]: { [number]: Worker } } = {}
local claims: { [Model]: number } = {} -- tree -> how many workers are after it
local rng = Random.new()

local function isAlive(w: Worker): boolean
	return w.alive and w.model.Parent ~= nil and w.owner.Parent ~= nil and w.humanoid.Health > 0
end

local function treeAlive(tree: Model): boolean
	return tree.Parent ~= nil and not tree:GetAttribute("Dead") and (tree:GetAttribute("HP") or 0) > 0
end

local function claim(tree: Model)
	claims[tree] = (claims[tree] or 0) + 1
end

local function release(tree: Model?)
	if not tree or not claims[tree] then
		return
	end
	claims[tree] -= 1
	if claims[tree] <= 0 then
		claims[tree] = nil
	end
end

-- Animations -------------------------------------------------------------------------------------

local function setWalking(w: Worker, walking: boolean)
	local walk = w.tracks.Walk
	if not walk then
		return
	end
	if walking then
		if not walk.IsPlaying then
			walk:Play(0.15)
		end
		walk:AdjustSpeed(w.movement:GetSpeed() / WALK_ANIM_SPEED)
	elseif walk.IsPlaying then
		walk:Stop(0.2)
	end
end

local function setupAnimations(w: Worker)
	local set = HeroModels.Anims(w.humanoid)
	local function load(id: string?, priority: Enum.AnimationPriority, looped: boolean): AnimationTrack
		return HeroModels.LoadTrack(w.humanoid, id, priority, looped) :: AnimationTrack
	end
	w.tracks.Idle = load(set.Idle, Enum.AnimationPriority.Core, true)
	w.tracks.Walk = load(set.Walk, Enum.AnimationPriority.Movement, true)
	w.tracks.Hold = load(set.Hold, Enum.AnimationPriority.Action, true)
	w.tracks.Chop = load(HeroModels.ChopAnimationId(), Enum.AnimationPriority.Action2, false)
	if w.tracks.Idle then
		w.tracks.Idle:Play()
	end
	if w.tracks.Hold then
		w.tracks.Hold:Play()
	end
	-- The root is anchored (Movement), so Humanoid.Running never fires: drive the walk anim ourselves.
end

-- Movement ---------------------------------------------------------------------------------------

-- Walks straight to `pos` until within `range` studs (flat distance). False when the worker
-- stopped, got stuck (no ground ahead) or `abort()` said so.
local function walkTo(w: Worker, pos: Vector3, range: number, abort: (() -> boolean)?): boolean
	local movement = w.movement
	movement:MoveTo(pos, range)
	setWalking(w, true)

	local lastPos, lastMove = w.root.Position, os.clock()
	local ok = false
	while isAlive(w) do
		if not movement:IsMoving() then
			ok = true
			break
		end
		if abort and abort() then
			break
		end
		task.wait()
		local p = w.root.Position
		if (p - lastPos).Magnitude > 0.2 then
			lastPos, lastMove = p, os.clock()
		elseif os.clock() - lastMove > STUCK_TIME then
			break -- no ground in that direction
		end
	end

	if w.movement then
		movement:Stop()
	end
	if w.model.Parent then
		setWalking(w, false)
	end
	return ok
end

-- Trees ------------------------------------------------------------------------------------------

local function pickTree(w: Worker): Model?
	local free, any = {}, {}
	for _, tree in TreeService.GetTrees(w.plot) do
		if treeAlive(tree) then
			table.insert(any, tree)
			if not claims[tree] then
				table.insert(free, tree)
			end
		end
	end
	local list = if #free > 0 then free else any
	if #list == 0 then
		return nil
	end
	return list[rng:NextInteger(1, #list)]
end

-- Trunk center (at the hero's height) and radius.
local function trunkOf(w: Worker, tree: Model): (Vector3, number)
	local trunk = tree:FindFirstChild("Trunk")
	local center = if trunk and trunk:IsA("BasePart") then trunk.Position else tree:GetPivot().Position
	local radius = if trunk and trunk:IsA("BasePart") then math.max(trunk.Size.X, trunk.Size.Z) / 2 else 2
	return Vector3.new(center.X, w.root.Position.Y, center.Z), radius
end

-- How close (from the trunk's center) the hero stands to chop.
local function attackRange(radius: number): number
	return math.max(ATTACK_RANGE, radius + MIN_SURFACE_GAP)
end

local function flatDir(from: Vector3, to: Vector3): Vector3
	local d = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	return if d.Magnitude > 0.05 then d.Unit else Vector3.new(0, 0, 1)
end

local function flatDist(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- One swing. Returns true when this swing felled the tree.
local function swing(w: Worker, tree: Model, center: Vector3, radius: number): boolean
	local track = w.tracks.Chop
	local speed = HeroConfig.ChopSpeed(w.hero)
	local length = (if track and track.Length > 0 then track.Length else 0.8) / speed
	local landed = false
	local conn: RBXScriptConnection? = nil
	if track then
		conn = track:GetMarkerReachedSignal("Hit"):Connect(function()
			landed = true
		end)
		track:Play(0.05)
		track:AdjustSpeed(speed)
	end
	local start = os.clock()
	while not landed and os.clock() - start < length * 0.9 and isAlive(w) do
		task.wait()
	end
	if conn then
		conn:Disconnect()
	end
	if not isAlive(w) or not treeAlive(tree) then
		return false
	end

	local dir = flatDir(center, w.root.Position)
	local hitPos = center + dir * radius + Vector3.new(0, 0.5, 0)
	local felled = TreeHitService.HeroHit(w.owner, w.root, tree, HeroConfig.ChopDamage(w.hero), hitPos)

	local rest = length - (os.clock() - start)
	if rest > 0 then
		task.wait(rest)
	end
	task.wait(HeroConfig.Worker.SwingCooldown)
	return felled
end

-- Main loop --------------------------------------------------------------------------------------

local function run(w: Worker)
	-- Wait for the swing animation so its length (and markers) are known.
	local t0 = os.clock()
	while w.tracks.Chop and w.tracks.Chop.Length == 0 and os.clock() - t0 < 3 do
		task.wait(0.1)
	end

	if w.exit then
		walkTo(w, w.exit, 1)
	end

	while isAlive(w) do
		-- Fell off the map somehow: back to the gate.
		if w.root.Position.Y < w.spawnCFrame.Position.Y - 40 then
			w.model:PivotTo(w.spawnCFrame)
		end

		local tree = pickTree(w)
		if not tree then
			task.wait(1)
			continue
		end
		claim(tree)
		w.target = tree

		local center, radius = trunkOf(w, tree)
		local range = attackRange(radius)
		walkTo(w, center, range, function()
			return not treeAlive(tree)
		end)

		center, radius = trunkOf(w, tree)
		range = attackRange(radius)
		if isAlive(w) and treeAlive(tree) and flatDist(w.root.Position, center) <= range + RANGE_SLACK then
			while isAlive(w) and treeAlive(tree) do
				w.movement:FaceTowards(center)
				if swing(w, tree, center, radius) then
					break
				end
			end
		end

		release(tree)
		w.target = nil
		task.wait(RETARGET_PAUSE)
	end
end

-- Spawning ---------------------------------------------------------------------------------------

local function workersFolder(plot: Model): Folder
	local folder = plot:FindFirstChild("HeroWorkers")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "HeroWorkers"
		folder.Parent = plot
	end
	return folder :: Folder
end

-- Parts that count as ground for heroes on this plot.
local function groundOf(plot: Model): { Instance }
	local list = {}
	for _, name in { "Floor", "HeroGate", "Gate" } do
		local inst = plot:FindFirstChild(name)
		if inst then
			table.insert(list, inst)
		end
	end
	return list
end

local function stopMovement(w: Worker)
	if w.movement then
		w.movement:Destroy()
		w.movement = nil
	end
end

function HeroWorkerService.Despawn(plot: Model, slot: number)
	local list = workersByPlot[plot]
	local w = list and list[slot]
	if not w then
		return
	end
	list[slot] = nil
	w.alive = false
	release(w.target)
	w.target = nil
	stopMovement(w)
	if w.model.Parent then
		w.model:Destroy()
	end
end

function HeroWorkerService.DespawnPlot(plot: Model)
	local list = workersByPlot[plot]
	if not list then
		return
	end
	for slot in list do
		HeroWorkerService.Despawn(plot, slot)
	end
	workersByPlot[plot] = nil
end

function HeroWorkerService.Spawn(plot: Model, slot: number, heroName: string, owner: Player): Model?
	HeroWorkerService.Despawn(plot, slot)

	local model, humanoid, root = HeroModels.Clone(heroName)
	if not model or not humanoid or not root then
		return nil
	end
	model.Name = "Slot" .. slot
	model:SetAttribute("OwnerUserId", owner.UserId)
	model:SetAttribute("Slot", slot)

	local gate = plot:FindFirstChild("HeroGate")
	local spawnPart = gate and gate:FindFirstChild("HeroSpawn") :: BasePart?
	local exitPart = gate and gate:FindFirstChild("HeroExit") :: BasePart?
	local spawnCFrame = if spawnPart then spawnPart.CFrame else plot:GetPivot() + Vector3.new(0, 5, 0)
	-- Spread heroes a little so they don't all pop out of the exact same spot.
	spawnCFrame *= CFrame.new(rng:NextNumber(-2, 2), 0, 0)
	model:PivotTo(spawnCFrame)
	model.Parent = workersFolder(plot)
	pcall(root.SetNetworkOwner, root, nil)

	HeroModels.GiveAxe(model, humanoid)

	-- Anchors the root and moves the model by CFrame every Heartbeat; snaps it onto the ground now.
	local movement = Movement.new(model, {
		Speed = HeroConfig.Worker.WalkSpeed,
		GroundInstances = groundOf(plot),
		GroundRayOffset = GROUND_RAY_OFFSET,
		GroundRayDistance = 60,
	})

	local w: Worker = {
		model = model,
		humanoid = humanoid,
		root = root,
		owner = owner,
		plot = plot,
		slot = slot,
		hero = heroName,
		alive = true,
		target = nil,
		tracks = {},
		spawnCFrame = spawnCFrame,
		exit = if exitPart then exitPart.Position + Vector3.new(rng:NextNumber(-3, 3), 0, rng:NextNumber(-1, 3)) else nil,
		movement = movement,
	}
	setupAnimations(w)

	workersByPlot[plot] = workersByPlot[plot] or {}
	workersByPlot[plot][slot] = w

	model.Destroying:Connect(function()
		w.alive = false
		stopMovement(w)
	end)
	task.spawn(run, w)
	return model
end

return HeroWorkerService
