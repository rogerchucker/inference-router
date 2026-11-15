# App CI reads these defaults before installing its toolchain.
ARG PYTHON_VERSION=3.12
ARG UV_VERSION=0.11.20

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv
FROM python:${PYTHON_VERSION}-slim
COPY --from=uv /uv /usr/local/bin/uv
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --no-cache
COPY app.py providers.py router.py ./
USER 10001:10001
ARG SOURCE_SHA=local
ENV ROUTER_BUILD_SHA=${SOURCE_SHA}
EXPOSE 8080
CMD ["/app/.venv/bin/python", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
