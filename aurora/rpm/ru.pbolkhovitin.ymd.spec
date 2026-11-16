Name: ru.pbolkhovitin.ymd
Summary: Unofficial Yandex Music client for Aurora OS
Version: 0.2.1
Release: 1
License: MIT
Group: Applications/Multimedia
URL: https://github.com/pbolkhovitin/ymd
Source0: %{name}-%{version}-%{_target_cpu}.tar.gz

Requires: sailfishsilica-qt5
Requires: qt5-qtmultimedia
Requires: qt5-qtdeclarative-import-multimedia

BuildRequires: rpm-build

%define debug_package %{nil}
%global __strip /opt/cross/bin/aarch64-meego-linux-gnu-strip
%global __objdump /opt/cross/bin/aarch64-meego-linux-gnu-objdump

%description
Unofficial Yandex Music client for Aurora OS.

%description -l ru
Неофициальный клиент Яндекс Музыки для ОС Аврора.

%prep
%autosetup -n %{name}-%{version}-%{_target_cpu}

%build
# The aarch64 binary is cross-built outside rpmbuild by build_rpm.sh.

%install
mkdir -p %{buildroot}
cp -a usr %{buildroot}/
install -Dpm0644 manifest.json %{buildroot}/manifest.json
# Aurora validation rejects executable desktop/icons/QML; only the binary is executable.
find %{buildroot} -type f -exec chmod 644 {} +
chmod 755 %{buildroot}%{_bindir}/%{name}

%files
%defattr(-,root,root,-)
%{_bindir}/%{name}
%{_datadir}/%{name}
%{_datadir}/applications/%{name}.desktop
%{_datadir}/icons/hicolor/86x86/apps/%{name}.png
%{_datadir}/icons/hicolor/108x108/apps/%{name}.png
%{_datadir}/icons/hicolor/128x128/apps/%{name}.png
%{_datadir}/icons/hicolor/172x172/apps/%{name}.png
/manifest.json

%changelog
* Tue Nov 17 2026 Leonid Yurasov <leonidy-85@users.noreply.github.com> - 0.2.1-1
- Automatic rebuild version bump.
* Tue Nov 17 2026 Leonid Yurasov <leonidy-85@users.noreply.github.com> - 0.2.0-1
- Bump version for Aurora package update.
* Mon Nov 16 2026 Leonid Yurasov <leonidy-85@users.noreply.github.com> - 0.1.0-1
- Initial Aurora OS Silica skeleton.
