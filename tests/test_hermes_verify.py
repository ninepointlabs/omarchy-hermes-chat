"""Tests for bin/hermes-verify against a fake pacman-installed tree.

python3 -I -B -m unittest discover -s tests
"""

import gzip
import hashlib
import importlib.machinery
import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "bin", "hermes-verify")


def load_helper():
    loader = importlib.machinery.SourceFileLoader("hermes_verify", HELPER)
    spec = importlib.util.spec_from_loader("hermes_verify", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


hv = load_helper()


def escape(path):
    return "".join(ch if ch.isalnum() or ch in "/._-+@" else "\\%03o" % ord(ch) for ch in path)


class FakeInstall:
    """A miniature / with hermes-agent and python311 installed by 'pacman'."""

    HERMES_FILES = {
        "/opt/hermes-agent/hermes_cli/main.py": b"print('hermes')\n",
        "/opt/hermes-agent/hermes_bootstrap.py": b"# bootstrap\n",
        "/opt/hermes-agent/contributors/email = x": b"odd name\n",
        "/opt/hermes-agent/venv/pyvenv.cfg": b"home = /usr/bin\ninclude-system-site-packages = false\n",
        "/opt/hermes-agent/venv/lib/python3.11/site-packages/hermes.pth": b"import sys\n",
    }
    HERMES_LINKS = {"/opt/hermes-agent/venv/bin/python": "/usr/bin/python3.11"}
    PYTHON_FILES = {
        "/usr/bin/python3.11": b"\x7fELF fake interpreter",
        "/usr/lib/python3.11/os.py": b"# os\n",
        "/usr/lib/python3.11/site-packages/README.txt": b"site\n",
    }

    def __init__(self, hermes_version="0.21.0-1"):
        self.root = tempfile.mkdtemp(prefix="hermes-verify-test-")
        os.chmod(self.root, 0o755)
        self.hermes_version = hermes_version
        self.build()

    def path(self, absolute):
        return self.root + absolute

    def layout(self, **overrides):
        options = dict(root=os.fsencode(self.root), trusted_uid=os.getuid(), trusted_gid=os.getgid())
        options.update(overrides)
        return hv.Layout(**options)

    def mkdirs(self, absolute):
        parts = [p for p in absolute.split("/") if p]
        current = ""
        for part in parts:
            current += "/" + part
            if not os.path.isdir(self.path(current)):
                os.mkdir(self.path(current))
            os.chmod(self.path(current), 0o755)

    def dirs_of(self, paths):
        result = set()
        for path in paths:
            parts = path.split("/")[1:-1]
            for i in range(1, len(parts) + 1):
                result.add("/" + "/".join(parts[:i]))
        return result

    def write_package(self, name, version, files, links, owned_top, depends=()):
        for path, data in files.items():
            self.mkdirs(os.path.dirname(path))
            with open(self.path(path), "wb") as handle:
                handle.write(data)
            os.chmod(self.path(path), 0o644)
        for path, target in links.items():
            self.mkdirs(os.path.dirname(path))
            os.symlink(target, self.path(path))
        self.write_record(name, version, files, links, owned_top, depends)

    def write_record(self, name, version, files, links, owned_top, depends=()):
        uid, gid = os.getuid(), os.getgid()
        all_paths = list(files) + list(links)
        dirs = sorted(d for d in self.dirs_of(all_paths) if d.startswith(owned_top))
        lines = ["#mtree", "/set type=file uid=%d gid=%d mode=644" % (uid, gid),
                 "./.PKGINFO time=1.0 size=1 sha256digest=" + "0" * 64]
        for d in dirs:
            lines.append(".%s time=1.0 mode=755 type=dir" % escape(d))
        for path, data in sorted(files.items()):
            lines.append(".%s time=1.0 size=%d sha256digest=%s"
                         % (escape(path), len(data), hashlib.sha256(data).hexdigest()))
        for path, target in sorted(links.items()):
            lines.append(".%s time=1.0 mode=777 type=link link=%s" % (escape(path), escape(target)))
        record = "/var/lib/pacman/local/%s-%s" % (name, version)
        self.mkdirs(record)
        with open(self.path(record + "/mtree"), "wb") as handle:
            handle.write(gzip.compress(("\n".join(lines) + "\n").encode()))
        desc = "%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n" % (name, version)
        if depends:
            desc += "%DEPENDS%\n" + "\n".join(depends) + "\n\n"
        with open(self.path(record + "/desc"), "w") as handle:
            handle.write(desc)
        with open(self.path(record + "/files"), "w") as handle:
            handle.write("%FILES%\n" + "\n".join(p[1:] for p in dirs + sorted(all_paths)) + "\n")
        for leaf in ("mtree", "desc", "files"):
            os.chmod(self.path(record + "/" + leaf), 0o644)

    def build(self):
        self.write_package("python311", "3.11.16-1", self.PYTHON_FILES, {}, "/usr/lib/python3.11")
        # python3.11 lives directly in /usr/bin, which the package lists as a file only.
        self.write_package("hermes-agent", self.hermes_version, self.HERMES_FILES, self.HERMES_LINKS,
                           "/opt/hermes-agent", depends=("python311", "nodejs>=20"))
        # The interpreter's own mtree must include /usr/bin/python3.11 and the stdlib dir.
        self.rewrite_python_record()

    def rewrite_python_record(self, files=None):
        files = dict(self.PYTHON_FILES if files is None else files)
        shutil.rmtree(self.path("/var/lib/pacman/local/python311-3.11.16-1"))
        self.write_record("python311", "3.11.16-1", files, {}, "/usr/lib/python3.11")

    def rewrite_hermes_record(self, version=None, files=None):
        version = version or self.hermes_version
        for entry in os.listdir(self.path("/var/lib/pacman/local")):
            if entry.startswith("hermes-agent-"):
                shutil.rmtree(self.path("/var/lib/pacman/local/" + entry))
        self.write_record("hermes-agent", version, files or self.HERMES_FILES, self.HERMES_LINKS,
                          "/opt/hermes-agent", depends=("python311", "nodejs>=20"))

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.fake = FakeInstall()

    def tearDown(self):
        self.fake.cleanup()

    def refusal(self, layout=None, approvals=()):
        with self.assertRaises(hv.Refusal) as caught:
            hv.verify(layout or self.fake.layout(), set(approvals))
        return caught.exception

    def test_clean_install_verifies(self):
        info = hv.verify(self.fake.layout(), set())
        self.assertEqual(info["status"], "ok")
        self.assertEqual(info["version"], "0.21.0-1")
        self.assertTrue(info["tested"])
        self.assertEqual(info["runtime"], "python311 3.11.16-1")

    def test_tampered_contents_same_size(self):
        with open(self.fake.path("/opt/hermes-agent/hermes_cli/main.py"), "r+b") as handle:
            handle.write(b"PRINT")
        refusal = self.refusal()
        self.assertEqual(refusal.code, hv.EXIT_MISMATCH)
        self.assertIn("contents differ", refusal.reason)

    def test_tampered_interpreter_stdlib(self):
        with open(self.fake.path("/usr/lib/python3.11/os.py"), "wb") as handle:
            handle.write(b"# evil\n")
        self.assertEqual(self.refusal().code, hv.EXIT_MISMATCH)

    def test_tampered_size(self):
        with open(self.fake.path("/opt/hermes-agent/hermes_bootstrap.py"), "ab") as handle:
            handle.write(b"import evil\n")
        self.assertIn("size differs", self.refusal().reason)

    def test_extra_module_is_refused(self):
        with open(self.fake.path("/opt/hermes-agent/sitecustomize.py"), "w") as handle:
            handle.write("evil")
        os.chmod(self.fake.path("/opt/hermes-agent/sitecustomize.py"), 0o644)
        refusal = self.refusal()
        self.assertIn("not part of the package", refusal.reason)
        self.assertTrue(refusal.path.endswith(b"/sitecustomize.py"))

    def test_extra_pth_in_site_packages_is_refused(self):
        with open(self.fake.path("/opt/hermes-agent/venv/lib/python3.11/site-packages/evil.pth"), "w") as handle:
            handle.write("import evil")
        os.chmod(self.fake.path("/opt/hermes-agent/venv/lib/python3.11/site-packages/evil.pth"), 0o644)
        self.assertIn("not part of the package", self.refusal().reason)

    def test_extra_module_in_stdlib_is_refused_but_system_site_packages_is_ignored(self):
        with open(self.fake.path("/usr/lib/python3.11/site-packages/other_pkg.py"), "w") as handle:
            handle.write("# another package's file")
        hv.verify(self.fake.layout(), set())
        with open(self.fake.path("/usr/lib/python3.11/evil.py"), "w") as handle:
            handle.write("# evil")
        self.assertIn("not part of the package", self.refusal().reason)

    def test_pycache_policy(self):
        cache = self.fake.path("/opt/hermes-agent/hermes_cli/__pycache__")
        os.mkdir(cache, 0o755)
        with open(cache + "/main.cpython-311.pyc", "wb") as handle:
            handle.write(b"pyc")
        os.chmod(cache + "/main.cpython-311.pyc", 0o644)
        hv.verify(self.fake.layout(), set())
        with open(cache + "/evil.py", "w") as handle:
            handle.write("evil")
        os.chmod(cache + "/evil.py", 0o644)
        self.assertIn("not part of the package", self.refusal().reason)

    def test_writable_pycache_is_refused(self):
        cache = self.fake.path("/opt/hermes-agent/hermes_cli/__pycache__")
        os.mkdir(cache)
        os.chmod(cache, 0o777)
        self.assertIn("not part of the package", self.refusal().reason)

    def test_group_writable_directory_is_refused(self):
        os.chmod(self.fake.path("/opt/hermes-agent/hermes_cli"), 0o775)
        self.assertEqual(self.refusal().code, hv.EXIT_MISMATCH)

    def test_writable_ancestor_is_refused(self):
        os.chmod(self.fake.path("/opt"), 0o777)
        self.assertIn("writable", self.refusal().reason)

    def test_file_mode_change_is_refused(self):
        os.chmod(self.fake.path("/opt/hermes-agent/hermes_cli/main.py"), 0o664)
        self.assertIn("permissions differ", self.refusal().reason)

    def test_retargeted_interpreter_link_is_refused(self):
        link = self.fake.path("/opt/hermes-agent/venv/bin/python")
        os.unlink(link)
        os.symlink("/home/user/evil-python", link)
        self.assertIn("symlink target differs", self.refusal().reason)

    def test_file_replaced_by_symlink_is_refused(self):
        target = self.fake.path("/opt/hermes-agent/hermes_cli/main.py")
        os.unlink(target)
        os.symlink("/tmp/evil.py", target)
        self.assertIn("expected a regular file", self.refusal().reason)

    def test_missing_file_is_refused(self):
        os.unlink(self.fake.path("/opt/hermes-agent/hermes_bootstrap.py"))
        self.assertIn("missing", self.refusal().reason)

    def test_foreign_owner_is_refused(self):
        refusal = self.refusal(self.fake.layout(trusted_uid=os.getuid() + 4242))
        self.assertIn("not owned by root", refusal.reason)

    def test_escaped_mtree_names(self):
        with open(self.fake.path("/opt/hermes-agent/contributors/email = x"), "r+b") as handle:
            handle.write(b"ODD")
        self.assertIn("contents differ", self.refusal().reason)

    def test_unapproved_version_and_explicit_approval(self):
        self.fake.rewrite_hermes_record(version="0.22.0-1")
        refusal = self.refusal()
        self.assertEqual(refusal.code, hv.EXIT_UNAPPROVED)
        approval = refusal.extra["approval"]
        self.assertTrue(approval.startswith("0.22.0-1@"))
        info = hv.verify(self.fake.layout(), {approval})
        self.assertFalse(info["tested"])
        wrong = "0.22.0-1@" + "0" * 64
        self.assertEqual(self.refusal(approvals=[wrong]).code, hv.EXIT_UNAPPROVED)

    def test_approval_is_bound_to_the_build(self):
        self.fake.rewrite_hermes_record(version="0.22.0-1")
        approval = self.refusal().extra["approval"]
        files = dict(FakeInstall.HERMES_FILES)
        files["/opt/hermes-agent/hermes_cli/main.py"] = b"print('other build')\n"
        with open(self.fake.path("/opt/hermes-agent/hermes_cli/main.py"), "wb") as handle:
            handle.write(files["/opt/hermes-agent/hermes_cli/main.py"])
        self.fake.rewrite_hermes_record(version="0.22.0-1", files=files)
        self.assertEqual(self.refusal(approvals=[approval]).code, hv.EXIT_UNAPPROVED)

    def test_unapproved_is_reported_only_for_an_intact_install(self):
        self.fake.rewrite_hermes_record(version="0.22.0-1")
        with open(self.fake.path("/opt/hermes-agent/hermes_cli/main.py"), "r+b") as handle:
            handle.write(b"PRINT")
        self.assertEqual(self.refusal().code, hv.EXIT_MISMATCH)

    def test_missing_package(self):
        shutil.rmtree(self.fake.path("/var/lib/pacman/local/hermes-agent-0.21.0-1"))
        self.assertEqual(self.refusal().code, hv.EXIT_MISSING)

    def test_duplicate_database_entries(self):
        shutil.copytree(self.fake.path("/var/lib/pacman/local/hermes-agent-0.21.0-1"),
                        self.fake.path("/var/lib/pacman/local/hermes-agent-0.20.0-1"))
        self.assertIn("more than one", self.refusal().reason)

    def test_system_site_packages_enabled_is_refused(self):
        files = dict(FakeInstall.HERMES_FILES)
        files["/opt/hermes-agent/venv/pyvenv.cfg"] = b"home = /usr/bin\ninclude-system-site-packages = true\n"
        with open(self.fake.path("/opt/hermes-agent/venv/pyvenv.cfg"), "wb") as handle:
            handle.write(files["/opt/hermes-agent/venv/pyvenv.cfg"])
        self.fake.rewrite_hermes_record(files=files)
        self.assertIn("system site-packages", self.refusal().reason)

    def test_interpreter_must_belong_to_a_dependency(self):
        record = self.fake.path("/var/lib/pacman/local/python311-3.11.16-1/files")
        with open(record) as handle:
            lines = [line for line in handle.read().split("\n") if line != "usr/bin/python3.11"]
        with open(record, "w") as handle:
            handle.write("\n".join(lines))
        self.assertIn("not owned by a dependency", self.refusal().reason)

    def test_environment_is_minimal(self):
        raw = {
            b"BASH_ENV": b"/tmp/evil", b"LD_PRELOAD": b"/tmp/evil.so", b"PYTHONPATH": b"/tmp",
            b"HERMES_LAZY_INSTALL_TARGET": b"/tmp/lazy", b"HOME": b"/tmp/fake-home",
            b"XDG_DATA_HOME": b"relative/path", b"XDG_CONFIG_HOME": b"/home/u/.config",
            b"LANG": b"en_US.UTF-8", b"WAYLAND_DISPLAY": b"wayland-1", b"DISPLAY": b":0\nX=1",
        }
        env = hv.hermes_environment(False, raw)
        for name in (b"BASH_ENV", b"LD_PRELOAD", b"PYTHONPATH", b"HERMES_LAZY_INSTALL_TARGET",
                     b"XDG_DATA_HOME", b"WAYLAND_DISPLAY", b"DISPLAY"):
            self.assertNotIn(name, env)
        self.assertEqual(env[b"PATH"], b"/usr/bin:/bin")
        self.assertEqual(env[b"HERMES_DISABLE_LAZY_INSTALLS"], b"1")
        self.assertEqual(env[b"XDG_CONFIG_HOME"], b"/home/u/.config")
        self.assertEqual(env[b"LANG"], b"en_US.UTF-8")
        self.assertNotEqual(env[b"HOME"], b"/tmp/fake-home")
        gui = hv.hermes_environment(True, raw)
        self.assertEqual(gui[b"WAYLAND_DISPLAY"], b"wayland-1")
        self.assertNotIn(b"DISPLAY", gui)


class CommandLineTests(unittest.TestCase):
    def run_helper(self, *args):
        return subprocess.run(["/usr/bin/python3", "-I", "-S", "-B", HELPER] + list(args),
                              env={"PATH": "/usr/bin"}, capture_output=True, timeout=60)

    def test_usage_errors(self):
        for args in ([], ["check", "extra"], ["exec"], ["exec", "--", "rm", "-rf"],
                     ["check", "--approve", "bad"], ["exec", "--approve", "1.0@" + "g" * 64, "--", "chat"]):
            with self.subTest(args=args):
                self.assertEqual(self.run_helper(*args).returncode, hv.EXIT_USAGE)


if __name__ == "__main__":
    unittest.main()
