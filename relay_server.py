"""
CopyTrader Relay Server
-----------------------
Master EA connects and pushes trade snapshots.
Slave EAs connect and receive those snapshots, broadcast in real time.

The newest master frame is cached, so a slave that connects LATE immediately
receives the current state instead of waiting for the next master tick — this
mirrors the file-transport behavior and avoids late-join divergence.

Usage:
    # Plain TCP (LAN / trusted tunnel only):
    python relay_server.py --port 9000 --token "shared-secret"

    # TLS (recommended for the public internet):
    python relay_server.py --port 9000 --tls --cert cert.pem --key key.pem --token "shared-secret"

    # Token may also come from the environment instead of the command line:
    COPYTRADER_TOKEN="shared-secret" python relay_server.py --port 9000 --tls ...

    # Generate a self-signed cert (run once on the VPS):
    openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=copytrader"
    # NOTE: MT5 SocketTlsHandshake validates the cert chain. A self-signed cert
    #       will fail unless the CA is trusted on the slave machine. For real
    #       deployments use a cert from a real CA (e.g. Let's Encrypt) for the
    #       host the EA connects to.

Protocol:
    Handshake (one line):   "MASTER <token>\n"  or  "SLAVE <token>\n"
    Server replies:         "OK\n"  or  "ERROR:<reason>\n"
    Data (master->slaves):  text frames, newline-terminated, prefix "SNAP|"
                            Frames are forwarded opaque (server does not parse
                            their contents), it only checks the prefix + length.

Security:
    - Shared-secret token required on every connection (constant-time compare).
    - Without a token configured the server refuses to start (fail closed).
    - Only ONE master may be connected at a time.
"""

import socket
import ssl
import threading
import argparse
import logging
import os
import hmac

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

HOST = "0.0.0.0"
PORT = 9000
FRAME_PREFIX = "SNAP|"
MAX_LINE = 65536            # reject frames / handshakes longer than this
HANDSHAKE_TIMEOUT = 10.0

master_conn: socket.socket | None = None
master_lock = threading.Lock()

slave_conns: list[socket.socket] = []
slaves_lock = threading.Lock()

last_frame: bytes | None = None       # cache of newest master frame (for late join)
last_frame_lock = threading.Lock()

EXPECTED_TOKEN = ""                    # set in main()


def token_ok(provided: str) -> bool:
    # constant-time compare to avoid timing leaks
    return hmac.compare_digest(provided, EXPECTED_TOKEN)


def broadcast_to_slaves(data: bytes):
    with slaves_lock:
        dead = []
        for s in slave_conns:
            try:
                s.sendall(data)
            except Exception:
                dead.append(s)
        for s in dead:
            logging.info("Slave send failed, removing.")
            try:
                slave_conns.remove(s)
            except ValueError:
                pass


def read_line(conn: socket.socket, initial: bytes = b"") -> tuple[str | None, bytes]:
    """Read one newline-terminated line. Returns (line, leftover_bytes).
    leftover_bytes are any bytes already received past the first newline."""
    buf = initial
    while b"\n" not in buf:
        if len(buf) > MAX_LINE:
            return None, b""
        chunk = conn.recv(4096)
        if not chunk:
            return None, b""
        buf += chunk
    line, _, leftover = buf.partition(b"\n")
    return line.decode("utf-8", errors="ignore").strip(), leftover


def handle_master(conn: socket.socket, addr, leftover: bytes):
    global master_conn, last_frame
    logging.info(f"Master connected from {addr}")
    buffer = leftover                      # bytes already read past handshake
    try:
        while True:
            while b"\n" in buffer:
                line, _, buffer = buffer.partition(b"\n")
                line = line.strip()
                if not line:
                    continue
                if len(line) > MAX_LINE:
                    logging.warning("Master frame too long, dropped.")
                    continue
                text = line.decode("utf-8", errors="ignore")
                if not text.startswith(FRAME_PREFIX):
                    logging.warning(f"Master frame bad prefix, dropped: {text[:60]}")
                    continue
                frame = line + b"\n"
                with last_frame_lock:
                    last_frame = frame     # cache newest for late-joining slaves
                broadcast_to_slaves(frame)

            if len(buffer) > MAX_LINE:
                logging.warning("Master buffer overflow, resetting.")
                buffer = b""

            chunk = conn.recv(4096)
            if not chunk:
                break
            buffer += chunk
    except Exception as e:
        logging.error(f"Master error: {e}")
    finally:
        with master_lock:
            master_conn = None
        conn.close()
        logging.info("Master disconnected.")


def handle_slave(conn: socket.socket, addr):
    logging.info(f"Slave connected from {addr}")
    with slaves_lock:
        slave_conns.append(conn)

    # Send cached state immediately so a late slave syncs without waiting.
    with last_frame_lock:
        cached = last_frame
    if cached:
        try:
            conn.sendall(cached)
        except Exception:
            pass

    try:
        while True:
            data = conn.recv(64)           # slaves are read-only; detect close
            if not data:
                break
    except Exception as e:
        logging.error(f"Slave error: {e}")
    finally:
        with slaves_lock:
            if conn in slave_conns:
                slave_conns.remove(conn)
        conn.close()
        logging.info(f"Slave {addr} disconnected.")


def handle_client(conn: socket.socket, addr):
    global master_conn
    try:
        conn.settimeout(HANDSHAKE_TIMEOUT)
        line, leftover = read_line(conn)
        conn.settimeout(None)
    except Exception as e:
        logging.warning(f"Handshake failed from {addr}: {e}")
        conn.close()
        return

    if line is None:
        conn.close()
        return

    # Handshake: "ROLE <token>"
    fields = line.split(" ", 1)
    role = fields[0].upper()
    provided_token = fields[1] if len(fields) > 1 else ""

    if not token_ok(provided_token):
        logging.warning(f"Auth failed from {addr} (role={role!r}).")
        try:
            conn.sendall(b"ERROR:AUTH\n")
        except Exception:
            pass
        conn.close()
        return

    if role == "MASTER":
        with master_lock:
            if master_conn is not None:
                logging.warning("Second master rejected.")
                try:
                    conn.sendall(b"ERROR:MASTER_ALREADY_CONNECTED\n")
                except Exception:
                    pass
                conn.close()
                return
            master_conn = conn
        conn.sendall(b"OK\n")
        handle_master(conn, addr, leftover)
    elif role == "SLAVE":
        conn.sendall(b"OK\n")
        handle_slave(conn, addr)
    else:
        logging.warning(f"Unknown role {role!r} from {addr}")
        try:
            conn.sendall(b"ERROR:BAD_ROLE\n")
        except Exception:
            pass
        conn.close()


def main():
    global EXPECTED_TOKEN

    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", PORT)))
    parser.add_argument("--host", type=str, default=HOST)
    parser.add_argument("--tls", action="store_true", help="Enable TLS")
    parser.add_argument("--cert", type=str, default="cert.pem", help="TLS certificate file")
    parser.add_argument("--key",  type=str, default="key.pem",  help="TLS private key file")
    parser.add_argument("--token", type=str, default=os.environ.get("COPYTRADER_TOKEN", ""),
                        help="Shared secret (or set COPYTRADER_TOKEN env var)")
    args = parser.parse_args()

    EXPECTED_TOKEN = args.token
    if not EXPECTED_TOKEN:
        # Fail closed: an open relay can inject trades into every slave.
        raise SystemExit("Refusing to start without --token (or COPYTRADER_TOKEN). "
                         "An unauthenticated relay lets anyone inject trades.")

    raw_server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    raw_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    raw_server.bind((args.host, args.port))
    raw_server.listen(20)

    if args.tls:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certfile=args.cert, keyfile=args.key)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        server = context.wrap_socket(raw_server, server_side=True)
        logging.info(f"TLS relay listening on {args.host}:{args.port}")
    else:
        server = raw_server
        logging.info(f"Plain TCP relay listening on {args.host}:{args.port}")
        logging.warning("TLS disabled — use --tls on untrusted networks!")

    try:
        while True:
            try:
                conn, addr = server.accept()
            except ssl.SSLError as e:
                logging.warning(f"TLS accept error: {e}")
                continue
            t = threading.Thread(target=handle_client, args=(conn, addr), daemon=True)
            t.start()
    except KeyboardInterrupt:
        logging.info("Shutting down.")
    finally:
        server.close()


if __name__ == "__main__":
    main()
