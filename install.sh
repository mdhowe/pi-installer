#!/bin/bash
set -e

[ -e common.sh ] &&
    . common.sh

NEW_HOSTNAME=$1

set -u

RELEASE="wheezy"
BASE_DIR="/mnt/scratch/raspbian"
DOMAIN="internal.michaelhowe.org"
KRB5_REALM="MICHAELHOWE.ORG"
TEMP_ROOT_PASSWORD="test"

MIRROR="http://mirror.internal.michaelhowe.org:3142/mirror.ox.ac.uk/sites/archive.raspbian.org/archive/raspbian"
DEBOOTSTRAP_DIR="${BASE_DIR}/debootstrap"

GIT_FIRMWARE_URL="https://github.com/raspberrypi/firmware.git"
GIT_FIRMWARE_DIR="${BASE_DIR}/firmware"
GIT_KERNEL_URL="https://github.com/raspberrypi/linux.git"
GIT_KERNEL_DIR="${BASE_DIR}/linux"

LOCAL_CERT="/usr/local/share/ca-certificates/MichaelSecurePlaces.crt"
TARGET_CERT_DIR="${DEBOOTSTRAP_DIR}/usr/local/share/ca-certificates"

APT_GPG_PARTS="/etc/apt/trusted.gpg.d"
ARCHIVE_KEYRING="${APT_GPG_PARTS}/mh-archive-michaelhowe.org.gpg"
DEBIAN_ARCHIVE_KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
RPI_KEY="http://archive.raspberrypi.org/debian/raspberrypi.gpg.key"
RPI_KEY_SHA256="76603890d82a492175caf17aba68dc73acb1189c9fd58ec0c19145dfa3866d56"

# To keep the xen-tools things happy:
verbose=1

# Work-arounds to keep things quiet:
OLD_LANG=$LANG
unset LANG
export LC_ALL=C

if [ -z "$NEW_HOSTNAME" ]; then
    echo "Usage: $0 hostname.fqdn" >&2
    exit 1
fi

if [ -d "$DEBOOTSTRAP_DIR" ]; then
    echo "Debootstrap directory $DEBOOTSTRAP_DIR already exists.  Skipping debootstrap step"
else
    echo "TODO: fix GPG" >&2
    sudo qemu-debootstrap --arch armhf --include=ca-certificates --no-check-gpg $RELEASE "$DEBOOTSTRAP_DIR" $MIRROR
fi

#echo "Setting up firmware"
#mkdir -p "$GIT_FIRMWARE_DIR"
#if [ ! -d "${GIT_FIRMWARE_DIR}/.git" ]; then
#    echo "Looks like ${GIT_FIRMWARE_DIR} doesn't exist as a git clone - running git clone $GIT_FIRMWARE_URL"
#    git clone "$GIT_FIRMWARE_URL" "$GIT_FIRMWARE_DIR"
#else
#    echo "Checking and updating ${GIT_FIRMWARE_DIR}"
#    git --git-dir="${GIT_FIRMWARE_DIR}/.git" --work-tree="${GIT_FIRMWARE_DIR}" pull
#fi

updateGitDirectory $GIT_FIRMWARE_DIR $GIT_FIRMWARE_URL "firmware"
updateGitDirectory $GIT_KERNEL_DIR $GIT_KERNEL_URL "kernel"
sudo wget -O "${GIT_KERNEL_DIR}/Module.symvers" https://github.com/raspberrypi/firmware/raw/master/extra/Module.symvers

sudo mkdir -p "${DEBOOTSTRAP_DIR}/opt/"
sudo cp -R "${GIT_FIRMWARE_DIR}/hardfp/opt/"* "${DEBOOTSTRAP_DIR}/opt/"

sudo mkdir -p "${DEBOOTSTRAP_DIR}/boot"
sudo cp -R "${GIT_FIRMWARE_DIR}/boot/"* "${DEBOOTSTRAP_DIR}/boot/"

sudo mkdir -p "${DEBOOTSTRAP_DIR}/lib/modules"
sudo cp -R "${GIT_FIRMWARE_DIR}/modules/"* "${DEBOOTSTRAP_DIR}/lib/modules/"

copyKernelSource "${DEBOOTSTRAP_DIR}" "${GIT_KERNEL_DIR}" "/usr/src"

echo "Configuring minimal apt setup"
SOURCES_LIST="${DEBOOTSTRAP_DIR}/etc/apt/sources.list"
SOURCES_DIR="${DEBOOTSTRAP_DIR}/etc/apt/sources.list.d"
sudo sh -c "echo 'deb $MIRROR $RELEASE main contrib non-free rpi' > $SOURCES_LIST"
sudo sh -c "echo 'deb http://debian.internal.michaelhowe.org/ internal main contrib non-free' >> $SOURCES_LIST"
sudo sh -c "echo 'deb http://archive.raspberrypi.org/debian/ wheezy main' > ${SOURCES_DIR}/raspi.list"
sudo sh -c "echo 'deb http://mirror.ox.ac.uk/debian unstable main' >> ${SOURCES_LIST}"

echo "Setting up local trust"
if [ -f "$LOCAL_CERT" ]; then
    sudo mkdir -p "$TARGET_CERT_DIR"
    sudo cp "$LOCAL_CERT" "$TARGET_CERT_DIR"
    sudo chroot "$DEBOOTSTRAP_DIR" /usr/sbin/update-ca-certificates
fi

# Ewwwwwww
echo "WARNING: Horrible lack of GPG validation going on here" >&2
installAptKeyFromURL "${DEBOOTSTRAP_DIR}" "${RPI_KEY}" "${RPI_KEY_SHA256}"

# Go through all the keyrings we want included and drop them in $APT_GPG_PARTS directory.
# Then, run apt-get update, and install the package for the keyring.
# In the debian case, remove the file we created since the package creates individual ones
if [ -f "$ARCHIVE_KEYRING" ]; then
    sudo cp "$ARCHIVE_KEYRING" "${DEBOOTSTRAP_DIR}/${ARCHIVE_KEYRING}"
fi
if [ -f "${DEBIAN_ARCHIVE_KEYRING}" ]; then
    sudo cp "${DEBIAN_ARCHIVE_KEYRING}" "${DEBOOTSTRAP_DIR}/${APT_GPG_PARTS}/debian-archive-keyring.gpg"
fi
updateApt "${DEBOOTSTRAP_DIR}"
[ -f "$ARCHIVE_KEYRING" ] && installDebianPackage ${DEBOOTSTRAP_DIR} mh-archive-keyring
if [ -f "${DEBIAN_ARCHIVE_KEYRING}" ]; then
    rm -f "${DEBOOTSTRAP_DIR}/${APT_GPG_PARTS}/debian-archive-keyring.gpg"
    installDebianPackage "${DEBOOTSTRAP_DIR}" debian-archive-keyring
fi

echo "Configuring locales"
debconfSetSelection "${DEBOOTSTRAP_DIR}" "locales locales/default_environment_locale select en_GB.UTF-8"
debconfSetSelection "${DEBOOTSTRAP_DIR}" "locales locales/locales_to_be_generated multiselect en_GB.UTF-8 UTF-8"
installDebianPackage "${DEBOOTSTRAP_DIR}" locales

# Reset lang
export LANG=$OLD_LANG
unset LC_ALL

echo "Setting up hostname"
sudo sh -c "echo \"$NEW_HOSTNAME\" > \"${DEBOOTSTRAP_DIR}/etc/hostname\""

#
# Preseed answers
#
NEW_HOST=$(cat ${DEBOOTSTRAP_DIR}/etc/hostname)
TEMP_FILE=`tempfile`

wget --output-document=$TEMP_FILE http://dev.internal.michaelhowe.org/configtool.debconf
perl -p -i -e "s/NEW_HOST/$NEW_HOST/g" $TEMP_FILE
chroot ${DEBOOTSTRAP_DIR} debconf-set-selections < $TEMP_FILE

rm -f $TEMP_FILE

# Standard packages
installDebianPackage "${DEBOOTSTRAP_DIR}" configtool vim subversion zsh sudo htop krb5-user dctrl-tools libyaml-perl openbsd-inetd openssh-server munin-node less exim4-daemon-light bsd-mailx
# System-specific specific packages
installDebianPackage "${DEBOOTSTRAP_DIR}" mpd alsa-utils kstart
# Raspberry pi specific packages
installDebianPackage "${DEBOOTSTRAP_DIR}" raspi-config fake-hwclock ntp

echo "Running initial configtool sync"
syncConfigtool "${DEBOOTSTRAP_DIR}"

runConfigtool "${DEBOOTSTRAP_DIR}"

createKerberosKeytab "${DEBOOTSTRAP_DIR}" "host/${NEW_HOSTNAME}.${DOMAIN}@${KRB5_REALM}" "/etc/krb5.keytab"
createKerberosKeytab "${DEBOOTSTRAP_DIR}" "music/${NEW_HOSTNAME}@${KRB5_REALM}" "/etc/krb5.music.keytab"
changeOwnership "${DEBOOTSTRAP_DIR}" "/etc/krb5.music.keytab" "mpd"

createUser "${DEBOOTSTRAP_DIR}" "michael" "Michael Howe"
addUserToGroup "${DEBOOTSTRAP_DIR}" "michael" "adm"
addUserToGroup "${DEBOOTSTRAP_DIR}" "michael" "audio"
addUserToGroup "${DEBOOTSTRAP_DIR}" "michael" "src"

echo "Tweaking time"
if [ -f "${DEBOOTSTRAP_DIR}/etc/init.d/hwclock.sh" ]; then
    sudo chroot "${DEBOOTSTRAP_DIR}" /usr/sbin/update-rc.d -f hwclock.sh remove
fi
sudo chroot "${DEBOOTSTRAP_DIR}" fake-hwclock save

echo "Setting temporary root password"
CRYPT_PASSWORD=`mkpasswd ${TEMP_ROOT_PASSWORD} RP`
sudo chroot "${DEBOOTSTRAP_DIR}" usermod --password "${CRYPT_PASSWORD}" root

enableStartStopDaemon "${DEBOOTSTRAP_DIR}"
set -x
# Now do the install
DEVICE=/dev/sdg

if [ ! -b ${DEVICE} ]; then
    echo "ERROR: device ${DEVICE} does not exist" >&2
    exit 1
fi
sudo parted --script ${DEVICE} mklabel msdos
sudo parted --script --align optimal ${DEVICE} mkpart primary fat16 '0%' 64M
sudo parted --script ${DEVICE} set 1 lba on
sudo parted --script --align optimal ${DEVICE} mkpart primary ext4 64M '100%'

sudo mkfs.msdos ${DEVICE}1
sudo mkfs.ext4 ${DEVICE}2

echo "TODO: check mount location" >&2
TEMP_MOUNTPOINT=/mnt/raspbian-install
sudo mkdir -p "${TEMP_MOUNTPOINT}"
sudo mount ${DEVICE}2 "${TEMP_MOUNTPOINT}"
sudo mkdir "${TEMP_MOUNTPOINT}/boot"
sudo mount ${DEVICE}1 "${TEMP_MOUNTPOINT}/boot"
sudo rsync -avvP "${DEBOOTSTRAP_DIR}/" "${TEMP_MOUNTPOINT}/"
sudo sync
sudo umount "${TEMP_MOUNTPOINT}/boot"
sudo umount "${TEMP_MOUNTPOINT}"

sudo eject ${DEVICE}
