-- Wires plot ownership to tree spawning: a player's plot starts growing trees when they join
-- and is cleared when they leave. DataService loads / saves each player's progress.
local PlotService = require(script.Parent:WaitForChild("PlotService"))
local TreeService = require(script.Parent:WaitForChild("TreeService"))
local TreeHitService = require(script.Parent:WaitForChild("TreeHitService"))
local ChestService = require(script.Parent:WaitForChild("ChestService"))
local HeroSlotService = require(script.Parent:WaitForChild("HeroSlotService"))
local ShopService = require(script.Parent:WaitForChild("ShopService"))
local SkillTreeService = require(script.Parent:WaitForChild("SkillTreeService"))
local DataService = require(script.Parent:WaitForChild("DataService"))
local ZoneBoardService = require(script.Parent:WaitForChild("ZoneBoardService"))

PlotService.PlotClaimed:Connect(function(player, plot)
	ChestService.ResetPlot(plot)
	ZoneBoardService.SetupPlot(plot, player) -- sets the plot's Zone before trees grow
	TreeService.StartPlot(plot)
	HeroSlotService.SetupPlot(plot, player)
end)

PlotService.PlotReleased:Connect(function(player, plot)
	-- Remember the heroes on the pads before the plot is cleared, for the leave-save.
	DataService.RememberPlaced(player)
	HeroSlotService.ResetPlot(plot)
	TreeService.StopPlot(plot)
	ChestService.ResetPlot(plot)
	ZoneBoardService.ResetPlot(plot)
end)

ChestService.Start()
TreeHitService.Start()
HeroSlotService.Start()
ShopService.Start()
SkillTreeService.Start()
ZoneBoardService.Start()
DataService.Start()
PlotService.Start()
