#!/bin/bash
# Runs once at codespace creation (and again on rebuild). Idempotent.
set -x
export DEBIAN_FRONTEND=noninteractive

# Lean base + the REAL Ubuntu desktop (GNOME + Ubuntu session, dock, Yaru)
# + Apache Guacamole on 8080 as the main door, noVNC on 6080 as fallback.
# The default Codespaces universal image wastes ~10 GB on toolchains; the
# base:ubuntu image is ~2 GB, which is how a 32 GB disk becomes livable.
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends \
  gnome-shell gnome-session gnome-settings-daemon ubuntu-session ubuntu-settings \
  gnome-shell-extension-ubuntu-dock gnome-shell-extension-desktop-icons-ng \
  gnome-control-center nautilus gnome-terminal gnome-tweaks \
  yaru-theme-gtk yaru-theme-icon yaru-theme-gnome-shell yaru-theme-sound \
  ubuntu-wallpapers fonts-dejavu fonts-liberation \
  tigervnc-standalone-server tigervnc-common novnc websockify \
  dbus-x11 x11-xserver-utils xauth curl net-tools procps \
  gnome-remote-desktop openssl \
  default-jre-headless build-essential pkg-config libcairo2-dev \
  libjpeg-turbo8-dev libpng-dev libtool-bin libossp-uuid-dev uuid-dev \
  libvncserver-dev libpulse-dev libwebp-dev libssl-dev

# FreeRDP dev: guacd's RDP protocol plugin (GNOME 50 streams via RDP, see below).
# Ubuntu 26.04 ships FreeRDP 3.32 runtime libs but the -dev packaging is split;
# install every plausible name, then let pkg-config be the judge.
if ! pkg-config --exists freerdp3 2>/dev/null; then
  for p in freerdp3-dev libfreerdp3-dev libfreerdp-client3-dev libfreerdp-server3-dev libwinpr3-dev; do
    sudo apt-get install -y -qq "$p" 2>/dev/null || true
  done
fi
echo "freerdp3 pkg-config: $(pkg-config --modversion freerdp3 2>/dev/null || echo MISSING)"

# Firefox: Ubuntu's deb is a snap stub (snaps don't run here) -> Mozilla tarball.
if [ ! -x /opt/firefox/firefox ]; then
  curl -L "https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=en-US" -o /tmp/firefox.tar
  sudo tar -xf /tmp/firefox.tar -C /opt
  sudo ln -sf /opt/firefox/firefox /usr/local/bin/firefox
  sudo tee /usr/share/applications/firefox.desktop > /dev/null <<'FFEOF'
[Desktop Entry]
Name=Firefox
Exec=/opt/firefox/firefox %u
Icon=/opt/firefox/browser/chrome/icons/default/default128.png
Type=Application
Categories=Network;WebBrowser;
Terminal=false
FFEOF
fi

# Passwords: one VNC password + one Guacamole login, generated per codespace.
mkdir -p ~/.vnc ~/.guacamole
if [ ! -f ~/.vnc/passwd ]; then
  VNC_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)
  echo "$VNC_PASS" | vncpasswd -f > ~/.vnc/passwd
  chmod 600 ~/.vnc/passwd
  echo "$VNC_PASS" > ~/.vnc/plaintext-pass
  chmod 600 ~/.vnc/plaintext-pass
fi
if [ ! -f ~/.guacamole/plaintext-pass ]; then
  GUAC_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 14)
  echo "$GUAC_PASS" > ~/.guacamole/plaintext-pass
  chmod 600 ~/.guacamole/plaintext-pass
fi
VNC_PASS=$(cat ~/.vnc/plaintext-pass)
GUAC_PASS=$(cat ~/.guacamole/plaintext-pass)
GUAC_USER=nova

# Desktop session: GNOME 50 is Wayland-only; its display-server mode demands a
# logind session ("Failed to find any matching session") a container can't have.
# Supported route: gnome-shell --headless (virtual monitor) streamed by
# gnome-remote-desktop over RDP - which Guacamole speaks natively.
cat > ~/run-session.sh <<'XEOF'
#!/bin/bash
export XDG_RUNTIME_DIR=$HOME/.runtime
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export XDG_SESSION_DESKTOP=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export DESKTOP_SESSION=ubuntu
export GNOME_SHELL_SESSION_MODE=ubuntu
export LIBGL_ALWAYS_SOFTWARE=1
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
exec dbus-run-session -- sh -c '
  for d in /usr/libexec/gsd-*; do [ -x "$d" ] && "$d" >/dev/null 2>&1 & done
  grdctl --headless rdp set-tls-cert $HOME/.config/gnome-remote-desktop/rdp-tls.crt >>$HOME/session.log 2>&1
  grdctl --headless rdp set-tls-key $HOME/.config/gnome-remote-desktop/rdp-tls.key >>$HOME/session.log 2>&1
  grdctl --headless rdp set-credentials nova "$(cat $HOME/.vnc/plaintext-pass)" >>$HOME/session.log 2>&1
  grdctl --headless rdp enable >>$HOME/session.log 2>&1 || true
  /usr/libexec/gnome-remote-desktop-daemon --headless >>$HOME/session.log 2>&1 &
  sleep 1
  exec gnome-shell --headless --virtual-monitor 1920x1080 >>$HOME/session.log 2>&1
'
XEOF
chmod +x ~/run-session.sh

# gnome-remote-desktop headless config: self-signed TLS + RDP credentials.
# The RDP password reuses the VNC password value - Guacamole passes it
# automatically from user-mapping.xml, so the user never types it.
mkdir -p ~/.config/gnome-remote-desktop
if [ ! -f ~/.config/gnome-remote-desktop/rdp-tls.crt ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=localhost" \
    -keyout ~/.config/gnome-remote-desktop/rdp-tls.key \
    -out ~/.config/gnome-remote-desktop/rdp-tls.crt > /dev/null 2>&1
fi
echo "grd: cert ready; grdctl config runs inside the session (it needs the session bus)"

# guacd (Guacamole's daemon, RDP protocol) — built in /tmp so the build
# tree doesn't eat workspace storage; installed to /usr/local.
if [ ! -x /usr/local/sbin/guacd ] || [ ! -e /usr/local/lib/libguac-client-rdp.so ]; then
  cd /tmp
  curl -fLO https://dlcdn.apache.org/guacamole/1.6.0/source/guacamole-server-1.6.0.tar.gz || echo "!! guacd download FAILED"
  tar -xzf guacamole-server-1.6.0.tar.gz
  cd guacamole-server-1.6.0
  ./configure --with-init-dir=/etc/init.d CFLAGS="-O2 -Wno-error" | tail -20
  sed -i '/#define _XOPEN_SOURCE 700/d' config.h
  make -j"$(nproc)" | tail -3
  sudo make install
  sudo ldconfig
  cd ~
fi
[ -x /usr/local/sbin/guacd ] || echo "!! GUACD MISSING — build failed, check output above"
[ -e /usr/local/lib/libguac-client-rdp.so ] || echo "!! RDP PLUGIN MISSING — guacd built without FreeRDP"

# Tomcat + Guacamole webapp as ROOT app -> the 8080 URL opens it directly.
if [ ! -f /opt/tomcat/bin/startup.sh ]; then
  cd /tmp
  curl -fLO https://dlcdn.apache.org/tomcat/tomcat-9/v9.0.123/bin/apache-tomcat-9.0.123.tar.gz || echo "!! tomcat download FAILED"
  sudo mkdir -p /opt/tomcat
  sudo tar -xzf apache-tomcat-9.0.123.tar.gz -C /opt/tomcat --strip-components=1
  cd ~
fi
sudo rm -rf /opt/tomcat/webapps/ROOT
sudo curl -fL https://dlcdn.apache.org/guacamole/1.6.0/binary/guacamole-1.6.0.war -o /opt/tomcat/webapps/ROOT.war || echo "!! guacamole war download FAILED"
printf 'guacd-hostname: 127.0.0.1\nguacd-port: 4822\n' > ~/.guacamole/guacamole.properties
MD5=$(echo -n "$GUAC_PASS" | md5sum | cut -d' ' -f1)
cat > ~/.guacamole/user-mapping.xml <<XEOF
<user-mapping>
  <authorize username="$GUAC_USER" password="$MD5" encoding="md5">
    <connection name="Ubuntu Desktop">
      <protocol>rdp</protocol>
      <param name="hostname">127.0.0.1</param>
      <param name="port">3389</param>
      <param name="username">$GUAC_USER</param>
      <param name="password">$VNC_PASS</param>
      <param name="security">any</param>
      <param name="ignore-cert">true</param>
      <param name="resize-method">display-update</param>
    </connection>
  </authorize>
</user-mapping>
XEOF
JAVA_BIN=$(readlink -f "$(command -v java)")
sudo tee /opt/tomcat/bin/setenv.sh > /dev/null <<XEOF
export JAVA_HOME=${JAVA_BIN%/bin/java}
export GUACAMOLE_HOME=$HOME/.guacamole
XEOF
sudo chown -R "$(id -un)" /opt/tomcat

cat > ~/start-desktop.sh <<'SEOF'
#!/bin/bash
# (Re)starts the whole stack and VERIFIES each piece - no fake banners.
# Run after every codespace start/wake (processes don't survive a stop).
echo "== starting stack =="
# --- desktop session: headless GNOME shell over RDP (gnome-remote-desktop) ---
pkill -f run-session.sh > /dev/null 2>&1 || true
pkill -f gnome-remote-desktop-daemon > /dev/null 2>&1 || true
pkill -x gnome-shell > /dev/null 2>&1 || true
sleep 1
: > ~/session.log
setsid nohup ~/run-session.sh > ~/session-start.log 2>&1 &
ok=0; for i in $(seq 1 30); do ss -ltn | grep -q ':3389' && { ok=1; break; }; sleep 2; done
if [ $ok = 1 ]; then echo "Desktop  : UP (RDP 3389)"; else echo "Desktop  : DOWN - session log:"; tail -8 ~/session.log; fi
# --- guacd (foreground under setsid so its log is captured) ---
pkill -x guacd > /dev/null 2>&1 || true
sleep 1
setsid nohup guacd -f -b 127.0.0.1 -l 4822 -p "$HOME/.guacamole/guacd.pid" -L info > ~/guacd-start.log 2>&1 &
sleep 1
if pgrep -x guacd > /dev/null; then echo "guacd    : UP (4822)"; else echo "guacd    : DOWN"; tail -5 ~/guacd-start.log; fi
# --- Tomcat (Guacamole webapp) ---
/opt/tomcat/bin/shutdown.sh > /dev/null 2>&1 || true
pkill -f catalina > /dev/null 2>&1 || true
sleep 2
/opt/tomcat/bin/startup.sh > ~/tomcat-start.log 2>&1
ok=0; for i in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:8080/ && { ok=1; break; }; sleep 2; done
if [ $ok = 1 ]; then echo "Guacamole: UP (8080)"; else echo "Guacamole: DOWN - catalina tail:"; tail -8 /opt/tomcat/logs/catalina.out; fi
echo "=============================================================="
if [ -n "$CODESPACE_NAME" ]; then echo "  GUACAMOLE: https://${CODESPACE_NAME}-8080.app.github.dev/"; fi
echo "    login:  nova / $(cat ~/.guacamole/plaintext-pass 2>/dev/null || echo MISSING)"
echo "    click:  Ubuntu Desktop  (RDP starts automatically, no second password)"
echo "=============================================================="
SEOF
chmod +x ~/start-desktop.sh
set +x
[ -f /opt/tomcat/bin/startup.sh ] || echo "!! TOMCAT MISSING — check output above"
echo "SETUP DONE. Start the desktop with:  ~/start-desktop.sh"
echo "Disk now: $(df -h / | tail -1)"
