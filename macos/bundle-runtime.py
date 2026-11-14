#!/usr/bin/env python3
"""Упаковка приватного аудио-runtime с переносимыми зависимостями Mach-O."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess


PLUGINS = (
    "coreelements", "playback", "typefindfunctions", "audioconvert",
    "audioresample", "autodetect", "osxaudio", "volume", "gio", "soup",
    "audioparsers", "isomp4", "id3demux", "apetag", "flac", "mpg123",
    "libav", "ogg", "vorbis", "opus", "wavparse", "wavenc", "aiff",
    "alaw", "mulaw", "audiotestsrc",
)


def run(*args):
    result = subprocess.run([str(arg) for arg in args], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"Команда {args[0]} завершилась с ошибкой: {result.stderr.strip()}")
    return result.stdout.strip()


def system_library(reference):
    return reference.startswith(("/System/Library/", "/usr/lib/"))


def dependencies(binary):
    result = []
    for line in run("otool", "-arch", "arm64", "-L", binary).splitlines()[1:]:
        match = re.match(r"\s+(.+?) \((?:compatibility|current) version", line)
        if match:
            result.append(match.group(1))
    return list(dict.fromkeys(result))


def install_id(binary):
    lines = run("otool", "-arch", "arm64", "-D", binary).splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def rpaths(binary):
    lines = run("otool", "-arch", "arm64", "-l", binary).splitlines()
    result = []
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            match = re.match(r"\s*path (.+) \(offset \d+\)", lines[index + 2])
            if match:
                result.append(match.group(1))
    return result


class Relocator:
    def __init__(self, contents, search_roots=()):
        self.contents = Path(contents).resolve()
        self.files = {}
        self.destinations = {}
        self.search_roots = [Path(path).resolve() for path in search_roots]

    def add(self, source, destination):
        source = Path(source).resolve(strict=True)
        destination = Path(destination).resolve()
        if not destination.is_relative_to(self.contents):
            raise RuntimeError(f"Назначение за пределами приложения: {destination}")
        if source in self.files:
            return self.files[source]
        previous = self.destinations.get(destination)
        if previous is not None and previous != source:
            raise RuntimeError(f"Конфликт библиотек {destination.name}: {previous} и {source}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        destination.chmod(destination.stat().st_mode | 0o200)
        architectures = run("lipo", "-archs", source).split()
        if "arm64" not in architectures:
            raise RuntimeError(f"Нет архитектуры arm64: {source}")
        if len(architectures) > 1:
            run("lipo", source, "-thin", "arm64", "-output", destination)
        self.files[source] = destination
        self.destinations[destination] = source
        return destination

    def resolve(self, reference, source):
        if reference.startswith("@loader_path/"):
            candidate = source.parent / reference.removeprefix("@loader_path/")
        elif reference.startswith("@rpath/"):
            suffix = reference.removeprefix("@rpath/")
            for entry in rpaths(source):
                if entry.startswith("@loader_path"):
                    entry = str(source.parent) + entry[len("@loader_path"):]
                candidate = Path(entry) / suffix
                if candidate.is_file():
                    return candidate.resolve()
            for root in self.search_roots:
                candidate = root / suffix
                if candidate.is_file() and candidate.resolve().is_relative_to(root):
                    return candidate.resolve()
            raise RuntimeError(f"Не найдена зависимость {reference} у {source}")
        elif reference.startswith("/"):
            candidate = Path(reference)
        else:
            raise RuntimeError(f"Неподдерживаемая зависимость {reference} у {source}")
        if not candidate.is_file():
            raise RuntimeError(f"Не найдена зависимость {reference} у {source}")
        return candidate.resolve()

    def relocate(self):
        processed = set()
        while pending := [source for source in self.files if source not in processed]:
            source = pending[0]
            processed.add(source)
            destination = self.files[source]
            identity = install_id(source)
            changes = []
            for reference in dependencies(source):
                if reference == identity or system_library(reference):
                    continue
                dependency = self.resolve(reference, source)
                target = self.add(dependency, self.contents / "Frameworks" / dependency.name)
                relative = os.path.relpath(target, destination.parent)
                changes.extend(["-change", reference, "@loader_path/" + relative])
            if identity:
                changes.extend(["-id", "@rpath/" + destination.name])
            for entry in rpaths(source):
                if entry.startswith("/") and not system_library(entry + "/"):
                    changes.extend(["-delete_rpath", entry])
            if changes:
                run("install_name_tool", *changes, destination)
            # После изменения заголовков исходная подпись недействительна.
            run("codesign", "--force", "--sign", "-", destination)

    def verify(self):
        for destination in self.destinations:
            identity = install_id(destination)
            for reference in dependencies(destination):
                if reference == identity or system_library(reference):
                    continue
                if not reference.startswith("@loader_path/"):
                    raise RuntimeError(f"Внешняя зависимость {reference} в {destination}")
                resolved = self.resolve(reference, destination)
                if not resolved.is_relative_to(self.contents):
                    raise RuntimeError(f"Зависимость за пределами приложения: {resolved}")

    def minimum_macos(self):
        minimum = (13, 0)
        for binary in self.destinations:
            for block in re.split(r"Load command \d+", run("otool", "-arch", "arm64", "-l", binary)):
                key = "minos" if "cmd LC_BUILD_VERSION" in block else "version"
                if "cmd LC_BUILD_VERSION" not in block and "cmd LC_VERSION_MIN_MACOSX" not in block:
                    continue
                match = re.search(rf"^\s*{key} (\d+\.\d+(?:\.\d+)?)$", block, re.MULTILINE)
                if match:
                    minimum = max(minimum, tuple(int(part) for part in match.group(1).split(".")))
        return ".".join(str(part) for part in minimum)

    def require_macos(self, target):
        minimum = self.minimum_macos()
        if tuple(map(int, minimum.split("."))) > tuple(map(int, target.split("."))):
            raise RuntimeError(f"Встроенный код требует macOS {minimum}, целевая версия — {target}")

    def licenses(self):
        directory = self.contents / "Resources" / "ThirdPartyLicenses"
        directory.mkdir(parents=True, exist_ok=True)
        packages = {}
        for source in self.files:
            for parent in source.parents:
                if (parent / "INSTALL_RECEIPT.json").is_file():
                    packages[parent] = parent.parent.name + "-" + parent.name
                    break
        for root, name in sorted(packages.items()):
            target = directory / name
            target.mkdir(exist_ok=True)
            for candidate in root.iterdir():
                if candidate.is_file() and candidate.name.upper().startswith(("LICENSE", "COPYING", "NOTICE", "AUTHORS")):
                    shutil.copy2(candidate, target / candidate.name)
        manifest = {
            "packages": sorted(packages.values()),
            "files": sorted(str(path.relative_to(self.contents)) for path in self.destinations),
        }
        (directory / "runtime-manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
        )


def bundle(app, daemon, prefix):
    contents = app.resolve() / "Contents"
    graph = Relocator(contents, search_roots=[prefix / "lib"])
    graph.add(daemon, contents / "Helpers" / "ymd")
    graph.add(prefix / "libexec/gstreamer-1.0/gst-plugin-scanner",
              contents / "Helpers" / "gst-plugin-scanner")
    for plugin in PLUGINS:
        name = f"libgst{plugin}.dylib"
        graph.add(prefix / "lib/gstreamer-1.0" / name,
                  contents / "Resources/gstreamer-1.0" / name)
    # libsoup загружается плагином по имени через dlopen и отсутствует в otool -L.
    graph.add(prefix / "lib/libsoup-3.0.0.dylib",
              contents / "Frameworks/libsoup-3.0.0.dylib")
    graph.add(prefix / "lib/gio/modules/libgioopenssl.so",
              contents / "Resources/gio/modules/libgioopenssl.so")
    (contents / "Resources/gio/modules/giomodule.cache").write_text(
        "libgioopenssl.so: gio-tls-backend\n"
    )
    certs = contents / "Resources/certs"
    certs.mkdir(parents=True, exist_ok=True)
    shutil.copy2(prefix / "etc/ssl/certs/ca-certificates.crt", certs / "ca-certificates.crt")
    graph.relocate()
    client = contents / "MacOS/ymd-menubar"
    graph.destinations[client] = client
    graph.verify()
    graph.require_macos("13.0")
    graph.licenses()
    shutil.copy2(prefix / "GSTREAMER-LICENSE.txt", contents / "Resources/ThirdPartyLicenses/GSTREAMER-LICENSE.txt")
    (contents / "Resources/ThirdPartyLicenses/SOURCES.txt").write_text(
        "GStreamer runtime 1.28.8 (официальная сборка Cerbero).\n"
        "https://gstreamer.freedesktop.org/data/pkg/osx/1.28.8/\n"
        "https://gitlab.freedesktop.org/gstreamer/cerbero/-/tree/1.28.8\n"
        "Библиотеки перепакованы без изменения исходников, пути Mach-O перенесены внутрь .app.\n"
    )
    minimum = graph.minimum_macos()
    plist_path = contents / "Info.plist"
    with plist_path.open("rb") as stream:
        info = plistlib.load(stream)
    info["LSMinimumSystemVersion"] = minimum
    with plist_path.open("wb") as stream:
        plistlib.dump(info, stream)
    print(f"Runtime: {len(graph.files)} файлов Mach-O; все зависимости внутри .app; macOS {minimum}+")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--daemon", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    args = parser.parse_args()
    bundle(args.app, args.daemon, args.prefix)
