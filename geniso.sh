#!/bin/bash
(
    cd $HOME/live_boot
    rm image/live/filesystem.squashfs
    sudo mksquashfs chroot image/live/filesystem.squashfs -e boot
)

genisoimage \
    -rational-rock \
    -volid "ICL-Backup Live" \
    -cache-inodes \
    -joliet \
    -hfs \
    -full-iso9660-filenames \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -output $HOME/live_boot/icl-backup-live.iso \
    $HOME/live_boot/image

