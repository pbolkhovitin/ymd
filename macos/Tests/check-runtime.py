#!/usr/bin/env python3
"""Звук и HTTPS из копии .app с запретом чтения Homebrew."""

import argparse
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile


def prepare_probe(contents, probe, runtime):
    graph = runtime.Relocator(contents)
    binary = graph.add(probe, contents / "Helpers/runtime-probe")
    changes = []
    for reference in runtime.dependencies(probe):
        if runtime.system_library(reference):
            continue
        name = graph.resolve(reference, probe).name
        target = contents / "Frameworks" / name
        if not target.is_file():
            raise RuntimeError(f"Нет встроенной библиотеки: {name}")
        changes.extend(["-change", reference, "@loader_path/../Frameworks/" + name])
    for entry in runtime.rpaths(probe):
        changes.extend(["-delete_rpath", entry])
    if changes:
        runtime.run("install_name_tool", *changes, binary)
    runtime.run("codesign", "--force", "--sign", "-", binary)
    # Проверяются существующие файлы .app; недостающие зависимости не
    # копируются из окружения сборщика и не исправляются перед тестом.
    for directory in ["Frameworks", "Helpers", "Resources/gstreamer-1.0", "Resources/gio/modules"]:
        for path in (contents / directory).iterdir():
            if path.is_file() and (path.suffix in [".dylib", ".so"] or directory == "Helpers"):
                graph.destinations[path] = path
    graph.verify()
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--https", help="также проверить TLS, например https://example.com/")
    parser.add_argument("--no-audio", action="store_true", help="пропустить звуковой сигнал")
    args = parser.parse_args()
    directory = Path(__file__).resolve().parent
    prefix = Path(subprocess.check_output(["brew", "--prefix"], text=True).strip())
    spec = importlib.util.spec_from_file_location("bundle_runtime", directory.parent / "bundle-runtime.py")
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    with tempfile.TemporaryDirectory(prefix="ymd runtime ") as temporary:
        root = Path(temporary)
        app = root / "Standalone Test.app"
        shutil.copytree(args.app, app)
        contents = app / "Contents"
        flags = subprocess.check_output(
            [str(prefix / "bin/pkg-config"), "--cflags", "--libs", "gstreamer-1.0", "gio-2.0"],
            text=True,
        ).split()
        probe = root / "runtime-probe"
        subprocess.run(["cc", str(directory / "runtime-probe.c"), "-o", str(probe), *flags], check=True)
        binary = prepare_probe(contents, probe, runtime)
        environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "DYLD_LIBRARY_PATH": str(contents / "Frameworks"),
            "DYLD_FALLBACK_LIBRARY_PATH": str(contents / "Frameworks"),
            "GST_PLUGIN_SYSTEM_PATH_1_0": str(contents / "Resources/gstreamer-1.0"),
            "GST_PLUGIN_PATH_1_0": "",
            "GST_PLUGIN_SCANNER": str(contents / "Helpers/gst-plugin-scanner"),
            "GST_REGISTRY": str(root / "registry.bin"),
            "GIO_MODULE_DIR": str(contents / "Resources/gio/modules"),
            "GIO_EXTRA_MODULES": str(contents / "Resources/gio/modules"),
            "YMD_CA_BUNDLE": str(contents / "Resources/certs/ca-certificates.crt"),
        }
        profile = '(version 1) (allow default) (deny file-read* (subpath "/opt/homebrew") (subpath "/usr/local"))'
        def command(*arguments):
            # SIP очищает DYLD_* у системных исполняемых файлов. Передаём
            # окружение целевому процессу после запуска sandbox-exec/env.
            return ["/usr/bin/sandbox-exec", "-p", profile, "/usr/bin/env", "-i",
                    *[f"{key}={value}" for key, value in environment.items()],
                    str(binary), *arguments]

        if not args.no_audio:
            subprocess.run(command(), check=True, timeout=40)
        if args.https:
            subprocess.run(command(args.https), check=True, timeout=40)
            # Отрицательная проверка: единственный посторонний CA не должен
            # позволять принять сертификат сайта из положительной проверки.
            environment["YMD_CA_BUNDLE"] = str(directory.parents[1] / "daemon/tests/fixtures/macos-ca.pem")
            rejected = subprocess.run(command(args.https), capture_output=True, text=True, timeout=40)
            if rejected.returncode != 5 or "certificate" not in rejected.stderr.lower():
                raise RuntimeError(f"Проверка недоверенного сертификата не пройдена: {rejected.returncode}, {rejected.stderr}")
            print("ok: недоверенный TLS-сертификат отклонён")


if __name__ == "__main__":
    main()
