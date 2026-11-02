FROM python:3.13-slim

# No .pyc files (the root filesystem is read-only in Kubernetes) and unbuffered
# logs so `kubectl logs` shows output immediately.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

# Run as an unprivileged, numeric user so Kubernetes can enforce
# `runAsNonRoot` and the namespace's "restricted" Pod Security Standard.
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home app
USER 10001:10001

EXPOSE 8000
CMD ["python", "manage.py", "runserver", "--host", "0.0.0.0", "--port", "8000", "--no-reload"]
