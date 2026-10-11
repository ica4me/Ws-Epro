#!/usr/bin/env bash
#
# setup.sh — pemasang otomatis WebSocket SSH tunnel (ws bersih + stunnel)
#
# Mendukung: Debian 10–13, Ubuntu 20.04–24.04 (x86-64 / arm64).
# Setelah selesai, service langsung aktif:
#   klien --(80 ws)--------> ws --> 127.0.0.1:22 (sshd)
#   klien --(443 TLS)--> stunnel --> ws(10015) --> 127.0.0.1:22 (sshd)
#
# Jalankan sebagai root:
#   wget -qO setup.sh https://raw.githubusercontent.com/ica4me/Ws-Epro/main/setup.sh
#   chmod +x setup.sh && sudo ./setup.sh
#
# Opsi lewat environment variable (semua ada default):
#   REPO=ica4me/Ws-Epro     # repo sumber (user/nama)
#   BRANCH=main
#   BUILD=0                 # 1 = kompilasi ws dari main.go (unduh Go resmi)
#   WITH_UDPGW=1            # 1 = pasang badvpn-udpgw (UDP: DNS/game/VoIP)
#   MAKE_DEMO_USER=1        # 1 = buat akun contoh + password acak
#   SSH_TARGET_PORT=22
#   WS_PORT=80
#   TLS_PORT=443
#   WS_TLS_BACKEND_PORT=10015
#   ENABLE_UFW=1            # 1 = pasang & aktifkan firewall ufw
set -euo pipefail

# ----------------------------------------------------------------------------
REPO="${REPO:-ica4me/Ws-Epro}"
BRANCH="${BRANCH:-main}"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
BUILD="${BUILD:-0}"
WITH_UDPGW="${WITH_UDPGW:-1}"
MAKE_DEMO_USER="${MAKE_DEMO_USER:-1}"
SSH_TARGET_PORT="${SSH_TARGET_PORT:-22}"
WS_PORT="${WS_PORT:-80}"
TLS_PORT="${TLS_PORT:-443}"
WS_TLS_BACKEND_PORT="${WS_TLS_BACKEND_PORT:-10015}"
ENABLE_UFW="${ENABLE_UFW:-1}"
GO_VERSION="1.22.6"

c_g(){ printf '\033[1;32m%s\033[0m\n' "$*"; }   # hijau
c_y(){ printf '\033[1;33m%s\033[0m\n' "$*"; }   # kuning
c_r(){ printf '\033[1;31m%s\033[0m\n' "$*"; }   # merah
step(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die(){ c_r "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Harus dijalankan sebagai root (pakai sudo)."

# ----------------------------------------------------------------------------
step "1/11  Deteksi OS"
[ -r /etc/os-release ] || die "/etc/os-release tidak ada — OS tidak dikenali."
. /etc/os-release
OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-0}"; OS_MAJ="${OS_VER%%.*}"
case "$OS_ID" in
  debian)
    if [ "$OS_MAJ" -ge 10 ] && [ "$OS_MAJ" -le 13 ]; then
      c_g "Debian $OS_VER — didukung."
    else
      c_y "Debian $OS_VER di luar rentang teruji (10–13). Lanjut, risiko sendiri."
    fi ;;
  ubuntu)
    if [ "$OS_MAJ" -ge 20 ] && [ "$OS_MAJ" -le 24 ]; then
      c_g "Ubuntu $OS_VER — didukung."
    else
      c_y "Ubuntu $OS_VER di luar rentang teruji (20.04–24.04). Lanjut, risiko sendiri."
    fi ;;
  *) die "OS '$OS_ID' tidak didukung. Hanya Debian/Ubuntu." ;;
esac

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in
  amd64|x86_64) GOARCH=amd64; ARCH=amd64 ;;
  arm64|aarch64) GOARCH=arm64; ARCH=arm64 ;;
  *) GOARCH=""; c_y "Arsitektur $ARCH: build dari source mungkin perlu penyesuaian." ;;
esac

# ----------------------------------------------------------------------------
step "2/11  Pasang paket yang diperlukan"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
PKGS="curl ca-certificates wget openssh-server stunnel4 openssl netcat-openbsd"
[ "$ENABLE_UFW" = "1" ] && PKGS="$PKGS ufw"
[ "$WITH_UDPGW" = "1" ] && PKGS="$PKGS git cmake make gcc build-essential"
apt-get install -y -q $PKGS
# fail2ban untuk meredam brute-force port 22 (opsional, tidak fatal bila gagal)
apt-get install -y -q fail2ban 2>/dev/null || c_y "fail2ban gagal dipasang (dilewati)."

# ----------------------------------------------------------------------------
step "3/11  Siapkan binary ws"
install -d /usr/bin /etc/ws
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

get_binary_prebuilt() {
  c_y "Mengunduh binary prebuilt: ${RAW}/ws"
  curl -fSL --retry 3 -o "$TMP/ws" "${RAW}/ws" || return 1
  [ -s "$TMP/ws" ] || return 1
}

build_from_source() {
  c_y "Build dari source (main.go)…"
  [ -n "$GOARCH" ] || return 1
  curl -fSL --retry 3 -o "$TMP/go.tgz" \
    "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" || return 1
  rm -rf /usr/local/go && tar -C /usr/local -xzf "$TMP/go.tgz"
  curl -fSL --retry 3 -o "$TMP/main.go" "${RAW}/main.go" || return 1
  ( cd "$TMP" && printf 'module ws\n\ngo 1.22\n' > go.mod &&
    /usr/local/go/bin/go build -trimpath -ldflags="-s -w" -o ws . ) || return 1
}

if [ "$BUILD" = "1" ]; then
  build_from_source || die "Build dari source gagal."
else
  get_binary_prebuilt || { c_y "Prebuilt gagal, coba build…"; build_from_source || die "Tidak bisa menyiapkan binary ws."; }
fi

# Sanity check: pastikan ini binary yang menerima '-f' dan BUKAN malware.
chmod +x "$TMP/ws"
if command -v strings >/dev/null 2>&1; then
  if strings "$TMP/ws" | grep -Eiq 'authorized_keys|ssh-ed25519 AAAA|chattr|api\.telegram|icanhazip|nevpn'; then
    die "Binary ws mengandung indikator berbahaya. Dibatalkan demi keamanan."
  fi
fi
install -m 0755 "$TMP/ws" /usr/bin/ws
c_g "ws terpasang: $(/usr/bin/ws 2>&1 | head -1 || true)"

# ----------------------------------------------------------------------------
step "4/11  Tulis /etc/ws/config.conf"
cat > /etc/ws/config.conf <<EOF
## verbose level 0=info, 1=verbose, 2=very verbose
verbose: 0
listen:

# Port ${WS_PORT} (ws polos) -> SSH
- target_host: 127.0.0.1
  target_port: ${SSH_TARGET_PORT}
  listen_port: ${WS_PORT}
  bufLen: 16384

# Port internal untuk dibungkus TLS oleh stunnel (${TLS_PORT}) -> SSH
- target_host: 127.0.0.1
  target_port: ${SSH_TARGET_PORT}
  listen_port: ${WS_TLS_BACKEND_PORT}
  bufLen: 16384
EOF
c_g "config.conf dibuat."

# ----------------------------------------------------------------------------
step "5/11  Aktifkan login password SSH"
# Set di sshd_config utama…
if grep -qE '^\s*#?\s*PasswordAuthentication' /etc/ssh/sshd_config; then
  sed -i 's/^\s*#\?\s*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
else
  echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
fi
# …dan timpa drop-in cloud-init (Ubuntu 22.04+/Debian 12 sering set 'no' di sini).
if [ -d /etc/ssh/sshd_config.d ]; then
  echo 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/99-ws.conf
fi
if sshd -t 2>/tmp/sshd_err; then
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  c_g "PasswordAuthentication aktif."
else
  c_y "sshd config warning: $(cat /tmp/sshd_err). Periksa manual bila SSH bermasalah."
fi

# ----------------------------------------------------------------------------
step "6/11  Service systemd untuk ws"
cat > /etc/systemd/system/ws.service <<'EOF'
[Unit]
Description=WebSocket TCP relay (clean)
After=syslog.target network-online.target

[Service]
User=root
NoNewPrivileges=true
ExecStart=/usr/bin/ws -f /etc/ws/config.conf
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now ws
c_g "ws.service aktif."

# ----------------------------------------------------------------------------
step "7/11  Siapkan stunnel (TLS port ${TLS_PORT})"
install -d /etc/stunnel
if [ ! -s /etc/stunnel/stunnel.pem ]; then
  openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -subj "/CN=ws" -keyout "$TMP/k.pem" -out "$TMP/c.pem" >/dev/null 2>&1
  cat "$TMP/c.pem" "$TMP/k.pem" > /etc/stunnel/stunnel.pem
  chmod 600 /etc/stunnel/stunnel.pem
fi
cat > /etc/stunnel/stunnel.conf <<EOF
pid = /var/run/stunnel.pid
[ws-tls]
accept = ${TLS_PORT}
connect = 127.0.0.1:${WS_TLS_BACKEND_PORT}
cert = /etc/stunnel/stunnel.pem
EOF
[ -f /etc/default/stunnel4 ] && sed -i 's/^ENABLED=0/ENABLED=1/' /etc/default/stunnel4
systemctl enable stunnel4 >/dev/null 2>&1 || true
systemctl restart stunnel4 2>/dev/null || systemctl restart stunnel 2>/dev/null || true
c_g "stunnel aktif di port ${TLS_PORT}."

# ----------------------------------------------------------------------------
step "8/11  (Opsional) badvpn-udpgw untuk UDP"
if [ "$WITH_UDPGW" = "0" ]; then
  if [ ! -x /usr/local/bin/badvpn-udpgw ]; then
    ( set -e
      git clone --depth 1 https://github.com/ambrop72/badvpn.git "$TMP/badvpn"
      mkdir -p "$TMP/badvpn/build" && cd "$TMP/badvpn/build"
      cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null
      make >/dev/null
      install -m 0755 udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw
    ) && c_g "badvpn-udpgw terpasang." || c_y "Build udpgw gagal (dilewati)."
  fi
  if [ -x /usr/local/bin/badvpn-udpgw ]; then
    cat > /etc/systemd/system/udpgw.service <<'EOF'
[Unit]
Description=badvpn-udpgw
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500 --max-connections-for-client 10
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now udpgw 2>/dev/null || true
  fi
else
  c_y "WITH_UDPGW=0 — udpgw dilewati."
fi

# ----------------------------------------------------------------------------
step "9/11  Firewall + fail2ban"
if [ "$ENABLE_UFW" = "1" ] && command -v ufw >/dev/null 2>&1; then
  ufw allow "${SSH_TARGET_PORT}"/tcp >/dev/null 2>&1 || true   # jangan sampai terkunci
  ufw allow 22/tcp  >/dev/null 2>&1 || true
  ufw allow "${WS_PORT}"/tcp  >/dev/null 2>&1 || true
  ufw allow "${TLS_PORT}"/tcp >/dev/null 2>&1 || true
  ufw deny  "${WS_TLS_BACKEND_PORT}"/tcp >/dev/null 2>&1 || true
  yes | ufw enable >/dev/null 2>&1 || true
  c_g "ufw aktif: izinkan 22,${WS_PORT},${TLS_PORT}; tutup ${WS_TLS_BACKEND_PORT}."
fi
systemctl enable --now fail2ban >/dev/null 2>&1 || true

# ----------------------------------------------------------------------------
step "10/11  (Opsional) Akun demo"
DEMO_USER=""; DEMO_PASS=""
if [ "$MAKE_DEMO_USER" = "1" ]; then
  DEMO_USER="${DEMO_USER_NAME:-user01}"
  DEMO_PASS="$(openssl rand -hex 9)"   # 18 char hex; tanpa pipe/head (hindari SIGPIPE+pipefail)
  if ! id "$DEMO_USER" >/dev/null 2>&1; then
    useradd -M -s /bin/false -e "$(date -d '+30 days' +%F)" "$DEMO_USER"
  fi
  echo "${DEMO_USER}:${DEMO_PASS}" | chpasswd
  c_g "Akun demo dibuat: $DEMO_USER (aktif 30 hari)."
fi

# ----------------------------------------------------------------------------
step "11/11  Verifikasi"
sleep 1
ss -tlnp 2>/dev/null | grep -E ":(${WS_PORT}|${TLS_PORT}|${WS_TLS_BACKEND_PORT}|${SSH_TARGET_PORT})\b" || true

test80="$(printf 'GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n\r\n' | timeout 4 nc 127.0.0.1 "${WS_PORT}" 2>/dev/null | head -1 || true)"
case "$test80" in *"101"*) c_g "Port ${WS_PORT} (ws): OK — $test80";; *) c_y "Port ${WS_PORT}: respon tak terduga: ${test80:-<kosong>}";; esac

test443="$( { printf 'GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n\r\n'; sleep 2; } | timeout 6 openssl s_client -connect 127.0.0.1:"${TLS_PORT}" -quiet 2>/dev/null | head -1 || true)"
case "$test443" in *"101"*) c_g "Port ${TLS_PORT} (TLS->ws): OK — $test443";; *) c_y "Port ${TLS_PORT}: respon tak terduga: ${test443:-<kosong>}";; esac

IP="$(curl -s --max-time 8 ipv4.icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')"

echo
c_g "==================== SELESAI ===================="
echo "IP VPS         : ${IP}"
echo "Port klien     : ${WS_PORT} (ws)  dan  ${TLS_PORT} (SSL/TLS)"
echo "Target SSH     : 127.0.0.1:${SSH_TARGET_PORT}"
[ -n "$DEMO_USER" ] && { echo "Akun demo      : ${DEMO_USER} / ${DEMO_PASS}"; echo "   (cek masa aktif: chage -l ${DEMO_USER})"; }
echo
echo "Payload HTTP Custom:"
echo '   GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]'
echo
echo "Buat akun baru : useradd -M -s /bin/false -e \$(date -d '+30 days' +%F) NAMA && echo 'NAMA:SANDI' | chpasswd"
echo "Pantau log     : journalctl -f -u ws -u ssh"
c_g "================================================="