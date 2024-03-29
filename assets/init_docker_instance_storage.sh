#!/bin/bash
# To run on first boot of an EC2 instance with NVMe instance storage volumes:
# 1) Assembles them into a RAID0 array, formats with XFS, and mounts to /mnt/scratch
# 2) Replaces /var/lib/docker with a symlink to /mnt/scratch/docker so that docker images and
#    container file systems use this high-performance scratch space. (restarts docker)
# The configuration persists through reboots (but not instance stop).
# logs go to /var/log/cloud-init-output.log
# refs:
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ssd-instance-store.html
# https://github.com/kislyuk/aegea/blob/master/aegea/rootfs.skel/usr/bin/aegea-format-ephemeral-storage

set -euxo pipefail
shopt -s nullglob


devices=(/dev/xvd[b-m] /dev/disk/by-id/nvme-Amazon_EC2_NVMe_Instance_Storage_AWS?????????????????)
num_devices="${#devices[@]}"
if (( num_devices > 0 )) && ! grep /dev/md0 <(df); then
    mdadm --create /dev/md0 --force --auto=yes --level=0 --chunk=256 --raid-devices=${num_devices} ${devices[@]}
    mkfs.xfs -f /dev/md0
    mkdir -p /mnt/scratch
    mount -o defaults,noatime,largeio,logbsize=256k -t xfs /dev/md0 /mnt/scratch
    echo UUID=$(blkid -s UUID -o value /dev/md0) /mnt/scratch xfs defaults,noatime,largeio,logbsize=256k 0 2 >> /etc/fstab
    update-initramfs -u
fi
mkdir -p /mnt/scratch/tmp


systemctl stop docker || true
if [ -d /var/lib/docker ] && [ ! -L /var/lib/docker ]; then
    mv /var/lib/docker /mnt/scratch
fi
mkdir -p /mnt/scratch/docker
ln -s /mnt/scratch/docker /var/lib/docker
systemctl restart docker || true
