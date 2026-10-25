#!/usr/bin/env bash
# نسخة احتياطية كاملة للمشروع:
#  1) git bundle: كل السجل (كل التعديلات والإصدارات) في ملف واحد
#  2) zip: نسخة من ملفات المشروع الحالية (بدون node_modules و .env)
# الاستخدام: ./scripts/backup.sh [مجلد_الوجهة]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT/backups}"
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
NAME="new-town-voice_${STAMP}"

mkdir -p "$DEST"
cd "$ROOT"

if [ ! -d .git ]; then
  echo "[!] المشروع ما فيه git. شغّل: git init && git add -A && git commit -m 'initial'" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "[!] فيه تعديلات غير محفوظة في git. الأفضل تسويها commit قبل النسخ:"
  git status --short
  echo "    (النسخة راح تحتوي الملفات الحالية، لكن بدون تاريخ هذه التعديلات)"
fi

git bundle create "$DEST/$NAME.bundle" --all
echo "[ok] git bundle: $DEST/$NAME.bundle"

TMP="$(mktemp -d)"
git archive --format=zip --prefix="new-town-voice/" -o "$TMP/$NAME.zip" HEAD
mv "$TMP/$NAME.zip" "$DEST/$NAME.zip"
rm -rf "$TMP"
echo "[ok] zip snapshot:   $DEST/$NAME.zip"

echo ""
echo "تنبيه: ملف .env (إن وُجد) ومفاتيح API ما تنحفظ هنا. احفظها في مدير كلمات مرور."
