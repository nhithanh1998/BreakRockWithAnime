-- HeldHeroService: the hero picked on the hotbar (keys 1-9 / 0) is shown as a small copy held in
-- front of the player's chest, with the arms raised to carry it. Everyone sees it.
--
--   HeldHeroService.Set(player, heroName | nil)   (HeroSlotService calls this on "Select")
--
-- The copy lives in Workspace.HeldHeroes.<UserId>, welded to the character's HumanoidRootPart, so it
-- is never part of the character model (nothing that scans the character trips over a second
-- Humanoid). It is rebuilt when the character respawns and removed when the player leaves.

local Players = game:GetService("Players")

local HeroModels = require(script.Parent:WaitForChild("HeroModels"))

local SCALE = 0.7 -- size of the held copy compared to the full hero
local OFFSET = CFrame.new(0, 0.9, -2.4) -- from the HumanoidRootPart: in front of the chest
-- Arms forward, as if carrying something (Roblox's default "hold tool" pose).
local HOLD_ANIMS = {
	[Enum.HumanoidRigType.R15] = "rbxassetid://507768375",
	[Enum.HumanoidRigType.R6] = "rbxassetid://182393478",
}

type Held = { hero: string, model: Model?, track: AnimationTrack? }

local HeldHeroService = {}

local held: { [Player]: Held } = {}

local function folder(): Folder
	local f = workspace:FindFirstChild("HeldHeroes")
	if not f then
		f = Instance.new("Folder")
		f.Name = "HeldHeroes"
		f.Parent = workspace
	end
	return f :: Folder
end

local function clear(state: Held)
	if state.track then
		state.track:Stop(0.15)
		state.track:Destroy()
		state.track = nil
	end
	if state.model then
		state.model:Destroy()
		state.model = nil
	end
end

local function build(player: Player, state: Held)
	clear(state)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local playerHumanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not playerHumanoid or playerHumanoid.Health <= 0 then
		return
	end

	local model, humanoid, heroRoot = HeroModels.Clone(state.hero)
	if not model or not humanoid or not heroRoot then
		return
	end
	model.Name = tostring(player.UserId)
	model:SetAttribute("HeldBy", player.UserId)
	HeroModels.HideBar(model)
	humanoid.EvaluateStateMachine = false -- just a puppet: no falling / getting up
	humanoid.PlatformStand = true
	humanoid.NameDisplayDistance = 0
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	heroRoot.Massless = true
	pcall(model.ScaleTo, model, SCALE)

	-- Stand it on an invisible spot in front of the chest, facing the same way as the player.
	model:PivotTo(root.CFrame * OFFSET)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = heroRoot
	weld.Parent = heroRoot
	model.Parent = folder()

	-- The little hero idles in the player's hands.
	local idle = HeroModels.LoadTrack(humanoid, HeroModels.Anims(humanoid).Idle, Enum.AnimationPriority.Idle, true)
	if idle then
		idle:Play()
	end

	-- The player's arms go forward to carry it.
	local animator = playerHumanoid:FindFirstChildOfClass("Animator")
	local id = HOLD_ANIMS[playerHumanoid.RigType]
	if animator and id then
		local anim = Instance.new("Animation")
		anim.AnimationId = id
		local ok, track = pcall(animator.LoadAnimation, animator, anim)
		if ok and track then
			track.Priority = Enum.AnimationPriority.Action
			track.Looped = true
			track:Play(0.15)
			state.track = track
		end
	end
	state.model = model
end

function HeldHeroService.Set(player: Player, hero: string?)
	local state = held[player]
	if state and state.hero == hero then
		return
	end
	if state then
		clear(state)
		held[player] = nil
	end
	if hero then
		local newState: Held = { hero = hero }
		held[player] = newState
		build(player, newState)
	end
end

function HeldHeroService.Start()
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			local state = held[player]
			if state then
				character:WaitForChild("HumanoidRootPart", 10)
				task.wait(0.1)
				if held[player] == state then
					build(player, state)
				end
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		local state = held[player]
		held[player] = nil
		if state then
			clear(state)
		end
	end)
end

return HeldHeroService
