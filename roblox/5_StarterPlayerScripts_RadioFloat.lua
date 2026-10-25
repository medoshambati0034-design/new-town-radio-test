--[[
    اسم السكربت: RadioFloat
    مكانه: StarterPlayer > StarterPlayerScripts  (LocalScript)

    وظيفته:
    1) زر راديو عائم دائم على الشاشة (يفتح/يقفل اللوحة).
    2) اللوحة تعرض القناة الحالية وحالة الراديو، وزر PTT للتحدث.
    3) الدخول للقنوات يتم من الموقع فقط. هذا السكربت يعرض الحالة ويرسل التحدث.
    4) يوقف التحدث تلقائياً عند إغلاق اللوحة، أو فقدان تركيز النافذة، أو الموت.

    لا يحتاج أداة (Tool). السكربت واحد لكل لاعب ولا يتكرر مع إعادة الظهور.
    الأداة NewTownRadio القديمة يُفضّل حذفها من StarterPack لتجنب واجهتين.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local RadioConfig = require(ReplicatedStorage:WaitForChild("RadioConfig"))

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild(RadioConfig.REMOTES_FOLDER)
local SetTalkingEvent = remotes:WaitForChild("SetTalking")
local RadioStateEvent = remotes:WaitForChild("RadioState")
local RequestStateEvent = remotes:WaitForChild("RequestState")

-- ============ الألوان ============
local BODY = Color3.fromRGB(24, 24, 27)
local EDGE = Color3.fromRGB(62, 62, 68)
local ORANGE = Color3.fromRGB(255, 120, 17)
local GREEN = Color3.fromRGB(60, 190, 100)
local RED = Color3.fromRGB(200, 60, 60)
local GREY = Color3.fromRGB(70, 66, 62)
local TEXT = Color3.fromRGB(235, 235, 240)
local SOFT = Color3.fromRGB(180, 170, 160)

-- ============ الحالة (السيرفر هو المرجع) ============
local currentChannel = nil
local serverTalking = false
local buttonTalking = false
local keyTalking = false
local lastSentTalk = false

-- ============ الواجهة ============
local gui = Instance.new("ScreenGui")
gui.Name = "RadioFloatGui"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

-- الزر العائم (فوق زر المايك)
local floatButton = Instance.new("TextButton")
floatButton.Name = "RadioFloatButton"
floatButton.Size = UDim2.new(0, 60, 0, 60)
floatButton.Position = UDim2.new(1, -80, 1, -150)
floatButton.BackgroundColor3 = BODY
floatButton.Font = Enum.Font.GothamBold
floatButton.TextSize = 26
floatButton.TextColor3 = TEXT
floatButton.Text = "📻"
floatButton.AutoButtonColor = true
floatButton.Parent = gui
do
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = floatButton
    local s = Instance.new("UIStroke"); s.Color = ORANGE; s.Thickness = 2; s.Parent = floatButton
end

-- علامة صغيرة على الزر: أخضر إذا القناة نشطة
local floatLed = Instance.new("Frame")
floatLed.Name = "Led"
floatLed.Size = UDim2.new(0, 12, 0, 12)
floatLed.Position = UDim2.new(1, -14, 0, -2)
floatLed.BackgroundColor3 = GREY
floatLed.Parent = floatButton
do
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = floatLed
end

-- اللوحة
local panel = Instance.new("Frame")
panel.Name = "RadioPanel"
panel.Size = UDim2.new(0, 300, 0, 230)
panel.Position = UDim2.new(1, -330, 1, -390)
panel.BackgroundColor3 = BODY
panel.Visible = false
panel.Parent = gui
do
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 14); c.Parent = panel
    local s = Instance.new("UIStroke"); s.Color = EDGE; s.Thickness = 2; s.Parent = panel
end

local titleLabel = Instance.new("TextLabel")
titleLabel.BackgroundTransparency = 1
titleLabel.Size = UDim2.new(1, -60, 0, 26)
titleLabel.Position = UDim2.new(0, 14, 0, 10)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 16
titleLabel.TextColor3 = TEXT
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Text = "NEW TOWN RADIO"
titleLabel.Parent = panel

local closeButton = Instance.new("TextButton")
closeButton.Name = "Close"
closeButton.Size = UDim2.new(0, 30, 0, 30)
closeButton.Position = UDim2.new(1, -40, 0, 8)
closeButton.BackgroundColor3 = GREY
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 14
closeButton.TextColor3 = TEXT
closeButton.Text = "X"
closeButton.Parent = panel
do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = closeButton end

local channelLabel = Instance.new("TextLabel")
channelLabel.Name = "Channel"
channelLabel.BackgroundTransparency = 1
channelLabel.Size = UDim2.new(1, -28, 0, 36)
channelLabel.Position = UDim2.new(0, 14, 0, 44)
channelLabel.Font = Enum.Font.Code
channelLabel.TextSize = 26
channelLabel.TextColor3 = ORANGE
channelLabel.TextXAlignment = Enum.TextXAlignment.Left
channelLabel.Text = "Channel --"
channelLabel.Parent = panel

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.BackgroundTransparency = 1
statusLabel.Size = UDim2.new(1, -28, 0, 36)
statusLabel.Position = UDim2.new(0, 14, 0, 82)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 13
statusLabel.TextColor3 = SOFT
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextWrapped = true
statusLabel.Text = "ادخل القناة من الموقع ثم تحدث من هنا"
statusLabel.Parent = panel

local talkButton = Instance.new("TextButton")
talkButton.Name = "TalkButton"
talkButton.Size = UDim2.new(1, -28, 0, 70)
talkButton.Position = UDim2.new(0, 14, 1, -84)
talkButton.BackgroundColor3 = GREY
talkButton.Font = Enum.Font.GothamBold
talkButton.TextSize = 18
talkButton.TextColor3 = Color3.fromRGB(255, 255, 255)
talkButton.Text = "PTT"
talkButton.AutoButtonColor = false
talkButton.Parent = panel
do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 12); c.Parent = talkButton end

-- ============ التحدث (نفس قواعد الأمان: لا يبقى المايك مفتوحاً) ============
local function wantsToTalk()
    return (buttonTalking or keyTalking) and currentChannel ~= nil
end

local function syncTalk()
    local want = wantsToTalk()
    if want == lastSentTalk then return end
    lastSentTalk = want
    SetTalkingEvent:FireServer(want)
end

local function forceStopTalk()
    buttonTalking = false
    keyTalking = false
    syncTalk()
end

local function updateVisuals()
    floatLed.BackgroundColor3 = currentChannel and GREEN or GREY
    channelLabel.Text = currentChannel and ("Channel " .. tostring(currentChannel)) or "Channel --"

    if serverTalking then
        talkButton.BackgroundColor3 = RED
        talkButton.Text = "تتحدث الآن"
    elseif currentChannel then
        talkButton.BackgroundColor3 = GREEN
        talkButton.Text = "PTT  -  اضغط للتحدث"
    else
        talkButton.BackgroundColor3 = GREY
        talkButton.Text = "ادخل قناة من الموقع أولاً"
    end
end

-- ============ الزر العائم واللوحة ============
local function setPanelOpen(open)
    panel.Visible = open
    if not open then
        -- إغلاق اللوحة يوقف التحدث حتى لا يبقى المايك مفتوحاً
        forceStopTalk()
    end
end

floatButton.Activated:Connect(function()
    setPanelOpen(not panel.Visible)
end)

closeButton.Activated:Connect(function()
    setPanelOpen(false)
end)

-- ============ أزرار التحدث ============
talkButton.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        buttonTalking = true
        syncTalk()
    end
end)

-- الرفع في أي مكان يوقف التحدث (مهم إذا ترك الإصبع الزر)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        if buttonTalking then
            buttonTalking = false
            syncTalk()
        end
    end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == RadioConfig.PTT_KEY then
        keyTalking = true
        syncTalk()
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode == RadioConfig.PTT_KEY and keyTalking then
        keyTalking = false
        syncTalk()
    end
end)

-- خروج التركيز من النافذة يوقف التحدث
UserInputService.WindowFocusReleased:Connect(forceStopTalk)

-- ============ ردود السيرفر ============
RadioStateEvent.OnClientEvent:Connect(function(channel, talking, message)
    currentChannel = channel
    serverTalking = (channel ~= nil) and talking or false

    if channel == nil then
        buttonTalking = false
        keyTalking = false
        syncTalk()
    end

    if message and message ~= "" then
        statusLabel.Text = message
    elseif channel then
        statusLabel.Text = "متصل بالقناة " .. tostring(channel)
    else
        statusLabel.Text = "غير متصل"
    end

    updateVisuals()
end)

-- ============ الحالة من Attributes (تُنشر من السيرفر) ============
local function applyAttributes()
    currentChannel = player:GetAttribute("RadioChannel")
    serverTalking = (currentChannel ~= nil) and (player:GetAttribute("RadioTalking") == true) or false
    if currentChannel == nil then
        buttonTalking = false
        keyTalking = false
        syncTalk()
    end
    updateVisuals()
end

player:GetAttributeChangedSignal("RadioChannel"):Connect(applyAttributes)
player:GetAttributeChangedSignal("RadioTalking"):Connect(applyAttributes)
applyAttributes()

-- ============ الموت وإعادة الظهور ============
local function onCharacter(character)
    local humanoid = character:WaitForChild("Humanoid", 10)
    if humanoid then
        humanoid.Died:Connect(function()
            forceStopTalk()
            setPanelOpen(false)
        end)
    end
    -- بعد إعادة الظهور نسأل السيرفر عن حالتنا، لأنه حافظ القناة
    RequestStateEvent:FireServer()
end

if player.Character then onCharacter(player.Character) end
player.CharacterAdded:Connect(onCharacter)

updateVisuals()
RequestStateEvent:FireServer()
