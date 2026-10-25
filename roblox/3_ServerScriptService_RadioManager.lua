--[[
    اسم السكربت: RadioManager
    مكانه: ServerScriptService  (Script عادي)

    وظيفته:
    1) يستقبل طلبات الانضمام للقنوات، ويتحقق من التيم على السيرفر (لا يثق بالواجهة أبداً).
    2) يسحب اللاعب من القناة فوراً إذا تغيّر تيمه وما عاد مسموحاً له.
    3) يرسل قرار الراديو للـ Backend، فيعرف الموقع القناة وحالة التحدث.
    4) يحدّ من عدد الطلبات لكل لاعب.

    ملاحظة: نفس BACKEND_URL و API_KEY المستخدمين في VoiceLinkManager.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Teams = game:GetService("Teams")

local RadioConfig = require(ReplicatedStorage:WaitForChild("RadioConfig"))

-- ============ الإعدادات (نفس قيم VoiceLinkManager) ============
local BACKEND_URL = "https://YOUR-SERVICE.onrender.com"
local API_KEY = "PUT_YOUR_SECRET_API_KEY_HERE"
local MIN_JOIN_INTERVAL = 0.5 -- أقل فترة بين طلبات الانضمام/الخروج (ثواني)
local MIN_TALK_INTERVAL = 0.15 -- أقل فترة بين طلبات بدء التحدث

BACKEND_URL = BACKEND_URL:gsub("/+$", "")

-- ============ الأحداث ============
local remotesFolder = ReplicatedStorage:FindFirstChild(RadioConfig.REMOTES_FOLDER)
if not remotesFolder then
    remotesFolder = Instance.new("Folder")
    remotesFolder.Name = RadioConfig.REMOTES_FOLDER
    remotesFolder.Parent = ReplicatedStorage
end

local function getOrCreateRemote(name)
    local ev = remotesFolder:FindFirstChild(name)
    if not ev then
        ev = Instance.new("RemoteEvent")
        ev.Name = name
        ev.Parent = remotesFolder
    end
    return ev
end

local JoinChannelEvent = getOrCreateRemote("JoinChannel")   -- كلاينت -> سيرفر: رقم القناة
local LeaveChannelEvent = getOrCreateRemote("LeaveChannel") -- كلاينت -> سيرفر
local SetTalkingEvent = getOrCreateRemote("SetTalking")     -- كلاينت -> سيرفر: true/false
local RadioStateEvent = getOrCreateRemote("RadioState")     -- سيرفر -> كلاينت: channel, talking, message
local RequestStateEvent = getOrCreateRemote("RequestState") -- كلاينت -> سيرفر: "وش حالتي الحالية؟" (عند تجهيز الأداة بعد الموت)

-- radioStates[player] = { channel = nil|number, talking = bool, lastJoin = 0, lastTalk = 0 }
local radioStates = {}

-- ============ طلب HTTP للـ Backend ============
local function postToBackend(endpoint, data)
    local success, result = pcall(function()
        return HttpService:RequestAsync({
            Url = BACKEND_URL .. endpoint,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Bearer " .. API_KEY,
            },
            Body = HttpService:JSONEncode(data),
        })
    end)

    if not success then
        warn("[RadioManager] فشل الاتصال بالسيرفر: " .. tostring(result))
        return nil, 0
    end
    if not result.Success and result.StatusCode ~= 404 then
        warn("[RadioManager] خطأ " .. tostring(result.StatusCode) .. " عند " .. endpoint)
    end
    return result, result.StatusCode
end

-- ============ الصلاحيات (تتحقق من السيرفر فقط) ============
local function isValidChannelNumber(channel)
    return type(channel) == "number"
        and channel == channel          -- يستبعد NaN
        and channel % 1 == 0
        and channel >= 1
        and channel <= RadioConfig.MAX_CHANNEL
end

local function canUseChannel(player, channel)
    if not isValidChannelNumber(channel) then
        return false
    end
    local rule = RadioConfig.getRule(channel)
    if rule == nil or rule.teams == nil then
        return true -- قناة مفتوحة للجميع
    end
    local team = player.Team
    if team == nil then
        return false
    end
    for _, allowedName in ipairs(rule.teams) do
        if team.Name == allowedName then
            return true
        end
    end
    return false
end

-- ============ تطبيق القرار: يحدّث الحالة ويرسلها للكلاينت والـ Backend ============
local function applyState(player, channel, talking, message)
    local st = radioStates[player]
    if not st then return end

    st.channel = channel
    st.talking = (channel ~= nil) and talking or false

    -- ملاحظة: إذا channel = nil لن يُرسل المفتاح، والـ Backend يعتبره null
    local body = {
        userId = player.UserId,
        talking = st.talking,
    }
    if channel ~= nil then
        body.channel = channel
    end

    task.spawn(function()
        local _, status = postToBackend("/api/radio/state", body)
        if status == 0 then
            warn("[RadioManager] تعذّر تحديث حالة الراديو للموقع")
        end
    end)

    RadioStateEvent:FireClient(player, st.channel, st.talking, message or "")
end

-- ============ الأحداث من اللاعب ============
JoinChannelEvent.OnServerEvent:Connect(function(player, channel)
    local st = radioStates[player]
    if not st then return end

    local now = os.clock()
    if now - st.lastJoin < MIN_JOIN_INTERVAL then
        -- لازم نرد دائماً، وإلا الواجهة تبقى تنتظر
        RadioStateEvent:FireClient(player, st.channel, st.talking, "انتظر لحظة ثم حاول مرة ثانية")
        return
    end
    st.lastJoin = now

    if not isValidChannelNumber(channel) then
        RadioStateEvent:FireClient(player, st.channel, st.talking, "رقم القناة غير صحيح")
        return
    end

    if not canUseChannel(player, channel) then
        RadioStateEvent:FireClient(player, st.channel, st.talking, "ما عندك صلاحية لهذه القناة")
        return
    end

    applyState(player, channel, false, "متصل بالقناة " .. tostring(channel))
end)

LeaveChannelEvent.OnServerEvent:Connect(function(player)
    local st = radioStates[player]
    if not st then return end

    local now = os.clock()
    if now - st.lastJoin < MIN_JOIN_INTERVAL then
        RadioStateEvent:FireClient(player, st.channel, st.talking, "انتظر لحظة ثم حاول مرة ثانية")
        return
    end
    st.lastJoin = now

    applyState(player, nil, false, "خرجت من القناة")
end)

SetTalkingEvent.OnServerEvent:Connect(function(player, talking)
    local st = radioStates[player]
    if not st or type(talking) ~= "boolean" then return end

    -- إيقاف التحدث دائماً مسموح، حتى لو الطلبات كثيرة، عشان المايك ما يبقى مفتوح
    if talking == false then
        if st.talking then
            applyState(player, st.channel, false, "")
        end
        return
    end

    if st.channel == nil then
        RadioStateEvent:FireClient(player, nil, false, "اختر قناة أولاً")
        return
    end

    local now = os.clock()
    if now - st.lastTalk < MIN_TALK_INTERVAL then return end
    st.lastTalk = now

    if st.talking then return end
    applyState(player, st.channel, true, "")
end)

-- ============ تحقق من أسماء التيمات (يظهر في Output إذا فيه خطأ) ============
local function checkTeamNames()
    local existing = {}
    for _, team in ipairs(Teams:GetTeams()) do
        existing[team.Name] = true
    end
    for channel, rule in pairs(RadioConfig.CHANNELS) do
        for _, teamName in ipairs(rule.teams) do
            if not existing[teamName] then
                warn("[RadioManager] التيم '" .. teamName .. "' (للقناة " .. tostring(channel)
                    .. ") غير موجود في Teams. غيّره في RadioConfig ليطابق اسمه بالضبط.")
            end
        end
    end
end

task.spawn(function()
    task.wait(2) -- ننتظر تحميل التيمات
    checkTeamNames()
end)

RequestStateEvent.OnServerEvent:Connect(function(player)
    local st = radioStates[player]
    if not st then return end
    local message = st.channel and ("متصل بالقناة " .. tostring(st.channel)) or "غير متصل"
    RadioStateEvent:FireClient(player, st.channel, st.talking, message)
end)

-- ============ تغيير التيم أثناء اللعب ============
local function watchTeam(player)
    player:GetPropertyChangedSignal("Team"):Connect(function()
        local st = radioStates[player]
        if not st or st.channel == nil then return end

        if not canUseChannel(player, st.channel) then
            applyState(player, nil, false, "تم إخراجك من القناة لأن تيمك تغيّر")
        end
    end)
end

-- ============ انضمام وخروج اللاعبين ============
local function onPlayerAdded(player)
    -- -math.huge: os.clock() قد يكون صغيراً جداً عند بدء السيرفر، فلا نبدأ من 0
    radioStates[player] = { channel = nil, talking = false, lastJoin = -math.huge, lastTalk = -math.huge }
    watchTeam(player)

    player.CharacterAdded:Connect(function(character)
        -- عند الموت أو إعادة الظهور نوقف التحدث (المايك ما يبقى مفتوح)
        local humanoid = character:WaitForChild("Humanoid", 10)
        if humanoid then
            humanoid.Died:Connect(function()
                local st = radioStates[player]
                if st and st.talking then
                    applyState(player, st.channel, false, "")
                end
            end)
        end
    end)
end

-- ملاحظة: إنهاء جلسة الموقع يتم في VoiceLinkManager فقط، هنا نمسح حالة الراديو المحلية
local function onPlayerRemoving(player)
    radioStates[player] = nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in ipairs(Players:GetPlayers()) do
    task.spawn(onPlayerAdded, player)
end
