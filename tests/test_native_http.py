"""Verify actual native bytes/deadline/stop behavior; no provider credentials or calls."""
import base64
import http.server
import json
import signal
import subprocess
import sys
import threading
from pathlib import Path

probe = Path(sys.argv[1]).resolve()
for mode in ("complete", "empty", "partial", "headers", "unobserved", "interrupted"):
    entered = threading.Event()
    release = threading.Event()

    class Fixture(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            assert self.rfile.read(int(self.headers["Content-Length"])) == b'{"fixture":true}'
            if mode in {"unobserved", "interrupted"}:
                entered.set()
                release.wait(5)
                return
            self.send_response(200)
            self.send_header("X-Fixture", "first")
            self.send_header("X-Fixture", "second")
            self.send_header("Content-Length", "0" if mode == "empty" else "4")
            self.end_headers()
            if mode == "empty":
                return
            if mode == "complete":
                self.wfile.write(b"\x00\xffok")
                self.wfile.flush()
                return
            if mode == "partial":
                self.wfile.write(b"\xe2\x82")
                self.wfile.flush()
            entered.set()
            release.wait(5)

        def log_message(self, *_args):
            pass

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        owner = threading.Thread(target=server.serve_forever)
        owner.start()
        process = subprocess.Popen([str(probe), f"http://127.0.0.1:{server.server_port}/v1/messages",
                                    "5000" if mode == "interrupted" else "250"]
                                   + (["repeat"] if mode not in {"complete", "empty"} else []),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            if mode == "interrupted":
                assert entered.wait(3), "owned request never started"
                process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=4)
            assert process.returncode == 0, stderr
            result = json.loads(stdout)
            body = base64.b64decode(result["body_b64"], validate=True)
            headers = base64.b64decode(result["headers_b64"], validate=True)
            assert result["latency_ms"] >= 0
            if mode in {"complete", "empty"}:
                assert result["kind"] == "nhComplete" and result["complete"]
                assert result["status"] == 200 and body == (b"\x00\xffok" if mode == "complete" else b"")
            else:
                assert result["kind"] == ("nhInterrupted" if mode == "interrupted" else "nhDeadline")
                assert not result["complete"]
                assert body == (b"\xe2\x82" if mode == "partial" else b"")
                assert result["status"] == (None if mode in {"unobserved", "interrupted"} else 200)
            if mode not in {"unobserved", "interrupted"}:
                assert headers.count(b"X-Fixture: ") == 2
                assert b"X-Fixture: first\r\nX-Fixture: second\r\n" in headers
            else:
                assert headers == b""
            print(mode, result["kind"], len(headers), len(body), flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=4)
            release.set()
            server.shutdown()
            owner.join(timeout=4)
            assert not owner.is_alive()
