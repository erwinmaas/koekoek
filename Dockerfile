# CopyTrader relay server — minimal, no third-party deps (stdlib only).
FROM python:3.12-slim

# Run as non-root.
RUN useradd --create-home --uid 10001 relay
WORKDIR /app

COPY relay_server.py /app/relay_server.py

# Port the server listens on (override with -e PORT=... ; ACA sets targetPort).
ENV PORT=9000

# Token MUST be supplied at runtime via COPYTRADER_TOKEN — the server refuses
# to start without it (fail closed). Never bake the secret into the image.

EXPOSE 9000
USER relay

# TCP healthcheck: a bare connect succeeds at L4 (handshake is app-level).
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD python -c "import os,socket; s=socket.create_connection(('127.0.0.1', int(os.environ.get('PORT','9000'))), 3); s.close()" || exit 1

# Plain TCP by default. For app-level TLS, append: --tls --cert /certs/cert.pem --key /certs/key.pem
ENTRYPOINT ["python", "relay_server.py"]
