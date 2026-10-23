import os
from contextlib import asynccontextmanager
from datetime import UTC
from math import ceil
from pathlib import Path

from fastapi import Depends, FastAPI, Form, HTTPException, Request, status
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from starlette.middleware.sessions import SessionMiddleware

from .checker import normalize_url, run_monitor_check
from .database import Base, engine, get_db
from .models import Check, Monitor, User
from .security import EMAIL_PATTERN, csrf_token, hash_password, verify_csrf, verify_password


BASE_DIR = Path(__file__).resolve().parent


@asynccontextmanager
async def lifespan(_: FastAPI):
    Base.metadata.create_all(bind=engine)
    yield


app = FastAPI(title="Uptime Monitor", lifespan=lifespan)
app.add_middleware(
    SessionMiddleware,
    secret_key=os.getenv("SESSION_SECRET", "development-secret-change-me"),
    same_site="lax",
    https_only=False,
)
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=BASE_DIR / "templates")


def current_user(request: Request, db: Session) -> User | None:
    user_id = request.session.get("user_id")
    return db.get(User, user_id) if user_id else None


def require_user(request: Request, db: Session) -> User:
    user = current_user(request, db)
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Login required")
    return user


def monitor_for_user(db: Session, monitor_id: int, user: User) -> Monitor:
    monitor = db.scalar(
        select(Monitor).where(Monitor.id == monitor_id, Monitor.user_id == user.id)
    )
    if not monitor:
        raise HTTPException(status_code=404, detail="Monitor not found")
    return monitor


def monitor_snapshot(db: Session, monitor: Monitor) -> dict:
    """Use one history view for the initial page and its live updates."""
    checks = db.scalars(
        select(Check)
        .where(Check.monitor_id == monitor.id)
        .order_by(Check.checked_at.desc(), Check.id.desc())
        .limit(50)
    ).all()
    total, successful = db.execute(
        select(func.count(Check.id), func.count(Check.id).filter(Check.is_available.is_(True)))
        .where(Check.monitor_id == monitor.id)
    ).one()
    maximum = max((check.response_time_ms or 0 for check in checks), default=0)
    chart_max_ms = max(100, ceil(maximum / 100) * 100)

    def utc_time(value):
        # SQLite returns naive datetimes; stored check timestamps are UTC.
        return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)

    return {
        "monitor": {
            "id": monitor.id,
            "is_active": monitor.is_active,
            "is_available": monitor.last_available,
            "status_code": monitor.last_status_code,
        },
        "total_checks": total,
        "uptime": round(successful / total * 100, 2) if total else None,
        "chart_max_ms": chart_max_ms,
        "checks": [
            {
                "id": check.id,
                "checked_at": utc_time(check.checked_at).isoformat(),
                "checked_at_label": utc_time(check.checked_at).strftime("%Y-%m-%d %H:%M:%S UTC"),
                "time_label": utc_time(check.checked_at).strftime("%H:%M:%S"),
                "is_available": check.is_available,
                "status_code": check.status_code,
                "response_time_ms": check.response_time_ms,
                "error_message": check.error_message,
                "chart_height": (check.response_time_ms or 0) / chart_max_ms * 100,
            }
            for check in checks
        ],
    }


def page_context(request: Request, db: Session, **values):
    values.update(
        request=request,
        user=current_user(request, db),
        csrf_token=csrf_token(request),
        message=request.session.pop("message", None),
    )
    return values


@app.get("/", response_class=HTMLResponse)
def home(request: Request, db: Session = Depends(get_db)):
    if current_user(request, db):
        return RedirectResponse("/dashboard", status_code=303)
    return templates.TemplateResponse(request, "home.html", page_context(request, db))


@app.get("/register", response_class=HTMLResponse)
def register_page(request: Request, db: Session = Depends(get_db)):
    return templates.TemplateResponse(request, "register.html", page_context(request, db))


@app.post("/register")
def register(
    request: Request,
    email: str = Form(...),
    password: str = Form(...),
    csrf: str = Form(...),
    db: Session = Depends(get_db),
):
    verify_csrf(request, csrf)
    email = email.strip().lower()
    error = None
    if not EMAIL_PATTERN.match(email):
        error = "Enter a valid email address."
    elif len(password) < 8:
        error = "Password must be at least 8 characters."
    elif db.scalar(select(User).where(User.email == email)):
        error = "An account with this email already exists."

    if error:
        context = page_context(request, db, error=error, email=email)
        return templates.TemplateResponse(request, "register.html", context, status_code=400)

    user = User(email=email, password_hash=hash_password(password))
    db.add(user)
    db.commit()
    db.refresh(user)
    request.session["user_id"] = user.id
    request.session["message"] = "Account created."
    return RedirectResponse("/dashboard", status_code=303)


@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request, db: Session = Depends(get_db)):
    return templates.TemplateResponse(request, "login.html", page_context(request, db))


@app.post("/login")
def login(
    request: Request,
    email: str = Form(...),
    password: str = Form(...),
    csrf: str = Form(...),
    db: Session = Depends(get_db),
):
    verify_csrf(request, csrf)
    user = db.scalar(select(User).where(User.email == email.strip().lower()))
    if not user or not verify_password(password, user.password_hash):
        context = page_context(request, db, error="Incorrect email or password.", email=email)
        return templates.TemplateResponse(request, "login.html", context, status_code=400)
    request.session["user_id"] = user.id
    return RedirectResponse("/dashboard", status_code=303)


@app.post("/logout")
def logout(request: Request, csrf: str = Form(...)):
    verify_csrf(request, csrf)
    request.session.clear()
    return RedirectResponse("/", status_code=303)


@app.get("/dashboard", response_class=HTMLResponse)
def dashboard(request: Request, db: Session = Depends(get_db)):
    user = require_user(request, db)
    monitors = db.scalars(
        select(Monitor).where(Monitor.user_id == user.id).order_by(Monitor.created_at.desc())
    ).all()
    available = sum(m.last_available is True for m in monitors)
    unavailable = sum(m.last_available is False for m in monitors)
    context = page_context(
        request, db, monitors=monitors, available=available, unavailable=unavailable
    )
    return templates.TemplateResponse(request, "dashboard.html", context)


@app.get("/monitors/new", response_class=HTMLResponse)
def new_monitor_page(request: Request, db: Session = Depends(get_db)):
    require_user(request, db)
    return templates.TemplateResponse(request, "monitor_form.html", page_context(request, db))


@app.post("/monitors")
def create_monitor(
    request: Request,
    name: str = Form(...),
    url: str = Form(...),
    interval_seconds: int = Form(60),
    csrf: str = Form(...),
    db: Session = Depends(get_db),
):
    verify_csrf(request, csrf)
    user = require_user(request, db)
    try:
        url = normalize_url(url)
    except ValueError as exc:
        context = page_context(request, db, error=str(exc), name=name, url=url)
        return templates.TemplateResponse(request, "monitor_form.html", context, status_code=400)

    if not 30 <= interval_seconds <= 86400:
        raise HTTPException(status_code=400, detail="Interval must be between 30 and 86400")

    monitor = Monitor(
        user_id=user.id,
        name=name.strip()[:100] or "Untitled monitor",
        url=url,
        interval_seconds=interval_seconds,
    )
    db.add(monitor)
    db.commit()
    db.refresh(monitor)
    request.session["message"] = "Monitor added."
    return RedirectResponse(f"/monitors/{monitor.id}", status_code=303)


@app.get("/monitors/{monitor_id}", response_class=HTMLResponse)
def monitor_detail(monitor_id: int, request: Request, db: Session = Depends(get_db)):
    user = require_user(request, db)
    monitor = monitor_for_user(db, monitor_id, user)
    context = page_context(
        request, db, monitor=monitor, snapshot=monitor_snapshot(db, monitor)
    )
    return templates.TemplateResponse(request, "monitor_detail.html", context)


@app.post("/monitors/{monitor_id}/check")
def check_now(
    monitor_id: int,
    request: Request,
    csrf: str = Form(...),
    db: Session = Depends(get_db),
):
    verify_csrf(request, csrf)
    user = require_user(request, db)
    monitor = monitor_for_user(db, monitor_id, user)
    run_monitor_check(db, monitor)
    return RedirectResponse(f"/monitors/{monitor.id}", status_code=303)


@app.post("/monitors/{monitor_id}/toggle")
def toggle_monitor(
    monitor_id: int,
    request: Request,
    csrf: str = Form(...),
    db: Session = Depends(get_db),
):
    verify_csrf(request, csrf)
    user = require_user(request, db)
    monitor = monitor_for_user(db, monitor_id, user)
    monitor.is_active = not monitor.is_active
    db.commit()
    return RedirectResponse(f"/monitors/{monitor.id}", status_code=303)


@app.post("/monitors/{monitor_id}/delete")
def delete_monitor(
    monitor_id: int,
    request: Request,
    csrf: str = Form(...),
    db: Session = Depends(get_db),
):
    verify_csrf(request, csrf)
    user = require_user(request, db)
    monitor = monitor_for_user(db, monitor_id, user)
    db.delete(monitor)
    db.commit()
    request.session["message"] = "Monitor deleted."
    return RedirectResponse("/dashboard", status_code=303)


@app.get("/api/health")
def health():
    return {"status": "ok"}


@app.get("/api/monitors")
def api_monitors(request: Request, db: Session = Depends(get_db)):
    user = require_user(request, db)
    monitors = db.scalars(select(Monitor).where(Monitor.user_id == user.id)).all()
    return [
        {
            "id": monitor.id,
            "name": monitor.name,
            "url": monitor.url,
            "is_active": monitor.is_active,
            "is_available": monitor.last_available,
            "status_code": monitor.last_status_code,
            "last_checked_at": monitor.last_checked_at,
        }
        for monitor in monitors
    ]


@app.get("/api/monitors/{monitor_id}/checks")
def api_monitor_checks(monitor_id: int, request: Request, db: Session = Depends(get_db)):
    user = require_user(request, db)
    monitor = monitor_for_user(db, monitor_id, user)
    return JSONResponse(monitor_snapshot(db, monitor), headers={"Cache-Control": "no-store"})


@app.exception_handler(401)
def unauthorized(_: Request, __: HTTPException):
    return RedirectResponse("/login", status_code=303)


@app.exception_handler(403)
def forbidden(_: Request, exc: HTTPException):
    return JSONResponse({"detail": exc.detail}, status_code=403)

