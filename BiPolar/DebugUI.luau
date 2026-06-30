--!strict

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Profiler = require(script.Parent.Profiler)
local Diagnostics = require(script.Parent.Diagnostics)

local DebugUI = {}

local TOGGLE_KEY = Enum.KeyCode.F3
local PAUSE_KEY = Enum.KeyCode.P
local BAR_W = 4
local MAX_FRAMES = Profiler.maxFrames()
local MAX_LEGEND = 128

local function formatBytes(n: number): string
	if n >= 1048576 then
		return string.format("%.1f MB", n / 1048576)
	elseif n >= 1024 then
		return string.format("%.1f KB", n / 1024)
	end
	return string.format("%d B", n)
end

local function colorFor(name: string): Color3
	local h = 0
	for i = 1, #name do
		h = (h * 31 + string.byte(name, i)) % 360
	end
	return Color3.fromHSV(h / 360, 0.6, 0.95)
end

local function pretty(value: any, indent: string, depth: number): string
	if depth > 8 then
		return "<...>"
	end
	local ty = typeof(value)
	if ty == "table" then
		local keys: { any } = {}
		for k in value do
			table.insert(keys, k)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		if #keys == 0 then
			return "{}"
		end
		local inner = indent .. "  "
		local parts: { string } = {}
		for _, k in keys do
			local keyStr = if type(k) == "string" then tostring(k) else `[{tostring(k)}]`
			table.insert(parts, `{inner}{keyStr} = {pretty(value[k], inner, depth + 1)}`)
		end
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
	elseif ty == "string" then
		return string.format("%q", value)
	elseif ty == "number" or ty == "boolean" or ty == "nil" then
		return tostring(value)
	end
	return `{ty}({tostring(value)})`
end

local function hexDump(raw: buffer): string
	local n = buffer.len(raw)
	if n == 0 then
		return "(empty)"
	end
	local lines: { string } = {}
	for i = 0, n - 1, 16 do
		local cells: { string } = {}
		for j = 0, 15 do
			local idx = i + j
			if idx < n then
				table.insert(cells, string.format("%02X", buffer.readu8(raw, idx)))
			end
		end
		table.insert(lines, string.format("%04X: %s", i, table.concat(cells, " ")))
	end
	return table.concat(lines, "\n")
end

local function hotText(hot: { Diagnostics.HotScope }): string
	if #hot == 0 then
		return "  (none -- use Bipolar.debug.scope)"
	end
	local lines: { string } = {}
	for _, h in hot do
		table.insert(lines, string.format("  %-22s %6.2f ms", h.name:sub(1, 22), h.ms))
	end
	return table.concat(lines, "\n")
end

local function attachDrag(handle: GuiObject, window: Frame, resize: boolean)
	local active = false
	local startInput = Vector2.zero
	local startValue = Vector2.zero
	handle.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			active = true
			startInput = input.Position
			startValue = if resize
				then Vector2.new(window.AbsoluteSize.X, window.AbsoluteSize.Y)
				else Vector2.new(window.Position.X.Offset, window.Position.Y.Offset)
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					active = false
				end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if not active then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - startInput
			if resize then
				window.Size = UDim2.fromOffset(math.max(240, startValue.X + delta.X), math.max(150, startValue.Y + delta.Y))
			else
				window.Position = UDim2.fromOffset(startValue.X + delta.X, startValue.Y + delta.Y)
			end
		end
	end)
end

local function makeWindow(titleText: string, x: number, y: number, w: number, h: number): (Frame, TextLabel, Frame)
	local window = Instance.new("Frame")
	window.Size = UDim2.fromOffset(w, h)
	window.Position = UDim2.fromOffset(x, y)
	window.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
	window.BackgroundTransparency = 0.08
	window.BorderSizePixel = 0
	window.Active = true

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = window

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 24)
	title.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
	title.BorderSizePixel = 0
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextColor3 = Color3.fromRGB(127, 209, 255)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "  " .. titleText
	title.Parent = window
	local titleCorner = Instance.new("UICorner")
	titleCorner.CornerRadius = UDim.new(0, 6)
	titleCorner.Parent = title

	local body = Instance.new("Frame")
	body.Position = UDim2.fromOffset(8, 28)
	body.Size = UDim2.new(1, -16, 1, -36)
	body.BackgroundTransparency = 1
	body.ClipsDescendants = true
	body.Parent = window

	local grip = Instance.new("TextButton")
	grip.AnchorPoint = Vector2.new(1, 1)
	grip.Position = UDim2.new(1, -2, 1, -2)
	grip.Size = UDim2.fromOffset(16, 16)
	grip.BackgroundColor3 = Color3.fromRGB(80, 80, 100)
	grip.BorderSizePixel = 0
	grip.Text = "/"
	grip.TextColor3 = Color3.fromRGB(200, 200, 220)
	grip.TextSize = 12
	grip.AutoButtonColor = true
	grip.ZIndex = 5
	grip.Parent = window

	attachDrag(title, window, false)
	attachDrag(grip, window, true)
	return window, title, body
end

local function makeTextBody(body: Frame): TextLabel
	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = body
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -6, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = 13
	label.TextColor3 = Color3.fromRGB(220, 220, 230)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Text = "..."
	label.Parent = scroll
	return label
end

local gui: ScreenGui? = nil
local visible = false

local clientLabel: TextLabel? = nil
local serverLabel: TextLabel? = nil

local pauseButton: TextButton? = nil
local statusLabel: TextLabel? = nil
local timeline: ScrollingFrame? = nil
local marker: Frame? = nil
local shareBar: Frame? = nil
local detailLabel: TextLabel? = nil
local bars: { TextButton } = {}
local legendRows: { TextButton } = {}
local legendNames: { string } = {}
local selectedFrame: number? = nil
local selectedPacket: string? = nil
local breakdownAccum = 0

local lastSampleByName: { [string]: Profiler.LogEntry } = {}

local function renderClient()
	if not clientLabel then
		return
	end
	local s = Diagnostics.localSnapshot()
	clientLabel.Text = table.concat({
		string.format("FPS        %.0f   (%.2f ms)", s.fps, s.frameMs),
		string.format("Ping       %.0f ms", s.ping),
		string.format("Net recv   %.1f kb/s", s.recvKbps),
		string.format("Net send   %.1f kb/s", s.sendKbps),
		string.format("Physics    %.1f kb/s", s.physicsKbps),
		string.format("Lua heap   %.1f MB", s.luaHeapMb),
		string.format("Total mem  %.1f MB", s.totalMemMb),
		string.format("Instances  %d", s.instances),
		string.format("Uptime     %.0f s", s.uptime),
		"",
		"hot scopes (ms/s):",
		hotText(s.hot),
	}, "\n")
end

local function renderServer()
	if not serverLabel then
		return
	end
	local s = Diagnostics.serverSnapshot()
	if not s then
		serverLabel.Text = "waiting for server stats...\n(panel open = server streams its metrics)"
		return
	end
	serverLabel.Text = table.concat({
		string.format("Uptime     %.0f s", s.uptime),
		string.format("Players    %d", s.players),
		string.format("Heartbeat  %.2f ms", s.heartbeatMs),
		string.format("Lua heap   %.1f MB", s.luaHeapMb),
		string.format("Total mem  %.1f MB", s.totalMemMb),
		string.format("Instances  %d", s.instances),
		string.format("Net recv   %.1f kb/s", s.recvKbps),
		string.format("Net send   %.1f kb/s", s.sendKbps),
		"",
		"hot scopes (ms/s):",
		hotText(s.hot),
	}, "\n")
end

local function isInternal(name: string): boolean
	return string.sub(name, 1, 2) == "__"
end

local function detailText(name: string): string
	local snapshot = Profiler.snapshot()
	local s = snapshot.packets[name]
	local lines: { string } = { name }
	if s then
		local avgOut = if s.outCount > 0 then s.outBytes / s.outCount else 0
		table.insert(lines, string.format("out: %s / %d msgs (avg %.1f B)", formatBytes(s.outBytes), s.outCount, avgOut))
		table.insert(lines, string.format("in:  %s / %d msgs", formatBytes(s.inBytes), s.inCount))
	end
	local sample = lastSampleByName[name]
	if sample then
		table.insert(lines, "")
		table.insert(lines, `latest [{sample.kind}/{sample.dir}] {sample.bytes} B  player={sample.player or "(none)"}`)
		table.insert(lines, "--- DECODED (unraw) ---")
		table.insert(lines, pretty(sample.value, "", 0))
		if sample.raw then
			table.insert(lines, `--- RAW (buffer, {buffer.len(sample.raw)} bytes) ---`)
			table.insert(lines, hexDump(sample.raw))
		end
	else
		table.insert(lines, "\n(no message captured yet)")
	end
	return table.concat(lines, "\n")
end

local function selectPacket(name: string)
	selectedPacket = name
	if detailLabel then
		detailLabel.Text = detailText(name)
	end
end

type Row = { name: string, bytes: number, count: number }

local function breakdownRows(): ({ Row }, number, string)
	local rows: { Row } = {}
	local total = 0
	if Profiler.isPaused() and selectedFrame then
		local f = Profiler.frames()[selectedFrame]
		if f then
			for name, b in f.perPacket do
				if not isInternal(name) then
					total += b
					table.insert(rows, { name = name, bytes = b, count = 0 })
				end
			end
		end
		table.sort(rows, function(a, b)
			return a.bytes > b.bytes
		end)
		return rows, total, "frame"
	end
	for name, r in Profiler.rates() do
		if not isInternal(name) then
			local b = r.outBytes + r.inBytes
			total += b
			table.insert(rows, { name = name, bytes = b, count = r.outCount + r.inCount })
		end
	end
	table.sort(rows, function(a, b)
		return a.bytes > b.bytes
	end)
	return rows, total, "sec"
end

local function renderShareBar(rows: { Row }, total: number)
	local bar = shareBar
	if not bar then
		return
	end
	for _, child in bar:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	if total <= 0 then
		return
	end
	for i, row in rows do
		local slice = Instance.new("Frame")
		slice.Size = UDim2.fromScale(row.bytes / total, 1)
		slice.BackgroundColor3 = colorFor(row.name)
		slice.BorderSizePixel = 0
		slice.LayoutOrder = i
		slice.Parent = bar
	end
end

local function renderLegend(rows: { Row }, total: number, unit: string)
	for i = 1, MAX_LEGEND do
		local btn = legendRows[i]
		local row = rows[i]
		if row then
			local pct = if total > 0 then row.bytes / total * 100 else 0
			legendNames[i] = row.name
			btn.Visible = true
			btn.TextColor3 = colorFor(row.name)
			btn.BackgroundColor3 = if row.name == selectedPacket then Color3.fromRGB(60, 60, 80) else Color3.fromRGB(24, 24, 30)
			btn.Text = string.format(" %-16s %9s/%s  %4.1f%%", row.name:sub(1, 16), formatBytes(row.bytes), unit, pct)
		else
			legendNames[i] = ""
			btn.Visible = false
		end
	end
end

local function heaviest(f: Profiler.FrameSample): string?
	local best, bestB = nil, -1
	for name, b in f.perPacket do
		if not isInternal(name) and b > bestB then
			best, bestB = name, b
		end
	end
	return best
end

local function renderTimeline()
	local tl = timeline
	if not tl then
		return
	end
	local frames = Profiler.frames()
	local maxB, sum = 1, 0
	for _, f in frames do
		maxB = math.max(maxB, f.total)
		sum += f.total
	end
	local avg = if #frames > 0 then sum / #frames else 0

	for i = 1, MAX_FRAMES do
		local bar = bars[i]
		local f = frames[i]
		if f then
			bar.Visible = true
			bar.Size = UDim2.new(0, BAR_W - 1, math.clamp(f.total / maxB, if f.total > 0 then 0.04 else 0, 1), 0)
			local hn = heaviest(f)
			local col = if hn then colorFor(hn) else Color3.fromRGB(70, 70, 80)
			if f.total > avg * 2 and f.total > 0 then
				col = Color3.fromRGB(255, 80, 80)
			end
			bar.BackgroundColor3 = col
		else
			bar.Visible = false
		end
	end

	if marker then
		if Profiler.isPaused() and selectedFrame and frames[selectedFrame] then
			marker.Visible = true
			marker.Position = UDim2.fromOffset((selectedFrame - 1) * BAR_W, 0)
		else
			marker.Visible = false
		end
	end

	if not Profiler.isPaused() then
		tl.CanvasPosition = Vector2.new(math.max(0, MAX_FRAMES * BAR_W - tl.AbsoluteSize.X), 0)
	end
end

local function renderNet()
	local rows, total, unit = breakdownRows()
	if statusLabel then
		local state = if Profiler.isPaused() then "PAUSED" else "LIVE"
		statusLabel.Text = string.format("%s   %s/%s", state, formatBytes(total), unit)
	end
	renderShareBar(rows, total)
	renderLegend(rows, total, unit)
	if selectedPacket and detailLabel then
		detailLabel.Text = detailText(selectedPacket)
	end
end

local function setPaused(state: boolean)
	Profiler.setPaused(state)
	if pauseButton then
		pauseButton.Text = if state then "RESUME" else "PAUSE"
		pauseButton.BackgroundColor3 = if state then Color3.fromRGB(70, 120, 70) else Color3.fromRGB(120, 70, 70)
	end
	if state then
		local n = #Profiler.frames()
		selectedFrame = if n > 0 then n else nil
	else
		selectedFrame = nil
	end
	renderTimeline()
	renderNet()
end

local function makeHeader(text: string, order: number, parent: Instance): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 15)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 11
	label.TextColor3 = Color3.fromRGB(127, 209, 255)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = text
	label.LayoutOrder = order
	label.Parent = parent
	return label
end

local function buildNetPanel(body: Frame)
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 3)
	layout.Parent = body

	local controls = Instance.new("Frame")
	controls.Size = UDim2.new(1, 0, 0, 22)
	controls.BackgroundTransparency = 1
	controls.LayoutOrder = 1
	controls.Parent = body
	local pause = Instance.new("TextButton")
	pause.Size = UDim2.fromOffset(76, 22)
	pause.BackgroundColor3 = Color3.fromRGB(120, 70, 70)
	pause.BorderSizePixel = 0
	pause.Font = Enum.Font.GothamBold
	pause.TextSize = 12
	pause.TextColor3 = Color3.fromRGB(240, 240, 240)
	pause.Text = "PAUSE"
	pause.Parent = controls
	local pauseCorner = Instance.new("UICorner")
	pauseCorner.CornerRadius = UDim.new(0, 4)
	pauseCorner.Parent = pause
	local status = Instance.new("TextLabel")
	status.Size = UDim2.new(1, -84, 1, 0)
	status.Position = UDim2.fromOffset(84, 0)
	status.BackgroundTransparency = 1
	status.Font = Enum.Font.Code
	status.TextSize = 13
	status.TextColor3 = Color3.fromRGB(220, 220, 230)
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Text = "LIVE"
	status.Parent = controls

	makeHeader("TIMELINE  (P to pause, click a bar)", 2, body)
	local tl = Instance.new("ScrollingFrame")
	tl.Size = UDim2.new(1, 0, 0, 60)
	tl.BackgroundColor3 = Color3.fromRGB(10, 10, 12)
	tl.BackgroundTransparency = 0.3
	tl.BorderSizePixel = 0
	tl.ScrollBarThickness = 6
	tl.ScrollingDirection = Enum.ScrollingDirection.X
	tl.CanvasSize = UDim2.fromOffset(MAX_FRAMES * BAR_W, 0)
	tl.LayoutOrder = 3
	tl.Parent = body
	for i = 1, MAX_FRAMES do
		local bar = Instance.new("TextButton")
		bar.AnchorPoint = Vector2.new(0, 1)
		bar.Position = UDim2.new(0, (i - 1) * BAR_W, 1, 0)
		bar.Size = UDim2.new(0, BAR_W - 1, 0, 0)
		bar.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
		bar.BorderSizePixel = 0
		bar.Text = ""
		bar.AutoButtonColor = false
		bar.Visible = false
		bar.Parent = tl
		bars[i] = bar
		local index = i
		bar.Activated:Connect(function()
			if Profiler.isPaused() then
				selectedFrame = index
				renderTimeline()
				renderNet()
			end
		end)
	end
	local mk = Instance.new("Frame")
	mk.Size = UDim2.new(0, BAR_W - 1, 1, 0)
	mk.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	mk.BackgroundTransparency = 0.4
	mk.BorderSizePixel = 0
	mk.Visible = false
	mk.ZIndex = 2
	mk.Parent = tl

	makeHeader("BANDWIDTH SHARE", 4, body)
	local share = Instance.new("Frame")
	share.Size = UDim2.new(1, 0, 0, 16)
	share.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
	share.BorderSizePixel = 0
	share.ClipsDescendants = true
	share.LayoutOrder = 5
	share.Parent = body
	local shareCorner = Instance.new("UICorner")
	shareCorner.CornerRadius = UDim.new(0, 4)
	shareCorner.Parent = share
	local shareLayout = Instance.new("UIListLayout")
	shareLayout.FillDirection = Enum.FillDirection.Horizontal
	shareLayout.SortOrder = Enum.SortOrder.LayoutOrder
	shareLayout.Parent = share

	makeHeader("PACKETS  (click to inspect)", 6, body)
	local legend = Instance.new("ScrollingFrame")
	legend.Size = UDim2.new(1, 0, 0, 120)
	legend.BackgroundColor3 = Color3.fromRGB(10, 10, 12)
	legend.BackgroundTransparency = 0.3
	legend.BorderSizePixel = 0
	legend.ScrollBarThickness = 6
	legend.AutomaticCanvasSize = Enum.AutomaticSize.Y
	legend.CanvasSize = UDim2.new()
	legend.LayoutOrder = 7
	legend.Parent = body
	local legendLayout = Instance.new("UIListLayout")
	legendLayout.SortOrder = Enum.SortOrder.LayoutOrder
	legendLayout.Padding = UDim.new(0, 1)
	legendLayout.Parent = legend
	for i = 1, MAX_LEGEND do
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1, 0, 0, 18)
		btn.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
		btn.BackgroundTransparency = 0.3
		btn.BorderSizePixel = 0
		btn.Font = Enum.Font.Code
		btn.TextSize = 13
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.LayoutOrder = i
		btn.Visible = false
		btn.Text = ""
		btn.Parent = legend
		legendRows[i] = btn
		legendNames[i] = ""
		local index = i
		btn.Activated:Connect(function()
			local name = legendNames[index]
			if name ~= "" then
				selectPacket(name)
				renderNet()
			end
		end)
	end

	makeHeader("DETAIL", 8, body)
	local detail = Instance.new("ScrollingFrame")
	detail.Size = UDim2.new(1, 0, 0, 150)
	detail.BackgroundColor3 = Color3.fromRGB(10, 10, 12)
	detail.BackgroundTransparency = 0.3
	detail.BorderSizePixel = 0
	detail.ScrollBarThickness = 6
	detail.AutomaticCanvasSize = Enum.AutomaticSize.Y
	detail.CanvasSize = UDim2.new()
	detail.LayoutOrder = 9
	detail.Parent = body
	local detailContent = Instance.new("TextLabel")
	detailContent.Size = UDim2.new(1, -6, 0, 0)
	detailContent.AutomaticSize = Enum.AutomaticSize.Y
	detailContent.BackgroundTransparency = 1
	detailContent.Font = Enum.Font.Code
	detailContent.TextSize = 13
	detailContent.TextColor3 = Color3.fromRGB(210, 210, 220)
	detailContent.TextXAlignment = Enum.TextXAlignment.Left
	detailContent.TextYAlignment = Enum.TextYAlignment.Top
	detailContent.Text = "Click a packet to see its decoded args and raw buffer."
	detailContent.Parent = detail

	pause.Activated:Connect(function()
		setPaused(not Profiler.isPaused())
	end)

	pauseButton = pause
	statusLabel = status
	timeline = tl
	marker = mk
	shareBar = share
	detailLabel = detailContent
end

local function build()
	if gui then
		return
	end
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "BipolarDebug"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 1000

	local clientWindow, _, clientBody = makeWindow("BiPolar · CLIENT  (F3)", 20, 20, 260, 300)
	clientWindow.Parent = screen
	clientLabel = makeTextBody(clientBody)

	local serverWindow, _, serverBody = makeWindow("BiPolar · SERVER  (F3)", 290, 20, 260, 300)
	serverWindow.Parent = screen
	serverLabel = makeTextBody(serverBody)

	local netWindow, _, netBody = makeWindow("BiPolar · NET  (F3)", 20, 340, 460, 420)
	netWindow.Parent = screen
	buildNetPanel(netBody)

	screen.Parent = playerGui
	gui = screen
end

function DebugUI.setVisible(state: boolean)
	visible = state
	Profiler.setLogging(state)
	Diagnostics.subscribeServer(state)
	if state then
		build()
		renderClient()
		renderServer()
		renderTimeline()
		renderNet()
	end
	if gui then
		gui.Enabled = visible
	end
end

function DebugUI.toggle()
	DebugUI.setVisible(not visible)
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == TOGGLE_KEY then
		DebugUI.toggle()
	elseif input.KeyCode == PAUSE_KEY and visible then
		setPaused(not Profiler.isPaused())
	end
end)

Profiler.onFrame(function()
	if not visible then
		return
	end
	renderTimeline()
	breakdownAccum += 1
	if breakdownAccum >= 6 then
		breakdownAccum = 0
		renderNet()
	end
end)

Profiler.onInterval(function()
	if visible then
		renderClient()
		renderServer()
	end
end)

Profiler.onLog(function(entry: Profiler.LogEntry)
	lastSampleByName[entry.name] = entry
end)

return DebugUI
