# Group membership audit: findings and triage

Source: `Get-ADGroupMembershipAudit.ps1`, whole domain run, September 29, 2026 (Screenshots 35 and 36). Empty groups (30, all built in) are left out of this table.

## Findings

| Group | Member | Membership | Member enabled | Finding |
|---|---|---|---|---|
| Administrators | Domain Admins | Direct | | NESTED_GROUP_IN_PRIVILEGED_GROUP |
| Administrators | Enterprise Admins | Direct | | NESTED_GROUP_IN_PRIVILEGED_GROUP |
| Administrators | Administrator | Direct | True | PRIVILEGED_ACCESS |
| Denied RODC Password Replication Group | krbtgt | Direct | False | DISABLED_ACCOUNT_STILL_A_MEMBER |
| Domain Admins | Administrator | Direct | True | PRIVILEGED_ACCESS |
| Enterprise Admins | Administrator | Direct | True | PRIVILEGED_ACCESS |
| Group Policy Creator Owners | Administrator | Direct | True | PRIVILEGED_ACCESS |
| GRP_IT | Marcus Bell | Direct | False | DISABLED_ACCOUNT_STILL_A_MEMBER |
| Guests | Guest | Direct | False | DISABLED_ACCOUNT_STILL_A_MEMBER |
| Schema Admins | Administrator | Direct | True | PRIVILEGED_ACCESS |

## Triage

| Finding | Account | Verdict | Reason |
|---|---|---|---|
| DISABLED_ACCOUNT_STILL_A_MEMBER | Marcus Bell (mbell) in GRP_IT | **Remediate** | Half finished Leaver: account disabled, department access never removed. Planted on purpose for this lab |
| DISABLED_ACCOUNT_STILL_A_MEMBER | krbtgt in Denied RODC Password Replication Group | Accept, by design | krbtgt signs Kerberos tickets and is supposed to be disabled. This group stops read only domain controllers from caching its password |
| DISABLED_ACCOUNT_STILL_A_MEMBER | Guest in Guests | Accept, by design | Windows default |
| PRIVILEGED_ACCESS (5 rows) | Administrator | Accept for a lab only | In production, admins use a daily account plus a separate admin account, with just in time elevation |
| NESTED_GROUP_IN_PRIVILEGED_GROUP (2 rows) | Domain Admins, Enterprise Admins in Administrators | Accept, by design, document | Default Active Directory structure, but every nested path into a privileged group should be on record |

**Result:** 3 disabled member findings, 1 real, 2 by design. Marcus Bell was removed from GRP_IT and a scoped rerun returned no findings (Screenshot 38).

## Nested access revealed

| Group | Member | Type | Membership |
|---|---|---|---|
| GRP_FinanceShare_ReadWrite | GRP_Finance | group | Direct |
| GRP_FinanceShare_ReadWrite | Aisha Carter | user | Nested |
| GRP_FinanceShare_ReadWrite | Liam O'Brien | user | Nested |

Looking only at direct members, the file share group has one group and zero people. The audit shows the real answer: two people can reach it.
