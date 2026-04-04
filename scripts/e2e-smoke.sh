#!/bin/bash
# End-to-end smoke test for the media stack.
# Validates live service health and optionally tests qBittorrent peer connectivity
# using the official Ubuntu torrent.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UBUNTU_SMOKE=false
UBUNTU_TORRENT_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.4-desktop-amd64.iso.torrent"
UBUNTU_TEST_CATEGORY="test-ubuntu"
UBUNTU_TEST_NAME="ubuntu-24.04.4-desktop-amd64.iso"

usage() {
    cat <<EOF
Usage: bash scripts/e2e-smoke.sh [OPTIONS]

Options:
  --ubuntu-smoke   Add the official Ubuntu torrent to qBittorrent and verify it starts downloading
  --help           Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ubuntu-smoke)
            UBUNTU_SMOKE=true
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

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    echo -e "${RED}Error:${NC} .env not found."
    exit 1
fi

source "$SCRIPT_DIR/.env"

MEDIA_DIR="${MEDIA_DIR:-$HOME/Media}"
CREDS_FILE="$MEDIA_DIR/state/first-run-credentials.txt"
SEERR_SETTINGS="$MEDIA_DIR/config/seerr/settings.json"
BAZARR_CONFIG="$MEDIA_DIR/config/bazarr/config/config.yaml"

if [[ ! -f "$CREDS_FILE" ]]; then
    echo -e "${RED}Error:${NC} credentials file not found at $CREDS_FILE"
    exit 1
fi

if [[ ! -f "$SEERR_SETTINGS" ]]; then
    echo -e "${RED}Error:${NC} Seerr settings not found at $SEERR_SETTINGS"
    exit 1
fi

log() { echo -e "  ${GREEN}OK${NC}  $1"; }
warn() { echo -e "  ${YELLOW}..${NC}  $1"; }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; }

QB_PASSWORD="$(sed -n 's/^qBittorrent Password: //p' "$CREDS_FILE" | head -1)"
RADARR_KEY="$(sed -n 's/^Radarr API Key: //p' "$CREDS_FILE" | head -1)"
SONARR_KEY="$(sed -n 's/^Sonarr API Key: //p' "$CREDS_FILE" | head -1)"
PROWLARR_KEY="$(sed -n 's/^Prowlarr API Key: //p' "$CREDS_FILE" | head -1)"
SEERR_API_KEY="$(jq -r '.main.apiKey' "$SEERR_SETTINGS")"

PASS=0
FAILS=0

record_ok() {
    log "$1"
    PASS=$((PASS + 1))
}

record_fail() {
    fail "$1"
    FAILS=$((FAILS + 1))
}

qb_login() {
    curl -s -c /tmp/qb.cookies http://127.0.0.1:8080/api/v2/auth/login \
        --data-urlencode "username=${QBITTORRENT_USERNAME:-admin}" \
        --data-urlencode "password=$QB_PASSWORD" >/dev/null
}

cleanup_ubuntu_test() {
    qb_login
    local hash
    hash="$(curl -s -b /tmp/qb.cookies "http://127.0.0.1:8080/api/v2/torrents/info?category=${UBUNTU_TEST_CATEGORY}" | jq -r '.[0].hash // empty')"
    if [[ -n "$hash" ]]; then
        curl -s -b /tmp/qb.cookies http://127.0.0.1:8080/api/v2/torrents/delete \
            --data-urlencode "hashes=$hash" \
            --data-urlencode "deleteFiles=true" >/dev/null
    fi
}

trap cleanup_ubuntu_test EXIT

echo ""
echo "=============================="
echo "  Media Stack E2E Smoke Test"
echo "=============================="
echo ""

warn "Running base health check..."
if bash "$SCRIPT_DIR/scripts/health-check.sh" >/tmp/e2e-health.txt 2>&1; then
    record_ok "Base stack health check passed"
else
    cat /tmp/e2e-health.txt
    record_fail "Base stack health check failed"
fi

warn "Checking Seerr integration settings..."
SEERR_RADARR_HOST="$(jq -r '.radarr[0].hostname // empty' "$SEERR_SETTINGS")"
SEERR_SONARR_HOST="$(jq -r '.sonarr[0].hostname // empty' "$SEERR_SETTINGS")"
SEERR_JELLYFIN_HOST="$(jq -r '.jellyfin.ip // empty' "$SEERR_SETTINGS")"
if [[ "$SEERR_RADARR_HOST" == "radarr" && "$SEERR_SONARR_HOST" == "sonarr" && "$SEERR_JELLYFIN_HOST" == "jellyfin" ]]; then
    record_ok "Seerr points to jellyfin/radarr/sonarr container hosts"
else
    record_fail "Seerr integration hosts are not using container DNS names"
fi

warn "Checking Bazarr integration settings..."
BAZARR_RADARR_HOST="$(sed -n '/^radarr:/,/^[^ ]/p' "$BAZARR_CONFIG" | sed -n 's/^  ip: //p' | head -1)"
BAZARR_SONARR_HOST="$(sed -n '/^sonarr:/,/^[^ ]/p' "$BAZARR_CONFIG" | sed -n 's/^  ip: //p' | head -1)"
if [[ "$BAZARR_RADARR_HOST" == "radarr" && "$BAZARR_SONARR_HOST" == "sonarr" ]]; then
    record_ok "Bazarr points to radarr/sonarr container hosts"
else
    record_fail "Bazarr still points to localhost or another invalid host"
fi

BAZARR_API_KEY="$(sed -n '/^auth:/,/^[^ ]/p' "$BAZARR_CONFIG" | sed -n 's/^  apikey: //p' | head -1)"
BAZARR_SETTINGS="$(curl -s -H "X-API-KEY: $BAZARR_API_KEY" http://127.0.0.1:6767/api/system/settings)"
BAZARR_PROFILES="$(curl -s -H "X-API-KEY: $BAZARR_API_KEY" http://127.0.0.1:6767/api/system/languages/profiles)"
if echo "$BAZARR_SETTINGS" | jq -e '.general.single_language == false and .general.movie_default_enabled == true and .general.movie_default_profile == 1 and .general.serie_default_enabled == true and .general.serie_default_profile == 1' >/dev/null &&
   echo "$BAZARR_PROFILES" | jq -e 'map(select(.name == "English + Vietnamese")) | length == 1' >/dev/null; then
    record_ok "Bazarr default subtitle profile is English + Vietnamese for movies and series"
else
    record_fail "Bazarr subtitle defaults are not configured as expected"
fi

warn "Checking app API health..."
if [[ "$(curl -s -H "X-Api-Key: $RADARR_KEY" http://127.0.0.1:7878/api/v3/health | jq 'map(select(.type == "error")) | length')" == "0" ]]; then
    record_ok "Radarr API reachable"
else
    record_fail "Radarr API reported errors"
fi

if [[ "$(curl -s -H "X-Api-Key: $SONARR_KEY" http://127.0.0.1:8989/api/v3/health | jq 'map(select(.type == "error")) | length')" == "0" ]]; then
    record_ok "Sonarr API reachable"
else
    record_fail "Sonarr API reported errors"
fi

if [[ "$(curl -s -H "X-Api-Key: $PROWLARR_KEY" http://127.0.0.1:9696/api/v1/health | jq 'length')" == "0" ]]; then
    record_ok "Prowlarr API reachable"
else
    record_fail "Prowlarr health reported issues"
fi

if curl -s -H "X-Api-Key: $SEERR_API_KEY" http://127.0.0.1:5055/api/v1/settings/main >/dev/null; then
    record_ok "Seerr API reachable"
else
    record_fail "Seerr API not reachable"
fi

warn "Checking qBittorrent VPN binding and categories..."
qb_login
QB_PREFS="$(curl -s -b /tmp/qb.cookies http://127.0.0.1:8080/api/v2/app/preferences)"
QB_CATEGORIES="$(curl -s -b /tmp/qb.cookies http://127.0.0.1:8080/api/v2/torrents/categories)"
QB_INTERFACE="$(echo "$QB_PREFS" | jq -r '.current_network_interface')"
QB_LISTEN_PORT="$(echo "$QB_PREFS" | jq -r '.listen_port')"
if [[ "$QB_INTERFACE" == "tun0" && "$QB_LISTEN_PORT" != "6881" && "$QB_LISTEN_PORT" != "0" ]]; then
    record_ok "qBittorrent bound to tun0 with forwarded port $QB_LISTEN_PORT"
else
    record_fail "qBittorrent is not using tun0 and a forwarded port"
fi

if echo "$QB_CATEGORIES" | jq -e '.radarr.savePath == "/downloads/complete/radarr" and .["tv-sonarr"].savePath == "/downloads/complete/tv-sonarr"' >/dev/null; then
    record_ok "qBittorrent categories point to expected download paths"
else
    record_fail "qBittorrent category paths are incorrect"
fi

warn "Checking container-visible download paths..."
if docker exec radarr sh -lc 'test -d /downloads/complete/radarr && test -d /movies' >/dev/null &&
   docker exec sonarr sh -lc 'test -d /downloads/complete/tv-sonarr && test -d /tv' >/dev/null; then
    record_ok "Radarr/Sonarr can see both library and download paths"
else
    record_fail "Radarr/Sonarr path mapping is broken"
fi

warn "Checking Bazarr can reach Sonarr and Radarr..."
if docker exec bazarr sh -lc 'wget -qO- http://sonarr:8989/ping >/dev/null && wget -qO- http://radarr:7878/ping >/dev/null'; then
    record_ok "Bazarr can reach Sonarr and Radarr over Docker DNS"
else
    record_fail "Bazarr cannot reach Sonarr and/or Radarr"
fi

if [[ "$UBUNTU_SMOKE" == true ]]; then
    warn "Running Ubuntu torrent smoke test..."
    mkdir -p "$MEDIA_DIR/Downloads/complete/$UBUNTU_TEST_CATEGORY"
    cleanup_ubuntu_test

    qb_login
    curl -s -b /tmp/qb.cookies http://127.0.0.1:8080/api/v2/torrents/add \
        --data-urlencode "urls=$UBUNTU_TORRENT_URL" \
        --data-urlencode "category=$UBUNTU_TEST_CATEGORY" \
        --data-urlencode "savepath=/downloads/complete/$UBUNTU_TEST_CATEGORY" >/dev/null

    started=false
    for _ in {1..12}; do
        state_json="$(curl -s -b /tmp/qb.cookies "http://127.0.0.1:8080/api/v2/torrents/info?category=${UBUNTU_TEST_CATEGORY}")"
        state="$(echo "$state_json" | jq -r '.[0].state // empty')"
        downloaded="$(echo "$state_json" | jq -r '.[0].downloaded // 0')"
        if [[ "$state" == "downloading" || "$downloaded" != "0" ]]; then
            started=true
            break
        fi
        sleep 5
    done

    if [[ "$started" == true ]]; then
        record_ok "Ubuntu torrent started transferring through qBittorrent"
    else
        record_fail "Ubuntu torrent did not start transferring within 60 seconds"
    fi
fi

echo ""
echo "=============================="
echo "  Results: ${PASS} passed, ${FAILS} failed"
echo "=============================="
echo ""

if [[ $FAILS -gt 0 ]]; then
    exit 1
fi
