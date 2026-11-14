"""Сборка приватного SDK из пересекающихся payload установщика."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


class PrepareRuntimeTests(unittest.TestCase):
    def test_duplicate_relative_symlinks_are_merged(self):
        spec = importlib.util.spec_from_file_location("prepare_runtime", Path(__file__).resolve().parents[1] / "prepare-runtime.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ["first", "second"]:
                source = root / name / "lib"
                source.mkdir(parents=True)
                (source / "libtest.1.dylib").write_bytes(b"test")
                (source / "libtest.dylib").symlink_to("libtest.1.dylib")
                module.merge_payload(root / name, root / "sdk")
            self.assertTrue((root / "sdk/lib/libtest.dylib").is_symlink())
            self.assertEqual((root / "sdk/lib/libtest.dylib").read_bytes(), b"test")
