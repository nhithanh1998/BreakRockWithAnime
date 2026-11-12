-- ZoneBoardService: unlocking and swapping zones from the Zones board on each plot.
--
-- Player attributes (saved by DataService):
--   UnlockedZones = highest zone unlocked (default 1)
--   CurrentZone   = zone the player's plot is set to (default 1)
-- The plot mirrors them as attributes "Zone" (ZoneLoader / TreeService react to it) and
-- "UnlockedZones" (ZoneBoardUI draws the board from it, so everyone sees the owner's board).
--
-- Remotes.ZoneAction (RemoteFunction), from ZoneBoardUI:
--   ("Unlock", zone) -> buys the next zone (must be UnlockedZones + 1) and travels there
--   ("Travel", zone) -> swaps the plot to an unlocked zone
-- Returns ok: boolean, message: string?

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ZoneConfig = require(Shared:WaitForChild("ZoneConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))
local PlotService = require(script.Parent:WaitForChild("PlotService"))

local SWAP_COOLDOWN = 1.5 -- seconds between zone changes (rebuilding a plot is not free)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local remote = Remotes:FindFirstChild("ZoneAction") :: RemoteFunction?
if not remote then
	local r = Instance.new("RemoteFunction")
	r.Name = "ZoneAction"
	r.Parent = Remotes
	remote = r
end

local ZoneBoardService = {}

local lastSwap: { [Player]: number } = {}
local connections: { [Player]: { RBXScriptConnection } } = {}

local function unlockedZones(player: Player): number
	local n = player:GetAttribute("UnlockedZones")
	n = if typeof(n) == "number" then math.floor(n) else 1
	return math.clamp(n, 1, ZoneConfig.Count())
end

local function currentZone(player: Player): number
	local n = player:GetAttribute("CurrentZone")
	n = if typeof(n) == "number" then math.floor(n) else 1
	return math.clamp(n, 1, unlockedZones(player))
end

-- Copies the player's zone state onto their plot.
local function sync(player: Player)
	local plot = PlotService.GetPlot(player)
	if not plot then
		return
	end
	plot:SetAttribute("UnlockedZones", unlockedZones(player))
	local zone = currentZone(player)
	if plot:GetAttribute("Zone") ~= zone then
		plot:SetAttribute("Zone", zone)
	end
end

local function travel(player: Player, zone: number): (boolean, string?)
	if zone > unlockedZones(player) then
		return false, "Zone is locked"
	end
	if zone == currentZone(player) then
		return true, nil
	end
	local now = os.clock()
	if now - (lastSwap[player] or 0) < SWAP_COOLDOWN then
		return false, "Slow down!"
	end
	lastSwap[player] = now
	player:SetAttribute("CurrentZone", zone) -- sync() runs from the attribute signal
	return true, nil
end

local function unlock(player: Player, zone: number): (boolean, string?)
	local info = ZoneConfig.Get(zone)
	if not info then
		return false, "Unknown zone"
	end
	local unlocked = unlockedZones(player)
	if zone <= unlocked then
		return travel(player, zone)
	end
	if zone ~= unlocked + 1 then
		return false, ("Unlock %s first"):format(ZoneConfig.Zones[zone - 1].Name)
	end
	if not ChestService.SpendMoney(player, info.Price) then
		local short = math.ceil(info.Price - ChestService.GetMoney(player))
		return false, ("Need $%s more!"):format(HeroConfig.Abbreviate(short))
	end
	player:SetAttribute("UnlockedZones", zone)
	lastSwap[player] = 0
	return travel(player, zone)
end

local function onInvoke(player: Player, action: any, zone: any): (boolean, string?)
	if typeof(zone) ~= "number" or zone ~= zone then
		return false, nil
	end
	zone = math.floor(zone)
	if not ZoneConfig.Get(zone) or not PlotService.GetPlot(player) then
		return false, nil
	end
	if action == "Unlock" then
		return unlock(player, zone)
	elseif action == "Travel" then
		return travel(player, zone)
	end
	return false, nil
end

-- Plot claimed: show the owner's zone (saved data may arrive a little later; the signals catch it).
function ZoneBoardService.SetupPlot(_plot: Model, player: Player)
	local list = connections[player]
	if list then
		for _, c in list do
			c:Disconnect()
		end
	end
	connections[player] = {
		player:GetAttributeChangedSignal("UnlockedZones"):Connect(function()
			sync(player)
		end),
		player:GetAttributeChangedSignal("CurrentZone"):Connect(function()
			sync(player)
		end),
	}
	sync(player)
end

-- Plot released: back to the starting zone so the next owner starts clean.
function ZoneBoardService.ResetPlot(plot: Model)
	plot:SetAttribute("UnlockedZones", 1)
	if plot:GetAttribute("Zone") ~= 1 then
		plot:SetAttribute("Zone", 1)
	end
end

function ZoneBoardService.Start()
	local plots = workspace:FindFirstChild("Plots")
	if plots then
		for _, plot in plots:GetChildren() do
			if plot:IsA("Model") and plot:GetAttribute("UnlockedZones") == nil then
				plot:SetAttribute("UnlockedZones", 1)
			end
		end
	end
	local zoneAction = remote :: RemoteFunction
	zoneAction.OnServerInvoke = onInvoke
	Players.PlayerRemoving:Connect(function(player)
		lastSwap[player] = nil
		local list = connections[player]
		connections[player] = nil
		if list then
			for _, c in list do
				c:Disconnect()
			end
		end
	end)
end

return ZoneBoardService
