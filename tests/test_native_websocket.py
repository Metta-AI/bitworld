"""Real transport gates: bytes survive timeout, control frames, and native stop."""
import base64
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import tempfile
import unittest
import struct
import subprocess
import sys
import time

PROBE = str(Path(sys.argv[1]).resolve())

def frame(payload: bytes, opcode: int = 1, final: bool = True) -> bytes:
    first = opcode | (128 if final else 0)
    size = len(payload)
    if size < 126:
        return bytes([first, size]) + payload
    if size < 65536:
        return bytes([first, 126]) + struct.pack('!H', size) + payload
    return bytes([first, 127]) + struct.pack('!Q', size) + payload

def exact(connection, count):
    data = b''
    while len(data) < count:
        chunk = connection.recv(count - len(data))
        assert chunk, 'unexpected EOF'
        data += chunk
    return data

def client_frame(connection, prefix=b''):
    header = prefix + exact(connection, 2 - len(prefix))
    size = header[1] & 127
    assert header[1] & 128
    if size == 126:
        size = struct.unpack('!H', exact(connection, 2))[0]
    elif size == 127:
        size = struct.unpack('!Q', exact(connection, 8))[0]
    mask = exact(connection, 4)
    body = exact(connection, size)
    return header[0] & 15, bytes(value ^ mask[index % 4] for index, value in enumerate(body))

def upgrade(connection, valid=True, stall=False):
    request = b''
    while b'\r\n\r\n' not in request:
        request += exact(connection, 1)
    if stall:
        time.sleep(.7)
        return
    key = next(line.split(b':', 1)[1].strip() for line in request.split(b'\r\n')
               if line.lower().startswith(b'sec-websocket-key:'))
    accept = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
    if not valid:
        accept = b'invalid'
    connection.sendall(b'HTTP/1.1 101 Arbitrary Reason\r\nUpgrade: websocket\r\n'
                       b'Connection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')

def run_case(name, mode, operation, signals=None, valid=True, tls=None, trust=None, host="127.0.0.1", rejected_tls=False, stall=False):
    with socket.socket() as listener, concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        listener.settimeout(3)
        def serve():
            connection, _ = listener.accept()
            if tls:
                connection = tls.wrap_socket(connection, server_side=True)
            with connection:
                connection.settimeout(5)
                if rejected_tls:
                    assert connection.recv(1) == b''
                    return
                upgrade(connection, valid, stall)
                operation(connection)
        future = executor.submit(serve)
        environment = os.environ.copy()
        environment.pop('SSL_CERT_FILE', None)
        if trust:
            environment['SSL_CERT_FILE'] = trust
        scheme = 'wss' if tls else 'ws'
        with subprocess.Popen([PROBE, f'{scheme}://{host}:{listener.getsockname()[1]}/player', mode],
                              env=environment,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as child:
            first = json.loads(child.stdout.readline())
            if signals:
                time.sleep(.1)
                child.send_signal(signals)
            child.wait(timeout=8)
            output, error = child.stdout.read(), child.stderr.read()
            assert child.returncode == 0, (name, error)
            rows = [first] + [json.loads(line) for line in output.splitlines()]
        if rejected_tls and not trust:
            with unittest.TestCase().assertRaises(ssl.SSLError):
                future.result(timeout=5)
        else:
            future.result(timeout=5)
    print(json.dumps({'case': name, 'rows': rows}), flush=True)
    return rows

def partial(connection):
    data = frame(b'buffered after timeout')
    connection.sendall(data[:1])
    time.sleep(.15)
    for byte in data[1:]:
        connection.sendall(bytes([byte]))

rows = run_case('partial-header-resume', 'resume', partial)
assert rows[1]['kind'] == 'wsDeadline' and rows[2]['data'] == 'buffered after timeout'

def partial_body(connection):
    data = frame(b'x' * 300)
    connection.sendall(data[:6])
    time.sleep(.15)
    connection.sendall(data[6:])
rows = run_case('extended-body-resume', 'resume', partial_body)
assert rows[1]['kind'] == 'wsDeadline' and rows[2]['data'] == 'x' * 300

def fragments(connection):
    connection.sendall(frame(b'frag', final=False) + frame(b'ping', opcode=9))
    assert client_frame(connection) == (10, b'ping')
    connection.sendall(frame(b'mented', opcode=0))
rows = run_case('fragment-control', 'normal', fragments)
assert rows[1]['data'] == 'fragmented'
metadata = json.dumps({'prompt_token_ids': list(range(32768))}).encode()
rows = run_case('32768-actual-token-ids', 'large', lambda connection: connection.sendall(frame(metadata)))
assert rows[1]['token_count'] == 32768 and rows[1]['bytes'] > 65536

def stop_receipt(connection):
    connection.sendall(frame(b'partial')[:3])
    assert client_frame(connection) == (1, b'stopped')
    connection.sendall(frame(b'partial')[3:] + frame(b'evidence_received'))
for sig in (signal.SIGTERM, signal.SIGINT):
    rows = run_case(sig.name, 'signal', stop_receipt, sig)
    assert rows[1]['kind'] == 'wsInterrupted'
    # Pending incomplete inbound bytes are retained. Finish them before receipt.
    assert rows[2]['kind'] == 'wsReady'
    assert rows[3]['data'] == 'partial' and rows[4]['data'] == 'evidence_received'

rows = run_case('wrong-accept', 'normal', lambda connection: None, valid=False)
assert rows[0]['connect'] == 'wsFailure'
rows = run_case('EOF', 'normal', lambda connection: None)
assert rows[1]['kind'] == 'wsClosed'
for name, payload in (
    ('unexpected-continuation', frame(b'no-start', opcode=0)),
    ('fragmented-control', frame(b'ping', opcode=9, final=False)),
    ('binary-message', frame(b'bytes', opcode=2)),
    ('invalid-close-code', frame(struct.pack('!H', 1005), opcode=8)),
    ('invalid-close-utf8', frame(struct.pack('!H', 1000) + b'\xff', opcode=8)),
    ('masked-server-frame', b'\x81\x81abcdx'),
):
    rows = run_case(name, 'normal', lambda connection: connection.sendall(payload))
    assert rows[1]['kind'] == 'wsFailure'

def echo_many(connection):
    for index in range(100):
        assert client_frame(connection) == (1, str(index).encode())
        connection.sendall(frame(str(index).encode()))
rows = run_case('concurrent-reader-writer', 'concurrent', echo_many)
assert rows[1]['kind'] == 'wsReady' and rows[1]['messages'] == 100
started = time.monotonic()
rows = run_case('upgrade-absolute-deadline', 'normal', lambda connection: None, stall=True)
assert rows[0]['connect'] == 'wsDeadline' and time.monotonic() - started < 1

def pong_after_timeout(connection):
    prefix = exact(connection, 1)
    connection.sendall(frame(b'ping-retained', opcode=9))
    time.sleep(.35)
    assert client_frame(connection, prefix) == (1, b'x' * (8 * 1024 * 1024))
    assert client_frame(connection) == (10, b'ping-retained')
    connection.sendall(frame(b'pong-finished'))
rows = run_case('pong-retained-across-writer-deadline', 'pong-timeout', pong_after_timeout)
assert rows[1]['kind'] == 'wsDeadline' and rows[2]['data'] == 'pong-finished'

def partial_send(connection):
    time.sleep(.2)
    assert client_frame(connection) == (1, b'x' * (8 * 1024 * 1024))
    assert client_frame(connection) == (1, b'stopped')
    connection.sendall(frame(b'evidence_received'))
rows = run_case('partial-send-flush-before-stop', 'partial-send', partial_send)
assert rows[1]['kind'] == 'wsDeadline' and rows[2]['kind'] == 'wsReady'
assert rows[3]['data'] == 'evidence_received'
with tempfile.TemporaryDirectory(prefix='native-websocket-tls-', dir=Path(PROBE).parent) as directory:
    cert = Path(directory) / 'cert.pem'
    key = Path(directory) / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                    '-keyout', str(key), '-out', str(cert), '-days', '1',
                    '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    rows = run_case('TLS-untrusted', 'normal', lambda connection: None, tls=context,
                    host='localhost', rejected_tls=True)
    assert rows[0]['connect'] == 'wsFailure'
    rows = run_case('TLS-trusted', 'normal', lambda connection: connection.sendall(frame(b'verified')),
                    tls=context, host='localhost', trust=str(cert))
    assert rows[1]['data'] == 'verified'
    rows = run_case('TLS-wrong-host', 'normal', lambda connection: None,
                    tls=context, trust=str(cert), rejected_tls=True)
    assert rows[0]['connect'] == 'wsFailure'
print('native websocket transport gates passed')
