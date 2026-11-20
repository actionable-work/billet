"""A guestbook HTTP service backed by PostgreSQL.

`guestbook migrate` creates the database if needed and applies the schema;
it is safe to run on every start. `guestbook serve` answers HTTP
requests. Configuration comes from the environment; the database password and
the session key are delivered by the runtime, never by the build.
"""

import hashlib
import hmac
import json
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg
from psycopg import errors, sql

SCHEMA_VERSION = 1
MIGRATION_LOCK = 4242
MAX_BODY_BYTES = 65536

LEVELS = {"debug": 10, "info": 20, "warning": 30}
THRESHOLD = LEVELS.get(os.environ.get("GUESTBOOK_LOG_LEVEL", "warning"), 30)


def log(message, level="info"):
    if LEVELS[level] >= THRESHOLD:
        print(f"guestbook: {message}", file=sys.stderr, flush=True)


def connect(timeout=3, dbname=None, autocommit=False):
    return psycopg.connect(
        host=os.environ["GUESTBOOK_DATABASE_HOST"],
        port=int(os.environ.get("GUESTBOOK_DATABASE_PORT", "5432")),
        dbname=dbname or os.environ["GUESTBOOK_DATABASE_NAME"],
        autocommit=autocommit,
        user=os.environ["GUESTBOOK_DATABASE_USER"],
        password=os.environ["GUESTBOOK_DATABASE_PASSWORD"],
        connect_timeout=timeout,
    )


def wait_for_database():
    """Connect to the server's maintenance database, retrying while it starts."""
    deadline = time.monotonic() + float(os.environ.get("GUESTBOOK_MIGRATION_WAIT", "15"))
    while True:
        try:
            return connect(dbname="postgres", autocommit=True)
        except psycopg.OperationalError as error:
            if time.monotonic() > deadline:
                log(f"database unavailable: {error}", "warning")
                return None
            time.sleep(1)


def ensure_database(maintenance):
    """Create the application database if it is missing. Safe to repeat."""
    name = os.environ["GUESTBOOK_DATABASE_NAME"]
    with maintenance:
        if maintenance.execute("SELECT 1 FROM pg_database WHERE datname = %s", (name,)).fetchone():
            return
        try:
            maintenance.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(name)))
            log(f"created database {name}")
        except (errors.DuplicateDatabase, errors.UniqueViolation):
            pass  # A concurrent replica created it first.


def migrate():
    maintenance = wait_for_database()
    if maintenance is None:
        return 1
    ensure_database(maintenance)
    with connect() as connection, connection.cursor() as cursor:
        # Concurrent replicas run the step at once; serialize them.
        cursor.execute("SELECT pg_advisory_xact_lock(%s)", (MIGRATION_LOCK,))
        cursor.execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations ("
            " version integer PRIMARY KEY,"
            " applied_at timestamptz NOT NULL DEFAULT now())"
        )
        cursor.execute("SELECT 1 FROM schema_migrations WHERE version = %s", (SCHEMA_VERSION,))
        if cursor.fetchone():
            log(f"schema already at version {SCHEMA_VERSION}")
            return 0
        cursor.execute(
            "CREATE TABLE entries ("
            " id serial PRIMARY KEY,"
            " author text NOT NULL,"
            " message text NOT NULL,"
            " created_at timestamptz NOT NULL DEFAULT now())"
        )
        cursor.execute("INSERT INTO schema_migrations (version) VALUES (%s)", (SCHEMA_VERSION,))
    log(f"applied migration {SCHEMA_VERSION}")
    return 0


def session_key():
    with open(os.environ["GUESTBOOK_SESSION_KEY_FILE"], "rb") as handle:
        key = handle.read().strip()
    if not key:
        raise SystemExit("guestbook: the session key file is empty")
    return key


class Handler(BaseHTTPRequestHandler):
    key = b""

    def reply(self, status, payload):
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def sign(self, entry_id, author, message):
        # A JSON array keeps field boundaries unambiguous.
        text = json.dumps([entry_id, author, message], separators=(",", ":")).encode()
        return hmac.new(self.key, text, hashlib.sha256).hexdigest()

    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, {"alive": True})
        if self.path == "/readyz":
            try:
                with connect(timeout=1) as connection:
                    row = connection.execute("SELECT max(version) FROM schema_migrations").fetchone()
            except psycopg.Error:
                return self.reply(503, {"ready": False})
            ready = row[0] is not None and row[0] >= SCHEMA_VERSION
            return self.reply(200 if ready else 503, {"ready": ready, "schema": row[0]})
        if self.path == "/entries":
            try:
                with connect() as connection:
                    rows = connection.execute("SELECT id, author, message FROM entries ORDER BY id").fetchall()
            except psycopg.Error as error:
                log(f"database unavailable: {error}", "warning")
                return self.reply(503, {"error": "database unavailable"})
            entries = [
                {"id": i, "author": a, "message": m, "signature": self.sign(i, a, m)}
                for i, a, m in rows
            ]
            return self.reply(200, {"entries": entries})
        return self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/entries":
            return self.reply(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self.reply(411, {"error": "expected a numeric Content-Length"})
        if length < 0:
            return self.reply(400, {"error": "invalid Content-Length"})
        if length > MAX_BODY_BYTES:
            return self.reply(413, {"error": f"the body exceeds {MAX_BODY_BYTES} bytes"})
        try:
            entry = json.loads(self.rfile.read(length))
            author, message = str(entry["author"]), str(entry["message"])
        except (ValueError, KeyError, TypeError):
            return self.reply(400, {"error": "expected author and message"})
        try:
            with connect() as connection:
                (entry_id,) = connection.execute(
                    "INSERT INTO entries (author, message) VALUES (%s, %s) RETURNING id",
                    (author, message),
                ).fetchone()
        except psycopg.Error as error:
            log(f"database unavailable: {error}", "warning")
            return self.reply(503, {"error": "database unavailable"})
        return self.reply(201, {"id": entry_id, "signature": self.sign(entry_id, author, message)})

    def log_message(self, format, *args):
        log(format % args, "debug")


def serve():
    Handler.key = session_key()
    server = ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("GUESTBOOK_PORT", "8080"))), Handler)
    server.daemon_threads = True

    def stop(signum, _frame):
        log(f"received {signal.Signals(signum).name}; shutting down")
        threading.Thread(target=server.shutdown).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log(f"listening on port {server.server_address[1]}")
    server.serve_forever()
    server.server_close()
    log("stopped")
    return 0


def main(argv):
    commands = {"migrate": migrate, "serve": serve}
    if len(argv) != 2 or argv[1] not in commands:
        print("usage: guestbook <migrate|serve>", file=sys.stderr)
        return 2
    return commands[argv[1]]()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
