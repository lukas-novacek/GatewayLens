#Requires -Version 7.2
<#
    GatewayLens test suite. Needs no tenant, no sign-in and no Windows: every call
    to Microsoft is replaced by a stand-in, so it runs anywhere PowerShell 7 does.

        ./tests/Run-Tests.ps1

    Exit code 0 = all passed. Run it before every commit.

    Optional: list words that must never appear in the published code - your
    employer's name, internal server or tenant names - one per line in
        tests/forbidden-words.local.txt
    That file is in .gitignore, so the list itself is never published.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off     # same rules as the script, whatever the caller's session has on
$root   = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'GatewayLens.ps1'

$script:Passed = 0
$script:Failed = 0
function Assert {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:Passed++; Write-Host "  PASS  $Message" -ForegroundColor Green }
    else            { $script:Failed++; Write-Host "  FAIL  $Message" -ForegroundColor Red }
}
function Section([string]$Name) { Write-Host ''; Write-Host $Name -ForegroundColor Cyan }

# ============================================================================
Section 'Repository hygiene'
# ============================================================================
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$parseErrors)
Assert ($parseErrors.Count -eq 0) "GatewayLens.ps1 parses ($($parseErrors.Count) error(s))"

$repoFiles = Get-ChildItem $root -Recurse -File |
    Where-Object { $_.FullName -notmatch '[\\/](\.git|dist|bin|obj)[\\/]' -and $_.Name -notlike '*.local.*' }
# Images are the only binary files allowed, and only in assets/.
$binary    = @($repoFiles | Where-Object { $_.Extension -in '.ico', '.png' })
$repoFiles = @($repoFiles | Where-Object { $_.Extension -notin '.ico', '.png' })
Assert (-not ($binary | Where-Object { $_.Directory.Name -ne 'assets' })) 'image files live only in assets/'
$nonAscii = foreach ($f in $repoFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1) { $f.Name }
}
Assert (-not $nonAscii) "every file is plain ASCII $(if ($nonAscii) { '- not: ' + ($nonAscii -join ', ') })"

# A GUID in the code is almost always a tenant, app registration or object id
# that belongs to someone. The one exception is GatewayLens's own public client id,
# on the single line marked public-client-id - every sign-in page shows it anyway.
$guidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$text   = Get-Content $script -Raw
$marked = @(($text -split "`n") | Where-Object { $_ -match '#\s*public-client-id\s*$' })
Assert ($marked.Count -eq 1 -and $marked[0] -match "^\`$script:BuiltInClientId = '($guidRx)?'\s+#\s*public-client-id\s*$") "exactly one line is marked public-client-id, and it holds only the built-in client id ($($marked.Count) marked)"
$unmarked = (($text -split "`n") | Where-Object { $_ -notmatch '#\s*public-client-id\s*$' }) -join "`n"
$guids  = [regex]::Matches($unmarked, $guidRx) | ForEach-Object Value
Assert (-not $guids) "no other GUID literals in the script $(if ($guids) { '- found: ' + ($guids -join ', ') })"

# Tokens are as good as a password for an hour: nothing may write one anywhere.
$leaks = @(($text -split "`n") | Where-Object {
    $_ -match '(Write-GLLog|Write-Host|Write-GLChange|Write-GLLogFile|Add-Content|Set-Content|Out-File|Export-Csv)' -and
    $_ -match '(access_token|refresh_token|RefreshToken|code_verifier|\.Verifier|Tokens\[)' })
Assert (-not $leaks) "no token is written to the log, the change record or a file $(if ($leaks) { '- ' + ($leaks.Trim() -join '; ') })"

$wordFile = Join-Path $PSScriptRoot 'forbidden-words.local.txt'
if (Test-Path $wordFile) {
    $words = Get-Content $wordFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
    $hits  = foreach ($f in $repoFiles) {
        $body = Get-Content $f.FullName -Raw
        # the embedded icon is random-looking Base64 and can spell anything
        $body = [regex]::Replace($body, "IconPng = '[A-Za-z0-9+/=]+'", "IconPng = ''")
        foreach ($w in $words) { if ($body -match [regex]::Escape($w)) { "$($f.Name): '$w'" } }
    }
    Assert (-not $hits) "no forbidden words in the repository ($($words.Count) checked) $(if ($hits) { '- ' + ($hits -join '; ') })"
}
else {
    Write-Host '  SKIP  forbidden-words check - create tests/forbidden-words.local.txt to enable it' -ForegroundColor DarkYellow
}

# Assigning to an automatic variable ($host, $args, $input, ...) either fails at
# run time or silently does something else. Both have happened in real code.
$automatic = @('args', 'input', 'host', 'pwd', 'error', 'matches', 'event', 'eventargs', 'sender',
               'this', 'psitem', 'myinvocation', 'pscmdlet', 'psboundparameters', 'home', 'pid',
               'profile', 'foreach', 'switch', 'lastexitcode', 'executioncontext', 'true', 'false')
# ($null is deliberately absent: "$null = <expression>" is the standard way to discard output.)
$bad = $ast.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
    $automatic -contains $n.Left.VariablePath.UserPath.ToLowerInvariant()
}, $true) | ForEach-Object { "`$$($_.Left.VariablePath.UserPath) (line $($_.Extent.StartLineNumber))" }
Assert (-not $bad) "no assignment to an automatic variable $(if ($bad) { '- ' + ($bad -join ', ') })"
# A parameter is assigned too, when it is bound - $PId is $PID, read-only, and a
# scriptblock with param($PId) failed every time it ran.
$badParams = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true) |
    Where-Object { $automatic -contains $_.Name.VariablePath.UserPath.ToLowerInvariant() } |
    ForEach-Object { "line $($_.Extent.StartLineNumber): `$$($_.Name.VariablePath.UserPath)" })
Assert (-not $badParams) "no parameter is named like an automatic variable $(if ($badParams) { '- ' + ($badParams -join ', ') })"

# #Requires above the help block makes Get-Help ignore the help entirely - the
# first thing many admins type would show nothing but a parameter list.
$synopsis = (Get-Help $script).Synopsis
Assert ($synopsis -match 'GatewayLens - ') "Get-Help shows the real synopsis"

# A function that returns ",@(...)" emits ONE object - the whole array. Piping its
# call, or wrapping the call in @(), hands that array on as a single item: a filter
# then keeps everything or nothing, and a loop runs once. Callers must assign first.
$commaFns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Body.Extent.Text -match 'return\s*,' } | ForEach-Object { $_.Name })
$trap = foreach ($line in (($text + "`n" + (Get-Content $PSCommandPath -Raw)) -split "`n")) {
    foreach ($f in $commaFns) {
        if ($line -match "@\(\s*$([regex]::Escape($f))\b" -or $line -match "\b$([regex]::Escape($f))\b[^|`n]*\|\s*(Where|ForEach|Select|Sort|Measure)") {
            if ($line -notmatch "^\s*function " -and $line -notmatch 'deliberate-trap') { "$f in: $($line.Trim())" }
        }
    }
}
Assert (-not $trap) "no array-returning function is piped or wrapped directly - in the script or the tests ($($commaFns.Count) checked) $(if ($trap) { '- ' + ($trap -join ' | ') })"

# "@(, @(a), @(b))" on one line wraps the first row once more - the leading comma binds
# tighter than the list - and a menu built that way lost its first item. Rows on one
# line are written "@(@(a), @(b))"; the leading comma is for a single row, or one per line.
$wrapRows = @(($text -split "`n") | Where-Object { $_ -match '@\(\s*,\s*@\(.*?\)\s*,\s*@\(' -and $_ -notmatch 'deliberate-trap' } | ForEach-Object { $_.Trim() })
Assert ($wrapRows.Count -eq 0) "no list of rows on one line starts with a comma - it wraps the first row $(if ($wrapRows.Count) { '- ' + ($wrapRows -join ' | ') })"

# Every function a background worker calls must be handed to the worker - a missing
# one only fails when the button is pressed, on a real tenant.
$wf = $null
$m = [regex]::Match($text, "(?s)\`$script:WorkerFunctions = @\((.*?)\)")
if ($m.Success) { $wf = @([regex]::Matches($m.Groups[1].Value, "'([A-Za-z-]+)'") | ForEach-Object { $_.Groups[1].Value }) }
$defs = @{}
foreach ($d in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $defs[$d.Name] = $d }
$missingDeps = foreach ($w in $wf) {
    if (-not $defs.ContainsKey($w)) { continue }
    $calls = $defs[$w].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs.ContainsKey($_) } | Sort-Object -Unique
    foreach ($c in $calls) { if ($wf -notcontains $c) { "$w calls $c" } }
}
Assert ($wf -and -not $missingDeps) "every function a worker calls is given to the workers $(if ($missingDeps) { '- ' + ($missingDeps -join '; ') })"

# The same for the scripts the window hands to workers: every GL function they call
# must be in the worker list.
$workBlocks = [regex]::Matches($text, "(?s)-Work \{(.*?)\n    \} -OnDone") | ForEach-Object { $_.Groups[1].Value }
$workCalls  = foreach ($b in $workBlocks) { [regex]::Matches($b, '\b([A-Z][a-z]+-GL[A-Za-z]+)\b') | ForEach-Object { $_.Groups[1].Value } }
$notGiven   = @($workCalls | Sort-Object -Unique | Where-Object { $wf -notcontains $_ })
Assert ($workBlocks.Count -gt 5 -and -not $notGiven) "every function used in a background job is given to the workers ($($workBlocks.Count) jobs checked) $(if ($notGiven) { '- missing: ' + ($notGiven -join ', ') })"

# The start page runs on a thread of its own: every function it calls, and every one
# those call, must be handed to it - or the page fails only when it opens.
$spf = @()
$m = [regex]::Match($text, "\`$script:StartPageFunctions = @\((.*?)\)")
if ($m.Success) { $spf = @([regex]::Matches($m.Groups[1].Value, "'([A-Za-z-]+)'") | ForEach-Object { $_.Groups[1].Value }) }
$spBlock = $defs['Get-GLStartPageScript'].Body
$spNeed = @($spBlock.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs.ContainsKey($_) })
foreach ($f in $spf) { if ($defs.ContainsKey($f)) { $spNeed += @($defs[$f].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs.ContainsKey($_) }) } }
$spMissing = @($spNeed | Sort-Object -Unique | Where-Object { $spf -notcontains $_ })
Assert ($spf.Count -ge 4 -and -not $spMissing) "every function the start page calls is given to its thread $(if ($spMissing) { '- missing: ' + ($spMissing -join ', ') })"

$hereStrings = [regex]::Matches($text, "(?s)\`$script:(MainXaml|StartXaml|InfoXaml|AlertsXaml|DialogXaml|PromptXaml|ModernStylesXaml|ClassicStylesXaml) = @'\r?\n(.*?)\r?\n'@")
Assert ($hereStrings.Count -eq 8 -and $hereStrings[0].Groups[1].Value -eq 'MainXaml') 'all eight XAML blocks found (six windows, two style sets), the main window first'
foreach ($m in $hereStrings) {
    $ok = $true
    try { [void][xml]$m.Groups[2].Value } catch { $ok = $false }
    Assert $ok "$($m.Groups[1].Value) is well-formed XML"
}

$declared = [regex]::Matches($hereStrings[0].Groups[2].Value, 'Name="([A-Za-z]+)"') | ForEach-Object { $_.Groups[1].Value }
$used     = [regex]::Matches($text, '\$script:UI\.([A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$missing  = $used | Where-Object { $declared -notcontains $_ }
Assert (-not $missing) "every control the code uses exists in the window $(if ($missing) { '- missing: ' + ($missing -join ', ') })"

# ============================================================================
#  Load the functions
# ============================================================================
. $script -LoadOnly

$version = $script:AppVersion
Assert ($version -match '^\d+\.\d+\.\d+$') "version '$version' is MAJOR.MINOR.PATCH"
$changelog = Join-Path $root 'CHANGELOG.md'
if (Test-Path $changelog) {
    Assert ((Get-Content $changelog -Raw) -match "\[$([regex]::Escape($version))\]") "CHANGELOG.md has an entry for $version"
}
Assert ($script:WhatsNew.Version -eq $version -and @($script:WhatsNew.Lines).Count -ge 3) "the What is new window is about $version, not an older release"
# PowerShell names ignore case: a job with param($I) that loops with $i overwrites its
# own input - which is how Verify status and Verify users tested nothing at all.
$shadow = foreach ($b in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockAst] -and $n.ParamBlock -and $n.Parent }, $true)) {
    $pn = @($b.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    foreach ($v in $b.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $u = $v.VariablePath.UserPath
        foreach ($p in $pn) { if ($u -ieq $p -and $u -cne $p) { "line $($v.Extent.StartLineNumber): `$$u is `$$p" } }
    }
}
$shadow = @($shadow | Sort-Object -Unique)
Assert (-not $shadow) "no variable is a parameter spelled with other capitals $(if ($shadow) { '- ' + ($shadow -join '; ') })"

# A .GetNewClosure() handler runs in a module of its own, where the script's
# functions do not exist - the history boxes failed that way on losing focus.
$ourFns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
$closureCalls = foreach ($m in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'GetNewClosure' }, $true)) {
    foreach ($c in $m.Expression.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        if ($ourFns -contains $c.GetCommandName()) { "line $($c.Extent.StartLineNumber): $($c.GetCommandName())" }
    }
}
Assert (-not $closureCalls) "no .GetNewClosure() handler calls the script's own functions $(if ($closureCalls) { '- ' + ($closureCalls -join '; ') })"

$undefined = $script:WorkerFunctions | Where-Object { -not (Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue) }
Assert (-not $undefined) "every worker function is defined $(if ($undefined) { '- missing: ' + ($undefined -join ', ') })"

# ============================================================================
Section 'Small helpers'
# ============================================================================
Assert (Test-GLGuid '0f8fad5b-d9cb-469f-a165-70867728950e'.Replace('0f8fad5b', 'abcdef01')) 'a GUID is recognised'
Assert (-not (Test-GLGuid 'someone@contoso.com')) 'an email is not a GUID'
Assert (-not (Test-GLGuid '')) 'empty is not a GUID'

$body = New-GLRoleAssignmentBody -PrincipalId 'p1' -PrincipalType 'Group' -Role 'User' | ConvertTo-Json -Compress -Depth 5
Assert ($body -match '"principal":\{' -and $body -match '"id":"p1"' -and $body -match '"type":"Group"' -and $body -match '"role":"User"') 'role assignment body has the documented shape'

# ============================================================================
Section 'Sign-in - plain OAuth in the browser, no module'
# ============================================================================
# RFC 7636 appendix B: the published verifier and the challenge it must give
Assert ((ConvertTo-GLCodeChallenge 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk') -eq 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM') 'the PKCE challenge matches the RFC 7636 example'
$pk = New-GLPkce; $pk2 = New-GLPkce
Assert ($pk.Verifier -match '^[A-Za-z0-9_-]{43}$' -and $pk.Challenge -eq (ConvertTo-GLCodeChallenge $pk.Verifier) -and $pk.Verifier -ne $pk2.Verifier) 'each sign-in gets a new random verifier of the right shape'

$q = ConvertFrom-GLQueryString '?code=a%2Fb+c&state=xyz&empty'
Assert ($q.code -eq 'a/b c' -and $q.state -eq 'xyz' -and $q.ContainsKey('empty') -and $q.empty -eq '') 'the browser''s answer is decoded'

$authArgs = @{ ClientId = 'cid'; Tenant = 'organizations'; RedirectUri = 'http://localhost:5000'; Scope = 'a b'; State = 's1'; Challenge = 'ch' }
$u  = New-GLAuthorizeUrl @authArgs
$uq = ConvertFrom-GLQueryString ($u.Split('?')[1])
Assert ($u.StartsWith('https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize?') -and $uq.client_id -eq 'cid' -and $uq.redirect_uri -eq 'http://localhost:5000' -and
        $uq.scope -eq 'a b' -and $uq.state -eq 's1' -and $uq.code_challenge -eq 'ch' -and $uq.code_challenge_method -eq 'S256' -and $uq.response_type -eq 'code') 'the sign-in address carries everything Entra needs'
$uh = ConvertFrom-GLQueryString ((New-GLAuthorizeUrl @authArgs -LoginHint 'jane@contoso.com').Split('?')[1])
Assert (-not $uq.ContainsKey('login_hint') -and $uh.login_hint -eq 'jane@contoso.com') 'an account is suggested to the browser only when there is one'

function New-TestJwt($Claims) { return 'eyJhbGciOiJub25lIn0.' + (ConvertTo-GLBase64Url ([System.Text.Encoding]::UTF8.GetBytes(($Claims | ConvertTo-Json -Compress)))) + '.sig' }
$padOk = foreach ($n in 'a', 'ab', 'abc', 'abcd') { (ConvertFrom-GLJwt (New-TestJwt @{ preferred_username = 'jane@contoso.com'; tid = 'tenant-1'; name = $n })).name -eq $n }
Assert (-not ($padOk -contains $false)) 'the sign-in token is read whatever its length (base64url has no padding)'
$c = ConvertFrom-GLJwt (New-TestJwt @{ preferred_username = 'jane@contoso.com'; tid = 'tenant-1' })
Assert ($c.preferred_username -eq 'jane@contoso.com' -and $c.tid -eq 'tenant-1') 'the name and tenant are read from the sign-in token'
Assert ($null -eq (ConvertFrom-GLJwt 'not-a-token') -and $null -eq (ConvertFrom-GLJwt 'a.!!!.c')) 'a malformed token gives nothing, not an error'

$m = Format-GLSignInError 'invalid_client' "AADSTS700016: Application was not found in the directory.`r`nTrace ID: t1`r`nCorrelation ID: c1"
Assert ($m -match '^invalid_client: AADSTS700016: Application was not found in the directory\. No app registration has this client id' -and $m -notmatch 'Trace ID') 'a sign-in error is one line: the reason and what to do, without trace ids'
Assert ((Get-GLSignInHint 'AADSTS65001: The user or administrator has not consented') -match 'administrator approves it once') 'not approved yet: says an administrator approves it once'
Assert ((Get-GLSignInHint 'AADSTS90094: Admin consent is required') -match 'administrator approves it once') 'users may not approve apps: same advice'
Assert ((Get-GLSignInHint 'AADSTS50011: redirect URI mismatch') -match 'http://localhost') 'a missing redirect address is named'
Assert ((Get-GLSignInHint 'AADSTS7000218: client_assertion or client_secret') -match 'public client flows') 'device code without public client flows is explained'
Assert ((Get-GLSignInHint 'invalid_grant: AADSTS700082: The refresh token has expired') -match 'Restart') 'an expired sign-in says to restart'
Assert ((Get-GLSignInHint 'something unexpected') -eq '') 'an unknown error gets no made-up advice'

# ---- which way to sign in ----
$cid = [guid]::NewGuid().ToString()
Assert ((Select-GLSignIn -AzAvailable $true -BuiltInId $cid) -eq 'Az') 'Auto: Az.Accounts is used when installed - it needs no approval'
Assert ((Select-GLSignIn -AzAvailable $false -BuiltInId $cid) -eq 'Browser') 'Auto: without Az.Accounts, the built-in sign-in - nothing to install'
Assert ((Select-GLSignIn -AzAvailable $true -BuiltInId '' -ClientId $cid) -eq 'Browser') 'Auto: a -ClientId given on purpose means the built-in sign-in, even with Az.Accounts'
Assert ((Select-GLSignIn -Requested Browser -AzAvailable $true -BuiltInId $cid) -eq 'Browser' -and (Select-GLSignIn -Requested AzAccounts -AzAvailable $true -BuiltInId '') -eq 'Az') '-SignIn chooses one way'
$err = ''; try { $null = Select-GLSignIn -AzAvailable $false -BuiltInId '' } catch { $err = $_.Exception.Message }
Assert ($err -match 'Install-Module Az\.Accounts -Scope CurrentUser' -and $err -match '-ClientId' -and $err -match 'docs/sign-in\.md') 'neither way available: says how to get either, instead of opening a browser'
$err = ''; try { $null = Select-GLSignIn -Requested AzAccounts -AzAvailable $false -BuiltInId $cid } catch { $err = $_.Exception.Message }
Assert ($err -match 'not installed' -and $err -match 'Install-Module') '-SignIn AzAccounts without the module says how to install it'
$err = ''; try { $null = Select-GLSignIn -Requested Browser -AzAvailable $true -BuiltInId '' } catch { $err = $_.Exception.Message }
Assert ($err -match 'no app registration' -and $err -match '-ClientId') '-SignIn Browser without a client id says what to do'
$err = ''; try { $null = Select-GLSignIn -AzAvailable $true -BuiltInId $cid -ClientId 'not-an-id' } catch { $err = $_.Exception.Message }
Assert ($err -match 'application \(client\) id') 'a client id that is not one is refused before anything is sent'
Assert ((Get-GLSignInHint 'AADSTS65001') -match 'Install-Module Az\.Accounts') 'not approved yet: Az.Accounts is offered as the way round it'

# ---- Az.Accounts, with the module replaced by stand-ins ----
$keepBuiltIn = $script:BuiltInClientId
$script:AzInstalled = $false
function Test-GLAzAccounts { return $script:AzInstalled }
$script:BuiltInClientId = ''
$err = ''; try { Connect-GL } catch { $err = $_.Exception.Message }
Assert ($err -match 'no way to sign in') 'Connect-GL with neither way available stops before anything is sent'

$script:AzInstalled = $true
$script:AzCalls = [System.Collections.Generic.List[object]]::new()
function Import-Module { param($Name) $script:AzCalls.Add("import $Name") }
function Connect-AzAccount { param($TenantId, [switch]$UseDeviceAuthentication, $AccountId) $script:AzCalls.Add("connect tenant=$TenantId device=$UseDeviceAuthentication account=$AccountId") }
function Get-AzContext { return [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'jane@contoso.com' }; Tenant = [pscustomobject]@{ Id = 'contoso-tenant' } } }
function Get-AzAccessToken {
    param($ResourceUrl)
    $script:AzCalls.Add("token $ResourceUrl")
    if ($ResourceUrl -match 'graph') { throw 'no Graph for this account' }
    return [pscustomobject]@{ Token = (ConvertTo-SecureString "tok-$ResourceUrl" -AsPlainText -Force) }
}
Connect-GL -Account 'admin.jane@contoso.com' -DeviceCode -TenantId 'contoso.onmicrosoft.com'
Assert ($script:AuthMode -eq 'Az.Accounts' -and $script:SignedInAs -eq 'jane@contoso.com' -and $script:TenantShown -eq 'contoso-tenant') 'Az.Accounts sign-in: the window shows who signed in'
Assert ($script:AzCalls -contains 'import Az.Accounts' -and $script:AzCalls -contains 'connect tenant=contoso.onmicrosoft.com device=True account=admin.jane@contoso.com') 'Az.Accounts gets the tenant, the device code choice and the account'
Assert ((Get-GLToken Fabric) -eq 'tok-https://api.fabric.microsoft.com' -and (Get-GLToken PowerBI) -eq 'tok-https://analysis.windows.net/powerbi/api') 'Az.Accounts hands out the Fabric and Power BI tokens, SecureString turned into text'
Assert ($null -eq (Get-GLToken Graph)) 'Az.Accounts without Graph: no token - name lookups fall back to object ids'
$secure = ConvertTo-SecureString 'plain-token' -AsPlainText -Force
Assert ((ConvertFrom-GLToken $secure) -eq 'plain-token' -and (ConvertFrom-GLToken 'already-text') -eq 'already-text') 'a token is text whichever form Az.Accounts uses'
# started from GatewayLens.exe there is no console window for the Windows broker
function Update-AzConfig {
    param($EnableLoginByWam, $LoginExperienceV2, $Scope)
    if ($null -ne $EnableLoginByWam) { $script:AzCalls.Add("config wam=$EnableLoginByWam scope=$Scope") }
    if ($null -ne $LoginExperienceV2) { $script:AzCalls.Add("config picker=$LoginExperienceV2 scope=$Scope") }
}
$script:AzCalls.Clear()
Connect-GL -NoWindow
Assert (($script:AzCalls -join '|') -match 'config wam=False scope=Process\|config picker=Off scope=Process\|connect') 'without a console window, Az.Accounts signs in through the browser and asks no subscription question - for this process only, before signing in'
$script:AzCalls.Clear()
$script:BrokerFails = 1
function Connect-AzAccount {
    param($TenantId, [switch]$UseDeviceAuthentication, $AccountId)
    $script:AzCalls.Add('connect')
    if ($script:BrokerFails-- -gt 0) { throw 'InteractiveBrowserCredential authentication failed: A window handle must be configured.' }
}
Connect-GL
Assert (($script:AzCalls -join '|') -eq 'import Az.Accounts|connect|config wam=False scope=Process|connect' -and $script:AuthMode -eq 'Az.Accounts') "the broker failing for want of a window: the browser gets one more try ($($script:AzCalls -join ', '))"
$script:BrokerFails = 1
function Connect-AzAccount { param($TenantId, [switch]$UseDeviceAuthentication, $AccountId) throw 'AADSTS50126: Invalid username or password.' }
$err = ''; try { Connect-GL } catch { $err = $_.Exception.Message }
Assert ($err -match 'AADSTS50126') 'any other sign-in error is not retried - it is shown as it is'
foreach ($f in 'Import-Module', 'Connect-AzAccount', 'Get-AzContext', 'Get-AzAccessToken', 'Update-AzConfig') { Remove-Item "function:$f" }
$script:AzInstalled = $false

# ---- the built-in sign-in, with Entra replaced by a stand-in ----
$script:TokenCalls   = [System.Collections.Generic.List[object]]::new()
$script:TokenReplies = [System.Collections.Generic.Queue[object]]::new()
function Invoke-GLTokenEndpoint { param($Uri, $Form) $script:TokenCalls.Add([pscustomobject]@{ Uri = $Uri; Form = $Form.Clone() }); return $script:TokenReplies.Dequeue() }
function New-TokenReply([string]$Access, [string]$Refresh, $Claims) {
    $b = [pscustomobject]@{ access_token = $Access; expires_in = 3600; refresh_token = $Refresh }
    if ($Claims) { $b | Add-Member id_token (New-TestJwt $Claims) }
    return [pscustomobject]@{ Ok = $true; Body = $b; Error = ''; Description = '' }
}
function New-TokenError([string]$Code, [string]$Desc) { return [pscustomobject]@{ Ok = $false; Body = $null; Error = $Code; Description = $Desc } }

# The browser: given the sign-in address, it calls the redirect address back the
# way Entra would - a real HTTP request to the real listener.
$script:Sent = $null; $script:Browser = $null; $script:BrowserAnswer = ''
$script:FakeBrowser = {
    param($u)
    $script:Sent    = ConvertFrom-GLQueryString $u.Split('?')[1]
    $a              = $script:BrowserAnswer.Replace('{state}', [uri]::EscapeDataString($script:Sent.state))
    $script:Browser = [System.Net.Http.HttpClient]::new().GetAsync("$($script:Sent.redirect_uri)/?$a")
    return $true
}
function Set-FakeBrowser([string]$Answer) { $script:BrowserAnswer = $Answer }
# A real browser must never open during the tests: the app's own opener is replaced.
function Open-GLBrowser { param($Url) return (& $script:FakeBrowser $Url) }
function Get-LastCall { return $script:TokenCalls[$script:TokenCalls.Count - 1] }
function Get-BrowserPage { if (-not $script:Browser.Wait(5000)) { return $null }; $r = $script:Browser.Result; return [pscustomobject]@{ Status = [int]$r.StatusCode; Text = $r.Content.ReadAsStringAsync().Result } }

$script:TokenReplies.Enqueue((New-TokenReply 'fab-1' 'rt-1' @{ preferred_username = 'jane@contoso.com'; tid = 'contoso-tenant' }))
Set-FakeBrowser 'code=the-code&state={state}'
$err = ''; try { Connect-GL -ClientId $cid -Account 'admin.jane@contoso.com' } catch { $err = $_.Exception.Message }
$page = Get-BrowserPage
Assert (-not $err) "browser sign-in completes against the real listener $(if ($err) { "- $err" })"
Assert ($script:SignedInAs -eq 'jane@contoso.com' -and $script:TenantShown -eq 'contoso-tenant' -and $script:AuthMode -eq 'Browser') 'the window shows who signed in, and to which tenant'
Assert ($script:Sent.client_id -eq $cid -and $script:Sent.login_hint -eq 'admin.jane@contoso.com' -and $script:Sent.redirect_uri -match '^http://localhost:\d+$' -and $script:Sent.scope -match 'offline_access') 'the browser is sent with the client id, the chosen account and a localhost return address'
$tc = $script:TokenCalls[0]
Assert ($tc.Uri -eq 'https://login.microsoftonline.com/organizations/oauth2/v2.0/token' -and $tc.Form.grant_type -eq 'authorization_code' -and $tc.Form.code -eq 'the-code' -and $tc.Form.client_id -eq $cid) 'the code from the browser is traded for tokens'
Assert ((ConvertTo-GLCodeChallenge $tc.Form.code_verifier) -eq $script:Sent.code_challenge -and $tc.Form.redirect_uri -eq $script:Sent.redirect_uri) 'the verifier matches the challenge sent, and the return address is the same - Entra checks both'
Assert ($page -and $page.Status -eq 200 -and $page.Text -match 'signed in') 'the browser tab says sign-in worked'
$closed = $false; try { $tcp = [System.Net.Sockets.TcpClient]::new(); $tcp.Connect('127.0.0.1', ([uri]$script:Sent.redirect_uri).Port); $tcp.Dispose() } catch { $closed = $true }
Assert $closed 'the listener is closed as soon as sign-in is done'

$n = $script:TokenCalls.Count
Assert ((Get-GLToken Fabric) -eq 'fab-1' -and $script:TokenCalls.Count -eq $n) 'a fresh token is reused, not fetched again'
$script:TokenReplies.Enqueue((New-TokenReply 'pbi-1' 'rt-2'))
$pbiTok = Get-GLToken PowerBI
$tc = (Get-LastCall)
Assert ($pbiTok -eq 'pbi-1' -and $tc.Form.grant_type -eq 'refresh_token' -and $tc.Form.refresh_token -eq 'rt-1' -and $tc.Form.scope -match '^https://analysis\.windows\.net/powerbi/api/\.default') 'a Power BI token comes from the same sign-in, without asking again'
Assert ($tc.Uri -match '/contoso-tenant/oauth2/v2\.0/token$') 'later tokens come from the tenant actually signed in to'
Assert ($script:Auth.RefreshToken -eq 'rt-2') 'a new refresh token from Entra replaces the old one'
$script:Auth.Tokens.Fabric.ExpiresOn = (Get-Date).AddMinutes(5)
$script:TokenReplies.Enqueue((New-TokenReply 'fab-2' ''))
Assert ((Get-GLToken Fabric) -eq 'fab-2' -and (Get-LastCall).Form.refresh_token -eq 'rt-2' -and $script:Auth.RefreshToken -eq 'rt-2') 'a token close to expiring is renewed before a job gets it'
$script:TokenReplies.Enqueue((New-TokenError 'invalid_grant' 'AADSTS65001: The user or administrator has not consented to use the application.'))
$n = $script:TokenCalls.Count
$g1 = Get-GLToken Graph; $g2 = Get-GLToken Graph
Assert ($null -eq $g1 -and $null -eq $g2 -and $script:TokenCalls.Count -eq $n + 1) 'Graph not approved: no token, asked once - name lookups fall back to object ids'
$script:Auth.Tokens.Fabric.ExpiresOn = (Get-Date).AddMinutes(-1)
$script:TokenReplies.Enqueue((New-TokenError 'invalid_grant' 'AADSTS700082: The refresh token has expired due to inactivity.'))
$err = ''; try { $null = Get-GLToken Fabric } catch { $err = $_.Exception.Message }
Assert ($err -match 'AADSTS700082' -and $err -match 'Restart GatewayLens') 'an expired sign-in fails with the reason and what to do'

Set-FakeBrowser 'error=access_denied&error_description=AADSTS65001%3A+The+user+or+administrator+has+not+consented&state={state}'
$err = ''; try { Connect-GL -ClientId $cid } catch { $err = $_.Exception.Message }
$page = Get-BrowserPage
Assert ($err -match 'access_denied: AADSTS65001' -and $err -match 'administrator approves it once' -and $page.Status -eq 200) 'a refusal in the browser comes back as the reason and what to do'

Set-FakeBrowser 'code=stolen&state=someone-else'
$err = ''; try { Connect-GLBrowser -ClientId $cid -Tenant 'organizations' -TimeoutSec 2 } catch { $err = $_.Exception.Message }
$page = Get-BrowserPage
Assert ($page.Status -eq 400 -and $err -match 'did not finish' -and $err -match '-DeviceCode') 'an answer meant for another sign-in is refused, and the wait ends with advice'

$script:TokenCalls.Clear()
$script:TokenReplies.Enqueue([pscustomobject]@{ Ok = $true; Error = ''; Description = ''; Body = [pscustomobject]@{ message = 'To sign in, open the page and enter code TEST'; device_code = 'dc-1'; interval = 0; expires_in = 60 } })
$script:TokenReplies.Enqueue((New-TokenError 'authorization_pending' 'AADSTS70016: pending'))
$script:TokenReplies.Enqueue((New-TokenReply 'fab-dc' 'rt-dc' @{ upn = 'joe@contoso.com'; tid = 'contoso-tenant' }))
$err = ''; try { Connect-GL -ClientId $cid -DeviceCode -TenantId 'contoso.onmicrosoft.com' } catch { $err = $_.Exception.Message }
Assert (-not $err -and $script:AuthMode -eq 'Device code' -and $script:SignedInAs -eq 'joe@contoso.com' -and (Get-GLToken Fabric) -eq 'fab-dc') "device code sign-in waits while Entra says pending, then signs in $(if ($err) { "- $err" })"
Assert ($script:TokenCalls[0].Uri -match '/contoso\.onmicrosoft\.com/oauth2/v2\.0/devicecode$' -and $script:TokenCalls[2].Form.grant_type -eq 'urn:ietf:params:oauth:grant-type:device_code' -and $script:TokenCalls[2].Form.device_code -eq 'dc-1') 'device code: the code is asked for in the chosen tenant and polled for'
$script:TokenReplies.Enqueue([pscustomobject]@{ Ok = $true; Error = ''; Description = ''; Body = [pscustomobject]@{ message = 'code'; device_code = 'dc-2'; interval = 0; expires_in = 60 } })
$script:TokenReplies.Enqueue((New-TokenError 'authorization_declined' 'AADSTS70000: The user declined.'))
$err = ''; try { Connect-GL -ClientId $cid -DeviceCode } catch { $err = $_.Exception.Message }
Assert ($err -match 'authorization_declined') 'device code: a refusal stops the wait with the reason'

# back to the real functions and a signed-out state
. $script -LoadOnly
Assert ($script:BuiltInClientId -eq $keepBuiltIn -and -not $script:Auth -and -not $script:AuthMode) 'the sign-in tests leave nothing behind'

# ============================================================================
Section 'Credential encryption - decrypted with the private key to prove the format'
# ============================================================================
function Protect-Test([int]$Bits, [string]$Text) {
    $rsa = [System.Security.Cryptography.RSA]::Create($Bits)
    $pub = $rsa.ExportParameters($false)
    $enc = ConvertTo-GLEncryptedCredential -CredentialJson $Text `
        -Modulus ([Convert]::ToBase64String($pub.Modulus)) -Exponent ([Convert]::ToBase64String($pub.Exponent))
    return @{ Rsa = $rsa; Enc = $enc }
}

# 2048-bit: Base64(RSA-OAEP-SHA256(keys)) + Base64([alg][tag][iv][ciphertext])
$secret = (ConvertTo-GLCredentialJson -CredentialType Basic -Username 'svc_reader' -Password 'p@ss;w"rd/{}<>&')
$x      = Protect-Test 2048 $secret
$keyB64Len = 344                                  # 256 RSA bytes as Base64
$encKeys   = [Convert]::FromBase64String($x.Enc.Substring(0, $keyB64Len))
$cipher    = [Convert]::FromBase64String($x.Enc.Substring($keyB64Len))
$keys      = $x.Rsa.Decrypt($encKeys, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
Assert ($keys.Length -eq 98 -and $keys[0] -eq 0 -and $keys[1] -eq 1) '2048: wrapped keys carry the KeyLength32 / KeyLength64 header'
$keyEnc = $keys[2..33]; $keyMac = $keys[34..97]
Assert ($cipher[0] -eq 0 -and $cipher[1] -eq 0) '2048: ciphertext starts with the AES-256-CBC / HMAC-SHA256 algorithm bytes'
$tag = $cipher[2..33]; $iv = $cipher[34..49]; $ct = $cipher[50..($cipher.Length - 1)]
$hmac = [System.Security.Cryptography.HMACSHA256]::new([byte[]]$keyMac)
$expect = $hmac.ComputeHash([byte[]](@(0, 0) + $iv + $ct))
Assert ((Compare-Object $expect $tag -SyncWindow 0).Count -eq 0) '2048: the authentication tag verifies'
$aes = [System.Security.Cryptography.Aes]::Create()
$aes.Key = [byte[]]$keyEnc; $aes.IV = [byte[]]$iv
$plainBytes = $aes.CreateDecryptor().TransformFinalBlock([byte[]]$ct, 0, $ct.Length)
$back = [System.Text.Encoding]::UTF8.GetString($plainBytes)
Assert ($back -eq $secret) '2048: decrypts back to exactly the original, special characters included'

$y = Protect-Test 2048 $secret
Assert ($y.Enc -ne $x.Enc) '2048: the same input encrypts differently each time (fresh keys and IV)'

# 1024-bit: 85-byte segments, each RSA-OAEP-SHA1 to 128 bytes, concatenated
$long = ConvertTo-GLCredentialJson -CredentialType Windows -Username 'DOMAIN\a.very.long.service.account.name' -Password ('x' * 120)
$z    = Protect-Test 1024 $long
$all  = [Convert]::FromBase64String($z.Enc)
$segs = [math]::Ceiling([System.Text.Encoding]::UTF8.GetByteCount($long) / 85)
Assert ($all.Length -eq $segs * 128) "1024: $segs segment(s) of 128 bytes"
$ms = New-Object System.IO.MemoryStream
for ($i = 0; $i -lt $all.Length; $i += 128) {
    $d = $z.Rsa.Decrypt([byte[]]$all[$i..($i + 127)], [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA1)
    $ms.Write($d, 0, $d.Length)
}
Assert ([System.Text.Encoding]::UTF8.GetString($ms.ToArray()) -eq $long) '1024: segments decrypt and join back to the original'

# the plaintext the SDK produces
$j = ConvertTo-GLCredentialJson -CredentialType Windows -Username 'u' -Password 'p' | ConvertFrom-Json
Assert ($j.credentialData.Count -eq 2 -and $j.credentialData[0].name -eq 'username' -and $j.credentialData[1].value -eq 'p') 'credential JSON: username then password as name/value pairs'
$j = ConvertTo-GLCredentialJson -CredentialType Anonymous
Assert ($j -eq '{"credentialData":[]}') "anonymous credential JSON is an empty list: $j"
$j = ConvertTo-GLCredentialJson -CredentialType Key -Password 'k' | ConvertFrom-Json
Assert ($j.credentialData.Count -eq 1 -and $j.credentialData[0].name -eq 'key') 'key credential JSON has a single "key" pair'

$pk = [pscustomobject]@{ modulus = [Convert]::ToBase64String($x.Rsa.ExportParameters($false).Modulus); exponent = 'AQAB' }
$cd = New-GLCredentialDetails -CredentialType Basic -Username 'u' -Password 'p' -PublicKey $pk -Privacy 'Private' -Encryption NotEncrypted
Assert ($cd.encryptionAlgorithm -eq 'RSA-OAEP' -and $cd.privacyLevel -eq 'Private' -and $cd.encryptedConnection -eq 'NotEncrypted' -and $cd.credentials.Length -gt 344) 'credentialDetails has the documented fields'
$err = $null; try { New-GLCredentialDetails -CredentialType Basic -Username 'u' -Password '' -PublicKey $pk } catch { $err = $_.Exception.Message }
Assert ($err -match 'username and a password') 'a missing password is refused before anything is sent'
$err = $null; try { New-GLCredentialDetails -CredentialType Basic -Username 'u' -Password 'p' -PublicKey $null } catch { $err = $_.Exception.Message }
Assert ($err -match 'public key') 'a gateway without a public key is refused clearly'

Assert ((ConvertTo-GLEncryptionSetting -Current 'Encrypted') -eq 'Encrypted') 'encryption: keep Encrypted'
Assert ((ConvertTo-GLEncryptionSetting -Current 'Any') -eq 'NotEncrypted') 'encryption: "Any" never becomes a hard requirement'
Assert ((ConvertTo-GLEncryptionSetting -Current 'Any' -Choice 'Encrypted') -eq 'Encrypted') 'encryption: an explicit choice wins'

# ============================================================================
Section 'Paging - and the array that must not collapse'
# ============================================================================
$script:Pages = @{}
function Invoke-GLRequest { param($Method, $Uri, $Token, $Body, $MaxRetry) return $script:Pages[$Uri] }

$script:Pages = @{
    'https://x/items'        = [pscustomobject]@{ value = @(@{ id = 1 }, @{ id = 2 }); continuationUri = 'https://x/items?page=2' }
    'https://x/items?page=2' = [pscustomobject]@{ value = @(@{ id = 3 }) }
}
$r = Get-GLPaged -Uri 'https://x/items' -Token 't'
Assert ($r.Count -eq 3) "follows continuationUri across pages ($($r.Count) items)"

$script:Pages = @{
    'https://x/t'                     = [pscustomobject]@{ value = @(@{ id = 1 }); continuationToken = 'a b' }
    'https://x/t?continuationToken=a%20b' = [pscustomobject]@{ value = @(@{ id = 2 }) }
}
$r = Get-GLPaged -Uri 'https://x/t' -Token 't'
Assert ($r.Count -eq 2) 'follows continuationToken alone, URL-encoded'

$script:Pages = @{ 'https://x/empty' = [pscustomobject]@{ value = @() } }
$r = Get-GLPaged -Uri 'https://x/empty' -Token 't'
Assert ($null -ne $r -and $r -is [array] -and $r.Count -eq 0) 'an empty result is an empty ARRAY, not $null'

$script:Pages = @{ 'https://x/one' = [pscustomobject]@{ value = @(@{ id = 'only' }) } }
$r = Get-GLPaged -Uri 'https://x/one' -Token 't'
Assert ($r -is [array] -and $r.Count -eq 1 -and $r[0].id -eq 'only') 'a single result stays an array of one'

$wrapped = @(Get-GLPaged -Uri 'https://x/one' -Token 't')   # deliberate-trap: shows what goes wrong
Assert ($wrapped.Count -eq 1 -and $wrapped[0] -is [array]) 'documented trap: wrapping the CALL in @() nests the array - callers assign instead'

Remove-Item function:Invoke-GLRequest
. $script -LoadOnly

# ============================================================================
Section 'Errors carry the API''s own message'
# ============================================================================
function Invoke-RestMethod { throw [System.Exception]::new('connection reset by peer') }
$msg = $null
try { Invoke-GLRequest -Uri 'https://api.example/test' -Token 't' -MaxRetry 0 } catch { $msg = $_.Exception.Message }
Assert ($msg -match 'GET https://api.example/test' -and $msg -match 'connection reset by peer') "failure names the call and the cause: $msg"
Remove-Item function:Invoke-RestMethod

# ============================================================================
Section 'Settings and history'
# ============================================================================
$sp = Join-Path ([System.IO.Path]::GetTempPath()) ("gl-set-" + [guid]::NewGuid().ToString('N') + '\settings.json')
$st = Read-GLSettings -Path $sp
Assert ($st.Theme -eq 'Light' -and $st.FontSize -eq 12 -and $st.History.Count -eq 0) 'no settings file gives the defaults'

Assert (Add-GLHistory -Settings $st -Field 'TxtCnSearch' -Value ' sql01 ') 'a search is recorded'
$null = Add-GLHistory -Settings $st -Field 'TxtCnSearch' -Value 'ora01'
$null = Add-GLHistory -Settings $st -Field 'TxtCnSearch' -Value 'SQL01'
$h = Get-GLHistory -Settings $st -Field 'TxtCnSearch'
Assert (($h -join ',') -eq 'SQL01,ora01') "most recent first, a repeat moves to the top instead of duplicating ($($h -join ','))"
Assert (-not (Add-GLHistory -Settings $st -Field 'TxtCnSearch' -Value '   ')) 'empty text is not recorded'
1..30 | ForEach-Object { $null = Add-GLHistory -Settings $st -Field 'TxtGwFilter' -Value "v$_" }
Assert ((Get-GLHistory -Settings $st -Field 'TxtGwFilter').Count -eq 20) 'history is capped at 20 per field'
Assert (-not (Add-GLHistory -Settings $st -Field 'PwdCred' -Value 'hunter2')) 'a password field is refused, whatever is passed in'
Assert (-not $st.History.Contains('PwdCred')) 'and nothing of it is kept'
$e = Get-GLHistory -Settings $st -Field 'NeverUsed'
Assert ($e -is [array] -and $e.Count -eq 0) 'an unused field has an empty history'

$st.Theme = 'Dark'; $st.FontSize = 14
Assert (Save-GLSettings -Settings $st -Path $sp) 'settings are saved, creating the folder'
$rt = Read-GLSettings -Path $sp
Assert ($rt.Theme -eq 'Dark' -and $rt.FontSize -eq 14 -and ((Get-GLHistory -Settings $rt -Field 'TxtCnSearch') -join ',') -eq 'SQL01,ora01') 'and read back intact'
# the panel sizes and the last account are kept; nonsense in the file is left out
$lay = New-GLDefaultSettings
$lay.Layout = [ordered]@{ LogHeight = 220; ActionsWidth = 610 }
$lay.LastAccount = 'jane@contoso.com'; $lay.SeenVersion = '0.7.0'
$null = Save-GLSettings -Settings $lay -Path $sp
$lr = Read-GLSettings -Path $sp
Assert ($lr.Layout.LogHeight -eq 220 -and $lr.Layout.ActionsWidth -eq 610 -and $lr.LastAccount -eq 'jane@contoso.com' -and $lr.SeenVersion -eq '0.7.0') 'panel sizes, the last account and the last version seen are read back'
Set-Content -LiteralPath $sp -Value '{"Layout":{"LogHeight":"wide","ActionsWidth":99999,"Bad Name":5},"LastAccount":"not an email"}'
$lb = Read-GLSettings -Path $sp
Assert ($lb.Layout.Count -eq 0 -and $lb.LastAccount -eq '') 'sizes that make no sense, and an account that is no email, are left out'
Assert (-not ((Get-Content $sp -Raw) -match 'hunter2')) 'the saved file contains no password'

Set-Content -Path $sp -Value '{ this is not json'
$bad = Read-GLSettings -Path $sp
Assert ($bad.Theme -eq 'Light') 'a damaged settings file falls back to the defaults, no error'
Set-Content -Path $sp -Value '{"FontSize": 99, "History": {"PwdX": ["leak"]}}'
$cl = Read-GLSettings -Path $sp
Assert ($cl.FontSize -eq 20 -and -not $cl.History.Contains('PwdX')) 'out-of-range font size is clamped, password-like history is dropped on read'

# ---- text size: A- and A+, Ctrl + mouse wheel, Ctrl + plus / minus / 0 ----
$rh = @(9, 12, 16, 20 | ForEach-Object { Get-GLRowHeight -FontSize $_ })
Assert ($rh[1].Row -eq 22 -and $rh[1].Header -eq 28) 'rows are compact at the default text size: 22 high, the header 28'
Assert ($rh[0].Row -eq 18 -and $rh[3].Row -eq 33 -and $rh[0].Row -lt $rh[1].Row -and $rh[1].Row -lt $rh[2].Row -and $rh[2].Row -lt $rh[3].Row) 'smaller text, lower rows; larger text, higher rows - from 18 at 9 to 33 at 20'
Assert (-not (@(9..20) | Where-Object { (Get-GLRowHeight -FontSize $_).Row -lt [math]::Ceiling($_ * 4 / 3) + 4 })) 'at every text size a row is higher than a line of its text - nothing is cut off'
Assert ((Get-GLFontStep -Delta 120 -Ctrl $true) -eq 1 -and (Get-GLFontStep -Delta -120 -Ctrl $true) -eq -1) 'Ctrl + mouse wheel: up is larger, down is smaller'
Assert ($null -eq (Get-GLFontStep -Delta 120 -Ctrl $false)) 'the wheel without Ctrl just scrolls'
Assert ((Get-GLFontStep -Key 'OemPlus' -Ctrl $true) -eq 1 -and (Get-GLFontStep -Key 'Subtract' -Ctrl $true) -eq -1 -and (Get-GLFontStep -Key 'D0' -Ctrl $true) -eq 0) 'Ctrl + plus, Ctrl + minus (main keys or number pad), and Ctrl + 0 for the default'
Assert ($null -eq (Get-GLFontStep -Key 'OemPlus' -Ctrl $false) -and $null -eq (Get-GLFontStep -Key 'C' -Ctrl $true)) 'other keys, or no Ctrl: the text size is left alone'
$keepFont = @{ W = $script:Window; U = $script:UI; S = $script:Settings; P = $script:SettingsPath }
$script:Window = [pscustomobject]@{ FontSize = 12 }
$script:UI = @{ TxtFontSize = [pscustomobject]@{ Text = '' }; GridConnections = [pscustomobject]@{ RowHeight = 0; ColumnHeaderHeight = 0 } }
$script:Settings = New-GLDefaultSettings
$script:SettingsPath = Join-Path ([System.IO.Path]::GetTempPath()) ('gl-font-' + [guid]::NewGuid().ToString('N') + '.json')
Step-GLFontSize -By 1
$savedSize = (Get-Content -Raw $script:SettingsPath | ConvertFrom-Json).FontSize
Assert ($script:Window.FontSize -eq 13 -and $script:UI.TxtFontSize.Text -eq '13' -and $savedSize -eq 13) 'a step changes the text size, shows it next to A- and A+, and keeps it in the settings'
Assert ($script:UI.GridConnections.RowHeight -eq 24 -and $script:UI.GridConnections.ColumnHeaderHeight -eq 30) "the grid rows follow the text size ($($script:UI.GridConnections.RowHeight) at 13)"
foreach ($n in 1..20) { Step-GLFontSize -By 1 }
Assert ($script:Settings.FontSize -eq 20 -and $script:Window.FontSize -eq 20) 'however far the wheel turns, it stops at 20'
Step-GLFontSize -Reset
Assert ($script:Settings.FontSize -eq 12 -and (Get-Content -Raw $script:SettingsPath | ConvertFrom-Json).FontSize -eq 12) 'Ctrl + 0 goes back to the default, 12, and keeps it'
Remove-Item -LiteralPath $script:SettingsPath -ErrorAction SilentlyContinue
$script:Window = $keepFont.W; $script:UI = $keepFont.U; $script:Settings = $keepFont.S; $script:SettingsPath = $keepFont.P
Remove-Item -Recurse -Force (Split-Path -Parent $sp)

# ============================================================================
Section 'Themes'
# ============================================================================
$keys0 = @($script:Themes[0].Keys)
foreach ($name in $script:Themes.Keys) {
    $t = $script:Themes[$name]
    $miss = @($keys0 | Where-Object { -not $t.Contains($_) })
    $extra = @($t.Keys | Where-Object { $keys0 -notcontains $_ })
    $badc = @($t.Keys | Where-Object { try { $null = ConvertTo-GLColorValue $t[$_]; $false } catch { $true } })
    Assert (-not $miss -and -not $extra -and -not $badc) "theme '$name' defines every brush, all valid colours $(if ($miss + $extra + $badc) { '- ' + (($miss + $extra + $badc) -join ', ') })"
}
$argb = ConvertTo-GLColorValue '#1A0F172A'
Assert ($argb[0] -eq 26 -and $argb[3] -eq 42) 'colours with transparency are read as ARGB'

# ============================================================================
Section 'Shaping gateways'
# ============================================================================
$gws = @(
    [pscustomobject]@{ id = 'G1'; displayName = 'Cluster A'; type = 'OnPremises'; numberOfMemberGateways = 2
                       loadBalancingSetting = 'Failover'; allowCloudConnectionRefresh = $true; allowCustomConnectors = $false }
    [pscustomobject]@{ id = 'G2'; displayName = 'VNet B'; type = 'VirtualNetwork'; numberOfMemberGateways = 1 }
)
$mem = @{ 'G1' = @(
    [pscustomobject]@{ id = 'M1'; displayName = 'node-1'; version = '3000.250.5'; enabled = $true }
    [pscustomobject]@{ id = 'M2'; displayName = 'node-2'; version = '3000.246.4'; enabled = $true }
) }
$live = @{
    'm1' = [pscustomobject]@{ Status = 'Live';    Machine = 'HOST1' }
    'm2' = [pscustomobject]@{ Status = 'Offline'; Machine = 'HOST2' }
}
$rows = ConvertTo-GLGatewayRows -Gateways $gws -Members $mem -Live $live
Assert ($rows.Count -eq 2) 'one row per gateway'
Assert ($rows[0].Online -eq '1 / 2') "online count comes from live status ($($rows[0].Online))"
Assert ($rows[0].Versions -eq '3000.246.4, 3000.250.5') "mixed member versions are listed, sorted ($($rows[0].Versions))"
Assert ($rows[1].Online -eq 'n/a' -and $rows[1].Members -eq 1) 'a VNet gateway has no live count but keeps its member count'

$noLive = ConvertTo-GLGatewayRows -Gateways $gws -Members $mem -Live $null
Assert ($noLive[0].Online -eq 'n/a') 'without live status the column says n/a, not 0'

$mrows = ConvertTo-GLMemberRows -GatewayName 'Cluster A' -Members $mem['G1'] -Live $live
Assert ($mrows.Count -eq 2 -and $mrows[0].Machine -eq 'HOST1' -and $mrows[1].Status -eq 'Offline') 'member rows carry machine and status'

$noProps = $rows[0].PSObject.Properties.Name | Where-Object { $_ -like '*_*' }
Assert (-not $noProps) 'no underscores in column names (WPF would hide them)'

$withPersonal = @($gws) + @([pscustomobject]@{ id = 'GP'; displayName = 'Jane (personal mode)'; type = 'OnPremisesPersonal' })
$pr = ConvertTo-GLGatewayRows -Gateways $withPersonal -Members $mem -Live $live
Assert ($pr.Count -eq 2 -and -not ($pr | Where-Object Type -eq 'OnPremisesPersonal')) 'personal gateways are left out - on-premises and VNet only'

# ---- the monitoring tiles ----
Assert ((Format-GLDuration ([timespan]::FromSeconds(20))) -eq 'under a minute' -and (Format-GLDuration ([timespan]::FromMinutes(27.6))) -eq '27 min') 'durations: under a minute, minutes'
Assert ((Format-GLDuration ([timespan]::FromMinutes(185))) -eq '3 h 05 min' -and (Format-GLDuration ([timespan]::FromHours(52))) -eq '2 d 4 h') 'durations: hours, days'

$t0 = [datetime]'2026-10-12 08:00'
$d1 = Update-GLDownSince -DownSince @{} -Live $live -Now $t0
Assert ($d1.Count -eq 1 -and $d1['m2'] -eq $t0) 'a member seen offline is remembered with the time it was first seen'
$d2 = Update-GLDownSince -DownSince $d1 -Live $live -Now $t0.AddMinutes(30)
Assert ($d2['m2'] -eq $t0) 'still offline at the next refresh: the first time is kept'
$liveAgain = @{ 'm1' = [pscustomobject]@{ Status = 'Live' }; 'm2' = [pscustomobject]@{ Status = 'Live' } }
Assert ((Update-GLDownSince -DownSince $d2 -Live $liveAgain -Now $t0.AddMinutes(40)).Count -eq 0) 'back online: forgotten'
Assert ((Update-GLDownSince -DownSince $d2 -Live $null -Now $t0).Count -eq 0) 'live status off: nothing is claimed to be down'

$tg = @(
    [pscustomobject]@{ id = 'G1'; displayName = 'Cluster A'; type = 'OnPremises' }
    [pscustomobject]@{ id = 'G3'; displayName = 'Cluster C'; type = 'OnPremises' }
    [pscustomobject]@{ id = 'G4'; displayName = 'Alpha';     type = 'OnPremises' }
    [pscustomobject]@{ id = 'G2'; displayName = 'VNet B';    type = 'VirtualNetwork' }
    [pscustomobject]@{ id = 'G5'; displayName = 'Beta';      type = 'OnPremises' }
)
$tm = @{
    'G1' = $mem['G1']                                                                                     # 3000.250.5 + 3000.246.4, one down
    'G3' = @([pscustomobject]@{ id = 'M3'; displayName = 'c-1'; version = '3000.250.5'; enabled = $true })  # down
    'G4' = @([pscustomobject]@{ id = 'M4'; displayName = 'a-1'; version = '3000.250.5'; enabled = $true })  # fine
    'G5' = @([pscustomobject]@{ id = 'M5'; displayName = 'b-1'; version = '3000.240.1'; enabled = $true })  # fine, but behind
}
$tl = @{
    'm1' = [pscustomobject]@{ Status = 'Live' }; 'm2' = [pscustomobject]@{ Status = 'Offline' }
    'm3' = [pscustomobject]@{ Status = 'Offline' }; 'm4' = [pscustomobject]@{ Status = 'Live' }; 'm5' = [pscustomobject]@{ Status = 'Live' }
}
$trows = ConvertTo-GLGatewayRows -Gateways $tg -Members $tm -Live $tl
$down  = @{ 'm2' = $t0.AddMinutes(-5); 'm3' = $t0.AddMinutes(-27) }
$tiles = ConvertTo-GLGatewayTiles -Rows $trows -Members $tm -DownSince $down -Now $t0
$byName = @{}; foreach ($x in $tiles) { $byName[$x.Name] = $x }
Assert (($tiles | ForEach-Object Name) -join ',' -eq 'Cluster C,Cluster A,Alpha,Beta,VNet B') "problems first: offline, degraded, then the rest by name, VNet last ($(($tiles | ForEach-Object Name) -join ', '))"
Assert ($byName['Cluster C'].Status -eq 'Offline' -and $byName['Cluster C'].StatusText -eq 'OFFLINE' -and $byName['Cluster C'].DownText -eq 'Down for 27 min') 'an offline gateway says for how long'
Assert ($byName['Cluster A'].Status -eq 'Degraded' -and $byName['Cluster A'].MembersText -eq '1 of 2 members online' -and $byName['Cluster A'].DownText -eq '1 down, the first for 5 min') 'a degraded gateway: how many members are up, and how long one has been down'
Assert ($byName['Cluster A'].Badge -eq 'MIXED VERSIONS' -and $byName['Cluster A'].HasBadge -and $byName['Cluster A'].VersionText -eq '3000.246.4 / 3000.250.5') 'members on different versions: MIXED VERSIONS'
Assert ($byName['Beta'].Badge -eq 'OLDER VERSION' -and $byName['Alpha'].Badge -eq '' -and -not $byName['Alpha'].HasBadge) 'a gateway behind the newest version seen: OLDER VERSION; an up-to-date one: no badge'
Assert ($byName['Alpha'].Status -eq 'Online' -and $byName['Alpha'].DownText -eq '') 'an online gateway has nothing to say about downtime'
Assert ($byName['VNet B'].Status -eq 'VNet' -and -not $byName['VNet B'].HasBadge) 'a VNet gateway gets its own tile, with no member checks'
$quiet = ConvertTo-GLGatewayTiles -Rows (ConvertTo-GLGatewayRows -Gateways $tg -Members $tm -Live $null) -Members $tm -DownSince @{} -Now $t0
Assert (-not ($quiet | Where-Object { $_.Status -in 'Offline', 'Degraded', 'Online' }) -and ($quiet | Where-Object Status -eq 'Unknown').Count -eq 4) 'live status off: tiles say NO STATUS - never a made-up green'
# ---- Microsoft's pages: the newest build, and the releases still supported ----
# the shapes the real pages had in October 2026
$dlc = '<script>{"files":[{"name":"GatewayInstall.exe","size":"717118056","version":"3000.334.9","datePublished":"10/5/2026 5:25:34 PM"}],' +
       '"detailsSection_file_version":"3000.334.9","detailsSection_file_name":["GatewayInstall.exe"]}</script>'
$dp = ConvertFrom-GLDownloadPage $dlc
Assert ($dp.Version -eq [version]'3000.334.9' -and $dp.Published -eq [datetime]'2026-10-05 17:25:34') "Download Center: the newest build and its date, from the page's JSON ($($dp.Version), $($dp.Published))"
$dp2 = ConvertFrom-GLDownloadPage '<div><h3 class="h6">Version:</h3><p style="overflow-wrap:break-word">3000.334.9</p></div>'
Assert ($dp2.Version -eq [version]'3000.334.9' -and $null -eq $dp2.Published) 'Download Center: the Version label still works if the JSON goes'
Assert ($null -eq (ConvertFrom-GLDownloadPage '<html>We are currently experiencing high demand.</html>') -and $null -eq (ConvertFrom-GLDownloadPage '')) 'Download Center: a busy page or nothing gives no version - never a guess'
$learn = '<nav>September 2026 update (3000.334)</nav>' + (@(
    'September 2026|334', 'August 2026|330', 'July 2026|326', 'June 2026|322', 'May 2026|318', 'April 2026|314' | ForEach-Object {
        $p = $_ -split '\|'; "<h2 id=""x"">$($p[0]) update (3000.$($p[1]))</h2><ul><li>Download</li></ul>" }) -join '')
$rp = ConvertFrom-GLReleasePage $learn
Assert ($rp.Count -eq 6 -and $rp[0].Version -eq [version]'3000.334' -and $rp[0].Name -eq 'September 2026' -and $rp[5].Version -eq [version]'3000.314') "Learn: six supported releases, newest first, each once ($($rp.Count))"
$noRel = ConvertFrom-GLReleasePage 'nothing here'
Assert ($noRel -is [array] -and $noRel.Count -eq 0) 'Learn: a page without releases is an empty list'

$rel = [pscustomobject]@{ Newest = [version]'3000.334.9'; Supported = $rp }
Assert ((Get-GLReleaseInfo '3000.334.9' $rel).State -eq 'Current' -and (Get-GLReleaseInfo '3000.334.9' $rel).Release -eq 'September 2026') 'the newest build is Current, in its month'
Assert ((Get-GLReleaseInfo '3000.334.7' $rel).State -eq 'Behind' -and (Get-GLReleaseInfo '3000.318.5' $rel).State -eq 'Behind') 'an older build, or an older supported month, can be updated'
Assert ((Get-GLReleaseInfo '3000.310.2' $rel).State -eq 'Unsupported' -and (Get-GLReleaseInfo '3000.310.2' $rel).Release -eq '') 'older than the oldest supported release: Unsupported'
$learnOnly = [pscustomobject]@{ Newest = [version]'3000.334'; Supported = $rp }
Assert ((Get-GLReleaseInfo '3000.334.1' $learnOnly).State -eq 'Current') 'with only the Learn page, any build of the newest month is Current'
Assert ($null -eq (Get-GLReleaseInfo '3000.310.2' $null) -and $null -eq (Get-GLReleaseInfo 'n/a' $rel)) 'no pages read, or no version: no verdict'

$rm = @{
    'G1' = @([pscustomobject]@{ id = 'A1'; version = '3000.334.9' })
    'G2' = @([pscustomobject]@{ id = 'B1'; version = '3000.326.4' })
    'G3' = @([pscustomobject]@{ id = 'C1'; version = '3000.302.1' }, [pscustomobject]@{ id = 'C2'; version = '3000.334.9' })
}
$rg = @('G1', 'G2', 'G3' | ForEach-Object { [pscustomobject]@{ id = $_; displayName = "Gw $_"; type = 'OnPremises' } })
$rrows = ConvertTo-GLGatewayRows -Gateways $rg -Members $rm -Live $null
$rtiles = ConvertTo-GLGatewayTiles -Rows $rrows -Members $rm -DownSince @{} -Releases $rel
$rb = @{}; foreach ($x in $rtiles) { $rb[$x.Id] = $x }
Assert ($rb['G1'].Badge -eq '' -and $rb['G1'].VersionText -eq '3000.334.9 (September 2026)') "on the newest build: no badge, and the month is named ($($rb['G1'].VersionText))"
Assert ($rb['G2'].Badge -eq 'UPDATE AVAILABLE' -and $rb['G3'].Badge -eq 'UNSUPPORTED VERSION') 'behind: UPDATE AVAILABLE; a member out of support outranks mixed versions: UNSUPPORTED VERSION'
$rn = Get-GLGatewayCounts -Tiles $rtiles
Assert ($rn.Unsupported -eq 1 -and $rn.Behind -eq 1 -and $rn.Mixed -eq 0) 'the banner counts unsupported and behind gateways'
$rmr = ConvertTo-GLMemberRows -GatewayName 'Gw G3' -Members $rm['G3'] -Live $null -Releases $rel
Assert ($rmr[0].Support -eq 'Not supported' -and $rmr[1].Support -eq 'Newest' -and $rmr[1].Release -eq 'September 2026') 'members say their release and whether it is supported'

$n = Get-GLGatewayCounts -Tiles $tiles
Assert ($n.Total -eq 5 -and $n.Offline -eq 1 -and $n.Degraded -eq 1 -and $n.Drift -eq 2) 'the banner counts gateways, offline, degraded and version drift'
Assert (-not ($tiles[0].PSObject.Properties.Name | Where-Object { $_ -like '*_*' })) 'no underscores in tile fields'

# ============================================================================
Section 'Shaping connections'
# ============================================================================
$names = Get-GLGatewayNameMap -Gateways $gws
$conns = @(
    [pscustomobject]@{ id = 'C1'; displayName = 'Sales SQL'; connectivityType = 'OnPremisesGateway'; gatewayId = 'g1'
                       connectionDetails = [pscustomobject]@{ type = 'SQL'; path = 'sql01;sales' }
                       credentialDetails = [pscustomobject]@{ credentialType = 'Windows' }; privacyLevel = 'Organizational' }
    [pscustomobject]@{ id = 'C2'; displayName = 'Orphan'; connectivityType = 'OnPremisesGateway'; gatewayId = 'GONE'
                       connectionDetails = [pscustomobject]@{ type = 'Oracle'; path = 'ora' } }
    [pscustomobject]@{ id = 'C3'; displayName = 'Cloud API'; connectivityType = 'ShareableCloud'
                       connectionDetails = [pscustomobject]@{ type = 'Web'; path = 'https://api.example' } }
)
$crows = ConvertTo-GLConnectionRows -Connections $conns -GatewayNames $names
Assert ($crows[0].Gateway -eq 'Cluster A') 'gateway id resolves to its name, case-insensitively'
Assert ($crows[1].Gateway -eq 'GONE') 'an unknown gateway shows its id instead of vanishing'

# connection recency (preview): times as local time, empty when not recorded
$now  = [datetime]::SpecifyKind([datetime]'2026-10-12 12:00', 'Utc').ToLocalTime()
$used = [datetime]::SpecifyKind([datetime]'2026-09-02 12:00', 'Utc')
$rec  = @(
    [pscustomobject]@{ id = 'R1'; displayName = 'Text times'; connectivityType = 'OnPremisesGateway'
        connectionRecency = [pscustomobject]@{ createdDateTime = '2026-01-05T08:30:00Z'; lastBoundDateTime = '2026-01-06T08:30:00Z'; lastCredentialUsedDateTime = '2026-09-02T12:00:00Z' } }
    [pscustomobject]@{ id = 'R2'; displayName = 'Parsed times'; connectivityType = 'OnPremisesGateway'
        connectionRecency = [pscustomobject]@{ createdDateTime = [datetime]::SpecifyKind([datetime]'2026-01-05 08:30', 'Utc'); lastCredentialUsedDateTime = $used } }
    [pscustomobject]@{ id = 'R3'; displayName = 'Never used'; connectivityType = 'ShareableCloud'
        connectionRecency = [pscustomobject]@{ createdDateTime = '2026-01-05T08:30:00Z'; lastBoundDateTime = $null; lastCredentialUsedDateTime = $null } }
    [pscustomobject]@{ id = 'R4'; displayName = 'No recency at all'; connectivityType = 'ShareableCloud' }
)
$rr = ConvertTo-GLConnectionRows -Connections $rec -GatewayNames @{} -Now $now
$localCreated = [datetime]::SpecifyKind([datetime]'2026-01-05 08:30', 'Utc').ToLocalTime().ToString('yyyy-MM-dd HH:mm')
Assert ($rr[0].Created -eq $localCreated -and $rr[0].LastLinked -and $rr[0].LastUsed) "recency: created, last linked and last used are shown, in local time ($($rr[0].Created))"
Assert ($rr[0].UnusedDays -eq 40 -and $rr[1].UnusedDays -eq 40) "recency: days since the credentials were last used, from text or parsed times ($($rr[0].UnusedDays), $($rr[1].UnusedDays))"
Assert ($rr[1].Created -eq $localCreated) 'recency: a time PowerShell already parsed comes out the same as text'
Assert ($rr[2].LastUsed -eq '' -and $null -eq $rr[2].UnusedDays -and $rr[3].Created -eq '' -and $null -eq $rr[3].UnusedDays) 'recency: never used, or not recorded, stays empty - never a made-up date'
Assert ($crows[2].Gateway -eq '' -and $crows[2].Credential -eq '') 'a cloud connection has no gateway and survives missing fields'

$f = Select-GLConnections -Rows $crows -Text 'sales'
Assert ($f.Count -eq 1 -and $f[0].Id -eq 'C1') 'search is case-insensitive across name and path'
$f = Select-GLConnections -Rows $crows -Gateway 'Cluster A'
Assert ($f.Count -eq 1) 'filter by gateway'
$f = Select-GLConnections -Rows $crows -Connectivity 'ShareableCloud' -IncludeCloud
Assert ($f.Count -eq 1 -and $f[0].Id -eq 'C3') 'filter by connectivity'
$f = Select-GLConnections -Rows $crows -Gateway '(all)' -Connectivity '(all)' -Type '(all)' -Text '' -IncludeCloud
Assert ($f.Count -eq 3) '(all) everywhere returns everything'
$f = Select-GLConnections -Rows $crows
Assert ($f.Count -eq 2 -and -not ($f | Where-Object Connectivity -eq 'ShareableCloud')) 'gateway connections only, unless cloud ones are asked for'
$f = Select-GLConnections -Rows $crows -Text 'nothing-matches-this'
Assert ($f -is [array] -and $f.Count -eq 0) 'no match is an empty array'

$d = Get-GLDistinct -Rows $crows -Property Type
Assert ($d[0] -eq '(all)' -and ($d -join ',') -eq '(all),Oracle,SQL,Web') "dropdown values: (all) first, sorted, distinct ($($d -join ','))"

# ---- enabling or disabling several members ----
$cm = @([pscustomobject]@{ id = 'N1'; enabled = $true }, [pscustomobject]@{ id = 'N2'; enabled = $true }, [pscustomobject]@{ id = 'N3'; enabled = $false })
$cr = @([pscustomobject]@{ Id = 'N1'; Member = 'n1'; Enabled = $true }, [pscustomobject]@{ Id = 'N2'; Member = 'n2'; Enabled = $true }, [pscustomobject]@{ Id = 'N3'; Member = 'n3'; Enabled = $false })
$mp = Get-GLMemberPlan -Members $cm -Selected @($cr[0], $cr[2]) -Enabled $false
Assert (@($mp.Change).Count -eq 1 -and $mp.Change[0].Id -eq 'N1' -and $mp.Already -eq 1 -and $mp.EnabledAfter -eq 1) 'disable two selected, one already off: one changes, one member stays enabled'
$mp = Get-GLMemberPlan -Members $cm -Selected @($cr[0], $cr[1]) -Enabled $false
Assert ($mp.EnabledAfter -eq 0) 'disabling every enabled member is seen - the confirmation warns that refreshes stop'
$mp = Get-GLMemberPlan -Members $cm -Selected $cr -Enabled $true
Assert (@($mp.Change).Count -eq 1 -and $mp.Change[0].Id -eq 'N3' -and $mp.Already -eq 2 -and $mp.EnabledAfter -eq 3) 'enable all three: only the disabled one changes'

# ---- a test result, as the Status column and the log show it ----
$o1 = ConvertTo-GLTestOutcome -Result ([pscustomobject]@{ Status = 'OK'; Detail = '' }) -SkipTest $false -Name 'Sales'
$o2 = ConvertTo-GLTestOutcome -Result ([pscustomobject]@{ Status = 'OK'; Detail = '' }) -SkipTest $true -Name 'Sandbox'
$o3 = ConvertTo-GLTestOutcome -Result ([pscustomobject]@{ Status = 'Failed'; Detail = 'Login failed' }) -SkipTest $true -Name 'HR'
$o4 = ConvertTo-GLTestOutcome -Result ([pscustomobject]@{ Status = 'Timeout'; Detail = '' }) -SkipTest $false -Name 'Slow'
Assert ($o1.Status -eq 'OK' -and $o1.Level -eq 'Ok' -and $o1.Text -eq '    Sales: OK') 'a working connection: OK'
Assert ($o2.Status -eq 'Unverified' -and $o2.Level -eq 'Warn' -and $o2.Text -match 'not verified' -and $o2.Detail -match 'Skip test connection') 'Skip test connection on: an OK is Unverified - the gateway may not have tried'
Assert ($o3.Status -eq 'Failed' -and $o3.Level -eq 'Error' -and $o3.Text -match 'failed - Login failed') 'a failure stays a failure, with its reason, whatever the flag'
Assert ($o4.Status -eq 'Timeout' -and $o4.Text -match 'did not answer') 'no answer in time says so'
$skipRows = @([pscustomobject]@{ Id = 'S1'; Name = 'a'; Connectivity = 'OnPremisesGateway'; SkipTest = $true; UserList = @() }, [pscustomobject]@{ Id = 'S2'; Name = 'b'; Connectivity = 'OnPremisesGateway'; SkipTest = $false; UserList = @() })
Assert ((Select-GLConnections -Rows $skipRows -Show 'Skip test connection on').Id -eq 'S1') 'Show > Skip test connection on lists only the flagged ones'

# ---- copying rows: what Excel gets ----
$cols = @([pscustomobject]@{ Header = 'Name'; Property = 'Name' }, [pscustomobject]@{ Header = 'Path'; Property = 'Path' }, [pscustomobject]@{ Header = 'Users'; Property = 'UserList' })
$crs = @(
    [pscustomobject]@{ Name = 'Sales'; Path = "sql01`tsales"; UserList = @('jane@contoso.com', 'joe@contoso.com') }
    [pscustomobject]@{ Name = "Two`r`nlines"; Path = $null; UserList = @() }
)
$ct = ConvertTo-GLClipboardText -Rows $crs -Columns $cols -Headers
$cl2 = @($ct -split "`r`n")
Assert ($cl2.Count -eq 3 -and $cl2[0] -eq "Name`tPath`tUsers") 'copied rows with column names: the names first, then one line per row'
Assert ($cl2[1] -eq "Sales`tsql01 sales`tjane@contoso.com; joe@contoso.com" -and $cl2[2] -eq "Two lines`t`t") 'a tab or line break inside a value becomes a space, a list is joined with ";", empty stays empty'
Assert ((ConvertTo-GLClipboardText -Rows $crs -Columns $cols) -notmatch '^Name') 'without -Headers there is no header line'
Assert ((ConvertTo-GLClipboardText -Rows @() -Columns $cols) -eq '' -and (ConvertTo-GLClipboardText -Rows @([pscustomobject]@{ Other = 1 }) -Columns $cols) -eq "`t`t") 'no rows is empty text; a missing property is an empty cell, not an error'

# ---- gateway connections only, and the cleanup views ----
$kinds = @('OnPremisesGateway', 'VirtualNetworkGateway', 'StreamingVirtualNetworkGateway', 'ShareableCloud', 'PersonalCloud', 'OnPremisesGatewayPersonal', 'Automatic', 'None' | ForEach-Object {
    [pscustomobject]@{ id = "K-$_"; displayName = $_; connectivityType = $_; connectionDetails = [pscustomobject]@{ type = 'SQL'; path = 'p' } } })
$kr = ConvertTo-GLConnectionRows -Connections $kinds -GatewayNames @{}
Assert ((($kr | ForEach-Object Connectivity) -join ',') -eq 'OnPremisesGateway,VirtualNetworkGateway,StreamingVirtualNetworkGateway,ShareableCloud') 'gateway and shareable cloud connections are kept - personal, Automatic and unbound ones are no gateway admin''s'

$cl = @(
    [pscustomobject]@{ Id = 'D1'; Name = 'Sales';       Connectivity = 'OnPremisesGateway'; GatewayId = 'G1'; Gateway = 'A'; Type = 'SQL'; Path = 'srv;db';   Account = 'CONTOSO\svc'; LastUsed = '2026-10-01 08:00'; UnusedDays = 11;    Status = 'OK';      GatewayState = 'Online'; UserList = @() }
    [pscustomobject]@{ Id = 'D2'; Name = 'Sales copy';  Connectivity = 'OnPremisesGateway'; GatewayId = 'g1'; Gateway = 'A'; Type = 'sql'; Path = 'SRV;db ';  Account = 'contoso\SVC'; LastUsed = '2026-01-01 08:00'; UnusedDays = 284;   Status = 'Failed';  GatewayState = 'Online'; UserList = @() }
    [pscustomobject]@{ Id = 'D3'; Name = 'Other';       Connectivity = 'OnPremisesGateway'; GatewayId = 'G1'; Gateway = 'A'; Type = 'SQL'; Path = 'srv;other'; Account = 'CONTOSO\svc'; LastUsed = '';                UnusedDays = $null; Status = 'Timeout'; GatewayState = 'Online'; UserList = @() }
    [pscustomobject]@{ Id = 'D4'; Name = 'Cloud dup';   Connectivity = 'ShareableCloud';    GatewayId = '';   Gateway = '';  Type = 'Web'; Path = 'https://x'; Account = '';           LastUsed = '';                UnusedDays = $null; Status = '';        GatewayState = '';       UserList = @() }
    [pscustomobject]@{ Id = 'D5'; Name = 'Cloud dup 2'; Connectivity = 'ShareableCloud';    GatewayId = '';   Gateway = '';  Type = 'Web'; Path = 'https://x'; Account = '';           LastUsed = '';                UnusedDays = $null; Status = '';        GatewayState = '';       UserList = @() }
)
$v = Select-GLConnections -Rows $cl -Show 'Last used over 90 days ago'
Assert ($v.Count -eq 1 -and $v[0].Id -eq 'D2') 'last used over 90 days ago: only rows with an old date - an empty one is not guessed at'
$v = Select-GLConnections -Rows $cl -Show 'No use recorded'
Assert ($v.Count -eq 1 -and $v[0].Id -eq 'D3') 'no use recorded: gateway connections without a date (cloud ones only when included)'
$v = Select-GLConnections -Rows $cl -Show 'Duplicates'
Assert ((($v | ForEach-Object Id) -join ',') -eq 'D1,D2') 'duplicates: same gateway, type, path and account, whatever the case or spaces - side by side'
$v = Select-GLConnections -Rows $cl -Show 'Duplicates' -IncludeCloud
Assert ($v.Count -eq 2) 'two cloud connections to the same address, accounts unknown, are not called copies - the same path with other credentials is often on purpose'
$dupSame  = [pscustomobject]@{ GatewayId = 'G1'; Type = 'SQL'; Path = 'srv;db'; Account = 'svc'; Credential = 'Basic';   SingleSignOn = 'None'; Privacy = 'Organizational'; Encryption = 'Encrypted' }
$dupOther = [pscustomobject]@{ GatewayId = 'G1'; Type = 'SQL'; Path = 'srv;db'; Account = 'svc'; Credential = 'Windows'; SingleSignOn = 'None'; Privacy = 'Organizational'; Encryption = 'Encrypted' }
$dupSso   = [pscustomobject]@{ GatewayId = 'G1'; Type = 'SQL'; Path = 'srv;db'; Account = 'svc'; Credential = 'Basic';   SingleSignOn = 'Kerberos'; Privacy = 'Organizational'; Encryption = 'Encrypted' }
$dupNone  = [pscustomobject]@{ GatewayId = 'G1'; Type = 'SQL'; Path = 'srv;db'; Account = '';    Credential = 'Basic';   SingleSignOn = 'None'; Privacy = 'Organizational'; Encryption = 'Encrypted' }
Assert ((Get-GLDuplicateKey $dupSame) -and (Get-GLDuplicateKey $dupSame) -ne (Get-GLDuplicateKey $dupOther) -and (Get-GLDuplicateKey $dupSame) -ne (Get-GLDuplicateKey $dupSso) -and -not (Get-GLDuplicateKey $dupNone)) 'a copy signs in the same way: another credential type or single sign-on is not a copy, and an unknown account is never one'
$v = Select-GLConnections -Rows $cl -Show 'Failing tests'
Assert ((($v | ForEach-Object Id) -join ',') -eq 'D2,D3') 'failing tests: failed or did not answer'
$v = Select-GLConnections -Rows $cl -Show 'All connections'
Assert ($v.Count -eq 3) 'All connections: no cleanup filter'

$cc = Get-GLConnectionCounts -Rows $cl -Directory @{ 'd1' = [pscustomobject]@{ ClusterId = 'g1' }; 'x9' = [pscustomobject]@{ ClusterId = 'g1' }; 'y1' = [pscustomobject]@{ ClusterId = '' } }
Assert ($cc['g1'] -eq 4 -and $cc.Count -eq 1) "connections per gateway: the Fabric list and the directory together, each once, cloud ones not counted ($($cc['g1']))"

# ---- the 1,000 data sources Microsoft allows on a cluster ----
$lim = @(
    [pscustomobject]@{ id = 'L1'; displayName = 'Full';        type = 'OnPremises' }
    [pscustomobject]@{ id = 'L2'; displayName = 'Near';        type = 'OnPremises' }
    [pscustomobject]@{ id = 'L3'; displayName = 'Roomy';       type = 'OnPremises' }
    [pscustomobject]@{ id = 'L4'; displayName = 'Cloudy VNet'; type = 'VirtualNetwork' }
)
$lm = @{
    'L1' = @([pscustomobject]@{ id = 'Q1'; version = '3000.310.1' })
    'L2' = @([pscustomobject]@{ id = 'Q2'; version = '3000.310.1' })
    'L3' = @([pscustomobject]@{ id = 'Q3'; version = '3000.334.9' })
}
$lrows = ConvertTo-GLGatewayRows -Gateways $lim -Members $lm -Live $null
$lt = ConvertTo-GLGatewayTiles -Rows $lrows -Members $lm -DownSince @{} -Releases $rel -ConnectionCounts @{ 'l1' = 1000; 'l2' = 812; 'l3' = 40; 'l4' = 3 } -VnetSkipped
$lb = @{}; foreach ($x in $lt) { $lb[$x.Name] = $x }
Assert ($lb['Full'].Badge -eq 'AT CONNECTION LIMIT' -and $lb['Full'].ConnectionsText -eq '1,000 of 1,000 connections') "at 1,000 connections: AT CONNECTION LIMIT, before even an unsupported version ($($lb['Full'].ConnectionsText))"
Assert ($lb['Near'].Badge -eq 'UNSUPPORTED VERSION' -and $lb['Roomy'].Badge -eq '' -and $lb['Roomy'].ConnectionsText -eq '40 of 1,000 connections') 'an unsupported version outranks being near the limit; plenty of room: no badge'
$lt2 = ConvertTo-GLGatewayTiles -Rows $lrows -Members @{ 'L2' = @([pscustomobject]@{ id = 'Q2'; version = '3000.334.9' }) } -DownSince @{} -Releases $rel -ConnectionCounts @{ 'l2' = 812 }
Assert (($lt2 | Where-Object Name -eq 'Near').Badge -eq 'NEAR CONNECTION LIMIT') '80% of the limit, nothing worse: NEAR CONNECTION LIMIT'
Assert ($lb['Cloudy VNet'].ConnectionsText -eq '3 connections' -and -not $lb['Cloudy VNet'].HasBadge) 'a VNet gateway shows its connections, with no limit badge'
Assert ((Get-GLGatewayCounts -Tiles $lt).NearLimit -eq 1 -and (Get-GLGatewayCounts -Tiles $lt2).NearLimit -eq 1) 'the banner counts gateways at or near the limit'
$nc = ConvertTo-GLGatewayTiles -Rows $lrows -Members $lm -DownSince @{}
Assert (-not ($nc | Where-Object ConnectionsText)) 'connections not loaded yet: no count is shown - never a made-up 0'

# ---- handing over access ----
$pj = [pscustomobject]@{ id = 'U-JOE'; displayName = 'Joe Smith'; type = 'User'; userDetails = [pscustomobject]@{ userPrincipalName = 'joe@contoso.com' } }
$pg = [pscustomobject]@{ id = 'G-BI'; displayName = 'BI Team'; type = 'Group'; groupDetails = [pscustomobject]@{ email = 'bi@contoso.com' } }
Assert ((Test-GLPrincipalMatch $pj ([pscustomobject]@{ Id = 'u-joe'; Names = @() })) -and (Test-GLPrincipalMatch $pj ([pscustomobject]@{ Id = ''; Names = @('JOE@contoso.com') })) -and (Test-GLPrincipalMatch $pg ([pscustomobject]@{ Id = ''; Names = @('bi@contoso.com') }))) 'the one handing over is matched by object id, UPN or group email - in any case'
Assert (-not (Test-GLPrincipalMatch $pj ([pscustomobject]@{ Id = ''; Names = @('Joe Smith') }))) 'never by display name - two people can share one'
$ras = @(
    [pscustomobject]@{ id = 'A1'; role = 'Owner'; principal = $pj }
    [pscustomobject]@{ id = 'A2'; role = 'User';  principal = [pscustomobject]@{ id = 'U-ANA'; type = 'User' } }
)
$fromJ = [pscustomobject]@{ Id = 'U-JOE'; Names = @() }
$st1 = Get-GLHandoverStep -Assignments $ras -From $fromJ -To ([pscustomobject]@{ Id = 'U-ANA' })
Assert ($st1.Action -eq 'Raise' -and $st1.Role -eq 'Owner' -and $st1.ToRole -eq 'User' -and $st1.ToAssignmentId -eq 'A2' -and $st1.FromAssignmentId -eq 'A1') 'a lower role: Raise it to the same role'
$st2 = Get-GLHandoverStep -Assignments $ras -From $fromJ -To ([pscustomobject]@{ Id = 'U-NEW' })
Assert ($st2.Action -eq 'Grant' -and $st2.Role -eq 'Owner') 'no role yet: Grant the same role'
$st3 = Get-GLHandoverStep -Assignments $ras -From ([pscustomobject]@{ Id = 'U-ANA'; Names = @() }) -To ([pscustomobject]@{ Id = 'U-JOE' })
Assert ($st3.Action -eq 'Keep' -and $st3.ToRole -eq 'Owner') 'already a higher role: Keep it'
$st4 = Get-GLHandoverStep -Assignments $ras -From ([pscustomobject]@{ Id = 'U-NOBODY'; Names = @() }) -To ([pscustomobject]@{ Id = 'U-ANA' })
Assert ($st4.Action -eq 'None') 'no role to hand over: None'
$gwRas = @([pscustomobject]@{ id = 'B1'; role = 'Admin'; principal = $pj }, [pscustomobject]@{ id = 'B2'; role = 'ConnectionCreatorWithResharing'; principal = [pscustomobject]@{ id = 'U-ANA' } })
Assert ((Get-GLHandoverStep -Assignments $gwRas -From $fromJ -To ([pscustomobject]@{ Id = 'U-ANA' }) -Kind gateways).Action -eq 'Raise') 'gateway roles rank too: connection creator to Admin is a raise'

# ---- the access report ----
$at = @(
    [pscustomobject]@{ Kind = 'connections'; Id = 'C1'; Name = 'Sales';  Gateway = 'A'; Type = 'SQL'; Path = 'srv;db'; Account = 'svc'; LastUsed = '2026-10-01 08:00' }
    [pscustomobject]@{ Kind = 'gateways';    Id = 'G1'; Name = 'A';      Gateway = 'A'; Type = 'OnPremises'; Path = ''; Account = ''; LastUsed = '' }
    [pscustomobject]@{ Kind = 'connections'; Id = 'C9'; Name = 'Locked'; Gateway = 'A' }
)
$am = @{ 'connections/C1' = $ras; 'gateways/G1' = $gwRas; 'connections/C9' = $null }
$ar = ConvertTo-GLAccessReportRows -Targets $at -Assignments $am
Assert ($ar.Count -eq 5 -and $ar[0].Kind -eq 'Connection' -and $ar[0].Email -eq 'joe@contoso.com' -and $ar[0].Role -eq 'Owner' -and $ar[0].Path -eq 'srv;db' -and $ar[0].LastUsed) "access report: one row per item and principal, with what an auditor needs ($($ar.Count) rows)"
Assert (($ar | Where-Object Target -eq 'Locked').Role -eq '(could not be read)' -and @($ar | Where-Object Kind -eq 'Gateway').Count -eq 2) 'gateways are in it, and an item whose access could not be read says so'
$arj = ConvertTo-GLAccessReportRows -Targets $at -Assignments $am -Who 'joe'
Assert ($arj.Count -eq 2 -and -not ($arj | Where-Object { $_.Email -ne 'joe@contoso.com' })) 'for one person: only their rows, without "could not be read" noise'

$t = Select-GLByText -Rows $rows -Text 'vnet'
Assert ($t.Count -eq 1 -and $t[0].Name -eq 'VNet B') 'quick filter matches any column'

# ============================================================================
Section 'Connection filters for management'
# ============================================================================
$mrows = @(
    [pscustomobject]@{ Name = 'Sales SQL';  Path = 'sql01;sales'; Type = 'SQL';    Gateway = 'A'; Connectivity = 'OnPremisesGateway'; GatewayId = 'g1'; Id = 'C1'; GatewayState = ''; Account = ''; Users = ''; Status = ''; StatusDetail = ''; UserList = @() }
    [pscustomobject]@{ Name = 'HR Oracle';  Path = 'ora01';       Type = 'Oracle'; Gateway = 'B'; Connectivity = 'OnPremisesGateway'; GatewayId = 'g2'; Id = 'C2'; GatewayState = ''; Account = ''; Users = ''; Status = ''; StatusDetail = ''; UserList = @() }
    [pscustomobject]@{ Name = 'Cloud web';  Path = 'https://x';   Type = 'Web';    Gateway = '';  Connectivity = 'ShareableCloud';    GatewayId = '';   Id = 'C3'; GatewayState = ''; Account = ''; Users = ''; Status = ''; StatusDetail = ''; UserList = @() }
)
Set-GLRowGatewayState -Rows $mrows -GatewayState @{ 'g1' = 'Online'; 'g2' = 'Partial' }
Assert ($mrows[0].GatewayState -eq 'Online' -and $mrows[1].GatewayState -eq 'Partial' -and $mrows[2].GatewayState -eq 'n/a') 'each connection takes its gateway''s state; cloud is n/a'

$f = Select-GLConnections -Rows $mrows -Text 'sql01; ora01'
Assert ($f.Count -eq 2) 'several search values at once - a row matches any of them'
$f = Select-GLConnections -Rows $mrows -States @('Online')
Assert ($f.Count -eq 1 -and $f[0].Id -eq 'C1') 'gateway state filter: Online only'
$f = Select-GLConnections -Rows $mrows -States @('Online', 'Partial', 'Unknown') -IncludeCloud
Assert ($f.Count -eq 3) 'cloud connections count as Unknown for the state filter'
$ex = [System.Collections.Generic.HashSet[string]]::new([string[]]@('C2'))
$f = Select-GLConnections -Rows $mrows -Excluded $ex -IncludeCloud
Assert ($f.Count -eq 2 -and -not ($f | Where-Object Id -eq 'C2')) 'excluded rows stay out'

Add-GLDirectoryInfo -Rows $mrows -Directory @{ 'c1' = [pscustomobject]@{ Account = 'DOM\svc_sales'; Users = @([pscustomobject]@{ Principal = 'jane@contoso.com' }, [pscustomobject]@{ Principal = 'bi@contoso.com' }) } }
Assert ($mrows[0].Account -eq 'DOM\svc_sales' -and $mrows[0].Users -eq '2') 'directory fills Account and the user count'
$f = Select-GLConnections -Rows $mrows -Account 'svc_sales'
Assert ($f.Count -eq 1) 'search by the account stored in the credentials'
$f = Select-GLConnections -Rows $mrows -User 'JANE@'
Assert ($f.Count -eq 1 -and $f[0].Id -eq 'C1') 'search by a user with access, case-insensitive'

Set-GLRowUsers -Rows $mrows -Assignments @{
    'C2' = @([pscustomobject]@{ principal = [pscustomobject]@{ id = 'P'; displayName = 'Joe'; userDetails = [pscustomobject]@{ userPrincipalName = 'joe@contoso.com' } } })
    'C3' = $null }
Assert ($mrows[1].Users -eq '1' -and $mrows[1].UserList[0] -eq 'joe@contoso.com') 'verify users fills the list from role assignments'
Assert ($mrows[2].Users -eq 'error') 'a connection whose users could not be read says so'
Assert ($mrows[0].Users -eq '2') 'rows not in the result keep what they had'

Set-GLRowStatus -Rows $mrows -Status @{ 'C1' = [pscustomobject]@{ Status = 'Failed'; Detail = 'Login failed' } }
Assert ($mrows[0].Status -eq 'Failed' -and $mrows[0].StatusDetail -eq 'Login failed' -and $mrows[1].Status -eq '') 'verify status fills only the rows it checked'


# ============================================================================
Section 'Shaping access'
# ============================================================================
$ras = @(
    [pscustomobject]@{ id = 'R1'; role = 'Owner'; principal = [pscustomobject]@{ id = 'P1'; displayName = 'Jane'; type = 'User'
                       userDetails = [pscustomobject]@{ userPrincipalName = 'jane@contoso.com' } } }
    [pscustomobject]@{ id = 'R2'; role = 'User'; principal = [pscustomobject]@{ id = 'P2'; displayName = 'BI Team'; type = 'Group'
                       groupDetails = [pscustomobject]@{ email = 'bi@contoso.com' } } }
    [pscustomobject]@{ id = 'R3'; role = 'User'; principal = [pscustomobject]@{ id = 'P3'; type = 'ServicePrincipal'
                       servicePrincipalDetails = [pscustomobject]@{ aadAppId = 'APP' } } }
)
$arows = ConvertTo-GLRoleRows -Assignments $ras
Assert ($arows[0].Detail -eq 'jane@contoso.com') 'a user shows their UPN'
Assert ($arows[1].Detail -eq 'bi@contoso.com') 'a group shows its email'
Assert ($arows[2].Principal -eq 'P3' -and $arows[2].Detail -eq 'app APP') 'a principal without a name shows its id and app id'

# ============================================================================
Section 'Finding the right person'
# ============================================================================
$who = Resolve-GLPrincipal -Value ' abcdef01-d9cb-469f-a165-70867728950e ' -Type 'User'
Assert ($who.Id -eq 'abcdef01-d9cb-469f-a165-70867728950e' -and $who.Source -eq 'object id') 'an object id is used as given, trimmed, without Graph'

$err = $null
try { Resolve-GLPrincipal -Value 'jane@contoso.com' -Type 'User' -GraphToken $null } catch { $err = $_.Exception.Message }
Assert ($err -match 'object id') 'a name without Graph asks for the object id'

$script:Graph = @{}
function Invoke-GLRequest {
    # Stand-in for every API call. Keys are URL fragments; the LONGEST matching key
    # wins, so a specific stub is never shadowed by a shorter one that happens to be
    # a substring of the same URL. (A plain hashtable has no fixed order - matching
    # in that order made these tests pass or fail at random.)
    param($Method, $Uri, $Token, $Body, $MaxRetry)
    foreach ($k in ($script:Graph.Keys | Sort-Object Length -Descending)) {
        if ($Uri -like "*$k*") { $v = $script:Graph[$k]; if ($v -is [string]) { throw $v }; return $v }
    }
    throw "no stub for $Uri"
}
$script:Graph = @{ 'users/jane%40contoso.com' = [pscustomobject]@{ id = 'U1'; displayName = 'Jane'; userPrincipalName = 'jane@contoso.com' } }
$who = Resolve-GLPrincipal -Value 'jane@contoso.com' -Type 'User' -GraphToken 'g'
Assert ($who.Id -eq 'U1' -and $who.DisplayName -match 'jane@contoso.com') 'a user is found by UPN'

$script:Graph = @{ 'users/guest' = 'HTTP 404'; 'users?' = [pscustomobject]@{ value = @([pscustomobject]@{ id = 'U2'; displayName = 'Guest'; userPrincipalName = 'g_ext' }) } }
$who = Resolve-GLPrincipal -Value 'guest@partner.com' -Type 'User' -GraphToken 'g'
Assert ($who.Id -eq 'U2') 'a guest is found by mail when the UPN lookup fails'

$script:Graph = @{ 'groups?' = [pscustomobject]@{ value = @([pscustomobject]@{ id = 'A' }, [pscustomobject]@{ id = 'B' }) } }
$err = $null
try { Resolve-GLPrincipal -Value 'Admins' -Type 'Group' -GraphToken 'g' } catch { $err = $_.Exception.Message }
Assert ($err -match 'matches 2') 'an ambiguous group name is refused, not guessed'

$script:Graph = @{ 'groups?' = [pscustomobject]@{ value = @() } }
$err = $null
try { Resolve-GLPrincipal -Value 'Nobody' -Type 'Group' -GraphToken 'g' } catch { $err = $_.Exception.Message }
Assert ($err -match 'No Group found') 'a name that matches nothing says so'

# ============================================================================
Section 'Live status and gateway data'
# ============================================================================
$script:Graph = @{
    'me/gatewayClusters' = [pscustomobject]@{ value = @(
        [pscustomobject]@{ id = 'C9'; memberGateways = @(
            [pscustomobject]@{ id = 'MA'; enabled = $true;  version = '1'; annotation = '{"gatewayMachine":"HOST-A"}' }
            [pscustomobject]@{ id = 'MB'; enabled = $false; version = '1' }
            [pscustomobject]@{ id = 'MC'; enabled = $true;  version = '1' }) }
        [pscustomobject]@{ id = 'C8'; memberGateways = @([pscustomobject]@{ id = 'MZ'; version = '1' }) }) }
}
$script:ParallelCalls = @()
function Invoke-GLParallelGet {
    param($Uris, $Token, $TimeoutSec, $Batch)
    $script:ParallelCalls += , @($Uris)
    $out = @{}
    foreach ($u in $Uris) {
        $out[$u] = switch -Wildcard ($u) {
            '*/MA/status' { [pscustomobject]@{ Ok = $true;  Status = 200; Body = [pscustomobject]@{ gatewayStatus = 'Live' }; Error = $null } }
            '*/MB/status' { [pscustomobject]@{ Ok = $false; Status = 500; Body = $null; Error = 'HTTP 500 : boom' } }
            default       { [pscustomobject]@{ Ok = $false; Status = 0;   Body = $null; Error = 'no answer within 30s' } }
        }
    }
    return $out
}
$ls = Get-GLLiveStatus -PbiToken 'p'
Assert ($ls['ma'].Status -eq 'Live' -and $ls['ma'].Machine -eq 'HOST-A') 'live status and machine name are read'
Assert ($ls['mb'].Status -eq 'Error') 'a member whose check fails is Error, and the rest still load'
Assert ($ls['mc'].Status -eq 'Timeout') 'a member that does not answer in time is Timeout, not Error'
Assert ($script:ParallelCalls.Count -eq 1 -and $script:ParallelCalls[0].Count -eq 4) 'every member is asked in ONE parallel call, not one by one'

$script:ParallelCalls = @()
$ls = Get-GLLiveStatus -PbiToken 'p' -MaxClusters 1
Assert ($ls.Count -eq 3 -and -not $ls.ContainsKey('mz')) 'MaxClusters limits the check to the first gateway (used by the self-test)'
Remove-Item function:Invoke-GLParallelGet

$script:Graph = @{
    'v1/gateways/G1/members' = [pscustomobject]@{ value = @([pscustomobject]@{ id = 'M1' }) }
    'v1/gateways'            = [pscustomobject]@{ value = @(
        [pscustomobject]@{ id = 'G1'; type = 'OnPremises'; displayName = 'A' }
        [pscustomobject]@{ id = 'G2'; type = 'VirtualNetwork'; displayName = 'B' }
        [pscustomobject]@{ id = 'G3'; type = 'OnPremises'; displayName = 'C' }) }
    'v1/gateways/G3/members' = 'HTTP 403'
    'me/gatewayClusters'     = 'HTTP 401'
}
$gd = Get-GLGatewayData -FabricToken 'f' -PbiToken 'p' -LiveStatus
Assert ($gd.Gateways.Count -eq 3) 'all gateways are returned'
Assert ($gd.Members.ContainsKey('G1') -and -not $gd.Members.ContainsKey('G2')) 'members are only fetched for on-premises gateways'
Assert (($gd.Log -join ' ') -match "Members of 'C'") 'a member call that fails becomes a warning, not a failed load'
Assert ($null -eq $gd.Live -and ($gd.Log -join ' ') -match 'unofficial') 'the unofficial status endpoint failing is a warning only'

$script:Graph = @{ 'datasources/C1/status' = [pscustomobject]@{} }
$tc = Test-GLConnection -GatewayId 'G1' -ConnectionId 'C1' -PbiToken 'p'
Assert ($tc.Ok) 'a passing connection test reports Ok'
$script:Graph = @{ 'datasources/C1/status' = 'GET ... -> HTTP 400 : DM_GWPipeline_Gateway_DataSourceAccessError' }
$tc = Test-GLConnection -GatewayId 'G1' -ConnectionId 'C1' -PbiToken 'p'
Assert (-not $tc.Ok -and $tc.Message -match 'DataSourceAccessError') 'a failing test returns the gateway''s own error'

Remove-Item function:Invoke-GLRequest
. $script -LoadOnly

# ============================================================================
Section 'Readable errors'
# ============================================================================
$pbiDot = '{"error":{"code":"DM_GWPipeline_Gateway_DataSourceAccessError","pbi.error":{"code":"DM_GWPipeline_Gateway_DataSourceAccessError","parameters":{},"details":[{"code":"DM_ErrorDetailNameCode_UnderlyingErrorCode","detail":{"type":1,"value":"-2146232060"}},{"code":"DM_ErrorDetailNameCode_UnderlyingErrorMessage","detail":{"type":1,"value":"Login failed for user ''CONTOSO\\svc_hr''."}},{"code":"DM_ErrorDetailNameCode_UnderlyingHResult","detail":{"type":1,"value":"-2146232060"}}],"exceptionCulprit":1}}}'
Assert ((ConvertFrom-GLApiError $pbiDot) -eq "DM_GWPipeline_Gateway_DataSourceAccessError: Login failed for user 'CONTOSO\svc_hr'.") 'Power BI: the "pbi.error" key with a dot, and the readable message - not the number listed first'
$nested = [pscustomobject]@{ error = [pscustomobject]@{ code = 'X'; pbi = [pscustomobject]@{ error = [pscustomobject]@{ details = @([pscustomobject]@{ code = 'A'; detail = [pscustomobject]@{ value = 'readable' } }) } } } }
Assert ((ConvertFrom-GLApiError $nested) -eq 'X: readable') 'Power BI: a nested pbi / error is read too'
Assert ((ConvertFrom-GLApiError '{"requestId":"r","errorCode":"PrincipalAlreadyHasRole","message":"The principal already has a role."}') -eq 'PrincipalAlreadyHasRole: The principal already has a role.') 'Fabric: error code and message'
Assert ((ConvertFrom-GLApiError '{"error":{"code":"Request_ResourceNotFound","message":"Resource does not exist."}}') -eq 'Request_ResourceNotFound: Resource does not exist.') 'Graph: code and message'
Assert ((ConvertFrom-GLApiError 'Bad gateway') -eq 'Bad gateway' -and (ConvertFrom-GLApiError '{not json') -eq '{not json') 'anything that is not JSON comes back as it was'
Assert ((ConvertFrom-GLApiError $null) -eq '') 'nothing in, nothing out'

# ============================================================================
Section 'Management - the exact requests sent'
# ============================================================================
# A recording stand-in: every call is logged, and answered by the longest matching rule.
$script:Calls = [System.Collections.Generic.List[object]]::new()
$script:Rules = @{}
function Invoke-GLRequest {
    param($Method = 'GET', $Uri, $Token, $Body, $MaxRetry)
    $script:Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body })
    foreach ($k in ($script:Rules.Keys | Sort-Object Length -Descending)) {
        if ("$Method $Uri" -like "*$k*") { $v = $script:Rules[$k]; if ($v -is [string]) { throw $v }; return $v }
    }
    return $null
}
function Reset-Calls { $script:Calls.Clear(); $script:Rules = @{} }

$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$pk  = [pscustomobject]@{ modulus = [Convert]::ToBase64String($rsa.ExportParameters($false).Modulus); exponent = 'AQAB' }

Reset-Calls
Set-GLConnectionCredential -GatewayId 'G1' -ConnectionId 'C1' -PublicKey $pk -CredentialType Basic -Username 'u' -Password 'p' -Privacy 'Private' -Encryption 'Encrypted' -PbiToken 't'
$c = $script:Calls[0]
Assert ($c.Method -eq 'PATCH' -and $c.Uri -eq 'https://api.powerbi.com/v1.0/myorg/gateways/G1/datasources/C1') "update credentials: PATCH the documented datasource URL"
Assert ($c.Body.credentialDetails.credentialType -eq 'Basic' -and $c.Body.credentialDetails.privacyLevel -eq 'Private') 'update credentials: keeps the privacy level it was given'

Reset-Calls
Remove-GLConnection -Id 'C9' -FabricToken 'f'
Assert ($script:Calls[0].Method -eq 'DELETE' -and $script:Calls[0].Uri -eq 'https://api.fabric.microsoft.com/v1/connections/C9') 'delete: the documented Fabric call'

Reset-Calls
Set-GLMemberEnabled -GatewayId 'G1' -MemberId 'M1' -Enabled $false -FabricToken 'f'
$c = $script:Calls[0]
Assert ($c.Method -eq 'PATCH' -and $c.Uri -like '*/v1/gateways/G1/members/M1' -and $c.Body.enabled -eq $false) 'disable member: PATCH enabled=false on the member'


# ============================================================================
Section 'Names and addresses'
# ============================================================================
$lst = Split-GLList "a@x.com; b@x.com`r`nc@x.com,a@x.com;;"
Assert ($lst.Count -eq 3 -and ($lst -join ',') -eq 'a@x.com,b@x.com,c@x.com') 'principal lists split on ; , and new lines, de-duplicated'
$lst = Split-GLList '   '
Assert ($lst -is [array] -and $lst.Count -eq 0) 'an empty list is an empty array'

$fakeDns = { param($n) if ($n -eq 'GW01.corp.example') { @([System.Net.IPAddress]::Parse('10.1.2.3')) } else { throw 'no such host' } }
Assert ((Resolve-GLHostAddress -Machine 'GW01' -Suffixes @('nope.example', 'corp.example') -Resolver $fakeDns) -eq '10.1.2.3;GW01.corp.example') 'an address is found through the suffix list'
Assert ((Resolve-GLHostAddress -Machine 'GW99' -Suffixes @('corp.example') -Resolver $fakeDns) -eq 'UNKNOWN;GW99') 'a name that does not resolve is reported, not dropped'
$fakeV6 = { param($n) @([System.Net.IPAddress]::Parse('fe80::1'), [System.Net.IPAddress]::Parse('10.9.9.9')) }
Assert ((Resolve-GLHostAddress -Machine 'H' -Resolver $fakeV6) -eq '10.9.9.9;H') 'the IPv4 address is chosen over IPv6'

Assert ((Get-GLGatewayState '3 / 3') -eq 'Online')  'gateway state: all up is Online'
Assert ((Get-GLGatewayState '0 / 2') -eq 'Offline') 'gateway state: none up is Offline'
Assert ((Get-GLGatewayState '1 / 2') -eq 'Partial') 'gateway state: some up is Partial'
Assert ((Get-GLGatewayState 'n/a')   -eq 'Unknown') 'gateway state: no live status is Unknown'

$txt = Format-GLClusterText -GatewayName 'Cluster A' -MemberRows @([pscustomobject]@{ Member = 'n1'; Machine = 'H1'; Version = '1'; Enabled = $true; Status = 'Live' })
Assert ($txt -eq "Cluster A`tn1`tH1`t1`tTrue`tLive") 'copied cluster text is tab-separated, one line per member'

# ============================================================================
Section 'Cleanup - what can go before the 1,000 limit'
# ============================================================================
$cuNow = Get-Date '2026-10-12 12:00'
$cuRow = {
    param([string]$Name, [string]$Made, [string]$Linked, [string]$Used, [string]$Path)
    $ud = if ($Used) { [int][math]::Floor(($cuNow - [datetime]::ParseExact($Used, 'yyyy-MM-dd HH:mm', $null)).TotalDays) } else { $null }
    [pscustomobject]@{ Name = $Name; Connectivity = 'OnPremisesGateway'; Gateway = 'Gateway 1'; GatewayId = 'G1'; Type = 'SQL'; Path = $Path; Account = 'svc'
                       Created = $Made; LastLinked = $Linked; LastUsed = $Used; UnusedDays = $ud; Id = "id-$Name"; Users = '2'; Cleanup = ''; CanGo = $false }
}
$cuRows = @(
    (& $cuRow 'old'      '2025-01-01 08:00' '2025-01-02 08:00' '2026-05-01 08:00' 'a')
    (& $cuRow 'quarter'  '2025-01-01 08:00' '2025-01-02 08:00' '2026-07-15 08:00' 'b')
    (& $cuRow 'never'    '2026-01-01 08:00' '2026-01-02 08:00' ''                 'c')
    (& $cuRow 'newbie'   '2026-10-01 08:00' ''                 ''                 'd')
    (& $cuRow 'relinked' '2025-01-01 08:00' '2026-10-10 08:00' '2026-01-01 08:00' 'e')
    (& $cuRow 'nodata'   ''                 ''                 ''                 'f')
    (& $cuRow 'copyA'    '2025-01-01 08:00' '2025-01-02 08:00' '2026-10-11 08:00' 'g')
    (& $cuRow 'copyB'    '2025-02-01 08:00' '2025-02-02 08:00' '2026-10-05 08:00' 'g')
    (& $cuRow 'copyC'    '2025-03-01 08:00' '2025-03-02 08:00' '2026-02-01 08:00' 'g')
)
$cuCloud = [pscustomobject]@{ Name = 'cloud'; Connectivity = 'ShareableCloud'; GatewayId = ''; Type = 'Web'; Path = 'x'; Account = ''; Created = '2024-01-01 08:00'; LastLinked = ''; LastUsed = '2024-02-01 08:00'; UnusedDays = 900; Id = 'id-cloud'; Cleanup = ''; CanGo = $false }
Set-GLCleanupReasons -Rows (@($cuRows) + @($cuCloud)) -Now $cuNow
$cuBy = @{}; foreach ($r in $cuRows) { $cuBy[$r.Name] = $r }
Assert ($cuBy.old.CanGo -and $cuBy.old.Cleanup -eq 'not used for 164 days') "not used for more than four months: it can go, and the column says why ($($cuBy.old.Cleanup))"
Assert (-not $cuBy.quarter.CanGo -and -not $cuBy.quarter.Cleanup) 'used 89 days ago - a quarterly refresh - stays'
Assert ($cuBy.never.CanGo -and $cuBy.never.Cleanup -eq 'no use recorded since it was made on 2026-01-01') 'never used since it was made, months ago: it can go'
Assert (-not $cuBy.newbie.CanGo -and -not $cuBy.relinked.CanGo -and -not $cuBy.nodata.CanGo) 'made or linked to an item in the last 30 days, or no recency data at all: never a candidate'
Assert (-not $cuBy.copyA.Cleanup -and -not $cuBy.copyB.CanGo -and $cuBy.copyB.Cleanup -match "a copy of 'copyA', which was used on 2026-10-11 - point its items at that one") "duplicates: the copy used most recently stays; a copy still in use is merged first, never 'can go' ($($cuBy.copyB.Cleanup))"
Assert ($cuBy.copyC.CanGo -and $cuBy.copyC.Cleanup -match "^not used for 253 days - a copy of 'copyA'") 'an unused copy can go, and says what it copies'
Assert (-not $cuCloud.CanGo -and -not $cuCloud.Cleanup) 'cloud connections are left out - the limit is per gateway cluster'
$cuView = Select-GLConnections -Rows $cuRows -Show 'Cleanup candidates'
Assert ((@($cuView | ForEach-Object Name | Sort-Object) -join ',') -eq 'copyC,never,old') "Show > Cleanup candidates lists exactly what can go ($(@($cuView | ForEach-Object Name) -join ', '))"
$cuCounts = Get-GLCleanupCounts -Rows $cuRows
Assert ($cuCounts['g1'] -eq 3) 'the tiles count what can go on each gateway'
$cuSum = Get-GLCleanupSummary -Rows $cuRows -Counts @{ g1 = 940 }
$cuB = $cuSum[0].Buckets
Assert ($cuSum.Count -eq 1 -and $cuSum[0].Total -eq 940 -and $cuSum[0].CanGo -eq 3 -and $cuSum[0].Merge -eq 1 -and $cuSum[0].After -eq 937 -and
        $cuB.Recent -eq 2 -and $cuB.Months -eq 1 -and $cuB.Year -eq 3 -and $cuB.Older -eq 0 -and $cuB.Never -eq 2 -and $cuB.NoData -eq 1) 'each cluster: how full, what can go, and how recently its connections were used'
$cuOwners = @{ 'id-old' = @('jane@contoso.com'); 'id-never' = @('<b>sneaky</b>'); 'id-copyC' = @('jane@contoso.com'); 'id-copyB' = @('ana@contoso.com') }
$cuHtml = ConvertTo-GLCleanupHtml -Summary $cuSum -Rows $cuRows -Owners $cuOwners -Meta @{ Version = '9.9.9'; Who = 'demo.user@contoso.com'; Tenant = 'contoso.example'; When = $cuNow }
Assert ($cuHtml -match 'Room on each cluster' -and $cuHtml -match 'How recently connections were used' -and $cuHtml -match 'Gateway 1</b> - 3 can go' -and $cuHtml -match 'Near the limit' -and $cuHtml -match 'Merge first' -and $cuHtml -match 'Who to ask') 'the report: room on each cluster, recency, what can go, what to merge, whom to ask'
Assert ($cuHtml -match '&lt;b&gt;sneaky&lt;/b&gt;' -and $cuHtml -notmatch '<b>sneaky</b>') 'every name from the tenant is HTML-encoded in the report'
Assert ($cuHtml -match 'jane@contoso\.com</td><td class="num">2</td>') 'whom to ask: each owner with how many of theirs can go'
Assert ($cuHtml -notmatch 'https?://(?!www\.w3\.org)' -and $cuHtml -notmatch '<script') 'the report loads nothing from anywhere and runs no script'
$cuCsv = ConvertTo-GLCleanupCsvRows -Rows $cuRows -Owners $cuOwners
Assert ($cuCsv.Count -eq 4 -and @($cuCsv | Where-Object Action -eq 'Merge first').Count -eq 1 -and ($cuCsv | Where-Object Connection -eq 'old').Owners -eq 'jane@contoso.com') 'the table: one row per connection to clean up, with its owners'
$cuFile = Join-Path ([System.IO.Path]::GetTempPath()) ('gl-cleanup-' + [guid]::NewGuid().ToString('N') + '.html')
$cuRes = Save-GLCleanupReport -Path $cuFile -Rows $cuRows -Owners $cuOwners -Counts @{ g1 = 940 } -Meta @{ Version = '9.9.9'; Who = 'x'; When = $cuNow } -NoOpen
$cuBytes = [System.IO.File]::ReadAllBytes($cuRes.Csv)
Assert ((Test-Path $cuRes.Html) -and $cuBytes[0] -eq 0xEF -and $cuBytes[1] -eq 0xBB -and $cuRes.CanGo -eq 3 -and $cuRes.Merge -eq 1) 'saved side by side: the page, and the table with a BOM for Excel'
Remove-Item -LiteralPath $cuRes.Html, $cuRes.Csv -ErrorAction SilentlyContinue

# ============================================================================
Section 'Progress and the meter'
# ============================================================================
$repTest = [hashtable]::Synchronized(@{ Stage = ''; Done = 0; Total = 0; Expect = 0 })
Reset-Calls
$script:Rules = @{ 'pages/one' = [pscustomobject]@{ value = @(1, 2, 3); continuationUri = 'https://x/pages/two' }; 'pages/two' = [pscustomobject]@{ value = @(4, 5) } }
$pg = Get-GLPaged -Uri 'https://x/pages/one' -Token 't' -Report $repTest
Assert ($pg.Count -eq 5 -and $repTest.Done -eq 5) 'paging reports how many it has so far'
$jobsNow = @(
    [pscustomobject]@{ Name = 'Loading connections'; Report = @{ Stage = 'reading the connections'; Done = 1500; Total = 0; Expect = 2600 } }
    [pscustomobject]@{ Name = 'Loading gateways'; Report = @{ Stage = 'reading the members of each gateway'; Done = 4; Total = 6; Expect = 0 } }
    [pscustomobject]@{ Name = 'Access for x'; Report = $null })
$ws = Get-GLWorkStatus -Jobs $jobsNow
Assert ($ws.Text -match 'Loading connections: reading the connections - 1\D?500 of about 2\D?600' -and $ws.Text -match 'reading the members of each gateway - 4 of 6' -and $ws.Text -match 'Access for x' -and $ws.Max -eq 2600 -and $ws.Value -eq 1500) "the status bar says what each job is doing, and how far ($($ws.Text))"
$ws2 = Get-GLWorkStatus -Jobs @([pscustomobject]@{ Name = 'Loading connections'; Report = @{ Stage = 'reading the connections'; Done = 4000; Total = 0; Expect = 2600 } })
Assert ($ws2.Value -lt $ws2.Max) 'more than expected: the bar never claims to be finished before it is'
$mt = Get-GLMeterText -Cpu 3.4 -MemoryBytes 420MB -Busy 6 -Workers 4 -Threads 41 -Calls 1284 -Throttled 3
Assert ($mt -match '^CPU 3%' -and $mt -match 'Memory 420 MB' -and $mt -match 'Workers 4 of 4 busy, 2 waiting' -and $mt -match 'Threads 41' -and $mt -match 'API calls 1\D?284' -and $mt -match 'throttled 3') "the meter: CPU, memory, workers, threads, calls and throttling ($mt)"

# ============================================================================
Section 'Alerts - a member down, a member back'
# ============================================================================
$t0 = Get-Date '2026-10-12 10:00:00'
$liveAt = {
    param([string]$S1, [string]$S2)
    @{ m1 = [pscustomobject]@{ Status = $S1; Cluster = 'C1'; Machine = 'GW-01'; Enabled = $true }
       m2 = [pscustomobject]@{ Status = $S2; Cluster = 'C1'; Machine = 'GW-02'; Enabled = $true }
       m3 = [pscustomobject]@{ Status = 'Offline'; Cluster = 'C2'; Machine = 'GW-03'; Enabled = $false } }
}
$a1 = Get-GLAlertEvents -Track @{} -Live (& $liveAt 'Live' 'Timeout') -Now $t0
$a2 = Get-GLAlertEvents -Track $a1.Track -Live (& $liveAt 'Live' 'Offline') -Now $t0.AddMinutes(1)
$a3 = Get-GLAlertEvents -Track $a2.Track -Live (& $liveAt 'Live' 'Offline') -Now $t0.AddMinutes(2)
$a4 = Get-GLAlertEvents -Track $a3.Track -Live (& $liveAt 'Live' 'Live') -Now $t0.AddMinutes(12)
Assert (@($a1.Events).Count -eq 0) 'one check without an answer is not an outage - nobody is woken'
Assert (@($a2.Events).Count -eq 1 -and $a2.Events[0].Kind -eq 'Down' -and $a2.Events[0].MemberId -eq 'm2' -and $a2.Events[0].Since -eq $t0) 'two checks in a row: the member is reported down, from when it was first seen down'
Assert (@($a3.Events).Count -eq 0) 'still down: not reported again'
Assert (@($a4.Events).Count -eq 1 -and $a4.Events[0].Kind -eq 'Up' -and [int]$a4.Events[0].DownFor.TotalMinutes -eq 12) 'online again: reported back, with how long it was down'
Assert (-not ($a2.Events | Where-Object MemberId -eq 'm3')) 'a member an admin disabled is never reported'
$aOther = Get-GLAlertEvents -Track $a1.Track -Live @{ m9 = [pscustomobject]@{ Status = 'Offline'; Cluster = 'C9'; Enabled = $true } } -OnlyClusterIds @('C9') -Now $t0
Assert ($aOther.Track['m2'].DownChecks -eq 1 -and @($aOther.Events).Count -eq 0) 'one cluster read again: the others keep their count - a member is not called down without being asked again'
$aNone = Get-GLAlertEvents -Track $a1.Track -Live $null
Assert (@($aNone.Events).Count -eq 0) 'no live status: nothing is reported'
$txt = Format-GLAlertText -Events $a2.Events -Live (& $liveAt 'Live' 'Offline') -ClusterNames @{ c1 = 'Contoso Prod Cluster' } -MemberNames @{ m2 = 'CTSGW-PRD02' }
Assert ($txt.Title -eq 'A gateway member is down' -and $txt.Lines[0] -eq 'CTSGW-PRD02 in Contoso Prod Cluster is offline since 10:00 - 1 of 2 members online' -and $txt.Severity -eq 'Down') "the alert names the member, its cluster and what is left ($($txt.Lines[0]))"
$txtUp = Format-GLAlertText -Events $a4.Events -Live (& $liveAt 'Live' 'Live') -ClusterNames @{ c1 = 'Contoso Prod Cluster' } -MemberNames @{ m2 = 'CTSGW-PRD02' }
Assert ($txtUp.Title -eq 'A gateway member is back online' -and $txtUp.Lines[0] -match 'back online, after 12 min - 2 of 2 members online') "and when it is back ($($txtUp.Lines[0]))"
$allDown = Format-GLAlertText -Events @([pscustomobject]@{ Kind = 'Down'; MemberId = 'm1'; ClusterId = 'c1'; Machine = 'GW-01'; Status = 'Timeout'; Since = $t0 }) -Live (& $liveAt 'Timeout' 'Offline')
Assert ($allDown.Lines[0] -match 'does not answer' -and $allDown.Lines[0] -match 'no member of the cluster is online') 'a cluster with no member left says so'
$card = New-GLAlertCard -Title $txt.Title -Lines $txt.Lines -Severity 'Down' -Version '9.9.9'
$cardJson = $card | ConvertTo-Json -Depth 20 -Compress
Assert ($cardJson -match '"contentType":"application/vnd.microsoft.card.adaptive"' -and $cardJson -match '"type":"AdaptiveCard"' -and $cardJson -match '"color":"Attention"' -and $cardJson -match 'CTSGW-PRD02 in Contoso Prod Cluster') 'Teams and Power Automate get an Adaptive Card, red for down'
foreach ($ok in 'https://prod-12.westeurope.logic.azure.com:443/workflows/abc/triggers/manual/paths/invoke?sig=x',
                'https://default1234.ab.environment.api.powerplatform.com:443/powerautomate/automations/direct/workflows/abc/triggers/manual/paths/invoke?sig=x') {
    Assert (-not (Test-GLWebhookUrl $ok)) "a Microsoft workflow address is taken ($(([uri]$ok).Host))"
}
foreach ($bad in 'http://prod-12.westeurope.logic.azure.com/x', 'https://logic.azure.com.evil.example/x', 'https://evil.example/?u=logic.azure.com',
                 'https://user@prod-1.logic.azure.com/x', 'not a url', '') {
    Assert ([bool](Test-GLWebhookUrl $bad)) "anything else is refused, with the reason: '$bad'"
}
if ($IsWindows) {
    $hook = 'https://prod-12.westeurope.logic.azure.com/workflows/abc?sig=SECRET123'
    $prot = Protect-GLText $hook
    Assert ($prot -and $prot -notmatch 'SECRET123' -and $prot -match '^[0-9a-f]+$' -and (Unprotect-GLText $prot) -eq $hook) 'the webhook address is kept encrypted for this Windows account, and read back'
    $alPath = Join-Path ([System.IO.Path]::GetTempPath()) ('gl-alerts-' + [guid]::NewGuid().ToString('N') + '.json')
    $alSet = New-GLDefaultSettings
    $alSet.Alerts = [ordered]@{ Desktop = $true; Sound = $false; WebhookProtected = $prot }
    $null = Save-GLSettings -Settings $alSet -Path $alPath
    $araw = Get-Content -Raw -LiteralPath $alPath
    $aback = Read-GLSettings -Path $alPath
    Assert ($araw -notmatch 'SECRET123' -and $araw -notmatch 'logic\.azure' -and $aback.Alerts.Desktop -and -not $aback.Alerts.Sound -and (Unprotect-GLText $aback.Alerts.WebhookProtected) -eq $hook) 'the settings file never holds the address readable; the choices come back'
    Remove-Item -LiteralPath $alPath -ErrorAction SilentlyContinue
    Assert ((Unprotect-GLText 'deadbeef') -eq '') 'an address that cannot be read back is as if none was set'
}
Enable-GLDemo
Send-GLWebhook -Url 'https://prod-1.logic.azure.com/x' -Body $card
Assert ((Get-GLDemoStore).WebhookPosts.Count -eq 1) 'in the demo an alert is kept, not sent - nothing leaves the computer'
Disable-GLDemo

# ============================================================================
Section 'Usernames and users (unofficial bulk endpoint)'
# ============================================================================
Reset-Calls
$script:Rules = @{
    'gatewayClusterDatasources?$expand=users' = [pscustomobject]@{
        value = @(
            [pscustomobject]@{ id = 'DS1'; credentialDetails = [pscustomobject]@{ publicCredentialProperties = '[{"name":"username","value":"DOM\\svc_sales"}]' }
                               users = @([pscustomobject]@{ emailAddress = 'jane@contoso.com'; datasourceAccessRight = 'Read' }) }
            [pscustomobject]@{ id = 'DS2'; credentialDetails = [pscustomobject]@{ publicCredentialProperties = $null }; users = @() })
        '@odata.nextLink' = 'https://api.powerbi.com/v2.0/myorg/me/gatewayClusterDatasources?page=2' }
    'gatewayClusterDatasources?page=2' = [pscustomobject]@{ value = @([pscustomobject]@{ id = 'DS3'; users = @([pscustomobject]@{ identifier = 'grp-id'; role = 'ReadOverrideEffectiveIdentity' }) }) }
}
$dir = Get-GLDatasourceDirectory -PbiToken 'p'
Assert ($dir.Count -eq 3) 'every page is read (follows @odata.nextLink)'
Assert ($dir['ds1'].Account -eq 'DOM\svc_sales') 'the credential username is read from publicCredentialProperties'
Assert ($dir['ds1'].Users[0].Principal -eq 'jane@contoso.com' -and $dir['ds1'].Users[0].Right -eq 'Read') 'users carry email and right'
Assert ($dir['ds2'].Account -eq '' -and $dir['ds2'].Users.Count -eq 0) 'a data source without credentials or users is still listed'
Assert ($dir['ds3'].Users[0].Principal -eq 'grp-id') 'a user without an email falls back to its identifier'

# ============================================================================
Section 'Bulk operations'
# ============================================================================
$items = @(
    [pscustomobject]@{ Id = 'C1'; Name = 'one';   Connectivity = 'OnPremisesGateway'; GatewayId = 'G1'; Privacy = 'Organizational'; Encryption = 'Encrypted' }
    [pscustomobject]@{ Id = 'C2'; Name = 'two';   Connectivity = 'OnPremisesGateway'; GatewayId = 'G1'; Privacy = 'Private'; Encryption = 'Any' }
    [pscustomobject]@{ Id = 'C3'; Name = 'cloud'; Connectivity = 'ShareableCloud' }
)
$who = @([pscustomobject]@{ Id = 'U1'; DisplayName = 'Jane'; Type = 'User' }, [pscustomobject]@{ Id = 'U2'; DisplayName = 'Joe'; Type = 'User' })

Reset-Calls
$script:Rules = @{ 'POST https://api.fabric.microsoft.com/v1/connections/C2/roleAssignments' = 'POST ... -> HTTP 409 : PrincipalAlreadyHasRole' }
$prog = @{ Cancel = $false }
$res = Invoke-GLBulkGrant -Items $items[0..1] -Principals $who -Role 'User' -FabricToken 'f' -Progress $prog
Assert ($res.Count -eq 4 -and $prog.Total -eq 4 -and $prog.Done -eq 4) 'grant: every connection x every principal, progress counted'
Assert (@($res | Where-Object { $_.Message -match 'already has access' }).Count -eq 2 -and @($res | Where-Object { -not $_.Ok }).Count -eq 0) 'grant: "already has access" is not reported as a failure'
$bodies = @($script:Calls | Where-Object Method -eq 'POST' | ForEach-Object { $_.Body.role })
Assert (($bodies | Select-Object -Unique) -eq 'User') 'grant: the chosen role is sent'

Reset-Calls
$script:Rules = @{
    'GET https://api.fabric.microsoft.com/v1/connections/C1/roleAssignments' = [pscustomobject]@{ value = @(
        [pscustomobject]@{ id = 'RA1'; role = 'User';  principal = [pscustomobject]@{ id = 'U1'; displayName = 'Jane' } }
        [pscustomobject]@{ id = 'RA2'; role = 'Owner'; principal = [pscustomobject]@{ id = 'OWNER'; displayName = 'Boss' } }) }
    'GET https://api.fabric.microsoft.com/v1/connections/C2/roleAssignments' = [pscustomobject]@{ value = @() }
}
$res = Invoke-GLBulkRevoke -Items $items[0..1] -Principals @($who[0]) -FabricToken 'f' -Progress @{ Cancel = $false }
$dels = @($script:Calls | Where-Object Method -eq 'DELETE')
Assert ($dels.Count -eq 1 -and $dels[0].Uri -like '*/roleAssignments/RA1') 'revoke: removes only the named principal, never the owner beside it'
Assert ($res[1].Message -eq 'none of them had access' -and $res[1].Ok) 'revoke: a connection they were never on is reported plainly'

Reset-Calls
$keys = @{ 'g1' = $pk }
$res = Invoke-GLBulkCredentials -Items $items -CredentialType Basic -Username 'u' -Password 'p' -PublicKeys $keys -PbiToken 't' -Progress @{ Cancel = $false }
$patches = @($script:Calls | Where-Object Method -eq 'PATCH')
Assert ($patches.Count -eq 2) 'credentials: one update per gateway connection'
Assert ($res[2].Ok -eq $false -and $res[2].Message -match 'skipped') 'credentials: a cloud connection is skipped and says so'
Assert ($patches[1].Body.credentialDetails.encryptedConnection -eq 'NotEncrypted' -and $patches[1].Body.credentialDetails.privacyLevel -eq 'Private') 'credentials: each connection keeps its own privacy and encryption'

Reset-Calls
$res = Invoke-GLBulkCredentials -Items @($items[0]) -CredentialType Basic -Username 'u' -Password 'p' -PublicKeys @{} -PbiToken 't' -Progress @{ Cancel = $false }
Assert (-not $res[0].Ok -and $res[0].Message -match 'public key' -and $script:Calls.Count -eq 0) 'credentials: an unknown gateway key fails that row and sends nothing'

# ---- backup before delete ----
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("gl-test-" + [guid]::NewGuid().ToString('N'))
$bk  = Join-Path $tmp 'sub\deleted.csv'
$raw = @{ 'C1' = [pscustomobject]@{ id = 'C1'; displayName = 'one'; connectionDetails = [pscustomobject]@{ type = 'SQL'; path = 's;d' } } }
$ras = @{ 'C1' = @([pscustomobject]@{ role = 'Owner'; principal = [pscustomobject]@{ id = 'P1'; type = 'User'; userDetails = [pscustomobject]@{ userPrincipalName = 'jane@contoso.com' } } })
          'C2' = $null }
$items[1] | Add-Member -NotePropertyName UserList -NotePropertyValue @('bob@contoso.com') -Force
$out = Backup-GLConnections -Items $items[0..1] -Raw $raw -Assignments $ras -Path $bk
Assert ((Test-Path $bk) -and $out -eq $bk) 'backup: written, creating the folder it needs'
$bb = [System.IO.File]::ReadAllBytes($bk)
Assert ($bb[0] -eq 0xEF -and $bb[1] -eq 0xBB -and $bb[2] -eq 0xBF) 'backup: UTF-8 with a BOM, so Excel shows accented names correctly'
$back = @(Import-Csv $bk)
Assert ($back.Count -eq 2 -and $back[0].Id -eq 'C1' -and $back[0].GatewayId -eq 'G1' -and $back[1].Privacy -eq 'Private') 'backup: one row per connection, with its details'
Assert ($back[0].Access -eq 'jane@contoso.com (User, Owner) [P1]') "backup: who had access, in which role, and their object id - for an account deleted later ($($back[0].Access))"
Assert ($back[1].Access -eq 'bob@contoso.com') 'backup: falls back to the users already loaded when access could not be read'
$def = $back[0].DefinitionJson | ConvertFrom-Json
Assert ($def.connectionDetails.path -eq 's;d') 'backup: the full connection definition survives as JSON'
Assert (-not ($back[0].PSObject.Properties.Name | Where-Object { $_ -match 'pass' })) 'backup: no password column - the API never returns one'

$blocker = Join-Path $tmp 'a-file'
Set-Content -Path $blocker -Value 'x'
$err = $null; try { Backup-GLConnections -Items $items[0..1] -Path (Join-Path $blocker 'x.csv') } catch { $err = $_.Exception.Message }
Assert ([bool]$err) 'backup: a location that cannot be written throws, so the delete never starts'

Reset-Calls
$err = $null; try { Invoke-GLBulkDelete -Items $items[0..1] -BackupPath (Join-Path $tmp 'missing.csv') -FabricToken 'f' -Progress @{ Cancel = $false } } catch { $err = $_.Exception.Message }
Assert ($err -match 'No backup' -and $script:Calls.Count -eq 0) 'delete: refuses without a backup file, sends nothing'

Reset-Calls
$err = $null; try { Invoke-GLBulkDelete -Items $items -BackupPath $bk -FabricToken 'f' -Progress @{ Cancel = $false } } catch { $err = $_.Exception.Message }
Assert ($err -match '1 connection\(s\) are not in the backup' -and $script:Calls.Count -eq 0) 'delete: refuses if even one connection is missing from the backup, sends nothing'

Reset-Calls
$prog = @{ Cancel = $false }
$script:Rules = @{ 'DELETE https://api.fabric.microsoft.com/v1/connections/C2' = 'DELETE ... -> HTTP 403 : Forbidden' }
$res = Invoke-GLBulkDelete -Items $items[0..1] -BackupPath $bk -FabricToken 'f' -Progress $prog
Assert ($res[0].Ok -and -not $res[1].Ok -and $res[1].Message -match '403') 'delete: with a backup, deletes - one failure is recorded and the run carries on'

Reset-Calls
$prog = @{ Cancel = $true }
$res = Invoke-GLBulkDelete -Items $items[0..1] -BackupPath $bk -FabricToken 'f' -Progress $prog
Assert ($res.Count -eq 0 -and $script:Calls.Count -eq 0) 'cancel: a cancelled run sends nothing more'
Remove-Item -Recurse -Force $tmp

Remove-Item function:Invoke-GLRequest
. $script -LoadOnly

$script:PG = @{}
function Invoke-GLParallelGet {
    param($Uris, $Token, $TimeoutSec, $Batch)
    $o = @{}
    foreach ($u in $Uris) { $o[$u] = $script:PG[($script:PG.Keys | Where-Object { $u -like "*$_*" } | Select-Object -First 1)] }
    return $o
}
$script:PG = @{
    'datasources/C1/status' = [pscustomobject]@{ Ok = $true; Status = 200; Body = $null; Error = $null }
    'datasources/C2/status' = [pscustomobject]@{ Ok = $false; Status = 400; Error = 'HTTP 400'
        Body = [pscustomobject]@{ error = [pscustomobject]@{ code = 'DM_GWPipeline_Gateway_DataSourceAccessError'
            pbi = [pscustomobject]@{ error = [pscustomobject]@{ details = @([pscustomobject]@{ detail = [pscustomobject]@{ value = 'Login failed for user' } }) } } } } }
}
$st = Test-GLConnectionsBulk -Items $items[0..1] -PbiToken 'p'
Assert ($st['C1'].Status -eq 'OK') 'bulk status: a working connection is OK'
Assert ($st['C2'].Status -eq 'Failed' -and $st['C2'].Detail -match 'Login failed for user') 'bulk status: the gateway''s own reason is pulled out of the error'
Remove-Item function:Invoke-GLParallelGet
. $script -LoadOnly     # a stand-in REPLACES the real function - load the real one back

$noBom = @([regex]::Matches((Get-Content $script -Raw), 'Export-Csv[^\r\n]*') | ForEach-Object Value | Where-Object { $_ -notmatch 'utf8BOM' })
Assert (-not $noBom) "every CSV the tool writes has a BOM for Excel $(if ($noBom) { '- not: ' + ($noBom -join ' | ') })"

$lost = $script:WorkerFunctions | Where-Object { -not (Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue) }
Assert (-not $lost) "every real function is back after the stand-ins $(if ($lost) { '- missing: ' + ($lost -join ', ') })"

# ============================================================================
Section 'Log files and change record'
# ============================================================================
$lf = Join-Path ([System.IO.Path]::GetTempPath()) ("gl-log-" + [guid]::NewGuid().ToString('N'))
Assert ((Get-GLSafeName 'Jane.Doe@Contoso.com') -eq 'jane.doe@contoso.com') 'user names make safe, lower-case file names'
Assert ((Get-GLSafeName 'a/b\c:d e') -eq 'a_b_c_d_e') 'characters a file name cannot hold are replaced'
Assert ((Split-Path -Leaf (Get-GLLogPath -Folder $lf -User 'jane@contoso.com' -Date ([datetime]'2026-10-10'))) -eq 'gatewaylens-2026-10-10-jane@contoso.com.log') 'one log file per day and user'
Assert ((Split-Path -Leaf (Get-GLChangePath -Folder $lf -User 'jane@contoso.com' -Date ([datetime]'2026-10-10'))) -eq 'changes-2026-10-jane@contoso.com.csv') 'one change record per month and user'

$lp = Get-GLLogPath -Folder $lf -User 'jane@contoso.com'
Assert (Write-GLLogFile -Path $lp -Level 'WARN' -Text "first line`nsecond line") 'the log file is written, creating its folder'
$ll = @(Get-Content $lp)
Assert ($ll[0] -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}  WARN   first line$' -and $ll[1] -match '^\s{28}second line$') 'entries are dated, levelled, and continuation lines indented'

foreach ($d in 40, 31, 5) { Set-Content -Path (Get-GLLogPath -Folder $lf -User 'jane@contoso.com' -Date (Get-Date).AddDays(-$d)) -Value 'x' }
Set-Content -Path (Get-GLLogPath -Folder $lf -User 'joe@contoso.com' -Date (Get-Date).AddDays(-90)) -Value 'x'
Set-Content -Path (Join-Path $lf 'changes-2020-01-jane@contoso.com.csv') -Value 'x'
$gone = Remove-GLOldLogs -Folder $lf -User 'jane@contoso.com' -Days 30
$left = @(Get-ChildItem $lf | ForEach-Object Name)
Assert ($gone -eq 2) "logs older than 30 days are removed ($gone)"
Assert ($left -contains 'gatewaylens-{0:yyyy-MM-dd}-joe@contoso.com.log' -f (Get-Date).AddDays(-90)) 'someone else''s logs in a shared folder are left alone'
Assert ($left -contains 'changes-2020-01-jane@contoso.com.csv') 'change records are never removed, however old'

$cf = Join-Path $lf 'audit'
$au = New-GLAudit -Folder $cf -User 'jane@contoso.com' -Tenant 'contoso' -Version '9.9.9'
Assert ($au.RunId -match '^[0-9a-f]{8}$') 'each run gets a short id that ties its rows together'
Assert ($null -eq (Test-GLChangeRecord -Audit $au)) 'the change record can be written'
Write-GLChange -Audit $au -Action 'Grant access' -Result Done -Target 'Sales, "EU"' -TargetId 'C1' -Principal 'Joe' -Role 'User' -Message "two`nlines"
Write-GLChange -Audit $au -Action 'Remove access' -Result Failed -Target 'HR' -Message 'HTTP 403'
Write-GLChange -Audit $null -Action 'Grant access' -Result Done -Target 'never written'
$cp = Get-GLChangePath -Folder $cf -User 'jane@contoso.com'
$raw = [System.IO.File]::ReadAllBytes($cp)
Assert ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) 'the change record starts with a UTF-8 BOM, so Excel shows accents correctly'
$cr = @(Import-Csv $cp)
Assert ($cr.Count -eq 2 -and $cr[0].Target -eq 'Sales, "EU"' -and $cr[0].Message -eq "two`nlines") 'commas, quotes and line breaks survive the CSV'
Assert ($cr[0].User -eq 'jane@contoso.com' -and $cr[0].RunId -eq $au.RunId -and $cr[0].App -eq '9.9.9' -and $cr[0].TimeUtc -match 'Z$') 'every row carries who, when (UTC), which run and which version'
Assert (@((Get-Content $cp -Raw) -split "`n" | Where-Object { $_ -like '"TimeUtc"*' }).Count -eq 1) 'the header is written once'

$blk = Join-Path $lf 'a-file'; Set-Content $blk 'x'
$bad = New-GLAudit -Folder (Join-Path $blk 'sub') -User 'jane' -Tenant 't' -Version 'v'
Assert ([bool](Test-GLChangeRecord -Audit $bad)) 'an unwritable change record is reported before any bulk run starts'

# several writers at once - the shared-folder case
$par = New-GLAudit -Folder (Join-Path $lf 'parallel') -User 'team' -Tenant 't' -Version 'v'
$jobs = foreach ($w in 1..4) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript({ param($S, $A, $W) . $S -LoadOnly; foreach ($i in 1..25) { Write-GLChange -Audit $A -Action 'Grant access' -Result Done -Target "w$W-$i" } })
    [void]$ps.AddArgument($script).AddArgument($par).AddArgument($w)
    [pscustomobject]@{ PS = $ps; H = $ps.BeginInvoke() }
}
foreach ($j in $jobs) { $null = $j.PS.EndInvoke($j.H); $j.PS.Dispose() }
$pr = @(Import-Csv (Get-GLChangePath -Folder $par.Folder -User 'team'))
$distinct = @($pr | ForEach-Object Target | Sort-Object -Unique).Count
Assert ($pr.Count -eq 100 -and $distinct -eq 100) "four writers at once: all 100 rows intact, none lost or merged ($($pr.Count) rows, $distinct distinct)"

# reading back, everyone's files together
$au2 = New-GLAudit -Folder $cf -User 'joe@contoso.com' -Tenant 'contoso' -Version '9.9.9'
Start-Sleep -Milliseconds 1100
Write-GLChange -Audit $au2 -Action 'Disable member' -Result Done -Target 'GW01' -Gateway 'Cluster A'
$all = Read-GLChanges -Folder $cf
Assert ($all.Count -eq 3 -and $all[0].User -eq 'joe@contoso.com') 'everyone''s records are read together, newest first'
Assert ($all[0].When -is [datetime] -and $all[0].When.Kind -eq 'Local') 'times are shown in your own time zone'
$empty = Read-GLChanges -Folder (Join-Path $lf 'nothing-here')
Assert ($empty -is [array] -and $empty.Count -eq 0) 'no records yet is an empty list, not an error'

# ============================================================================
Section 'Every bulk change is recorded'
# ============================================================================
$script:Calls = [System.Collections.Generic.List[object]]::new()
$script:Rules = @{}
function Invoke-GLRequest {
    param($Method = 'GET', $Uri, $Token, $Body, $MaxRetry)
    $script:Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body })
    foreach ($k in ($script:Rules.Keys | Sort-Object Length -Descending)) {
        if ("$Method $Uri" -like "*$k*") { $v = $script:Rules[$k]; if ($v -is [string]) { throw $v }; return $v }
    }
    return $null
}
$bf  = Join-Path $lf 'bulk'
$ba  = New-GLAudit -Folder $bf -User 'jane@contoso.com' -Tenant 'contoso' -Version 'v'
$bi  = @(
    [pscustomobject]@{ Id = 'C1'; Name = 'one'; Connectivity = 'OnPremisesGateway'; Gateway = 'GA'; GatewayId = 'G1'; Privacy = 'Organizational'; Encryption = 'Encrypted' }
    [pscustomobject]@{ Id = 'C2'; Name = 'two'; Connectivity = 'ShareableCloud'; Gateway = ''; GatewayId = '' }
)
$who = @([pscustomobject]@{ Id = 'U1'; DisplayName = 'Joe'; Type = 'User' })
$script:Rules = @{ 'POST https://api.fabric.microsoft.com/v1/connections/C2/roleAssignments' = 'POST -> HTTP 409 : PrincipalAlreadyHasRole' }
$null = Invoke-GLBulkGrant -Items $bi -Principals $who -Role 'UserWithReshare' -FabricToken 'f' -Progress @{ Cancel = $false } -Audit $ba
$script:Rules = @{ 'GET https://api.fabric.microsoft.com/v1/connections/C1/roleAssignments' = [pscustomobject]@{ value = @(
    [pscustomobject]@{ id = 'RA1'; role = 'UserWithReshare'; principal = [pscustomobject]@{ id = 'U1'; displayName = 'Joe'; type = 'User' } }) } }
$null = Invoke-GLBulkRevoke -Items $bi -Principals $who -FabricToken 'f' -Progress @{ Cancel = $false } -Audit $ba
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$pk  = [pscustomobject]@{ modulus = [Convert]::ToBase64String($rsa.ExportParameters($false).Modulus); exponent = 'AQAB' }
$null = Invoke-GLBulkCredentials -Items $bi -CredentialType Basic -Username 'svc_report' -Password 'Tr0ub4dor&3' -PublicKeys @{ 'g1' = $pk } -PbiToken 't' -Progress @{ Cancel = $false } -Audit $ba
$rec = @(Import-Csv (Get-GLChangePath -Folder $bf -User 'jane@contoso.com'))
$g = @($rec | Where-Object Action -eq 'Grant access')
Assert ($g.Count -eq 2 -and $g[0].Result -eq 'Done' -and $g[0].PrincipalId -eq 'U1' -and $g[0].Role -eq 'UserWithReshare' -and $g[0].PrincipalType -eq 'User') 'grant: principal, id, type and role are recorded as columns'
Assert ($g[1].Result -eq 'NoChange' -and $g[1].Message -eq 'already had access') 'grant: "already had access" is recorded as no change'
$r = @($rec | Where-Object Action -eq 'Remove access')
Assert ($r[0].Result -eq 'Done' -and $r[0].Role -eq 'UserWithReshare' -and $r[0].PrincipalId -eq 'U1') 'remove: the role that was removed is recorded'
Assert ($r[1].Result -eq 'NoChange') 'remove: a connection they were not on is recorded as no change'
$c = @($rec | Where-Object Action -eq 'Update credentials')
Assert ($c[0].Result -eq 'Done' -and $c[0].Details -match 'Username=svc_report' -and $c[1].Result -eq 'Skipped') 'credentials: done and skipped are both recorded, with the username'
Assert (-not ((Get-Content (Get-GLChangePath -Folder $bf -User 'jane@contoso.com') -Raw) -match 'Tr0ub4dor')) 'the password is nowhere in the change record'
Assert (@($rec | Select-Object -ExpandProperty RunId -Unique).Count -eq 1) 'one run, one run id on every row'

Remove-Item function:Invoke-GLRequest
. $script -LoadOnly

Remove-Item -Recurse -Force $lf

# ============================================================================
Section 'Demo mode - the whole tool end to end, against fictional Contoso'
# ============================================================================
$keepMode = $script:AuthMode; $keepUser = $script:SignedInAs; $keepTenant = $script:TenantShown
Enable-GLDemo
$s = Get-GLDemoStore
$s.Fast = $true
$T = 'demo-token'
$st0 = [long]([System.AppDomain]::CurrentDomain.GetData('GatewayLens.Stats').Calls)
$null = Invoke-GLRequest -Uri 'https://api.fabric.microsoft.com/v1/gateways' -Token $T
Assert ([long]([System.AppDomain]::CurrentDomain.GetData('GatewayLens.Stats').Calls) -eq $st0 + 1) 'every call to Microsoft is counted, for the meter - in the demo too'
Assert ($s.Users.Count -eq 6 -and $s.Connections.Count -eq 27 -and $s.Gateways.Count -eq 6) "the company is built: 6 people, 6 gateways, 27 connections ($($s.Users.Count), $($s.Gateways.Count), $($s.Connections.Count))"
$allIds = @($s.Connections | ForEach-Object id) + @($s.Gateways | ForEach-Object id) + @($s.Users | ForEach-Object id)
Assert (@($allIds | Sort-Object -Unique).Count -eq $allIds.Count) 'every id is unique'
Assert ((New-GLDemoId 'x') -eq (New-GLDemoId 'x') -and (Test-GLGuid (New-GLDemoId 'x'))) 'demo ids are stable and shaped like real ones'
Assert ((Get-GLToken Fabric) -eq 'demo-token') 'no sign-in: the demo hands out its own token'

$gd   = Get-GLGatewayData -FabricToken $T -PbiToken $T -LiveStatus
$grow = ConvertTo-GLGatewayRows -Gateways $gd.Gateways -Members $gd.Members -Live $gd.Live
$gs   = @{}; foreach ($r in $grow) { $gs[$r.Name] = Get-GLGatewayState $r.Online }
Assert ($gs['Contoso Prod Cluster'] -eq 'Online' -and $gs['Contoso Finance Cluster'] -eq 'Partial' -and $gs['Legacy Warehouse Gateway'] -eq 'Offline' -and $gs['Contoso Test Cluster'] -eq 'Partial') 'gateways in every state: online, partly online, offline'
Assert (@($gd.Live.Values | Where-Object Status -eq 'Timeout').Count -eq 1) 'and one member that does not answer'

# Microsoft's pages, from the demo's own copies - nothing leaves the computer
$dr = Get-GLGatewayReleases
Assert ($dr.Newest -eq [version]'3000.290.10' -and @($dr.Supported).Count -eq 6 -and $dr.Published -and $dr.Log.Count -eq 0) "the demo answers both Microsoft pages ($($dr.Newest), $(@($dr.Supported).Count) supported)"
$dt = ConvertTo-GLGatewayTiles -Rows $grow -Members $gd.Members -DownSince @{} -VnetSkipped -Live $gd.Live -Releases $dr
$db = @{}; foreach ($x in $dt) { $db[$x.Name] = $x.Badge }
Assert ($db['Contoso Prod Cluster'] -eq '' -and $db['Contoso Test Cluster'] -eq 'UPDATE AVAILABLE' -and $db['Legacy Warehouse Gateway'] -eq 'UNSUPPORTED VERSION' -and $db['Contoso Finance Cluster'] -eq 'MIXED VERSIONS') "the demo shows every version badge ($(($db.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '))"

# VNet gateways: a status check starts a sleeping one, so nothing asks unless told to
Assert ($s.VnetWoken -eq 0 -and -not ($gd.Live.Values | Where-Object { $_.Cluster -eq ($s.Gateways | Where-Object type -eq 'VirtualNetwork').id.ToLowerInvariant() })) 'live status leaves VNet gateways alone unless asked - a status check would wake them'
$vt = ConvertTo-GLGatewayTiles -Rows $grow -Members $gd.Members -DownSince @{} -VnetSkipped -Live $gd.Live
$vtile = $vt | Where-Object Type -eq 'VirtualNetwork'
Assert ($vtile.Status -eq 'VNet' -and $vtile.MembersText -match 'not woken') 'a skipped VNet gateway''s tile says it was not checked, and why'
$gdv  = Get-GLGatewayData -FabricToken $T -PbiToken $T -LiveStatus -CheckVnet
$vrows = ConvertTo-GLGatewayRows -Gateways $gdv.Gateways -Members $gdv.Members -Live $gdv.Live
$vrow  = $vrows | Where-Object Type -eq 'VirtualNetwork'
$vt2  = ConvertTo-GLGatewayTiles -Rows @($vrow) -Members $gdv.Members -DownSince @{} -Live $gdv.Live
Assert ($s.VnetWoken -eq 2 -and $vrow.Online -eq '2 / 2' -and $vt2[0].Status -eq 'Online' -and $vt2[0].MembersText -like 'VNet - 2 of 2*') "asked to check VNet gateways: both members are asked, and the tile shows their status (asked $($s.VnetWoken), $($vrow.Online))"
$s.VnetWoken = 0

$cd   = Get-GLConnectionData -FabricToken $T
$crow = ConvertTo-GLConnectionRows -Connections $cd.Connections -GatewayNames (Get-GLGatewayNameMap -Gateways $cd.Gateways)
Add-GLDirectoryInfo -Rows $crow -Directory (Get-GLDatasourceDirectory -PbiToken $T)
$byN  = @{}; foreach ($r in $crow) { $byN[$r.Name] = $r }
$hr   = $byN['HR Core']
Assert ($crow.Count -eq 27 -and $hr.Gateway -eq 'Contoso Prod Cluster' -and $hr.Account -eq 'CONTOSO\svc_hr') 'connections come with gateway names and the account in their credentials'
Set-GLCleanupReasons -Rows $crow
$cuTiles = ConvertTo-GLGatewayTiles -Rows $grow -Members $gd.Members -DownSince @{} -VnetSkipped -Live $gd.Live -ConnectionCounts (Get-GLConnectionCounts -Rows $crow) -CleanupCounts (Get-GLCleanupCounts -Rows $crow)
Assert (@($crow | Where-Object CanGo).Count -ge 2 -and @($cuTiles | Where-Object { $_.ConnectionsText -match '\d unused$' }).Count -ge 1) "the demo has connections that can go, and a tile says how many ($(@($crow | Where-Object CanGo).Count))"
# the directory gives only object ids, like a real tenant - the names come from Graph
$ddir   = Get-GLDatasourceDirectory -PbiToken $T
$dids   = Get-GLDirectoryPrincipalIds -Directory $ddir
$dnames = Get-GLPrincipalNames -Ids $dids -GraphToken $T
$tomKey = ([string]$s.Deleted[0].id).ToLowerInvariant()
$janeU  = $s.Users[1]
Assert ($dids.Count -ge 5 -and $dnames[$tomKey].Missing -and -not $dnames[([string]$janeU.id).ToLowerInvariant()].Missing) "an id Graph answers for but does not know is remembered as not in Entra ID ($($dids.Count) ids)"
Add-GLDirectoryInfo -Rows $crow -Directory $ddir -Names $dnames
$sdw = $byN['Sales DW']; $apa = $byN['AP Archive']
Assert ($sdw.UserNames -match [regex]::Escape($janeU.userPrincipalName) -and $sdw.UserNames -notmatch '[0-9a-f]{8}-[0-9a-f]{4}') "the users column shows emails, not ids ($($sdw.UserNames))"
Assert ($apa.UnknownUsers -eq 1 -and $apa.UserNames -match 'not in Entra ID' -and $sdw.UnknownUsers -eq 0) 'a deleted account that still has access is marked as not in Entra ID'
$byDisplay = Select-GLConnections -Rows $crow -User $janeU.displayName
Assert (@($byDisplay | Where-Object Name -eq 'Sales DW').Count -eq 1) "the User filter finds people by their display name too ('$($janeU.displayName)')"
$orphans = Select-GLConnections -Rows $crow -Show 'Access by accounts not in Entra ID' -IncludeCloud
Assert ((@($orphans | ForEach-Object Name | Sort-Object) -join ',') -eq 'AP Archive,Treasury Oracle') "Show > Access by accounts not in Entra ID lists the connections a deleted account can still use ($(@($orphans | ForEach-Object Name) -join ', '))"
$apaRoles = Get-GLRoleAssignments -Kind connections -Id $apa.Id -FabricToken $T
$apaRows  = ConvertTo-GLRoleRows -Assignments $apaRoles -Names $dnames
$goneRow  = @($apaRows | Where-Object NotInEntra)
Assert ($goneRow.Count -eq 1 -and $goneRow[0].Principal -eq 'Tom Wright (deleted)' -and $goneRow[0].Detail -match 'tom\.wright@contoso\.com - deleted from Microsoft Entra ID on \d{4}-\d\d-\d\d' -and $goneRow[0].Detail -match 'portal' -and (Format-GLAccessList $apaRows) -match 'not in Entra ID\] \(Owner\)') "the access panel and the log say who is not in Entra ID, and that the portal leaves them out ($($goneRow[0].Principal): $($goneRow[0].Detail))"
# what Graph can say: deleted lately - still in the recycle bin, with a name; long gone; or nothing
$oldId = ([string]$s.Deleted[1].id).ToLowerInvariant()
$why   = Get-GLMissingPrincipals -Ids @($tomKey, $oldId) -GraphToken $T
Assert ($why[$tomKey].State -eq 'Deleted' -and $why[$tomKey].Name -eq 'Tom Wright' -and $why[$tomKey].DeletedOn -is [datetime] -and $why[$oldId].State -eq 'Gone') "an account deleted lately is named from the recycle bin; one gone for good is called deleted, without a name ($($why[$tomKey].State), $($why[$oldId].State))"
$oldLabel = Get-GLPrincipalLabel -Principal ([pscustomobject]@{ id = $oldId; type = 'User' }) -Names $why
$unkLabel = Get-GLPrincipalLabel -Principal ([pscustomobject]@{ id = 'x1'; type = 'User' }) -Names @{ x1 = [pscustomobject]@{ Name = ''; Email = ''; Missing = $true; State = 'Unknown' } }
Assert ($oldLabel.Name -eq 'Deleted account' -and $oldLabel.Key -eq $oldId -and $unkLabel.Name -eq 'Not found in Microsoft Entra ID' -and (Get-GLMissingText $unkLabel) -match 'would not say') 'an account Graph would not tell about is never called deleted - and each is known by its id only'
Assert ($apa.Users -eq '2' -and $apa.UserNames -match '\+1 not in Entra ID') "the Users column counts whom the portal shows; the account not in Entra ID is added apart ($($apa.Users): $($apa.UserNames))"
$prodGwId    = [string](@($s.Gateways | Where-Object { $_.displayName -like '*Prod*' })[0].id)
$prodGwRoles = Get-GLRoleAssignments -Kind gateways -Id $prodGwId -FabricToken $T
$prodNames   = Get-GLPrincipalNames -Ids @($prodGwRoles | ForEach-Object { [string]$_.principal.id }) -GraphToken $T
$prodRows    = ConvertTo-GLRoleRows -Assignments $prodGwRoles -Names $prodNames
Assert (@($prodRows | Where-Object NotInEntra).Count -eq 1 -and @($prodRows | Where-Object { -not $_.NotInEntra }).Count -eq 3) 'the Prod gateway: three people the portal shows, and an admin who left years ago'
# the countdown on the Gateways tab
$at = Get-Date '2026-10-12 10:00:00'
Assert ((Get-GLCountdownText -LastRefresh $at -NextAt $at.AddSeconds(102) -Now $at) -eq 'Updated 10:00:00   |   next in 1:42' -and
        (Get-GLCountdownText -LastRefresh $at -NextAt $null -Now $at) -eq 'Updated 10:00:00' -and
        (Get-GLCountdownText -LastRefresh $at -NextAt $at.AddSeconds(-5) -Now $at) -match 'next in 0:00' -and
        (Get-GLCountdownText -LastRefresh $at -NextAt $at.AddSeconds(30) -Busy $true -Now $at) -match 'refreshing now') 'the Gateways tab says when it was updated and counts down to the next refresh'

$idle  = @($crow | Where-Object { $_.UnusedDays -gt 30 })
$never = @($crow | Where-Object { -not $_.LastUsed })
Assert (@($crow | Where-Object Created).Count -eq 27 -and $idle.Count -ge 2 -and $never.Count -ge 2) "the demo has connection recency: all created, $($idle.Count) idle for over a month, $($never.Count) never used"

$onp = @($crow | Where-Object Connectivity -eq 'OnPremisesGateway')
$st  = Test-GLConnectionsBulk -Items $onp -PbiToken $T
Assert ($st[$hr.Id].Detail -eq "DM_GWPipeline_Gateway_DataSourceAccessError: Login failed for user 'CONTOSO\svc_hr'.") 'a failed login reads as the gateway''s own words'
Assert ($st[$byN['Legacy Orders'].Id].Detail -match 'offline or could not be reached') 'a connection on an offline gateway says so'
Assert (@($st.Values | Where-Object Status -eq 'Failed').Count -eq 5 -and @($st.Values | Where-Object Status -eq 'OK').Count -eq ($onp.Count - 5)) 'five failures, the rest OK'

$keys = @{}; foreach ($g in $cd.Gateways) { if ($g.publicKey) { $keys[([string]$g.id).ToLowerInvariant()] = $g.publicKey } }
$dl = Join-Path ([System.IO.Path]::GetTempPath()) ("gl-demo-" + [guid]::NewGuid().ToString('N'))
$au = New-GLAudit -Folder $dl -User 'demo.user@contoso.com' -Tenant 'contoso.example (demo)' -Version 'test'
$r1 = Invoke-GLBulkCredentials -Items @($hr) -CredentialType Windows -Username 'CONTOSO\svc_hr' -Password 'wrong' -PublicKeys $keys -PbiToken $T -Progress @{ Cancel = $false } -Audit $au
Assert (-not $r1[0].Ok -and $r1[0].Message -match "Login failed for user 'CONTOSO\\svc_hr'") 'wrong password: the gateway decrypts it, tries it, and refuses'
$r2 = Invoke-GLBulkCredentials -Items @($hr) -CredentialType Windows -Username 'CONTOSO\svc_hr' -Password 'Correct horse 9' -PublicKeys $keys -PbiToken $T -Progress @{ Cancel = $false } -Audit $au
$st2 = Test-GLConnectionsBulk -Items @($hr) -PbiToken $T
Assert ($r2[0].Ok -and $st2[$hr.Id].Status -eq 'OK') 'right password: accepted, and the connection now tests OK'
$finKey = $keys[([string]($cd.Gateways | Where-Object displayName -eq 'Contoso Finance Cluster').id).ToLowerInvariant()]
$err = $null; try { Set-GLConnectionCredential -GatewayId $hr.GatewayId -ConnectionId $hr.Id -PublicKey $finKey -CredentialType Basic -Username 'u' -Password 'p' -PbiToken $T } catch { $err = $_.Exception.Message }
Assert ($err -match 'could not decrypt') 'credentials encrypted for a different gateway are refused - the demo really decrypts'

# The portal's way: one encrypted copy per gateway member, and the username stays
# readable. The documented way keeps only the encrypted copy - the Account goes.
$accountOf = { param($Id) $dd = Get-GLDatasourceDirectory -PbiToken $T; $dd[([string]$Id).ToLowerInvariant()].Account }
$pds = Invoke-GLRequest -Uri "https://api.powerbi.com/v2.0/myorg/me/gatewayClusterDatasources/$($hr.Id)" -Token $T
$mk  = @($pds.memberGatewayPublicKeys.PSObject.Properties)
$pk  = ConvertFrom-GLRsaXmlKey -Base64Xml ([string]$mk[0].Value)
Assert ($mk.Count -eq 3 -and $pk.modulus.Length -gt 300 -and $pk.exponent -eq 'AQAB') "a member key from the portal's API reads as a modulus and exponent ($($mk.Count) members)"
$beforeDoc = [int]$s.DocumentedCredentialCalls
$rp = Invoke-GLBulkCredentials -Items @($hr) -CredentialType Windows -Username 'CONTOSO\svc_hr2' -Password 'Correct horse 9' -PublicKeys $keys -PbiToken $T -Progress @{ Cancel = $false } -Audit $au -PortalWay
Assert ($rp[0].Ok -and $rp[0].Way -eq 'portal' -and (& $accountOf $hr.Id) -eq 'CONTOSO\svc_hr2' -and [int]$s.DocumentedCredentialCalls -eq $beforeDoc) "like the portal: every member gets the credentials, and the Account stays readable ($(& $accountOf $hr.Id))"
$rd = Invoke-GLBulkCredentials -Items @($hr) -CredentialType Windows -Username 'CONTOSO\svc_hr' -Password 'Correct horse 9' -PublicKeys $keys -PbiToken $T -Progress @{ Cancel = $false } -Audit $au
Assert ($rd[0].Ok -and $rd[0].Way -eq 'documented' -and -not (& $accountOf $hr.Id)) 'the documented way works too, but the readable username is gone - as on a real tenant'
$rf = Invoke-GLBulkCredentials -Items @($hr) -CredentialType Windows -Username 'CONTOSO\svc_hr' -Password 'Correct horse 9' -PublicKeys $keys -PbiToken $T -Progress @{ Cancel = $false } -Audit $au -PortalWay -PortalMethod 'POST'
Assert ($rf[0].Ok -and $rf[0].Way -eq 'documented' -and $rf[0].Message -match "portal's way was refused \(HTTP 405\)") "a portal endpoint that refuses the request changes nothing, so the documented way is used - and says so ($($rf[0].Message))"
$beforeDoc = [int]$s.DocumentedCredentialCalls
$rw = Invoke-GLBulkCredentials -Items @($hr) -CredentialType Windows -Username 'CONTOSO\svc_hr' -Password 'wrong' -PublicKeys $keys -PbiToken $T -Progress @{ Cancel = $false } -Audit $au -PortalWay
Assert (-not $rw[0].Ok -and $rw[0].Message -match 'Login failed' -and [int]$s.DocumentedCredentialCalls -eq $beforeDoc) 'a wrong password is the gateway''s answer, not a refusal: it fails, and is not sent the other way as well'
$recCsv = Get-ChildItem -LiteralPath $dl -Recurse -Filter 'changes-*.csv' | Select-Object -First 1
$recTxt = if ($recCsv) { Get-Content -LiteralPath $recCsv.FullName -Raw } else { '' }
Assert ($recTxt -match 'Way=like the portal \(unofficial\)' -and $recTxt -match 'Way=documented API' -and $recTxt -match "portal's way was refused" -and $recTxt -notmatch 'Correct horse') 'the change record says which way each update went, and never the password'
Assert ((Test-GLPortalWayRefused 'PUT https://x -> HTTP 405 : MethodNotAllowed') -and (Test-GLPortalWayRefused 'PORTAL-NOT-USABLE: no keys') -and -not (Test-GLPortalWayRefused 'PUT https://x -> HTTP 400 : DM_GWPipeline_Gateway_DataSourceAccessError: Login failed') -and -not (Test-GLPortalWayRefused 'PUT https://x -> no response : timed out')) 'only a refusal of the request itself lets the documented way be tried - not a gateway answer, not silence'

$jane = Resolve-GLPrincipal -Value 'jane.doe@contoso.com' -Type User -GraphToken $T
$grp  = Resolve-GLPrincipal -Value 'Finance Analysts' -Type Group -GraphToken $T
Assert ($jane.DisplayName -eq 'Jane Doe <jane.doe@contoso.com>' -and $grp.DisplayName -eq 'Finance Analysts <finance-analysts@contoso.com>') 'people and groups are found by email and by name'
$err = $null; try { Resolve-GLPrincipal -Value 'nobody@contoso.com' -Type User -GraphToken $T } catch { $err = $_.Exception.Message }
Assert ($err -match "No User found for 'nobody@contoso.com'") 'someone who does not exist is refused by name'

$two = @($byN['Product Catalog'], $byN['Sales DW'])
$who = @([pscustomobject]@{ Id = $jane.Id; DisplayName = $jane.DisplayName; Type = 'User' })
$g1 = Invoke-GLBulkGrant -Items $two -Principals $who -Role 'User' -FabricToken $T -Progress @{ Cancel = $false } -Audit $au
Assert ($g1[0].Message -like 'granted User*' -and $g1[1].Message -like '*already has User') 'grant: new access, and "already has User" where she had it - checked before anything is sent'
$v1 = Invoke-GLBulkRevoke -Items $two -Principals $who -FabricToken $T -Progress @{ Cancel = $false } -Audit $au
$ras  = Get-GLRoleAssignments -Kind connections -Id $byN['Sales DW'].Id -FabricToken $T
$left = @($ras | Where-Object { $_.principal.id -eq $jane.Id })
Assert (@($v1 | Where-Object Ok).Count -eq 2 -and $left.Count -eq 0) 'remove: gone from both'
$ras    = Get-GLRoleAssignments -Kind connections -Id $byN['Web API Sandbox'].Id -FabricToken $T
$owners = @($ras | Where-Object role -eq 'Owner')
$err = $null
foreach ($o in $owners) { try { Remove-GLRoleAssignment -Kind connections -Id $byN['Web API Sandbox'].Id -AssignmentId $o.id -FabricToken $T } catch { $err = $_.Exception.Message } }
Assert ($err -match 'LastOwnerCannotBeRemoved') 'the last owner of a connection cannot be removed'

$prodGw = $cd.Gateways | Where-Object displayName -eq 'Contoso Prod Cluster'
$pm = @($s.Members[$prodGw.id])
$mrw = ConvertTo-GLMemberRows -GatewayName $prodGw.displayName -Members $pm -Live $null
$bm = Invoke-GLBulkMembers -Gateway ([pscustomobject]@{ Id = $prodGw.id; Name = $prodGw.displayName }) -Members @($mrw[0], $mrw[2]) -Enabled $false -FabricToken $T -Progress @{ Cancel = $false } -Audit $au
Assert (@($bm | Where-Object Ok).Count -eq 2 -and -not $pm[0].enabled -and $pm[1].enabled -and -not $pm[2].enabled) 'several members disabled in one run, the one not chosen left alone'
$bm = Invoke-GLBulkMembers -Gateway ([pscustomobject]@{ Id = $prodGw.id; Name = $prodGw.displayName }) -Members @($mrw[0], $mrw[2]) -Enabled $true -FabricToken $T -Progress @{ Cancel = $false } -Audit $au
Assert ($pm[0].enabled -and $pm[2].enabled) 'and enabled again'
$one = Get-GLLiveStatus -PbiToken $T -OnlyClusterIds @($prodGw.id)
Assert ($one.Count -eq $pm.Count -and -not ($one.Values | Where-Object { $_.Cluster -ne ([string]$prodGw.id).ToLowerInvariant() })) "live status for one cluster asks only its members ($($one.Count))"
$m2 = $s.Members[$prodGw.id][1]
Set-GLMemberEnabled -GatewayId $prodGw.id -MemberId $m2.id -Enabled $false -FabricToken $T
Assert ($m2.enabled -eq $false) 'a member is disabled'
Set-GLMemberEnabled -GatewayId $prodGw.id -MemberId $m2.id -Enabled $true -FabricToken $T

$testGw = $cd.Gateways | Where-Object displayName -eq 'Contoso Test Cluster'
$made = [pscustomobject]@{ id = (New-GLDemoId 'connection|Scratch DB'); displayName = 'Scratch DB'; connectivityType = 'OnPremisesGateway'; gatewayId = $testGw.id
    connectionDetails = [pscustomobject]@{ type = 'Sql'; path = 'sqltst02.contoso.local;Scratch' }; privacyLevel = 'Organizational'
    credentialDetails = [pscustomobject]@{ credentialType = 'Basic'; singleSignOnType = 'None'; connectionEncryption = 'Encrypted'; skipTestConnection = $false } }
$s.Connections.Add($made)

$bk = Join-Path $dl 'backup.csv'
$mi = ConvertTo-GLConnectionRows -Connections @($made) -GatewayNames (Get-GLGatewayNameMap -Gateways $cd.Gateways)
$null = Backup-GLConnections -Items $mi -Path $bk
$d1 = Invoke-GLBulkDelete -Items $mi -BackupPath $bk -FabricToken $T -Progress @{ Cancel = $false } -Audit $au
Assert ($d1[0].Ok -and -not ($s.Connections | Where-Object displayName -eq 'Scratch DB')) 'delete, after its backup: gone'

Assert ((Resolve-GLHostAddress -Machine 'CTSGW-PRD01') -match '^10\.20\.\d+\.\d+;CTSGW-PRD01$' -and (Resolve-GLHostAddress -Machine 'LEGGW-01') -eq 'UNKNOWN;LEGGW-01') 'Resolve IPs works in the demo - with one machine missing from DNS'

$rec = @(Import-Csv (Get-GLChangePath -Folder $dl -User 'demo.user@contoso.com'))
$acts = @($rec | Select-Object -ExpandProperty Action -Unique)
$want = 'Update credentials', 'Grant access', 'Remove access', 'Delete connection'
Assert (-not ($want | Where-Object { $acts -notcontains $_ }) -and -not ((Get-Content (Get-GLChangePath -Folder $dl -User 'demo.user@contoso.com') -Raw) -match 'Correct horse')) "every kind of demo change is in the change record - and no password ($($acts -join ', '))"

# ---- hand over access: Joe Smith is leaving ----
$joeU  = $s.Users | Where-Object displayName -eq 'Joe Smith'
$anaU  = $s.Users | Where-Object displayName -eq 'Ana Novak'
$janeU = $s.Users | Where-Object displayName -eq 'Jane Doe'
$meU   = $s.Users | Where-Object userPrincipalName -eq $s.Me
$prodG = $cd.Gateways | Where-Object displayName -eq 'Contoso Prod Cluster'
$allConn = @($crow | ForEach-Object { [pscustomobject]@{ Kind = 'connections'; Id = $_.Id; Name = $_.Name; Gateway = $_.Gateway; GatewayId = $_.GatewayId } })
$allGw   = @($cd.Gateways | Where-Object { $_.type -in 'OnPremises', 'VirtualNetwork' } | ForEach-Object { [pscustomobject]@{ Kind = 'gateways'; Id = $_.id; Name = $_.displayName; Gateway = $_.displayName; GatewayId = $_.id } })
$ha = New-GLAudit -Folder (Join-Path $dl 'handover') -User 'demo.user@contoso.com' -Tenant 'contoso.example (demo)' -Version 'test'
function Get-DemoRole([string]$Kind, [string]$Id, [string]$UserId) { return (@($s.Roles["$Kind/$Id"]) | Where-Object { $_.principal.id -eq $UserId } | Select-Object -First 1).role }
$toAna = [pscustomobject]@{ Id = $anaU.id; DisplayName = 'Ana Novak'; Type = 'User' }
$vnetG = $cd.Gateways | Where-Object type -eq 'VirtualNetwork' | Select-Object -First 1
$nobody = Get-GLRoleAssignmentsBulk -Ids @($vnetG.id) -FabricToken $T -Kind gateways
Assert ($null -ne $nobody[$vnetG.id] -and $nobody[$vnetG.id] -is [array] -and $nobody[$vnetG.id].Count -eq 0) 'nobody has access is an empty list, not "could not be read"'

$err = $null; try { $null = Resolve-GLHandoverFrom -Value 'joe.smith@contoso.com' -GraphToken $null } catch { $err = $_.Exception.Message }
Assert ($err -match 'object id') 'without Graph an email cannot be matched - role assignments carry only object ids - so the object id is asked for'
$err = $null; try { $null = Resolve-GLHandoverFrom -Value 'joe' -GraphToken $T } catch { $err = $_.Exception.Message }
Assert ($err -match 'was not found' -and $err -match 'object id') 'someone Graph does not know - a deleted account - is refused, with the object id as the way out'
$fromMail = Resolve-GLHandoverFrom -Value 'joe.smith@contoso.com' -GraphToken $T
$h1 = Invoke-GLAccessHandover -Targets ($allGw + $allConn) -From $fromMail -To $toAna -FabricToken $T -Progress @{ Cancel = $false } -Audit $ha
$given = @($h1 | Where-Object { $_.Message -like 'gave Ana Novak*' })
Assert ($given.Count -eq 2 -and (Get-DemoRole connections $byN['Sales DW'].Id $anaU.id) -eq 'User' -and (Get-DemoRole connections $byN['Sales Staging'].Id $joeU.id) -eq 'User') "Copy access: Ana gets Joe's User role on both his connections, and Joe keeps his ($($given.Count) given)"
Assert (@($h1 | Where-Object { -not $_.Ok }).Count -eq 0 -and @($h1 | Where-Object { $_.Message -like '*has no role here' }).Count -eq ($allGw.Count + $allConn.Count - 2)) 'everything else: nothing to hand over, and nothing fails'

$fromJoe = Resolve-GLHandoverFrom -Value 'joe.smith@contoso.com' -GraphToken $T
Assert ($fromJoe.Id -eq $joeU.id) 'with Graph, the email is looked up to an object id'
$h2 = Invoke-GLAccessHandover -Targets $allConn -From $fromJoe -To ([pscustomobject]@{ Id = $meU.id; DisplayName = 'Demo User'; Type = 'User' }) -Move -FabricToken $T -Progress @{ Cancel = $false } -Audit $ha
Assert (-not (Get-DemoRole connections $byN['Sales DW'].Id $joeU.id) -and (Get-DemoRole connections $byN['Sales DW'].Id $meU.id) -eq 'Owner' -and @($h2 | Where-Object { $_.Message -like '*already has Owner, removed*' }).Count -eq 2) 'Move access to someone with a higher role: their role is kept, and Joe is removed'

$biG = $s.Groups | Where-Object displayName -eq 'BI Admins'
# Jane has User on Sales DW (an earlier test removed it - give it back first)
if (-not (Get-DemoRole connections $byN['Sales DW'].Id $janeU.id)) { $null = Add-GLRoleAssignment -Kind connections -Id $byN['Sales DW'].Id -PrincipalId $janeU.id -PrincipalType User -Role User -FabricToken $T }
$t3 = @($allConn | Where-Object { $_.Name -in 'Sales DW', 'Product Catalog' })
$h3 = Invoke-GLAccessHandover -Targets $t3 -From (Resolve-GLHandoverFrom -Value $biG.id) -To ([pscustomobject]@{ Id = $janeU.id; DisplayName = 'Jane Doe'; Type = 'User' }) -FabricToken $T -Progress @{ Cancel = $false } -Audit $ha
Assert ((Get-DemoRole connections $byN['Sales DW'].Id $janeU.id) -eq 'Owner' -and ($h3 | Where-Object Name -eq 'Sales DW').Message -like 'raised Jane Doe from User to Owner*') 'a lower role is raised to the same one - Jane goes from User to Owner, as the group had'
Assert ((Get-DemoRole connections $byN['Product Catalog'].Id $janeU.id) -eq 'Owner' -and ($h3 | Where-Object Name -eq 'Product Catalog').Message -eq 'gave Jane Doe Owner') 'no role yet: the same role is given'

$h4 = Invoke-GLAccessHandover -Targets $allGw -From (Resolve-GLHandoverFrom -Value 'jane.doe@contoso.com' -GraphToken $T) -To $toAna -Move -FabricToken $T -Progress @{ Cancel = $false } -Audit $ha
Assert ((Get-DemoRole gateways $prodG.id $anaU.id) -eq 'ConnectionCreator' -and -not (Get-DemoRole gateways $prodG.id $janeU.id)) 'gateways too: Ana takes over Jane''s connection-creator role on the Prod gateway'

$ghost = [pscustomobject]@{ Id = (New-GLDemoId 'nobody'); DisplayName = 'Nobody'; Type = 'User' }
$t5 = @($allConn | Where-Object Name -eq 'Sales Staging')
$h5 = Invoke-GLAccessHandover -Targets $t5 -From (Resolve-GLHandoverFrom -Value $anaU.id) -To $ghost -Move -FabricToken $T -Progress @{ Cancel = $false } -Audit $ha
Assert (-not $h5[0].Ok -and $h5[0].Message -match 'could not be given' -and $h5[0].Message -match 'keeps it' -and (Get-DemoRole connections $byN['Sales Staging'].Id $anaU.id) -eq 'User') 'a grant that fails removes nothing: Ana keeps her role'
$err = $null; try { $null = Invoke-GLAccessHandover -Targets $allConn -From (Resolve-GLHandoverFrom -Value $anaU.id) -To $toAna -FabricToken $T -Progress @{ Cancel = $false } -Audit $ha } catch { $err = $_.Exception.Message }
Assert ($err -match 'is the one handing over') 'handing over to the same person is refused before anything is read'

$hrec = @(Import-Csv (Get-GLChangePath -Folder $ha.Folder -User 'demo.user@contoso.com'))
$hg = @($hrec | Where-Object { $_.Action -eq 'Grant access' -and $_.Result -eq 'Done' -and $_.Details -like 'Handed over from*' })
$hm = @($hrec | Where-Object { $_.Action -eq 'Remove access' -and $_.Result -eq 'Done' -and $_.Details -like 'Handed over to*' })
$hc = @($hrec | Where-Object { $_.Action -eq 'Change role' -and $_.Result -eq 'Done' })
Assert ($hg.Count -eq 4 -and $hm.Count -eq 3 -and $hc.Count -eq 1 -and $hg[0].Principal -and $hg[0].Role) "every grant, raise and removal of a handover is in the change record ($($hg.Count) given, $($hc.Count) raised, $($hm.Count) removed)"

$rt = @(
    [pscustomobject]@{ Kind = 'gateways';    Id = $prodG.id; Name = $prodG.displayName; Gateway = $prodG.displayName; Type = 'OnPremises'; Path = ''; Account = ''; LastUsed = '' }
    [pscustomobject]@{ Kind = 'connections'; Id = $byN['Sales DW'].Id; Name = 'Sales DW'; Gateway = 'Contoso Prod Cluster'; Type = 'SQL'; Path = $byN['Sales DW'].Path; Account = $byN['Sales DW'].Account; LastUsed = $byN['Sales DW'].LastUsed }
)
$rep = Get-GLAccessReport -Targets $rt -FabricToken $T -Progress @{ Cancel = $false } -GraphToken $T
Assert (@($rep | Where-Object { $_.Target -eq 'Sales DW' -and $_.Email -eq 'demo.user@contoso.com' -and $_.Role -eq 'Owner' }).Count -eq 1 -and @($rep | Where-Object { $_.Kind -eq 'Gateway' -and $_.Role -eq 'Admin' }).Count -ge 1) "access report from the demo: gateways and connections, each person with their role ($($rep.Count) rows)"
$repAna = Get-GLAccessReport -Targets $rt -Who 'ana.novak' -FabricToken $T -Progress @{ Cancel = $false } -GraphToken $T
Assert ($repAna.Count -eq 2 -and -not ($repAna | Where-Object { $_.Email -ne 'ana.novak@contoso.com' })) "access report for one person: Ana's gateway role and her connection, nothing else ($($repAna.Count))"

$s.VnetWoken = 0
$ok = Invoke-GLSelfTest 6>$null
Assert ($s.VnetWoken -eq 0) 'the self-test never wakes a VNet gateway'
Assert ($ok) 'the self-test passes against the demo, every check'

# the background workers see the same Contoso - the window depends on it
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
foreach ($n in $script:WorkerFunctions) { $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($n, (Get-Item "function:$n").Definition)) }
$rs = [runspacefactory]::CreateRunspace($iss); $rs.Open()
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void]$ps.AddScript({ param($T, $G, $M) $d = Get-GLConnectionData -FabricToken $T; Set-GLMemberEnabled -GatewayId $G -MemberId $M -Enabled $false -FabricToken $T; @($d.Connections).Count }).AddArgument($T).AddArgument($prodGw.id).AddArgument($m2.id)
$wc = $ps.Invoke()
$ps.Dispose(); $rs.Dispose()
Assert ($wc[0] -eq 27 -and $m2.enabled -eq $false) 'a background worker reads and changes the same demo company as the window'


Disable-GLDemo
Assert (-not [System.AppDomain]::CurrentDomain.GetData('GatewayLens.Demo')) 'switching the demo off removes it completely'

# Someone whose profile turns strict mode on must get the same tool - start a fresh
# PowerShell with it on, and run the demo self-test there, end to end.
$pw  = (Get-Process -Id $PID).Path
$out = & $pw -NoProfile -Command "Set-StrictMode -Version Latest; & '$script' -Demo -SelfTest" 2>&1
Assert ($LASTEXITCODE -eq 0 -and ($out -join "`n") -match 'Everything works') "the tool works for a caller with strict mode on (exit $LASTEXITCODE)"
Assert (($out -join "`n") -match 'PASS\s+Demo: kept apart from real records') 'demo mode writes only to its own folders, never the real log, changes or backups'
$script:AuthMode = $keepMode; $script:SignedInAs = $keepUser; $script:TenantShown = $keepTenant
Remove-Item -Recurse -Force $dl

$listNew = @([regex]::Matches((Get-Content $script -Raw), "New-Object '?System\.Collections\.Generic") )
Assert ($listNew.Count -eq 0) 'every list is made with ::new() - New-Object lists break @() in PowerShell 7.4'

# ============================================================================
Section 'Look and feel'
# ============================================================================
$xamlBy = @{}
foreach ($h in $hereStrings) { $xamlBy[$h.Groups[1].Value] = $h.Groups[2].Value }
$allXaml = ($xamlBy.Values -join "`n")
$styleKeys   = @([regex]::Matches($allXaml, 'x:Key="(\w+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$brushesUsed = @([regex]::Matches($allXaml, '\{DynamicResource (\w+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique | Where-Object { $styleKeys -notcontains $_ })
foreach ($name in $script:Themes.Keys) {
    $miss = @($brushesUsed | Where-Object { -not $script:Themes[$name].Contains($_) })
    Assert (-not $miss) "theme '$name' defines all $($brushesUsed.Count) brushes the windows use $(if ($miss) { '- missing: ' + ($miss -join ', ') })"
}
$windowsXaml = $xamlBy.MainXaml + $xamlBy.StartXaml + $xamlBy.InfoXaml + $xamlBy.AlertsXaml + $xamlBy.DialogXaml + $xamlBy.PromptXaml
$asked = @([regex]::Matches($windowsXaml, 'Style="\{DynamicResource (\w+)\}"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
foreach ($set in 'ModernStylesXaml', 'ClassicStylesXaml') {
    $have = @([regex]::Matches($xamlBy[$set], 'x:Key="(\w+)"') | ForEach-Object { $_.Groups[1].Value })
    $miss = @($asked | Where-Object { $have -notcontains $_ })
    Assert (-not $miss) "$set has every style the windows ask for ($($asked -join ', ')) $(if ($miss) { '- missing: ' + ($miss -join ', ') })"
}
# A style and a brush with the same name: the window's brushes are found first, so
# the style gets a brush - "'#FFDC2626' is not a valid value for property 'Style'".
$clash = @($styleKeys | Where-Object { $script:Themes[0].Contains($_) })
Assert ($styleKeys.Count -ge 5 -and -not $clash) "no style shares a name with a brush ($($styleKeys.Count) styles) $(if ($clash) { '- both: ' + ($clash -join ', ') })"
$hard = @([regex]::Matches($windowsXaml, '"#[0-9A-Fa-f]{6,8}"'))
Assert ($hard.Count -eq 0) 'the windows use no fixed colours - everything follows the theme'

foreach ($f in $script:HistoryFields) {
    Assert ($xamlBy.MainXaml -match "<ComboBox Name=""$f"" IsEditable=""True""") "$f is an editable box with history"
}
Assert (-not ($script:HistoryFields | Where-Object { $_ -match 'Pwd|Pass' })) 'no password box is among the fields with history'
$gridTags = @([regex]::Matches($xamlBy.MainXaml, '<DataGrid [^>]*>') | ForEach-Object Value)
$gridNames = @($gridTags | ForEach-Object { if ($_ -match 'Name="(\w+)"') { $Matches[1] } })
$unsafe = @($gridTags | Where-Object { $_ -notmatch 'CanUserAddRows="False"' -or $_ -notmatch 'CanUserDeleteRows="False"' })
$wired  = [regex]::Match($text, "\`$script:Grids\s*=\s*@\(([^)]*)\)").Groups[1].Value
$unwired = @($gridNames | Where-Object { $wired -notmatch "'$_'" })
Assert ($gridTags.Count -ge 4 -and -not $unsafe -and -not $unwired) "every grid: rows can be neither added nor deleted, and it gets read-only copyable columns ($($gridNames -join ', ')) $(if ($unsafe -or $unwired) { '- not: ' + (@($unwired) + @($unsafe) -join ', ') })"

$fixedBoxes = @([regex]::Matches($xamlBy.MainXaml, '<(ComboBox|PasswordBox|TextBox)\b[^>]*\sHeight="\d+"') | ForEach-Object { ($_.Value -split '\s+')[0..1] -join ' ' })
Assert (-not $fixedBoxes) "no input box has a fixed height - it would cut off larger text $(if ($fixedBoxes) { '- ' + ($fixedBoxes -join ', ') })"

$pwBoxes = @([regex]::Matches($xamlBy.MainXaml, '<(\w+) Name="(Pwd\w+)"') | ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" })
Assert ($pwBoxes.Count -eq 1 -and -not ($pwBoxes | Where-Object { $_ -notlike 'PasswordBox *' })) "the password field is a masked PasswordBox ($($pwBoxes -join ', '))"

$png = [Convert]::FromBase64String($script:IconPng)
Assert ($png[0] -eq 0x89 -and $png[1] -eq 0x50 -and $png[2] -eq 0x4E -and $png[3] -eq 0x47) 'the embedded icon is a PNG'
$w = ($png[16] -shl 24) -bor ($png[17] -shl 16) -bor ($png[18] -shl 8) -bor $png[19]
Assert ($w -eq 64) "the embedded icon is 64 pixels wide ($w)"
$ico = [System.IO.File]::ReadAllBytes((Join-Path $root 'assets/GatewayLens.ico'))
Assert ($ico[0] -eq 0 -and $ico[1] -eq 0 -and $ico[2] -eq 1 -and $ico[3] -eq 0 -and $ico[4] -ge 5) "assets/GatewayLens.ico is an icon with $($ico[4]) sizes"

# the brush is the value in braces - { 'Danger' } - in each colour rule, which may run over two lines
$codeBrushes = @([regex]::Matches((Get-Content $script -Raw), "Set-GLRowColor \`$e\.Row([\s\S]{0,300}?)\}\)\s*\r?\n\s*\}\)") | ForEach-Object {
    [regex]::Matches($_.Groups[1].Value, "\{\s*'(\w+)'\s*\}") | ForEach-Object { $_.Groups[1].Value } } | Sort-Object -Unique)
foreach ($name in $script:Themes.Keys) {
    $miss = @($codeBrushes | Where-Object { -not $script:Themes[$name].Contains($_) })
    Assert ($codeBrushes.Count -ge 2 -and -not $miss) "theme '$name' has the row colours the code asks for ($($codeBrushes -join ', ')) $(if ($miss) { '- missing: ' + ($miss -join ', ') })"
}

$wl = Join-Path ([System.IO.Path]::GetTempPath()) ("gl-wl-" + [guid]::NewGuid().ToString('N'))
$keep = @{ R = $script:LogReady; F = $script:LogFolder; U = $script:SignedInAs }
$script:LogReady = $true; $script:LogFolder = $wl; $script:SignedInAs = 'tester@contoso.com'
Write-GLLog 'detail for the file only' -FileOnly
$null = Write-GLLog 'shown and filed' 'Warn' 6>&1
$wtxt = Get-Content (Get-GLLogPath -Folder $wl -User 'tester@contoso.com') -Raw
Assert ($wtxt -match 'INFO   detail for the file only' -and $wtxt -match 'WARN   shown and filed') 'everything logged reaches the daily file, file-only detail included'
$script:LogReady = $keep.R; $script:LogFolder = $keep.F; $script:SignedInAs = $keep.U
Remove-Item -Recurse -Force $wl

# CLAUDE.md guides every Claude Code session - what it names must exist
$cm = Get-Content (Join-Path $root 'CLAUDE.md') -Raw
$named = @([regex]::Matches($cm, '`((?:tests|build|docs|assets|\.github)/[^`\s]*|GatewayLens\.ps1|CHANGELOG\.md|README\.md)`') | ForEach-Object { $_.Groups[1].Value.TrimEnd('/') } | Sort-Object -Unique)
$gone  = @($named | Where-Object { $_ -notlike '*.local.*' -and -not (Test-Path (Join-Path $root $_)) })   # local files are absent by design
Assert ($named.Count -ge 6 -and -not $gone) "every file CLAUDE.md names exists ($($named.Count) checked) $(if ($gone) { '- missing: ' + ($gone -join ', ') })"
$fnNamed = @([regex]::Matches($cm, '`((?:Get|Write|Invoke|Set|New)-GL[A-Za-z]+)`') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$fnGone  = @($fnNamed | Where-Object { -not (Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue) })
Assert ($fnNamed.Count -ge 3 -and -not $fnGone) "every function CLAUDE.md names exists ($($fnNamed -join ', ')) $(if ($fnGone) { '- missing: ' + ($fnGone -join ', ') })"

# ============================================================================
Section 'The real window'
# ============================================================================
# A script's parameters ARE its script variables. Writing $script:LogFolder silently
# overwrote the -LogFolder parameter, and the demo then wrote into the real log folder.
$paramNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$aliasWrites = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
    Where-Object { $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                   $_.Left.VariablePath.UserPath -like 'script:*' -and
                   $paramNames -contains $_.Left.VariablePath.UserPath.Substring(7) } |
    ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Left.Extent.Text)" })
Assert ($paramNames.Count -ge 10 -and -not $aliasWrites) "no parameter is overwritten through `$script: ($($paramNames.Count) parameters) $(if ($aliasWrites) { '- ' + ($aliasWrites -join '; ') })"

$newObj = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-Object' }, $true))
Assert ($newObj.Count -eq 0) "no New-Object in the script - it wraps objects, and WPF stored a wrapped brush as text $(if ($newObj.Count) { '- line ' + (($newObj | ForEach-Object { $_.Extent.StartLineNumber }) -join ', ') })"

# back to the start page: the next window starts with nothing from the last one
$keepReset = @{ State = $script:State; UI = $script:UI; Auth = $script:Auth; Who = $script:SignedInAs; Mode = $script:AuthMode; Tenant = $script:TenantShown; Ready = $script:LogReady; Jobs = $script:Jobs }
$script:State.ConnRows = @(1, 2, 3); $script:State.Names['x'] = 'y'; $script:UI = @{ X = 1 }
$script:SignedInAs = 'someone@contoso.com'; $script:AuthMode = 'Demo'
$script:LogEntries.Add([pscustomobject]@{ Level = 'Error'; Line = 'old error' })
Reset-GLSession
Assert (@($script:State.ConnRows).Count -eq 0 -and $script:State.Names.Count -eq 0 -and $script:UI.Count -eq 0 -and -not $script:SignedInAs -and -not $script:AuthMode -and $script:LogEntries.Count -eq 0 -and @($script:EarlierErrors | Where-Object Line -eq 'old error').Count -eq 1) 'back to the start page: no rows, names, window or account remain - and earlier errors are kept for the smoke test'
$script:EarlierErrors.Clear()
$script:State = $keepReset.State; $script:UI = $keepReset.UI; $script:Auth = $keepReset.Auth; $script:SignedInAs = $keepReset.Who
$script:AuthMode = $keepReset.Mode; $script:TenantShown = $keepReset.Tenant; $script:LogReady = $keepReset.Ready; $script:Jobs = $keepReset.Jobs

# what the window checks after the smoke run, tested on any OS by setting the state it reads
$keepStyle = $script:StyleMode; $keepErr = $script:StyleError; $keepSmoke = $script:Smoke
$keepRows = @{ G = $script:State.GatewayRows; C = $script:State.ConnRows; A = $script:State.Changes }
$script:StyleMode = 'Modern'; $script:StyleError = $null; $script:LogEntries.Clear()
$script:Smoke = @{ Plan = @(1, 2, 3); Next = 3; KioskOk = $true; Duplicates = 2; GridChecks = ''; TileScale = 16 / 12; FilterOk = $true; HistoryOk = $true; GoneOk = $true; CountdownOk = $true; AgainOk = $true; AlertsOk = $true; TaskbarOk = $true; MeterOk = $true; CleanupOk = $true; MenuOk = $true }
$keepStart = $script:StartPageResult; $script:StartPageResult = 'Demo'
$keepTiles = $script:State.Tiles
$script:State.GatewayRows = @(1..5); $script:State.ConnRows = @(1..27)
$script:State.Tiles = @('Offline', 'Degraded', 'Online', 'Online', 'VNet' | ForEach-Object { [pscustomobject]@{ Status = $_ } })
$keepReleases = $script:State.Releases
$script:State.Releases = [pscustomobject]@{ Newest = [version]'3000.290.10'; Supported = @(); Checked = Get-Date }
Assert ((Get-GLSmokeVerdict).Count -eq 0) 'smoke verdict: a clean run passes'
$script:StyleMode = 'Classic'; $script:StyleError = 'bad template'
$script:LogEntries.Add([pscustomobject]@{ Level = 'Error'; Line = '12:00:00  ERROR  boom' })
$script:Smoke.Next = 2
$v = Get-GLSmokeVerdict
Assert ($v.Count -eq 3 -and ($v -join ' ') -match 'bad template' -and ($v -join ' ') -match 'boom' -and ($v -join ' ') -match 'step 2 of 3') 'smoke verdict: falling back to the classic look, an error, or an unfinished run all fail'
$script:State.ConnRows = @(1..3)
Assert (((Get-GLSmokeVerdict) -join ' ') -match 'connections shown: 3, expected 27') 'smoke verdict: missing demo data fails'
$script:State.ConnRows = @(1..27); $script:Smoke.KioskOk = $false
Assert (((Get-GLSmokeVerdict) -join ' ') -match 'kiosk view') 'smoke verdict: a kiosk view that did not hide and restore fails'
$script:Smoke.KioskOk = $true; $script:Smoke.GridChecks = 'a cell wrote its text back into the row'
Assert (((Get-GLSmokeVerdict) -join ' ') -match 'grids: a cell wrote') 'smoke verdict: a grid that sorts, opens or copies wrongly fails'
$script:Smoke.GridChecks = ''
foreach ($k in 'GoneOk', 'CountdownOk', 'AgainOk', 'AlertsOk', 'TaskbarOk', 'MeterOk', 'CleanupOk', 'MenuOk') {
    $script:Smoke[$k] = $false
    Assert ((Get-GLSmokeVerdict).Count -ge 1) "smoke verdict: $k false fails"
    $script:Smoke[$k] = $true
}
$script:StartPageResult = 'Fallback'
Assert (((Get-GLSmokeVerdict) -join ' ') -match 'start page') 'smoke verdict: a start page that did not open, or whose demo button did nothing, fails'
$script:StartPageResult = 'Demo'
$script:Smoke.HistoryOk = $false
Assert (((Get-GLSmokeVerdict) -join ' ') -match 'remembered entry') 'smoke verdict: a remembered entry that cannot be picked again fails'
$script:Smoke.HistoryOk = $true
$script:Smoke.FilterOk = $false
Assert (((Get-GLSmokeVerdict) -join ' ') -match 'search box') 'smoke verdict: a search box that does not filter fails'
$script:Smoke.FilterOk = $true
$script:Smoke.TileScale = 1.0
Assert (((Get-GLSmokeVerdict) -join ' ') -match 'tiles at text size 16') 'smoke verdict: tiles that do not follow the text size fail'
$script:Smoke.TileScale = 16 / 12
$script:Smoke.KioskOk = $true; $script:State.Releases = $null
Assert (((Get-GLSmokeVerdict) -join ' ') -match 'newest gateway version') 'smoke verdict: the newest gateway version not read fails'
$script:StyleMode = $keepStyle; $script:StyleError = $keepErr; $script:Smoke = $keepSmoke; $script:StartPageResult = $keepStart; $script:LogEntries.Clear()
$script:State.GatewayRows = $keepRows.G; $script:State.ConnRows = $keepRows.C; $script:State.Changes = $keepRows.A; $script:State.Tiles = $keepTiles; $script:State.Releases = $keepReleases

if ($IsWindows -and -not $env:GATEWAYLENS_NO_WINDOW_TEST) {
    # The window itself. This is also what catches a theme brush that reaches WPF as
    # text: PowerShell hides its wrappers too well for a smaller test to see one.: a fresh PowerShell opens it on demo data and drives it
    $pw  = (Get-Process -Id $PID).Path
    $so  = [System.IO.Path]::GetTempFileName()
    $se  = [System.IO.Path]::GetTempFileName()
    $argList = @('-NoProfile', '-STA', '-File', "`"$script`"", '-SmokeTest')
    $proc = Start-Process -FilePath $pw -ArgumentList $argList -PassThru -NoNewWindow -RedirectStandardOutput $so -RedirectStandardError $se
    $null = $proc.Handle            # without this, Start-Process often reports no exit code
    $done = $proc.WaitForExit(180000)
    if ($done) { $proc.WaitForExit() } else { try { $proc.Kill() } catch { } }
    $said = ((Get-Content $so -Raw) + (Get-Content $se -Raw)) -replace '\s+', ' '
    Remove-Item $so, $se -ErrorAction SilentlyContinue
    $ok = $done -and $proc.ExitCode -eq 0
    Assert $ok "the real window opens on demo data, goes through every theme and tab, and closes cleanly $(if (-not $done) { '- no answer within 3 minutes' } elseif (-not $ok) { '- ' + $said.Trim() })"
}
elseif ($IsWindows) {
    Write-Host '  SKIP  the real window - GATEWAYLENS_NO_WINDOW_TEST is set' -ForegroundColor DarkYellow
}
else {
    Write-Host '  SKIP  the real window - needs Windows' -ForegroundColor DarkYellow
}

# ============================================================================
Section 'API inspection output'
# ============================================================================
$sample = [pscustomobject]@{
    id = 'x'; datasourceName = 'Finance warehouse'; datasourceType = 'Sql'
    lastModified = [datetime]'2026-09-30 14:05:00'; createdText = '2026-01-02T03:04:05Z'
    count = 3; enabled = $true
    credentialDetails = [pscustomobject]@{ credentialType = 'Windows'; publicCredentialProperties = '[{"name":"username","value":"DOM\\secret.user"}]' }
    users = @([pscustomobject]@{ emailAddress = 'jane@contoso.com'; datasourceAccessRight = 'Read' })
}
$shape = (Format-GLShape -Object $sample) -join "`n"
Assert ($shape -match 'datasourceName\s+<text, 17 characters>') 'ordinary text is replaced by its length'
Assert ($shape -notmatch 'secret\.user' -and $shape -notmatch 'jane@contoso') 'usernames and emails never appear'
Assert ($shape -match 'lastModified\s+2026-09-30 14:05:00\s+<- date' -and $shape -match 'createdText\s+2026-01-02T03:04:05Z\s+<- date') 'dates are shown and marked - the point of the exercise'
Assert ($shape -match 'datasourceType\s+Sql' -and $shape -match 'credentialDetails\.credentialType\s+Windows') 'short type fields are shown, nested ones with their path'
Assert ($shape -match 'users\s+list of 1' -and $shape -match 'users\[0\]\.datasourceAccessRight\s+Read') 'lists show their length and the fields of the first item'
Assert ($shape -match 'enabled\s+True' -and $shape -match 'count\s+3') 'numbers and yes/no values are shown'

# ============================================================================
Section 'GatewayLens.exe'
# ============================================================================
$proj = Get-Content (Join-Path $root 'build/launcher/GatewayLens.csproj') -Raw
$prog = Get-Content (Join-Path $root 'build/launcher/Program.cs') -Raw
[xml]$projXml = $proj
$res = $projXml.Project.ItemGroup.EmbeddedResource
Assert ($res.LogicalName -eq 'GatewayLens.ps1' -and $prog -match 'GetManifestResourceStream\("GatewayLens\.ps1"\)') 'the exe reads the script under the same name it was embedded with'
$launcherDir = Join-Path $root 'build/launcher'
Assert (Test-Path (Join-Path $launcherDir $res.Include)) 'the embedded script path points at GatewayLens.ps1'
Assert (Test-Path (Join-Path $launcherDir $projXml.Project.PropertyGroup.ApplicationIcon)) 'the exe icon path points at assets/GatewayLens.ico'
Assert ($projXml.Project.PropertyGroup.TargetFramework -eq 'net48') 'the exe targets .NET Framework 4.8 - built into Windows, nothing to install'
Assert ($prog -match '"-Launched"' -and ((Get-Command -Name $script -Syntax) -match '-Launched')) 'the exe passes -Launched and the script accepts it'
foreach ($sw in 'SelfTest', 'Inspect', 'DeviceCode') {
    Assert ($prog -match """-$sw""") "the exe keeps the console open for -$sw"
}
$m = [regex]::Match((Get-Content $script -Raw), "AppVersion\s*=\s*'(\d+\.\d+\.\d+)'")
Assert ($m.Success) "the build script can read the version from GatewayLens.ps1 ($($m.Groups[1].Value))"

# ============================================================================
Section 'Parallel requests against a real HTTP server'
# ============================================================================
# A small local web server with a fast endpoint, a failing one and slow ones.
# This checks the real HttpClient code: the time limit, error handling, and that
# requests genuinely run at the same time.
$probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
$prefix   = "http://localhost:$port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$serverUp = $true
try { $listener.Start() } catch { $serverUp = $false }

if (-not $serverUp) {
    Write-Host '  SKIP  could not start a local HTTP listener on this machine' -ForegroundColor DarkYellow
}
else {
    # several runspaces each serve requests, so slow requests overlap like real ones
    $serve = {
        param($L)
        while ($L.IsListening) {
            try { $ctx = $L.GetContext() } catch { break }
            $path = $ctx.Request.Url.AbsolutePath
            $code = 200; $body = '{"gatewayStatus":"Live"}'
            if ($path -like '/fail*')  { $code = 500; $body = '{"error":"boom"}' }
            if ($path -like '/slow1*') { Start-Sleep -Milliseconds 1000 }
            if ($path -like '/hang*')  { Start-Sleep -Seconds 4 }
            if ($ctx.Request.Headers['Authorization'] -ne 'Bearer tok') { $code = 401; $body = '{"error":"no token"}' }
            $bytes = [Text.Encoding]::UTF8.GetBytes($body)
            $ctx.Response.StatusCode = $code
            $ctx.Response.ContentType = 'application/json'
            try { $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length); $ctx.Response.Close() } catch { }
        }
    }
    $servers = foreach ($i in 1..8) {
        $ps = [powershell]::Create(); [void]$ps.AddScript($serve).AddArgument($listener)
        [pscustomobject]@{ PS = $ps; H = $ps.BeginInvoke() }
    }
    # If anything below throws, the listener and its threads must still stop -
    # otherwise they keep the whole test run alive forever.
    try {

    $r = Invoke-GLParallelGet -Uris @("${prefix}ok", "${prefix}fail") -Token 'tok' -TimeoutSec 5
    Assert ($r["${prefix}ok"].Ok -and $r["${prefix}ok"].Body.gatewayStatus -eq 'Live') 'a good answer is parsed'
    Assert (-not $r["${prefix}fail"].Ok -and $r["${prefix}fail"].Status -eq 500 -and $r["${prefix}fail"].Error -match 'boom') 'a failing answer keeps its status code and body'

    $r = Invoke-GLParallelGet -Uris @("${prefix}ok") -Token 'wrong' -TimeoutSec 5
    Assert ($r["${prefix}ok"].Status -eq 401) 'the bearer token is sent'

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r  = Invoke-GLParallelGet -Uris @("${prefix}hang", "${prefix}ok") -Token 'tok' -TimeoutSec 1
    $sw.Stop()
    Assert ($r["${prefix}hang"].Error -like 'no answer within 1s') 'a request that hangs is cut off at the time limit'
    Assert ($r["${prefix}ok"].Ok) 'a hanging request does not spoil the others'
    Assert ($sw.Elapsed.TotalSeconds -lt 3.5) "and the whole call returns near the limit ($([math]::Round($sw.Elapsed.TotalSeconds,1))s, limit 1s)"

    $five = 1..5 | ForEach-Object { "${prefix}slow1-$_" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r  = Invoke-GLParallelGet -Uris $five -Token 'tok' -TimeoutSec 10
    $sw.Stop()
    $okCount = @($five | Where-Object { $r[$_].Ok }).Count
    Assert ($okCount -eq 5) 'five slow requests all succeed'
    Assert ($sw.Elapsed.TotalSeconds -lt 3) "five 1-second requests take about 1 second, not 5 - they run in parallel ($([math]::Round($sw.Elapsed.TotalSeconds,1))s)"

    }
    finally {
        try { $listener.Stop(); $listener.Close() } catch { }
        foreach ($s in $servers) { try { $s.PS.Stop() } catch { }; $s.PS.Dispose() }
    }
}

# ============================================================================
Section 'Background workers - the real mechanism, without the window'
# ============================================================================
# The window hands work to a runspace pool built exactly like this. These tests run
# real worker runspaces and check that results survive the trip back intact.
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
foreach ($n in $script:WorkerFunctions) {
    $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($n, (Get-Item "function:$n").Definition))
}
$pool = [runspacefactory]::CreateRunspacePool(1, 2, $iss, $Host)
$pool.Open()
function Invoke-Worker([string]$Code) {
    $ps = [powershell]::Create(); $ps.RunspacePool = $pool
    [void]$ps.AddScript($Code)
    try { return ConvertFrom-GLJobOutput ($ps.Invoke()) } finally { $ps.Dispose() }
}

$r = Invoke-Worker '[pscustomobject]@{ Ok = $true; Message = "fine" }'
Assert ($r.Ok -eq $true -and $r.Message -eq 'fine') 'a [pscustomobject] result keeps its properties'

$r = Invoke-Worker '@{ Gateways = @(1, 2, 3); Log = @() }'
Assert ($r.Gateways.Count -eq 3) 'a hashtable result keeps its contents'

$r = Invoke-Worker 'function Get-Three { return , @(1, 2, 3) }; Get-Three'
Assert ($r -is [array] -and $r.Count -eq 3) 'an array result arrives as one array'

$r = Invoke-Worker 'function Get-None { return , @() }; Get-None'
Assert ($r -is [array] -and $r.Count -eq 0) 'an empty array result arrives as an empty array'

# A list of OBJECTS - what most jobs return. A list of numbers has no properties to
# lose, which is how a bug that emptied every object in a list went unnoticed.
$r = Invoke-Worker 'function Get-Rows { return , @([pscustomobject]@{ Name = "a"; Ok = $true }, [pscustomobject]@{ Name = "b"; Ok = $false }) }; Get-Rows'
Assert ($r.Count -eq 2 -and $r[0].Name -eq 'a' -and $r[0].Ok -eq $true -and $r[1].Name -eq 'b') 'a list of objects arrives with every property on every object'
$r = Invoke-Worker 'function Get-One { return , @([pscustomobject]@{ Name = "only" }) }; Get-One'
Assert ($r.Count -eq 1 -and $r[0].Name -eq 'only') 'a list of one object stays a list, its object intact'

# the real jobs that return lists of objects
$wf = Join-Path ([IO.Path]::GetTempPath()) ("gl-wk-" + [guid]::NewGuid().ToString('N'))
Enable-GLDemo; (Get-GLDemoStore).Fast = $true
$wa = New-GLAudit -Folder $wf -User 'demo.user@contoso.com' -Tenant 'contoso.example (demo)' -Version 'test'
foreach ($i in 1..8) { Write-GLChange -Audit $wa -Action 'Grant access' -Result Done -Target "Connection $i" -Principal 'Joe Smith' -Role 'User' }
$r = Invoke-Worker "Read-GLChanges -Folder '$wf'"
Assert ($r.Count -eq 8 -and $r[0].Action -and $r[0].User -and $r[0].When -is [datetime]) 'the change record arrives from a worker whole - every change, every field'
$cid = (Get-GLDemoStore).Connections[0].id
$r = Invoke-Worker "Get-GLRoleAssignments -Kind connections -Id '$cid' -FabricToken 'demo-token'"
Assert ($r.Count -ge 2 -and $r[0].role -and $r[0].principal.id -and $r[0].principal.type) 'who has access arrives from a worker whole - the id and type a real tenant gives'
$r = Invoke-Worker ('$s = Get-GLDemoStore; $c = $s.Connections | Where-Object displayName -eq ''Customer 360''; $u = $s.Users[3]; ' +
    'Invoke-GLBulkGrant -Items @([pscustomobject]@{ Id = $c.id; Name = $c.displayName }) ' +
    '-Principals @([pscustomobject]@{ Id = $u.id; DisplayName = $u.displayName; Type = "User" }) -Role User -FabricToken demo-token -Progress @{ Cancel = $false }')
Assert ($r.Count -eq 1 -and $r[0].Name -eq 'Customer 360' -and $r[0].Ok -eq $true -and $r[0].Message -like 'granted User to Ana Novak') "bulk results arrive from a worker whole - name, outcome and reason ($($r[0].Name): $($r[0].Message))"

# the window's own job path - Start-GLJob, then Receive-GLJobs handing the result to
# OnDone - with stand-in controls: the path where every list once came back empty
$keepUI = $script:UI
$script:UI = @{}
foreach ($n in 'Busy', 'BtnCancel', 'TxtStatus') {
    $script:UI[$n] = [pscustomobject]@{ Text = ''; Visibility = ''; IsIndeterminate = $false; Maximum = 0; Value = 0 }
}
$script:Pool = $pool    # careful: names ignore case - in this file $pool and $script:Pool are ONE variable
$script:Jobs = [System.Collections.Generic.List[object]]::new()
$script:JobResult = $null
$readWork = { param($D) Read-GLChanges -Folder $D }
$keepDone = { param($r, $err, $ctx) $script:JobResult = @($r | Where-Object { $_ }) }
Start-GLJob -Quiet -Name 'Reading the change record' -Arguments @{ D = $wf } -Work $readWork -OnDone $keepDone 6>$null
for ($i = 0; $i -lt 100 -and $script:Jobs.Count; $i++) { Start-Sleep -Milliseconds 50; Receive-GLJobs 6>$null }
Assert (@($script:JobResult).Count -eq 8 -and @($script:JobResult)[0].Action -eq 'Grant access' -and @($script:JobResult)[0].Target) "a window job hands its list to OnDone whole ($(@($script:JobResult).Count) of 8)"

# the real Verify status and Verify users buttons, on demo data, with a stand-in grid
$cdw = Get-GLConnectionData -FabricToken 'demo-token'
$script:State.ConnRows = ConvertTo-GLConnectionRows -Connections $cdw.Connections -GatewayNames (Get-GLGatewayNameMap -Gateways $cdw.Gateways)
$grid = [pscustomobject]@{ ItemsSource = $script:State.ConnRows; Items = [pscustomobject]@{} }
$grid.Items | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
$script:UI.GridConnections = $grid
$keepMode = $script:AuthMode; $script:AuthMode = 'Demo'
Invoke-GLBulkStatusUi 6>$null
for ($i = 0; $i -lt 200 -and $script:Jobs.Count; $i++) { Start-Sleep -Milliseconds 50; Receive-GLJobs 6>$null }
$tested = @($script:State.ConnRows | Where-Object { $_.Status })
$bad = @($tested | Where-Object Status -eq 'Failed')
Assert ($tested.Count -eq 20 -and $bad.Count -ge 3) "Verify status from the window tests every gateway connection ($($tested.Count) of 20 tested, $($bad.Count) failed)"
Assert ((@($script:State.ConnRows | Where-Object Name -eq 'Web API Sandbox'))[0].Status -eq 'Unverified') 'a connection made with Skip test connection: its OK is Unverified'
foreach ($r in $script:State.ConnRows) { $r.Users = '' }
Invoke-GLBulkUsersUi 6>$null
for ($i = 0; $i -lt 200 -and $script:Jobs.Count; $i++) { Start-Sleep -Milliseconds 50; Receive-GLJobs 6>$null }
$read = @($script:State.ConnRows | Where-Object { $_.Users })
Assert ($read.Count -eq 27) "Verify users from the window reads every connection ($($read.Count) of 27)"
# the real Move access button: the User filter names who leaves, To who takes over
$keepConfirm  = ${function:Confirm-GL}
function Confirm-GL { param($Text, $Title) $script:Confirmed = $Text; return $true }
$keepSettings = $script:Settings; $script:Settings = New-GLDefaultSettings
$keepLogDir   = $script:LogFolder; $script:LogFolder = Join-Path $wf 'logs'
$keepWho      = $script:SignedInAs; $script:SignedInAs = 'demo.user@contoso.com'
foreach ($n in 'TxtMoveFrom', 'TxtMoveTo', 'TxtCnUser', 'TxtCredUser') { $script:UI[$n] = [pscustomobject]@{ Text = ''; ItemsSource = $null } }
$script:UI.TxtMoveTo.Text  = 'ana.novak@contoso.com'
$script:UI.TxtCnUser.Text  = 'joe.smith'
$script:UI.ChkMoveGateways = [pscustomobject]@{ IsChecked = $false }
$script:UI.CmbMoveToType   = [pscustomobject]@{ SelectedItem = 'User' }
$script:UI.LstGwTiles      = [pscustomobject]@{ ItemsSource = @() }
$joeRows = Select-GLConnections -Rows $script:State.ConnRows -User 'joe.smith'
$script:UI.GridConnections = [pscustomobject]@{ ItemsSource = $joeRows; Items = $grid.Items }
Invoke-GLHandoverUi -Move 6>$null
for ($i = 0; $i -lt 200 -and $script:Jobs.Count; $i++) { Start-Sleep -Milliseconds 50; Receive-GLJobs 6>$null }
$ds = Get-GLDemoStore
$joeW = $ds.Users | Where-Object displayName -eq 'Joe Smith'; $anaW = $ds.Users | Where-Object displayName -eq 'Ana Novak'
$left  = @($ds.Roles.Values | ForEach-Object { $_ } | Where-Object { $_.principal.id -eq $joeW.id })
$taken = @($joeRows | Where-Object { $id = $_.Id; @($ds.Roles["connections/$id"] | Where-Object { $_.principal.id -eq $anaW.id -and $_.role -eq 'User' }).Count })
Assert ($joeRows.Count -eq 2 -and $script:Confirmed -match "Move every role 'joe.smith@contoso.com' has to 'ana.novak@contoso.com'" -and $taken.Count -eq 2 -and $left.Count -eq 0) "Move access from the window: the User filter names who leaves, Ana takes over both connections, Joe keeps nothing ($($taken.Count) taken, $($left.Count) left)"
$script:UI.TxtCnUser.Text = 'a'
$script:Confirmed = $null
Invoke-GLHandoverUi -Move 6>$null
Assert (-not $script:Confirmed -and $script:Jobs.Count -eq 0) 'a User filter that matches several people is not guessed at: nothing is asked, nothing runs'

# the real Update credentials button, with Test them afterwards
$sales = @($script:State.ConnRows | Where-Object { $_.Name -in 'Sales DW', 'Sales Staging', 'Sales DW (old copy)' })
foreach ($r in $sales) { $r.Status = '' }
$script:UI.GridConnections   = [pscustomobject]@{ ItemsSource = $sales; Items = $grid.Items }
$script:UI.CmbCredType       = [pscustomobject]@{ SelectedItem = 'Windows' }
$script:UI.TxtCredUser.Text  = 'CONTOSO\svc_sales'
$pwBox = [pscustomobject]@{ Password = 'N3w-Passw0rd!' }
$pwBox | Add-Member -MemberType ScriptMethod -Name Clear -Value { $this.Password = '' }
$script:UI.PwdCred           = $pwBox
$script:UI.CmbCredEncryption = [pscustomobject]@{ SelectedItem = 'Keep current' }
$script:UI.ChkCredRetest     = [pscustomobject]@{ IsChecked = $true }
$script:UI.LstLog = [pscustomobject]@{ ItemsSource = $null }    # the log list, as far as Write-GLLog needs one
$script:LogEntries.Clear()
$logBox = [pscustomobject]@{}
$logBox | Add-Member -MemberType ScriptProperty -Name Text -Value { (@($script:LogEntries | ForEach-Object Line) -join "`n") + "`n" }
$script:State.PublicKeys = @{}
foreach ($g in $cdw.Gateways) { if ($g.publicKey) { $script:State.PublicKeys[([string]$g.id).ToLowerInvariant()] = $g.publicKey } }
Invoke-GLBulkCredentialsUi 6>$null
for ($i = 0; $i -lt 300 -and $script:Jobs.Count; $i++) { Start-Sleep -Milliseconds 50; Receive-GLJobs 6>$null }
$retested = @($sales | Where-Object { $_.Status -eq 'OK' })
Assert ($logBox.Text -match 'Testing 1-3 of 3' -and $logBox.Text -match '    Sales DW: OK' -and $logBox.Text.IndexOf('    Sales DW: OK') -lt $logBox.Text.IndexOf('Tested after the credential update')) 'each test result is in the log as it comes, before the summary'
Assert ($retested.Count -eq 3 -and $logBox.Text -match 'Tested after the credential update: 3 of 3 work' -and $pwBox.Password -eq '') "Test them afterwards: the 3 updated connections are tested at once and all 3 work - and the password box is emptied ($($retested.Count))"
Set-Item -Path function:Confirm-GL -Value $keepConfirm
$script:Settings = $keepSettings; $script:LogFolder = $keepLogDir; $script:SignedInAs = $keepWho
$script:AuthMode = $keepMode; $script:State.ConnRows = @()
$script:UI = $keepUI   # $script:Pool stays: it is $pool
Disable-GLDemo
Remove-Item -Recurse -Force $wf

$r = Invoke-Worker 'Test-GLGuid "abcdef01-d9cb-469f-a165-70867728950e"'
Assert ($r -eq $true) 'worker runspaces can call the shared functions'

$r = Invoke-Worker '$x = New-GLRoleAssignmentBody -PrincipalId a -PrincipalType User -Role Owner; $x.role'
Assert ($r -eq 'Owner') 'functions that call other shared functions work in a worker'

$pool.Close(); $pool.Dispose()

# ============================================================================
Write-Host ''
$total = $script:Passed + $script:Failed
if ($script:Failed -eq 0) {
    Write-Host "All $total tests passed." -ForegroundColor Green
    exit 0
}
Write-Host "$($script:Failed) of $total tests FAILED." -ForegroundColor Red
exit 1
