import time
from datetime import UTC, datetime

from sqlalchemy import or_, select

from .checker import run_monitor_check
from .database import Base, SessionLocal, engine
from .models import Monitor


def run_due_checks() -> int:
    now = datetime.now(UTC)
    with SessionLocal() as db:
        monitors = db.scalars(
            select(Monitor).where(
                Monitor.is_active.is_(True),
                or_(Monitor.next_check_at.is_(None), Monitor.next_check_at <= now),
            )
        ).all()
        for monitor in monitors:
            run_monitor_check(db, monitor)
        return len(monitors)


def main() -> None:
    Base.metadata.create_all(bind=engine)
    print("Worker started. Press Ctrl+C to stop.")
    try:
        while True:
            checked = run_due_checks()
            if checked:
                print(f"Websites checked: {checked}")
            time.sleep(5)
    except KeyboardInterrupt:
        print("Worker stopped.")


if __name__ == "__main__":
    main()

