-- Movement: di chuyển model bằng CFrame mỗi Heartbeat (Root Anchored), không dùng Humanoid:MoveTo.
-- Bám mặt đất bằng raycast; hỗ trợ bay (config.Flying). Dùng cho mob và hero.

local RunService = game:GetService("RunService")

local Movement = {}
Movement.__index = Movement

local DEFAULT_SPEED = 15
local DEFAULT_ROTATION_SPEED = 15
local MELEE_SPEED_MULTIPLIER = 1.3 -- Melee chạy nhanh hơn +30%

-- Ground following settings
local GROUND_RAY_OFFSET = 100   -- Start raycast this high above current Y
local GROUND_RAY_DISTANCE = 300 -- Total downward raycast distance
local SNAP_THRESHOLD = 5        -- Snap về ground nếu lệch quá ngưỡng này (cả 2 chiều: lún xuống hoặc lơ lửng)
local MIN_GROUND_NORMAL_Y = 0.5 -- Chỉ chấp nhận bề mặt tương đối nằm ngang là "đất" (bỏ vách đứng)

-- Flying settings (chỉ dùng khi config.Flying = true)
local DEFAULT_FLY_HEIGHT = 8        -- khoảng cách từ điểm thấp nhất của model tới mặt đất khi bay (studs)
local DEFAULT_FLY_BOB = 0.6         -- biên độ nhấp nhô khi lơ lửng (studs)
local DEFAULT_FLY_BOB_SPEED = 2.2   -- tốc độ nhấp nhô (rad/s)
local DEFAULT_FLY_CLIMB_SPEED = 14  -- tốc độ lên/xuống tối đa (studs/s)
local DEFAULT_FLY_SMOOTH = 3        -- độ mượt khi đổi độ cao (lớn = đổi nhanh)
local DEFAULT_DIVE_DISTANCE = 14    -- tới gần mục tiêu trong khoảng này (theo mặt phẳng ngang) thì hạ độ cao xuống ngang mục tiêu
local DEFAULT_FLY_TILT = 10         -- độ chúi mũi khi bay tới (độ)
local DEFAULT_FLY_BANK = 1.5        -- nghiêng người khi rẽ (rad nghiêng / rad rẽ)
local MAX_BANK = math.rad(25)       -- nghiêng tối đa
local DIVE_HOLD_TIME = 1.0          -- giữ nguyên độ cao tấn công bao lâu sau khi đã tới nơi (giây)
local DIVE_ARRIVE_TOLERANCE = 1.5   -- lệch độ cao <= giá trị này coi như đã ngang target
local DIVE_CLIMB_MULT = 2.5         -- hạ nhanh hơn bình thường khi dive

--[[
	config:
	  Speed, RotationSpeed, AttackType         (như cũ)
	  GroundInstances : danh sách Instance được tính là mặt đất (mặc định { workspace.Terrain }).
	                    Map dựng bằng Part thì truyền các Part/Model sàn vào đây, vd { plot.Floor, plot.HeroGate }
	  GroundRayOffset : raycast bắt đầu cao hơn Root bao nhiêu (mặc định 100). Map có mái/vòm (cổng)
	                    thì để nhỏ (vd 2) để không bị snap lên nóc vòm khi đi bên dưới
	  GroundRayDistance: độ dài raycast xuống (mặc định 300)
	  Flying          : true = model bay (không bám đất, lơ lửng ở độ cao FlyHeight so với mặt đất)
	  FlyHeight       : độ cao bay (studs), mặc định 8
	  FlySpeed        : tốc độ bay (ghi đè Speed khi bay). Hoặc FlySpeedMultiplier: nhân với Speed
	  FlyBob          : biên độ nhấp nhô khi lơ lửng, mặc định 0.6
	  FlyClimbSpeed   : tốc độ lên/xuống tối đa, mặc định 14
	  DiveToTarget    : true (mặc định) = tới gần mục tiêu thì hạ độ cao ngang mục tiêu để tấn công
	  DiveDistance    : bắt đầu hạ độ cao khi cách mục tiêu (ngang) dưới khoảng này, mặc định 14
	  DiveYOffset     : lệch độ cao so với mục tiêu khi tấn công, mặc định 0
	  FlyTilt         : độ chúi mũi khi bay tới (độ), mặc định 10
	  FlyBank         : mức nghiêng người khi rẽ, mặc định 1.5 (0 = không nghiêng)
]]
function Movement.new(model, config)
	config = config or {}
	local self = setmetatable({}, Movement)

	self.Model = model
	self.Root = model:WaitForChild("HumanoidRootPart")

	local baseSpeed = config.Speed or DEFAULT_SPEED
	-- Melee thì chạy nhanh hơn x1.3, config.AttackType truyền vào từ nơi
	-- gọi Movement.new (vd: AttackConfig.Get(Template).AttackType)
	if config.AttackType == "Melee" then
		baseSpeed *= MELEE_SPEED_MULTIPLIER
	end

	-- Bay
	self.Flying = config.Flying == true
	self.FlyHeight = config.FlyHeight or DEFAULT_FLY_HEIGHT
	self.FlyBob = config.FlyBob or DEFAULT_FLY_BOB
	self.FlyBobSpeed = config.FlyBobSpeed or DEFAULT_FLY_BOB_SPEED
	self.FlyClimbSpeed = config.FlyClimbSpeed or DEFAULT_FLY_CLIMB_SPEED
	self.FlySmooth = config.FlySmooth or DEFAULT_FLY_SMOOTH
	self.DiveToTarget = config.DiveToTarget ~= false
	self.DiveDistance = config.DiveDistance or DEFAULT_DIVE_DISTANCE
	self.DiveYOffset = config.DiveYOffset or 0
	self.FlyTilt = math.rad(config.FlyTilt or DEFAULT_FLY_TILT)
	self.FlyBank = config.FlyBank or DEFAULT_FLY_BANK

	if self.Flying then
		if config.FlySpeed then
			baseSpeed = config.FlySpeed
		elseif config.FlySpeedMultiplier then
			baseSpeed *= config.FlySpeedMultiplier
		end
	end
	self.Speed = baseSpeed

	self.RotationSpeed = config.RotationSpeed or DEFAULT_ROTATION_SPEED

	self.Target = nil
	self.StopDistance = 4

	-- Trạng thái bay
	self.BobTime = math.random() * math.pi * 2 -- lệch pha để nhiều con bay cùng lúc không nhấp nhô đồng loạt
	self.LastGroundY = nil                      -- Y đứng của mặt đất gần nhất đã đo được
	self.HoldY = nil                            -- độ cao tấn công đang giữ
	self.HoldTimer = 0
	self.LastTargetPos = nil                    -- vị trí target gần nhất (dùng cho IsReadyToAttack)
	self.Roll = 0
	self.BaseRotation = self.Root.CFrame.Rotation -- xoay không tính phần nghiêng người

	-- Cache raycast params — mặc định chỉ tính Terrain làm mặt đất (map build bằng Terrain)
	self.GroundRayOffset = config.GroundRayOffset or GROUND_RAY_OFFSET
	self.GroundRayDistance = config.GroundRayDistance or GROUND_RAY_DISTANCE
	self.RayParams = RaycastParams.new()
	self.RayParams.FilterType = Enum.RaycastFilterType.Include
	self.RayParams.FilterDescendantsInstances = config.GroundInstances or { workspace.Terrain }

	-- Cache khoảng cách từ tâm HRP xuống điểm thấp nhất của body (chân)
	self.StandOffset = self:ComputeStandOffset()

	self.Root.Anchored = true

	-- Snap ngay lúc spawn, tránh model bị treo lơ lửng / lún nếu vị trí spawn ban đầu lệch
	if self.Flying then
		self:SnapToHover()
	else
		self:SnapToGround()
	end

	self.Connection = RunService.Heartbeat:Connect(function(dt)
		self:Update(dt)
	end)

	return self
end

-- Đặt CFrame cho Root (cả model đi theo). Pivot của model thường KHÔNG trùng Root
-- (vd pivot cao hơn Root 1.5 stud), nên không được PivotTo thẳng bằng CFrame của Root.
function Movement:SetRootCFrame(cf)
	local rootToPivot = self.Root.CFrame:ToObjectSpace(self.Model:GetPivot())
	self.Model:PivotTo(cf * rootToPivot)
end

function Movement:MoveTo(target, stopDistance)
	self.Target = target
	self.StopDistance = stopDistance or 1
end

function Movement:Stop()
	self.Target = nil
end

-- true khi đang có target (đang đi tới)
function Movement:IsMoving()
	return self.Target ~= nil
end

function Movement:GetTargetPosition()
	if not self.Target then
		return nil
	end

	if typeof(self.Target) == "Vector3" then
		return self.Target
	end

	if self.Target:IsA("BasePart") then
		return self.Target.Position
	end

	return nil
end

-- Quay mặt về phía một điểm (giữ thẳng đứng), dùng khi đứng yên tấn công
function Movement:FaceTowards(position)
	local p = self.Root.Position
	local flat = Vector3.new(position.X - p.X, 0, position.Z - p.Z)
	if flat.Magnitude < 1e-3 then
		return
	end
	local cf = CFrame.lookAt(p, p + flat)
	self.BaseRotation = cf.Rotation
	self:SetRootCFrame(cf)
end

-- Kiểm tra part có nằm trong Accessory/Tool không (bỏ qua phụ kiện/vũ khí khi tính chân đứng)
local function isBodyPart(part)
	local current = part
	while current do
		if current:IsA("Accessory") or current:IsA("Tool") then
			return false
		end
		current = current.Parent
	end
	return true
end

-- Tính khoảng cách từ tâm HumanoidRootPart xuống điểm thấp nhất của body model.
-- Root.Position.Y - lowestY đã LÀ khoảng cách thật từ tâm Root xuống chân model,
-- nên KHÔNG cộng thêm HipHeight nữa. HipHeight chỉ dùng làm fallback khi model
-- không có part nào khác ngoài Root để đo.
function Movement:ComputeStandOffset()
	local lowestY = self.Root.Position.Y - (self.Root.Size.Y / 2)
	local foundOtherPart = false

	for _, part in ipairs(self.Model:GetDescendants()) do
		if part:IsA("BasePart") and part ~= self.Root and isBodyPart(part) then
			foundOtherPart = true
			local bottom = part.Position.Y - (part.Size.Y / 2)
			if bottom < lowestY then
				lowestY = bottom
			end
		end
	end

	if not foundOtherPart then
		return self.Root.Size.Y / 2
	end

	return self.Root.Position.Y - lowestY
end

-- Get the stand offset (distance from HumanoidRootPart center to the lowest body point)
function Movement:GetStandOffset()
	return self.StandOffset
end

-- Raycast downward to find ground Y at a given XZ position
-- Returns the Y position where the character should stand, or nil if no valid ground found
function Movement:GetGroundY(x, z, currentY)
	local rayOrigin = Vector3.new(x, currentY + self.GroundRayOffset, z)
	local result = workspace:Raycast(rayOrigin, Vector3.new(0, -self.GroundRayDistance, 0), self.RayParams)

	-- Chỉ chấp nhận bề mặt tương đối nằm ngang (bỏ vách đứng / hang động dốc của Terrain)
	if result and result.Normal.Y > MIN_GROUND_NORMAL_Y then
		return result.Position.Y + self:GetStandOffset()
	end

	return nil
end

-- Snap character về ground nếu lệch quá SNAP_THRESHOLD, dù là lún xuống dưới
-- hay lơ lửng phía trên (Root đang Anchored = true, không có gravity thật).
function Movement:SnapToGround()
	local rootPos = self.Root.Position
	local groundY = self:GetGroundY(rootPos.X, rootPos.Z, rootPos.Y)
	if groundY and math.abs(rootPos.Y - groundY) > SNAP_THRESHOLD then
		local currentPivot = self.Model:GetPivot()
		self.Model:PivotTo(currentPivot + Vector3.new(0, groundY - rootPos.Y, 0))
	end
end

------------------------------------------------------------------
-- Bay
------------------------------------------------------------------

-- Độ cao (Y của Root) khi lơ lửng bình thường tại vị trí XZ: mặt đất + FlyHeight.
-- Không đo được mặt đất (bay ra ngoài Terrain) thì dùng độ cao mặt đất gần nhất đã đo.
function Movement:GetHoverY(x, z, currentY)
	local groundY = self:GetGroundY(x, z, currentY)
	if groundY then
		self.LastGroundY = groundY
	else
		groundY = self.LastGroundY
	end

	if not groundY then
		return nil
	end

	return groundY + self.FlyHeight
end

-- Đặt ngay model về độ cao bay (dùng lúc spawn)
function Movement:SnapToHover()
	local rootPos = self.Root.Position
	local hoverY = self:GetHoverY(rootPos.X, rootPos.Z, rootPos.Y)
	if hoverY then
		self.Model:PivotTo(self.Model:GetPivot() + Vector3.new(0, hoverY - rootPos.Y, 0))
	end
end

-- Độ cao Root cần đạt để tấn công target (ngang target, không thấp hơn mặt đất)
function Movement:GetDiveY(targetPosition)
	local diveY = targetPosition.Y + self.DiveYOffset
	if self.LastGroundY then
		diveY = math.max(diveY, self.LastGroundY)
	end
	return diveY
end

-- AI gọi hàm này trước khi vào Attack.
-- Mob đi bộ / mob bay không dive (đánh xa) luôn trả true.
-- Mob bay cận chiến chỉ true khi đã tới sát target và đã hạ xuống ngang target.
function Movement:IsReadyToAttack()
	if not self.Flying or not self.DiveToTarget then
		return true
	end

	if not self.LastTargetPos then
		return false
	end

	local rootPos = self.Root.Position
	local flatDist = Vector3.new(self.LastTargetPos.X - rootPos.X, 0, self.LastTargetPos.Z - rootPos.Z).Magnitude
	if flatDist > self.StopDistance + 2 then
		return false
	end

	return math.abs(rootPos.Y - self:GetDiveY(self.LastTargetPos)) <= DIVE_ARRIVE_TOLERANCE
end

function Movement:UpdateFlying(dt)
	self.BobTime += dt * self.FlyBobSpeed

	local rootPos = self.Root.Position
	local targetPosition = self:GetTargetPosition()

	local newX, newZ = rootPos.X, rootPos.Z
	local moveDir = nil -- hướng bay ngang (unit) khi đang di chuyển
	local diving = false

	if targetPosition then
		self.LastTargetPos = targetPosition

		local flat = Vector3.new(targetPosition.X - rootPos.X, 0, targetPosition.Z - rootPos.Z)
		local flatDist = flat.Magnitude
		local heightGap = math.abs(rootPos.Y - self:GetDiveY(targetPosition))

		if flatDist <= self.StopDistance then
			-- Tới nơi (theo mặt phẳng ngang). Chỉ Stop khi đã hạ ngang target,
			-- chưa thì đứng lại hạ tiếp để AI không Attack khi còn ở trên cao.
			diving = self.DiveToTarget
			if not diving or heightGap <= DIVE_ARRIVE_TOLERANCE then
				self:Stop()
			end
		else
			moveDir = flat.Unit
			diving = self.DiveToTarget and flatDist <= self.DiveDistance

			local speedScale = 1
			if diving then
				-- Chưa hạ kịp thì bay chậm lại để không tới nơi mà còn ở trên cao
				speedScale = math.clamp(1 - heightGap / 12, 0.3, 1)
			end

			local step = math.min(flatDist, self.Speed * speedScale * dt)
			newX += moveDir.X * step
			newZ += moveDir.Z * step
		end
	end

	-- Độ cao mong muốn
	local hoverY = self:GetHoverY(newX, newZ, rootPos.Y) or rootPos.Y
	local desiredY = hoverY + math.sin(self.BobTime) * self.FlyBob

	if diving and targetPosition then
		local diveY = self:GetDiveY(targetPosition)
		desiredY = diveY
		self.HoldY = diveY
		self.HoldTimer = DIVE_HOLD_TIME
	elseif not moveDir and (self.HoldAltitude or self.HoldTimer > 0) then
		if not self.HoldAltitude then
			self.HoldTimer -= dt
		end
		desiredY = self.HoldY or desiredY
	else
		self.HoldTimer = 0
	end

	-- Đổi độ cao mượt, giới hạn tốc độ lên/xuống; khi dive thì hạ nhanh hơn
	local climbSpeed = self.FlyClimbSpeed * (diving and DIVE_CLIMB_MULT or 1)
	local smooth = self.FlySmooth * (diving and 2 or 1)
	local dy = desiredY - rootPos.Y
	local maxStep = climbSpeed * dt
	local stepY = math.clamp(dy * math.min(1, smooth * dt), -maxStep, maxStep)
	local newPosition = Vector3.new(newX, rootPos.Y + stepY, newZ)

	-- Hướng nhìn: quay theo hướng bay, chúi mũi khi bay tới, ngẩng/chúi theo lên/xuống, nghiêng người khi rẽ
	local currentLook = self.BaseRotation.LookVector
	local flatLook = Vector3.new(currentLook.X, 0, currentLook.Z)
	if flatLook.Magnitude > 1e-4 then
		flatLook = flatLook.Unit
	else
		flatLook = Vector3.new(0, 0, -1)
	end
	local desiredFlat = moveDir or flatLook

	local turn = math.atan2(flatLook:Cross(desiredFlat).Y, flatLook:Dot(desiredFlat))
	local targetRoll = 0
	if moveDir then
		targetRoll = math.clamp(turn * self.FlyBank, -MAX_BANK, MAX_BANK)
	end
	self.Roll += (targetRoll - self.Roll) * math.min(1, 6 * dt)

	local vy = stepY / math.max(dt, 1e-3)
	local pitchY = math.clamp(vy / math.max(self.Speed, 1), -1, 1)
	if moveDir then
		pitchY -= math.tan(self.FlyTilt)
	end
	local lookDir = Vector3.new(desiredFlat.X, pitchY, desiredFlat.Z)

	local targetCF = CFrame.lookAt(newPosition, newPosition + lookDir)
	self.BaseRotation = self.BaseRotation:Lerp(targetCF.Rotation, math.min(1, self.RotationSpeed * dt))

	self:SetRootCFrame(CFrame.new(newPosition) * self.BaseRotation * CFrame.Angles(0, 0, self.Roll))
end

-- Bật/tắt bay lúc đang chạy (ví dụ boss đổi giai đoạn). Tắt bay thì model tự hạ xuống đất ở frame sau.
function Movement:SetFlying(flying, flyHeight)
	flying = flying == true
	if flyHeight then
		self.FlyHeight = flyHeight
	end
	if flying == self.Flying then
		return
	end

	self.Flying = flying
	self.Roll = 0
	self.HoldTimer = 0
	self.LastTargetPos = nil
	if flying then
		self.BaseRotation = self.Root.CFrame.Rotation
	else
		-- Trả model về đứng thẳng khi hạ cánh
		local rootCF = self.Root.CFrame
		local look = rootCF.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		if flatLook.Magnitude > 1e-4 then
			local cf = CFrame.lookAt(rootCF.Position, rootCF.Position + flatLook)
			self.BaseRotation = cf.Rotation
			self:SetRootCFrame(cf)
		end
	end
end

-- Giữ nguyên độ cao tấn công cho tới khi tắt (quái bay cận chiến trong state Attack)
function Movement:SetHoldAltitude(hold)
	self.HoldAltitude = hold == true
end

function Movement:IsFlying()
	return self.Flying
end

function Movement:SetFlyHeight(height)
	self.FlyHeight = height
end

function Movement:Update(dt)
	if not self.Model or not self.Model.Parent then
		return
	end

	if self.Flying then
		self:UpdateFlying(dt)
		return
	end

	-- Always try to snap back to ground if fallen below or floating above
	self:SnapToGround()

	local targetPosition = self:GetTargetPosition()
	if not targetPosition then
		return
	end

	-- Chỉ tính mặt phẳng ngang: Y luôn lấy theo mặt đất bên dưới.
	local rootPos = self.Root.Position
	local offset = Vector3.new(targetPosition.X - rootPos.X, 0, targetPosition.Z - rootPos.Z)
	local distance = offset.Magnitude

	if distance <= self.StopDistance + 0.05 then -- +0.05: tránh lỗi làm tròn kẹt ở 5.0000001
		self:Stop()
		return
	end

	-- Chỉ đi tới mép StopDistance (không đi lố vào trong rồi mới dừng)
	local moveDistance = math.min(distance - self.StopDistance, self.Speed * dt)
	local direction = offset.Unit
	local newPosition = rootPos + direction * moveDistance

	-- Ground following: find ground Y at new XZ position
	local groundY = self:GetGroundY(newPosition.X, newPosition.Z, rootPos.Y)

	if groundY then
		newPosition = Vector3.new(newPosition.X, groundY, newPosition.Z)
	else
		-- No ground below new position - don't move (prevent falling off edges)
		return
	end

	-- Face the target direction (keep upright by using same Y)
	local lookAt = Vector3.new(targetPosition.X, newPosition.Y, targetPosition.Z)
	local targetCF = CFrame.lookAt(newPosition, lookAt)

	-- Vị trí set chính xác theo ground (không Lerp vị trí), chỉ Lerp phần xoay để quay người mượt.
	local currentRotation = self.Root.CFrame.Rotation
	local newRotation = currentRotation:Lerp(targetCF.Rotation, math.min(1, self.RotationSpeed * dt))
	self.BaseRotation = newRotation

	self:SetRootCFrame(CFrame.new(newPosition) * newRotation)
end

function Movement:SetSpeed(speed)
	self.Speed = speed
end

function Movement:GetSpeed()
	return self.Speed
end

function Movement:Destroy()
	if self.Connection then
		self.Connection:Disconnect()
		self.Connection = nil
	end

	self.Target = nil
	self.LastTargetPos = nil
	self.Model = nil
	self.Root = nil
	self.RayParams = nil
	self.BaseRotation = nil
end

return Movement
