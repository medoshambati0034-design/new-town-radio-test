--[[
    اسم السكربت: VoiceLinkUI
    مكانه: StarterPlayer > StarterPlayerScripts  (لازم LocalScript)

    وظيفته:
    1) يعرض رابط التفعيل في مربع نص، واللاعب يحدده وينسخه (Roblox ما تقدر تنسخ للحافظة بنفسها).
    2) يعرض حالة الربط بألوان New Town.
    3) زر مايك عائم يتغير لونه حسب الحالة، ويرسل الضغطة للسيرفر فقط.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

local remotesFolder = ReplicatedStorage:WaitForChild("VoiceLinkRemotes")
local LinkReadyEvent = remotesFolder:WaitForChild("LinkReady")
local LinkStatusEvent = remotesFolder:WaitForChild("LinkStatus")
local ToggleMicEvent = remotesFolder:WaitForChild("ToggleMic")
local MicStateEvent = remotesFolder:WaitForChild("MicState")

local ORANGE = Color3.fromRGB(255, 120, 17)
local GREEN = Color3.fromRGB(60, 190, 100)
local RED = Color3.fromRGB(200, 60, 60)
local ERROR_TEXT = Color3.fromRGB(220, 80, 75)
local WAIT_TEXT = Color3.fromRGB(255, 160, 70)

-- ============ الواجهة ============
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "VoiceLinkUI"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Name = "LinkFrame"
frame.Size = UDim2.new(0, 340, 0, 128)
frame.Position = UDim2.new(0, 20, 0, 20)
frame.BackgroundColor3 = Color3.fromRGB(22, 18, 15)
frame.BackgroundTransparency = 0.1
frame.Parent = screenGui

local frameCorner = Instance.new("UICorner")
frameCorner.CornerRadius = UDim.new(0, 12)
frameCorner.Parent = frame

local frameStroke = Instance.new("UIStroke")
frameStroke.Color = ORANGE
frameStroke.Transparency = 0.6
frameStroke.Thickness = 1
frameStroke.Parent = frame

local titleLabel = Instance.new("TextLabel")
titleLabel.BackgroundTransparency = 1
titleLabel.Size = UDim2.new(1, -20, 0, 20)
titleLabel.Position = UDim2.new(0, 10, 0, 5)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 13
titleLabel.TextColor3 = Color3.fromRGB(170, 160, 150)
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Text = "رابط تفعيل المايك:"
titleLabel.Parent = frame

local linkBox = Instance.new("TextBox")
linkBox.Name = "LinkBox"
linkBox.Size = UDim2.new(1, -20, 0, 34)
linkBox.Position = UDim2.new(0, 10, 0, 28)
linkBox.BackgroundColor3 = Color3.fromRGB(12, 10, 8)
linkBox.TextColor3 = ORANGE
linkBox.Font = Enum.Font.Code
linkBox.TextSize = 12
linkBox.TextXAlignment = Enum.TextXAlignment.Left
linkBox.ClearTextOnFocus = false
linkBox.Text = "جارٍ تجهيز الرابط..."
linkBox.Parent = frame

local linkBoxCorner = Instance.new("UICorner")
linkBoxCorner.CornerRadius = UDim.new(0, 8)
linkBoxCorner.Parent = linkBox

-- نخلّي الرابط للقراءة والتحديد فقط (إذا المنصة تدعم الخاصية)
pcall(function()
    linkBox.TextEditable = false
end)

local hintLabel = Instance.new("TextLabel")
hintLabel.BackgroundTransparency = 1
hintLabel.Size = UDim2.new(1, -20, 0, 18)
hintLabel.Position = UDim2.new(0, 10, 0, 66)
hintLabel.Font = Enum.Font.Gotham
hintLabel.TextSize = 11
hintLabel.TextColor3 = Color3.fromRGB(170, 160, 150)
hintLabel.TextXAlignment = Enum.TextXAlignment.Left
hintLabel.TextWrapped = true
hintLabel.Text = "اضغط على الرابط وانسخه، وافتحه في Chrome أو Safari"
hintLabel.Parent = frame

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "ConnectionStatus"
statusLabel.BackgroundTransparency = 1
statusLabel.Size = UDim2.new(1, -20, 0, 24)
statusLabel.Position = UDim2.new(0, 10, 0, 92)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 11
statusLabel.TextColor3 = Color3.fromRGB(180, 170, 160)
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextWrapped = true
statusLabel.Text = "جارٍ تجهيز رابط التفعيل..."
statusLabel.Parent = frame

local micButton = Instance.new("TextButton")
micButton.Name = "MicButton"
micButton.Size = UDim2.new(0, 60, 0, 60)
micButton.Position = UDim2.new(1, -80, 1, -80)
micButton.BackgroundColor3 = GREEN
micButton.Text = "🎙"
micButton.TextSize = 26
micButton.Font = Enum.Font.GothamBold
micButton.TextColor3 = Color3.fromRGB(255, 255, 255)
micButton.Parent = screenGui

local micCorner = Instance.new("UICorner")
micCorner.CornerRadius = UDim.new(1, 0)
micCorner.Parent = micButton

-- ============ الرابط ============
local currentUrl = nil

-- إذا حاول اللاعب يكتب في المربع نرجّع الرابط كما هو
linkBox:GetPropertyChangedSignal("Text"):Connect(function()
    if currentUrl and linkBox.Text ~= currentUrl then
        linkBox.Text = currentUrl
    end
end)

-- عند التركيز نحدد الرابط كامل عشان ينسخه بسهولة
linkBox.Focused:Connect(function()
    linkBox.CursorPosition = -1
    linkBox.SelectionStart = 1
end)

local function setLink(url)
    if type(url) == "string" and #url > 0 then
        currentUrl = url
        linkBox.Text = url
    else
        currentUrl = nil
        linkBox.Text = "جارٍ تجهيز الرابط..."
    end
end

-- ============ الحالة ============
local function updateStatus(state, message)
    if state == "error" then
        statusLabel.TextColor3 = ERROR_TEXT
    elseif state == "linked" or state == "ready" then
        statusLabel.TextColor3 = GREEN
    else
        statusLabel.TextColor3 = WAIT_TEXT
    end
    statusLabel.Text = message or ""
end

-- ============ المايك ============
local isMuted = false

local function updateMicVisual()
    local targetColor = isMuted and RED or GREEN
    TweenService:Create(micButton, TweenInfo.new(0.2), { BackgroundColor3 = targetColor }):Play()
    micButton.Text = isMuted and "🔇" or "🎙"
end

micButton.MouseButton1Click:Connect(function()
    ToggleMicEvent:FireServer()
end)

MicStateEvent.OnClientEvent:Connect(function(muted)
    isMuted = muted
    updateMicVisual()
end)

-- ============ الأحداث ============
LinkReadyEvent.OnClientEvent:Connect(setLink)
LinkStatusEvent.OnClientEvent:Connect(updateStatus)

-- قراءة الـ Attributes بعد ربط الأحداث تمنع ضياع البيانات إذا وصلت قبل تحميل الواجهة.
player:GetAttributeChangedSignal("VoiceLinkUrl"):Connect(function()
    setLink(player:GetAttribute("VoiceLinkUrl"))
end)

player:GetAttributeChangedSignal("VoiceLinkStatus"):Connect(function()
    updateStatus(
        player:GetAttribute("VoiceLinkStatusState"),
        player:GetAttribute("VoiceLinkStatus")
    )
end)

setLink(player:GetAttribute("VoiceLinkUrl"))
updateStatus(
    player:GetAttribute("VoiceLinkStatusState"),
    player:GetAttribute("VoiceLinkStatus") or "جارٍ تجهيز رابط التفعيل..."
)
updateMicVisual()
