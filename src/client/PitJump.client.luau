-- PitJump: while the player stands in a plot's chop area (inside Floor.Ground, below the rim), their
-- jump is raised so one jump clears the rim, however deep the zone's floor is (ZoneService FloorLevel).
-- Outside the chop area the normal jump comes back.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local MARGIN = 3 -- studs above the rim the jump reaches, so the player can step onto it
local DEFAULT_RIM_ABOVE_FLOOR = 4 -- if a Floor has no "RimTopY" attribute

local player = Players.LocalPlayer
local Plots = workspace:WaitForChild("Plots")

local humanoid: Humanoid? = nil
local defaultHeight = 7.2
local defaultPower = 50

local function setJump(height: number)
	local h = humanoid
	if not h then return end
	if h.UseJumpPower then
		local power = if height <= defaultHeight then defaultPower else math.sqrt(2 * workspace.Gravity * height)
		if h.JumpPower ~= power then h.JumpPower = power end
	else
		if h.JumpHeight ~= height then h.JumpHeight = height end
	end
end

-- Jump height needed to get out of the pit the root is in, or nil when not in one.
local function neededHeight(pos: Vector3): number?
	for _, plot in ipairs(Plots:GetChildren()) do
		local floor = plot:FindFirstChild("Floor")
		local ground = floor and floor:FindFirstChild("Ground")
		if ground and ground:IsA("BasePart") then
			local rel = ground.CFrame:PointToObjectSpace(pos)
			if math.abs(rel.X) <= ground.Size.X / 2 and math.abs(rel.Z) <= ground.Size.Z / 2 then
				local groundTop = ground.Position.Y + ground.Size.Y / 2
				local rimTop = floor:GetAttribute("RimTopY")
				if typeof(rimTop) ~= "number" then
					rimTop = groundTop + DEFAULT_RIM_ABOVE_FLOOR + (plot:GetAttribute("FloorDepth") or 0)
				end
				if pos.Y < rimTop then
					return rimTop - groundTop + MARGIN
				end
			end
		end
	end
	return nil
end

local function onCharacter(character: Model)
	local h = character:WaitForChild("Humanoid") :: Humanoid
	humanoid = h
	defaultHeight = h.JumpHeight
	defaultPower = h.JumpPower
end

if player.Character then task.spawn(onCharacter, player.Character) end
player.CharacterAdded:Connect(onCharacter)
player.CharacterRemoving:Connect(function()
	humanoid = nil
end)

RunService.Heartbeat:Connect(function()
	local h = humanoid
	local root = h and h.RootPart
	if not h or not root then return end
	-- Only change it on the ground, so a jump already in the air keeps its height.
	if h.FloorMaterial == Enum.Material.Air then return end
	local need = neededHeight(root.Position)
	setJump(if need then math.max(need, defaultHeight) else defaultHeight)
end)
