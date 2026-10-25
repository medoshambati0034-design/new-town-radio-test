--[[
    اسم السكربت: VoiceLinkManager
    مكانه: ServerScriptService  (Script عادي وليس LocalScript)

    وظيفته:
    1) لما أي لاعب يدخل الماب -> يطلب من السيرفر رابط تفعيل لمرة واحدة.
    2) يعرض الرابط للاعب (يقدر ينسخه ويفتحه في Chrome أو Safari).
    3) يرسل موقع اللاعب كل ثانيتين عشان السيرفر يحسب "مين قريب من مين".
    4) يعرف متى اللاعب فعّل الرابط، ويزامن حالة المايك بين الموقع وزر اللعبة.
    5) إذا انتهت الجلسة أو صلاحية الرابط، يطلب رابطاً جديداً تلقائياً.

    قبل التجربة:
    - فعّل HttpService: Game Settings -> Security -> Allow HTTP Requests
    - غيّر BACKEND_URL لعنوان الخدمة على Render (https://...onrender.com)
    - اضبط API_KEY بنفس القيمة اللي في Render (Environment -> API_KEY)
--]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ============ الإعدادات ============
local BACKEND_URL = "https://YOUR-SERVICE.onrender.com" -- بدون / بالنهاية
local API_KEY = "PUT_YOUR_SECRET_API_KEY_HERE"           -- نفس قيمة API_KEY في Render
local POSITION_UPDATE_INTERVAL = 2  -- كل كم ثانية نرسل الموقع
local LOCAL_TOGGLE_GRACE = 3        -- بعد ما اللاعب يضغط الزر نتجاهل مزامنة الموقع هالمدة (ثواني)
local LINK_EXPIRY_MARGIN = 15       -- نطلب رابطاً جديداً قبل انتهائه بهالمدة

BACKEND_URL = BACKEND_URL:gsub("/+$", "")

-- ============ تجهيز RemoteEvents ============
local remotesFolder = ReplicatedStorage:FindFirstChild("VoiceLinkRemotes")
if not remotesFolder then
    remotesFolder = Instance.new("Folder")
    remotesFolder.Name = "VoiceLinkRemotes"
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

local LinkReadyEvent = getOrCreateRemote("LinkReady")   -- سيرفر -> كلاينت: رابط التفعيل
local LinkStatusEvent = getOrCreateRemote("LinkStatus") -- سيرفر -> كلاينت: حالة الربط
local ToggleMicEvent = getOrCreateRemote("ToggleMic")   -- كلاينت -> سيرفر: تشغيل/إطفاء
local MicStateEvent = getOrCreateRemote("MicState")     -- سيرفر -> كلاينت: الحالة الحالية

-- playerData[userId] = { url, muted, lastToggle, registered, linked, linkExpiresAt }
local playerData = {}

-- ============ طلب HTTP ============
-- يرجّع: (النتيجة أو nil, رمز الحالة) — رمز 0 يعني فشل اتصال
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
        warn("[VoiceLink] فشل الاتصال بالسيرفر عند " .. endpoint .. ": " .. tostring(result))
        return nil, 0
    end

    if not result.Success then
        if result.StatusCode ~= 404 then
            warn("[VoiceLink] خطأ " .. tostring(result.StatusCode) .. " عند " .. endpoint .. ": " .. tostring(result.Body))
        end
        return nil, result.StatusCode
    end

    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(result.Body)
    end)
    return (ok and decoded) or {}, result.StatusCode
end

-- ============ رسائل الحالة ============
local function publishStatus(player, state, message)
    player:SetAttribute("VoiceLinkStatusState", state)
    player:SetAttribute("VoiceLinkStatus", message)
    LinkStatusEvent:FireClient(player, state, message)
end

local function getFailureMessage(status)
    if status == 401 then
        return "مفتاح API_KEY غير صحيح أو غير مضبوط في سكربت الخادم."
    elseif status == 0 then
        return "تعذّر الوصول إلى خادم الصوت. تحقق من رابط BACKEND_URL."
    elseif status == 404 then
        return "لم يُعثر على الخادم (404). تأكد من رابط BACKEND_URL."
    end
    return "تعذّر تجهيز رابط الصوت (HTTP " .. tostring(status) .. "). سنحاول مرة ثانية."
end

-- ============ طلب رابط تفعيل جديد ============
local function requestLink(player, data)
    local res, status = postToBackend("/api/link", {
        userId = player.UserId,
        username = player.Name,
    })
    if res and type(res.url) == "string" then
        data.url = res.url
        data.registered = true
        data.linked = false
        data.linkExpiresAt = os.time() + (tonumber(res.expiresIn) or 300) - LINK_EXPIRY_MARGIN
        return true
    end
    return false, status
end

local function publishLink(player, data)
    player:SetAttribute("VoiceLinkUrl", data.url)
    LinkReadyEvent:FireClient(player, data.url)
    MicStateEvent:FireClient(player, data.muted)
    publishStatus(player, "waiting", "افتح الرابط في Chrome أو Safari وفعّل المايك")
end

-- ============ لما لاعب يدخل ============
local function onPlayerAdded(player)
    local data = {
        url = nil,
        muted = false,
        lastToggle = 0,
        registered = false,
        linked = false,
        linkExpiresAt = 0,
    }
    playerData[player.UserId] = data
    player:SetAttribute("VoiceLinkUrl", nil)
    publishStatus(player, "connecting", "جارٍ تجهيز رابط التفعيل...")

    task.spawn(function()
        local retryDelay = POSITION_UPDATE_INTERVAL
        while player.Parent and playerData[player.UserId] == data do
            local needLink = (not data.registered) or (not data.linked and os.time() >= data.linkExpiresAt)

            if needLink then
                local ok, status = requestLink(player, data)
                if ok then
                    retryDelay = POSITION_UPDATE_INTERVAL
                    publishLink(player, data)
                else
                    data.registered = false
                    publishStatus(player, "error", getFailureMessage(status))
                    task.wait(retryDelay)
                    retryDelay = math.min(retryDelay * 2, 30)
                end
            else
                local character = player.Character
                if character and character.PrimaryPart then
                    local pos = character.PrimaryPart.Position
                    local res, status = postToBackend("/api/position/update", {
                        userId = player.UserId,
                        x = pos.X, y = pos.Y, z = pos.Z,
                    })

                    if status == 404 then
                        -- انتهت الجلسة في السيرفر (فصل من الموقع أو انتهاء مهلة) -> رابط جديد
                        data.registered = false
                        data.linked = false
                        publishStatus(player, "connecting", "انتهت الجلسة، جارٍ تجهيز رابط جديد...")
                    elseif status == 401 then
                        data.registered = false
                        publishStatus(player, "error", getFailureMessage(status))
                    elseif status == 0 then
                        publishStatus(player, "connecting", getFailureMessage(status))
                    elseif res then
                        if res.linked == true and not data.linked then
                            -- اللاعب فعّل الرابط من الموقع
                            data.linked = true
                            publishStatus(player, "linked", "المايك مربوط ✓")
                        end

                        -- المايك تغيّر من الموقع: ننعكس على زر اللعبة
                        if data.linked and res.muted ~= nil and res.muted ~= data.muted
                            and os.clock() - data.lastToggle > LOCAL_TOGGLE_GRACE then
                            data.muted = res.muted
                            MicStateEvent:FireClient(player, data.muted)
                        end
                    end
                end
                task.wait(POSITION_UPDATE_INTERVAL)
            end
        end
    end)
end

-- ============ زر المايك داخل اللعبة ============
ToggleMicEvent.OnServerEvent:Connect(function(player)
    local data = playerData[player.UserId]
    if not data then return end

    data.muted = not data.muted
    data.lastToggle = os.clock()

    if data.registered then
        task.spawn(function()
            postToBackend("/api/mic/toggle", { userId = player.UserId, muted = data.muted })
        end)
    end

    MicStateEvent:FireClient(player, data.muted)
end)

-- ============ لما لاعب يطلع ============
local function onPlayerRemoving(player)
    local data = playerData[player.UserId]
    if data then
        playerData[player.UserId] = nil
        player:SetAttribute("VoiceLinkUrl", nil)
        if data.registered then
            task.spawn(function()
                postToBackend("/api/session/end", { userId = player.UserId })
            end)
        end
    end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in ipairs(Players:GetPlayers()) do
    task.spawn(onPlayerAdded, player)
end
