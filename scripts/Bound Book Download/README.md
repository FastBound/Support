# FastBound Bound Book Download Scripts

Scripts to automate bound book A&D record downloads from FastBound per ATF Ruling 2016-1.

## Overview

Most users should use FastBound's built-in integrations with Dropbox or a NAS device for automatic bound book backups. The scripts in this folder are intended for advanced configurations where you need more control over the download process, such as custom storage locations, integration with existing backup systems, or environments where the built-in options aren't available.

## Recommended: NAS with Built-in Sync

If you have a Synology or QNAP NAS, you can configure automatic bound book downloads without running these scripts:

- [ATF Ruling 2016-1 Compliant Backups to Synology DiskStation NAS](https://fastbound.help/en/articles/10348556-atf-ruling-2016-1-compliant-backups-to-synology-diskstation-nas)
- [ATF Ruling 2016-1 Compliant Backups to QNAP NAS](https://fastbound.help/en/articles/10770650-atf-ruling-2016-1-compliant-backups-to-qnap-nas)

See [Recommended Products](https://fastbound.help/en/articles/2378708-recommended-products#h_c47262dabf) for NAS recommendations.

## Available Scripts

| Script | Platform | Use Case |
|--------|----------|----------|
| `Download-BoundBooks.ps1` | PowerShell 7+ | Multiple accounts with secure credential storage |
| `Download-BoundBook.ps1` | PowerShell 7+ | Single account |
| `download-boundbook.sh` | macOS/Linux | Single account using cURL |
| `download-boundbook.py` | Any (Python 3) | Single account, no external dependencies |

These scripts are intentionally simple. If you know how to write code (or how to get AI to write code for you), you can easily port them to any language or platform you need.

## Multi-Account Downloads

For users managing multiple FastBound accounts, `Download-BoundBooks.ps1` stores credentials securely in a PowerShell Secret Vault.

### Requirements

PowerShell 7 or later:
- [Windows](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows)
- [macOS](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-macos)
- [Linux](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux)

### Usage

```powershell
# Add an account to the vault
./Download-BoundBooks.ps1 -Add ACCOUNT_NAME -Key API_KEY

# List stored accounts
./Download-BoundBooks.ps1 -List

# Download bound books for all accounts
./Download-BoundBooks.ps1 -Download -AuditUser user@example.com

# Remove an account from the vault
./Download-BoundBooks.ps1 -Remove ACCOUNT_NAME
```

### Scheduling with Password-Protected Vaults

If your PowerShell Secret Store requires a password, provide it with `-VaultPassword`:

```powershell
./Download-BoundBooks.ps1 -Download -AuditUser user@example.com -VaultPassword "YourPassword"
```

Or disable password authentication for automated use:

```powershell
Set-SecretStoreConfiguration -Authentication None -Interaction None -Confirm:$false
```

## Single-Account Downloads

For simpler setups with one account, use any of the single-account scripts.

### PowerShell

```powershell
./Download-BoundBook.ps1 -Account ACCOUNT -Key API_KEY -AuditUser user@example.com

# Custom output path
./Download-BoundBook.ps1 -Account ACCOUNT -Key API_KEY -AuditUser user@example.com -Output C:\Books\mybook.pdf
```

### Bash/cURL (macOS/Linux)

```bash
./download-boundbook.sh -a ACCOUNT -k API_KEY -u user@example.com

# Custom output path
./download-boundbook.sh -a ACCOUNT -k API_KEY -u user@example.com -o ~/Books/mybook.pdf
```

### Python

```bash
./download-boundbook.py -a ACCOUNT -k API_KEY -u user@example.com

# Custom output path
./download-boundbook.py -a ACCOUNT -k API_KEY -u user@example.com -o ~/Books/mybook.pdf
```

## Scheduling

### Windows (Task Scheduler)

1. Open Task Scheduler and create a new basic task
2. Set the trigger to run daily
3. Set the action to start a program:
   - Program: `pwsh.exe`
   - Arguments: `-File "C:\path\to\Download-BoundBooks.ps1" -Download -AuditUser user@example.com`

### macOS (launchd)

Create `~/Library/LaunchAgents/com.fastbound.download.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.fastbound.download</string>
    <key>ProgramArguments</key>
    <array>
        <string>pwsh</string>
        <string>-File</string>
        <string>/path/to/Download-BoundBooks.ps1</string>
        <string>-Download</string>
        <string>-AuditUser</string>
        <string>user@example.com</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>12</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
</dict>
</plist>
```

Load with: `launchctl load ~/Library/LaunchAgents/com.fastbound.download.plist`

### Linux (cron)

Edit crontab with `crontab -e` and add:

```
0 12 * * * pwsh -File /path/to/Download-BoundBooks.ps1 -Download -AuditUser user@example.com
```

## Security Warning

The single-account scripts (`Download-BoundBook.ps1`, `download-boundbook.sh`, `download-boundbook.py`) require your API key as a command-line argument. On multi-user systems, command-line arguments are visible to all users via process listing tools (e.g., `ps`, Task Manager, `Get-Process`).

**For shared or multi-user environments, use `Download-BoundBooks.ps1` with PowerShell Secret Vault.**

## Help

Each script provides built-in help:

```powershell
# PowerShell
./Download-BoundBooks.ps1 -Help
./Download-BoundBook.ps1   # Run without arguments

# Bash
./download-boundbook.sh -h

# Python
./download-boundbook.py -h
```
