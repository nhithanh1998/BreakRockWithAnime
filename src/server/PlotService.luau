-- PlotService: gives each joining player a free plot from workspace.Plots and frees it when they leave.
--
-- A plot is free while its "OwnerUserId" attribute is 0 / missing. Plots are handed out in
-- name order (Plot1, Plot2, ...), so adding more plots later only means cloning Plot1.
--
-- Spawn point: a BasePart or Attachment named "SpawnPoint" inside the plot (a direct child wins; the
-- tree spots in TreeSpawns, also named "SpawnPoint", are skipped), otherwise the top
-- step of the plot's Gate, otherwise above the plot's pivot.

local Players = game:GetService("Players")

local Plots = workspace:WaitForChild("Plots")

local PlotService = {}

local plotByPlayer: { [Player]: Model } = {}

local claimedEvent = Instance.new("BindableEvent")
local releasedEvent = Instance.new("BindableEvent")
PlotService.PlotClaimed = claimedEvent.Event -- (player, plot)
PlotService.PlotReleased = releasedEvent.Event -- (player, plot)

local function plotNumber(plot: Instance): number
	return tonumber(plot.Name:match("%d+")) or math.huge
end

local function sortedPlots(): { Instance }
	local list = Plots:GetChildren()
	table.sort(list, function(a, b)
		return plotNumber(a) < plotNumber(b)
	end)
	return list
end

local function isFree(plot: Instance): boolean
	return (plot:GetAttribute("OwnerUserId") or 0) == 0
end

function PlotService.GetPlot(player: Player): Model?
	return plotByPlayer[player]
end

function PlotService.GetOwner(plot: Model): Player?
	local userId = plot:GetAttribute("OwnerUserId")
	if not userId or userId == 0 then
		return nil
	end
	return Players:GetPlayerByUserId(userId)
end

function PlotService.GetSpawnCFrame(plot: Model): CFrame
	-- A direct child first: TreeSpawns also holds parts named "SpawnPoint" (tree spots, not the player's).
	local marker = plot:FindFirstChild("SpawnPoint")
	if not marker then
		for _, d in plot:GetDescendants() do
			if d.Name == "SpawnPoint" and not d:IsDescendantOf(plot:FindFirstChild("TreeSpawns") or d) then
				marker = d
				break
			end
		end
	end
	if marker and marker:IsA("BasePart") then
		return marker.CFrame + Vector3.new(0, 3, 0)
	elseif marker and marker:IsA("Attachment") then
		return marker.WorldCFrame + Vector3.new(0, 3, 0)
	end

	local gate = plot:FindFirstChild("Gate")
	local topStep: BasePart? = nil
	if gate then
		for _, part in gate:GetChildren() do
			if part:IsA("BasePart") and part.Name:match("^StepOut") then
				if not topStep or part.Position.Y > topStep.Position.Y then
					topStep = part
				end
			end
		end
	end
	if topStep then
		local pos = topStep.Position + Vector3.new(0, topStep.Size.Y / 2 + 3, 0)
		local center = plot:GetPivot().Position
		return CFrame.lookAt(pos, Vector3.new(center.X, pos.Y, center.Z))
	end

	return plot:GetPivot() + Vector3.new(0, 5, 0)
end

local function sendHome(player: Player, character: Model)
	local plot = plotByPlayer[player]
	if not plot then
		return
	end
	character:WaitForChild("HumanoidRootPart", 5)
	-- Wait one frame so the default spawn logic doesn't override our position.
	task.defer(function()
		if character.Parent then
			character:PivotTo(PlotService.GetSpawnCFrame(plot))
		end
	end)
end

local function claim(player: Player): Model?
	for _, plot in sortedPlots() do
		if plot:IsA("Model") and isFree(plot) then
			plot:SetAttribute("OwnerUserId", player.UserId)
			plot:SetAttribute("Owner", player.Name)
			plotByPlayer[player] = plot
			player:SetAttribute("Plot", plot.Name)
			claimedEvent:Fire(player, plot)
			return plot
		end
	end
	warn(("[PlotService] No free plot for %s"):format(player.Name))
	return nil
end

local function release(player: Player)
	local plot = plotByPlayer[player]
	if not plot then
		return
	end
	plotByPlayer[player] = nil
	plot:SetAttribute("OwnerUserId", 0)
	plot:SetAttribute("Owner", "")
	releasedEvent:Fire(player, plot)
end

local function onPlayerAdded(player: Player)
	-- PlayerAdded and the existing-players loop in Start() can both reach the same player.
	if plotByPlayer[player] then
		return
	end
	if not claim(player) then
		return
	end
	player.CharacterAdded:Connect(function(character)
		sendHome(player, character)
	end)
	if player.Character then
		sendHome(player, player.Character)
	end
end

function PlotService.Start()
	for _, plot in Plots:GetChildren() do
		plot:SetAttribute("OwnerUserId", 0)
		plot:SetAttribute("Owner", "")
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(release)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return PlotService
