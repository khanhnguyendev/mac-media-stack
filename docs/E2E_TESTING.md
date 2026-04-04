# E2E Testing

This file defines the full-flow test cases for the stack:

`Seerr -> Radarr/Sonarr -> qBittorrent -> import -> Bazarr -> Jellyfin`

Use it after:

- first-time setup
- VPN changes
- qBittorrent reconfiguration
- indexer changes
- path mapping changes
- moving the stack to another Mac

## Scope

There are two layers of testing:

1. **Smoke test**
   Confirms the stack is healthy, VPN binding is correct, port forwarding is active, and containers can see each other.

2. **Manual full-flow test**
   Confirms a real media request can move through Seerr, the *arr apps, qBittorrent, import, Jellyfin, and Bazarr.

## Quick Start

Run the smoke test:

```bash
cd /Users/ryan/workspace/toolings/mac-media-stack
bash scripts/e2e-smoke.sh
```

Run the smoke test plus a real qBittorrent transfer check using the official Ubuntu torrent:

```bash
bash scripts/e2e-smoke.sh --ubuntu-smoke
```

Run a scripted movie request through Seerr -> Radarr -> qBittorrent -> import -> Jellyfin -> Bazarr:

```bash
bash scripts/e2e-request-movie.sh --title "Movie Title"
```

Optional year disambiguation:

```bash
bash scripts/e2e-request-movie.sh --title "Big Buck Bunny" --year 2008
```

## Preconditions

Before running the manual full-flow tests:

- `bash scripts/health-check.sh` returns all green
- Seerr opens at `http://localhost:5055`
- Jellyfin opens at `http://localhost:8096`
- qBittorrent opens at `http://localhost:8080`
- VPN is active and qBittorrent is bound to `tun0`
- Proton NAT-PMP port forwarding is working

## Test Data Guidance

Use a title that is:

- available in TMDb/TVDb
- legal or safe for your environment
- known to have active peers if you want to validate the actual download/import path

For smoke network validation only, prefer the official Ubuntu torrent via `--ubuntu-smoke`.

## TC-001: Stack Health Smoke Test

Goal:
Validate that the infrastructure is ready for a request flow.

Steps:

1. Run:

```bash
bash scripts/e2e-smoke.sh
```

Expected:

- health check passes
- Seerr/Jellyfin/Radarr/Sonarr/Prowlarr/qBittorrent APIs are reachable
- qBittorrent uses `tun0`
- qBittorrent listen port is not the static default `6881`
- Bazarr reaches `radarr` and `sonarr`
- Bazarr default profile is `English + Vietnamese` for both movies and series
- Radarr and Sonarr can see `/downloads` and library paths

## TC-002: qBittorrent Live Download Smoke

Goal:
Confirm peer connectivity and transfer through the VPN tunnel.

Steps:

1. Run:

```bash
bash scripts/e2e-smoke.sh --ubuntu-smoke
```

Expected:

- the official Ubuntu torrent is added
- its state changes from `stalledDL` or metadata state into `downloading`
- downloaded bytes become greater than zero
- the test torrent is removed automatically at the end

## TC-003: Seerr -> Radarr -> qBittorrent Movie Flow

Goal:
Validate the movie request pipeline.

Scripted option:

```bash
bash scripts/e2e-request-movie.sh --title "Movie Title" --year 2023
```

Steps:

1. Open `http://localhost:5055`
2. Search for a test movie
3. Submit a request
4. Open Radarr at `http://localhost:7878`
5. Confirm the movie appears in Radarr and is monitored
6. Open qBittorrent at `http://localhost:8080`
7. Confirm a torrent appears under category `radarr`

Expected:

- Seerr marks the request as approved/processing
- Radarr adds the movie at `/movies/<Title (Year)>`
- qBittorrent receives a torrent with category `radarr`
- if peers exist, download starts

Failure hints:

- If Seerr shows a request but Radarr never adds it: check Seerr Radarr settings
- If Radarr adds it but qBittorrent stays empty: inspect Radarr search/manual search results
- If qBittorrent shows `stalled` with no transfer: check peers, VPN, and port forwarding

## TC-004: Seerr -> Sonarr -> qBittorrent TV Flow

Goal:
Validate the TV request pipeline.

Steps:

1. Open `http://localhost:5055`
2. Search for a test TV show
3. Submit a request for one season
4. Open Sonarr at `http://localhost:8989`
5. Confirm the series appears in Sonarr and the requested season is monitored
6. Open qBittorrent at `http://localhost:8080`
7. Confirm a torrent appears under category `tv-sonarr`

Expected:

- Seerr creates the request
- Sonarr adds the series at `/tv/<Show Name>`
- qBittorrent receives a torrent with category `tv-sonarr`
- if peers exist, download starts

Failure hints:

- If Sonarr finds releases but grabs none, use Sonarr manual search to inspect rejection reasons
- If Sonarr reports bad remote path mapping, verify `/downloads/complete/tv-sonarr` exists in both qBittorrent and Sonarr containers

## TC-005: Import Into Library

Goal:
Confirm completed downloads are imported to the final media library.

Movie expected destination:

- host: `/Users/ryan/Media/Movies`
- container: `/movies`

TV expected destination:

- host: `/Users/ryan/Media/TV Shows`
- container: `/tv`

Steps:

1. Wait for a test download to finish
2. Open Radarr or Sonarr queue/activity
3. Confirm the item is imported
4. Check the destination folder on disk

Expected:

- download disappears from the import queue
- final file appears in the library folder
- qBittorrent retains or removes the original based on client settings/category behavior

## TC-006: Jellyfin Detection

Goal:
Confirm imported media becomes visible in Jellyfin.

Steps:

1. Open `http://localhost:8096`
2. Trigger a library scan if needed
3. Find the newly imported movie/show

Expected:

- the imported item appears in the correct Jellyfin library

Failure hints:

- If Jellyfin does not see the item, verify library paths:
  - Movies: `/data/movies`
  - TV: `/data/tvshows`

## TC-007: Bazarr Subtitle Flow

Goal:
Confirm Bazarr can see the imported item and perform subtitle work.

Important:

- Bazarr acts after import, not at request time
- This is why Bazarr should be validated after TC-005 and TC-006

Steps:

1. Open Bazarr at `http://localhost:6767`
2. Confirm the new movie/show appears in Bazarr
3. Trigger a subtitle search manually if needed
4. Check whether subtitle files are downloaded into the media folder

Expected:

- Bazarr lists the imported media
- subtitle search succeeds for at least one language/profile you configured
- subtitle files appear alongside the media item

Failure hints:

- If Bazarr is empty, check that it points to `radarr` and `sonarr`, not `127.0.0.1`
- If Bazarr sees the item but subtitle search fails, inspect subtitle provider configuration rather than the core stack

## Current Known Caveats

- Seerr can be healthy while its Docker health state briefly says `starting` or `unhealthy`
- Bazarr relies on import completion; it is not part of the initial request/download hop
- A successful request flow does not guarantee a successful download if the chosen torrent has weak or dead peers
- Jellyfin sync can misclassify badly organized media; keep movies in Movies and shows in TV Shows
