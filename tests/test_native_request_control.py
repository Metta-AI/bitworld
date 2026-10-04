"""Real request admission, partial invalid bytes, request-local cancel, and later calls."""
import base64
import http.server
import json
import subprocess
import sys
import threading
import time
from pathlib import Path

probe = Path(sys.argv[1]).resolve()
for trial in range(8):
    entered = threading.Event()
    release = threading.Event()
    requests = []

    class Fixture(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            requests.append(body)
            assert body in {b"first", b"second"}
            self.send_response(200)
            self.send_header("X-Fixture", "first")
            self.send_header("X-Fixture", "second")
            self.send_header("Content-Length", "4")
            self.end_headers()
            self.wfile.write(b"\xe2\x82" if body == b"first" else b"\x00\xffok")
            self.wfile.flush()
            if body == b"first":
                entered.set()
                release.wait(5)

        def log_message(self, *_args):
            pass

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        owner = threading.Thread(target=server.serve_forever)
        owner.start()
        process = subprocess.Popen([str(probe), f"http://127.0.0.1:{server.server_port}/v1/messages"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            assert entered.wait(3), "the real owned request never entered"
            time.sleep(0.2)
            started = time.monotonic()
            stdout, stderr = process.communicate("cancel\n", timeout=3)
            assert process.returncode == 0, stderr
            result = json.loads(stdout)
            assert result["canceled"]["status"] == 200
            assert not result["canceled"]["complete"]
            assert base64.b64decode(result["canceled"]["body_b64"], validate=True) == b"\xe2\x82"
            assert b"X-Fixture: first\r\nX-Fixture: second\r\n" in base64.b64decode(result["canceled"]["headers_b64"], validate=True)
            assert result["later_call_complete"] and result["original_deadline_retained"]
            assert result["global_stop_blocks_fresh_control"]
            assert requests == [b"first", b"second"]
            print(trial, "phase cancel joined; later call completes; global stop seals", time.monotonic() - started, flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=3)
            release.set()
            server.shutdown()
            owner.join(timeout=3)
            assert not owner.is_alive()
