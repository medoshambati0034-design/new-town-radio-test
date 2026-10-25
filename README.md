# New Town Voice — مايك القرب لروبلكس

اللاعب يدخل الماب، يطلع له **رابط** يحدده وينسخه، يفتحه في Chrome أو Safari، يضغط **تفعيل المايك**، وخلاص. ما فيه أي كود يكتبه يدوياً.

## كيف يشتغل

1. اللاعب يدخل اللعبة، وسكربت السيرفر يطلب رابطاً من الخادم (مرتبط بـ UserId اللاعب).
2. الرابط يظهر في الواجهة داخل مربع نص، واللاعب يحدده وينسخه.
3. الرابط يفتح صفحة فيها اسم الحساب وزر **تفعيل المايك**.
4. عند الضغط، الرابط يصير مستخدماً (لا يشتغل مرة ثانية)، ويتربط المتصفح بجلسة اللاعب عبر كوكي آمن.
5. اللعبة تعرف أن الربط تم، وتعرض "المايك مربوط ✓".

**ملاحظة مهمة:** هذا الصوت قناة منفصلة خارج Roblox. الموقع لا يقدر يفعّل مايك Roblox الرسمي (Voice Chat)، ولا يغيّر إعداداته.

## البنية

```
new-town-voice/
  server/
    server.js      نقطة التشغيل (يقرأ الإعدادات من البيئة)
    app.js         الـ API والـ WebSocket وترويسات الأمان
    store.js       الروابط والجلسات (في الذاكرة، مع انتهاء صلاحية)
  public/
    index.html     صفحة التفعيل والموقع (نفس تصميم New Town)
    assets/        الصور
  roblox/
    1_ServerScriptService_VoiceLinkManager.lua   Script داخل ServerScriptService
    2_StarterPlayerScripts_VoiceLinkUI.lua       LocalScript داخل StarterPlayerScripts
  test/api.test.js  اختبارات (التفعيل، الصلاحية، المصادقة، WebSocket، السجلات)
  render.yaml       إعداد النشر على Render
```

## التشغيل المحلي (للتجربة)

```bash
npm ci
API_KEY=$(openssl rand -hex 32) LOCAL_DEV=1 PORT=3000 PUBLIC_BASE_URL=http://localhost:3000 npm start
```

ثم افتح `http://localhost:3000/api/health` وينبغي أن يرجع `{"ok":true}`.

تشغيل الاختبارات:

```bash
npm test
```

## النشر على GitHub و Render (الخطة المجانية)

1. ارفع هذا المجلد إلى مستودع GitHub **خاص** (Private). لا ترفع `.env` ولا مفتاح API.
2. من Render اختر **New > Blueprint** واختر المستودع. أو **New > Web Service** بالإعدادات التالية:
   - Runtime: `Node`
   - Build Command: `npm ci`
   - Start Command: `npm start`
   - Health Check Path: `/api/health`
   - Instance Type: `Free`
3. من **Environment** أضف:
   - `API_KEY`: مفتاح سري طويل (مثلاً من `openssl rand -hex 32`). لا تشاركه مع أحد.
   - `PUBLIC_BASE_URL`: عنوان الخدمة، مثل `https://new-town-voice.onrender.com`
4. اضغط Deploy، ثم جرّب `https://YOUR-SERVICE.onrender.com/api/health`.

**ملاحظة الخطة المجانية:** الخدمة تنام بعد نحو 15 دقيقة بدون طلبات، وأول طلب بعدها يأخذ وقتاً. سكربت Roblox يعيد المحاولة تلقائياً.

## إعداد Roblox

1. **Game Settings > Security > Allow HTTP Requests**: فعّله.
2. أنشئ `Script` داخل **ServerScriptService** اسمه `VoiceLinkManager` والصق محتوى `1_ServerScriptService_VoiceLinkManager.lua`.
3. عدّل فيه:
   ```lua
   local BACKEND_URL = "https://YOUR-SERVICE.onrender.com"
   local API_KEY = "نفس قيمة API_KEY في Render"
   ```
4. أنشئ `LocalScript` داخل **StarterPlayer > StarterPlayerScripts** اسمه `VoiceLinkUI` والصق محتوى `2_StarterPlayerScripts_VoiceLinkUI.lua`.

## الأمان

- الرابط يحتوي توكناً عشوائياً من 128 بت، ويُحفظ هاشه فقط. ينتهي بعد 5 دقائق، ويُستخدم مرة واحدة.
- الرابط لا يُفعَّل بمجرد فتحه. التفعيل يحتاج ضغطة زر، فبرامج معاينة الروابط ما تفعّله.
- مفتاح API لا يظهر في الموقع ولا في الكود العام. يبقى فقط في سكربت السيرفر في Roblox وفي Render.
- الكوكي: `HttpOnly` و`Secure` و`SameSite=Strict`.
- ترويسة `Referrer-Policy: no-referrer` حتى لا يتسرب الرابط لمواقع أخرى.
- السجلات لا تحتوي التوكنات.
- حد لعدد محاولات التفعيل لكل عنوان IP.

**حد معروف:** الرابط يثبت أن الرابط صدر لهذا اللاعب، لكن لا يثبت أن الشخص الذي يفتحه هو نفس الحساب. لذلك الرابط قصير العمر ولمرة واحدة، ولا تنشره. الحل الأقوى لاحقاً هو تسجيل الدخول عبر Roblox OAuth.

## ملاحظات

- **الجوال:** متصفحات الجوال توقف المايك إذا انتقلت للخلفية. الأفضل أن تكون اللعبة على جهاز والموقع على جهاز ثاني.
- **TURN:** الإعدادات الحالية تستخدم سيرفر TURN تجريبياً عاماً. للاستخدام الجاد سجّل في خدمة TURN (مثل metered.ca) واطلب بيانات مؤقتة من السيرفر.
- **حد HTTP في Roblox:** كل لاعب يرسل موقعه كل ثانيتين. Roblox يحد عدد طلبات HTTP لكل سيرفر، وإذا كان عدد اللاعبين كبيراً يلزم تجميع المواقع في طلب واحد.
- **الصوت خارج المنصة:** راجع شروط استخدام Roblox وسياسات المجتمع قبل الإطلاق.

## نظام الراديو (New Town Radio)

### كيف يشتغل
- **الدخول للقنوات من الموقع فقط.** بعد ربط المايك، يظهر قسم الراديو تحته. والسيرفر يتحقق من التيم دائماً.
- **Roblox** يرسل تيم اللاعب، ويعرض زر راديو عائم يفتح لوحة فيها القناة الحالية وزر PTT.
- **زر PTT** يرسل الحالة للسيرفر، والسيرفر يتحقق أن اللاعب داخل قناة قبل ما يسمح بالتحدث.

### الملفات
- `roblox/RadioConfig.lua`: ModuleScript داخل **ReplicatedStorage** باسم `RadioConfig`. أسماء التيمات والأزرار المختصرة.
- `roblox/1_ServerScriptService_VoiceLinkManager.lua`: يرسل التيم عند إنشاء الرابط، وينشر القناة الحالية.
- `roblox/3_ServerScriptService_RadioManager.lua`: Script داخل **ServerScriptService**. يرسل تغيير التيم، ويمرر PTT.
- `roblox/5_StarterPlayerScripts_RadioFloat.lua`: LocalScript داخل **StarterPlayerScripts**. الزر العائم واللوحة.
- `server/radio-rules.js`: قواعد القنوات على السيرفر (المصدر الوحيد للصلاحيات).
- `public/radio-panel.js`: قسم الراديو في الموقع.

### إعداد Roblox
1. أنشئ `ModuleScript` في ReplicatedStorage باسم `RadioConfig` والصق فيه محتوى `RadioConfig.lua`، وعدّل أسماء التيمات بالضبط.
2. أنشئ `Script` في ServerScriptService باسم `RadioManager` والصق فيه ملف السيرفر، وضع `BACKEND_URL` و`API_KEY` نفس قيم VoiceLinkManager.
3. أنشئ `LocalScript` في StarterPlayerScripts باسم `RadioFloat` والصق فيه ملف الزر العائم.
4. **احذف الأداة `NewTownRadio` من StarterPack** إذا كانت موجودة. الواجهة القديمة تعتمد على أوامر دخول محذوفة، وتسبب واجهتين. نسختها محفوظة في `deprecated/`.

### القنوات الافتراضية
- القنوات 1 و2 و3: تيم الشرطة فقط.
- القناة 4: تيم الإسعاف فقط.
- القناة 5: تيم العدل فقط.
- القنوات 6 حتى 20: مفتوحة للجميع.

### الاختبارات
```bash
npm test
```
تشمل: اختبارات الـ Backend، واختبار قسم الموقع في DOM، واختبار سكربت السيرفر ضد محاكاة Roblox، واختبار الزر العائم.

### ما لم يُنفذ بعد
- **الصوت الفعلي للراديو:** الدخول والصلاحيات وحالة التحدث تشتغل. نقل الصوت بين أعضاء القناة يحتاج الخطوة الجاية (mesh للقنوات الصغيرة أو SFU).

## النسخ الاحتياطي والاسترجاع

### الطبقة الأولى: GitHub (الأهم)
المشروع يُدار بـ git. كل تعديل يُحفظ كـ commit، وأي إصدار قديم يرجع له بأمر واحد.
```bash
git add -A
git commit -m "وصف التعديل"
git push
```
استخدم مستودعاً **خاصاً** (Private) حتى لا تظهر الملفات للعامة.

### الطبقة الثانية: نسخة محلية دورية
```bash
./scripts/backup.sh          # ينشئ ملفين في مجلد backups/
```
- `*.bundle`: كل السجل. يُسترجع بـ `git clone ملف.bundle مجلد_جديد`.
- `*.zip`: نسخة من الملفات الحالية، تفتحها مباشرة.

### ما لا يُنسخ هنا (احفظه في مكان آمن)
- مفتاح `API_KEY`، وأي ملف `.env`. لا تحفظها في git أبداً.
- ملف مكان Roblox (`.rbxl`): احفظه من Studio بـ **File > Save to File** بعد كل تعديل كبير.

### الاسترجاع
```bash
git clone new-town-voice_XXXX.bundle restored
cd restored && npm ci && npm test
```
ثم اربط المجلد بمستودع GitHub وارفع منه.

### Render
الخدمة تُنشر من GitHub. إذا حدث خلل، يمكن إعادة النشر من آخر commit أو من commit سابق. الخطة المجانية لا تحتفظ ببيانات (الربط والجلسات في الذاكرة فقط)، لذلك النسخ الاحتياطي يخص الكود والإعدادات فقط.
