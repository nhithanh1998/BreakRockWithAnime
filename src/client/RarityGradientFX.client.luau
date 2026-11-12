-- RarityGradientFX: makes the rarity gradients in the world move.
--
-- Every UIGradient tagged HeroConfig.RarityGradientTag (set by HeroConfig.PaintRarity on the
-- server: HeroBar above heroes, HeroInfo above hero pads) gets its Color rebuilt each frame from
-- HeroConfig.RarityGradientFX[its "Rarity" attribute], so the palette scrolls across the text
-- in a seamless loop. One ColorSequence is built per rarity per frame and shared by all labels.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local HeroConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HeroConfig"))

local TAG = HeroConfig.RarityGradientTag
local FX = HeroConfig.RarityGradientFX
local SWEEP = HeroConfig.RarityGradientSweep
local KEYPOINTS = 20 -- ColorSequence max
local MAX_FPS = 30

-- Palette colour at loop position p (any number, wraps), blending linearly between neighbours.
local function sample(colors: { Color3 }, p: number): Color3
	local n = #colors
	if n == 1 then
		return colors[1]
	end
	local x = (p % 1) * n
	local i = math.floor(x)
	local a = colors[i + 1]
	local b = colors[(i + 1) % n + 1]
	return a:Lerp(b, x - i)
end

local function build(fx, phase: number): ColorSequence
	local points = table.create(KEYPOINTS)
	for k = 0, KEYPOINTS - 1 do
		local t = k / (KEYPOINTS - 1)
		points[k + 1] = ColorSequenceKeypoint.new(t, sample(fx.Colors, t * fx.Span - phase))
	end
	return ColorSequence.new(points)
end

local gradients: { [UIGradient]: true } = {}

local function add(inst: Instance)
	if inst:IsA("UIGradient") then
		gradients[inst] = true
	end
end
for _, inst in CollectionService:GetTagged(TAG) do
	add(inst)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(add)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(inst)
	gradients[inst :: UIGradient] = nil
end)

local acc = 0
RunService.RenderStepped:Connect(function(dt)
	acc += dt
	if acc < 1 / MAX_FPS then
		return
	end
	acc = 0
	if next(gradients) == nil then
		return
	end

	local now = os.clock()
	local cache: { [string]: ColorSequence } = {}
	for g in gradients do
		if not g.Parent then
			continue
		end
		local rarity = g:GetAttribute("Rarity")
		local fx = rarity and FX[rarity]
		if not fx then
			continue
		end
		local seq = cache[rarity]
		if not seq then
			seq = build(fx, now * SWEEP * fx.Span) -- same on-screen sweep speed whatever the Span
			cache[rarity] = seq
		end
		g.Color = seq
	end
end)
