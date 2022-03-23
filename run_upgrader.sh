#!/bin/bash

#
# This script is copied into the guest with the 32 and 64 bit upgrader binaries.
# It selects one of the binaries based on the userland bitness of the guest and
# runs it.
#

SCRIPT=$0
BINDIR=`dirname $0`
DBPATH="/etc/vmware-tools/locations"
LOGFILE='/var/log/vmware-tools-upgrader.log'
UPGRADER64='vmware-tools-upgrader-64'
UPGRADER32='vmware-tools-upgrader-32'
ARGS="$@"

# Setup the logfile in a spot that avoids SElinux errors and allows for
# better debugging of upgrader errors.  Add the date as the first line
# so we can get a better handle on the situation.  This also effectively
# deletes any previous log file that may have been there.
date >$LOGFILE
chmod 0600 $LOGFILE

# If the temp directory on the system has a 'noexec' property, the upgrade
# binary as well as the vmware-install.pl will need to be executed from
# another location.

# Function to return the last positional parameter passed in.
function last_field {
   eval last_value='$'$#
   echo $last_value
}

# Check whether the single argument is a directory located in a 'noexec'
# filesystem.  If the directory is on a 'noexec' filesystem, return TRUE (0).
# Otherwise return FALSE (1).
function check_tmp_noexec {
   if [ $# -eq 1 -a -n "$1" -a -d "$1" ];
   then
      df_out="`df $1 | tail -1`"
      mount_point=`last_field $df_out`
      if [ -n "$mount_point" -a -d "$mount_point" ];
      then
         if grep -Eq "^[^ ]+ $mount_point [^ ]+ ([^ ]*,)?noexec[, ]" \
                 /proc/mounts;
         then
            # Looking at a 'noexec' filesystem; return TRUE
            return `true`
         fi
      fi
   fi
   # Return FALSE.
   return `false`
}

# Create a temporary directory in the same directory as the VMware Tools
# LIBDIR which must already exist on a non-noexec filesystem.
function create_executable_temp_dir {
   libdir=`grep "^answer LIBDIR" $DBPATH | tail -1 | cut -d ' ' -f3`
   if [ -n "$libdir" ];
   then
      libdir=`dirname $libdir`
   fi
   if [ -z "$libdir" -o ! -d "$libdir" ];
   then
      # Default to /usr/lib on Linux.
      libdir=/usr/lib
   fi
   echo `mktemp -d -p $libdir vmware-tools-temp-XXXXXX`
}

# Close all the inherited FDs. See bug 138500 for details.
MAXFD=$(expr `ulimit -n` - 1)
for fd in `seq 3 $MAXFD`; do
   eval "exec $fd>&-"
done

# Check userland bitness.  Remove the unneeded upgrader binary.
which file >& /dev/null
if [ $? -ne 0 ];then
    echo "Dependency file package not installed" >>$LOGFILE 2>&1
    exit 1
fi
if LANG=C file -L -- "$SHELL" | grep 64-bit >& /dev/null;
then
   UPGRADER=$UPGRADER64;
   UPGRADER_UNUSED=$BINDIR/$UPGRADER32
else
   UPGRADER=$UPGRADER32;
   UPGRADER_UNUSED=$BINDIR/$UPGRADER64
fi
echo "Deleting the unneeded upgrader binary: ${UPGRADER_UNUSED}" \
     >>$LOGFILE 2>&1
rm -f ${UPGRADER_UNUSED}

# Pass a '-d' option to the upgrader to direct the binary to delete itself
# after starting execution.
UPGRADERARGS="-d"

# Check if the executable is currently in a 'noexec' $BINDIR.
if `check_tmp_noexec $BINDIR`;
then
   # Get an executable temp directory and move the UPGRADER binary into
   # that directory.  Pass the directory to the upgrader; the '-d' option
   # directs the binary to delete itself after starting execution.
   newdir=`create_executable_temp_dir`
   mv $BINDIR/$UPGRADER $newdir/$UPGRADER
   UPGRADERARGS="$UPGRADERARGS -t $newdir"
   # Set BINDIR to the new temporary directory.
   BINDIR=$newdir
fi

# Set UPGRADER to a full path.
UPGRADER=$BINDIR/$UPGRADER

# Complete argument list based on whether Tools is
# already installed or not. If user passes args, though,
# use them blindly.
# (-s checks to see if a file exists and has nonzero length.)

if [ ! -s "$DBPATH" ] && [ "x$ARGS" = "x" ];
then
   UPGRADERARGS="$UPGRADERARGS -p --default --force-install"
else
   # Has no effect if $@ was empty on entry.
   UPGRADERARGS="$UPGRADERARGS $ARGS"
fi

# cope with "-p" which needs all subsequent args as one.
PARGS=""
set -- $UPGRADERARGS
UPGRADERARGS=""
while [ $# -gt 0 ]; do
   UPGRADERARGS="$UPGRADERARGS $1"
   if [ "x-p" = "x$1" ];
   then
      shift
      PARGS="$@"
      break
   fi
   shift
done

chmod +x $UPGRADER
# Run the upgrader.
# Delay starting the upgrader till rhgb-client (if present and running) has
# quit.
RHGBCLNT=/usr/bin/rhgb-client
if [ -x $RHGBCLNT ]; then
   while true ; do
      if ! $RHGBCLNT --ping ; then
         break
      fi
      echo "Waiting for rhgb to exit, will sleep for 30 seconds..." >> $LOGFILE
      sleep 30
   done
fi

# Before executing the UPGRADER binary, remove this script from the guest
echo "Removing this script from the guest: $SCRIPT" >>$LOGFILE 2>&1
rm -f $SCRIPT

echo "Executing \"$UPGRADER $UPGRADERARGS $PARGS\"" >>$LOGFILE 2>&1
if [ "x$PARGS" = "x" ]
then
   exec $UPGRADER $UPGRADERARGS >>$LOGFILE 2>&1
else
   exec $UPGRADER $UPGRADERARGS "$PARGS" >>$LOGFILE 2>&1
fi

# If here then the exec failed.
echo "Exec call failed!" >>$LOGFILE 2>&1
exit 1
