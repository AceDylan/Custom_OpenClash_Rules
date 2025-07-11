FROM python:3.11-slim

WORKDIR /app

COPY bot.py /app/
COPY requirements.txt /app/

RUN apt-get update && \
    apt-get install -y git && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    pip install --no-cache-dir -r requirements.txt

CMD ["python", "bot.py"] 