--!nocheck
-- BuildChopR15: authoring script (run in Studio's command bar / MCP, Edit mode). Not part of the game.
-- Builds the three R15 chop swings as KeyframeSequences in
--   ServerStorage.RBX_ANIMSAVES.SaiyanWarrior.{ChopR15_LightA, ChopR15_LightB, ChopR15_Heavy}
-- so they show up in the Animation Editor (select the SaiyanWarrior rig -> Load) for publishing.
--   LightA = quick horizontal slash, right to left
--   LightB = quick diagonal chop from over the right shoulder
--   Heavy  = charged swing: crouch + coil, tremble while charging, explosive step-in slash
-- Every swing starts and ends on the hold pose (R15 "toolnone" arm over the default idle stance), so
-- it blends in and out of the hero's idle / hold without a pop. Each has a "Hit" marker at impact.

local ServerStorage = game:GetService("ServerStorage")

local rad = math.rad
local function A(x, y, z)
	return CFrame.Angles(rad(x or 0), rad(y or 0), rad(z or 0))
end
-- Shoulder: sweep (yaw) * raise forward (pitch) * twist about the arm (roll).
local function arm(yaw, pitch, roll, abd)
	return CFrame.Angles(0, rad(yaw), 0) * CFrame.Angles(rad(pitch), 0, 0) * CFrame.Angles(0, rad(roll or 0), rad(abd or 0))
end
local function P(x, y, z)
	return CFrame.new(x or 0, y or 0, z or 0)
end

-- Rig hierarchy (Part0 -> Part1) for the Pose tree.
local PARENT = {
	LowerTorso = "HumanoidRootPart",
	UpperTorso = "LowerTorso",
	Head = "UpperTorso",
	RightUpperArm = "UpperTorso",
	RightLowerArm = "RightUpperArm",
	RightHand = "RightLowerArm",
	LeftUpperArm = "UpperTorso",
	LeftLowerArm = "LeftUpperArm",
	LeftHand = "LeftLowerArm",
	RightUpperLeg = "LowerTorso",
	RightLowerLeg = "RightUpperLeg",
	RightFoot = "RightLowerLeg",
	LeftUpperLeg = "LowerTorso",
	LeftLowerLeg = "LeftUpperLeg",
	LeftFoot = "LeftLowerLeg",
}

-- Ready / hold pose: R15 toolnone right arm over the first frame of the default R15 idle.
local READY = {
	LowerTorso = P(0, -0.09, 0),
	UpperTorso = A(-1, 3, 0),
	Head = A(3, -3, 0),
	RightUpperArm = arm(0, 79, 0),
	RightLowerArm = A(13, 0, 0),
	RightHand = CFrame.identity,
	LeftUpperArm = A(-3, -2, -6),
	LeftLowerArm = A(12, 0, 0),
	LeftHand = CFrame.identity,
	LeftUpperLeg = A(17, -2, -9),
	LeftLowerLeg = A(-31, 0, 0),
	LeftFoot = A(14, -1, 9),
	RightUpperLeg = A(23, 2, 8),
	RightLowerLeg = A(-25, 0, 0),
	RightFoot = A(1, 1.5, -8),
}

local function pose(overrides)
	local t = table.clone(READY)
	for k, v in overrides do
		t[k] = v
	end
	return t
end

-- Leg helpers: a stance with the hips dropped by `drop` studs and knees bent to match.
local function legs(t, bendL, bendR, turn)
	turn = turn or 0
	t.LeftUpperLeg = A(17 + bendL, -2 - turn, -9)
	t.LeftLowerLeg = A(-31 - bendL * 1.6, 0, 0)
	t.LeftFoot = A(14 + bendL * 0.6, -1 + turn, 9)
	t.RightUpperLeg = A(23 + bendR, 2 - turn, 8)
	t.RightLowerLeg = A(-25 - bendR * 1.6, 0, 0)
	t.RightFoot = A(1 + bendR * 0.6, 1.5 + turn, -8)
	return t
end

local S, D = Enum.PoseEasingStyle, Enum.PoseEasingDirection
-- key = { time, pose table, easing style, easing direction, marker? }
local ANIMS = {}

-- Light A: horizontal slash, right -> left. 0.62s, hit at 0.29.
ANIMS.ChopR15_LightA = {
	{ 0.00, READY, S.CubicV2, D.InOut },
	{ 0.17, legs(pose({ -- wind up: coil to the right, axe drawn back
		LowerTorso = P(0.05, -0.16, 0.05) * A(0, -18, 0),
		UpperTorso = A(-4, -38, 0),
		Head = A(2, 34, 0),
		RightUpperArm = arm(-43, 103, -83),
		RightLowerArm = A(4, 0, 0),
		RightHand = A(-58, 0, 0),
		LeftUpperArm = arm(35, 60, 0),
		LeftLowerArm = A(45, 0, 0),
	}), 14, 22, -12), S.CubicV2, D.In }, -- accelerates into the next key
	{ 0.29, legs(pose({ -- impact: arm through the trunk, torso unwinding
		LowerTorso = P(0, -0.15, -0.05) * A(0, 10, 0),
		UpperTorso = A(-8, 15, 0),
		Head = A(4, -14, 0),
		RightUpperArm = arm(61, 87, -94),
		RightLowerArm = A(20, 0, 0),
		RightHand = A(3, 0, 0),
		LeftUpperArm = arm(-10, 20, 0, -15),
		LeftLowerArm = A(30, 0, 0),
	}), 18, 14, 8), S.CubicV2, D.Out, "Hit" }, -- decelerates out of the hit
	{ 0.40, legs(pose({ -- follow-through overshoot
		LowerTorso = P(0, -0.13, -0.04) * A(0, 18, 0),
		UpperTorso = A(-6, 34, 0),
		Head = A(3, -28, 0),
		RightUpperArm = arm(43, 78, -88),
		RightLowerArm = A(4, 0, 0),
		RightHand = A(-39, 0, 0),
		LeftUpperArm = arm(-20, 10, 0, -20),
		LeftLowerArm = A(25, 0, 0),
	}), 16, 10, 12), S.CubicV2, D.InOut },
	{ 0.62, READY, S.Linear, D.InOut },
}

-- Light B: diagonal chop from over the right shoulder down across the trunk. 0.66s, hit at 0.31.
ANIMS.ChopR15_LightB = {
	{ 0.00, READY, S.CubicV2, D.InOut },
	{ 0.19, legs(pose({ -- wind up: axe up over the right shoulder, chest opens and leans back
		LowerTorso = P(0, -0.12, 0.06) * A(0, -10, 0),
		UpperTorso = A(8, -24, 4),
		Head = A(-4, 20, 0),
		RightUpperArm = arm(28, 45, -13),
		RightLowerArm = A(97, 0, 0),
		RightHand = A(-15, 0, 0),
		LeftUpperArm = arm(20, 55, 0),
		LeftLowerArm = A(40, 0, 0),
	}), 8, 14, -6), S.CubicV2, D.In },
	{ 0.31, legs(pose({ -- impact: crunch forward, axe biting into the trunk low-left
		LowerTorso = P(0, -0.22, -0.08) * A(0, 8, 0),
		UpperTorso = A(-20, 16, -6),
		Head = A(10, -12, 0),
		RightUpperArm = arm(-23, 16, 34),
		RightLowerArm = A(40, 0, 0),
		RightHand = A(2, 0, 0),
		LeftUpperArm = arm(-15, 15, 0, -18),
		LeftLowerArm = A(35, 0, 0),
	}), 26, 22, 6), S.CubicV2, D.Out, "Hit" },
	{ 0.43, legs(pose({ -- follow-through: settle low
		LowerTorso = P(0, -0.2, -0.06) * A(0, 12, 0),
		UpperTorso = A(-22, 22, -8),
		Head = A(12, -16, 0),
		RightUpperArm = arm(-13, 14, 37),
		RightLowerArm = A(6, 0, 0),
		RightHand = A(15, 0, 0),
		LeftUpperArm = arm(-20, 8, 0, -20),
		LeftLowerArm = A(30, 0, 0),
	}), 24, 20, 8), S.CubicV2, D.InOut },
	{ 0.66, READY, S.Linear, D.InOut },
}

-- Heavy: charged horizontal swing. 1.50s, hit at 0.86.
local function coil(extra, tremble)
	-- deep crouch, everything twisted far right, axe cocked behind
	return legs(pose({
		LowerTorso = P(0.08, -0.3 - extra * 0.03, 0.1) * A(0, -28 - extra, 0),
		UpperTorso = A(-10, -52 - extra * 1.5, tremble),
		Head = A(6, 46 + extra * 1.5, -tremble),
		RightUpperArm = arm(-34 + extra * 1.4, 115 + extra * 0.85 + tremble, -107 - extra * 0.7),
		RightLowerArm = A(4, 0, 0),
		RightHand = A(-58, 0, 0),
		LeftUpperArm = arm(45 + extra, 72, 0),
		LeftLowerArm = A(25, 0, 0),
	}), 34 + extra, 40 + extra, -20)
end
ANIMS.ChopR15_Heavy = {
	{ 0.00, READY, S.CubicV2, D.InOut },
	{ 0.30, coil(0, 0), S.CubicV2, D.InOut }, -- coil
	{ 0.40, coil(2, 1.5), S.Linear, D.InOut }, -- charging: keeps winding tighter, trembling
	{ 0.48, coil(3.5, -1.5), S.Linear, D.InOut },
	{ 0.56, coil(5, 1.5), S.Linear, D.InOut },
	{ 0.64, coil(6, -1.8), S.Linear, D.InOut },
	{ 0.72, coil(7, 0), S.CubicV2, D.In }, -- release: explodes into the swing
	{ 0.86, legs(pose({ -- impact: stepped in, full unwind
		LowerTorso = P(0, -0.2, -0.22) * A(0, 16, 0),
		UpperTorso = A(-12, 25, 0),
		Head = A(6, -22, 0),
		RightUpperArm = arm(59, 85, -89),
		RightLowerArm = A(23, 0, 0),
		RightHand = A(20, 0, 0),
		LeftUpperArm = arm(-40, 25, 0, -25),
		LeftLowerArm = A(20, 0, 0),
	}), 34, 6, 14), S.CubicV2, D.Out, "Hit" },
	{ 1.02, legs(pose({ -- big follow-through
		LowerTorso = P(0, -0.18, -0.2) * A(0, 30, 0),
		UpperTorso = A(-8, 50, 0),
		Head = A(4, -40, 0),
		RightUpperArm = arm(48, 77, -80),
		RightLowerArm = A(4, 0, 0),
		RightHand = A(-54, 0, 0),
		LeftUpperArm = arm(-45, 10, 0, -30),
		LeftLowerArm = A(18, 0, 0),
	}), 30, 4, 22), S.CubicV2, D.InOut },
	{ 1.18, legs(pose({ -- settle (weight drops back)
		LowerTorso = P(0, -0.2, -0.16) * A(0, 24, 0),
		UpperTorso = A(-6, 40, 0),
		Head = A(3, -32, 0),
		RightUpperArm = arm(60, 76, -89),
		RightLowerArm = A(20, 0, 0),
		RightHand = A(-35, 0, 0),
		LeftUpperArm = arm(-35, 12, 0, -25),
		LeftLowerArm = A(20, 0, 0),
	}), 28, 8, 18), S.CubicV2, D.InOut },
	{ 1.50, READY, S.Linear, D.InOut },
}

local function build(name, keys)
	local ks = Instance.new("KeyframeSequence")
	ks.Name = name
	ks.Loop = false
	ks.Priority = Enum.AnimationPriority.Action2
	for _, key in keys do
		local kf = Instance.new("Keyframe")
		kf.Time = key[1]
		local poses = {}
		local rootPose = Instance.new("Pose")
		rootPose.Name = "HumanoidRootPart"
		rootPose.Weight = 0
		rootPose.Parent = kf
		poses.HumanoidRootPart = rootPose
		local function get(part)
			if poses[part] then
				return poses[part]
			end
			local p = Instance.new("Pose")
			p.Name = part
			p.Weight = 1
			p.EasingStyle = key[3]
			p.EasingDirection = key[4]
			p.CFrame = key[2][part] or CFrame.identity
			p.Parent = get(PARENT[part])
			poses[part] = p
			return p
		end
		for part in PARENT do
			get(part)
		end
		if key[5] then
			local marker = Instance.new("KeyframeMarker")
			marker.Name = key[5]
			marker.Value = ""
			kf:AddMarker(marker)
		end
		kf.Parent = ks
	end
	return ks
end

local saves = ServerStorage:FindFirstChild("RBX_ANIMSAVES")
if not saves then
	saves = Instance.new("Model")
	saves.Name = "RBX_ANIMSAVES"
	saves.Parent = ServerStorage
end
local rigSaves = saves:FindFirstChild("SaiyanWarrior")
if not rigSaves then
	rigSaves = Instance.new("ObjectValue")
	rigSaves.Name = "SaiyanWarrior"
	rigSaves.Parent = saves
end
local built = {}
for name, keys in ANIMS do
	local old = rigSaves:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	build(name, keys).Parent = rigSaves
	table.insert(built, name)
end
table.sort(built)
return "built " .. table.concat(built, ", ")
