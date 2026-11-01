import argparse
import io
import json
import struct
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

parser = argparse.ArgumentParser()
parser.add_argument('port_file')
args = parser.parse_args()
buffer = io.BytesIO()
with wave.open(buffer, 'wb') as audio:
    audio.setnchannels(2)
    audio.setsampwidth(2)
    audio.setframerate(44100)
    audio.writeframes(struct.pack('<hh', 100, -100) * 180000)
payload = buffer.getvalue()
counts = {}
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_):
        pass
    def do_GET(self):
        path = urlparse(self.path).path
        with lock:
            counts[path] = counts.get(path, 0) + 1
            count = counts[path]
        if path == '/stats':
            data = json.dumps(counts).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/audio')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if path == '/redirect-cross-origin':
            self.send_response(302)
            self.send_header('Location', f'http://localhost:{self.server.server_port}/audio')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        data = b'#EXTM3U\n#EXT-X-TARGETDURATION:4\nsegment.aac\n' if path == '/playlist' else payload
        start, end = 0, len(data) - 1
        byte_range = self.headers.get('Range')
        if byte_range:
            start_text, end_text = byte_range.removeprefix('bytes=').split('-')
            start, end = int(start_text), min(int(end_text) if end_text else end, end)
        if path == '/ranges' and count == 2:
            self.send_response(503)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        self.send_response(206 if byte_range else 200)
        self.send_header('Content-Type', 'application/vnd.apple.mpegurl' if path == '/playlist' else 'audio/wav')
        self.send_header('ETag', '"fixture-v1"')
        self.send_header('Accept-Ranges', 'bytes')
        if byte_range:
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
        if path != '/unknown-length':
            self.send_header('Content-Length', str(end - start + 1))
        else:
            self.send_header('Connection', 'close')
            self.close_connection = True
        self.end_headers()
        if path in ['/drop', '/direct-drop'] and count == 1:
            self.wfile.write(data[:65536])
            self.wfile.flush()
            self.close_connection = True
            return
        try:
            for offset in range(start, end + 1, 16384):
                self.wfile.write(data[offset:min(offset + 16384, end + 1)])
                self.wfile.flush()
                if path in ['/slow', '/ranges']:
                    time.sleep(0.025)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
Path(args.port_file).write_text(str(server.server_port))
server.serve_forever()
