FROM ghcr.io/astral-sh/uv:0.11.20 AS uv
FROM python:3.12-slim
COPY --from=uv /uv /usr/local/bin/uv
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --no-cache
COPY app.py providers.py router.py ./
USER 10001:10001
EXPOSE 8080
CMD ["/app/.venv/bin/python", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
