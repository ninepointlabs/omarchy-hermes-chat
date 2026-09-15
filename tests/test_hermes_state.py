"""Tests for bin/hermes-state: python3 -I -B -m unittest discover -s tests"""

import importlib.machinery
import importlib.util
import json
import multiprocessing
import os
import shutil
import stat
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "bin", "hermes-state")


def load_helper():
    loader = importlib.machinery.SourceFileLoader("hermes_state", HELPER)
    spec = importlib.util.spec_from_loader("hermes_state", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


hs = load_helper()


def concurrent_writer(home, index, rounds):
    for n in range(rounds):
        payload = json.dumps({"writer": index, "n": n, "pad": "x" * 2000}).encode()
        hs.write_state(home, payload)


class StateTests(unittest.TestCase):
    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="hermes-state-test-")
        os.chmod(self.base, 0o700)
        self.home = os.path.join(self.base, "home")
        os.mkdir(self.home, 0o700)
        self.home_b = os.fsencode(self.home)
        self.state_dir = os.path.join(self.home, ".local", "state", "omarchy", "hermes-chat")
        self.state_file = os.path.join(self.state_dir, "state.json")
        self.outside = os.path.join(self.base, "outside")
        os.mkdir(self.outside, 0o700)
        self.victim = os.path.join(self.outside, "victim")
        with open(self.victim, "w") as handle:
            handle.write("untouched")

    def tearDown(self):
        shutil.rmtree(self.base, ignore_errors=True)

    def make_state_dir(self):
        os.makedirs(self.state_dir, mode=0o700)

    def assert_victim_untouched(self):
        with open(self.victim) as handle:
            self.assertEqual(handle.read(), "untouched")
        self.assertEqual(sorted(os.listdir(self.outside)), ["victim"])

    def test_round_trip_modes_and_no_leftovers(self):
        hs.write_state(self.home_b, b'{"transcript":[{"role":"user","text":"hi"}]}')
        self.assertEqual(hs.read_state(self.home_b), b'{"transcript":[{"role":"user","text":"hi"}]}')
        self.assertEqual(stat.S_IMODE(os.stat(self.state_file).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.state_dir).st_mode), 0o700)
        self.assertEqual(os.listdir(self.state_dir), ["state.json"])

    def test_read_without_state_creates_nothing(self):
        self.assertEqual(hs.read_state(self.home_b), b"{}")
        self.assertFalse(os.path.exists(os.path.join(self.home, ".local")))

    def test_existing_loose_directory_is_tightened(self):
        os.makedirs(self.state_dir, mode=0o700)
        os.chmod(self.state_dir, 0o750)
        hs.write_state(self.home_b, b"{}")
        self.assertEqual(stat.S_IMODE(os.stat(self.state_dir).st_mode), 0o700)

    def test_legacy_notify_preference(self):
        self.make_state_dir()
        with open(os.path.join(self.state_dir, "notify"), "w") as handle:
            handle.write("1\n")
        os.chmod(os.path.join(self.state_dir, "notify"), 0o644)
        self.assertEqual(json.loads(hs.read_state(self.home_b)), {"notifyOnAnswers": True})

    def test_symlink_at_state_file_is_refused_not_followed(self):
        self.make_state_dir()
        os.symlink(self.victim, self.state_file)
        with self.assertRaises(hs.Refused):
            hs.read_state(self.home_b)
        with self.assertRaises(hs.Refused):
            hs.write_state(self.home_b, b'{"a":1}')
        self.assertTrue(os.path.islink(self.state_file))
        self.assert_victim_untouched()

    def test_symlink_at_each_component_is_refused(self):
        components = [".local", "state", "omarchy", "hermes-chat"]
        for depth in range(len(components)):
            with self.subTest(component=components[depth]):
                shutil.rmtree(os.path.join(self.home, ".local"), ignore_errors=True)
                if os.path.lexists(os.path.join(self.home, ".local")):
                    os.unlink(os.path.join(self.home, ".local"))
                parent = os.path.join(self.home, *components[:depth])
                os.makedirs(parent, mode=0o700, exist_ok=True)
                os.symlink(self.outside, os.path.join(parent, components[depth]))
                with self.assertRaises(hs.Refused):
                    hs.write_state(self.home_b, b'{"a":1}')
                with self.assertRaises(hs.Refused):
                    hs.read_state(self.home_b)
                self.assert_victim_untouched()

    def test_symlinked_home_component_is_refused(self):
        link = os.path.join(self.base, "homelink")
        os.symlink(self.home, link)
        with self.assertRaises(hs.Refused):
            hs.write_state(os.fsencode(link), b"{}")

    def test_fifo_is_refused_without_blocking(self):
        self.make_state_dir()
        os.mkfifo(self.state_file, 0o600)
        started = time.monotonic()
        with self.assertRaises(hs.Refused):
            hs.read_state(self.home_b)
        with self.assertRaises(hs.Refused):
            hs.write_state(self.home_b, b"{}")
        self.assertLess(time.monotonic() - started, 2)

    def test_directory_at_state_file_is_refused(self):
        self.make_state_dir()
        os.mkdir(self.state_file, 0o700)
        with self.assertRaises(hs.Refused):
            hs.read_state(self.home_b)
        with self.assertRaises(hs.Refused):
            hs.write_state(self.home_b, b"{}")

    def test_oversized_file_and_payload(self):
        self.make_state_dir()
        with open(self.state_file, "wb") as handle:
            handle.write(b" " * (hs.STATE_LIMIT + 1))
        os.chmod(self.state_file, 0o600)
        with self.assertRaises(hs.Refused):
            hs.read_state(self.home_b)
        read_fd, write_fd = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(read_fd)
            try:
                os.write(write_fd, b" " * (hs.STATE_LIMIT + 10))
            finally:
                os._exit(0)
        os.close(write_fd)
        saved = os.dup(0)
        os.dup2(read_fd, 0)
        try:
            with self.assertRaises(hs.Invalid):
                hs.read_stdin(hs.STATE_LIMIT)
        finally:
            os.dup2(saved, 0)
            os.close(saved)
            os.close(read_fd)
            os.waitpid(pid, 0)

    def test_readable_by_others_is_refused(self):
        hs.write_state(self.home_b, b"{}")
        os.chmod(self.state_file, 0o644)
        with self.assertRaises(hs.Refused):
            hs.read_state(self.home_b)

    def test_group_writable_directory_is_refused(self):
        hs.write_state(self.home_b, b"{}")
        os.chmod(os.path.join(self.home, ".local", "state"), 0o770)
        with self.assertRaises(hs.Refused):
            hs.read_state(self.home_b)
        with self.assertRaises(hs.Refused):
            hs.write_state(self.home_b, b"{}")

    def test_wrong_owner_is_refused(self):
        hs.write_state(self.home_b, b"{}")
        with self.assertRaises(hs.Refused):
            hs.read_state(self.home_b, euid=os.geteuid() + 4242)
        with self.assertRaises(hs.Refused):
            hs.write_state(self.home_b, b"{}", euid=os.geteuid() + 4242)

    def test_hard_link_is_refused(self):
        self.make_state_dir()
        os.chmod(self.victim, 0o600)
        os.link(self.victim, self.state_file)
        with self.assertRaises(hs.Refused):
            hs.read_state(self.home_b)

    def test_invalid_payloads(self):
        for payload in (b"not json", b"[1,2]", b"\xff\xfe"):
            with self.subTest(payload=payload):
                with self.assertRaises(hs.Invalid):
                    hs.write_state(self.home_b, payload)
        self.assertFalse(os.path.exists(self.state_file))

    def test_held_descriptor_survives_path_swap(self):
        dir_fd = hs.open_state_directory(self.home_b, create=True)
        try:
            moved = os.path.join(self.base, "moved-state-dir")
            os.rename(self.state_dir, moved)
            os.symlink(self.outside, self.state_dir)
            hs.write_file(dir_fd, b"state.json", b'{"ok":true}')
        finally:
            os.close(dir_fd)
        with open(os.path.join(moved, "state.json"), "rb") as handle:
            self.assertEqual(handle.read(), b'{"ok":true}')
        self.assert_victim_untouched()

    def test_concurrent_writers_never_expose_partial_state(self):
        hs.write_state(self.home_b, b'{"writer":-1}')
        context = multiprocessing.get_context("fork")
        workers = [context.Process(target=concurrent_writer, args=(self.home_b, i, 40)) for i in range(6)]
        for worker in workers:
            worker.start()
        reads = 0
        while any(worker.is_alive() for worker in workers):
            value = json.loads(hs.read_state(self.home_b))
            self.assertIn("writer", value)
            reads += 1
        for worker in workers:
            worker.join()
            self.assertEqual(worker.exitcode, 0)
        self.assertGreater(reads, 0)
        self.assertEqual(os.listdir(self.state_dir), ["state.json"])
        self.assertEqual(json.loads(hs.read_state(self.home_b))["n"], 39)


if __name__ == "__main__":
    unittest.main()
