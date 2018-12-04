#!/bin/bash

## Default settings
dryRun=false
verbose=false
silent=false
snapshotsToKeep=10

Usage() { 
	printf "
Usage: $0 [parameters]

Required parameters:
-s | --source => Name of source ZFS pool.
-d | --destination => Name of ZFS pool to use as backup.

Optional parameters:
-D | --dry-run => Test run: outputs commands to console but won't run. (overrides silent and verbose modes)
-S | --silent => Silent mode: only errors and warnings will be loged.
-v | --verbose => Verbose mode: sends output also to console. (overrides silent mode)
-k | --keep-snapshots => Number of snapshots to keep. Default: $snapshotsToKeep Minimum: 1
-vols | --datasets => Limits the sync to only the specified dataset(s). Must enter value(s) between quotes (and separated with spaces). Example: --datasets \"vm-1-disk-0 vm-1-disk-1\"
	
Example: $0 -s source-pool -d dest-pool
" 1>&2
}

ExitError() {
	printf "\nERROR! Please check usage!\nMake sure your call is valid and all required parameters are specified.\n"
	Usage
	exit 2
}

## Exit script and show usage if no parameters were specified
if [[ $# -eq 0 ]] ; then
	ExitError
fi

## Set variables from parameters
while [ "$1" != "" ]; do
	case $1 in
		#required parameters
		-s | --source ) shift
						sourcePool=$1;;
		-d | --destination ) shift
						destPool=$1;;
		#optional parameters
		-D | --dry-run ) dryRun=true;;
		-S | --silent ) silent=true;;
		-v | --verbose ) verbose=true;;
		-k | --keep-snapshots ) shift
						snapshotsToKeep=$1;;
		-vols | --datasets ) shift
						datasets=$1;;
		#misc
		-h | --help )	Usage
						exit;;
		* )             ExitError;;
	esac
	shift
done

## Make sure all required variables are set
if [ -z "$sourcePool" ] || [ -z "$destPool" ]; then
	ExitError
fi

## Set common variables
currentTime=`date +"%Y-%m-%d_%H-%M-%S"` # used for naming snapshots and log messages
startTime=`date +%s` # used for script runtime calculation
syncId="_localsync_$(printf "$sourcePool$destPool" | md5sum | cut -f1 -d' ' | cut -c1-8)_"

## Set log file
logDir="/var/log/zfs-local-sync"
logFile="$logDir/$sourcePool.log"
if [ ! -d "$logDir" ]; then
  mkdir -p $logDir
fi

## Define Run, Log and Warn functions
Run() {
	command=$1
	if $dryRun; then
		# only print command to console but don't run
		printf "$command\n"
	else
		if ! $silent; then
			# send command to log file
			printf "$command\n" >> $logFile
		fi
		if $verbose; then
			# send command to console, outputs to console and log file
			printf "$command\n"
			command="$command 2>&1 | tee -a $logFile"
		else
			# send outputs only to log file
			command="$command >> $logFile 2>&1"
		fi
		# run command
		eval $command
	fi
}

Log() {
	message="### $1"
	if $dryRun; then
		# only print to console
		printf "$message\n"
	else
		if $verbose; then
			# print to console
			printf "$message\n"
		fi
		if ! $silent; then
			# send to log file
			printf "$message\n" >> $logFile
		fi
	fi
}

Warn() {
	message="###** WARNING! **### $1"
	if $dryRun; then
		# only print to console
		printf "$message\n"
	else
		# send to log file
		printf "$message\n" >> $logFile
		if $verbose; then
			# print to console
			printf "$message\n"
		fi
	fi
}

## Check for conflicting run modes
if ( $dryRun && $silent ) || ( $dryRun && $verbose ); then
	Log "Dry run was requested: silent or verbose modes will be ignored."
elif $verbose && $silent; then
	verbose=true
	silent=false
	Warn "Conflicting modes detected! Verbose overrides silent."
fi

## Check parameters for unacceptable values
if [ $snapshotsToKeep -lt 1 ]; then
	Warn "snapshotsToKeep is set to an invalid value: $snapshotsToKeep\nMinimum: 1, default: 10.\nExiting..."
	exit 2
fi

## Manage lock file for the source pool
pidFile=/var/run/zfs-local-sync_$sourcePool.pid
if [ -f $pidFile ]; then
	pid=`cat $pidFile`
	processInfo=`ps -ef | grep $pid | grep -v grep`
	if [[ -z "${processInfo// }" ]]; then
		Warn "A lock file was found: $pidFile, but no process exists with the specified PID: $pid."
		Warn "Deleting lock file and continuing with sync @ $currentTime"
	else
		Log "Another sync task is running for the specified pool: $sourcePool\n### PID: $pid"
		Log "Exiting script... $currentTime"
		exit
	fi
fi
trap "rm -f -- '$pidFile'" EXIT
echo $$ > "$pidFile"

## Begin script
Log "Beginning pool sync @ $currentTime"

if $dryRun; then
	Log "This is a dry run! No pool will be modified."
fi

## If no datasets were specified, get all existing datasets on source pool
if [ -z $datasets ]; then
	datasets=`zfs list | grep $sourcePool/ | awk '{print $1}' | tr "\n" " " | sed "s/$sourcePool\///g"`
fi

# Get all existing snapshots on source and destination pools
sourceSnapshots=`zfs list -t snapshot | grep $sourcePool/ | grep $syncId | awk '{print $1}'`
destSnapshots=`zfs list -t snapshot | grep $destPool/ | grep $syncId | awk '{print $1}'`

## Create snapshots on source pool to be sent
for dataset in $datasets; do
	Run "zfs snapshot $sourcePool/$dataset@$syncId$currentTime"
done

## Auxiliary functions
GetLatestSnapshot() {
	snapshots=$1
	dataset=$2
	echo $snapshots | tr "[:space:]" "\n" | grep $dataset | tail -1 | xargs -n1 | tr "\n" ""
}

IsDatasetFirstRun() {
	dataset=$1
	latestSnapshotOnDest=$(GetLatestSnapshot "$destSnapshots" $dataset)
	if [[ -z "${latestSnapshotOnDest// }" ]]; then
		return 0 # true
	else
		return 1 # false
	fi
}

## Send the new snapshots to the destination pool
for dataset in $datasets; do
	if [[ $dataset == *"swap"* ]]; then
		Log "Ignoring dataset: $dataset"
	elif IsDatasetFirstRun $dataset; then
		Log "No previous snapshots were found for the dataset $dataset. Executing first run."
		Run "zfs send $sourcePool/$dataset@$syncId$currentTime | zfs receive $destPool/$dataset"
	else
		latestSnapshotOnSource=$(GetLatestSnapshot "$sourceSnapshots" $dataset)
		Run "zfs send -I $latestSnapshotOnSource $sourcePool/$dataset@$syncId$currentTime | zfs receive $destPool/$dataset"
	fi
done

## Remove old snapshots if there are more than $snapshotsToKeep
PurgeSnapshots() {
	snapshots=$1
	dataset=$2
	existingSnapshots=`echo $snapshots | tr "[:space:]" "\n" | grep $dataset | tr "\n" " " | awk -F"@" '{print NF-1}'`
	if [ $existingSnapshots -gt $snapshotsToKeep ]; then
		toDelete=`echo $snapshots | tr "[:space:]" "\n" | grep $dataset | grep -m$((existingSnapshots-snapshotsToKeep)) ""`
		for snapshot in $toDelete; do
			if [[ $snapshot == *"@"* ]]; then
				Run "zfs destroy $snapshot"
			else
				Warn "\n*** Script may be attempting to delete a dataset instead of a snapshot! ***\n*** Command received: \"zfs destroy $snapshot\" ***\n*** Command skipped. ***\n#################"
			fi
		done
	fi
}
for dataset in $datasets; do
	if [[ $dataset == *"swap"* ]]; then
		continue
	elif ! IsDatasetFirstRun $dataset; then
		PurgeSnapshots "$sourceSnapshots" "$dataset"
		PurgeSnapshots "$destSnapshots" "$dataset"
	fi
done

finishTime=`date +%s`

HumanizeSeconds() {
    num=$1; min=0; hour=0; day=0
    if((num>59));then
        ((sec=num%60)); ((num=num/60))
        if((num>59));then
            ((min=num%60)); ((num=num/60))
            if((num>23));then
                ((hour=num%24)); ((day=num/24))
            else
                ((hour=num))
            fi
        else
            ((min=num))
        fi
    else
        ((sec=num))
    fi
	if((day>0)); then
		echo "$day"d "$hour"h "$min"m "$sec"s
	elif((hour>0)); then
		echo "$hour"h "$min"m "$sec"s
	elif((min>0)); then
		echo "$min"m "$sec"s
	else
		echo "$sec"s
	fi
}

runTime=`HumanizeSeconds $((finishTime-startTime))`
Log "Done in: $runTime"
