# zfs-local-sync
Bash script to automate ZFS snapshots and sync to a local pool. Tested and working on Proxmox VE 5.2.

This may not be a state of the art script but it does it's job reliably. Comments and contributions are welcome :)


Use at your own risk! First do a dry run (-D) to see which pools/datasets will be affected and what commands will be executed. Then manually run the script at least 2 times to make sure it is doing what you expect for your setup.

After verifying it is doing what you need, add it to crontab. For a sync every 15 minutes:
`*/15 * * * * root /bin/bash /root/zfs-local-sync.sh -s source_pool_name -d backup_pool_name`

```
Usage: /root/zfs-local-sync.sh [parameters]

Required parameters:
-s | --source => Name of source ZFS pool.
-d | --destination => Name of ZFS pool to use as backup.

Optional parameters:
-D | --dry-run => Test run. Will output commands to console but won't do anything.
-v | --verbose => Output to console and log file.
-k | --keep-snapshots => Number of snapshots to keep. Default: 10 Minimum: 1
-vols | --datasets => Limits the sync to only the specified dataset(s). Must enter value(s) between quotes (and separated with spaces). Example: --datasets "vm-1-disk-0 vm-1-disk-1"

Example: /root/zfs-local-sync.sh -s source-pool -d dest-pool
```

By default the script will not do any output unless enabeling verbose or dry run. All output will go to a log file: 
```
/var/log/zfs-local-sync/*POOL_NAME*.log
```
