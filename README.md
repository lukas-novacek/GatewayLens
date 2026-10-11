<img src="assets/icon-256.png" width="88" align="right" alt="">

# GatewayLens

A lightweight desktop console for **Microsoft on-premises data gateways** and the
connections that run on them, for Power BI and Microsoft Fabric.

One PowerShell script - or one small exe. No database, no server, no agent on the
gateways. Sign in as yourself and see every gateway, every member, every connection
and who has access to it - in one window.

![tests](https://github.com/<your-github-name>/GatewayLens/actions/workflows/tests.yml/badge.svg)

<!-- Add a screenshot taken in demo mode (.\GatewayLens.ps1 -Demo): save it as
docs/screenshot.png and uncomment the line below.
![GatewayLens](docs/screenshot.png)
-->

## Why

The portal's *Manage connections and gateways* page works well for one gateway.
With dozens of gateway clusters and hundreds of connections, the everyday
questions get slow to answer:

- Which gateway members are offline right now, and which are on an old version?
- Which connections run on this gateway, and what do they point at?
- Who can use this connection - and can I give a colleague access without
  clicking through every connection one at a time?

GatewayLens answers those in one place.

## What it does

**Gateways**
- Every gateway you can see: on-premises, personal and virtual network
- Members with version, enabled state and live online / offline status *(optional - see below)*
- Version drift at a glance, a running "x of y members online", and auto-refresh
- Enable and disable members - with a warning before you disable the last one
- Copy one gateway or all of them as tab-separated text, ready for Excel or a ticket
- Resolve member machines to IP addresses, one block per gateway
- Gateway access: admins and connection creators, with add and remove

**Connections**
- Every connection, with filters you can combine: several search values at once,
  gateway, connectivity, type, a user with access, the account stored in the
  credentials, and whether the connection's gateway is online
- Exclude rows you want to leave alone, then act on everything that is left:
  - **Verify status** - the gateway's own reason for every failing connection
  - **Verify users** - who has access to each one
  - **Grant** or **remove** access for any number of users and groups
  - **Update credentials** - Windows, Basic, Anonymous or Key
  - **Delete** - only after typing the count to confirm
- Single-connection access and a connection test in the panel below the list

**Create connections**
- Type rows in, paste connection strings, or load a CSV - and create them all on
  any on-premises gateway in one go. Passwords are never stored in a file.

**Everywhere**
- Every bulk run shows progress and can be cancelled
- CSV export of any list
- Nothing blocks the window: every API call runs in the background
- A plain activity log of what was done, and the reason for anything that was not

## Requirements

- Windows with **PowerShell 7.2 or later** - `winget install Microsoft.PowerShell`
- One sign-in module, either of:
  - **Az.Accounts** *(recommended)* - `Install-Module Az.Accounts -Scope CurrentUser`
  - MicrosoftPowerBIMgmt - works, but cannot look people up by name, so granting
    access needs an object id

## Get started

**Try it first, without a tenant:**

```powershell
.\GatewayLens.ps1 -Demo
```

Demo mode opens the real application on Contoso, a fictional company: gateways
online, offline and slow, connections that fail for different reasons, people,
groups and a week of change history. Every button works, nothing leaves your
computer, and no sign-in or Azure module is needed. It is also the safe way to take
screenshots.

**The exe** - download `GatewayLens.exe` from the
[Releases](../../releases) page and run it. It carries the script inside it and
starts it in PowerShell 7; if PowerShell 7 is missing, it says how to install it.

**Or the script:**

```powershell
# 1. Download GatewayLens.ps1, then allow it to run
Unblock-File .\GatewayLens.ps1

# 2. Check what works for your account - read-only, changes nothing
.\GatewayLens.ps1 -SelfTest

# 3. Open the console
.\GatewayLens.ps1
```

Run the self-test first - `GatewayLens.exe -SelfTest` works too. It signs you in,
calls every API once and reports what your account can and cannot do, so a missing
permission shows up as one clear line instead of an empty grid.

Other options:

```powershell
.\GatewayLens.ps1 -TenantId contoso.onmicrosoft.com     # a specific tenant
.\GatewayLens.ps1 -DeviceCode                           # sign in on another device
.\GatewayLens.ps1 -DnsSuffix corp.contoso.com           # extra suffix for Resolve IPs
.\GatewayLens.ps1 -LogFolder \\server\share\gatewaylens  # a shared change record for a team
.\GatewayLens.ps1 -Inspect                              # which fields the APIs return (no data)
.\GatewayLens.ps1 -Demo -SelfTest                       # the self-test against the demo
Get-Help .\GatewayLens.ps1 -Full                        # everything else
```

### About the exe

`GatewayLens.exe` is a small launcher built from [build/launcher](build/launcher)
by GitHub Actions - the same script, inside. It needs no runtime of its own (.NET
Framework 4.8 is part of Windows 10 and 11), but it does need **PowerShell 7**.

The exe is not code-signed, so Windows SmartScreen may warn the first time it runs,
and some company security tools block unsigned programs that start PowerShell. If
yours does, run the script instead - it is exactly the same tool.

## Activity and change record

Every change GatewayLens makes is recorded the moment it happens, one row per
connection or member: who, when, what, the principal and role, the result, and
Microsoft's reason for anything that failed. Passwords never appear. If the record
cannot be written, the change is not made.

- The **Activity** tab shows the record, filtered by period, action, result, user
  and text - failures in red - and exports it.
- **Undo selected** reverses your own completed access changes and member
  enable / disable. Each undo is recorded too.
- The **log panel** filters by text or level, and copies or saves what it shows.
  Everything in it, plus every item of every bulk run, also goes to a daily log
  file, kept for 30 days.

Both live in `%LOCALAPPDATA%\GatewayLens\logs` - **Open folder** takes you there.

**For a team:** start GatewayLens with `-LogFolder \\server\share\gatewaylens` for
everyone. The Activity tab then shows the whole team's changes. Each person writes
only to files with their own name in them, so nobody overwrites anybody.

## Look and feel

- **Themes**: Light, Dark, Midnight and Contrast - top right, switched instantly.
- **Text size**: the **A-** and **A+** buttons, from 9 to 20.
- **History**: the search, filter, user, account and principal boxes remember the
  last 20 entries - open the drop-down to pick one. **Password boxes are never
  remembered** and always masked. **Clear history** forgets everything.

All three are kept for your Windows account only, in
`%LOCALAPPDATA%\GatewayLens\settings.json`.

## What you will see

GatewayLens shows what **your account** can see. The Fabric API lists the gateways
and connections you hold a role on - it is not a tenant-wide inventory, even for
Fabric administrators. To manage a gateway or its connections you need the
matching role on it; [docs/permissions.md](docs/permissions.md) has the details.

## Where the data comes from

| Feature | API | Status |
|---|---|---|
| Gateways, members, connections, access, delete | Fabric REST API | Documented |
| Connection test, create, update credentials | Power BI REST API | Documented |
| Name lookup when granting access | Microsoft Graph | Documented |
| **Live member status** | Power BI v2 `gatewayClusters` | **Unofficial** |
| **Usernames and access in one call** | Power BI v2 `gatewayClusterDatasources` | **Unofficial** |

### About the unofficial parts

Two things are not available from Microsoft's documented APIs at a reasonable cost,
and GatewayLens takes them from the same endpoints the portal itself uses:

- **Live member status** - whether each member is online right now.
- **Usernames and access in one call** - the account stored in each connection's
  credentials, and its users. The documented route needs one call per connection
  for the users and has no username at all.

Each is isolated in a single function and has its own checkbox. If Microsoft ever
changes one, the only effect is empty columns - everything else keeps working, and
**Verify users** remains the documented way to read access.

### Credentials

Credentials sent to a gateway must be encrypted with that gateway's public key, in
exactly the format the gateway expects. GatewayLens uses a port of Microsoft's own
implementation from the open-source Power BI .NET SDK (MIT License), so it needs no
extra module - and the test suite decrypts its output with a private key to prove the
format byte for byte.

## Safety

- Nothing changes unless you press a button that says so - and every one of them
  asks first, naming exactly what it is about to do and to how many connections.
- Bulk changes go one connection at a time, can be cancelled at any point, and report
  every connection that did not succeed, with the reason.
- Every change is written to the change record as it happens - and is not made at
  all if the record cannot be written. Access and member changes can be undone.
- **Delete** asks you to type the number of connections, then writes a backup CSV
  before deleting anything - everything needed to recreate each connection except
  its password, which the API never returns. If the backup cannot be written, nothing
  is deleted. Disabling the last enabled member of a gateway warns you that
  refreshes will stop.
- A name that matches more than one user or group is refused, not guessed -
  granting access to the wrong person is worse than asking for the object id.
- No credentials are stored. Sign-in is handled by Az.Accounts or
  MicrosoftPowerBIMgmt; GatewayLens only ever holds short-lived access tokens.
- Exported CSV files contain your tenant's gateway, connection and user names.
  Treat them accordingly.

## Troubleshooting

**An empty grid.** Run `.\GatewayLens.ps1 -SelfTest`. It names the call that failed
and the API's own error message.

**"cannot be loaded because running scripts is disabled".** Run
`Unblock-File .\GatewayLens.ps1`, or for your user only:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

**The Status column shows n/a.** The unofficial status endpoint did not answer -
see the activity log for the reason. Untick *Live member status* to stop trying.

**A connection test fails with a data source error.** That is the gateway's own
answer: it reached the gateway, and the gateway could not reach the data source.

## Roadmap

- Local snapshots, to show what changed and what was deleted since a given day
- Sign-in as a service principal for unattended reporting
- Credentials for virtual network gateway connections

Suggestions are welcome as issues.

## Development

```powershell
.\tests\Run-Tests.ps1          # the test suite - no tenant, no sign-in
.\build\Build-Exe.ps1          # builds dist\GatewayLens.exe (needs the .NET SDK)
```

The tests replace every call to Microsoft with a stand-in, so they run on every
push via GitHub Actions - which also builds the exe each time; download it from the
run's **Artifacts**. Pushing a tag such as `v0.3.0` publishes a release with the
exe and the script attached. Changes are recorded in [CHANGELOG.md](CHANGELOG.md).

## Licence

[MIT](LICENSE). GatewayLens is an independent project and is not affiliated with,
endorsed by or supported by Microsoft. Power BI and Microsoft Fabric are trademarks
of Microsoft Corporation.
