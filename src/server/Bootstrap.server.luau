-- Wires plot ownership to tree spawning: a player's plot starts growing trees when they join
-- and is cleared when they leave.
local PlotService = require(script.Parent:WaitForChild("PlotService"))
local TreeService = require(script.Parent:WaitForChild("TreeService"))
local TreeHitService = require(script.Parent:WaitForChild("TreeHitService"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))

PlotService.PlotClaimed:Connect(function(_player, plot)
	ChestService.ResetPlot(plot)
	TreeService.StartPlot(plot)
end)

PlotService.PlotReleased:Connect(function(_player, plot)
	TreeService.StopPlot(plot)
	ChestService.ResetPlot(plot)
end)

ChestService.Start()
TreeHitService.Start()
PlotService.Start()
