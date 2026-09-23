"""Shared stub Unix socket server for the Herdr Python client unit tests.

It binds relative to the socket's own directory, so a test can place the socket
at an absolute path longer than the platform sun_path limit, exactly as a Herdr
session socket under a long resolved config root ends up.
"""
import os
import shutil
import socket
import tempfile
import threading

SUN_PATH_MAX_BYTES = 103


def make_socket_path(long_path):
    """Return (root, socket_path): a fresh temp root and a socket path inside it
    whose absolute UTF-8 length is at least 110 bytes when long_path is true,
    and at most SUN_PATH_MAX_BYTES otherwise."""
    root = os.path.realpath(tempfile.mkdtemp(prefix="fm-hs-", dir="/tmp"))
    directory = root
    if long_path:
        while len(os.fsencode(os.path.join(directory, "herdr.sock"))) < 110:
            directory = os.path.join(directory, "d" * 24)
        os.makedirs(directory)
    path = os.path.join(directory, "herdr.sock")
    length = len(os.fsencode(path))
    if long_path:
        assert length >= 110, length
    else:
        assert length <= SUN_PATH_MAX_BYTES, length
    return root, path


class StubServer:
    """Accept one connection, record every request line, and answer the first
    one with a caller-supplied response line; then hold the connection open
    until the client closes it or the server is stopped."""

    def __init__(self, path, response):
        self.path = path
        self.response = response
        self.requests = []
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        saved = os.open(".", os.O_RDONLY)
        try:
            os.chdir(os.path.dirname(path))
            self.listener.bind(os.path.basename(path))
        finally:
            os.fchdir(saved)
            os.close(saved)
        self.listener.listen(1)
        self.listener.settimeout(10)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        try:
            conn, _ = self.listener.accept()
        except OSError:
            return
        with conn:
            conn.settimeout(10)
            buffer = b""
            answered = False
            while True:
                try:
                    chunk = conn.recv(65536)
                except OSError:
                    return
                if not chunk:
                    return
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    self.requests.append(line.decode("utf-8"))
                    if not answered:
                        conn.sendall(self.response.encode("utf-8") + b"\n")
                        answered = True

    def stop(self):
        self.listener.close()
        self.thread.join(10)


def cleanup(root):
    shutil.rmtree(root, ignore_errors=True)
