#!/bin/bash
# Request a specific movie through Seerr and trace the flow through
# Radarr -> qBittorrent -> import -> Jellyfin -> Bazarr.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TITLE=""
YEAR=""
SEARCH_TIMEOUT=60
DOWNLOAD_TIMEOUT=180
IMPORT_TIMEOUT=900

usage() {
    cat <<EOF
Usage: bash scripts/e2e-request-movie.sh --title "Movie Title" [OPTIONS]

Options:
  --title TITLE          Movie title to request through Seerr
  --year YEAR            Expected release year to disambiguate search results
  --search-timeout SEC   Seconds to wait for qBittorrent visibility (default: 60)
  --import-timeout SEC   Seconds to wait for import/Jellyfin/Bazarr visibility (default: 900)
  --help                 Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --title)
            TITLE="${2:-}"
            shift 2
            ;;
        --year)
            YEAR="${2:-}"
            shift 2
            ;;
        --search-timeout)
            SEARCH_TIMEOUT="${2:-}"
            shift 2
            ;;
        --import-timeout)
            IMPORT_TIMEOUT="${2:-}"
            shift 2
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

if [[ -z "$TITLE" ]]; then
    usage
    exit 1
fi

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    echo -e "${RED}Error:${NC} .env not found."
    exit 1
fi

source "$SCRIPT_DIR/.env"

MEDIA_DIR="${MEDIA_DIR:-$HOME/Media}"
CREDS_FILE="$MEDIA_DIR/state/first-run-credentials.txt"
SEERR_SETTINGS="$MEDIA_DIR/config/seerr/settings.json"
BAZARR_CONFIG="$MEDIA_DIR/config/bazarr/config/config.yaml"

if [[ ! -f "$CREDS_FILE" || ! -f "$SEERR_SETTINGS" || ! -f "$BAZARR_CONFIG" ]]; then
    echo -e "${RED}Error:${NC} missing required runtime config under $MEDIA_DIR"
    exit 1
fi

QB_PASSWORD="$(sed -n 's/^qBittorrent Password: //p' "$CREDS_FILE" | head -1)"
RADARR_KEY="$(sed -n 's/^Radarr API Key: //p' "$CREDS_FILE" | head -1)"
SEERR_API_KEY="$(jq -r '.main.apiKey' "$SEERR_SETTINGS")"
JELLYFIN_API_KEY="$(jq -r '.jellyfin.apiKey' "$SEERR_SETTINGS")"
BAZARR_API_KEY="$(sed -n '/^auth:/,/^[^ ]/p' "$BAZARR_CONFIG" | sed -n 's/^  apikey: //p' | head -1)"

PASS_COUNT=0
FAIL_COUNT=0

log() { echo -e "  ${GREEN}OK${NC}  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
warn() { echo -e "  ${YELLOW}..${NC}  $1"; }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

qb_login() {
    curl -s -c /tmp/qb.cookies http://127.0.0.1:8080/api/v2/auth/login \
        --data-urlencode "username=${QBITTORRENT_USERNAME:-admin}" \
        --data-urlencode "password=$QB_PASSWORD" >/dev/null
}

normalize_title() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/ /g; s/  */ /g; s/^ //; s/ $//'
}

echo ""
echo "=============================="
echo "  Media Stack Movie Flow Test"
echo "=============================="
echo ""
echo "  Title: $TITLE${YEAR:+ ($YEAR)}"
echo ""

warn "Running smoke precheck..."
if bash "$SCRIPT_DIR/scripts/e2e-smoke.sh" >/tmp/e2e-movie-smoke.txt 2>&1; then
    log "Smoke precheck passed"
else
    cat /tmp/e2e-movie-smoke.txt
    fail "Smoke precheck failed"
    exit 1
fi

ENCODED_QUERY="$(python3 - <<'PY' "$TITLE"
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
)"

warn "Searching Seerr for the movie..."
SEARCH_JSON="$(curl -s -H "X-Api-Key: $SEERR_API_KEY" "http://127.0.0.1:5055/api/v1/search?query=${ENCODED_QUERY}&page=1&language=en")"

MATCH_JSON="$(jq -c --arg title "$TITLE" --arg year "$YEAR" '
  .results
  | map(select(.mediaType == "movie"))
  | map(. + {normTitle: (.title | ascii_downcase)})
  | (map(select(.normTitle == ($title | ascii_downcase) and (($year == "") or (.releaseDate[0:4] == $year))))[0]
     // map(select(.normTitle == ($title | ascii_downcase)))[0]
     // .[0])
' <<<"$SEARCH_JSON")"

if [[ "$MATCH_JSON" == "null" || -z "$MATCH_JSON" ]]; then
    fail "No movie result found in Seerr for '$TITLE'"
    exit 1
fi

TMDB_ID="$(jq -r '.id' <<<"$MATCH_JSON")"
MATCH_TITLE="$(jq -r '.title' <<<"$MATCH_JSON")"
MATCH_YEAR="$(jq -r '.releaseDate[0:4] // ""' <<<"$MATCH_JSON")"
log "Seerr search matched '$MATCH_TITLE${MATCH_YEAR:+ ($MATCH_YEAR)}' (TMDb: $TMDB_ID)"

warn "Submitting request to Seerr..."
REQ_STATUS="$(curl -s -o /tmp/e2e-seerr-request.json -w "%{http_code}" \
    -H "X-Api-Key: $SEERR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"mediaId\":${TMDB_ID},\"mediaType\":\"movie\"}" \
    http://127.0.0.1:5055/api/v1/request)"

if [[ "$REQ_STATUS" =~ ^(200|201|409)$ ]]; then
    log "Seerr accepted or already had the request"
else
    sed -n '1,120p' /tmp/e2e-seerr-request.json
    fail "Seerr request failed with HTTP $REQ_STATUS"
    exit 1
fi

warn "Waiting for Radarr to add the movie..."
RADARR_MOVIE_JSON=""
for _ in {1..24}; do
    RADARR_MOVIE_JSON="$(curl -s -H "X-Api-Key: $RADARR_KEY" http://127.0.0.1:7878/api/v3/movie | jq -c --argjson tmdb "$TMDB_ID" 'map(select(.tmdbId == $tmdb))[0]')"
    if [[ "$RADARR_MOVIE_JSON" != "null" && -n "$RADARR_MOVIE_JSON" ]]; then
        break
    fi
    sleep 5
done

if [[ "$RADARR_MOVIE_JSON" == "null" || -z "$RADARR_MOVIE_JSON" ]]; then
    fail "Radarr never added the movie"
    exit 1
fi

RADARR_PATH="$(jq -r '.path' <<<"$RADARR_MOVIE_JSON")"
log "Radarr added movie at $RADARR_PATH"

warn "Waiting for qBittorrent activity in category 'radarr'..."
qb_login
QB_TORRENT_JSON=""
QB_NORM_TITLE="$(normalize_title "$MATCH_TITLE")"
SEARCH_POLLS=$(( SEARCH_TIMEOUT / 5 ))
for ((i=0; i<SEARCH_POLLS; i++)); do
    QB_TORRENT_JSON="$(curl -s -b /tmp/qb.cookies 'http://127.0.0.1:8080/api/v2/torrents/info?category=radarr' | jq -c --arg norm "$QB_NORM_TITLE" '
      map(. + {normName: (.name | ascii_downcase | gsub("[^a-z0-9]"; " "))})
      | map(select(.normName | contains($norm)))[0]
    ')"
    if [[ "$QB_TORRENT_JSON" != "null" && -n "$QB_TORRENT_JSON" ]]; then
        break
    fi
    sleep 5
done

if [[ "$QB_TORRENT_JSON" == "null" || -z "$QB_TORRENT_JSON" ]]; then
    fail "qBittorrent never received a matching torrent from Radarr"
else
    QB_NAME="$(jq -r '.name' <<<"$QB_TORRENT_JSON")"
    QB_STATE="$(jq -r '.state' <<<"$QB_TORRENT_JSON")"
    log "qBittorrent received '$QB_NAME' with state '$QB_STATE'"
fi

warn "Waiting for Radarr import..."
IMPORT_POLLS=$(( IMPORT_TIMEOUT / 10 ))
IMPORTED=false
for ((i=0; i<IMPORT_POLLS; i++)); do
    RADARR_MOVIE_JSON="$(curl -s -H "X-Api-Key: $RADARR_KEY" http://127.0.0.1:7878/api/v3/movie | jq -c --argjson tmdb "$TMDB_ID" 'map(select(.tmdbId == $tmdb))[0]')"
    if [[ "$(jq -r '.hasFile' <<<"$RADARR_MOVIE_JSON")" == "true" ]]; then
        IMPORTED=true
        break
    fi
    sleep 10
done

if [[ "$IMPORTED" == true ]]; then
    log "Radarr imported the movie"
else
    fail "Radarr did not import the movie within ${IMPORT_TIMEOUT}s"
fi

HOST_MOVIE_DIR="${RADARR_PATH/\/movies/$MEDIA_DIR\/Movies}"
if [[ -d "$HOST_MOVIE_DIR" ]]; then
    FILE_COUNT="$(find "$HOST_MOVIE_DIR" -type f | wc -l | tr -d ' ')"
    if [[ "$FILE_COUNT" != "0" ]]; then
        log "Movie files exist on disk at $HOST_MOVIE_DIR"
    else
        fail "Movie directory exists but no files were found at $HOST_MOVIE_DIR"
    fi
else
    fail "Expected host movie directory does not exist: $HOST_MOVIE_DIR"
fi

warn "Checking Jellyfin visibility..."
JELLYFIN_QUERY="$(python3 - <<'PY' "$MATCH_TITLE"
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
)"
JELLYFIN_MATCHES="$(curl -s -H "X-Emby-Token: $JELLYFIN_API_KEY" "http://127.0.0.1:8096/Items?searchTerm=${JELLYFIN_QUERY}&Recursive=true&IncludeItemTypes=Movie" | jq --arg title "$MATCH_TITLE" '[.Items[] | select(.Name == $title)] | length')"
if [[ "$JELLYFIN_MATCHES" != "0" ]]; then
    log "Jellyfin can see the movie"
else
    fail "Jellyfin does not show the movie yet"
fi

warn "Checking Bazarr movie catalog..."
BAZARR_MATCHES="$(curl -s -H "X-API-KEY: $BAZARR_API_KEY" "http://127.0.0.1:6767/api/movies?start=0&length=10000" | jq --arg title "$MATCH_TITLE" '[.data[] | select(.title == $title)] | length')"
if [[ "$BAZARR_MATCHES" != "0" ]]; then
    log "Bazarr can see the movie"
else
    fail "Bazarr does not show the movie yet"
fi

echo ""
echo "=============================="
echo "  Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "=============================="
echo ""

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi

