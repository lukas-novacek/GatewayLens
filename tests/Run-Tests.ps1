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
# that belongs to someone. The tool has no reason to contain one.
$guidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$text   = Get-Content $script -Raw
$guids  = [regex]::Matches($text, $guidRx) | ForEach-Object Value
Assert (-not $guids) "no GUID literals in the script $(if ($guids) { '- found: ' + ($guids -join ', ') })"

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

$hereStrings = [regex]::Matches($text, "(?s)\`$script:(MainXaml|DialogXaml|PromptXaml|ModernStylesXaml|ClassicStylesXaml) = @'\r?\n(.*?)\r?\n'@")
Assert ($hereStrings.Count -eq 5) 'all five XAML blocks found (three windows, two style sets)'
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
$undefined = $script:WorkerFunctions | Where-Object { -not (Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue) }
Assert (-not $undefined) "every worker function is defined $(if ($undefined) { '- missing: ' + ($undefined -join ', ') })"

# ============================================================================
Section 'Small helpers'
# ============================================================================
Assert (Test-GLGuid '0f8fad5b-d9cb-469f-a165-70867728950e'.Replace('0f8fad5b', 'abcdef01')) 'a GUID is recognised'
Assert (-not (Test-GLGuid 'someone@contoso.com')) 'an email is not a GUID'
Assert (-not (Test-GLGuid '')) 'empty is not a GUID'

$secure = ConvertTo-SecureString 'plain-token' -AsPlainText -Force
Assert ((ConvertFrom-GLToken $secure) -eq 'plain-token') 'a SecureString token is converted to text'
Assert ((ConvertFrom-GLToken 'already-text') -eq 'already-text') 'a text token passes through'

$body = New-GLRoleAssignmentBody -PrincipalId 'p1' -PrincipalType 'Group' -Role 'User' | ConvertTo-Json -Compress -Depth 5
Assert ($body -match '"principal":\{' -and $body -match '"id":"p1"' -and $body -match '"type":"Group"' -and $body -match '"role":"User"') 'role assignment body has the documented shape'

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
Assert (-not ((Get-Content $sp -Raw) -match 'hunter2')) 'the saved file contains no password'

Set-Content -Path $sp -Value '{ this is not json'
$bad = Read-GLSettings -Path $sp
Assert ($bad.Theme -eq 'Light') 'a damaged settings file falls back to the defaults, no error'
Set-Content -Path $sp -Value '{"FontSize": 99, "History": {"PwdX": ["leak"]}}'
$cl = Read-GLSettings -Path $sp
Assert ($cl.FontSize -eq 20 -and -not $cl.History.Contains('PwdX')) 'out-of-range font size is clamped, password-like history is dropped on read'
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
Assert ($crows[2].Gateway -eq '' -and $crows[2].Credential -eq '') 'a cloud connection has no gateway and survives missing fields'

$f = Select-GLConnections -Rows $crows -Text 'sales'
Assert ($f.Count -eq 1 -and $f[0].Id -eq 'C1') 'search is case-insensitive across name and path'
$f = Select-GLConnections -Rows $crows -Gateway 'Cluster A'
Assert ($f.Count -eq 1) 'filter by gateway'
$f = Select-GLConnections -Rows $crows -Connectivity 'ShareableCloud'
Assert ($f.Count -eq 1 -and $f[0].Id -eq 'C3') 'filter by connectivity'
$f = Select-GLConnections -Rows $crows -Gateway '(all)' -Connectivity '(all)' -Type '(all)' -Text ''
Assert ($f.Count -eq 3) '(all) everywhere returns everything'
$f = Select-GLConnections -Rows $crows -Text 'nothing-matches-this'
Assert ($f -is [array] -and $f.Count -eq 0) 'no match is an empty array'

$d = Get-GLDistinct -Rows $crows -Property Type
Assert ($d[0] -eq '(all)' -and ($d -join ',') -eq '(all),Oracle,SQL,Web') "dropdown values: (all) first, sorted, distinct ($($d -join ','))"

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
$f = Select-GLConnections -Rows $mrows -States @('Online', 'Partial', 'Unknown')
Assert ($f.Count -eq 3) 'cloud connections count as Unknown for the state filter'
$ex = [System.Collections.Generic.HashSet[string]]::new([string[]]@('C2'))
$f = Select-GLConnections -Rows $mrows -Excluded $ex
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

Assert ((ConvertFrom-GLConnectionString 'Data Source=s;Initial Catalog=d').Type -eq 'Sql') 'type guess: SQL Server keywords give Sql'
Assert ((ConvertFrom-GLConnectionString 'Host=o;Service Name=P').Type -eq 'Oracle') 'type guess: Oracle keywords give Oracle'
Assert ((ConvertFrom-GLConnectionString 'Server=pg;Database=d').Type -eq '') 'type guess: ambiguous strings are left blank'

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
$script:Rules = @{ 'POST https://api.powerbi.com' = [pscustomobject]@{ id = 'NEW1' } }
$r = New-GLGatewayConnection -GatewayId 'G1' -PublicKey $pk -Name 'Sales' -DataSourceType 'Sql' -ConnectionDetails '{"server":"s","database":"d"}' -CredentialType Windows -Username 'DOM\u' -Password 'p' -PbiToken 't'
$c = $script:Calls[0]
Assert ($c.Method -eq 'POST' -and $c.Uri -like '*/gateways/G1/datasources' -and $r.id -eq 'NEW1') 'create: POST to the gateway''s datasources'
Assert ($c.Body.connectionDetails -is [string] -and $c.Body.datasourceName -eq 'Sales' -and $c.Body.dataSourceType -eq 'Sql') 'create: connectionDetails is a JSON STRING, as the API requires'

Reset-Calls
Remove-GLConnection -Id 'C9' -FabricToken 'f'
Assert ($script:Calls[0].Method -eq 'DELETE' -and $script:Calls[0].Uri -eq 'https://api.fabric.microsoft.com/v1/connections/C9') 'delete: the documented Fabric call'

Reset-Calls
Set-GLMemberEnabled -GatewayId 'G1' -MemberId 'M1' -Enabled $false -FabricToken 'f'
$c = $script:Calls[0]
Assert ($c.Method -eq 'PATCH' -and $c.Uri -like '*/v1/gateways/G1/members/M1' -and $c.Body.enabled -eq $false) 'disable member: PATCH enabled=false on the member'

Assert ((ConvertTo-GLConnectionDetails -Server ' sql01 ' -Database 'Sales') -eq '{"server":"sql01","database":"Sales"}') 'connection details from server and database, trimmed'
Assert ((ConvertTo-GLConnectionDetails -Url 'https://x') -eq '{"url":"https://x"}') 'connection details from a url'
Assert ((ConvertTo-GLConnectionDetails -Server 'ignored' -Json '{"extensionDataSourceKind":"Snowflake"}') -eq '{"extensionDataSourceKind":"Snowflake"}') 'explicit JSON wins, for connectors this does not know'
$err = $null; try { ConvertTo-GLConnectionDetails -Json '{bad' } catch { $err = $_.Exception.Message }
Assert ($err -match 'not valid JSON') 'broken JSON is refused before sending'
$err = $null; try { ConvertTo-GLConnectionDetails } catch { $err = $_.Exception.Message }
Assert ($err -match 'No connection details') 'an empty row is refused'

# ============================================================================
Section 'Connection strings, names and addresses'
# ============================================================================
$cs = ConvertFrom-GLConnectionString 'Data Source=sql01.contoso.com,1433;Initial Catalog=Sales;Integrated Security=True'
Assert ($cs.Server -eq 'sql01.contoso.com,1433' -and $cs.Database -eq 'Sales') 'SQL Server style: Data Source + Initial Catalog'
$cs = ConvertFrom-GLConnectionString 'Server=pg01;Port=5432;Database=dw;User Id=x'
Assert ($cs.Server -eq 'pg01:5432' -and $cs.Database -eq 'dw') 'Server + Port + Database, port joined on'
$cs = ConvertFrom-GLConnectionString 'Host=ora01;Port=1521;Service Name=PROD'
Assert ($cs.Server -eq 'ora01:1521' -and $cs.Database -eq 'PROD') 'Oracle style: Host + Port + Service Name'
$cs = ConvertFrom-GLConnectionString 'not a connection string'
Assert ($cs.Server -eq '' -and $cs.Database -eq '') 'nonsense gives empty fields, not an error'

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
Assert ($back[0].Access -eq 'jane@contoso.com (User, Owner)') "backup: who had access, and in which role ($($back[0].Access))"
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

$gwList = @(
    [pscustomobject]@{ id = 'G1'; displayName = 'Prod Cluster'; type = 'OnPremises'; publicKey = $pk }
    [pscustomobject]@{ id = 'GV'; displayName = 'VNet';         type = 'VirtualNetwork' }
)
$rows = @(
    [pscustomobject]@{ Gateway = 'prod cluster'; Name = 'Sales'; Type = 'Sql'; Server = 's'; Database = 'd'; CredentialType = 'Windows'; Username = 'DOM\u' }
    [pscustomobject]@{ Gateway = '';             Name = 'Web';   Type = 'Web'; Url = 'https://x'; CredentialType = 'Anonymous' }
    [pscustomobject]@{ Gateway = 'VNet';         Name = 'Bad';   Type = 'Sql'; Server = 's' }
    [pscustomobject]@{ Gateway = 'Prod Cluster'; Name = '';      Type = 'Sql'; Server = 's' }
)
Reset-Calls
$script:Rules = @{ 'POST https://api.powerbi.com' = [pscustomobject]@{ id = 'NEW' } }
$res = Invoke-GLBulkCreate -Rows $rows -Gateways $gwList -DefaultGateway 'G1' -Password 'p' -PbiToken 't' -Progress @{ Cancel = $false }
Assert ($res[0].Ok -and $res[1].Ok) 'create: by gateway name (any case) and by the default gateway'
Assert (-not $res[2].Ok -and $res[2].Message -match "no on-premises gateway called 'VNet'") 'create: a VNet gateway is refused - this API is for on-premises gateways'
Assert (-not $res[3].Ok -and $res[3].Message -match 'no Name') 'create: a row without a name is refused'
Assert (@($script:Calls | Where-Object Method -eq 'POST').Count -eq 2) 'create: only the valid rows are sent'

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
Section 'Activity log and change record'
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
Assert ($all.Count -eq 3 -and $all[0].User -eq 'joe@contoso.com') 'the Activity view reads every user''s record, newest first'
Assert ($all[0].When -is [datetime] -and $all[0].When.Kind -eq 'Local') 'times are shown in your own time zone'
Assert ((Select-GLChanges -Rows $all -Result 'Failed').Count -eq 1) 'filter by result'
Assert ((Select-GLChanges -Rows $all -Action 'Disable member').Count -eq 1) 'filter by action'
Assert ((Select-GLChanges -Rows $all -Text 'cluster a').Count -eq 1) 'search across target, gateway, principal and details'
Assert ((Select-GLChanges -Rows $all -User 'jane@contoso.com').Count -eq 2) 'filter by user'
Assert ((Select-GLChanges -Rows $all -Days 1).Count -eq 3) 'filter by period'
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
Assert ($r[0].Result -eq 'Done' -and $r[0].Role -eq 'UserWithReshare' -and $r[0].PrincipalId -eq 'U1') 'remove: the role that was removed is recorded - what undo needs'
Assert ($r[1].Result -eq 'NoChange') 'remove: a connection they were not on is recorded as no change'
$c = @($rec | Where-Object Action -eq 'Update credentials')
Assert ($c[0].Result -eq 'Done' -and $c[0].Details -match 'Username=svc_report' -and $c[1].Result -eq 'Skipped') 'credentials: done and skipped are both recorded, with the username'
Assert (-not ((Get-Content (Get-GLChangePath -Folder $bf -User 'jane@contoso.com') -Raw) -match 'Tr0ub4dor')) 'the password is nowhere in the change record'
Assert (@($rec | Select-Object -ExpandProperty RunId -Unique).Count -eq 1) 'one run, one run id on every row'

# ============================================================================
Section 'Undo'
# ============================================================================
$script:Calls.Clear()
$script:Rules = @{ 'GET https://api.fabric.microsoft.com/v1/connections/C1/roleAssignments' = [pscustomobject]@{ value = @(
    [pscustomobject]@{ id = 'RA9'; role = 'UserWithReshare'; principal = [pscustomobject]@{ id = 'U1'; displayName = 'Joe'; type = 'User' } }
    [pscustomobject]@{ id = 'RA8'; role = 'Owner';           principal = [pscustomobject]@{ id = 'U1'; displayName = 'Joe'; type = 'User' } }) } }
$undoRows = @(
    [pscustomobject]@{ Action = 'Grant access';   Result = 'Done'; TargetType = 'Connection'; Target = 'one'; TargetId = 'C1'; Principal = 'Joe'; PrincipalId = 'U1'; PrincipalType = 'User'; Role = 'UserWithReshare'; User = 'jane'; Time = 't'; RunId = 'r1' }
    [pscustomobject]@{ Action = 'Remove access';  Result = 'Done'; TargetType = 'Gateway';    Target = 'GA';  TargetId = 'G1'; Principal = 'Ann'; PrincipalId = 'U2'; PrincipalType = 'Group'; Role = 'Admin'; User = 'jane'; Time = 't'; RunId = 'r1' }
    [pscustomobject]@{ Action = 'Disable member'; Result = 'Done'; TargetType = 'Gateway member'; Target = 'n1'; TargetId = 'M1'; GatewayId = 'G1'; Gateway = 'GA'; User = 'jane'; Time = 't'; RunId = 'r1' }
    [pscustomobject]@{ Action = 'Delete connection'; Result = 'Done'; Target = 'gone'; TargetId = 'C9' }
    [pscustomobject]@{ Action = 'Grant access';   Result = 'Failed'; Target = 'x'; TargetId = 'C5' }
)
Assert (@($undoRows | Where-Object { Test-GLUndoable $_ }).Count -eq 3) 'only completed access and member changes can be undone'
$ua  = New-GLAudit -Folder (Join-Path $lf 'undo') -User 'jane' -Tenant 't' -Version 'v'
$ur  = Invoke-GLUndo -Rows $undoRows -FabricToken 'f' -Audit $ua -Progress @{ Cancel = $false }
$dels = @($script:Calls | Where-Object Method -eq 'DELETE')
Assert ($dels.Count -eq 1 -and $dels[0].Uri -like '*/connections/C1/roleAssignments/RA9') 'undo a grant: removes exactly that role, not the Owner role beside it'
$post = @($script:Calls | Where-Object Method -eq 'POST')
Assert ($post.Count -eq 1 -and $post[0].Uri -like '*/gateways/G1/roleAssignments' -and $post[0].Body.role -eq 'Admin' -and $post[0].Body.principal.type -eq 'Group') 'undo a removal: grants the same role again, on the right kind of target'
$patch = @($script:Calls | Where-Object Method -eq 'PATCH')
Assert ($patch.Count -eq 1 -and $patch[0].Uri -like '*/gateways/G1/members/M1' -and $patch[0].Body.enabled -eq $true) 'undo a disable: enables the member again'
Assert (-not $ur[3].Ok -and $ur[3].Message -match 'cannot be undone' -and -not $ur[4].Ok) 'a delete, or a change that failed, is refused - nothing is sent for it'
$ul = @(Import-Csv (Get-GLChangePath -Folder $ua.Folder -User 'jane'))
Assert ($ul.Count -eq 3 -and -not ($ul | Where-Object { $_.Details -notlike 'undo of *' })) 'every undo is itself recorded, marked as the undo of the original'
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
Assert ($s.Users.Count -eq 6 -and $s.Connections.Count -eq 26 -and $s.Gateways.Count -eq 6) "the company is built: 6 people, 6 gateways, 26 connections ($($s.Users.Count), $($s.Gateways.Count), $($s.Connections.Count))"
$allIds = @($s.Connections | ForEach-Object id) + @($s.Gateways | ForEach-Object id) + @($s.Users | ForEach-Object id)
Assert (@($allIds | Sort-Object -Unique).Count -eq $allIds.Count) 'every id is unique'
Assert ((New-GLDemoId 'x') -eq (New-GLDemoId 'x') -and (Test-GLGuid (New-GLDemoId 'x'))) 'demo ids are stable and shaped like real ones'
Assert ((Get-GLToken Fabric) -eq 'demo-token') 'no sign-in: the demo hands out its own token'

$gd   = Get-GLGatewayData -FabricToken $T -PbiToken $T -LiveStatus
$grow = ConvertTo-GLGatewayRows -Gateways $gd.Gateways -Members $gd.Members -Live $gd.Live
$gs   = @{}; foreach ($r in $grow) { $gs[$r.Name] = Get-GLGatewayState $r.Online }
Assert ($gs['Contoso Prod Cluster'] -eq 'Online' -and $gs['Contoso Finance Cluster'] -eq 'Partial' -and $gs['Legacy Warehouse Gateway'] -eq 'Offline' -and $gs['Contoso Test Cluster'] -eq 'Partial') 'gateways in every state: online, partly online, offline'
Assert (@($gd.Live.Values | Where-Object Status -eq 'Timeout').Count -eq 1) 'and one member that does not answer'

$cd   = Get-GLConnectionData -FabricToken $T
$crow = ConvertTo-GLConnectionRows -Connections $cd.Connections -GatewayNames (Get-GLGatewayNameMap -Gateways $cd.Gateways)
Add-GLDirectoryInfo -Rows $crow -Directory (Get-GLDatasourceDirectory -PbiToken $T)
$byN  = @{}; foreach ($r in $crow) { $byN[$r.Name] = $r }
$hr   = $byN['HR Core']
Assert ($crow.Count -eq 26 -and $hr.Gateway -eq 'Contoso Prod Cluster' -and $hr.Account -eq 'CONTOSO\svc_hr') 'connections come with gateway names and the account in their credentials'

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

$jane = Resolve-GLPrincipal -Value 'jane.doe@contoso.com' -Type User -GraphToken $T
$grp  = Resolve-GLPrincipal -Value 'Finance Analysts' -Type Group -GraphToken $T
Assert ($jane.DisplayName -eq 'Jane Doe <jane.doe@contoso.com>' -and $grp.DisplayName -eq 'Finance Analysts <finance-analysts@contoso.com>') 'people and groups are found by email and by name'
$err = $null; try { Resolve-GLPrincipal -Value 'nobody@contoso.com' -Type User -GraphToken $T } catch { $err = $_.Exception.Message }
Assert ($err -match "No User found for 'nobody@contoso.com'") 'someone who does not exist is refused by name'

$two = @($byN['Product Catalog'], $byN['Sales DW'])
$who = @([pscustomobject]@{ Id = $jane.Id; DisplayName = $jane.DisplayName; Type = 'User' })
$g1 = Invoke-GLBulkGrant -Items $two -Principals $who -Role 'User' -FabricToken $T -Progress @{ Cancel = $false } -Audit $au
Assert ($g1[0].Message -like 'granted User*' -and $g1[1].Message -like '*already has access') 'grant: new access, and "already has access" where she had it'
$v1 = Invoke-GLBulkRevoke -Items $two -Principals $who -FabricToken $T -Progress @{ Cancel = $false } -Audit $au
$ras  = Get-GLRoleAssignments -Kind connections -Id $byN['Sales DW'].Id -FabricToken $T
$left = @($ras | Where-Object { $_.principal.id -eq $jane.Id })
Assert (@($v1 | Where-Object Ok).Count -eq 2 -and $left.Count -eq 0) 'remove: gone from both'
$changes = Read-GLChanges -Folder $dl
$undo = @($changes | Where-Object { $_.Action -eq 'Remove access' -and $_.Result -eq 'Done' })
$u1 = Invoke-GLUndo -Rows $undo -FabricToken $T -Audit $au -Progress @{ Cancel = $false }
$ras  = Get-GLRoleAssignments -Kind connections -Id $byN['Sales DW'].Id -FabricToken $T
$back = @($ras | Where-Object { $_.principal.id -eq $jane.Id -and $_.role -eq 'User' })
Assert ($undo.Count -eq 2 -and @($u1 | Where-Object Ok).Count -eq 2 -and $back.Count -eq 1) 'undo, from the change record: she is back, with the same role'
$ras    = Get-GLRoleAssignments -Kind connections -Id $byN['Web API Sandbox'].Id -FabricToken $T
$owners = @($ras | Where-Object role -eq 'Owner')
$err = $null
foreach ($o in $owners) { try { Remove-GLRoleAssignment -Kind connections -Id $byN['Web API Sandbox'].Id -AssignmentId $o.id -FabricToken $T } catch { $err = $_.Exception.Message } }
Assert ($err -match 'LastOwnerCannotBeRemoved') 'the last owner of a connection cannot be removed'

$prodGw = $cd.Gateways | Where-Object displayName -eq 'Contoso Prod Cluster'
$m2 = $s.Members[$prodGw.id][1]
Set-GLMemberEnabled -GatewayId $prodGw.id -MemberId $m2.id -Enabled $false -FabricToken $T
Assert ($m2.enabled -eq $false) 'a member is disabled'
Set-GLMemberEnabled -GatewayId $prodGw.id -MemberId $m2.id -Enabled $true -FabricToken $T

$testGw = $cd.Gateways | Where-Object displayName -eq 'Contoso Test Cluster'
$newRow = [pscustomobject]@{ Gateway = 'contoso test cluster'; Name = 'Scratch DB'; Type = 'Sql'; Server = 'sqltst02.contoso.local'; Database = 'Scratch'; CredentialType = 'Basic'; Username = 'scratch_user' }
$c1 = Invoke-GLBulkCreate -Rows @($newRow) -Gateways $cd.Gateways -Password 'pw' -PbiToken $T -Progress @{ Cancel = $false } -Audit $au
$c2 = Invoke-GLBulkCreate -Rows @($newRow) -Gateways $cd.Gateways -Password 'pw' -PbiToken $T -Progress @{ Cancel = $false } -Audit $au
$made = $s.Connections | Where-Object displayName -eq 'Scratch DB'
Assert ($c1[0].Ok -and $made.gatewayId -eq $testGw.id -and $made.connectionDetails.path -eq 'sqltst02.contoso.local;Scratch' -and $s.Accounts[$made.id] -eq 'scratch_user') 'create: the connection exists, on the right gateway, with its account'
Assert (-not $c2[0].Ok -and $c2[0].Message -match 'already exists') 'create: the same name twice on one gateway is refused'

$bk = Join-Path $dl 'backup.csv'
$mi = ConvertTo-GLConnectionRows -Connections @($made) -GatewayNames (Get-GLGatewayNameMap -Gateways $cd.Gateways)
$null = Backup-GLConnections -Items $mi -Path $bk
$d1 = Invoke-GLBulkDelete -Items $mi -BackupPath $bk -FabricToken $T -Progress @{ Cancel = $false } -Audit $au
Assert ($d1[0].Ok -and -not ($s.Connections | Where-Object displayName -eq 'Scratch DB')) 'delete, after its backup: gone'

Assert ((Resolve-GLHostAddress -Machine 'CTSGW-PRD01') -match '^10\.20\.\d+\.\d+;CTSGW-PRD01$' -and (Resolve-GLHostAddress -Machine 'LEGGW-01') -eq 'UNKNOWN;LEGGW-01') 'Resolve IPs works in the demo - with one machine missing from DNS'

$rec = @(Import-Csv (Get-GLChangePath -Folder $dl -User 'demo.user@contoso.com'))
Assert (@($rec | Select-Object -ExpandProperty Action -Unique).Count -ge 5 -and -not ((Get-Content (Get-GLChangePath -Folder $dl -User 'demo.user@contoso.com') -Raw) -match 'Correct horse')) 'every demo change is in the change record - and no password'

$ok = Invoke-GLSelfTest 6>$null
Assert ($ok) 'the self-test passes against the demo, every check'

# the background workers see the same Contoso - the window depends on it
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
foreach ($n in $script:WorkerFunctions) { $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($n, (Get-Item "function:$n").Definition)) }
$rs = [runspacefactory]::CreateRunspace($iss); $rs.Open()
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void]$ps.AddScript({ param($T, $G, $M) $d = Get-GLConnectionData -FabricToken $T; Set-GLMemberEnabled -GatewayId $G -MemberId $M -Enabled $false -FabricToken $T; @($d.Connections).Count }).AddArgument($T).AddArgument($prodGw.id).AddArgument($m2.id)
$wc = $ps.Invoke()
$ps.Dispose(); $rs.Dispose()
Assert ($wc[0] -eq 26 -and $m2.enabled -eq $false) 'a background worker reads and changes the same demo company as the window'

$hist = Join-Path $dl 'history'
Initialize-GLDemoHistory -Folder $hist
$hr2 = Read-GLChanges -Folder $hist
$mine = @($hr2 | Where-Object { $_.User -eq 'demo.user@contoso.com' -and (Test-GLUndoable $_) })
Assert ($hr2.Count -eq 8 -and @($hr2 | Select-Object -ExpandProperty User -Unique).Count -eq 2 -and $mine.Count -eq 2) 'a week of history from two people, two of the changes yours to undo'
$u2 = Invoke-GLUndo -Rows $mine -FabricToken $T -Audit $au -Progress @{ Cancel = $false }
$joe = $s.Users | Where-Object displayName -eq 'Joe Smith'; $raj = $s.Users | Where-Object displayName -eq 'Raj Patel'
$ras1 = Get-GLRoleAssignments -Kind connections -Id $byN['Sales DW'].Id -FabricToken $T
$ras2 = Get-GLRoleAssignments -Kind connections -Id $byN['Customer 360'].Id -FabricToken $T
$joeLeft = @($ras1 | Where-Object { $_.principal.id -eq $joe.id })
$rajBack = @($ras2 | Where-Object { $_.principal.id -eq $raj.id })
Assert (@($u2 | Where-Object Ok).Count -eq 2 -and $joeLeft.Count -eq 0 -and $rajBack.Count -eq 1) 'the history matches the company: undoing it really changes access'
Initialize-GLDemoHistory -Folder $hist
Assert ((Read-GLChanges -Folder $hist).Count -eq 8) 'the history is written once, not on every start'

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
$windowsXaml = $xamlBy.MainXaml + $xamlBy.DialogXaml + $xamlBy.PromptXaml
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
$pwBoxes = @([regex]::Matches($xamlBy.MainXaml, '<(\w+) Name="(Pwd\w+)"') | ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" })
Assert ($pwBoxes.Count -eq 2 -and -not ($pwBoxes | Where-Object { $_ -notlike 'PasswordBox *' })) "both password fields are masked PasswordBoxes ($($pwBoxes -join ', '))"

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
    Assert ($codeBrushes.Count -ge 3 -and -not $miss) "theme '$name' has the row colours the code asks for ($($codeBrushes -join ', ')) $(if ($miss) { '- missing: ' + ($miss -join ', ') })"
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

# what the window checks after the smoke run, tested on any OS by setting the state it reads
$keepStyle = $script:StyleMode; $keepErr = $script:StyleError; $keepSmoke = $script:Smoke
$keepRows = @{ G = $script:State.GatewayRows; C = $script:State.ConnRows; A = $script:State.Changes }
$script:StyleMode = 'Modern'; $script:StyleError = $null; $script:LogEntries.Clear()
$script:Smoke = @{ Plan = @(1, 2, 3); Next = 3 }
$script:State.GatewayRows = @(1..6); $script:State.ConnRows = @(1..26); $script:State.Changes = @(1..8)
Assert ((Get-GLSmokeVerdict).Count -eq 0) 'smoke verdict: a clean run passes'
$script:StyleMode = 'Classic'; $script:StyleError = 'bad template'
$script:LogEntries.Add([pscustomobject]@{ Level = 'Error'; Line = '12:00:00  ERROR  boom' })
$script:Smoke.Next = 2
$v = Get-GLSmokeVerdict
Assert ($v.Count -eq 3 -and ($v -join ' ') -match 'bad template' -and ($v -join ' ') -match 'boom' -and ($v -join ' ') -match 'step 2 of 3') 'smoke verdict: falling back to the classic look, an error, or an unfinished run all fail'
$script:State.ConnRows = @(1..3)
Assert (((Get-GLSmokeVerdict) -join ' ') -match 'connections shown: 3, expected 26') 'smoke verdict: missing demo data fails'
$script:StyleMode = $keepStyle; $script:StyleError = $keepErr; $script:Smoke = $keepSmoke; $script:LogEntries.Clear()
$script:State.GatewayRows = $keepRows.G; $script:State.ConnRows = $keepRows.C; $script:State.Changes = $keepRows.A

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
Initialize-GLDemoHistory -Folder $wf
$r = Invoke-Worker "Read-GLChanges -Folder '$wf'"
Assert ($r.Count -eq 8 -and $r[0].Action -and $r[0].User -and $r[0].When -is [datetime]) 'the change record arrives from a worker whole - every change, every field'
$cid = (Get-GLDemoStore).Connections[0].id
$r = Invoke-Worker "Get-GLRoleAssignments -Kind connections -Id '$cid' -FabricToken 'demo-token'"
Assert ($r.Count -ge 2 -and $r[0].role -and $r[0].principal.displayName) 'who has access arrives from a worker whole'
$r = Invoke-Worker ('$s = Get-GLDemoStore; $c = $s.Connections[2]; $u = $s.Users[3]; ' +
    'Invoke-GLBulkGrant -Items @([pscustomobject]@{ Id = $c.id; Name = $c.displayName }) ' +
    '-Principals @([pscustomobject]@{ Id = $u.id; DisplayName = $u.displayName; Type = "User" }) -Role User -FabricToken demo-token -Progress @{ Cancel = $false }')
Assert ($r.Count -eq 1 -and $r[0].Name -eq 'Customer 360' -and $r[0].Ok -eq $true -and $r[0].Message -like 'granted User to Ana Novak') "bulk results arrive from a worker whole - name, outcome and reason ($($r[0].Name): $($r[0].Message))"

# the window's own Activity refresh, with stand-in controls: the path that came back empty
$keepUI = $script:UI; $keepFolder = $script:LogFolder
$script:UI = @{}
foreach ($n in 'CmbActAction', 'CmbActUser', 'CmbActPeriod', 'CmbActResult', 'TxtActFind', 'GridActivity', 'TxtActCount', 'Busy', 'BtnCancel', 'TxtStatus') {
    $script:UI[$n] = [pscustomobject]@{ ItemsSource = $null; SelectedItem = '(all)'; SelectedIndex = 0; Text = ''; Visibility = ''; IsIndeterminate = $false; Maximum = 0; Value = 0 }
}
$script:UI.CmbActPeriod.SelectedItem = '30 days'
$script:LogFolder = $wf
$script:Pool = $pool    # careful: names ignore case - in this file $pool and $script:Pool are ONE variable
$script:Jobs = [System.Collections.Generic.List[object]]::new()
$script:State.Changes = @()
Invoke-GLActivityRefresh 6>$null
for ($i = 0; $i -lt 100 -and $script:Jobs.Count; $i++) { Start-Sleep -Milliseconds 50; Receive-GLJobs 6>$null }
Assert (@($script:State.Changes).Count -eq 8 -and @($script:UI.GridActivity.ItemsSource).Count -eq 8 -and @($script:UI.GridActivity.ItemsSource)[0].Action) "the Activity tab's own refresh shows every change ($(@($script:State.Changes).Count) loaded, $(@($script:UI.GridActivity.ItemsSource).Count) shown)"
$script:UI = $keepUI; $script:LogFolder = $keepFolder; $script:State.Changes = @()   # $script:Pool stays: it is $pool
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
