-- CollisionGroups: players never collide with heroes.
--
-- Setting CanCollide = false on a hero isn't enough: the Humanoid turns collision back on for its
-- torso / head every physics step. So every hero part goes into the "Heroes" collision group and every
-- player character part into "Players", and those two groups never collide (with anything else they
-- collide as usual).
--
--   CollisionGroups.SetHero(model)   puts the model's parts (and parts added later) in "Heroes"
--   CollisionGroups.Start()          registers the groups and tags player characters

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

local CollisionGroups = {}

CollisionGroups.HEROES = "Heroes"
CollisionGroups.PLAYERS = "Players"

local registered = false

local function register()
	if registered then
		return
	end
	registered = true
	for _, name in { CollisionGroups.HEROES, CollisionGroups.PLAYERS } do
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			PhysicsService:RegisterCollisionGroup(name)
		end
	end
	PhysicsService:CollisionGroupSetCollidable(CollisionGroups.HEROES, CollisionGroups.PLAYERS, false)
end

-- Puts every BasePart under `root` (now and later) in `group`.
local function tag(root: Instance, group: string)
	register()
	local function set(d: Instance)
		if d:IsA("BasePart") then
			d.CollisionGroup = group
		end
	end
	set(root)
	for _, d in root:GetDescendants() do
		set(d)
	end
	root.DescendantAdded:Connect(set)
end

function CollisionGroups.SetHero(model: Model)
	tag(model, CollisionGroups.HEROES)
end

function CollisionGroups.Start()
	register()
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			tag(character, CollisionGroups.PLAYERS)
		end)
		if player.Character then
			tag(player.Character, CollisionGroups.PLAYERS)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
end

return CollisionGroups
