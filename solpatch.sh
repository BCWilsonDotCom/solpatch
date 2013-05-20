#!/bin/bash
# Script to automate the Solaris patching process
#############################################################

############################################
# Set some vars that we'll need later on.
############################################
PATH="$PATH:/bin:/sbin:/usr/bin:/usr/sbin"
PATCHCLUSTER="1H2013"
NEWBE="s10-$PATCHCLUSTER"
TASK="$1"
HOST="$2"
COL=$(tput cols)
LOGFILE="/tmp/solpatch-$TASK-$PATCHCLUSTER-$HOST.log"

############################
# FUNCTIONS
############################
Confirm_To_Proceed() {
    #Just a function that will prompt the user to confirm before proceeding, whenever necessary.
    CONF_YN="A" ; CONFYN=" "
    until [ "$CONF_YN" = "y" ] || [ "$CONF_YN" = "n" ]
    do
        echo;echo "Do you want to Proceed (Y/N): " ; read CONFYN
        CONF_YN=`echo $CONFYN|tr '[A-Z]' '[a-z]'`
    done
    if [ $CONF_YN = "n" ]; then
        echo ; echo "Operation aborted, Exiting... "
        exit 1
    fi
}

SysCheck() {
    #Verify that the system has the necessary requirements to patch it.
    echo -ne "Checking System Requirements... "

    #Check free space in /opt
    if [[ "`hostname`" = "mrtg" && $HOST != "mrtg" ]]; then
        OPTFREESPACE=`ssh $HOST "df -k /opt" |grep -v avail |awk '{print $4}'`
    elif  [[ "`hostname`" != "mrtg" && "`hostname`" = $HOST ]]; then
        OPTFREESPACE=`df -k /opt |grep -v avail |awk '{print $4}'`
    else
        echo "ERROR: Unable to determine available space for $HOST:/opt!"
        exit 2
    fi

    if [ "$OPTFREESPACE" -lt "2621440" ]; then
        echo "FAILED!"
        echo "$HOST:/opt does not have at least 2.5GB of free space!"
        exit 2
    fi

    #Check % of free space in /root
    if [[ "`hostname`" = "mrtg" && $HOST != "mrtg" ]]; then
        ROOTFREESPACE=`ssh $HOST "df -h /" |grep -v avail |awk '{print $5}' |sed '$s/.$//'`
    elif  [[ "`hostname`" != "mrtg" && "`hostname`" = $HOST ]]; then
        ROOTFREESPACE=`df -h / |grep -v avail |awk '{print $5}' |sed '$s/.$//'`
    else
        echo "ERROR!"
        echo "Unable to determine available space for $HOST:/!"
        exit 2
    fi

    if [ "$ROOTFREESPACE" -gt "90" ]; then
        echo "ERROR!"
        echo "$HOST:/ Is over 90% utilized!"
        exit 2
    fi

    #Check to make sure we're NOT trying to patch a zone
    if [ "`hostname`" = "mrtg" ]; then
        ZONENAME=`ssh $HOST 'zonename'`
    elif [ "`hostname`" = "$HOST" ]; then
        ZONENAME=`zonename`
    fi

    if [ "$ZONENAME" != "global" ]; then
        echo "ERROR!"
        echo "You're trying to patch a zone. Bad admin! Don't do that!"
        exit 3
    fi

    #Check to make sure that we're not running this from mrtg unless:
    #1)We're running prep. 2)We're actually trying to patch mrtg itself.
    if [[ "$TASK" != "prep" &&  "$HOST" != "mrtg" && "`hostname`" = "mrtg" ]]; then
        echo "ERROR: Only the 'prep' functions can be run from mrtg."
        echo "Run all other functions from the target host itself."
        exit 4
    fi

    echo "PASSED!";
}

SysInfo() {
    #Call this function whenever we need to get info on the system
    echo -ne "Gathering System Information... "

    #Get the current Boot Environment's name
    if [[ "`hostname`" = "mrtg" && $HOST != "mrtg" ]]; then
        CURRENTBE=`ssh $HOST '/sbin/lucurr'`
    elif [[ "`hostname`" != "mrtg" && "`hostname`" = $HOST ]]; then
        CURRENTBE=`/sbin/lucurr`
    else
        echo "ERROR!"
        echo "Unable to determine the current Boot Environment!"
        exit 5
    fi

    #Get the platform type
    if [[ "`hostname`" = "mrtg" && $HOST != "mrtg" ]]; then
        PLATFORM=`ssh $HOST 'uname -p'`
    elif [[ "`hostname`" != "mrtg" && "`hostname`" = $HOST ]]; then
        PLATFORM=`uname -p`
    else
        echo "ERROR!"
        echo "Unable to determine the platform type!"
        exit 6
    fi

    echo "COMPLETE!"
}

PatchPrep() {
    #Function preps a host with required data for patching.

    echo; echo "Beginning prep of $HOST for $PATCHCLUSTER $PLATFORM patches."; echo

    if [[ "`hostname`" = "mrtg" && {$HOST} != "mrtg" ]]; then
        #Create the directories we'll need for storing the proper patch cluster.
        echo -ne "Creating $PATCHCLUSTER staging directories on $HOST... "
        ssh $HOST "mkdir -p /opt/patching/$PATCHCLUSTER/$PLATFORM"
        if [[ $? != 0 ]]; then echo "ERROR!"; echo " Failed to create patching directory on $HOST"; exit 7; fi
        echo "SUCCESSFUL!"

        #SCP the proper patch cluster and solpatch script to the host.
        echo "Transfering $PATCHCLUSTER Patch Cluster Data... "
        scp -rp /opt/patching/$PATCHCLUSTER/$PLATFORM/*zip $HOST:/opt/patching/$PATCHCLUSTER/$PLATFORM/
        if [[ $? != 0 ]]; then echo "ERROR!"; echo " Failed to SCP patching archive to $HOST!"; exit 7; fi
        scp -p /opt/patching/solpatch.sh $HOST:/opt/patching/
        if [[ $? != 0 ]]; then echo "ERROR!"; echo " Failed to SCP patching script to $HOST!"; exit 7; fi
        echo "SUCCESSFUL!"

        #Unzip the patches on the host.
        echo -ne "Extracting $PATCHCLUSTER Patch Cluster on $HOST... "
        ssh $HOST "unzip -q /opt/patching/$PATCHCLUSTER/$PLATFORM/*zip -d /opt/patching/$PATCHCLUSTER/$PLATFORM/"
        if [[ $? != 0 ]]; then echo "ERROR!"; echo "Failed to unzip the patching archive on $HOST!"; exit 7; fi
        echo "SUCCESSFUL!"
    elif [[ "`hostname`" = "mrtg" && "`hostname`" = $HOST ]]; then
        #We're on mrtg, and trying to patch it. Let's just unzip the patches we need.
        echo -ne "Extracting $PATCHCLUSTER Patch Cluster on $HOST... "
        unzip -q /opt/patching/$PATCHCLUSTER/$PLATFORM/*zip -d /opt/patching/$PATCHCLUSTER/$PLATFORM/
        if [[ $? != 0 ]]; then echo "ERROR!"; echo "Failed to unzip the patching archive on $HOST!"; exit 7; fi
        echo "SUCCESSFUL!"
    else
        echo "I've no idea what's going on."; exit 7
    fi

    echo; echo "Host Prep Completed Sucessfully!"; echo
}

ApplyPrePatches() {
    #Solaris CPUs sometimes require certain patches already in place.
    #This function will make sure that any PreReqs are taken care of.
    echo
    echo "Applying Pre-Patches."
    /opt/patching/$PATCHCLUSTER/$PLATFORM/10*/installpatchset --s10patchset --apply-prereq
    if [[ $? != 0 ]]; then echo "ERROR! Failed to apply the Pre-Patches on $HOST!"; exit 8; fi
}

comment_opt_vfstab() {
    echo
    echo -ne "Commenting out /opt mount from /etc/vfstab... "
    sed -e 's/rpool\/opt/#rpool\/opt/g' /etc/vfstab > /tmp/etcvfstab
    if [[ $? != 0 ]]; then echo "ERROR!"; echo "Failed to modify /opt in /etc/vfstab for $HOST!"; exit 9; fi
    cp /tmp/etcvfstab /etc/vfstab
    if [[ $? != 0 ]]; then echo "ERROR!"; echo "Failed to modify /opt in /etc/vfstab for $HOST!"; exit 9; fi
    echo "SUCCESSFUL!"
}

uncomment_opt_vfstab() {
    echo -ne "Un-Commenting /opt from /etc/vfstab... "
    sed -e 's/#rpool\/opt/rpool\/opt/g' /etc/vfstab > /tmp/etcvfstab
    cp /tmp/etcvfstab /etc/vfstab
    sed -e 's/#rpool\/opt/rpool\/opt/g' ${ALT_BE}/etc/vfstab > /tmp/etcvfstab
    cp /tmp/etcvfstab ${ALT_BE}/etc/vfstab
    echo "SUCCESSFUL!"
}

fix_vfstab_newbe() {
    echo -ne "Looking for issues with new BE vfstab file... "
    VFSFILE="${ALT_BE}/etc/vfstab"
    grep -n rpool/ROOT/${NEWBE} ${VFSFILE} |grep zfs > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "FOUND ISSUE!";
        grep -n rpool/ROOT/${NEWBE} ${VFSFILE} |grep zfs
        echo "Uncomment these lines from $NEWBE Boot Environment!"
        Confirm_To_Proceed
    fi
    gval=`grep -n rpool/ROOT/${NEWBE} ${VFSFILE}|grep zfs|awk -F':' '{print $1}'|head -1`
    while [ ! -z $gval ]
    do
        (echo "${gval}d"; echo 'wq') | ex -s ${VFSFILE}
        gval=`grep -n rpool/ROOT/${NEWBE} ${VFSFILE}|grep zfs|awk -F':' '{print $1}'|head -1`
    done

    echo "COMPLETE!"
}

fix_grub_after_luactivate() {
    #Function to fix the console variables on menu.lst after luactivate command has been invoked.
    PBEMENUFILE="/etc/lu/DelayUpdate/menu.pbe"
    MENUFILE="/etc/lu/DelayUpdate/menu.lst"
    TMPFILE="/tmp/newmenu.lst"

    echo -ne "Fixing console redirection... "

    PBE_CONS_VALUE=`cat ${PBEMENUFILE}|grep ZFS-BOOTFS|grep console|head -1|awk '{print $4}'|awk -F'$' '{print $2}'`
    sed -e s/"ZFS-BOOTFS"/"${PBE_CONS_VALUE}"/g ${MENUFILE} > ${TMPFILE}
    cp ${TMPFILE} ${MENUFILE}
    PBE_CONS_VALUE=`cat ${PBEMENUFILE}|grep 'boot/multiboot'|grep console|head -1|awk '{print $NF}'`
    sed -e s/"console=ttyb"/"${PBE_CONS_VALUE}"/g ${MENUFILE} > ${TMPFILE}
    cp ${TMPFILE} ${MENUFILE}

    echo "SUCCESSFUL!"
}

fix_sendmail() {
    echo -ne "Fixing sendmail... "
    cp /lib/svc/method/smtp-sendmail ${ALT_BE}/lib/svc/method/smtp-sendmail
    cp /etc/mail/local.cf ${ALT_BE}/etc/mail/local.cf
    echo "#!/bin/ksh" > ${ALT_BE}/etc/rc3.d/S90stop_sendmail-client
    echo "svcadm disable svc:/network/sendmail-client:default" >> ${ALT_BE}/etc/rc3.d/S90stop_sendmail-client
    echo "rm /etc/rc3.d/S90stop_sendmail-client" >> ${ALT_BE}/etc/rc3.d/S90stop_sendmail-client
    chmod 755 ${ALT_BE}/etc/rc3.d/S90stop_sendmail-client
    echo "SUCCESSFUL!"
}

lu_cmd_check() {
    RET_VAL=$1
    CMD_NAME=$2
    if [ $RET_VAL -eq 0 ];then
        echo; echo "--------------------------------------------------------------"
        echo "$CMD_NAME command completed successfully"
        echo "lustatus is:"
        lustatus
    else
        echo "Fatal Error!!! $CMD_NAME command was not successful"
        echo "Exiting..."
        echo "lustatus is:"
        lustatus
        exit 1
    fi
}

createBE() {
    echo
    echo -ne "Creating new Boot Environment $NEWBE... "
    lucreate -n $NEWBE > /dev/null 2>&1
    if [[ $? != 0 ]]; then echo "ERROR!"; echo "Failed to create Boot Environment $NEWBE on $HOST!"; exit 9; fi
    echo "SUCCESSFUL!"
    #echo
    #lustatus
}

activateBE() {
    echo -ne "Activating the patched Boot Environment $NEWBE on $HOST... "
    luactivate $NEWBE > /dev/null 2>&1
    if [[ $? != 0 ]]; then echo "ERROR!"; echo "Failed to activate Boot Environment $NEWBE on $HOST!"; exit 11; fi
    echo "SUCCESSFUL!"
}

PatchInstall() {
    /opt/patching/$PATCHCLUSTER/$PLATFORM/10*/installpatchset --s10patchset -B $NEWBE
    if [[ $? != 0 ]]; then echo "ERROR! Failed to install $PATCHCLUSTER Patch Cluster to Boot Environment $NEWBE on $HOST!"; exit 10; fi
}

mountBE() {
    echo -ne "Mounting $NEWBE Boot Environment... "
    lumount $NEWBE > /tmp/lumount_name
    if [[ $? != 0 ]]; then echo "ERROR!"; echo "Failed to mount Boot Environment $NEWBE on $HOST!"; exit 12; fi
    echo "SUCCESSFUL!"
}

unmountBE() {
    echo -ne "Unmounting $NEWBE Boot Environment..."
    luumount $NEWBE
    if [[ $? != 0 ]]; then echo "ERROR!"; echo "Failed to unmount Boot Environment $NEWBE on $HOST!"; exit 13; fi
    echo "SUCCESSFUL!"
}

CleanUp() {
    echo -ne "Cleaning up $PATCHCLUSTER files from $HOST... "
    if [[ "`hostname`" = "mrtg" && $HOST != "mrtg" ]]; then
        ssh $HOST "rm -r /opt/patching/*"
    elif [[ "`hostname`" != "mrtg" && "`hostname`" = $HOST ]]; then
        PLATFORM=`rm -r /opt/patching/*`
    fi
    if [[ $? != 0 ]]; then echo "ERROR!"; echo "Failed to delete $PATCHCLUSTER files from $HOST!"; exit 14; fi
    echo "SUCCESSFUL!"
}

printusage() {
        echo
        echo "Usage: `basename $0` [prep|pre|patch|post|clean|fixgrub] [hostname]"
        echo -e "\tprep\t-- Prep a host for patching."
        echo -e "\tpre\t-- To perform pre patching task, i.e. uncomment /opt from vfstab and run lucreate command"
        echo -e "\tpatch\t-- Run luupgrade command to patch, followed by luactivate"
        echo -e "\tpost\t-- Run the post luactivate tasks, before you run init 6"
        echo -e "\t\t   Contains fix for console redirect, mail, uncomment /etc/vfstab"
        echo -e "\tclean\t-- Clean up by deleting old BEs and patch directories."
        echo -e "\tfixgrub\t-- Just fix console redirect, incase we are just activating old BE using luactivate"
        echo
}

################
# MAIN SECTION
################

# Check to make sure that the user has provided a function and a hostname
# Or at least the correct number of args!
if [ ! "$#" -eq "2" ]; then
    printusage
    exit 1
fi

case $1 in
    prep)
        SysCheck
        SysInfo
        PatchPrep
        ;;

    pre)
        SysCheck
        SysInfo
        echo
        echo "Beginning Pre-Patch Tasks for $PATCHCLUSTER Patch Cluster on $HOST."
        comment_opt_vfstab
        ApplyPrePatches
        createBE
        echo
        echo "Pre-Patch Tasks Completed Successfully!"
        ;;

    patch)
        SysCheck
        SysInfo
        echo
        echo "Beginning Installation of $PATCHCLUSTER Patch Cluster to Boot Environment $NEWBE on $HOST."
        PatchInstall
        echo
        echo "Installation of $PATCHCLUSTER Patch Cluster to Boot Environment $NEWBE on $HOST was SUCESSFUL!"
        ;;

    post)
        SysCheck
        SysInfo
        echo
        echo "Beginning Post-Patch Tasks for $PATCHCLUSTER Patch Cluster on $HOST."
        echo
        activateBE
        mountBE
        ALT_BE=`cat /tmp/lumount_name`
        uncomment_opt_vfstab
        if [[ $PLATFORM = "i386" ]]; then
            fix_grub_after_luactivate
        fi
        fix_sendmail
        #fix_vfstab_newbe
        unmountBE
        echo
        echo "Post-Patch Tasks for $PATCHCLUSTER Patch Cluster on $HOST completed successfully!"
        echo "If all looks good, run init 6 to boot into the newly patched $NEWBE Boot Environment!"
        ;;

    clean)
        SysCheck
        SysInfo
        CleanUp
        ;;

    fixgrub)
        fix_grub_after_luactivate
        ;;

    *)
        printusage
        ;;

esac

USERID=`id |awk '{print $1}'|awk -F'(' '{print $2}'|awk -F')' '{print $1}'`
if [ "$USERID" != "root" ];then
    echo;echo
    echo "This script requires root privileges, please run the script as user root"
    echo "Fatal error, exiting.."
    exit 1
fi
