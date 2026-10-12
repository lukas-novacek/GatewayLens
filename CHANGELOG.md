# Changelog

All notable changes to GatewayLens are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [0.8.2] - 2026-10-12

### Changed
- **Access lists match the portal.** Accounts that Microsoft Entra ID no longer
  knows are left out of the access panels and the Users count, as in the portal.
  When there are any, a checkbox says how many - *Show 8 not in Entra ID* - and
  ticked, they are listed too, to be removed. The choice is kept.
- **What is known about such an account comes from Graph, and only that.** An
  account deleted in the last 30 days is still in the recycle bin: it is shown by
  name, with the day it was deleted. One that Entra ID has no object for is a
  *Deleted account*. When Graph will not say - you may not be allowed to see it -
  it is *Not found in Microsoft Entra ID*, never called deleted. The access report
  has an *InEntraId* column, and the self-test counts them that way.

### Added
- **A countdown on the Gateways tab**: "Updated 22:13:58 | next in 0:42" while
  auto-refresh is on, "refreshing now" while it loads - in the kiosk view too.
- **From the demo to the start page**: *Sign in to your tenant* in the top bar of
  the demo closes it and opens the start page. Nothing of the demo is kept.

### Fixed
- Update credentials like the portal uses PATCH, as the portal does.

## [0.8.1] - 2026-10-12

### Fixed
- **Update credentials keeps the username visible.** The documented API stores the
  credentials encrypted only, so the readable copy of the username - the Account
  column, and the username the portal shows - was lost. GatewayLens now updates
  them the way the portal does: it reads each gateway member's key from the
  data source, encrypts the credentials once per member, and sends them to the
  portal's own endpoint (`credentialsV2`, unofficial). Privacy level, encryption and
  *Skip test connection* stay as they were.
  - *Like the portal - keeps the username visible* is on by default, in the
    Credentials box.
  - If that endpoint refuses the request, nothing was changed, and the documented
    way is used instead - the log says so for each connection. The gateway's own
    answer, such as a wrong password, is not sent a second way, and neither is a
    request that got no answer.
  - The change record says which way each update went.
- The demo answers like a real tenant here too: the documented call loses the
  username, the portal's way keeps it.

## [0.8.0] - 2026-10-12

From the second run on a real tenant.

### Added
- **A start page.** GatewayLens opens on a small page: sign in when you are ready -
  with the account from last time, or another one - or try the demo first. A failed
  sign-in is shown on the page, to try again, and the page stays alive while the
  browser sign-in runs. `-Demo`, `-Kiosk`, `-SelfTest`, `-Inspect` and `-DeviceCode`
  go straight in, as before.
- **Help in the window**: the **?** button in the top bar - how to use GatewayLens,
  what each action needs, what is new, report a problem (a GitHub issue with the
  version filled in, nothing from the tenant), the project on GitHub, and About. F1
  opens the guide. After an update, *What is new* shows once.
- **Access left behind by deleted accounts.** An object id that Microsoft Entra ID
  no longer knows is marked *Not in Microsoft Entra ID* in the access lists, the
  Users column and the log. The portal leaves such principals out of its lists, so
  they are easy to miss - and they still hold their roles. *Show > Access by
  accounts not in Entra ID* lists every connection one of them can still use, and
  the self-test counts them.
- **Panels you can resize**: drag the grips between the list, the access panel and
  the actions, and above the log. The sizes are kept for next time.
- `-Screenshots <folder>`: pictures of the demo, for the README.

### Changed
- **The activity log is in colour** - green for what went well, amber for warnings,
  red for failures, the time in grey - and follows the text size. Ctrl+C copies the
  selected lines; right-click copies everything shown.
- **Names in the Users column and the User filter.** On a real tenant the unofficial
  directory gives only object ids; they are now named through Microsoft Graph while
  the connections load. The User filter finds people by display name, email or id.
- **Kiosk view** moved to the top bar, with its own look and an icon.

### Fixed
- **A remembered entry could not be picked again** in a search box after its text
  was deleted: the entry stayed selected, and WPF ignores a click that does not
  change the selection. Opening the list now lets go of it.
- **The Account column emptied after Update credentials.** The column shows the
  readable copy of the username that the portal saves next to the encrypted
  credentials, and Microsoft's credentials API stores only the encrypted one. The
  list now shows the new account straight away, and the log says that it can be
  empty after the next refresh. The connections use the new account either way.
- The first item of the gateway tiles' right-click menu did nothing: a list of menu
  rows written on one line wrapped its first row once more. A guard test catches it.

## [0.7.0] - 2026-10-12

From the first run on a real tenant with thousands of connections.

### Fixed
- **Access lists showed object ids, not names.** Fabric's role assignments carry
  only each principal's id and type. GatewayLens now asks Microsoft Graph for the
  names - up to 1,000 in one call - and remembers them for the session. Gateway
  access, connection access, the Users column, the User filter, the access report
  and the delete backup show names and emails. If Graph refuses, the lists show the
  ids, and the log says so once.
- **The window froze for half a minute** when a filter was typed in or cleared:
  every keystroke filtered and redrew thousands of rows. The filter boxes now wait
  until typing stops, and the connection rows are made in the background, not on
  the window's thread.
- **Auto-refresh stayed on after the kiosk view**, and redrew the connections every
  minute. Leaving the kiosk view now sets auto-refresh back to what it was. It is
  off by default.
- **Disabling one member read every gateway cluster again.** Now only that cluster
  is read again, and the connections are redrawn only if a gateway's state changed.
- **Granting access looked as if it did not work**: the access panel was not read
  again, and showed ids. After every grant, removal or handover, the connections
  concerned are read again, and the panel shows the result.
- While the connections were loading, the old list could still be changed - and
  then the window froze. While a change or a load runs, the buttons that would clash
  with it now wait. Looking, filtering and copying stay open.

### Added
- **Several members at once**: select them, then Enable or Disable. The
  confirmation names each one, and warns before the last enabled member of a
  cluster is disabled.
- **SkipTest column**, and *Show > Skip test connection on*. Verify status marks
  such a connection **Unverified** instead of OK: with the flag on, a test says
  nothing about it.
- **Verify status reports as it goes**: each connection and its outcome go to the
  log while the run is still testing, ten at a time.
- **Verify users logs every connection with its users**, by name - or why it could
  not be read.
- **Grant access looks first**: someone who already has the role, or a higher one,
  is left alone, and a lower role is raised.
- **The tiles follow the text size** - A-, A+ and Ctrl + mouse wheel make them
  smaller or larger, text and all.
- **A fuller log**: every item of a bulk run, not only the failures (the first
  1,000 in the panel, all of them in the file); how long each load and run took;
  what each load reads; what the list shows after a filter changes; each automatic
  refresh; theme changes.
- Self-test: **Graph: names in access lists** checks that names can be read.

### Changed
- *Gateways too* in Hand over access is now **Gateway clusters too**, and off by
  default.
- Hand over access needs the object id of who hands over when Microsoft Graph is
  not available, or when their account has been deleted - the access lists show it.
  A name is never guessed.
- The built-in app registration also asks for `Directory.Read.All` (delegated), for
  the names in access lists.
- The demo answers like a real tenant: its role assignments carry only ids.

## [0.6.1] - 2026-10-12

### Fixed
- **GatewayLens.exe could not sign in with Az.Accounts**: "A window handle must be
  configured". Az.Accounts signs in through the Windows account broker, which needs a
  window to show its dialog on, and the exe hides the console. Without a console
  window GatewayLens now has Az.Accounts sign in through the browser - for its own
  process only, the user's Az setting is left as it is - and if the broker fails that
  way anyway, the browser gets one more try. Without a console it also skips the
  subscription question Az.Accounts asks after signing in, which would otherwise
  wait for an answer no one can give. The script, started from a console, keeps
  using the broker.

## [0.6.0] - 2026-10-12

### Changed
- **No module is required any more.** GatewayLens picks whichever way in works
  with nothing more to do:
  - **Az.Accounts, when it is installed** - as before. Microsoft's Azure PowerShell
    is already approved in practically every tenant, so no one has to approve
    anything.
  - **Built-in sign-in, when it is not** - GatewayLens signs in by itself, through
    the browser, as its own app registration. Nothing to install; the organisation
    approves GatewayLens once. On a company PC the browser usually signs in without
    a password, because Edge and Chrome pass on the Windows sign-in.
- The built-in sign-in is plain OAuth 2.0 against Microsoft Entra ID: authorization code with
  PKCE, through a one-off listener on this computer that only accepts connections
  from this computer. `-DeviceCode` signs in on another device. One sign-in gives
  the Fabric, Power BI and Microsoft Graph tokens, and each is renewed before it
  runs out. Tokens stay in memory - never in a file, the log or the change record.
- `docs/sign-in.md` explains both ways, how an organisation approves GatewayLens,
  and what to forward to IT.
- Sign-in errors say what to do next: not approved yet (with Az.Accounts offered as
  the way round it), a sign-in policy, an expired sign-in, a wrong tenant.

- **The Gateways tab is a monitoring wall.** One coloured tile per gateway cluster -
  green online, amber degraded, red offline, grey when there is no live status -
  with problems first, members online, versions, and a banner with the totals.
  Click a tile for its members and access, as before.
- Personal-mode gateways are no longer shown, and VNet gateways always are: the
  tool is for the gateways a team runs - on-premises and virtual network.
- **The Connections tab shows gateway connections** - on-premises, VNet and
  streaming VNet - with **Include cloud connections** to add the shareable cloud
  ones. Personal, Automatic and unbound connections are never listed.
- The README leads with what the tool is for: the jobs big tenants struggle with in
  the portal, and how GatewayLens does each one in bulk.

### Fixed
- **Verify status and Verify users did nothing in the window** - "0 OK, 0 failed".
  Their background jobs took the list as `$I` and looped with `$i`, and PowerShell
  names ignore case: the loop overwrote the list with 0. The functions themselves
  were tested; the window's path to them was not. A test now presses both buttons on
  demo data, and a guard refuses any parameter spelled again with other capitals.
- **The search boxes forgot what was typed** when left: their handlers were made
  with `.GetNewClosure()`, which runs them in a module of their own, where the
  script's functions do not exist. A guard now checks every such handler.
- An unexpected error now writes its full details to the log file, and the same
  error many times in a row is logged once, with a count.
- **A connection or gateway that nobody has access to read as "could not be read"** -
  in Verify users ("error"), and in the backup before a delete. PowerShell turns an
  empty list that comes out of an if-statement into nothing; the list is now
  assigned directly, and a test checks it.
- A guard now refuses a parameter named like an automatic variable: `$PId` is `$PID`,
  which is read-only, and a scriptblock that took it failed every time it ran.

### Added
- **Text size with Ctrl + mouse wheel**, as in a browser - and Ctrl + plus, Ctrl + minus,
  Ctrl + 0 for the default. The same steps as A- and A+, from 9 to 20, kept in the
  settings. While Ctrl is held, the list under the mouse does not scroll.
- **Compact rows that follow the text size** - a row is the text's line height plus a
  little air: 22 at the default size instead of a fixed 28, so about a quarter more
  rows fit on the screen; 18 at size 9, 33 at size 20. The column headers follow too.
  Input boxes had a fixed height that cut off larger text; they now grow with it, and
  a guard keeps any new one from getting a fixed height.
- **Every list sorts and copies like a spreadsheet** - connections, members and both
  access lists:
  - Click a column name to sort; an arrow shows which way. The sort now lasts through
    refreshes and filter changes - WPF forgot it every time the rows were replaced,
    and the modern header style had no arrow, so sorting looked broken.
  - Ctrl+C copies the selected rows, Ctrl+Shift+C with the column names; right-click
    adds Copy cell and Copy all rows. Tab-separated, in the order shown, so it pastes
    into Excel as cells. Exports follow the sort on screen too.
  - Double-click a cell to open it as read-only text, all selected, to copy part of
    it. Nothing is ever written back: the columns are template columns with one-way
    bindings - a text column with a one-way binding refuses to open at all.
  - Several rows can be selected in every list. Remove access, and Enable or Disable
    a member, still take one at a time and say so if more are selected.
  - The gateway tiles have a right-click menu too - copy this gateway, all of them,
    or the id - and Ctrl+C.
- **Hand over access** - for someone leaving, or a new owner. Name who hands over and
  who takes over; **Copy access** gives the successor exactly the same roles on every
  listed connection, and with *Gateways too* on every gateway on the Gateways tab -
  raising a lower role where they already have one. **Move access** does the same,
  then removes the old roles - but only where the successor has them by then, so no
  connection is ever left without its owner. The one handing over is matched by
  object id, UPN or email, never by display name, so someone whose account is
  already deleted can still be handed over by their email. Left empty, *From* takes
  the one person the User filter matches - and refuses if it matches several. Every
  grant, raise and removal is in the change record.
- **Cleanup views** - a *Show* filter on the Connections tab: *last used over 30, 90,
  180 or 365 days ago*, *no use recorded*, *duplicates* (the same gateway, type, path
  and account, side by side) and *failing tests*. Then Delete, which writes a backup
  first.
- **Connections per cluster against Microsoft's limit of 1,000 data sources** - on
  every tile, counted from the connections list and the data source directory
  together. Badges: NEAR CONNECTION LIMIT from 800, AT CONNECTION LIMIT at 1,000.
- **Access report** - who can use what, read fresh from Fabric: one row per
  connection or gateway and person, with the role, the credential account and when
  the connection was last used. With the User filter set, everything that one person
  can access.
- **Test them afterwards** - after a mass credential update, exactly the connections
  that took the new credentials are tested, and the log says how many still fail.
  On by default.
- The demo has a stale duplicate of Sales DW to find, and walks through a handover:
  Joe Smith is leaving.
- **Connection recency** (a Fabric preview): Created, LastLinked, LastUsed and
  UnusedDays columns on the Connections tab and in its CSV export, from the
  `connectionRecency` object the connections list already returns - no extra call.
  LastUsed is when the credentials were last used at run time; empty means not
  recorded, including use from before Microsoft began recording it.
- **Skip VNet status**, on by default. A status check starts a VNet gateway that
  has gone to sleep, and it then uses capacity until it sleeps again - many tenants
  let them sleep after 30 minutes. While it is on, no status call goes to a VNet
  gateway and its tile says it was not checked; the self-test never checks one.
  Untick it to have them checked like the rest.
- **Kiosk view** - full screen, tiles only, no button that changes anything,
  refreshing every minute - for a wall screen. The **Kiosk view** button, `-Kiosk`
  or F11; Esc or F11 leaves it.
- **Down for** - how long a gateway or member has been offline, counted from when
  this window first saw it (the API keeps no history).
- **Gateway versions against Microsoft's own list.** The newest build comes from the
  gateway's Download Center page, the six releases Microsoft still supports from the
  Learn page of monthly updates - read once a session (again after 12 hours), with
  no sign-in and nothing about the tenant sent. Tiles say UNSUPPORTED VERSION, MIXED
  VERSIONS or UPDATE AVAILABLE; the banner names the newest build; each member shows
  its release month and whether it is supported; the self-test checks both pages.
  If the pages cannot be read, tiles compare members with each other (OLDER VERSION).
- `-SignIn Auto|AzAccounts|Browser` - Auto by default; the other two choose one way.
- `-Account` - sign in with another account than the Windows one, such as a
  separate admin account. Works with both ways.
- `-ClientId` - use your organisation's own app registration instead of the
  built-in one.

### Removed
- `-AuthModule`, and sign-in through MicrosoftPowerBIMgmt: it could not look people
  up by name, and the built-in sign-in now covers computers without Az.Accounts.
- **The Create connections tab**, with its CSV import and connection-string parsing.
- **The Activity tab and Undo.** Every change is still written to the change record
  files the moment it happens, and nothing is changed if the record cannot be
  written - there is just no tab to browse it in. **Open folder** in the log panel
  shows the files. The demo no longer makes up a week of history.
- The "Include VNet gateways" checkbox.

## [0.5.5] - 2026-10-11

### Fixed
- **Every list of objects from a background job arrived empty.** Unpacking a job's
  result read `$r.BaseObject`, which on a list is member enumeration: PowerShell took
  `BaseObject` of every item, and for a `[pscustomobject]` that is an empty
  placeholder. The Activity tab showed no changes; in real use every bulk operation
  would have reported every item as not done, with no name or reason, and the access
  panels would have shown empty rows. It now reads `$r.PSObject.BaseObject`.
- **Resolve IPs** showed only the last gateway: a job's result is the last thing it
  writes, and it wrote one result per gateway. It now returns them as one list.
- The tests now send lists of real objects through the real worker pool - the old
  test used a list of numbers, which has no properties to lose - and drive the
  Activity tab's own refresh with stand-in controls.

## [0.5.4] - 2026-10-11

### Fixed
- **Demo mode wrote into the real folders** - its log, its made-up change history and
  any backups went where the real ones live. A script's parameters are its script
  variables, so filling in the default `-LogFolder` made the demo think a folder had
  been given. The demo now checks which parameters were really passed, the
  self-test checks in demo mode that it stays in its own folder, and a guard stops
  any parameter being overwritten through `$script:`.
- The window smoke test says where it looked when the Activity tab comes up short.

## [0.5.3] - 2026-10-11

### Fixed
- **The window did not open** - "'#FFDC2626' is not a valid value for property
  'Style'". The red button style and the red theme brush were both called Danger,
  and the brush was found first. Every style now has a name ending in what it styles
  (`DangerButton`, `LabelText`), and a test checks that no style and brush share one.

## [0.5.2] - 2026-10-11

### Fixed
- **The window did not open** - "'#FFF4F6FA' is not a valid value for property
  'Background'". Theme brushes were made with `New-Object`, which wraps them in a
  PowerShell object; a WPF resource dictionary stores that wrapper as it is, and WPF
  could only read it as text. Every `New-Object` in the script is now `::new()`, and
  a guard test keeps it that way.
- An unexpected error inside the window is now logged, and the window stays open.

### Added
- **A test of the real window.** `-SmokeTest` opens it on demo data, waits for every
  load, goes through every theme and tab and two text sizes, and closes it. It fails
  on any logged error, on falling back to the classic look, or on missing data. It
  runs with the test suite on Windows - on your PC and on GitHub with every push.
  Set `GATEWAYLENS_NO_WINDOW_TEST=1` to skip it.

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
