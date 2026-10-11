# Changelog

All notable changes to GatewayLens are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [0.5.1] - 2026-10-11

### Fixed
- GatewayLens and its tests no longer depend on the caller's strict mode. With
  `Set-StrictMode` on in a PowerShell profile, reading a field an API answer left
  out was an error; the script now sets its own rules, and a test runs the whole
  demo self-test from a strict-mode session.

## [0.5.0] - 2026-10-10

### Added
- **Demo mode.** `-Demo` opens the real application on Contoso, a fictional company -
  no tenant, no sign-in, no Az module. Six gateways (online, partly online, offline,
  a member that does not answer, personal and VNet), 26 connections of a dozen
  types, three of them failing for different reasons, people, groups and service
  principals with roles, and a week of change history from two people. Every button
  works against it and nothing leaves the computer. The demo keeps its own log,
  change record and backups, apart from the real ones. `-Demo -SelfTest` and
  `-Demo -Inspect` work too.
- Only the network layer is replaced, so the demo runs the same code as real use -
  and each demo gateway has a real key pair: credentials sent to it are decrypted
  and checked, exactly as a gateway would. The password `wrong` is refused with the
  gateway's own message.
- The demo is also part of the test suite: the whole tool, end to end, on every run.

### Fixed
- **Error messages are readable.** Fabric, Power BI and Graph errors now arrive as
  one line - for a failing connection, the gateway's own reason, such as
  `Login failed for user 'CONTOSO\svc_hr'.` - instead of a block of JSON or a
  numeric error code. Power BI puts that reason under a key literally named
  `pbi.error`; it is now read correctly.
- Every list is created with `::new()`. In PowerShell 7.4, a list created with
  `New-Object` throws "Argument types do not match" when wrapped in `@()`.

## [0.4.0] - 2026-10-10

### Added
- **Change record.** Every change GatewayLens makes - access granted or removed,
  credentials updated, connections created or deleted, members enabled or
  disabled, and every undo - is written as one row of a monthly CSV the moment it
  happens: who, when, what, on which connection or gateway, the principal and role,
  the result and Microsoft's reason for any failure. Never a password. Rows are
  written from the running job itself, so an interrupted run still leaves a
  complete record of what it did. A change is not made at all if its record cannot
  be written.
- **Activity tab.** The change record in a grid: filter by period, action, result,
  user and text, export it, and see failures in red.
- **Undo.** Select your own completed changes in the Activity tab and reverse them:
  a grant is removed (only that role - nothing else the person holds), a removal is
  granted again with the same role, a member is switched back. Every undo is
  recorded too.
- **Daily log file.** Everything in the log panel, plus every item of every bulk
  run, in one file per day - kept for 30 days.
- **Team view.** `-LogFolder` points the log and change record at another folder.
  Point several people at one share and the Activity tab shows everyone's changes;
  each person only ever writes files carrying their own name.
- **Log panel toolbar**: filter by text or level, copy, save, open the log folder,
  clear.
- **Colour where it matters**: offline gateways, failing connections and failed
  changes in red; partly online gateways and members that did not answer in amber.
  The colours follow the theme.

### Fixed
- CSV files - exports, delete backups and the create template - are now written as
  UTF-8 with a byte order mark. Without it Excel misreads accented characters, so
  names with accents came out garbled.

## [0.3.0] - 2026-10-10

### Added
- **GatewayLens.exe** - a small launcher that carries the script inside it and starts
  it in PowerShell 7, or explains how to install PowerShell 7 if it is missing.
  Built by GitHub Actions on every push and attached to every release.
- **Themes**: Light, Dark, Midnight and Contrast, switched instantly from the header.
- **A modern look**: rounded, flat controls throughout - buttons, boxes, drop-downs,
  check boxes, tabs, grids, scroll bars and progress bar. If that styling ever fails
  to load, the window opens in the standard Windows look and says why in the log.
- **Text size** from 9 to 20 with the A- and A+ buttons.
- **History** in the search, filter, user, account and principal boxes - the last 20
  entries, picked from a drop-down. Password boxes are never remembered and always
  masked. Theme, size and history are kept per Windows user in
  `%LOCALAPPDATA%\GatewayLens\settings.json`; **Clear history** forgets them.
- **An icon**, for the window, the taskbar and the exe.
- **-Inspect** lists the fields Microsoft's APIs return for gateways and connections,
  with dates shown and every other text value replaced by its length - safe to share,
  and the way to find fields worth adding.
- Problems before the window opens are shown in a message box when started from the
  exe, since there is no console to read them in.

## [0.2.1] - 2026-10-09

### Added
- **Every delete writes a backup first.** Before any connection is deleted, a CSV goes
  to `Documents\GatewayLens\backups` (or `-BackupFolder`) with everything the API
  returns about each one - name, gateway, type, path, credential type and username,
  privacy, encryption, who had access and in which role, and the complete definition
  as JSON - enough to recreate it. Passwords cannot be included: the API never
  returns them.
- The guarantee is enforced inside the delete itself, not only in the window: it
  refuses to run unless the backup file exists and contains every connection about
  to be deleted. If the backup cannot be written, nothing is deleted.

## [0.2.0] - 2026-10-09

Full gateway management: everything needed to run on-premises gateways day to day,
not just look at them.

### Added
- **Bulk actions on every listed connection** - the list after filters and exclusions:
  - **Verify status** - tests each gateway connection and shows the gateway's own reason
    for any failure. Runs in parallel, with progress, and can be cancelled.
  - **Verify users** - reads who has access to each connection.
  - **Grant** and **remove** access for one or more users, groups or service principals.
    Every name is looked up before anything changes, so one typo stops the run cleanly.
  - **Update credentials** - Windows, Basic, Anonymous or Key, keeping each connection's
    privacy level and, by default, its encryption setting.
  - **Delete** - only after typing the number of connections to confirm.
- **Create connections** tab: rows typed in, loaded from CSV, or built from pasted
  connection strings, created on any on-premises gateway. A CSV template is one click
  away. Passwords are never read from or written to a file.
- Credential encryption ported from Microsoft's open-source Power BI SDK (MIT), so no
  extra module is needed. Tested by decrypting the output with a private key.
- **Connection filters**: several search values at once, a user with access, the
  account stored in the credentials, and the state of the connection's gateway
  (online, partially online, offline, unknown). Rows can be excluded from the list.
- **Usernames and access** in one call, from the endpoint the portal uses. Unofficial
  and optional, like live status; **Verify users** is the documented alternative.
- **Gateways**: enable and disable members (with a warning before disabling the last
  one), auto-refresh, an Include VNet gateways switch, copy one or all gateways as
  tab-separated text, and resolve member machines to IP addresses (`-DnsSuffix` adds
  suffixes Windows does not try by itself).
- A progress bar and a **Cancel** button for every bulk run; closing the window during
  one asks first.

### Not included
- The history and deleted-items views of database-backed tools: GatewayLens talks to
  the REST APIs only, so there is nothing to keep history in.

## [0.1.1] - 2026-10-09

### Fixed
- Live member status no longer stalls. Each member was asked in turn with no time
  limit, and the status endpoint waits for the member to answer, so a few offline
  members could hold up loading - and the self-test - for minutes. Every member is
  now asked at the same time, each with a 30-second limit; one that does not answer
  shows as **Timeout** instead of blocking the rest.
- The self-test checks live status on one gateway only and says what it is doing
  while it waits.

## [0.1.0] - 2026-10-09

First public version.

### Added
- **Gateways** tab: every gateway you can see, with type, member count, versions and
  load-balancing setting; members per gateway; gateway access with add and remove.
- **Live member status** (online / offline per member) from the endpoint behind the
  portal's *Manage gateways* page. Unofficial and optional - see the README.
- **Connections** tab: every connection, filtered by text, gateway, connectivity and
  type; who has access, with add and remove; a connection test for on-premises
  gateway connections.
- Name lookup through Microsoft Graph, so access can be granted by email or group
  name instead of object id. Ambiguous names are refused rather than guessed.
- CSV export of both lists.
- `-SelfTest`: calls every API once, read-only, and reports what works for your account.
- Test suite in `tests/` that runs without a tenant.
