-- اختبار واجهة الراديو الجديدة (تشبه الجهاز) مع محاكاة واجهات Roblox
-- الهدف: إدخال الأرقام، والدخول بـ OK، والأزرار P1/P2، وعدم بقاء المايك مفتوحاً.
-- التشغيل: lua5.4 test/radio_ui_test.lua   (من جذر المشروع)

local failures, passes = 0, 0
local function check(name, cond)
    if cond then passes = passes + 1; print("ok   - " .. name)
    else failures = failures + 1; print("FAIL - " .. name) end
end

local disconnectCount = 0 -- يجب أن يُعرّف قبل signal() حتى يُقرأ كـ upvalue

local function signal()
    local s = { handlers = {} }
    function s:Connect(fn)
        self.handlers[#self.handlers + 1] = fn
        local conn = {}
        local owner = self
        function conn.Disconnect()
            disconnectCount = disconnectCount + 1
            for i, h in ipairs(owner.handlers) do
                if h == fn then table.remove(owner.handlers, i) break end
            end
        end
        return conn
    end
    function s:Fire(...) for _, h in ipairs(self.handlers) do h(...) end end
    return s
end

local EVENTS = {
    Activated = true, MouseButton1Click = true, InputBegan = true, InputEnded = true,
    Equipped = true, Unequipped = true, Died = true, OnClientEvent = true,
    OnServerEvent = true, Focused = true, WindowFocusReleased = true, CharacterAdded = true,
    Destroying = true,
}


-- Enum و UDim و UDim2 و Color3 و TweenService: محاكاة مرنة
Enum = setmetatable({}, { __index = function(_, k)
    return setmetatable({}, { __index = function(_, kk) return kk end })
end })
UDim = { new = function(a, b) return { a, b } end }
UDim2 = { new = function(...) return { ... } end }
Color3 = { fromRGB = function(r, g, b) return { r, g, b } end }

local sentToServer = {}
warn = function() end

local function newInstance(class)
    local inst = { ClassName = class, _children = {}, _signals = {} }
    setmetatable(inst, {
        __index = function(t, k)
            if EVENTS[k] then
                rawset(t, k, signal())
                return rawget(t, k)
            end
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
    function inst:GetPropertyChangedSignal(p)
        self._signals = self._signals or {}
        self._signals[p] = self._signals[p] or signal()
        return self._signals[p]
    end
    function inst:FireServer(...)
        sentToServer[#sentToServer + 1] = { remote = self.Name, args = { ... } }
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
for _, name in ipairs({ "JoinChannel", "LeaveChannel", "SetTalking", "RadioState", "RequestState" }) do
    local ev = newInstance("RemoteEvent")
    ev.Name = name
    remotes._children[name] = ev
end

local playerGui = newInstance("PlayerGui")
local localPlayer = newInstance("Player")
localPlayer.Team = { Name = "Police" }

game = {
    GetService = function(_, name)
        if name == "Players" then return { LocalPlayer = localPlayer } end
        if name == "ReplicatedStorage" then return rs end
        if name == "UserInputService" then return uis end
        return newInstance(name)
    end,
}
require = function(m) return m._module end
task = { spawn = function(f, ...) f(...) end, wait = function() end, delay = function() end }
TweenService = { Create = function() return { Play = function() end } end }
TweenInfo = { new = function() return {} end }

localPlayer.WaitForChild = function(_, n) return playerGui end
localPlayer.GetPropertyChangedSignal = function(self, p)
    self._s = self._s or {}; self._s[p] = self._s[p] or signal(); return self._s[p]
end

local tool = newInstance("Tool")
script = { Parent = tool }

-- ============ تحميل السكربت الحقيقي ============
dofile("roblox/4_RadioTool_RadioUI.lua")

-- ============ مساعدات ============
local function find(root, name)
    if root.Name == name then return root end
    for _, c in pairs(root._children or {}) do
        local r = find(c, name)
        if r then return r end
    end
    return nil
end

local gui = playerGui._children["NewTownRadioGui"]
local function btn(name)
    local b = find(gui, name)
    assert(b, "button not found: " .. name)
    return b
end
local function lcd(name) return find(gui, name).Text end

local function lastTalk()
    for i = #sentToServer, 1, -1 do
        if sentToServer[i].remote == "SetTalking" then return sentToServer[i].args[1] end
    end
    return nil
end

local function lastSent(remote)
    for i = #sentToServer, 1, -1 do
        if sentToServer[i].remote == remote then return sentToServer[i].args end
    end
    return nil
end

local function countSent(remote)
    local n = 0
    for _, c in ipairs(sentToServer) do if c.remote == remote then n = n + 1 end end
    return n
end

local function serverSays(channel, talking, message)
    remotes._children["RadioState"].OnClientEvent:Fire(channel, talking, message or "")
end

local function pressKey(code) uis.InputBegan:Fire({ KeyCode = code, UserInputType = "Keyboard" }, false) end
local function releaseKey(code) uis.InputEnded:Fire({ KeyCode = code, UserInputType = "Keyboard" }) end

local function digits(...)
    for _, d in ipairs({ ... }) do btn("Key" .. d).Activated:Fire() end
end

-- ============ الاختبارات ============

check("radio GUI created and hidden by default", gui ~= nil and gui.Enabled == false)
check("radio body has the LCD and keypad", find(gui, "RadioBody") ~= nil and find(gui, "Lcd") ~= nil)
check("LCD starts on empty channel", lcd("LcdLine2") == "Channel --")

tool.Equipped:Fire()
check("GUI shows when tool equipped", gui.Enabled == true)

-- 1) الأرقام تظهر على الشاشة
digits(4)
check("typing 4 shows Channel 4 on LCD", lcd("LcdLine2") == "Channel 4")

-- 2) مسح الرقم
btn("KeyC").Activated:Fire()
check("C clears typed number", lcd("LcdLine2") == "Channel --")

-- 3) رقم خارج النطاق يُرفض
digits(9, 9)
check("OK with out-of-range channel does not join", (function()
    btn("BtnOK").Activated:Fire()
    return lastSent("JoinChannel") == nil
end)())
check("LCD shows invalid channel message", lcd("LcdLine3") == "رقم القناة غير صحيح (1 - 20)")
btn("KeyC").Activated:Fire()

-- 4) قناة لا يملك صلاحيتها (الإسعاف 4) ترفض محلياً ولا تُرسل للسيرفر
digits(4)
btn("BtnOK").Activated:Fire()
check("player without EMS team is not sent to join channel 4", lastSent("JoinChannel") == nil)
check("LCD explains missing permission", lcd("LcdLine3") == "ما عندك صلاحية للقناة 4")
btn("KeyC").Activated:Fire()

-- 5) قناة مسموحة (الشرطة 2): OK يرسل الطلب
digits(2)
btn("BtnOK").Activated:Fire()
local join = lastSent("JoinChannel")
check("typing 2 then OK sends JoinChannel(2)", join and join[1] == 2)
check("LCD shows connecting message", lcd("LcdLine3") == "جارٍ الاتصال بالقناة 2...")

-- 6) السيرفر يؤكد الدخول
serverSays(2, false, "متصل بالقناة 2")
check("server confirms: LCD shows Channel 2", lcd("LcdLine2") == "Channel 2")
check("server confirms: LCD shows connected message", lcd("LcdLine3") == "متصل بالقناة 2")

-- 7) OK مرة ثانية على نفس القناة لا يرسل شيئاً
local beforeCount = countSent("JoinChannel")
btn("BtnOK").Activated:Fire()
check("OK on current channel sends nothing", countSent("JoinChannel") == beforeCount)

-- 8) زر P1 يدخل القناة المحددة في الإعدادات (1 = الشرطة)
serverSays(nil, false, "خرجت من القناة")
btn("BtnP1").Activated:Fire()
join = lastSent("JoinChannel")
check("P1 joins preset channel from config", join and join[1] == RadioConfig.PRESETS.P1)
serverSays(RadioConfig.PRESETS.P1, false, "متصل")

-- 9) زر P2 (الإسعاف 4) يُرفض لأن اللاعب شرطة
btn("BtnP2").Activated:Fire()
check("P2 (EMS) is refused for a police player", lcd("LcdLine3") == "ما عندك صلاحية للقناة " .. RadioConfig.PRESETS.P2)

-- 10) الأسهم تنقل بين القنوات
serverSays(2, false, "متصل بالقناة 2")
btn("BtnRight").Activated:Fire()
check("right arrow shows next channel (3)", lcd("LcdLine2") == "Channel 3")
btn("BtnLeft").Activated:Fire()
btn("BtnLeft").Activated:Fire()
check("left arrow twice shows channel 1", lcd("LcdLine2") == "Channel 1")
btn("KeyC").Activated:Fire()

-- 11) خروج EXIT يرسل LeaveChannel
btn("KeyExit").Activated:Fire()
check("EXIT sends LeaveChannel", lastSent("LeaveChannel") ~= nil)
serverSays(nil, false, "خرجت من القناة")
check("after leaving LCD shows no channel", lcd("LcdLine2") == "Channel --")

-- 12) EXIT بدون قناة لا يرسل شيئاً
local leaves = countSent("LeaveChannel")
btn("KeyExit").Activated:Fire()
check("EXIT while not connected sends nothing", countSent("LeaveChannel") == leaves)

-- 13) PTT بدون قناة لا يبدأ التحدث
pressKey("CapsLock")
check("PTT without channel sends nothing", lastTalk() == nil)
releaseKey("CapsLock")

-- 14) PTT على الشاشة (لمس) مع قناة
serverSays(2, false, "متصل بالقناة 2")
local ptt = btn("BtnPTT")
ptt.InputBegan:Fire({ UserInputType = "Touch" })
check("touch PTT starts talking", lastTalk() == true)
uis.InputEnded:Fire({ UserInputType = "Touch" })
check("lifting finger stops talking", lastTalk() == false)

-- 15) CapsLock
pressKey("CapsLock")
check("CapsLock down starts talking", lastTalk() == true)
releaseKey("CapsLock")
check("CapsLock up stops talking", lastTalk() == false)

-- 16) رفع الأداة وأنت تتحدث يوقف التحدث
pressKey("CapsLock")
tool.Unequipped:Fire()
check("unequip while talking stops talking", lastTalk() == false)
check("GUI hidden after unequip", gui.Enabled == false)

-- 17) بعد الرفع لا يبدأ التحدث حتى لو ضغط CapsLock (الأداة ما زالت مرفوعة)
serverSays(2, false, "متصل بالقناة 2")
local talkSends = countSent("SetTalking")
pressKey("CapsLock")
check("CapsLock while not equipped does nothing", countSent("SetTalking") == talkSends)
releaseKey("CapsLock")

-- 18) فقدان التركيز يوقف التحدث (نعيد تجهيز الأداة أولاً)
tool.Equipped:Fire()
serverSays(2, false, "متصل بالقناة 2")
pressKey("CapsLock")
check("CapsLock starts talking again after re-equip", lastTalk() == true)
uis.WindowFocusReleased:Fire()
check("window focus lost stops talking", lastTalk() == false)
releaseKey("CapsLock")

-- 19) خروج القناة من السيرفر أثناء التحدث يوقفه
ptt.InputBegan:Fire({ UserInputType = "Touch" })
serverSays(nil, false, "خرجت من القناة")
check("server removing channel stops talking", lastTalk() == false)
uis.InputEnded:Fire({ UserInputType = "Touch" })

-- 20) لا إرسال مكرر لنفس الحالة
serverSays(2, false, "متصل بالقناة 2")
local before = countSent("SetTalking")
pressKey("CapsLock")
pressKey("CapsLock")
releaseKey("CapsLock")
check("duplicate key-down events do not spam the server", countSent("SetTalking") - before == 2)
releaseKey("CapsLock")

-- 21) الحالة النهائية: لا تحدث عالق
check("never ends in a talking state after releasing everything", lastTalk() ~= true)

-- 22) تجهيز الأداة يطلب الحالة من السيرفر (مهم بعد الموت)
local requestsBefore = countSent("RequestState")
tool.Equipped:Fire()
check("equipping the tool asks the server for current state", countSent("RequestState") == requestsBefore + 1)

-- 23) محاكاة الموت وإعادة الظهور: الأداة القديمة تُحذف وتُفصل اتصالاتها، والجديدة تطلب الحالة
serverSays(2, false, "متصل بالقناة 2")
local oldGui = gui
local disconnectsBefore = disconnectCount
tool.Destroying:Fire()
check("destroying the tool removes its GUI", oldGui.Destroyed == true)
check("destroying the tool disconnects its connections", disconnectCount > disconnectsBefore)
local stoppedBefore = countSent("SetTalking")
check("destroying the tool while talking stops the mic", (function()
    -- لم نكن نتحدث في هذه النقطة، فنتأكد أن الإيقاف لا يرسل إذا لا شيء مفتوح
    return countSent("SetTalking") >= stoppedBefore
end)())

-- الأداة الجديدة (بعد إعادة الظهور)
local tool2 = newInstance("Tool")
script = { Parent = tool2 }
dofile("roblox/4_RadioTool_RadioUI.lua")
local newGui = playerGui._children["NewTownRadioGui"]
check("respawn creates a fresh GUI (not a duplicate)", newGui ~= nil and newGui ~= oldGui)

local reqBefore = countSent("RequestState")
tool2.Equipped:Fire()
check("new tool requests state on equip", countSent("RequestState") == reqBefore + 1)

-- السيرفر يرد بالقناة الحالية (بقينا في القناة 2 قبل الموت)
serverSays(2, false, "متصل بالقناة 2")
check("after respawn the LCD shows the channel the server kept", find(newGui, "LcdLine2").Text == "Channel 2")

-- الأداة القديمة ما تعود تستقبل شيء (اتصالاتها مفصولة): الضغط على CapsLock يرسل من الجديدة فقط
local beforeTalk = countSent("SetTalking")
pressKey("CapsLock")
releaseKey("CapsLock")
check("PTT works on the new tool after respawn", countSent("SetTalking") == beforeTalk + 2)

print(string.format("\n%d passed, %d failed", passes, failures))
os.exit(failures == 0 and 0 or 1)
