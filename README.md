# $\color{blue}{\text{AD-UserDomainMigration}}$

A PowerShell script for migrating on-premises Active Directory user attributes from one email domain to another. Designed for organizations transitioning to a new domain suffix (e.g. `.com` → `.gov`) who need to update UPNs, primary SMTP addresses, proxy address aliases, and the `mail` attribute in bulk.

---

## $\color{blue}{\text{Features}}$

- Prompts for all inputs at runtime — no hardcoded values
- Updates **User Principal Name (UPN)** to new domain
- Updates the **`mail` attribute** to new domain
- Rebuilds **`proxyAddresses`** with full alias preservation:
  - Promotes new domain address as primary `SMTP:`
  - Retains old domain address as a lowercase `smtp:` alias
  - Adds a new-domain counterpart for every existing old-domain alias
  - Passes through third-party domain aliases untouched
  - Passes through non-SMTP entries (X400, X500, SIP, etc.) untouched
- Validates UPNs in input file against the entered old domain before processing
- Skips blank lines and `#` comment lines in the input file
- Writes a detailed timestamped log for every action taken per user
- Confirmation prompt before any changes are made
- Summary line at completion showing attempted / completed / error counts

---

## $\color{blue}{\text{Requirements}}$

| Requirement | Details |
|---|---|
| PowerShell | 5.1 or later |
| Module | `ActiveDirectory` (RSAT) |
| Permissions | Write access to target AD user objects |
| OS | Windows — domain-joined or with AD remote access |

To install RSAT on Windows 10/11 if not already present:

```powershell
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
```

---

## $\color{blue}{\text{Usage}}$

1. **Create your input file** — one current UPN per line (see [Input File Format](#input-file-format) below)
2. **Run the script** in an elevated PowerShell session:

```powershell
.\Update-ADUserDomain.ps1
```

3. **Answer the prompts:**

```
Enter the OLD domain (e.g. contoso.com)     : contoso.com
Enter the NEW domain (e.g. contoso.gov)     : contoso.gov
Enter the full path to the users input file : C:\scripts\users.txt
Enter the full path for the log file        : C:\scripts\migration_log.txt
```

4. **Review the confirmation summary** and type `yes` to proceed.

---

<a id="input-file-format"></a>

## $\color{blue}{\text{Input File Format}}$

The input file should contain one UPN per line using the **current (pre-migration)** domain. Lines starting with `#` are treated as comments and skipped. Blank lines are also skipped.

```text
jsmith@contoso.com
bjones@contoso.com
# this user is on hold - do not migrate yet
tdavis@contoso.com
mwilliams@contoso.com
```

> **Note:** UPNs that do not match the old domain entered at runtime will be skipped and logged as errors.

---

## $\color{blue}{\text{What Gets Changed}}$

For each user the script makes the following changes:

| Attribute | Before | After |
|---|---|---|
| `userPrincipalName` | `jsmith@contoso.com` | `jsmith@contoso.gov` |
| `mail` | `jsmith@contoso.com` | `jsmith@contoso.gov` |
| `proxyAddresses` primary | `SMTP:jsmith@contoso.com` | `SMTP:jsmith@contoso.gov` |
| `proxyAddresses` alias | *(none)* | `smtp:jsmith@contoso.com` |
| `proxyAddresses` existing alias | `smtp:jsmith.old@contoso.com` | `smtp:jsmith.old@contoso.com` *(kept)* |
| `proxyAddresses` alias counterpart | *(none)* | `smtp:jsmith.old@contoso.gov` *(added)* |
| `proxyAddresses` third-party | `smtp:jsmith@otherdomain.com` | `smtp:jsmith@otherdomain.com` *(unchanged)* |
| Non-SMTP entries (X400, SIP, etc.) | unchanged | unchanged |

---

## $\color{blue}{\text{Log File}}$

A timestamped log is written to the path entered at runtime. Each user's block looks like this:

```
2026-07-17 10:22:01  jsmith@contoso.com migration starting
2026-07-17 10:22:01      jsmith UPN changed to jsmith@contoso.gov - Done
2026-07-17 10:22:01          proxyAddresses: set SMTP:jsmith@contoso.gov as new primary SMTP
2026-07-17 10:22:01          proxyAddresses: retained smtp:jsmith@contoso.com as alias
2026-07-17 10:22:01      jsmith proxyAddresses updated - Done
2026-07-17 10:22:01      jsmith mail property changed to jsmith@contoso.gov - Done
2026-07-17 10:22:01      User update complete

2026-07-17 10:22:03  ===== Migration complete =====
2026-07-17 10:22:03  3 User migrations attempted | 3 User migrations completed | 0 User migration errors
```

---

## $\color{blue}{\text{Recommendations}}$

**Test before a full run.** Create a `users_test.txt` with one or two non-production accounts and run the script against those first to verify output in your environment.

**Stop directory sync before running.** If you are using Entra Connect (Azure AD Connect) or a similar sync tool, disable or stop the sync cycle before running this script. If sync runs mid-migration it may overwrite the changes made here.

**Verify domain acceptance.** If this migration is part of a Microsoft 365 tenant move, ensure the new domain is verified as an accepted domain in the destination tenant before or shortly after running this script, or mail flow may not function correctly.

---

## $\color{blue}{\text{License}}$

MIT License. See [LICENSE](LICENSE) for details.

---

## $\color{blue}{\text{Contributing}}$

Pull requests are welcome. For major changes please open an issue first to discuss what you'd like to change.
