# Merge /home into / on a Hetzner RAID 1 server

This guide removes the `/home` partition and grows `/` into its space. It applies to a dedicated server that Hetzner
`installimage` set up with software RAID 1 on two disks. RAID 1 keeps the same data on both disks, so one disk can fail
without data loss. The result is one large `/`, still mirrored on both disks. You do all steps on the running system,
and you reboot only at the end.

| Item | Value |
|---|---|
| Done on | 2026-11-22, a Hetzner dedicated server with two 4 TB disks (`ST4000NM0024`) |
| Operating system | Rocky Linux 9.8, image `Rocky-98-amd64-base`, kernel `5.14.0-687.54.1.el9_8.x86_64` |
| Tools | `parted` 3.5, `mdadm` 4.4, e2fsprogs 1.46.5 (`resize2fs`), util-linux 2.37.4 (`partx`) |
| Result | `/` grew from 2.0 TB to 3.6 TB. `md2` grew from 2111699968 KiB to 3872281415 KiB |
| Status | All nine steps were done and checked, the test reboot included |

## Start layout

Each disk has the same five partitions. Each pair of partitions forms one RAID 1 array.

| Partitions | Array | Size | Use |
|---|---|---|---|
| `sda1`, `sdb1` | `md0` | 32 GB | swap |
| `sda2`, `sdb2` | `md1` | 1 GB | `/boot`, ext3 |
| `sda3`, `sdb3` | `md2` | 2 TB | `/`, ext4 |
| `sda4`, `sdb4` | `md3` | 1.6 TB | `/home`, ext4 |
| `sda5`, `sdb5` | none | 1 MB | BIOS boot partition, which GRUB needs to start the server |

The merge changes only partitions 3 and 4 and the arrays `md2` and `md3`. Do not change `md0`, `md1` or partition 5.

The merge works because partition 4 starts where partition 3 ends, at 2047 GiB on each disk. After you delete
partition 4, partition 3 can grow to the end of the disk. Then the array `md2` and the ext4 filesystem on it grow into
the new space.

## Before you start

Copy all data from `/home` to another place before you start. Step 3 deletes the `/home` filesystem and all data on it.

1. Log in as root and start a `tmux` session:

   ```bash
   dnf install -y tmux
   tmux new -s merge
   ```

   If your SSH connection drops, the commands continue in `tmux`. Connect again and run `tmux attach -t merge`.

2. Make sure that the layout matches this guide:

   ```bash
   lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
   parted -s /dev/sda unit GiB print
   parted -s /dev/sdb unit GiB print
   ```

   The `End` of partition 3 must be the `Start` of partition 4 on both disks. If another partition is between them,
   stop. This guide does not apply to that layout.

3. Make sure that no process uses `/home`:

   ```bash
   ls -la /home
   fuser -vm /home
   ```

   On a new server, `/home` holds only `lost+found`. If `fuser` lists a process, stop that process first.

## Procedure

### 1. Back up the configuration files

```bash
cp -a /etc/fstab /etc/fstab.bak
cp -a /etc/mdadm.conf /etc/mdadm.conf.bak
```

### 2. Remove /home from the system

```bash
umount /home
sed -i '\#[[:space:]]/home[[:space:]]#d' /etc/fstab
grep -v '^#' /etc/fstab
```

The output must show no `/home` line. The empty folder `/home` stays on `/`.

### 3. Remove the md3 array

```bash
mdadm --stop /dev/md3
mdadm --zero-superblock /dev/sda4 /dev/sdb4
sed -i '\#ARRAY /dev/md/3 #d' /etc/mdadm.conf
grep ARRAY /etc/mdadm.conf
```

`--zero-superblock` deletes the RAID label on both partitions, so the system does not assemble `md3` again. The output
of `grep` must show only `md/0`, `md/1` and `md/2`. After this step, you cannot get `/home` back.

### 4. Grow partition 3 on both disks

```bash
for d in /dev/sda /dev/sdb; do
  parted -s "$d" rm 4
  parted -s "$d" ---pretend-input-tty resizepart 3 100% <<< 'Yes'
  partx -u "$d"
done
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS /dev/sda /dev/sdb
```

Partition 3 is in use by `/`, so `parted` asks you to answer `Yes`. `---pretend-input-tty` with `<<< 'Yes'` gives that
answer. `partx -u` gives the new size to the kernel while the partition is in use. Make sure that `sda3` and `sdb3`
show 3.6T, and that `sda4` and `sdb4` are gone. On the test server, both partitions had 7744827023 sectors after this
step.

### 5. Grow the md2 array

On a new server, the RAID copy of `md2` (resync) usually still runs. Read its state first:

```bash
cat /sys/block/md2/md/sync_action
```

If the output is `idle`, run only `mdadm --grow /dev/md2 --size=max`. If the output is `resync`, `mdadm` refuses the
grow with this error:

```text
mdadm: /dev/md2 is performing resync/recovery and cannot be reshaped
```

In that case, pause the resync, grow the array, and start the resync again:

```bash
echo frozen > /sys/block/md2/md/sync_action
cat /sys/block/md2/md/sync_action
mdadm --grow /dev/md2 --size=max
echo idle > /sys/block/md2/md/sync_action
```

The second command must print `frozen`. If `mdadm --grow` fails, still run `echo idle`. If you do not, the resync stays
paused, and the second disk does not get a full copy.

Make sure that the array is larger and that the resync runs:

```bash
grep -A3 '^md2' /proc/mdstat
```

The block count must be larger than before. For a short time, the resync can show `resync=DELAYED`. Then it continues
from its checkpoint and also copies the new space. On the test server, `md2` showed 3872281415 blocks, and the resync
needed about 400 minutes for the full 3.6 TB.

### 6. Grow the ext4 filesystem

```bash
resize2fs /dev/md2
```

The first output lines are:

```text
resize2fs 1.46.5 (30-Dec-2021)
Filesystem at /dev/md2 is mounted on /; on-line resizing required
old_desc_blocks = 252, new_desc_blocks = 462
```

Then `resize2fs` works with no output until it finishes. Do not stop it. It ends with a line that starts with
`The filesystem on /dev/md2 is now`. On the test server, it took about 6 minutes for the new 1.6 TB, while the resync
ran. To see the progress from a second session, run this command:

```bash
dmesg | grep 'EXT4-fs (md2)' | tail -1
```

When it finishes, the kernel log shows `resized filesystem to 968070353` (the new block count of 4 KiB blocks). Make
sure that `/` has its new size:

```bash
df -h /
```

### 7. Set the SELinux label of /home

```bash
restorecon -Rv /home
ls -Zd /home
```

The `/home` folder on `/` was covered by the old mount, so it had no SELinux label (`unlabeled_t`). After `restorecon`,
it must show `home_root_t`.

### 8. Build the boot image again

```bash
dracut -f
lsinitrd -f etc/mdadm.conf | grep ARRAY
```

The boot image (initramfs) holds its own copy of `mdadm.conf`, and the old copy still lists `md3`. `dracut -f` prints
nothing and took 2 to 3 minutes on the test server, because the resync kept the disks busy. Do not reboot while
`dracut` runs, because a partly written image can stop the server from booting. The `lsinitrd` output must show only
`md/0`, `md/1` and `md/2`.

### 9. Reboot and make sure that the server starts

```bash
reboot
```

After the reboot, log in again and run these commands:

```bash
df -h /
grep -A3 '^md2' /proc/mdstat
ls -Zd /home
```

`/` must show 3.6T, and `/home` must show `home_root_t`. On the test server, SSH answered about one minute after the
reboot. `/` showed 3.6T with 3.4T free, and the resync continued at 6.5%. A reboot during the resync is safe. The array has an internal
bitmap (a record of the areas that are not copied yet), so the resync continues after the reboot.

## Why the pause of the resync is safe

The `mdadm` 4.4 source has a test for an array that is too busy to grow. If `sync_action` reads `resync`,
`sysfs_freeze_array` in `sysfs.c` (lines 981 to 1002) returns -1. `Grow.c`, lines 1964 to 1966, then prints the error
from step 5. When `sync_action` already reads `frozen`, the same function returns 0, and the grow continues.

The kernel has its own check. In Linux 5.14 `drivers/md/md.c`, `update_size` returns `-EBUSY` while the resync thread
runs. A write of `frozen` stops that thread. In `drivers/md/raid1.c`, `raid1_resize` also grows the internal bitmap. If the
array was fully copied before the grow, it moves the resync checkpoint. Otherwise, the checkpoint stays. On the test
server, the checkpoint was at 6.3%, so the resync continued from that point after `echo idle`.

## If something fails

| Problem | Action |
|---|---|
| `mdadm --grow` fails after `echo frozen` | Run `echo idle > /sys/block/md2/md/sync_action`. Wait until `/proc/mdstat` shows no resync, then run `mdadm --grow /dev/md2 --size=max` alone. Continue with step 6 |
| The terminal shows no prompt for a long time | From a second session, run `ps -eo pid,etime,stat,args \| grep -E 'resize2fs\|dracut'`. If the command does not run, the SSH session is frozen. Press Enter, `~` and `.` to close it, and connect again |
| SSH answers `Not allowed at this time` | OpenSSH 9.8 and later blocks an IP address after repeated failed logins (`PerSourcePenalties`). Make no login attempts for 10 minutes, then try once |
| A step before step 3 fails | Copy the `.bak` files back to `/etc/fstab` and `/etc/mdadm.conf`, then run `mount /home` |
| A step after step 3 fails | `/home` cannot come back. Finish the steps, or install the server again with `installimage` from the Hetzner Rescue System |

## Sources

- mdadm 4.4: [`sysfs.c`](https://github.com/md-raid-utilities/mdadm/blob/mdadm-4.4/sysfs.c) and
  [`Grow.c`](https://github.com/md-raid-utilities/mdadm/blob/mdadm-4.4/Grow.c)
- Linux 5.14: [`drivers/md/md.c`](https://github.com/torvalds/linux/blob/v5.14/drivers/md/md.c) and
  [`drivers/md/raid1.c`](https://github.com/torvalds/linux/blob/v5.14/drivers/md/raid1.c)
- [OpenSSH 9.8 release notes](https://openssh.com/txt/release-9.8), for `PerSourcePenalties`
