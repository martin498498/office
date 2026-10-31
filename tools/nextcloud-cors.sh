#!/bin/bash
# 童鞋辦公室系統：准許 https://martin498498.github.io 經 WebDAV 讀寫 Nextcloud（只限 /remote.php/dav/）
# 用法（喺 Raspberry Pi 上面）：
#   curl -fsSL https://raw.githubusercontent.com/martin498498/office/main/tools/nextcloud-cors.sh | sudo bash
# 還原：sudo bash nextcloud-cors.sh --remove
set -u
ORIGIN="${OFFICE_ORIGIN:-https://martin498498.github.io}"
MARK_BEGIN="# BEGIN office-cors (童鞋辦公室)"
MARK_END="# END office-cors"
say(){ printf '%s\n' "$*"; }
fail(){ say ""; say "❌ $*"; say "   請將上面全部文字截圖俾 Claude。"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "要用 sudo 執行（指令前面要有 sudo）。"

# 1. 搵 Nextcloud 喺邊
NCDIR="${NEXTCLOUD_DIR:-}"
if [ -z "$NCDIR" ]; then
  for d in /var/www/nextcloud /var/www/html/nextcloud /var/www/html /srv/nextcloud /usr/share/nginx/nextcloud; do
    if [ -f "$d/occ" ] && [ -f "$d/remote.php" ]; then NCDIR="$d"; break; fi
  done
fi
if [ -z "$NCDIR" ]; then
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qi 'nextcloud-aio'; then
    fail "呢部機用緊 Nextcloud All-in-One（Docker），要用另一個方法。"
  fi
  if command -v snap >/dev/null 2>&1 && snap list 2>/dev/null | grep -q '^nextcloud '; then
    fail "呢部機用緊 Nextcloud snap，要用另一個方法。"
  fi
  fail "搵唔到 Nextcloud 安裝位置。"
fi
say "✓ 搵到 Nextcloud：$NCDIR"
HT="$NCDIR/.htaccess"

# 2. 要係 Apache
if ! command -v apache2ctl >/dev/null 2>&1; then
  fail "呢部機唔係用 Apache（可能係 nginx），要用另一個方法。"
fi
say "✓ 網頁伺服器：Apache"

if [ "${1:-}" = "--remove" ]; then
  if grep -qF "$MARK_BEGIN" "$HT"; then
    cp -p "$HT" "$HT.bak-office-$(date +%Y%m%d%H%M%S)"
    sed -i "/^# BEGIN office-cors/,/^# END office-cors/d" "$HT"
    apache2ctl configtest >/dev/null 2>&1 && (systemctl reload apache2 2>/dev/null || apache2ctl graceful)
    say "✓ 已移除設定。"
  else
    say "冇搵到之前加過嘅設定，唔使移除。"
  fi
  exit 0
fi

# 3. 開啟需要嘅 Apache 模組
CHANGED_MOD=0
for m in headers rewrite setenvif; do
  if ! apache2ctl -M 2>/dev/null | grep -q "${m}_module"; then
    a2enmod -q "$m" >/dev/null && CHANGED_MOD=1 && say "✓ 已開啟 Apache 模組：$m"
  fi
done

# 4. 備份 .htaccess，再加入設定（放喺 Nextcloud 標記下面，升級時唔會被洗走）
[ -f "$HT" ] || fail "搵唔到 $HT"
BAK="$HT.bak-office-$(date +%Y%m%d%H%M%S)"
cp -p "$HT" "$BAK"
say "✓ 已備份：$BAK"
sed -i "/^# BEGIN office-cors/,/^# END office-cors/d" "$HT"
ORE=$(printf '%s' "$ORIGIN" | sed 's/[.]/\\./g')
cat >> "$HT" <<EOF
$MARK_BEGIN
<IfModule mod_setenvif.c>
  SetEnvIf Origin "^${ORE}\$" OFFICE_CORS=1
</IfModule>
<IfModule mod_headers.c>
  Header always set Access-Control-Allow-Origin "${ORIGIN}" env=OFFICE_CORS
  Header always set Access-Control-Allow-Methods "GET, PUT, MKCOL, OPTIONS" env=OFFICE_CORS
  Header always set Access-Control-Allow-Headers "Authorization, Content-Type" env=OFFICE_CORS
  Header always set Access-Control-Max-Age "86400" env=OFFICE_CORS
  Header always merge Vary "Origin"
</IfModule>
<IfModule mod_rewrite.c>
  RewriteEngine on
  RewriteCond %{REQUEST_METHOD} =OPTIONS
  RewriteCond %{HTTP:Origin} "^${ORE}\$"
  RewriteRule ^remote\.php/dav/ - [R=204,L]
</IfModule>
$MARK_END
EOF
say "✓ 已加入設定"

# 5. 檢查設定冇錯，再重新載入 Apache
if ! apache2ctl configtest >/dev/null 2>&1; then
  cp -p "$BAK" "$HT"
  fail "Apache 設定檢查失敗，已經自動還原。"
fi
if [ "$CHANGED_MOD" = 1 ]; then systemctl restart apache2 2>/dev/null || apache2ctl restart; else systemctl reload apache2 2>/dev/null || apache2ctl graceful; fi
sleep 2

# 6. 自我測試
TEST_URL="${TEST_URL:-https://localhost}"
H=$(curl -sk -o /dev/null -D - -X OPTIONS -H "Origin: $ORIGIN" -H "Access-Control-Request-Method: PUT" \
     -H "Access-Control-Request-Headers: authorization,content-type" "$TEST_URL/remote.php/dav/files/test/" 2>/dev/null)
if printf '%s' "$H" | grep -qi "access-control-allow-origin: $ORIGIN"; then
  say ""
  say "✅ 完成！Nextcloud 已經准許童鞋辦公室系統連接。"
  say "   返去系統「☁ Nextcloud 同步」頁，填網址、用戶名、應用程式密碼，㩒「測試並連接」。"
else
  say ""
  say "⚠ 設定已經加咗，但係自我測試睇唔到預期結果（可能係本機 https 設定唔同，未必有問題）。"
  say "   請直接去系統「☁ Nextcloud 同步」試連接；如果連唔到，將呢頁截圖俾 Claude。"
  printf '%s\n' "$H" | head -5
fi
