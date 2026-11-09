-- Chalk (client only, single file)
--
-- Run it in your executor, or put it in a LocalScript inside
-- StarterPlayer > StarterPlayerScripts. No server script is needed.
--
-- Everything is drawn on your own screen, so only YOU can see the drawings.
-- If your executor supports writefile/readfile, drawings are saved to a file
-- per place and come back the next time you run the script in that game.
-- Without file support they last until you leave.
--
-- Only Undo removes a stroke (newest first). Running the script again
-- replaces the old copy and reloads your saved drawings.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local env = (type(getgenv) == "function" and getgenv()) or _G
if env.ChalkClientCleanup then
	pcall(env.ChalkClientCleanup)
	env.ChalkClientCleanup = nil
end

----------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------

local DRAW_DISTANCE = 70
local MAX_POINTS = 250 -- per stroke
local MAX_SEGMENT = 8 -- a bigger jump starts a new stroke
local MIN_STEP = 0.35
local MIN_BRUSH, MAX_BRUSH = 0.15, 1.2

local MAX_STROKES = 400 -- strokes you can have at once
local MAX_TOTAL_PARTS = 40000 -- keeps the game from lagging
local MATERIAL = Enum.Material.Sand -- grainy, chalk-like look

local SAVE_DELAY = 2 -- seconds after a change before saving
local SAVE_FILE = "ChalkDrawings_" .. tostring(game.PlaceId) .. ".json"

-- Saved numbers are rounded to integers to keep the file small.
local POS_SCALE = 20 -- 0.05 stud precision
local NORMAL_SCALE = 100
local SIZE_SCALE = 100

local MIN_W, MIN_H = 210, 340
local MAX_W, MAX_H = 480, 620

local PALETTE = {
	Color3.fromRGB(245, 245, 240), -- white
	Color3.fromRGB(250, 224, 110), -- yellow
	Color3.fromRGB(245, 150, 190), -- pink
	Color3.fromRGB(235, 95, 95), -- red
	Color3.fromRGB(245, 160, 90), -- orange
	Color3.fromRGB(130, 200, 120), -- green
	Color3.fromRGB(110, 200, 200), -- teal
	Color3.fromRGB(110, 160, 240), -- blue
	Color3.fromRGB(170, 130, 230), -- purple
	Color3.fromRGB(60, 60, 60), -- dark
}

local BG = Color3.fromRGB(32, 38, 36)
local PANEL = Color3.fromRGB(52, 60, 57)
local TEXT = Color3.fromRGB(240, 240, 235)
local MUTED = Color3.fromRGB(170, 178, 174)
local ON_COLOR = Color3.fromRGB(90, 170, 110)
local OFF_COLOR = Color3.fromRGB(78, 86, 83)

local HINT = "Turn chalk on, then hold click (or touch) and drag over any surface."

local hasFiles = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local active = false
local locked = false
local brushSize = 0.4
local brushColor = PALETTE[1]

local drawInput = nil
local stroke = nil
local renderConn = nil
local charConn = nil
local leaveConn = nil

local strokes = {} -- oldest first: { rec = {...}, folder = Folder, parts = n }
local totalParts = 0
local layerCounter = 0
local lastLimitNotice = 0

local loaded = false
local saveBlocked = false
local dirty = false
local saveScheduled = false

local ACTION = "ChalkDraw"

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function create(class, props, children)
	local obj = Instance.new(class)
	for key, value in pairs(props) do
		obj[key] = value
	end
	for _, child in ipairs(children or {}) do
		child.Parent = obj
	end
	return obj
end

local function corner(radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

-- Calls callback(position) while a pressed input is held and moving.
local function followInput(input, callback)
	local moveConn, endConn
	moveConn = UserInputService.InputChanged:Connect(function(changed)
		local matches = (input.UserInputType == Enum.UserInputType.Touch and changed == input)
			or (
				input.UserInputType == Enum.UserInputType.MouseButton1
				and changed.UserInputType == Enum.UserInputType.MouseMovement
			)
		if matches then
			callback(changed.Position)
		end
	end)
	endConn = input.Changed:Connect(function()
		if input.UserInputState == Enum.UserInputState.End then
			moveConn:Disconnect()
			endConn:Disconnect()
		end
	end)
end

-- Pointer position in GUI space (same space as AbsolutePosition).
local function pointerPosition(input)
	if input.UserInputType == Enum.UserInputType.Touch then
		return Vector2.new(input.Position.X, input.Position.Y)
	end
	return UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
end

local function attachGui(screenGui)
	if type(gethui) == "function" then
		local ok, container = pcall(gethui)
		if ok and typeof(container) == "Instance" then
			local okParent = pcall(function()
				screenGui.Parent = container
			end)
			if okParent and screenGui.Parent == container then
				return
			end
		end
	end
	local okCore = pcall(function()
		screenGui.Parent = game:GetService("CoreGui")
	end)
	if okCore and screenGui.Parent then
		return
	end
	screenGui.Parent = playerGui
end

----------------------------------------------------------------------
-- Menu
----------------------------------------------------------------------

local gui = create("ScreenGui", {
	Name = "ChalkMenu",
	ResetOnSpawn = false,
	DisplayOrder = 50,
	IgnoreGuiInset = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})

local main = create("Frame", {
	Name = "Menu",
	Size = UDim2.fromOffset(240, 350),
	Position = UDim2.fromOffset(16, 110),
	BackgroundColor3 = BG,
	BackgroundTransparency = 0.05,
	BorderSizePixel = 0,
	Active = true,
	ClipsDescendants = true,
}, {
	corner(10),
	create("UIStroke", { Color = Color3.new(1, 1, 1), Transparency = 0.75, Thickness = 1 }),
})
main.Parent = gui

local titleBar = create("TextButton", {
	Name = "TitleBar",
	Size = UDim2.new(1, -104, 0, 36),
	BackgroundTransparency = 1,
	AutoButtonColor = false,
	Text = "  Chalk",
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = TEXT,
	TextSize = 18,
	Font = Enum.Font.GothamBold,
})
titleBar.Parent = main

local lockButton = create("TextButton", {
	Name = "LockButton",
	Size = UDim2.fromOffset(62, 24),
	Position = UDim2.new(1, -70, 0, 6),
	BackgroundColor3 = PANEL,
	Text = "Lock",
	TextColor3 = TEXT,
	TextSize = 14,
	Font = Enum.Font.GothamMedium,
}, { corner(6) })
lockButton.Parent = main

local compactButton = create("TextButton", {
	Name = "CompactButton",
	Size = UDim2.fromOffset(26, 24),
	Position = UDim2.new(1, -98, 0, 6),
	BackgroundColor3 = PANEL,
	Text = "-",
	TextColor3 = TEXT,
	TextSize = 18,
	Font = Enum.Font.GothamBold,
}, { corner(6) })
compactButton.Parent = main

local body = create("Frame", {
	Name = "Body",
	Position = UDim2.fromOffset(0, 38),
	Size = UDim2.new(1, 0, 1, -38),
	BackgroundTransparency = 1,
}, {
	create("UIListLayout", {
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
	create("UIPadding", {
		PaddingTop = UDim.new(0, 4),
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 24),
	}),
})
body.Parent = main

local toggleButton = create("TextButton", {
	Name = "ToggleButton",
	LayoutOrder = 1,
	Size = UDim2.new(1, 0, 0, 40),
	BackgroundColor3 = OFF_COLOR,
	Text = "Chalk: OFF",
	TextColor3 = TEXT,
	TextSize = 17,
	Font = Enum.Font.GothamBold,
}, { corner(8) })
toggleButton.Parent = body

local colorGrid = create("Frame", {
	Name = "Colors",
	LayoutOrder = 2,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
}, {
	create("UIGridLayout", {
		CellSize = UDim2.fromOffset(30, 30),
		CellPadding = UDim2.fromOffset(6, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})
colorGrid.Parent = body

local swatchStrokes = {}
local function selectColor(color)
	brushColor = color
	for swatchColor, swatchStroke in pairs(swatchStrokes) do
		swatchStroke.Thickness = (swatchColor == color) and 3 or 0
	end
end

for index, color in ipairs(PALETTE) do
	local swatch = create("TextButton", {
		LayoutOrder = index,
		BackgroundColor3 = color,
		Text = "",
		AutoButtonColor = true,
	}, { corner(15) })
	local swatchStroke = create("UIStroke", {
		Color = Color3.new(1, 1, 1),
		Thickness = 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
	swatchStroke.Parent = swatch
	swatchStrokes[color] = swatchStroke
	swatch.Activated:Connect(function()
		selectColor(color)
	end)
	swatch.Parent = colorGrid
end

local sizeRow = create("Frame", {
	Name = "SizeRow",
	LayoutOrder = 3,
	Size = UDim2.new(1, 0, 0, 46),
	BackgroundTransparency = 1,
})
sizeRow.Parent = body

local sizeLabel = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 18),
	BackgroundTransparency = 1,
	Text = "Size",
	TextColor3 = TEXT,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = Enum.Font.GothamMedium,
})
sizeLabel.Parent = sizeRow

local sliderArea = create("Frame", {
	Name = "SliderArea",
	Position = UDim2.fromOffset(0, 20),
	Size = UDim2.new(1, 0, 0, 26),
	BackgroundTransparency = 1,
	Active = true,
})
sliderArea.Parent = sizeRow

local bar = create("Frame", {
	Position = UDim2.new(0, 9, 0.5, -3),
	Size = UDim2.new(1, -18, 0, 6),
	BackgroundColor3 = PANEL,
	BorderSizePixel = 0,
}, { corner(3) })
bar.Parent = sliderArea

local knob = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Size = UDim2.fromOffset(18, 18),
	BackgroundColor3 = TEXT,
	BorderSizePixel = 0,
}, { corner(9) })
knob.Parent = bar

local function setBrushFromAlpha(alpha)
	alpha = math.clamp(alpha, 0, 1)
	-- rounded to 0.01 so a saved stroke looks exactly like the one you drew
	brushSize = math.round((MIN_BRUSH + (MAX_BRUSH - MIN_BRUSH) * alpha) * SIZE_SCALE) / SIZE_SCALE
	knob.Position = UDim2.new(alpha, 0, 0.5, 0)
	sizeLabel.Text = string.format("Size: %.2f", brushSize)
end

sliderArea.InputBegan:Connect(function(input)
	if not isPress(input) then
		return
	end
	local function update(position)
		setBrushFromAlpha((position.X - bar.AbsolutePosition.X) / math.max(1, bar.AbsoluteSize.X))
	end
	update(input.Position)
	followInput(input, update)
end)

local undoButton = create("TextButton", {
	Name = "UndoButton",
	LayoutOrder = 4,
	Size = UDim2.new(1, 0, 0, 32),
	BackgroundColor3 = PANEL,
	Text = "Undo last stroke",
	TextColor3 = TEXT,
	TextSize = 15,
	Font = Enum.Font.GothamMedium,
}, { corner(8) })
undoButton.Parent = body

local statusLabel = create("TextLabel", {
	Name = "Status",
	LayoutOrder = 5,
	Size = UDim2.new(1, 0, 0, 40),
	BackgroundTransparency = 1,
	Text = HINT,
	TextColor3 = MUTED,
	TextSize = 13,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	Font = Enum.Font.Gotham,
})
statusLabel.Parent = body

local resizeHandle = create("TextButton", {
	Name = "ResizeHandle",
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -2, 1, -2),
	Size = UDim2.fromOffset(24, 24),
	BackgroundTransparency = 1,
	Text = "//",
	TextColor3 = MUTED,
	TextSize = 16,
	Font = Enum.Font.GothamBold,
	ZIndex = 5,
})
resizeHandle.Parent = main

attachGui(gui)

----------------------------------------------------------------------
-- Compact mode: only the Chalk button and Lock stay visible
----------------------------------------------------------------------

local COMPACT_H = 90
local compact = false
local statusShown = false
local fullSize = main.Size

local function applyMode()
	colorGrid.Visible = not compact
	sizeRow.Visible = not compact
	undoButton.Visible = not compact
	-- in compact mode a notice (like the stroke limit) pops up for a few seconds
	statusLabel.Visible = (not compact) or statusShown
	resizeHandle.Visible = (not compact) and (not locked)
	if compact then
		main.Size = UDim2.fromOffset(fullSize.X.Offset, COMPACT_H + (statusShown and 48 or 0))
	end
end

local statusToken = 0
local function showStatus(message)
	statusToken += 1
	local token = statusToken
	statusLabel.Text = message
	statusShown = true
	applyMode()
	task.delay(4, function()
		if token == statusToken then
			statusLabel.Text = HINT
			statusShown = false
			applyMode()
		end
	end)
end

setBrushFromAlpha((brushSize - MIN_BRUSH) / (MAX_BRUSH - MIN_BRUSH))
selectColor(brushColor)

----------------------------------------------------------------------
-- Menu: drag, resize, lock
----------------------------------------------------------------------

titleBar.InputBegan:Connect(function(input)
	if locked or not isPress(input) then
		return
	end
	local start = input.Position
	local origin = main.Position
	followInput(input, function(position)
		local screen = gui.AbsoluteSize
		local x = origin.X.Offset + (position.X - start.X)
		local y = origin.Y.Offset + (position.Y - start.Y)
		x = math.clamp(x, 0, math.max(0, screen.X - main.Size.X.Offset))
		y = math.clamp(y, 0, math.max(0, screen.Y - 40))
		main.Position = UDim2.fromOffset(x, y)
	end)
end)

resizeHandle.InputBegan:Connect(function(input)
	if locked or not isPress(input) then
		return
	end
	local start = input.Position
	local startW, startH = main.Size.X.Offset, main.Size.Y.Offset
	followInput(input, function(position)
		local screen = gui.AbsoluteSize
		local maxW = math.min(MAX_W, screen.X - main.Position.X.Offset)
		local maxH = math.min(MAX_H, screen.Y - main.Position.Y.Offset)
		local w = math.clamp(startW + (position.X - start.X), MIN_W, math.max(MIN_W, maxW))
		local h = math.clamp(startH + (position.Y - start.Y), MIN_H, math.max(MIN_H, maxH))
		main.Size = UDim2.fromOffset(w, h)
	end)
end)

lockButton.Activated:Connect(function()
	locked = not locked
	lockButton.Text = locked and "Locked" or "Lock"
	lockButton.BackgroundColor3 = locked and ON_COLOR or PANEL
	applyMode()
end)

-- A mode switch, not a manual resize, so it also works while locked.
-- The menu stays where it is; only its size changes.
compactButton.Activated:Connect(function()
	if not compact then
		fullSize = main.Size
		compact = true
	else
		compact = false
		local screen = gui.AbsoluteSize
		local maxH = math.min(MAX_H, screen.Y - main.Position.Y.Offset)
		local h = math.clamp(fullSize.Y.Offset, MIN_H, math.max(MIN_H, maxH))
		main.Size = UDim2.fromOffset(fullSize.X.Offset, h)
	end
	compactButton.Text = compact and "+" or "-"
	applyMode()
end)

----------------------------------------------------------------------
-- Building strokes out of parts
----------------------------------------------------------------------

local world = Instance.new("Folder")
world.Name = "ChalkDrawings"
world.Parent = workspace

-- Makes the parts of one stroke. Call add(point) for each point in order,
-- then finish(). Used both while drawing and when loading saved strokes,
-- so a loaded stroke looks the same as when it was drawn.
local function newBuilder(color, width, normal)
	normal = normal.Unit

	-- Later strokes sit a hair higher so they draw over older ones.
	layerCounter = (layerCounter + 1) % 25
	local lift = 0.05 + layerCounter * 0.004

	local side = normal:Cross(Vector3.xAxis)
	if side.Magnitude < 0.1 then
		side = normal:Cross(Vector3.zAxis)
	end
	side = side.Unit

	local folder = Instance.new("Folder")
	folder.Name = "Stroke"
	folder.Parent = world

	local builder = { folder = folder, parts = 0 }
	local last, previousDir
	local pointCount = 0

	local function addPart(size, cframe, shape)
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = MATERIAL
		part.Color = color
		part.Transparency = 0.05
		if shape then
			part.Shape = shape
		end
		part.Size = size
		part.CFrame = cframe
		part.Parent = folder
		builder.parts += 1
		totalParts += 1
	end

	local function addDot(position)
		addPart(
			Vector3.new(0.04, width, width),
			CFrame.fromMatrix(position + normal * (lift + 0.002), normal, side),
			Enum.PartType.Cylinder
		)
	end

	function builder.add(point)
		pointCount += 1
		if not last then
			addDot(point)
			last = point
			return
		end
		local a, b = last, point
		local d = b - a
		d = d - normal * d:Dot(normal)
		local length = d.Magnitude
		if length > 0.001 then
			local dir = d / length
			addPart(
				Vector3.new(length + width * 0.5, 0.04, width),
				CFrame.fromMatrix((a + b) / 2 + normal * lift, dir, normal)
			)
			-- round off sharp corners
			if previousDir and previousDir:Dot(dir) < 0.92 then
				addDot(a)
			end
			previousDir = dir
		end
		last = point
	end

	function builder.finish()
		if pointCount > 1 and last then
			addDot(last)
		end
	end

	return builder
end

----------------------------------------------------------------------
-- Saving and loading (only when the executor supports files)
----------------------------------------------------------------------

local function save()
	if not hasFiles or not loaded or saveBlocked or not dirty then
		return
	end
	dirty = false
	local list = table.create(#strokes)
	for i, entry in ipairs(strokes) do
		list[i] = entry.rec
	end
	local ok, err = pcall(function()
		writefile(SAVE_FILE, HttpService:JSONEncode({ v = 1, strokes = list }))
	end)
	if not ok then
		dirty = true
		warn("[Chalk] Could not save: " .. tostring(err))
	end
end

local function markDirty()
	dirty = true
	if not hasFiles or saveScheduled then
		return
	end
	saveScheduled = true
	task.delay(SAVE_DELAY, function()
		saveScheduled = false
		save()
	end)
end

local function validRecord(rec)
	if type(rec) ~= "table" or type(rec.c) ~= "string" or type(rec.s) ~= "number" then
		return false
	end
	if type(rec.n) ~= "table" or type(rec.n[1]) ~= "number" or type(rec.n[2]) ~= "number" or type(rec.n[3]) ~= "number" then
		return false
	end
	if type(rec.p) ~= "table" or #rec.p < 3 then
		return false
	end
	for k = 1, #rec.p do
		if type(rec.p[k]) ~= "number" then
			return false
		end
	end
	return true
end

-- rec = { c = hex color, s = size * 100, n = { normal * 100 }, p = { x, y, z, ... } * 20 }
local function buildFromRecord(rec)
	if not validRecord(rec) then
		error("bad record")
	end
	local normal = Vector3.new(rec.n[1], rec.n[2], rec.n[3]) / NORMAL_SCALE
	if normal.Magnitude < 0.1 then
		normal = Vector3.yAxis
	end
	local builder = newBuilder(Color3.fromHex(rec.c), math.max(0.05, rec.s / SIZE_SCALE), normal)
	local flat = rec.p
	for k = 1, #flat - 2, 3 do
		builder.add(Vector3.new(flat[k], flat[k + 1], flat[k + 2]) / POS_SCALE)
	end
	builder.finish()
	return builder
end

local function loadSaved()
	if not hasFiles then
		return
	end

	local okExists, exists = pcall(isfile, SAVE_FILE)
	if not okExists then
		saveBlocked = true
		return
	end
	if not exists then
		return
	end

	local okRead, raw = pcall(readfile, SAVE_FILE)
	if not okRead or type(raw) ~= "string" then
		-- never overwrite a file we could not read
		saveBlocked = true
		warn("[Chalk] Could not read " .. SAVE_FILE .. ". Saving is turned off for this session.")
		return
	end

	local okDecode, data = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not okDecode or type(data) ~= "table" or type(data.strokes) ~= "table" then
		pcall(writefile, SAVE_FILE .. ".bak", raw)
		warn("[Chalk] Saved drawings were damaged. A copy was kept as " .. SAVE_FILE .. ".bak")
		return
	end

	local count = 0
	for _, rec in ipairs(data.strokes) do
		local okBuild, builder = pcall(buildFromRecord, rec)
		if okBuild then
			strokes[#strokes + 1] = { rec = rec, folder = builder.folder, parts = builder.parts }
			count += 1
		else
			warn("[Chalk] Skipped a damaged stroke.")
		end
		if count % 25 == 0 then
			task.wait()
		end
	end
	print("[Chalk] Loaded " .. count .. " strokes.")
	return count
end

----------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function updateFilter(character)
	if character then
		rayParams.FilterDescendantsInstances = { character, world }
	else
		rayParams.FilterDescendantsInstances = { world }
	end
end
updateFilter(player.Character)
charConn = player.CharacterAdded:Connect(updateFilter)

local function snapPoint(p)
	return Vector3.new(
		math.round(p.X * POS_SCALE),
		math.round(p.Y * POS_SCALE),
		math.round(p.Z * POS_SCALE)
	)
end

local function canStartStroke()
	if not loaded then
		return false
	end
	local message
	if #strokes >= MAX_STROKES then
		message = "Stroke limit reached. Undo something to draw more."
	elseif totalParts >= MAX_TOTAL_PARTS then
		message = "The world is full of chalk."
	end
	if message then
		if os.clock() - lastLimitNotice > 3 then
			lastLimitNotice = os.clock()
			showStatus(message)
		end
		return false
	end
	return true
end

local function addPointToStroke(snapped)
	local flat = stroke.flat
	local n = #flat
	if n > 0 and flat[n - 2] == snapped.X and flat[n - 1] == snapped.Y and flat[n] == snapped.Z then
		return
	end
	flat[n + 1] = snapped.X
	flat[n + 2] = snapped.Y
	flat[n + 3] = snapped.Z
	stroke.count += 1
	stroke.last = snapped / POS_SCALE
	stroke.builder.add(stroke.last)
end

local function beginStroke(position, normal)
	if not canStartStroke() then
		return false
	end

	local qn = Vector3.new(
		math.round(normal.X * NORMAL_SCALE),
		math.round(normal.Y * NORMAL_SCALE),
		math.round(normal.Z * NORMAL_SCALE)
	)
	local unitNormal = (qn.Magnitude > 0) and (qn / NORMAL_SCALE).Unit or Vector3.yAxis

	stroke = {
		builder = newBuilder(brushColor, brushSize, unitNormal),
		normal = unitNormal,
		qNormal = qn,
		color = brushColor,
		size = brushSize,
		flat = {},
		count = 0,
		last = position,
	}
	addPointToStroke(snapPoint(position))
	return true
end

local function endStroke()
	local finished = stroke
	stroke = nil
	if not finished then
		return
	end
	finished.builder.finish()

	local rec = {
		c = finished.color:ToHex(),
		s = math.round(finished.size * SIZE_SCALE),
		n = { finished.qNormal.X, finished.qNormal.Y, finished.qNormal.Z },
		p = finished.flat,
	}
	strokes[#strokes + 1] = {
		rec = rec,
		folder = finished.builder.folder,
		parts = finished.builder.parts,
	}
	markDirty()
end

local function undo()
	-- a stroke being drawn right now is finished first, then undone
	if stroke then
		endStroke()
	end
	local entry = table.remove(strokes)
	if not entry then
		showStatus("Nothing to undo.")
		return
	end
	totalParts -= entry.parts
	entry.folder:Destroy()
	markDirty()
end

local function step()
	if not drawInput then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local screen = pointerPosition(drawInput)
	local ray = camera:ScreenPointToRay(screen.X, screen.Y)
	local result = workspace:Raycast(ray.Origin, ray.Direction * DRAW_DISTANCE, rayParams)
	if not result then
		return
	end

	local instance = result.Instance
	if not instance.Anchored then
		return
	end
	local model = instance:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return
	end

	local position, normal = result.Position, result.Normal
	if not stroke then
		beginStroke(position, normal)
		return
	end

	local distance = (position - stroke.last).Magnitude
	if stroke.normal:Dot(normal) < 0.95 or distance > MAX_SEGMENT then
		endStroke()
		beginStroke(position, normal)
		return
	end
	if distance < math.max(MIN_STEP, stroke.size * 0.5) then
		return
	end
	if totalParts >= MAX_TOTAL_PARTS then
		endStroke()
		canStartStroke()
		return
	end
	if stroke.count >= MAX_POINTS then
		local lastPosition, lastNormal = stroke.last, stroke.normal
		endStroke()
		if not beginStroke(lastPosition, lastNormal) then
			return
		end
	end

	addPointToStroke(snapPoint(position))
end

local function stopDrawing()
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	endStroke()
	drawInput = nil
end

local function overMenu(input)
	local p = pointerPosition(input)
	local pos, size = main.AbsolutePosition, main.AbsoluteSize
	return p.X >= pos.X and p.X <= pos.X + size.X and p.Y >= pos.Y and p.Y <= pos.Y + size.Y
end

local function sameInput(a, b)
	if a.UserInputType == Enum.UserInputType.Touch then
		return a == b
	end
	return a.UserInputType == b.UserInputType
end

local function onDrawInput(_, state, input)
	if state == Enum.UserInputState.Begin then
		if overMenu(input) then
			return Enum.ContextActionResult.Pass
		end
		if not drawInput then
			drawInput = input
			renderConn = RunService.RenderStepped:Connect(step)
			step()
		end
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		if drawInput and sameInput(input, drawInput) then
			stopDrawing()
		end
	end
	return Enum.ContextActionResult.Sink
end

local function setActive(state)
	active = state
	toggleButton.Text = state and "Chalk: ON" or "Chalk: OFF"
	toggleButton.BackgroundColor3 = state and ON_COLOR or OFF_COLOR
	if state then
		ContextActionService:BindActionAtPriority(
			ACTION,
			onDrawInput,
			false,
			Enum.ContextActionPriority.High.Value,
			Enum.UserInputType.MouseButton1,
			Enum.UserInputType.Touch
		)
	else
		ContextActionService:UnbindAction(ACTION)
		stopDrawing()
	end
end

toggleButton.Activated:Connect(function()
	setActive(not active)
end)

undoButton.Activated:Connect(undo)

----------------------------------------------------------------------
-- Cleanup (running the script again replaces this copy)
----------------------------------------------------------------------

local function cleanup()
	pcall(function()
		if active then
			setActive(false)
		end
		save()
	end)
	if charConn then
		charConn:Disconnect()
	end
	if leaveConn then
		leaveConn:Disconnect()
	end
	pcall(function()
		ContextActionService:UnbindAction(ACTION)
	end)
	gui:Destroy()
	world:Destroy()
end
env.ChalkClientCleanup = cleanup

leaveConn = Players.PlayerRemoving:Connect(function(leaving)
	if leaving == player then
		save()
	end
end)

----------------------------------------------------------------------
-- Start
----------------------------------------------------------------------

task.spawn(function()
	local count = loadSaved()
	loaded = true
	if not hasFiles then
		showStatus("This executor can't save files, so drawings last until you leave.")
	elseif saveBlocked then
		showStatus("Could not read your saved drawings. Saving is off this session.")
	elseif count and count > 0 then
		showStatus("Loaded " .. count .. " saved strokes.")
	end
end)
