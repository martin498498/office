#!/bin/bash
# 童鞋辦公室系統：准許 https://martin498498.github.io 經 WebDAV 讀寫 Nextcloud（只限 /remote.php/dav/）
# 支援：Pi 本機安裝（Apache）同 Docker 官方 nextcloud 映像（apache 版）
# 用法（喺 Raspberry Pi 上面）：
#   curl -fsSL https://raw.githubusercontent.com/martin498498/office/main/tools/nextcloud-cors.sh | sudo bash
# 還原：curl -fsSL https://raw.githubusercontent.com/martin498498/office/main/tools/nextcloud-cors.sh | sudo bash -s -- --remove
set -u
ORIGIN="${OFFICE_ORIGIN:-https://martin498498.github.io}"
MARK_BEGIN="# BEGIN office-cors (童鞋辦公室)"
MARK_END="# END office-cors"
ACTION="${1:-install}"
say(){ printf '%s\n' "$*"; }
fail(){ say ""; say "❌ $*"; say "   請將上面全部文字截圖俾 Claude。"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "要用 sudo 執行（指令最後要有 | sudo bash）。"

MODE=local; CT=""; NCDIR="${NEXTCLOUD_DIR:-}"
X(){ if [ "$MODE" = docker ]; then docker exec -i "$CT" "$@"; else "$@"; fi; }

# 1. 搵 Nextcloud：先搵本機，再搵 Docker 容器
if [ -z "$NCDIR" ]; then
  for d in /var/www/nextcloud /var/www/html/nextcloud /var/www/html /srv/nextcloud; do
    if [ -f "$d/occ" ] && [ -f "$d/remote.php" ]; then NCDIR="$d"; break; fi
  done
fi
if [ -z "$NCDIR" ] && command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^nextcloud-aio-nextcloud$'; then
    fail "呢部機用緊 Nextcloud All-in-One，要用另一個方法。"
  fi
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    for d in /var/www/html /var/www/nextcloud; do
      if docker exec "$c" test -f "$d/occ" 2>/dev/null && docker exec "$c" test -f "$d/remote.php" 2>/dev/null; then
        MODE=docker; CT="$c"; NCDIR="$d"; break 2
      fi
    done
  done
fi
[ -n "$NCDIR" ] || fail "搵唔到 Nextcloud 安裝位置（本機同 Docker 都冇）。"
if [ "$MODE" = docker ]; then say "✓ 搵到 Nextcloud：Docker 容器「$CT」入面嘅 $NCDIR"; else say "✓ 搵到 Nextcloud：$NCDIR"; fi
HT="$NCDIR/.htaccess"

# 2. 要係 Apache
X sh -c 'command -v apache2ctl' >/dev/null 2>&1 || fail "Nextcloud 唔係用 Apache 運行（可能係 nginx / php-fpm 版），要用另一個方法。"
say "✓ 網頁伺服器：Apache"
X test -f "$HT" || fail "搵唔到 $HT"

reload_apache(){
  if [ "$MODE" = docker ]; then
    if [ "${1:-}" = restart ]; then docker restart "$CT" >/dev/null && say "✓ 已重新啟動容器 $CT"; else X apache2ctl graceful >/dev/null 2>&1 || docker restart "$CT" >/dev/null; fi
  else
    if [ "${1:-}" = restart ]; then systemctl restart apache2 2>/dev/null || apache2ctl restart; else systemctl reload apache2 2>/dev/null || apache2ctl graceful; fi
  fi
}
backup(){ BAK="$HT.bak-office-$(date +%Y%m%d%H%M%S)"; X cp -p "$HT" "$BAK" && say "✓ 已備份：$BAK"; }

if [ "$ACTION" = "--remove" ]; then
  if X grep -qF "$MARK_BEGIN" "$HT"; then
    backup
    X sed -i '/^# BEGIN office-cors/,/^# END office-cors/d' "$HT"
    reload_apache; say "✓ 已移除設定。"
  else
    say "冇搵到之前加過嘅設定，唔使移除。"
  fi
  exit 0
fi

# 3. 開啟需要嘅 Apache 模組
NEED_RESTART=0
for m in headers rewrite setenvif; do
  if ! X apache2ctl -M 2>/dev/null | grep -q "${m}_module"; then
    X a2enmod -q "$m" >/dev/null 2>&1 && NEED_RESTART=1 && say "✓ 已開啟 Apache 模組：$m"
  fi
done

# 4. 備份 .htaccess，再加入設定（放喺 Nextcloud 標記下面）
backup
X sed -i '/^# BEGIN office-cors/,/^# END office-cors/d' "$HT"
ORE=$(printf '%s' "$ORIGIN" | sed 's/[.]/\\./g')
cat <<EOF | X sh -c "cat >> '$HT'"
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

# 5. 檢查設定，再重新載入
if ! X apache2ctl configtest >/dev/null 2>&1; then
  X cp -p "$BAK" "$HT"; fail "Apache 設定檢查失敗，已經自動還原。"
fi
if [ "$NEED_RESTART" = 1 ]; then reload_apache restart; else reload_apache; fi
sleep 5

# 6. 自我測試（喺 Nextcloud 嗰邊直接試）
if [ "$MODE" = docker ]; then TU="${TEST_URL:-http://localhost}"; else TU="${TEST_URL:-https://localhost}"; fi
H=$(X curl -sk -o /dev/null -D - -X OPTIONS -H "Origin: $ORIGIN" -H "Access-Control-Request-Method: PUT" \
     -H "Access-Control-Request-Headers: authorization,content-type" "$TU/remote.php/dav/files/test/" 2>/dev/null)
say ""
if printf '%s' "$H" | grep -qi "access-control-allow-origin: $ORIGIN"; then
  say "✅ 完成！Nextcloud 已經准許童鞋辦公室系統連接。"
else
  say "✅ 設定已經加好（自我測試未能確認，通常唔影響）。"
fi
say "   返去系統「☁ Nextcloud 同步」頁，填網址、用戶名、應用程式密碼，㩒「測試並連接」。"
if [ "$MODE" = docker ]; then
  say "   註：將來更新 Nextcloud Docker 映像之後，如果連唔到，再執行一次呢個指令就得。"
fi
