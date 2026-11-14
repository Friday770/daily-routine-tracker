"""作息打卡后端（FastAPI + MySQL）。

运行：.venv/bin/python app.py
配置：同目录下的 .env 文件（参考 .env.example）
项目：https://github.com/Friday770/daily-routine-tracker
"""
from __future__ import annotations

import asyncio
import datetime as dt
import json
import os
import re
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from decimal import Decimal
from pathlib import Path
from typing import Literal, Optional
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import pymysql
from fastapi import FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

BASE_DIR = Path(__file__).resolve().parent

# 打卡时间窗口（学习项需要打两次卡：开始学习、结束学习）
#   开始学习：开始前 START_BEFORE_MIN 分钟起，到这一项结束为止（迟到也能开始）
#   结束学习：结束前 END_BEFORE_MIN 分钟起，到结束后 END_AFTER_MIN 分钟为止
#   过了结束窗口还没结束打卡的，只能在完整作息表里补打卡（记为补打卡）
START_BEFORE_MIN = 1
END_BEFORE_MIN = 1
END_AFTER_MIN = 5
# 手机和电脑的时钟可能差几秒，服务器判断时放宽这么多秒
CLOCK_SLACK_SEC = 30
# 只能给最近这么多天打卡 / 补打卡
MAKEUP_MAX_DAYS = 7
# 计时打卡：实际时长达到计划时长的这个比例，算“完成”，否则算“部分完成”
DONE_RATIO = 0.9


# ---------------------------------------------------------------- 配置
def load_env(path: Path) -> None:
    """读取 .env（KEY=VALUE），不覆盖已有的环境变量。"""
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


load_env(BASE_DIR / ".env")

# 统一使用的时区：在 .env 里设置 APP_TIMEZONE（如 Asia/Shanghai）；不设置则用这台电脑的系统时区。
# 网页（电脑和手机）、后端判断打卡时间、数据库统计“今天”，都按这个时区。
APP_TIMEZONE = os.getenv("APP_TIMEZONE", "").strip()
try:
    TZ = ZoneInfo(APP_TIMEZONE) if APP_TIMEZONE else None
except (ZoneInfoNotFoundError, ValueError):
    raise SystemExit(f"APP_TIMEZONE={APP_TIMEZONE!r} 不是有效的时区名，例如 Asia/Shanghai、America/Los_Angeles")


def aware_now() -> dt.datetime:
    return dt.datetime.now(TZ) if TZ else dt.datetime.now().astimezone()


def tz_info() -> dict:
    n = aware_now()
    off = int(n.utcoffset().total_seconds() // 60)
    return {"timezone": APP_TIMEZONE or str(n.tzinfo), "utc_offset_min": off}


def mysql_offset() -> str:
    off = tz_info()["utc_offset_min"]
    sign = "+" if off >= 0 else "-"
    return f"{sign}{abs(off) // 60:02d}:{abs(off) % 60:02d}"


def now() -> dt.datetime:
    """统一时区下的当前时间（不带时区信息，方便和数据库里的时间比较）。"""
    return aware_now().replace(tzinfo=None)


def today() -> dt.date:
    return now().date()

DB = dict(
    host=os.getenv("DB_HOST", "127.0.0.1"),
    port=int(os.getenv("DB_PORT", "3306")),
    user=os.getenv("DB_USER", "root"),
    password=os.getenv("DB_PASSWORD", ""),
    database=os.getenv("DB_NAME", "daily_routine"),
    charset="utf8mb4",
    cursorclass=pymysql.cursors.DictCursor,
    autocommit=True,
    connect_timeout=5,
)


@contextmanager
def db():
    pw = DB["password"]
    if "填写" in pw:  # 还是模板里的占位文字
        raise HTTPException(503, "还没有填写数据库密码：请在 .env 里把 DB_PASSWORD 改成 MySQL 的密码，然后重启后端")
    if any(ord(ch) > 255 for ch in pw):
        raise HTTPException(503, "数据库密码含有中文等字符，MySQL 驱动无法使用，请检查 .env 里的 DB_PASSWORD")
    try:
        conn = pymysql.connect(**DB)
        with conn.cursor() as c:  # 让数据库里的“今天”、创建时间也按同一个时区
            c.execute("SET time_zone = %s", (mysql_offset(),))
    except pymysql.err.OperationalError as e:
        code = e.args[0] if e.args else None
        if code == 1045:
            raise HTTPException(503, "数据库密码不对：请检查 .env 里的 DB_USER 和 DB_PASSWORD")
        if code == 1049:
            raise HTTPException(503, "找不到 daily_routine 数据库：请先导入 daily_routine.sql")
        raise HTTPException(503, f"连接数据库失败：{e.args[-1]}")
    except Exception as e:  # 其他意外（如缺少依赖），也给出明确提示而不是 500
        raise HTTPException(503, f"连接数据库失败：{e}")
    try:
        with conn.cursor() as cur:
            yield cur
    finally:
        conn.close()


# ---------------------------------------------------------------- 工具
def to_json(v):
    if isinstance(v, dt.timedelta):  # MySQL TIME
        total = int(v.total_seconds())
        return f"{total // 3600:02d}:{total % 3600 // 60:02d}"
    if isinstance(v, (dt.datetime, dt.date)):
        return v.isoformat(sep=" ") if isinstance(v, dt.datetime) else v.isoformat()
    if isinstance(v, Decimal):
        return int(v) if v == v.to_integral_value() else float(v)
    return v


def row_json(row: dict) -> dict:
    return {k: to_json(v) for k, v in row.items()}


def parse_date(s: Optional[str]) -> dt.date:
    if not s:
        return today()
    try:
        return dt.date.fromisoformat(s)
    except ValueError:
        raise HTTPException(400, "日期格式应为 YYYY-MM-DD")


def day_type_of(d: dt.date) -> str:
    return "end" if d.weekday() >= 5 else "week"


def slot_datetimes(d: dt.date, start: dt.timedelta, end: Optional[dt.timedelta]):
    base = dt.datetime.combine(d, dt.time())
    return base + start, base + (end if end is not None else start)


DAY_SQL = """
SELECT s.id AS schedule_id, s.start_time, s.end_time, s.planned_min, s.count_in_rate,
       t.id AS task_id, t.name AS task, t.category,
       c.id AS checkin_id, c.status, c.actual_min, c.started_at, c.ended_at,
       c.is_makeup, c.note, c.updated_at
FROM schedule s
JOIN task t ON t.id = s.task_id
LEFT JOIN checkin c ON c.schedule_id = s.id AND c.checkin_date = %(d)s
WHERE s.day_type = %(dt)s
  AND s.valid_from <= %(d)s
  AND (s.valid_to IS NULL OR %(d)s <= s.valid_to)
ORDER BY s.start_time
"""


def get_slot(cur, d: dt.date, schedule_id: int) -> dict:
    cur.execute(
        """SELECT s.id, s.start_time, s.end_time, s.planned_min, s.count_in_rate, t.name AS task
           FROM schedule s JOIN task t ON t.id = s.task_id
           WHERE s.id = %s AND s.day_type = %s AND s.valid_from <= %s
             AND (s.valid_to IS NULL OR %s <= s.valid_to)""",
        (schedule_id, day_type_of(d), d, d),
    )
    slot = cur.fetchone()
    if not slot:
        raise HTTPException(404, "这一天没有这一项安排")
    return slot


def windows(d: dt.date, slot: dict):
    """返回 (开始窗口起点, 结束窗口起点, 结束窗口终点)。"""
    start_dt, end_dt = slot_datetimes(d, slot["start_time"], slot["end_time"])
    slack = dt.timedelta(seconds=CLOCK_SLACK_SEC)
    return (
        start_dt - dt.timedelta(minutes=START_BEFORE_MIN) - slack,
        end_dt - dt.timedelta(minutes=END_BEFORE_MIN) - slack,
        end_dt + dt.timedelta(minutes=END_AFTER_MIN) + slack,
        start_dt,
        end_dt,
    )


def fmt_t(x: dt.datetime) -> str:
    return x.strftime("%H:%M")


def study_slot(cur, d: dt.date, schedule_id: int) -> dict:
    slot = get_slot(cur, d, schedule_id)
    if not slot["count_in_rate"]:
        raise HTTPException(400, f"「{slot['task']}」是非学习时间，不需要打卡")
    return slot


def get_checkin(cur, d: dt.date, schedule_id: int) -> Optional[dict]:
    cur.execute("SELECT * FROM checkin WHERE checkin_date = %s AND schedule_id = %s", (d, schedule_id))
    return cur.fetchone()


def check_date_window(d: dt.date) -> None:
    t = today()
    if d > t:
        raise HTTPException(400, "还没到这一天，不能打卡")
    if (t - d).days > MAKEUP_MAX_DAYS:
        raise HTTPException(400, f"只能补最近 {MAKEUP_MAX_DAYS} 天的打卡")


# ---------------------------------------------------------------- 应用
app = FastAPI(title="作息打卡", docs_url="/api/docs", redoc_url=None)


# ---------------------------------------------------------------- 实时同步
# 任何一端打卡（开始、结束、补打卡、跳过、撤销）后计数加一，所有打开的页面通过 /api/events 立即收到并刷新。
_change_lock = threading.Lock()
CHANGE = {"seq": 0, "date": "", "by": ""}


def notify(d: dt.date, by: Optional[str]) -> None:
    with _change_lock:
        CHANGE["seq"] += 1
        CHANGE["date"] = d.isoformat()
        CHANGE["by"] = by or ""


@app.get("/api/events", include_in_schema=False)
async def events(request: Request):
    """服务器推送（Server-Sent Events）：有打卡变化时立即通知页面。"""

    async def gen():
        last, idle = CHANGE["seq"], 0
        yield "retry: 3000\n\n"
        while not await request.is_disconnected():
            if CHANGE["seq"] != last:
                last = CHANGE["seq"]
                msg = {"seq": last, "date": CHANGE["date"], "by": CHANGE["by"]}
                yield f"data: {json.dumps(msg)}\n\n"
                idle = 0
            else:
                idle += 1
                if idle >= 30:  # 每 15 秒发一次心跳，防止连接被手机或路由器断开
                    yield ": ping\n\n"
                    idle = 0
            await asyncio.sleep(0.5)

    return StreamingResponse(
        gen(), media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/", include_in_schema=False)
def index():
    return FileResponse(BASE_DIR / "static" / "index.html", headers={"Cache-Control": "no-cache"})


@app.get("/apple-touch-icon.png", include_in_schema=False)
def touch_icon():
    return FileResponse(BASE_DIR / "static" / "apple-touch-icon.png", media_type="image/png")


# ---------------------------------------------------------------- 版本与在线更新
# 服务器上的项目是从 GitHub 克隆的 git 仓库：定时 git fetch，发现新提交时网页上提示更新，
# 点“立即更新”后在后台运行 update.sh（拉取代码、安装依赖、重启），数据库变更在启动时自动执行。
UPDATE_BRANCH = os.getenv("UPDATE_BRANCH", "main")
UPDATE_CHECK_SEC = 30 * 60
_update = {"checked": 0.0, "data": None, "running": False}
LOG_DIR = BASE_DIR / "logs"


def git(*args: str, timeout: int = 60) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=BASE_DIR, capture_output=True, text=True, timeout=timeout)


def is_git_repo() -> bool:
    return (BASE_DIR / ".git").exists()


def current_version() -> str:
    if not is_git_repo():
        return "dev"
    r = git("rev-parse", "--short", "HEAD")
    return r.stdout.strip() or "dev"


STARTED_VERSION = current_version()


def read_release(text: str) -> str:
    v = (text or "").strip()
    return f"v{v}" if v and not v.startswith("v") else (v or "")


# 发布版本号（VERSION 文件，如 1.2）；STARTED_VERSION 是具体的提交编号
RELEASE = read_release((BASE_DIR / "VERSION").read_text(encoding="utf-8") if (BASE_DIR / "VERSION").exists() else "")


def check_updates(force: bool = False) -> dict:
    if not is_git_repo():
        return {"enabled": False, "current": STARTED_VERSION, "available": False,
                "reason": "不是从 GitHub 安装的，无法在线更新"}
    if not force and _update["data"] and time.time() - _update["checked"] < UPDATE_CHECK_SEC:
        return {**_update["data"], "running": _update["running"]}
    data = {"enabled": True, "current": STARTED_VERSION, "release": RELEASE, "available": False, "behind": 0, "changes": []}
    try:
        r = git("fetch", "--quiet", "origin", UPDATE_BRANCH)
        if r.returncode != 0:
            data["error"] = "连不上 GitHub，稍后再试"
        else:
            ref = f"origin/{UPDATE_BRANCH}"
            behind = int(git("rev-list", "--count", f"HEAD..{ref}").stdout.strip() or 0)
            data.update(
                latest=git("rev-parse", "--short", ref).stdout.strip(),
                latest_release=read_release(git("show", f"{ref}:VERSION").stdout),
                behind=behind,
                available=behind > 0,
                changes=[x for x in git("log", "--format=%h %s", "-n", "20", f"HEAD..{ref}").stdout.splitlines() if x],
            )
    except (subprocess.TimeoutExpired, OSError, ValueError) as e:
        data["error"] = f"检查更新失败：{e}"
    _update.update(checked=time.time(), data=data)
    return {**data, "running": _update["running"]}


@app.get("/api/version")
def version():
    return {"version": STARTED_VERSION, "release": RELEASE}


@app.get("/api/update/check")
def update_check(force: bool = False):
    return check_updates(force)


@app.post("/api/update/apply", status_code=202)
def update_apply():
    """后台运行 update.sh：拉取最新代码、安装依赖，然后重启后端。"""
    info = check_updates(force=True)
    if not info.get("enabled"):
        raise HTTPException(400, info.get("reason", "无法在线更新"))
    if not info.get("available"):
        raise HTTPException(400, info.get("error") or "已经是最新版本")
    if _update["running"]:
        return {"status": "updating"}
    LOG_DIR.mkdir(exist_ok=True)
    log = open(LOG_DIR / "update.log", "a", encoding="utf-8")
    log.write(f"\n===== {dt.datetime.now():%Y-%m-%d %H:%M:%S} 网页触发更新 {STARTED_VERSION} -> {info.get('latest')} =====\n")
    log.flush()
    subprocess.Popen(
        ["bash", str(BASE_DIR / "update.sh"), "--yes", "--from-app", "--pid", str(os.getpid())],
        cwd=BASE_DIR, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True,
    )
    _update["running"] = True
    return {"status": "updating", "from": STARTED_VERSION, "to": info.get("latest")}


# ---------------------------------------------------------------- 数据库变更（迁移）
# migrations/ 里的 .sql 文件按文件名顺序执行一次，执行记录保存在 schema_migrations 表。
# 每条语句以分号加换行结尾；不要在一条语句中间写分号。
def run_migrations() -> None:
    files = sorted((BASE_DIR / "migrations").glob("*.sql"))
    try:
        conn = pymysql.connect(**DB)
    except Exception as e:  # 数据库连不上时照常启动，网页会显示具体原因
        print(f"[迁移] 跳过：连接数据库失败：{e}", file=sys.stderr)
        return
    try:
        with conn.cursor() as cur:
            cur.execute(
                """CREATE TABLE IF NOT EXISTS schema_migrations (
                     name VARCHAR(200) NOT NULL PRIMARY KEY,
                     applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                   ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='已执行的数据库变更'"""
            )
            cur.execute("SELECT name FROM schema_migrations")
            done = {r["name"] for r in cur.fetchall()}
            for f in files:
                if f.name in done:
                    continue
                sql = re.sub(r"^\s*--.*$", "", f.read_text(encoding="utf-8"), flags=re.M)
                for stmt in re.split(r";\s*(?:\n|$)", sql):
                    if stmt.strip():
                        cur.execute(stmt)
                cur.execute("INSERT INTO schema_migrations (name) VALUES (%s)", (f.name,))
                print(f"[迁移] 已执行 {f.name}")
    except Exception as e:
        print(f"[迁移] 失败：{e}", file=sys.stderr)
    finally:
        conn.close()


@app.get("/api/config")
def config():
    """网页启动时读取：统一使用的时区和服务器当前时间。"""
    return {**tz_info(), "server_time": to_json(now())}


@app.get("/api/health")
def health():
    with db() as cur:
        cur.execute("SELECT COUNT(*) AS n FROM schedule")
        return {"ok": True, "schedule_rows": cur.fetchone()["n"], "server_time": to_json(now())}


@app.get("/api/day")
def get_day(date: Optional[str] = None):
    """某一天的全部安排及打卡情况。"""
    d = parse_date(date)
    with db() as cur:
        cur.execute(DAY_SQL, {"d": d, "dt": day_type_of(d)})
        items = [row_json(r) for r in cur.fetchall()]
    t = today()
    return {
        "date": d.isoformat(),
        "day_type": day_type_of(d),
        "server_time": to_json(now()),
        "editable": 0 <= (t - d).days <= MAKEUP_MAX_DAYS,
        "items": items,
    }


class CheckinIn(BaseModel):
    date: str
    schedule_id: int
    status: Literal["done", "partial", "skipped"] = "done"
    actual_min: Optional[int] = Field(None, ge=0, le=1440)
    started_at: Optional[str] = None  # 'YYYY-MM-DD HH:MM:SS'，计时打卡用
    ended_at: Optional[str] = None
    note: Optional[str] = Field(None, max_length=500)


def parse_dt(s: Optional[str]) -> Optional[dt.datetime]:
    if not s:
        return None
    try:
        return dt.datetime.fromisoformat(s.replace("T", " "))
    except ValueError:
        raise HTTPException(400, "时间格式应为 YYYY-MM-DD HH:MM:SS")


class PunchIn(BaseModel):
    date: str
    schedule_id: int


@app.post("/api/punch/start")
def punch_start(body: PunchIn, x_client: Optional[str] = Header(None)):
    """开始学习：开始前 1 分钟起，到这一项结束前都可以。"""
    d = parse_date(body.date)
    check_date_window(d)
    t = now()
    with db() as cur:
        slot = study_slot(cur, d, body.schedule_id)
        w_start, _, _, start_dt, end_dt = windows(d, slot)
        if t < w_start:
            raise HTTPException(400, f"「{slot['task']}」{fmt_t(start_dt)} 开始，{fmt_t(start_dt - dt.timedelta(minutes=START_BEFORE_MIN))} 起才能开始学习")
        if t >= end_dt:
            raise HTTPException(400, f"「{slot['task']}」已经结束，不能再开始了")
        row = get_checkin(cur, d, body.schedule_id)
        if row and row["status"] != "started":
            raise HTTPException(400, f"「{slot['task']}」已经打过卡了")
        if not row:
            cur.execute(
                "INSERT INTO checkin (checkin_date, schedule_id, status, started_at) VALUES (%s, %s, 'started', %s)",
                (d, body.schedule_id, t.replace(microsecond=0)),
            )
        out = row_json(get_checkin(cur, d, body.schedule_id))
    notify(d, x_client)
    return out


@app.post("/api/punch/end")
def punch_end(body: PunchIn, x_client: Optional[str] = Header(None)):
    """结束学习：结束前 1 分钟到结束后 5 分钟内。实际时长 = 结束 − 开始。"""
    d = parse_date(body.date)
    check_date_window(d)
    t = now()
    with db() as cur:
        slot = study_slot(cur, d, body.schedule_id)
        _, w_end_from, w_end_to, start_dt, end_dt = windows(d, slot)
        if t < w_end_from:
            raise HTTPException(400, f"「{slot['task']}」{fmt_t(end_dt - dt.timedelta(minutes=END_BEFORE_MIN))} 起才能结束学习")
        if t > w_end_to:
            raise HTTPException(400, f"「{slot['task']}」结束打卡时间已过（{fmt_t(end_dt + dt.timedelta(minutes=END_AFTER_MIN))} 截止），请在完整作息表里补打卡")
        row = get_checkin(cur, d, body.schedule_id)
        if row and row["status"] != "started":
            raise HTTPException(400, f"「{slot['task']}」已经打过卡了")
        ended = t.replace(microsecond=0)
        if row and row["started_at"]:
            actual = max(0, int((ended - row["started_at"]).total_seconds() // 60))
            status = "done" if actual >= slot["planned_min"] * DONE_RATIO else "partial"
            cur.execute(
                """UPDATE checkin SET status = %s, ended_at = %s, actual_min = %s
                   WHERE checkin_date = %s AND schedule_id = %s""",
                (status, ended, actual, d, body.schedule_id),
            )
        else:  # 没打开始卡：按计划时长记完成
            cur.execute(
                """INSERT INTO checkin (checkin_date, schedule_id, status, ended_at) VALUES (%s, %s, 'done', %s)""",
                (d, body.schedule_id, ended),
            )
        out = row_json(get_checkin(cur, d, body.schedule_id))
    notify(d, x_client)
    return out


@app.put("/api/checkin")
def put_checkin(body: CheckinIn, x_client: Optional[str] = Header(None)):
    """跳过 / 补打卡 / 修改打卡（同一天同一项只有一条记录）。

    - 还没到开始时间：不允许
    - 开始和结束打卡的时间段内：只能“跳过”，开始和结束请用主页面的打卡按钮
    - 结束打卡时间过了以后：可以补打卡（完成 / 部分完成 / 跳过），记为补打卡，不记备注
    """
    d = parse_date(body.date)
    check_date_window(d)
    t = now()
    status, actual = body.status, body.actual_min
    with db() as cur:
        slot = study_slot(cur, d, body.schedule_id)
        w_start, _, w_end_to, start_dt, _ = windows(d, slot)
        if t < w_start:
            raise HTTPException(400, f"「{slot['task']}」{fmt_t(start_dt)} 才开始，还不能打卡")
        live = t <= w_end_to
        if live and status != "skipped":
            raise HTTPException(400, "这一项还在打卡时间内，请用主页面的按钮开始 / 结束学习")
        if status == "partial" and actual is None:
            raise HTTPException(400, "部分完成需要填写实际分钟数")
        if status == "skipped":
            actual = None
        row = get_checkin(cur, d, body.schedule_id)
        # 已经正常打过卡（完成 / 部分完成 / 跳过）的记录，修改时保留原来的“补打卡”标记；其余情况在打卡时间过后算补打卡
        if row and row["status"] in ("done", "partial", "skipped"):
            is_makeup = row["is_makeup"]
        else:
            is_makeup = 0 if live else 1
        note = None if is_makeup else (body.note or None)
        started = row["started_at"] if row else None
        ended = row["ended_at"] if row else None
        cur.execute(
            """INSERT INTO checkin
                 (checkin_date, schedule_id, status, started_at, ended_at, actual_min, is_makeup, note)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
               ON DUPLICATE KEY UPDATE
                 status = VALUES(status), actual_min = VALUES(actual_min),
                 is_makeup = VALUES(is_makeup), note = VALUES(note)""",
            (d, body.schedule_id, status, started, ended, actual, is_makeup, note),
        )
        out = row_json(get_checkin(cur, d, body.schedule_id))
    notify(d, x_client)
    return out


@app.delete("/api/checkin")
def delete_checkin(date: str, schedule_id: int, x_client: Optional[str] = Header(None)):
    """撤销打卡。"""
    d = parse_date(date)
    check_date_window(d)
    with db() as cur:
        n = cur.execute(
            "DELETE FROM checkin WHERE checkin_date = %s AND schedule_id = %s", (d, schedule_id)
        )
    notify(d, x_client)
    return {"deleted": n}


@app.get("/api/stats")
def get_stats(days: int = Query(7, ge=1, le=366), weeks: int = Query(8, ge=1, le=104)):
    """每日、每周指标。"""
    since = today() - dt.timedelta(days=days - 1)
    with db() as cur:
        cur.execute(
            "SELECT * FROM v_daily_stats WHERE plan_date >= %s ORDER BY plan_date", (since,)
        )
        daily = [row_json(r) for r in cur.fetchall()]
        cur.execute("SELECT * FROM v_weekly_stats ORDER BY week_start DESC LIMIT %s", (weeks,))
        weekly = [row_json(r) for r in cur.fetchall()]
        # 本周各学习事项：计划分钟、实际分钟（只算需要打卡的学习项）
        monday = today() - dt.timedelta(days=today().weekday())
        cur.execute(
            """SELECT task, SUM(planned_min) AS planned_min, SUM(effective_min) AS actual_min,
                      SUM(status IS NOT NULL) AS checked, COUNT(*) AS planned_items
               FROM v_daily_plan
               WHERE plan_date >= %s AND count_in_rate = 1
               GROUP BY task ORDER BY planned_min DESC""",
            (monday,),
        )
        tasks = [row_json(r) for r in cur.fetchall()]
    return {"daily": daily, "weekly": weekly, "week_tasks": tasks}


@app.exception_handler(pymysql.err.MySQLError)
def mysql_error(_, exc: pymysql.err.MySQLError):
    if exc.args and exc.args[0] == 1146:
        return JSONResponse(status_code=503, content={"detail": "数据库里还没有表：请先导入 daily_routine.sql"})
    return JSONResponse(status_code=500, content={"detail": f"数据库错误：{exc.args[-1]}"})


if __name__ == "__main__":
    import uvicorn

    run_migrations()
    print(f"作息打卡 {RELEASE or ''} 版本 {STARTED_VERSION}")
    uvicorn.run(
        app,
        host=os.getenv("HOST", "0.0.0.0"),
        port=int(os.getenv("PORT", "8000")),
        timeout_graceful_shutdown=2,  # 按 Ctrl+C 时不等推送连接，2 秒内退出
        proxy_headers=True,           # 在 nginx 后面运行时识别真实来源
        forwarded_allow_ips="127.0.0.1",
    )
