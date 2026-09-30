# Script run results

Every number below comes from a run captured in the screenshots folder. Raw `logs/` and `output/` folders are kept out of this repo on purpose (see `.gitignore`), because they hold account names and sign in data.

Lab: `iamlab.local` domain controller, Windows Server 2022 (build 20348), Windows PowerShell 5.1. Run date: September 29, 2026.

## Script 1: New-BulkADUsers.ps1

### Baseline

| Method | Time | Notes |
|---|---|---|
| One user by hand in ADUC | 1 minute 20 seconds | Name, logon name, password, title, department, one group. ADUC already open to the right OU, no interruptions |
| Ten users by hand (projected) | About 13 minutes 20 seconds | 80 seconds × 10 |

### Runs

| Run | Mode | Rows | Created | Skipped | Failed | Preview | Run time | Screenshot |
|---|---|---|---|---|---|---|---|---|
| Dress rehearsal | WhatIf | 10 | 0 | 1 | 1 | 8 | 0.1 s | 08 |
| Clean live run | Live | 10 | 8 | 1 | 1 | 0 | 0.4 s | 11 |
| Rerun safety test | Live | 10 | 0 | 9 | 1 | 0 | 0.0 s | 18 |

### Row by row outcome of the clean live run

| Row | SamAccountName | Status | Detail |
|---|---|---|---|
| 2 | acarter | CREATED | Account created; added to GRP_Finance |
| 3 | mbell | CREATED | Account created; added to GRP_IT |
| 4 | pnair | CREATED | Account created; added to GRP_HR |
| 5 | lobrien | CREATED | Account created; added to GRP_Finance |
| 6 | sramirez | CREATED | Account created; added to GRP_IT |
| 7 | (none) | FAILED | Missing a required value. FirstName, LastName, and Department cannot be blank |
| 8 | acarter | SKIPPED | Duplicate of an earlier row in this same file |
| 9 | dbrooks | CREATED_WITH_WARNING | Account created; no group named GRP_Marketing so no department access was assigned |
| 10 | epark | CREATED | Account created; added to GRP_IT |
| 11 | glee | CREATED | Account created; added to GRP_HR |

## Script 2: Get-InactiveADUsers.ps1

| Run | Threshold | In scope | Active | Inactive | Never logged in | Too new to judge | Excluded | Screenshot |
|---|---|---|---|---|---|---|---|---|
| Manual | 90 days | 18 | 1 | 0 | 0 | 17 | 0 | 19 |
| Manual | 7 days | 18 | 1 | 0 | 9 | 8 | 0 | 20 |
| Manual, managers added | 7 days | 18 | 1 | 0 | 9 | 8 | 0 | 22 |
| Scheduled task | 90 days | 18 | 1 | 0 | 0 | 17 | 0 | 33 |

Unplanned data quality finding from the 7 day report: 4 of the 9 flagged Week 1 accounts (tdrake, kmishima, jjakes, jtodd) have no Department value.

## Scheduled task: IAM_Weekly_Inactive_Account_Report

| Attempt | Last Run Result | Log written | Screenshot |
|---|---|---|---|
| 4:06:44 PM | 0x1 | No | 27, 28 |
| Manual reproduction of the task command | Exit code 1 | No | 29 |
| After the fix, manual | Exit code 0 | Yes | 31 |
| 4:17:15 PM, after the fix | 0x0 | Yes, 4:17:16 PM | 32, 33 |

## Script 3: Get-ADGroupMembershipAudit.ps1

| Run | Scope | Groups | Membership rows | Disabled members | Privileged memberships | Empty groups | Fallback groups | Run time | Screenshot |
|---|---|---|---|---|---|---|---|---|---|
| Before remediation | Whole domain | 46 | 61 | 3 | 5 | 30 | 0 | 1.3 s | 35 |
| After remediation | Week8_Automation OU | 4 | 9 | 0 | 0 | 0 | 0 | 0.1 s | 38 |

## Script 4: Watch-BreakGlassSignIn.ps1

| Item | Value |
|---|---|
| Lookback window | 24 hours |
| Sign ins found for the break glass account | 5 (successful 2, failed 3) |
| Windows Event Log | Application log, source IAM_BreakGlass_Monitor, Event ID 9001, Level Warning |
| Graph query time | About 56 seconds |
| Scopes consented | AuditLog.Read.All, Directory.Read.All, for the signed in admin only (not tenant wide) |

Break glass UPN, tenant ID, and source IP are redacted in every screenshot.
