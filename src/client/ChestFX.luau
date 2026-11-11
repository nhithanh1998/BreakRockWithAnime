-- ChestFX: draws every TreasureChest's bar / "stored/capacity" text on this client, and plays the
-- shake + flash + count-up when a dropped item lands in it.
--
-- The server sets the chest's "Stored" attribute as soon as a tree falls, but the items are still
-- flying. While items are in flight for a chest, the number shown here only goes up as each item
-- lands; once nothing is in flight it snaps back to the server's value.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local TreeConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TreeConfig"))
local TreeFX = require(script.Parent:WaitForChild("TreeFX"))

local ChestFX = {}

type ChestState = {
	chest: Model,
	shown: number, -- value the text is heading to
	display: NumberValue, -- tweened value actually drawn
	inFlight: number,
	bump: UIScale?,
}

local states: { [Model]: ChestState } = {}

local function commas(n: number): string
	local s = tostring(math.floor(n))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

local function abbreviate(n: number): string
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, u in units do
		if n >= u[1] then
			local v = n / u[1]
			local text = if v >= 100 or v == math.floor(v) then ("%d"):format(math.floor(v)) else ("%.1f"):format(v)
			return text .. u[2]
		end
	end
	return tostring(math.floor(n))
end

local function guiOf(chest: Model): (TextLabel?, Frame?, Frame?)
	local gui = chest:FindFirstChild("ChestGui", true)
	if not gui then
		return nil, nil, nil
	end
	local bar = gui:FindFirstChild("Bar", true)
	local amount = bar and bar:FindFirstChild("Amount")
	local fill = bar and bar:FindFirstChild("Fill")
	return amount :: TextLabel?, fill :: Frame?, bar :: Frame?
end

local function draw(state: ChestState)
	local amount, fill = guiOf(state.chest)
	local capacity = state.chest:GetAttribute("Capacity") or 0
	local value = state.display.Value
	if amount then
		amount.Text = ("%s/%s"):format(commas(value), abbreviate(capacity))
	end
	if fill and capacity > 0 then
		fill.Size = UDim2.fromScale(math.clamp(value / capacity, 0.02, 1), 1)
	end
end

local countInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function setShown(state: ChestState, value: number, instant: boolean?)
	state.shown = value
	if instant then
		state.display.Value = value
	else
		TweenService:Create(state.display, countInfo, { Value = value }):Play()
	end
end

local function stored(chest: Model): number
	return chest:GetAttribute("Stored") or 0
end

local function track(chest: Model)
	if states[chest] then
		return
	end
	local display = Instance.new("NumberValue")
	display.Value = stored(chest)
	local state: ChestState = {
		chest = chest,
		shown = stored(chest),
		display = display,
		inFlight = 0,
	}
	states[chest] = state

	local _, _, bar = guiOf(chest)
	if bar then
		local scale = Instance.new("UIScale")
		scale.Parent = bar
		state.bump = scale
	end

	display.Changed:Connect(function()
		draw(state)
	end)
	chest:GetAttributeChangedSignal("Capacity"):Connect(function()
		draw(state)
	end)
	chest:GetAttributeChangedSignal("Stored"):Connect(function()
		-- The drop event and this attribute can arrive in either order; wait a moment so the
		-- event has a chance to mark items as in flight before we sync.
		task.delay(0.15, function()
			local s = stored(chest)
			if state.inFlight == 0 or s < state.shown then
				setShown(state, s, s < state.shown)
			end
		end)
	end)
	chest.Destroying:Once(function()
		states[chest] = nil
		display:Destroy()
	end)
	draw(state)
end

local function isChest(inst: Instance): boolean
	return inst:IsA("Model") and inst.Name == "TreasureChest" and inst:GetAttribute("Capacity") ~= nil
end

function ChestFX.Start()
	for _, d in workspace:GetDescendants() do
		if isChest(d) then
			track(d :: Model)
		end
	end
	workspace.DescendantAdded:Connect(function(d)
		if isChest(d) then
			track(d :: Model)
		end
	end)
end

-- Where items fly to: just above the middle of the chest's top.
function ChestFX.GetMouth(chest: Model): Vector3
	local cf, size = chest:GetBoundingBox()
	return cf.Position + Vector3.new(0, size.Y / 2, 0)
end

-- Items for this chest are on their way.
function ChestFX.AddInFlight(chest: Model, amount: number)
	track(chest)
	local state = states[chest]
	if state then
		state.inFlight += amount
	end
end

-- One item stack landed in the chest.
function ChestFX.Arrive(chest: Model, amount: number, fromPos: Vector3?)
	local state = states[chest]
	if not state or not chest.Parent then
		return
	end
	state.inFlight = math.max(state.inFlight - amount, 0)
	if state.inFlight == 0 then
		setShown(state, math.max(stored(chest), state.shown + amount))
	else
		setShown(state, math.min(state.shown + amount, stored(chest)))
	end

	TreeFX.Shake(chest, fromPos, TreeConfig.ChestShakeAngle, TreeConfig.ChestShakeTime)
	TreeFX.Flash(chest, TreeConfig.ChestFlashColor)
	local bump = state.bump
	if bump then
		bump.Scale = 1.15
		TweenService:Create(bump, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
end

return ChestFX
