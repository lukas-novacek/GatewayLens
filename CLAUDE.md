# GatewayLens - notes for Claude Code

Read this first, every session. It holds what cannot be seen from the code alone:
how to check your work, and the traps this project has already fallen into.

## What it is

A desktop console for Microsoft on-premises data gateways and their connections,
for Power BI and Microsoft Fabric. One PowerShell 7 script with a WPF window. It
talks only to Microsoft: the Fabric and Power BI REST APIs, Microsoft Graph for
name lookups, and two public pages for the newest gateway version (Download Center,
Learn - no token is ever sent there). Sign-in: Az.Accounts when installed (no tenant approval needed),
otherwise built-in OAuth in the browser as its own multi-tenant app registration
(no module needed). No database, no server, no agent. MIT licence,
published on GitHub as freeware for anyone.

The user signs in as themselves and the tool acts with their permissions. It can
change real access and credentials on hundreds of connections, so correctness and
safety come before features.

## Layout

- `GatewayLens.ps1` - the whole application, about 5,000 lines, in this order:
  CORE (requests, paging, parallel GET), SHAPING (API objects into grid rows, pure),
  CREDENTIAL ENCRYPTION (port of Microsoft's SDK), CONNECTION MANAGEMENT,
  BULK OPERATIONS, SETTINGS AND HISTORY, THEMES, ACTIVITY LOG AND CHANGE RECORD,
  DEMO MODE, the worker function list, SIGN-IN, SELF-TEST, INSPECTION, WINDOW
  (XAML in here-strings, then the UI functions), MAIN.
- `tests/Run-Tests.ps1` - the test suite. Needs no tenant and no sign-in.
- `build/` - `GatewayLens.exe`: a small .NET Framework 4.8 launcher (C#) that carries
  the script inside it, and `Build-Exe.ps1`.
- `assets/` - icons. `docs/permissions.md` - which role each action needs.
  `docs/sign-in.md` - how sign-in works, approval by IT, the app registration.
  `docs/testing-on-a-real-tenant.md` - the checklist for a real tenant, read-only first.
- `.github/workflows/` - tests on Linux and Windows, exe build, release on a tag.

## Commands

```
pwsh -NoProfile -File tests/Run-Tests.ps1                # must pass before every commit
pwsh -NoProfile -File GatewayLens.ps1 -Demo -SelfTest    # end to end on fictional data, any OS
pwsh -NoProfile -File GatewayLens.ps1 -Demo              # the window on fictional data (Windows)
pwsh -NoProfile -File GatewayLens.ps1 -Demo -SmokeTest   # drives the real window and the start page (Windows)
pwsh -NoProfile -File build/Make-Marketing.ps1   # the README pictures, the tour and the social preview, from the demo
pwsh -NoProfile -File build/Build-Exe.ps1                # needs the .NET SDK
```

The smoke test drives the real window but cannot judge how it looks. After a change
to the window, look at the pictures `-Screenshots` makes, say what you could not
check, and ask the user to try it with `-Demo`.

## Rules

Each rule is here because breaking it caused a real bug. Several are enforced by
guard tests - never weaken a guard to make it pass; fix the code instead.

1. **Run the tests after every change**, and show the result. Read failures before
   fixing them: more than once the failing test was right and the code was wrong.
2. **A function that ends with `return , @(...)` emits one object - the whole array.**
   Never pipe its call (`Get-X | Where-Object`) or wrap it (`@(Get-X)`): assign it
   to a variable first, then filter the variable. Guard: "array-returning". A line
   that shows the trap on purpose is marked `# deliberate-trap`.
3. **Create lists with `[System.Collections.Generic.List[object]]::new()`**, never
   `New-Object`: in PowerShell 7.4 a list made with New-Object throws "Argument types
   do not match" inside `@()`. Guard.
4. **Uncaught output becomes a function's return value.** Discard what you do not
   mean to return: `$null = Add-Something ...`.
5. **Rows of an array written one per line inside `@( )` are flattened** into loose
   values. Start each row with a comma: `,@('a', 'b')`. On one line it is the other
   way round: `@(@('a', 1), @('b', 2))` - a leading comma there, `@(, @(..), @(..))`,
   wraps the first row once more, and a menu lost its first item. Guard.
6. **Every function a background job calls must be in `$script:WorkerFunctions`.**
   A missing one only fails when the button is pressed. Guard.
7. **Plain ASCII in every file. No GUID literals** - except the built-in public client
   id, on the one line marked `# public-client-id`. Guard. **No tenant data** - no real names,
   ids, emails, server names. Use Contoso and the demo for examples.
   `tests/forbidden-words.local.txt` holds the user's private words; it is never
   committed and the tests check every file against it.
8. **CSV meant for Excel: `Export-Csv -Encoding utf8BOM`**, or accented names come
   out garbled. Guard.
9. **Colours only through theme brush names.** A new brush goes into all four themes
   in `$script:Themes`. Style keys end in what they style - `DangerButton`,
   `LabelText` - and never share a name with a brush: the window's brushes are
   found first, so a style named like a brush gets the brush. Guards.
10. **XAML lives in here-strings and must stay well-formed** - the tests parse it.
    New controls need `Name="..."` and are reached as `$script:UI.Name`. Styling can
    fail at run time without the tests noticing; that is why the modern style
    dictionary loads inside a try, with the classic one as fallback.
11. **Never log, record or store a password or a token.** Not in the log, the change
    record, a backup, the settings or history. Tokens and the refresh token live in
    `$script:Auth`, in memory only. Tests check this. A Teams or Power Automate alert
    address works like a password: it is stored only DPAPI-encrypted
    (`Protect-GLText`), and never in a message, an error or the log.
12. **Unofficial endpoints** (Power BI v2) and **web pages** (`Get-GLGatewayReleases`)
    stay isolated in their own function, are optional, and degrade to empty columns -
    never to an error. Never send a token to a web page. The one unofficial change,
    credentials like the portal (`Set-GLConnectionCredentialPortal`), has its own
    checkbox and falls back to the documented call only when the endpoint refused
    the request (`Test-GLPortalWayRefused`) - never after the gateway's answer or no
    answer, which could send the same change twice.
13. **Every change to a tenant** starts with `Get-GLRunAudit` (no record, no change)
    and records each item with `Write-GLChange` as it happens.
14. **Bulk runs act on every listed row**, never on the selection, one item at a
    time, and can be cancelled. Delete always writes a backup first and refuses
    without one. The one exception: Enable and Disable act on the selected members
    of one cluster - a handful, each named in the confirmation. What only reads -
    Verify status, Verify users - may act on the selection, from the right-click menu.
15. **Demo mode must answer every endpoint the app calls.** A new API call needs a
    route in `Invoke-GLDemoHttp` and a demo test.
16. **WPF events bubble.** `SelectionChanged` on the tab control also fires for every
    list inside it - check `$e.OriginalSource`.
17. **Tests must never open a real browser or reach Entra ID.** The sign-in tests
    replace `Open-GLBrowser` and `Invoke-GLTokenEndpoint`. Do not stub a scriptblock
    parameter through `$PSDefaultParameterValues`: it runs a scriptblock value to get
    the default instead of passing it, the binding fails, and the real one runs.
18. **A VNet gateway is never asked for its status unless the user unticks Skip VNet
    status**: a status check starts a sleeping one, and it then uses capacity.
    `Get-GLGatewayData` leaves VNet clusters alone unless given `-CheckVnet`.
19. **Names ignore case, so a variable can be something else.** `$i` is `$I`, `$failed`
    in the tests is the suite's `$script:Failed`, `$PId` is the read-only `$PID`.
    Guards: no parameter spelled again with other capitals, none named like an
    automatic variable. Give job parameters whole names (`$Items`, not `$I`).
20. **An empty list that comes out of an `if` becomes `$null`.** `$x = if (...) { @() }`
    leaves `$x` empty-handed - "nobody has access" turned into "could not be read".
    Assign inside the branch, or wrap the result again with `@()`.
21. **Move access removes the old role only where the new principal has it** - never
    leave a connection without its owner. Match principals by object id (or the UPN
    or email an assignment carries, which the real API leaves out), never by display
    name. Who hands over is turned into an object id first - through Graph, or given
    as one.
22. **Fabric role assignments carry only the principal's id and type** - no name, no
    email. Names come from Graph (`Get-GLPrincipalNames`, getByIds), and the demo
    answers the same way, so code that expects a name in an assignment fails in the
    tests, not on a real tenant.
23. **OnDone runs on the window's thread.** Work on thousands of rows belongs in the
    job's Work block; filter boxes go through `Start-GLDebounce`, never straight to
    a redraw on every keystroke.
24. **A button that changes something or reloads a list goes into `Update-GLActions`**,
    which switches it off while a change or a load runs.
25. **An empty collection is false.** `if ($list)` skips an empty list, an empty
    ObservableCollection, an empty grid's Items - the log panel stayed blank because
    its first line was never added. Test for `$null -ne $x`, or `.Count`.
26. **The start page runs on a thread of its own**, so the sign-in on the main thread
    does not freeze it. They share one synchronized hashtable. A function the page
    calls goes into `$script:StartPageFunctions` - guard.
27. **An object id getByIds does not return is checked, never guessed.**
    `Get-GLMissingPrincipals` asks Graph's recycle bin (deleted lately: name and day)
    and the directory (no such object: deleted). Anything else is Unknown, never
    "deleted". The access panels hide them by default, like the portal, and count them.
28. **Everything a window learns goes into `New-GLState`, or is cleared in
    `Reset-GLSession`.** The start page can come back - out of the demo, or to sign
    in again - and the next window must not see the last one's rows, names or timers.
29. **Alerts never stop a refresh, and never alert on one check.** `Get-GLAlertEvents`
    needs two checks in a row, and a refresh of one cluster leaves the others' counts
    alone. An alert that fails to go out is logged as a warning.
31. **"Can go" comes from recency, and only from rules in `Get-GLCleanupRules`.**
    Nothing made or linked in the grace days, nothing without recency data, and no
    copy still in use is ever a candidate. The tiles, the view and the report all
    read the same CanGo - never their own idea of it.
30. **The tests have their own variables.** `$ast`, `$text`, `$root`, `$s` and others
    belong to the suite: a test that reuses one breaks the checks after it. Give a
    test's variables names of their own.

## Versions and changes

Semantic versioning in `$script:AppVersion`. Every change raises the version and
adds a section to `CHANGELOG.md` - the tests check that the current version has one.
Keep `README.md` in step with what the tool does.

## Writing

Comments explain why, not what. Text the user sees - messages, tooltips, docs - is
plain English in short sentences, says what happened and what to do next, and
never blames the user. Use a short dash (-), never a long one.
