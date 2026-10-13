# Security

GatewayLens can change access and credentials on hundreds of connections, so it is
fair to ask what it touches before you run it. This page says, and how to report a
security problem.

## What it touches

**Who it is.** GatewayLens signs in as you - through Az.Accounts, or its own OAuth 2.0
sign-in with PKCE in the browser - and can do exactly what your account can do in the
portal, nothing more. Tokens live in memory only, and are never written to a file,
the log or the change record.

**Where it connects.** Only to Microsoft:

| | What for |
|---|---|
| Microsoft Entra ID | Sign-in and tokens |
| Fabric REST API | Gateways, members, connections, access, delete |
| Power BI REST API | Connection tests, credentials |
| Power BI v2 (unofficial - the endpoints the portal uses) | Live member status, usernames and access in one call, credentials the way the portal sets them |
| Microsoft Graph | Names of who has access, deleted accounts, finding people by email |
| Microsoft Download Center and Learn | The newest gateway version - public pages, no token, nothing about your tenant |
| Your Teams workflow or Power Automate flow | Alerts - only if you turn them on, and only to an address on logic.azure.com or api.powerplatform.com |

There is no telemetry, no update check and no server of ours. The **?** menu opens
pages on github.com in your browser - only when you click one.

**Credentials.** A password you type is encrypted on your PC with the gateway's
public key before it is sent - in the format Microsoft's own SDK uses - so the service
never sees it in plain text. It is never stored, logged or put in the change record,
and the password box is never remembered.

**What it keeps on your PC**, in `%LOCALAPPDATA%\GatewayLens`:
- settings: theme, text size, panel sizes, what you typed into the search and name
  boxes (never a password), the last account you signed in with, and your alert
  choices. A Teams or Power Automate address is encrypted for your Windows account.
- the daily log (30 days) and the change record (kept), in `logs`
- the backup written before a delete, in `backups`

These hold your tenant's gateway, connection and user names - treat them like any
other export from your tenant. `-LogFolder` and `-BackupFolder` move them elsewhere.

**Changes.** Nothing changes until you press a button that says so, and every one
asks first. Every change is recorded as it happens, and is not made at all if the
record cannot be written. [README - Safe by design](README.md#safe-by-design) has the
rest.

## Check what you run

- The exe is built from this repository by GitHub Actions, and carries the script
  inside it - the same `GatewayLens.ps1` as in the release. The release build checks
  that before it publishes, and `build/Test-Release.ps1` checks it on a download.
- Every release lists the SHA-256 of both. Compare with
  `Get-FileHash .\GatewayLens.exe`.
- Signed releases are signed by SignPath Foundation - the exe, the script, and the
  script inside the exe. `Get-AuthenticodeSignature .\GatewayLens.exe` says *Valid*.
  Signing is applied for; the [code signing policy](README.md#code-signing-policy)
  says when it starts, and [docs/code-signing.md](docs/code-signing.md) how to check.
- The script is plain PowerShell: read it, or run the script instead of the exe.
- `.\GatewayLens.ps1 -Demo` runs everything against a fictional company, without
  signing in and without a single call leaving your computer.

## Reporting a vulnerability

Please do not open a public issue. Use **Security > Report a vulnerability** on this
repository - GitHub keeps it private between you and the maintainer. Say which
version, and how to see the problem. Leave out anything from your tenant: names,
ids, server names.

You will hear back within a week. A fix is released as soon as it is ready, and the
release notes say what was fixed - with thanks, if you want them.
