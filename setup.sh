#!/bin/bash
# Hapus script setelah dijalankan agar bersih
rm -- "$0"

echo "[*] Memulai instalasi Auto Setup Ws-Epro All-in-One..."

# 1. Update dan Install paket yang dibutuhkan
echo "[*] Memperbarui repository dan menginstal dependensi (OpenSSH, Stunnel4, UFW, dll)..."
apt-get update
apt-get install -y openssh-server stunnel4 ufw curl wget openssl netcat-traditional

# 2. Pasang binary ws dari repositori
echo "[*] Mengunduh binary ws..."
mkdir -p /etc/ws
REPO="https://raw.githubusercontent.com/ica4me/Ws-Epro/main/"
wget -O /usr/bin/ws "${REPO}ws"
chmod +x /usr/bin/ws

# 3. Siapkan server SSH sebagai target tunnel
echo "[*] Mengonfigurasi OpenSSH Server..."
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh

# 4. Tulis konfigurasi Ws-Epro
echo "[*] Membuat konfigurasi Ws-Epro..."
cat << 'EOF' > /etc/ws/config.conf
## verbose level 0=info, 1=verbose, 2=very verbose
verbose: 0
listen:
# Port 80 (ws:// langsung) -> SSH
  target_host: 127.0.0.1
  target_port: 22
  listen_port: 80
  bufLen: 16384
# Port internal untuk dibungkus TLS oleh stunnel (443) -> SSH
  target_host: 127.0.0.1
  target_port: 22
  listen_port: 10015
  bufLen: 16384
EOF

# 5. Buat service systemd dan jalankan Ws-Epro
echo "[*] Membuat dan menjalankan service ws..."
cat << 'EOF' > /etc/systemd/system/ws.service
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
systemctl enable --now ws.service

# 6. Buka firewall
echo "[*] Membuka port firewall (22, 80, 443)..."
ufw allow 22,80,443/tcp 2>/dev/null || true

# 7. Buat akun + password untuk klien (Aktif 30 Hari)
echo "[*] Membuat akun SSH tunnel (user01 / pass01)..."
if id "user01" &>/dev/null; then
    echo "[-] User 'user01' sudah ada, melewati pembuatan user."
else
    useradd -M -s /bin/false -e $(date -d "+30 days" +%F) user01
    echo 'user01:pass01' | chpasswd
    echo "[+] User 'user01' berhasil dibuat."
fi

# 8. Konfigurasi Stunnel untuk Port 443 (TLS/wss)
echo "[*] Mengonfigurasi Stunnel4 untuk koneksi TLS (Port 443)..."
# Buat sertifikat self-signed
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
  -subj "/CN=myvpn" -keyout /tmp/k.pem -out /tmp/c.pem 2>/dev/null

cat /tmp/c.pem /tmp/k.pem > /etc/stunnel/stunnel.pem
chmod 600 /etc/stunnel/stunnel.pem
rm -f /tmp/k.pem /tmp/c.pem

# Tulis konfigurasi Stunnel
cat << 'EOF' > /etc/stunnel/stunnel.conf
pid = /var/run/stunnel.pid
[ws-tls]
accept = 443
connect = 127.0.0.1:10015
cert = /etc/stunnel/stunnel.pem
EOF

# Aktifkan dan restart Stunnel4
sed -i 's/^ENABLED=0/ENABLED=1/' /etc/default/stunnel4
systemctl enable --now stunnel4
systemctl restart stunnel4

echo "====================================================="
echo " Instalasi Selesai!"
echo "====================================================="
echo "Verifikasi port yang sedang berjalan (80, 443, 10015, 22):"
ss -tlnp | grep -E ':(80|443|10015|22)\b'

echo ""
echo "[*] Mengetes handshake port 80 secara internal..."
printf 'GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n\r\n' | timeout 3 nc 127.0.0.1 80 | head -2

echo ""
echo "VPS sudah siap digunakan untuk tunnel SSH-over-WebSocket."