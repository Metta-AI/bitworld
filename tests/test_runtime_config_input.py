"""Runtime config input records real bytes before status, UTF-8, or JSON rejection."""
import base64
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

probe = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="bitworld-input-private-") as directory:
    root = Path(directory)
    for mode in ("valid", "status", "utf8", "json"):
        raw = b"\xffinvalid" if mode == "utf8" else b'{"invalid"' if mode == "json" else b'{"secret":"PRIVATE_INPUT_SENTINEL"}'
        class Fixture(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(503 if mode == "status" else 200)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
            def log_message(self, *_args):
                pass
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
            owner = threading.Thread(target=server.serve_forever)
            owner.start()
            destination = root / f"{mode}.json"
            try:
                result = subprocess.run([str(probe)], capture_output=True, text=True,
                                        env=os.environ | {"COGAME_CONFIG_URI": f"http://127.0.0.1:{server.server_port}/config",
                                                          "INPUT_PRIVATE_CAPTURE": str(destination)}, timeout=4)
                assert (result.returncode == 0) == (mode == "valid")
                capture = json.loads(destination.read_text())
                assert len(capture) == 1
                transport = capture[0]["transport"]
                assert base64.b64decode(transport["response_body_b64"], validate=True) == raw
                assert transport["response_complete"] and transport["response_reader_joined"]
                assert transport["http_status"] == (503 if mode == "status" else 200)
                assert destination.stat().st_mode & 0o777 == 0o600
                print(mode, "exact private input capture precedes validation", flush=True)
            finally:
                server.shutdown()
                owner.join(timeout=3)
                assert not owner.is_alive()
