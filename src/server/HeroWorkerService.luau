-- HeroWorkerService: heroes placed on a plot's HeroSlots walk out of the plot's HeroGate holding an
-- axe and chop the plot's trees: pick a random tree, walk to it, swing until it falls, pick another.
--
--   HeroWorkerService.Spawn(plot, slotIndex, heroName, owner)
--   HeroWorkerService.Despawn(plot, slotIndex)
--   HeroWorkerService.DespawnPlot(plot)
--
-- Workers live in plot.HeroWorkers as "Slot<index>" (attributes Hero, OwnerUserId, Slot).
-- Spawn point: plot.HeroGate.HeroSpawn; they first walk to HeroGate.HeroExit.
-- Walking uses Movement (anchored root on plot.Floor / plot.HeroGate), not Humanoid:MoveTo. Movement runs
-- ClientRendered: the server only keeps each hero's logical position (posOf) and publishes its path as
-- attributes; every client draws the motion itself each frame (client HeroMotion), so heroes glide
-- smoothly for all players. The real root part on the server is only written when a hero stops.
-- A hero chops once it is within ATTACK_RANGE studs of the trunk (measured from the trunk's center).
-- Models / axe / default animations come from HeroModels. Swing: HeroModels.ChopAnimationId(),
-- played at the hero's ChopSpeed; its ChopPower (HeroConfig.ChopDamage) lands on the animation's "Hit"
-- marker, or near the end of the swing if the marker never fires (e.g. the animation failed to load).
-- Trees a worker fells give drops to the slot's owner, exactly like their own clicks (TreeHitService.HeroHit).
-- Stats come from the pad's upgrade levels (slot attributes "LevelDamage" / "LevelSpeed" / "LevelWalk",
-- HeroConfig.Upgrades) times their grades ("GradeDamage" ..., HeroConfig.StatValue): damage and swing speed are read every swing, walk speed and the "Level N"
-- on the HeroBar are set on spawn and by HeroWorkerService.ApplyLevels(plot, slotIndex).
-- Devil Fruits: the pad's "HeroFruit" (FruitConfig) multiplies damage by its Boost, swing / walk speed
-- by its Skill Speed / Walk, and its Skill triggers on swings (extra hits, splash, burn, crits). Effects
-- are drawn by the clients (Remotes.FruitFX -> FruitFX).
-- Zone swaps: while the plot's "HeroesHold" is set (ZoneService), heroes drop what they are doing, run
-- back into the HeroGate and hide (ServerStorage.HiddenHeroes). Once it clears they walk out again.
-- The plot's "HeroesOutside" = how many heroes are not hidden yet; ZoneService waits for it to reach 0.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))
local TreeService = require(script.Parent:WaitForChild("TreeService"))
local TreeHitService = require(script.Parent:WaitForChild("TreeHitService"))
local HeroModels = require(script.Parent:WaitForChild("HeroModels"))
local Movement = require(script.Parent:WaitForChild("Movement"))
local ShopConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ShopConfig"))
local FruitConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FruitConfig"))
local WeatherConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeatherConfig"))
local PotionConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PotionConfig"))
local FruitService = require(script.Parent:WaitForChild("FruitService"))

local ATTACK_RANGE = HeroConfig.Worker.AttackRange or 2.5 -- studs from the trunk's center at which a hero stops and chops
local MIN_SURFACE_GAP = 0.5 -- never stand closer than this to the trunk's surface (thick trunks)
local MOUND_GAP = HeroConfig.Worker.MoundGap or 0.4 -- studs between the dirt mound's edge and the hero
local RANGE_SLACK = 1.5 -- extra studs allowed when checking "still in range" before each swing
local STUCK_TIME = 1.5 -- seconds without progress before giving up on a walk
local GROUND_RAY_OFFSET = 2 -- raycast from just above the root so the gate's arch never counts as ground
local WALK_ANIM_SPEED = 14.5 -- walk speed the walk animation was made for
local RUN_ANIM_SPEED = HeroConfig.Worker.RunAnimSpeed or 16 -- same for the run animation
local RETARGET_PAUSE = 0.35
local RETREAT_SPEED_MULT = 1.6 -- heroes run back to the gate this much faster on a zone swap
local RETREAT_MAX_TIME = 3 -- seconds; a hero still outside by then just vanishes into the gate

local hiddenFolder = ServerStorage:FindFirstChild("HiddenHeroes")
if not hiddenFolder then
	hiddenFolder = Instance.new("Folder")
	hiddenFolder.Name = "HiddenHeroes"
	hiddenFolder.Parent = ServerStorage
end

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
	chops: { AnimationTrack }, -- swing animations, one picked at random per swing
	chopMults: { number }, -- damage multiplier of each swing in `chops` (the charged R15 swing hits harder)
	lastChop: number?,
	running: boolean?, -- tracks.Walk is the run animation (HeroModels.RunAnimationId)
	spawnCFrame: CFrame, -- where it spawned (the gate may have moved since; see gateSpawn)
	spread: number, -- sideways offset from HeroSpawn, so heroes don't stack
	exitOffset: Vector3, -- offset from HeroExit
	hidden: boolean, -- inside the gate during a zone swap
	movement: any,
	swings: number, -- swings so far (fruit skills that trigger "Every" N swings)
}

local HeroWorkerService = {}

local workersByPlot: { [Model]: { [number]: Worker } } = {}
local claims: { [Model]: number } = {} -- tree -> how many workers are after it
local rng = Random.new()

-- The pad's level for `stat` (1 when the pad or attribute is missing).
local function levelOf(plot: Model, slot: number, stat: string): number
	local slots = plot:FindFirstChild("HeroSlots")
	local model = slots and slots:FindFirstChild("Slot" .. slot)
	local level = model and model:GetAttribute(HeroConfig.LevelAttribute(stat))
	return if typeof(level) == "number" then level else 1
end

-- The pad's grade letter for `stat` (nil = HeroConfig.DefaultGrade).
local function gradeOf(plot: Model, slot: number, stat: string): string?
	local slots = plot:FindFirstChild("HeroSlots")
	local model = slots and slots:FindFirstChild("Slot" .. slot)
	local grade = model and model:GetAttribute(HeroConfig.GradeAttribute(stat))
	return if typeof(grade) == "string" then grade else nil
end

-- The axe the pad gives its hero (slot "HeroAxe"), or nil for the default axe.
local function axeOf(plot: Model, slot: number): string?
	local slots = plot:FindFirstChild("HeroSlots")
	local model = slots and slots:FindFirstChild("Slot" .. slot)
	local axe = model and model:GetAttribute("HeroAxe")
	return if typeof(axe) == "string" and ShopConfig.GetAxe(axe) then axe else nil
end

-- The Devil Fruit the pad gives its hero (slot "HeroFruit"), or nil.
local function fruitOf(plot: Model, slot: number): FruitConfig.FruitDef?
	local slots = plot:FindFirstChild("HeroSlots")
	local model = slots and slots:FindFirstChild("Slot" .. slot)
	local id = model and model:GetAttribute("HeroFruit")
	return if typeof(id) == "string" and id ~= "" then FruitConfig.Get(id) else nil
end

-- A pad stat with the fruit's multipliers on top (damage Boost, Skill Speed / Walk).
local function padStat(plot: Model, slot: number, hero: string, stat: string): number
	local value = HeroConfig.StatValue(stat, levelOf(plot, slot, stat), gradeOf(plot, slot, stat), hero)
	local fruit = fruitOf(plot, slot)
	if stat == "Damage" then
		local axe = axeOf(plot, slot)
		local def = axe and ShopConfig.GetAxe(axe)
		if def then
			value = math.max(1, math.floor(value * def.HeroBoost))
		end
		if fruit then
			value = math.max(1, math.floor(value * fruit.Boost))
		end
	elseif fruit and stat == "Speed" and fruit.Skill.Speed then
		value *= fruit.Skill.Speed
	elseif fruit and stat == "Walk" and fruit.Skill.Walk then
		value *= fruit.Skill.Walk
	end
	-- Weather buffs (WeatherConfig) and the owner's potions (PotionConfig): HeroDamage / HeroSpeed / HeroWalk.
	local weather = WeatherConfig.Mult("Hero" .. stat) * PotionConfig.MultForPlot(plot, "Hero" .. stat)
	if weather ~= 1 then
		value = if stat == "Damage" then math.max(1, math.floor(value * weather)) else value * weather
	end
	return value
end

local function statOf(w: Worker, stat: string): number
	return padStat(w.plot, w.slot, w.hero, stat)
end

-- HeroBar above the hero: "Level N" = the pad's Damage level, Power = the damage it really deals.
local function drawBarLevel(w: Worker)
	HeroModels.DrawBar(w.model, levelOf(w.plot, w.slot, "Damage"), statOf(w, "Damage"))
end

-- Where the hero is now. Read this instead of w.root.Position: while a hero walks, the server keeps its
-- position in Movement and only writes the real part when it stops.
local function posOf(w: Worker): Vector3
	return if w.movement then w.movement:GetPosition() else w.root.Position
end

local function isAlive(w: Worker): boolean
	return w.alive and w.model.Parent ~= nil and w.owner.Parent ~= nil and w.humanoid.Health > 0
end

local function zoneBusy(w: Worker): boolean
	return w.plot:GetAttribute("HeroesHold") == true
end

-- HeroSpawn / HeroExit as they are now (the HeroGate follows the floor's depth).
local function gateSpawn(w: Worker): CFrame
	local gate = w.plot:FindFirstChild("HeroGate")
	local part = gate and gate:FindFirstChild("HeroSpawn")
	if part and part:IsA("BasePart") then
		return part.CFrame * CFrame.new(w.spread, 0, 0)
	end
	return w.spawnCFrame
end

local function gateExit(w: Worker): Vector3?
	local gate = w.plot:FindFirstChild("HeroGate")
	local part = gate and gate:FindFirstChild("HeroExit")
	if part and part:IsA("BasePart") then
		return part.Position + w.exitOffset
	end
	return nil
end

local function treeAlive(tree: Model): boolean
	return tree.Parent ~= nil and not tree:GetAttribute("Dead") and (tree:GetAttribute("HP") or 0) > 0
end

-- "HeroTargets" on the tree = how many heroes are after it; clients draw the red target ring from it.
local function claim(tree: Model)
	claims[tree] = (claims[tree] or 0) + 1
	tree:SetAttribute("HeroTargets", claims[tree])
end

local function release(tree: Model?)
	if not tree or not claims[tree] then
		return
	end
	claims[tree] -= 1
	if claims[tree] <= 0 then
		claims[tree] = nil
	end
	if tree.Parent then
		tree:SetAttribute("HeroTargets", claims[tree])
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
		walk:AdjustSpeed(w.movement:GetSpeed() / (if w.running then RUN_ANIM_SPEED else WALK_ANIM_SPEED))
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
	-- The hero's own run (HeroConfig.Worker.RunAnimation) replaces the default walk when there is one.
	-- R6 heroes use RunAnimation, R15 heroes RunAnimationR15.
	local run = HeroModels.RunAnimationId(w.humanoid)
	local runTrack = run and HeroModels.LoadTrack(w.humanoid, run, Enum.AnimationPriority.Movement, true)
	w.running = runTrack ~= nil
	w.tracks.Walk = runTrack or load(set.Walk, Enum.AnimationPriority.Movement, true)
	w.tracks.Hold = load(set.Hold, Enum.AnimationPriority.Action, true)
	w.chops = {}
	w.chopMults = {}
	local ids, mults = HeroModels.ChopAnimationIds(w.humanoid)
	for i, id in ids do
		local track = HeroModels.LoadTrack(w.humanoid, id, Enum.AnimationPriority.Action2, false)
		if track then
			table.insert(w.chops, track)
			table.insert(w.chopMults, mults[i] or 1)
		end
	end
	w.tracks.Chop = w.chops[1]
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

	local lastPos, lastMove = posOf(w), os.clock()
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
		local p = posOf(w)
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
	return Vector3.new(center.X, posOf(w).Y, center.Z), radius
end

-- Body size multiplier of a hero from its size (HeroConfig.Sizes Scale; 1 = Normal).
local function sizeScale(heroName: string): number
	local def = HeroConfig.Get(heroName)
	return if def and def.Scale then def.Scale else 1
end

-- Extra studs a bigger hero keeps from the trunk (HeroConfig.Worker.SizeReach per +1 Scale).
local function reachOf(w: Worker): number
	return math.max(0, sizeScale(w.hero) - 1) * (HeroConfig.Worker.SizeReach or 0)
end

-- How far from the trunk's center the hero stands to chop, coming from `from`: just outside the
-- tree's dirt mound ("Ground" model) on that side, so it never stands inside the roots; trees without
-- a mound use the trunk radius.
local function attackRange(tree: Model, center: Vector3, radius: number, from: Vector3, reach: number?): number
	local range = math.max(ATTACK_RANGE, radius + MIN_SURFACE_GAP)
	local ground = tree:FindFirstChild("Ground")
	if ground and ground:IsA("Model") then
		local cf, size = ground:GetBoundingBox()
		local a, b = size.X / 2, size.Z / 2
		-- Direction to the hero in the mound's own axes, then the edge of the ellipse that way.
		local d = cf:VectorToObjectSpace(Vector3.new(from.X - center.X, 0, from.Z - center.Z))
		local flat = Vector2.new(d.X, d.Z)
		if flat.Magnitude > 0.05 and a > 0 and b > 0 then
			local u = flat.Unit
			local edge = 1 / math.sqrt((u.X / a) ^ 2 + (u.Y / b) ^ 2)
			range = math.max(range, edge + MOUND_GAP)
		else
			range = math.max(range, math.max(a, b) + MOUND_GAP)
		end
	end
	return range + (reach or 0)
end

local function flatDir(from: Vector3, to: Vector3): Vector3
	local d = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	return if d.Magnitude > 0.05 then d.Unit else Vector3.new(0, 0, 1)
end

local function flatDist(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- Devil Fruit skills -------------------------------------------------------------------------------

local function fx(kind: string, pos: Vector3, radius: number?, tree: Model?, hero: Model?)
	FruitService.FXRemote:FireAllClients(kind, pos, radius, tree, hero)
end

-- Does the fruit's skill trigger on this swing?
local function skillTriggers(w: Worker, skill: FruitConfig.Skill): boolean
	if skill.Every then
		return w.swings % skill.Every == 0
	end
	if skill.Chance then
		return rng:NextNumber() < skill.Chance
	end
	return false
end

-- Every other living tree of the plot within `radius` studs of `center` takes `damage`.
local function splash(w: Worker, target: Model, center: Vector3, radius: number, damage: number)
	for _, other in TreeService.GetTrees(w.plot) do
		if other ~= target and treeAlive(other) then
			local pos = other:GetPivot().Position
			if flatDist(pos, center) <= radius then
				TreeHitService.HeroHit(w.owner, posOf(w), other, damage, pos + Vector3.new(0, 2, 0))
			end
		end
	end
end

-- The tree burns: `damage` every second until `duration` runs out (refreshed by new burns). The
-- ticks come from TreeService's single upkeep scan, not a loop per tree.
local function burn(w: Worker, tree: Model, damage: number, duration: number, kind: string)
	TreeService.Burn(tree, duration, function(t: Model)
		if not w.owner.Parent or not treeAlive(t) then
			return
		end
		local pos = t:GetPivot().Position + Vector3.new(0, 2, 0)
		fx(kind .. "Tick", pos, nil, t)
		TreeHitService.HeroHit(w.owner, posOf(w), t, damage, pos)
	end)
end

-- One swing. Returns true when this swing felled the tree.
local function swing(w: Worker, tree: Model, center: Vector3, radius: number): boolean
	-- A random swing, never the same one twice in a row (so it doesn't look repetitive).
	local track: AnimationTrack? = nil
	local damageMult = 1
	local count = #w.chops
	if count > 0 then
		local pick = math.random(1, count)
		if count > 1 and pick == w.lastChop then
			pick = pick % count + 1
		end
		w.lastChop = pick
		track = w.chops[pick]
		damageMult = w.chopMults[pick] or 1
	end
	local speed = statOf(w, "Speed")
	local length = (if track and track.Length > 0 then track.Length else 0.8) / speed
	local hitAt = length * (if track and track.Length > 0 then (HeroConfig.Worker.HitFraction or 0.9) else 0.9)
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
	while not landed and os.clock() - start < hitAt and isAlive(w) do
		task.wait()
	end
	if conn then
		conn:Disconnect()
	end
	if not isAlive(w) or not treeAlive(tree) then
		return false
	end

	local dir = flatDir(center, posOf(w))
	local hitPos = center + dir * radius + Vector3.new(0, 0.5, 0)
	local damage = statOf(w, "Damage")
	if damageMult ~= 1 then
		damage = math.floor(damage * damageMult + 0.5)
	end
	-- Devil Fruit skill.
	w.swings += 1
	local fruit = fruitOf(w.plot, w.slot)
	local skill = fruit and fruit.Skill
	local triggered = skill ~= nil and skillTriggers(w, skill)
	local baseDamage = damage
	if triggered and skill and skill.Mult then
		damage = math.floor(damage * skill.Mult + 0.5)
	end
	local felled = TreeHitService.HeroHit(w.owner, posOf(w), tree, damage, hitPos)
	-- Always-on skills (only Speed / Walk, e.g. Smoke) still show off now and then.
	if skill and not skill.Chance and not skill.Every and w.swings % 8 == 0 then
		fx(skill.FX, hitPos, nil, tree, w.model)
	end
	if triggered and skill then
		fx(skill.FX, hitPos, skill.Radius, tree, w.model)
		for _ = 1, skill.Hits or 0 do
			if felled or not treeAlive(tree) then
				break
			end
			felled = TreeHitService.HeroHit(w.owner, posOf(w), tree, baseDamage, hitPos)
		end
		if skill.Radius and skill.Share then
			splash(w, tree, center, skill.Radius, math.max(1, math.floor(damage * skill.Share)))
		end
		if skill.BurnShare and skill.BurnTime and not felled then
			burn(w, tree, math.max(1, math.floor(baseDamage * skill.BurnShare)), skill.BurnTime, skill.FX)
		end
	end

	local rest = length - (os.clock() - start)
	if rest > 0 then
		task.wait(rest)
	end
	task.wait(HeroConfig.Worker.SwingCooldown)
	return felled
end

-- Zone swaps -------------------------------------------------------------------------------------

local function countOutside(plot: Model)
	local n = 0
	for _, w in workersByPlot[plot] or {} do
		if w.alive and not w.hidden then
			n += 1
		end
	end
	plot:SetAttribute("HeroesOutside", n)
end

local function workersFolder(plot: Model): Folder
	local folder = plot:FindFirstChild("HeroWorkers")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "HeroWorkers"
		folder.Parent = plot
	end
	return folder :: Folder
end

local retreat: (w: Worker) -> ()

-- Walks from the gate's spawn point out to its exit.
local function walkOut(w: Worker)
	local exit = gateExit(w)
	if exit and isAlive(w) then
		walkTo(w, exit, 1, function()
			return zoneBusy(w)
		end)
	end
end

-- Runs back into the gate, hides until the zone swap is over, then walks back out.
retreat = function(w: Worker)
	release(w.target)
	w.target = nil
	for _, track in w.chops do
		track:Stop(0.1)
	end

	if not w.hidden then
		local speed = w.movement and w.movement:GetSpeed()
		if w.movement then
			w.movement:SetSpeed(speed * RETREAT_SPEED_MULT)
		end
		local start = os.clock()
		walkTo(w, gateSpawn(w).Position, 1.5, function()
			return os.clock() - start > RETREAT_MAX_TIME or not zoneBusy(w)
		end)
		if w.movement then
			w.movement:SetSpeed(speed)
		end
		if not isAlive(w) or not zoneBusy(w) then
			return -- gone, or the swap was over before the hero got home: just carry on
		end
		w.hidden = true
		w.model.Parent = hiddenFolder
		countOutside(w.plot)
	end

	while w.alive and w.model.Parent ~= nil and zoneBusy(w) do
		task.wait(0.1)
	end
	if not w.alive or w.model.Parent == nil then
		return
	end

	-- Out of the gate again, at its new height.
	w.model:PivotTo(gateSpawn(w))
	w.model.Parent = workersFolder(w.plot)
	w.hidden = false
	if w.movement then
		w.movement:Resync() -- the model was just placed at the gate: clients put it there at once
	end
	countOutside(w.plot)
	walkOut(w)
end

-- Main loop --------------------------------------------------------------------------------------

local function run(w: Worker)
	-- Wait for the swing animation so its length (and markers) are known.
	local t0 = os.clock()
	local function loading(): boolean
		for _, t in w.chops do
			if t.Length == 0 then
				return true
			end
		end
		return false
	end
	while loading() and os.clock() - t0 < 3 do
		task.wait(0.1)
	end

	if zoneBusy(w) then
		retreat(w) -- spawned during a zone swap: wait inside the gate
	else
		walkOut(w)
	end

	while isAlive(w) do
		if zoneBusy(w) then
			retreat(w)
			continue
		end

		-- Fell off the map somehow: back to the gate.
		if posOf(w).Y < gateSpawn(w).Position.Y - 40 then
			w.model:PivotTo(gateSpawn(w))
			w.movement:Resync()
		end

		local tree = pickTree(w)
		if not tree then
			task.wait(0.25)
			continue
		end
		claim(tree)
		w.target = tree

		local center, radius = trunkOf(w, tree)
		local range = attackRange(tree, center, radius, posOf(w), reachOf(w))
		walkTo(w, center, range, function()
			return not treeAlive(tree) or zoneBusy(w)
		end)

		center, radius = trunkOf(w, tree)
		range = attackRange(tree, center, radius, posOf(w), reachOf(w))
		if isAlive(w) and treeAlive(tree) and not zoneBusy(w) and flatDist(posOf(w), center) <= range + RANGE_SLACK then
			while isAlive(w) and treeAlive(tree) and not zoneBusy(w) do
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
	countOutside(plot)
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

-- The pad's levels changed: new walk speed and HeroBar level now (damage / swing speed apply on the
-- next swing by themselves).
function HeroWorkerService.ApplyLevels(plot: Model, slot: number)
	local list = workersByPlot[plot]
	local w = list and list[slot]
	if not w or not w.alive then
		return
	end
	if w.movement then
		w.movement:SetSpeed(statOf(w, "Walk"))
		if w.movement:IsMoving() then
			setWalking(w, true) -- walk animation speed follows
		end
	end
	drawBarLevel(w)
	-- The pad's axe changed: swap the one in the hero's hands.
	local want = axeOf(plot, slot)
	if w.model:GetAttribute("Axe") ~= want then
		w.model:SetAttribute("Axe", want)
		for _, child in w.model:GetChildren() do
			if child:IsA("Tool") and child:GetAttribute("HeroAxe") then
				child:Destroy()
			end
		end
		HeroModels.GiveAxe(w.model, w.humanoid, w.model:GetAttribute("AxeScale") :: number?, want)
	end
end

-- Every working hero picks up new numbers now (weather started / ended: walk speed, HeroBar power).
function HeroWorkerService.ApplyAll()
	for plot, list in workersByPlot do
		for slot in list do
			HeroWorkerService.ApplyLevels(plot, slot)
		end
	end
end

function HeroWorkerService.Spawn(plot: Model, slot: number, heroName: string, owner: Player): Model?
	HeroWorkerService.Despawn(plot, slot)

	local model, humanoid, root = HeroModels.Clone(heroName)
	if not model or not humanoid or not root then
		return nil
	end
	model.Name = "Slot" .. slot
	-- Body = HeightRatio x the owner's body (the template keeps its catalog size; only this copy is
	-- scaled). The axe is scaled by the same factor so it stays in proportion.
	-- Bigger sizes (HeroConfig.Sizes Scale) multiply that height.
	local axeScale = HeroModels.ScaleToHeight(model, HeroModels.PlayerBodyHeight(owner) * (HeroConfig.Worker.HeightRatio or 0.5) * sizeScale(heroName))
	model:SetAttribute("AxeScale", axeScale)
	model:SetAttribute("OwnerUserId", owner.UserId)
	model:SetAttribute("Slot", slot)

	local gate = plot:FindFirstChild("HeroGate")
	local spawnPart = gate and gate:FindFirstChild("HeroSpawn") :: BasePart?
	local spawnCFrame = if spawnPart then spawnPart.CFrame else plot:GetPivot() + Vector3.new(0, 5, 0)
	-- Spread heroes a little so they don't all pop out of the exact same spot.
	local spread = rng:NextNumber(-2, 2)
	spawnCFrame *= CFrame.new(spread, 0, 0)
	model:PivotTo(spawnCFrame)
	model.Parent = workersFolder(plot)
	pcall(root.SetNetworkOwner, root, nil)

	local axe = axeOf(plot, slot)
	model:SetAttribute("Axe", axe)
	HeroModels.GiveAxe(model, humanoid, axeScale, axe)

	-- Anchors the root and snaps it onto the ground now; clients draw the walking (ClientRendered).
	local movement = Movement.new(model, {
		ClientRendered = true,
		Speed = padStat(plot, slot, heroName, "Walk"),
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
		chops = {},
		chopMults = {},
		spawnCFrame = spawnCFrame,
		spread = spread,
		exitOffset = Vector3.new(rng:NextNumber(-3, 3), 0, rng:NextNumber(-1, 3)),
		hidden = false,
		movement = movement,
		swings = 0,
	}
	setupAnimations(w)
	drawBarLevel(w)

	workersByPlot[plot] = workersByPlot[plot] or {}
	workersByPlot[plot][slot] = w
	countOutside(plot)

	model.Destroying:Connect(function()
		w.alive = false
		stopMovement(w)
	end)
	task.spawn(run, w)
	return model
end

return HeroWorkerService
