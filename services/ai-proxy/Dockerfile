FROM python:3.12-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
RUN useradd --uid 10001 --create-home demo
COPY demo/ ./demo/
COPY services/ai-proxy/app.py ./app.py
USER 10001
EXPOSE 3002
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=10 CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:3002/health', timeout=2)"
CMD ["python", "app.py"]
