
import asyncio
import os
import secrets
import time
from html import escape

import httpx

from auth_api import connect, digest

TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
BOT_USERNAME = "tokyodeltest_bot"

if not TOKEN:
    raise RuntimeError("Не задан TELEGRAM_BOT_TOKEN")

API_URL = f"https://api.telegram.org/bot{TOKEN}"

CONTACT_KEYBOARD = {
    "keyboard": [
        [
            {
                "text": "📱 Отправить мои данные",
                "request_contact": True,
            }
        ]
    ],
    "resize_keyboard": True,
    "one_time_keyboard": True,
    "is_persistent": False,
}

REPEAT_KEYBOARD = {
    "keyboard": [
        [{"text": "🔑 Получить новый код"}]
    ],
    "resize_keyboard": True,
    "is_persistent": True,
}


async def api(client, method, payload):
    response = await client.post(
        f"{API_URL}/{method}",
        json=payload,
        timeout=40.0,
    )
    response.raise_for_status()

    result = response.json()

    if not result.get("ok"):
        raise RuntimeError(
            result.get("description", "Telegram API error")
        )

    return result["result"]


async def send(
    client,
    chat_id,
    message,
    keyboard=None,
    html=False,
):
    data = {
        "chat_id": chat_id,
        "text": message,
    }

    if keyboard is not None:
        data["reply_markup"] = keyboard

    if html:
        data["parse_mode"] = "HTML"

    return await api(client, "sendMessage", data)


async def show_start(client, chat_id):
    await send(
        client,
        chat_id,
        "🍣 Добро пожаловать в Tokyo Суши!\n\n"
        "Чтобы подтвердить свой Telegram-аккаунт, "
        "нажмите кнопку «Отправить мои данные».\n\n"
        "Telegram попросит разрешение "
        "передать ваш контакт.",
        CONTACT_KEYBOARD,
    )


def generate_code(con):
    for _ in range(40):
        code = f"{secrets.randbelow(1000000):06d}"

        found = con.execute(
            "SELECT 1 FROM telegram_codes "
            "WHERE code_hash=?",
            (digest(code),),
        ).fetchone()

        if found is None:
            return code

    raise RuntimeError("Не удалось создать код")


def store_code(user):
    now = int(time.time())
    telegram_id = int(user["id"])

    with connect() as con:
        con.execute("""
            CREATE TABLE IF NOT EXISTS bot_issue_limits (
                telegram_id INTEGER PRIMARY KEY,
                window_start INTEGER NOT NULL,
                count INTEGER NOT NULL
            )
        """)

        row = con.execute(
            "SELECT window_start, count "
            "FROM bot_issue_limits WHERE telegram_id=?",
            (telegram_id,),
        ).fetchone()

        if row and now - row["window_start"] < 3600:
            count = row["count"]
            window_start = row["window_start"]
        else:
            count = 0
            window_start = now

        if count >= 5:
            return None

        con.execute("""
            INSERT INTO bot_issue_limits
            (telegram_id, window_start, count)
            VALUES (?, ?, ?)
            ON CONFLICT(telegram_id) DO UPDATE SET
                window_start=excluded.window_start,
                count=excluded.count
        """, (telegram_id, window_start, count + 1))

        con.execute(
            "DELETE FROM telegram_codes "
            "WHERE telegram_id=? OR expires<?",
            (telegram_id, now),
        )

        con.execute("""
            INSERT INTO telegram_users
            (telegram_id, username, first_name, created)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(telegram_id) DO UPDATE SET
                username=excluded.username,
                first_name=excluded.first_name
        """, (
            telegram_id,
            user.get("username") or "",
            user.get("first_name") or "",
            now,
        ))

        code = generate_code(con)

        con.execute("""
            INSERT INTO telegram_codes
            (code_hash, telegram_id, created, expires, attempts)
            VALUES (?, ?, ?, ?, 0)
        """, (
            digest(code),
            telegram_id,
            now,
            now + 600,
        ))

    return code


async def issue_code(client, user, chat_id):
    code = store_code(user)

    if code is None:
        await send(
            client,
            chat_id,
            "Слишком много запросов.\n"
            "Попробуйте снова через час.",
        )
        return

    await send(
        client,
        chat_id,
        "✅ Telegram-аккаунт подтверждён!",
        REPEAT_KEYBOARD,
    )

    await send(
        client,
        chat_id,
        "🍣 <b>Tokyo Суши</b>\n\n"
        "Ваш код для входа:\n\n"
        f"<code>{escape(code)}</code>\n\n"
        "Нажмите «Скопировать код» "
        "и вставьте его в приложение.\n\n"
        "⏱ Код действует 10 минут.",
        {
            "inline_keyboard": [
                [
                    {
                        "text": "📋 Скопировать код",
                        "copy_text": {
                            "text": code
                        },
                    }
                ]
            ]
        },
        html=True,
    )


async def handle_message(client, message):
    chat = message.get("chat") or {}
    user = message.get("from") or {}

    if chat.get("type") != "private":
        return

    chat_id = chat["id"]
    telegram_id = user.get("id")

    if not telegram_id or user.get("is_bot"):
        return

    text = (message.get("text") or "").strip()
    command = text.split(" ", 1)[0].split("@", 1)[0].lower()

    # /start всегда показывает кнопку передачи контакта.
    if command == "/start":
        await show_start(client, chat_id)
        return

    # Telegram присылает контакт отдельным объектом.
    contact = message.get("contact")

    if contact:
        contact_user_id = contact.get("user_id")

        # Принимаем только контакт самого отправителя.
        if contact_user_id != telegram_id:
            await send(
                client,
                chat_id,
                "Отправьте именно свой контакт "
                "через кнопку Telegram.",
                CONTACT_KEYBOARD,
            )
            return

        print(
            f"Контакт подтверждён для Telegram ID "
            f"{telegram_id}",
            flush=True,
        )

        # Телефон не записываем в базу и логи.
        await issue_code(client, user, chat_id)
        return

    if command == "/code" or text == "🔑 Получить новый код":
        with connect() as con:
            existing_user = con.execute(
                "SELECT 1 FROM telegram_users "
                "WHERE telegram_id=?",
                (telegram_id,),
            ).fetchone()

        if existing_user is None:
            await show_start(client, chat_id)
            return

        await issue_code(client, user, chat_id)
        return

    if text == "📱 Отправить мои данные":
        await show_start(client, chat_id)
        return

    await send(
        client,
        chat_id,
        "Нажмите «Отправить мои данные» "
        "или отправьте /start.",
        CONTACT_KEYBOARD,
    )


async def setup(client):
    bot = await api(client, "getMe", {})

    username = bot.get("username", "")

    if username.lower() != BOT_USERNAME.lower():
        raise RuntimeError(
            f"Токен принадлежит @{username}, "
            f"а ожидался @{BOT_USERNAME}"
        )

    await api(
        client,
        "deleteWebhook",
        {"drop_pending_updates": False},
    )

    await api(
        client,
        "setMyCommands",
        {
            "commands": [
                {
                    "command": "start",
                    "description": "Начать регистрацию",
                },
                {
                    "command": "code",
                    "description": "Получить новый код",
                },
            ]
        },
    )

    print(
        f"Бот запущен: @{username}",
        flush=True,
    )


async def main():
    async with httpx.AsyncClient() as client:
        await setup(client)

        offset = None

        while True:
            try:
                request = {
                    "timeout": 25,
                    "allowed_updates": ["message"],
                }

                if offset is not None:
                    request["offset"] = offset

                updates = await api(
                    client,
                    "getUpdates",
                    request,
                )

                for update in updates:
                    offset = update["update_id"] + 1
                    message = update.get("message")

                    if message:
                        try:
                            await handle_message(
                                client,
                                message,
                            )
                        except Exception as error:
                            print(
                                "Ошибка обработки сообщения:",
                                repr(error),
                                flush=True,
                            )

            except Exception as error:
                print(
                    "Ошибка Telegram polling:",
                    repr(error),
                    flush=True,
                )
                await asyncio.sleep(3)


if __name__ == "__main__":
    asyncio.run(main())
