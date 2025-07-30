# 1. Create the VM shell
qm create 100 \
  --name pfsense \
  --memory 4096 \
  --cores 2 \
  --boot order=scsi0 \
  --scsihw virtio-scsi-pci
  --cpu host

# 2. Add NICs
qm set 100 --net0 virtio=00:50:56:00:52:FF,bridge=vmbr0
qm set 100 --net1 virtio,bridge=vmbr1

# 3. Add disk
qm set 100 --scsi0 local-zfs:64,discard=on,ssd=1

# 4. Attach ISO
qm set 100 --cdrom local:iso/pfSense-CE-2.7.2-RELEASE-amd64.iso

# 5. Enable serial console
qm set 100 --vga std



### TEST VM
qm create 200 \
  --name lan-test \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=vmbr1 \
  --scsihw virtio-scsi-pci
qm set 200 --scsi0 local-zfs:16
qm set 200 --cdrom local:iso/debian-live-12.5.0-xfce.iso --boot order=scsi0
qm start 200

ip addr add 192.168.1.10/24 dev vmbr1
ssh -L 8443:192.168.1.1:443 root@162.55.85.59



# App vm
cd /var/lib/vz/template/iso
wget https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso

qm create 200 --name pvapp-prod --memory 16384 --cores 6 --net0 virtio,bridge=vmbr1 --cpu host
qm set 200 --scsihw virtio-scsi-pci 
qm set 200 --scsi0 local-zfs:128
qm set 200 --scsi1 media:7000
qm set 200 --ide2 local:iso/ubuntu-24.04.2-live-server-amd64.iso,media=cdrom
qm set 200 --boot "order=ide2;scsi0"
qm start 200


# After install
qm set 200 --delete ide2
qm set 200 --boot order=scsi0

sudo mkfs.ext4 -F /dev/sda
94b7f661-f2ef-4bdd-b0c5-eb9c27de9baa


# install node exporter
sudo useradd --no-create-home --shell /usr/sbin/nologin node_exporter
cd /tmp
wget https://github.com/prometheus/node_exporter/releases/download/v1.9.1/node_exporter-1.9.1.linux-amd64.tar.gz
tar xvf node_exporter-1.9.1.linux-amd64.tar.gz
sudo mv node_exporter-1.9.1.linux-amd64/node_exporter /usr/local/bin/
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter


sudo tee /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable node_exporter
sudo systemctl start node_exporter
sudo systemctl status node_exporter

# cadvisor
services:
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: cadvisor
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro

sudo apt install qemu-guest-agent -y

# postgres vm
qm create 300 --name db-pvapp-prod --memory 16384 --cores 4 --net0 virtio,bridge=vmbr1 --cpu host
qm set 300 --scsihw virtio-scsi-pci 
qm set 300 --scsi0 local-zfs:64
qm set 300 --scsi1 local-zfs:200
qm set 300 --ide2 local:iso/ubuntu-24.04.2-live-server-amd64.iso,media=cdrom
qm set 300 --boot "order=ide2;scsi0"
qm start 300

sudo mkfs.ext4 -F /dev/sdb


# vpn
wg genkey | tee surya-macbook-private.key | wg pubkey > surya-macbook-public.key

# observability vm
qm create 400 --name obs-pvapp-prod --memory 8192 --cores 4 --net0 virtio,bridge=vmbr1 --cpu host
qm set 400 --scsihw virtio-scsi-pci 
qm set 400 --scsi0 local-zfs:64
qm set 400 --ide2 local:iso/ubuntu-24.04.2-live-server-amd64.iso,media=cdrom
qm set 400 --boot "order=ide2;scsi0"
qm start 400

### observability
version: '3.8'

services:
  grafana:
    image: grafana/grafana:11.2.0
    container_name: grafana
    ports:
      - "3000:3000"       # Grafana UI
    volumes:
      - ./grafana:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=supersecret
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:v2.55.0
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus:/etc/prometheus
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.retention.time=30d'
    restart: unless-stopped

  loki:
    image: grafana/loki:3.1.1
    container_name: loki
    ports:
      - "3100:3100"
    volumes:
      - ./loki:/etc/loki
      - loki_data:/loki
    command: -config.file=/etc/loki/loki-config.yaml
    restart: unless-stopped

  promtail:
    image: grafana/promtail:3.1.1
    container_name: promtail
    volumes:
      - /var/log:/var/log         # Collect system logs
      - ./promtail:/etc/promtail
    command: -config.file=/etc/promtail/promtail-config.yaml
    restart: unless-stopped

volumes:
  prometheus_data:
  loki_data:
