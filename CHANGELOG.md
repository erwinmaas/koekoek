# Changelog — koekoek_v2.mq5

Master/slave trade copier over a shared `.bin` file in the common `Files` folder.

## [v4] — 2026-05-29

New file `koekoek_v4.mq5` (copy of v3) adds remote copying via a relay server.
Local file transport is unchanged and still the default. The relay server
`relay_server.py` was hardened.

### Added (EA)

- **Transport selector input (`Transport`).** `LOCAL_FILE` (default, identical to
  v3 behavior) or `RELAY` (TCP to a relay server). User picks per terminal.
- **Relay inputs.** `RelayHost`, `RelayPort`, `RelayUseTLS`, `RelayToken` — all
  user-settable. Host/port must also be whitelisted in the terminal's allowed-URL
  list or the socket is refused.
- **Text frame protocol.** `SNAP|seq|ts|count|t;sym;vol;type;open;sl;tp|...`,
  parsed with `StringSplit` (robust in MQL5; avoids fragile hand-rolled JSON).
  Strict integrity check: header count must equal actual record count or the
  frame is dropped.
- **Reconnect handling.** Throttled auto-reconnect (`RECONNECT_SEC`), connection-
  loss detection, runaway-buffer guard (`MAX_LINE`).
- **Receipt-based staleness for relay.** Freeze decision uses the slave's local
  time of the last received frame, not the master's timestamp — cross-broker
  server clocks can differ, so the master `ts` is not trusted for staleness over
  the relay.

### Notes (EA)

- Reconcile logic (magic-number ownership, two-pass open/close, freeze-on-stale)
  is unchanged and shared by both transports — only acquire/publish differ.
- TLS uses `SocketTlsHandshake`, which validates the cert chain; a self-signed
  cert needs the CA trusted on the slave machine, otherwise use a real CA cert.

### Hardened (relay_server.py)

- **Shared-secret auth.** Handshake is now `ROLE <token>`; constant-time compare
  (`hmac.compare_digest`). Server refuses to start without a token (fail closed) —
  an open relay could inject trades into every slave.
- **Late-join cache.** Newest master frame is cached and sent immediately to a
  newly connected slave, so a late slave syncs at once instead of waiting for the
  next master tick.
- **Handshake leftover-bytes bug fixed.** Bytes received past the role line are now
  preserved into the master data buffer instead of being discarded (the old code
  could drop or corrupt the first frame).
- **Frame validation + limits.** Frames must carry the `SNAP|` prefix; line-length
  caps on handshake, frames, and buffers prevent unbounded memory use.

## [v2.1] — 2026-05-29

Rewrite of the file-transport and slave reconcile logic. Fixes the "slave started
later than master produces duplicate trades and erratic behavior" bug.

### Fixed

- **Truncation race (root cause).** The master previously opened the file with
  `FILE_WRITE`, which truncates it to zero before rewriting. The slave reading at
  the same moment got an empty or half-written file. Master now writes to a `.tmp`
  file and `FileMove`s it over the real file — an atomic swap, so the reader always
  sees the complete old or complete new snapshot, never a partial one.

- **Mass-close on bad reads.** A short/garbage read left the slave's in-tick ticket
  set incomplete, so the orphan-close loop closed real copied trades, which then
  reopened next tick — the flapping that created many trades. The read is now
  validated (frame magic + record count + EOF check); any invalid read makes the
  slave do nothing that tick instead of closing positions.

- **Lot sizing used the chart symbol.** `CalculateLotSize` read volume min/max/step
  from `_Symbol` instead of the copied position's symbol. It now takes the symbol as
  a parameter, so multi-symbol copying sizes correctly.

### Added

- **Framed snapshot format.** File header carries a magic marker, a monotonic
  sequence number, a timestamp, and a record count, so the slave can detect partial
  data and skip unchanged snapshots.

- **Sequence debounce.** The slave only reconciles when the sequence number changes,
  rather than re-scanning every 500 ms tick.

- **Magic-number ownership (`COPY_MAGIC`).** The slave tags its copies and filters
  by magic, so it matches and closes only its own positions — manual trades and
  other EAs on the same account are never touched.

- **Heartbeat / stale guard (`STALE_SEC`).** If the master snapshot is older than the
  timeout (master crashed or detached), the slave freezes and keeps existing copies
  open instead of acting on stale data.

- **File share flags.** `FILE_SHARE_READ` / `FILE_SHARE_WRITE` on both ends prevent
  intermittent open failures (and missed updates) on Windows.

### Notes / open items

- Trade matching still relies on the broker preserving the order comment
  (`master ticket` stored in `POSITION_COMMENT`). Verified working same-broker.
  Cross-broker setups may strip/mutate the comment — switch to a persistent
  `masterTicket -> slaveTicket` map at that point.
- Volume changes (partial closes on the master) are not yet synced; only SL/TP are.
- Remote copying (master and slave on different servers) is not implemented — planned
  via a relay carrying the same authoritative snapshot.

## [v2.0] — initial

File-based master/slave copier: master dumps open positions to `.bin` every 500 ms,
slave reads and mirrors them, matching by ticket stored in the order comment.
