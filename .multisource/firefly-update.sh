#!/usr/bin/env bash
# firefly-update.sh - install/update firefly-iii-multisource in a community-scripts
# Firefly III LXC. Everything that matters lives below /opt/firefly (may be a
# separate, mirrored volume); nothing important is written to the root disk.
#
# Layout below /opt/firefly:
#   releases/<tag>/     unpacked releases (the last KEEP_RELEASES are kept)
#   current -> releases/<tag>      what Apache serves (DocumentRoot current/public)
#   shared/.env         configuration (DB credentials, APP_KEY)
#   shared/storage/     uploads, OAuth keys, logs  (symlinked into every release)
#   backups/<timestamp>/  db.sql.gz, env, storage.tar.gz, release name
#   dataimporter/       Data Importer from community-scripts (left untouched)
#
# Install inside the LXC:
#   apt install -y jq unzip curl
#   curl -fsSL https://raw.githubusercontent.com/Simon0Harms/firefly-iii-multisource/main/.multisource/firefly-update.sh \
#     -o /usr/local/bin/firefly-update && chmod +x /usr/local/bin/firefly-update
#
# Usage:
#   firefly-update                 update to the latest fork release (backup first)
#   firefly-update --check         show installed / available version
#   firefly-update --tag TAG       install a specific release (e.g. v6.7.6-multisource)
#   firefly-update --list-backups  list backups
#   firefly-update --rollback [TS] switch back to the release of backup TS (default:
#                                  newest) and restore its database, .env and storage
#   firefly-update --install-guard block the community 'update' command
#   firefly-update --init-db-password PW   first install into an empty /opt/firefly:
#                                  creates shared/.env (DB firefly@localhost, new APP_KEY)
#
# License: GPL-3.0-or-later
set -Eeuo pipefail

REPO="Simon0Harms/firefly-iii-multisource"
BASE="/opt/firefly"
RELEASES="$BASE/releases"
SHARED="$BASE/shared"
BACKUPS="$BASE/backups"
CURRENT="$BASE/current"
KEEP_RELEASES=2
KEEP_BACKUPS=5
WEB_USER="www-data"
APACHE_SITE="/etc/apache2/sites-available/firefly.conf"
SPACE_MARGIN_MB=100

log()  { printf '\e[1;34m[firefly-update]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[firefly-update]\e[0m %s\n' "$*"; }
die()  { printf '\e[1;31m[firefly-update] ERROR:\e[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
for c in curl unzip jq tar gzip; do command -v "$c" >/dev/null || die "$c missing (apt install $c)"; done
[[ -d "$BASE" ]] || die "$BASE does not exist"

free_mb() { df -Pm "$BASE" | awk 'NR==2 {print $4}'; }

artisan() {
  log "php artisan $*"
  (cd "$CURRENT" && runuser -u "$WEB_USER" -- php artisan "$@")
}

install_guard() {
  # The community-scripts 'update' pulls upstream Firefly III and runs
  # upgrade-database, which would unify all multi-source splits. Block it.
  local target
  target=$(command -v update || true)
  if [[ -n "$target" && ! -e "$target.community" ]] && ! grep -q multisource "$target" 2>/dev/null; then
    mv "$target" "$target.community"
  fi
  cat > /usr/bin/update <<'EOF'
#!/usr/bin/env bash
echo "This LXC runs firefly-iii-multisource."
echo "The community 'update' would install upstream Firefly III and silently merge"
echo "split transactions with different source accounts. Use: firefly-update"
echo "(Original script kept as /usr/bin/update.community - do NOT use it for Firefly.)"
exit 1
EOF
  chmod +x /usr/bin/update
  log "guard installed: 'update' now refuses to run"
}

# Point Apache and cron at /opt/firefly/current instead of /opt/firefly.
adjust_paths() {
  if [[ -f "$APACHE_SITE" ]] && grep -q "$BASE/public" "$APACHE_SITE"; then
    cp "$APACHE_SITE" "$APACHE_SITE.bak-multisource"
    sed -i "s#$BASE/public#$CURRENT/public#g" "$APACHE_SITE"
    log "Apache DocumentRoot -> $CURRENT/public"
  fi
  local f
  for f in /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/*; do
    [[ -f "$f" ]] || continue
    if grep -q "$BASE/artisan" "$f"; then
      sed -i "s#$BASE/artisan#$CURRENT/artisan#g" "$f"
      log "cron path fixed in $f"
    fi
  done
}

# Convert a classic install (code directly in /opt/firefly) to the new layout.
migrate_classic_layout() {
  [[ -f "$BASE/artisan" && ! -L "$CURRENT" ]] || return 0
  log "converting classic layout in $BASE"
  local legacy="$RELEASES/legacy-$(date +%Y%m%d-%H%M%S)" e
  mkdir -p "$legacy" "$SHARED"
  shopt -s dotglob
  for e in "$BASE"/*; do
    case "$(basename "$e")" in
      releases|shared|backups|dataimporter|current|lost+found) ;;
      *) mv "$e" "$legacy/" ;;
    esac
  done
  shopt -u dotglob
  [[ -f "$legacy/.env" ]] && mv "$legacy/.env" "$SHARED/.env"
  [[ -d "$legacy/storage" ]] && mv "$legacy/storage" "$SHARED/storage"
  link_shared "$legacy"
  ln -sfn "$legacy" "$CURRENT"
  adjust_paths
}

link_shared() {
  local rel="$1"
  rm -rf "$rel/storage" "$rel/.env"
  ln -s "$SHARED/storage" "$rel/storage"
  ln -s "$SHARED/.env" "$rel/.env"
}

load_env() {
  [[ -f "$SHARED/.env" ]] || die "$SHARED/.env missing (see README: fresh setup)"
  set -a; source "$SHARED/.env"; set +a
}

backup() {
  local ts bk
  ts=$(date +%Y%m%d-%H%M%S); bk="$BACKUPS/$ts"; mkdir -p "$bk"
  load_env
  case "${DB_CONNECTION:-mysql}" in
    mysql|mariadb) mysqldump --single-transaction -h "${DB_HOST:-127.0.0.1}" -P "${DB_PORT:-3306}" \
                     -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" | gzip > "$bk/db.sql.gz" ;;
    pgsql)         PGPASSWORD="$DB_PASSWORD" pg_dump -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-5432}" \
                     -U "$DB_USERNAME" "$DB_DATABASE" | gzip > "$bk/db.sql.gz" ;;
    sqlite)        cp "$SHARED/storage/database/database.sqlite" "$bk/" ;;
    *) die "unknown DB_CONNECTION ${DB_CONNECTION}" ;;
  esac
  cp "$SHARED/.env" "$bk/env"
  tar -C "$SHARED" --exclude='storage/logs/*' --exclude='storage/framework/cache/*' \
      --exclude='storage/framework/views/*' -czf "$bk/storage.tar.gz" storage
  basename "$(readlink -f "$CURRENT" 2>/dev/null || echo none)" > "$bk/release"
  gzip -t "$bk/db.sql.gz" 2>/dev/null || [[ -f "$bk/database.sqlite" ]] || die "database backup is broken"
  log "backup written to $bk"
  ls -1dt "$BACKUPS"/*/ 2>/dev/null | tail -n +$((KEEP_BACKUPS+1)) | xargs -r rm -rf
}

restore_db() {
  local bk="$1"
  set -a; source "$bk/env"; set +a
  case "${DB_CONNECTION:-mysql}" in
    mysql|mariadb) gunzip -c "$bk/db.sql.gz" | mysql -h "${DB_HOST:-127.0.0.1}" -P "${DB_PORT:-3306}" \
                     -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" ;;
    pgsql)         gunzip -c "$bk/db.sql.gz" | PGPASSWORD="$DB_PASSWORD" psql -q -h "${DB_HOST:-127.0.0.1}" \
                     -p "${DB_PORT:-5432}" -U "$DB_USERNAME" "$DB_DATABASE" ;;
    sqlite)        cp "$bk/database.sqlite" "$SHARED/storage/database/database.sqlite" ;;
  esac
}

rollback() {
  local ts="${1:-}" bk rel
  [[ -n "$ts" ]] || ts=$(ls -1t "$BACKUPS" 2>/dev/null | head -1)
  bk="$BACKUPS/$ts"
  [[ -n "$ts" && -d "$bk" ]] || die "backup '$ts' not found (see --list-backups)"
  rel=$(cat "$bk/release")
  [[ -d "$RELEASES/$rel" ]] || die "release $rel of that backup is no longer in $RELEASES"
  log "rolling back to $rel with data from $ts"
  cp "$bk/env" "$SHARED/.env"
  rm -rf "$SHARED/storage" && tar -C "$SHARED" -xzf "$bk/storage.tar.gz"
  mkdir -p "$SHARED"/storage/{logs,framework/cache,framework/views,framework/sessions}
  restore_db "$bk"
  ln -sfn "$RELEASES/$rel" "$CURRENT"
  chown -R "$WEB_USER:$WEB_USER" "$SHARED"
  artisan cache:clear; artisan view:clear; artisan config:clear
  systemctl reload apache2 || true
  log "rollback done: $rel"
}

# --- options ------------------------------------------------------------------
CHECK_ONLY=0; TAG=""; INIT_DB_PW=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --tag) TAG="$2"; shift ;;
    --install-guard) install_guard; exit 0 ;;
    --list-backups) for d in "$BACKUPS"/*/; do [[ -d "$d" ]] && echo "$(basename "$d")  release=$(cat "$d/release")  $(du -sh "$d" | cut -f1)"; done; exit 0 ;;
    --rollback) rollback "${2:-}"; exit 0 ;;
    --init-db-password) INIT_DB_PW="$2"; shift ;;
    *) die "unknown option $1" ;;
  esac
  shift
done

mkdir -p "$RELEASES" "$SHARED" "$BACKUPS"
migrate_classic_layout

# --- what is available? -------------------------------------------------------
API="https://api.github.com/repos/$REPO/releases"
if [[ -n "$TAG" ]]; then REL_JSON=$(curl -fsSL "$API/tags/$TAG"); else REL_JSON=$(curl -fsSL "$API/latest"); fi
NEW=$(jq -r .tag_name <<<"$REL_JSON")
ZIP_URL=$(jq -r '.assets[] | select(.name|test("^FireflyIII-multisource-.*\\.zip$")) | .browser_download_url' <<<"$REL_JSON")
SHA_URL=$(jq -r '.assets[] | select(.name|test("\\.zip\\.sha256$")) | .browser_download_url' <<<"$REL_JSON")
[[ -n "$ZIP_URL" && "$ZIP_URL" == https://github.com/$REPO/* ]] || die "no release asset from $REPO found"

CUR=$(basename "$(readlink -f "$CURRENT" 2>/dev/null || echo none)")
log "installed: $CUR   available: $NEW"
[[ $CHECK_ONLY -eq 1 ]] && exit 0
[[ "$CUR" == "$NEW" ]] && { log "already up to date"; exit 0; }
[[ -f "$SHARED/.env" || -n "$INIT_DB_PW" ]] || die "$SHARED/.env missing - for a first install use --init-db-password"

# --- download (to /tmp, a tmpfs) and verify -------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
log "downloading $NEW"
curl -fsSL "$ZIP_URL" -o "$TMP/ff.zip"
curl -fsSL "$SHA_URL" -o "$TMP/ff.sha256"
[[ "$(awk '{print $1}' "$TMP/ff.sha256")" == "$(sha256sum "$TMP/ff.zip" | awk '{print $1}')" ]] || die "checksum mismatch"
unzip -p "$TMP/ff.zip" app/Validation/TransactionValidation.php | grep -q "firefly-iii-multisource" \
  || die "archive does not contain the multisource patch - aborting"

# --- space check on /opt/firefly ------------------------------------------------
UNZIP_MB=$(( $(unzip -l "$TMP/ff.zip" | tail -1 | awk '{print $1}') / 1024 / 1024 + 1 ))
STORAGE_MB=$(du -sm "$SHARED/storage" 2>/dev/null | cut -f1 || echo 0)
NEED_MB=$(( UNZIP_MB + STORAGE_MB + SPACE_MARGIN_MB ))
HAVE_MB=$(free_mb)
log "space on $BASE: need ~${NEED_MB} MB, free ${HAVE_MB} MB"
(( HAVE_MB >= NEED_MB )) || die "not enough space on $BASE - nothing was changed"

# --- backup, unpack, switch ------------------------------------------------------
[[ -L "$CURRENT" ]] && backup
artisan down 2>/dev/null || true

TARGET="$RELEASES/$NEW"
rm -rf "$TARGET" && mkdir -p "$TARGET"
unzip -q "$TMP/ff.zip" -d "$TARGET"
if [[ ! -d "$SHARED/storage" ]]; then mv "$TARGET/storage" "$SHARED/storage"; fi
if [[ ! -f "$SHARED/.env" ]]; then
  log "creating $SHARED/.env from .env.example"
  cp "$TARGET/.env.example" "$SHARED/.env"
  KEY="base64:$(head -c 32 /dev/urandom | base64)"
  sed -i -e "s#^APP_KEY=.*#APP_KEY=$KEY#" \
         -e "s#^DB_CONNECTION=.*#DB_CONNECTION=mysql#" \
         -e "s#^DB_HOST=.*#DB_HOST=localhost#" \
         -e "s#^DB_DATABASE=.*#DB_DATABASE=firefly#" \
         -e "s#^DB_USERNAME=.*#DB_USERNAME=firefly#" \
         -e "s#^DB_PASSWORD=.*#DB_PASSWORD=$INIT_DB_PW#" "$SHARED/.env"
  chmod 640 "$SHARED/.env"
fi
link_shared "$TARGET"
chown -R "$WEB_USER:$WEB_USER" "$TARGET" "$SHARED"
chmod -R 775 "$SHARED/storage"
ln -sfn "$TARGET" "$CURRENT"
adjust_paths

artisan cache:clear
artisan config:clear
artisan route:clear
artisan view:clear
artisan migrate --seed --force
artisan firefly-iii:upgrade-database
artisan firefly-iii:laravel-passport-keys
artisan storage:link || true
artisan optimize
artisan up || true
systemctl reload apache2 || true

# keep the newest KEEP_RELEASES releases (never the current one)
ls -1dt "$RELEASES"/*/ | tail -n +$((KEEP_RELEASES+1)) | while read -r d; do
  [[ "$(readlink -f "$d")" == "$(readlink -f "$CURRENT")" ]] || rm -rf "$d"
done

log "updated to $NEW  (free on $BASE: $(free_mb) MB; rollback: firefly-update --rollback)"
