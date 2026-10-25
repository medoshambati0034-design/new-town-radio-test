--[[
    اسم السكربت: RadioUI
    مكانه: داخل الأداة NewTownRadio (Tool) داخل StarterPack  (LocalScript)

    الواجهة تشبه جهاز اللاسلكي:
    - شاشة LCD تعرض اسم الشبكة والقناة والحالة.
    - لوحة أرقام: اكتب رقم القناة ثم اضغط OK للدخول.
    - السهمين < > تنقل بين القنوات، والزر C يمسح الرقم المكتوب.
    - P1 و P2 تدخل قنوات محددة مسبقاً (تُضبط من RadioConfig.PRESETS).
    - زر EXIT يخرجك من القناة.
    - زر PTT الكبير للتحدث (وCapsLock على الكمبيوتر).

    الصلاحيات تتحقق منها السيرفر دائماً، والواجهة تعرض الرسائل فقط.
    يوقف التحدث تلقائياً عند رفع الأداة، أو الموت، أو فقدان تركيز النافذة.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local RadioConfig = require(ReplicatedStorage:WaitForChild("RadioConfig"))

local tool = script.Parent
local player = Players.LocalPlayer

local remotes = ReplicatedStorage:WaitForChild(RadioConfig.REMOTES_FOLDER)
local JoinChannelEvent = remotes:WaitForChild("JoinChannel")
local LeaveChannelEvent = remotes:WaitForChild("LeaveChannel")
local SetTalkingEvent = remotes:WaitForChild("SetTalking")
local RadioStateEvent = remotes:WaitForChild("RadioState")

-- ============ الألوان ============
local BODY = Color3.fromRGB(24, 24, 27)
local BODY_EDGE = Color3.fromRGB(62, 62, 68)
local GRILLE = Color3.fromRGB(44, 44, 49)
local KEY = Color3.fromRGB(36, 36, 41)
local KEY_TEXT = Color3.fromRGB(235, 235, 240)
local KEY_ACCENT = Color3.fromRGB(255, 120, 17)
local LCD_BG = Color3.fromRGB(176, 206, 230)
local LCD_INK = Color3.fromRGB(28, 38, 72)
local LCD_TX = Color3.fromRGB(150, 45, 40)
local GREEN = Color3.fromRGB(60, 190, 100)
local RED = Color3.fromRGB(200, 60, 60)
local GREY = Color3.fromRGB(70, 66, 62)

local MAX = RadioConfig.MAX_CHANNEL

-- ============ الحالة المحلية (للعرض فقط، السيرفر هو المرجع) ============
local equipped = false
local currentChannel = nil     -- آخر قناة أكدها السيرفر
local serverTalking = false    -- آخر حالة تحدث أكدها السيرفر
local pendingJoin = false
local typed = ""               -- الرقم اللي يكتبه اللاعب على لوحة الأرقام
local statusText = "اكتب رقم القناة ثم OK"
local buttonTalking = false    -- الضغط الحالي على زر PTT
local keyTalking = false       -- الضغط الحالي على CapsLock
local lastSentTalk = false
local pendingToken = 0

-- ============ بناء الواجهة ============
local gui = Instance.new("ScreenGui")
gui.Name = "NewTownRadioGui"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

local body = Instance.new("Frame")
body.Name = "RadioBody"
body.Size = UDim2.new(0, 280, 0, 580)
body.Position = UDim2.new(1, -310, 0.5, -290)
body.BackgroundColor3 = BODY
body.Parent = gui
do
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 28); c.Parent = body
    local s = Instance.new("UIStroke"); s.Color = BODY_EDGE; s.Thickness = 2; s.Parent = body
end

-- شريط صغير يمثل الهوائي
local antenna = Instance.new("Frame")
antenna.Name = "Antenna"
antenna.Size = UDim2.new(0, 18, 0, 26)
antenna.Position = UDim2.new(0.5, -9, 0, -24)
antenna.BackgroundColor3 = GRILLE
antenna.Parent = body
do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = antenna end

-- اسم الجهاز + LED
local brand = Instance.new("TextLabel")
brand.BackgroundTransparency = 1
brand.Size = UDim2.new(0, 200, 0, 22)
brand.Position = UDim2.new(0, 22, 0, 10)
brand.Font = Enum.Font.GothamBold
brand.TextSize = 14
brand.TextColor3 = KEY_TEXT
brand.TextXAlignment = Enum.TextXAlignment.Left
brand.Text = "NEW TOWN RADIO"
brand.Parent = body

local led = Instance.new("Frame")
led.Name = "Led"
led.Size = UDim2.new(0, 10, 0, 10)
led.Position = UDim2.new(1, -32, 0, 16)
led.BackgroundColor3 = GREY
led.Parent = body
do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = led end

-- الشبك الجانبي (الخطوط فوق الشاشة كما في الجهاز)
for i = 0, 2 do
    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(0, 200, 0, 10)
    bar.Position = UDim2.new(0, 40, 0, 40 + i * 16)
    bar.BackgroundColor3 = GRILLE
    bar.Parent = body
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 5); c.Parent = bar
end

-- شاشة LCD
local lcd = Instance.new("Frame")
lcd.Name = "Lcd"
lcd.Size = UDim2.new(0, 230, 0, 118)
lcd.Position = UDim2.new(0, 25, 0, 92)
lcd.BackgroundColor3 = LCD_BG
lcd.Parent = body
do
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = lcd
    local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(10, 10, 14); s.Thickness = 2; s.Parent = lcd
end

local function lcdLabel(name, y, h, size, font)
    local l = Instance.new("TextLabel")
    l.Name = name
    l.BackgroundTransparency = 1
    l.Size = UDim2.new(1, -20, 0, h)
    l.Position = UDim2.new(0, 10, 0, y)
    l.Font = font
    l.TextSize = size
    l.TextColor3 = LCD_INK
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextWrapped = true
    l.Text = ""
    l.Parent = lcd
    return l
end

local lcdLine1 = lcdLabel("LcdLine1", 6, 22, 16, Enum.Font.Code)
local lcdLine2 = lcdLabel("LcdLine2", 34, 40, 30, Enum.Font.Code)
local lcdLine3 = lcdLabel("LcdLine3", 80, 32, 13, Enum.Font.Gotham)

-- ============ أدوات الأزرار ============
local function makeKey(name, text, x, y, w, h, color, onClick)
    local b = Instance.new("TextButton")
    b.Name = name
    b.Size = UDim2.new(0, w, 0, h)
    b.Position = UDim2.new(0, x, 0, y)
    b.BackgroundColor3 = color or KEY
    b.Font = Enum.Font.GothamBold
    b.TextSize = 18
    b.TextColor3 = KEY_TEXT
    b.Text = text
    b.AutoButtonColor = true
    b.Parent = body
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 10); c.Parent = b
    if onClick then b.Activated:Connect(onClick) end
    return b
end

-- ============ منطق الأرقام والقنوات ============
local function looksAllowed(channel)
    local rule = RadioConfig.getRule(channel)
    if rule == nil or rule.teams == nil then return true end
    local team = player.Team
    if team == nil then return false end
    for _, name in ipairs(rule.teams) do
        if team.Name == name then return true end
    end
    return false
end

local function updateScreen()
    if typed ~= "" then
        lcdLine2.Text = "Channel " .. typed
    elseif currentChannel then
        lcdLine2.Text = "Channel " .. tostring(currentChannel)
    else
        lcdLine2.Text = "Channel --"
    end
    lcdLine1.Text = serverTalking and "NEW TOWN      TX" or "NEW TOWN"
    lcdLine1.TextColor3 = serverTalking and LCD_TX or LCD_INK
    lcdLine3.Text = statusText
    lcd.BackgroundColor3 = serverTalking and Color3.fromRGB(214, 190, 186) or LCD_BG
    led.BackgroundColor3 = currentChannel and GREEN or GREY
end

local function setStatus(message)
    statusText = message
    updateScreen()
end

-- شبكة أمان: إذا ما وصل رد من السيرفر خلال 4 ثواني نفك الانتظار
local function armPendingTimeout()
    pendingToken = pendingToken + 1
    local myToken = pendingToken
    task.delay(4, function()
        if pendingToken == myToken and pendingJoin then
            pendingJoin = false
            setStatus("ما وصل رد من السيرفر، حاول مرة ثانية")
        end
    end)
end

local function tryJoin(channel)
    if pendingJoin then return end
    if channel == nil then
        setStatus("اكتب رقم القناة ثم OK")
        return
    end
    if channel ~= math.floor(channel) or channel < 1 or channel > MAX then
        setStatus("رقم القناة غير صحيح (1 - " .. MAX .. ")")
        return
    end
    if channel == currentChannel then
        setStatus("أنت متصل بالقناة " .. channel)
        return
    end
    if not looksAllowed(channel) then
        setStatus("ما عندك صلاحية للقناة " .. channel)
        return
    end
    pendingJoin = true
    setStatus("جارٍ الاتصال بالقناة " .. channel .. "...")
    JoinChannelEvent:FireServer(channel)
    armPendingTimeout()
end

local function typeDigit(d)
    if #typed >= 2 then
        typed = tostring(d)
    else
        typed = typed .. tostring(d)
    end
    typed = tostring(tonumber(typed))
    updateScreen()
end

local function navBase()
    return tonumber(typed) or currentChannel or 1
end

-- ============ لوحة الأزرار (تطابق الصورة) ============
makeKey("BtnP1", "P1", 25, 226, 110, 36, nil, function()
    typed = tostring(RadioConfig.PRESETS.P1)
    tryJoin(RadioConfig.PRESETS.P1)
end)
makeKey("BtnP2", "P2", 145, 226, 110, 36, nil, function()
    typed = tostring(RadioConfig.PRESETS.P2)
    tryJoin(RadioConfig.PRESETS.P2)
end)

makeKey("BtnLeft", "<", 25, 270, 66, 36, nil, function()
    local target = math.max(1, navBase() - 1)
    typed = tostring(target)
    updateScreen()
end)
makeKey("BtnOK", "OK", 107, 270, 66, 36, KEY_ACCENT, function()
    tryJoin(tonumber(typed))
end)
makeKey("BtnRight", ">", 189, 270, 66, 36, nil, function()
    local target = math.min(MAX, navBase() + 1)
    typed = tostring(target)
    updateScreen()
end)

local digitLayout = {
    { "1", "2", "3" },
    { "4", "5", "6" },
    { "7", "8", "9" },
}
for row = 1, 3 do
    for col = 1, 3 do
        local d = digitLayout[row][col]
        makeKey("Key" .. d, d, 33 + (col - 1) * 74, 314 + (row - 1) * 38, 66, 34, nil, function()
            typeDigit(d)
        end)
    end
end

makeKey("KeyC", "C", 33, 428, 66, 34, nil, function()
    typed = ""
    updateScreen()
end)
makeKey("Key0", "0", 107, 428, 66, 34, nil, function()
    typeDigit(0)
end)
makeKey("KeyExit", "EXIT", 181, 428, 66, 34, nil, function()
    if currentChannel == nil then
        setStatus("أنت غير متصل بأي قناة")
        return
    end
    if pendingJoin then return end
    pendingJoin = true
    typed = ""
    setStatus("جارٍ الخروج من القناة...")
    LeaveChannelEvent:FireServer()
    armPendingTimeout()
end)

-- ============ زر التحدث PTT ============
local talkButton = Instance.new("TextButton")
talkButton.Name = "BtnPTT"
talkButton.Size = UDim2.new(0, 230, 0, 74)
talkButton.Position = UDim2.new(0, 25, 0, 486)
talkButton.BackgroundColor3 = GREY
talkButton.Font = Enum.Font.GothamBold
talkButton.TextSize = 20
talkButton.TextColor3 = Color3.fromRGB(255, 255, 255)
talkButton.Text = "PTT"
talkButton.AutoButtonColor = false
talkButton.Parent = body
do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 14); c.Parent = talkButton end

local function wantsToTalk()
    return buttonTalking or keyTalking
end

local function syncTalk()
    local want = wantsToTalk() and currentChannel ~= nil
    if want == lastSentTalk then return end
    lastSentTalk = want
    SetTalkingEvent:FireServer(want)
end

local function forceStopTalk()
    buttonTalking = false
    keyTalking = false
    syncTalk()
end

local function updateTalkVisuals()
    if serverTalking then
        talkButton.BackgroundColor3 = RED
        talkButton.Text = "PTT  -  تتحدث الآن"
    elseif currentChannel then
        talkButton.BackgroundColor3 = GREEN
        talkButton.Text = "PTT  -  اضغط للتحدث"
    else
        talkButton.BackgroundColor3 = GREY
        talkButton.Text = "PTT  -  ادخل قناة أولاً"
    end
end

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
    if gameProcessed or not equipped then return end
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

-- خروج التركيز من النافذة يوقف التحدث حتى لا يبقى المايك مفتوحاً
UserInputService.WindowFocusReleased:Connect(forceStopTalk)

-- ============ ردود السيرفر ============
RadioStateEvent.OnClientEvent:Connect(function(channel, talking, message)
    pendingJoin = false
    pendingToken = pendingToken + 1 -- يلغي مؤقت الأمان

    local previous = currentChannel
    currentChannel = channel
    serverTalking = (channel ~= nil) and talking or false

    -- عند تغيّر القناة نمسح الرقم المكتوب
    if channel ~= previous then
        typed = ""
    end

    if channel == nil then
        buttonTalking = false
        keyTalking = false
        syncTalk() -- يرسل الإيقاف إذا كان المايك مرسلاً
    end

    if message and message ~= "" then
        statusText = message
    elseif channel then
        statusText = "متصل بالقناة " .. channel
    else
        statusText = "غير متصل"
    end

    updateScreen()
    updateTalkVisuals()
end)

-- ============ إظهار الواجهة مع الأداة ============
local function onEquipped()
    equipped = true
    gui.Enabled = true
    updateScreen()
    updateTalkVisuals()
end

local function onUnequipped()
    equipped = false
    gui.Enabled = false
    forceStopTalk()
end

tool.Equipped:Connect(onEquipped)
tool.Unequipped:Connect(onUnequipped)

-- عند الموت نوقف التحدث ونخفي الجهاز
local function onCharacter(character)
    local humanoid = character:WaitForChild("Humanoid", 10)
    if humanoid then
        humanoid.Died:Connect(function()
            forceStopTalk()
            gui.Enabled = false
            equipped = false
        end)
    end
end

if player.Character then onCharacter(player.Character) end
player.CharacterAdded:Connect(onCharacter)

updateScreen()
updateTalkVisuals()
