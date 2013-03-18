#
# Mostly copied from the xen-tools Debian package, and under the GPL/Perl
# Artistic License.
# Homepage <http://xen-tools.org/software/xen-tools/>
#
#  If we're running verbosely show a message, otherwise swallow it.
#
logMessage ()
{
    message="$*"

    if [ ! -z "${verbose}" ]; then
        echo $message
    fi
}

#
#  Test the given condition is true, and if not abort.
#
#  Sample usage:
#    assert "$LINENO" "${verbose}"
#
assert ()
{
    lineno="?"

    if [ -n "${LINENO}" ]; then
        # our shell defines variable LINENO, great!
        lineno=$1
        shift
    fi

    if [ ! $* ] ; then
        echo "assert failed: $0:$lineno [$*]"
        exit
    fi
}


installDebianPackage ()
{
    prefix=$1
    shift

    #
    # Log our options
    #
    logMessage "Installing Debian packages $@ to prefix ${prefix}"

    #
    #  We require a package + prefix
    #
    assert "$LINENO" "${prefix}"

    #
    # Prefix must be a directory.
    #
    assert "$LINENO" -d ${prefix}

    #
    #  Use policy-rc to stop any daemons from starting.
    #
    sudo sh -c "printf '#!/bin/sh\nexit 101\n' > ${prefix}/usr/sbin/policy-rc.d"
    sudo chmod +x ${prefix}/usr/sbin/policy-rc.d

    #
    # Disable the start-stop-daemon - this shouldn't be necessary
    # with the policy-rc.d addition above, however leaving it in
    # place won't hurt ..
    #
    disableStartStopDaemon ${prefix}

    #
    # Install the packages
    #
    DEBIAN_FRONTEND=noninteractive chroot ${prefix} /usr/bin/apt-get --yes --force-yes install "$@"

    #
    #  Remove the policy-rc.d script.
    #
    sudo rm -f ${prefix}/usr/sbin/policy-rc.d

    #
    # Re-enable the start-stop-daemon
    #
    enableStartStopDaemon ${prefix}

}

#
# Disable the start-stop-daemon
#
disableStartStopDaemon ()
{
   local prefix="$1"
   assert "$LINENO" "${prefix}"
   for starter in start-stop-daemon initctl; do
      local daemonfile="${prefix}/sbin/${starter}"

      if [ -e "${daemonfile}" ]; then
        sudo mv "${daemonfile}" "${daemonfile}.REAL"
      fi
      echo '#!/bin/sh' > "${daemonfile}"
      echo "echo \"Warning: Fake ${starter} called, doing nothing\"" >> "${daemonfile}"

      chmod 755 "${daemonfile}"
      logMessage "${starter} disabled / made a stub."
   done
}



#
# Enable the start-stop-daemon
#
enableStartStopDaemon ()
{
   local prefix=$1
   assert "$LINENO" "${prefix}"
   for starter in start-stop-daemon initctl; do
      local daemonfile="${prefix}/sbin/${starter}"

      #
      #  If the disabled file is present then enable it.
      #
      if [ -e "${daemonfile}.REAL" ]; then
          mv "${daemonfile}.REAL" "${daemonfile}"
          logMessage "${starter} restored to working order."
      fi
   done
}
