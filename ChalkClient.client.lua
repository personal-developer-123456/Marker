-- ChalkClient
-- Place as a LocalScript inside StarterPlayer > StarterPlayerScripts.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild("ChalkRemotes")
local DrawStroke = remotes:WaitForChild("DrawStroke")
local UndoStroke = remotes:WaitForChild("UndoStroke")
local Notice = remotes:WaitForChild("Notice")

----------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------

local DRAW_DISTANCE = 70
local MAX_POINTS = 250 -- per stroke (server allows 300)
local MAX_SEGMENT = 8 -- a bigger jump starts a new stroke
local MIN_STEP = 0.35
local MIN_BRUSH, MAX_BRUSH = 0.15, 1.2
local PREVIEW_LIFT = 0.12

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

----------------------------------------------------------------------
-- Menu
----------------------------------------------------------------------

local gui = create("ScreenGui", {
	Name = "ChalkMenu",
	ResetOnSpawn = false,
	DisplayOrder = 50,
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
	Size = UDim2.new(1, -76, 0, 36),
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
	brushSize = MIN_BRUSH + (MAX_BRUSH - MIN_BRUSH) * alpha
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

gui.Parent = playerGui

local statusToken = 0
local function showStatus(message)
	statusToken += 1
	local token = statusToken
	statusLabel.Text = message
	task.delay(4, function()
		if token == statusToken then
			statusLabel.Text = HINT
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
	resizeHandle.Visible = not locked
end)

----------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------

local previewRoot = Instance.new("Folder")
previewRoot.Name = "ChalkPreview"
previewRoot.Parent = workspace

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function updateFilter(character)
	rayParams.FilterDescendantsInstances = { character }
end
if player.Character then
	updateFilter(player.Character)
end
player.CharacterAdded:Connect(updateFilter)

local function previewPart(size, cframe, shape)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Sand
	part.Color = stroke.color
	part.Transparency = 0.05
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Parent = stroke.folder
end

local function previewDot(position)
	local normal = stroke.normal
	local side = normal:Cross(Vector3.xAxis)
	if side.Magnitude < 0.1 then
		side = normal:Cross(Vector3.zAxis)
	end
	previewPart(
		Vector3.new(0.04, stroke.size, stroke.size),
		CFrame.fromMatrix(position + normal * PREVIEW_LIFT, normal, side.Unit),
		Enum.PartType.Cylinder
	)
end

local function previewSegment(a, b)
	local normal = stroke.normal
	local d = b - a
	d = d - normal * d:Dot(normal)
	if d.Magnitude < 0.001 then
		return
	end
	previewPart(
		Vector3.new(d.Magnitude + stroke.size * 0.5, 0.04, stroke.size),
		CFrame.fromMatrix((a + b) / 2 + normal * PREVIEW_LIFT, d.Unit, normal)
	)
end

local function beginStroke(position, normal)
	local folder = Instance.new("Folder")
	folder.Name = "Preview"
	folder.Parent = previewRoot
	stroke = {
		points = { position },
		normal = normal.Unit,
		last = position,
		color = brushColor,
		size = brushSize,
		folder = folder,
	}
	previewDot(position)
end

local function endStroke()
	local finished = stroke
	stroke = nil
	if not finished then
		return
	end
	DrawStroke:FireServer(finished.color, finished.size, finished.normal, finished.points)
	-- the real stroke arrives from the server, then the preview goes away
	task.delay(0.6, function()
		finished.folder:Destroy()
	end)
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
	if #stroke.points >= MAX_POINTS then
		local lastPosition, lastNormal = stroke.last, stroke.normal
		endStroke()
		beginStroke(lastPosition, lastNormal)
	end

	previewSegment(stroke.last, position)
	table.insert(stroke.points, position)
	stroke.last = position
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

undoButton.Activated:Connect(function()
	UndoStroke:FireServer()
end)

Notice.OnClientEvent:Connect(function(message)
	if type(message) == "string" then
		showStatus(message)
	end
end)
