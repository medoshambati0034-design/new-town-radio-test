// ============================================================
//  قواعد قنوات الراديو (المصدر الوحيد للصلاحيات على السيرفر)
//  أي قناة غير مذكورة هنا = مفتوحة للجميع.
//  أسماء التيمات يجب أن تطابق Teams في Roblox بالضبط.
// ============================================================

export const MAX_RADIO_CHANNEL = 20;

export const RADIO_CHANNELS = {
  1: { teams: ['Police'] },
  2: { teams: ['Police'] },
  3: { teams: ['Police'] },
  4: { teams: ['EMS'] },
  5: { teams: ['Justice'] },
};

export function isValidChannel(channel) {
  return Number.isSafeInteger(channel) && channel >= 1 && channel <= MAX_RADIO_CHANNEL;
}

// هل يقدر لاعب من هذا التيم يدخل القناة؟
export function channelAllowed(channel, team) {
  if (!isValidChannel(channel)) return false;
  const rule = RADIO_CHANNELS[channel];
  if (!rule) return true; // قناة مفتوحة
  return typeof team === 'string' && rule.teams.includes(team);
}

// قائمة القنوات للموقع (لعرض الواجهة فقط، السيرفر يتحقق بنفسه)
export function publicChannelList() {
  const list = [];
  for (let channel = 1; channel <= MAX_RADIO_CHANNEL; channel++) {
    const rule = RADIO_CHANNELS[channel];
    list.push({ channel, teams: rule ? [...rule.teams] : null });
  }
  return list;
}
