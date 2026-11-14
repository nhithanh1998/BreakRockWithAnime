-- HeroChatter: the working heroes (chopping trees, carrying stock: the models HeroMotion draws, tag
-- "ClientMoved") say something now and then, on this client only, so the plots feel alive.
-- Each hero talks every ChatConfig.Worker.Min..Max seconds while it is within Range of the camera; at
-- most MaxTalking bubbles at once. Sometimes another hero in the same folder (same plot) answers.
-- Lines / emojis: ChatConfig.Worker; bubbles: ChatBubble.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ChatConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ChatConfig"))
local ChatBubble = require(script.Parent:WaitForChild("ChatBubble"))

local TAG = "ClientMoved"
local CFG = ChatConfig.Worker
local OFFSET = ChatConfig.Bubble.HeroOffset
local TICK = 0.5

local rng = Random.new()
local nextTalk: { [Model]: number } = {}
local talking = 0

local function headOf(model: Model): BasePart?
	local head = model:FindFirstChild("Head")
	return if head and head:IsA("BasePart") then head else nil
end

local function near(head: BasePart): boolean
	local cam = workspace.CurrentCamera
	return cam ~= nil and (cam.CFrame.Position - head.Position).Magnitude <= CFG.Range
end

local function say(head: BasePart, text: string)
	talking += 1
	ChatBubble.Say(head, text, nil, OFFSET)
	task.delay(ChatConfig.Bubble.Time, function()
		talking -= 1
	end)
end

local function reply(model: Model)
	local folder = model.Parent
	if not folder then
		return
	end
	local others = {}
	for _, m in folder:GetChildren() do
		local head = m:IsA("Model") and m ~= model and headOf(m)
		if head and CollectionService:HasTag(m, TAG) and near(head) and not ChatBubble.Talking(head) then
			table.insert(others, m)
		end
	end
	if #others == 0 or talking >= CFG.MaxTalking then
		return
	end
	local other = others[rng:NextInteger(1, #others)]
	local head = headOf(other)
	if head then
		say(head, ChatBubble.Line(CFG.Replies, CFG.ReplyMood))
		nextTalk[other] = os.clock() + rng:NextNumber(CFG.Min, CFG.Max)
	end
end

local function talk(model: Model, head: BasePart)
	local mood = if rng:NextNumber() < 0.6 then "Work" else "Chill"
	say(head, ChatBubble.Line(CFG.Lines[mood], mood))
	if rng:NextNumber() < CFG.ReplyChance then
		task.delay(CFG.ReplyDelay, reply, model)
	end
end

while true do
	task.wait(TICK)
	local now = os.clock()
	for _, model in CollectionService:GetTagged(TAG) do
		if not model:IsA("Model") or not model:IsDescendantOf(workspace) then
			continue
		end
		local due = nextTalk[model]
		if not due then
			-- first sight: start at a random point of the wait, so heroes don't all talk together
			nextTalk[model] = now + rng:NextNumber(2, CFG.Max)
			continue
		end
		if now < due then
			continue
		end
		nextTalk[model] = now + rng:NextNumber(CFG.Min, CFG.Max)
		local head = headOf(model)
		if head and talking < CFG.MaxTalking and near(head) and not ChatBubble.Talking(head) then
			talk(model, head)
		end
	end
	for model in nextTalk do
		if not model.Parent then
			nextTalk[model] = nil
		end
	end
end
