// ============================================================
//  تخزين الروابط والجلسات (في الذاكرة)
//  - الرابط: لمرة واحدة، ينتهي بعد مدة قصيرة، والتوكن نفسه ما يُحفظ — يُحفظ هاشه فقط.
//  - الجلسة: تمثّل لاعب Roblox داخل السيرفر، وتبقى طالما اللعبة ترسل تحديثات.
// ============================================================

import crypto from 'node:crypto';

export const SESSION_TIMEOUT_MS = 90_000;        // بدون تحديث من Roblox لهالمدة تنحذف الجلسة
export const SESSION_COOKIE_TTL_MS = 12 * 60 * 60 * 1000;
const CLEANUP_GRACE_MS = 60_000;                  // نحتفظ بالرابط المنتهي دقيقة عشان نرجع رسالة "منتهي"

const sha256 = (value) => crypto.createHash('sha256').update(value).digest('hex');
const randomId = (bytes) => crypto.randomBytes(bytes).toString('base64url');

export function createStore({ linkTtlMs = 5 * 60_000, now = () => Date.now() } = {}) {
  const links = new Map();    // tokenHash -> { userId, username, expiresAt, usedAt }
  const sessions = new Map(); // userId -> session
  const bySid = new Map();    // sid (كوكي المتصفح) -> session

  function endSession(userId) {
    const s = sessions.get(userId);
    if (!s) return false;
    sessions.delete(userId);
    if (s.sid) bySid.delete(s.sid);
    s.sid = null;
    s.linked = false;
    if (s.ws) {
      try { s.ws.close(4000, 'session ended'); } catch { /* ignore */ }
      s.ws = null;
    }
    return true;
  }

  // يُنشئ رابطاً جديداً للاعب. أي رابط قديم غير مستخدم يصير باطلاً.
  function createLink(userId, username) {
    for (const [hash, link] of links) {
      if (link.userId === userId && !link.usedAt) links.delete(hash);
    }

    let session = sessions.get(userId);
    if (session && session.linked) {
      // دخول جديد للعبة بعد تفعيل سابق: نبدأ جلسة نظيفة
      endSession(userId);
      session = undefined;
    }
    if (!session) {
      session = {
        userId,
        username,
        position: null,
        muted: false,
        linked: false,
        sid: null,
        ws: null,
        lastSeen: now(),
        radioChannel: null,   // يحدده سكربت Roblox فقط
        radioTalking: false,
      };
      sessions.set(userId, session);
    }
    session.username = username;
    session.lastSeen = now();

    const token = randomId(16); // 128 بت عشوائي
    const expiresAt = now() + linkTtlMs;
    links.set(sha256(token), { userId, username, expiresAt, usedAt: null });
    return { token, expiresAt, ttlMs: linkTtlMs };
  }

  function getLink(token) {
    const link = links.get(sha256(token));
    if (!link) return { status: 'invalid' };
    if (link.usedAt) return { status: 'used' };
    if (now() >= link.expiresAt) return { status: 'expired' };
    return { status: 'pending', username: link.username };
  }

  // التفعيل: كل شيء هنا متزامن (synchronous)، فلا يمكن لطلبين ينجحان بنفس الرابط.
  function activate(token) {
    const check = getLink(token);
    if (check.status !== 'pending') return { status: check.status };

    const link = links.get(sha256(token));
    const session = sessions.get(link.userId);
    if (!session) return { status: 'invalid' }; // اللعبة أنهت الجلسة

    link.usedAt = now();
    if (session.sid) bySid.delete(session.sid);
    const sid = randomId(32);
    session.sid = sid;
    session.linked = true;
    session.lastSeen = now();
    bySid.set(sid, session);
    return { status: 'ok', sid, session };
  }

  function getSessionBySid(sid) {
    return sid ? bySid.get(sid) : undefined;
  }

  function getSession(userId) {
    return sessions.get(userId);
  }

  function allSessions() {
    return [...sessions.values()];
  }

  // يحذف الجلسات المتوقفة، ويحذف الروابط القديمة جداً
  function cleanup() {
    const t = now();
    const removed = [];
    for (const s of allSessions()) {
      if (t - s.lastSeen > SESSION_TIMEOUT_MS) {
        endSession(s.userId);
        removed.push(s.userId);
      }
    }
    for (const [hash, link] of links) {
      if (t >= link.expiresAt + CLEANUP_GRACE_MS) links.delete(hash);
    }
    return removed;
  }

  return { createLink, getLink, activate, getSessionBySid, getSession, endSession, allSessions, cleanup };
}
