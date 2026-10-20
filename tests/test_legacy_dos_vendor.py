"""Offline regression tests for vendor archive boundaries. No installed RE tools needed."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
import warnings
import gc
from unittest import mock
import zipfile
import sys

SOURCE = Path(__file__).resolve().parents[1] / "tools" / "legacy_dos_vendor.py"
sys.path.insert(0, str(SOURCE.parent))
SPEC = importlib.util.spec_from_file_location("legacy_dos_vendor", SOURCE)
vendor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(vendor)


class VendorTests(unittest.TestCase):
    def test_windows_paths_cannot_escape_or_alias_destinations(self):
        for name in ("../escape", "/absolute", "C:/absolute", "bin\\escape", "bin/aux.txt", "bin/x.", "bin/x "):
            with self.subTest(name=name), self.assertRaises(ValueError):
                vendor.archive_path(name)

    def test_protected_path_strings_are_rejected_without_access(self):
        for name in ("x.env", ".env", ".env.test", ".npmrc", "public.pem", "synthetic.key", "privatekey-fixture"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                vendor.archive_path(name)

    def test_sibling_directory_does_not_match_root_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "root"
            with self.assertRaises(ValueError):
                vendor.inside(root, Path(directory) / "root-sibling" / "output")

    def test_valid_zip_extracts_one_tool_root(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            archive = base / "vendor.zip"
            with zipfile.ZipFile(archive, "w") as out:
                out.writestr("package/bin/tool.exe", b"fixture")
            spec = {"format": "zip", "marker": "bin/tool.exe", "required": ["bin/tool.exe"]}
            vendor.extract(archive, spec, base / "stage")
            self.assertEqual((base / "stage/bin/tool.exe").read_bytes(), b"fixture")

    def test_zip_traversal_rejects_before_any_files_are_written(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            archive = base / "vendor.zip"
            with zipfile.ZipFile(archive, "w") as out:
                out.writestr("bin/tool.exe", b"fixture")
                out.writestr("../escape", b"fixture")
            with self.assertRaises(ValueError):
                vendor.extract(archive, {"format": "zip", "marker": "bin/tool.exe", "required": ["bin/tool.exe"]}, base / "stage")
            self.assertFalse((base / "stage").exists())
            self.assertFalse((base / "escape").exists())

    def test_tar_links_reject_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            archive = base / "vendor.tar.xz"
            with tarfile.open(archive, "w:xz") as out:
                item = tarfile.TarInfo("bin/tool.exe")
                item.size = 7
                out.addfile(item, io.BytesIO(b"fixture"))
                link = tarfile.TarInfo("bin/link")
                link.type = tarfile.SYMTYPE
                link.linkname = "../../outside"
                out.addfile(link)
            with self.assertRaises(ValueError):
                vendor.extract(archive, {"format": "tar.xz", "marker": "bin/tool.exe", "required": ["bin/tool.exe"]}, base / "stage")
            self.assertFalse((base / "stage").exists())

    def test_case_collisions_reject(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            archive = base / "vendor.zip"
            with zipfile.ZipFile(archive, "w") as out:
                out.writestr("bin/tool.exe", b"a")
                out.writestr("BIN/TOOL.EXE", b"b")
            with self.assertRaises(ValueError):
                vendor.extract(archive, {"format": "zip", "marker": "bin/tool.exe", "required": ["bin/tool.exe"]}, base / "stage")

    def test_bad_hash_never_promotes_download(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "archive.zip"
            with mock.patch.object(vendor, "urlopen", return_value=io.BytesIO(b"fixture")):
                with self.assertRaises(ValueError):
                    vendor.download({"url": "https://example.invalid/archive.zip", "sha256": "0" * 64}, target)
            self.assertFalse(target.exists())

    def test_vendor_origin_is_pinned(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps({"schema_version": 1, "watcom": {"url": "https://example.invalid/archive"}}), encoding="utf-8")
            with self.assertRaises(ValueError):
                vendor.load_spec(path, "watcom")

    def test_cached_good_archive_does_not_use_network(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "archive.zip"
            target.write_bytes(b"fixture")
            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always", ResourceWarning)
                with mock.patch.object(vendor, "urlopen", side_effect=AssertionError("network used")):
                    vendor.download({"sha256": hashlib.sha256(b"fixture").hexdigest()}, target)
                gc.collect()
            self.assertFalse([w for w in caught if issubclass(w.category, ResourceWarning)])



class ManifestMergeTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.parent / "merge_tool_manifests.py"
        spec = importlib.util.spec_from_file_location("merge_tool_manifests", source)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_merge_preserves_inventory_and_sticky_ownership(self):
        baseline = [
            {"name": "existing", "installed_by_toolbox": True, "notes": "old"},
            {"name": "untouched", "binary": "original"},
        ]
        current = [
            {"name": "existing", "installed_by_toolbox": False, "notes": "updated"},
            {"name": "new-tool", "binary": "new"},
        ]
        result = self.module.merge_entries(baseline, current)
        self.assertEqual([row["name"] for row in result], ["existing", "untouched", "new-tool"])
        self.assertTrue(result[0]["installed_by_toolbox"])
        self.assertEqual(result[0]["notes"], "updated")
        self.assertEqual(result[1]["binary"], "original")

    def test_invalid_inventory_entry_fails(self):
        with self.assertRaises(ValueError):
            self.module.merge_entries([{"name": "valid"}], [{"name": 1}])

    def test_cli_refuses_to_overwrite_baseline(self):
        with tempfile.TemporaryDirectory() as directory:
            baseline = Path(directory) / "baseline.json"
            baseline.write_text('[{"name":"baseline"}]', encoding="utf-8")
            with mock.patch.object(sys, "argv", ["merge_tool_manifests.py", "--base", str(baseline), "--current", str(baseline), "--output", str(baseline)]):
                with self.assertRaises(ValueError):
                    self.module.main()
            self.assertEqual(baseline.read_text(encoding="utf-8"), '[{"name":"baseline"}]')

class DosboxProbeTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.parent / "probe_dosbox.py"
        spec = importlib.util.spec_from_file_location("probe_dosbox", source)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_zero_exit_without_guest_marker_fails(self):
        with self.assertRaises(RuntimeError):
            self.module.verify_marker(0, "fresh-nonce", None)

    def test_stale_guest_marker_fails(self):
        with self.assertRaises(RuntimeError):
            self.module.verify_marker(0, "fresh-nonce", "old-nonce")

    def test_nonce_requires_successful_guest_exit(self):
        with self.assertRaises(RuntimeError):
            self.module.verify_marker(7, "fresh-nonce", "fresh-nonce")
        self.module.verify_marker(0, "fresh-nonce", "fresh-nonce\r\n")


class LegacyPythonInstallTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.parent / "install_legacy_python.py"
        spec = importlib.util.spec_from_file_location("install_legacy_python", source)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_matching_version_does_not_run_pip(self):
        execute = mock.Mock(side_effect=AssertionError("pip must not run"))
        result = self.module.install_pinned("capstone", "capstone==5.0.6", "5.0.6",
            installed_version=lambda name: "5.0.6", execute=execute)
        self.assertFalse(result["changed"])
        execute.assert_not_called()

    def test_wrong_version_uses_existing_interpreter_and_isolated_pinned_pip(self):
        execute = mock.Mock()
        version = mock.Mock(side_effect=["old-version", "5.0.6"])
        self.module.install_pinned("capstone", "capstone==5.0.6", "5.0.6",
            installed_version=version, execute=execute)
        command = execute.call_args.args[0]
        self.assertEqual(command[0], sys.executable)
        self.assertEqual(command[1:7], ["-X", "utf8", "-m", "pip", "--isolated", "--disable-pip-version-check"])
        self.assertEqual(command[-1], "capstone==5.0.6")
        self.assertTrue(execute.call_args.kwargs["check"])

    def test_wrong_version_after_pip_is_a_failure(self):
        with self.assertRaises(RuntimeError):
            self.module.install_pinned("unicorn", "unicorn==2.1.4", "2.1.4",
                installed_version=lambda name: "wrong-version", execute=mock.Mock())

    def test_missing_distribution_requires_install_and_exact_post_version(self):
        version = mock.Mock(side_effect=[
            self.module.metadata.PackageNotFoundError("unicorn"), "2.1.4"])
        execute = mock.Mock()
        result = self.module.install_pinned("unicorn", "unicorn==2.1.4", "2.1.4",
            installed_version=version, execute=execute)
        self.assertTrue(result["changed"])
        execute.assert_called_once()

    def test_unpinned_or_url_catalog_requirement_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            catalog = Path(directory) / "catalog.json"
            for requirement in ("capstone", "https://example.invalid/package"):
                with self.subTest(requirement=requirement):
                    catalog.write_text(json.dumps({"tools": [{
                        "name": "capstone", "channel": "pip-toolbox",
                        "id": requirement, "binary": None, "register_manifest": False
                    }]}), encoding="utf-8")
                    with self.assertRaises(ValueError):
                        self.module.catalog_pin(catalog, "capstone")


class ChildWindowPlacementTests(unittest.TestCase):
    def setUp(self):
        source = SOURCE.parent / "child_window_placement.py"
        spec = importlib.util.spec_from_file_location("child_window_placement", source)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_an_arbitrary_pid_is_not_accepted_as_a_launched_child(self):
        with mock.patch.object(self.module, "_api", side_effect=AssertionError("desktop API accessed")):
            with self.assertRaises(ValueError):
                self.module.move_child_windows(mock.Mock(pid=123), (-1920, 0, 0, 1080))

    def test_exited_child_never_accesses_desktop_apis(self):
        process = mock.Mock(spec=self.module.subprocess.Popen)
        process.pid = 123
        process.poll.return_value = 0
        with mock.patch.object(self.module, "_api", side_effect=AssertionError("desktop API accessed")):
            self.assertEqual(self.module.move_child_windows(process, (-1920, 0, 0, 1080)), 0)

    def test_oversized_window_is_contained_on_a_negative_coordinate_monitor(self):
        work = (-3840, -1080, -1920, 0)
        x, y, width, height = self.module.fit_rectangle((100, 100, 5000, 4000), work)
        self.assertGreaterEqual(x, work[0])
        self.assertGreaterEqual(y, work[1])
        self.assertLessEqual(x + width, work[2])
        self.assertLessEqual(y + height, work[3])
        with self.assertRaises(ValueError):
            self.module.fit_rectangle((0, 0, 1, 1), (0, 0, 0, 0))


if __name__ == "__main__":
    unittest.main()
