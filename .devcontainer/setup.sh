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
  default-jre-headless build-essential pkg-config libcairo2-dev \
  libjpeg-turbo8-dev libpng-dev libtool-bin libossp-uuid-dev uuid-dev \
  libvncserver-dev libpulse-dev libwebp-dev libssl-dev

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

# VNC session -> the Ubuntu GNOME session (dock + Yaru come with it)
cat > ~/.vnc/xstartup <<'XEOF'
#!/bin/sh
# GNOME session WITHOUT gnome-session: on Ubuntu 25.x gnome-session launches via
# systemd user targets (gnome-session@ubuntu.target) and Codespaces has no systemd,
# so it aborts (signal 6) and TigerVNC kills the X server. Start the real Ubuntu
# shell directly instead: settings daemons + gnome-shell in ubuntu mode.
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_DESKTOP=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export DESKTOP_SESSION=ubuntu
export XDG_SESSION_TYPE=x11
export XDG_RUNTIME_DIR=$HOME/.runtime
export GNOME_SHELL_SESSION_MODE=ubuntu
export LIBGL_ALWAYS_SOFTWARE=1
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
exec dbus-run-session -- sh -c '
  for d in /usr/libexec/gsd-*; do [ -x "$d" ] && "$d" >/dev/null 2>&1 & done
  sleep 1
  exec gnome-shell --x11 >>$HOME/session.log 2>&1
'
XEOF
chmod +x ~/.vnc/xstartup

# guacd (Guacamole's daemon, VNC protocol) — built in /tmp so the build
# tree doesn't eat workspace storage; installed to /usr/local.
if [ ! -x /usr/local/sbin/guacd ]; then
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
  <authorize username="$GUAC_USER" password="$MD5">
    <connection name="Ubuntu Desktop (VNC)">
      <protocol>vnc</protocol>
      <param name="hostname">127.0.0.1</param>
      <param name="port">5901</param>
      <param name="password">$VNC_PASS</param>
      <param name="color-depth">24</param>
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
# (Re)starts the whole stack and VERIFIES each piece — no fake banners.
# Run after every codespace start/wake (processes don't survive a stop).
W=1920; H=1080
echo "== starting stack =="
# --- VNC desktop ---
vncserver -kill :1 > /dev/null 2>&1 || true
vncserver :1 -geometry "${W}x${H}" -depth 24 -localhost yes > ~/vnc-start.log 2>&1
sleep 2
if ss -ltn | grep -q ':5901'; then echo "VNC      : UP (5901)"; else echo "VNC      : DOWN - last VNC log lines:"; tail -8 ~/.vnc/*:1.log; fi
# --- guacd (foreground under setsid so its log is captured) ---
pgrep -x guacd > /dev/null || setsid nohup guacd -f -b 127.0.0.1 -l 4822 -p "$HOME/.guacamole/guacd.pid" -L info > ~/guacd-start.log 2>&1 &
sleep 1
if pgrep -x guacd > /dev/null; then echo "guacd    : UP (4822)"; else echo "guacd    : DOWN"; tail -5 ~/guacd-start.log; fi
# --- Tomcat (Guacamole webapp) ---
pgrep -f catalina > /dev/null || /opt/tomcat/bin/startup.sh > ~/tomcat-start.log 2>&1
ok=0; for i in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:8080/ && { ok=1; break; }; sleep 2; done
if [ $ok = 1 ]; then echo "Guacamole: UP (8080)"; else echo "Guacamole: DOWN - catalina tail:"; tail -8 /opt/tomcat/logs/catalina.out; fi
# --- noVNC fallback ---
pkill -f websockify > /dev/null 2>&1 || true
sleep 1
setsid nohup websockify --web /usr/share/novnc 6080 127.0.0.1:5901 > ~/novnc.log 2>&1 &
sleep 1
if ss -ltn | grep -q ':6080'; then echo "noVNC    : UP (6080)"; else echo "noVNC    : DOWN"; fi
echo "=============================================================="
if [ -n "$CODESPACE_NAME" ]; then echo "  GUACAMOLE: https://${CODESPACE_NAME}-8080.app.github.dev/"; fi
echo "    login:  nova / $(cat ~/.guacamole/plaintext-pass 2>/dev/null || echo MISSING)"
echo "    click:  Ubuntu Desktop (VNC)"
if [ -n "$CODESPACE_NAME" ]; then echo "  NOVNC:     https://${CODESPACE_NAME}-6080.app.github.dev/vnc.html"; fi
echo "    VNC password:  $(cat ~/.vnc/plaintext-pass 2>/dev/null || echo MISSING)"
echo "=============================================================="
SEOF
chmod +x ~/start-desktop.sh
set +x
[ -f /opt/tomcat/bin/startup.sh ] || echo "!! TOMCAT MISSING — check output above"
echo "SETUP DONE. Start the desktop with:  ~/start-desktop.sh"
echo "Disk now: $(df -h / | tail -1)"
