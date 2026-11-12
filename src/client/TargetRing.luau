--!strict
-- TargetRing: a red dashed circle on the ground around every tree that is being chopped, spinning
-- non-stop. A tree counts as targeted while a hero is after it ("HeroTargets" attribute, set by
-- HeroWorkerService) or while someone hit it in the last TreeConfig.TargetRing.PlayerTargetTime seconds.
--
--   TargetRing.Start()
--   TargetRing.MarkHit(tree)   -- call whenever a tree is hit (own clicks + server TreeHit)
-- Look & speed: TreeConfig.TargetRing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local TreeFX = require(script.Parent:WaitForChild("TreeFX"))

local CFG = TreeConfig.TargetRing

type Ring = {
	folder: Folder,
	parts: { BasePart },
	cframes: { CFrame },
	center: Vector3,
	radius: number,
	step: number,
	born: number,
	dying: number?,
}

local TargetRing = {}

local rings: { [Model]: Ring } = {}
local lastHit: { [Model]: number } = {}
local angle = 0
local started = false

function TargetRing.MarkHit(tree: Model?)
	if tree then
		lastHit[tree] = os.clock()
	end
end

local function isAlive(tree: Model): boolean
	return tree.Parent ~= nil and not tree:GetAttribute("Dead") and (tree:GetAttribute("HP") or 0) > 0
end

local function isTargeted(tree: Model, now: number): boolean
	if not isAlive(tree) then
		return false
	end
	if ((tree:GetAttribute("HeroTargets") :: number?) or 0) > 0 then
		return true
	end
	local t = lastHit[tree]
	return t ~= nil and now - t <= CFG.PlayerTargetTime
end

-- Ring center and radius from the tree's dirt mound ("Ground" model) so the ring lies on the floor
-- just outside it; falls back to the whole tree's footprint.
local function measure(tree: Model): (Vector3, number)
	local ground = tree:FindFirstChild("Ground")
	local source: Model = if ground and ground:IsA("Model") then ground else tree
	local bboxCF, size = source:GetBoundingBox()
	local pos = bboxCF.Position
	local floorY = pos.Y - size.Y / 2 + 0.15
	local radius = math.max(CFG.MinRadius, math.max(size.X, size.Z) / 2 * CFG.RadiusScale + CFG.Padding)
	return Vector3.new(pos.X, floorY, pos.Z), radius
end

local function createRing(tree: Model, now: number): Ring
	local center, radius = measure(tree)
	local circumference = 2 * math.pi * radius
	local count = math.max(10, math.floor(circumference / (CFG.DashLength + CFG.GapLength)))
	local step = 2 * math.pi / count
	local dashLen = circumference / count * CFG.DashLength / (CFG.DashLength + CFG.GapLength)

	local folder = Instance.new("Folder")
	folder.Name = "TargetRing"
	local parts, cframes = {}, {}
	for i = 1, count do
		local p = Instance.new("Part")
		p.Name = "Dash"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = CFG.Color
		p.Transparency = 1
		p.Size = Vector3.new(dashLen, 0.2, CFG.DashWidth)
		p.CFrame = CFrame.new(center)
		p.Parent = folder
		parts[i] = p
		cframes[i] = p.CFrame
	end
	folder.Parent = TreeFX.Folder

	return {
		folder = folder,
		parts = parts,
		cframes = cframes,
		center = center,
		radius = radius,
		step = step,
		born = now,
		dying = nil,
	}
end

local function easeOut(t: number): number
	t = math.clamp(t, 0, 1)
	return 1 - (1 - t) * (1 - t)
end

-- Returns false once a dying ring has finished shrinking (caller removes it).
local function drawRing(ring: Ring, now: number): boolean
	local grow = easeOut((now - ring.born) / CFG.PopTime)
	local fade = 1
	if ring.dying then
		fade = 1 - easeOut((now - ring.dying) / CFG.PopTime)
		if fade <= 0 then
			return false
		end
	end
	local k = grow * fade
	local r = ring.radius * (0.55 + 0.45 * k)
	local transparency = 1 - (1 - CFG.Transparency) * k
	local base = CFrame.new(ring.center)
	for i, p in ring.parts do
		ring.cframes[i] = base * CFrame.Angles(0, angle + i * ring.step, 0) * CFrame.new(0, 0, -r)
		if p.Transparency ~= transparency then
			p.Transparency = transparency
		end
	end
	workspace:BulkMoveTo(ring.parts, ring.cframes, Enum.BulkMoveMode.FireCFrameChanged)
	return true
end

local function forEachTree(fn: (Model) -> ())
	local plots = workspace:FindFirstChild("Plots")
	if not plots then
		return
	end
	for _, plot in plots:GetChildren() do
		local spawns = plot:FindFirstChild("TreeSpawns")
		if spawns then
			for _, tree in spawns:GetChildren() do
				if tree:IsA("Model") then
					fn(tree)
				end
			end
		end
	end
end

local function update(dt: number)
	local now = os.clock()
	angle = (angle + CFG.SpinSpeed * dt) % (2 * math.pi)

	forEachTree(function(tree)
		if isTargeted(tree, now) then
			local ring = rings[tree]
			if not ring then
				rings[tree] = createRing(tree, now)
			elseif ring.dying then
				ring.dying = nil -- targeted again before it finished fading
				ring.born = now
			end
		end
	end)

	for tree, ring in rings do
		if not ring.dying and not isTargeted(tree, now) then
			ring.dying = now
		end
		if not drawRing(ring, now) then
			ring.folder:Destroy()
			rings[tree] = nil
		end
	end

	for tree in lastHit do
		if tree.Parent == nil then
			lastHit[tree] = nil
		end
	end
end

function TargetRing.Start()
	if started then
		return
	end
	started = true
	RunService.RenderStepped:Connect(update)
end

return TargetRing
