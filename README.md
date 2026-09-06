# PulseWatch

Учебный сервис мониторинга доступности сайтов на Python. Пользователь добавляет URL, запускает проверки и видит историю HTTP-статусов и времени ответа.

## Возможности

- регистрация и вход через cookie-сессию;
- отдельные мониторы для каждого пользователя;
- ручные и фоновые HTTP-проверки;
- история проверок и расчёт uptime;
- пауза и удаление монитора;
- блокировка локальных IP-адресов для снижения риска SSRF;
- health endpoint `GET /api/health`;
- JSON-список мониторов `GET /api/monitors`.

## Запуск

Требуется Python 3.11 или новее.

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements-dev.txt
$env:SESSION_SECRET="change-this-secret"
python manage.py runserver
```

Открой `http://127.0.0.1:8000`.

Во втором терминале запусти worker для автоматических проверок:

```powershell
.venv\Scripts\Activate.ps1
python manage.py worker
```

Без worker кнопка «Проверить сейчас» продолжает работать.

## PostgreSQL

По умолчанию используется SQLite. Для PostgreSQL достаточно задать переменную окружения:

```powershell
$env:DATABASE_URL="postgresql+psycopg://user:password@localhost:5432/uptime"
```

Таблицы создаются при запуске. Для развития проекта следующим шагом стоит добавить Alembic.

## Тесты

```powershell
python manage.py test
```

Дополнительные команды:

```powershell
python manage.py initdb
python manage.py runserver --host 0.0.0.0 --port 8080
python manage.py runserver --no-reload
```

## Что намеренно не добавлено

Docker, CI/CD, Kubernetes, Terraform и мониторинг самого приложения не включены: это отдельная DevOps-часть проекта.
