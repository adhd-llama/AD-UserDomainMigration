# ============================================================
# AD Attribute Migration: Generic Domain Migration Script
# Script:  Update-ADUserDomain.ps1
# Author: ADHD-Llama 
# Version: 1.0
# ============================================================
# DESCRIPTION:
#   Migrates on-premises Active Directory user attributes from
#   one domain to another. For each user in the input file the
#   script will:
#     - Update the User Principal Name (UPN)
#     - Rebuild proxyAddresses (new .gov primary, retain .com
#       alias, mirror all existing aliases to the new domain)
#     - Update the mail attribute
#
# REQUIREMENTS:
#   - ActiveDirectory PowerShell module (RSAT)
#   - Account running the script must have write access to
#     the target AD user objects
#
# INPUT FILE FORMAT:
#   One UPN per line using the CURRENT (old) domain.
#   Lines starting with # are treated as comments and skipped.
#   Example:
#     jsmith@olddomain.com
#     bjones@olddomain.com
#     # this user is on hold
#     tdavis@olddomain.com
#
# OUTPUT:
#   - Console output mirrored to log file
#   - Log file written to the log path entered at runtime
# ============================================================

#Requires -Modules ActiveDirectory

# ---- Banner ----
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   AD Domain Migration Script" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ---- Collect inputs ----
$OldDomain = Read-Host "Enter the OLD domain (e.g. contoso.com)"
$OldDomain = $OldDomain.Trim().TrimStart("@")

$NewDomain = Read-Host "Enter the NEW domain (e.g. contoso.gov)"
$NewDomain = $NewDomain.Trim().TrimStart("@")

$UsersFile = Read-Host "Enter the full path to the users input file (e.g. C:\scripts\users.txt)"
$UsersFile = $UsersFile.Trim()

$LogPath = Read-Host "Enter the full path for the log file (e.g. C:\scripts\migration_log.txt)"
$LogPath  = $LogPath.Trim()

# ---- Confirm before proceeding ----
Write-Host ""
Write-Host "----------------------------------------" -ForegroundColor Yellow
Write-Host "  Please confirm the following settings:" -ForegroundColor Yellow
Write-Host "----------------------------------------" -ForegroundColor Yellow
Write-Host "  Old Domain : $OldDomain"
Write-Host "  New Domain : $NewDomain"
Write-Host "  Input File : $UsersFile"
Write-Host "  Log File   : $LogPath"
Write-Host ""

$confirm = Read-Host "Proceed with migration? (yes/no)"
if ($confirm.Trim().ToLower() -ne "yes") {
    Write-Host "Migration cancelled." -ForegroundColor Red
    exit 0
}

Write-Host ""

# --- Counters ---
$attempted = 0
$completed = 0
$errors    = 0

# --- Helper: Write to log AND console ---
function Write-Log {
    param([string]$Message, [string]$Indent = "")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp  $Indent$Message"
    Add-Content -Path $LogPath -Value $line
    Write-Host $line
}

# --- Ensure log directory exists ---
$logDir = Split-Path $LogPath
if ($logDir -and -not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# --- Validate input file ---
if (-not (Test-Path $UsersFile)) {
    Write-Host "ERROR: Input file not found: $UsersFile" -ForegroundColor Red
    exit 1
}

Write-Log "===== Migration started ====="
Write-Log "Old Domain   : $OldDomain"
Write-Log "New Domain   : $NewDomain"
Write-Log "Source file  : $UsersFile"
Write-Log "Log file     : $LogPath"
Write-Log ""

# --- Read UPN list (skip blank lines and comments) ---
$upnList = Get-Content $UsersFile |
           Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } |
           ForEach-Object { $_.Trim() }

if ($upnList.Count -eq 0) {
    Write-Log "ERROR: No users found in input file. Exiting."
    exit 1
}

Write-Log "Users to process: $($upnList.Count)"
Write-Log ""

foreach ($upn in $upnList) {

    $attempted++
    $userErrors = 0

    # Validate that the UPN in the file matches the old domain
    if ($upn -notmatch "@$([regex]::Escape($OldDomain))$") {
        Write-Log "$upn migration starting"
        Write-Log "ERROR: UPN does not match old domain '$OldDomain' -- skipping" -Indent "    "
        Write-Log "User update ERROR!" -Indent "    "
        $errors++
        Write-Log ""
        continue
    }

    Write-Log "$upn migration starting"

    # --- Locate the AD user by current UPN ---
    try {
        $adUser = Get-ADUser -Filter { UserPrincipalName -eq $upn } `
                             -Properties UserPrincipalName, mail, proxyAddresses `
                             -ErrorAction Stop
    } catch {
        Write-Log "ERROR locating user in AD: $_" -Indent "    "
        Write-Log "User update ERROR!" -Indent "    "
        $errors++
        Write-Log ""
        continue
    }

    if (-not $adUser) {
        Write-Log "ERROR: No AD user found with UPN '$upn'" -Indent "    "
        Write-Log "User update ERROR!" -Indent "    "
        $errors++
        Write-Log ""
        continue
    }

    # Derive prefix (everything before the @)
    $prefix  = ($upn -split "@")[0]
    $newUPN  = "$prefix@$NewDomain"
    $newMail = "$prefix@$NewDomain"

    # ---- 1. Update UPN ----
    try {
        Set-ADUser -Identity $adUser -UserPrincipalName $newUPN -ErrorAction Stop
        Write-Log "$prefix UPN changed to $newUPN - Done" -Indent "    "
    } catch {
        Write-Log "$prefix UPN change FAILED: $_" -Indent "    "
        $userErrors++
    }

    # ---- 2. Rebuild proxyAddresses ----
    try {
        $proxies     = @($adUser.proxyAddresses)
        $newProxySet = [System.Collections.Generic.List[string]]::new()

        # Always seed the new domain primary and old domain alias first,
        # regardless of whether the user has any existing proxyAddresses
        $newPrimary = "SMTP:$prefix@$NewDomain"
        $newProxySet.Add($newPrimary)
        Write-Log "proxyAddresses: set $newPrimary as new primary SMTP" -Indent "        "

        $oldAlias = "smtp:$prefix@$OldDomain"
        $newProxySet.Add($oldAlias)
        Write-Log "proxyAddresses: retained $oldAlias as alias" -Indent "        "

        # Process any pre-existing proxy entries
        foreach ($entry in $proxies) {

            # Carry non-SMTP entries (X400, X500, SIP, etc.) through untouched
            if ($entry -notmatch '^smtp:' -and $entry -notmatch '^SMTP:') {
                if (-not $newProxySet.Contains($entry)) {
                    $newProxySet.Add($entry)
                }
                continue
            }

            $isPrimary   = $entry.StartsWith("SMTP:")
            $address     = $entry -replace '^smtp:', '' -replace '^SMTP:', ''
            $aliasPfx    = ($address -split "@")[0]
            $aliasDomain = ($address -split "@")[1]

            if ($isPrimary) {
                # Old primary already seeded above — skip to avoid duplication
                continue

            } else {

                if ($aliasDomain -ieq $OldDomain) {
                    # Keep existing old-domain alias
                    if (-not $newProxySet.Contains($entry)) {
                        $newProxySet.Add($entry)
                        Write-Log "proxyAddresses: kept existing old-domain alias $entry" -Indent "        "
                    }
                    # Add matching new-domain counterpart
                    $newDomainAlias = "smtp:$aliasPfx@$NewDomain"
                    if (-not $newProxySet.Contains($newDomainAlias)) {
                        $newProxySet.Add($newDomainAlias)
                        Write-Log "proxyAddresses: added new-domain counterpart $newDomainAlias" -Indent "        "
                    }

                } elseif ($aliasDomain -ieq $NewDomain) {
                    # Already a new-domain alias — carry through as-is
                    if (-not $newProxySet.Contains($entry)) {
                        $newProxySet.Add($entry)
                        Write-Log "proxyAddresses: kept existing new-domain alias $entry" -Indent "        "
                    }

                } else {
                    # Third-party domain alias — carry through untouched
                    if (-not $newProxySet.Contains($entry)) {
                        $newProxySet.Add($entry)
                        Write-Log "proxyAddresses: kept third-party alias $entry" -Indent "        "
                    }
                }
            }
        }

        Set-ADUser -Identity $adUser `
                   -Replace @{ proxyAddresses = $newProxySet.ToArray() } `
                   -ErrorAction Stop

        Write-Log "$prefix proxyAddresses updated - Done" -Indent "    "

    } catch {
        Write-Log "$prefix proxyAddresses update FAILED: $_" -Indent "    "
        $userErrors++
    }

    # ---- 3. Update mail attribute ----
    try {
        Set-ADUser -Identity $adUser -EmailAddress $newMail -ErrorAction Stop
        Write-Log "$prefix mail property changed to $newMail - Done" -Indent "    "
    } catch {
        Write-Log "$prefix mail property change FAILED: $_" -Indent "    "
        $userErrors++
    }

    # ---- Result for this user ----
    if ($userErrors -eq 0) {
        Write-Log "User update complete" -Indent "    "
        $completed++
    } else {
        Write-Log "User update ERROR!" -Indent "    "
        $errors++
    }

    Write-Log ""
}

# --- Final summary ---
Write-Log "===== Migration complete ====="
Write-Log "$attempted User migrations attempted | $completed User migrations completed | $errors User migration errors"
