"""Проверки переносимости реальных Mach-O без установленного runtime."""

import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "bundle-runtime.py"


@unittest.skipUnless(sys.platform == "darwin", "проверка Mach-O требует macOS")
class RelocatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ymd bundle test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "original libraries"
        self.source.mkdir()
        self.contents = self.root / "App.app" / "Contents"
        spec = importlib.util.spec_from_file_location("bundle_runtime", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def compile(self, name, code, *flags):
        source = self.source / (name + ".c")
        source.write_text(code)
        target = self.source / name
        subprocess.run(["cc", str(source), "-o", str(target), *map(str, flags)], check=True)
        return target

    def test_transitive_libraries_work_after_move_and_source_removal(self):
        leaf = self.compile("libleaf.dylib", "int leaf(void) { return 42; }", "-dynamiclib")
        subprocess.run(["install_name_tool", "-id", str(leaf), str(leaf)], check=True)
        middle = self.compile(
            "libmiddle.dylib", "extern int leaf(void); int middle(void) { return leaf(); }",
            "-dynamiclib", leaf,
        )
        subprocess.run(["install_name_tool", "-id", str(middle), str(middle)], check=True)
        executable = self.compile(
            "test-app", "extern int middle(void); int main(void) { return middle() == 42 ? 0 : 1; }",
            middle,
        )
        graph = self.module.Relocator(self.contents)
        graph.add(executable, self.contents / "Helpers" / "test-app")
        graph.relocate()
        graph.verify()
        self.assertTrue((self.contents / "Frameworks" / "libleaf.dylib").is_file())
        self.assertTrue((self.contents / "Frameworks" / "libmiddle.dylib").is_file())
        shutil.rmtree(self.source)
        moved = self.root / "Moved App.app"
        shutil.move(str(self.contents.parent), moved)
        binary = moved / "Contents" / "Helpers" / "test-app"
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
        result = subprocess.run([str(binary)], env=environment, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_library_name_collision_is_an_error(self):
        first = self.compile("libduplicate.dylib", "int first(void) { return 1; }", "-dynamiclib")
        second = self.root / "different" / first.name
        second.parent.mkdir()
        shutil.copy2(first, second)
        graph = self.module.Relocator(self.contents)
        graph.add(first, self.contents / "Frameworks" / first.name)
        with self.assertRaisesRegex(RuntimeError, "[Кк]онфликт"):
            graph.add(second, self.contents / "Frameworks" / first.name)

    def test_minimum_macos_reflects_bundled_libraries(self):
        binary = self.compile("minimum", "int main(void) { return 0; }", "-mmacosx-version-min=14.0")
        graph = self.module.Relocator(self.contents)
        graph.add(binary, self.contents / "Helpers/minimum")
        self.assertEqual(graph.minimum_macos(), "14.0")
        with self.assertRaisesRegex(RuntimeError, "macOS 14.0"):
            graph.require_macos("13.0")

    def test_rpath_runtime_is_resolved_from_private_sdk(self):
        leaf = self.compile("libprivate.dylib", "int leaf(void) { return 42; }", "-dynamiclib", "-Wl,-install_name,@rpath/libprivate.dylib")
        binary = self.compile("consumer-rpath", "extern int leaf(void); int main(void) { return leaf() == 42 ? 0 : 1; }", leaf)
        graph = self.module.Relocator(self.contents, search_roots=[self.source])
        graph.add(binary, self.contents / "Helpers/consumer-rpath")
        graph.relocate()
        graph.verify()
        shutil.rmtree(self.source)
        subprocess.run([str(self.contents / "Helpers/consumer-rpath")], check=True)

    def test_adhoc_signing_works_with_system_bash(self):
        binary = self.compile("ymd-menubar", "int main(void) { return 0; }")
        for directory in ["MacOS", "Helpers", "Frameworks", "Resources/gstreamer-1.0", "Resources/gio/modules"]:
            (self.contents / directory).mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary, self.contents / "MacOS/ymd-menubar")
        shutil.copy2(binary, self.contents / "Helpers/ymd")
        with (self.contents / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "ymd-menubar", "CFBundleIdentifier": "test.ymd.signing", "CFBundlePackageType": "APPL"}, stream)
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT.parent / "sign-app.sh"), str(self.contents.parent)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_runtime_probe_does_not_restore_missing_library(self):
        leaf = self.compile("libnotbundled.dylib", "int leaf(void) { return 42; }", "-dynamiclib")
        subprocess.run(["install_name_tool", "-id", str(leaf), str(leaf)], check=True)
        probe = self.compile("probe", "extern int leaf(void); int main(void) { return leaf(); }", leaf)
        spec = importlib.util.spec_from_file_location("check_runtime", SCRIPT.parent / "Tests/check-runtime.py")
        checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checker)
        with self.assertRaisesRegex(RuntimeError, "Нет встроенной библиотеки"):
            checker.prepare_probe(self.contents, probe, self.module)
        self.assertFalse((self.contents / "Frameworks/libnotbundled.dylib").exists())

    def test_missing_dependency_fails_packaging(self):
        leaf = self.compile("libmissing.dylib", "int leaf(void) { return 42; }", "-dynamiclib")
        subprocess.run(["install_name_tool", "-id", str(leaf), str(leaf)], check=True)
        binary = self.compile("consumer", "extern int leaf(void); int main(void) { return leaf(); }", leaf)
        leaf.unlink()
        graph = self.module.Relocator(self.contents)
        graph.add(binary, self.contents / "Helpers" / "consumer")
        with self.assertRaisesRegex(RuntimeError, "[Нн]е найдена"):
            graph.relocate()


if __name__ == "__main__":
    unittest.main()
