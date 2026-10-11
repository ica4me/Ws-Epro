#!/bin/bash
# Hapus script setelah dijalankan
rm -- "$0"

echo "Mempersiapkan instalasi Ws-Epro..."
# Hentikan service jika sedang berjalan
systemctl stop ws.service 2>/dev/null

# Simpan IP VPS
curl -sS ipv4.icanhazip.com > /usr/bin/.ipvps

# URL Raw dari repositori ica4me
REPO="https://raw.githubusercontent.com/ica4me/Ws-Epro/main/"

# Buat direktori konfigurasi
mkdir -p /etc/ws

# Unduh binary ws, config, dan file service systemd
wget -O /usr/bin/ws "${REPO}ws"
wget -O /etc/ws/config.conf "${REPO}config.conf"
wget -O /etc/systemd/system/ws.service "${REPO}ws.service"

# Berikan hak akses eksekusi pada binary ws
chmod +x /usr/bin/ws

# Muat ulang daemon systemd dan aktifkan service
systemctl daemon-reload
systemctl enable ws.service
systemctl start ws.service
systemctl restart ws.service

echo "Instalasi Ws-Epro selesai!"
echo "Status service:"
systemctl status ws.service --no-pager