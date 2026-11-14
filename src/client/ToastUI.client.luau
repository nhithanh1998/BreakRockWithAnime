-- ToastUI: short messages from the server (Remotes.Toast, ToastService) that pop in at the top of the
-- screen, stack up (newest at the bottom, at most MAX_SHOWN) and fade out after SHOW_TIME seconds.
-- The same text arriving again while it is shown just bumps the existing toast instead of stacking.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Toast") :: RemoteEvent
local player = Players.LocalPlayer

local SHOW_TIME = 2.6
local MAX_SHOWN = 4
local COLORS = {
	Info = Color3.fromRGB(255, 255, 255),
	Good = Color3.fromRGB(110, 255, 120),
	Bad = Color3.fromRGB(255, 110, 100),
}

local gui = Instance.new("ScreenGui")
gui.Name = "ToastGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 20
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local list = Instance.new("Frame")
list.Name = "Toasts"
list.BackgroundTransparency = 1
list.AnchorPoint = Vector2.new(0.5, 0)
list.Position = UDim2.new(0.5, 0, 0, 70)
list.Size = UDim2.fromOffset(520, 200)
list.Parent = gui
local layout = Instance.new("UIListLayout")
layout.VerticalAlignment = Enum.VerticalAlignment.Top
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 6)
layout.Parent = list

local order = 0
local shown: { [string]: { frame: Frame, scale: UIScale, expires: number } } = {}

local function pop(scale: UIScale)
	scale.Scale = 0.6
	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function fadeOut(text: string, entry: { frame: Frame, scale: UIScale, expires: number })
	task.delay(SHOW_TIME, function()
		if shown[text] ~= entry or os.clock() < entry.expires then
			return
		end
		shown[text] = nil
		local label = entry.frame:FindFirstChildOfClass("TextLabel")
		local info = TweenInfo.new(0.3)
		TweenService:Create(entry.scale, info, { Scale = 0.7 }):Play()
		if label then
			TweenService:Create(label, info, { TextTransparency = 1 }):Play()
			local stroke = label:FindFirstChildOfClass("UIStroke")
			if stroke then
				TweenService:Create(stroke, info, { Transparency = 1 }):Play()
			end
		end
		TweenService:Create(entry.frame, info, { BackgroundTransparency = 1 }):Play()
		task.wait(0.3)
		entry.frame:Destroy()
	end)
end

local function show(text: string, kind: string)
	local existing = shown[text]
	if existing then
		existing.expires = os.clock() + SHOW_TIME - 0.05
		pop(existing.scale)
		fadeOut(text, existing)
		return
	end
	order += 1
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = Color3.fromRGB(25, 27, 34)
	frame.BackgroundTransparency = 0.25
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.Size = UDim2.fromOffset(0, 40)
	frame.LayoutOrder = order
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 16)
	pad.PaddingRight = UDim.new(0, 16)
	pad.Parent = frame
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromScale(0, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextSize = 24
	label.TextColor3 = COLORS[kind] or COLORS.Info
	label.Text = text
	label.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(10, 10, 14)
	stroke.Parent = label
	local scale = Instance.new("UIScale")
	scale.Parent = frame
	frame.Parent = list
	pop(scale)
	local entry = { frame = frame, scale = scale, expires = os.clock() + SHOW_TIME - 0.05 }
	shown[text] = entry
	fadeOut(text, entry)
	-- Too many: the oldest goes right away.
	local frames = {}
	for _, c in list:GetChildren() do
		if c:IsA("Frame") then
			table.insert(frames, c)
		end
	end
	if #frames > MAX_SHOWN then
		table.sort(frames, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		for t, e in shown do
			if e.frame == frames[1] then
				shown[t] = nil
			end
		end
		frames[1]:Destroy()
	end
end

remote.OnClientEvent:Connect(function(text: any, kind: any)
	if typeof(text) == "string" then
		show(text, if typeof(kind) == "string" then kind else "Info")
	end
end)
