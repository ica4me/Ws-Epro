# Manual Instalasi Ws (SSH over WebSocket)

Berisi langkah-langkah lengkap untuk mengatur tunnel SSH-over-WebSocket di VPS Ubuntu/Debian.

**Catatan:** Jalankan semua perintah di bawah ini sebagai `root`.

## 1. Pasang Binary ws dan Folder Config

Buat direktori, unduh binary bersih, dan berikan hak akses eksekusi.
```bash
sudo mkdir -p /etc/ws
cd /etc/ws
wget https://raw.githubusercontent.com/ica4me/Ws-Epro/main/ws
sudo chmod +x /usr/bin/ws
```

## 2. Siapkan Server SSH sebagai Target Tunnel

Gunakan OpenSSH bawaan (port 22). Aktifkan login password.
Alur tunnel: Klien → ws (80/443) → 127.0.0.1:22 (sshd).

```bash
sudo apt update && sudo apt install -y openssh-server
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

## 3. Konfigurasi (config.conf)

Buat file konfigurasi untuk mengatur routing port. Port 80 dilayani langsung oleh `ws`, sedangkan port 443 akan ditangani oleh stunnel.

```bash
sudo tee /etc/ws/config.conf >/dev/null <<'EOF'
## verbose level 0=info, 1=verbose, 2=very verbose
verbose: 0
listen:

# Port 80 (ws:// langsung) -> SSH
- target_host: 127.0.0.1
  target_port: 22
  listen_port: 80
  bufLen: 16384

# Port internal untuk dibungkus TLS oleh stunnel (443) -> SSH
- target_host: 127.0.0.1
  target_port: 22
  listen_port: 10015
  bufLen: 16384
EOF
```

## 4. Service Systemd

Buat service agar `ws` berjalan di latar belakang (daemon).
```bash
sudo tee /etc/systemd/system/ws.service >/dev/null <<'EOF'
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

sudo systemctl daemon-reload
sudo systemctl enable --now ws
sudo systemctl status ws --no-pager
```

## 5. Buka Firewall
```bash
sudo ufw allow 22,80,443/tcp 2>/dev/null || true
```

## 6. Buat Akun dan Password untuk Klien

Contoh ini membuat akun aktif selama 30 hari tanpa akses shell (hanya untuk tunnel).
```bash
sudo useradd -M -s /bin/false -e $(date -d "+30 days" +%F) user01
echo 'user01:pass01' | sudo chpasswd
```

## 7. Setup Port 443 (TLS/wss) via Stunnel

Karena `ws` hanya menggunakan TCP polos, enkripsi TLS di port 443 ditangani oleh Stunnel4.
Alur 443: Klien → TLS(443) → stunnel → 127.0.0.1:10015 (ws) → 127.0.0.1:22 (sshd).

```bash
sudo apt install -y stunnel4

# Buat sertifikat self-signed
sudo openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
  -subj "/CN=myvpn" -keyout /tmp/k.pem -out /tmp/c.pem
sudo bash -c 'cat /tmp/c.pem /tmp/k.pem > /etc/stunnel/stunnel.pem'
sudo chmod 600 /etc/stunnel/stunnel.pem
sudo rm -f /tmp/k.pem /tmp/c.pem

# Konfigurasi Stunnel
sudo tee /etc/stunnel/stunnel.conf >/dev/null <<'EOF'
pid = /var/run/stunnel.pid
[ws-tls]
accept = 443
connect = 127.0.0.1:10015
cert = /etc/stunnel/stunnel.pem
EOF

# Aktifkan dan jalankan Stunnel4
sudo sed -i 's/^ENABLED=0/ENABLED=1/' /etc/default/stunnel4
sudo systemctl enable --now stunnel4
sudo systemctl restart stunnel4
```

## 8. Verifikasi di Server

Cek port yang berjalan:
```bash
sudo ss -tlnp | grep -E ':(80|443|10015|22)\b'
```

Untuk melihat log secara real-time (aktifkan verbose level 2 jika perlu debugging):
```bash
sudo sed -i 's/^verbose:.*/verbose: 2/' /etc/ws/config.conf
sudo systemctl restart ws
sudo journalctl -u ws -f
# Di terminal lain, cek log stunnel:
sudo journalctl -u stunnel4 -f
```

---

## Testing Koneksi dari Klien (APK HTTP Custom)

Gunakan pola berikut pada aplikasi HTTP Custom (atau aplikasi serupa yang mendukung payload HTTP tanpa `Sec-WebSocket-Key`):

*   **Host/Server SSH:** `IP_VPS`
*   **Port SSH:** `80`
*   **Username:** `user01`
*   **Password:** `pass01`
*   **Payload:**
```text
GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
```