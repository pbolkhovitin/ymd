# Aurora OS port

Single Qt 5.6 / Silica application `ru.pbolkhovitin.ymd` with a C++ backend
(Yandex auth, search, stream signing, QtMultimedia playback, queue).

## Build

```sh
bash aurora/build_rpm.sh
```

The script cross-builds aarch64 and armv7hl, stages the files and builds both
RPMs under `aurora/output/aurora-rpm/RPMS/`.

Every run bumps the patch version automatically:

- `aurora/rpm/ru.pbolkhovitin.ymd.spec` — `Version:` and a new `%changelog` entry;
- `aurora/src/main.cpp` — `setApplicationVersion()`;
- the RPM file name and staging directory follow the new version.

The version bump is done by `aurora/bump_version.sh`; do not edit those two
version strings by hand.

## Signing

Aurora packages are signed with the provided X.509 certificate via
`rpmsign-external` (not GPG). Signing is a separate step after the build; the
private key passphrase is supplied through `KEY_PASSPHRASE` and is never stored
in the repository.
