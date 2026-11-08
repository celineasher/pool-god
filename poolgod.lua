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
local PoolTableRenderer2D = require(POOL.PoolTableRenderer2D)

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

local function raySegT(p, d, a, b)
	local e = b - a
	local den = d.X * e.Y - d.Y * e.X
	if math.abs(den) < 1e-9 then return nil end
	local ap = a - p
	local t = (ap.X * e.Y - ap.Y * e.X) / den
	local u = (ap.X * d.Y - ap.Y * d.X) / den
	if t > 1e-4 and u >= 0 and u <= 1 then return t end
end

local function rayCircleT(p, d, c, r)
	local m = p - c
	local b = m:Dot(d)
	local cc = m:Dot(m) - r * r
	local disc = b * b - cc
	if disc < 0 then return nil end
	local root = math.sqrt(disc)
	local t = -b - root
	if t < 0 then t = -b + root end
	if t >= 0 then return t end
end

local function getCushions(sim)
	local ok, c = pcall(function() return PoolPhysics.GetTable(sim).Cushions end)
	return ok and c or {}
end

local function bankCandidate(sim, cue, ball, pk, cushion)
	local A, B, N = cushion.A, cushion.B, cushion.Normal
	if not A or not B or not N then return nil end
	local n = N.Unit
	local target = pk.MouthCentre
	local sideBall = (ball.Position - A):Dot(n)
	local sidePocket = (target - A):Dot(n)
	if sideBall * sidePocket <= 0 then return nil end
	local mirror = target - n * (2 * sidePocket)
	local toM = mirror - ball.Position
	local dm = toM.Magnitude
	if dm < 1e-3 then return nil end
	local d = toM / dm
	local qt = raySegT(ball.Position, d, A, B)
	if not qt then return nil end
	local q = ball.Position + d * qt
	local qp = target - q
	local qpd = qp.Magnitude
	if qpd < 1e-3 then return nil end
	local refl = d - n * (2 * d:Dot(n))
	if refl.Unit:Dot(qp.Unit) < 0.9 then return nil end
	if not isClear(sim, ball.Position, q, ball.Number) then return nil end
	if not isClear(sim, q, target, ball.Number) then return nil end
	local ghost = ball.Position - d * (R * 2.02)
	if math.abs(ghost.X) > HALF_W - R or math.abs(ghost.Y) > HALF_H - R then return nil end
	local toGhost = ghost - cue.Position
	local gd = toGhost.Magnitude
	if gd < 1e-3 then return nil end
	local adir = toGhost / gd
	local cut = adir:Dot(d)
	if cut <= 0.25 then return nil end
	if not isClear(sim, cue.Position, ghost, ball.Number) then return nil end
	local dist = gd + qt + qpd
	return {
		dir = adir,
		power = math.clamp(0.62 + dist / 150, 0.6, 1),
		score = dist / (cut * cut) + 20,
		bank = true,
		ball = ball.Number,
		pocket = pk.Id,
		objPos = ball.Position,
		pocketPos = target,
		contact = q,
		rail = cushion.Id,
		ghost = ghost,
	}
end

local function computeShot(s)
	local sim = s.Simulation
	local cue = sim.Balls[PoolConstants.CueBallNumber]
	if not cue or cue.Pocketed then return nil end
	local cpos = cue.Position
	local cushions = getCushions(sim)
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
											bank = false,
											ball = ball.Number,
											pocket = pk.Id,
											objPos = ball.Position,
											pocketPos = mouth,
											ghost = ghost,
										}
									end
								end
							end
						end
						for _, cushion in ipairs(cushions) do
							local cand = bankCandidate(sim, cue, ball, pk, cushion)
							if cand and (not best or cand.score < best.score) then
								best = cand
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

local function traceCue(sim, start, dir, maxLen, maxBounces)
	local pts = { start }
	local p = start
	local d = dir.Unit
	local left = maxLen
	local bounces = 0
	local cushions = getCushions(sim)
	while left > 0.05 and bounces <= maxBounces do
		local bestT = left
		local kind, normal
		for _, ball in pairs(sim.Balls) do
			if type(ball) == "table" and ball.Number and ball.Number ~= PoolConstants.CueBallNumber
				and not ball.Pocketed and ball.Position then
				local t = rayCircleT(p, d, ball.Position, R * 2)
				if t and t < bestT then bestT = t; kind = "ball"; normal = nil end
			end
		end
		for _, c in ipairs(cushions) do
			local t = raySegT(p, d, c.A, c.B)
			if t and t < bestT then bestT = t; kind = "cushion"; normal = c.Normal.Unit end
		end
		local hit = p + d * bestT
		pts[#pts + 1] = hit
		if kind ~= "cushion" or not normal then break end
		left = left - bestT
		d = (d - normal * (2 * d:Dot(normal))).Unit
		p = hit + d * 0.02
		bounces = bounces + 1
	end
	return pts
end

local function guideFolder(s)
	if not s.Overlay or not s.Overlay.Root then return nil end
	local f = s.Overlay.Root:FindFirstChild("BankGuide")
	if not f then
		f = Instance.new("Folder")
		f.Name = "BankGuide"
		f.Parent = s.Overlay.Root
	end
	return f
end

local function clearGuide(s)
	local f = s and s.Overlay and s.Overlay.Root and s.Overlay.Root:FindFirstChild("BankGuide")
	if f then f:ClearAllChildren() end
end

local function drawSeg(folder, a, b, thick, color, transparency)
	local fs = PoolTableRenderer2D.GetFrameSize()
	local d = b - a
	local len = d.Magnitude
	if len < 0.05 then return end
	local mid = (a + b) / 2
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5 + mid.X / fs.X, 0.5 - mid.Y / fs.Y)
	f.Size = UDim2.fromScale(len / fs.X, thick / fs.Y)
	f.Rotation = math.deg(math.atan2(-d.Y, d.X))
	f.BackgroundColor3 = color
	f.BackgroundTransparency = transparency or 0.1
	f.BorderSizePixel = 0
	f.ZIndex = 33
	f.Parent = folder
end

local function drawPoly(folder, pts, thick, color, transparency)
	for i = 1, #pts - 1 do
		drawSeg(folder, pts[i], pts[i + 1], thick, color, transparency)
	end
end

local function drawGuide(s, shot)
	local cue = s.Simulation.Balls[PoolConstants.CueBallNumber]
	if not cue or not s.Overlay then return end
	local pred
	local ok = pcall(function()
		pred = PoolPhysics.PredictShot(s.Simulation, shot.dir, shot.power, Vector2.zero, 1 / 60)
	end)
	if ok and pred then
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

	local folder = guideFolder(s)
	if not folder then return end
	clearGuide(s)

	local cuePts = traceCue(s.Simulation, cue.Position, shot.dir, 42, 3)
	drawPoly(folder, cuePts, 0.55, Color3.fromRGB(124, 200, 255), 0.15)

	if shot.bank and shot.objPos and shot.contact and shot.pocketPos then
		drawSeg(folder, shot.objPos, shot.contact, 0.85, Color3.fromRGB(255, 201, 74), 0.05)
		drawSeg(folder, shot.contact, shot.pocketPos, 0.85, Color3.fromRGB(255, 201, 74), 0.05)
		local fs = PoolTableRenderer2D.GetFrameSize()
		local dot = Instance.new("Frame")
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromScale(0.5 + shot.contact.X / fs.X, 0.5 - shot.contact.Y / fs.Y)
		dot.Size = UDim2.fromScale((R * 2.4) / fs.X, (R * 2.4) / fs.Y)
		dot.BackgroundColor3 = Color3.fromRGB(255, 201, 74)
		dot.BackgroundTransparency = 0.2
		dot.BorderSizePixel = 0
		dot.ZIndex = 34
		Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
		dot.Parent = folder
	elseif shot.objPos and shot.pocketPos then
		drawSeg(folder, shot.objPos, shot.pocketPos, 0.55, Color3.fromRGB(124, 255, 107), 0.2)
	end
end

local function hideGuide(s)
	if s and s.Overlay then
		clearGuide(s)
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
	shotInfo.Text = string.format("%s: %d -> %s  p%.2f", shot.bank and "BANK" or "AIM", shot.ball, tostring(shot.pocket), shot.power)
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
			shotInfo.Text = string.format("AUTO %s: %d -> %s", shot.bank and "BANK" or "", shot.ball, tostring(shot.pocket))
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
	bankCandidate = bankCandidate,
	traceCue = traceCue,
	getCushions = getCushions,
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
