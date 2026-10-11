#!/bin/bash
# ─────────────────────────────────────────────────────────
# Deploy script — vladcealicu.com
# Run as: coder
#   SKIP_PING=1 ./deploy.sh   → deploy without pinging search engines
# ─────────────────────────────────────────────────────────
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$DEPLOY_DIR")"
SRC_DIR="$PROJECT_DIR/public"
DEST_DIR="/var/www/vladcealicu.com/public"
NGINX_SRC="$DEPLOY_DIR/nginx.conf"
NGINX_DEST="/etc/nginx/sites-available/www.vladcealicu.com"
SITE_URL="https://www.vladcealicu.com"
SITE_HOST="www.vladcealicu.com"
INDEXNOW_KEY_FILE="$DEPLOY_DIR/indexnow.key"

echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║  🚀 DEPLOY — vladcealicu.com"
echo "  ╚═══════════════════════════════════════╝"
echo ""

# ── IndexNow key (public by design, made once on this server, then reused) ──
if [ ! -s "$INDEXNOW_KEY_FILE" ]; then
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$INDEXNOW_KEY_FILE"
    echo "  [🔑] new IndexNow key in deploy/indexnow.key"
fi
INDEXNOW_KEY="$(cat "$INDEXNOW_KEY_FILE")"

# ── Sync public/ → /var/www/ ──
echo "> SYNCING FILES..."
rsync -av8 --checksum --delete \
    --exclude='sitemap.xml' \
    --exclude="${INDEXNOW_KEY}.txt" \
    --out-format="  [↑] %n" \
    "$SRC_DIR"/ "$DEST_DIR"/

# IndexNow verification file at the site root
printf '%s' "$INDEXNOW_KEY" > "$DEST_DIR/${INDEXNOW_KEY}.txt"

# ── Sitemap (HTML pages only; the .md twins are linked from each page) ──
echo ""
echo "> GENERATING SITEMAP..."
lastmod() { date -u -r "$1" +%Y-%m-%d; }

PAGE_URLS=()
{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"'
    echo '        xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">'
    echo '  <url>'
    echo "    <loc>${SITE_URL}/</loc>"
    echo "    <lastmod>$(lastmod "$SRC_DIR/index.html")</lastmod>"
    echo '    <image:image>'
    echo "      <image:loc>${SITE_URL}/images/vlad.png</image:loc>"
    echo '    </image:image>'
    echo '  </url>'
} > "$DEST_DIR/sitemap.xml"
PAGE_URLS+=("${SITE_URL}/")

while IFS= read -r -d '' html_file; do
    rel="${html_file#$SRC_DIR/}"
    [ "$rel" = "index.html" ] && continue
    [[ "$rel" == error/* ]] && continue
    if [[ "$rel" == */index.html ]]; then
        url="/${rel%index.html}"
    else
        url="/${rel%.html}"
    fi
    {
        echo '  <url>'
        echo "    <loc>${SITE_URL}${url}</loc>"
        echo "    <lastmod>$(lastmod "$html_file")</lastmod>"
        echo '  </url>'
    } >> "$DEST_DIR/sitemap.xml"
    PAGE_URLS+=("${SITE_URL}${url}")
done < <(find "$SRC_DIR" -name "*.html" -type f -print0)

echo "</urlset>" >> "$DEST_DIR/sitemap.xml"
echo "  [📍] sitemap.xml (${#PAGE_URLS[@]} pages)"

# ── Nginx config (if changed). No sudo: coder owns the site config and may reload nginx.
#    The reload parses the config first and refuses a broken one without touching the
#    running server, so a failed reload means "invalid", and the old file goes back. ──
if [ -f "$NGINX_SRC" ]; then
    if ! cmp -s "$NGINX_SRC" "$NGINX_DEST" 2>/dev/null; then
        echo ""
        echo "> NGINX CONFIG..."
        if [ ! -w "$NGINX_DEST" ] && [ ! -w "$(dirname "$NGINX_DEST")" ]; then
            echo "  [!] $NGINX_DEST is not writable by $(whoami), nginx config skipped"
        else
            BACKUP="$(mktemp)"
            cp "$NGINX_DEST" "$BACKUP" 2>/dev/null || true
            cp "$NGINX_SRC" "$NGINX_DEST"
            if systemctl --no-ask-password reload nginx; then
                echo "  [⚡] nginx deployed & reloaded"
            elif [ -s "$BACKUP" ]; then
                cp "$BACKUP" "$NGINX_DEST"
                echo "  [✗] nginx refused the new config, previous config restored (running server untouched)"
            else
                echo "  [✗] nginx refused the new config and there was no previous one to restore"
            fi
            rm -f "$BACKUP"
        fi
    else
        echo ""
        echo "  [—] nginx unchanged"
    fi
fi

# ── Tell search engines (IndexNow covers Bing, Yandex, Seznam, Naver; Google reads the sitemap) ──
if [ "${SKIP_PING:-0}" != "1" ] && command -v curl >/dev/null 2>&1; then
    echo ""
    echo "> PINGING INDEXNOW..."
    URL_JSON=$(printf '"%s",' "${PAGE_URLS[@]}" "${SITE_URL}/llms.txt" "${SITE_URL}/index.md")
    URL_JSON="[${URL_JSON%,}]"
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
        -H 'Content-Type: application/json; charset=utf-8' \
        -d "{\"host\":\"${SITE_HOST}\",\"key\":\"${INDEXNOW_KEY}\",\"keyLocation\":\"${SITE_URL}/${INDEXNOW_KEY}.txt\",\"urlList\":${URL_JSON}}" \
        https://api.indexnow.org/indexnow || echo "000")
    case "$code" in
        200|202) echo "  [📡] IndexNow accepted ($code)" ;;
        *)       echo "  [!] IndexNow returned $code (deploy is fine, search engines will find it anyway)" ;;
    esac
fi

echo ""
echo "  ✅ DEPLOYED"
echo ""
