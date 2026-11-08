--[[
    CLIENT WAYPOINT & MARKER SYSTEM
    Version: 1.0
    Platform: Roblox
    Location: StarterPlayerScripts > LocalScript

    Features:
    - Mobile and desktop interface
    - Surface raycasting
    - Surface-attached markers
    - Active waypoint beam and indicator
    - Distance display
    - Marker list and customization
    - Optional JSON file storage
    - Memory fallback
    - Gamepad support
    - Draggable and minimizable panel
    - Long-press marker movement
    - Cleanup and respawn handling

    NOTE:
    File APIs are not available in ordinary Roblox LocalScripts.
]]

--==================================================
-- 1. CONFIGURATION
--==================================================

local CONFIG = {
    MaxMarkers = 50,

    MarkerColor = Color3.fromRGB(255, 190, 60),
    WaypointColor = Color3.fromRGB(50, 220, 120),

    MarkerSize = 1,
    MarkerIcon = "📍",

    FadeDistance = 150,

    DefaultVisibility = "A", -- A = Always visible, B = Near only

    SaveEnabled = true,
    SaveFilePrefix = "WaypointData_",

    -- Set to a folder name to restrict marker placement.
    -- nil means any BasePart in Workspace is valid.
    MapFolderName = nil,

    -- Alternatively, use a CollectionService tag.
    MapTag = nil,

    -- UI configuration
    UIPadding = 12,
    UIWidth = 300,
    UIHeight = 440,

    BackgroundColor = Color3.fromRGB(28, 31, 40),
    AccentColor = Color3.fromRGB(55, 145, 255),

    TouchTapThreshold = 12,
    LongPressDuration = 0.65,

    NearDistance = 150,

    BeamWidth = 0.12,
}

--==================================================
-- 2. SERVICES
--==================================================

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")
local CollectionService = game:GetService("CollectionService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Camera = workspace.CurrentCamera

--==================================================
-- 3. INSTANCE CLEANUP / REINITIALIZATION
--==================================================

local OLD = PlayerGui:FindFirstChild("WaypointSystem")

if OLD then
    OLD:Destroy()
end

local OLD_WORLD = workspace:FindFirstChild("ClientWaypointObjects")

if OLD_WORLD then
    OLD_WORLD:Destroy()
end

local Connections = {}
local WorldFolder = Instance.new("Folder")
WorldFolder.Name = "ClientWaypointObjects"
WorldFolder.Parent = workspace

local Unloaded = false

local function Connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(Connections, connection)
    return connection
end

local function DisconnectAll()
    for _, connection in ipairs(Connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end

    table.clear(Connections)
end

--==================================================
-- 4. STORAGE MODULE
--==================================================

local Storage = {}

local MemoryStorage = {}

local PlaceKey = CONFIG.SaveFilePrefix .. tostring(game.PlaceId) .. ".json"

local function FileAPIAvailable()
    return type(writefile) == "function"
        and type(readfile) == "function"
        and type(isfile) == "function"
end

function Storage.Save(data)
    local success, result = pcall(function()

        if not CONFIG.SaveEnabled then
            return false
        end

        local encoded = HttpService:JSONEncode(data)

        if FileAPIAvailable() then
            writefile(PlaceKey, encoded)
            return true
        end

        MemoryStorage[game.PlaceId] = encoded
        return true

    end)

    if not success then
        warn("[WaypointSystem] Save failed:", result)
        return false
    end

    return result
end

function Storage.Load()
    local success, result = pcall(function()

        if not CONFIG.SaveEnabled then
            return nil
        end

        local encoded

        if FileAPIAvailable() then
            if isfile(PlaceKey) then
                encoded = readfile(PlaceKey)
            end
        else
            encoded = MemoryStorage[game.PlaceId]
        end

        if not encoded then
            return nil
        end

        return HttpService:JSONDecode(encoded)
    end)

    if not success then
        warn("[WaypointSystem] Load failed:", result)
        return nil
    end

    return result
end

--==================================================
-- 5. STATE
--==================================================

local Markers = {}
local ActiveMarker = nil
local SelectedMarker = nil

local NextMarkerId = 0

local Settings = {
    Visibility = CONFIG.DefaultVisibility,
    SaveEnabled = CONFIG.SaveEnabled,
    MarkerColor = CONFIG.MarkerColor,
    WaypointColor = CONFIG.WaypointColor,
}

local function GetCharacter()
    return Player.Character
end

local function GetRoot()
    local character = GetCharacter()

    if not character then
        return nil
    end

    return character:FindFirstChild("HumanoidRootPart")
end

--==================================================
-- 6. MAP VALIDATION
--==================================================

local function IsValidMapPart(part)

    if not part or not part:IsA("BasePart") then
        return false
    end

    if not part:IsDescendantOf(workspace) then
        return false
    end

    if CONFIG.MapFolderName then
        local folder = workspace:FindFirstChild(
            CONFIG.MapFolderName,
            true
        )

        if not folder or not part:IsDescendantOf(folder) then
            return false
        end
    end

    if CONFIG.MapTag then
        if not CollectionService:HasTag(part, CONFIG.MapTag) then
            return false
        end
    end

    return true
end

--==================================================
-- 7. RAYCASTING
--==================================================

local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Exclude

local function UpdateRayFilter()
    local character = GetCharacter()

    RayParams.FilterDescendantsInstances = {
        WorldFolder,
        character
    }
end

local function ScreenRaycast(screenPosition)

    Camera = workspace.CurrentCamera

    if not Camera then
        return nil
    end

    UpdateRayFilter()

    local ray = Camera:ViewportPointToRay(
        screenPosition.X,
        screenPosition.Y
    )

    local result = workspace:Raycast(
        ray.Origin,
        ray.Direction * 2000,
        RayParams
    )

    if not result then
        return nil
    end

    if not IsValidMapPart(result.Instance) then
        return nil
    end

    return result
end

--==================================================
-- 8. MARKER VISUALS
--==================================================

local function CreateMarkerVisual(marker)

    local attachment = Instance.new("Attachment")
    attachment.Name = "WaypointAttachment"

    attachment.Position = marker.LocalPosition
    attachment.Parent = marker.Surface

    marker.Attachment = attachment

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "MarkerBillboard"
    billboard.Size = UDim2.fromOffset(80, 65)
    billboard.StudsOffset = Vector3.new(0, 2, 0)
    billboard.AlwaysOnTop = true
    billboard.MaxDistance =
        Settings.Visibility == "B"
        and CONFIG.NearDistance
        or 0

    billboard.Parent = attachment

    local icon = Instance.new("TextLabel")
    icon.Size = UDim2.fromScale(1, 1)
    icon.BackgroundTransparency = 1
    icon.Text = marker.Icon or CONFIG.MarkerIcon
    icon.TextScaled = true
    icon.Font = Enum.Font.GothamBold
    icon.TextColor3 = marker.Color
    icon.Parent = billboard

    marker.Billboard = billboard

    -- Optional waypoint beam
    if marker == ActiveMarker then
        -- Beam is handled by UpdateWaypointVisual.
    end
end

local function DestroyMarkerVisual(marker)

    if marker.Attachment then
        marker.Attachment:Destroy()
    end

    marker.Attachment = nil
    marker.Billboard = nil
end

--==================================================
-- 9. MARKER CREATION
--==================================================

local function SaveMarkers()
    if not Settings.SaveEnabled then
        return
    end

    local data = {
        PlaceId = game.PlaceId,
        Markers = {},
        ActiveId = ActiveMarker and ActiveMarker.Id or nil,
        Visibility = Settings.Visibility,
    }

    for _, marker in ipairs(Markers) do

        if marker.Surface and marker.Surface.Parent then

            table.insert(data.Markers, {
                Id = marker.Id,
                Name = marker.Name,
                Position = {
                    marker.Position.X,
                    marker.Position.Y,
                    marker.Position.Z
                },
                Color = {
                    marker.Color.R,
                    marker.Color.G,
                    marker.Color.B
                },
                Icon = marker.Icon,
            })

        end
    end

    Storage.Save(data)
end

local function CreateMarker(hit, markerName, savedId)

    if #Markers >= CONFIG.MaxMarkers then
        return nil
    end

    if not hit or not IsValidMapPart(hit.Instance) then
        return nil
    end

    NextMarkerId += 1

    local surface = hit.Instance

    local marker = {
        Id = savedId or NextMarkerId,
        Name = markerName or ("Marker " .. tostring(NextMarkerId)),

        Surface = surface,
        Position = hit.Position,

        LocalPosition = surface.CFrame:PointToObjectSpace(
            hit.Position
        ),

        Color = Settings.MarkerColor,
        Icon = CONFIG.MarkerIcon,

        Visibility = Settings.Visibility,
        Attachment = nil,
        Billboard = nil,
    }

    table.insert(Markers, marker)

    CreateMarkerVisual(marker)

    SaveMarkers()

    return marker
end

--==================================================
-- 10. DELETE / CLEAR
--==================================================

local function DeleteMarker(marker)

    if not marker then
        return
    end

    if ActiveMarker == marker then
        ActiveMarker = nil
    end

    if SelectedMarker == marker then
        SelectedMarker = nil
    end

    DestroyMarkerVisual(marker)

    for i, item in ipairs(Markers) do
        if item == marker then
            table.remove(Markers, i)
            break
        end
    end

    SaveMarkers()
end

local function ClearAllMarkers()

    for _, marker in ipairs(Markers) do
        DestroyMarkerVisual(marker)
    end

    table.clear(Markers)

    ActiveMarker = nil
    SelectedMarker = nil

    SaveMarkers()
end

--==================================================
-- 11. WAYPOINT BEAM
--==================================================

local WaypointAttachment = Instance.new("Attachment")
WaypointAttachment.Name = "PlayerWaypointAttachment"

local WaypointBeam = Instance.new("Beam")
WaypointBeam.Name = "ActiveWaypointBeam"
WaypointBeam.Width0 = CONFIG.BeamWidth
WaypointBeam.Width1 = CONFIG.BeamWidth
WaypointBeam.FaceCamera = true
WaypointBeam.Color = ColorSequence.new(
    Settings.WaypointColor
)
WaypointBeam.LightEmission = 1
WaypointBeam.Enabled = false
WaypointBeam.Parent = WorldFolder

local function UpdateWaypointVisual()

    if not ActiveMarker
        or not ActiveMarker.Attachment
        or not ActiveMarker.Surface
        or not ActiveMarker.Surface.Parent then

        WaypointBeam.Enabled = false
        WaypointBeam.Attachment0 = nil
        WaypointBeam.Attachment1 = nil
        return
    end

    local root = GetRoot()

    if not root then
        WaypointBeam.Enabled = false
        return
    end

    if WaypointAttachment.Parent ~= root then
        WaypointAttachment.Parent = root
    end

    WaypointBeam.Attachment0 = WaypointAttachment
    WaypointBeam.Attachment1 = ActiveMarker.Attachment
    WaypointBeam.Enabled = true
end

local function SetWaypoint(marker)

    if not marker then
        return
    end

    ActiveMarker = marker

    UpdateWaypointVisual()
    SaveMarkers()
end

--==================================================
-- 12. GUI CREATION
--==================================================

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "WaypointSystem"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = false
ScreenGui.DisplayOrder = 20
ScreenGui.Parent = PlayerGui

local Main = Instance.new("Frame")
Main.Name = "MainPanel"
Main.Size = UDim2.fromOffset(
    CONFIG.UIWidth,
    CONFIG.UIHeight
)
Main.Position = UDim2.new(0, 20, 0.5, -220)
Main.BackgroundColor3 = CONFIG.BackgroundColor
Main.BorderSizePixel = 0
Main.Active = true
Main.ClipsDescendants = true
Main.Parent = ScreenGui

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 14)
MainCorner.Parent = Main

local MainStroke = Instance.new("UIStroke")
MainStroke.Color = CONFIG.AccentColor
MainStroke.Transparency = 0.35
MainStroke.Thickness = 1.5
MainStroke.Parent = Main

local Scale = Instance.new("UIScale")
Scale.Parent = Main

local function UpdateScale()

    local viewport = workspace.CurrentCamera.ViewportSize

    Scale.Scale = math.clamp(
        math.min(
            viewport.X / 400,
            viewport.Y / 500,
            1
        ),
        0.72,
        1
    )
end

UpdateScale()

Connect(
    workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"),
    UpdateScale
)

--==================================================
-- 13. UI HELPERS
--==================================================

local function CreateButton(parent, text, height)

    local button = Instance.new("TextButton")

    button.Size = UDim2.new(1, 0, 0, height or 48)
    button.BackgroundColor3 = Color3.fromRGB(45, 53, 68)
    button.BorderSizePixel = 0

    button.Text = text
    button.TextColor3 = Color3.new(1, 1, 1)
    button.TextScaled = true
    button.Font = Enum.Font.GothamSemibold

    button.AutoButtonColor = true
    button.Selectable = true

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 9)
    corner.Parent = button

    button.Parent = parent

    return button
end

local function CreateLabel(parent, text, height)

    local label = Instance.new("TextLabel")

    label.Size = UDim2.new(1, 0, 0, height or 30)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = Color3.new(1, 1, 1)
    label.TextScaled = true
    label.Font = Enum.Font.Gotham

    label.Parent = parent

    return label
end

local Content = Instance.new("ScrollingFrame")
Content.Name = "Content"
Content.Size = UDim2.new(1, -20, 1, -65)
Content.Position = UDim2.fromOffset(10, 58)
Content.BackgroundTransparency = 1
Content.BorderSizePixel = 0
Content.ScrollBarThickness = 5
Content.AutomaticCanvasSize = Enum.AutomaticSize.Y
Content.CanvasSize = UDim2.new()
Content.Parent = Main

local Layout = Instance.new("UIListLayout")
Layout.Padding = UDim.new(0, 7)
Layout.SortOrder = Enum.SortOrder.LayoutOrder
Layout.Parent = Content

--==================================================
-- 14. HEADER / DRAGGING
--==================================================

local Header = Instance.new("TextButton")
Header.Size = UDim2.new(1, 0, 0, 48)
Header.BackgroundColor3 = Color3.fromRGB(37, 44, 57)
Header.Text = "📍  WAYPOINT MANAGER"
Header.TextColor3 = Color3.new(1, 1, 1)
Header.TextScaled = true
Header.Font = Enum.Font.GothamBold
Header.Parent = Main

local Minimize = Instance.new("TextButton")
Minimize.Size = UDim2.fromOffset(44, 44)
Minimize.Position = UDim2.new(1, -46, 0, 2)
Minimize.BackgroundTransparency = 1
Minimize.Text = "−"
Minimize.TextColor3 = Color3.new(1, 1, 1)
Minimize.TextScaled = true
Minimize.Parent = Main

local minimized = false

Minimize.Activated:Connect(function()

    minimized = not minimized

    Content.Visible = not minimized

    Main.Size = minimized
        and UDim2.fromOffset(CONFIG.UIWidth, 50)
        or UDim2.fromOffset(CONFIG.UIWidth, CONFIG.UIHeight)

    Minimize.Text = minimized and "+" or "−"
end)

-- Drag only from the header.
local dragging = false
local dragInput
local dragStart
local startPosition

Header.InputBegan:Connect(function(input)

    if input.UserInputType ~= Enum.UserInputType.MouseButton1
        and input.UserInputType ~= Enum.UserInputType.Touch then
        return
    end

    dragging = true
    dragStart = input.Position
    startPosition = Main.Position

    dragInput = input
end)

Connect(UserInputService.InputChanged, function(input)

    if not dragging then
        return
    end

    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then

        local delta = input.Position - dragStart

        Main.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + delta.X,
            startPosition.Y.Scale,
            startPosition.Y.Offset + delta.Y
        )
    end
end)

Connect(UserInputService.InputEnded, function(input)

    if input == dragInput
        or input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then

        dragging = false
    end
end)

--==================================================
-- 15. STATUS AND CONTROLS
--==================================================

local Status = CreateLabel(
    Content,
    "Ready | Markers: 0",
    32
)

local StorageNotice = CreateLabel(
    Content,
    FileAPIAvailable()
        and "File storage detected"
        or "Session storage only - normal Roblox client",
    32
)

StorageNotice.TextColor3 = Color3.fromRGB(255, 205, 100)

local PlaceButton = CreateButton(Content, "📍 PLACE MARKER", 52)
local WaypointButton = CreateButton(Content, "⭐ SET WAYPOINT", 52)
local DeleteButton = CreateButton(Content, "🗑 DELETE SELECTED", 52)
local ClearButton = CreateButton(Content, "CLEAR ALL MARKERS", 52)
local SettingsButton = CreateButton(Content, "⚙ SETTINGS", 48)

local DistanceLabel = CreateLabel(
    Content,
    "Distance: --",
    36
)

local MarkerHeader = CreateLabel(
    Content,
    "YOUR MARKERS",
    36
)

MarkerHeader.Font = Enum.Font.GothamBold

--==================================================
-- 16. MARKER LIST
--==================================================

local MarkerList = Instance.new("Frame")
MarkerList.Size = UDim2.new(1, 0, 0, 0)
MarkerList.AutomaticSize = Enum.AutomaticSize.Y
MarkerList.BackgroundTransparency = 1
MarkerList.Parent = Content

local MarkerLayout = Instance.new("UIListLayout")
MarkerLayout.Padding = UDim.new(0, 5)
MarkerLayout.Parent = MarkerList

local function RefreshMarkerList()

    for _, child in ipairs(MarkerList:GetChildren()) do
        if child:IsA("GuiObject") and child ~= MarkerLayout then
            child:Destroy()
        end
    end

    for _, marker in ipairs(Markers) do

        local button = CreateButton(
            MarkerList,
            (marker == ActiveMarker and "⭐ " or "")
                .. marker.Name,
            48
        )

        button.BackgroundColor3 =
            marker == SelectedMarker
            and CONFIG.AccentColor
            or Color3.fromRGB(45, 53, 68)

        button.Activated:Connect(function()
            SelectedMarker = marker
            RefreshMarkerList()
        end)

        -- Long press to reposition a selected marker.
        local holdStart = nil
        local holdInput = nil

        button.InputBegan:Connect(function(input)

            if input.UserInputType ~= Enum.UserInputType.Touch
                and input.UserInputType ~= Enum.UserInputType.MouseButton1 then
                return
            end

            holdStart = os.clock()
            holdInput = input
        end)

        button.InputEnded:Connect(function(input)

            if input == holdInput and holdStart then

                local elapsed = os.clock() - holdStart

                if elapsed >= CONFIG.LongPressDuration then
                    SelectedMarker = marker
                    PlaceButton.Text = "MOVE MARKER: " .. marker.Name
                end

                holdStart = nil
                holdInput = nil
            end
        end)
    end

    Status.Text = string.format(
        "Ready | Markers: %d/%d",
        #Markers,
        CONFIG.MaxMarkers
    )
end

--==================================================
-- 17. RENAME / RECOLOR
--==================================================

local function EditSelectedMarker()

    local marker = SelectedMarker

    if not marker then
        return
    end

    local editFrame = Instance.new("Frame")
    editFrame.Size = UDim2.fromOffset(280, 180)
    editFrame.Position = UDim2.fromScale(0.5, 0.5)
    editFrame.AnchorPoint = Vector2.new(0.5, 0.5)
    editFrame.BackgroundColor3 = CONFIG.BackgroundColor
    editFrame.ZIndex = 10
    editFrame.Parent = ScreenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = editFrame

    local nameBox = Instance.new("TextBox")
    nameBox.Size = UDim2.new(1, -20, 0, 42)
    nameBox.Position = UDim2.fromOffset(10, 10)
    nameBox.Text = marker.Name
    nameBox.PlaceholderText = "Marker name"
    nameBox.TextScaled = true
    nameBox.ClearTextOnFocus = false
    nameBox.Parent = editFrame

    local rename = CreateButton(editFrame, "SAVE NAME", 44)
    rename.Position = UDim2.fromOffset(10, 60)
    rename.Size = UDim2.new(1, -20, 0, 44)
    rename.ZIndex = 11

    local recolor = CreateButton(editFrame, "CHANGE COLOR", 44)
    recolor.Position = UDim2.fromOffset(10, 108)
    recolor.Size = UDim2.new(1, -20, 0, 44)
    recolor.ZIndex = 11

    rename.Activated:Connect(function()

        local newName = nameBox.Text:sub(1, 32)

        if newName ~= "" then
            marker.Name = newName
        end

        editFrame:Destroy()
        RefreshMarkerList()
        SaveMarkers()
    end)

    recolor.Activated:Connect(function()

        local colors = {
            Color3.fromRGB(255, 80, 80),
            Color3.fromRGB(80, 180, 255),
            Color3.fromRGB(100, 255, 130),
            Color3.fromRGB(255, 210, 70),
            Color3.fromRGB(200, 120, 255),
        }

        local current = 1

        for i, color in ipairs(colors) do
            if color == marker.Color then
                current = i
            end
        end

        current = current % #colors + 1
        marker.Color = colors[current]

        if marker.Attachment then
            local label = marker.Attachment:FindFirstChild(
                "MarkerBillboard"
            )

            if label then
                local icon = label:FindFirstChildOfClass("TextLabel")

                if icon then
                    icon.TextColor3 = marker.Color
                end
            end
        end

        SaveMarkers()
        editFrame:Destroy()
    end)
end

--==================================================
-- 18. PLACING MARKERS
--==================================================

local placing = false
local movingMarker = nil

PlaceButton.Activated:Connect(function()

    placing = not placing

    PlaceButton.Text = placing
        and "TAP MAP TO PLACE..."
        or "📍 PLACE MARKER"

    movingMarker = nil
end)

local function PlaceOrMoveAt(screenPosition)

    local hit = ScreenRaycast(screenPosition)

    if not hit then
        return
    end

    if movingMarker then

        DestroyMarkerVisual(movingMarker)

        movingMarker.Surface = hit.Instance
        movingMarker.Position = hit.Position

        movingMarker.LocalPosition =
            hit.Instance.CFrame:PointToObjectSpace(
                hit.Position
            )

        CreateMarkerVisual(movingMarker)

        movingMarker = nil
        PlaceButton.Text = "📍 PLACE MARKER"

        SaveMarkers()
        return
    end

    if placing then

        local marker = CreateMarker(hit)

        if marker then
            SelectedMarker = marker
            RefreshMarkerList()
        end

        placing = false
        PlaceButton.Text = "📍 PLACE MARKER"
    end
end

-- Clean-tap detection: movement beyond the threshold cancels placement.
local InputStart = {}

Connect(UserInputService.InputBegan, function(input, processed)

    if processed then
        return
    end

    if input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseButton1 then

        InputStart[input] = {
            Position = input.Position,
            Time = os.clock(),
        }
    end
end)

Connect(UserInputService.InputEnded, function(input)

    local start = InputStart[input]

    if not start then
        return
    end

    InputStart[input] = nil

    if os.clock() - start.Time > 0.8 then
        return
    end

    local delta = input.Position - start.Position

    if delta.Magnitude > CONFIG.TouchTapThreshold then
        return
    end

    if not placing and not movingMarker then
        return
    end

    -- Avoid placing while interacting with the panel.
    local objects = PlayerGui:GetGuiObjectsAtPosition(
        input.Position.X,
        input.Position.Y
    )

    for _, object in ipairs(objects) do
        if object:IsDescendantOf(Main) then
            return
        end
    end

    PlaceOrMoveAt(input.Position)
end)

--==================================================
-- 19. BUTTON ACTIONS
--==================================================

WaypointButton.Activated:Connect(function()

    if not SelectedMarker then
        return
    end

    SetWaypoint(SelectedMarker)
    RefreshMarkerList()
end)

DeleteButton.Activated:Connect(function()

    if SelectedMarker then
        DeleteMarker(SelectedMarker)
        RefreshMarkerList()
    end
end)

ClearButton.Activated:Connect(function()

    ClearAllMarkers()
    RefreshMarkerList()
end)

--==================================================
-- 20. SETTINGS WINDOW
--==================================================

local SettingsFrame = Instance.new("Frame")
SettingsFrame.Size = UDim2.fromOffset(280, 240)
SettingsFrame.Position = UDim2.fromScale(0.5, 0.5)
SettingsFrame.AnchorPoint = Vector2.new(0.5, 0.5)
SettingsFrame.BackgroundColor3 = CONFIG.BackgroundColor
SettingsFrame.Visible = false
SettingsFrame.ZIndex = 5
SettingsFrame.Parent = ScreenGui

local SettingsCorner = Instance.new("UICorner")
SettingsCorner.CornerRadius = UDim.new(0, 12)
SettingsCorner.Parent = SettingsFrame

local SettingsTitle = CreateLabel(
    SettingsFrame,
    "SETTINGS",
    40
)
SettingsTitle.ZIndex = 6

local VisibilityButton = CreateButton(
    SettingsFrame,
    "Visibility: A",
    46
)
VisibilityButton.Position = UDim2.fromOffset(10, 48)
VisibilityButton.Size = UDim2.new(1, -20, 0, 46)
VisibilityButton.ZIndex = 6

local SaveButton = CreateButton(
    SettingsFrame,
    "Saving: ON",
    46
)
SaveButton.Position = UDim2.fromOffset(10, 100)
SaveButton.Size = UDim2.new(1, -20, 0, 46)
SaveButton.ZIndex = 6

local CloseSettings = CreateButton(
    SettingsFrame,
    "CLOSE",
    46
)
CloseSettings.Position = UDim2.fromOffset(10, 152)
CloseSettings.Size = UDim2.new(1, -20, 0, 46)
CloseSettings.ZIndex = 6

SettingsButton.Activated:Connect(function()

    SettingsFrame.Visible = not SettingsFrame.Visible
end)

VisibilityButton.Activated:Connect(function()

    Settings.Visibility =
        Settings.Visibility == "A" and "B" or "A"

    VisibilityButton.Text =
        "Visibility: " .. Settings.Visibility

    for _, marker in ipairs(Markers) do

        if marker.Billboard then

            marker.Billboard.MaxDistance =
                Settings.Visibility == "B"
                and CONFIG.NearDistance
                or 0
        end
    end

    SaveMarkers()
end)

SaveButton.Activated:Connect(function()

    Settings.SaveEnabled = not Settings.SaveEnabled

    SaveButton.Text =
        "Saving: " .. (Settings.SaveEnabled and "ON" or "OFF")
end)

CloseSettings.Activated:Connect(function()
    SettingsFrame.Visible = false
end)

--==================================================
-- 21. OFF-SCREEN INDICATOR
--==================================================

local Indicator = Instance.new("TextLabel")
Indicator.Size = UDim2.fromOffset(65, 65)
Indicator.AnchorPoint = Vector2.new(0.5, 0.5)
Indicator.Position = UDim2.fromScale(0.5, 0.5)
Indicator.BackgroundColor3 = Settings.WaypointColor
Indicator.BackgroundTransparency = 0.15
Indicator.Text = "▲"
Indicator.TextScaled = true
Indicator.TextColor3 = Color3.new(1, 1, 1)
Indicator.Font = Enum.Font.GothamBold
Indicator.Visible = false
Indicator.Parent = ScreenGui

local IndicatorCorner = Instance.new("UICorner")
IndicatorCorner.CornerRadius = UDim.new(1, 0)
IndicatorCorner.Parent = Indicator

--==================================================
-- 22. DISTANCE AND WAYPOINT UPDATE
--==================================================

local function UpdateWaypoint()

    local root = GetRoot()

    if not root or not ActiveMarker then
        DistanceLabel.Text = "Distance: --"
        Indicator.Visible = false
        return
    end

    local marker = ActiveMarker

    if not marker.Surface
        or not marker.Surface.Parent
        or not marker.Attachment
        or not marker.Attachment.Parent then

        DeleteMarker(marker)
        RefreshMarkerList()

        return
    end

    local position = marker.Attachment.WorldPosition

    local distance = (root.Position - position).Magnitude

    DistanceLabel.Text = string.format(
        "Distance: %d studs",
        math.floor(distance + 0.5)
    )

    local screenPoint, onScreen =
        Camera:WorldToViewportPoint(position)

    if onScreen and screenPoint.Z > 0 then

        Indicator.Visible = false

    else

        Indicator.Visible = true

        local viewport = Camera.ViewportSize

        local center = Vector2.new(
            viewport.X / 2,
            viewport.Y / 2
        )

        local target = Vector2.new(
            screenPoint.X,
            screenPoint.Y
        )

        if screenPoint.Z < 0 then
            target = center * 2 - target
        end

        local direction = target - center

        if direction.Magnitude > 0 then

            direction = direction.Unit

            local edge = Vector2.new(
                viewport.X / 2 - 55,
                viewport.Y / 2 - 85
            )

            local xScale = edge.X / math.max(
                math.abs(direction.X),
                0.001
            )

            local yScale = edge.Y / math.max(
                math.abs(direction.Y),
                0.001
            )

            local position2D =
                center + direction * math.min(xScale, yScale)

            Indicator.Position = UDim2.fromOffset(
                position2D.X,
                position2D.Y
            )

            local angle = math.deg(
                math.atan2(direction.Y, direction.X)
            )

            Indicator.Rotation = angle + 90
        end
    end
end

--==================================================
-- 23. MARKER VALIDATION
--==================================================

local function ValidateMarkers()

    for i = #Markers, 1, -1 do

        local marker = Markers[i]

        if not IsValidMapPart(marker.Surface)
            or not marker.Attachment
            or not marker.Attachment.Parent then

            DeleteMarker(marker)
        end
    end
end

--==================================================
-- 24. LOADING SAVED DATA
--==================================================

local function LoadMarkers()

    local data = Storage.Load()

    if not data then
        return
    end

    if data.PlaceId ~= game.PlaceId then
        return
    end

    if type(data.Markers) ~= "table" then
        return
    end

    if data.Visibility == "A" or data.Visibility == "B" then
        Settings.Visibility = data.Visibility
        VisibilityButton.Text =
            "Visibility: " .. Settings.Visibility
    end

    -- Saved positions are only coordinates, not Instance references.
    -- Reconstruct only when a valid surface can be found at the location.

    for _, saved in ipairs(data.Markers) do

        if #Markers >= CONFIG.MaxMarkers then
            break
        end

        if type(saved.Position) == "table"
            and #saved.Position == 3 then

            local position = Vector3.new(
                saved.Position[1],
                saved.Position[2],
                saved.Position[3]
            )

            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = {
                WorldFolder,
                GetCharacter()
            }

            local result = workspace:Raycast(
                position + Vector3.new(0, 3, 0),
                Vector3.new(0, -6, 0),
                params
            )

            if result and IsValidMapPart(result.Instance) then

                local marker = CreateMarker(
                    result,
                    saved.Name,
                    saved.Id
                )

                if marker then

                    if type(saved.Color) == "table"
                        and #saved.Color == 3 then

                        marker.Color = Color3.new(
                            saved.Color[1],
                            saved.Color[2],
                            saved.Color[3]
                        )
                    end

                    marker.Icon = saved.Icon or CONFIG.MarkerIcon

                    DestroyMarkerVisual(marker)
                    CreateMarkerVisual(marker)
                end
            end
        end
    end

    if data.ActiveId then

        for _, marker in ipairs(Markers) do

            if marker.Id == data.ActiveId then
                SetWaypoint(marker)
                SelectedMarker = marker
                break
            end
        end
    end

    RefreshMarkerList()
end

--==================================================
-- 25. GAMEPAD SUPPORT
--==================================================

local function SetupGamepad()

    GuiService.AutoSelectGuiEnabled = true

    PlaceButton.Selectable = true
    WaypointButton.Selectable = true
    DeleteButton.Selectable = true
    ClearButton.Selectable = true
    SettingsButton.Selectable = true

    GuiService.SelectedObject = PlaceButton
end

SetupGamepad()

--==================================================
-- 26. RESPAWN HANDLING
--==================================================

Connect(Player.CharacterAdded, function(character)

    task.wait(0.5)

    if Unloaded then
        return
    end

    local root = character:WaitForChild(
        "HumanoidRootPart",
        10
    )

    if root then
        WaypointAttachment.Parent = root
        UpdateWaypointVisual()
    end
end)

--==================================================
-- 27. MAIN UPDATE LOOP
--==================================================

local validationTimer = 0

Connect(RunService.RenderStepped, function(dt)

    if Unloaded then
        return
    end

    UpdateWaypoint()

    validationTimer += dt

    if validationTimer >= 0.5 then

        validationTimer = 0

        ValidateMarkers()
        RefreshMarkerList()
    end
end)

--==================================================
-- 28. INITIALIZATION
--==================================================

LoadMarkers()
RefreshMarkerList()
UpdateWaypointVisual()

--==================================================
-- 29. UNLOAD BUTTON
--==================================================

local UnloadButton = CreateButton(
    Content,
    "✖ UNLOAD WAYPOINT SYSTEM",
    52
)

UnloadButton.BackgroundColor3 = Color3.fromRGB(180, 55, 55)

local function Unload()

    if Unloaded then
        return
    end

    Unloaded = true

    pcall(SaveMarkers)

    DisconnectAll()

    for _, marker in ipairs(Markers) do
        DestroyMarkerVisual(marker)
    end

    WaypointBeam:Destroy()
    WaypointAttachment:Destroy()

    WorldFolder:Destroy()
    ScreenGui:Destroy()

    table.clear(Markers)
end

UnloadButton.Activated:Connect(Unload)

print("[WaypointSystem] Successfully initialized.")