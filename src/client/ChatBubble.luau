-- ChatBubble: speech bubbles over NPC heads, on this client only (customers, stand keepers, workers).
--
--   ChatBubble.Say(head, text, time?, offset?)  shows `text` over `head` for `time` seconds (it pops in,
--                                               then fades); a new line replaces the head's old one.
--   ChatBubble.Line(lines, mood)                a random line, now and then with an emoji at the end
--   ChatBubble.Talking(head)                    true while `head` has a bubble
-- Lines, emojis, sizes: ChatConfig.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")

local ChatConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ChatConfig"))

local CFG = ChatConfig.Bubble
local NAME = "ChatBubble"
local FONT = Enum.Font.GothamBold
local PAD_X, PAD_Y = 12, 6
local TAIL = 10 -- pixels

local ChatBubble = {}

local rng = Random.new()

-- Emojis are drawn wider than GetTextSize says; count each non-ASCII character a bit wider.
local function measure(text: string): Vector2
	local size = TextService:GetTextSize(text, CFG.TextSize, FONT, Vector2.new(CFG.MaxWidth - PAD_X * 2, 1000))
	local extra = 0
	for _, code in utf8.codes(text) do
		if code > 0x2000 then
			extra += 6
		end
	end
	return Vector2.new(math.min(size.X + extra, CFG.MaxWidth - PAD_X * 2), size.Y)
end

local function endsWithEmoji(text: string): boolean
	local last = 0
	for _, code in utf8.codes(text) do
		last = code
	end
	return last > 0x2000 or text:sub(-2) == ":(" or text:sub(-2) == ":)"
end

function ChatBubble.Line(lines: { string }, mood: string?): string
	local text = lines[rng:NextInteger(1, #lines)]
	local emojis = mood and ChatConfig.Emojis[mood]
	if emojis and #emojis > 0 and not endsWithEmoji(text) and rng:NextNumber() < ChatConfig.EmojiChance then
		text ..= " " .. emojis[rng:NextInteger(1, #emojis)]
	end
	return text
end

function ChatBubble.Talking(head: Instance): boolean
	return head:FindFirstChild(NAME) ~= nil
end

function ChatBubble.Say(head: BasePart, text: string, time: number?, offset: number?): BillboardGui
	local old = head:FindFirstChild(NAME)
	if old then
		old:Destroy()
	end
	local textSize = measure(text)
	local w, h = textSize.X + PAD_X * 2, textSize.Y + PAD_Y * 2

	local gui = Instance.new("BillboardGui")
	gui.Name = NAME
	gui.Adornee = head
	gui.Size = UDim2.fromOffset(w, h + TAIL)
	gui.StudsOffset = Vector3.new(0, offset or CFG.CustomerOffset, 0)
	gui.MaxDistance = CFG.MaxDistance
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false

	local root = Instance.new("Frame")
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = root
	local group = Instance.new("CanvasGroup")
	group.BackgroundTransparency = 1
	group.Size = UDim2.fromScale(1, 1)
	group.Parent = root

	local tail = Instance.new("Frame")
	tail.AnchorPoint = Vector2.new(0.5, 0.5)
	tail.Position = UDim2.new(0.5, 0, 1, -TAIL - 1)
	tail.Size = UDim2.fromOffset(TAIL * 1.4, TAIL * 1.4)
	tail.Rotation = 45
	tail.BackgroundColor3 = Color3.new(1, 1, 1)
	tail.BorderSizePixel = 0
	tail.Parent = group

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 1, -TAIL)
	frame.BackgroundColor3 = Color3.new(1, 1, 1)
	frame.BorderSizePixel = 0
	frame.Parent = group
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, math.min(14, h / 2))
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(60, 60, 75)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.6
	stroke.Parent = frame

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(PAD_X, PAD_Y)
	label.Size = UDim2.new(1, -PAD_X * 2, 1, -PAD_Y * 2)
	label.Font = FONT
	label.TextSize = CFG.TextSize
	label.TextWrapped = true
	label.TextColor3 = Color3.fromRGB(40, 40, 50)
	label.Text = text
	label.Parent = frame

	gui.Parent = head
	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	local life = time or CFG.Time
	task.delay(math.max(life - 0.3, 0), function()
		if gui.Parent then
			TweenService:Create(group, TweenInfo.new(0.3), { GroupTransparency = 1 }):Play()
			task.delay(0.3, function()
				gui:Destroy()
			end)
		end
	end)
	return gui
end

return ChatBubble
