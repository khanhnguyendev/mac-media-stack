# Jellyfin + ProtonVPN Run Guide

This guide assumes:

- You are in `/Users/ryan/workspace/toolings/mac-media-stack`
- Docker Desktop is installed and running
- You already generated a ProtonVPN WireGuard config
- You want to use `Jellyfin`

Important note:

- This repo is designed around ProtonVPN + Gluetun.
- If you are on the Proton free plan, the stack may still be limited for torrent/P2P behavior even if the WireGuard config works.

## 1. Go to the repo

```bash
cd /Users/ryan/workspace/toolings/mac-media-stack
```

## 2. Run initial setup

This creates the media folders and `.env` file.

```bash
bash scripts/setup.sh
```

Expected media folders:

- `~/Media/Downloads`
- `~/Media/Movies`
- `~/Media/TV Shows`
- `~/Media/config`

## 3. Fill in `.env`

Open the config:

```bash
open -a TextEdit .env
```

Set these values:

```env
TIMEZONE=Asia/Ho_Chi_Minh
MEDIA_SERVER=jellyfin
SEERR_BIND_IP=127.0.0.1
WIREGUARD_PRIVATE_KEY=YOUR_PRIVATE_KEY
WIREGUARD_ADDRESSES=YOUR_ADDRESS
```

Example:

```env
TIMEZONE=Asia/Ho_Chi_Minh
MEDIA_SERVER=jellyfin
SEERR_BIND_IP=127.0.0.1
WIREGUARD_PRIVATE_KEY=abc123exampleprivatekey=
WIREGUARD_ADDRESSES=10.2.0.2/32
```

How to map from the Proton `.conf` file:

- `PrivateKey = ...` -> `WIREGUARD_PRIVATE_KEY=...`
- `Address = ...` -> `WIREGUARD_ADDRESSES=...`

Do not change these unless you have a reason:

- `PUID`
- `PGID`
- `MEDIA_DIR`

## 4. Validate before startup

```bash
bash scripts/doctor.sh
```

If you see `FAIL`, fix those items first.

Most common failures:

- Docker Desktop is not running
- `.env` still contains placeholder VPN values
- Another app is already using one of these ports:
  - `5055`
  - `8080`
  - `7878`
  - `8989`
  - `9696`
  - `6767`
  - `8096`

## 5. Start the stack

Because you chose Jellyfin, use the Jellyfin profile:

```bash
docker compose --profile jellyfin up -d
```

First run can take a few minutes because it downloads the container images.

## 6. Check health

```bash
bash scripts/health-check.sh
```

If qBittorrent or Gluetun fails, inspect logs:

```bash
docker compose --profile jellyfin logs --tail=100
```

If you only want Gluetun logs:

```bash
docker logs gluetun --tail=100
```

## 7. Auto-configure the apps

Run:

```bash
bash scripts/configure.sh
```

This script will:

- wait for services
- configure qBittorrent
- configure Radarr and Sonarr
- configure Prowlarr
- ask you to connect Seerr

## 8. Complete Seerr login

When prompted by `scripts/configure.sh`, open:

```text
http://localhost:5055
```

Then:

1. Click `Use your Jellyfin account`
2. Enter Jellyfin URL as `http://jellyfin:8096`
3. Sign in after Jellyfin is ready
4. Return to Terminal and press Enter when the script asks

## 9. Complete Jellyfin first-run setup

Open:

```text
http://localhost:8096
```

Finish the setup wizard and add these libraries:

- Movies -> `/data/movies`
- TV Shows -> `/data/tvshows`

Create your Jellyfin admin account during that wizard.

## 10. Where to use the stack

Main URLs:

- Seerr: `http://localhost:5055`
- Jellyfin: `http://localhost:8096`
- qBittorrent: `http://localhost:8080`
- Radarr: `http://localhost:7878`
- Sonarr: `http://localhost:8989`
- Prowlarr: `http://localhost:9696`
- Bazarr: `http://localhost:6767`

Daily flow:

1. Request media in Seerr
2. Radarr/Sonarr search via Prowlarr
3. qBittorrent downloads through Gluetun
4. Files land in `~/Media`
5. Jellyfin scans and plays them

## 11. Credentials and saved state

After `scripts/configure.sh`, first-run credentials are saved at:

```text
~/Media/state/first-run-credentials.txt
```

That file contains the generated qBittorrent password and API keys.

## 12. Useful commands

Start:

```bash
docker compose --profile jellyfin up -d
```

Stop:

```bash
docker compose --profile jellyfin down
```

Restart:

```bash
docker compose --profile jellyfin restart
```

See running containers:

```bash
docker ps
```

See logs:

```bash
docker compose --profile jellyfin logs -f
```

Re-run health check:

```bash
bash scripts/health-check.sh
```

Re-run auto-config if needed:

```bash
bash scripts/configure.sh
```

## 13. If Proton free plan does not work

Possible symptoms:

- `gluetun` never becomes healthy
- qBittorrent is unreachable
- downloads do not start
- health check reports VPN failure

If that happens, the most likely cause is Proton free-plan limitations with this torrent-oriented setup.

Your options then are:

1. Upgrade ProtonVPN
2. Modify the repo to a no-VPN test mode
3. Use the stack only for local media serving first

## 14. Recommended exact command order

If you just want the shortest correct sequence:

```bash
cd /Users/ryan/workspace/toolings/mac-media-stack
bash scripts/setup.sh
open -a TextEdit .env
bash scripts/doctor.sh
docker compose --profile jellyfin up -d
bash scripts/health-check.sh
bash scripts/configure.sh
```
