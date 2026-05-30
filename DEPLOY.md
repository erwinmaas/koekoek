# Deploying the relay to Azure Container Apps

The relay (`relay_server.py`) is packaged with the `Dockerfile`. It is a raw-TCP
server with **in-memory** state, which drives two hard constraints on Azure
Container Apps (ACA):

1. **TCP ingress, not HTTP.** EAs open a raw socket, not HTTP. ACA must use
   `transport: tcp` ingress (external). The platform does **L4 passthrough only**
   — it does **not** terminate TLS for TCP.
2. **Single replica.** Master and slave state lives in process memory and the
   relay fans frames out within one process. If ACA scales to >1 replica, a slave
   may land on a different replica than the master and receive nothing. Pin
   `minReplicas = maxReplicas = 1`. No scale-to-zero.

## TLS reality check (read this)

You cannot get a public CA certificate for the `*.azurecontainerapps.io`
hostname, and ACA TCP ingress won't terminate TLS for you. MT5's
`SocketTlsHandshake` validates the certificate chain against the host it
connects to, so **app-level TLS to the ACA FQDN will fail chain validation**.

Practical options, in order of effort:

| Option | Confidentiality | Notes |
|--------|-----------------|-------|
| **Plain TCP + strong token** (recommended on ACA) | None (cleartext) | Token still authenticates and blocks injection. Trade metadata travels in clear. Simplest. |
| Own VM/VPS + custom domain + real CA cert, run with `--tls` | Full | Leaves ACA; you control the hostname so the MT5 cert chain validates. |
| Front the relay with a TCP-terminating proxy on a domain you own | Full | More moving parts; ACA TCP native ingress can't do this itself. |

If confidentiality of position data matters, use a VM/VPS with your own domain
and a real cert rather than ACA TCP ingress. If a leaked token is the only real
threat (the token already prevents trade injection), plain TCP on ACA is
workable for a first deployment.

## Build & push

```bash
# Build for the ACA platform (linux/amd64)
az acr build --registry <youracr> --image koekoek-relay:1 \
  --platform linux/amd64 .
```

## Create the Container App (plain TCP, single replica)

```bash
# Store the token as a secret, not an env literal.
az containerapp create \
  --name koekoek-relay \
  --resource-group <rg> \
  --environment <aca-environment> \
  --image <youracr>.azurecr.io/koekoek-relay:1 \
  --target-port 9000 \
  --transport tcp \
  --ingress external \
  --min-replicas 1 \
  --max-replicas 1 \
  --secrets copytrader-token=<your-shared-secret> \
  --env-vars PORT=9000 COPYTRADER_TOKEN=secretref:copytrader-token
```

After creation, get the FQDN and the exposed port:

```bash
az containerapp show -n koekoek-relay -g <rg> \
  --query "properties.configuration.ingress.{fqdn:fqdn, exposedPort:exposedPort}"
```

ACA returns an `exposedPort` for TCP ingress — clients connect to
`fqdn:exposedPort`, which may differ from the internal `targetPort` (9000).

## Wire up the EA (`koekoek_v4.mq5`)

| Input | Value |
|-------|-------|
| `Transport` | `RELAY` |
| `RelayHost` | the ACA `fqdn` |
| `RelayPort` | the ACA `exposedPort` |
| `RelayUseTLS` | `false` (plain TCP on ACA) |
| `RelayToken` | the same shared secret |

Then in MetaTrader: **Tools → Options → Expert Advisors → Allow connections to
the listed URLs**, add `fqdn:exposedPort`. Otherwise the terminal blocks the
socket.

## Local sanity test before Azure

```bash
export COPYTRADER_TOKEN="your-shared-secret"
docker compose up --build
# In another shell, fake a slave handshake:
printf 'SLAVE your-shared-secret\n' | nc 127.0.0.1 9000   # expect: OK
printf 'SLAVE wrong-token\n'        | nc 127.0.0.1 9000   # expect: ERROR:AUTH
```

## Operational notes

- **Restart = state loss.** On container restart the cached frame is gone; the
  master republishes within 500 ms and slaves re-sync. Slaves freeze (keep
  positions) during any gap longer than `STALE_SEC` (~15 s).
- **One master only.** A second master connection is rejected
  (`ERROR:MASTER_ALREADY_CONNECTED`).
- **Rotate the token** by updating the ACA secret and the EA input together.

## Audit logging

Every **transaction** (a change in the master's position set — open, close, or
SL/TP modify) is logged as a `TXN` line with the seq, position count, number of
slaves it was delivered to, and the full frame. The master republishes every
~500 ms, but identical heartbeat frames are de-duplicated, so the log shows real
events only.

- **stdout** is always on — on ACA this is captured by Log Analytics
  (`az containerapp logs show -n koekoek-relay -g <rg> --follow`).
- **Durable file** (optional): set `LOG_FILE` (rotating, size-capped):

  ```bash
  --env-vars PORT=9000 COPYTRADER_TOKEN=secretref:copytrader-token \
             LOG_FILE=/data/relay_audit.log LOG_MAX_MB=50 LOG_BACKUPS=10
  ```

  For the file to survive restarts on ACA, mount a persistent Azure Files volume
  at the directory; otherwise rely on Log Analytics for retention.
