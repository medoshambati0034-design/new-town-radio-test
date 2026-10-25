-- اختبار سكربت RadioManager الحقيقي مع محاكاة واجهات Roblox
-- التشغيل: lua5.4 test/radio_manager_test.lua   (من جذر المشروع)

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

local fired, requests, warnings = {}, {}, {}
local responses = {}   -- الرد المحاكى لكل endpoint
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
    function inst:FireClient(player, ...)
        fired[#fired + 1] = { remote = self.Name, player = player, args = { ... } }
    end
    return inst
end
Instance = { new = newInstance }
Enum = { KeyCode = { CapsLock = "CapsLock" } } -- يحتاجه RadioConfig

local rs = newInstance("ReplicatedStorage")
local RadioConfigModule = dofile("roblox/RadioConfig.lua")
rs._children["RadioConfig"] = { _module = RadioConfigModule }
require = function(m) return m._module end

local playersSvc = { PlayerAdded = signal(), PlayerRemoving = signal() }
function playersSvc:GetPlayers() return {} end

local existingTeams = MOCK_TEAMS or { "Police", "EMS" } -- عمداً بدون Justice لاختبار التحذير
local teamsSvc = {}
function teamsSvc:GetTeams()
    local list = {}
    for _, name in ipairs(existingTeams) do list[#list + 1] = { Name = name } end
    return list
end

local httpSvc = {}
function httpSvc:JSONEncode(t) return t end
function httpSvc:JSONDecode(t) return t end
function httpSvc:RequestAsync(req)
    requests[#requests + 1] = req
    local endpoint = req.Url:gsub("^.-(/api/)", "%1")
    local body = responses[endpoint] or {}
    local status = body.__status or 200
    if body.__status then body.__status = nil end
    return { Success = status < 400, StatusCode = status, Body = body }
end

services = {
    Players = playersSvc,
    ReplicatedStorage = rs,
    HttpService = httpSvc,
    Teams = teamsSvc,
}
game = { GetService = function(_, name) return services[name] end }
task = {
    spawn = function(f, ...) f(...) end,
    wait = function() end,
    delay = function() end,
}

dofile("roblox/3_ServerScriptService_RadioManager.lua")

local remotes = rs._children["RadioRemotes"]
local SetTalking = remotes._children["SetTalking"]
local RadioState = remotes._children["RadioState"]
local RequestState = remotes._children["RequestState"]

-- ============ مساعدات ============
local function makePlayer(id, team)
    local attrs = {}
    local p = { UserId = id, Name = "P" .. id, Team = team }
    function p:SetAttribute(k, v) attrs[k] = v end
    function p:GetAttribute(k) return attrs[k] end
    function p:GetPropertyChangedSignal(prop)
        self._s = self._s or {}
        self._s[prop] = self._s[prop] or signal()
        return self._s[prop]
    end
    playersSvc.PlayerAdded:Fire(p)
    return p
end

local function lastState(p)
    for i = #fired, 1, -1 do
        if fired[i].remote == "RadioState" and fired[i].player == p then return fired[i].args end
    end
end

local function requestsTo(endpoint)
    local out = {}
    for _, r in ipairs(requests) do
        if r.Url:find(endpoint, 1, true) then out[#out + 1] = r end
    end
    return out
end

local function busyWait(seconds)
    local t = os.clock()
    while os.clock() - t < seconds do end
end

-- ============ الاختبارات ============
local cop = makePlayer(1, { Name = "Police" })

-- 1) تيم اللاعب يُرسل عند تغييره
cop.Team = { Name = "EMS" }
cop:GetPropertyChangedSignal("Team"):Fire()
local teamReq = requestsTo("/api/radio/team")
check("team change is sent to the backend", #teamReq >= 1)
check("team name is sent correctly", #teamReq >= 1 and teamReq[#teamReq].Body.team == "EMS")

-- 2) بدون قناة من الموقع: زر التحدث يرفض ولا يتصل بالسيرفر
local before = #requestsTo("/api/radio/talk")
SetTalking.OnServerEvent:Fire(cop, true)
check("talk without a website channel is refused locally", #requestsTo("/api/radio/talk") == before)
check("player sees 'choose a channel on the website' message",
    lastState(cop) and lastState(cop)[3] == "ادخل قناة من الموقع أولاً")

-- 3) الموقع دخّل اللاعب القناة 2 (يصل عبر position update): زر التحدث يعمل
cop:SetAttribute("RadioChannel", 2)
responses["/api/radio/talk"] = { channel = 2, talking = true }
SetTalking.OnServerEvent:Fire(cop, true)
local talkReq = requestsTo("/api/radio/talk")
check("talk with a channel is relayed to the backend",
    #talkReq >= 1 and talkReq[#talkReq].Body.talking == true)
check("talk state is published to the player", cop:GetAttribute("RadioTalking") == true)
check("player is told talking started on channel 2", lastState(cop)[1] == 2 and lastState(cop)[2] == true)

-- 4) إيقاف التحدث دائماً مرسل، حتى لو الطلبات متتالية بسرعة
responses["/api/radio/talk"] = { channel = 2, talking = false }
local stopsBefore = #requestsTo("/api/radio/talk")
SetTalking.OnServerEvent:Fire(cop, false)
SetTalking.OnServerEvent:Fire(cop, false)
check("stop talking is never rate-limited", #requestsTo("/api/radio/talk") - stopsBefore == 2)
check("talking is cleared on the player", cop:GetAttribute("RadioTalking") == false)

-- 5) حد الطلبات على بدء التحدث
busyWait(0.2)
responses["/api/radio/talk"] = { channel = 2, talking = true }
local startsBefore = #requestsTo("/api/radio/talk")
SetTalking.OnServerEvent:Fire(cop, true)
SetTalking.OnServerEvent:Fire(cop, true)
check("rapid repeated talk starts are rate-limited", #requestsTo("/api/radio/talk") - startsBefore == 1)

-- 6) الموقع فصل اللاعب من القناة: الـ Backend يرجع null
responses["/api/radio/talk"] = { channel = nil, talking = false }
busyWait(0.2)
SetTalking.OnServerEvent:Fire(cop, true)
check("backend says no channel: attribute cleared", cop:GetAttribute("RadioChannel") == nil)
check("backend says no channel: player told to join from website",
    lastState(cop)[3] == "ادخل قناة من الموقع أولاً")

-- 7) اللاعب غير مربوط بالموقع (404)
cop:SetAttribute("RadioChannel", 2)
responses["/api/radio/talk"] = { __status = 404 }
busyWait(0.2)
SetTalking.OnServerEvent:Fire(cop, true)
check("unlinked player gets a clear message", lastState(cop)[3] == "غير مربوط بالموقع بعد")
check("unlinked player's channel attribute is cleared", cop:GetAttribute("RadioChannel") == nil)

-- 8) طلب الحالة بعد إعادة الظهور يرجّع القناة الحالية
local other = makePlayer(2, { Name = "EMS" })
other:SetAttribute("RadioChannel", 4)
RequestState.OnServerEvent:Fire(other)
check("RequestState returns the current channel",
    lastState(other)[1] == 4 and lastState(other)[3] == "متصل بالقناة 4")

-- 9) قيم غير صحيحة من الكلاينت لا تسبب شيء
local bad = makePlayer(3, nil)
bad:SetAttribute("RadioChannel", 2)
local badBefore = #requests
SetTalking.OnServerEvent:Fire(bad, "yes")
check("non-boolean talk value is ignored", #requests == badBefore)

-- 10) تحذير التيم الناقص (Justice غير موجود في هذا الاختبار)
check("missing team name produces a warning", (function()
    for _, w in ipairs(warnings) do
        if w:find("Justice") and w:find("غير موجود") then return true end
    end
    return false
end)())

print(string.format("\n%d passed, %d failed", passes, failures))
os.exit(failures == 0 and 0 or 1)
