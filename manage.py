import argparse
import subprocess
import sys


def runserver(args: argparse.Namespace) -> None:
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host=args.host,
        port=args.port,
        reload=not args.no_reload,
    )


def run_worker(_: argparse.Namespace) -> None:
    from app.worker import main

    main()


def init_database(_: argparse.Namespace) -> None:
    from app.database import Base, engine
    from app import models  # noqa: F401 - импорт регистрирует модели

    Base.metadata.create_all(bind=engine)
    print("База данных подготовлена.")


def run_tests(_: argparse.Namespace) -> None:
    result = subprocess.run([sys.executable, "-m", "pytest"], check=False)
    raise SystemExit(result.returncode)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Управление PulseWatch")
    commands = parser.add_subparsers(dest="command", required=True)

    server = commands.add_parser("runserver", help="Запустить веб-сервер")
    server.add_argument("--host", default="127.0.0.1")
    server.add_argument("--port", type=int, default=8000)
    server.add_argument("--no-reload", action="store_true")
    server.set_defaults(handler=runserver)

    worker = commands.add_parser("worker", help="Запустить фоновые проверки")
    worker.set_defaults(handler=run_worker)

    initdb = commands.add_parser("initdb", help="Создать таблицы базы данных")
    initdb.set_defaults(handler=init_database)

    tests = commands.add_parser("test", help="Запустить тесты")
    tests.set_defaults(handler=run_tests)
    return parser


if __name__ == "__main__":
    arguments = build_parser().parse_args()
    arguments.handler(arguments)

