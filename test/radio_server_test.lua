-- اختبار سكربت RadioManager الحقيقي مع محاكاة واجهات Roblox
-- التشغيل: lua5.4 test/radio_server_test.lua   (من جذر المشروع)

local failures, passes = 0, 0
local function check(name, cond)
    if cond then
        passes = passes + 1
        print("ok   - " .. name)
    else
        failures = failures + 1
        print("FAIL - " .. name)
    end
end

-- ============ محاكاة Roblox ============
local function signal()
    local s = { handlers = {} }
    function s:Connect(fn)
        self.handlers[#self.handlers + 1] = fn
        return { Disconnect = function() end }
    end
    function s:Fire(...)
        for _, h in ipairs(self.handlers) do h(...) end
    end
    return s
end

local fired = {}          -- رسائل FireClient
local backendCalls = {}   -- طلبات HttpService
local warnings = {}
warn = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    warnings[#warnings + 1] = table.concat(parts, " ")
end

local function newInstance(class)
    local inst = { ClassName = class, _children = {}, _signals = {} }
    inst.OnServerEvent = signal()
    inst.OnClientEvent = signal()
    setmetatable(inst, {
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
        self._signals[p] = self._signals[p] or signal()
        return self._signals[p]
    end
    function inst:FireClient(player, ...)
        fired[#fired + 1] = { remote = self.Name, player = player, args = { ... } }
    end
    return inst
end

Instance = { new = newInstance }

Enum = { KeyCode = { CapsLock = "CapsLock" } }

local rs = newInstance("ReplicatedStorage")
local radioConfigPath = "roblox/RadioConfig.lua"
local RadioConfigModule = dofile(radioConfigPath)
rs._children["RadioConfig"] = { _module = RadioConfigModule }

local playersSvc = { PlayerAdded = signal(), PlayerRemoving = signal() }
function playersSvc:GetPlayers() return {} end

local httpSvc = {}
function httpSvc:JSONEncode(t) return t end
function httpSvc:RequestAsync(req)
    backendCalls[#backendCalls + 1] = req
    return { Success = true, StatusCode = 200, Body = "{}" }
end

local services = {
    Players = playersSvc,
    ReplicatedStorage = rs,
    HttpService = httpSvc,
}
game = { GetService = function(_, name) return services[name] end }

require = function(m) return m._module end
task = {
    spawn = function(f, ...) f(...) end,
    wait = function() end,
    delay = function() end,
}

-- ============ تحميل السكربت الحقيقي ============
dofile("roblox/3_ServerScriptService_RadioManager.lua")

local remotes = rs._children["RadioRemotes"]
assert(remotes, "RadioRemotes folder not created")
local JoinChannel = remotes._children["JoinChannel"]
local LeaveChannel = remotes._children["LeaveChannel"]
local SetTalking = remotes._children["SetTalking"]

-- ============ مساعدات ============
local POLICE = { Name = "Police" }
local CIVIL = { Name = "Civilian" }
local EMS = { Name = "EMS" }

local function makePlayer(id, team)
    local p = { UserId = id, Name = "P" .. id, Team = team, CharacterAdded = signal() }
    p.GetPropertyChangedSignal = function(self, prop)
        self._signals = self._signals or {}
        self._signals[prop] = self._signals[prop] or signal()
        return self._signals[prop]
    end
    playersSvc.PlayerAdded:Fire(p)
    return p
end

local function lastMessage(p)
    for i = #fired, 1, -1 do
        if fired[i].player == p then return fired[i].args end
    end
    return nil
end

local function lastBackendFor(userId)
    for i = #backendCalls, 1, -1 do
        if backendCalls[i].Body and backendCalls[i].Body.userId == userId then
            return backendCalls[i].Body
        end
    end
    return nil
end

local function busyWait(seconds)
    local t = os.clock()
    while os.clock() - t < seconds do end
end

-- ============ الاختبارات ============
local police = makePlayer(1, POLICE)
local civil = makePlayer(2, CIVIL)
local medic = makePlayer(3, EMS)
local noTeam = makePlayer(4, nil)

-- 1) تيم الشرطة يدخل القناة 2
JoinChannel.OnServerEvent:Fire(police, 2)
local m = lastMessage(police)
check("police joins channel 2", m and m[1] == 2 and m[2] == false and m[3] == "متصل بالقناة 2")
check("join sends channel to backend", lastBackendFor(1) and lastBackendFor(1).channel == 2)

-- 2) مدني يحاول دخول قناة الشرطة
busyWait(0.6)
JoinChannel.OnServerEvent:Fire(civil, 2)
m = lastMessage(civil)
check("civilian denied on police channel 2", m and m[1] == nil and m[3] == "ما عندك صلاحية لهذه القناة")

-- 3) الإسعاف يدخل القناة 4، والشرطة تُمنع منها
busyWait(0.6)
JoinChannel.OnServerEvent:Fire(medic, 4)
m = lastMessage(medic)
check("EMS joins channel 4", m and m[1] == 4)
busyWait(0.6)
JoinChannel.OnServerEvent:Fire(police, 4)
m = lastMessage(police)
check("police denied on EMS channel 4", m and m[1] == 2 and m[3] == "ما عندك صلاحية لهذه القناة")

-- 4) القناة 6 مفتوحة لأي لاعب (بما فيهم بدون تيم)
busyWait(0.6)
JoinChannel.OnServerEvent:Fire(civil, 6)
m = lastMessage(civil)
check("civilian joins open channel 6", m and m[1] == 6)
busyWait(0.6)
JoinChannel.OnServerEvent:Fire(noTeam, 6)
m = lastMessage(noTeam)
check("player without team joins open channel 6", m and m[1] == 6)
busyWait(0.6)
JoinChannel.OnServerEvent:Fire(noTeam, 1)
m = lastMessage(noTeam)
check("player without team denied on channel 1", m and m[3] == "ما عندك صلاحية لهذه القناة")

-- 5) أرقام غير صحيحة
local invalid = { 0, 21, 2.5, "police", -1, 0 / 0 }
local allInvalid = true
for _, v in ipairs(invalid) do
    busyWait(0.6)
    JoinChannel.OnServerEvent:Fire(civil, v)
    local msg = lastMessage(civil)
    if not (msg and msg[3] == "رقم القناة غير صحيح") then
        allInvalid = false
        print("   value rejected incorrectly: " .. tostring(v))
    end
end
check("invalid channel values are rejected (0, 21, 2.5, string, -1, NaN)", allInvalid)

-- 6) التحدث
local idle = makePlayer(5, nil) -- لم ينضم لأي قناة
SetTalking.OnServerEvent:Fire(idle, true)
m = lastMessage(idle)
check("talk without channel is refused", m and m[3] == "اختر قناة أولاً")

busyWait(0.2)
SetTalking.OnServerEvent:Fire(police, true)
m = lastMessage(police)
check("police starts talking on channel 2", m and m[1] == 2 and m[2] == true)
check("talking state sent to backend", lastBackendFor(1) and lastBackendFor(1).talking == true)

busyWait(0.2)
SetTalking.OnServerEvent:Fire(police, false)
m = lastMessage(police)
check("police stops talking", m and m[2] == false)

-- 7) إيقاف التحدث دائماً مسموح حتى لو الطلبات متتالية بسرعة
busyWait(0.2)
SetTalking.OnServerEvent:Fire(police, true)
SetTalking.OnServerEvent:Fire(police, false)
m = lastMessage(police)
check("stop talking is never rate-limited", m and m[2] == false)

-- 8) تغيير التيم أثناء القناة يُخرج اللاعب
busyWait(0.2)
police.Team = CIVIL
police:GetPropertyChangedSignal("Team"):Fire()
m = lastMessage(police)
check("team change removes player from restricted channel", m and m[1] == nil
    and m[3] == "تم إخراجك من القناة لأن تيمك تغيّر")
local b = lastBackendFor(1)
check("backend told player left (no channel key)", b and b.channel == nil and b.talking == false)

-- 9) تغيير التيم في قناة مفتوحة لا يُخرج اللاعب
busyWait(0.6)
civil.Team = POLICE
JoinChannel.OnServerEvent:Fire(civil, 6)
civil.Team = EMS
civil:GetPropertyChangedSignal("Team"):Fire()
m = lastMessage(civil)
check("team change keeps player in open channel 6", m and m[1] == 6)

-- 10) الرد دائماً حتى مع Rate limit (الواجهة لا تنتظر للأبد)
busyWait(0.6)
JoinChannel.OnServerEvent:Fire(medic, 4)
JoinChannel.OnServerEvent:Fire(medic, 4)
m = lastMessage(medic)
check("rate-limited join still gets a reply", m and m[3] == "انتظر لحظة ثم حاول مرة ثانية")

-- 11) مغادرة القناة
busyWait(0.6)
LeaveChannel.OnServerEvent:Fire(medic)
m = lastMessage(medic)
check("leave channel clears channel", m and m[1] == nil and m[3] == "خرجت من القناة")

-- 12) لا أخطاء تحذير غير متوقعة
check("no unexpected backend warnings", #warnings == 0)

print(string.format("\n%d passed, %d failed", passes, failures))
os.exit(failures == 0 and 0 or 1)
