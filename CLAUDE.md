# GatewayLens - notes for Claude Code

Read this first, every session. It holds what cannot be seen from the code alone:
how to check your work, and the traps this project has already fallen into.

## What it is

A desktop console for Microsoft on-premises data gateways and their connections,
for Power BI and Microsoft Fabric. One PowerShell 7 script with a WPF window. It
talks only to Microsoft's REST APIs - Fabric and Power BI, plus Microsoft Graph for
name lookups. No database, no server, no agent. MIT licence, published on GitHub.

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
- `.github/workflows/` - tests on Linux and Windows, exe build, release on a tag.

## Commands

```
pwsh -NoProfile -File tests/Run-Tests.ps1                # must pass before every commit
pwsh -NoProfile -File GatewayLens.ps1 -Demo -SelfTest    # end to end on fictional data, any OS
pwsh -NoProfile -File GatewayLens.ps1 -Demo              # the window on fictional data (Windows)
pwsh -NoProfile -File build/Build-Exe.ps1                # needs the .NET SDK
```

The window cannot be tested automatically. After a change to it, say so and ask the
user to check it with `-Demo`.

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
   values. Start each row with a comma: `,@('a', 'b')`.
6. **Every function a background job calls must be in `$script:WorkerFunctions`.**
   A missing one only fails when the button is pressed. Guard.
7. **Plain ASCII in every file. No GUID literals. No tenant data** - no real names,
   ids, emails, server names. Use Contoso and the demo for examples.
   `tests/forbidden-words.local.txt` holds the user's private words; it is never
   committed and the tests check every file against it.
8. **CSV meant for Excel: `Export-Csv -Encoding utf8BOM`**, or accented names come
   out garbled. Guard.
9. **Colours only through theme brush names.** A new brush goes into all four themes
   in `$script:Themes`. Guards.
10. **XAML lives in here-strings and must stay well-formed** - the tests parse it.
    New controls need `Name="..."` and are reached as `$script:UI.Name`. Styling can
    fail at run time without the tests noticing; that is why the modern style
    dictionary loads inside a try, with the classic one as fallback.
11. **Never log, record or store a password.** Not in the log, the change record,
    a backup, the settings or history. Tests check this.
12. **Unofficial endpoints** (Power BI v2) stay isolated in their own function,
    are optional, and degrade to empty columns - never to an error.
13. **Every change to a tenant** starts with `Get-GLRunAudit` (no record, no change)
    and records each item with `Write-GLChange` as it happens.
14. **Bulk runs act on every listed row**, never on the selection, one item at a
    time, and can be cancelled. Delete always writes a backup first and refuses
    without one.
15. **Demo mode must answer every endpoint the app calls.** A new API call needs a
    route in `Invoke-GLDemoHttp` and a demo test.
16. **WPF events bubble.** `SelectionChanged` on the tab control also fires for every
    list inside it - check `$e.OriginalSource`.

## Versions and changes

Semantic versioning in `$script:AppVersion`. Every change raises the version and
adds a section to `CHANGELOG.md` - the tests check that the current version has one.
Keep `README.md` in step with what the tool does.

## Writing

Comments explain why, not what. Text the user sees - messages, tooltips, docs - is
plain English in short sentences, says what happened and what to do next, and
never blames the user. Use a short dash (-), never a long one.
