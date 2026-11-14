-- UIManager: one window open at a time.
--
-- Every window script registers its window once:
--
--   UIManager.Register("Shop", root, closeFunction)          -- root: the window's frame
--   UIManager.Register("HeroUpgrade", { winA, winB }, close) -- several frames = one window
--
-- The manager only watches the frames (Visible, and the ScreenGui's Enabled); each script keeps its
-- own open / close code. When a window opens:
--   * every other open window is closed with its own close function,
--   * the world behind is dimmed (a backdrop under the HUD, it never takes input),
--   * on phones the HUD (hotbar, sidebar, buffs, weather, carry pill) is hidden so the window
--     gets the whole screen. It comes back when the last window closes.

local Players = game:GetService("Players")

local Theme = require(script.Parent:WaitForChild("Theme"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local UIManager = {}

-- ScreenGuis hidden on phones while a window is open.
UIManager.HUD = { "HotbarGui", "LeftSidebar", "PotionGui", "WeatherGui", "CarryHUD" }

type Entry = {
	name: string,
	roots: { GuiObject },
	close: () -> (),
	open: boolean,
	order: number,
}

local entries: { Entry } = {}
local hiddenHud: { ScreenGui } = {}
local updateQueued = false

local backdropGui = Instance.new("ScreenGui")
backdropGui.Name = "UIBackdrop"
backdropGui.IgnoreGuiInset = true
backdropGui.ResetOnSpawn = false
backdropGui.DisplayOrder = 3 -- under the HUD (4-5) and every window (5+)
backdropGui.Parent = playerGui

local backdrop = Instance.new("Frame")
backdrop.Name = "Dim"
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
backdrop.BackgroundTransparency = 0.55
backdrop.BorderSizePixel = 0
backdrop.Active = false -- never blocks the thumbstick / camera
backdrop.Visible = false
backdrop.Parent = backdropGui

local function isOpen(e: Entry): boolean
	for _, root in e.roots do
		local gui = root:FindFirstAncestorOfClass("ScreenGui")
		if root.Visible and root.Parent and (not gui or gui.Enabled) then
			return true
		end
	end
	return false
end

local function setHud(hide: boolean)
	if hide then
		for _, name in UIManager.HUD do
			local gui = playerGui:FindFirstChild(name)
			if gui and gui:IsA("ScreenGui") and gui.Enabled and not table.find(hiddenHud, gui) then
				gui.Enabled = false
				table.insert(hiddenHud, gui)
			end
		end
	else
		for _, gui in hiddenHud do
			if gui.Parent then
				gui.Enabled = true
			end
		end
		table.clear(hiddenHud)
	end
end

local function update()
	updateQueued = false
	-- Windows that just opened win: close the rest.
	local newest: Entry? = nil
	for _, e in entries do
		local now = isOpen(e)
		if now and not e.open and (not newest or e.order > newest.order) then
			newest = e
		end
	end
	if newest then
		for _, e in entries do
			if e ~= newest and isOpen(e) then
				e.close()
			end
		end
	end
	local any = false
	for _, e in entries do
		e.open = isOpen(e)
		any = any or e.open
	end
	backdrop.Visible = any
	setHud(any and Theme.IsPhone())
end

local function queueUpdate()
	if not updateQueued then
		updateQueued = true
		task.defer(update)
	end
end

local registered = 0

function UIManager.Register(name: string, roots: GuiObject | { GuiObject }, close: () -> ())
	local list = if typeof(roots) == "table" then roots else { roots }
	registered += 1
	local e: Entry = { name = name, roots = list, close = close, open = false, order = registered }
	table.insert(entries, e)
	for _, root in list do
		root:GetPropertyChangedSignal("Visible"):Connect(queueUpdate)
		root.AncestryChanged:Connect(queueUpdate)
		local gui = root:FindFirstAncestorOfClass("ScreenGui")
		if gui then
			gui:GetPropertyChangedSignal("Enabled"):Connect(queueUpdate)
		end
	end
	queueUpdate()
end

-- Name of the open window, if any.
function UIManager.Current(): string?
	for _, e in entries do
		if e.open then
			return e.name
		end
	end
	return nil
end

return UIManager
