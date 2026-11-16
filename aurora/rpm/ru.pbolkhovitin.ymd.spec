Name: ru.pbolkhovitin.ymd
Summary: Unofficial Yandex Music client for Aurora OS
Version: 0.1.0
Release: 1
License: MIT
Group: Applications/Multimedia
URL: https://github.com/pbolkhovitin/ymd
Source0: %{name}-%{version}.tar.gz

Requires: sailfishsilica-qt5
Requires: qt5-qtmultimedia
Requires: qt5-qtdeclarative-import-multimedia

BuildRequires: pkgconfig(auroraapp)
BuildRequires: pkgconfig(Qt5Core)
BuildRequires: pkgconfig(Qt5Qml)
BuildRequires: pkgconfig(Qt5Quick)
BuildRequires: pkgconfig(Qt5Network)
BuildRequires: pkgconfig(Qt5Multimedia)
BuildRequires: desktop-file-utils

%description
Unofficial Yandex Music client for Aurora OS.

%description -l ru
Неофициальный клиент Яндекс Музыки для ОС Аврора.

%prep
%setup -q

%build
%qmake5
make %{?_smp_mflags}

%install
%qmake5_install

%files
%defattr(-,root,root,-)
/usr/bin/%{name}
/usr/share/%{name}
/usr/share/applications/%{name}.desktop
/usr/share/icons/hicolor/86x86/apps/%{name}.png
/usr/share/icons/hicolor/108x108/apps/%{name}.png
/usr/share/icons/hicolor/128x128/apps/%{name}.png
/usr/share/icons/hicolor/172x172/apps/%{name}.png

%changelog
* Mon Nov 16 2026 Leonid Yurasov <leonidy-85@users.noreply.github.com> - 0.1.0-1
- Initial Aurora OS Silica skeleton.
