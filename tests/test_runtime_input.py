"""Bounded real startup GET ownership, partial bytes, and one shared deadline."""
import base64
import http.server
import json
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

probe = Path(sys.argv[1]).resolve()
for mode in ("complete", "status", "redirect", "bytes", "headers", "deadline", "twice",
             "TERM", "INT", "header-TERM", "prestop", "precancel", "presignal"):
    entered = threading.Event()
    release = threading.Event()
    observed = []

    class Fixture(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            observed.append(self.path)
            if mode == "header-TERM":
                self.wfile.write(b"HTTP/1.1 200 OK\r\nX-Partial: retained\r\n")
                self.wfile.flush()
                entered.set()
                release.wait(3)
                return
            body = b"\xff\x00exact" if mode == "complete" else b"0123456789"
            self.send_response(503 if mode == "status" else 302 if mode == "redirect" else 200)
            self.send_header("X-Fixture", "first")
            self.send_header("X-Fixture", "second")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Location", "/must-not-follow")
            self.end_headers()
            self.wfile.write(body[:2] if mode in ("deadline", "twice", "TERM", "INT") else body)
            self.wfile.flush()
            entered.set()
            if mode in ("deadline", "twice", "TERM", "INT"):
                release.wait(3)

        def log_message(self, *_args):
            pass

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        owner = threading.Thread(target=server.serve_forever)
        owner.start()
        process = subprocess.Popen([str(probe), f"http://127.0.0.1:{server.server_port}/input",
                                    mode, "250" if mode in ("deadline", "twice") else "2000",
                                    "5" if mode == "bytes" else "1024",
                                    "40" if mode == "headers" else "4096"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        started = time.monotonic()
        try:
            if mode == "presignal":
                assert process.stdout.readline().strip() == "installed"
                process.send_signal(signal.SIGTERM)
                stdout, stderr = process.communicate("continue\n", timeout=3)
            else:
                if mode in ("TERM", "INT", "header-TERM"):
                    assert entered.wait(2)
                    time.sleep(.03)
                    process.send_signal(signal.SIGINT if mode == "INT" else signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=3)
            assert process.returncode == 0, stderr
            result = json.loads(stdout)
            body = base64.b64decode(result["body_b64"], validate=True)
            headers = base64.b64decode(result["headers_b64"], validate=True)
            if mode in ("prestop", "precancel", "presignal"):
                assert not observed and not body and not headers and result["joined"] is None
                assert result["kind"] == ("nhCanceled" if mode == "precancel" else "nhInterrupted")
            else:
                assert result["joined"] is True and observed == ["/input"]
                if mode in ("deadline", "twice", "TERM", "INT", "header-TERM"):
                    assert not result["complete"]
                    assert result["kind"] == ("nhDeadline" if mode in ("deadline", "twice") else "nhInterrupted")
                    assert body == (b"" if mode == "header-TERM" else b"01")
                    if mode == "header-TERM": assert b"X-Partial: retained\r\n" in headers
                    if mode == "twice": assert result["next_kind"] == "nhDeadline"
                elif mode in ("bytes", "headers"):
                    assert result["kind"] == "nhLimitExceeded" and not result["complete"]
                    assert len(body) <= 5 if mode == "bytes" else len(headers) <= 40
                else:
                    assert result["kind"] == "nhComplete" and result["complete"]
                    assert result["status"] == (503 if mode == "status" else 302 if mode == "redirect" else 200)
                    assert body == (b"\xff\x00exact" if mode == "complete" else b"0123456789")
            print(mode, result["kind"], round(time.monotonic() - started, 3), flush=True)
        finally:
            if process.poll() is None: process.terminate()
            process.wait(timeout=3)
            release.set()
            server.shutdown()
            owner.join(timeout=3)
            assert not owner.is_alive()
