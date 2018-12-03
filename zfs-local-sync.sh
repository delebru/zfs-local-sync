#!/bin/bash

## Default settings
dryRun=false
verbose=false
snapshotsToKeep=10

Usage() { 
	printf "\nUsage: $0 [parameters]\n\nRequired parameters:\n-s | --source => Name of source ZFS pool.\n-d | --destination => Name of ZFS pool to use as backup.\n\nOptional parameters:\n-D | --dry-run => Test run. Will output commands to console but won't do anything.\n-v | --verbose => Output to console and log file.\n-k | --keep-snapshots => Number of snapshots to keep. Default: $snapshotsToKeep Minimum: 1\n-vols | --datasets => Limits the sync to only the specified dataset(s). Must enter value(s) between quotes (and separated with spaces). Example: --datasets \"vm-1-disk-0 vm-1-disk-1\"\n\nExample: $0 -s source-pool -d dest-pool\n" 1>&2
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

## Set log file
logDir="/var/log/zfs-local-sync"
logFile="$logDir/$sourcePool.log"
if [ ! -d "$logDir" ]; then
  mkdir -p $logDir
fi

## Define Run and Log functions
Run() {
	command=$1
	if $dryRun; then
		printf "$command\n"
	else
		printf "$command\n" >> $logFile
		if $verbose; then
			printf "$command\n"
			command="$command 2>&1 | tee -a $logFile"
		else
			command="$command >> $logFile 2>&1"
		fi
		eval $command
	fi
}

Log() {
	value=$1
	if $dryRun; then
		printf "$value\n"
	else
		if $verbose; then
			printf "$value\n"
		fi
		printf "$value\n" >> $logFile
	fi
}

## Check parameters for unacceptable values
if [ $snapshotsToKeep -lt 1 ]; then
	Log "Warning! snapshotsToKeep is set to an invalid value: $snapshotsToKeep\nMinimum: 1, default: 10.\nExiting..."
	exit 2
fi

## Manage lock file for the source pool
pidFile=/var/run/zfs-local-sync_$sourcePool.pid
if [ -f $pidFile ]; then
	pid=`cat $pidFile`
	processInfo=`ps -ef | grep $pid | grep -v grep`
	currentTime=`date +"%Y-%m-%d %H:%M:%S"`
	if [[ -z "${processInfo// }" ]]; then
		Log "### A lock file was found: $pidFile, but no process exists with the specified PID: $pid."
		Log "### Deleting lock file and continuing with sync. $currentTime"
	else
		Log "### Another sync task is running for the specified pool: $sourcePool\n### PID: $pid"
		Log "### Exiting script... $currentTime"
		exit
	fi
fi
trap "rm -f -- '$pidFile'" EXIT
echo $$ > "$pidFile"

## Begin script
startTime=`date +%s`
Log "######### Beginning pool sync..."

if $dryRun; then
	Log "## This is a dry run! No pool will be modified."
fi

## If no datasets were specified, get all existing datasets on source pool
if [ -z $datasets ]; then
	datasets=`zfs list | grep $sourcePool/ | awk '{print $1}' | tr "\n" " " | sed "s/$sourcePool\///g"`
fi

# Get all existing snapshots on source and destination pools
sourceSnapshots=`zfs list -t snapshot | grep $sourcePool/ | grep zfs-local-sync | awk '{print $1}'`
destSnapshots=`zfs list -t snapshot | grep $destPool/ | grep zfs-local-sync | awk '{print $1}'`

## Create snapshots on source pool to be sent
currentTime=`date +"%Y-%m-%d_%H-%M-%S"`
for dataset in $datasets; do
	Run "zfs snapshot $sourcePool/$dataset@_zfs-local-sync_$currentTime"
done

## Auxiliary functions
GetLatestSnapshot() {
	dataset=$1
	echo $sourceSnapshots | tr "[:space:]" "\n" | grep $dataset | tail -1 | xargs -n1 | tr "\n" " "
}

IsDatasetFirstRun() {
	dataset=$1
	latestSnapshot=$(GetLatestSnapshot $dataset)
	if [[ -z "${latestSnapshot// }" ]]; then
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
		Log "## No previous snapshots were found for the dataset $dataset. Executing first run."
		Run "zfs send $sourcePool/$dataset@_zfs-local-sync_$currentTime | zfs receive $destPool/$dataset"
	else
		latestSnapshot=$(GetLatestSnapshot $dataset)
		Run "zfs send -I $latestSnapshot $sourcePool/$dataset@_zfs-local-sync_$currentTime | zfs receive $destPool/$dataset"
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
				Log "########### WARNING! #############\nScript may be attempting to delete a dataset instead of a snapshot!\nCommand received: \"zfs destroy $snapshot\"\n#################"
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
Log "##### Done in: $runTime"
