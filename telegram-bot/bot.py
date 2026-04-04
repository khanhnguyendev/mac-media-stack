import os
import logging
import asyncio
import json
import httpx
from aiohttp import web
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, BotCommand, Bot
from telegram.ext import (
    Application,
    CommandHandler,
    CallbackQueryHandler,
    ContextTypes,
)
from telegram.constants import ParseMode

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
ALLOWED_CHAT_IDS = {
    int(x) for x in os.environ.get("TELEGRAM_CHAT_ID", "").split(",") if x.strip()
}

RADARR_URL = os.environ.get("RADARR_URL", "http://radarr:7878")
RADARR_KEY = os.environ.get("RADARR_API_KEY", "")
SONARR_URL = os.environ.get("SONARR_URL", "http://sonarr:8989")
SONARR_KEY = os.environ.get("SONARR_API_KEY", "")


class ArrApiError(Exception):
    pass


def _mask_secret(secret: str) -> str:
    if not secret:
        return "<missing>"
    if len(secret) <= 8:
        return "*" * len(secret)
    return f"{secret[:4]}...{secret[-4:]}"


def _api_headers(api_key: str) -> dict[str, str]:
    return {"X-Api-Key": api_key}


def _ensure_success(resp: httpx.Response, service_name: str) -> None:
    if resp.is_success:
        return

    if resp.status_code == 401:
        raise ArrApiError(
            f"{service_name} rejected the configured API key (401 Unauthorized)."
        )

    snippet = resp.text.strip().replace("\n", " ")[:160]
    detail = f" Response: {snippet}" if snippet else ""
    raise ArrApiError(
        f"{service_name} API request failed with HTTP {resp.status_code}.{detail}"
    )


def _json_or_raise(resp: httpx.Response, service_name: str):
    _ensure_success(resp, service_name)
    try:
        return resp.json()
    except json.JSONDecodeError as exc:
        raise ArrApiError(
            f"{service_name} returned a non-JSON response."
        ) from exc


def authorized(func):
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        chat_id = update.effective_chat.id
        if ALLOWED_CHAT_IDS and chat_id not in ALLOWED_CHAT_IDS:
            await update.message.reply_text("Unauthorized.")
            return
        return await func(update, context)
    return wrapper


def authorized_callback(func):
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        chat_id = update.effective_chat.id
        if ALLOWED_CHAT_IDS and chat_id not in ALLOWED_CHAT_IDS:
            await update.callback_query.answer("Unauthorized.")
            return
        return await func(update, context)
    return wrapper


@authorized
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "\U0001F3AC *Media Bot*\n\n"
        "\U0001F3A5 /movie `<title>` \u2014 Search & download a movie\n"
        "\U0001F4FA /tv `<title>` \u2014 Search & download a TV show\n"
        "\U0001F4E5 /status \u2014 Check download queue\n"
        "\U0001F4DA /library \u2014 List downloaded movies & shows\n"
        "\u2753 /help \u2014 Show this message",
        parse_mode=ParseMode.MARKDOWN,
    )


@authorized
async def movie_search(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = " ".join(context.args)
    if not query:
        await update.message.reply_text("Usage: /movie <title>")
        return

    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.get(
            f"{RADARR_URL}/api/v3/movie/lookup",
            params={"term": query},
            headers=_api_headers(RADARR_KEY),
        )
        results = _json_or_raise(resp, "Radarr")

    if not results:
        await update.message.reply_text(f"\u274C No results for `{query}`.", parse_mode=ParseMode.MARKDOWN)
        return

    results = results[:8]
    buttons = []
    for i, m in enumerate(results):
        year = m.get("year", "?")
        title = m.get("title", "Unknown")
        tmdb = m.get("tmdbId", 0)
        label = f"{title} ({year})"
        buttons.append(
            [InlineKeyboardButton(label, callback_data=f"addmovie:{tmdb}")]
        )

    context.user_data["movie_results"] = {m["tmdbId"]: m for m in results}
    await update.message.reply_text(
        f"\U0001F50D *Results for* `{query}`\nTap to download:",
        reply_markup=InlineKeyboardMarkup(buttons),
        parse_mode=ParseMode.MARKDOWN,
    )


@authorized_callback
async def add_movie_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()

    tmdb_id = int(query.data.split(":")[1])
    movie = context.user_data.get("movie_results", {}).get(tmdb_id)
    if not movie:
        await query.edit_message_text("Session expired. Search again with /movie.")
        return

    async with httpx.AsyncClient(timeout=15) as client:
        # Get root folder
        resp = await client.get(
            f"{RADARR_URL}/api/v3/rootfolder",
            headers=_api_headers(RADARR_KEY),
        )
        root_folders = _json_or_raise(resp, "Radarr")
        root_path = root_folders[0]["path"] if root_folders else "/movies"

        # Get quality profiles
        resp = await client.get(
            f"{RADARR_URL}/api/v3/qualityprofile",
            headers=_api_headers(RADARR_KEY),
        )
        profiles = _json_or_raise(resp, "Radarr")
        profile_id = profiles[0]["id"] if profiles else 1

        payload = {
            "title": movie["title"],
            "tmdbId": movie["tmdbId"],
            "year": movie.get("year"),
            "qualityProfileId": profile_id,
            "rootFolderPath": root_path,
            "monitored": True,
            "addOptions": {"searchForMovie": True},
            "images": movie.get("images", []),
        }

        resp = await client.post(
            f"{RADARR_URL}/api/v3/movie",
            json=payload,
            headers=_api_headers(RADARR_KEY),
        )

        if resp.status_code == 400 and "already been added" in resp.text.lower():
            await query.edit_message_text(
                f"\u2139\uFE0F *{movie['title']}* is already in your library.",
                parse_mode=ParseMode.MARKDOWN,
            )
            return

        _ensure_success(resp, "Radarr")

    await query.edit_message_text(
        f"\u2705 *{movie['title']}* ({movie.get('year', '?')})\n"
        f"Added to Radarr \u2014 searching for downloads\u2026",
        parse_mode=ParseMode.MARKDOWN,
    )


@authorized
async def tv_search(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = " ".join(context.args)
    if not query:
        await update.message.reply_text("Usage: /tv <title>")
        return

    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.get(
            f"{SONARR_URL}/api/v3/series/lookup",
            params={"term": query},
            headers=_api_headers(SONARR_KEY),
        )
        results = _json_or_raise(resp, "Sonarr")

    if not results:
        await update.message.reply_text(f"\u274C No results for `{query}`.", parse_mode=ParseMode.MARKDOWN)
        return

    results = results[:8]
    buttons = []
    for m in results:
        year = m.get("year", "?")
        title = m.get("title", "Unknown")
        tvdb = m.get("tvdbId", 0)
        seasons = m.get("seasonCount", "?")
        label = f"{title} ({year}) \u2022 {seasons}S"
        buttons.append(
            [InlineKeyboardButton(label, callback_data=f"addtv:{tvdb}")]
        )

    context.user_data["tv_results"] = {m["tvdbId"]: m for m in results}
    await update.message.reply_text(
        f"\U0001F50D *Results for* `{query}`\nTap to download:",
        reply_markup=InlineKeyboardMarkup(buttons),
        parse_mode=ParseMode.MARKDOWN,
    )


@authorized_callback
async def add_tv_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()

    tvdb_id = int(query.data.split(":")[1])
    show = context.user_data.get("tv_results", {}).get(tvdb_id)
    if not show:
        await query.edit_message_text("Session expired. Search again with /tv.")
        return

    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.get(
            f"{SONARR_URL}/api/v3/rootfolder",
            headers=_api_headers(SONARR_KEY),
        )
        root_folders = _json_or_raise(resp, "Sonarr")
        root_path = root_folders[0]["path"] if root_folders else "/tv"

        resp = await client.get(
            f"{SONARR_URL}/api/v3/qualityprofile",
            headers=_api_headers(SONARR_KEY),
        )
        profiles = _json_or_raise(resp, "Sonarr")
        profile_id = profiles[0]["id"] if profiles else 1

        payload = {
            "title": show["title"],
            "tvdbId": show["tvdbId"],
            "qualityProfileId": profile_id,
            "rootFolderPath": root_path,
            "monitored": True,
            "seasonFolder": True,
            "seasons": show.get("seasons", []),
            "addOptions": {
                "monitor": "all",
                "searchForMissingEpisodes": True,
                "searchForCutoffUnmetEpisodes": False,
            },
            "images": show.get("images", []),
        }

        resp = await client.post(
            f"{SONARR_URL}/api/v3/series",
            json=payload,
            headers=_api_headers(SONARR_KEY),
        )

        if resp.status_code == 400 and "already been added" in resp.text.lower():
            await query.edit_message_text(
                f"\u2139\uFE0F *{show['title']}* is already in your library.",
                parse_mode=ParseMode.MARKDOWN,
            )
            return

        _ensure_success(resp, "Sonarr")

    await query.edit_message_text(
        f"\u2705 *{show['title']}* ({show.get('year', '?')})\n"
        f"Added to Sonarr \u2014 searching for downloads\u2026",
        parse_mode=ParseMode.MARKDOWN,
    )


def _progress_bar(pct: float, width: int = 10) -> str:
    filled = round(pct / 100 * width)
    return "\u2588" * filled + "\u2591" * (width - filled)


def _format_eta(seconds: float) -> str:
    if seconds <= 0:
        return "\u221E"
    h, remainder = divmod(int(seconds), 3600)
    m, s = divmod(remainder, 60)
    if h > 0:
        return f"{h}h{m:02d}m"
    if m > 0:
        return f"{m}m{s:02d}s"
    return f"{s}s"


def _format_queue_item(r: dict, kind: str) -> str:
    title = r.get("title", "?")[:45]
    size = r.get("size", 0)
    sizeleft = r.get("sizeleft", 0)
    pct = ((size - sizeleft) / size * 100) if size > 0 else 0
    size_gb = size / 1e9

    status = r.get("trackedDownloadStatus", "")
    state = r.get("trackedDownloadState", r.get("status", ""))

    if status == "warning":
        icon = "\u26A0\uFE0F"
    elif state == "downloading":
        icon = "\u2B07\uFE0F"
    elif state in ("importPending", "importing"):
        icon = "\U0001F4E6"
    elif pct >= 100:
        icon = "\u2705"
    else:
        icon = "\u23F3"

    eta_str = ""
    eta_secs = r.get("timeleft")
    if eta_secs and state == "downloading":
        # timeleft is "HH:MM:SS" string
        parts = str(eta_secs).split(":")
        try:
            total_s = int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
            eta_str = f" \u2022 ETA {_format_eta(total_s)}"
        except (ValueError, IndexError):
            pass

    bar = _progress_bar(pct)
    label = "\U0001F3A5" if kind == "movie" else "\U0001F4FA"

    return (
        f"{icon} {label} *{title}*\n"
        f"   {bar} {pct:.0f}% of {size_gb:.1f}GB{eta_str}"
    )


@authorized
async def status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    items = []

    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.get(
            f"{RADARR_URL}/api/v3/queue",
            params={"pageSize": 20},
            headers=_api_headers(RADARR_KEY),
        )
        for r in _json_or_raise(resp, "Radarr").get("records", []):
            items.append(_format_queue_item(r, "movie"))

        resp = await client.get(
            f"{SONARR_URL}/api/v3/queue",
            params={"pageSize": 20},
            headers=_api_headers(SONARR_KEY),
        )
        for r in _json_or_raise(resp, "Sonarr").get("records", []):
            items.append(_format_queue_item(r, "tv"))

    if not items:
        await update.message.reply_text("\u2705 No active downloads.")
    else:
        header = f"\U0001F4E5 *{len(items)} active download(s)*\n\n"
        await update.message.reply_text(
            header + "\n\n".join(items),
            parse_mode=ParseMode.MARKDOWN,
        )


@authorized
async def library(update: Update, context: ContextTypes.DEFAULT_TYPE):
    lines = []

    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.get(
            f"{RADARR_URL}/api/v3/movie",
            headers=_api_headers(RADARR_KEY),
        )
        movies = _json_or_raise(resp, "Radarr")
        downloaded = [m for m in movies if m.get("hasFile")]
        if downloaded:
            lines.append(f"\U0001F3A5 *Movies* ({len(downloaded)})")
            for m in sorted(downloaded, key=lambda x: x.get("title", ""))[:30]:
                lines.append(f"  \u2022 {m['title']} ({m.get('year', '?')})")

        resp = await client.get(
            f"{SONARR_URL}/api/v3/series",
            headers=_api_headers(SONARR_KEY),
        )
        shows = _json_or_raise(resp, "Sonarr")
        if shows:
            lines.append(f"\n\U0001F4FA *TV Shows* ({len(shows)})")
            for s in sorted(shows, key=lambda x: x.get("title", ""))[:30]:
                eps = s.get("episodeFileCount", 0)
                total = s.get("episodeCount", 0)
                pct = (eps / total * 100) if total > 0 else 0
                check = "\u2705" if eps == total else f"{pct:.0f}%"
                lines.append(
                    f"  \u2022 {s['title']} ({s.get('year','?')}) \u2014 {eps}/{total} eps [{check}]"
                )

    if not lines:
        await update.message.reply_text("\U0001F4DA Library is empty.")
    else:
        await update.message.reply_text(
            "\U0001F4DA *Library*\n\n" + "\n".join(lines),
            parse_mode=ParseMode.MARKDOWN,
        )


WEBHOOK_PORT = int(os.environ.get("WEBHOOK_PORT", "8282"))


async def _notify_all(bot: Bot, text: str):
    for chat_id in ALLOWED_CHAT_IDS:
        try:
            await bot.send_message(chat_id, text, parse_mode=ParseMode.MARKDOWN)
        except Exception as e:
            logger.error(f"Failed to notify {chat_id}: {e}")


async def handle_radarr_webhook(request: web.Request) -> web.Response:
    bot = request.app["bot"]
    try:
        data = await request.json()
    except Exception:
        return web.Response(status=400)

    event = data.get("eventType", "")
    movie = data.get("movie", {})
    title = movie.get("title", "Unknown")
    year = movie.get("year", "?")

    if event == "Download":
        is_upgrade = data.get("isUpgrade", False)
        quality = data.get("movieFile", {}).get("quality", {}).get("quality", {}).get("name", "")
        action = "Upgraded" if is_upgrade else "Downloaded"
        msg = (
            f"\u2705 \U0001F3A5 *Movie {action}*\n\n"
            f"*{title}* ({year})\n"
            f"Quality: {quality}"
        )
        await _notify_all(bot, msg)
    elif event == "Grab":
        msg = (
            f"\u2B07\uFE0F \U0001F3A5 *Movie Grabbed*\n\n"
            f"*{title}* ({year})\n"
            f"Downloading\u2026"
        )
        await _notify_all(bot, msg)

    return web.Response(text="ok")


async def handle_sonarr_webhook(request: web.Request) -> web.Response:
    bot = request.app["bot"]
    try:
        data = await request.json()
    except Exception:
        return web.Response(status=400)

    event = data.get("eventType", "")
    series = data.get("series", {})
    title = series.get("title", "Unknown")

    if event == "Download":
        is_upgrade = data.get("isUpgrade", False)
        eps = data.get("episodes", [])
        ep_list = ", ".join(
            f"S{e.get('seasonNumber', 0):02d}E{e.get('episodeNumber', 0):02d}"
            for e in eps
        ) or "?"
        quality = data.get("episodeFile", {}).get("quality", {}).get("quality", {}).get("name", "")
        action = "Upgraded" if is_upgrade else "Downloaded"
        msg = (
            f"\u2705 \U0001F4FA *Episode {action}*\n\n"
            f"*{title}* \u2014 {ep_list}\n"
            f"Quality: {quality}"
        )
        await _notify_all(bot, msg)
    elif event == "Grab":
        eps = data.get("episodes", [])
        ep_list = ", ".join(
            f"S{e.get('seasonNumber', 0):02d}E{e.get('episodeNumber', 0):02d}"
            for e in eps
        ) or "?"
        msg = (
            f"\u2B07\uFE0F \U0001F4FA *Episode Grabbed*\n\n"
            f"*{title}* \u2014 {ep_list}\n"
            f"Downloading\u2026"
        )
        await _notify_all(bot, msg)

    return web.Response(text="ok")


async def run_webhook_server(bot: Bot):
    app = web.Application()
    app["bot"] = bot
    app.router.add_post("/radarr", handle_radarr_webhook)
    app.router.add_post("/sonarr", handle_sonarr_webhook)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", WEBHOOK_PORT)
    await site.start()
    logger.info(f"Webhook server listening on port {WEBHOOK_PORT}")


async def _ensure_webhook(api_url: str, api_key: str, name: str, hook_path: str):
    """Add a webhook notification to Radarr/Sonarr if not already present."""
    if not api_key:
        raise ArrApiError(f"{name} API key is missing.")

    webhook_url = f"http://telegram-bot:{WEBHOOK_PORT}{hook_path}"
    headers = _api_headers(api_key)

    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(f"{api_url}/api/v3/notification", headers=headers)
        existing = _json_or_raise(resp, name)
        for n in existing:
            # Check if our webhook already exists
            url_field = next(
                (f for f in n.get("fields", []) if f.get("name") == "url"),
                None,
            )
            if url_field and url_field.get("value") == webhook_url:
                logger.info(f"Webhook already configured in {name}")
                return

        payload = {
            "name": "Telegram Bot",
            "implementation": "Webhook",
            "configContract": "WebhookSettings",
            "onGrab": True,
            "onDownload": True,
            "onUpgrade": True,
            "fields": [
                {"name": "url", "value": webhook_url},
                {"name": "method", "value": 1},
            ],
        }
        resp = await client.post(
            f"{api_url}/api/v3/notification", json=payload, headers=headers,
        )
        _ensure_success(resp, name)
        logger.info(f"Webhook added to {name}")


async def setup_arr_notifications():
    try:
        await _ensure_webhook(RADARR_URL, RADARR_KEY, "Radarr", "/radarr")
    except Exception as e:
        logger.error(f"Failed to setup Radarr webhook: {e}")
    try:
        await _ensure_webhook(SONARR_URL, SONARR_KEY, "Sonarr", "/sonarr")
    except Exception as e:
        logger.error(f"Failed to setup Sonarr webhook: {e}")


async def post_init(application: Application) -> None:
    logger.info(
        "ARR config loaded: Radarr=%s Sonarr=%s",
        _mask_secret(RADARR_KEY),
        _mask_secret(SONARR_KEY),
    )
    await application.bot.set_my_commands([
        BotCommand("movie", "Search & download a movie"),
        BotCommand("tv", "Search & download a TV show"),
        BotCommand("status", "Check download queue"),
        BotCommand("library", "List downloaded content"),
        BotCommand("help", "Show available commands"),
    ])
    logger.info("Bot commands menu registered")
    await run_webhook_server(application.bot)
    await setup_arr_notifications()


async def on_error(update: object, context: ContextTypes.DEFAULT_TYPE) -> None:
    logger.exception("Unhandled bot error", exc_info=context.error)

    message = "Something went wrong while talking to Sonarr/Radarr."
    if isinstance(context.error, ArrApiError):
        message = f"ARR API error: {context.error}"

    target = None
    if isinstance(update, Update):
        if update.effective_message:
            target = update.effective_message.reply_text
        elif update.callback_query and update.callback_query.message:
            target = update.callback_query.message.reply_text

    if target:
        try:
            await target(message)
        except Exception:
            logger.exception("Failed to send error message to Telegram user")


def main():
    app = Application.builder().token(TOKEN).post_init(post_init).build()

    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("help", start))
    app.add_handler(CommandHandler("movie", movie_search))
    app.add_handler(CommandHandler("tv", tv_search))
    app.add_handler(CommandHandler("status", status))
    app.add_handler(CommandHandler("library", library))

    app.add_handler(CallbackQueryHandler(add_movie_callback, pattern=r"^addmovie:"))
    app.add_handler(CallbackQueryHandler(add_tv_callback, pattern=r"^addtv:"))
    app.add_error_handler(on_error)

    logger.info("Bot started")
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
