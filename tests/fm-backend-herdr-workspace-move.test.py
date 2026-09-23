#!/usr/bin/env python3
"""Unit tests for bin/backends/herdr-workspace-move.py with no Herdr involved."""
import importlib.util
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import herdr_socket_stub as stub  # noqa: E402

MOVER_PATH = Path(__file__).parents[1] / "bin" / "backends" / "herdr-workspace-move.py"
SPEC = importlib.util.spec_from_file_location("herdr_workspace_move", MOVER_PATH)
MOVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOVER)

RESPONSE = json.dumps(
    {
        "id": "fm-workspace-move",
        "result": {
            "type": "workspace_list",
            "workspaces": [{"workspace_id": "w1"}, {"workspace_id": "w4"}],
        },
    },
    separators=(",", ":"),
)


class WorkspaceMoveConnectTest(unittest.TestCase):
    def run_mover(self, long_path):
        root, path = stub.make_socket_path(long_path)
        self.addCleanup(stub.cleanup, root)
        server = stub.StubServer(path, RESPONSE)
        self.addCleanup(server.stop)
        proc = subprocess.run(
            [sys.executable, str(MOVER_PATH), path, "w4", "1"],
            capture_output=True,
            text=True,
            timeout=20,
        )
        server.thread.join(10)
        return proc, server

    def assert_moved(self, proc, server):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout), json.loads(RESPONSE))
        self.assertEqual(len(server.requests), 1, server.requests)
        request = json.loads(server.requests[0])
        self.assertEqual(request["method"], "workspace.move")
        self.assertEqual(request["params"], {"workspace_id": "w4", "insert_index": 1})

    def test_long_socket_path_connects(self):
        proc, server = self.run_mover(long_path=True)
        self.assert_moved(proc, server)

    def test_short_socket_path_connects(self):
        proc, server = self.run_mover(long_path=False)
        self.assert_moved(proc, server)

    def test_long_path_connect_restores_cwd(self):
        root, path = stub.make_socket_path(long_path=True)
        self.addCleanup(stub.cleanup, root)
        server = stub.StubServer(path, RESPONSE)
        self.addCleanup(server.stop)
        before = os.getcwd()
        sock = MOVER.socket.socket(MOVER.socket.AF_UNIX, MOVER.socket.SOCK_STREAM)
        self.addCleanup(sock.close)
        MOVER._connect_unix(sock, path)
        self.assertEqual(os.getcwd(), before)

    def test_long_path_missing_directory_fails_with_cwd_restored(self):
        root, path = stub.make_socket_path(long_path=True)
        self.addCleanup(stub.cleanup, root)
        missing = os.path.join(os.path.dirname(path), "missing", "herdr.sock")
        before = os.getcwd()
        proc = subprocess.run(
            [sys.executable, str(MOVER_PATH), missing, "w4", "1"],
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(proc.returncode, 2)
        sock = MOVER.socket.socket(MOVER.socket.AF_UNIX, MOVER.socket.SOCK_STREAM)
        self.addCleanup(sock.close)
        with self.assertRaises(OSError):
            MOVER._connect_unix(sock, missing)
        self.assertEqual(os.getcwd(), before)


if __name__ == "__main__":
    unittest.main()
