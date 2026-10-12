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

- [ ] `.\GatewayLens.ps1` - signs in, and the gateways and connections load.
- [ ] **Gateways tab:** every cluster you expect is there, and none is personal-mode.
      Online, degraded and offline match the portal.
- [ ] Versions: the banner names the newest build, and *Update available* and
      *Not supported* on the members match
      [Microsoft's list](https://learn.microsoft.com/en-us/data-integration/gateway/service-gateway-monthly-updates).
- [ ] VNet tiles say *Not checked, so it is not woken up* - and a sleeping VNet
      gateway stays asleep.
- [ ] Each tile counts its connections. Compare one cluster with the portal.
- [ ] **Kiosk view** (F11) on a second screen; Esc leaves it.
- [ ] **Connections tab:** gateway connections only; *Include cloud connections* adds
      the cloud ones.
- [ ] Filters: *User* (a colleague), *Account* (a service account), *Search* (a server
      name, then two separated by `;`).
- [ ] Recency: compare *LastUsed* on two or three connections with the portal.
- [ ] **Show:** each view - *Last used over 90 days ago*, *No use recorded*,
      *Duplicates*, *Failing tests* (after step 3).
- [ ] **Export CSV**, and **Access report...** - with and without the User filter.
      Both open cleanly in Excel, accents included.

## 3. Light load: tests

Each test makes a gateway contact its data source, so start small.

- [ ] Filter to five connections, **Verify status**. Failing ones say why.
- [ ] **Verify users** on the same five - the Users column fills in.

## 4. Changes - on the scratch connection only

Search for `GatewayLens TEST`, so the list holds that one connection and nothing else.

- [ ] **Grant** the colleague *User*, then **Remove** them. Check both in the portal.
- [ ] **Hand over access:** From = you, To = the colleague, **Copy access**. The
      colleague now has your role on it; you still have yours.
- [ ] Then From = the colleague, To = you, **Move access**. The colleague is gone and
      you keep your role.
- [ ] **Update credentials** with the right test credentials and *Test them afterwards*
      ticked - the log says 1 of 1 works.
- [ ] Again with a wrong password - the log says it still fails, and *Show > Failing
      tests* lists it. Then put the right credentials back.
- [ ] Only on the test cluster, with two or more members: **Disable** a member, then
      **Enable** it again.
- [ ] Last: **Delete all listed connections** with the scratch connection alone in the
      list. A backup CSV is written first, and the log names it.

## 5. The record

- [ ] **Open folder** in the log panel. The change record CSV has one row for every
      change above - who, when, what, the result - and no password anywhere.

## What to send back

- The `-Inspect` output (safe to share).
- Any self-test line that said FAIL.
- Anything in the window that did not match the portal - with names removed.
