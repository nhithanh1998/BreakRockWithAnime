-- CustomerModels: the "Guest" customers of the Farm Stands: real Roblox players' R15 avatars.
-- The other customer looks are the hand-made R15 models in ReplicatedStorage.Customers (made in
-- Studio); clients mix both (StandCustomers, StandConfig.Customers.GuestChance).
--
-- Who: the friends of the players in the server (a few per player, FriendsPerPlayer), and when
-- there are not enough of those, the players themselves (so a fresh server still has guests).
-- At most MaxGuests avatars; the oldest go first. Built on the server
-- (Players:CreateHumanoidModelFromDescription) into ReplicatedStorage.GuestCustomers as
-- "Guest_<userId>" with attributes UserId, Username, DisplayName (the client puts "@Username" over
-- the head). The server never moves a customer.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StandConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StandConfig"))

local CFG = StandConfig.Customers
local FOLDER = "GuestCustomers"

local CustomerModels = {}

local folder: Folder
local order: { number } = {} -- user ids, oldest first
local building: { [number]: boolean } = {}

local function clean(model: Model)
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
end

local function trim()
	while #order > CFG.MaxGuests do
		local id = table.remove(order, 1) :: number
		local old = folder:FindFirstChild("Guest_" .. id)
		if old then
			old:Destroy()
		end
	end
end

local function addGuest(userId: number, username: string, displayName: string)
	if userId <= 0 or building[userId] or folder:FindFirstChild("Guest_" .. userId) then
		return
	end
	building[userId] = true
	local ok, model = pcall(function()
		local desc = Players:GetHumanoidDescriptionFromUserId(userId)
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	building[userId] = nil
	if not ok or not model then
		warn(("[CustomerModels] no avatar for %d: %s"):format(userId, tostring(model)))
		return
	end
	model.Name = "Guest_" .. userId
	model:SetAttribute("Guest", true)
	model:SetAttribute("UserId", userId)
	model:SetAttribute("Username", username)
	model:SetAttribute("DisplayName", displayName)
	clean(model)
	model.Parent = folder
	table.insert(order, userId)
	trim()
end

local function friendsOf(player: Player): { { id: number, name: string, display: string } }
	local out = {}
	local ok, pages = pcall(function()
		return Players:GetFriendsAsync(player.UserId)
	end)
	if not ok or not pages then
		return out
	end
	local okPage, page = pcall(function()
		return pages:GetCurrentPage()
	end)
	if okPage and page then
		for _, f in page do
			table.insert(out, { id = f.Id, name = f.Username, display = f.DisplayName or f.Username })
		end
	end
	return out
end

local function onPlayer(player: Player)
	local friends = friendsOf(player)
	local rng = Random.new()
	for i = #friends, 2, -1 do
		local j = rng:NextInteger(1, i)
		friends[i], friends[j] = friends[j], friends[i]
	end
	for i = 1, math.min(CFG.FriendsPerPlayer, #friends) do
		local f = friends[i]
		addGuest(f.id, f.name, f.display)
	end
	-- not enough friends around: real players in the server are guests too
	if #order < CFG.MinGuests then
		addGuest(player.UserId, player.Name, player.DisplayName)
	end
end

function CustomerModels.Start()
	local old = ReplicatedStorage:FindFirstChild(FOLDER)
	if old then
		old:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = FOLDER
	f.Parent = ReplicatedStorage
	folder = f
	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayer, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
end

return CustomerModels
