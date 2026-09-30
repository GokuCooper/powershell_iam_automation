# Break glass sign in evidence (redacted)

Source: `Watch-BreakGlassSignIn.ps1` evidence CSV, September 29, 2026 (Screenshot 45). The IP address, city, country, and UPN columns are left out on purpose.

## Sign ins in the 24 hour window

| Time (local) | Result | Application | Client | Conditional Access |
|---|---|---|---|---|
| 2026-09-29 16:28:48 | Failure (50140): "Keep me signed in" interrupt | Azure Portal | Browser | notApplied |
| 2026-09-29 16:28:51 | Success | Azure Portal | Browser | notApplied |
| 2026-09-29 16:29:11 | Failure (50203): user has not registered the authenticator app, must register or snooze | Azure Portal | Browser | notApplied |
| 2026-09-29 16:29:13 | Failure (50140): "Keep me signed in" interrupt | Azure Portal | Browser | notApplied |
| 2026-09-29 16:29:17 | Success | Azure Portal | Browser | notApplied |

## Reading it

| Observation | Meaning |
|---|---|
| 5 log entries | 2 real sign ins. Each browser sign in writes several entries as it moves through its steps |
| 50140 (twice) | Not an attack and not a real failure. The "Stay signed in?" question pauses the flow and gets logged as an interrupted step, followed seconds later by a Success |
| 50203 | Entra nudged the break glass account to register Microsoft Authenticator, and the account moved past the nudge. Follow up: review the account's registered authentication methods |
| notApplied on every row | The Week 7 exclusion group (CA_Exclude_BreakGlass) works as designed. Conditional Access skips this account on purpose, which is exactly why it needs this monitor |

## Verdict

2 sign ins, 0 attack attempts, all expected from the planned test. The alert classified this as Event 9001 (successful use) because at least one sign in succeeded.

## Follow ups

1. Protect the break glass account with phishing resistant MFA (a FIDO2 key or passkey stored physically secured) and an authentication strength policy scoped to the break glass group, so it stays excluded from normal policies without relying on a password alone.
2. Teach the script to label interrupt codes like 50140 as sign in steps instead of failures, so a responder is not misled by "Failed: 3."
