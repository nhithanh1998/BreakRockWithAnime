-- FruitService: Devil Fruits on the server (see FruitConfig for the rules and numbers).
--
-- Player data:
--   player "Fertilizer" attribute = bags owned (FruitService.AddFertilizer is the one way to add
--     them: Robux packs here, and later gift codes / daily rewards / wheel / missions).
--   player.Fruits.<Id> (IntValue) = copies owned of each fruit. Copies on pads are counted by
--     HeroSlotService (slot attribute "HeroFruit"); a copy can only be on one pad.
--
-- The Devil Tree: each plot gets a "DevilGarden" model (FruitModels.Garden, placed at
-- FruitConfig.GardenOffset) with an E prompt ("FruitPrompt", drawn by SlotPromptUI). The owner's
-- prompt opens the Devil Tree window on the client (Remotes.FruitOpen).
--
-- Remotes.FruitAction (RemoteFunction):
--   ("Grow")             -> { ok, fruit = Id, message }  uses FertilizerPerGrow bags, rolls a fruit
--   ("Buy", amount)      -> prompts the Robux pack with that Amount (FertilizerProducts)
--   ("Equip", fruitId)   -> { ok, message }  puts a free copy on the best pad (HeroSlotService)
-- Remotes.FruitFX (RemoteEvent, server -> all clients): skill effects (HeroWorkerService).

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FruitConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FruitConfig"))
local FruitModels = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FruitModels"))

local PROMPT_NAME = "FruitPrompt"
local GARDEN_NAME = "DevilGarden"

local FruitService = {}

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local function remote(className: string, name: string): any
	local r = Remotes:FindFirstChild(name)
	if not r then
		r = Instance.new(className)
		r.Name = name
		r.Parent = Remotes
	end
	return r
end
local actionRemote = remote("RemoteFunction", "FruitAction") :: RemoteFunction
local openRemote = remote("RemoteEvent", "FruitOpen") :: RemoteEvent
FruitService.FXRemote = remote("RemoteEvent", "FruitFX") :: RemoteEvent

local rng = Random.new()
local lastGrow: { [Player]: number } = {}
local gardens: { [Model]: { model: Model, conn: RBXScriptConnection?, built: boolean } } = {}

-- Fertilizer -------------------------------------------------------------------------------------------

function FruitService.GetFertilizer(player: Player): number
	local n = player:GetAttribute("Fertilizer")
	return if typeof(n) == "number" then n else 0
end

-- Adds (or with a negative amount, removes) bags. Every source of fertilizer goes through here.
function FruitService.AddFertilizer(player: Player, amount: number)
	player:SetAttribute("Fertilizer", math.max(0, FruitService.GetFertilizer(player) + math.floor(amount)))
end

-- Fruits ------------------------------------------------------------------------------------------------

local function fruitsFolder(player: Player): Folder
	local folder = player:FindFirstChild("Fruits")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Fruits"
		folder.Parent = player
	end
	return folder :: Folder
end

-- Copies of `id` this player owns (on pads or not).
function FruitService.Copies(player: Player, id: string): number
	local folder = player:FindFirstChild("Fruits")
	local v = folder and folder:FindFirstChild(id) :: IntValue?
	return if v then v.Value else 0
end

function FruitService.AddFruit(player: Player, id: string, amount: number)
	if not FruitConfig.Get(id) then
		return
	end
	local folder = fruitsFolder(player)
	local v = folder:FindFirstChild(id) :: IntValue?
	if not v then
		local iv = Instance.new("IntValue")
		iv.Name = id
		iv.Parent = folder
		v = iv
	end
	(v :: IntValue).Value = math.max(0, (v :: IntValue).Value + math.floor(amount))
end

-- Saved data (DataService) ---------------------------------------------------------------------------

function FruitService.GetSaveData(player: Player): (number, { [string]: number })
	local fruits = {}
	local folder = player:FindFirstChild("Fruits")
	if folder then
		for _, v in folder:GetChildren() do
			if v:IsA("IntValue") and v.Value > 0 then
				fruits[v.Name] = v.Value
			end
		end
	end
	return FruitService.GetFertilizer(player), fruits
end

-- Added on top of whatever the player got during the load (same as the rest of DataService).
function FruitService.ApplySaved(player: Player, fertilizer: any, fruits: any)
	if typeof(fertilizer) == "number" and fertilizer > 0 then
		FruitService.AddFertilizer(player, fertilizer)
	end
	if typeof(fruits) == "table" then
		for id, n in fruits do
			if typeof(id) == "string" and typeof(n) == "number" and n > 0 then
				FruitService.AddFruit(player, id, n)
			end
		end
	end
end

-- Growing ------------------------------------------------------------------------------------------------

local function grow(player: Player): { [string]: any }
	local now = os.clock()
	if lastGrow[player] and now - lastGrow[player] < FruitConfig.GrowCooldown then
		return { ok = false, message = "Slow down!" }
	end
	if player:GetAttribute("DataLoaded") == false then
		return { ok = false, message = "Your data didn't load, rejoin to grow fruits" }
	end
	local cost = FruitConfig.FertilizerPerGrow
	if FruitService.GetFertilizer(player) < cost then
		return { ok = false, message = ("You need %s!"):format(FruitConfig.FertilizerName) }
	end
	lastGrow[player] = now
	FruitService.AddFertilizer(player, -cost)
	local fruit = FruitConfig.Roll(rng)
	FruitService.AddFruit(player, fruit.Id, 1)
	return { ok = true, fruit = fruit.Id, message = ("You got %s!"):format(fruit.Name) }
end

local function packFor(amount: any): { Amount: number, ProductId: number, Robux: number }?
	for _, pack in FruitConfig.FertilizerProducts do
		if pack.Amount == amount then
			return pack
		end
	end
	return nil
end

-- Robux --------------------------------------------------------------------------------------------------

local productAmount: { [number]: number } = {}
for _, pack in FruitConfig.FertilizerProducts do
	if pack.ProductId ~= 0 then
		productAmount[pack.ProductId] = pack.Amount
	end
end

-- Other features can add their own products here (one ProcessReceipt per game).
FruitService.ProductHandlers = {} :: { [number]: (Player) -> boolean }
for id, amount in productAmount do
	FruitService.ProductHandlers[id] = function(player: Player): boolean
		FruitService.AddFertilizer(player, amount)
		return true
	end
end

local granted: { [string]: boolean } = {} -- receipts already handled this server

local function processReceipt(info: any): Enum.ProductPurchaseDecision
	if granted[info.PurchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	local player = Players:GetPlayerByUserId(info.PlayerId)
	local handler = FruitService.ProductHandlers[info.ProductId]
	if not player or not handler then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- Wait for the save to be loaded so the bags land on top of it.
	local start = os.clock()
	while player.Parent and player:GetAttribute("DataLoaded") == nil and os.clock() - start < 30 do
		task.wait(0.5)
	end
	if not player.Parent or player:GetAttribute("DataLoaded") ~= true then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not handler(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- Save right away so a crash can't lose a paid purchase.
	local DataService = require(script.Parent:WaitForChild("DataService")) :: any
	if not DataService.Save(player) then
		warn(("[FruitService] could not save after purchase %s"):format(tostring(info.PurchaseId)))
	end
	granted[info.PurchaseId] = true
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- Garden on the plot ------------------------------------------------------------------------------------

local function groundY(plot: Model, at: Vector3): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { plot }
	local hit = workspace:Raycast(at + Vector3.new(0, 80, 0), Vector3.new(0, -200, 0), params)
	return if hit then hit.Position.Y else nil
end

-- Walk-in greenhouse around the planter (FruitModels.Greenhouse), standing on the planter's floor
-- level; the sign moves up above the roof so it stays readable.
local function addGreenhouse(garden: Model)
	if garden:FindFirstChild("Greenhouse") then
		return
	end
	local base = garden:FindFirstChild("Base") :: BasePart?
	local ground = if base then base.CFrame * CFrame.new(0, -base.Size.Y / 2, 0) else garden:GetPivot()
	local size = FruitConfig.GreenhouseSize
	local house = FruitModels.Greenhouse(size.X, size.Z, size.Y)
	house:PivotTo(ground)
	house.Parent = garden
	local sign = garden:FindFirstChild("SignAnchor") :: BasePart?
	if sign then
		local roofTop = house:GetAttribute("RoofTop") :: number? or size.Y
		sign.CFrame = ground * CFrame.new(0, roofTop + 4, 0)
	end
end

local function placeGarden(plot: Model): Model
	local existing = plot:FindFirstChild(GARDEN_NAME)
	if existing and existing:IsA("Model") then
		addGreenhouse(existing)
		return existing
	end
	local model = FruitModels.Garden(FruitConfig.GardenSize)
	local pivot = plot:GetPivot()
	local spot = pivot:PointToWorldSpace(FruitConfig.GardenOffset)
	local y = groundY(plot, spot) or spot.Y
	local rot = (pivot - pivot.Position) * CFrame.Angles(0, math.rad(FruitConfig.GardenYaw), 0)
	model:PivotTo(CFrame.new(spot.X, y, spot.Z) * rot)
	model:SetAttribute("Built", true) -- made here (removed again when the plot is reset)
	model.Parent = plot
	addGreenhouse(model)
	return model
end

local function getPrompt(garden: Model): ProximityPrompt
	local anchor = garden:FindFirstChild("PromptPart") or garden.PrimaryPart or garden:FindFirstChildWhichIsA("BasePart")
	local prompt = (anchor :: Instance):FindFirstChild(PROMPT_NAME) :: ProximityPrompt?
	if not prompt then
		local p = Instance.new("ProximityPrompt")
		p.Name = PROMPT_NAME
		p.ObjectText = "Devil Tree"
		p.ActionText = "Grow"
		p.KeyboardKeyCode = Enum.KeyCode.E
		p.Style = Enum.ProximityPromptStyle.Custom
		p.HoldDuration = 0
		p.MaxActivationDistance = FruitConfig.PromptDistance
		p.RequiresLineOfSight = false
		p.Parent = anchor
		prompt = p
	end
	return prompt :: ProximityPrompt
end

function FruitService.SetupPlot(plot: Model, owner: Player)
	FruitService.ResetPlot(plot)
	local garden = placeGarden(plot)
	local prompt = getPrompt(garden)
	prompt.Enabled = true
	local conn = prompt.Triggered:Connect(function(player)
		if player == owner then
			openRemote:FireClient(player)
		end
	end)
	gardens[plot] = { model = garden, conn = conn, built = garden:GetAttribute("Built") == true }
end

function FruitService.ResetPlot(plot: Model)
	local g = gardens[plot]
	gardens[plot] = nil
	if g and g.conn then
		g.conn:Disconnect()
	end
	-- A free plot still shows its Devil Tree, just without a usable prompt.
	local garden = plot:FindFirstChild(GARDEN_NAME)
	if garden and garden:IsA("Model") then
		local prompt = garden:FindFirstChild(PROMPT_NAME, true) :: ProximityPrompt?
		if prompt then
			prompt.Enabled = false
		end
	end
end

-- Start ---------------------------------------------------------------------------------------------------

function FruitService.Start()
	local plots = workspace:FindFirstChild("Plots")
	if plots then
		for _, plot in plots:GetChildren() do
			if plot:IsA("Model") then
				placeGarden(plot)
				FruitService.ResetPlot(plot)
			end
		end
	end

	actionRemote.OnServerInvoke = function(player, action, arg)
		if action == "Grow" then
			return grow(player)
		elseif action == "Buy" then
			local pack = packFor(arg)
			if not pack then
				return { ok = false, message = "Unknown pack" }
			end
			if pack.ProductId == 0 then
				return { ok = false, message = "Coming soon!" }
			end
			MarketplaceService:PromptProductPurchase(player, pack.ProductId)
			return { ok = true }
		elseif action == "Equip" then
			if typeof(arg) ~= "string" or not FruitConfig.Get(arg) then
				return { ok = false, message = "Unknown fruit" }
			end
			local HeroSlotService = require(script.Parent:WaitForChild("HeroSlotService")) :: any
			local ok, message = HeroSlotService.EquipFruitOnBest(player, arg)
			return { ok = ok, message = message }
		end
		return { ok = false, message = "Bad request" }
	end

	MarketplaceService.ProcessReceipt = processReceipt

	local function onPlayer(player: Player)
		fruitsFolder(player)
		if RunService:IsStudio() and FruitConfig.StudioTestFertilizer > 0 then
			-- After the save loads, so a saved amount isn't topped up twice.
			task.spawn(function()
				local start = os.clock()
				while player.Parent and player:GetAttribute("DataLoaded") == nil and os.clock() - start < 15 do
					task.wait(0.5)
				end
				local missing = FruitConfig.StudioTestFertilizer - FruitService.GetFertilizer(player)
				if player.Parent and missing > 0 then
					FruitService.AddFertilizer(player, missing)
				end
			end)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastGrow[player] = nil
	end)
end

return FruitService
