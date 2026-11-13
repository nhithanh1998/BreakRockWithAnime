-- Builds every plot's layout at server start and plays a transition whenever the plot's "Zone" attribute changes.
-- Test in Play (server side):  workspace.Plots.Plot1:SetAttribute("Zone", 2)
local ZoneService = require(script.Parent:WaitForChild("ZoneService"))
local Plots = workspace:WaitForChild("Plots")

local function hook(plot)
	ZoneService.Apply(plot)
	plot:GetAttributeChangedSignal("Zone"):Connect(function()
		task.spawn(ZoneService.Transition, plot)
	end)
end

for _, plot in ipairs(Plots:GetChildren()) do hook(plot) end
Plots.ChildAdded:Connect(hook)
