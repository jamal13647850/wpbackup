# Usage Guide for WordPress Backup and Migration Toolkit

This document explains how to use the scripts in the WordPress Backup and Migration Toolkit: `sync.sh`, `files.sh`, `cron-scheduler.sh`, `setup.sh`, `migrate.sh`, and `staging.sh`. Each script requires a configuration file (e.g., `configs/mywebsite.conf`) created via `setup.sh`.

---

## General Notes
- **Configuration**: All scripts require a `.conf` file specifying settings like paths, SSH credentials, and notification methods.
- **Flags**:
  - `-c <config_file>`: Specify the configuration file.
  - `-d` or `-p`: Dry run (preview actions without executing them).
  - `-v`: Verbose mode (detailed logging).
- **Execution**: Ensure scripts are executable (`chmod +x <script>.sh`) before running.

---

## 1. Sync (`sync.sh`)
Synchronizes files and/or database between production and staging environments.

### Syntax
```bash
./sync.sh -c <config_file> -t <db|files|both> -d <push|pull> [-p] [-v]
```

### Options
- `-t <db|files|both>`: Type of synchronization:
  - `db`: Database only.
  - `files`: Files only.
  - `both`: Files and database.
- `-d <push|pull>`: Direction of synchronization:
  - `push`: Staging to production.
  - `pull`: Production to staging.
- `-p`: Dry run (simulates the sync process).
- `-v`: Verbose logging.

### Examples
1. Sync both files and database from production to staging:
   ```bash
   ./sync.sh -c configs/mywebsite.conf -t both -d pull
   ```
2. Sync files only from staging to production with verbose output:
   ```bash
   ./sync.sh -c configs/mywebsite.conf -t files -d push -v
   ```
3. Preview database sync from production to staging:
   ```bash
   ./sync.sh -c configs/mywebsite.conf -t db -d pull -p
   ```

---

## 2. Files Backup (`files.sh`)
Backs up WordPress files locally or to a remote server.

### Syntax
```bash
./files.sh -c <config_file> [-f <format>] [-d] [-i] [-v]
```

### Options
- `-f <format>`: Compression format (`tar.gz`, `zip`, `tar`). Defaults to `zip` if unspecified.
- `-d`: Dry run (simulates the backup process).
- `-i`: Incremental backup (uses previous backup as reference for changes).
- `-v`: Verbose logging.

### Examples
1. Full backup of files in `tar.gz` format:
   ```bash
   ./files.sh -c configs/mywebsite.conf -f tar.gz
   ```
2. Incremental backup with verbose output:
   ```bash
   ./files.sh -c configs/mywebsite.conf -i -v
   ```
3. Preview backup in `zip` format:
   ```bash
   ./files.sh -c configs/mywebsite.conf -f zip -d
   ```

---

## 3. Cron Scheduler (`cron-scheduler.sh`)
Schedules automated backups via cron jobs.

### Syntax
```bash
./cron-scheduler.sh <config_file> [dry_run] [verbose] [compression] [location]
```

### Positional Arguments
- `<config_file>`: Path to the configuration file (required).
- `dry_run`: `true` or `false` (optional, defaults to `false`).
- `verbose`: `true` or `false` (optional, defaults to `false`).
- `compression`: Compression format (`tar.gz`, `zip`, `tar`; optional, defaults to `tar.gz`).
- `location`: Backup location (`l` for local, `r` for remote, `b` for both; optional, defaults to `b`).

### Interactive Prompts
- **Backup Frequency**:
  1. Daily (2 AM)
  2. Every 12 hours (2 AM, 2 PM)
  3. Every 6 hours (2 AM, 8 AM, 2 PM, 8 PM)
  4. Every 4 hours
  5. Weekly (Sunday 2 AM)
  6. Monthly (1st of each month 2 AM)
- **Backup Type**:
  1. Full (database + files)
  2. Database only
  3. Files only

### Examples
1. Schedule a daily full backup with `tar.gz` compression:
   ```bash
   ./cron-scheduler.sh configs/mywebsite.conf false false tar.gz b
   ```
   - Then select `1` for daily and `1` for full backup.
2. Schedule a weekly database-only backup with verbose logging:
   ```bash
   ./cron-scheduler.sh configs/mywebsite.conf false true tar.gz r
   ```
   - Then select `5` for weekly and `2` for database only.
3. Preview a monthly files-only backup:
   ```bash
   ./cron-scheduler.sh configs/mywebsite.conf true false zip l
   ```
   - Then select `6` for monthly and `3` for files only.

---

## 4. Setup (`setup.sh`)
Installs prerequisites and creates configuration files for backups and migrations.

### Syntax
```bash
./setup.sh
```

### Interactive Prompts
1. **Prerequisites**: Automatically installs required tools (`rsync`, `wp-cli`, etc.).
2. **Backup Config**:
   - Project name, WordPress path, SSH details, backup paths, retention duration, compression format, notification methods.
   - Option to add multiple backup projects.
3. **Migration Config** (optional):
   - Source and destination server details (SSH, WordPress paths, database settings), notification methods.
   - Option to add multiple migration projects.
4. **Gravity Forms CLI** (optional): Installs the Gravity Forms CLI for form backups.

### Example
```bash
./setup.sh
```
- Follow the prompts to:
  - Install tools.
  - Create a backup config (e.g., `configs/mywebsite.conf`).
  - Optionally create a migration config (e.g., `configs/migrate_site.conf`).
  - Optionally install Gravity Forms CLI.

---

## 5. Migration (`migrate.sh`)
Migrates a WordPress site between servers (local-to-remote or remote-to-remote).

### Syntax
```bash
./migrate.sh -c <config_file> [-d] [-v]
```

### Options
- `-d`: Dry run (simulates the migration process).
- `-v`: Verbose logging.

### Examples
1. Migrate a site with verbose output:
   ```bash
   ./migrate.sh -c configs/migrate_site.conf -v
   ```
2. Preview a migration:
   ```bash
   ./migrate.sh -c configs/migrate_site.conf -d
   ```

---

## 6. Staging (`staging.sh`)
Creates a staging environment from a production WordPress site.

### Syntax
```bash
./staging.sh -c <config_file> [-d] [-v]
```

### Options
- `-d`: Dry run (simulates the staging creation).
- `-v`: Verbose logging.

### Examples
1. Create a staging environment:
   ```bash
   ./staging.sh -c configs/mywebsite.conf
   ```
2. Preview staging creation with verbose output:
   ```bash
   ./staging.sh -c configs/mywebsite.conf -d -v
   ```

---

## Output and Logs
- **Logs**: Each script writes to a dedicated log file (e.g., `sync.log`, `files.log`) in the script directory.
- **Status**: Status updates are written to `<script>_status.log`.
- **Notifications**: Sent via configured methods (email, Slack, Telegram) on completion or failure.

---

## Tips
- **Test First**: Use `-d` or `-p` to preview actions before executing them.
- **Verbose Mode**: Enable `-v` for troubleshooting.
- **Configuration**: Ensure your `.conf` file matches the script’s requirements (e.g., `stagingPath` for `sync.sh`, `destinationIP` for `files.sh`).
- **Permissions**: Run scripts with appropriate permissions (e.g., `sudo` if accessing system directories).