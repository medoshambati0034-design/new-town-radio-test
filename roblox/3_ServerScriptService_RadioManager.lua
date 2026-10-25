--[[
    اسم السكربت: RadioManager
    مكانه: ServerScriptService  (Script عادي)

    الدخول للقنوات يتم من الموقع فقط، والسيرفر (Backend) هو اللي يتحقق من الصلاحيات.
    هذا السكربت:
    1) يرسل تيم اللاعب للسيرفر عند كل تغيير، عشان الموقع يطبّق القواعد.
    2) يمرر زر التحدث (PTT) من اللعبة للسيرفر، ويرجّع الحالة للاعب.
    3) ينشر القناة الحالية كـ Attributes على اللاعب، فالزر العائم يقراها.

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
local MIN_TALK_INTERVAL = 0.15 -- أقل فترة بين طلبات بدء التحدث (إيقاف التحدث ما له حد)

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

local SetTalkingEvent = getOrCreateRemote("SetTalking")     -- كلاينت -> سيرفر: true/false
local RadioStateEvent = getOrCreateRemote("RadioState")     -- سيرفر -> كلاينت: channel, talking, message
local RequestStateEvent = getOrCreateRemote("RequestState") -- كلاينت -> سيرفر: "وش حالتي؟"

-- lastTalk[player] = آخر وقت طلب تحدث (للحد من الطلبات)
local lastTalk = {}

-- ============ طلبات HTTP ============
-- يرجّع: (جدول الرد أو nil, رمز الحالة) — رمز 0 يعني فشل اتصال
local function postJson(endpoint, data)
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
        warn("[RadioManager] فشل الاتصال بالسيرفر عند " .. endpoint .. ": " .. tostring(result))
        return nil, 0
    end

    if not result.Success then
        if result.StatusCode ~= 404 then
            warn("[RadioManager] خطأ " .. tostring(result.StatusCode) .. " عند " .. endpoint)
        end
        return nil, result.StatusCode
    end

    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(result.Body)
    end)
    return (ok and decoded) or {}, result.StatusCode
end

-- ============ حالة اللاعب (منشورة كـ Attributes) ============
local function publishRadio(player, channel, talking)
    player:SetAttribute("RadioChannel", channel)
    player:SetAttribute("RadioTalking", channel ~= nil and talking or false)
end

local function fireState(player, message)
    local channel = player:GetAttribute("RadioChannel")
    local talking = player:GetAttribute("RadioTalking") or false
    RadioStateEvent:FireClient(player, channel, talking, message or "")
end

-- ============ تيم اللاعب ============
local function sendTeam(player)
    local team = player.Team
    task.spawn(function()
        postJson("/api/radio/team", {
            userId = player.UserId,
            team = team and team.Name or nil,
        })
    end)
end

-- تحقق من أسماء التيمات (يظهر في Output إذا فيه خطأ في RadioConfig)
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
    task.wait(2)
    checkTeamNames()
end)

-- ============ التحدث ============
local function setTalking(player, talking)
    task.spawn(function()
        local res, status = postJson("/api/radio/talk", {
            userId = player.UserId,
            talking = talking,
        })

        if status == 404 then
            publishRadio(player, nil, false)
            fireState(player, "غير مربوط بالموقع بعد")
            return
        end
        if res == nil then
            fireState(player, "تعذّر الاتصال بالسيرفر")
            return
        end

        if res.channel == nil then
            publishRadio(player, nil, false)
            fireState(player, "ادخل قناة من الموقع أولاً")
        else
            publishRadio(player, res.channel, res.talking == true)
            fireState(player, "")
        end
    end)
end

SetTalkingEvent.OnServerEvent:Connect(function(player, talking)
    if type(talking) ~= "boolean" then return end

    -- إيقاف التحدث مسموح دائماً، ولا يتأثر بالحد، عشان المايك ما يبقى مفتوح
    if talking == false then
        setTalking(player, false)
        return
    end

    if player:GetAttribute("RadioChannel") == nil then
        fireState(player, "ادخل قناة من الموقع أولاً")
        return
    end

    -- الحد يُحسب فقط للطلبات اللي تُرسل فعلاً، عشان الرفض ما يمنع المحاولة الثانية
    local now = os.clock()
    local last = lastTalk[player] or -math.huge
    if now - last < MIN_TALK_INTERVAL then return end
    lastTalk[player] = now

    setTalking(player, true)
end)

RequestStateEvent.OnServerEvent:Connect(function(player)
    local channel = player:GetAttribute("RadioChannel")
    local message = channel and ("متصل بالقناة " .. tostring(channel)) or "غير متصل"
    fireState(player, message)
end)

-- ============ انضمام وخروج ============
local function onPlayerAdded(player)
    publishRadio(player, nil, false)
    player:GetPropertyChangedSignal("Team"):Connect(function()
        sendTeam(player)
    end)
end

local function onPlayerRemoving(player)
    lastTalk[player] = nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in ipairs(Players:GetPlayers()) do
    task.spawn(onPlayerAdded, player)
end
