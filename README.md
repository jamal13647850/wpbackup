# WordPress Backup and Migration Toolkit

This toolkit provides a set of Bash scripts designed to streamline WordPress site management, including backups, synchronization between staging and production environments, file transfers, and scheduled tasks. Built with flexibility and automation in mind, it supports both local and remote operations, incremental backups, and multiple notification methods.

## Features

- **Sync (`sync.sh`)**: Synchronize files and/or database between production and staging environments in both directions (`push` or `pull`).
- **Files Backup (`files.sh`)**: Back up WordPress files locally or to a remote server with support for incremental backups and customizable exclusions.
- **Cron Scheduler (`cron-scheduler.sh`)**: Schedule automated backups (full, database, or files) with flexible frequency options (daily, weekly, etc.).
- **Setup (`setup.sh`)**: Install prerequisites and create configuration files for backups and migrations interactively.
- **Migration (`migrate.sh`)**: Migrate a WordPress site from one server to another (local-to-remote or remote-to-remote).
- **Staging (`staging.sh`)**: Create a staging environment from a production WordPress site.
- **Common Utilities (`common.sh`)**: Shared functions for logging, status updates, notifications, and configuration loading.

### Key Capabilities
- Supports local and remote operations via SSH.
- Incremental backups for efficient storage usage.
- Configurable compression formats (`tar.gz`, `zip`, `tar`).
- Customizable file size limits and exclusion patterns.
- Notification support for email, Slack, and Telegram.
- Dry-run mode for testing without making changes.
- Verbose logging for detailed debugging.

## Prerequisites

- **Operating System**: Linux (tested with `apt` and `yum` package managers).
- **Required Tools**:
  - `bash`, `rsync`, `curl`, `pigz`, `unzip`, `zip`, `mysql-client`, `mailutils`.
  - WP-CLI (`wp`) for WordPress operations.
- **Optional**: SSH access for remote operations, Gravity Forms CLI for form backups.

## Installation

1. **Clone the Repository** (if applicable):
   ```bash
   git clone <repository-url>
   cd <repository-directory>
   ```

2. **Run the Setup Script**:
   ```bash
   chmod +x setup.sh
   ./setup.sh
   ```
   - This installs prerequisites (e.g., `rsync`, `wp-cli`) and guides you through creating configuration files for backups and migrations.

3. **Set Permissions**:
   ```bash
   chmod +x *.sh
   ```

## Configuration

Configuration files are stored in the `configs/` directory and can be created using `setup.sh`. Each script requires a `.conf` file specifying settings like paths, SSH credentials, and notification methods.

### Example Configuration File (`configs/mywebsite.conf`)
```bash
# SSH settings (optional for remote operations)
destinationPort=22
destinationUser="user"
destinationIP="192.168.1.100"
destinationDbBackupPath="/backups/db"
destinationFilesBackupPath="/backups/files"
privateKeyPath="/root/.ssh/id_rsa"

# WordPress settings
wpPath="/var/www/mywebsite"
stagingPath="/var/www/mywebsite-staging"
stagingUrl="http://staging.mywebsite.com"
maxSize="50m"

# Backup settings
fullPath="/var/www/backups"
BACKUP_RETAIN_DURATION=10
NICE_LEVEL=19
COMPRESSION_FORMAT="tar.gz"
LOG_LEVEL="normal"
BACKUP_LOCATION="both"

# Notification settings
NOTIFY_METHOD="email,slack"
NOTIFY_EMAIL="admin@mywebsite.com"
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/xxx/yyy/zzz"
```

## Usage

### 1. Sync (`sync.sh`)
Synchronize files and/or database between production and staging.

```bash
./sync.sh -c configs/mywebsite.conf -t <db|files|both> -d <push|pull> [-p] [-v]
```
- `-t`: Sync type (`db`, `files`, or `both`).
- `-d`: Direction (`push` for staging-to-production, `pull` for production-to-staging).
- `-p`: Dry run (preview changes).
- `-v`: Verbose logging.

**Example**:
```bash
./sync.sh -c configs/mywebsite.conf -t both -d pull -v
```

### 2. Files Backup (`files.sh`)
Back up WordPress files locally or to a remote server.

```bash
./files.sh -c configs/mywebsite.conf [-f <format>] [-d] [-i] [-v]
```
- `-f`: Compression format (`tar.gz`, `zip`, `tar`).
- `-d`: Dry run.
- `-i`: Incremental backup.
- `-v`: Verbose logging.

**Example**:
```bash
./files.sh -c configs/mywebsite.conf -f zip -i
```

### 3. Cron Scheduler (`cron-scheduler.sh`)
Schedule automated backups.

```bash
./cron-scheduler.sh configs/mywebsite.conf [dry_run] [verbose] [compression] [location]
```
- Positional arguments:
  - `dry_run`: `true` or `false`.
  - `verbose`: `true` or `false`.
  - `compression`: `tar.gz`, `zip`, or `tar`.
  - `location`: `l` (local), `r` (remote), `b` (both).

**Example**:
```bash
./cron-scheduler.sh configs/mywebsite.conf false true tar.gz b
```

### 4. Setup (`setup.sh`)
Install prerequisites and create configuration files.

```bash
./setup.sh
```
- Follow the interactive prompts to install tools and configure backup/migration settings.

### 5. Migration (`migrate.sh`)
Migrate a WordPress site between servers.

```bash
./migrate.sh -c configs/migrate_site.conf [-d] [-v]
```
- `-d`: Dry run.
- `-v`: Verbose logging.

**Example**:
```bash
./migrate.sh -c configs/migrate_site.conf -v
```

### 6. Staging (`staging.sh`)
Create a staging environment.

```bash
./staging.sh -c configs/mywebsite.conf [-d] [-v]
```
- `-d`: Dry run.
- `-v`: Verbose logging.

**Example**:
```bash
./staging.sh -c configs/mywebsite.conf
```

## Logging and Notifications

- **Logs**: Stored in `<script>.log` (e.g., `sync.log`, `files.log`).
- **Status**: Updated in `<script>_status.log`.
- **Notifications**: Sent via configured methods (email, Slack, Telegram) on success or failure.

## Customization

- **Exclude Patterns**: Modify `EXCLUDE_PATTERNS` in `files.sh` or config files (e.g., `wp-staging,*.log,cache`).
- **Retention**: Set `BACKUP_RETAIN_DURATION` in config files to control how long backups are kept.
- **Performance**: Adjust `NICE_LEVEL` for process priority or `maxSize` for file size limits.

## Troubleshooting

- **Permission Issues**: Ensure scripts have execute permissions (`chmod +x`) and SSH keys are readable (`chmod 600`).
- **Missing Tools**: Run `setup.sh` to install prerequisites.
- **Verbose Mode**: Use `-v` for detailed logs.
- **Dry Run**: Test with `-d` or `-p` to preview actions.

## Contributing

Feel free to submit issues or pull requests to enhance functionality. Suggestions for additional features (e.g., more notification methods, compression options) are welcome!

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.