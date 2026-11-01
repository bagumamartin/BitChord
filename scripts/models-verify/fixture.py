#!/usr/bin/env python3
"""HTTP fixture for scripts/check-models.sh.

Serves the deterministic fixtures so the model store's download path can be driven
through the states that matter without touching the project's release assets:

  /good.bin     a well-behaved file, Range-aware
  /corrupt.bin  the same length, different bytes — a transport that succeeded and a
                payload that is wrong, which is the only way to reach the checksum
                rejection rather than a network error
  /cut.bin      Range-aware, but a request *without* a Range header gets half a body
                and a closed connection — the interrupted transfer that must resume
  /coreml.aar   a real Apple Archive containing a dummy BeatThisFinal0.mlpackage,
                written by scripts/check-models.sh before the server starts
  /count        how many model requests have been served, for the metered test

The fixtures are generated from a fixed seed, so the harness can hash the same file
it asked the server to serve.
"""
import argparse
import hashlib
import json
import os
import random
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Large enough that CFNetwork delivers several chunks before the cut, which is
# what a real 23 MB transfer looks like. A body small enough to sit in one
# buffer can be dropped whole when the connection dies, and then the test would
# be measuring the socket, not the resume.
SIZE = 4 * 1024 * 1024

lock = threading.Lock()
served = 0


def payload(seed: int) -> bytes:
    rng = random.Random(seed)
    return bytes(rng.getrandbits(8) for _ in range(SIZE))


def write_fixtures(directory: str) -> dict:
    good = payload(1)
    corrupt = bytearray(payload(1))
    # One flipped bit is enough: same length, different digest.
    corrupt[0] ^= 0xFF
    # cut.bin is structurally the good file; only the server's behaviour differs.
    with open(os.path.join(directory, "good.bin"), "wb") as handle:
        handle.write(good)
    with open(os.path.join(directory, "corrupt.bin"), "wb") as handle:
        handle.write(bytes(corrupt))
    with open(os.path.join(directory, "cut.bin"), "wb") as handle:
        handle.write(good)
    return {
        "size": len(good),
        "good_sha256": hashlib.sha256(good).hexdigest(),
        "corrupt_sha256": hashlib.sha256(bytes(corrupt)).hexdigest(),
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    directory = "."
    manifest = {}

    def log_message(self, fmt, *args):
        sys.stderr.write("fixture: " + (fmt % args) + "\n")

    def do_GET(self):  # noqa: N802 — http.server's own naming
        global served
        if self.path == "/count":
            body = json.dumps({"requests": served}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        name = self.path.lstrip("/")
        if name not in ("good.bin", "corrupt.bin", "cut.bin", "coreml.aar"):
            self.send_error(404)
            return

        with lock:
            served += 1

        with open(os.path.join(self.directory, name), "rb") as handle:
            body = handle.read()

        start = 0
        header = self.headers.get("Range")
        if header and header.startswith("bytes="):
            start = int(header[len("bytes="):].split("-")[0])

        chunk = body[start:]
        self.send_response(206 if start else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        if start:
            self.send_header("Content-Range", f"bytes {start}-{len(body) - 1}/{len(body)}")
        self.send_header("Content-Length", str(len(chunk)))
        self.end_headers()

        # The interrupted case: advertise the whole body and deliver half of it.
        if name == "cut.bin" and not start:
            self.wfile.write(chunk[: len(chunk) // 4])
            self.wfile.flush()
            self.close_connection = True
            return

        self.wfile.write(chunk)
        self.wfile.flush()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--port-file")
    args = parser.parse_args()

    os.makedirs(args.dir, exist_ok=True)
    manifest = write_fixtures(args.dir)

    Handler.directory = args.dir
    Handler.manifest = manifest

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    if args.port_file:
        with open(args.port_file, "w") as handle:
            handle.write(str(server.server_address[1]))
    print(json.dumps(manifest), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
