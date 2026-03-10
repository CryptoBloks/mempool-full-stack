# Backup & Restore

## Overview

The backup system supports two modes:

| Mode | Downtime | Requirements |
|------|----------|-------------|
| **BTRFS** (recommended) | ~30-60 seconds | BTRFS filesystem on storage path |
| **Non-BTRFS** (fallback) | Duration of upload | Any filesystem |

All backups use streaming compression: `tar | zstd -T0 -3 | rclone rcat` — no intermediate files are written to disk.

### Prerequisites

- `rclone` configured with an S3-compatible remote (for S3 backup)
- `zstd` for compression
- BTRFS filesystem (recommended, auto-detected)

---

## BTRFS Snapshots

BTRFS snapshots provide atomic, instant, copy-on-write captures of data directories.

**Prerequisite:** Data directories must be BTRFS subvolumes (not regular directories) for snapshots to work. Create them before first start:

```bash
# Example for mainnet (adjust paths for your STORAGE_PATH)
sudo btrfs subvolume create /data/mempool/mainnet/bitcoin
sudo btrfs subvolume create /data/mempool/mainnet/electrs
sudo btrfs subvolume create /data/mempool/mainnet/mempool-cache
sudo btrfs subvolume create /data/mempool/mariadb
sudo chown -R 1000:1000 /data/mempool/mainnet/{bitcoin,electrs,mempool-cache}
sudo chown -R 999:999 /data/mempool/mariadb
```

### Create Snapshots

```bash
# Snapshot all components for a network
./scripts/snapshot/create.sh --network mainnet

# Snapshot all networks
./scripts/snapshot/create.sh
```

### List Snapshots

```bash
./scripts/snapshot/list.sh
```

### Prune Old Snapshots

```bash
# Keep the 5 most recent snapshots per component
./scripts/snapshot/prune.sh --keep 5
```

---

## Full Backup (S3)

The full backup script orchestrates a multi-step process:

```
full-backup.sh --network mainnet
  │
  ├─ 1. Pre-backup checks
  │     Verify BTRFS, rclone, zstd, S3 remote
  │     Generate backup ID (YYYYMMDD_HHMMSS)
  │
  ├─ 2. Stop services for this network
  │     docker compose stop bitcoind-{net} electrs-{net} mempool-api-{net}
  │
  ├─ 3. Create BTRFS snapshots (if available)
  │     Read-only snapshots of bitcoin, electrs, mempool-cache, mariadb
  │
  ├─ 4. Restart services immediately
  │     Services come back up while upload runs from frozen snapshots
  │     Downtime: ~30-60 seconds
  │
  ├─ 5. Stream upload to S3
  │     tar | zstd -T0 -3 | rclone rcat (per component)
  │     Write manifest.json with block height, versions, sizes
  │
  ├─ 6. Cleanup snapshots
  │
  └─ Done
```

### Non-BTRFS Fallback

Without BTRFS, Step 3 is skipped and Step 5 reads directly from live data directories. Services remain stopped until the upload completes — which can take hours for mainnet.

### Usage

```bash
# Full backup of mainnet to S3
./scripts/backup/full-backup.sh --network mainnet

# Full backup of signet
./scripts/backup/full-backup.sh --network signet
```

---

## S3 Path Structure

```
{S3_REMOTE}:{S3_BUCKET}/{S3_PREFIX}backups/
├── mainnet/
│   ├── 20260309_120000/
│   │   ├── bitcoin.tar.zst
│   │   ├── electrs.tar.zst
│   │   ├── mariadb.tar.zst
│   │   ├── mempool.tar.zst
│   │   └── manifest.json
│   └── 20260308_120000/
│       └── ...
├── signet/
│   └── ...
```

### Manifest

Each backup includes a `manifest.json` with metadata:

```json
{
  "backup_id": "20260309_120000",
  "network": "mainnet",
  "date": "2026-03-09T12:00:00+00:00",
  "components": {
    "bitcoin": {
      "version": "28.1",
      "block_height": 890123,
      "txindex": true,
      "size_bytes": 654321098765
    },
    "electrs": {
      "version": "latest",
      "size_bytes": 87654321098
    },
    "mariadb": {
      "version": "10.11",
      "databases": ["mempool"],
      "size_bytes": 1234567890
    },
    "mempool": {
      "version": "3.1.0",
      "size_bytes": 12345678
    }
  },
  "btrfs": true,
  "zstd_level": 3,
  "duration_seconds": 1847
}
```

The `block_height` field is critical for verifying that a restored electrs index matches the bitcoin data.

---

## S3 Management

### List Remote Backups

```bash
./scripts/backup/s3-list.sh
```

Shows backup ID, network, block height, date, and component sizes.

### Prune Remote Backups

```bash
# Keep the 3 most recent backups per network
./scripts/backup/s3-prune.sh --keep 3

# Dry run (show what would be deleted)
./scripts/backup/s3-prune.sh --keep 3 --dry-run
```

### Manual Push/Pull

For advanced use — the full-backup and restore scripts use these internally:

```bash
# Upload a local directory to S3
./scripts/backup/s3-push.sh /path/to/data remote:bucket/path/archive.tar.zst

# Download from S3 to a local directory
./scripts/backup/s3-pull.sh remote:bucket/path/archive.tar.zst /path/to/dest
```

Both stream without intermediate files.

---

## Restore

### Full Restore

```bash
# Restore mainnet from the latest S3 backup
./scripts/backup/restore.sh --network mainnet --source s3

# Restore from a specific backup ID
./scripts/backup/restore.sh --network mainnet --source s3 --backup-id 20260309_120000

# Restore from a local snapshot
./scripts/backup/restore.sh --network mainnet --source local
```

### Restore Flow

```
restore.sh --network mainnet --source s3
  │
  ├─ 1. Determine backup (latest or specified ID)
  │
  ├─ 2. Stop services for this network
  │
  ├─ 3. Clear existing data
  │     BTRFS: delete subvolume + recreate
  │     Non-BTRFS: rm -rf + mkdir
  │
  ├─ 4. Stream download and extract
  │     rclone cat | zstd -d | tar -xf - (per component)
  │
  ├─ 5. Fix permissions
  │     bitcoin/electrs/mempool: 1000:1000
  │     mariadb: 999:999
  │
  ├─ 6. Start services
  │
  └─ Done
```

### Component-Level Restore

Restore individual components without touching others:

```bash
# Restore just electrs (e.g., index got corrupted)
./scripts/backup/restore.sh --network mainnet --source s3 --component electrs

# Restore bitcoin + electrs together (they must match)
./scripts/backup/restore.sh --network mainnet --source s3 --component bitcoin,electrs
```

When restoring `bitcoin`, the electrs index will likely need restoring too (or a full re-index).

### Bootstrap from Backup

For new deployments, skip the multi-day initial sync by restoring from a backup:

```bash
# Run wizard to set up config
./scripts/setup/wizard.sh

# Restore from S3 before starting
./scripts/backup/restore.sh --network mainnet --source s3

# Start the stack
docker compose up -d
```

---

## Downtime Comparison

| Scenario | BTRFS | Non-BTRFS |
|----------|-------|-----------|
| **Full backup** | ~30-60s (snapshot + restart) | Hours (mainnet: 600GB+) |
| **Full restore** | Download duration | Download duration |
| **Component restore** | Download duration (one component) | Download duration (one component) |

With BTRFS, the upload runs from frozen read-only snapshots while services are already back online.

---

## Script Reference

| Script | Purpose |
|--------|---------|
| `scripts/backup/full-backup.sh` | Orchestrated backup: stop, snapshot, restart, upload, prune |
| `scripts/backup/restore.sh` | Full or component-level restore from S3 or local |
| `scripts/backup/s3-push.sh` | Stream-compress and upload to S3 |
| `scripts/backup/s3-pull.sh` | Stream-download and extract from S3 |
| `scripts/backup/s3-list.sh` | List remote backups with manifest details |
| `scripts/backup/s3-prune.sh` | Enforce retention policy on remote backups |
| `scripts/snapshot/create.sh` | Create BTRFS snapshots |
| `scripts/snapshot/list.sh` | List local snapshots |
| `scripts/snapshot/prune.sh` | Delete old local snapshots |
