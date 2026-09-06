FROM python:3.13-slim
WORKDIR /uptine_monitor
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["python", "manage.py", "runserver", "--host", "0.0.0.0", "--port", "8000", "--no-reload"]

