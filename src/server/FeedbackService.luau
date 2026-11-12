--!strict
-- FeedbackService: saves what players write at the Feedback stall (plot.Shops.Feedback,
-- ShopConfig.Shops.Feedback). The client window (FeedbackUI) calls Remotes.FeedbackAction:
--   ("Send", { Category = "Bug" | "Idea" | "Other", Rating = 1..5, Text = string })
--   -> { ok: boolean, message: string? }
-- Checks: the player stands near the stall, text length (ShopConfig.Feedback.MinLength..MaxLength),
-- a cooldown and a per-session limit. Each message is one key in the DataStore
-- ShopConfig.Feedback.DataStore ("<unix time>_<UserId>_<n>") and is also printed to the server log.
--
-- Reading the feedback (Studio command bar, with "Enable Studio Access to API Services" on):
--[[
local ds = game:GetService("DataStoreService"):GetDataStore("GameFeedback_v1")
local pages = ds:ListKeysAsync()
while true do
	for _, key in pages:GetCurrentPage() do
		local v = ds:GetAsync(key.KeyName)
		print(os.date("%Y-%m-%d %H:%M", v.Time), v.Category, ("%d★"):format(v.Rating), v.Name, v.UserId, v.Text)
	end
	if pages.IsFinished then break end
	pages:AdvanceToNextPageAsync()
end
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShopConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ShopConfig"))
local ShopService = require(script.Parent:WaitForChild("ShopService"))

local CONFIG = ShopConfig.Feedback

type Result = { ok: boolean, message: string? }

local FeedbackService = {}

local store: DataStore? = nil
local lastSent: { [Player]: number } = {}
local sentCount: { [Player]: number } = {}
local counter = 0

local function getStore(): DataStore?
	if not store then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(CONFIG.DataStore)
		end)
		if ok then
			store = result
		else
			warn("[FeedbackService] DataStore unavailable: " .. tostring(result))
		end
	end
	return store
end

local function isNear(player: Player): boolean
	local shop = ShopService.FindShop(player, "Feedback")
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not shop or not root then
		return false
	end
	local anchor = shop:FindFirstChild("PromptPart")
	local pos = if anchor and anchor:IsA("BasePart") then anchor.Position else shop:GetPivot().Position
	return (root.Position - pos).Magnitude <= ShopConfig.CloseDistance + 8
end

local function send(player: Player, data: any): Result
	if typeof(data) ~= "table" then
		return { ok = false }
	end
	local category = data.Category
	if typeof(category) ~= "string" or not table.find(CONFIG.Categories, category) then
		category = "Other"
	end
	local rating = tonumber(data.Rating) or 0
	rating = math.clamp(math.floor(rating), 0, 5)
	local text = data.Text
	if typeof(text) ~= "string" then
		return { ok = false, message = "Write something first!" }
	end
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	if utf8.len(text) == nil then
		return { ok = false, message = "That text can't be sent." }
	end
	if (utf8.len(text) :: number) < CONFIG.MinLength then
		return { ok = false, message = ("Please write at least %d characters."):format(CONFIG.MinLength) }
	end
	if (utf8.len(text) :: number) > CONFIG.MaxLength then
		return { ok = false, message = ("Max %d characters."):format(CONFIG.MaxLength) }
	end
	if not isNear(player) then
		return { ok = false, message = "Walk up to the Feedback stall." }
	end
	if (sentCount[player] or 0) >= CONFIG.MaxPerSession then
		return { ok = false, message = "Thanks! You've sent a lot already, come back next time." }
	end
	local wait = CONFIG.Cooldown - (os.clock() - (lastSent[player] or -math.huge))
	if wait > 0 then
		return { ok = false, message = ("Please wait %ds before sending again."):format(math.ceil(wait)) }
	end

	local entry = {
		UserId = player.UserId,
		Name = player.Name,
		Category = category,
		Rating = rating,
		Text = text,
		Time = os.time(),
		PlaceVersion = game.PlaceVersion,
		Zone = player:GetAttribute("UnlockedZones"),
	}
	print(("[Feedback] %s (%d) %s %d★: %s"):format(player.Name, player.UserId, category, rating, text))

	local ds = getStore()
	if not ds then
		return { ok = false, message = "Couldn't send right now, try again later." }
	end
	counter += 1
	local key = ("%d_%d_%d"):format(entry.Time, player.UserId, counter)
	local ok, err = pcall(function()
		(ds :: DataStore):SetAsync(key, entry, { player.UserId })
	end)
	if not ok then
		warn("[FeedbackService] save failed: " .. tostring(err))
		return { ok = false, message = "Couldn't send right now, try again later." }
	end
	lastSent[player] = os.clock()
	sentCount[player] = (sentCount[player] or 0) + 1
	return { ok = true, message = "Thanks for your feedback!" }
end

local function onAction(player: Player, action: any, data: any): Result
	if action == "Send" then
		return send(player, data)
	end
	return { ok = false }
end

function FeedbackService.Start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:FindFirstChild("FeedbackAction") :: RemoteFunction?
	if not remote then
		local newRemote = Instance.new("RemoteFunction")
		newRemote.Name = "FeedbackAction"
		newRemote.Parent = remotes
		remote = newRemote
	end
	(remote :: RemoteFunction).OnServerInvoke = onAction
	Players.PlayerRemoving:Connect(function(player)
		lastSent[player] = nil
		sentCount[player] = nil
	end)
end

return FeedbackService
