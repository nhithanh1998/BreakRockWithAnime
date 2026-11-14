-- CarryService: materials the player carries from the plot's chest to the Farm Stand.
--
-- Loot Pad: the "LootPad" part in the player's own plot (in front of the TreasureChest). While the
-- player stands on it, every MaterialConfig.Carry.TickInterval seconds the server moves up to PerTick
-- materials from the chest onto the player (ChestService.TakeMaterials, cheapest first), until the
-- player's CarryCapacity. Nothing is sold here and no money is given. All of it runs on the server
-- (no remote), so it can't be spammed; only the plot owner can use their pad.
--
-- What a player carries: player.Carried (IntValue per material id). Player attributes:
--   CarryCount     how many materials they carry
--   CarryCapacity  how many they can carry (MaterialConfig.Carry.BaseCapacity + "CarryBonus" attribute,
--                  set by the Carry Capacity upgrade later)
-- On the character: a "CarryStack" of boxes held out in front (one per BoxEvery materials, coloured
-- by what is carried), so everyone sees who carries what. The character's "Carrying" attribute makes
-- every client pose its arms under the stack (CarryPose).
-- The Loot Pad may be a part or a pad model (its "RestockMat" part is the mat).
--
--   CarryService.Count(player) / Capacity(player) / Room(player)
--   CarryService.Add(player, { [id] = n }) -> { [id] = n } added (trimmed to the room left)
--   CarryService.Take(player, max) -> { [id] = n } taken (dearest first; used by the Restock mat)
--   CarryService.GetSaveData(player) / ApplySaved(player, data)   (DataService "Carried")

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MaterialConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MaterialConfig"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))
local PlotService = require(script.Parent:WaitForChild("PlotService"))
local ToastService = require(script.Parent:WaitForChild("ToastService"))

local CARRY = MaterialConfig.Carry
local FOLDER = "Carried"
local STACK_NAME = "CarryStack"
local PAD_NAME = "LootPad"

local CarryService = {}

local function folderOf(player: Player): Folder
	local f = player:FindFirstChild(FOLDER)
	if not f then
		local nf = Instance.new("Folder")
		nf.Name = FOLDER
		nf.Parent = player
		f = nf
	end
	return f :: Folder
end

function CarryService.Capacity(player: Player): number
	local bonus = player:GetAttribute("CarryBonus")
	return CARRY.BaseCapacity + (if typeof(bonus) == "number" then bonus else 0)
end

function CarryService.Count(player: Player): number
	local n = 0
	for _, v in folderOf(player):GetChildren() do
		if v:IsA("IntValue") then
			n += v.Value
		end
	end
	return n
end

function CarryService.Room(player: Player): number
	return math.max(0, CarryService.Capacity(player) - CarryService.Count(player))
end

-- The stack of boxes in the character's arms --------------------------------------------------------

local function sortedStacks(player: Player): { IntValue }
	local list = {}
	for _, v in folderOf(player):GetChildren() do
		if v:IsA("IntValue") and v.Value > 0 then
			table.insert(list, v)
		end
	end
	table.sort(list, function(a, b)
		return a.Value > b.Value
	end)
	return list
end

local function drawStack(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local torso = (character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")) :: BasePart?
	local old = character:FindFirstChild(STACK_NAME)
	local count = CarryService.Count(player)
	local boxes = if count > 0 then math.clamp(math.ceil(count / CARRY.BoxEvery), 1, CARRY.MaxBoxes) else 0
	-- Colours: the boxes are shared out over what is carried, most first.
	local colors = {}
	local stacks = sortedStacks(player)
	for i = 1, boxes do
		local share = (i - 1) / math.max(boxes, 1) * count
		local acc = 0
		local pick = stacks[#stacks]
		for _, v in stacks do
			acc += v.Value
			if share < acc then
				pick = v
				break
			end
		end
		local def = pick and MaterialConfig.Get(pick.Name)
		colors[i] = if def then def.Color else Color3.fromRGB(150, 110, 70)
	end
	local key = ""
	for i = 1, boxes do
		key ..= colors[i]:ToHex()
	end
	if old and old:GetAttribute("Key") == key then
		return
	end
	if old then
		old:Destroy()
	end
	if boxes == 0 or not torso then
		character:SetAttribute("Carrying", false)
		return
	end
	local stack = Instance.new("Model")
	stack.Name = STACK_NAME
	stack:SetAttribute("Key", key)
	local size = CARRY.BoxSize
	-- held out in front at the hands (CarryPose bends both arms forward under the bottom box)
	local base = torso.CFrame * CFrame.new(0, -torso.Size.Y / 2 + size.Y / 2 + CARRY.HoldUp, -(torso.Size.Z / 2 + size.Z / 2 + CARRY.HoldOut))
	for i = 1, boxes do
		local box = Instance.new("Part")
		box.Name = "Box"
		box.Size = size
		box.Color = colors[i]
		box.Material = Enum.Material.WoodPlanks
		box.CanCollide = false
		box.CanQuery = false
		box.CanTouch = false
		box.Massless = true
		box.CFrame = base * CFrame.new(0, (i - 1) * size.Y, 0) * CFrame.Angles(0, math.rad(if i % 2 == 0 then 6 else -6), 0)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = torso
		weld.Part1 = box
		weld.Parent = box
		box.Parent = stack
	end
	stack.Parent = character
	character:SetAttribute("Carrying", true)
end

local function changed(player: Player)
	player:SetAttribute("CarryCount", CarryService.Count(player))
	player:SetAttribute("CarryCapacity", CarryService.Capacity(player))
	drawStack(player)
end

-- Adding / taking --------------------------------------------------------------------------------------

function CarryService.Add(player: Player, stacks: { [string]: number }): { [string]: number }
	local added = {}
	local room = CarryService.Room(player)
	local folder = folderOf(player)
	for id, n in stacks do
		local amount = math.min(math.floor(n), room)
		if amount <= 0 or not MaterialConfig.IsMaterial(id) then
			continue
		end
		local v = folder:FindFirstChild(id) :: IntValue?
		if not v then
			local nv = Instance.new("IntValue")
			nv.Name = id
			nv.Parent = folder
			v = nv
		end
		(v :: IntValue).Value += amount
		room -= amount
		added[id] = amount
	end
	changed(player)
	return added
end

function CarryService.Take(player: Player, max: number): { [string]: number }
	local taken = {}
	local list = sortedStacks(player)
	table.sort(list, function(a, b)
		local da, db = MaterialConfig.Get(a.Name), MaterialConfig.Get(b.Name)
		return (if da then da.BasePrice else 0) > (if db then db.BasePrice else 0)
	end)
	local left = math.floor(max)
	for _, v in list do
		if left <= 0 then
			break
		end
		local n = math.min(v.Value, left)
		v.Value -= n
		left -= n
		taken[v.Name] = n
		if v.Value <= 0 then
			v:Destroy()
		end
	end
	changed(player)
	return taken
end

-- Loot Pad ------------------------------------------------------------------------------------------------

local function onPad(player: Player, pad: BasePart): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return false
	end
	local rel = pad.CFrame:PointToObjectSpace(root.Position)
	return math.abs(rel.X) <= pad.Size.X / 2 + CARRY.PadReach
		and math.abs(rel.Z) <= pad.Size.Z / 2 + CARRY.PadReach
		and rel.Y >= -1
		and rel.Y <= CARRY.PadHeight
end

-- The pad's mat: "LootPad" is a part, or a pad model whose mat is its "RestockMat" part (else its
-- PrimaryPart / biggest part).
local function padPart(plot: Instance): BasePart?
	local pad = plot:FindFirstChild(PAD_NAME)
	if not pad then
		return nil
	end
	if pad:IsA("BasePart") then
		return pad
	end
	local mat = pad:FindFirstChild("RestockMat", true)
	if mat and mat:IsA("BasePart") then
		return mat
	end
	if pad:IsA("Model") and pad.PrimaryPart then
		return pad.PrimaryPart
	end
	local best: BasePart? = nil
	for _, d in pad:GetDescendants() do
		if d:IsA("BasePart") and (not best or d.Size.X * d.Size.Z > best.Size.X * best.Size.Z) then
			best = d
		end
	end
	return best
end

local function tick(player: Player)
	local plot = PlotService.GetPlot(player)
	local pad = plot and padPart(plot)
	if not plot or not pad or not onPad(player, pad) then
		return
	end
	-- the plot's own chest, else the shared workspace chest (same lookup as ChestService)
	local own = ChestService.GetChest(plot)
	if not own then
		return
	end
	local room = CarryService.Room(player)
	if room <= 0 then
		ToastService.SendThrottled(player, "CarryFull", ("Hands full! (%d/%d) Bring it to the Farm Stand"):format(CarryService.Count(player), CarryService.Capacity(player)), "Bad", CARRY.FullToastCooldown)
		return
	end
	local taken = ChestService.TakeMaterials(own, math.min(CARRY.PerTick, room))
	if next(taken) == nil then
		ToastService.SendThrottled(player, "ChestEmpty", "The chest is empty: chop more trees!", "Info", CARRY.FullToastCooldown)
		return
	end
	CarryService.Add(player, taken)
	if CarryService.Room(player) <= 0 then
		ToastService.SendThrottled(player, "CarryFull", ("Hands full! (%d/%d) Bring it to the Farm Stand"):format(CarryService.Count(player), CarryService.Capacity(player)), "Bad", CARRY.FullToastCooldown)
	end
end

-- Saving ---------------------------------------------------------------------------------------------------

function CarryService.GetSaveData(player: Player): { [string]: number }
	local out = {}
	for _, v in folderOf(player):GetChildren() do
		if v:IsA("IntValue") and v.Value > 0 then
			out[v.Name] = v.Value
		end
	end
	return out
end

-- Saved carried materials are given back as they were (even above the capacity, nothing is lost).
function CarryService.ApplySaved(player: Player, data: any)
	if typeof(data) ~= "table" then
		return
	end
	local folder = folderOf(player)
	for id, n in data do
		if typeof(id) == "string" and typeof(n) == "number" and n > 0 and MaterialConfig.IsMaterial(id) then
			local v = folder:FindFirstChild(id) :: IntValue?
			if not v then
				local nv = Instance.new("IntValue")
				nv.Name = id
				nv.Parent = folder
				v = nv
			end
			(v :: IntValue).Value += math.floor(n)
		end
	end
	changed(player)
end

function CarryService.Start()
	local function onPlayer(player: Player)
		folderOf(player)
		changed(player)
		player.CharacterAdded:Connect(function(character)
			character:WaitForChild("UpperTorso", 5)
			drawStack(player)
		end)
		player:GetAttributeChangedSignal("CarryBonus"):Connect(function()
			changed(player)
		end)
		if player.Character then
			drawStack(player)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	task.spawn(function()
		while true do
			task.wait(CARRY.TickInterval)
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(tick, player)
				if not ok then
					warn("[CarryService] " .. tostring(err))
				end
			end
		end
	end)
end

return CarryService
