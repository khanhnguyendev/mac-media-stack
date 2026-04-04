#!/bin/bash
# Reset Sonarr/Radarr library entries and history while preserving app configuration.
# Optionally triggers a Jellyfin library refresh so stale items disappear after media files are removed.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
YES=false
REFRESH_JELLYFIN=true

usage() {
    cat <<EOF
Usage: bash scripts/reset-library-state.sh [OPTIONS]

Removes Sonarr/Radarr tracked library items and clears their history/blocklists
without deleting your application configuration. Also triggers a Jellyfin library
refresh by default.

Options:
  --yes              Run without confirmation prompt
  --no-jellyfin      Skip Jellyfin refresh
  --help             Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            YES=true
            shift
            ;;
        --no-jellyfin)
            REFRESH_JELLYFIN=false
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${RED}Error:${NC} .env not found at $ENV_FILE"
    exit 1
fi

source "$ENV_FILE"

MEDIA_DIR="${MEDIA_DIR:-$HOME/Media}"
CREDS_FILE="$MEDIA_DIR/state/first-run-credentials.txt"
SONARR_DB="$MEDIA_DIR/config/sonarr/sonarr.db"
RADARR_DB="$MEDIA_DIR/config/radarr/radarr.db"
SEERR_SETTINGS="$MEDIA_DIR/config/seerr/settings.json"
BACKUP_DIR="$MEDIA_DIR/state/reset-library-backups/$(date +%Y%m%d-%H%M%S)"

if [[ ! -f "$CREDS_FILE" ]]; then
    echo -e "${RED}Error:${NC} credentials file not found at $CREDS_FILE"
    exit 1
fi

if [[ ! -f "$SONARR_DB" || ! -f "$RADARR_DB" ]]; then
    echo -e "${RED}Error:${NC} Sonarr/Radarr database files not found under $MEDIA_DIR/config"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}Error:${NC} jq is required"
    exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo -e "${RED}Error:${NC} sqlite3 is required"
    exit 1
fi

log() { echo -e "  ${GREEN}OK${NC}  $1"; }
warn() { echo -e "  ${YELLOW}..${NC}  $1"; }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; }

SONARR_KEY="$(sed -n 's/^Sonarr API Key: //p' "$CREDS_FILE" | head -1)"
RADARR_KEY="$(sed -n 's/^Radarr API Key: //p' "$CREDS_FILE" | head -1)"
JELLYFIN_API_KEY=""
if [[ -f "$SEERR_SETTINGS" ]]; then
    JELLYFIN_API_KEY="$(jq -r '.jellyfin.apiKey // empty' "$SEERR_SETTINGS")"
fi

echo ""
echo "=============================="
echo "  Reset Library State"
echo "=============================="
echo ""
echo "This will:"
echo "  - remove tracked series from Sonarr"
echo "  - remove tracked movies from Radarr"
echo "  - clear Sonarr/Radarr history, blocklists, and pending releases"
echo "  - keep app configuration, API keys, indexers, and VPN settings"
if [[ "$REFRESH_JELLYFIN" == true ]]; then
    echo "  - trigger a Jellyfin library refresh"
fi
echo ""

if [[ "$YES" != true ]]; then
    read -r -p "Continue? [y/N] " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

mkdir -p "$BACKUP_DIR"
cp "$SONARR_DB" "$BACKUP_DIR/sonarr.db.bak"
cp "$RADARR_DB" "$BACKUP_DIR/radarr.db.bak"
log "Backed up Sonarr/Radarr databases to $BACKUP_DIR"

warn "Removing tracked Sonarr series..."
SONARR_IDS="$(curl -fsS -H "X-Api-Key: $SONARR_KEY" http://127.0.0.1:8989/api/v3/series | jq '.[].id')"
if [[ -n "$SONARR_IDS" ]]; then
    while read -r id; do
        [[ -z "$id" ]] && continue
        curl -fsS -X DELETE \
            "http://127.0.0.1:8989/api/v3/series/$id?deleteFiles=false&addImportListExclusion=false" \
            -H "X-Api-Key: $SONARR_KEY" >/dev/null
    done <<<"$SONARR_IDS"
fi
log "Cleared Sonarr tracked series"

warn "Removing tracked Radarr movies..."
RADARR_IDS="$(curl -fsS -H "X-Api-Key: $RADARR_KEY" http://127.0.0.1:7878/api/v3/movie | jq '.[].id')"
if [[ -n "$RADARR_IDS" ]]; then
    while read -r id; do
        [[ -z "$id" ]] && continue
        curl -fsS -X DELETE \
            "http://127.0.0.1:7878/api/v3/movie/$id?deleteFiles=false&addImportExclusion=false" \
            -H "X-Api-Key: $RADARR_KEY" >/dev/null
    done <<<"$RADARR_IDS"
fi
log "Cleared Radarr tracked movies"

warn "Clearing Sonarr history tables..."
sqlite3 "$SONARR_DB" "
delete from History;
delete from DownloadHistory;
delete from Blocklist;
delete from PendingReleases;
delete from EpisodeFiles;
delete from Episodes;
delete from Series;
delete from SubtitleFiles;
delete from MetadataFiles;
delete from ExtraFiles;
" >/dev/null
log "Sonarr history and library records cleared"

warn "Clearing Radarr history tables..."
sqlite3 "$RADARR_DB" "
delete from History;
delete from DownloadHistory;
delete from Blocklist;
delete from PendingReleases;
delete from MovieFiles;
delete from Movies;
delete from SubtitleFiles;
delete from MetadataFiles;
delete from ExtraFiles;
" >/dev/null
log "Radarr history and library records cleared"

warn "Restarting Sonarr and Radarr..."
docker restart sonarr radarr >/dev/null
log "Sonarr and Radarr restarted"

if [[ "$REFRESH_JELLYFIN" == true ]]; then
    if [[ -n "$JELLYFIN_API_KEY" ]]; then
        warn "Triggering Jellyfin library refresh..."
        curl -fsS -X POST \
            -H "X-Emby-Token: $JELLYFIN_API_KEY" \
            "http://127.0.0.1:8096/Library/Refresh" >/dev/null || true
        log "Jellyfin refresh requested"
    else
        warn "Jellyfin API key not found; skipped Jellyfin refresh"
    fi
fi

echo ""
echo "Done."
echo ""
echo "Backup location:"
echo "  $BACKUP_DIR"
echo ""
echo "Configuration preserved:"
echo "  - Sonarr/Radarr settings"
echo "  - Prowlarr indexers"
echo "  - qBittorrent settings"
echo "  - Bazarr settings"
echo "  - Seerr settings"
echo "  - Jellyfin users/settings"
echo ""
