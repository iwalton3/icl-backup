#!/bin/bash
#[disk] [repo] [name]
NEWT_COLORS='root=,blue'
set -o pipefail

disk="$1"
repo="$2"
location="$3"
mode="$4"

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

function e {
    NEWT_COLORS='root=,red' whiptail --title "icl-backup" --yesno --defaultno "$1"$'\n\n'"Would you like to continue anyway? (NOT RECOMMENDED!)" 0 0 || exit 1
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

function partName {
    #[partition]
    sed -e 's/\/dev\/sd[a-z]*//g' -e 's/\/dev\/mapper\///g' -e 's/\/dev\///g' -e 's/\//-/g' <<< "$1"
}

function processLuks {
    #[partition] Enable and backup LUKS.
    cryptsetup luksHeaderBackup "$1" --header-backup-file "${bkds}luks-$(partName "$1")" || e "Could not backup LUKS $1."
    passwordBox "Please enter passphrase for $1." || e "User canceled on passphrase."
    echo "$answer" | cryptsetup luksOpen "$1" "bk$(partName "$1")" || e "Could not open $1."
    scanPart "/dev/mapper/bk$(partName "$1")"
}

function processLvm {
    #[partition] Enable and backup LVM.
    vuuid=$(pvdisplay "$1" | grep UUID | tr -s ' ' | cut -d ' ' -f 4)
    echo "$vuuid" > "${bkds}lvmid-$(partName "$1")"
    vgroup=$(pvscan | grep -F "$1" | sed 's/.*VG \([^ ]*\).*/\1/g')
    echo "$vgroup" > "${bkds}lvmvg-$(partName "$1")"
    vgscan --mknodes
    vgchange -ay
    vgcfgbackup "$vgroup" -f "${bkds}lvmbk-$(partName "$1")" || e "Could not back up LVM $1."
    find /dev/$vgroup/ -not -type d > "${bkds}lvml-$(partName "$1")"
    for fs in $(find /dev/$vgroup/ -not -type d)
    do
        scanPart "$fs"
    done
}

function scanPart {
    #[partition] Add partition to list based on type.

    fstype=$(pType "$1")
    if [[ "$fstype" == "crypto_LUKS" ]]
    then
        echo "Found LUKS $1"
        echo "c$1" >> "${bkds}container-tree"
        processLuks "$1"
    elif [[ "$fstype" == "ptdos" ]]
    then
        echo "Processing extended partition $fs"
        dd if="$fs" of="${bkds}ept-bootloader" bs=512 count=1 status=none || e "Could not backup extended bootloader."
        echo "$fs" | sed 's/[^0-9]//g' > "${bkds}ept-disk"
    elif [[ "$fstype" == "LVM2_member" ]]
    then
        echo "Found LVM $1"
        echo "l$1" >> "${bkds}container-tree"
        processLvm "$1"
    elif [[ "$fstype" == "swap" ]]
    then
        echo "Found swap space $1"
        echo "$1" >> "${bkds}swap-partitions"
        blkid "$1" | tr ' ' '\n' | grep UUID | cut -d'"' -f 2 > "${bkds}swap-$(partName "$1")"
    elif [[ -f "/usr/sbin/partclone.$fstype" ]]
    then
        echo "Found regular ($fstype) partition $1"
        echo "$1" >> "${bkds}regular-partitions"
    else
        echo "Found raw ($fstype) partition $1"
        echo "$1" >> "${bkds}raw-partitions"
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

mkdir -p "$repo/$location"

if [[ ! -e "$repo/zb" ]]
then
    zbackup init --compression lzo --non-encrypted "$repo/zb" || e "Could not initialize. Are you running a good zbackup?"
fi

if [[ ! -e "$repo/dd" ]]
then
    free=$(df -BM "$repo" | tr -s ' ' | cut -d ' ' -f 4 | tr -d '[A-Za-z]\n')
    mkdir "$repo/df" "$repo/dd"
    mkddumbfs -s "${free}M" -a "$repo/df"
fi

ddumbfs -o parent="$repo/df" "$repo/dd" || e "Could not mount ddumbfs."

bkds="$repo/$location/"

> "${bkds}regular-partitions"
> "${bkds}swap-partitions"
> "${bkds}container-tree"

if gdisk -l "$disk" | grep -q "GPT: not present"
then
    echo "Disk type is MBR."
    hstop=$(parted -s "$disk" unit s print | grep ' [0-9]\+.*[0-9]\+s.*s.*s' | sed 's/^ [0-9]\|  *\([0-9]\+\)s.*/\1/g' | sort -n | head -n 1)
    if [[ "$hstop" -gt "20480" ]]
    then
        hsize="4096"
    else
        hsize=$((hstop-1))
    fi
    if [[ "$hsize" != "0" ]]
    then
        echo "$hsize" > "${bkds}hidden-size"
        dd if="$disk" of="${bkds}hidden-area" bs=512 skip=1 count="$hsize" status=none || e "Could not backup hidden area."
    fi
else
    echo "Disk type is GPT."
    sgdisk --backup "${bkds}gpt-table" "$disk" || e "Could not backup GPT table."
fi

sfdisk -d "$disk" > "${bkds}mbr-table" || e "Could not backup MBR table."
dd if="$disk" of="${bkds}bootloader" bs=512 count=1 status=none || e "Could not back up bootloader."

for fs in $(find /dev | grep "^$disk[0-9]");
do
    scanPart "$fs"
done

mkdir -p "$repo/zb/backups/$location"
mkdir -p "$repo/dd/$location"

for fs in $(cat "${bkds}regular-partitions")
do
    if [[ "$mode" == "fast" ]]
    then
        fastCopySparse "$fs" "$repo/dd/$location/$(partName "$fs")-image"
    else
        fstype=$(pType "$fs")
        partclone.$fstype -cN -s "$fs" -o - | zbackup backup --non-encrypted "$repo/zb/backups/$location/$(partName "$fs")-image" &>/dev/null || e "Could not backup $fs. (partclone.$fstype)"
    fi
done

for fs in $(cat "${bkds}raw-partitions")
do
    if [[ "$mode" == "fast" ]]
    then
        fastCopySparse "$fs" "$repo/dd/$location/$(partName "$fs")-image"
    else
        partclone.dd -N -s "$fs" -o - | zbackup backup --non-encrypted "$repo/zb/backups/$location/$(partName "$fs")-image" &>/dev/null || e "Could not backup $fs. (partclone.dd)"
    fi
done

umount "$repo/dd"
