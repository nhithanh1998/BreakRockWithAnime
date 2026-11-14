--!strict
-- DailyRewardService: the 7 Day Login Rewards (rules and rewards in Shared.DailyRewardConfig).
--
-- Player state (also mirrored to player attributes for DailyRewardUI):
--   Unlocked  "DailyUnlocked"  how many days of the streak are unlocked (0..7)
--   Claimed   "DailyClaimed"   bit mask of claimed days (DailyRewardConfig.IsClaimed)
--   LastAt                     os.time() of the last day roll-over (a new day unlocks once
--                              os.time() reaches the start of the next day)
--             "DailyNextAt"    os.time() when the next day starts (the "Next Claim" timer)
-- Saved by DataService as SaveData.Daily = { Unlocked, Claimed, LastAt }.
--
-- Nothing unlocks or can be claimed until the player's save has loaded (attribute DataLoaded = true),
-- so a claim can never be undone by the load. In Studio without DataStore access the player is let
-- in after STUDIO_NO_DATA_WAIT seconds.
--
-- Remotes.DailyRewardAction (RemoteFunction):
--   ("Claim", day)  -> { ok, message?, claimed = { day } }
--   ("ClaimAll")    -> { ok, message?, claimed = { days } }
-- Heroes / materials given also fire Remotes.ItemsAdded so the hotbar "Added!" popups show.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DailyRewardConfig = require(Shared:WaitForChild("DailyRewardConfig"))
local Rewards = require(script.Parent:WaitForChild("Rewards"))
local CHECK_INTERVAL = 15 -- seconds between day roll-over checks for players in the game
local STUDIO_NO_DATA_WAIT = 8

type Reward = DailyRewardConfig.Reward
type State = { Unlocked: number, Claimed: number, LastAt: number? }
type Result = { ok: boolean, message: string?, claimed: { number }? }

local DailyRewardService = {}

local states: { [Player]: State } = {}
local ready: { [Player]: boolean } = {}
local busy: { [Player]: boolean } = {}
local itemsAdded: RemoteEvent? = nil

local MAX = DailyRewardConfig.MaxDays

local function dayLength(): number
	return if RunService:IsStudio() then DailyRewardConfig.StudioDayLength else DailyRewardConfig.DayLength
end

local function dayIndex(t: number): number
	return t // dayLength()
end

local function stateOf(player: Player): State
	local s = states[player]
	if not s then
		s = { Unlocked = 0, Claimed = 0, LastAt = nil }
		states[player] = s
	end
	return s
end

local function allClaimed(s: State): boolean
	for d = 1, MAX do
		if not DailyRewardConfig.IsClaimed(s.Claimed, d) then
			return false
		end
	end
	return true
end

local function publish(player: Player)
	local s = stateOf(player)
	player:SetAttribute("DailyUnlocked", s.Unlocked)
	player:SetAttribute("DailyClaimed", s.Claimed)
	player:SetAttribute("DailyNextAt", (dayIndex(os.time()) + 1) * dayLength())
	player:SetAttribute("DailyReady", ready[player] == true)
end

-- Unlocks the next day of the streak when a new day has started since the last one.
local function rollOver(player: Player)
	if not ready[player] then
		return
	end
	local s = stateOf(player)
	local now = os.time()
	local today = dayIndex(now)
	local last = if s.LastAt then dayIndex(s.LastAt) else nil
	if last == today then
		publish(player)
		return
	end
	local streakDone = s.Unlocked >= MAX and allClaimed(s)
	local missed = last ~= nil and today > last + 1
	if (streakDone and DailyRewardConfig.Loop) or (missed and DailyRewardConfig.ResetIfMissed) then
		s.Unlocked = 0
		s.Claimed = 0
	end
	if s.Unlocked < MAX then
		s.Unlocked += 1
	end
	s.LastAt = now
	publish(player)
end

-- Rewards -------------------------------------------------------------------------------------------

-- One reward (shared with the Index rewards: server/Rewards.luau, which also knows "Potion").
local function give(player: Player, reward: Reward, popups: { any })
	Rewards.Give(player, reward, popups)
end

local function claimDays(player: Player, days: { number }): Result
	if not ready[player] then
		return { ok = false, message = "Still loading your data, try again in a moment." }
	end
	if busy[player] then
		return { ok = false }
	end
	busy[player] = true
	rollOver(player)
	local s = stateOf(player)
	local claimed = {}
	local popups = {}
	for _, day in days do
		if day >= 1 and day <= s.Unlocked and not DailyRewardConfig.IsClaimed(s.Claimed, day) then
			s.Claimed = DailyRewardConfig.SetClaimed(s.Claimed, day)
			for _, reward in DailyRewardConfig.Days[day].Rewards do
				give(player, reward, popups)
			end
			table.insert(claimed, day)
		end
	end
	publish(player)
	busy[player] = nil
	if #claimed == 0 then
		return { ok = false, message = "Nothing to claim yet. Come back tomorrow!" }
	end
	if #popups > 0 and itemsAdded then
		itemsAdded:FireClient(player, popups)
	end
	return { ok = true, claimed = claimed }
end

local function onAction(player: Player, action: any, arg: any): Result
	if action == "Claim" then
		local day = tonumber(arg)
		if not day or day ~= math.floor(day) then
			return { ok = false }
		end
		return claimDays(player, { day })
	elseif action == "ClaimAll" then
		local all = {}
		for d = 1, MAX do
			table.insert(all, d)
		end
		return claimDays(player, all)
	end
	return { ok = false }
end

-- Saved data (DataService) ---------------------------------------------------------------------------

function DailyRewardService.GetSaveData(player: Player): State?
	local s = states[player]
	if not s then
		return nil
	end
	return { Unlocked = s.Unlocked, Claimed = s.Claimed, LastAt = s.LastAt }
end

function DailyRewardService.ApplySaved(player: Player, data: any)
	if typeof(data) ~= "table" then
		return
	end
	local s = stateOf(player)
	if typeof(data.Unlocked) == "number" then
		s.Unlocked = math.clamp(math.floor(data.Unlocked), 0, MAX)
	end
	if typeof(data.Claimed) == "number" then
		s.Claimed = math.floor(data.Claimed)
	end
	if typeof(data.LastAt) == "number" then
		-- A LastAt in the future (clock skew) would block every new day; treat it as now.
		s.LastAt = math.min(data.LastAt, os.time())
	end
end

-- DataService calls this after the leave-save (the state must still be there when it collects).
function DailyRewardService.Forget(player: Player)
	states[player] = nil
	ready[player] = nil
	busy[player] = nil
end

-- Lifecycle -----------------------------------------------------------------------------------------

local function markReady(player: Player)
	if ready[player] or not player.Parent then
		return
	end
	ready[player] = true
	rollOver(player)
end

local function onJoin(player: Player)
	stateOf(player)
	publish(player)
	if player:GetAttribute("DataLoaded") == true then
		markReady(player)
	end
	player:GetAttributeChangedSignal("DataLoaded"):Connect(function()
		if player:GetAttribute("DataLoaded") == true then
			markReady(player)
		end
	end)
	if RunService:IsStudio() then
		task.delay(STUDIO_NO_DATA_WAIT, function()
			-- nil = DataService never tried (no DataStore access); false = the load failed. Studio
			-- sessions without API access are not saved anyway, so let the rewards be tested.
			if player.Parent and player:GetAttribute("DataLoaded") ~= true then
				warn("[DailyRewardService] no saved data in Studio; daily rewards run without saving")
				markReady(player)
			end
		end)
	end
end

function DailyRewardService.Start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:FindFirstChild("DailyRewardAction") :: RemoteFunction?
	if not remote then
		local r = Instance.new("RemoteFunction")
		r.Name = "DailyRewardAction"
		r.Parent = remotes
		remote = r
	end
	(remote :: RemoteFunction).OnServerInvoke = onAction
	itemsAdded = remotes:WaitForChild("ItemsAdded") :: RemoteEvent

	Players.PlayerAdded:Connect(onJoin)
	for _, player in Players:GetPlayers() do
		task.spawn(onJoin, player)
	end
	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			for _, player in Players:GetPlayers() do
				rollOver(player)
			end
		end
	end)
end

return DailyRewardService
