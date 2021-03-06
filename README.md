# zfs-local-sync
Bash script to automate ZFS snapshot creation and syncing. Tested and working on Proxmox VE 5.2, should be compatible with any other distro using [ZFS on Linux](https://github.com/zfsonlinux/zfs).

It may not look super fancy but it does it's job reliably. Comments and contributions are welcome :)

### Use cases & requirements
This script can be used to automatically create snapshots and copy them to another local pool.

Limitations:
* At least 2 ZFS pools are required; one with the content you want to make redundant, and another one to receive the datasets and snapshots.
* The destination (backup) pool must have enough free space to allocate the source datasets and snapshots.
* The destination pool must not have datasets with the same name as the source pool.

### Installation
```
cd /opt && git clone https://github.com/delebru/zfs-local-sync.git
```

### Parameters
Required parameters:
* -s | --source: Name of source ZFS pool.
* -d | --destination: Name of ZFS pool to use as backup.

Optional parameters:
* -D | --dry-run => Test run: outputs commands to console but won't run. (overrides silent and verbose modes)
* -S | --silent => Silent mode: only errors and warnings will be loged.
* -v | --verbose => Verbose mode: sends output also to console. (overrides silent mode)
* -k | --keep-snapshots: Number of snapshots to keep. Default: 10 Minimum: 1
* -vols | --datasets: Limits the sync to only the specified dataset(s). Must enter value(s) between quotes (and separated with spaces). Example: --datasets "vm-1-disk-0 vm-1-disk-1"

### First run
Please do a dry run (-D) to make sure the script will be doing what you expect it to.

To sync all the datasets in the source pool to the backup pool:
```
/bin/bash /opt/zfs-local-sync/zfs-local-sync.sh -s source_pool_name -d backup_pool_name -D
```

To sync only certain datasets (for example vm-1-disk-0 and vm-1-disk-1):
```
/bin/bash /opt/zfs-local-sync/zfs-local-sync.sh -s source_pool_name -d backup_pool_name -vols "vm-1-disk-0 vm-1-disk-1" -D
```

### Automation
After doing a dry run and confirming the script will do what you need, add an entry to your crontab. 

For example to sync every 15 minutes:
```
*/15 * * * * root /bin/bash /opt/zfs-local-sync/zfs-local-sync.sh -s source_pool_name -d backup_pool_name
```

To duplicate multiple pools, one entry per source pool is required. A single destination pool may be used for various source pools as long as it satisfies the requirements specified above (enough free space and non conflicting dataset names):
```
*/15 * * * * root /bin/bash /opt/zfs-local-sync/zfs-local-sync.sh -s source_pool_name -d backup_pool_name
*/15 * * * * root /bin/bash /opt/zfs-local-sync/zfs-local-sync.sh -s source_pool_name_2 -d backup_pool_name
```

### Logs & output
By default the script will write the executed commands and any output to a log file. One log file will be created for every source pool:
```
/var/log/zfs-local-sync/source_pool_name.log
```
#### Special modes
* Dry run: nothing will be executed nor any log file will be created. Only the commands to be run will be shown on console.
* Verbose: commands and output will be go to both: log file and console.
* Silent: only warnings will be written to the log file.
