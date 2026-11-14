#!/usr/bin/env python3
"""Приватный официальный SDK для Rust FFI, без установки .pkg в систему."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


VERSION = "1.28.8"
SHA256 = "d371ab04a7632713626836c2fc234e863cc98484c74c473eba99b0fbd9b3a3fe"


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def merge_payload(source, destination):
    destination.mkdir(parents=True, exist_ok=True)
    for item in source.iterdir():
        target = destination / item.name
        if item.is_symlink():
            link = os.readlink(item)
            if target.is_symlink() and os.readlink(target) == link:
                continue
            if target.exists() or target.is_symlink():
                raise RuntimeError(f"Конфликт payload: {target}")
            target.symlink_to(link)
        elif item.is_dir():
            merge_payload(item, target)
        elif target.exists():
            if checksum(item) != checksum(target):
                raise RuntimeError(f"Конфликт payload: {target}")
        else:
            shutil.copy2(item, target)


def prepare(cache):
    sdk = cache / f"sdk-{VERSION}"
    if (sdk / ".complete").is_file():
        return sdk
    cache.mkdir(parents=True, exist_ok=True)
    package = cache / f"gstreamer-1.0-{VERSION}-universal.pkg"
    if not package.is_file():
        download = package.with_suffix(".download")
        subprocess.run(["curl", "--fail", "--location", "--retry", "2", "--continue-at", "-",
                        f"https://gstreamer.freedesktop.org/data/pkg/osx/{VERSION}/{package.name}",
                        "--output", str(download)], check=True)
        download.replace(package)
    digest = checksum(package)
    if digest != SHA256:
        raise RuntimeError(f"Контрольная сумма {package.name} не совпадает: {digest}")
    with tempfile.TemporaryDirectory(prefix="gst-sdk-", dir=cache) as directory:
        expanded = Path(directory) / "expanded"
        subprocess.run(["pkgutil", "--expand-full", str(package), str(expanded)], check=True)
        sdk.mkdir(parents=True, exist_ok=True)
        for payload in sorted(expanded.glob("*/Payload")):
            merge_payload(payload, sdk)
        shutil.copy2(expanded / "Resources/license.txt", sdk / "GSTREAMER-LICENSE.txt")
    # Rust использует готовые FFI-объявления, а не компилирует C-заголовки.
    # Достаточно точных метаданных линковки runtime; devel.pkg со статическими
    # библиотеками (~770 МБ) и глобальная установка framework не требуются.
    modules = {
        "glib-2.0": ("2.82.4", "glib-2.0", ""),
        "gobject-2.0": ("2.82.4", "gobject-2.0", "glib-2.0"),
        "gio-2.0": ("2.82.4", "gio-2.0", "gobject-2.0"),
        "gstreamer-1.0": (VERSION, "gstreamer-1.0", "gobject-2.0"),
    }
    pc_directory = sdk / "lib/pkgconfig"
    pc_directory.mkdir(parents=True, exist_ok=True)
    for name, (version, library, requires) in modules.items():
        (pc_directory / f"{name}.pc").write_text(
            f"prefix={sdk.resolve()}\nlibdir=${{prefix}}/lib\n"
            f"Name: {name}\nDescription: Официальный runtime GStreamer для Rust FFI\n"
            f"Version: {version}\nRequires: {requires}\nLibs: -L${{libdir}} -l{library}\n"
        )
    (sdk / ".complete").write_text(SHA256 + "\n")
    return sdk


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    print(prepare(root / "packaging/.cache/gstreamer-macos"))
