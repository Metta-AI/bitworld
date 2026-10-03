"""Actual upload ownership, interruption, and one shared cleanup deadline."""
import base64
import http.server
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

probe = Path(sys.argv[1]).resolve()
for mode in ("put", "post", "stop", "budget", "writer", "failure", "signal-upload", "retained"):
    entered = threading.Event()
    release = threading.Event()
    observed = []

    class Fixture(http.server.BaseHTTPRequestHandler):
        def handle_upload(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            observed.append((self.command, self.path, body))
            if self.path in {"/inference", "/first"}:
                entered.set()
                release.wait(5)
                return
            self.send_response(503 if mode == "failure" else 200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            if mode == "signal-upload":
                entered.set()
                release.wait(3)
            self.wfile.write(b"ok")

        do_PUT = handle_upload
        do_POST = handle_upload

        def do_GET(self):
            observed.append((self.command, self.path, b""))
            self.send_response(200)
            self.send_header("Content-Length", "8")
            self.end_headers()
            self.wfile.write(b"reloaded")

        def log_message(self, *_args):
            pass

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        owner = threading.Thread(target=server.serve_forever)
        owner.start()
        url = f"http://127.0.0.1:{server.server_port}"
        process = subprocess.Popen([str(probe), url, mode, "250" if mode == "budget" else "3000"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            if mode in {"stop", "signal-upload"}:
                assert entered.wait(2), "inference never started"
                process.send_signal(signal.SIGTERM)
                if mode == "signal-upload":
                    release.set()
            stdout, stderr = process.communicate(timeout=4)
            if mode == "failure":
                assert process.returncode != 0
                assert "artifact upload failed: 503" in stderr and url not in stderr
            else:
                assert process.returncode == 0, stderr
            if mode == "budget":
                assert observed == [("PUT", "/first", b"first")]
                assert json.loads(stdout) == {"first": "nhDeadline", "second": "nhDeadline"}
            elif mode == "retained":
                assert observed == [("PUT", "/", b"retained"), ("GET", "/", b"")] * 8
            elif mode in {"writer", "failure"}:
                assert observed == [("PUT", "/", b"private checkpoint")]
            else:
                lines = [json.loads(line) for line in stdout.splitlines()]
                if mode == "stop":
                    assert lines[0] == {"inference": "nhInterrupted"}
                    assert observed[0] == ("POST", "/inference", b"started")
                result = lines[-1]
                assert result["kind"] == "nhComplete" and result["complete"]
                assert result["status"] == 200 and base64.b64decode(result["body_b64"]) == b"ok"
                assert observed[-1] == ("POST" if mode == "post" else "PUT", "/artifact", b"\x00\xffcheckpoint")
            print(mode, process.returncode, len(observed), flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=4)
            release.set()
            server.shutdown()
            owner.join(timeout=4)
            assert not owner.is_alive()

with tempfile.TemporaryDirectory(prefix="bitworld-artifact-") as directory:
    path = Path(directory) / "private.jsonl"
    first = subprocess.run([str(probe), path.as_uri(), "local", "3000"], capture_output=True, text=True)
    assert first.returncode == 0, first.stderr
    assert (os.stat(path).st_mode & 0o777) == 0o600
    payload = json.loads(path.read_text())
    assert payload["status"] == "truncated"
    original = path.read_bytes()
    repeated = subprocess.run([str(probe), path.as_uri(), "local", "3000"], capture_output=True, text=True)
    assert repeated.returncode != 0 and path.read_bytes() == original
    print("local interrupted checkpoint and exclusive private creation", flush=True)
