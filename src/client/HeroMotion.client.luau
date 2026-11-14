-- HeroMotion: draws the walking of server-driven models (heroes) on this client, every frame.
--
-- The server (Movement with ClientRendered = true) no longer moves these models each Heartbeat: a part
-- moved that way only reaches clients at the network rate with no interpolation, which looked choppy.
-- Instead it tags the model "ClientMoved" and publishes its path as attributes:
--   MoveRest   CFrame   root CFrame when the path was published (where it stands when not walking)
--   MoveTarget Vector3? walking straight to this point (nil = standing at MoveRest)
--   MoveStop   number   stops this many studs (flat) before MoveTarget
--   MoveSpeed  number   studs / second
--   MoveTime   number   server time (workspace:GetServerTimeNow) the path started
--   MoveSeq    number   written last; bumps on every publish
--   MoveSnap   number   = MoveSeq when the model must be placed at once (teleport), not slid there
--   MoveStand  number   root centre -> feet, for standing on the ground
-- Every client plays the same path against the server clock, so all players see every hero in the same
-- place, at their own frame rate. Whatever differs from the server (ping, a changed path) is kept as an
-- offset that fades out, so heroes never pop.
-- Ground height comes from a raycast on the plot's Floor / Gate, like the server's Movement.
-- Zone swap: while the plot's floor moves (ZoneLift, drawn by ZoneTransitionFX), heroes standing on it are
-- drawn exactly on its top every frame, so they ride it without hovering or sinking.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local ZoneLift = require(script.Parent:WaitForChild("ZoneLift"))

local TAG = "ClientMoved"
local GROUND_NAMES = { "Floor", "Gate" } -- same as HeroWorkerService groundOf
local RAY_UP = 2 -- same as HeroWorkerService GROUND_RAY_OFFSET (stay under the gate's arch)
local RAY_DOWN = 60
local MIN_GROUND_NORMAL_Y = 0.5
local ERROR_RATE = 8 -- how fast the offset from the server's path fades (1/s)
local ROTATION_RATE = 15 -- same as Movement DEFAULT_ROTATION_SPEED
local HEIGHT_RATE = 25 -- how fast the height follows the ground (1/s)
local SNAP_DISTANCE = 12 -- further than this from the server's path: place the model at once

type State = {
	model: Model,
	root: BasePart,
	conn: RBXScriptConnection?,
	ready: boolean, -- has read a path at least once
	settled: boolean, -- standing exactly at rest: nothing to draw
	rest: CFrame,
	from: Vector3,
	dir: Vector3?, -- flat unit direction of the walk (nil = standing)
	look: CFrame, -- rotation facing `dir`
	length: number, -- studs to walk along `dir`
	speed: number,
	t0: number,
	stand: number,
	err: Vector3, -- flat offset of what is drawn from the server's path; fades out
	pos: Vector3, -- what is drawn
	rot: CFrame,
	params: RaycastParams?,
	ground: { Instance },
}

local states: { [Model]: State } = {}

-- The plot parts heroes walk on (model = plot.HeroWorkers.Slot<n>).
local function refreshGround(s: State)
	for _, inst in s.ground do
		if inst.Parent == nil then
			s.params = nil -- the floor was replaced
			break
		end
	end
	if s.params then
		return
	end
	local folder = s.model.Parent
	local plot = folder and folder.Parent
	local list = {}
	if plot then
		for _, name in GROUND_NAMES do
			local inst = plot:FindFirstChild(name)
			if inst then
				table.insert(list, inst)
			end
		end
	end
	s.ground = list
	if #list > 0 then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = list
		s.params = params
	end
end

-- Where the server's path is at server time `now` (flat; Y is not meaningful while walking).
local function idealAt(s: State, now: number): Vector3
	local dir = s.dir
	if not dir then
		return s.from
	end
	return s.from + dir * math.clamp((now - s.t0) * s.speed, 0, s.length)
end

local function read(s: State)
	local model = s.model
	local rest = model:GetAttribute("MoveRest")
	if typeof(rest) ~= "CFrame" then
		return
	end
	local target = model:GetAttribute("MoveTarget")
	local stop = model:GetAttribute("MoveStop")
	local speed = model:GetAttribute("MoveSpeed")
	local t0 = model:GetAttribute("MoveTime")
	local stand = model:GetAttribute("MoveStand")
	local now = workspace:GetServerTimeNow()

	s.rest = rest
	s.from = rest.Position
	s.dir = nil
	s.length = 0
	if typeof(stand) == "number" then
		s.stand = stand
	end
	if typeof(target) == "Vector3" and typeof(speed) == "number" and speed > 0 then
		local flat = Vector3.new(target.X - s.from.X, 0, target.Z - s.from.Z)
		local dist = flat.Magnitude
		local stopAt = if typeof(stop) == "number" then stop else 0
		if dist > stopAt + 0.05 then -- same test as Movement:Update
			s.dir = flat.Unit
			s.look = CFrame.lookAt(Vector3.zero, flat)
			s.length = dist - stopAt
			s.speed = speed
			s.t0 = if typeof(t0) == "number" then t0 else now
		end
	end
	refreshGround(s)

	local ideal = idealAt(s, now)
	local err = Vector3.new(s.pos.X - ideal.X, 0, s.pos.Z - ideal.Z)
	local snap = model:GetAttribute("MoveSnap") == model:GetAttribute("MoveSeq")
	if snap or not s.ready or err.Magnitude > SNAP_DISTANCE then
		err = Vector3.zero
		s.pos = Vector3.new(ideal.X, rest.Position.Y, ideal.Z)
		s.rot = if s.dir then s.look else rest.Rotation
	end
	s.err = err
	s.ready = true
	s.settled = false
end

local function step(s: State, dt: number, now: number)
	if not s.ready then
		return
	end
	local root = s.root
	if root.Parent == nil then
		-- StreamingEnabled: the root streamed out. When it streams back in it is a new part, sitting
		-- where the server last wrote it: adopt it and draw it again.
		local again = s.model:FindFirstChild("HumanoidRootPart")
		if not again or not again:IsA("BasePart") then
			return
		end
		root = again
		s.root = again
		s.settled = false
	end
	local folder = s.model.Parent
	local plot = folder and folder.Parent
	local lifting = ZoneLift.IsLifting(plot)
	if lifting then
		s.settled = false
	end
	if s.settled then
		return
	end

	local ideal = idealAt(s, now)
	s.err *= math.exp(-ERROR_RATE * dt)
	local x, z = ideal.X + s.err.X, ideal.Z + s.err.Z
	local y = s.pos.Y

	if lifting then
		local top = ZoneLift.FloorTopAt(plot, Vector3.new(x, y, z), os.clock())
		if top then
			-- Glued to the floor that is drawn this frame; turning still eases.
			s.pos = Vector3.new(x, top + s.stand, z)
			s.rot = s.rot:Lerp(if s.dir then s.look else s.rest.Rotation, math.min(1, ROTATION_RATE * dt))
			root.CFrame = CFrame.new(s.pos) * s.rot
			return
		end
	end

	local goalY, goalRot = y, s.rot
	if s.dir then
		goalRot = s.look
		if s.params then
			local hit = workspace:Raycast(Vector3.new(x, y + RAY_UP, z), Vector3.new(0, -RAY_DOWN, 0), s.params)
			if hit and hit.Normal.Y > MIN_GROUND_NORMAL_Y then
				goalY = hit.Position.Y + s.stand
			end
		end
	else
		goalRot = s.rest.Rotation
		goalY = s.rest.Position.Y
	end

	y += (goalY - y) * math.min(1, HEIGHT_RATE * dt)
	s.rot = s.rot:Lerp(goalRot, math.min(1, ROTATION_RATE * dt))
	s.pos = Vector3.new(x, y, z)

	-- Standing and caught up with the server: draw the exact rest CFrame once, then stop working.
	if
		not s.dir
		and s.err.Magnitude < 0.01
		and math.abs(goalY - y) < 0.01
		and s.rot.LookVector:Dot(goalRot.LookVector) > 0.9999
	then
		s.pos = s.rest.Position
		s.rot = s.rest.Rotation
		s.err = Vector3.zero
		s.settled = true
	end

	-- The root is anchored and the body hangs off it by Motor6Ds, so the whole hero follows.
	root.CFrame = CFrame.new(s.pos) * s.rot
end

local function untrack(model: Instance)
	local s = states[model :: Model]
	if s then
		states[model :: Model] = nil
		if s.conn then
			s.conn:Disconnect()
		end
	end
end

local function track(model: Instance)
	if not model:IsA("Model") or states[model] or not model:IsDescendantOf(workspace) then
		return
	end
	local root = model:WaitForChild("HumanoidRootPart", 10)
	if not root or not root:IsA("BasePart") or states[model] or not CollectionService:HasTag(model, TAG) then
		return
	end
	if not model:IsDescendantOf(workspace) then
		return
	end
	local s: State = {
		model = model,
		root = root,
		ready = false,
		settled = false,
		rest = root.CFrame,
		from = root.Position,
		dir = nil,
		look = root.CFrame.Rotation,
		length = 0,
		speed = 0,
		t0 = 0,
		stand = root.Size.Y / 2,
		err = Vector3.zero,
		pos = root.Position,
		rot = root.CFrame.Rotation,
		params = nil,
		ground = {},
	}
	states[model] = s
	s.conn = model:GetAttributeChangedSignal("MoveSeq"):Connect(function()
		read(s)
	end)
	read(s)
end

CollectionService:GetInstanceAddedSignal(TAG):Connect(function(model)
	task.spawn(track, model)
end)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(untrack)
for _, model in CollectionService:GetTagged(TAG) do
	task.spawn(track, model)
end

-- Before each frame is drawn (animations are applied on top of the root afterwards).
RunService.PreRender:Connect(function(dt)
	local now = workspace:GetServerTimeNow()
	for _, s in states do
		step(s, dt, now)
	end
end)
