/etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

parted /dev/nvme0n1
mkpart special zfs 913GB 963GB
mkpart l2arc zfs 963GB 1024GB
quit

parted /dev/nvme1n1
mkpart special zfs 913GB 963GB
mkpart l2arc zfs 963GB 1024GB
quit

zpool create -f -o ashift=12 \
  -O compression=lz4 \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  media mirror /dev/sda /dev/sdb

zfs set recordsize=1M media

# Add special vdev (mirrored)
zpool add media special mirror /dev/nvme0n1p4 /dev/nvme1n1p4

# Ensure metadata-only
zfs set special_small_blocks=0 media

# Add L2ARC (cache devices, not mirrored)
zpool add media cache /dev/nvme0n1p5 /dev/nvme1n1p5
