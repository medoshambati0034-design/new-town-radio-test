--[[
    اسم السكربت: RadioConfig
    النوع: ModuleScript
    المكان: ReplicatedStorage  (اسمه بالضبط RadioConfig)

    هذا الملف يحدد القنوات وتيماتها. السيرفر هو اللي يطبّق الصلاحيات،
    والواجهة تستخدم نفس الملف فقط لعرض التلميحات.

    مهم: أسماء التيمات أدناه افتراضية. غيّرها لأسماء التيمات الحقيقية
    الموجودة في Teams service بالضبط (حساسة لحروف الكبيرة والصغيرة).
]]

local RadioConfig = {}

-- أعلى رقم قناة مسموح. يجب أن يطابق MAX_RADIO_CHANNEL في السيرفر (20).
RadioConfig.MAX_CHANNEL = 20

-- القنوات المقيّدة. أي قناة غير مذكورة هنا (من 6 فما فوق) مفتوحة للجميع.
-- teams = قائمة أسماء التيمات المسموح لها بالقناة.
RadioConfig.CHANNELS = {
    [1] = { teams = { "Police" } }, -- غيّر "Police" لاسم تيم الشرطة الحقيقي
    [2] = { teams = { "Police" } },
    [3] = { teams = { "Police" } },
    [4] = { teams = { "EMS" } },    -- غيّر "EMS" لاسم تيم الإسعاف
    [5] = { teams = { "Justice" } }, -- غيّر "Justice" لاسم تيم وزارة العدل
}

-- أزرار P1 و P2 في الجهاز: كل زر ينتقل لقناة محددة بضغطة واحدة
RadioConfig.PRESETS = {
    P1 = 1, -- الشرطة
    P2 = 4, -- الإسعاف
}

-- زر التحدث على الكمبيوتر. يمكن تغييره لأي Enum.KeyCode.
RadioConfig.PTT_KEY = Enum.KeyCode.CapsLock

-- اسم الأداة في StarterPack
RadioConfig.TOOL_NAME = "NewTownRadio"

-- اسم مجلد الأحداث داخل ReplicatedStorage
RadioConfig.REMOTES_FOLDER = "RadioRemotes"

-- يرجّع قواعد القناة، أو nil إذا القناة مفتوحة للجميع
function RadioConfig.getRule(channel)
    return RadioConfig.CHANNELS[channel]
end

return RadioConfig
