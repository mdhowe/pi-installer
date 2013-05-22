#!/bin/bash
set -e

[ -e common.sh ] &&
    . common.sh

NEW_HOSTNAME=$1
DEVICE=$2

######################################################################
# Customize these:
######################################################################
# Set the following to false (eg "" or 0) to disable them
USE_KERBEROS=1

USE_CONFIGTOOL=1
USE_DEBIAN_KEYRING=1
USE_LOCAL_CERT=1
USE_LOCAL_KEYRING=1
USE_PACKAGED_KERNEL=1
WRITE_IMAGE=1
DD_DEVICE=0

# Tweak the following as necessary

RELEASE="wheezy"
BASE_DIR="/mnt/scratch/raspbian"
DOMAIN="internal.michaelhowe.org"
KRB5_REALM="MICHAELHOWE.ORG"
TEMP_ROOT_PASSWORD="test"

MIRROR="http://mirror.internal.michaelhowe.org:3142/mirror.ox.ac.uk/sites/archive.raspbian.org/archive/raspbian"
DEBOOTSTRAP_DIR="${BASE_DIR}/debootstrap"

LOCAL_CERT="/usr/local/share/ca-certificates/MichaelSecurePlaces.crt"
TARGET_CERT_DIR="${DEBOOTSTRAP_DIR}/usr/local/share/ca-certificates"

APT_GPG_PARTS="/etc/apt/trusted.gpg.d"

ARCHIVE_KEYRING="${APT_GPG_PARTS}/mh-archive-michaelhowe.org.gpg"

DEBIAN_ARCHIVE_KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
RPI_KEY="http://archive.raspberrypi.org/debian/raspberrypi.gpg.key"
RPI_KEY_SHA256="76603890d82a492175caf17aba68dc73acb1189c9fd58ec0c19145dfa3866d56"
RASPBIAN_KEY="http://archive.raspbian.org/raspbian.public.key"
RASPBIAN_KEY_SHA256="886b3a94c1000356535cc7e7404696f93b43278c0983c3f0fa81f1f17466c435"

GIT_FIRMWARE_URL="https://github.com/raspberrypi/firmware.git"
GIT_FIRMWARE_DIR="${BASE_DIR}/firmware"
GIT_KERNEL_URL="https://github.com/raspberrypi/linux.git"
GIT_KERNEL_DIR="${BASE_DIR}/linux"

TEMPDIR="/tmp"
LOCALES_SELECTED="en_GB.UTF-8"
LOCALES_GENERATED="en_GB.UTF-8 UTF-8"

######################################################################
# Things below here should not need modification
######################################################################
set -u

# To keep the xen-tools things happy:
verbose=1

# Work-arounds to keep things quiet:
OLD_LANG=$LANG
unset LANG
export LC_ALL=C

# Check we're running as root (or lots of things will fail):
if [[ $(/usr/bin/id -u) -ne 0 ]]; then
    echo "Error: script must be run as root" >&2
    exit 1
fi

if [ -z "$NEW_HOSTNAME" ]; then
    echo "Usage: $0 hostname /dev/of/sdcard" >&2
    exit 1
fi

APP_TEMPDIR=`mktemp -d ${TEMPDIR}/pi-installer.XXXXXXXX`
export APP_TEMPDIR

cleanup ()
{
    enableStartStopDaemon "${DEBOOTSTRAP_DIR}" || true
    umountProc "${DEBOOTSTRAP_DIR}" || true
}
cleanup_err()
{
    cleanup
    echo "Command failed, cleaning up.  You need to manually remove '${APP_TEMPDIR}' yourself" >&2
}

trap 'cleanup_err' EXIT

echo "Downloading raspbian GPG key"
downloadGPGKey "${RASPBIAN_KEY}" "${RASPBIAN_KEY_SHA256}"

RASPBIAN_KEY_FILE=$(downloadGPGKey "${RASPBIAN_KEY}" "${RASPBIAN_KEY_SHA256}")
if [ -d "$DEBOOTSTRAP_DIR" ]; then
    echo "Debootstrap directory $DEBOOTSTRAP_DIR already exists.  Skipping debootstrap step"
else
    echo "Running initial debootstrap"
    qemu-debootstrap --arch armhf --include=ca-certificates --keyring="${RASPBIAN_KEY_FILE}" $RELEASE "$DEBOOTSTRAP_DIR" $MIRROR
fi

updateGitDirectory $GIT_FIRMWARE_DIR $GIT_FIRMWARE_URL "firmware"
updateGitDirectory $GIT_KERNEL_DIR $GIT_KERNEL_URL "kernel"
wget -O "${GIT_KERNEL_DIR}/Module.symvers" https://github.com/raspberrypi/firmware/raw/master/extra/Module.symvers

echo "Copying firmware"
mkdir -p "${DEBOOTSTRAP_DIR}/opt/"
cp -R "${GIT_FIRMWARE_DIR}/hardfp/opt/"* "${DEBOOTSTRAP_DIR}/opt/"

echo "Copying /boot"
mkdir -p "${DEBOOTSTRAP_DIR}/boot"
cp -R "${GIT_FIRMWARE_DIR}/boot/"* "${DEBOOTSTRAP_DIR}/boot/"

echo "Copying kernel modules"
mkdir -p "${DEBOOTSTRAP_DIR}/lib/modules"
cp -R "${GIT_FIRMWARE_DIR}/modules/"* "${DEBOOTSTRAP_DIR}/lib/modules/"

echo "Copying kernel source"
copyKernelSource "${DEBOOTSTRAP_DIR}" "${GIT_KERNEL_DIR}" "/usr/src"

echo "Configuring minimal apt setup"
SOURCES_LIST="${DEBOOTSTRAP_DIR}/etc/apt/sources.list"
SOURCES_DIR="${DEBOOTSTRAP_DIR}/etc/apt/sources.list.d"
echo "deb $MIRROR $RELEASE main contrib non-free rpi" > $SOURCES_LIST
echo 'deb http://debian.internal.michaelhowe.org/ internal main contrib non-free' >> $SOURCES_LIST
echo 'deb http://archive.raspberrypi.org/debian/ wheezy main' > ${SOURCES_DIR}/raspi.list
# DANGER WILL ROBINSON: Debian armhf packages are NOT COMPATIBLE with the pi,
# and will not work (arch: all packages on the other hand are fine)
#echo 'deb http://mirror.ox.ac.uk/debian unstable main' >> ${SOURCES_LIST}

echo "Setting up local trust"

if [ -n "$USE_LOCAL_CERT" -a "$USE_LOCAL_CERT" ]; then
    if [ -f "$LOCAL_CERT" ]; then
        mkdir -p "$TARGET_CERT_DIR"
        cp "$LOCAL_CERT" "$TARGET_CERT_DIR"
        chroot "$DEBOOTSTRAP_DIR" /usr/sbin/update-ca-certificates
    fi
fi

# Ewwwwwww
echo "WARNING: Horrible lack of GPG validation going on here" >&2
installAptKeyFromURL "${DEBOOTSTRAP_DIR}" "${RPI_KEY}" "${RPI_KEY_SHA256}"

# Go through all the keyrings we want included and drop them in $APT_GPG_PARTS directory.
# Then, run apt-get update, and install the package for the keyring.
# In the debian case, remove the file we created since the package creates individual ones
if test $(testVar $USE_LOCAL_KEYRING) -eq 1; then
    if [ -f "$ARCHIVE_KEYRING" ]; then
        cp "$ARCHIVE_KEYRING" "${DEBOOTSTRAP_DIR}/${ARCHIVE_KEYRING}"
    fi
fi
if test $(testVar $USE_DEBIAN_KEYRING) -eq 1; then
    if [ -f "${DEBIAN_ARCHIVE_KEYRING}" ]; then
        cp "${DEBIAN_ARCHIVE_KEYRING}" "${DEBOOTSTRAP_DIR}/${APT_GPG_PARTS}/debian-archive-keyring.gpg"
    fi
fi
updateApt "${DEBOOTSTRAP_DIR}"

if test $(testVar $USE_LOCAL_KEYRING) -eq 1; then
    [ -f "$ARCHIVE_KEYRING" ] && installDebianPackage ${DEBOOTSTRAP_DIR} mh-archive-keyring
fi

if test $(testVar $USE_DEBIAN_KEYRING) -eq 1; then
    if [ -f "${DEBIAN_ARCHIVE_KEYRING}" ]; then
        rm -f "${DEBOOTSTRAP_DIR}/${APT_GPG_PARTS}/debian-archive-keyring.gpg"
        installDebianPackage "${DEBOOTSTRAP_DIR}" debian-archive-keyring
    fi
fi

echo "Configuring locales"
debconfSetSelection "${DEBOOTSTRAP_DIR}" "locales locales/default_environment_locale select ${LOCALES_SELECTED}"
debconfSetSelection "${DEBOOTSTRAP_DIR}" "locales locales/locales_to_be_generated multiselect ${LOCALES_GENERATED}"
installDebianPackage "${DEBOOTSTRAP_DIR}" locales

# Reset lang
export LANG=$OLD_LANG
unset LC_ALL

echo "Setting up hostname"
echo "$NEW_HOSTNAME" > "${DEBOOTSTRAP_DIR}/etc/hostname"

#
# Preseed answers
#
if test $(testVar $USE_CONFIGTOOL) -eq 1; then
    debconfSetSelection "${DEBOOTSTRAP_DIR}" "configtool configtool/syncmode select subversion"
    debconfSetSelection "${DEBOOTSTRAP_DIR}" "configtool configtool/svn/username string ${NEW_HOSTNAME}.${DOMAIN}"
    debconfSetSelection "${DEBOOTSTRAP_DIR}" "configtool configtool/svn/source string https://config.internal.michaelhowe.org/svn/basic/sysconfig/systems/${NEW_HOSTNAME}.${DOMAIN}/root"
    debconfSetSelection "${DEBOOTSTRAP_DIR}" "configtool configtool/rsync/source string "
    debconfSetSelection "${DEBOOTSTRAP_DIR}" "configtool configtool/rsync/source seen true"
    debconfSetSelection "${DEBOOTSTRAP_DIR}" "configtool configtool/userskel/source string https://config.internal.michaelhowe.org/svn/basic/sysconfig/userskel"

    # Configure configtool before tweaking other things
    echo "Installing configtool and running initial sync"
    installDebianPackage "${DEBOOTSTRAP_DIR}" configtool
    syncConfigtool "${DEBOOTSTRAP_DIR}"

    # Configure /etc/apt
    runConfigtool "${DEBOOTSTRAP_DIR}" "/etc/apt"
    updateApt "${DEBOOTSTRAP_DIR}"
fi


# Standard packages
installDebianPackage "${DEBOOTSTRAP_DIR}" vim subversion zsh sudo htop krb5-user dctrl-tools libyaml-perl openbsd-inetd openssh-server munin-node less exim4-daemon-light bsd-mailx curl abr libpam-krb5 libpam-afs-session
# System-specific specific packages
installDebianPackage "${DEBOOTSTRAP_DIR}" mpd alsa-utils kstart mpd-utils openafs-krb5 openafs-client openafs-modules-source
# Packages specific to my setup
installDebianPackage "${DEBOOTSTRAP_DIR}" wpasupplicant firmware-realtek
# Raspberry pi specific packages
installDebianPackage "${DEBOOTSTRAP_DIR}" raspi-config fake-hwclock ntp
# Note that raspberrypi-bootloader also contains a kernel, which may overwrite
# the kernel installed from git
if test $(testVar $USE_PACKAGED_KERNEL) -eq 1; then
    installDebianPackage "${DEBOOTSTRAP_DIR}" raspberrypi-bootloader
fi

if test $(testVar $USE_CONFIGTOOL) -eq 1; then
    # Run other configtool things
    echo "Initial abr deployment"
    runConfigtool "${DEBOOTSTRAP_DIR}" "/etc/abr"
    chroot "${DEBOOTSTRAP_DIR}" abr -d

    echo "Applying any wireless configuration"
    runConfigtool "${DEBOOTSTRAP_DIR}" "/etc/wireless" "--post --ifpresent"
    echo "Applying configtool"
    runConfigtool "${DEBOOTSTRAP_DIR}"
fi

if test $(testVar $USE_KERBEROS) -eq 1; then
    createKerberosKeytab "${DEBOOTSTRAP_DIR}" "host/${NEW_HOSTNAME}.${DOMAIN}@${KRB5_REALM}" "/etc/krb5.keytab"
    createKerberosKeytab "${DEBOOTSTRAP_DIR}" "music/${NEW_HOSTNAME}@${KRB5_REALM}" "/etc/krb5.music.keytab"
    changeOwnership "${DEBOOTSTRAP_DIR}" "/etc/krb5.music.keytab" "mpd"
fi

createUser "${DEBOOTSTRAP_DIR}" "michael" "Michael Howe"
addUserToGroup "${DEBOOTSTRAP_DIR}" "michael" "adm"
addUserToGroup "${DEBOOTSTRAP_DIR}" "michael" "audio"
addUserToGroup "${DEBOOTSTRAP_DIR}" "michael" "src"

echo "Tweaking time"
if [ -f "${DEBOOTSTRAP_DIR}/etc/init.d/hwclock.sh" ]; then
    chroot "${DEBOOTSTRAP_DIR}" /usr/sbin/update-rc.d -f hwclock.sh remove
fi
chroot "${DEBOOTSTRAP_DIR}" fake-hwclock save

echo "Setting temporary root password"
CRYPT_PASSWORD=`mkpasswd ${TEMP_ROOT_PASSWORD} RP`
chroot "${DEBOOTSTRAP_DIR}" usermod --password "${CRYPT_PASSWORD}" root

enableStartStopDaemon "${DEBOOTSTRAP_DIR}"
if test $(testVar $WRITE_IMAGE) -eq 1; then
    # Now do the install

    if [ ! -b ${DEVICE} ]; then
        echo "ERROR: device ${DEVICE} does not exist" >&2
        exit 1
    fi

    if test $(testVar $DD_DEVICE) -eq 1; then
        echo "Wiping device ${DEVICE}"
        dd if=/dev/zero of=${DEVICE} bs=1M || true
        # Wait for dd to finish
        sleep 30
        sync
        sleep 30
    fi
#    else
        echo "Clearing partition table of ${DEVICE}"
        dd if=/dev/zero of=${DEVICE} bs=1k count=512
#    fi

    echo "Partitioning ${DEVICE}"
    parted --script ${DEVICE} mklabel msdos
    parted --script --align optimal ${DEVICE} mkpart primary fat32 '0%' 64M
    parted --script --align optimal ${DEVICE} mkpart primary ext4 64M '100%'

    echo "Creating filesystems..."
    mkfs.msdos -s 16 ${DEVICE}1
    echo "/boot complete"
    mkfs.ext4 ${DEVICE}2
    echo "/ complete"

    echo

    TEMP_MOUNTPOINT="${APP_TEMPDIR}/install"
    echo "Mounting under ${TEMP_MOUNTPOINT}"
    mkdir -p "${TEMP_MOUNTPOINT}"
    mount ${DEVICE}2 "${TEMP_MOUNTPOINT}"
    mkdir "${TEMP_MOUNTPOINT}/boot"
    mount ${DEVICE}1 "${TEMP_MOUNTPOINT}/boot"
    echo "Copying files"
    rsync -avvP "${DEBOOTSTRAP_DIR}/" "${TEMP_MOUNTPOINT}/"
    echo "Running final 'sync'"
    sync
    echo "Unmounting"
    umount "${TEMP_MOUNTPOINT}/boot"
    umount "${TEMP_MOUNTPOINT}"

    eject ${DEVICE}
fi  # $WRITE_IMAGE

trap - EXIT
cleanup
rm -rf "${APP_TEMPDIR}"

echo "Install complete"
