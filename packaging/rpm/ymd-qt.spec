Name:           ymd-qt
Version:        @VERSION@
Release:        1%{?dist}
Summary:        Yandex Music client for KDE Plasma (Qt/Kirigami)
License:        MIT
URL:            https://github.com/pbolkhovitin/ymd
Source0:        ymd-qt
Source1:        ymd-qt.desktop
Source2:        ymd-qt.svg
Source3:        README.md
Source4:        LICENSE

Requires:       qt6-qtbase
Requires:       qt6-qtdeclarative
Requires:       kf6-kirigami
Requires:       kf6-kstatusnotifieritem
Recommends:     ymd

%description
Standalone desktop application with cover art, seek bar, transport,
search and queue. Talks to the ymd daemon over its local HTTP API and
never stores the OAuth token itself.

%prep

%build

%install
install -Dm755 %{SOURCE0} %{buildroot}%{_bindir}/ymd-qt
install -Dm644 %{SOURCE1} %{buildroot}%{_datadir}/applications/ymd-qt.desktop
install -Dm644 %{SOURCE2} %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/ymd-qt.svg
install -Dm644 %{SOURCE3} %{buildroot}%{_docdir}/%{name}/README.md
install -Dm644 %{SOURCE4} %{buildroot}%{_docdir}/%{name}/LICENSE

%files
%{_bindir}/ymd-qt
%{_datadir}/applications/ymd-qt.desktop
%{_datadir}/icons/hicolor/scalable/apps/ymd-qt.svg
%doc %{_docdir}/%{name}/README.md
%license %{_docdir}/%{name}/LICENSE

%changelog
* Sat Nov 14 2026 Pavel Bolkhovitin <pbolkhovitin@yandex.ru> - @VERSION@-1
- Release @VERSION@
