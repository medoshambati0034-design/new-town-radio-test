-- اختبار الزر العائم للراديو (LocalScript) مع محاكاة واجهات Roblox
-- الهدف: الزر يفتح اللوحة، القناة تظهر من السيرفر، والمايك لا يبقى مفتوحاً.
-- التشغيل: lua5.4 test/radio_float_test.lua   (من جذر المشروع)

local failures, passes = 0, 0
local function check(name, cond)
    if cond then passes = passes + 1; print("ok   - " .. name)
    else failures = failures + 1; print("FAIL - " .. name) end
end

local function signal()
    local s = { handlers = {} }
    function s:Connect(fn) self.handlers[#self.handlers + 1] = fn; return { Disconnect = function() end } end
    function s:Fire(...) for _, h in ipairs(self.handlers) do h(...) end end
    return s
end

local EVENTS = {
    Activated = true, InputBegan = true, InputEnded = true, Died = true,
    OnClientEvent = true, OnServerEvent = true, WindowFocusReleased = true, CharacterAdded = true,
}

local sentToServer = {}

-- Enum و UDim و UDim2 و Color3
Enum = setmetatable({}, { __index = function(_, k)
    return setmetatable({}, { __index = function(_, kk) return kk end })
end })
UDim = { new = function(a, b) return { a, b } end }
UDim2 = { new = function(...) return { ... } end }
Color3 = { fromRGB = function(r, g, b) return { r, g, b } end }
warn = function() end

local function newInstance(class)
    local inst = { ClassName = class, _children = {}, _signals = {}, _attrs = {} }
    setmetatable(inst, {
        __index = function(t, k)
            if EVENTS[k] then rawset(t, k, signal()); return rawget(t, k) end
            return nil
        end,
        __newindex = function(t, k, v)
            if k == "Parent" and type(v) == "table" and v._children and rawget(t, "Name") then
                v._children[t.Name] = t
            end
            rawset(t, k, v)
        end,
    })
    function inst:FindFirstChild(n) return self._children[n] end
    function inst:WaitForChild(n) return self._children[n] end
    function inst:FireServer(...)
        sentToServer[#sentToServer + 1] = { remote = self.Name, args = { ... } }
    end
    function inst:SetAttribute(k, v)
        local old = self._attrs[k]
        self._attrs[k] = v
        if old ~= v and self._signals["attr:" .. k] then self._signals["attr:" .. k]:Fire() end
    end
    function inst:GetAttribute(k) return self._attrs[k] end
    function inst:GetAttributeChangedSignal(k)
        self._signals["attr:" .. k] = self._signals["attr:" .. k] or signal()
        return self._signals["attr:" .. k]
    end
    function inst:GetPropertyChangedSignal(p)
        self._signals[p] = self._signals[p] or signal()
        return self._signals[p]
    end
    function inst:Destroy() self.Destroyed = true end
    return inst
end
Instance = { new = newInstance }

-- ============ الخدمات ============
local uis = { InputBegan = signal(), InputEnded = signal(), WindowFocusReleased = signal() }
local rs = newInstance("ReplicatedStorage")
local RadioConfig = dofile("roblox/RadioConfig.lua")
rs._children["RadioConfig"] = { _module = RadioConfig }
rs._children["RadioRemotes"] = newInstance("Folder")
local remotes = rs._children["RadioRemotes"]
for _, name in ipairs({ "SetTalking", "RadioState", "RequestState" }) do
    local ev = newInstance("RemoteEvent")
    ev.Name = name
    remotes._children[name] = ev
end

local playerGui = newInstance("PlayerGui")
local player = newInstance("Player")
player.Character = nil

game = {
    GetService = function(_, name)
        if name == "Players" then return { LocalPlayer = player } end
        if name == "ReplicatedStorage" then return rs end
        if name == "UserInputService" then return uis end
        return newInstance(name)
    end,
}
require = function(m) return m._module end
task = { spawn = function(f, ...) f(...) end, wait = function() end, delay = function() end }
player.WaitForChild = function(_, n) return playerGui end

dofile("roblox/5_StarterPlayerScripts_RadioFloat.lua")

-- ============ مساعدات ============
local function find(root, name)
    if root.Name == name then return root end
    for _, c in pairs(root._children or {}) do
        local r = find(c, name)
        if r then return r end
    end
    return nil
end

local gui = playerGui._children["RadioFloatGui"]
local floatButton = find(gui, "RadioFloatButton")
local panel = find(gui, "RadioPanel")
local channelLabel = find(panel, "Channel")
local statusLabel = find(panel, "Status")
local talkButton = find(panel, "TalkButton")
local closeButton = find(panel, "Close")
local led = find(floatButton, "Led")

local function talkSends(value)
    local n = 0
    for _, c in ipairs(sentToServer) do
        if c.remote == "SetTalking" and c.args[1] == value then n = n + 1 end
    end
    return n
end
local function lastTalk()
    for i = #sentToServer, 1, -1 do
        if sentToServer[i].remote == "SetTalking" then return sentToServer[i].args[1] end
    end
end
local function serverSays(channel, talking, message)
    remotes._children["RadioState"].OnClientEvent:Fire(channel, talking, message or "")
end
local function pressKey(code) uis.InputBegan:Fire({ KeyCode = code, UserInputType = "Keyboard" }, false) end
local function releaseKey(code) uis.InputEnded:Fire({ KeyCode = code, UserInputType = "Keyboard" }) end

-- ============ الاختبارات ============

check("floating button exists on screen", floatButton ~= nil)
check("panel starts hidden", panel.Visible == false)
check("RequestState is sent on start", (function()
    for _, c in ipairs(sentToServer) do if c.remote == "RequestState" then return true end end
    return false
end)())

-- 1) الزر يفتح اللوحة ويقفلها
floatButton.Activated:Fire()
check("float button opens the panel", panel.Visible == true)
floatButton.Activated:Fire()
check("float button closes the panel again", panel.Visible == false)

-- 2) بدون قناة: الواجهة تقول ادخل من الموقع، والتحدث ما يرسل شيء
check("no channel shows 'enter from website' hint", talkButton.Text == "ادخل قناة من الموقع أولاً")
check("channel label shows empty channel", channelLabel.Text == "Channel --")
pressKey("CapsLock")
check("PTT without channel sends nothing", lastTalk() == nil)
releaseKey("CapsLock")

-- 3) الموقع دخّل اللاعب القناة 2 (تصل عبر Attribute من السيرفر)
player:SetAttribute("RadioChannel", 2)
check("channel attribute updates the label", channelLabel.Text == "Channel 2")
check("LED turns green when in a channel", led.BackgroundColor3[2] == 190)
check("talk button invites to talk", talkButton.Text == "PTT  -  اضغط للتحدث")

-- 4) PTT بالكيبورد يرسل الحالة للسيرفر
pressKey("CapsLock")
check("CapsLock down starts talking", lastTalk() == true)
releaseKey("CapsLock")
check("CapsLock up stops talking", lastTalk() == false)

-- 5) PTT بالزر (لمس) ورفع الإصبع في أي مكان
talkButton.InputBegan:Fire({ UserInputType = "Touch" })
check("touch on PTT starts talking", lastTalk() == true)
uis.InputEnded:Fire({ UserInputType = "Touch" })
check("lifting finger anywhere stops talking", lastTalk() == false)

-- 6) الموقع يقول إن اللاعب يتحدث: الزر يعكس الحالة
player:SetAttribute("RadioTalking", true)
check("server talking state shows on the button", talkButton.Text == "تتحدث الآن")
player:SetAttribute("RadioTalking", false)

-- 7) إغلاق اللوحة وأنت تتحدث يوقف التحدث
floatButton.Activated:Fire()
talkButton.InputBegan:Fire({ UserInputType = "Touch" })
closeButton.Activated:Fire()
check("closing the panel while talking stops the mic", lastTalk() == false)
uis.InputEnded:Fire({ UserInputType = "Touch" })
check("panel is hidden after close", panel.Visible == false)

-- 8) فقدان التركيز يوقف التحدث
floatButton.Activated:Fire()
pressKey("CapsLock")
uis.WindowFocusReleased:Fire()
check("window focus lost stops talking", lastTalk() == false)
releaseKey("CapsLock")

-- 9) الموقع فصل اللاعب (القناة null): التحدث يتوقف وما يرسل بعدها
pressKey("CapsLock")
player:SetAttribute("RadioChannel", nil)
check("leaving the channel stops talking", lastTalk() == false)
check("hint returns when channel is gone", talkButton.Text == "ادخل قناة من الموقع أولاً")
releaseKey("CapsLock")
local stillBefore = talkSends(true)
pressKey("CapsLock")
check("no talk is sent after the channel is gone", talkSends(true) == stillBefore)
releaseKey("CapsLock")

-- 10) الرسائل من السيرفر تظهر في الحالة
player:SetAttribute("RadioChannel", 4)
serverSays(4, false, "متصل بالقناة 4")
check("server message shows in the status line", statusLabel.Text == "متصل بالقناة 4")
serverSays(nil, false, "ادخل قناة من الموقع أولاً")
check("server message on leaving shows in the status line", statusLabel.Text == "ادخل قناة من الموقع أولاً")

-- 11) إعادة الظهور: الزر يطلب الحالة من السيرفر من جديد
player:SetAttribute("RadioChannel", 2)
local requestsBefore = 0
for _, c in ipairs(sentToServer) do if c.remote == "RequestState" then requestsBefore = requestsBefore + 1 end end
local character = newInstance("Model")
character.WaitForChild = function(_, n) return nil end
player.CharacterAdded:Fire(character)
local requestsAfter = 0
for _, c in ipairs(sentToServer) do if c.remote == "RequestState" then requestsAfter = requestsAfter + 1 end end
check("respawn asks the server for the current state", requestsAfter == requestsBefore + 1)
check("channel survives respawn (attribute-based)", channelLabel.Text == "Channel 2")

-- 12) الحالة النهائية: لا تحدث عالق
releaseKey("CapsLock")
uis.InputEnded:Fire({ UserInputType = "Touch" })
check("never ends in a talking state after releasing everything", lastTalk() ~= true)

print(string.format("\n%d passed, %d failed", passes, failures))
os.exit(failures == 0 and 0 or 1)
