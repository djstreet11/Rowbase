# Rowbase MCP server (stdio) — used by MCP directories (e.g. Glama) for automated checks, and handy for container use.
#   docker build -t rowbase . && docker run -i --rm rowbase            # speaks MCP JSON-RPC on stdin/stdout
#   docker run -i --rm -v ~/.config/rowbase:/root/.config/rowbase -e ROWBASE_SECRETS=file rowbase   # with your connections
FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml README.md LICENSE NOTICE ./
COPY rowbase ./rowbase
RUN pip install --no-cache-dir . && useradd -m rowbase
USER rowbase
# no OS keychain inside a container → passwords come from ~/.config/rowbase/secrets.json or ROWBASE_PASSWORD_<NAME>
ENV ROWBASE_SECRETS=file PYTHONUNBUFFERED=1
ENTRYPOINT ["rowbase", "mcp"]
