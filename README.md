# Koekoek

A lightweight MQL5 **copy trader** for MetaTrader 5. A *master* EA publishes its
open positions; one or more *slave* EAs mirror them into other accounts.

The slave is idempotent and self-healing: it reconciles its positions to the
master's current state on every update, so a slave that starts late simply syncs
to the live picture instead of replaying a backlog.

| File | What it is |
|------|------------|
| `koekoek_v3.mq5` | **Stable.** Local copy trading via a shared file. |
| `koekoek_v4.mq5` | **Preview.** Everything in v3 **plus** remote copying over a relay server. |
| `relay_server.py` | Relay server for v4 (TCP / TLS). |
| `CHANGELOG.md` | Version history and rationale. |

---

## 1. Using v3 (local copy trading)

v3 copies trades between two terminals **on the same machine**, using a shared
file in MetaTrader's common `Files` folder. No network, no server.

### Install

1. Copy `koekoek_v3.mq5` into `MQL5/Experts/` of **both** terminals
   (MetaEditor → open the folder via *File → Open Data Folder*).
2. Compile in MetaEditor (`F7`). It should compile with no errors or warnings.
3. Attach the EA to a chart in each terminal and enable **Algo Trading**.

> Both terminals must share the same common folder — this is the default when
> they run under the same Windows user. The file lives in
> `…/Terminal/Common/Files/koekoek_v3.bin`.

### Configure

Attach to the **master** account's terminal:

| Input | Value |
|-------|-------|
| `Mode` | `MODE_MASTER` |

Attach to the **slave** account's terminal:

| Input | Value |
|-------|-------|
| `Mode` | `MODE_SLAVE` |
| `LotSetting` | `AUTO_RISK` or `MANUAL_LOT` |
| `RiskSetting` | `LIGHT` / `MEDIUM` / `HIGH` (used only with `AUTO_RISK`) |
| `ManualLotSize` | fixed lot (used only with `MANUAL_LOT`) |

**Lot sizing on the slave**

- `MANUAL_LOT` → every copy uses `ManualLotSize`.
- `AUTO_RISK` → lot scales with slave balance:
  `lot = (balance / 1000) * factor`, where the factor is
  `LIGHT 0.01 / MEDIUM 0.04 / HIGH 0.10`.
  The result is clamped to the symbol's min/max and rounded to its lot step.

### How it behaves

- The master writes a full snapshot of its open positions every 500 ms,
  published **atomically** (write-temp-then-rename) so the slave never reads a
  half-written file.
- The slave reconciles each tick: opens any master position it is missing,
  syncs SL/TP, and closes copies whose master position is gone.
- The slave only ever touches **its own** positions (tagged with a magic
  number) — manual trades and other EAs on the slave account are left alone.
- If the master stops updating for more than ~15 s, the slave **freezes**
  (keeps existing copies open) rather than acting on stale data.

### Quick test (demo first!)

1. Master + slave on demo accounts.
2. Open a trade on the master → it appears on the slave within ~1 s.
3. Modify SL/TP on the master → the slave follows.
4. Close on the master → the slave closes.
5. Restart the slave while trades are open → it re-syncs to the current master
   state with no duplicate burst.

> ⚠️ Always validate on demo accounts before going live. The slave can close
> positions; a misconfiguration affects real money.

---

## 2. Sneak preview: v4 (remote copying via relay)

v4 keeps **everything in v3 unchanged** — including the local file mode as the
default — and adds an option to copy trades between terminals on **different
machines / VPSes** through a small relay server.

### What's new

- **Transport selector.** A new `Transport` input: `LOCAL_FILE` (default,
  behaves exactly like v3) or `RELAY`.
- **User-configurable relay.** `RelayHost`, `RelayPort`, `RelayUseTLS`, and a
  shared-secret `RelayToken` — all set from the EA inputs.
- **Relay server (`relay_server.py`).** Master pushes snapshots, the relay fans
  them out to all slaves, and caches the latest snapshot so a **late-joining
  slave syncs instantly**.

### How it will work

```
[Master terminal] --TCP/TLS--> [relay_server.py on a VPS] --TCP/TLS--> [Slave terminal(s)]
```

Run the relay (a token is required — it refuses to start without one):

```bash
# plain TCP, for a LAN or a trusted tunnel
python relay_server.py --port 9000 --token "your-shared-secret"

# TLS, for the public internet
python relay_server.py --port 9000 --tls --cert cert.pem --key key.pem --token "your-shared-secret"
```

Then on the EA set `Transport = RELAY` and fill in `RelayHost`, `RelayPort`,
`RelayToken` (and `RelayUseTLS` if the server runs with `--tls`).

### Setup gotchas (read before testing v4)

- **Whitelist the address.** Add `RelayHost:RelayPort` to
  *Tools → Options → Expert Advisors → Allow connections to the listed URLs*,
  or MetaTrader will block the socket.
- **TLS certificates.** MetaTrader validates the certificate chain, so a
  self-signed cert will fail the handshake. Use a cert from a real CA (e.g.
  Let's Encrypt) for the host the EA connects to, or test plain TCP over a
  trusted VPN/tunnel first.
- **Same broker for now.** Trade matching still relies on the broker preserving
  the order comment. This is reliable on a single broker; cross-broker setups
  need a persistent ticket map (planned).

### Status

v4 is a **preview**: the transport and the relay are in place and the relay
server passes a syntax/compile check, but the end-to-end flow has not yet been
hardened in live conditions. Use `koekoek_v3.mq5` for anything that matters.
See `CHANGELOG.md` for the full list of changes and open items.
