-- Wires plot ownership to tree spawning: a player's plot starts growing trees when they join
-- and is cleared when they leave.
local PlotService = require(script.Parent:WaitForChild("PlotService"))
local TreeService = require(script.Parent:WaitForChild("TreeService"))

PlotService.PlotClaimed:Connect(function(_player, plot)
	TreeService.StartPlot(plot)
end)

PlotService.PlotReleased:Connect(function(_player, plot)
	TreeService.StopPlot(plot)
end)

PlotService.Start()
