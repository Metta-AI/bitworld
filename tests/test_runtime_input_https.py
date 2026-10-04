"""Verify configured private CA trust without changing global certificate stores."""
import base64
import http.server
import json
import os
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

probe = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="bitworld-https-") as directory:
    root = Path(directory)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                    "-nodes", "-days", "1", "-subj", "/CN=Owned fixture CA", "-keyout", str(root / "ca.key"),
                    "-out", str(root / "ca.pem")], check=True, capture_output=True)
    subprocess.run(["openssl", "req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                    "-nodes", "-subj", "/CN=localhost", "-keyout", str(root / "server.key"),
                    "-out", str(root / "server.csr")], check=True, capture_output=True)
    (root / "extensions").write_text("subjectAltName=DNS:localhost\n")
    subprocess.run(["openssl", "x509", "-req", "-in", str(root / "server.csr"), "-CA", str(root / "ca.pem"),
                    "-CAkey", str(root / "ca.key"), "-CAcreateserial", "-days", "1", "-extfile", str(root / "extensions"),
                    "-out", str(root / "server.pem")], check=True, capture_output=True)
    observed = []

    class Fixture(http.server.BaseHTTPRequestHandler):
        def upload(self):
            observed.append((self.command, self.rfile.read(int(self.headers["Content-Length"]))))
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")

        def do_GET(self):
            observed.append((self.command, b""))
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")

        def log_message(self, *_args):
            pass

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(root / "server.pem", root / "server.key")
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.socket = context.wrap_socket(server.socket, server_side=True)
        owner = threading.Thread(target=server.serve_forever)
        owner.start()
        try:
            for transport in ("input",):
                for trust in ("untrusted", "trusted", "wrong-host"):
                    env = {**os.environ, "NO_PROXY": "localhost,127.0.0.1"}
                    env.pop("SSL_CERT_FILE", None)
                    if trust != "untrusted": env["SSL_CERT_FILE"] = str(root / "ca.pem")
                    host = "127.0.0.1" if trust == "wrong-host" else "localhost"
                    process = subprocess.run([str(probe), f"https://{host}:{server.server_port}/", transport, "2000", "1024", "4096"],
                                             env=env, capture_output=True, text=True, timeout=4)
                    assert process.returncode == 0, process.stderr
                    result = json.loads(process.stdout)
                    if trust == "trusted":
                        assert result["kind"] == "nhComplete" and result["complete"] and result["status"] == 200
                        assert result["joined"] is True and base64.b64decode(result["body_b64"]) == b"ok"
                    else:
                        assert result["kind"] == "nhTransportFailure" and not result["complete"]
                        assert result["joined"] is True and result["status"] is None and result["body_b64"] == ""
                    print(transport, trust, result["kind"], flush=True)
            assert observed == [("GET", b"")]
        finally:
            server.shutdown()
            owner.join(timeout=4)
            assert not owner.is_alive()

# A real unfinished TLS handshake must join on either an absolute deadline or SIGTERM.
for mode in ("deadline", "TERM"):
    entered = threading.Event()
    release = threading.Event()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        def hold_handshake():
            with listener.accept()[0] as connection:
                assert connection.recv(4096)
                entered.set()
                release.wait(3)
        owner = threading.Thread(target=hold_handshake)
        owner.start()
        process = subprocess.Popen([str(probe), f"https://127.0.0.1:{listener.getsockname()[1]}/",
                                    mode, "250" if mode == "deadline" else "2000", "1024", "4096"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert entered.wait(2)
            if mode == "TERM": process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=3)
            assert process.returncode == 0, stderr
            result = json.loads(stdout)
            assert result["kind"] == ("nhDeadline" if mode == "deadline" else "nhInterrupted")
            assert result["joined"] is True and not result["complete"]
            assert result["status"] is None and result["body_b64"] == result["headers_b64"] == ""
            print("partial-TLS", mode, result["kind"], flush=True)
        finally:
            if process.poll() is None: process.terminate()
            process.wait(timeout=3)
            release.set()
            owner.join(timeout=3)
            assert not owner.is_alive()
