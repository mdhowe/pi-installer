#
# Common functions used by install.sh
#

[ -e common-xentools.sh ] &&
    . common-xentools.sh

mountProc ()
{
    local prefix=$1

    local procfile="${prefix}/proc"

    assert "$LINENO" -d "$prefix"
    assert "$LINENO" -d "$procfile"

    umountProc $prefix

    mount -t proc proc "${procfile}"
#    trap "umountProc \"${prefix}\"" EXIT
}

umountProc ()
{
    local prefix=$1
    local procfile="${prefix}/proc"

#    assert "$LINENO" -d "$prefix"
#    assert "$LINENO" -d "$procfile"

    if $(mount | grep --quiet "${prefix}/proc"); then
        umount "$procfile"
    fi
    
#    trap - EXIT
}

updateApt ()
{
    local prefix=$1
    
    assert "$LINENO" -d "$prefix"
    sudo chroot "${prefix}" apt-get update
}

debconfSetSelection ()
{
    local prefix=$1
    local selection=$2
    
    assert "$LINENO" -d "$prefix"
#    assert "$LINENO" "\"$selection\""

    echo "${selection}" | sudo chroot "${prefix}" debconf-set-selections
}

downloadGPGKey()
{
    local url=$1
    local sha256sum=$2
    assert "$LINENO" "$url"
    assert "$LINENO" "$sha256sum"
    assert "$LINENO" -d "$APP_TEMPDIR"

    FILENAME=`echo ${url} | sed -e 's#.*/##'`
    TEMPKEY="${APP_TEMPDIR}/${FILENAME}"
    TEMPSUM="${APP_TEMPDIR}/${FILENAME}.sha256"
    wget --output-document "$TEMPKEY" --quiet "$url"
    echo -e "$sha256sum  ${TEMPKEY}" > "${TEMPSUM}"
    sha256sum --quiet --check "${TEMPSUM}" || (
        echo "ERROR: GPG key $url failed to checksum correctly!" >&2
        echo "Downloaded key and checksum can be found in ${APP_TEMPDIR}" >&2
        exit 1
    )
    # Check file type
    if grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' ${TEMPKEY}; then
        GPGNAME="${TEMPKEY}.gpg"
        gpg --keyring="${GPGNAME}" --no-default-keyring --quiet --import "${TEMPKEY}" >/dev/null
        echo "${GPGNAME}"
    else
        echo "${TEMPKEY}"
    fi
}
installAptKeyFromURL ()
{
    local prefix=$1
    local url=$2
    local sha256sum=$3

    assert "$LINENO" "$prefix"
    assert "$LINENO" "$url"
    assert "$LINENO" "$sha256sum"

    GPG_FILE=`downloadGPGKey $url $sha256sum`

    installAptKeyFromFile ${prefix} "${GPG_FILE}"
}

installAptKeyFromFile ()
{
    local prefix=$1
    local file=$2

    assert "$LINENO" "$prefix"
    assert "$LINENO" -f "$file"

    echo "Results of apt-key add:"
    cat "${file}" | sudo chroot "${prefix}" apt-key add -
}

# TODO: replace this with abr
createKerberosKeytab ()
{
    local prefix=$1
    local principal=$2
    local file=$3

    KEYTAB_FILE="${prefix}/${file}"
    kadmin -q "ktadd -k ${KEYTAB_FILE} ${principal}"
}

syncConfigtool ()
{
    local prefix=$1

    assert "${LINENO}" -d "${prefix}"

    mountProc "${prefix}"
    sudo chroot "${prefix}" configtool --sync
    umountProc "${prefix}"
}

runConfigtool ()
{
    local prefix=$1
    local destdir="/"
    if [ $# -gt 1 ]; then
        destdir=$2
    fi

    assert "${LINENO}" -d "${prefix}"

    disableStartStopDaemon "${prefix}"
#    trap "enableStartStopDaemon \"${prefix}\"" EXIT
    sudo chroot "${prefix}" configtool --nopost --force $destdir || logMessage "Configtool failed: $?"
    enableStartStopDaemon "${prefix}"
#    trap - EXIT

    # These are normally tidied up by postct scripts, but we don't run them
    logMessage "Tidying up ctold files"
    sudo chroot "${DEBOOTSTRAP_DIR}" sh -c "rm -f /etc/apt/apt.conf.d/*.ctold"
    sudo chroot "${DEBOOTSTRAP_DIR}" sh -c "rm -f /etc/init.d/*.ctold"
}

changeOwnership ()
{
    local prefix=$1
    local filename=$2
    local ownership=$3

    assert "${LINENO}" -d "${prefix}"
    assert "${LINENO}" "${filename}"

    assert "${LINENO}" -f "${prefix}/${filename}"

    sudo chroot "${prefix}" chown "${ownership}" "${filename}"
    
}

# Of course, ideally you'd do this with configtool
createUser ()
{
    local prefix=$1
    local user=$2
    local gecos=$3

    assert "${LINENO}" -d "${prefix}"
    assert "${LINENO}" "${user}"

    # or true - cope with set -e
    USER_EXISTS=`sudo chroot "${prefix}" getent passwd "${user}" || true`
    if [ -n "$USER_EXISTS" ]; then
        logMessage "User $user already exists - not re-creating, but fixing up .k5login"
    else
        sudo chroot "${prefix}" adduser --disabled-password --gecos "${gecos}" "${user}"
    fi

    sudo chroot "${prefix}" sh -c "echo '${user}@$KRB5_REALM' >> ~${user}/.k5login && chown ${user} ~${user}/.k5login"
    sudo chroot "${prefix}" sh -c "echo '${user}/root@$KRB5_REALM' >> ~${user}/.k5login"
    sudo chroot "${prefix}" sh -c "echo '${user}/admin@$KRB5_REALM' >> ~${user}/.k5login"
}

addUserToGroup ()
{
    local prefix=$1
    local user=$2
    local group=$3

    assert "${LINENO}" -d "${prefix}"
    assert "${LINENO}" "${user}"
    assert "${LINENO}" "${group}"

    sudo chroot "${prefix}" adduser "${user}" "${group}"
}

updateGitDirectory ()
{
    local gitdir=$1
    local giturl=$2
    local description=$3

    assert "${LINENO}" $gitdir
    assert "${LINENO}" $giturl
    assert "${LINENO}" $description

    logMessage "Setting up $description git repository"

    if [ ! -d "${gitdir}/.git" ]; then
        logMessage "Looks like ${gitdir} doesn't exist as a git clone - running git clone $giturl"
        mkdir -p "$gitdir"
        git clone "$giturl" "$gitdir"
    else
        logMessage "Checking and updating $gitdir"
        git --git-dir="${gitdir}/.git" --work-tree="${gitdir}" pull
    fi
}

copyKernelSource ()
{
    local prefix=$1
    local src=$2
    local destbasedir=$3

    cd "$src"
    KVER=`make kernelversion`
    DEST="${destbasedir}/linux-${KVER}"
    FULL_DEST="${prefix}/${DEST}"
    sudo mkdir -p "${FULL_DEST}"
    cp -R "${src}/"* "${FULL_DEST}"
    sudo chroot "$prefix" ln -sf "${DEST}" "${destbasedir}/linux"
    sudo chroot "$prefix" chgrp -R src "${DEST}"
    sudo chroot "$prefix" chmod -R g+w "${DEST}"
    # TODO: this probably shouldn't actually be here
    logMessage "Hacking kernel version to add '+'"
    sudo chroot "${prefix}" sed -i -e 's/^EXTRAVERSION =$/EXTRAVERSION = +/' "${DEST}/Makefile"
    sudo chroot "$prefix" ln -sf "${DEST}" "${DEST}+"
    MODULES_LIBDIR="/lib/modules/${KVER}+"
    for i in build source; do
        sudo chroot "${prefix}" ln -sf "${DEST}" "${MODULES_LIBDIR}/$i"
    done
}
