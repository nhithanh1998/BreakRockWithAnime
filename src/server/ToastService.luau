-- ToastService: short messages that pop up for one player (ToastUI on the client).
--
--   ToastService.Send(player, text, kind?)   kind = "Info" | "Good" | "Bad" (colour), default "Info"
--   ToastService.SendThrottled(player, key, text, kind?, cooldown)   at most once per `cooldown` s per key
-- Remotes.Toast (RemoteEvent, server -> client): (text, kind)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ToastService = {}

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local remote = remotes:FindFirstChild("Toast") :: RemoteEvent?
if not remote then
	local r = Instance.new("RemoteEvent")
	r.Name = "Toast"
	r.Parent = remotes
	remote = r
end

local last: { [Player]: { [string]: number } } = {}

function ToastService.Send(player: Player, text: string, kind: string?)
	(remote :: RemoteEvent):FireClient(player, text, kind or "Info")
end

function ToastService.SendThrottled(player: Player, key: string, text: string, kind: string?, cooldown: number)
	local mine = last[player]
	if not mine then
		mine = {}
		last[player] = mine
	end
	local now = os.clock()
	if now - (mine[key] or -math.huge) < cooldown then
		return
	end
	mine[key] = now
	ToastService.Send(player, text, kind)
end

Players.PlayerRemoving:Connect(function(player)
	last[player] = nil
end)

return ToastService
