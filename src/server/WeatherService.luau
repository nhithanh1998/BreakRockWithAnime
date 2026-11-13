-- WeatherService: runs the server-wide weather (WeatherConfig).
--
-- Every Interval seconds there is one weather: it starts at a random moment inside the interval and
-- lasts Duration seconds (Studio playtests use WeatherConfig.Studio: the first one comes after
-- FirstDelay seconds). The state lives in ReplicatedStorage attributes so everyone can read it:
--   "Weather"      = weather Id ("" when clear)
--   "WeatherEnds"  = workspace:GetServerTimeNow() when it ends
--   "WeatherNext"  = when the next one starts
-- The buffs are read where they apply through WeatherConfig.Mult (TreeHitService, HeroWorkerService,
-- SkillTreeConfig.MaterialValue, ShopService). Clients draw the effects and the banner (WeatherFX /
-- WeatherUI).
--
--   WeatherService.Force(id, duration?)  start a weather now (testing / admin / events)
--   WeatherService.Stop()                end the current one now

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeatherConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeatherConfig"))
local HeroWorkerService = require(script.Parent:WaitForChild("HeroWorkerService"))

local WeatherService = {}

local rng = Random.new()
local last: string? = nil
local token = 0 -- bumps on every start / stop so an old timer can't end a newer weather

local function now(): number
	return workspace:GetServerTimeNow()
end

local function setNext(at: number)
	ReplicatedStorage:SetAttribute("WeatherNext", at)
end

function WeatherService.Stop()
	token += 1
	ReplicatedStorage:SetAttribute("Weather", "")
	ReplicatedStorage:SetAttribute("WeatherEnds", 0)
	HeroWorkerService.ApplyAll()
end

function WeatherService.Force(id: string, duration: number?): boolean
	local def = WeatherConfig.Get(id)
	if not def then
		return false
	end
	token += 1
	local mine = token
	local _, defaultDuration = WeatherConfig.Timing()
	local length = duration or defaultDuration
	last = def.Id
	ReplicatedStorage:SetAttribute("WeatherEnds", now() + length)
	ReplicatedStorage:SetAttribute("Weather", def.Id)
	HeroWorkerService.ApplyAll() -- hero walk speed / HeroBar power follow the buffs
	task.delay(length, function()
		if token == mine then
			WeatherService.Stop()
		end
	end)
	return true
end

function WeatherService.Start()
	ReplicatedStorage:SetAttribute("Weather", "")
	ReplicatedStorage:SetAttribute("WeatherEnds", 0)
	task.spawn(function()
		local interval, duration, firstDelay = WeatherConfig.Timing()
		-- Interval windows; the weather lands somewhere inside each one.
		local windowStart = now()
		local startAt = if firstDelay then windowStart + firstDelay else windowStart + rng:NextNumber(0, interval - duration)
		while true do
			setNext(startAt)
			while now() < startAt do
				task.wait(math.min(5, math.max(0.1, startAt - now())))
			end
			-- A weather started by Force (event / admin) is still on: let it finish first.
			if WeatherConfig.Current() then
				local ends = ReplicatedStorage:GetAttribute("WeatherEnds")
				startAt = (if typeof(ends) == "number" then ends else now()) + 5
				continue
			end
			WeatherService.Force(WeatherConfig.Roll(rng, last).Id, duration)
			windowStart += interval
			-- Next window: a random moment in it, but never before this weather has ended.
			startAt = math.max(windowStart + rng:NextNumber(0, interval - duration), now() + duration + 5)
		end
	end)
end

return WeatherService
