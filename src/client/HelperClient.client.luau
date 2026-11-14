-- HelperClient: draws the Farm Stand helpers walking between the chest and the stand. The server
-- (StandService) only runs timers and sends each leg: Remotes.StandEvent
--   ("HelperLeg", site, index, points, duration, carried)   walk `points` in `duration` seconds;
--                                                          carried > 0 = holding a crate
--   ("HelperIdle", site, index)                            back on the pad
--   ("HelperDrop", site, index, amount)                    "+N" at the stand
-- The walker is a local copy of the idle hero standing on the helper pad (PadHero), so it looks the
-- same. The pad copy stays standing idle on the pad the whole time; the walker shows its own bar
-- (name, "Helper" / "Carrying N"). One walker per pad, reused for every leg (no new models per trip).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local standEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("StandEvent") :: RemoteEvent

local WALK = {
	[Enum.HumanoidRigType.R6] = "rbxassetid://180426354",
	[Enum.HumanoidRigType.R15] = "rbxassetid://913402848",
}
local HOLD = {
	[Enum.HumanoidRigType.R6] = "rbxassetid://182393478",
	[Enum.HumanoidRigType.R15] = "rbxassetid://507768375",
}

local folder = Instance.new("Folder")
folder.Name = "StandHelpers"
folder.Parent = workspace

type Walker = {
	model: Model,
	root: BasePart,
	lift: number, -- studs from the ground to the model's pivot
	walk: AnimationTrack?,
	hold: AnimationTrack?,
	crate: BasePart,
	conn: RBXScriptConnection?,
	leg: number,
	status: TextLabel?, -- the bar's second line ("Helper" / "Carrying N")
	id: number, -- breaks ties when two walkers are exactly in line
	base: Vector3?, -- where the server's route puts it this frame (nil when not walking)
	off: Vector3, -- its sidestep from the route (keep right, make room for the others)
	right: Vector3, -- its right-hand side on the last stretch it walked (kept while it stands)
}

-- Walking manners: each walker keeps KEEP_RIGHT studs to the right of the route (so two helpers
-- coming the opposite way pass each other), and steps up to MAX_SIDE aside from any other walker
-- closer than SEP studs (also while standing at the chest or the stand, so they wait side by side).
-- Near the ends of a leg (pad, chest, stand: EDGE studs) it stops keeping right. The server decides when a walker is where; this only moves it sideways.
local KEEP_RIGHT = 1
local SEP = 3.5
local PUSH = 1.6
local MAX_SIDE = 1.6
local EDGE = 2.5
local SIDE_RATE = 5
local nextId = 0

local walkers: { [Instance]: Walker } = {}

local function helperPad(site: Instance, index: number): Model?
	local pads = site:FindFirstChild("Pads")
	local pad = pads and pads:FindFirstChild("HelperPad_" .. index)
	return if pad and pad:IsA("Model") then pad else nil
end

local function loadTrack(humanoid: Humanoid, ids: { [Enum.HumanoidRigType]: string }, priority: Enum.AnimationPriority): AnimationTrack?
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animator.Parent = humanoid
	local anim = Instance.new("Animation")
	anim.AnimationId = ids[humanoid.RigType] or ids[Enum.HumanoidRigType.R15]
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

local function getWalker(pad: Model): Walker?
	local existing = walkers[pad]
	local source = pad:FindFirstChild("PadHero")
	if existing and existing.model.Parent and source and existing.model:GetAttribute("Hero") == source:GetAttribute("Hero") then
		return existing
	end
	if existing then
		if existing.conn then
			existing.conn:Disconnect()
		end
		existing.model:Destroy()
		walkers[pad] = nil
	end
	if not source or not source:IsA("Model") then
		return nil
	end
	local padPart = pad:FindFirstChild("Pad")
	local home = source:GetPivot()
	local groundY = if padPart and padPart:IsA("BasePart") then padPart.Position.Y + padPart.Size.Y / 2 else home.Position.Y
	local model = source:Clone()
	model:PivotTo(home)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		model:Destroy()
		return nil
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Anchored = d == root
		end
	end
	-- The pad copy hides its bar (the pad's billboard names it); the walker shows it again, with
	-- "Helper" / "Carrying N" on the second line instead of the level and no power line.
	local status: TextLabel? = nil
	local info = root:FindFirstChild("InfoAttachment")
	if info then
		for _, g in info:GetChildren() do
			if g:IsA("BillboardGui") then
				g.Enabled = true
			end
		end
		local bar = info:FindFirstChild("HeroBar")
		local container = bar and bar:FindFirstChild("Container")
		if container then
			local level = container:FindFirstChild("Level")
			if level and level:IsA("TextLabel") then
				level.Text = "Helper"
				status = level
			end
			local power = container:FindFirstChild("Power")
			if power and power:IsA("GuiObject") then
				power.Visible = false
			end
		end
	end
	-- the crate it holds while carrying
	local crate = Instance.new("Part")
	crate.Name = "Crate"
	crate.Size = Vector3.new(1.6, 1.1, 1.2) * math.max(0.6, model:GetScale())
	crate.Material = Enum.Material.WoodPlanks
	crate.Color = Color3.fromRGB(176, 120, 64)
	crate.CanCollide = false
	crate.CanQuery = false
	crate.CanTouch = false
	crate.Massless = true
	crate.Transparency = 1
	crate.CFrame = root.CFrame * CFrame.new(0, 0.3, -root.Size.Z / 2 - crate.Size.Z / 2 - 0.2)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = crate
	weld.Parent = crate
	crate.Parent = model
	model.Parent = folder
	local w: Walker = {
		model = model,
		root = root,
		lift = home.Position.Y - groundY,
		walk = loadTrack(humanoid, WALK, Enum.AnimationPriority.Movement),
		hold = loadTrack(humanoid, HOLD, Enum.AnimationPriority.Action),
		crate = crate,
		conn = nil,
		leg = 0,
		status = status,
		id = 0,
		base = nil,
		off = Vector3.zero,
		right = Vector3.xAxis,
	}
	nextId += 1
	w.id = nextId
	walkers[pad] = w
	return w
end

local function setCarrying(w: Walker, carried: number)
	local carrying = carried > 0
	w.crate.Transparency = if carrying then 0 else 1
	if w.status then
		w.status.Text = if carrying then ("Carrying %d"):format(carried) else "Helper"
	end
	if w.hold then
		if carrying and not w.hold.IsPlaying then
			w.hold:Play(0.15)
		elseif not carrying and w.hold.IsPlaying then
			w.hold:Stop(0.15)
		end
	end
end

local function legLength(points: { Vector3 }): { number }
	local acc = { 0 }
	for i = 2, #points do
		acc[i] = acc[i - 1] + (points[i] - points[i - 1]).Magnitude
	end
	return acc
end

local function playLeg(site: Instance, index: number, points: { Vector3 }, duration: number, carried: number)
	local pad = helperPad(site, index)
	if not pad or #points < 2 then
		return
	end
	local w = getWalker(pad)
	if not w then
		return
	end
	w.model.Parent = folder
	setCarrying(w, carried)
	if w.walk and not w.walk.IsPlaying then
		w.walk:Play(0.15)
	end
	if w.conn then
		w.conn:Disconnect()
	end
	w.leg += 1
	local acc = legLength(points)
	local total = acc[#acc]
	local t0 = os.clock()
	local walker = w
	walker.conn = RunService.Heartbeat:Connect(function(dt: number)
		local t = if duration > 0 then math.min((os.clock() - t0) / duration, 1) else 1
		local dist = total * t
		local seg = 2
		while seg < #points and acc[seg] < dist do
			seg += 1
		end
		local a, b = points[seg - 1], points[seg]
		local segLen = acc[seg] - acc[seg - 1]
		local alpha = if segLen > 0 then (dist - acc[seg - 1]) / segLen else 1
		local base = a:Lerp(b, alpha)
		local dir = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
		walker.base = base
		local moving = dir.Magnitude > 0.05
		if moving then
			local u = dir.Unit
			walker.right = Vector3.new(-u.Z, 0, u.X)
		end
		local right = walker.right
		local fade = if moving then math.clamp(math.min(dist, total - dist) / EDGE, 0, 1) else 0
		local lat = KEEP_RIGHT * fade
		for _, o in walkers do
			local ob = o.base
			if o ~= walker and ob and o.model.Parent then
				local d = Vector3.new(base.X - ob.X, 0, base.Z - ob.Z)
				local m = d.Magnitude
				if m < SEP then
					local side = d:Dot(right)
					local sign = if math.abs(side) > 0.1 then math.sign(side) elseif walker.id > o.id then 1 else -1
					lat += sign * (1 - m / SEP) * PUSH
				end
			end
		end
		local goal = right * math.clamp(lat, -MAX_SIDE, MAX_SIDE)
		walker.off = walker.off:Lerp(goal, math.min(1, dt * SIDE_RATE))
		local pos = base + walker.off + Vector3.new(0, walker.lift, 0)
		local look = if dir.Magnitude > 0.05 then CFrame.lookAt(pos, pos + dir) else CFrame.new(pos) * walker.root.CFrame.Rotation
		walker.model:PivotTo(look)
		if t >= 1 then
			walker.conn:Disconnect()
			walker.conn = nil -- `base` stays: the others still make room for it while it stands
			if walker.walk then
				walker.walk:Stop(0.2)
			end
		end
	end)
end

local function backOnPad(site: Instance, index: number)
	local pad = helperPad(site, index)
	if not pad then
		return
	end
	local w = walkers[pad]
	if w then
		if w.conn then
			w.conn:Disconnect()
			w.conn = nil
		end
		setCarrying(w, 0)
		w.base = nil
		w.off = Vector3.zero
		if w.walk then
			w.walk:Stop(0)
		end
		w.model.Parent = nil -- kept for the next trip
	end
end

local function popup(at: Vector3, text: string)
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.Position = at + Vector3.new(0, 4, 0)
	holder.Parent = folder
	local g = Instance.new("BillboardGui")
	g.Size = UDim2.fromScale(5, 1.4)
	g.LightInfluence = 0
	g.MaxDistance = 90
	g.Parent = holder
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromScale(1, 1)
	l.Font = Enum.Font.FredokaOne
	l.TextScaled = true
	l.TextColor3 = Color3.fromRGB(255, 200, 80)
	l.Text = text
	l.Parent = g
	local s = Instance.new("UIStroke")
	s.Thickness = 2
	s.Parent = l
	TweenService:Create(holder, TweenInfo.new(1), { Position = holder.Position + Vector3.new(0, 2.5, 0) }):Play()
	TweenService:Create(l, TweenInfo.new(1), { TextTransparency = 1 }):Play()
	TweenService:Create(s, TweenInfo.new(1), { Transparency = 1 }):Play()
	task.delay(1.05, function()
		holder:Destroy()
	end)
end

standEvent.OnClientEvent:Connect(function(kind: string, site: Instance, index: any, a: any, b: any, c: any)
	if typeof(site) ~= "Instance" or typeof(index) ~= "number" then
		return
	end
	if kind == "HelperLeg" and typeof(a) == "table" then
		playLeg(site, index, a, if typeof(b) == "number" then b else 1, if typeof(c) == "number" then c else 0)
	elseif kind == "HelperIdle" then
		backOnPad(site, index)
	elseif kind == "HelperDrop" then
		local pad = helperPad(site, index)
		local w = pad and walkers[pad]
		if w and w.model.Parent then
			popup(w.root.Position, "+" .. tostring(a))
			setCarrying(w, 0)
		end
	end
end)

-- A pad whose hero changed / left: drop its walker.
local function watchPad(pad: Instance)
	if not pad:IsA("Model") or not pad.Name:match("^HelperPad_") then
		return
	end
	pad:GetAttributeChangedSignal("HeroId"):Connect(function()
		local w = walkers[pad]
		if w then
			if w.conn then
				w.conn:Disconnect()
			end
			w.model:Destroy()
			walkers[pad] = nil
		end
	end)
end

task.spawn(function()
	local plots = workspace:WaitForChild("Plots")
	local function watchPlot(plot: Instance)
		local sites = plot:WaitForChild("StandSites", 30)
		if not sites then
			return
		end
		for _, d in sites:GetDescendants() do
			watchPad(d)
		end
		sites.DescendantAdded:Connect(watchPad)
	end
	for _, plot in plots:GetChildren() do
		task.spawn(watchPlot, plot)
	end
	plots.ChildAdded:Connect(function(plot)
		task.spawn(watchPlot, plot)
	end)
end)

