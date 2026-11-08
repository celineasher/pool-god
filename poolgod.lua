-- POOL GOD - 8 Ball Duels
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("RunService")

local POOL = game:GetService("ReplicatedStorage"):WaitForChild("Libraries"):WaitForChild("GameSpecific"):WaitForChild("Pool")
local PoolConstants = require(POOL.PoolConstants)
local PoolPhysics = require(POOL.PoolPhysics)
local PoolRules = require(POOL.PoolRules)
local PoolInput = require(POOL.PoolInputController)
local PoolAimOverlay = require(POOL.PoolAimOverlay)

local R = PoolConstants.BallRadius
local HALF_W = PoolConstants.PlayWidth / 2
local HALF_H = PoolConstants.PlayHeight / 2

local state = { auto = false, busy = false, nextAuto = 0, lastScan = 0 }

local function getPath(s)
	return s.Replica and s.Replica.Data and s.Replica.Data.poolMatch
end

local function validSeat(s)
	if type(s) ~= "table" then return false end
	local ok, res = pcall(function()
		return type(s.Input) == "table"
			and s.Input.ShotBindable ~= nil
			and type(s.Simulation) == "table"
			and type(s.Simulation.Balls) == "table"
			and type(s.Seat) == "number"
			and s.Seat > 0
			and type(s.Rules) == "table"
	end)
	return ok and res
end

local seat

local function getSeat()
	if validSeat(seat) then
		local ok, pm = pcall(getPath, seat)
		if ok and pm and pm.Phase == "Playing" then return seat end
	end
	local now = os.clock()
	if now - state.lastScan < 1 then return seat end
	state.lastScan = now
	local best
	for _, v in ipairs(getgc(true)) do
		if validSeat(v) then
			local ok, pm = pcall(getPath, v)
			if ok and pm and pm.Phase == "Playing" then
				if pm.Turn == v.Seat then
					seat = v
					return v
				end
				best = best or v
			end
		end
	end
	seat = best
	return best
end

local function segDist(p, a, b)
	local ab = b - a
	local l = ab:Dot(ab)
	if l < 1e-6 then return (p - a).Magnitude end
	local t = math.clamp((p - a):Dot(ab) / l, 0, 1)
	return (p - (a + ab * t)).Magnitude
end

local function getPockets(sim)
	local ok, p = pcall(function() return PoolPhysics.GetTable(sim).Pockets end)
	return ok and p or {}
end

local function isClear(sim, a, b, ignoreNumber)
	local rr = R * 2.02
	for _, ball in pairs(sim.Balls) do
		if type(ball) == "table" and ball.Position and not ball.Pocketed
			and ball.Number ~= ignoreNumber and ball.Number ~= PoolConstants.CueBallNumber then
			if segDist(ball.Position, a, b) < rr then return false end
		end
	end
	return true
end

local function ourTurn(s)
	local ok, pm = pcall(getPath, s)
	return ok and pm and pm.Phase == "Playing" and pm.Turn == s.Seat
end

local function computeShot(s)
	local sim = s.Simulation
	local cue = sim.Balls[PoolConstants.CueBallNumber]
	if not cue or cue.Pocketed then return nil end
	local cpos = cue.Position
	local best
	for _, ball in pairs(sim.Balls) do
		if type(ball) == "table" and ball.Number and ball.Number > 0 and not ball.Pocketed and ball.Position then
			local legal = true
			pcall(function() legal = PoolRules.IsLegalFirstContact(s.Rules, sim, ball.Number) end)
			if legal then
				for _, pk in ipairs(getPockets(sim)) do
					local mouth = pk.MouthCentre
					local toPk = mouth - ball.Position
					local pd = toPk.Magnitude
					if pd > 1e-3 then
						local pdir = toPk / pd
						local ghost = ball.Position - pdir * (R * 2.02)
						if math.abs(ghost.X) <= HALF_W - R and math.abs(ghost.Y) <= HALF_H - R then
							local toGhost = ghost - cpos
							local gd = toGhost.Magnitude
							if gd > 1e-3 then
								local adir = toGhost / gd
								local cut = adir:Dot(pdir)
								if cut > 0.2 and isClear(sim, cpos, ghost, ball.Number) and isClear(sim, ball.Position, mouth, ball.Number) then
									local score = (gd + pd) / (cut * cut)
									if not best or score < best.score then
										best = {
											dir = adir,
											power = math.clamp(0.55 + (gd + pd) / 140, 0.55, 0.95),
											score = score,
											ball = ball.Number,
											pocket = pk.Id,
										}
									end
								end
							end
						end
					end
				end
			end
		end
	end
	return best
end

local function aimOnly(s, shot)
	PoolInput.SetAimDirection(s.Input, shot.dir)
end

local function drawGuide(s, shot)
	local cue = s.Simulation.Balls[PoolConstants.CueBallNumber]
	if not cue or not s.Overlay then return end
	local pred
	local ok = pcall(function()
		pred = PoolPhysics.PredictShot(s.Simulation, shot.dir, shot.power, Vector2.zero, 1 / 60)
	end)
	if not ok or not pred then return end
	local legal = true
	pcall(function()
		legal = pred.Kind ~= "Ball" or not pred.Other or PoolRules.IsLegalFirstContact(s.Rules, s.Simulation, pred.Other)
	end)
	pcall(function()
		PoolAimOverlay.SetVisible(s.Overlay, true)
		PoolAimOverlay.SetStickVisible(s.Overlay, not (s.View and s.View.Mode) or s.View.Mode == "2D")
		PoolAimOverlay.Update(s.Overlay, cue.Position, shot.dir, pred, shot.power, PoolConstants.BasePredictionLength, legal)
	end)
end

local function hideGuide(s)
	if s and s.Overlay then
		pcall(function() PoolAimOverlay.SetVisible(s.Overlay, false) end)
	end
end

local function fire(s, shot)
	PoolInput.SetAimDirection(s.Input, shot.dir)
	local needs = false
	pcall(function() needs = PoolRules.NeedsCall(s.Rules, s.Simulation) end)
	if needs then
		s.Call = shot.pocket
		s.CallLocked = true
	end
	task.wait(0.13)
	s.Input.ShotBindable:Fire(shot.dir, shot.power, Vector2.zero)
	task.wait(0.06)
	pcall(function() PoolInput.ReleaseAim(s.Input) end)
end

-- UI
if _G.__poolGod and _G.__poolGod.destroy then pcall(_G.__poolGod.destroy) end
local conns = {}
local gui = Instance.new("ScreenGui")
gui.Name = "PoolGod"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999
local okParent, container = pcall(function() return gethui() end)
gui.Parent = (okParent and container) or Players.LocalPlayer:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(224, 150)
panel.Position = UDim2.fromOffset(24, 130)
panel.BackgroundColor3 = Color3.fromRGB(12, 17, 26)
panel.BorderSizePixel = 0
panel.Active = true
panel.Draggable = true
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 6)
local stroke = Instance.new("UIStroke", panel)
stroke.Color = Color3.fromRGB(38, 92, 120)
stroke.Thickness = 1

local function label(text, y, size, color)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Position = UDim2.fromOffset(10, y)
	l.Size = UDim2.new(1, -20, 0, size)
	l.Font = Enum.Font.Arcade
	l.TextSize = size - 2
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = color
	l.Text = text
	l.Parent = panel
	return l
end

local title = label("POOL GOD", 6, 14, Color3.fromRGB(124, 255, 107))
local status = label("BALL: -   TURN: -", 26, 12, Color3.fromRGB(226, 240, 220))
local shotInfo = label("AIM: -", 42, 12, Color3.fromRGB(120, 138, 120))

local function button(text, y, color)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, -20, 0, 24)
	b.Position = UDim2.fromOffset(10, y)
	b.BackgroundColor3 = Color3.fromRGB(22, 30, 44)
	b.BorderSizePixel = 0
	b.Font = Enum.Font.Arcade
	b.TextSize = 12
	b.TextColor3 = color
	b.Text = text
	b.AutoButtonColor = false
	b.Parent = panel
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
	return b
end

local autoBtn = button("AUTO SHOT: OFF", 64, Color3.fromRGB(226, 240, 220))
local aimBtn = button("H  AIM ONLY", 92, Color3.fromRGB(124, 200, 255))
local shootBtn = button("G  SHOOT", 120, Color3.fromRGB(255, 201, 74))

local function paintAuto()
	autoBtn.Text = state.auto and "AUTO SHOT: ON" or "AUTO SHOT: OFF"
	autoBtn.TextColor3 = state.auto and Color3.fromRGB(124, 255, 107) or Color3.fromRGB(120, 138, 120)
end

autoBtn.Activated:Connect(function()
	state.auto = not state.auto
	paintAuto()
end)

local function manual(shoot)
	local s = getSeat()
	if not s then
		shotInfo.Text = "AIM: no match"
		return
	end
	if not s.Simulation.Settled then
		local t0 = os.clock()
		repeat task.wait(0.1) until s.Simulation.Settled or os.clock() - t0 > 4
	end
	if not ourTurn(s) then
		shotInfo.Text = "AIM: not your turn"
		return
	end
	local shot = computeShot(s)
	if not shot then
		shotInfo.Text = "AIM: no shot"
		return
	end
	shotInfo.Text = string.format("AIM: %d -> %s  p%.2f", shot.ball, tostring(shot.pocket), shot.power)
	aimOnly(s, shot)
	drawGuide(s, shot)
	if shoot then
		if state.busy then return end
		state.busy = true
		local ok, err = pcall(fire, s, shot)
		state.busy = false
		if not ok then shotInfo.Text = "AIM: " .. tostring(err) end
		state.nextAuto = os.clock() + 2
	end
end

aimBtn.Activated:Connect(function() task.spawn(manual, false) end)
shootBtn.Activated:Connect(function() task.spawn(manual, true) end)

table.insert(conns, UIS.InputBegan:Connect(function(input, gp)
	if input.KeyCode == Enum.KeyCode.H then
		task.spawn(manual, false)
	elseif input.KeyCode == Enum.KeyCode.G then
		task.spawn(manual, true)
	elseif input.KeyCode == Enum.KeyCode.J then
		state.auto = not state.auto
		paintAuto()
	elseif input.KeyCode == Enum.KeyCode.R then
		local s = getSeat()
		if s then
			pcall(function() PoolInput.ReleaseAim(s.Input) end)
			hideGuide(s)
		end
	elseif input.KeyCode == Enum.KeyCode.RightShift then
		panel.Visible = not panel.Visible
	end
end))

table.insert(conns, RS.RenderStepped:Connect(function()
	local s = getSeat()
	if not s then
		status.Text = "BALL: -   TURN: -"
		return
	end
	local pm = getPath(s)
	local mine = pm and pm.Turn == s.Seat
	status.Text = string.format("BALL: %s   TURN: %s", mine and "YOU" or "WAIT", tostring(pm and pm.Turn))
	local now = os.clock()
	if state.auto and not state.busy and mine and s.Simulation.Settled and now >= state.nextAuto then
		local shot = computeShot(s)
		if shot then
			shotInfo.Text = string.format("AUTO: %d -> %s", shot.ball, tostring(shot.pocket))
			aimOnly(s, shot)
			drawGuide(s, shot)
			state.busy = true
			state.nextAuto = now + 2.5
			task.spawn(function()
				local ok, err = pcall(fire, s, shot)
				state.busy = false
				if not ok then shotInfo.Text = "AUTO: " .. tostring(err) end
			end)
		end
	end
end))

paintAuto()
_G.__poolGod = {
	state = state,
	getSeat = getSeat,
	computeShot = computeShot,
	fire = fire,
	drawGuide = drawGuide,
	hideGuide = hideGuide,
	gui = gui,
	destroy = function()
		for _, c in ipairs(conns) do
			pcall(function() c:Disconnect() end)
		end
		table.clear(conns)
		pcall(function() gui:Destroy() end)
		_G.__poolGod = nil
	end,
}
return "POOL GOD loaded"
