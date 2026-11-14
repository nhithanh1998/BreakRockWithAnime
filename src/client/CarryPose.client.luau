-- CarryPose: while a character carries materials (character attribute "Carrying", set by CarryService)
-- both arms are held out in front, under the stack of boxes. Every client does this for every
-- character, so everyone sees it. It overrides the arm joints' Transform after the Animator each
-- frame (RunService.Stepped), so walking / idle animations keep playing on the rest of the body.
-- Pose angles: MaterialConfig.Carry.Pose. Works on R15 (Shoulder + Elbow) and R6 (Shoulder only),
-- with Motor6D joints or AnimationConstraint joints (avatar joint upgrade).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MaterialConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MaterialConfig"))

local POSE = MaterialConfig.Carry.Pose

-- A joint is a Motor6D, or an AnimationConstraint on avatars with the joint upgrade; both have Transform.
type Joint = { motor: any, pose: CFrame }
type Rig = { joints: { Joint }, weight: number }

local rigs: { [Model]: Rig } = {}

local function isJoint(m: Instance?): boolean
	return m ~= nil and (m:IsA("Motor6D") or m:IsA("AnimationConstraint"))
end

local function motor(character: Model, part: string, name: string): Instance?
	local p = character:FindFirstChild(part)
	local m = p and p:FindFirstChild(name)
	return if isJoint(m) then m else nil
end

local function buildRig(character: Model): Rig
	local pitch, yaw, bend = math.rad(POSE.ShoulderPitch), math.rad(POSE.ShoulderYaw), math.rad(POSE.ElbowBend)
	local joints: { Joint } = {}
	local function add(m: Instance?, pose: CFrame)
		if m then
			table.insert(joints, { motor = m, pose = pose })
		end
	end
	if character:FindFirstChild("UpperTorso") then
		-- R15: arm forward (pitch about X), then turned in toward the middle (yaw), forearm bent up
		add(motor(character, "RightUpperArm", "RightShoulder"), CFrame.fromEulerAnglesYXZ(pitch, yaw, 0))
		add(motor(character, "LeftUpperArm", "LeftShoulder"), CFrame.fromEulerAnglesYXZ(pitch, -yaw, 0))
		add(motor(character, "RightLowerArm", "RightElbow"), CFrame.Angles(bend, 0, 0))
		add(motor(character, "LeftLowerArm", "LeftElbow"), CFrame.Angles(bend, 0, 0))
	else
		-- R6: the shoulder joints point sideways (X is the arm's forward axis)
		local torso = character:FindFirstChild("Torso")
		local r = torso and torso:FindFirstChild("Right Shoulder")
		local l = torso and torso:FindFirstChild("Left Shoulder")
		add(if isJoint(r) then r else nil, CFrame.Angles(0, 0, pitch))
		add(if isJoint(l) then l else nil, CFrame.Angles(0, 0, -pitch))
	end
	return { joints = joints, weight = 0 }
end

local function track(character: Model)
	if rigs[character] then
		return
	end
	rigs[character] = buildRig(character)
	character.Destroying:Connect(function()
		rigs[character] = nil
	end)
	character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			rigs[character] = nil
		end
	end)
end

local function onCharacter(character: Model)
	-- the arms may arrive a little after the character
	task.spawn(function()
		character:WaitForChild("RightUpperArm", 5)
		character:WaitForChild("LeftLowerArm", 5)
		if character.Parent then
			rigs[character] = nil
			track(character)
		end
	end)
	track(character)
end

local function onPlayer(player: Player)
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		onCharacter(player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayer)
for _, p in Players:GetPlayers() do
	onPlayer(p)
end
Players.PlayerRemoving:Connect(function(p)
	if p.Character then
		rigs[p.Character] = nil
	end
end)

RunService.Stepped:Connect(function(_, dt)
	local step = if POSE.BlendTime > 0 then dt / POSE.BlendTime else 1
	for character, rig in rigs do
		local target = if character:GetAttribute("Carrying") == true then 1 else 0
		if rig.weight == 0 and target == 0 then
			continue
		end
		rig.weight = math.clamp(rig.weight + (if target > rig.weight then step else -step), 0, 1)
		local w = rig.weight
		local eased = w * w * (3 - 2 * w)
		for _, j in rig.joints do
			if j.motor.Parent then
				j.motor.Transform = j.motor.Transform:Lerp(j.pose, eased)
			end
		end
	end
end)
