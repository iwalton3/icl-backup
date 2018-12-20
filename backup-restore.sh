#!/bin/bash
#[repo] [name] [dest]
NEWT_COLORS='root=,blue'
set -o pipefail

function ce {
    if ! which "$1" > /dev/null
    then
        echo "The following program is needed: $1"
        exit 1
    fi
}

ce sfdisk
ce gdisk
ce cryptsetup
ce vgchange
ce partclone.dd
ce zbackup

function yesNo {
    #[question]
    whiptail --title "icl-backup" --yesno "$1" 0 0
    return $?
}

function passwordBox {
    #[question] Password will be saved to answer.
    tmpfile="/dev/shm/$RANDOM$RANDOM"
    whiptail --title "icl-backup" --passwordbox "$1" 8 50 2> "$tmpfile"
    status="$?"
    answer="$(cat "$tmpfile")"
    rm "$tmpfile"
    return $status
}

repo="$1"
disk="$3"
location="$2"

if [[ ! -e "$disk" ]]
then
    echo "Partition does not exist!"
    exit 1
fi

# Confirmation should happen in ui-live.
#echo "You are about to overwrite $disk!"
#read -p "Are you sure? [y/N] " confirm
#if [[ "$confirm" != "y" ]]
#then
#    exit
#fi

function e {
    NEWT_COLORS='root=,red' whiptail --title "icl-backup" --yesno --defaultno "$1"$'\n\n'"Would you like to continue anyway? (NOT RECOMMENDED!)" 0 0 || exit 1
}

function pType {
    #[partition] Get type of partition.

    pttype=$(blkid "$1" | tr ' ' '\n' | grep 'PTTYPE' | cut -d'"' -f 2)
    type=$(blkid "$1" | tr ' ' '\n' | grep '^TYPE' | cut -d'"' -f 2)
    if [[ "$type" == "" ]]
    then
        echo "pt$pttype"
    else
        echo "$type"
    fi
}

function fastCopySparse {
    # [Source] [Destination] Copy sparse filesystem.
    fstype=$(pType "$1")

    if [[ -f "/usr/sbin/partclone.$fstype" ]]
    then
        if [[ ! -e "$2" ]]
        then
            size=$(blockdev --getsize64 "$1")
            truncate -s "$size" "$2"
        fi
        partclone.$fstype -bN -s "$1" --overwrite "$2" || e "Could not copy $1 ($fstype)."
    else
        partclone.dd -Ns "$1" -o "$2" || e "Could not copy $1 (raw)."
    fi
}

function partName {
    #[partition]
    sed -e 's/\/dev\/sd[a-z]*//g' -e 's/\/dev\/mapper\///g' -e 's/\/dev\///g' -e 's/\//-/g' <<< "$1"
}

function processLuks {
    #[partition] Enable and restore LUKS.
    cryptsetup luksHeaderRestore -q "$fs" --header-backup-file "${bkds}luks-$(partName "$1")" || e "Could not restore LUKS $1."
    while true
    do
        passwordBox "Please enter passphrase for $1." || e "User canceled on passphrase."
        echo "$answer" | cryptsetup luksOpen "$1" "bk$(partName "$1")" && break
        if [[ -e "/dev/mapper/bk$(partName "$1")" ]]
        then
            break
        fi
    done
}

function processLvm {
    #[partition] Enable and restore LVM.
    dd if=/dev/zero of="$1" bs=512 count=16
    pvcreate --uuid "$(cat "${bkds}lvmid-$(partName "$1")")" --restorefile "${bkds}lvmbk-$(partName "$1")" "$1" || e "Could not create LVM $1."
    vgcfgrestore -f "${bkds}lvmbk-$(partName "$1")" "$(cat "${bkds}lvmvg-$(partName "$1")")" || e "Could not restore LVM $1."
    vgscan --mknodes
    vgchange -ay
}

bkds="$repo/$location/"

sfdisk "$disk" < "${bkds}mbr-table" || e "Could not restore MBR table."

if [[ -f "${bkds}gpt-table" ]]
then
    echo "Disk type is GPT."
    sgdisk --load-backup "${bkds}gpt-table" "$disk" || e "Could not restore GPT table."
fi

dd if="${bkds}bootloader" of="$disk" bs=446 count=1 || e "Could not restore bootloader."

if [[ -f "${bkds}ept-bootloader" ]]
then
    ept=$(cat "${bkds}ept-disk")
    if [[ "$ept" == "" ]]
    then
        echo "Cannot find original extended partition!"
        exit 1
    else
        dd if="${bkds}ept-bootloader" of="$disk$(cat "${bkds}ept-disk")" bs=446 count=1 || e "Could not restore extended bootloader."
    fi
fi

if [[ -f "${bkds}hidden-area" ]]
then
    dd if="${bkds}hidden-area" of="$disk" bs=512 count="$(cat "${bkds}hidden-size")" seek=1 || e "Could not restore hidden data."
fi

for line in $(cat "${bkds}container-tree")
do
    action="${line:0:1}"
    fs="${line:1}"

    if [[ "$action" == "c" ]]
    then
        processLuks "$fs"
    elif [[ "$action" == "l" ]]
    then
        processLvm "$fs"
    fi
done

if [[ -e "$repo/dd" ]]
then
    ddumbfs -o parent="$repo/df" "$repo/dd" || e "Could not mount ddumbfs."
fi

for fs in $(cat "${bkds}regular-partitions")
do
    if [[ "$(dirname "$fs")" == "/dev" ]]
    then
        fs=$(sed 's/[^0-9]*//g' <<< "$fs")
        fs="${disk}$fs"
    fi

    if [[ -e "$repo/zb/backups/$location/$(partName "$fs")-image" ]]
    then
        zbackup restore --non-encrypted "$repo/zb/backups/$location/$(partName "$fs")-image" 2>/dev/null | partclone.restore -Ns - -o "$fs" || e "Could not restore $fs."
    else
        fastCopySparse "$repo/dd/$location/$(partName "$fs")-image" "$fs"
    fi

    if [[ "$(pType "$fs")" == "ntfs" ]]
    then
        ntfsfix -d "$fs" || e "Could not fix NTFS status."
    fi
done

for fs in $(cat "${bkds}raw-partitions")
do
    if [[ "$(dirname "$fs")" == "/dev" ]]
    then
        fs=$(sed 's/[^0-9]*//g' <<< "$fs")
        fs="${disk}$fs"
    fi

    if [[ -e "$repo/zb/backups/$location/$(partName "$fs")-image" ]]
    then
        zbackup restore --non-encrypted "$repo/zb/backups/$location/$(partName "$fs")-image" 2>/dev/null | partclone.dd -Ns - -o "$fs" || e "Could not restore $fs."
    else
        fastCopySparse "$repo/dd/$location/$(partName "$fs")-image" "$fs"
    fi
done

for fs in $(cat "${bkds}swap-partitions")
do
    if [[ "$(dirname "$fs")" == "/dev" ]]
    then
        fs=$(sed 's/[^0-9]*//g' <<< "$fs")
        fs="${disk}$fs"
    fi
    mkswap -U "$(cat "${bkds}swap-$(partName "$fs")")" "$fs" || e "Could not make swap $fs."
done

if [[ -e "$repo/dd" ]]
then
    umount "$repo/dd"
fi
