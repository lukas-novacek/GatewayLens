# Testing on a real tenant

The automated tests run against stand-ins and the demo. They prove the logic, but
only a real tenant shows what Microsoft's APIs really return. This checklist goes
from read-only to changes, and makes every change on a scratch connection first.

Tick each step, and note anything that looks wrong - with names removed if you share
it publicly.

## Before you start

- [ ] Windows, PowerShell 7.2 or later: `pwsh -v`
- [ ] A way to sign in: Az.Accounts installed (`Install-Module Az.Accounts -Scope CurrentUser`),
      or an app registration and `-ClientId` - see [sign-in.md](sign-in.md)
- [ ] A **test gateway cluster** you are Admin on, ideally with two or more members
- [ ] In the portal, a **scratch connection** on that gateway, to a data source you
      have test credentials for. Name it so it cannot be mistaken: `GatewayLens TEST`
- [ ] A colleague, or a test account, who may be given access to it

## 1. Read-only: what the APIs return

- [ ] `.\GatewayLens.ps1 -Inspect` - lists field names and dates only, no data, so it is
      safe to share. Check that **Fabric connections** shows `connectionRecency` with
      its dates, and that **gatewayClusterDatasources** shows `clusterId`.
- [ ] `.\GatewayLens.ps1 -SelfTest` - every API once, read-only. Every line should say
      PASS. A FAIL line names the call and Microsoft's own reason.

## 2. Read-only: the window

- [ ] `.\GatewayLens.ps1` (or the exe) - the start page opens. *Sign in* opens the
      browser, the page waits, and the gateways and connections load. Close the
      browser tab half way once: the page says so, and *Sign in* works again.
- [ ] **Gateways tab:** every cluster you expect is there, and none is personal-mode.
      Online, degraded and offline match the portal.
- [ ] Versions: the banner names the newest build, and *Update available* and
      *Not supported* on the members match
      [Microsoft's list](https://learn.microsoft.com/en-us/data-integration/gateway/service-gateway-monthly-updates).
- [ ] VNet tiles say *Not checked, so it is not woken up* - and a sleeping VNet
      gateway stays asleep.
- [ ] Each tile counts its connections. Compare one cluster with the portal.
- [ ] **Gateway access:** select a tile - the access list shows names and emails. An id
      marked *Not in Microsoft Entra ID* should be a deleted account: look it up in
      the Entra admin center (Users, search by object id) to be sure.
- [ ] **Text size** (Ctrl + mouse wheel): the tiles grow and shrink with the text.
- [ ] **Kiosk view** (F11) on a second screen; Esc leaves it. Auto-refresh is back to
      what it was afterwards.
- [ ] **Connections tab:** gateway connections only; *Include cloud connections* adds
      the cloud ones.
- [ ] Filters: *User* (a colleague), *Account* (a service account), *Search* (a server
      name, then two separated by `;`). Type and delete quickly - the window keeps up,
      and the log says what the list shows once you stop.
- [ ] *Refresh connections* - while it loads, the change buttons are greyed out.
- [ ] Recency: compare *LastUsed* on two or three connections with the portal.
- [ ] **Show:** each view - *Last used over 90 days ago*, *No use recorded*,
      *Duplicates*, *Skip test connection on*, *Access by accounts not in Entra ID*,
      *Failing tests* (after step 3).
- [ ] *UserNames* shows emails, not ids, and the *User* filter finds a colleague by
      their display name.
- [ ] Pick an entry from a search box's history, delete the text, pick it again.
- [ ] Drag the grips to resize the panels; close and start again - they keep the size.
- [ ] The log is in colour and follows Ctrl + mouse wheel. **?** opens the help menu.
- [ ] **Export CSV**, and **Access report...** - with and without the User filter.
      Both open cleanly in Excel, accents included.

## 3. Light load: tests

Each test makes a gateway contact its data source, so start small.

- [ ] Filter to five connections, **Verify status**. The log shows each one as it is
      tested; failing ones say why. One with *SkipTest* on says *Unverified*.
- [ ] **Verify users** on the same five - the Users column fills in with names, and
      the log lists each connection with its users.

## 4. Changes - on the scratch connection only

Search for `GatewayLens TEST`, so the list holds that one connection and nothing else.

- [ ] **Grant** the colleague *User*, then **Remove** them. After each, the log reads
      the connection again and the access panel shows the change. Check both in
      the portal. Grant *User* twice - the second time says they already have it.
- [ ] **Hand over access:** From = you, To = the colleague, **Copy access**. The
      colleague now has your role on it; you still have yours.
- [ ] Then From = the colleague, To = you, **Move access**. The colleague is gone and
      you keep your role.
- [ ] **Update credentials** with the right test credentials and *Test them afterwards*
      ticked - the log says 1 of 1 works. With *Like the portal* ticked, Refresh: the
      Account column still shows the username, and so does the portal. If the log
      says the portal's way was refused, send the HTTP code it names.
- [ ] Again with a wrong password - the log says it still fails, and *Show > Failing
      tests* lists it. Then put the right credentials back.
- [ ] Only on the test cluster, with two or more members: **Disable** a member, then
      **Enable** it again. Only that cluster is read again. Select two members and
      Disable - the confirmation names both, and warns if none would be left.
- [ ] Last: **Delete all listed connections** with the scratch connection alone in the
      list. A backup CSV is written first, and the log names it.

## 5. The record

- [ ] **Open folder** in the log panel. The change record CSV has one row for every
      change above - who, when, what, the result - and no password anywhere.

## What to send back

- The `-Inspect` output (safe to share).
- Any self-test line that said FAIL.
- Anything in the window that did not match the portal - with names removed.
