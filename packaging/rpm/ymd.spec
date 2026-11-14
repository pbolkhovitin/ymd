Name:           ymd
Version:        @VERSION@
Release:        1%{?dist}
Summary:        Yandex Music daemon for KDE Plasma, Qt and Noctalia clients
License:        MIT
URL:            https://github.com/pbolkhovitin/ymd
Source0:        ymd
Source1:        ymd.service
Source2:        README.md
Source3:        LICENSE

Requires:       gstreamer1
Requires:       gstreamer1-plugins-base
Requires:       libsecret
Requires:       playerctl
Recommends:     gstreamer1-plugins-good
Recommends:     gstreamer1-plugins-bad-free
Recommends:     gstreamer1-libav
Recommends:     gstreamer1-plugin-pipewire
Recommends:     pipewire

%description
Local HTTP API, GStreamer playback, MPRIS export, offline cache and
"My Wave" for the Yandex Music clients: the KDE Plasma plasmoid,
the ymd-qt application and the Noctalia plugin.

The daemon keeps the OAuth token in the user keyring, streams lossless
audio to PipeWire and exports MPRIS, so media keys and the desktop
media widget work out of the box.

%prep

%build

%install
install -Dm755 %{SOURCE0} %{buildroot}%{_bindir}/ymd
install -Dm644 %{SOURCE1} %{buildroot}%{_userunitdir}/ymd.service
install -Dm644 %{SOURCE2} %{buildroot}%{_docdir}/%{name}/README.md
install -Dm644 %{SOURCE3} %{buildroot}%{_docdir}/%{name}/LICENSE

%files
%{_bindir}/ymd
%{_userunitdir}/ymd.service
%doc %{_docdir}/%{name}/README.md
%license %{_docdir}/%{name}/LICENSE

%changelog
* Sat Nov 14 2026 Pavel Bolkhovitin <pbolkhovitin@yandex.ru> - @VERSION@-1
- Release @VERSION@
