-- ZoneTransitionFX: animates zone changes on every plot from the attributes ZoneService sets.
--   ZoneOutAt / ZoneOutTime    old trees + decor sink into the floor and fade (wave from the center out)
--   FloorMoveAt / FloorMoveTime / FloorFromY / FloorToY / FloorToColor
--                              the floor (and FollowFloor children like HeroGate) glide to the new depth
--   ZoneInAt / ZoneInTime      new decor and trees rise out of the floor (decor first, then trees)
-- Everything here is visual and local; the server already holds the real positions, and each animation
-- ends exactly on them.

local RunService = game:GetService("RunService")

local Plots = workspace:WaitForChild("Plots")

local FOLDERS = { ChopGround = "decor", ZoneMap = "decor", TreeSpawns = "tree" }

-- Share of the phase time used to spread items out (the rest is each item's own animation).
local OUT_STAGGER = 0.5
local IN_DECOR_STAGGER, IN_DECOR_TIME = 0.55, 0.6
local IN_TREE_DELAY, IN_TREE_STAGGER, IN_TREE_TIME = 0.15, 0.45, 0.7
local MAX_DECOR_SINK = 6
local TREE_TWIST = math.rad(50)

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

-- Easing ---------------------------------------------------------------------------------------

local function smooth(t: number): number
	return t * t * (3 - 2 * t)
end

local function backOut(t: number): number
	local c1 = 1.4
	local c3 = c1 + 1
	local u = t - 1
	return 1 + c3 * u * u * u + c1 * u * u
end

local function quadIn(t: number): number
	return t * t
end

-- Item animations (decor pieces and trees) -----------------------------------------------------

type PartState = { part: BasePart, cf: CFrame, t: number }
type DecalState = { inst: Instance, t: number }
type Anim = {
	inst: Instance,
	isTree: boolean,
	parts: { PartState },
	decals: { DecalState },
	pivot: CFrame,
	sink: number,
	twist: number,
	minY: number,
	maxY: number,
	mode: "in" | "out",
	start: number, -- os.clock() when this item starts moving
	duration: number,
	conn: RBXScriptConnection?,
}

local anims: { [Instance]: Anim } = {}

-- Height and base point come from the parts collected so far: with StreamingEnabled a model can
-- arrive before its parts, so this is updated as they come in.
local function measure(a: Anim, part: BasePart, cf: CFrame)
	local half = part.Size.Y / 2
	a.minY = math.min(a.minY, cf.Position.Y - half)
	a.maxY = math.max(a.maxY, cf.Position.Y + half)
	local height = a.maxY - a.minY
	a.sink = if a.isTree then height * 0.95 else math.min(height + 0.5, MAX_DECOR_SINK)
	local p = a.pivot.Position
	a.pivot = CFrame.new(p.X, a.minY, p.Z)
end

local function addDescendant(a: Anim, d: Instance)
	if d:IsA("BasePart") then
		local cf = d.CFrame
		table.insert(a.parts, { part = d, cf = cf, t = d.Transparency })
		measure(a, d, cf)
	elseif d:IsA("Decal") or d:IsA("Texture") then
		table.insert(a.decals, { inst = d, t = (d :: any).Transparency })
	end
end

local function getAnim(inst: Instance, isTree: boolean): Anim?
	local a = anims[inst]
	if a then
		return a
	end
	if not (inst:IsA("Model") or inst:IsA("BasePart")) then
		return nil
	end
	local pivot = (inst :: PVInstance):GetPivot()
	a = {
		inst = inst,
		isTree = isTree,
		parts = {},
		decals = {},
		pivot = pivot,
		sink = 0,
		twist = if isTree then TREE_TWIST else 0,
		minY = math.huge,
		maxY = -math.huge,
		mode = "in",
		start = 0,
		duration = 1,
	}
	addDescendant(a, inst)
	for _, d in inst:GetDescendants() do
		addDescendant(a, d)
	end
	-- Parts that stream in mid-animation join it from their real spot.
	a.conn = inst.DescendantAdded:Connect(function(d)
		addDescendant(a, d)
	end)
	anims[inst] = a
	return a
end

local function stopAnim(a: Anim)
	if a.conn then
		a.conn:Disconnect()
	end
	anims[a.inst] = nil
end

-- progress 0 = hidden in the floor, 1 = in place.
local function pose(a: Anim, progress: number, visible: number)
	local offset = -(1 - progress) * a.sink
	local twist = (1 - progress) * a.twist
	local delta = CFrame.new(0, offset, 0)
	if twist ~= 0 then
		delta = delta * (a.pivot * CFrame.Angles(0, twist, 0) * a.pivot:Inverse())
	end
	local parts, cframes = table.create(#a.parts), table.create(#a.parts)
	for _, s in a.parts do
		if s.part.Parent then
			table.insert(parts, s.part)
			table.insert(cframes, delta * s.cf)
			s.part.Transparency = 1 - (1 - s.t) * visible
		end
	end
	if #parts > 0 then
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
	for _, s in a.decals do
		if s.inst.Parent then
			(s.inst :: any).Transparency = 1 - (1 - s.t) * visible
		end
	end
end

local function step(a: Anim, now: number)
	if not a.inst.Parent then
		stopAnim(a)
		return
	end
	local t = math.clamp((now - a.start) / a.duration, 0, 1)
	if a.mode == "in" then
		pose(a, backOut(t), math.clamp(t * 2, 0, 1))
		if t >= 1 then
			pose(a, 1, 1)
			stopAnim(a)
		end
	else
		pose(a, 1 - quadIn(t), 1 - t)
		-- Stays hidden until the server removes it.
	end
end

local function startAnim(inst: Instance, isTree: boolean, mode: "in" | "out", start: number, duration: number)
	local a = getAnim(inst, isTree)
	if not a then
		return
	end
	a.mode = mode
	a.start = start
	a.duration = duration
	step(a, os.clock())
end

-- Center of the plot's floor, and how far its corners are, for the wave delay.
local function waveDelay(plot: Instance, inst: Instance, stagger: number): number
	local ground = plot:FindFirstChild("Floor") and plot.Floor:FindFirstChild("Ground")
	if not ground then
		return 0
	end
	local pos = if inst:IsA("Model") then inst:GetPivot().Position else (inst :: BasePart).Position
	local d = Vector2.new(pos.X - ground.Position.X, pos.Z - ground.Position.Z).Magnitude
	local maxD = Vector2.new(ground.Size.X, ground.Size.Z).Magnitude / 2
	return math.clamp(d / maxD, 0, 1) * stagger
end

-- Calls fn for each animatable item under a container (folders are opened up).
local function eachItem(container: Instance, fn: (Instance) -> ())
	for _, child in container:GetChildren() do
		if child:IsA("Folder") then
			eachItem(child, fn)
		elseif child:IsA("Model") or child:IsA("BasePart") then
			fn(child)
		end
	end
end

-- Seconds since a server timestamp attribute, or nil.
local function since(plot: Instance, attr: string): number?
	local at = plot:GetAttribute(attr)
	if typeof(at) ~= "number" then
		return nil
	end
	return serverNow() - at
end

-- Out phase ------------------------------------------------------------------------------------

local function playOut(plot: Instance)
	local elapsed = since(plot, "ZoneOutAt")
	local total = plot:GetAttribute("ZoneOutTime") or 0.9
	if not elapsed or elapsed > total then
		return
	end
	local begin = os.clock() - elapsed
	local stagger = total * OUT_STAGGER
	local duration = total - stagger
	for name, kind in FOLDERS do
		local folder = plot:FindFirstChild(name)
		if folder then
			eachItem(folder, function(item)
				startAnim(item, kind == "tree", "out", begin + waveDelay(plot, item, stagger), duration)
			end)
		end
	end
end

-- In phase: items that show up while the plot's "In" window is open rise out of the floor ---------

local function onItemAdded(plot: Instance, item: Instance, kind: string)
	local elapsed = since(plot, "ZoneInAt")
	local window = (plot:GetAttribute("ZoneInTime") or 1.6) + 1
	if not elapsed or elapsed > window then
		return
	end
	local begin = os.clock() - elapsed
	if kind == "tree" then
		startAnim(item, true, "in", begin + IN_TREE_DELAY + waveDelay(plot, item, IN_TREE_STAGGER), IN_TREE_TIME)
	else
		startAnim(item, false, "in", begin + waveDelay(plot, item, IN_DECOR_STAGGER), IN_DECOR_TIME)
	end
end

local function watchContainer(plot: Instance, container: Instance, kind: string)
	container.ChildAdded:Connect(function(child)
		if child:IsA("Folder") then
			watchContainer(plot, child, kind)
			eachItem(child, function(item)
				onItemAdded(plot, item, kind)
			end)
		elseif child:IsA("Model") or child:IsA("BasePart") then
			onItemAdded(plot, child, kind)
		end
	end)
	for _, child in container:GetChildren() do
		if child:IsA("Folder") then
			watchContainer(plot, child, kind)
		end
	end
end

-- Floor glide ------------------------------------------------------------------------------------

type FloorMove = {
	plot: Instance,
	ground: BasePart,
	baseCF: CFrame, -- ground CFrame with its Y set to 0
	fromY: number,
	toY: number,
	fromColor: Color3,
	toColor: Color3,
	followers: { [PVInstance]: CFrame }, -- pivot when the floor is at fromY
	start: number,
	duration: number,
}

local floorMoves: { [Instance]: FloorMove } = {}

local function playFloor(plot: Instance)
	local elapsed = since(plot, "FloorMoveAt")
	local duration = plot:GetAttribute("FloorMoveTime")
	local fromY, toY = plot:GetAttribute("FloorFromY"), plot:GetAttribute("FloorToY")
	local ground = plot:FindFirstChild("Floor") and plot.Floor:FindFirstChild("Ground")
	if not elapsed or typeof(duration) ~= "number" or elapsed > duration or typeof(fromY) ~= "number"
		or typeof(toY) ~= "number" or not ground then
		return
	end
	local cf = ground.CFrame
	local nowY = cf.Position.Y
	local followers = {}
	for _, child in plot:GetChildren() do
		if child:GetAttribute("FollowFloor") and child:IsA("PVInstance") then
			followers[child] = child:GetPivot() + Vector3.new(0, fromY - nowY, 0)
		end
	end
	local toColor = plot:GetAttribute("FloorToColor")
	floorMoves[plot] = {
		plot = plot,
		ground = ground,
		baseCF = cf - Vector3.new(0, nowY, 0),
		fromY = fromY,
		toY = toY,
		fromColor = ground.Color,
		toColor = if typeof(toColor) == "Color3" then toColor else ground.Color,
		followers = followers,
		start = os.clock() - elapsed,
		duration = duration,
	}
end

local function stepFloor(m: FloorMove, now: number)
	if not m.ground.Parent then
		floorMoves[m.plot] = nil
		return
	end
	local t = math.clamp((now - m.start) / m.duration, 0, 1)
	local e = smooth(t)
	local y = m.fromY + (m.toY - m.fromY) * e
	m.ground.CFrame = m.baseCF + Vector3.new(0, y, 0)
	m.ground.Color = m.fromColor:Lerp(m.toColor, e)
	for inst, pivot in m.followers do
		if inst.Parent then
			inst:PivotTo(pivot + Vector3.new(0, y - m.fromY, 0))
		end
	end
	if t >= 1 then
		floorMoves[m.plot] = nil
	end
end

-- Wiring -----------------------------------------------------------------------------------------

local function hookPlot(plot: Instance)
	plot:GetAttributeChangedSignal("ZoneOutAt"):Connect(function()
		playOut(plot)
	end)
	plot:GetAttributeChangedSignal("FloorMoveAt"):Connect(function()
		playFloor(plot)
	end)
	local function hookFolder(child: Instance)
		local kind = FOLDERS[child.Name]
		if kind then
			watchContainer(plot, child, kind)
		end
	end
	plot.ChildAdded:Connect(hookFolder)
	for _, child in plot:GetChildren() do
		hookFolder(child)
	end
end

for _, plot in Plots:GetChildren() do
	hookPlot(plot)
end
Plots.ChildAdded:Connect(hookPlot)

local function update()
	local now = os.clock()
	for _, m in floorMoves do
		stepFloor(m, now)
	end
	for _, a in anims do
		step(a, now)
	end
end

-- Before rendering and before physics, so players standing on the floor ride it down smoothly.
RunService.RenderStepped:Connect(update)
RunService.Stepped:Connect(update)
