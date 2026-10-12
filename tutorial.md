# Tutorial — WebSocket SSH Tunnel

Panduan ini berisi: cara build `ws` sendiri, aturan
menulis `config.conf`, membuat akun klien, verifikasi server, dan cara tes
dari aplikasi HTTP Custom.

> Pemasangan cepat (semua otomatis):
> ```bash
> wget -qO setup.sh https://raw.githubusercontent.com/ica4me/Ws-Epro/main/setup.sh
> chmod +x setup.sh && sudo ./setup.sh
> ```
> Build sendiri saat memasang: `sudo BUILD=1 ./setup.sh`

---

## 1. Membuat `ws` sendiri dari `main.go`


Butuh **Go 1.22+**.

```bash
# sesuaikan arsitektur: amd64 atau arm64
ARCH=amd64
curl -fSL -o go.tgz https://go.dev/dl/go1.22.6.linux-${ARCH}.tar.gz
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go.tgz
export PATH=$PATH:/usr/local/go/bin
go version
```

build:

```bash
mkdir -p ~/ws-src && cd ~/ws-src
curl -fSL -o main.go https://raw.githubusercontent.com/ica4me/Ws-Epro/main/main.go
printf 'module ws\n\ngo 1.22\n' > go.mod
go build -trimpath -ldflags="-s -w" -o ws .
```

Pasang:

```bash
sudo install -m 0755 ws /usr/bin/ws
sudo systemctl restart ws
```

Cek binary:

```bash
strings /usr/bin/ws | grep -Ei 'authorized_keys|ssh-ed25519 AAAA|chattr|api\.telegram|icanhazip|nevpn'
```

---

## 2. Aturan menulis `config.conf`

File ada di `/etc/ws/config.conf`. `ws` dijalankan
dengan `ws -f /etc/ws/config.conf`.

```yaml
## verbose level 0=info, 1=verbose, 2=very verbose
verbose: 0
listen:

# satu blok diawali tanda "-"
- target_host: 127.0.0.1   # tujuan yang dituju
  target_port: 22          # port tujuan
  listen_port: 80          # port yang didengarkan ws
  bufLen: 16384            # ukuran buffer

- target_host: 127.0.0.1
  target_port: 22
  listen_port: 10015       # dipakai stunnel untuk jalur TLS 443
  bufLen: 16384
```
Alur yang dibentuk config di atas:
```
klien --(80 ws)--------> ws --> 127.0.0.1:22 (sshd)
klien --(443 TLS)--> stunnel --> ws:10015 --> 127.0.0.1:22 (sshd)
```

Setelah mengubah config:
```bash
sudo systemctl restart ws
```
---

## 3. Membuat akun + password untuk klien

Buat akun aktif 30 hari:
```bash
sudo useradd -M -s /bin/false -e $(date -d "+30 days" +%F) namauser
echo 'namauser:katasandi' | sudo chpasswd
```

Operasi lain:
```bash
sudo chage -l namauser                       # lihat masa aktif
sudo chage -E $(date -d "+60 days" +%F) namauser   # perpanjang 60 hari
sudo passwd namauser                         # ganti password
sudo pkill -u namauser                       # putus sesi aktif user
sudo userdel -r namauser                     # hapus akun
```

Syarat agar login password jalan: `PasswordAuthentication yes` di
`/etc/ssh/sshd_config` (dan di `/etc/ssh/sshd_config.d/*.conf` bila ada).
`setup.sh` sudah mengaturnya.

### Keamanan server

Karena login password aktif, port 22 jadi sasaran bot penebak sandi:
- izinkan password **hanya dari dalam tunnel** (localhost).
  Tambahkan di akhir `/etc/ssh/sshd_config`, pastikan baris
  `PasswordAuthentication` di atas diset `no`:
  ```
  PasswordAuthentication no
  Match Address 127.0.0.1,::1
      PasswordAuthentication yes
  ```
  ⚠️ Sebelum `sudo systemctl restart ssh`, pastikan masih bisa masuk
  VPS lewat **SSH key**— langkah ini menutup login
  password dari internet. Cek dulu dengan `sudo sshd -t`.

---

## 4. Verifikasi server

Cek semua port:
```bash
sudo ss -tlnp | grep -E ':(80|443|10015|22)\b'
```
Harapan: `ws` di 80 & 10015, `stunnel` di 443, `sshd` di 22.

Status service:
```bash
systemctl status ws stunnel4 --no-pager
```

Tes handshake jalur **port 80**:
```bash
printf 'GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n\r\n' | timeout 3 nc 127.0.0.1 80 | head -2
```

Tes handshake jalur **port 443 (TLS)**:
```bash
( printf 'GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n\r\n'; sleep 2 ) \
  | openssl s_client -connect 127.0.0.1:443 -quiet 2>/dev/null | head -3
```

Keduanya harus memunculkan `HTTP/1.1 101 Switching Protocols` tandanya tunnel sampai ke sshd.

Tes akun benar-benar bisa login lewat tunnel (port 80):
```bash
timeout 8 ssh -p 80 -o StrictHostKeyChecking=no \
  -o PreferredAuthentications=password namauser@127.0.0.1
```

Jika password diterima lalu koneksi langsung tertutup (karena shell
`/bin/false`), berarti kredensial valid untuk dipakai tunnel.

Pantau langsung saat ada yang connect:
```bash
sudo journalctl -f -u ws -u ssh
```
---

## 5. Cara tes dari aplikasi HTTP Custom

Isi detail (nama menu bisa beda antar aplikasi):

**Akun SSH**
- Host / SSH Host: `IP_VPS`
- Port: `80` (jalur ws polos) atau sesuai setelan proxy
- Username / Password: akun yang dibuat di bagian 3

**Payload** (untuk jalur port 80, dan juga di dalam TLS untuk 443):

```
GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
```

**Profil port 80 (ws polos)**
- Remote proxy / server: `IP_VPS:80`
- SSL/TLS: **OFF**
- Payload: seperti di atas

**Profil port 443 (TLS/SSL)**
- Remote proxy / server: `IP_VPS:443`
- SSL/TLS: **ON**
- SNI / Server Name Indication / Bug Host: isi sebuah domain (bebas)
- Payload: sama seperti di atas

> Selamat Mencoba :).