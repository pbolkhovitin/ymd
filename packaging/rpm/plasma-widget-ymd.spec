Name:           plasma-widget-ymd
Version:        @VERSION@
Release:        1%{?dist}
Summary:        Yandex Music plasmoid for KDE Plasma 6
License:        MIT
URL:            https://github.com/pbolkhovitin/ymd
BuildArch:      noarch
Source0:        plasma-widget-ymd.tar.gz
Source1:        README.md
Source2:        LICENSE

Requires:       plasma-workspace
Requires:       kf6-kirigami
Recommends:     ymd

%description
Compact panel widget and popup with search, queue, transport and
"My Wave" controls. Requires the ymd daemon for playback.

%prep
%setup -q -c -T -a 0

%build

%install
install -d %{buildroot}%{_datadir}/plasma/plasmoids/io.github.pbolkhovitin.ymd
cp -a plasmoid/. %{buildroot}%{_datadir}/plasma/plasmoids/io.github.pbolkhovitin.ymd/
install -Dm644 %{SOURCE1} %{buildroot}%{_docdir}/%{name}/README.md
install -Dm644 %{SOURCE2} %{buildroot}%{_docdir}/%{name}/LICENSE

%files
%{_datadir}/plasma/plasmoids/io.github.pbolkhovitin.ymd
%doc %{_docdir}/%{name}/README.md
%license %{_docdir}/%{name}/LICENSE

%changelog
* Sat Nov 14 2026 Pavel Bolkhovitin <pbolkhovitin@yandex.ru> - @VERSION@-1
- Release @VERSION@
