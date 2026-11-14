-- CustomerModels: builds the Farm Stand customer looks once, when the server starts, as R15 rigs in
-- ReplicatedStorage.CustomerModels (Customer1..N). Clients clone them for the customer NPCs
-- (CustomerClient); the server never moves a customer.
-- Each look is a default R15 body (Players:CreateHumanoidModelFromDescription) with its own skin,
-- shirt and pants colours and, for some, a simple cap. StandConfig.Customers.Templates looks.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StandConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StandConfig"))

local CustomerModels = {}

local SKINS = {
	Color3.fromRGB(255, 220, 185),
	Color3.fromRGB(234, 184, 146),
	Color3.fromRGB(204, 142, 105),
	Color3.fromRGB(160, 105, 75),
	Color3.fromRGB(110, 72, 50),
}
local SHIRTS = {
	Color3.fromRGB(220, 70, 60),
	Color3.fromRGB(70, 130, 220),
	Color3.fromRGB(80, 180, 90),
	Color3.fromRGB(240, 190, 60),
	Color3.fromRGB(160, 90, 200),
	Color3.fromRGB(240, 140, 60),
	Color3.fromRGB(60, 190, 190),
	Color3.fromRGB(235, 235, 235),
}
local PANTS = {
	Color3.fromRGB(50, 60, 90),
	Color3.fromRGB(70, 50, 40),
	Color3.fromRGB(40, 40, 45),
	Color3.fromRGB(110, 110, 120),
}

local function addCap(model: Model, color: Color3)
	local head = model:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end
	local cap = Instance.new("Part")
	cap.Name = "Cap"
	cap.Size = Vector3.new(1.25, 0.35, 1.25)
	cap.Color = color
	cap.Material = Enum.Material.SmoothPlastic
	cap.CanCollide = false
	cap.CanQuery = false
	cap.CanTouch = false
	cap.Massless = true
	cap.CFrame = head.CFrame * CFrame.new(0, head.Size.Y / 2 + 0.1, 0)
	local brim = cap:Clone()
	brim.Name = "Brim"
	brim.Size = Vector3.new(1.1, 0.12, 0.6)
	brim.CFrame = head.CFrame * CFrame.new(0, head.Size.Y / 2 - 0.02, -0.75)
	for _, p in { cap, brim } do
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = head
		weld.Part1 = p
		weld.Parent = p
		p.Parent = model
	end
end

local function build(i: number, rng: Random): Model?
	local desc = Instance.new("HumanoidDescription")
	local skin = SKINS[rng:NextInteger(1, #SKINS)]
	local shirt = SHIRTS[(i - 1) % #SHIRTS + 1]
	local pants = PANTS[rng:NextInteger(1, #PANTS)]
	desc.HeadColor = skin
	desc.LeftArmColor = skin
	desc.RightArmColor = skin
	desc.TorsoColor = shirt
	desc.LeftLegColor = pants
	desc.RightLegColor = pants
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok or not model then
		warn("[CustomerModels] could not build a customer: " .. tostring(model))
		return nil
	end
	model.Name = "Customer" .. i
	-- arms in the shirt colour (upper arms), hands stay skin
	for _, name in { "LeftUpperArm", "RightUpperArm" } do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			part.Color = shirt
		end
	end
	if rng:NextNumber() < 0.5 then
		addCap(model, SHIRTS[rng:NextInteger(1, #SHIRTS)])
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		elseif d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	return model
end

function CustomerModels.Start()
	local folder = ReplicatedStorage:FindFirstChild("CustomerModels")
	if folder then
		folder:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = "CustomerModels"
	task.spawn(function()
		local rng = Random.new(42)
		for i = 1, StandConfig.Customers.Templates do
			local model = build(i, rng)
			if model then
				model.Parent = f
			end
		end
		f.Parent = ReplicatedStorage
	end)
end

return CustomerModels
