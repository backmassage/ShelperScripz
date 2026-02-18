# DAS BTRFS Setup Guide — Arch Linux

> **Hardware:** 4-Bay USB 3.2 DAS → Ryzen Arch Linux Mini PC
> **Starting Drive:** 1× 16TB Seagate IronWolf Pro
> **Goal:** Expandable media pool (up to 4× 16TB), max usable space, separate backups
> **Network Access:** Single SMB share — one drive letter in Windows

This guide sets up your DAS as a single network drive you can access from Windows (and
your phone). Start with one 16TB drive now, drop in more later — the pool grows
transparently and the mapped drive in Windows just gets bigger. No virtual drives, no
split shares, just one big disk on the network.

Everything here assumes you're working from a terminal on your Arch box with `sudo`
access.

---

## Step 0: Prerequisites

Install the tools you'll need upfront:

```bash
sudo pacman -S btrfs-progs samba smartmontools
```

- `btrfs-progs` — BTRFS filesystem utilities (format, manage, scrub).
- `samba` — SMB file sharing for Windows and phone access (configured in Step 7).
- `smartmontools` — drive health monitoring via S.M.A.R.T. (useful for `smartctl`).

---

## Step 1: Identify Your Drive

Plug in your DAS and find the IronWolf:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN
```

Look for your 16TB drive on a `usb` transport. It will show up as something like
`/dev/sda` or `/dev/sdb`.

**Double-check you have the right drive before proceeding — formatting is destructive:**

```bash
sudo smartctl -i /dev/sdX
```

Confirm the model and serial number match your IronWolf Pro.

> ⚠️ Replace `/dev/sdX` with your actual device name throughout this entire guide.

---

## Step 2: Partition the Drive

Using a GPT partition table keeps things clean and future-proof, especially in a
multi-drive enclosure where device names can shift around:

```bash
sudo parted /dev/sdX mklabel gpt
sudo parted /dev/sdX mkpart mediapool btrfs 0% 100%
```

> Note: On GPT, the first argument to `mkpart` is the partition **name** (not a type
> like "primary" — that's an MBR concept). We name it `mediapool` for clarity, but
> the name is cosmetic and doesn't affect functionality.

This creates a single partition at `/dev/sdX1`. All subsequent commands target this
partition — not the raw device.

---

## Step 3: Create the BTRFS Filesystem

```bash
sudo mkfs.btrfs -L mediapool /dev/sdX1
```

- `-L mediapool` assigns a human-readable label. You'll use this label for mounting,
  which is more reliable than device paths for USB drives.
- With a single drive, BTRFS defaults to "single" profile — no redundancy, maximum
  usable space. This is exactly what we want.

Verify the filesystem was created:

```bash
sudo btrfs filesystem show mediapool
```

You should see your 16TB IronWolf listed under the `mediapool` label.

---

## Step 4: Set Up Auto-Mount via fstab

USB device names (like `/dev/sdb`) can change between boots or when you plug drives in a
different order. Mounting by UUID avoids this problem entirely.

First, create the mount point and get your filesystem's UUID:

```bash
sudo mkdir -p /mnt/media
sudo blkid /dev/sdX1
```

Copy the `UUID="..."` value, then edit your fstab:

```bash
sudo nano /etc/fstab
```

Add this entry (replace the UUID with yours):

```
# ──────────────────────────────────────────────────────────────
# DAS Media Pool — BTRFS on USB 3.2
# ──────────────────────────────────────────────────────────────
UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  /mnt/media  btrfs  noatime,compress=zstd:1,nofail,x-systemd.device-timeout=10  0 0
```

### What each mount option does

| Option                         | Purpose |
|--------------------------------|---------|
| `noatime`                      | Skips updating "last accessed" timestamps on every read. Reduces unnecessary disk writes and improves performance. There's almost never a reason to track access times on a media server. |
| `compress=zstd:1`              | Applies lightweight Zstandard compression. Level 1 is nearly free on CPU. Won't shrink video files (they're already compressed), but it helps with metadata, subtitles, `.nfo` files, and other small text. Can actually *improve* USB throughput by reducing the amount of data transferred over the bus. |
| `nofail`                       | **Critical for a USB DAS.** Without this, if the DAS isn't plugged in or hasn't powered up yet at boot, systemd will drop you into an emergency shell instead of booting normally. |
| `x-systemd.device-timeout=10` | Tells systemd to wait a maximum of 10 seconds for the DAS to appear before giving up. Prevents long boot hangs if the enclosure is slow to initialize or disconnected. |

### Test it

```bash
sudo mount -a                 # mount everything defined in fstab
df -h /mnt/media              # confirm it's mounted and shows ~14.5 TiB
```

---

## Step 5: Set Permissions

Set ownership so your user can read and write freely:

```bash
sudo chown -R youruser:youruser /mnt/media
```

> Replace `youruser` with your actual Linux username. You can check it with `whoami`.

If Jellyfin or Plex also needs access, add your user to the media service's group (or
vice versa) rather than splitting ownership. Since everything lives in one shared pool,
simple is better:

```bash
sudo usermod -aG youruser jellyfin
sudo systemctl restart jellyfin
```

This lets Jellyfin read files owned by your user without complicating the permissions
model.

---

## Step 6: Verify the Filesystem

Before moving on to network sharing, confirm everything is healthy:

```bash
# Show the pool and its devices
sudo btrfs filesystem show mediapool

# Detailed space usage breakdown
sudo btrfs filesystem usage /mnt/media
```

### Test USB 3.2 transfer speed

```bash
sudo dd if=/dev/zero of=/mnt/media/testfile bs=1M count=1024 oflag=direct status=progress
sudo rm /mnt/media/testfile
```

**Expected:** roughly 300–400 MB/s on USB 3.2 Gen 2.

If you're seeing under 100 MB/s, the enclosure may have negotiated USB 2.0 instead.
Check with:

```bash
dmesg | grep -i usb | grep -i speed
```

Look for "SuperSpeed" (USB 3.x) vs. "high-speed" (USB 2.0). If it fell back, try a
different cable or port — USB 3.2 is picky about cable quality.

---

## Step 7: Network Sharing with Samba (SMB)

Samba speaks the SMB protocol, which is what Windows uses natively for file sharing.
We'll expose the entire DAS pool as a single share — it shows up in Windows as one drive
letter, just like plugging in a local disk.

### Create the Samba configuration

Arch doesn't ship a default `smb.conf`, so we'll write one from scratch:

```bash
sudo nano /etc/samba/smb.conf
```

Paste this configuration:

```ini
[global]
   workgroup = WORKGROUP
   server string = Media Server
   server role = standalone server

   # Security — password-required access, no guest
   map to guest = never
   usershare allow guests = no

   # Disable printer sharing (not needed, reduces log noise)
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes

   # Logging — one log file per connecting machine
   log file = /var/log/samba/%m.log
   max log size = 50

# ── Share ─────────────────────────────────────────────────────

[Media Pool]
   path = /mnt/media
   browseable = yes
   read only = no
   valid users = youruser
   create mask = 0664
   directory mask = 0775
```

> ⚠️ Replace `youruser` with your actual Linux username.

That's it — one share, pointing at the root of the pool. Organize it however you want
with regular folders (Movies, TV Shows, Backups, whatever). When you add drives to the
pool later, this share just gets bigger.

**What the share options mean:**

| Option           | Purpose |
|------------------|---------|
| `browseable`     | The share shows up when you browse the server in File Explorer. |
| `read only = no` | Full read/write access for the connected user. |
| `valid users`    | Only this user can connect. Keeps it locked down to just you. |
| `create mask`    | New files get `0664` permissions (owner read/write, group read/write, others read). |
| `directory mask` | New directories get `0775` (same as above, plus execute bit for directory traversal). |

### Set your Samba password

Samba maintains its own password database, separate from your Linux login password. The
username must match a real Linux user, but the password can be different:

```bash
sudo smbpasswd -a youruser
```

You'll be prompted to create a password. This is what you'll type on Windows and your
phone to connect.

### Validate the configuration

```bash
testparm
```

If it prints "Loaded services file OK" you're good. Fix any errors it reports before
continuing.

### Enable and start Samba

```bash
sudo systemctl enable --now smb nmb
```

- `smb` — the core file sharing service.
- `nmb` — NetBIOS name resolution. This lets Windows find your Arch box by hostname
  (e.g., `\\my-archbox`) instead of requiring you to remember the IP address.

The `--now` flag starts the services immediately in addition to enabling them for future
boots.

### Open the firewall (if applicable)

If you're running `firewalld`:

```bash
sudo firewall-cmd --permanent --add-service=samba
sudo firewall-cmd --reload
```

If you're running `ufw`:

```bash
sudo ufw allow samba
```

If you're not running a firewall, skip this step.

### Verify from the Arch box

```bash
smbclient -L localhost -U youruser
```

You should see `Media Pool` listed as a share.

---

## Step 8: Connect Your Devices

### Windows — Map as a drive letter

1. Open **File Explorer**.
2. In the address bar, type `\\YOUR-HOSTNAME` or `\\192.168.x.x` (your mini PC's local IP).
3. Enter your Samba username and password when prompted.
4. You'll see **Media Pool** as a network folder.

**To map it as a persistent drive letter:**

Right-click the share → **Map network drive...** → pick a letter (e.g., `Z:`) → check
**Reconnect at sign-in** → enter your credentials.

Now `Z:\` is your DAS. Create folders, copy files, whatever — it behaves like a local
disk. When you add more drives to the pool later, `Z:\` just has more free space.

> **Tip:** Find your mini PC's IP with `ip addr show` on the Arch box. For a stable
> address, set a static IP or create a DHCP reservation in your router's admin page.
> This prevents your mapped drive from breaking if the IP changes after a reboot.

### Phone

**Android:** Most file managers support SMB natively — Solid Explorer, CX File Explorer,
and Total Commander all work well. Add a remote/network location and enter
`smb://192.168.x.x/Media Pool` with your Samba credentials.

**iOS:** The built-in **Files** app supports SMB. Tap **Browse** → **⋯** menu →
**Connect to Server** → enter `smb://192.168.x.x/Media Pool`.

Media apps like **VLC**, **Kodi**, and **Jellyfin** can also mount SMB shares as media
sources, so you can stream files directly from the DAS to your phone without downloading
them first.

---

## Future: Adding Drives 2, 3, and 4

One of the main reasons we chose BTRFS is how painless expansion is. When you pick up
another 16TB IronWolf, here's the entire process:

### 1. Partition the new drive

```bash
sudo parted /dev/sdY mklabel gpt
sudo parted /dev/sdY mkpart mediapool btrfs 0% 100%
```

### 2. Add it to the existing pool

This happens live — no downtime, no unmounting:

```bash
sudo btrfs device add /dev/sdY1 /mnt/media
```

Your pool just got 16TB larger.

### 3. Rebalance and protect metadata

```bash
sudo btrfs balance start -dconvert=raid0 -mconvert=raid1 /mnt/media
```

> ⚠️ **This takes a long time.** Rebalancing rewrites and redistributes all existing data
> across the drives. On a pool with several terabytes of media, expect it to run for many
> hours. It operates in the background and the filesystem stays usable, but I/O
> performance will be reduced until it finishes. You can check progress with:
> `sudo btrfs balance status /mnt/media`

What this does:

- `-dconvert=raid0` — stripes your **data** across all drives. This maximizes usable
  space and improves read throughput. No fault tolerance (a single drive failure loses
  data), but you have separate backups so this is an acceptable tradeoff.
- `-mconvert=raid1` — mirrors your **metadata** across two drives. Metadata is the
  filesystem's internal bookkeeping (directory structure, file locations, checksums). It's
  tiny — a few GB at most — but losing it destroys the entire filesystem. Mirroring it
  is cheap insurance that costs almost no space.

> **Strong recommendation:** Once you have 2+ drives, always keep metadata in raid1. It
> uses negligible space and protects against the single most catastrophic failure mode in
> BTRFS.

### 4. Verify

```bash
sudo btrfs filesystem show mediapool
sudo btrfs filesystem usage /mnt/media
```

### Capacity math (all 4 bays filled)

| Configuration                        | Usable Space | Fault Tolerance               |
|--------------------------------------|-------------|-------------------------------|
| RAID0 data, RAID1 metadata           | ~63.5 TB   | None (metadata protected)     |
| RAID1 data + RAID1 metadata          | ~32 TB     | Survives 1 drive failure      |

For your setup (max space + separate backups), RAID0 data with RAID1 metadata is the
sweet spot.

### Do you need to update fstab, Samba, or Windows?

**No.** The BTRFS filesystem UUID stays the same when you add devices, so fstab keeps
working. Samba points at `/mnt/media` which doesn't change. Your `Z:\` drive in Windows
just shows more free space. Nothing to reconfigure — it all happens transparently.

---

## Maintenance

### Monthly scrub

A scrub reads every block on every drive and verifies it against BTRFS's internal
checksums. This is how you catch **bit rot** — silent data corruption where a few bits
flip on disk without the drive reporting an error. On a large media library stored for
years, this is a real concern.

```bash
sudo btrfs scrub start /mnt/media
sudo btrfs scrub status /mnt/media      # check progress and results
```

> Consider setting up a systemd timer to run this automatically each month. A 16TB drive
> takes several hours to scrub, but it runs at low priority in the background and won't
> noticeably affect streaming performance.

### Check for errors

```bash
sudo btrfs device stats /mnt/media
```

All counters should be `0`. Non-zero values indicate a drive or data issue that needs
your attention — investigate the affected drive with `smartctl`.

### Snapshots

BTRFS can create instant, space-efficient, read-only snapshots. Useful before big
reorganizations or batch deletions:

```bash
sudo btrfs subvolume snapshot -r /mnt/media /mnt/media/.snapshots/snap-$(date +%F)
```

> Create the snapshots directory first: `sudo mkdir -p /mnt/media/.snapshots`

This creates a frozen point-in-time copy. It takes seconds and initially uses no extra
space — it only grows as the live data diverges from the snapshot. The `.snapshots`
directory will be hidden from Windows by default (dotfiles are hidden in SMB).

To delete a snapshot when you no longer need it:

```bash
sudo btrfs subvolume delete /mnt/media/.snapshots/snap-2026-02-18
```

### Safe DAS removal

Always unmount before physically disconnecting the DAS:

```bash
sudo umount /mnt/media
```

### Power loss protection

- **Use a UPS if possible**, even a small one. USB enclosures sometimes don't flush
  their write caches properly on unexpected power loss.
- BTRFS's copy-on-write design makes it more resilient to unclean shutdowns than ext4,
  but it's not bulletproof — especially behind a USB bridge with its own caching
  behavior.
- **Do not** add `discard` or TRIM mount options — these are for SSDs, not HDDs, and can
  cause issues with some USB enclosures.

---

## Quick Reference

| Task               | Command                                              |
|--------------------|------------------------------------------------------|
| Pool status        | `sudo btrfs filesystem show mediapool`               |
| Space usage        | `sudo btrfs filesystem usage /mnt/media`             |
| Add a drive        | `sudo btrfs device add /dev/sdY1 /mnt/media`        |
| Rebalance          | `sudo btrfs balance start /mnt/media`                |
| Rebalance progress | `sudo btrfs balance status /mnt/media`               |
| Run scrub          | `sudo btrfs scrub start /mnt/media`                  |
| Check for errors   | `sudo btrfs device stats /mnt/media`                 |
| Create snapshot    | `sudo btrfs subvolume snapshot -r /mnt/media <dest>` |
| Delete snapshot    | `sudo btrfs subvolume delete <snapshot-path>`        |
| Samba status       | `sudo systemctl status smb nmb`                      |
| Restart Samba      | `sudo systemctl restart smb nmb`                     |
| Test Samba config  | `testparm`                                           |
