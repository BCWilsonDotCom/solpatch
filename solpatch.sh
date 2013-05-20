#!/bin/bash
# Script to automate the Solaris patching process.
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

############################
# FUNCTIONS
############################
Confirm_To_Proceed() {
    #Just a function that will prompt the user to confirm before proceeding, whenever necessary.
    CONF_YN="A" ; CONFYN=" "
    until [ "$CONF_YN" = "y" ] || [ "$CONF_YN" = "n" ]
    do
        echo;echo "Do you want to Proceed (Y/N): \c" ; read CONFYN
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
    elif  [[ "`hostname`" != "mrtg" && "`hostname`" = {$HOST} ]]; then
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
    elif  [[ "`hostname`" != "mrtg" && "`hostname`" = {$HOST} ]]; then
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
    if [[ "`hostname`" = "mrtg" && {$HOST} != "mrtg" ]]; then
        CURRENTBE=`ssh $HOST '/sbin/lucurr'`
    elif [[ "`hostname`" != "mrtg" && "`hostname`" = {$HOST} ]]; then
        CURRENTBE=`/sbin/lucurr`
    else
        echo "ERROR!"
        echo "Unable to determine the current Boot Environment!"
        exit 5
    fi

    #Get the platform type
    if [[ "`hostname`" = "mrtg" && {$HOST} != "mrtg" ]]; then
        PLATFORM=`ssh $HOST 'uname -p'`
    elif [[ "`hostname`" != "mrtg" && "`hostname`" = {$HOST} ]]; then
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

    echo; echo "Beginning prep of $HOST for $PATCHCLUSTER $PLATFORM patches."

    if [[ "`hostname`" = "mrtg" && {$HOST} != "mrtg" ]]; then
        #Create the directories we'll need for storing the proper patch cluster.
        ssh $HOST "mkdir -p /opt/patching/$PATCHCLUSTER/$PLATFORM"
        if [[ $? != 0 ]]; then echo "ERROR! Failed to create patching directory on $HOST"; exit 7; fi

        #SCP the proper patch cluster and solpatch script to the host.
        scp -rp /opt/patching/$PATCHCLUSTER/$PLATFORM/*zip $HOST:/opt/patching/$PATCHCLUSTER/$PLATFORM/
        if [[ $? != 0 ]]; then echo "ERROR! Failed to SCP patching archive to $HOST!"; exit 7; fi
        scp -p /opt/patching/solpatch.sh $HOST:/opt/patching/
        if [[ $? != 0 ]]; then echo "ERROR! Failed to SCP patching script to $HOST!"; exit 7; fi

        #Unzip the patches on the host.
        ssh $HOST "unzip -q /opt/patching/$PATCHCLUSTER/$PLATFORM/*zip"
        if [[ $? != 0 ]]; then echo "ERROR! Failed to unzip the patching archive on $HOST!"; exit 7; fi
    elif [[ "`hostname`" = "mrtg" && "`hostname`" = {$HOST} ]]; then
        #We're on mrtg, and trying to patch it. Let's just unzip the patches we need.
        unzip -q /opt/patching/$PATCHCLUSTER/$PLATFORM/*zip
        if [[ $? != 0 ]]; then echo "ERROR! Failed to unzip the patching archive on $HOST!"; exit 7; fi
    else
        echo "I've no idea what's going on."; exit 7
    fi

    echo "Host Prep Completed Sucessfully!"
}

ApplyPrePatches() {
    #Solaris CPUs sometimes require certain patches already in place.
    #This function will make sure that any PreReqs are taken care of.
    echo "Applying patching command and lu patches"
    /opt/patching/$PATCHCLUSTER/$PLATFORM/installpatchset --s10patchset --apply-prereq
}

comment_opt_vfstab() {
    echo "Commenting out rpool/opt from /etc/vfstab"
    sed -e 's/rpool\/opt/#rpool\/opt/g' /etc/vfstab > /tmp/etcvfstab
    cp /tmp/etcvfstab /etc/vfstab
}

uncomment_opt_vfstab() {
    echo "UnCommenting out rpool/opt from /etc/vfstab"
    sed -e 's/#rpool\/opt/rpool\/opt/g' /etc/vfstab > /tmp/etcvfstab
    cp /tmp/etcvfstab /etc/vfstab
    sed -e 's/#rpool\/opt/rpool\/opt/g' ${ALT_BE}/etc/vfstab > /tmp/etcvfstab
    cp /tmp/etcvfstab ${ALT_BE}/etc/vfstab
}

fix_vfstab_newbe() {
    echo;echo "Looking for issues with new BE vfstab file"
    VFSFILE="${ALT_BE}/etc/vfstab"
    echo "---------------------------------------"
    grep -n rpool/ROOT/${NEWBE} ${VFSFILE}|grep zfs
    if [ $? -eq 0 ];then
        echo; echo "Uncomment these lines from New BE "
        Confirm_To_Proceed
    fi
    gval=`grep -n rpool/ROOT/${NEWBE} ${VFSFILE}|grep zfs|awk -F':' '{print $1}'|head -1`
    while [ ! -z $gval ]
    do
        (echo "${gval}d"; echo 'wq') | ex -s ${VFSFILE}
        gval=`grep -n rpool/ROOT/${NEWBE} ${VFSFILE}|grep zfs|awk -F':' '{print $1}'|head -1`
    done
}

fix_grub_after_luactivate() {
    #Function to fix the console variables on menu.lst after luactivate command has been invoked.
    PBEMENUFILE="/etc/lu/DelayUpdate/menu.pbe"
    MENUFILE="/etc/lu/DelayUpdate/menu.lst"
    TMPFILE="/tmp/newmenu.lst"

    PBE_CONS_VALUE=`cat ${PBEMENUFILE}|grep ZFS-BOOTFS|grep console|head -1|awk '{print $4}'|awk -F'$' '{print $2}'`
    sed -e s/"ZFS-BOOTFS"/"${PBE_CONS_VALUE}"/g ${MENUFILE} > ${TMPFILE}
    cp ${TMPFILE} ${MENUFILE}
    PBE_CONS_VALUE=`cat ${PBEMENUFILE}|grep 'boot/multiboot'|grep console|head -1|awk '{print $NF}'`
    sed -e s/"console=ttyb"/"${PBE_CONS_VALUE}"/g ${MENUFILE} > ${TMPFILE}
    cp ${TMPFILE} ${MENUFILE}
}

fix_sendmail() {
    cp /lib/svc/method/smtp-sendmail ${ALT_BE}/lib/svc/method/smtp-sendmail
    cp /etc/mail/local.cf ${ALT_BE}/etc/mail/local.cf
    echo "#!/bin/ksh" > ${ALT_BE}/etc/rc3.d/S90stop_sendmail-client
    echo "svcadm disable svc:/network/sendmail-client:default" >> ${ALT_BE}/etc/rc3.d/S90stop_sendmail-client
    echo "rm /etc/rc3.d/S90stop_sendmail-client" >> ${ALT_BE}/etc/rc3.d/S90stop_sendmail-client
    chmod 755 ${ALT_BE}/etc/rc3.d/S90stop_sendmail-client
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
        echo "Running Pre patch tasks"
        echo "------------------------------------";echo
        comment_opt_vfstab
        cat /etc/vfstab
        echo
        echo "vfstab comment done; please verify the output above from /etc/vfstab"
        Confirm_To_Proceed
        ApplyPrePatches
        echo "prereq patch util and lu patches have been applied"
        echo "preparing to run lucreate"
        Confirm_To_Proceed
        echo;echo "Running lucreate -n ${NEWBE} command, please standby"
        lucreate -n ${NEWBE} 
        lu_cmd_check $? lucreate
        echo; echo;
        echo "pre tasks completed successfully, please check for any additional details";echo
        ;;

    patch)
        SysCheck
        SysInfo
        echo "Running the patch tasks"
        echo "------------------------------------";echo
        echo "WARNING: You are about to create a"
        echo "New BE named ${NEWBE} and install"
        echo "patches for $PATCHCLUSTER to it."
        echo "Are you sure you want to continue?"
        Confirm_To_Proceed

        PATCH_PATH="/opt/patching/$PATCHCLUSTER/$PLATFORM/"
        /opt/patching/$PATCHCLUSTER/$PLATFORM/installpatchset --s10patchset -B ${NEWBE}
        echo "------------------------------------------------------------------------------------------------"
        echo "------------------------------------------------------------------------------------------------"
        lu_cmd_check $? luupgrade
        echo;echo;echo "Now activating the newly patch BE: ${NEWBE}"
        Confirm_To_Proceed
        echo "Running command: luactivate ${NEWBE}"
        luactivate ${NEWBE}
        lu_cmd_check $? luactivate
        echo
        echo "------------------------------------------------------------------------------------------------"
        echo "patch tasks completed successfully, please check for any additional details";echo
        ;;

    post)
        SysCheck
        SysInfo 
        echo "Running post tasks"
        echo "------------------------------------"
        echo "New BE name detected is : ${NEWBE}"
        Confirm_To_Proceed
        lumount ${NEWBE} > /tmp/lumount_name
        lu_cmd_check $? lumount
        ALT_BE=`cat /tmp/lumount_name`
        echo; echo "Task 1. uncomment opt from vfstab on both old & new BE"
        uncomment_opt_vfstab
        echo "done."
        echo; echo "Task 2. Fix console redirection"
        fix_grub_after_luactivate
        echo "done."
        echo; echo "Task 3. Fix sendmail issue"
        fix_sendmail
        echo "done."
        echo; echo "Task 4. Fix /etc/vfstab issue on new BE for /var"
        fix_vfstab_newbe
        echo "done."
        echo; echo "unmounting new BE ${NEWBE}"
        luumount ${NEWBE}
        lu_cmd_check $? luumount
        echo "post-patch tasks completed successfully, please check for any additional details";echo
        echo "If all looks good then run the init 6 command"
        ;;

    clean)
        SysCheck
        SysInfo
        CleanUp
        ;;

    fixgrub)
        echo "Going to fix the console redirection"
        fix_grub_after_luactivate
        echo "done."
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
