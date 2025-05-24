```markdown
# WordPress Command-Line Backup & Management Suite

## Description

This project is a suite of Bash shell scripts designed to provide a comprehensive command-line solution for WordPress site backup, restoration, management, monitoring, and installer creation. It helps users automate and control various aspects of their WordPress sites, including database and file backups, remote storage, backup lifecycle management, site monitoring, and the creation of portable installers.

**Key Features:**

* **Multiple Backup Types:** Perform full, database-only, or files-only backups.
* **Flexible Backup Locations:** Store backups locally, remotely (via SSH/rsync), or both.
* **Incremental Backups:** Supports incremental file backups to save space and time.
* **Parallel Backups:** The `backup_all.sh` script can run multiple backup jobs in parallel for different WordPress instances.
* **Configuration Management:** Uses per-site `.conf` files for easy management of multiple WordPress instances.
* **Encrypted Configurations:** Supports GPG encryption for sensitive configuration files (`.conf.gpg`).
* **Restore Capabilities:** Restore full sites, databases, or files from existing backups.
* **Backup Management:** Interactive script (`manage_backups.sh`) to list, download, restore, or delete local and remote backups.
* **Old Backup Removal:** Script (`removeOld.sh`) to automatically clean up old backups based on retention time, disk space, or both.
* **Site Monitoring:** Script (`monitor.sh`) to check system health (disk, CPU, memory, load, connections), WordPress application status (response time, updates, PHP errors, security settings), and send notifications.
* **WordPress Installer Creation:** Script (`create_installer.sh`) to package a WordPress site (database and files) into a portable installer with a dynamic installation script.
* **Gravity Forms Backup:** Dedicated script (`gfbackup.sh`) to export Gravity Forms data.
* **Notifications:** Supports notifications via email, Slack, and Telegram for various operations.
* **Setup Utility:** An interactive `setup.sh` script to help configure the environment, create configuration files, and set up cron jobs.
* **Logging:** Comprehensive logging for all operations.

**Core Technologies, Languages, and Frameworks:**

* **Language:** Bash Shell Scripting
* **Core Utilities:** `wp-cli`, `rsync`, `ssh`, `scp`, `gpg`, `tar`, `gzip`, `zip`, `unzip`, `mysql` (client), `sed`, `awk`, `find`, `df`, `du`, `split`, `cat`, `curl`.
* **WordPress Interaction:** Primarily through WP-CLI.

## Table of Contents

* [Project Title](#wordpress-command-line-backup--management-suite)
* [Description](#description)
* [Table of Contents](#table-of-contents)
* [Getting Started](#getting-started)
    * [Prerequisites](#prerequisites)
    * [Installation](#installation)
* [Configuration](#configuration)
* [Usage](#usage)
    * [1. `setup.sh`](#1-setupsh)
    * [2. `backup_all.sh`](#2-backup_allsh)
    * [3. `backup.sh`](#3-backupsh)
    * [4. `database.sh`](#4-databasesh)
    * [5. `files.sh`](#5-filessh)
    * [6. `gfbackup.sh`](#6-gfbackupsh)
    * [7. `restore.sh`](#7-restoresh)
    * [8. `manage_backups.sh`](#8-manage_backupssh)
    * [9. `create_installer.sh`](#9-create_installersh)
    * [10. `removeOld.sh`](#10-removeoldsh)
    * [11. `monitor.sh`](#11-monitorsh)
    * [Common Script: `common.sh`](#common-script-commonsh)
* [Project Structure](#project-structure)
* [Running Tests](#running-tests)
* [Contributing](#contributing)
* [License](#license)
* [Author/Contact Info](#authorcontact-info)

## Getting Started

### Prerequisites

Ensure the following software and utilities are installed on the system where these scripts will run:

* **Bash:** The shell interpreter for running the scripts.
* **WP-CLI:** WordPress Command-Line Interface (essential for WordPress operations).
* **rsync:** For efficient file synchronization.
* **ssh, scp:** For remote operations (backups, restore, management).
* **gpg:** For encrypting and decrypting configuration files.
* **Standard Unix Utilities:**
    * `tar`, `gzip`, `zip`, `unzip`: For creating and extracting archives.
    * `mysql` (client): For database operations like import.
    * `sed`, `awk`, `find`, `basename`, `dirname`, `date`, `stat`, `wc`, `grep`, `head`, `tail`, `cut`, `sort`, `xargs`, `mktemp`, `touch`.
    * `df`, `du`: For disk space checks. 
    * `split`, `cat`: For handling large file archives in `create_installer.sh`.
* **Notification Utilities (Optional, if used):**
    * `mail` (e.g., from `mailutils` or `postfix`): For email notifications.
    * `curl`: For Slack and Telegram notifications, and site response checks.
* **System Monitoring Utilities (Optional, used by `monitor.sh`):**
    * `mpstat` (often part of `sysstat` package): For CPU usage.
    * `top` (alternative for CPU usage).
    * `free` (from `procps` or similar): For memory usage.
    * `netstat` or `ss`: For checking active network connections.
* **numfmt (Optional, used by `create_installer.sh` for size conversion):** From GNU coreutils.

It is recommended to run the `setup.sh` script which includes a requirements check for most common commands. 

### Installation

1.  **Clone the Repository (Example):**
    ```bash
    git clone https://github.com/jamal13647850/wpbackup
    cd wpbackup
    ```
    *(If you don't have a git repository, you can just download/copy the scripts to a directory on your server.)*

2.  **Run the Setup Script:**
    The `setup.sh` script provides an interactive menu to guide you through the initial setup.
    ```bash
    chmod +x setup.sh
    ./setup.sh
    ```
    This script will help you:
    * Create the necessary directory structure (`configs/`, `logs/`, `backups/`, `local_backups/`).
    * Set executable permissions for the main shell scripts.
    * Guide you through creating your first configuration file.
    * Optionally set up cron jobs for automated tasks.

## Configuration

This suite relies on configuration files stored in the `configs/` directory. Each WordPress site you want to manage should ideally have its own configuration file.

* **Creating Configuration Files:** The `setup.sh` script provides an interactive way to generate these files.
* **File Format:** Configuration files are shell scripts that set various variables (e.g., `wpPath`, `destinationUser`, `destinationIP`, `NOTIFY_EMAIL`, etc.).
* **Naming:** Typically named `your_site_identifier.conf`.
* **Encryption:** For security, you can encrypt your configuration files using GPG. The scripts will recognize and decrypt `.conf.gpg` files if `gpg` is installed and you can provide the passphrase. The `setup.sh` script offers options to encrypt/decrypt these files.
    * **Security Note:** Encrypted `.conf.gpg` files should NOT be used directly in cron jobs as there's no interactive way to provide a passphrase. Use unencrypted `.conf` files (with strict 600 permissions, owned by root) for cron automation.
* **Key Variables (Examples - refer to `setup.sh` config creation for a more complete list):**
    * `wpPath`: Absolute path to your WordPress installation.
    * `destinationUser`, `destinationIP`, `destinationPort`, `privateKeyPath`: SSH details for remote backups.
    * `destinationDbBackupPath`, `destinationFilesBackupPath`: Paths on the remote server for database and file backups. 
    * `LOCAL_BACKUP_DIR`: Path for local backups. 
    * `NOTIFY_METHOD`: Comma-separated list of notification methods (e.g., `email,slack,telegram`). 
    * `NOTIFY_EMAIL`, `SLACK_WEBHOOK_URL`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`: Corresponding credentials for notifications. 
    * `BACKUP_RETAIN_DURATION`: For `removeOld.sh`, how many days to keep backups. 
    * And many more for fine-tuning various script behaviors.

## Usage

All scripts are designed to be run from the command line. Most scripts require a configuration file to be specified using the `-c` option. The `common.sh` script, sourced by other scripts, sets up shared functions and variables. 

### 1. `setup.sh`

This is the main interactive script for initial setup and configuration management.

* **To run:**
    ```bash
    ./setup.sh
    ```
* **Features:**
    * Creates necessary directory structure (`configs`, `logs`, `backups`, `local_backups`, `installers`). 
    * Helps create new `.conf` files for your WordPress sites. 
    * Sets up cron jobs for automated backups and cleanup. 
    * Tests SSH connections based on config files. 
    * Sets executable permissions on other scripts. 
    * Encrypts or decrypts configuration files. 
    * Tests the validity of configuration files. 

### 2. `backup_all.sh`

This script iterates through all configuration files in the specified `configs` directory (default: `$SCRIPTPATH/configs`) and runs `backup.sh` for each one. 

* **Syntax:**
    ```bash
    ./backup_all.sh [<config_dir>] [-v] [-d] [-p <jobs>] [-t <type>] [-i] [-n] [-q] [-h]
    ```
* **Options:**
    * `<config_dir>`: Directory containing `.conf` or `.conf.gpg` files (defaults to `$SCRIPTPATH/configs`). 
    * `-v`: Enable verbose logging. 
    * `-d`: Enable dry run mode (simulates but doesn't perform backups). 
    * `-p <jobs>`: Number of parallel backup jobs (default: 1). 
    * `-t <type>`: Backup type: `full`, `db`, or `files` (default: `full`). 
    * `-i`: Use incremental backup for files (passed to `backup.sh`). 
    * `-n`: Disable notifications. 
    * `-q`: Quiet mode (minimal output). 
    * `-h`: Display help. 

### 3. `backup.sh`

Performs a backup (full, database, or files) for a single WordPress site defined in a configuration file.

* **Syntax:**
    ```bash
    ./backup.sh -c <config_file> [-f <format>] [-d] [-l|-r|-b] [-i] [-t <type>] [-q] [-n <suffix>] [-v]
    ```
* **Options:**
    * `-c <config_file>`: Path to the configuration file (`.conf` or `.conf.gpg`). **Required.** 
    * `-f <format>`: Override compression format (e.g., `zip`, `tar.gz`, `tar`). 
    * `-d`: Dry run mode. 
    * `-l`: Store backup locally only. 
    * `-r`: Store backup remotely only. 
    * `-b`: Store backup both locally and remotely (uses config default if not specified). 
    * `-i`: Use incremental backup for files. 
    * `-t <type>`: Backup type (`full`, `db`, `files`). Default is `full`. 
    * `-q`: Quiet mode (minimal output, suppresses interactive prompts for suffix). 
    * `-n <suffix>`: Custom suffix for backup filenames. 
    * `-v`: Verbose output. 

### 4. `database.sh`

Performs a database-only backup for a WordPress site.

* **Syntax:**
    ```bash
    ./database.sh -c <config_file> [-f <format>] [-d] [-l|-r|-b] [-q] [-n <suffix>] [-v]
    ```
* **Options:** (Similar to `backup.sh` but only for database)
    * `-c <config_file>`: Configuration file. **Required.** 
    * `-f <format>`: Override compression format. 
    * `-d`: Dry run. 
    * `-l`: Store locally only. 
    * `-r`: Store remotely only. 
    * `-b`: Store both locally and remotely. 
    * `-q`: Quiet mode. 
    * `-n <suffix>`: Custom suffix for backup filename. 
    * `-v`: Verbose output. 

### 5. `files.sh`

Performs a files-only backup for a WordPress site.

* **Syntax:**
    ```bash
    ./files.sh -c <config_file> [-f <format>] [-d] [-l|-r|-b] [-i] [-q] [-n <suffix>] [-v]
    ```
* **Options:** (Similar to `backup.sh` but only for files)
    * `-c <config_file>`: Configuration file. **Required.** 
    * `-f <format>`: Override compression format. 
    * `-d`: Dry run. 
    * `-l`: Store locally only. 
    * `-r`: Store remotely only. 
    * `-b`: Store both locally and remotely. 
    * `-i`: Use incremental backup. 
    * `-q`: Quiet mode. 
    * `-n <suffix>`: Custom suffix for backup filename. 
    * `-v`: Verbose output. 

### 6. `gfbackup.sh`

Performs a backup of Gravity Forms data by exporting forms to JSON.

* **Syntax:**
    ```bash
    ./gfbackup.sh -c <config_file> [-f <format>] [-d] [-v]
    ```
* **Options:**
    * `-c <config_file>`: Configuration file. **Required.** 
    * `-f <format>`: Override compression format for the archive of JSON files (default: `zip`). 
    * `-d`: Dry run. 
    * `-v`: Verbose output. 
    *The script will attempt to use `wp gf export --all` to get the forms.* 

### 7. `restore.sh`

Restores a WordPress site (full, database, or files) from a backup.

* **Syntax:**
    ```bash
    ./restore.sh -c <config_file> [-b <backup_file>] [-s <source>] [-t <type>] [-d] [-f] [-q] [-v]
    ```
* **Options:**
    * `-c <config_file>`: Configuration file. **Required.** 
    * `-b <backup_file>`: Path to a specific backup file to restore. If not provided, the script attempts to find the latest backup based on type and source. 
    * `-s <source>`: Backup source: `local` or `remote`. (Defaults to `local` or as per config `BACKUP_LOCATION`). 
    * `-t <type>`: Restore type: `full`, `db`, `files`. Default is `full`. 
    * `-d`: Dry run. 
    * `-f`: Force restore without confirmation. 
    * `-q`: Quiet mode. 
    * `-v`: Verbose output. 
    * **Note for Full Restore via `manage_backups.sh`**: This script can be invoked by `manage_backups.sh` with environment variables `MGMT_DB_BKP_PATH` and `MGMT_FILES_BKP_PATH` set to use specific staged backup files for a full restore. 

### 8. `manage_backups.sh`

An interactive script to manage existing backups.

* **To run:**
    ```bash
    ./manage_backups.sh
    ```
    *(The script uses its own logging and does not have CLI options for config file directly in the provided `manage_backups.sh` snippet, but it prompts for config selection if not already loaded via `ensure_config_loaded` which internally uses `select_config_file`). It seems designed to be interactive.* 
* **Features:**
    * Prompts to select a configuration file for context. 
    * Lists local or remote backups with filtering options (by type: DB/Files/All, by date). 
    * Allows selection of a backup to:
        * Restore the selected backup (DB or Files). 
        * Delete the selected backup. 
        * Download a remote backup to local storage. 
    * Perform a full restore by selecting a DB backup and then a Files backup from any source. 

### 9. `create_installer.sh`

Creates a distributable installer package (typically a ZIP file) containing the WordPress site's files and database, along with an installation script.

* **Syntax:**
    ```bash
    ./create_installer.sh -c <config_file> [options]
    ```
* **Options:**
    * `-c <file>`: Configuration file (`.conf` or `.conf.gpg`). **Required.** 
    * `-f <format>`: Override final installer package compression format (currently installer logic primarily supports creating a `.zip` archive containing other assets). 
    * `-d`: Dry run. 
    * `-v`: Verbose output. 
    * `-e <patterns>`: Comma-separated patterns to exclude from file backup (e.g., `'cache,uploads/large'`). 
    * `-m <limit>`: PHP memory limit for operations (default: `512M`). 
    * `-l <size>`: Chunk size for splitting large file archives (default: `500M`). 
    * `-p`: Set installer to disable plugins during its execution. 
    * `-M`: Enable special handling for multisite installations. 
    * `-h, -?`: Show help message. 
* **Installer Contents:** The generated package typically includes:
    * `install.sh`: The dynamic installation script. 
    * `db.sql`: Database dump. 
    * `files.tar.gz` (or split parts like `files.tar.part.aa`): Compressed WordPress files. 
    * `reassemble.sh` (if files are split). 
    * `README.txt` with instructions. 
    * Optional `extra_files/` directory. 

### 10. `removeOld.sh`

Removes old backup archives and log files based on retention policies defined in the configuration file.

* **Syntax:**
    ```bash
    ./removeOld.sh -c <config_file> [-d] [-v] [--help|-h]
    ```
* **Options:**
    * `-c <config_file>`: Path to the configuration file. **Required.** 
    * `-d`: Dry run mode (simulates deletions, no actual files removed). 
    * `-v`: Verbose output. 
    * `--help, -h`: Show help message. 
* **Configuration Variables Used:**
    * `fullPath`: The main directory path where backups/logs are stored to be cleaned. 
    * `BACKUP_RETAIN_DURATION`: Number of days to retain backups. 
    * `MAX_LOG_SIZE`: Max size for log files before considering deletion (if also old). 
    * `ARCHIVE_EXTS`: Comma-separated list of archive extensions to target. 
    * `SAFE_PATHS`: List of parent paths allowed for cleanup operations. 
    * `CLEANUP_MODE`: `time` (age-based), `space` (disk-space based), or `both`. 
    * `DISK_FREE_ENABLE`: `y` or `n` to enable disk space criteria. 
    * `DISK_MIN_FREE_GB`: Target minimum free disk space in GB. 

### 11. `monitor.sh`

Monitors system health and WordPress application status. Generates a report and can send alerts.

* **Syntax:**
    ```bash
    ./monitor.sh -c <config_file> [-t <threshold_file>] [-r <report_file>] [-m <metrics_file>] [-a] [-q] [-v] [-d]
    ```
* **Options:**
    * `-c <config_file>`: Configuration file for site details. **Required.** 
    * `-t <threshold_file>`: Optional threshold configuration file (overrides defaults set in script or main config). 
    * `-r <report_file>`: Output report file path. 
    * `-m <metrics_file>`: Metrics CSV file path. 
    * `-a`: Alert only mode (only reports/notifies on issues exceeding thresholds). 
    * `-q`: Quiet mode. 
    * `-v`: Verbose output. 
    * `-d`: Dry run (simulates checks). 
* **Checks Performed (configurable thresholds):**
    * System: Disk usage, CPU usage, memory usage, load average, active connections. 
    * WordPress: Site response time, pending plugin/theme/core updates, PHP error log count, database size, basic security settings (WP_DEBUG, DISALLOW_FILE_EDIT, readme.html). 

### Common Script: `common.sh`

This script is not meant to be run directly. It is sourced by most other scripts in the suite (`backup.sh`, `database.sh`, `files.sh`, `backup_all.sh`, `restore.sh`, `create_installer.sh`, `removeOld.sh`, `gfbackup.sh`, `monitor.sh`). 
It provides:
* Shared functions for logging, status checking, notifications, configuration loading (including GPG decryption), command existence checks, input sanitization, calculating durations, human-readable sizes, file compression/extraction, and SSH validation. 
* Common environment variables (like color codes for output).

## Project Structure

A brief overview of the typical directory structure:

```
/wpbackup
|-- backup_all.sh
|-- backup.sh
|-- common.sh
|-- create_installer.sh
|-- database.sh
|-- files.sh
|-- gfbackup.sh
|-- manage_backups.sh
|-- monitor.sh
|-- removeOld.sh
|-- restore.sh
|-- setup.sh
|-- configs/                  # Stores .conf and .conf.gpg site configuration files 
|   |-- yoursite1.conf
|   |-- yoursite2.conf.gpg
|-- logs/                     # Contains log files for each script and operation 
|   |-- backup.log
|   |-- backup_all.log
|   |-- monitor_report.txt
|   |-- monitor_metrics.csv
|   |-- last_backup.txt       # Stores path to last successful backup for incremental 
|-- backups/                  # Default staging directory for creating backup archives 
|-- local_backups/            # Default directory for storing local copies of backups 
|-- installers/               # Default output directory for `create_installer.sh` 
|-- temp_installer_XXXX/      # Temporary directory used by `create_installer.sh` (cleaned up) 
|-- restore_tmp/              # Temporary directory for `restore.sh` operations (cleaned up) 
|-- restore_staging_area_XXXX/ # Temporary directory for `manage_backups.sh` full restore staging 
```

*(Note: Some temporary directory names include `$$` which represents the process ID, ensuring uniqueness.)*

## Running Tests

This suite does not come with an automated test framework. Testing is typically done by:
* Using the **Dry Run** mode (`-d` flag) available in many scripts (e.g., `backup.sh`, `restore.sh`, `removeOld.sh`, `monitor.sh`).  This allows you to see what actions the script *would* take without making actual changes.
* Testing on a staging or non-critical WordPress installation.
* Carefully verifying backup integrity and restore procedures manually.
* Checking log files in the `logs/` directory for detailed operation information and errors.

## Contributing

Contributions are welcome! Please feel free to open an issue to discuss a bug or feature request, or submit a pull request with your improvements.
When contributing, please try to:
* Follow the existing coding style and conventions.
* Ensure your changes are well-documented with comments where necessary.
* Test your changes thoroughly, ideally in a non-production environment.
* Update the README.md if your changes affect usage, configuration, or add new features.

## Author/Contact Info

**Sayyed Jamal Ghasemi**
_Full Stack Developer_

📧 [jamal13647850@gmail.com](mailto:jamal13647850@gmail.com)
🔗 [LinkedIn](https://www.linkedin.com/in/jamal1364/)
📸 [Instagram](https://www.instagram.com/jamal13647850)
💬 [Telegram](https://t.me/jamaldev)
🌐 [Website](https://jamalghasemi.com)

```