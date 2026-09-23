#!/usr/bin/env python3
import importlib.util
import io
import json
import os
import socket
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import herdr_socket_stub as stub  # noqa: E402

READER_PATH = Path(__file__).parents[1] / "bin" / "backends" / "herdr-eventwait.py"
SPEC = importlib.util.spec_from_file_location("herdr_eventwait", READER_PATH)
READER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(READER)


class FailingSocket:
    def settimeout(self, _timeout):
        pass

    def recv(self, _size):
        raise OSError("receive failed")


class ClosingStreamSocket:
    def __init__(self):
        self.chunks = [
            b'{"result":{"type":"subscription_started"}}\n',
            b"",
        ]

    def settimeout(self, _timeout):
        pass

    def connect(self, _path):
        pass

    def sendall(self, _request):
        pass

    def recv(self, _size):
        return self.chunks.pop(0)


class RejectedSubscriptionSocket(ClosingStreamSocket):
    def __init__(self):
        self.chunks = [b'{"result":{"type":"not_started"}}\n']


class EventWaitReadLineTest(unittest.TestCase):
    def test_deadline_is_clean_timeout(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)

        line, buf, outcome = READER._read_line(left, b"", time.monotonic())

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "timeout")

    def test_peer_closure_is_runtime_failure(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        right.close()

        line, buf, outcome = READER._read_line(
            left, b"", time.monotonic() + 1
        )

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "closed")

    def test_receive_error_is_runtime_failure(self):
        line, buf, outcome = READER._read_line(
            FailingSocket(), b"", time.monotonic() + 1
        )

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "error")

    def test_main_reports_early_stream_closure(self):
        stdout = io.StringIO()
        with mock.patch.object(READER.socket, "socket", return_value=ClosingStreamSocket()):
            with mock.patch.object(READER.sys, "stdout", stdout):
                result = READER.main(["herdr-eventwait.py", "socket", "1", "pane"])

        self.assertEqual(result, 4)
        self.assertEqual(stdout.getvalue(), "@subscribed\n")

    def test_main_does_not_signal_readiness_before_valid_ack(self):
        stdout = io.StringIO()
        with mock.patch.object(
            READER.socket, "socket", return_value=RejectedSubscriptionSocket()
        ):
            with mock.patch.object(READER.sys, "stdout", stdout):
                result = READER.main(["herdr-eventwait.py", "socket", "1", "pane"])

        self.assertEqual(result, 3)
        self.assertEqual(stdout.getvalue(), "")


class EventWaitConnectTest(unittest.TestCase):
    ACK = json.dumps({"id": "fm-eventwait", "result": {"type": "subscription_started"}})

    def run_reader(self, long_path):
        root, path = stub.make_socket_path(long_path)
        self.addCleanup(stub.cleanup, root)
        server = stub.StubServer(path, self.ACK)
        self.addCleanup(server.stop)
        proc = subprocess.run(
            [sys.executable, str(READER_PATH), path, "0.5", "p1", "p2"],
            capture_output=True,
            text=True,
            timeout=20,
        )
        server.thread.join(10)
        return proc, server

    def assert_subscribed(self, proc, server):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "@subscribed\n")
        self.assertEqual(len(server.requests), 1, server.requests)
        request = json.loads(server.requests[0])
        self.assertEqual(request["method"], "events.subscribe")
        self.assertEqual(
            [entry["pane_id"] for entry in request["params"]["subscriptions"]],
            ["p1", "p2"],
        )

    def test_long_socket_path_connects_and_subscribes(self):
        proc, server = self.run_reader(long_path=True)
        self.assert_subscribed(proc, server)

    def test_short_socket_path_connects_and_subscribes(self):
        proc, server = self.run_reader(long_path=False)
        self.assert_subscribed(proc, server)

    def test_long_path_connect_restores_cwd(self):
        root, path = stub.make_socket_path(long_path=True)
        self.addCleanup(stub.cleanup, root)
        server = stub.StubServer(path, self.ACK)
        self.addCleanup(server.stop)
        before = os.getcwd()
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(sock.close)
        READER._connect_unix(sock, path)
        self.assertEqual(os.getcwd(), before)


if __name__ == "__main__":
    unittest.main()
