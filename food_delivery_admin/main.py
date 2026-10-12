
"""Tokyo Суши — Python FastAPI сервер и админ-панель."""

import json
import hmac
import os
import secrets
import sqlite3

from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated

from fastapi import (
    Depends,
    FastAPI,
    File,
    HTTPException,
    UploadFile,
    status,
)
from fastapi.responses import FileResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field


# ============================================================
# НАСТРОЙКИ
# ============================================================

BASE = Path(__file__).resolve().parent

UPLOADS = BASE / "uploads"
UPLOADS.mkdir(parents=True, exist_ok=True)

DB_PATH = Path(
    os.environ.get("FOOD_DB_PATH", str(BASE / "food.db"))
)

ADMIN_USER = os.environ.get("FOOD_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("FOOD_ADMIN_PASSWORD", "")

if not ADMIN_PASSWORD:
    raise RuntimeError(
        "Укажите FOOD_ADMIN_PASSWORD перед запуском сервера"
    )

app = FastAPI(
    title="Tokyo Sushi API",
    version="2.1",
    docs_url=None,
    redoc_url=None,
)

security = HTTPBasic(auto_error=False)

app.mount(
    "/uploads",
    StaticFiles(directory=str(UPLOADS)),
    name="uploads",
)


# ============================================================
# БАЗА ДАННЫХ
# ============================================================

@contextmanager
def db():
    connection = sqlite3.connect(DB_PATH, timeout=15)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys=ON")

    try:
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def initialize():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)

    with db() as con:
        con.execute("""
            CREATE TABLE IF NOT EXISTS categories (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                sort_order INTEGER NOT NULL DEFAULT 0
            )
        """)

        con.execute("""
            CREATE TABLE IF NOT EXISTS products (
                id INTEGER PRIMARY KEY,
                category_id INTEGER NOT NULL
                    REFERENCES categories(id),
                name TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                price INTEGER NOT NULL CHECK(price >= 0),
                image_url TEXT NOT NULL DEFAULT '',
                is_hit INTEGER NOT NULL DEFAULT 0,
                is_available INTEGER NOT NULL DEFAULT 1,
                sort_order INTEGER NOT NULL DEFAULT 0
            )
        """)

        con.execute("""
            CREATE TABLE IF NOT EXISTS orders (
                id INTEGER PRIMARY KEY,
                customer_name TEXT NOT NULL,
                phone TEXT NOT NULL,
                address TEXT NOT NULL,
                comment TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'new',
                total INTEGER NOT NULL,
                created_at TEXT NOT NULL
            )
        """)

        con.execute("""
            CREATE TABLE IF NOT EXISTS modifier_groups (
                id INTEGER PRIMARY KEY,
                product_id INTEGER NOT NULL
                    REFERENCES products(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                min_select INTEGER NOT NULL DEFAULT 0,
                max_select INTEGER NOT NULL DEFAULT 1,
                sort_order INTEGER NOT NULL DEFAULT 0
            )
        """)

        con.execute("""
            CREATE TABLE IF NOT EXISTS modifier_options (
                id INTEGER PRIMARY KEY,
                group_id INTEGER NOT NULL
                    REFERENCES modifier_groups(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                price INTEGER NOT NULL DEFAULT 0 CHECK(price >= 0),
                sort_order INTEGER NOT NULL DEFAULT 0
            )
        """)

        con.execute("""
            CREATE TABLE IF NOT EXISTS order_items (
                id INTEGER PRIMARY KEY,
                order_id INTEGER NOT NULL
                    REFERENCES orders(id),
                product_id INTEGER NOT NULL,
                product_name TEXT NOT NULL,
                quantity INTEGER NOT NULL,
                unit_price INTEGER NOT NULL,
                modifiers TEXT NOT NULL DEFAULT '[]'
            )
        """)

        # Обновление старой базы без удаления заказов.
        columns = [
            row[1]
            for row in con.execute(
                "PRAGMA table_info(order_items)"
            )
        ]

        if "modifiers" not in columns:
            con.execute("""
                ALTER TABLE order_items
                ADD COLUMN modifiers TEXT NOT NULL DEFAULT '[]'
            """)


initialize()


# ============================================================
# АВТОРИЗАЦИЯ АДМИНИСТРАТОРА
# ============================================================

def admin_only(
    credentials: Annotated[
        HTTPBasicCredentials | None,
        Depends(security),
    ],
):
    valid = (
        credentials is not None
        and hmac.compare_digest(
            credentials.username.encode(),
            ADMIN_USER.encode(),
        )
        and hmac.compare_digest(
            credentials.password.encode(),
            ADMIN_PASSWORD.encode(),
        )
    )

    if not valid:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Неверный логин или пароль",
            headers={"WWW-Authenticate": "Basic"},
        )


# ============================================================
# МОДЕЛИ ДАННЫХ
# ============================================================

class CategoryInput(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    sort_order: int = 0


class ProductInput(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    category_id: int
    description: str = Field(default="", max_length=700)
    price: int = Field(ge=0, le=10000000)
    image_url: str = Field(default="", max_length=500)
    is_hit: bool = False
    is_available: bool = True
    sort_order: int = 0


class ModifierOptionIn(BaseModel):
    name: str = Field(min_length=1, max_length=70)
    price: int = Field(ge=0, le=1000000)
    sort_order: int = 0


class ModifierGroupIn(BaseModel):
    name: str = Field(min_length=1, max_length=70)
    min_select: int = Field(ge=0, le=20)
    max_select: int = Field(ge=1, le=20)
    sort_order: int = 0
    options: list[ModifierOptionIn] = Field(
        default_factory=list,
        max_length=50,
    )


class ProductModifiersIn(BaseModel):
    groups: list[ModifierGroupIn] = Field(
        default_factory=list,
        max_length=15,
    )


class ItemInput(BaseModel):
    product_id: int
    quantity: int = Field(ge=1, le=50)
    option_ids: list[int] = Field(
        default_factory=list,
        max_length=25,
    )


class OrderInput(BaseModel):
    customer_name: str = Field(min_length=2, max_length=100)
    phone: str = Field(min_length=5, max_length=30)
    address: str = Field(min_length=5, max_length=240)
    comment: str = Field(default="", max_length=500)
    items: list[ItemInput] = Field(
        min_length=1,
        max_length=60,
    )


class OrderStatus(BaseModel):
    status: str


# ============================================================
# СТРАНИЦЫ АДМИНКИ
# ============================================================

@app.get("/")
def admin_page():
    return FileResponse(
        BASE / "static" / "index.html"
    )


@app.get(
    "/photo-editor",
    dependencies=[Depends(admin_only)],
)
def photo_editor():
    path = BASE / "static" / "photo-editor.html"

    if not path.is_file():
        raise HTTPException(
            status_code=404,
            detail="Файл photo-editor.html не найден",
        )

    return FileResponse(path)


@app.get("/api/health")
def health():
    return {
        "ok": True,
        "service": "Tokyo Sushi",
    }


# ============================================================
# КАТЕГОРИИ
# ============================================================

@app.get("/api/categories")
def categories():
    with db() as con:
        rows = con.execute("""
            SELECT *
            FROM categories
            ORDER BY sort_order, id
        """).fetchall()

        return [dict(row) for row in rows]


@app.post(
    "/api/admin/categories",
    dependencies=[Depends(admin_only)],
)
def add_category(payload: CategoryInput):
    name = payload.name.strip()

    if not name:
        raise HTTPException(400, "Введите название категории")

    with db() as con:
        try:
            cur = con.execute(
                """
                INSERT INTO categories(name, sort_order)
                VALUES (?, ?)
                """,
                (name, payload.sort_order),
            )
        except sqlite3.IntegrityError:
            raise HTTPException(409, "Категория уже существует")

        return {"id": cur.lastrowid}


@app.delete(
    "/api/admin/categories/{category_id}",
    dependencies=[Depends(admin_only)],
)
def delete_category(category_id: int):
    with db() as con:
        exists = con.execute(
            "SELECT 1 FROM products WHERE category_id=?",
            (category_id,),
        ).fetchone()

        if exists:
            raise HTTPException(
                409,
                "Сначала удалите блюда из категории",
            )

        cur = con.execute(
            "DELETE FROM categories WHERE id=?",
            (category_id,),
        )

        if not cur.rowcount:
            raise HTTPException(404, "Категория не найдена")

    return {"ok": True}


# ============================================================
# БЛЮДА
# ============================================================

@app.get("/api/products")
def products():
    with db() as con:
        rows = con.execute("""
            SELECT *
            FROM products
            WHERE is_available=1
            ORDER BY sort_order, id DESC
        """).fetchall()

        return [dict(row) for row in rows]


@app.get(
    "/api/admin/products",
    dependencies=[Depends(admin_only)],
)
def all_products():
    with db() as con:
        rows = con.execute("""
            SELECT *
            FROM products
            ORDER BY sort_order, id DESC
        """).fetchall()

        return [dict(row) for row in rows]


@app.get(
    "/api/admin/check",
    dependencies=[Depends(admin_only)],
)
def admin_check():
    return {"ok": True}


@app.post(
    "/api/admin/products",
    dependencies=[Depends(admin_only)],
)
def add_product(payload: ProductInput):
    with db() as con:
        exists = con.execute(
            "SELECT 1 FROM categories WHERE id=?",
            (payload.category_id,),
        ).fetchone()

        if not exists:
            raise HTTPException(
                400,
                "Сначала создайте категорию",
            )

        cur = con.execute("""
            INSERT INTO products (
                category_id,
                name,
                description,
                price,
                image_url,
                is_hit,
                is_available,
                sort_order
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            payload.category_id,
            payload.name.strip(),
            payload.description.strip(),
            payload.price,
            payload.image_url.strip(),
            int(payload.is_hit),
            int(payload.is_available),
            payload.sort_order,
        ))

        return {"id": cur.lastrowid}


@app.put(
    "/api/admin/products/{product_id}",
    dependencies=[Depends(admin_only)],
)
def update_product(
    product_id: int,
    payload: ProductInput,
):
    with db() as con:
        exists = con.execute(
            "SELECT 1 FROM categories WHERE id=?",
            (payload.category_id,),
        ).fetchone()

        if not exists:
            raise HTTPException(400, "Категория не найдена")

        cur = con.execute("""
            UPDATE products
            SET
                category_id=?,
                name=?,
                description=?,
                price=?,
                image_url=?,
                is_hit=?,
                is_available=?,
                sort_order=?
            WHERE id=?
        """, (
            payload.category_id,
            payload.name.strip(),
            payload.description.strip(),
            payload.price,
            payload.image_url.strip(),
            int(payload.is_hit),
            int(payload.is_available),
            payload.sort_order,
            product_id,
        ))

        if not cur.rowcount:
            raise HTTPException(404, "Блюдо не найдено")

    return {"ok": True}


@app.delete(
    "/api/admin/products/{product_id}",
    dependencies=[Depends(admin_only)],
)
def delete_product(product_id: int):
    with db() as con:
        # Сохраняем историю заказов.
        used = con.execute(
            """
            SELECT 1 FROM order_items
            WHERE product_id=?
            LIMIT 1
            """,
            (product_id,),
        ).fetchone()

        if used:
            con.execute(
                "UPDATE products SET is_available=0 WHERE id=?",
                (product_id,),
            )
            return {"ok": True, "archived": True}

        cur = con.execute(
            "DELETE FROM products WHERE id=?",
            (product_id,),
        )

        if not cur.rowcount:
            raise HTTPException(404, "Блюдо не найдено")

    return {"ok": True}


# ============================================================
# ДОПОЛНЕНИЯ К БЛЮДАМ
# ============================================================

def read_modifiers(con, product_id: int):
    groups = []

    rows = con.execute("""
        SELECT *
        FROM modifier_groups
        WHERE product_id=?
        ORDER BY sort_order, id
    """, (product_id,)).fetchall()

    for row in rows:
        group = dict(row)

        options = con.execute("""
            SELECT *
            FROM modifier_options
            WHERE group_id=?
            ORDER BY sort_order, id
        """, (group["id"],)).fetchall()

        group["options"] = [
            dict(option)
            for option in options
        ]

        groups.append(group)

    return groups


@app.get("/api/products/{product_id}/modifiers")
def product_modifiers(product_id: int):
    with db() as con:
        exists = con.execute("""
            SELECT 1
            FROM products
            WHERE id=? AND is_available=1
        """, (product_id,)).fetchone()

        if not exists:
            raise HTTPException(404, "Блюдо не найдено")

        return read_modifiers(con, product_id)


@app.get(
    "/api/admin/products/{product_id}/modifiers",
    dependencies=[Depends(admin_only)],
)
def admin_product_modifiers(product_id: int):
    with db() as con:
        return read_modifiers(con, product_id)


@app.put(
    "/api/admin/products/{product_id}/modifiers",
    dependencies=[Depends(admin_only)],
)
def set_product_modifiers(
    product_id: int,
    payload: ProductModifiersIn,
):
    with db() as con:
        exists = con.execute(
            "SELECT 1 FROM products WHERE id=?",
            (product_id,),
        ).fetchone()

        if not exists:
            raise HTTPException(404, "Блюдо не найдено")

        for group in payload.groups:
            if (
                group.min_select > group.max_select
                or group.max_select > len(group.options)
            ):
                raise HTTPException(
                    400,
                    f"Неверное число вариантов: {group.name}",
                )

        con.execute(
            "DELETE FROM modifier_groups WHERE product_id=?",
            (product_id,),
        )

        for group in payload.groups:
            cur = con.execute("""
                INSERT INTO modifier_groups (
                    product_id,
                    name,
                    min_select,
                    max_select,
                    sort_order
                )
                VALUES (?, ?, ?, ?, ?)
            """, (
                product_id,
                group.name.strip(),
                group.min_select,
                group.max_select,
                group.sort_order,
            ))

            for option in group.options:
                con.execute("""
                    INSERT INTO modifier_options (
                        group_id,
                        name,
                        price,
                        sort_order
                    )
                    VALUES (?, ?, ?, ?)
                """, (
                    cur.lastrowid,
                    option.name.strip(),
                    option.price,
                    option.sort_order,
                ))

    return {"ok": True}


# ============================================================
# ЗАГРУЗКА ФОТОГРАФИЙ
# ============================================================

@app.post(
    "/api/admin/upload",
    dependencies=[Depends(admin_only)],
)
async def upload_photo(
    file: UploadFile = File(...),
):
    allowed = {
        "image/jpeg": ".jpg",
        "image/png": ".png",
        "image/webp": ".webp",
    }

    if file.content_type not in allowed:
        raise HTTPException(
            400,
            "Используйте JPG, PNG или WebP",
        )

    payload = await file.read(4 * 1024 * 1024 + 1)

    if len(payload) > 4 * 1024 * 1024:
        raise HTTPException(
            413,
            "Размер фотографии не больше 4 МБ",
        )

    signatures = {
        "image/jpeg": payload.startswith(b"\xff\xd8\xff"),
        "image/png": payload.startswith(b"\x89PNG\r\n\x1a\n"),
        "image/webp": (
            payload[:4] == b"RIFF"
            and payload[8:12] == b"WEBP"
        ),
    }

    if not signatures[file.content_type]:
        raise HTTPException(
            400,
            "Некорректный формат фотографии",
        )

    filename = (
        secrets.token_hex(16)
        + allowed[file.content_type]
    )

    (UPLOADS / filename).write_bytes(payload)

    return {
        "url": "/uploads/" + filename,
        "filename": filename,
    }


# ============================================================
# ОФОРМЛЕНИЕ ЗАКАЗОВ
# ============================================================

@app.post("/api/orders", status_code=201)
def place_order(payload: OrderInput):
    with db() as con:
        entries = []
        total = 0

        for item in payload.items:
            product = con.execute("""
                SELECT id, name, price
                FROM products
                WHERE id=? AND is_available=1
            """, (item.product_id,)).fetchone()

            if product is None:
                raise HTTPException(
                    400,
                    f"Блюдо {item.product_id} недоступно",
                )

            if len(set(item.option_ids)) != len(item.option_ids):
                raise HTTPException(
                    400,
                    "Повторяющиеся дополнения",
                )

            groups = read_modifiers(con, product["id"])

            allowed = {
                option["id"]: option
                for group in groups
                for option in group["options"]
            }

            if any(
                option_id not in allowed
                for option_id in item.option_ids
            ):
                raise HTTPException(
                    400,
                    "Неверное дополнение",
                )

            selected = []

            for group in groups:
                chosen = [
                    option
                    for option in group["options"]
                    if option["id"] in item.option_ids
                ]

                if not (
                    group["min_select"]
                    <= len(chosen)
                    <= group["max_select"]
                ):
                    raise HTTPException(
                        400,
                        f"Проверьте выбор: {group['name']}",
                    )

                selected.extend(chosen)

            unit = (
                product["price"]
                + sum(option["price"] for option in selected)
            )

            entries.append((
                product,
                item.quantity,
                selected,
                unit,
            ))

            total += unit * item.quantity

        cur = con.execute("""
            INSERT INTO orders (
                customer_name,
                phone,
                address,
                comment,
                status,
                total,
                created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, (
            payload.customer_name.strip(),
            payload.phone.strip(),
            payload.address.strip(),
            payload.comment.strip(),
            "new",
            total,
            datetime.now(timezone.utc).isoformat(),
        ))

        order_id = cur.lastrowid

        for product, qty, selected, unit in entries:
            snapshot = json.dumps(
                [
                    {
                        "name": option["name"],
                        "price": option["price"],
                    }
                    for option in selected
                ],
                ensure_ascii=False,
            )

            con.execute("""
                INSERT INTO order_items (
                    order_id,
                    product_id,
                    product_name,
                    quantity,
                    unit_price,
                    modifiers
                )
                VALUES (?, ?, ?, ?, ?, ?)
            """, (
                order_id,
                product["id"],
                product["name"],
                qty,
                unit,
                snapshot,
            ))

        return {
            "id": order_id,
            "total": total,
            "status": "new",
        }


# ============================================================
# УПРАВЛЕНИЕ ЗАКАЗАМИ В АДМИНКЕ
# ============================================================

@app.get(
    "/api/admin/orders",
    dependencies=[Depends(admin_only)],
)
def admin_orders():
    with db() as con:
        results = []

        rows = con.execute("""
            SELECT *
            FROM orders
            ORDER BY id DESC
        """).fetchall()

        for row in rows:
            order = dict(row)

            items = con.execute("""
                SELECT
                    product_name,
                    quantity,
                    unit_price,
                    modifiers
                FROM order_items
                WHERE order_id=?
            """, (row["id"],)).fetchall()

            order["items"] = [
                dict(item)
                for item in items
            ]

            results.append(order)

        return results


@app.patch(
    "/api/admin/orders/{order_id}",
    dependencies=[Depends(admin_only)],
)
def change_status(
    order_id: int,
    payload: OrderStatus,
):
    allowed = {
        "new",
        "accepted",
        "preparing",
        "delivering",
        "completed",
        "cancelled",
    }

    if payload.status not in allowed:
        raise HTTPException(
            400,
            "Недопустимый статус заказа",
        )

    with db() as con:
        cur = con.execute("""
            UPDATE orders
            SET status=?
            WHERE id=?
        """, (
            payload.status,
            order_id,
        ))

        if not cur.rowcount:
            raise HTTPException(
                404,
                "Заказ не найден",
            )

    return {"ok": True}
