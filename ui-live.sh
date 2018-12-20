#!/bin/bash
dmesg -n 1
sleep 2
export NEWT_COLORS='root=,blue'

function listBox {
    #[question] [action text] Ask and store result into answer variable.
    question="$1"
    tmpfile="/tmp/$RANDOM$RANDOM"
    shift
    whiptail --title "icl-backup live" --menu "$question" 0 0 0 "$@" 2> "$tmpfile"
    status="$?"
    answer="$(cat "$tmpfile")"
    rm "$tmpfile"
    return $status
}

function yesNo {
    #[question]
    whiptail --title "icl-backup live" --yesno "$1" 0 0
    return $?
}

function passwordBox {
    #[question] Password will be saved to answer.
    tmpfile="/dev/shm/$RANDOM$RANDOM"
    whiptail --title "icl-backup live" --nocancel --passwordbox "$1" 8 50 2> "$tmpfile"
    answer="$(cat "$tmpfile")"
    rm "$tmpfile"
}

function inputBox {
    #[question] [initial] Answer will be saved to answer.
    tmpfile="/tmp/$RANDOM$RANDOM"
    whiptail --title "icl-backup live" --inputbox "$1" 0 0 "$2" 2> "$tmpfile"
    status="$?"
    answer="$(cat "$tmpfile")"
    rm "$tmpfile"
    return $status
}

function e {
    NEWT_COLORS='root=,red' whiptail --title "icl-backup" --msgbox "$1" 0 0
}

function checkDev {
    #[device] [reason] in mount, format, backup
    # Check if a drive is suitable for a purpose.
    # Store description into desc.
    action="$2"
    grep -q "$1" /proc/mounts && return 1

    if [[ -e "/dev/mapper/iclbkrepo" ]]
    then
        repoloc=$(cryptsetup status iclbkrepo | grep device)
        grep -q "$1" <<< "$repoloc" && return 1
    fi

    size=$(echo "$(blockdev --getsize64 "$1")/(1024^3)" | bc)
    [[ "$size" -lt "7" ]] && return 1

    fsType=$(blkid "$1" | sed 's/.* TYPE="\([^"]*\).*/\1/g' | grep -v '/dev/')
    ptType=$(blkid "$1" | sed 's/.*PTTYPE="\([^"]*\).*/\1/g' | grep -v '/dev/')
    label=$(blkid "$1" | sed 's/.*LABEL="\([^"]*\).*/\1/g' | grep -v '/dev/')
    model=$(hdparm -I "$1" | grep 'Model Number' | sed 's/.*Model Number:[^A-Za-z0-9]\(.*\)/\1/g')

    if ! grep -q "^/dev/[a-z]*$" <<< "$1"
    then
        [[ "$action" == "backup" ]] && return 1
        [[ "$ptType" == "dos" ]] && return 1
    fi

    if [[ "$action" == "mount" ]]
    then
        [[ "$fsType" == "swap" ]] && return 1
        [[ "$fsType" == "lvm2" ]] && return 1
        [[ "$ptType" == "dos" ]] && return 1
    fi

    desc=$(echo "${size}G_${label}_${fsType}_$model" | tr ' ' _ | tr -s '_' | sed 's/_$//g')
}

function getDrives {
    #[reason] [text] Get a list of drives/partitions for use.
    # Result is stored in answer along with description is desc.
    items=""
    for device in $(cat /proc/partitions | grep '\(hd\|sd\)[a-z]' | tr -s ' ' | cut -d ' ' -f 5)
    do
        if checkDev "/dev/$device" "$1"
        then
            items="$items $device $desc"
        fi
    done

    if [[ "$items" == "" ]]
    then
        return 1
    fi

    listBox "$2" $items || return 1
    answer="/dev/$answer"
    checkDev "$answer" "$1"
}

function doShutdown {
    poweroff
    #exit
}

function doCommand {
    echo "When you are done, type exit or press CTRL+D."
    bash
}

function doFormat {
    umount /mnt
    cryptsetup luksClose iclbkrepo
    vgchange -an
    for c in $(ls /dev/mapper/bk*)
    do
        cryptsetup luksClose "$c"
    done
    getDrives format $'Please select a drive to format and use for encrypted backup storage.\n\nTHIS WILL DELETE EVERYTHING ON THE DRIVE!' || return
    disk="$answer"
    yesNo $'You are about to delete everything on '"$disk ($desc)"$'!\n\nAre you sure?' || return
    while true
    do
        passwordBox "Please enter an encryption passphrase."
        password="$answer"
        passwordBox "Please enter the passphrase again."
        [[ "$password" == "$answer" ]] && break
    done
    echo "$password" | cryptsetup luksFormat -q "$disk"
    echo "$password" | cryptsetup luksOpen "$disk" iclbkrepo
    mkfs.ext4 /dev/mapper/iclbkrepo
    cryptsetup luksClose iclbkrepo
    partprobe
    sleep 3
}

function mountSelect {
    # [allowCreate] Mount repo to /mnt and get chain name.
    keepMount="false"
    if grep -q ' /mnt ' /proc/mounts
    then
        if yesNo "Use already mounted /mnt?"
        then
            keepMount="true"
        else
            umount /mnt
            cryptsetup luksClose iclbkrepo
        fi
    fi
    vgchange -an
    for c in $(ls /dev/mapper/bk*)
    do
        cryptsetup luksClose "$c"
    done
    if [[ "$keepMount" == "false" ]]
    then
        getDrives mount "Please select a drive to use as backup storage. This will NOT erase the drive."$'\n\n'"If a drive is not marked as crypto_LUKS, backups stored to it will not be encrypted."$'\n'"Use Format from the main menu to use a drive as an encrypted repository." || return 1
        disk="$answer"
        if [[ "$fsType" == "crypto_LUKS" ]]
        then
            passwordBox "Please enter the passphrase for $disk."
            echo "$answer" | cryptsetup luksOpen "$disk" iclbkrepo
            if [[ "$?" != "0" ]]
            then
                e "Unable to mount disk. Wrong passphrase?"
                return 1
            fi
            mount /dev/mapper/iclbkrepo /mnt
            if [[ "$?" != "0" ]]
            then
                e "Unable to mount disk. Bad filesystem or LVM?"
                return 1
            fi
        else
            mount "$disk" /mnt
            if [[ "$?" != "0" ]]
            then
                e "Unable to mount disk. Bad filesystem?"
                return 1
            fi
        fi
    fi
    options=""
    for option in $(ls /mnt/icl-backup-repo/zb/backups)
    do
        options="$options $option Use_group_$option"
    done
    if [[ "$1" == "true" ]]
    then
        listBox "Please select a backup group, or select Create to make a new one." $options "Create" "Create a new backup group." || return 1
        if [[ "$answer" == "Create" ]]
        then
            inputBox "Please enter the name for the backup group."$'\n\n'"Backup groups are intended to be used to keep track of which computer"$'\n'"backups belong to, but they can be used for anything." || return 1
            answer=$(echo "$answer" | tr ' ' _)
            if [[ "$answer" == "" ]]
            then
                e "No backup group name was provided!"
                return 1
            fi
        fi
        chain="$answer"
    else
        if [[ "$options" == "" ]]
        then
            e "There are no backup groups on this disk!"
            return 1
        fi

        listBox "Please select a backup group." $options || return 1
        chain="$answer"
    fi
}

function doBackup {
    mountSelect true || return 1
    inputBox "Please enter a name for the backup." "$(date +%FT%R)" || return 1
    backup=$(echo "$answer" | tr ' ' _)
    if [[ "$backup" == "" ]]
    then
        e "Backup name was blank!"
        return 1
    fi
    getDrives backup "Please select the disk to backup." || return 1
    disk="$answer"
    whiptail --title "icl-backup live" --yesno "Would you like to use fast deduplication or thorough deduplication?"$'\n\n'"Fast deduplication backups up at several gigabytes per second, but additional backups will use more space."$'\n'"Thorough deduplication can take days on large disks, but usage by further backups is significantly reduced."$'\n\n'"Fast and thorough backups are completely seperate. 2 backups using both methods is equal to 2 full backups." 0 0 --yes-button "Fast" --no-button "Thorough"

    if [[ "$?" == "0" ]]
    then
        mode="fast"
    else
        mode="normal"
    fi

    yesNo "Are you sure you want to create a backup of $disk ($desc) called $backup? (In group $chain?)" || return 1
    backup-create.sh "$disk" "/mnt/icl-backup-repo" "$chain/$backup" "$mode"
}

function doRestore {
    mountSelect || return 1
    options=""
    for backup in $(ls /mnt/icl-backup-repo/zb/backups/$chain/)
    do
        options="$options $backup Restore_$backup"
    done
    if [[ "$options" == "" ]]
    then
        e "There are no backups in this group!"
        return 1
    fi
    listBox "Please select a backup to restore. (From group $chain.)" $options || return 1
    backup="$answer"
    getDrives backup "Please select the disk to erase and restore the backup to." || return 1
    disk="$answer"
    yesNo "Are you sure you want to restore $backup (from $chain) to $disk ($desc)?"$'\n\n'"THIS WILL DELETE EVERYTHING ON THE TARGET DRIVE!" || return 1
    backup-restore.sh "/mnt/icl-backup-repo" "$chain/$backup" "$disk"
    partprobe
    sleep 3
}

function doDelete {
    mountSelect || return 1
    options=""
    for backup in $(ls /mnt/icl-backup-repo/zb/backups/$chain/)
    do
        options="$options $backup Delete_$backup"
    done
    if [[ "$options" == "" ]]
    then
        e "There are no backups in this group!"
        return 1
    fi
    listBox "Please select a backup to delete. (From group $chain.)" $options || return 1
    yesNo "Are you sure you want to delete $answer from $chain?" || return 1

    repo="/mnt/icl-backup-repo"

    if [[ -e "$repo/dd/" ]]
    then
        ddumbfs -o parent="$repo/df" "$repo/dd" || e "Could not mount ddumbfs."
        rm -r "$repo/dd/$chain/$answer/"
    fi

    rm -r "$repo/zb/backups/$chain/$answer/"
    rm -r "$repo/$chain/$answer/"

    zbackup gc --non-encrypted "$repo/zb"

    if [[ -e "$repo/dd/" ]]
    then
        cat "$repo/dd/.ddumbfs/reclaim"
        umount "$repo/dd"
    fi
}

while true; do

listBox $'Welcome to icl-backup!\n\nPlease select an action to begin.' \
"Backup" "Create a backup of a disk." \
"Restore" "Restore a backup to a disk." \
"Delete" "Delete a backup." \
"Format" "Format a drive to store encrypted backups." \
"Command" "Drop into command line." \
"Shutdown" "Shutdown the computer." || doShutdown

case $answer in
    Backup) doBackup;;
    Restore) doRestore;;
    Delete) doDelete;;
    Format) doFormat;;
    Command) doCommand;;
    Shutdown) doShutdown;;
esac

done

