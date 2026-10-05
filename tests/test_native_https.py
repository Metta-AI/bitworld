"""Verify configured private CA trust without changing global certificate stores."""
import http.server
import json
import os
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

        do_POST = upload
        do_PUT = upload

        def log_message(self, *_args):
            pass

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(root / "server.pem", root / "server.key")
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.socket = context.wrap_socket(server.socket, server_side=True)
        owner = threading.Thread(target=server.serve_forever)
        owner.start()
        try:
            for transport in ("inference", "artifact"):
                for trust in ("untrusted", "trusted", "wrong-host"):
                    env = {**os.environ, "NO_PROXY": "localhost,127.0.0.1"}
                    env.pop("SSL_CERT_FILE", None)
                    if trust != "untrusted": env["SSL_CERT_FILE"] = str(root / "ca.pem")
                    host = "127.0.0.1" if trust == "wrong-host" else "localhost"
                    process = subprocess.run([str(probe), f"https://{host}:{server.server_port}/", transport],
                                             env=env, capture_output=True, text=True, timeout=4)
                    assert process.returncode == 0, process.stderr
                    result = json.loads(process.stdout)
                    if trust == "trusted":
                        assert result == {"kind": "nhComplete", "complete": True, "status": 200, "body": "ok"}
                    else:
                        assert result == {"kind": "nhTransportFailure", "complete": False, "status": None, "body": ""}
                    print(transport, trust, result["kind"], flush=True)
            assert observed == [("POST", b"private fixture"), ("PUT", b"private fixture")]
        finally:
            server.shutdown()
            owner.join(timeout=4)
            assert not owner.is_alive()
