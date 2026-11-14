-- PotionService: owning and drinking potions (PotionConfig has the list and the rules).
--
-- Player data:
--   player.Potions.<Id> (IntValue) = potions owned (PotionService.Add is the one way to give them:
--     Index rewards, Daily rewards, later shop / codes ...).
--   player attribute "PotionEnd_<Id>" = server time the active potion runs out (PotionConfig.TimeLeft).
--
-- Remotes.PotionAction (RemoteFunction):
--   ("Use", id) -> { ok, message }   drinks one: adds its Duration to the timer (max MaxStack x Duration)
--
-- The boosts themselves are read where they apply through PotionConfig.Mult (TreeHitService,
-- HeroWorkerService, ShopService, SkillTreeConfig).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PotionConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PotionConfig"))

local PotionService = {}

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local actionRemote = Remotes:FindFirstChild("PotionAction") :: RemoteFunction?
if not actionRemote then
	local r = Instance.new("RemoteFunction")
	r.Name = "PotionAction"
	r.Parent = Remotes
	actionRemote = r
end

local function now(): number
	return workspace:GetServerTimeNow()
end

local function folderOf(player: Player): Folder
	local folder = player:FindFirstChild("Potions")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Potions"
		folder.Parent = player
	end
	return folder :: Folder
end

function PotionService.Count(player: Player, id: string): number
	local folder = player:FindFirstChild("Potions")
	local v = folder and folder:FindFirstChild(id)
	return if v and v:IsA("IntValue") then v.Value else 0
end

-- Adds (or with a negative amount, removes) potions. Returns false for an unknown id.
function PotionService.Add(player: Player, id: string, amount: number): boolean
	if not PotionConfig.Get(id) then
		warn("[PotionService] unknown potion " .. tostring(id))
		return false
	end
	local folder = folderOf(player)
	local v = folder:FindFirstChild(id) :: IntValue?
	if not v then
		local iv = Instance.new("IntValue")
		iv.Name = id
		iv.Parent = folder
		v = iv
	end
	(v :: IntValue).Value = math.max(0, (v :: IntValue).Value + math.floor(amount))
	return true
end

-- Adds `seconds` to the potion's timer (starting it if it isn't running), capped at MaxStack durations.
local function extend(player: Player, def: PotionConfig.PotionDef, seconds: number)
	local left = PotionConfig.TimeLeft(player, def.Id)
	local total = math.min(left + seconds, def.Duration * PotionConfig.MaxStack)
	player:SetAttribute(PotionConfig.AttributePrefix .. def.Id, now() + total)
end

local function use(player: Player, id: any): { [string]: any }
	local def = typeof(id) == "string" and PotionConfig.Get(id)
	if not def then
		return { ok = false, message = "Unknown potion" }
	end
	if player:GetAttribute("DataLoaded") == false then
		return { ok = false, message = "Your data didn't load, rejoin first" }
	end
	if PotionService.Count(player, def.Id) <= 0 then
		return { ok = false, message = "You don't have any!" }
	end
	if PotionConfig.TimeLeft(player, def.Id) >= def.Duration * (PotionConfig.MaxStack - 1) + 1 then
		return { ok = false, message = "That potion is already stacked to the max" }
	end
	PotionService.Add(player, def.Id, -1)
	extend(player, def, def.Duration)
	return { ok = true, message = ("%s active! %s"):format(def.Name, def.Desc) }
end

-- Saved data (DataService) ---------------------------------------------------------------------------

-- (owned counts, seconds left on each active potion)
function PotionService.GetSaveData(player: Player): ({ [string]: number }, { [string]: number })
	local owned, active = {}, {}
	local folder = player:FindFirstChild("Potions")
	for _, v in if folder then folder:GetChildren() else {} do
		if v:IsA("IntValue") and v.Value > 0 then
			owned[v.Name] = v.Value
		end
	end
	for _, def in PotionConfig.Potions do
		local left = PotionConfig.TimeLeft(player, def.Id)
		if left >= 1 then
			active[def.Id] = math.floor(left)
		end
	end
	return owned, active
end

-- Added on top of whatever the player got during the load (like the rest of DataService).
function PotionService.ApplySaved(player: Player, owned: any, active: any)
	if typeof(owned) == "table" then
		for id, n in owned do
			if typeof(id) == "string" and typeof(n) == "number" and n > 0 and PotionConfig.Get(id) then
				PotionService.Add(player, id, n)
			end
		end
	end
	if typeof(active) == "table" then
		for id, seconds in active do
			local def = typeof(id) == "string" and PotionConfig.Get(id)
			if def and typeof(seconds) == "number" and seconds > 0 then
				extend(player, def, seconds)
			end
		end
	end
end

-- Start -------------------------------------------------------------------------------------------------

function PotionService.Start()
	(actionRemote :: RemoteFunction).OnServerInvoke = function(player, action, arg)
		if action == "Use" then
			return use(player, arg)
		end
		return { ok = false, message = "Bad request" }
	end

	local function onPlayer(player: Player)
		folderOf(player)
		if RunService:IsStudio() and PotionConfig.StudioTestAmount > 0 then
			-- After the save loads, so saved potions aren't topped up twice.
			task.spawn(function()
				local start = os.clock()
				while player.Parent and player:GetAttribute("DataLoaded") == nil and os.clock() - start < 15 do
					task.wait(0.5)
				end
				if not player.Parent then
					return
				end
				for _, def in PotionConfig.Potions do
					local missing = PotionConfig.StudioTestAmount - PotionService.Count(player, def.Id)
					if missing > 0 then
						PotionService.Add(player, def.Id, missing)
					end
				end
			end)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
end

return PotionService
