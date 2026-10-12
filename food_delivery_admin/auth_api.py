"""Tokyo Sushi: Telegram code login, no phone collection."""
import hashlib
import hmac
import os
import secrets
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

from fastapi import APIRouter, HTTPException, Header, Request
from pydantic import BaseModel, Field

BASE = Path(__file__).resolve().parent
DB = BASE / 'auth.db'
SECRET = os.getenv('AUTH_SECRET', '')
if len(SECRET) < 32:
    raise RuntimeError('AUTH_SECRET must be at least 32 characters')

router = APIRouter(prefix='/api/auth', tags=['Telegram login'])


@contextmanager
def connect():
    con = sqlite3.connect(DB, timeout=20)
    con.row_factory = sqlite3.Row
    con.execute('PRAGMA busy_timeout=20000')
    try:
        yield con
        con.commit()
    except Exception:
        con.rollback()
        raise
    finally:
        con.close()


def digest(value: str) -> str:
    return hmac.new(SECRET.encode(), value.encode(), hashlib.sha256).hexdigest()


def init():
    with connect() as con:
        con.execute('PRAGMA journal_mode=WAL')
        con.execute('''CREATE TABLE IF NOT EXISTS telegram_codes (
            code_hash TEXT PRIMARY KEY,
            telegram_id INTEGER NOT NULL,
            created INTEGER NOT NULL,
            expires INTEGER NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0
        )''')
        con.execute('''CREATE INDEX IF NOT EXISTS code_by_user
                       ON telegram_codes(telegram_id)''')
        con.execute('''CREATE TABLE IF NOT EXISTS telegram_users (
            telegram_id INTEGER PRIMARY KEY,
            username TEXT NOT NULL DEFAULT '',
            first_name TEXT NOT NULL DEFAULT '',
            created INTEGER NOT NULL,
            policy_version TEXT NOT NULL DEFAULT ''
        )''')
        con.execute('''CREATE TABLE IF NOT EXISTS telegram_sessions (
            token_hash TEXT PRIMARY KEY,
            telegram_id INTEGER NOT NULL,
            expires INTEGER NOT NULL
        )''')
        con.execute('''CREATE TABLE IF NOT EXISTS telegram_limits (
            source TEXT PRIMARY KEY,
            window_start INTEGER NOT NULL,
            attempts INTEGER NOT NULL
        )''')


init()


class VerifyRequest(BaseModel):
    code: str = Field(pattern=r'^\d{6}$')
    accepted_policy: bool


def limit_ip(con, source: str, now: int):
    row = con.execute('SELECT * FROM telegram_limits WHERE source=?',
                      (source,)).fetchone()
    if row is None or now - row['window_start'] >= 600:
        con.execute('INSERT OR REPLACE INTO telegram_limits VALUES (?,?,1)',
                    (source, now))
    elif row['attempts'] >= 10:
        raise HTTPException(429, 'Слишком много попыток. Подождите 10 минут')
    else:
        con.execute('UPDATE telegram_limits SET attempts=attempts+1 WHERE source=?',
                    (source,))


@router.post('/verify')
def verify(body: VerifyRequest, request: Request):
    if not body.accepted_policy:
        raise HTTPException(400, 'Примите политику конфиденциальности')
    now = int(time.time())
    # Reverse proxy must not forward arbitrary X-Forwarded-For headers.
    ip = request.client.host if request.client else 'unknown'
    with connect() as con:
        limit_ip(con, ip, now)
        row = con.execute('''SELECT telegram_id FROM telegram_codes
                             WHERE code_hash=? AND expires>? AND attempts<5''',
                          (digest(body.code), now)).fetchone()
        if row is None:
            raise HTTPException(400, 'Неверный или просроченный код')
        telegram_id = row['telegram_id']
        con.execute('DELETE FROM telegram_codes WHERE telegram_id=?',
                    (telegram_id,))
        con.execute('''UPDATE telegram_users SET policy_version=?
                       WHERE telegram_id=?''', ('2026-10-12', telegram_id))
        token = secrets.token_urlsafe(40)
        con.execute('''INSERT INTO telegram_sessions VALUES (?,?,?)''',
                    (digest(token), telegram_id, now + 30 * 86400))
        user = con.execute('''SELECT username,first_name FROM telegram_users
                              WHERE telegram_id=?''', (telegram_id,)).fetchone()
    name = user['first_name'] or ('@' + user['username'] if user['username'] else 'Telegram')
    return {'token': token, 'telegram_id': telegram_id,
            'display_name': name, 'username': user['username']}


def current_user(authorization: str):
    if not authorization.startswith('Bearer '):
        raise HTTPException(401, 'Нужно войти')
    with connect() as con:
        row = con.execute('''SELECT u.telegram_id,u.username,u.first_name
             FROM telegram_sessions s JOIN telegram_users u
             ON s.telegram_id=u.telegram_id
             WHERE s.token_hash=? AND s.expires>?''',
             (digest(authorization[7:]), int(time.time()))).fetchone()
    if not row:
        raise HTTPException(401, 'Сессия истекла')
    return {'telegram_id': row['telegram_id'], 'username': row['username'],
            'display_name': row['first_name'] or ('@' + row['username'] if row['username'] else 'Telegram')}


@router.get('/me')
def me(authorization: str = Header(default='')):
    return current_user(authorization)


@router.post('/logout')
def logout(authorization: str = Header(default='')):
    if authorization.startswith('Bearer '):
        with connect() as con:
            con.execute('DELETE FROM telegram_sessions WHERE token_hash=?',
                        (digest(authorization[7:]),))
    return {'ok': True}
