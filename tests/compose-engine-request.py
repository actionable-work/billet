import http.server
import json
import os
import re
import socketserver
import subprocess
import sys
import tempfile
import threading


class Engine(http.server.BaseHTTPRequestHandler):
    def log_message(self, message, *args):
        print(message % args, file=sys.stderr)

    def respond(self, status, payload=None):
        body = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("API-Version", "1.54")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def handle_engine_request(self):
        path = re.sub(r"^/v\d+\.\d+", "", self.path.split("?", 1)[0])
        if path == "/_ping":
            self.respond(200)
        elif path in ("/containers/json", "/networks"):
            self.respond(200, [])
        elif path == "/volumes":
            self.respond(200, {"Volumes": []})
        elif path.startswith("/images/") and path.endswith("/json"):
            self.respond(200, {"Id": "sha256:" + "a" * 64, "Os": "linux", "Architecture": self.server.arch, "Config": {}})
        elif path == "/networks/create":
            self.respond(201, {"Id": "b" * 64})
        elif path == "/containers/create":
            body = self.rfile.read(int(self.headers["Content-Length"]))
            self.server.creates.append(json.loads(body))
            self.respond(400, {"message": "Billet test recorded the container create request"})
        else:
            self.respond(404, {"message": f"Unexpected Engine endpoint: {self.command} {path}"})

    do_HEAD = handle_engine_request
    do_GET = handle_engine_request
    do_POST = handle_engine_request


compose, config, arch = sys.argv[1:]
with tempfile.TemporaryDirectory(dir="/tmp") as directory:
    socket = os.path.join(directory, "engine.sock")
    with socketserver.UnixStreamServer(socket, Engine) as engine:
        engine.arch = arch
        engine.creates = []
        worker = threading.Thread(target=engine.serve_forever, daemon=True)
        worker.start()
        env = {**os.environ, "DOCKER_HOST": f"unix://{socket}", "DOCKER_CONFIG": directory}
        env.pop("DOCKER_CONTEXT", None)
        try:
            result = subprocess.run(
                [compose, "--project-name", "billet-cpu", "--file", config,
                 "create", "--no-build", "--pull", "never"],
                env=env, capture_output=True, text=True, timeout=30,
            )
        finally:
            engine.shutdown()
            worker.join()
        assert len(engine.creates) == 1, result.stderr
        assert engine.creates[0]["HostConfig"]["NanoCpus"] == 9223370937343148032, engine.creates
