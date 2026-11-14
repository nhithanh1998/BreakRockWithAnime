-- ZoneLift: which plot floors are moving right now (zone swap), shared between client scripts.
-- ZoneTransitionFX writes it; HeroMotion reads it so idle heroes stay glued to the moving floor in the
-- same frame the floor is drawn (no hovering / sinking).
--   ZoneLift.Set(plot, ground, yAt)   yAt(clock) -> the Ground part's center Y at os.clock() = clock
--   ZoneLift.Clear(plot)
--   ZoneLift.FloorTopAt(plot, pos, clock) -> Y of the floor's top under pos (nil when not lifting or
--                                            pos is not above the floor)

local ZoneLift = {}

type Entry = { ground: BasePart, yAt: (number) -> number }
local entries: { [Instance]: Entry } = {}

function ZoneLift.Set(plot: Instance, ground: BasePart, yAt: (number) -> number)
	entries[plot] = { ground = ground, yAt = yAt }
end

function ZoneLift.Clear(plot: Instance)
	entries[plot] = nil
end

function ZoneLift.IsLifting(plot: Instance?): boolean
	return plot ~= nil and entries[plot] ~= nil
end

function ZoneLift.FloorTopAt(plot: Instance?, pos: Vector3, clock: number): number?
	local e = plot and entries[plot]
	if not e or not e.ground.Parent then
		return nil
	end
	local g = e.ground
	local rel = g.CFrame:PointToObjectSpace(pos)
	local hx, hz = g.Size.X / 2, g.Size.Z / 2
	if math.abs(rel.X) > hx or math.abs(rel.Z) > hz then
		return nil
	end
	return e.yAt(clock) + g.Size.Y / 2
end

return ZoneLift
