<#
.SYNOPSIS
    GatewayLens - a lightweight desktop console for Microsoft on-premises data
    gateways and the connections that run on them, for Power BI and Microsoft Fabric.

.DESCRIPTION
    One PowerShell script. No database, no server components, no modules to
    install. It signs in through the browser as you - with Az.Accounts if that is
    installed, by itself if not - and talks to Microsoft's REST APIs with your
    permissions:

      Fabric REST API     (documented)   gateways, members, connections, access
      Power BI REST API   (documented)   connection health test
      Power BI v2 API     (UNOFFICIAL)   live member status - the endpoint behind the
                                         portal's Manage gateways page. Optional, used
                                         for the Status column only, and the only part
                                         that would stop working if Microsoft changed it.
      Microsoft Graph     (documented)   turning a UPN or group name into an object id

    Run with -SelfTest first: it calls every endpoint once and reports what works
    with your account in your tenant.

.PARAMETER TenantId
    Tenant to sign in to. Optional - your home tenant is used if omitted.

.PARAMETER DeviceCode
    Sign in with a code on another device instead of a browser on this one.

.PARAMETER Account
    The account to sign in with, for example an admin account that differs from
    your Windows account. Default: the account you are signed in to Windows with.

.PARAMETER ClientId
    The application (client) id of your own app registration, to use instead of
    the one built into GatewayLens. docs/sign-in.md explains when and how.

.PARAMETER SignIn
    Auto (default) signs in through Az.Accounts when it is installed - no approval
    needed - and otherwise by itself, as GatewayLens's own app registration, which
    your organisation approves once. AzAccounts or Browser chooses one.

.PARAMETER DnsSuffix
    Extra DNS suffixes to try when resolving gateway machine names to IP
    addresses, for names Windows does not resolve on its own. Optional.

.PARAMETER BackupFolder
    Where the automatic backup is written before connections are deleted.
    Default: Documents\GatewayLens\backups.

.PARAMETER LogFolder
    Where the daily log files and the change records are kept. Default:
    %LOCALAPPDATA%\GatewayLens\logs. Several people can share one folder - each
    person writes only to files carrying their own name.

.PARAMETER Demo
    Opens GatewayLens on Contoso, a fictional company, with no sign-in and no
    tenant: gateways online, offline and slow, connections that fail for real-looking
    reasons, people and groups. Every button works against that data and nothing
    leaves the computer. The demo keeps its own log and change record, apart from
    the real ones. Good for trying things out and for screenshots.

.PARAMETER Kiosk
    Opens straight into the kiosk view: full screen, gateway tiles only, nothing
    that changes anything, refreshing every minute - for a wall screen. Esc or
    F11 leaves it.

.PARAMETER SmokeTest
    For the test suite: opens the real window on demo data, steps through every
    theme and tab, closes it, and exits 0 only if nothing went wrong. Your own
    settings are not touched.

.PARAMETER Screenshots
    For the README: opens the real window on demo data, takes pictures of the
    gateway wall, the connections, a test run, the kiosk view and more, saves them
    as screenshot-*.png in this folder (assets, for the README) and closes. Contoso is fictional - nothing real
    is in them.

.PARAMETER Inspect
    Signs in and lists the fields Microsoft's APIs return for gateways and
    connections - names and dates only, no data. Safe to share.

.PARAMETER Launched
    Set by GatewayLens.exe. Problems before the window opens are shown in a
    message box, since there is no console to read them in.

.PARAMETER SelfTest
    Sign in, call every API once read-only, print the results and exit.

.PARAMETER LoadOnly
    Define the functions and stop. Used by the test suite; not for normal use.

.EXAMPLE
    ./GatewayLens.ps1

.EXAMPLE
    ./GatewayLens.ps1 -SelfTest

.EXAMPLE
    ./GatewayLens.ps1 -TenantId contoso.onmicrosoft.com -DeviceCode
#>
#Requires -Version 7.2
# (#Requires must sit BELOW the help block - above it, Get-Help ignores the help.)
[CmdletBinding()]
param(
    [string]$TenantId,
    [switch]$DeviceCode,
    [string]$Account,
    [string]$ClientId,
    [ValidateSet('Auto', 'AzAccounts', 'Browser')]
    [string]$SignIn = 'Auto',
    [string[]]$DnsSuffix = @(),
    [string]$BackupFolder,
    [string]$LogFolder,
    [switch]$SelfTest,
    [switch]$Inspect,
    [switch]$Demo,
    [switch]$Kiosk,
    [switch]$SmokeTest,
    [string]$Screenshots,
    [switch]$Launched,
    [switch]$LoadOnly
)

$script:AppName    = 'GatewayLens'
# Documents can be missing (non-Windows, or an unusual profile), and this line runs
# whenever the script loads - so fall back rather than fail.
$docs = [Environment]::GetFolderPath('MyDocuments')
if (-not $docs) { $docs = $HOME }
if (-not $docs) { $docs = [System.IO.Path]::GetTempPath() }
if (-not $BackupFolder) { $BackupFolder = Join-Path (Join-Path $docs 'GatewayLens') 'backups' }   # the parameter is the script variable
$appData = [Environment]::GetFolderPath('LocalApplicationData')
if (-not $appData) { $appData = $docs }
if (-not $LogFolder) { $LogFolder = Join-Path (Join-Path $appData 'GatewayLens') 'logs' }   # the parameter is the script variable
$script:DnsSuffixes = @($DnsSuffix | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# Strict mode, if the caller's session has it on, would make every optional field in
# an API answer an error - Microsoft's APIs leave fields out freely, and this script
# reads them defensively instead. So the script sets its own rules.
Set-StrictMode -Off

$script:AppVersion = '0.9.0'
# What is new, in a few lines for the window - shown once after an update. The full
# list is CHANGELOG.md. The tests check that it is about the current version.
$script:WhatsNew = @{
    Version = '0.9.0'
    Lines   = @(
        'Alerts when a gateway member goes down, and when it is back: a Windows notification, a sound, or a message in Teams or a Power Automate flow. Off until you turn them on - Alerts on the Gateways tab.'
        'The taskbar button turns yellow while a gateway is degraded, red while one is offline.'
        'The status bar says what is loading and how far it is, and shows what GatewayLens uses - CPU, memory, workers, calls to Microsoft.'
        'Access lists match the portal. Accounts that are no longer in Microsoft Entra ID are counted apart - tick Show to see or remove them.'
        'A countdown to the next automatic refresh on the Gateways tab.'
        'Update credentials the way the portal does: the username stays visible in the Account column and in the portal.'
        'A start page: sign in when you are ready, or try the demo first.'
        'Names everywhere: the Users column and the User filter show people, not object ids.'
    )
}

$script:GatewayRoles    = @('Admin', 'ConnectionCreator', 'ConnectionCreatorWithResharing')
$script:ConnectionRoles = @('Owner', 'User', 'UserWithReshare')
$script:PrincipalTypes  = @('User', 'Group', 'ServicePrincipal', 'ServicePrincipalProfile')

# ============================================================================
#  CORE
#
#  Everything below runs both on the UI thread and inside the background worker
#  runspaces, so each function is self-contained: base URLs are written out in
#  full and nothing reads a variable from outside its own parameters.
# ============================================================================

function Test-GLGuid {
    param([string]$Value)
    return [bool]($Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
}

function ConvertFrom-GLApiError {
    <#
        One readable line from a Microsoft error body, whatever its shape:
          Fabric       {"errorCode": "...", "message": "..."}
          Graph        {"error": {"code": "...", "message": "..."}}
          Power BI     {"error": {"code": "...", "pbi.error": {"details": [...]}}}
        For Power BI the gateway's own reason is the detail whose code ends in
        UnderlyingErrorMessage - the first detail is usually just a number. The
        key really is named "pbi.error", with a dot; a nested pbi/error is read too.
        Anything that is not JSON comes back as it was.
    #>
    param($Body)
    if ($null -eq $Body) { return '' }
    $o = $Body
    if ($Body -is [string]) {
        $t = $Body.Trim()
        if (-not ($t.StartsWith('{'))) { return $t }
        try { $o = $t | ConvertFrom-Json -ErrorAction Stop } catch { return $t }
    }
    if ($o.errorCode -or ($o.message -and -not $o.error)) {
        return (@($o.errorCode, $o.message) | Where-Object { $_ }) -join ': '
    }
    $e = $o.error
    if (-not $e) { return ($o | ConvertTo-Json -Compress -Depth 6) }
    $code = [string]$e.code
    $pbi  = $null
    $prop = $e.PSObject.Properties['pbi.error']
    if ($prop) { $pbi = $prop.Value } elseif ($e.pbi -and $e.pbi.error) { $pbi = $e.pbi.error }
    $why = ''
    if ($pbi -and $pbi.details) {
        $d = @($pbi.details)
        $msg = $d | Where-Object { [string]$_.code -like '*UnderlyingErrorMessage' -and $_.detail.value } | Select-Object -First 1
        if (-not $msg) { $msg = $d | Where-Object { $_.detail.value -and [string]$_.detail.value -notmatch '^-?\d+$' } | Select-Object -First 1 }
        if ($msg) { $why = [string]$msg.detail.value }
    }
    if (-not $why -and $e.message) { $why = [string]$e.message }
    return (@($code, $why) | Where-Object { $_ }) -join ': '
}

# How many calls this session made, and how many Microsoft throttled - shared by the
# window and every worker in the process, for the meter in the status bar.
if (-not [System.AppDomain]::CurrentDomain.GetData('GatewayLens.Stats')) {
    [System.AppDomain]::CurrentDomain.SetData('GatewayLens.Stats', [hashtable]::Synchronized(@{ Calls = 0; Throttled = 0 }))
}

function Add-GLStat([string]$Name, [int]$By = 1) {
    $st = [System.AppDomain]::CurrentDomain.GetData('GatewayLens.Stats')
    if ($st) { $st[$Name] = [long]$st[$Name] + $By }
}

function Invoke-GLRequest {
    <#
        One REST call. Retries throttling (429) and server errors (5xx), honouring
        Retry-After. Any other failure is thrown with the method, the URL and the
        API's own error text, because "400 Bad Request" alone helps nobody.
    #>
    [CmdletBinding()]
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        $Body,
        [int]$MaxRetry = 4
    )
    Add-GLStat Calls
    if ([System.AppDomain]::CurrentDomain.GetData('GatewayLens.Demo')) {      # -Demo: answered locally, nothing is sent
        $d = Invoke-GLDemoHttp -Method $Method -Uri $Uri -Body $Body
        if ($d.Status -ge 200 -and $d.Status -lt 300) { return $d.Body }
        $what = if ($d.Status) { "HTTP $($d.Status)" } else { 'no answer' }
        throw "$Method $Uri -> $what : $(ConvertFrom-GLApiError $d.Body)"
    }
    $headers = @{ Authorization = "Bearer $Token" }
    for ($attempt = 1; ; $attempt++) {
        try {
            $p = @{ Method = $Method; Uri = $Uri; Headers = $headers; ErrorAction = 'Stop' }
            if ($null -ne $Body) {
                $p.Body        = ($Body | ConvertTo-Json -Depth 10 -Compress)
                $p.ContentType = 'application/json'
            }
            return Invoke-RestMethod @p
        }
        catch {
            $code = 0
            $resp = $_.Exception.Response
            if ($resp) { try { $code = [int]$resp.StatusCode } catch { } }

            if ($code -eq 429) { Add-GLStat Throttled }
            if (($code -eq 429 -or $code -ge 500) -and $attempt -le $MaxRetry) {
                $wait = [math]::Min(60, 2 * $attempt)
                try {
                    $ra = $resp.Headers.RetryAfter
                    if ($ra -and $ra.Delta) { $wait = [math]::Min(120, [math]::Ceiling($ra.Delta.TotalSeconds)) }
                } catch { }
                Start-Sleep -Seconds ([math]::Max(1, [int]$wait))
                continue
            }

            $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { ConvertFrom-GLApiError $_.ErrorDetails.Message } else { $_.Exception.Message }
            $what   = if ($code) { "HTTP $code" } else { 'no response' }
            throw "$Method $Uri -> $what : $detail"
        }
    }
}

function Get-GLPaged {
    <#
        Every page of a Fabric list call. Fabric pages with continuationUri, or with
        continuationToken alone on some endpoints - both are handled.

        Returns the items as ONE array. The leading comma on the return stops
        PowerShell unrolling it, so an empty result stays an empty array rather than
        becoming $null. Callers therefore assign the result to a variable and must
        NOT wrap the call itself in @(...) - that would produce a one-element array
        holding the array.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        [int]$MaxPages = 500,
        [hashtable]$Report       # a job's progress: Done is the count so far
    )
    $all   = [System.Collections.Generic.List[object]]::new()
    $next  = $Uri
    $pages = 0
    while ($next -and $pages -lt $MaxPages) {
        $pages++
        $r = Invoke-GLRequest -Uri $next -Token $Token
        if ($null -ne $r) {
            foreach ($v in $r.value) { if ($null -ne $v) { $all.Add($v) } }
        }
        if ($Report) { $Report.Done = $all.Count }
        $next = $null
        if ($r -and $r.continuationUri) {
            $next = [string]$r.continuationUri
        }
        elseif ($r -and $r.continuationToken) {
            $sep  = if ($Uri.Contains('?')) { '&' } else { '?' }
            $next = "$Uri${sep}continuationToken=$([uri]::EscapeDataString([string]$r.continuationToken))"
        }
    }
    return , $all.ToArray()
}

function Invoke-GLParallelGet {
    <#
        GET many URLs at once, each with its own time limit.

        Built for live member status: that endpoint waits for each gateway member
        to answer, and an offline member can take a long time to give up. Called
        one after another, a handful of offline members stalled the whole load for
        minutes. In parallel, the worst case is a single timeout.

        Returns a hashtable keyed by URL, each value: Ok, Status, Body, Error.
        Requests go out in batches so a large estate is not hit all at once.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Uris,
        [Parameter(Mandatory)][string]$Token,
        [int]$TimeoutSec = 30,
        [int]$Batch = 10
    )
    $out    = @{}
    Add-GLStat Calls -By @($Uris).Count
    if ([System.AppDomain]::CurrentDomain.GetData('GatewayLens.Demo')) {      # -Demo: answered locally, nothing is sent
        for ($i = 0; $i -lt $Uris.Count; $i += $Batch) {
            $slow = $false
            foreach ($u in @($Uris[$i..([math]::Min($i + $Batch, $Uris.Count) - 1)])) {
                $d  = Invoke-GLDemoHttp -Uri $u -NoDelay
                $ok = $d.Status -ge 200 -and $d.Status -lt 300
                if ($d.Status -eq 0) { $slow = $true }
                $out[$u] = [pscustomobject]@{
                    Ok = $ok; Status = $d.Status; Body = $d.Body
                    Error = if ($ok) { $null } elseif ($d.Status -eq 0) { "no answer within ${TimeoutSec}s" } else { "HTTP $($d.Status) : $(ConvertFrom-GLApiError $d.Body)" }
                }
            }
            if (-not ([System.AppDomain]::CurrentDomain.GetData('GatewayLens.Demo')).Fast) {
                Start-Sleep -Milliseconds $(if ($slow) { [math]::Min(2000, $TimeoutSec * 1000) } else { Get-Random -Minimum 200 -Maximum 600 })
            }
        }
        return $out
    }
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    $client.DefaultRequestHeaders.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    try {
        for ($i = 0; $i -lt $Uris.Count; $i += $Batch) {
            $last  = [math]::Min($i + $Batch, $Uris.Count) - 1
            $chunk = @($Uris[$i..$last])
            $tasks = @{}
            foreach ($u in $chunk) { $tasks[$u] = $client.GetAsync($u) }
            # WaitAll throws if any request failed - each one is inspected below anyway
            try {
                [void][System.Threading.Tasks.Task]::WaitAll(
                    [System.Threading.Tasks.Task[]]@($tasks.Values), [TimeSpan]::FromSeconds($TimeoutSec + 5))
            } catch { }

            foreach ($u in $chunk) {
                $t = $tasks[$u]
                if ($t.IsCompletedSuccessfully) {
                    $resp = $t.Result
                    $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    $body = $null
                    if ($text) { try { $body = $text | ConvertFrom-Json -ErrorAction Stop } catch { } }
                    $out[$u] = [pscustomobject]@{
                        Ok     = $resp.IsSuccessStatusCode
                        Status = [int]$resp.StatusCode
                        Body   = $body
                        Error  = if ($resp.IsSuccessStatusCode) { $null } else { "HTTP $([int]$resp.StatusCode) : $text" }
                    }
                    $resp.Dispose()
                }
                elseif ($t.IsCanceled -or -not $t.IsCompleted) {
                    $out[$u] = [pscustomobject]@{ Ok = $false; Status = 0; Body = $null; Error = "no answer within ${TimeoutSec}s" }
                }
                else {
                    $e = $t.Exception
                    while ($e.InnerException) { $e = $e.InnerException }
                    $out[$u] = [pscustomobject]@{ Ok = $false; Status = 0; Body = $null; Error = $e.Message }
                }
            }
        }
    }
    finally { $client.Dispose() }
    return $out
}

function Get-GLLiveStatus {
    <#
        UNOFFICIAL.

        /v2.0/myorg/me/gatewayClusters is the endpoint behind the portal's Manage
        gateways page. It is the only source of live per-member status, and it is not
        part of Microsoft's documented API - so it is isolated here, feeds the Status
        column and nothing else, and every caller treats a failure as "status unknown"
        rather than an error. If Microsoft changes or blocks it, this one function is
        what stops working.

        Every member is asked at the same time, each with a time limit: a member
        that does not answer is reported as Timeout instead of holding up the rest.

        -SkipClusterIds: clusters never asked at all. A VNet gateway that has gone to
        sleep is started by a status check, and then uses capacity - so callers pass
        their VNet gateways here unless the user chose to check them.

        Returns a hashtable keyed by lower-case member id.
    #>
    param(
        [Parameter(Mandatory)][string]$PbiToken,
        [int]$TimeoutSec = 30,
        [int]$MaxClusters = 0,
        [string[]]$SkipClusterIds = @(),
        [string[]]$OnlyClusterIds = @()        # after a change to one cluster: just that one
    )
    $skip     = @($SkipClusterIds | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $only     = @($OnlyClusterIds | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $base     = 'https://api.powerbi.com/v2.0/myorg/me/gatewayClusters'
    $r        = Invoke-GLRequest -Uri $base -Token $PbiToken
    $clusters = @($r.value | Where-Object { $_ -and $skip -notcontains ([string]$_.id).ToLowerInvariant() })
    if ($only.Count) { $clusters = @($clusters | Where-Object { $only -contains ([string]$_.id).ToLowerInvariant() }) }
    if ($MaxClusters -gt 0) { $clusters = @($clusters | Select-Object -First $MaxClusters) }

    $members = foreach ($c in $clusters) {
        foreach ($mg in $c.memberGateways) {
            if ($null -eq $mg) { continue }
            [pscustomobject]@{ Member = $mg; Cluster = ([string]$c.id).ToLowerInvariant(); Uri = "$base/$($c.id)/memberGateways/$($mg.id)/status" }
        }
    }
    $members = @($members)
    $results = @{}
    if ($members.Count -gt 0) {
        $results = Invoke-GLParallelGet -Uris @($members | ForEach-Object Uri) -Token $PbiToken -TimeoutSec $TimeoutSec
    }

    $out = @{}
    foreach ($m in $members) {
        $mg = $m.Member
        $machine = $null
        if ($mg.annotation) {
            try {
                $a = $mg.annotation
                if ($a -is [string]) { $a = $a | ConvertFrom-Json -ErrorAction Stop }
                $machine = $a.gatewayMachine
            } catch { }
        }
        $res    = $results[$m.Uri]
        $status = if ($res -and $res.Ok -and $res.Body -and $res.Body.gatewayStatus) { [string]$res.Body.gatewayStatus }
                  elseif ($res -and -not $res.Ok -and $res.Status -eq 0 -and $res.Error -like 'no answer*') { 'Timeout' }
                  else { 'Error' }
        $out[([string]$mg.id).ToLowerInvariant()] = [pscustomobject]@{
            Status  = $status
            Cluster = $m.Cluster
            Machine = $machine
            Enabled = $mg.enabled
            Version = $mg.version
        }
    }
    return $out
}

function Get-GLGatewayData {
    # Gateways and their members from the documented Fabric API, plus - optionally -
    # live member status from the unofficial endpoint. A failure in either optional
    # part becomes a warning in Log, never a failed load.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FabricToken,
        [string]$PbiToken,
        [switch]$LiveStatus,
        [switch]$CheckVnet,     # off unless asked: a status check wakes a sleeping VNet gateway
        [hashtable]$Report
    )
    $base     = 'https://api.fabric.microsoft.com/v1'
    $log      = [System.Collections.Generic.List[string]]::new()
    Set-GLReport $Report 'reading the gateways'
    $gateways = Get-GLPaged -Uri "$base/gateways" -Token $FabricToken

    $members = @{}
    $onPrem = @($gateways | Where-Object { [string]$_.type -eq 'OnPremises' })
    Set-GLReport $Report 'reading the members of each gateway' -Total $onPrem.Count
    foreach ($g in $gateways) {
        if ([string]$g.type -ne 'OnPremises') { continue }   # personal and VNet gateways have no member list
        if ($Report) { $Report.Done = [int]$Report.Done + 1 }
        try {
            $m = Get-GLPaged -Uri "$base/gateways/$($g.id)/members" -Token $FabricToken
            $members[[string]$g.id] = $m
        }
        catch { $log.Add("Members of '$($g.displayName)': $($_.Exception.Message)") }
    }

    $live = $null
    if ($LiveStatus -and $PbiToken) {
        Set-GLReport $Report 'asking every member whether it is online'
        $leave = if (-not $CheckVnet) { @($gateways | Where-Object { [string]$_.type -eq 'VirtualNetwork' } | ForEach-Object { [string]$_.id }) } else { @() }
        try { $live = Get-GLLiveStatus -PbiToken $PbiToken -SkipClusterIds $leave }
        catch { $log.Add("Live status is unavailable (unofficial API): $($_.Exception.Message)") }
    }

    return @{ Gateways = $gateways; Members = $members; Live = $live; Log = $log.ToArray() }
}

function Get-GLConnectionData {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FabricToken, [hashtable]$Report)
    $base = 'https://api.fabric.microsoft.com/v1'
    Set-GLReport $Report 'reading the gateways'
    $gateways = Get-GLPaged -Uri "$base/gateways" -Token $FabricToken
    Set-GLReport $Report 'reading the connections' -Expect $(if ($Report) { [int]$Report.ExpectConnections } else { 0 })
    $connections = Get-GLPaged -Uri "$base/connections" -Token $FabricToken -Report $Report
    return @{ Gateways = $gateways; Connections = $connections }
}

function Set-GLReport {
    # A job tells the window what it is doing now: a stage, and a total when known
    # (-Expect: about how many - from the last time).
    param([hashtable]$Report, [string]$Stage, [int]$Total = 0, [int]$Expect = 0)
    if (-not $Report) { return }
    $Report.Stage = $Stage; $Report.Done = 0; $Report.Total = $Total; $Report.Expect = $Expect
}

function Get-GLRoleAssignments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('gateways', 'connections')][string]$Kind,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$FabricToken
    )
    $items = Get-GLPaged -Uri "https://api.fabric.microsoft.com/v1/$Kind/$Id/roleAssignments" -Token $FabricToken
    return , $items
}

function New-GLRoleAssignmentBody {
    param([string]$PrincipalId, [string]$PrincipalType, [string]$Role)
    return @{ principal = @{ id = $PrincipalId; type = $PrincipalType }; role = $Role }
}

function Add-GLRoleAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('gateways', 'connections')][string]$Kind,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$PrincipalType,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$FabricToken
    )
    $body = New-GLRoleAssignmentBody -PrincipalId $PrincipalId -PrincipalType $PrincipalType -Role $Role
    return Invoke-GLRequest -Method POST -Uri "https://api.fabric.microsoft.com/v1/$Kind/$Id/roleAssignments" -Token $FabricToken -Body $body
}

function Remove-GLRoleAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('gateways', 'connections')][string]$Kind,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$AssignmentId,
        [Parameter(Mandatory)][string]$FabricToken
    )
    $null = Invoke-GLRequest -Method DELETE -Uri "https://api.fabric.microsoft.com/v1/$Kind/$Id/roleAssignments/$AssignmentId" -Token $FabricToken
}

function Resolve-GLPrincipal {
    <#
        Fabric role assignments need an object id. An id is used as given; anything
        else is looked up in Microsoft Graph - a user by UPN (or mail, for guests),
        a group by mail or display name, a service principal by display name. A
        lookup must find exactly one match: an ambiguous name is refused rather than
        guessed, because granting access to the wrong principal is worse than asking.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Type,
        [string]$GraphToken
    )
    $v = $Value.Trim()
    if (Test-GLGuid $v) {
        return [pscustomobject]@{ Id = $v; DisplayName = $v; Source = 'object id' }
    }
    if (-not $GraphToken) {
        throw "Looking up '$v' by name needs Microsoft Graph, which your organisation has not approved for GatewayLens. Paste the object id instead."
    }
    $graph = 'https://graph.microsoft.com/v1.0'
    $q     = $v.Replace("'", "''")

    switch ($Type) {
        'User' {
            try {
                $u = Invoke-GLRequest -Uri "$graph/users/$([uri]::EscapeDataString($v))?`$select=id,displayName,userPrincipalName" -Token $GraphToken -MaxRetry 1
                return [pscustomobject]@{ Id = $u.id; DisplayName = "$($u.displayName) <$($u.userPrincipalName)>"; Source = 'Microsoft Graph' }
            }
            catch {
                # guests and people whose mail differs from their UPN
                $f    = [uri]::EscapeDataString("mail eq '$q'")
                $r    = Invoke-GLRequest -Uri "$graph/users?`$filter=$f&`$select=id,displayName,userPrincipalName" -Token $GraphToken
                $hits = $r.value
            }
        }
        'Group' {
            $f    = [uri]::EscapeDataString("mail eq '$q' or displayName eq '$q'")
            $r    = Invoke-GLRequest -Uri "$graph/groups?`$filter=$f&`$select=id,displayName,mail" -Token $GraphToken
            $hits = $r.value
        }
        'ServicePrincipal' {
            $f    = [uri]::EscapeDataString("displayName eq '$q'")
            $r    = Invoke-GLRequest -Uri "$graph/servicePrincipals?`$filter=$f&`$select=id,displayName,appId" -Token $GraphToken
            $hits = $r.value
        }
        default {
            throw "A $Type cannot be looked up by name. Paste its id."
        }
    }

    $list = @($hits | Where-Object { $_ })
    if ($list.Count -eq 0) { throw "No $Type found for '$v'." }
    if ($list.Count -gt 1) { throw "'$v' matches $($list.Count) $($Type.ToLower())s. Use the object id to pick the right one." }
    $h    = $list[0]
    $name = if ($h.userPrincipalName) { "$($h.displayName) <$($h.userPrincipalName)>" }
            elseif ($h.mail)          { "$($h.displayName) <$($h.mail)>" }
            else                      { [string]$h.displayName }
    return [pscustomobject]@{ Id = $h.id; DisplayName = $name; Source = 'Microsoft Graph' }
}

function Test-GLConnection {
    # Documented Power BI endpoint. A gateway connection's id is the same id the
    # Power BI API calls a datasource.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GatewayId,
        [Parameter(Mandatory)][string]$ConnectionId,
        [Parameter(Mandatory)][string]$PbiToken
    )
    $uri = "https://api.powerbi.com/v1.0/myorg/gateways/$GatewayId/datasources/$ConnectionId/status"
    try {
        $null = Invoke-GLRequest -Uri $uri -Token $PbiToken -MaxRetry 1
        return [pscustomobject]@{ Ok = $true;  Message = 'Connection test succeeded.' }
    }
    catch {
        $m = $_.Exception.Message
        $i = $m.IndexOf(' -> ')
        if ($i -gt 0) { $m = $m.Substring($i + 4) }      # the URL is noise here - the reason is what matters
        return [pscustomobject]@{ Ok = $false; Message = $m }
    }
}

# ============================================================================
#  SHAPING  -  API objects into grid rows. Pure functions, no I/O, fully tested.
#  Property names have no underscores: a WPF DataGrid treats an underscore in a
#  header as a keyboard-shortcut marker and hides it.
# ============================================================================

function ConvertTo-GLGatewayRows {
    param($Gateways, [hashtable]$Members, [hashtable]$Live)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $Gateways) {
        if ([string]$g.type -eq 'OnPremisesPersonal') { continue }   # one person's own gateway - not ours to watch
        $id  = [string]$g.id
        $mem = @()
        if ($Members -and $Members.ContainsKey($id)) { $mem = $Members[$id] }

        $online = 'n/a'
        if ($Live -and $mem.Count -gt 0) {
            $known = @($mem | ForEach-Object { $Live[([string]$_.id).ToLowerInvariant()] } | Where-Object { $_ })
            if ($known.Count -gt 0) {
                $up     = @($known | Where-Object { $_.Status -eq 'Live' }).Count
                $online = "$up / $($mem.Count)"
            }
        }
        elseif ($Live -and [string]$g.type -eq 'VirtualNetwork') {
            # no member list for VNet gateways - only checked when the user asked for it
            $known = @($Live.Values | Where-Object { $_.Cluster -eq $id.ToLowerInvariant() })
            if ($known.Count -gt 0) { $online = "$(@($known | Where-Object { $_.Status -eq 'Live' }).Count) / $($known.Count)" }
        }

        $versions = @($mem | ForEach-Object { [string]$_.version } | Where-Object { $_ } | Sort-Object -Unique)
        if ($versions.Count -eq 0 -and $g.version) { $versions = @([string]$g.version) }

        $count = if ($null -ne $g.numberOfMemberGateways) { [int]$g.numberOfMemberGateways } else { $mem.Count }

        $rows.Add([pscustomobject]@{
            Name             = [string]$g.displayName
            Type             = [string]$g.type
            Members          = $count
            Online           = $online
            Versions         = ($versions -join ', ')
            LoadBalancing    = [string]$g.loadBalancingSetting
            CloudRefresh     = $g.allowCloudConnectionRefresh
            CustomConnectors = $g.allowCustomConnectors
            Id               = $id
        })
    }
    return , $rows.ToArray()
}

function ConvertTo-GLMemberRows {
    param([string]$GatewayName, $Members, [hashtable]$Live, $Releases)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $Members) {
        $l = $null
        if ($Live) { $l = $Live[([string]$m.id).ToLowerInvariant()] }
        $ri = Get-GLReleaseInfo $m.version $Releases
        $rows.Add([pscustomobject]@{
            Gateway = $GatewayName
            Member  = [string]$m.displayName
            Machine = if ($l) { [string]$l.Machine } else { '' }
            Version = [string]$m.version
            Release = $(if ($ri) { $ri.Release } else { '' })
            Support = $(if ($ri) { @{ Current = 'Newest'; Behind = 'Update available'; Unsupported = 'Not supported' }[$ri.State] } else { '' })
            Enabled = $m.enabled
            Status  = if ($l) { [string]$l.Status } else { 'n/a' }
            Id      = [string]$m.id
        })
    }
    return , $rows.ToArray()
}

function Format-GLDuration([timespan]$Span) {
    if ($Span.TotalMinutes -lt 1) { return 'under a minute' }
    if ($Span.TotalHours -lt 1)   { return "$([int][math]::Floor($Span.TotalMinutes)) min" }
    if ($Span.TotalDays -lt 1)    { return '{0} h {1:00} min' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes }
    return '{0} d {1} h' -f [int][math]::Floor($Span.TotalDays), $Span.Hours
}

function Get-GLAlertEvents {
    <#
        What to tell the user, from one refresh to the next. A member counts as down
        when it is not online two checks in a row - one slow answer wakes nobody -
        and as back when it is online again after it was reported down. Members an
        admin disabled are left out. -OnlyClusterIds: only those clusters were read
        again; the others keep their count as it was.
        Returns @{ Track = what to carry to the next refresh; Events = Down and Up }.
    #>
    param([hashtable]$Track, [hashtable]$Live, [string[]]$OnlyClusterIds, [int]$Confirm = 2, [datetime]$Now = (Get-Date))
    $only = @($OnlyClusterIds | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $next = @{}
    if ($Track -and $only.Count) {
        foreach ($k in $Track.Keys) { if ($only -notcontains [string]$Track[$k].Cluster) { $next[$k] = $Track[$k] } }
    }
    $events = [System.Collections.Generic.List[object]]::new()
    if ($Live) {
        foreach ($k in $Live.Keys) {
            $m  = $Live[$k]
            $cl = ([string]$m.Cluster).ToLowerInvariant()
            if ($only.Count -and $only -notcontains $cl) { continue }
            if ($m.Enabled -eq $false) { continue }
            $prev  = if ($Track -and $Track.ContainsKey($k)) { $Track[$k] } else { $null }
            $down  = [string]$m.Status -ne 'Live'
            $count = if ($down) { 1 + [int]$prev.DownChecks } else { 0 }
            $since = if ($down) { if ($prev -and $prev.Since) { $prev.Since } else { $Now } } else { $null }
            $told  = [bool]($prev -and $prev.Alerted)
            if ($down -and -not $told -and $count -ge $Confirm) {
                $events.Add([pscustomobject]@{ Kind = 'Down'; MemberId = $k; ClusterId = $cl; Machine = [string]$m.Machine; Status = [string]$m.Status; Since = $since; DownFor = $null })
                $told = $true
            }
            elseif (-not $down -and $told) {
                $was = if ($prev.Since) { $Now - [datetime]$prev.Since } else { [timespan]::Zero }
                $events.Add([pscustomobject]@{ Kind = 'Up'; MemberId = $k; ClusterId = $cl; Machine = [string]$m.Machine; Status = 'Live'; Since = $prev.Since; DownFor = $was })
                $told = $false
            }
            $next[$k] = [pscustomobject]@{ Cluster = $cl; DownChecks = $count; Alerted = $told; Since = $since }
        }
    }
    return @{ Track = $next; Events = $events.ToArray() }
}

function Format-GLAlertText {
    # Alert events as a title and one line each - the same words everywhere they go.
    param($Events, [hashtable]$Live, [hashtable]$ClusterNames, [hashtable]$MemberNames)
    $all  = @($Events | Where-Object { $_ })
    $down = @($all | Where-Object { $_.Kind -eq 'Down' })
    $up   = @($all | Where-Object { $_.Kind -eq 'Up' })
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @($down) + @($up)) {
        $who = if ($MemberNames -and $MemberNames[$e.MemberId]) { $MemberNames[$e.MemberId] } elseif ($e.Machine) { $e.Machine } else { $e.MemberId }
        $cl  = if ($ClusterNames -and $ClusterNames[$e.ClusterId]) { $ClusterNames[$e.ClusterId] } else { $e.ClusterId }
        $mem = @(if ($Live) { $Live.Values | Where-Object { ([string]$_.Cluster).ToLowerInvariant() -eq $e.ClusterId -and $_.Enabled -ne $false } })
        $on  = @($mem | Where-Object { [string]$_.Status -eq 'Live' }).Count
        if ($e.Kind -eq 'Down') {
            $how = switch ([string]$e.Status) { 'Timeout' { 'does not answer' } 'Error' { 'cannot be reached' } default { "is $(([string]$e.Status).ToLowerInvariant())" } }
            $since = if ($e.Since) { ' since {0:HH:mm}' -f [datetime]$e.Since } else { '' }
            $tail = if ($on -eq 0) { 'no member of the cluster is online' } else { "$on of $($mem.Count) members online" }
            $lines.Add("$who in $cl $how$since - $tail")
        }
        else {
            $lines.Add("$who in $cl is back online, after $(Format-GLDuration ([timespan]$e.DownFor)) - $on of $($mem.Count) members online")
        }
    }
    $title = if ($down.Count -and $up.Count) { "$($down.Count) gateway member(s) down, $($up.Count) back online" }
             elseif ($down.Count -eq 1) { 'A gateway member is down' }
             elseif ($down.Count) { "$($down.Count) gateway members are down" }
             elseif ($up.Count -eq 1) { 'A gateway member is back online' }
             else { "$($up.Count) gateway members are back online" }
    return [pscustomobject]@{ Title = $title; Lines = $lines.ToArray(); Severity = $(if ($down.Count) { 'Down' } else { 'Up' }) }
}

function New-GLAlertCard {
    # The message for Teams or a flow: an Adaptive Card, the format Teams workflows take.
    param([string]$Title, [string[]]$Lines, [string]$Severity, [string]$Version)
    $body = [System.Collections.Generic.List[object]]::new()
    $body.Add([ordered]@{ type = 'TextBlock'; text = $Title; weight = 'Bolder'; size = 'Medium'; wrap = $true; color = $(if ($Severity -eq 'Down') { 'Attention' } else { 'Good' }) })
    foreach ($l in @($Lines)) { $body.Add([ordered]@{ type = 'TextBlock'; text = [string]$l; wrap = $true; spacing = 'Small' }) }
    $body.Add([ordered]@{ type = 'TextBlock'; text = "GatewayLens $Version - $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"; isSubtle = $true; size = 'Small'; wrap = $true; spacing = 'Medium' })
    return [ordered]@{
        type        = 'message'
        attachments = @([ordered]@{
            contentType = 'application/vnd.microsoft.card.adaptive'
            contentUrl  = $null
            content     = [ordered]@{ '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'; type = 'AdaptiveCard'; version = '1.4'; body = $body.ToArray() }
        })
    }
}

function Test-GLWebhookUrl {
    <#
        '' when GatewayLens may post alerts to this address: https, and a Teams
        workflow or a Power Automate flow - Microsoft's own - so an alert can go
        nowhere else. Otherwise, why not, in words for the user.
    #>
    param([string]$Url)
    $v = ([string]$Url).Trim()
    if (-not $v) { return 'Paste the address of the Teams workflow or the Power Automate flow first.' }
    $u = $null
    if (-not [uri]::TryCreate($v, [System.UriKind]::Absolute, [ref]$u)) { return 'That is not a web address.' }
    if ($u.Scheme -ne 'https') { return 'The address must start with https://.' }
    $h = $u.Host.ToLowerInvariant()
    $ok = $h -match '(^|\.)logic\.azure\.com$' -or $h -match '(^|\.)api\.powerplatform\.com$' -or $h -match '(^|\.)powerautomate\.com$'
    if ($u.UserInfo -or -not $ok) { return 'Only a Teams workflow or a Power Automate flow can receive alerts - its address ends in logic.azure.com or api.powerplatform.com.' }
    return ''
}

function Protect-GLText([string]$Text) {
    # Readable only by this Windows account (DPAPI): the settings file never holds it plain.
    if (-not $Text) { return '' }
    return (ConvertFrom-SecureString -SecureString (ConvertTo-SecureString -String $Text -AsPlainText -Force))
}

function Unprotect-GLText([string]$Protected) {
    if (-not $Protected) { return '' }
    try { return [System.Net.NetworkCredential]::new('', (ConvertTo-SecureString -String $Protected)).Password }
    catch { return '' }      # another account's, or damaged - as if none was set
}

function Send-GLWebhook {
    # One alert to a Teams workflow or a Power Automate flow. The address works like a
    # password - whoever has it can post - so it is never in a message, an error or the log.
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)]$Body)
    $store = [System.AppDomain]::CurrentDomain.GetData('GatewayLens.Demo')
    if ($store) { $store.WebhookPosts.Add($Body); return }          # the demo sends nothing
    $json = $Body | ConvertTo-Json -Depth 20 -Compress
    try {
        $null = Invoke-RestMethod -Method POST -Uri $Url -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 20 -ErrorAction Stop
    }
    catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        throw $(if ($code) { "the flow answered HTTP $code" } else { 'no answer from the flow' })
    }
}

function Update-GLDownSince {
    <#
        When each member was first seen not online, carried from one refresh to the
        next. A member that is online again is forgotten. Only this session knows:
        the API has no history, so "down for" counts from when the window saw it.
    #>
    param([hashtable]$DownSince, [hashtable]$Live, [datetime]$Now)
    $out = @{}
    if (-not $Live) { return $out }
    foreach ($k in $Live.Keys) {
        if ([string]$Live[$k].Status -eq 'Live') { continue }
        $out[$k] = if ($DownSince -and $DownSince.ContainsKey($k)) { $DownSince[$k] } else { $Now }
    }
    return $out
}

function ConvertTo-GLGatewayTiles {
    <#
        One tile per gateway row, for the monitoring view: a status the tile is
        coloured by, the lines it shows, and a badge for version drift. Problems
        come first - offline, then degraded, then no status - so they are seen first.
    #>
    param($Rows, [hashtable]$Members, [hashtable]$DownSince, [datetime]$Now = (Get-Date), [switch]$VnetSkipped, [hashtable]$Live, $Releases,
          [hashtable]$ConnectionCounts, [int]$ConnectionLimit = 1000)
    $parse = { param($v) $p = $null; if ([version]::TryParse([string]$v, [ref]$p)) { $p } }
    $inv   = [System.Globalization.CultureInfo]::InvariantCulture
    $countOf = { param($Row) if ($ConnectionCounts) { [int]$ConnectionCounts[([string]$Row.Id).ToLowerInvariant()] } else { 0 } }
    $byId = @{}
    $all  = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $Rows) {
        $mem = @()
        if ($Members -and $Members.ContainsKey($r.Id)) { $mem = @($Members[$r.Id]) }
        $byId[$r.Id] = $mem
        foreach ($m in $mem) { $v = & $parse $m.version; if ($v) { $all.Add($v) } }
    }
    $newest = $all | Sort-Object -Descending | Select-Object -First 1

    $tiles = foreach ($r in $Rows) {
        $mem = $byId[$r.Id]
        if ($r.Type -eq 'VirtualNetwork' -and ($VnetSkipped -or (Get-GLGatewayState $r.Online) -eq 'Unknown')) {
            $why = if ($VnetSkipped) { 'Not checked, so it is not woken up' } else { 'No status' }
            $n = & $countOf $r
            [pscustomobject]@{ Id = $r.Id; Name = $r.Name; Type = $r.Type; Status = 'VNet'; StatusText = 'VIRTUAL NETWORK'
                MembersText = $why; VersionText = ''; Badge = ''; HasBadge = $false; DownText = ''; Order = 4
                Connections = $n; ConnectionsText = $(if ($ConnectionCounts) { "$n connection$(if ($n -ne 1) { 's' })" } else { '' }) }
            continue
        }
        $state  = Get-GLGatewayState $r.Online
        $status = @{ Online = 'Online'; Partial = 'Degraded'; Offline = 'Offline'; Unknown = 'Unknown' }[$state]
        $text   = @{ Online = 'ONLINE'; Partial = 'DEGRADED'; Offline = 'OFFLINE'; Unknown = 'NO STATUS' }[$state]
        $order  = @{ Offline = 0; Partial = 1; Unknown = 2; Online = 3 }[$state]
        $membersText = if ($r.Online -match '^(\d+) / (\d+)$') { "$($Matches[1]) of $($Matches[2]) members online" } else { "$($r.Members) member(s)" }
        if ($r.Type -eq 'VirtualNetwork') { $membersText = "VNet - $membersText" }

        # With Microsoft's pages read: against Microsoft's releases. Without: against
        # the newest version seen in this tenant.
        $vers  = @($mem | ForEach-Object { & $parse $_.version } | Where-Object { $_ } | Sort-Object -Unique)
        $infos = @($vers | ForEach-Object { Get-GLReleaseInfo $_ $Releases } | Where-Object { $_ })
        # Microsoft allows 1,000 data sources on an on-premises gateway cluster
        $n = & $countOf $r
        $limitBadge = if (-not $ConnectionCounts -or $r.Type -eq 'VirtualNetwork') { '' }
                      elseif ($n -ge $ConnectionLimit) { 'AT CONNECTION LIMIT' }
                      elseif ($n -ge [math]::Ceiling($ConnectionLimit * 0.8)) { 'NEAR CONNECTION LIMIT' }
                      else { '' }
        $connText = if (-not $ConnectionCounts) { '' }
                    elseif ($r.Type -eq 'VirtualNetwork') { "$n connection$(if ($n -ne 1) { 's' })" }
                    else { [string]::Format($inv, '{0:N0} of {1:N0} connections', $n, $ConnectionLimit) }
        $badge = if ($limitBadge -eq 'AT CONNECTION LIMIT') { $limitBadge }
                 elseif ($infos | Where-Object State -eq 'Unsupported') { 'UNSUPPORTED VERSION' }
                 elseif ($limitBadge) { $limitBadge }
                 elseif ($vers.Count -gt 1) { 'MIXED VERSIONS' }
                 elseif ($infos | Where-Object State -eq 'Behind') { 'UPDATE AVAILABLE' }
                 elseif ($infos.Count -eq 0 -and $vers.Count -eq 1 -and $newest -and $vers[0] -lt $newest) { 'OLDER VERSION' }
                 else { '' }
        $versionText = @($vers | ForEach-Object { "$_" }) -join ' / '
        if ($vers.Count -eq 1 -and $infos.Count -eq 1 -and $infos[0].Release) { $versionText += " ($($infos[0].Release))" }

        $keys = @($mem | ForEach-Object { ([string]$_.id).ToLowerInvariant() })
        if ($r.Type -eq 'VirtualNetwork' -and $Live) { $keys = @($Live.Keys | Where-Object { $Live[$_].Cluster -eq $r.Id.ToLowerInvariant() }) }
        $down = @($keys | ForEach-Object { if ($DownSince -and $DownSince.ContainsKey($_)) { $DownSince[$_] } } | Sort-Object)
        $downText = ''
        if ($down.Count -and $state -eq 'Offline') { $downText = "Down for $(Format-GLDuration ($Now - $down[0]))" }
        elseif ($down.Count -and $state -eq 'Partial') { $downText = "$($down.Count) down, the first for $(Format-GLDuration ($Now - $down[0]))" }

        [pscustomobject]@{ Id = $r.Id; Name = $r.Name; Type = $r.Type; Status = $status; StatusText = $text
            MembersText = $membersText; VersionText = $versionText; Badge = $badge
            HasBadge = [bool]$badge; DownText = $downText; Order = $order; Connections = $n; ConnectionsText = $connText }
    }
    return , @($tiles | Sort-Object Order, Name)
}

function Get-GLGatewayCounts {
    # For the banner over the tiles.
    param($Tiles)
    $t = @($Tiles)
    return [pscustomobject]@{
        Total    = $t.Count
        Offline  = @($t | Where-Object Status -eq 'Offline').Count
        Degraded = @($t | Where-Object Status -eq 'Degraded').Count
        Drift       = @($t | Where-Object HasBadge).Count
        Unsupported = @($t | Where-Object Badge -eq 'UNSUPPORTED VERSION').Count
        Behind      = @($t | Where-Object Badge -eq 'UPDATE AVAILABLE').Count
        Mixed       = @($t | Where-Object Badge -eq 'MIXED VERSIONS').Count
        NearLimit   = @($t | Where-Object Badge -like '*CONNECTION LIMIT').Count
    }
}

function ConvertTo-GLTestOutcome {
    <#
        One connection's test result as the Status column and the log show it. With
        "Skip test connection" on, the gateway may answer OK without trying the data
        source at all - so an OK there is Unverified, not OK.
    #>
    param($Result, [bool]$SkipTest, [string]$Name)
    $status = [string]$Result.Status
    $detail = [string]$Result.Detail
    if ($status -eq 'OK' -and $SkipTest) {
        $status = 'Unverified'
        $detail = 'Skip test connection is on - the gateway may answer OK without trying the data source'
    }
    $level = @{ OK = 'Ok'; Failed = 'Error'; Timeout = 'Warn'; Unverified = 'Warn' }[$status]
    if (-not $level) { $level = 'Warn' }
    $said = switch ($status) {
        'OK'         { 'OK' }
        'Timeout'    { 'did not answer in time' }
        'Unverified' { "OK, but not verified - $detail" }
        default      { "failed - $detail" }
    }
    return [pscustomobject]@{ Status = $status; Detail = $detail; Level = $level; Text = "    ${Name}: $said" }
}

function Get-GLConnectionCounts {
    <#
        Connections per gateway, against the 1,000 data sources Microsoft allows on
        a gateway cluster: every connection the Fabric list or the data source
        directory knows, each counted once. Keyed by lower-case gateway id. It is
        what this account can see - the real number can be higher.
    #>
    param($Rows, [hashtable]$Directory)
    $sets = @{}
    $add = {
        param($Gw, $Conn)
        if (-not $Gw -or -not $Conn) { return }
        $key = $Gw.ToLowerInvariant()
        if (-not $sets.ContainsKey($key)) { $sets[$key] = [System.Collections.Generic.HashSet[string]]::new() }
        [void]$sets[$key].Add($Conn.ToLowerInvariant())
    }
    foreach ($r in $Rows) { if ($r -and $r.Connectivity -ne 'ShareableCloud') { & $add ([string]$r.GatewayId) ([string]$r.Id) } }
    if ($Directory) { foreach ($k in $Directory.Keys) { & $add ([string]$Directory[$k].ClusterId) ([string]$k) } }
    $out = @{}
    foreach ($k in $sets.Keys) { $out[$k] = $sets[$k].Count }
    return $out
}

function Test-GLPrincipalMatch {
    # Is this role assignment's principal the one meant? By object id, or by the
    # UPN or email it carries - never by display name: two people can share one.
    param($Principal, $Who)
    if (-not $Principal -or -not $Who) { return $false }
    if ($Who.Id -and ([string]$Principal.id) -ieq [string]$Who.Id) { return $true }
    $carried = @($Principal.userDetails.userPrincipalName, $Principal.groupDetails.email) | Where-Object { $_ }
    foreach ($n in @($Who.Names)) {
        if (-not $n) { continue }
        foreach ($x in $carried) { if ([string]$x -ieq [string]$n) { return $true } }
    }
    return $false
}

function Get-GLHandoverStep {
    <#
        What handing over means on one gateway or connection, from who has access:
          None   From has no role here - nothing to hand over
          Grant  To has no role here - give To the same role
          Raise  To has a lower role - raise it to the same one
          Keep   To already has that role, or a higher one
        A principal holds one role per item. Roles rank Owner > UserWithReshare >
        User on connections, Admin > ConnectionCreatorWithResharing >
        ConnectionCreator on gateways.
    #>
    param($Assignments, $From, $To, [ValidateSet('gateways', 'connections')][string]$Kind = 'connections')
    $rank = if ($Kind -eq 'gateways') { @{ ConnectionCreator = 1; ConnectionCreatorWithResharing = 2; Admin = 3 } }
            else { @{ User = 1; UserWithReshare = 2; Owner = 3 } }
    $fromA = @($Assignments | Where-Object { $_ -and (Test-GLPrincipalMatch -Principal $_.principal -Who $From) }) | Select-Object -First 1
    if (-not $fromA) {
        return [pscustomobject]@{ Action = 'None'; Role = ''; FromAssignmentId = ''; FromPrincipal = $null; ToAssignmentId = ''; ToRole = '' }
    }
    $toA  = @($Assignments | Where-Object { $_ -and ([string]$_.principal.id) -ieq [string]$To.Id }) | Select-Object -First 1
    $role = [string]$fromA.role
    $action = if (-not $toA) { 'Grant' }
              elseif ([int]$rank[[string]$toA.role] -ge [int]$rank[$role]) { 'Keep' }
              else { 'Raise' }
    return [pscustomobject]@{
        Action = $action; Role = $role; FromAssignmentId = [string]$fromA.id; FromPrincipal = $fromA.principal
        ToAssignmentId = $(if ($toA) { [string]$toA.id } else { '' }); ToRole = $(if ($toA) { [string]$toA.role } else { '' })
    }
}

function ConvertTo-GLAccessReportRows {
    <#
        Who can use what: one row per gateway or connection and principal - for an
        auditor, or with -Who for everything one person can access. -Who matches the
        way the User filter does: part of the name, email, UPN or object id.
        A target whose access could not be read gets one row that says so.
    #>
    param($Targets, [hashtable]$Assignments, [string]$Who, [hashtable]$Names)
    $w  = if ($Who) { $Who.Trim() } else { '' }
    $ic = [System.StringComparison]::OrdinalIgnoreCase
    $rows = [System.Collections.Generic.List[object]]::new()
    $row = {
        param($T, $Principal, $Email, $PType, $Role, $PrincipalId, $InEntra)
        [pscustomobject][ordered]@{
            Kind = $(if ($T.Kind -eq 'gateways') { 'Gateway' } else { 'Connection' })
            Target = [string]$T.Name; Gateway = [string]$T.Gateway; Type = [string]$T.Type; Path = [string]$T.Path
            Account = [string]$T.Account; LastUsed = [string]$T.LastUsed
            Principal = [string]$Principal; Email = [string]$Email; PrincipalType = [string]$PType; Role = [string]$Role
            InEntraId = [string]$InEntra; PrincipalId = [string]$PrincipalId; TargetId = [string]$T.Id
        }
    }
    foreach ($t in $Targets) {
        $ras = $Assignments["$($t.Kind)/$($t.Id)"]
        if ($null -eq $ras) {
            if (-not $w) { $rows.Add((& $row $t '' '' '' '(could not be read)' '' '')) }
            continue
        }
        foreach ($as in $ras) {
            $p = $as.principal
            $label = Get-GLPrincipalLabel -Principal $p -Names $Names
            if ($w -and ("$($label.Name)|$($label.Email)|$($p.id)").IndexOf($w, $ic) -lt 0) { continue }
            $rows.Add((& $row $t $label.Name $label.Email $p.type $as.role $p.id $(if ($label.Missing) { 'No' } else { 'Yes' })))
        }
    }
    return , $rows.ToArray()
}

function ConvertTo-GLClipboardText {
    <#
        Rows as tab-separated text, the way Excel pastes them into cells: one line
        per row, columns in the order given, -Headers with the column names first.
        A list is joined with "; ", and a tab or line break inside a value becomes a
        space, so one row always stays one line.
    #>
    param($Rows, $Columns, [switch]$Headers)
    $clean = {
        param($Value)
        $s = if ($null -eq $Value) { '' }
             elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { (@($Value) | ForEach-Object { [string]$_ }) -join '; ' }
             else { [string]$Value }
        $s -replace '[\t\r\n]+', ' '
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Headers) { $lines.Add((@($Columns | ForEach-Object { & $clean $_.Header }) -join "`t")) }
    foreach ($r in $Rows) {
        if ($null -eq $r) { continue }
        $lines.Add((@($Columns | ForEach-Object { $pr = $r.PSObject.Properties[[string]$_.Property]; & $clean $(if ($pr) { $pr.Value }) }) -join "`t"))
    }
    return ($lines.ToArray() -join "`r`n")
}

function Get-GLMemberPlan {
    <#
        Enabling or disabling the selected members of one cluster: the ones that
        would change, how many are already as asked, and how many members of the
        cluster are enabled afterwards - none left means no refreshes at all.
    #>
    param($Members, $Selected, [bool]$Enabled)
    $sel    = @($Selected | Where-Object { $_ })
    $change = @($sel | Where-Object { [bool]$_.Enabled -ne $Enabled })
    $ids    = @($change | ForEach-Object { [string]$_.Id })
    $on     = @($Members | Where-Object { $_ -and $_.enabled })
    $after  = if ($Enabled) { $on.Count + $change.Count } else { @($on | Where-Object { $ids -notcontains [string]$_.id }).Count }
    return [pscustomobject]@{ Change = $change; Already = $sel.Count - $change.Count; EnabledAfter = $after }
}

function Get-GLGatewayNameMap {
    param($Gateways)
    $map = @{}
    foreach ($g in $Gateways) { $map[([string]$g.id).ToLowerInvariant()] = [string]$g.displayName }
    return $map
}

function ConvertTo-GLLocalTime($Value) {
    # An API time - text such as 2026-10-01T08:00:00Z, or a date PowerShell already
    # parsed - as local time. Empty stays $null.
    if ($null -eq $Value -or [string]$Value -eq '') { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq 'Local') { return $Value }
        return [datetime]::SpecifyKind($Value, 'Utc').ToLocalTime()
    }
    $d = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$d)) {
        return [datetime]::SpecifyKind($d, 'Utc').ToLocalTime()
    }
    return $null
}

function ConvertTo-GLConnectionRows {
    <#
        Created, LastLinked and LastUsed come from connectionRecency (preview): when
        the connection was made, last bound to an item, and when its credentials were
        last used at run time. Empty means not recorded - also for use before
        Microsoft began recording it. UnusedDays counts from LastUsed.

        Gateway connections and shareable cloud ones only: personal, Automatic and
        unbound connections are no gateway admin's to manage.
    #>
    param($Connections, [hashtable]$GatewayNames, [datetime]$Now = (Get-Date))
    $rows  = [System.Collections.Generic.List[object]]::new()
    $fmt   = { param($d) if ($d) { $d.ToString('yyyy-MM-dd HH:mm') } else { '' } }
    $kinds = 'OnPremisesGateway', 'VirtualNetworkGateway', 'StreamingVirtualNetworkGateway', 'ShareableCloud'
    foreach ($c in $Connections) {
        if ($kinds -notcontains [string]$c.connectivityType) { continue }
        $rc      = $c.connectionRecency
        $created = ConvertTo-GLLocalTime $rc.createdDateTime
        $linked  = ConvertTo-GLLocalTime $rc.lastBoundDateTime
        $used    = ConvertTo-GLLocalTime $rc.lastCredentialUsedDateTime
        $gid = [string]$c.gatewayId
        $gw  = ''
        if ($gid) {
            $gw = $gid
            if ($GatewayNames -and $GatewayNames.ContainsKey($gid.ToLowerInvariant())) { $gw = $GatewayNames[$gid.ToLowerInvariant()] }
        }
        $rows.Add([pscustomobject]@{
            Name         = [string]$c.displayName
            Connectivity = [string]$c.connectivityType
            Gateway      = $gw
            GatewayState = ''
            Type         = [string]$c.connectionDetails.type
            Path         = [string]$c.connectionDetails.path
            Account      = ''
            Users        = ''
            UserNames    = ''
            Status       = ''
            StatusDetail = ''
            Credential   = [string]$c.credentialDetails.credentialType
            SingleSignOn = [string]$c.credentialDetails.singleSignOnType
            Privacy      = [string]$c.privacyLevel
            Encryption   = [string]$c.credentialDetails.connectionEncryption
            SkipTest     = [bool]$c.credentialDetails.skipTestConnection
            Created      = & $fmt $created
            LastLinked   = & $fmt $linked
            LastUsed     = & $fmt $used
            UnusedDays   = $(if ($used) { [int][math]::Floor(($Now - $used).TotalDays) } else { $null })
            Id           = [string]$c.id
            GatewayId    = $gid
            UserList     = @()
            People       = @()
            UnknownUsers = 0
        })
    }
    return , $rows.ToArray()
}

function Set-GLRoleAssignment {
    # A principal's role on a gateway or connection, changed in place.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('gateways', 'connections')][string]$Kind,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$AssignmentId,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$FabricToken
    )
    $null = Invoke-GLRequest -Method PATCH -Uri "https://api.fabric.microsoft.com/v1/$Kind/$Id/roleAssignments/$AssignmentId" -Token $FabricToken -Body @{ role = $Role }
}

function Get-GLPrincipalNames {
    <#
        Names for object ids, from Microsoft Graph - Fabric's role assignments carry
        only each principal's id and type. One call answers up to 1,000 ids.
        Returns a hashtable keyed by lower-case id: Name, and Email (the UPN or mail,
        or an app id). Ids in -Known are not asked again. An id Graph answered for
        but does not know - an account that has been deleted - comes back with
        Missing set: the portal leaves such a principal out of its lists, so it is
        easy to miss that it still has access. Throws if Graph refuses: callers carry
        on without names.
    #>
    param([string[]]$Ids, [string]$GraphToken, [hashtable]$Known = @{}, [hashtable]$Report)
    $out  = @{}
    $want = @($Ids | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique |
              Where-Object { -not $Known.ContainsKey($_) })
    if (-not $GraphToken -or $want.Count -eq 0) { return $out }
    Set-GLReport $Report 'naming the people with access' -Total $want.Count
    $missing = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $want.Count; $i += 1000) {
        $chunk = @($want[$i..([Math]::Min($i + 1000, $want.Count) - 1)])
        $r = Invoke-GLRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds' -Token $GraphToken `
                -Body @{ ids = $chunk; types = @('user', 'group', 'servicePrincipal') } -MaxRetry 2
        foreach ($o in @($r.value)) {
            if (-not $o -or -not $o.id) { continue }
            $mail = @($o.userPrincipalName, $o.mail) | Where-Object { $_ } | Select-Object -First 1
            if (-not $mail -and $o.appId) { $mail = "app $($o.appId)" }
            $out[([string]$o.id).ToLowerInvariant()] = [pscustomobject]@{ Name = [string]$o.displayName; Email = [string]$mail; Missing = $false }
        }
        foreach ($id in $chunk) { if (-not $out.ContainsKey($id)) { $missing.Add($id) } }
        if ($Report) { $Report.Done = [Math]::Min($i + 1000, $want.Count) }
    }
    if ($missing.Count) {
        Set-GLReport $Report 'checking the accounts that are not in Entra ID' -Total $missing.Count
        $why = Get-GLMissingPrincipals -Ids $missing.ToArray() -GraphToken $GraphToken -Report $Report
        foreach ($id in $missing) { $out[$id] = $why[$id] }
    }
    return $out
}

function Get-GLGraphBatch {
    # Graph's $batch: up to 20 GET requests in one call. -Urls are relative to v1.0,
    # like /directoryObjects/{id}. Returns url -> Status, Body.
    param([string[]]$Urls, [string]$GraphToken, [hashtable]$Report)
    $out = @{}
    $all = @($Urls | Where-Object { $_ })
    for ($i = 0; $i -lt $all.Count; $i += 20) {
        $chunk = @($all[$i..([Math]::Min($i + 20, $all.Count) - 1)])
        $reqs = for ($j = 0; $j -lt $chunk.Count; $j++) { [ordered]@{ id = [string]$j; method = 'GET'; url = $chunk[$j] } }
        $r = Invoke-GLRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/$batch' -Token $GraphToken -Body @{ requests = @($reqs) } -MaxRetry 2
        foreach ($resp in @($r.responses)) {
            if ($null -eq $resp) { continue }
            $out[$chunk[[int]$resp.id]] = [pscustomobject]@{ Status = [int]$resp.status; Body = $resp.body }
        }
        if ($Report) { $Report.Done = [Math]::Min($i + 20, $all.Count) }
    }
    return $out
}

function Get-GLMissingPrincipals {
    <#
        What Graph can tell about ids that getByIds did not return. Its recycle bin
        first: an account deleted in the last 30 days is still there, with its name
        and the day it went (State Deleted). Then the directory: "no such object"
        means it is gone for good (Gone). When Graph refuses to say, the id stays
        Unknown - and is never called deleted.
        Returns id -> Name, Email, Missing, State, DeletedOn.
    #>
    param([string[]]$Ids, [string]$GraphToken, [hashtable]$Report)
    $out = @{}
    $list = @($Ids | Where-Object { $_ })
    foreach ($id in $list) { $out[$id] = [pscustomobject]@{ Name = ''; Email = ''; Missing = $true; State = 'Unknown'; DeletedOn = $null } }
    if ($list.Count -eq 0 -or -not $GraphToken) { return $out }
    $bin = @{}
    try { $bin = Get-GLGraphBatch -Urls @($list | ForEach-Object { "/directory/deletedItems/$_" }) -GraphToken $GraphToken -Report $Report } catch { return $out }
    $ask = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $list) {
        $r = $bin["/directory/deletedItems/$id"]
        if ($r -and $r.Status -eq 200 -and $r.Body) {
            $b = $r.Body
            # a deleted user's UPN gets its object id in front - the mail stays as it was
            $mail = @($b.mail, ([string]$b.userPrincipalName -replace '^[0-9a-fA-F]{32}', '')) | Where-Object { $_ } | Select-Object -First 1
            $out[$id] = [pscustomobject]@{ Name = [string]$b.displayName; Email = [string]$mail; Missing = $true; State = 'Deleted'
                                           DeletedOn = (ConvertTo-GLLocalTime $b.deletedDateTime) }
        }
        elseif ($r -and $r.Status -eq 404) { $out[$id].State = 'Gone' }
        else { $ask.Add($id) }
    }
    if ($ask.Count) {
        $dir = @{}
        try { $dir = Get-GLGraphBatch -Urls @($ask | ForEach-Object { "/directoryObjects/$_" }) -GraphToken $GraphToken } catch { }
        foreach ($id in $ask) {
            $r = $dir["/directoryObjects/$id"]
            if ($r -and $r.Status -eq 404) { $out[$id].State = 'Gone' }
            elseif ($r -and $r.Status -eq 200 -and $r.Body) {
                $b = $r.Body
                $mail = @($b.userPrincipalName, $b.mail) | Where-Object { $_ } | Select-Object -First 1
                if (-not $mail -and $b.appId) { $mail = "app $($b.appId)" }
                $out[$id] = [pscustomobject]@{ Name = [string]$b.displayName; Email = [string]$mail; Missing = $false; State = 'Found'; DeletedOn = $null }
            }
        }
    }
    return $out
}

function Resolve-GLHandoverFrom {
    <#
        The principal handing over, as an object id: role assignments carry only the
        id, so an email or a name is looked up in Microsoft Graph first. Someone
        whose account is already deleted is not in Graph any more - their object id,
        which the access lists show, still works.
    #>
    param([Parameter(Mandatory)][string]$Value, [string]$GraphToken)
    $v = $Value.Trim()
    if (Test-GLGuid $v) { return [pscustomobject]@{ Id = $v; DisplayName = $v; Names = @() } }
    if (-not $GraphToken) { throw "Looking up '$v' needs Microsoft Graph, which is not available. Use their object id - the access lists show it." }
    foreach ($kind in 'User', 'Group') {
        try {
            $p = Resolve-GLPrincipal -Value $v -Type $kind -GraphToken $GraphToken
            return [pscustomobject]@{ Id = [string]$p.Id; DisplayName = [string]$p.DisplayName; Names = @($v) }
        } catch { }
    }
    throw "'$v' was not found in Microsoft Entra ID. If the account has been deleted, use its object id - the access lists show it."
}

function Get-GLPrincipalLabel {
    <#
        How a principal is shown: its name and email from -Names (Graph), else what
        the assignment carries, else the object id. Key is what lists and filters
        use: the email, else the name, else the id.
    #>
    param($Principal, [hashtable]$Names)
    $id = ([string]$Principal.id).ToLowerInvariant()
    $n  = if ($Names -and $id -and $Names.ContainsKey($id)) { $Names[$id] } else { $null }
    $missing = [bool]($n -and $n.Missing)
    $state = if ($missing) { [string]$n.State } else { '' }
    $app = if ($Principal.servicePrincipalDetails.aadAppId) { "app $($Principal.servicePrincipalDetails.aadAppId)" } else { '' }
    $name  = @($n.Name, $Principal.displayName) | Where-Object { $_ } | Select-Object -First 1
    $email = @($n.Email, $Principal.userDetails.userPrincipalName, $Principal.groupDetails.email, $app) | Where-Object { $_ } | Select-Object -First 1
    $shown = if ($missing) {
        # only what Graph confirmed: a deleted account by name, gone for good, or not known
        if ($state -eq 'Deleted' -and $name) { "$name (deleted)" } elseif ($state -in 'Deleted', 'Gone') { 'Deleted account' } else { 'Not found in Microsoft Entra ID' }
    } elseif ($name) { [string]$name } else { [string]$Principal.id }
    return [pscustomobject]@{
        Name      = $shown
        Email     = [string]$email
        # an account that is not in Entra ID can only be named by its id - for a handover, a removal
        Key       = $(if ($missing) { [string]$Principal.id } elseif ($email) { [string]$email } elseif ($name) { [string]$name } else { [string]$Principal.id })
        Missing   = $missing
        State     = $state
        DeletedOn = $(if ($missing) { $n.DeletedOn } else { $null })
    }
}

function ConvertTo-GLPeopleLabels {
    <#
        The users of one connection from the unofficial directory, as labels. The
        directory gives an email on some tenants and only the object id on others -
        an id is named through -Names, like a Fabric role assignment.
    #>
    param($Users, [hashtable]$Names)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($u in @($Users | Where-Object { $_ })) {
        $who = [string]$u.Principal
        if (-not $who) { continue }
        if (Test-GLGuid $who) { $out.Add((Get-GLPrincipalLabel -Principal ([pscustomobject]@{ id = $who }) -Names $Names)) }
        else { $out.Add([pscustomobject]@{ Name = $who; Email = $who; Key = $who; Missing = $false }) }
    }
    return , $out.ToArray()
}

function Set-GLRowPeople {
    <#
        Who has access to one connection, in every form the list needs: UserList (one
        key each - the email, else the name, else the id) for the handover, UserNames
        to read, People for the User filter to search names, emails and ids alike, and
        UnknownUsers - how many are not in Microsoft Entra ID.
    #>
    param($Row, $Labels)
    $l = @($Labels | Where-Object { $_ })
    $live = @($l | Where-Object { -not $_.Missing })
    $gone = @($l | Where-Object { $_.Missing })
    $Row.UserList = @($l | ForEach-Object { [string]$_.Key } | Where-Object { $_ })
    $Row.Users    = [string]$live.Count             # as many as the portal lists
    $shown = @($live | ForEach-Object { if ($_.Email) { $_.Email } else { $_.Name } })
    if ($gone.Count) { $shown += "+$($gone.Count) not in Entra ID" }
    # rows made elsewhere - in the tests, by older code - may not have these yet
    $Row | Add-Member -NotePropertyName UserNames -NotePropertyValue ($shown -join '; ') -Force
    $Row | Add-Member -NotePropertyName People -NotePropertyValue $l -Force
    $Row | Add-Member -NotePropertyName UnknownUsers -NotePropertyValue @($l | Where-Object { $_.Missing }).Count -Force
}

function Get-GLMissingText {
    # Why a principal is not named, in the words of what Graph said.
    param($Label)
    $tail = 'the portal leaves it out, but it still has this role'
    switch ([string]$Label.State) {
        'Deleted' {
            $on = if ($Label.DeletedOn) { ' on ' + ([datetime]$Label.DeletedOn).ToString('yyyy-MM-dd') } else { '' }
            $who = if ($Label.Email) { "$($Label.Email) - " } else { '' }
            return "${who}deleted from Microsoft Entra ID$on - $tail"
        }
        'Gone'  { return "Microsoft Entra ID has no account with this id any more - $tail" }
        default { return "Graph would not say who this is - you may not be allowed to see it. $($tail.Substring(0,1).ToUpper())$($tail.Substring(1))" }
    }
}

function Format-GLAccessList {
    # One line for the log: who has access, each with the role.
    param($Rows)
    $all = @($Rows | Where-Object { $_ })
    if ($all.Count -eq 0) { return 'nobody' }
    return (@($all | ForEach-Object {
        $who = if ($_.NotInEntra) { "$($_.Principal) [$($_.PrincipalId) - not in Entra ID]" } elseif ($_.Detail) { $_.Detail } else { $_.Principal }
        "$who ($($_.Role))"
    }) -join ', ')
}

function ConvertTo-GLRoleRows {
    param($Assignments, [hashtable]$Names)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $Assignments) {
        $p = $a.principal
        $label = Get-GLPrincipalLabel -Principal $p -Names $Names
        $gone  = [bool]$label.Missing
        $rows.Add([pscustomobject]@{
            Principal   = $label.Name
            Detail      = $(if ($gone) { Get-GLMissingText $label } else { $label.Email })
            Type        = [string]$p.type
            Role        = [string]$a.role
            Id          = [string]$a.id
            PrincipalId = [string]$p.id
            NotInEntra  = [bool]$gone
        })
    }
    return , $rows.ToArray()
}

function Select-GLConnections {
    <#
        The Connections tab filters. '(all)' or empty means "no filter".
          Text          several values separated by ; or new lines - a row matches ANY
          User          someone with access (needs Users loaded)
          Account       the username stored in the credentials (needs Account loaded)
          States        gateway states to keep: Online, Offline, Partial, Unknown
          Excluded      ids to leave out
          IncludeCloud  shareable cloud connections too - gateway connections only without it
          Show          a cleanup view:
                          'Last used over N days ago'  credentials last used more than N days ago
                          'No use recorded'            no use since Microsoft began recording
                          'Duplicates'                 same gateway, type, path and account as
                                                       another - listed side by side
                          'Failing tests'              failed or did not answer in Verify status
                          'Skip test connection on'    a test of these may say OK without trying
                          'Access by accounts not in Entra ID'
                                                       someone with access is not in the directory
                                                       any more - deleted, and hidden by the portal
    #>
    param($Rows, [string]$Text, [string]$Gateway, [string]$Connectivity, [string]$Type,
          [string]$User, [string]$Account, [string[]]$States, $Excluded,
          [switch]$IncludeCloud, [string]$Show)
    $scope = @($Rows | Where-Object { $_ -and ($IncludeCloud -or $_.Connectivity -ne 'ShareableCloud') })
    $terms = @()
    if ($Text) { $terms = @($Text -split '[;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $u = if ($User) { $User.Trim() } else { '' }
    $a = if ($Account) { $Account.Trim() } else { '' }
    $ic = [System.StringComparison]::OrdinalIgnoreCase
    $days = if ($Show -match '(\d+) days') { [int]$Matches[1] } else { 0 }
    $dupKey = { param($r) (@($r.GatewayId, $r.Type, $r.Path, $r.Account) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() }) -join '|' }
    $seen = $null
    if ($Show -eq 'Duplicates') {
        $seen = @{}
        foreach ($r in $scope) { $k = & $dupKey $r; $seen[$k] = 1 + [int]$seen[$k] }
    }
    $out = foreach ($r in $scope) {
        if ($Excluded -and $Excluded.Contains([string]$r.Id)) { continue }
        if ($Gateway      -and $Gateway      -ne '(all)' -and $r.Gateway      -ne $Gateway)      { continue }
        if ($Connectivity -and $Connectivity -ne '(all)' -and $r.Connectivity -ne $Connectivity) { continue }
        if ($Type         -and $Type         -ne '(all)' -and $r.Type         -ne $Type)         { continue }
        if ($null -ne $States) {
            $st = if ($r.GatewayState -in 'Online', 'Offline', 'Partial') { $r.GatewayState } else { 'Unknown' }
            if ($States -notcontains $st) { continue }
        }
        if ($terms.Count) {
            $hay = "$($r.Name)|$($r.Path)|$($r.Type)|$($r.Gateway)|$($r.Id)"
            $hit = $false
            foreach ($t in $terms) { if ($hay.IndexOf($t, $ic) -ge 0) { $hit = $true; break } }
            if (-not $hit) { continue }
        }
        if ($a -and ([string]$r.Account).IndexOf($a, $ic) -lt 0) { continue }
        if ($u) {
            $hit = $false
            $people = if ($r.PSObject.Properties['People'] -and @($r.People).Count) { @($r.People | ForEach-Object { $_.Name; $_.Email; $_.Key }) } else { @($r.UserList) }
            foreach ($x in $people) { if (([string]$x).IndexOf($u, $ic) -ge 0) { $hit = $true; break } }
            if (-not $hit) { continue }
        }
        if ($days -and -not ($null -ne $r.UnusedDays -and $r.UnusedDays -gt $days)) { continue }
        if ($Show -eq 'No use recorded' -and $r.LastUsed) { continue }
        if ($seen -and $seen[(& $dupKey $r)] -lt 2) { continue }
        if ($Show -eq 'Failing tests' -and $r.Status -notin 'Failed', 'Timeout') { continue }
        if ($Show -eq 'Skip test connection on' -and -not $r.SkipTest) { continue }
        if ($Show -eq 'Access by accounts not in Entra ID' -and -not ($r.PSObject.Properties['UnknownUsers'] -and $r.UnknownUsers -gt 0)) { continue }
        $r
    }
    if ($seen) { $out = @($out | Sort-Object { & $dupKey $_ }, Name) }
    return , @($out)
}

function Set-GLRowGatewayState {
    # Each connection takes the state of its gateway; anything not on an
    # on-premises gateway is n/a.
    param($Rows, [hashtable]$GatewayState)
    foreach ($r in $Rows) {
        $r.GatewayState = if ($r.Connectivity -ne 'OnPremisesGateway' -or -not $r.GatewayId) { 'n/a' }
                          elseif ($GatewayState -and $GatewayState.ContainsKey(([string]$r.GatewayId).ToLowerInvariant())) { $GatewayState[([string]$r.GatewayId).ToLowerInvariant()] }
                          else { 'Unknown' }
    }
}

function Add-GLDirectoryInfo {
    # Account and users from the unofficial bulk directory, the users named through -Names.
    param($Rows, [hashtable]$Directory, [hashtable]$Names)
    if (-not $Directory) { return }
    foreach ($r in $Rows) {
        $d = $Directory[([string]$r.Id).ToLowerInvariant()]
        if (-not $d) { continue }
        $r.Account = [string]$d.Account
        Set-GLRowPeople -Row $r -Labels (ConvertTo-GLPeopleLabels -Users $d.Users -Names $Names)
    }
}

function Get-GLDirectoryPrincipalIds {
    # Every object id among the directory's users - to be named in one go.
    param([hashtable]$Directory)
    if (-not $Directory) { return , @() }
    return , @($Directory.Values | ForEach-Object { $_.Users } | ForEach-Object { [string]$_.Principal } | Where-Object { Test-GLGuid $_ } | Sort-Object -Unique)
}

function Set-GLRowUsers {
    # Users from Fabric role assignments (Verify users), named through -Names.
    # $Assignments: id -> list, or $null when it could not be read.
    param($Rows, [hashtable]$Assignments, [hashtable]$Names)
    foreach ($r in $Rows) {
        if (-not $Assignments.ContainsKey([string]$r.Id)) { continue }
        $list = $Assignments[[string]$r.Id]
        if ($null -eq $list) { $r.Users = 'error'; continue }
        Set-GLRowPeople -Row $r -Labels @($list | ForEach-Object { Get-GLPrincipalLabel -Principal $_.principal -Names $Names })
    }
}

function Set-GLRowStatus {
    param($Rows, [hashtable]$Status)
    foreach ($r in $Rows) {
        $s = $Status[[string]$r.Id]
        if (-not $s) { continue }
        $r.Status       = $s.Status
        $r.StatusDetail = $s.Detail
    }
}

function Select-GLByText {
    # Generic quick filter over every property of a row.
    param($Rows, [string]$Text)
    $t = if ($Text) { $Text.Trim() } else { '' }
    if (-not $t) { return , @($Rows) }
    $out = foreach ($r in $Rows) {
        $hay = ($r.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join '|'
        if ($hay.IndexOf($t, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $r }
    }
    return , @($out)
}

function Get-GLDistinct {
    # Values for a filter dropdown: '(all)' first, then the distinct non-empty values.
    param($Rows, [string]$Property)
    $vals = @($Rows | ForEach-Object { [string]$_.$Property } | Where-Object { $_ } | Sort-Object -Unique)
    return , (@('(all)') + $vals)
}

function ConvertFrom-GLJobOutput {
    <#
        The last object a worker wrote is its result. Results come back wrapped in a
        PSObject; arrays, hashtables and plain values are unwrapped to their base
        object - but a [pscustomobject] must NOT be, because its base object is an
        empty placeholder and every property lives on the wrapper. Unwrapping it
        would hand back an object whose properties are all missing.
    #>
    param($Output)
    if ($null -eq $Output -or $Output.Count -eq 0) { return $null }
    $r = $Output[$Output.Count - 1]
    # .PSObject.BaseObject - never .BaseObject. On a list, .BaseObject is member
    # enumeration: PowerShell takes BaseObject of every ITEM, and for a
    # [pscustomobject] that is an empty placeholder - every list of objects came
    # back as a list of empty shells.
    $base = $r.PSObject.BaseObject
    if ($base -isnot [System.Management.Automation.PSCustomObject]) { $r = $base }
    # keep an array an array on the way out
    if ($r -is [array]) { return , $r }
    return $r
}

# ============================================================================
#  CREDENTIAL ENCRYPTION
#
#  Ported from Microsoft's Power BI .NET SDK, which is published under the MIT
#  License, Copyright (c) Microsoft Corporation:
#      github.com/microsoft/PowerBI-CSharp  sdk/PowerBI.Api/Extensions/
#          AsymmetricKeyEncryptor.cs, Asymmetric1024KeyEncryptionHelper.cs,
#          AsymmetricHigherKeyEncryptionHelper.cs, AuthenticatedEncryption.cs,
#          Models/CredentialDetails.cs
#  The format must match that code byte for byte, or the gateway cannot read the
#  credentials. The test suite decrypts the output with a private key to check it.
# ============================================================================

function ConvertTo-GLCredentialJson {
    # The plaintext the SDK encrypts: {"credentialData":[{"name":..,"value":..}]}
    param(
        [Parameter(Mandatory)][ValidateSet('Windows', 'Basic', 'Anonymous', 'Key')][string]$CredentialType,
        [string]$Username,
        [string]$Password
    )
    $pairs = switch ($CredentialType) {
        'Anonymous' { @() }
        'Key'       { @([ordered]@{ name = 'key'; value = $Password }) }
        default     { @([ordered]@{ name = 'username'; value = $Username }, [ordered]@{ name = 'password'; value = $Password }) }
    }
    return ([ordered]@{ credentialData = @($pairs) } | ConvertTo-Json -Depth 5 -Compress)
}

function ConvertTo-GLEncryptedCredential {
    param(
        [Parameter(Mandatory)][string]$CredentialJson,
        [Parameter(Mandatory)][string]$Modulus,
        [Parameter(Mandatory)][string]$Exponent
    )
    $plain = [System.Text.Encoding]::UTF8.GetBytes($CredentialJson)
    $mod   = [Convert]::FromBase64String($Modulus)
    $exp   = [Convert]::FromBase64String($Exponent)

    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $p = [System.Security.Cryptography.RSAParameters]::new()
        $p.Modulus  = $mod
        $p.Exponent = $exp
        $rsa.ImportParameters($p)

        if ($mod.Length -eq 128) {
            # 1024-bit key: RSA-OAEP (SHA-1) on 85-byte segments, 128 bytes each out
            $out = [System.IO.MemoryStream]::new()
            for ($i = 0; $i -lt $plain.Length; $i += 85) {
                $len = [Math]::Min(85, $plain.Length - $i)
                $seg = [byte[]]::new($len)
                [Array]::Copy($plain, $i, $seg, 0, $len)
                $enc = $rsa.Encrypt($seg, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA1)
                $out.Write($enc, 0, $enc.Length)
            }
            return [Convert]::ToBase64String($out.ToArray())
        }

        # 2048-bit and larger: AES-256-CBC + HMAC-SHA256, both keys wrapped with RSA-OAEP-SHA256
        $keyEnc = [byte[]]::new(32)
        $keyMac = [byte[]]::new(64)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($keyEnc)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($keyMac)

        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.KeySize = 256
            $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key     = $keyEnc
            $aes.GenerateIV()
            $iv = $aes.IV
            $ct = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
        }
        finally { $aes.Dispose() }

        $alg  = [byte[]](0, 0)                     # Aes256CbcPkcs7, HMACSHA256
        $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyMac)
        try   { $tag = $hmac.ComputeHash([byte[]]($alg + $iv + $ct)) }
        finally { $hmac.Dispose() }

        $cipher  = [byte[]]($alg + $tag + $iv + $ct)
        $keys    = [byte[]](@(0, 1) + $keyEnc + $keyMac)   # KeyLength32, KeyLength64
        $encKeys = $rsa.Encrypt($keys, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        return [Convert]::ToBase64String($encKeys) + [Convert]::ToBase64String($cipher)
    }
    finally { $rsa.Dispose() }
}

function New-GLCredentialDetails {
    # The credentialDetails block of a Power BI datasource request.
    param(
        [Parameter(Mandatory)][string]$CredentialType,
        [string]$Username,
        [string]$Password,
        $PublicKey,   # checked inside, so a missing key gets a clear message
        [string]$Privacy = 'Organizational',
        [ValidateSet('Encrypted', 'NotEncrypted')][string]$Encryption = 'Encrypted'
    )
    if ($CredentialType -in 'Windows', 'Basic') {
        if ([string]::IsNullOrEmpty($Username) -or [string]::IsNullOrEmpty($Password)) {
            throw "$CredentialType credentials need a username and a password."
        }
    }
    if ($CredentialType -eq 'Key' -and [string]::IsNullOrEmpty($Password)) { throw 'Key credentials need the key in the password field.' }
    if (-not $PublicKey -or -not $PublicKey.modulus -or -not $PublicKey.exponent) {
        throw 'The gateway has no public key - credentials cannot be encrypted for it.'
    }
    $json = ConvertTo-GLCredentialJson -CredentialType $CredentialType -Username $Username -Password $Password
    $enc  = ConvertTo-GLEncryptedCredential -CredentialJson $json -Modulus $PublicKey.modulus -Exponent $PublicKey.exponent
    if (-not $Privacy) { $Privacy = 'Organizational' }
    return [ordered]@{
        credentialType       = $CredentialType
        credentials          = $enc
        encryptedConnection  = $Encryption
        encryptionAlgorithm  = 'RSA-OAEP'
        privacyLevel         = $Privacy
        useCallerAADIdentity = $false
    }
}

function ConvertTo-GLEncryptionSetting {
    # Fabric reports Encrypted / NotEncrypted / Any. The Power BI datasource API
    # only takes Encrypted or NotEncrypted. "Any" means "use encryption if the
    # source supports it", so it maps to NotEncrypted - requiring encryption could
    # break a source that never had it.
    param([string]$Current, [string]$Choice = 'Keep')
    if ($Choice -in 'Encrypted', 'NotEncrypted') { return $Choice }
    if ($Current -eq 'Encrypted') { return 'Encrypted' }
    return 'NotEncrypted'
}

# ============================================================================
#  CONNECTION MANAGEMENT
# ============================================================================

function Set-GLConnectionCredential {
    # Documented Power BI endpoint: Gateways - Update Datasource.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GatewayId,
        [Parameter(Mandatory)][string]$ConnectionId,
        $PublicKey,   # checked inside, so a missing key gets a clear message
        [Parameter(Mandatory)][string]$CredentialType,
        [string]$Username,
        [string]$Password,
        [string]$Privacy,
        [string]$Encryption = 'Encrypted',
        [Parameter(Mandatory)][string]$PbiToken
    )
    $details = New-GLCredentialDetails -CredentialType $CredentialType -Username $Username -Password $Password `
        -PublicKey $PublicKey -Privacy $Privacy -Encryption $Encryption
    $null = Invoke-GLRequest -Method PATCH -Uri "https://api.powerbi.com/v1.0/myorg/gateways/$GatewayId/datasources/$ConnectionId" `
        -Token $PbiToken -Body @{ credentialDetails = $details } -MaxRetry 2
}

function Get-GLPortalCredentialMethod {
    # The HTTP method of the portal's credentialsV2 call, as the portal sends it. One
    # place, so the demo answers exactly what the real service accepts.
    return 'PATCH'
}

function ConvertFrom-GLRsaXmlKey {
    # A gateway member's public key as the portal's API gives it - base64 of an XML
    # <RSAParameters> - as the modulus and exponent the encryption takes.
    param([Parameter(Mandatory)][string]$Base64Xml)
    $text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64Xml)).TrimStart([char]0xFEFF)
    $x = [xml]$text
    $mod = [string]$x.RSAParameters.Modulus
    $exp = [string]$x.RSAParameters.Exponent
    if (-not $mod -or -not $exp) { throw 'The gateway member key has no modulus or exponent.' }
    return [pscustomobject]@{ modulus = $mod.Trim(); exponent = $exp.Trim() }
}

function Set-GLConnectionCredentialPortal {
    <#
        UNOFFICIAL - the way the portal updates a gateway connection's credentials.

        The documented Update Datasource call stores only the encrypted credentials,
        and the readable copy of the username (publicCredentialProperties - the
        Account column, and the username the portal shows) is lost. The portal
        reads each gateway member's key from
            GET /v2.0/myorg/me/gatewayClusterDatasources/{id}
        encrypts the credentials once per member, and sends them all to
            /v2.0/myorg/me/gatewayClusters/{cluster}/datasources/{id}/credentialsV2
        Privacy level, encryption and Skip test connection stay as they are, unless
        -Encryption says otherwise. Throws like any request; Invoke-GLBulkCredentials
        decides whether the documented way may be tried after a refusal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GatewayId,
        [Parameter(Mandatory)][string]$ConnectionId,
        [Parameter(Mandatory)][string]$CredentialType,
        [string]$Username,
        [string]$Password,
        [string]$Encryption = 'Keep',
        [Parameter(Mandatory)][string]$PbiToken,
        [string]$Method = (Get-GLPortalCredentialMethod)
    )
    # Only reading so far: whatever this answers, nothing was changed - the documented
    # way may be tried, and gives its own answer.
    try { $ds = Invoke-GLRequest -Uri "https://api.powerbi.com/v2.0/myorg/me/gatewayClusterDatasources/$ConnectionId" -Token $PbiToken -MaxRetry 2 }
    catch { throw "PORTAL-NOT-USABLE: $($_.Exception.Message)" }
    $keys = $ds.memberGatewayPublicKeys
    $members = @(if ($keys) { $keys.PSObject.Properties | Where-Object { $_.Value } })
    if ($members.Count -eq 0) { throw 'PORTAL-NOT-USABLE: the data source lists no gateway member keys.' }
    $cur = $ds.credentialDetails
    $enc = if ($Encryption -in 'Encrypted', 'NotEncrypted') { $Encryption } elseif ($cur.encryptedConnection) { [string]$cur.encryptedConnection } else { 'Encrypted' }
    $priv = if ($cur.privacyLevel) { [string]$cur.privacyLevel } else { 'Organizational' }
    $json = ConvertTo-GLCredentialJson -CredentialType $CredentialType -Username $Username -Password $Password
    $perMember = [ordered]@{}
    foreach ($m in $members) {
        $k = ConvertFrom-GLRsaXmlKey -Base64Xml ([string]$m.Value)
        $perMember[[string]$m.Name] = [ordered]@{
            credentialType      = $CredentialType
            credentials         = (ConvertTo-GLEncryptedCredential -CredentialJson $json -Modulus $k.modulus -Exponent $k.exponent)
            encryptedConnection = $enc
            privacyLevel        = $priv
            skipTestConnection  = [bool]$cur.skipTestConnection
            encryptionAlgorithm = 'RSA-OAEP'
            credentialSources   = @()
        }
    }
    $null = Invoke-GLRequest -Method $Method -Uri "https://api.powerbi.com/v2.0/myorg/me/gatewayClusters/$GatewayId/datasources/$ConnectionId/credentialsV2" `
        -Token $PbiToken -Body @{ credentialDetails = $perMember } -MaxRetry 0
    return $members.Count
}

function Test-GLPortalWayRefused {
    <#
        Did the portal's endpoint refuse the request itself - so nothing was changed,
        and the documented way may be tried instead? The gateway's own answer to the
        new credentials (its DM_ codes - a wrong password, an unreachable server) is
        no refusal: they would fail the other way too. No answer at all may still
        have arrived, so it is never sent a second way.
    #>
    param([string]$Message)
    if ($Message -match 'PORTAL-NOT-USABLE') { return $true }
    if ($Message -match 'DM_GWPipeline|DMTS_') { return $false }
    if ($Message -match '-> HTTP (\d{3}) :') { return ([int]$Matches[1] -in 400, 403, 404, 405, 415, 501) }
    return $false
}

function Remove-GLConnection {
    # Documented Fabric endpoint: Connections - Delete Connection.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$FabricToken)
    $null = Invoke-GLRequest -Method DELETE -Uri "https://api.fabric.microsoft.com/v1/connections/$Id" -Token $FabricToken -MaxRetry 2
}

function Set-GLMemberEnabled {
    # Documented Fabric endpoint: Gateways - Update Gateway Member.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GatewayId,
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter(Mandatory)][string]$FabricToken
    )
    $null = Invoke-GLRequest -Method PATCH -Uri "https://api.fabric.microsoft.com/v1/gateways/$GatewayId/members/$MemberId" `
        -Token $FabricToken -Body @{ enabled = $Enabled }
}

function Test-GLConnectionsBulk {
    # Documented Power BI status endpoint, many connections at once.
    param([Parameter(Mandatory)]$Items, [Parameter(Mandatory)][string]$PbiToken, [int]$TimeoutSec = 60)
    $map = @{}
    foreach ($it in $Items) {
        $map["https://api.powerbi.com/v1.0/myorg/gateways/$($it.GatewayId)/datasources/$($it.Id)/status"] = [string]$it.Id
    }
    $out = @{}
    if ($map.Count -eq 0) { return $out }
    $res = Invoke-GLParallelGet -Uris @($map.Keys) -Token $PbiToken -TimeoutSec $TimeoutSec
    foreach ($u in $map.Keys) {
        $r = $res[$u]
        $msg = ''
        if ($r -and -not $r.Ok) {
            $msg = if ($r.Body) { ConvertFrom-GLApiError $r.Body } else { [string]$r.Error }
        }
        $out[$map[$u]] = [pscustomobject]@{
            Ok     = [bool]($r -and $r.Ok)
            Status = if ($r -and $r.Ok) { 'OK' } elseif ($r -and $r.Status -eq 0) { 'Timeout' } else { 'Failed' }
            Detail = $msg
        }
    }
    return $out
}

function Get-GLRoleAssignmentsBulk {
    # Who has access to many connections - or gateways - one documented Fabric call
    # each, in parallel. A target that could not be read maps to $null.
    param([Parameter(Mandatory)][string[]]$Ids, [Parameter(Mandatory)][string]$FabricToken,
          [ValidateSet('gateways', 'connections')][string]$Kind = 'connections', [hashtable]$Errors)
    $map = @{}
    foreach ($id in $Ids) { $map["https://api.fabric.microsoft.com/v1/$Kind/$id/roleAssignments"] = $id }
    $out = @{}
    if ($map.Count -eq 0) { return $out }
    $res = Invoke-GLParallelGet -Uris @($map.Keys) -Token $FabricToken -TimeoutSec 60
    foreach ($u in $map.Keys) {
        $r = $res[$u]
        # assigned directly: an empty list that comes out of an if-statement becomes
        # $null, and "nobody has access" would read as "could not be read"
        if ($r -and $r.Ok -and $r.Body) { $out[$map[$u]] = @($r.Body.value) }
        else {
            $out[$map[$u]] = $null
            if ($null -ne $Errors) {
                $Errors[$map[$u]] = if (-not $r) { 'no answer' } elseif ($r.Body) { "HTTP $($r.Status): $(ConvertFrom-GLApiError $r.Body)" } else { [string]$r.Error }
            }
        }
    }
    return $out
}

function Get-GLDatasourceDirectory {
    <#
        UNOFFICIAL.

        /v2.0/myorg/me/gatewayClusterDatasources?$expand=users is what the portal
        uses. One paged call returns every gateway data source with its credential
        username and its users - the documented route needs a call per connection
        for the users and has no username at all. Isolated like live status: it
        feeds the Account and Users columns, and a failure means those stay empty.

        Returns a hashtable keyed by lower-case data source id:
            Account   - the username stored in the credentials, if any
            Users     - list of @{ Principal; Right }
            ClusterId - the gateway it is on, lower case
    #>
    param([Parameter(Mandatory)][string]$PbiToken, [int]$MaxPages = 200, [hashtable]$Report)
    Set-GLReport $Report 'reading usernames and access'
    $next  = 'https://api.powerbi.com/v2.0/myorg/me/gatewayClusterDatasources?$expand=users'
    $out   = @{}
    $pages = 0
    while ($next -and $pages -lt $MaxPages) {
        $pages++
        $r = Invoke-GLRequest -Uri $next -Token $PbiToken
        foreach ($ds in $r.value) {
            if (-not $ds -or -not $ds.id) { continue }
            $stored = ''
            $pcp = $ds.credentialDetails.publicCredentialProperties
            if ($pcp) {
                try {
                    $props = if ($pcp -is [string]) { $pcp | ConvertFrom-Json -ErrorAction Stop } else { $pcp }
                    $u = $props | Where-Object { $_.name -eq 'username' } | Select-Object -First 1
                    if ($u) { $stored = [string]$u.value }
                } catch { }
            }
            $users = foreach ($x in $ds.users) {
                if (-not $x) { continue }
                $who = @($x.emailAddress, $x.userPrincipalName, $x.displayName, $x.identifier, $x.id) | Where-Object { $_ } | Select-Object -First 1
                [pscustomobject]@{ Principal = [string]$who; Right = [string](@($x.datasourceAccessRight, $x.role) | Where-Object { $_ } | Select-Object -First 1) }
            }
            $out[([string]$ds.id).ToLowerInvariant()] = [pscustomobject]@{ Account = $stored; Users = @($users); ClusterId = ([string]$ds.clusterId).ToLowerInvariant() }
        }
        if ($Report) { $Report.Done = $out.Count }
        $next = $null
        $nl = $r.PSObject.Properties['@odata.nextLink']
        if ($nl -and $nl.Value) { $next = [string]$nl.Value }
    }
    return $out
}

function Resolve-GLHostAddress {
    <#
        IPv4 address for a gateway machine. Tries the name as given - Windows adds
        its own DNS suffix search list - then each extra suffix supplied.
        Returns "IP;HOSTNAME", or "UNKNOWN;machine".
    #>
    param([string]$Machine, [string[]]$Suffixes = @(), [scriptblock]$Resolver)
    if ([string]::IsNullOrWhiteSpace($Machine)) { return $null }
    if (-not $Resolver) {
        $Resolver = if ([System.AppDomain]::CurrentDomain.GetData('GatewayLens.Demo')) { { param($n) Get-GLDemoAddress $n } }
                    else { { param($n) [System.Net.Dns]::GetHostAddresses($n) } }
    }
    $m = $Machine.Trim().TrimEnd('.')
    $candidates = @($m)
    if (-not $m.Contains('.')) { foreach ($s in $Suffixes) { if ($s) { $candidates += "$m.$($s.Trim('.'))" } } }
    foreach ($c in $candidates) {
        try {
            $ip = @(& $Resolver $c) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                ForEach-Object { $_.ToString() } | Select-Object -First 1
            if ($ip) { return "$ip;$c" }
        } catch { }
    }
    return "UNKNOWN;$m"
}

function Format-GLClusterText {
    # One cluster as tab-separated lines, for Copy - pastes cleanly into Excel or a ticket.
    param([string]$GatewayName, $MemberRows)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $MemberRows) {
        $lines.Add((@($GatewayName, $m.Member, $m.Machine, $m.Version, $m.Enabled, $m.Status) -join "`t"))
    }
    return ($lines.ToArray() -join "`r`n")
}

# ---- the newest gateway version, from Microsoft's public pages ----------------------
function ConvertFrom-GLDownloadPage {
    # The Download Center page for the gateway: version and date of the newest build,
    # from the JSON the page carries - or, failing that, from its "Version:" label.
    param([string]$Html)
    $t = [string]$Html
    $v = $null
    foreach ($rx in '"detailsSection_file_version"\s*:\s*"(\d+\.\d+\.\d+(?:\.\d+)?)"',
                    '>Version:</h3>\s*<p[^>]*>\s*(\d+\.\d+\.\d+(?:\.\d+)?)\s*<') {
        $m = [regex]::Match($t, $rx)
        if ($m.Success) { $v = [version]$m.Groups[1].Value; break }
    }
    if (-not $v) { return $null }
    $published = $null
    $m = [regex]::Match($t, '"datePublished"\s*:\s*"([^"]+)"')
    if ($m.Success) {
        $d = [datetime]::MinValue
        $us = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
        if ([datetime]::TryParse($m.Groups[1].Value, $us, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { $published = $d }
    }
    return [pscustomobject]@{ Version = $v; Published = $published }
}

function ConvertFrom-GLReleasePage {
    # Learn's list of the monthly releases Microsoft still supports - the last six -
    # newest first, from headings such as "September 2026 update (3000.334)".
    param([string]$Html)
    $seen = @{}
    $list = foreach ($m in [regex]::Matches([string]$Html, '([A-Z][a-z]+ \d{4}) update \((\d+\.\d+)\)')) {
        $v = [version]$m.Groups[2].Value
        if ($seen.ContainsKey("$v")) { continue }
        $seen["$v"] = $true
        [pscustomobject]@{ Name = $m.Groups[1].Value; Version = $v }
    }
    return , @($list | Sort-Object Version -Descending)
}

function Get-GLGatewayReleases {
    <#
        PUBLIC WEB PAGES, not an API: the newest gateway build from the Download
        Center, and the releases Microsoft still supports from Learn. No sign-in and
        no token - nothing about the tenant is sent anywhere. Either page can be
        unreachable or change its layout; then its part stays empty, the version
        badges compare members with each other only, and Log says why. Never an error.
    #>
    param([int]$TimeoutSec = 20)
    $pages = [ordered]@{
        Download = 'https://www.microsoft.com/en-us/download/details.aspx?id=53127'
        Releases = 'https://learn.microsoft.com/en-us/data-integration/gateway/service-gateway-monthly-updates'
    }
    $text = @{}
    $log  = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $pages.Keys) {
        try {
            if ([System.AppDomain]::CurrentDomain.GetData('GatewayLens.Demo')) {   # -Demo: answered locally
                $d = Invoke-GLDemoHttp -Uri $pages[$k]
                if ($d.Status -ne 200) { throw "HTTP $($d.Status)" }
                $text[$k] = [string]$d.Body
            }
            else {
                $text[$k] = (Invoke-WebRequest -Uri $pages[$k] -TimeoutSec $TimeoutSec -UseBasicParsing -Headers @{ 'Accept-Language' = 'en-US' } -ErrorAction Stop).Content
            }
        }
        catch { $log.Add("$($pages[$k]): $($_.Exception.Message)") }
    }
    $newest    = ConvertFrom-GLDownloadPage $text['Download']
    $supported = ConvertFrom-GLReleasePage $text['Releases']
    if ($text['Download'] -and -not $newest)        { $log.Add("$($pages.Download): no version on the page - its layout may have changed") }
    if ($text['Releases'] -and $supported.Count -eq 0) { $log.Add("$($pages.Releases): no releases on the page - its layout may have changed") }
    return [pscustomobject]@{
        Newest    = if ($newest) { $newest.Version } elseif ($supported.Count) { $supported[0].Version } else { $null }
        Published = if ($newest) { $newest.Published } else { $null }
        Supported = $supported
        Checked   = Get-Date
        Log       = $log.ToArray()
    }
}

function Get-GLReleaseInfo {
    # One gateway version against Microsoft's pages: the release it belongs to, and
    # Current (the newest build or later), Behind, or Unsupported (older than the
    # oldest release Microsoft still supports). $null when the pages were not read.
    param($Version, $Releases)
    $v = $null
    if (-not $Releases -or -not $Releases.Newest -or -not [version]::TryParse([string]$Version, [ref]$v)) { return $null }
    $mm  = [version]::new($v.Major, $v.Minor)
    $sup = @($Releases.Supported)
    $rel = $sup | Where-Object { $_.Version -eq $mm } | Select-Object -First 1
    $state = if ($sup.Count -and $mm -lt $sup[$sup.Count - 1].Version) { 'Unsupported' }
             elseif ($v -ge [version]$Releases.Newest) { 'Current' }
             else { 'Behind' }
    return [pscustomobject]@{ State = $state; Release = $(if ($rel) { $rel.Name } else { '' }) }
}

function Get-GLGatewayState {
    # Online / Offline / Partial / Unknown from the gateway rows' "up / total".
    param([string]$Online)
    if ($Online -notmatch '^(\d+) / (\d+)$') { return 'Unknown' }
    $up = [int]$Matches[1]; $all = [int]$Matches[2]
    if ($all -eq 0)   { return 'Unknown' }
    if ($up -eq $all) { return 'Online' }
    if ($up -eq 0)    { return 'Offline' }
    return 'Partial'
}

function Split-GLList {
    # "a@x.com; b@x.com" or one per line -> clean, distinct list
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return , @() }
    $items = $Text -split '[;,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
    return , @($items)
}

# ============================================================================
#  BULK OPERATIONS
#
#  Each takes the connections to act on and a Progress hashtable shared with the
#  window: Total and Done are read to show progress, and setting Cancel stops the
#  run after the item in hand. Writes go one at a time, never in parallel - a bulk
#  change should be predictable, and easy on Microsoft's throttling.
#  Every function returns one result row per item: Name, Id, Ok, Message.
# ============================================================================

function New-GLResult([string]$Name, [string]$Id, [bool]$Ok, [string]$Message) {
    return [pscustomobject]@{ Name = $Name; Id = $Id; Ok = $Ok; Message = $Message }
}

function Invoke-GLBulkGrant {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)]$Principals,      # resolved: Id, DisplayName, Type
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$FabricToken,
        [Parameter(Mandatory)][hashtable]$Progress,
        $Audit
    )
    $Progress.Total = @($Items).Count * @($Principals).Count
    $Progress.Done  = 0
    $out  = [System.Collections.Generic.List[object]]::new()
    $rank = @{ User = 1; UserWithReshare = 2; Owner = 3 }
    foreach ($it in $Items) {
        # who has access now: a role they already have is not given again, a lower one is raised
        $now = $null
        try { $now = Get-GLRoleAssignments -Kind connections -Id $it.Id -FabricToken $FabricToken } catch { }
        foreach ($p in $Principals) {
            if ($Progress.Cancel) { return , $out.ToArray() }
            $rec = @{ Audit = $Audit; Action = 'Grant access'; TargetType = 'Connection'; Target = $it.Name; TargetId = $it.Id
                      Gateway = $it.Gateway; GatewayId = $it.GatewayId; Principal = $p.DisplayName; PrincipalId = $p.Id
                      PrincipalType = $p.Type; Role = $Role }
            $has = @($now | Where-Object { $_ -and ([string]$_.principal.id) -ieq [string]$p.Id }) | Select-Object -First 1
            try {
                if ($has -and [int]$rank[[string]$has.role] -ge [int]$rank[$Role]) {
                    Write-GLChange @rec -Result NoChange -Message "already had access as $($has.role)"
                    $out.Add((New-GLResult $it.Name $it.Id $true "$($p.DisplayName) already has $($has.role)"))
                }
                elseif ($has) {
                    Set-GLRoleAssignment -Kind connections -Id $it.Id -AssignmentId $has.id -Role $Role -FabricToken $FabricToken
                    $rec.Action = 'Change role'; $rec.Details = "From $($has.role) to $Role"
                    Write-GLChange @rec -Result Done
                    $out.Add((New-GLResult $it.Name $it.Id $true "raised $($p.DisplayName) from $($has.role) to $Role"))
                }
                else {
                    $null = Add-GLRoleAssignment -Kind connections -Id $it.Id -PrincipalId $p.Id -PrincipalType $p.Type -Role $Role -FabricToken $FabricToken
                    Write-GLChange @rec -Result Done
                    $out.Add((New-GLResult $it.Name $it.Id $true "granted $Role to $($p.DisplayName)"))
                }
            }
            catch {
                $m = $_.Exception.Message
                # already having access is not a failure of what was asked
                if ($m -match 'already|exist|Conflict|HTTP 409') {
                    Write-GLChange @rec -Result NoChange -Message 'already had access'
                    $out.Add((New-GLResult $it.Name $it.Id $true "$($p.DisplayName) already has access"))
                }
                else {
                    Write-GLChange @rec -Result Failed -Message $m
                    $out.Add((New-GLResult $it.Name $it.Id $false "$($p.DisplayName): $m"))
                }
            }
            $Progress.Done++
        }
    }
    return , $out.ToArray()
}

function Invoke-GLBulkRevoke {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)]$Principals,
        [Parameter(Mandatory)][string]$FabricToken,
        [Parameter(Mandatory)][hashtable]$Progress,
        $Audit
    )
    $ids = @($Principals | ForEach-Object { ([string]$_.Id).ToLowerInvariant() })
    $Progress.Total = @($Items).Count
    $Progress.Done  = 0
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($it in $Items) {
        if ($Progress.Cancel) { return , $out.ToArray() }
        $base = @{ Audit = $Audit; Action = 'Remove access'; TargetType = 'Connection'; Target = $it.Name; TargetId = $it.Id
                   Gateway = $it.Gateway; GatewayId = $it.GatewayId }
        try {
            $ras  = Get-GLRoleAssignments -Kind connections -Id $it.Id -FabricToken $FabricToken
            $hits = @($ras | Where-Object { $ids -contains ([string]$_.principal.id).ToLowerInvariant() })
            if ($hits.Count -eq 0) {
                Write-GLChange @base -Result NoChange -Principal (@($Principals | ForEach-Object DisplayName) -join '; ') -Message 'none of them had access'
                $out.Add((New-GLResult $it.Name $it.Id $true 'none of them had access'))
            }
            foreach ($h in $hits) {
                $given = @($Principals | Where-Object { ([string]$_.Id) -ieq [string]$h.principal.id }) | Select-Object -First 1
                $who = if ($given.DisplayName) { $given.DisplayName } elseif ($h.principal.displayName) { $h.principal.displayName } else { $h.principal.id }
                $rec = $base + @{ Principal = $who; PrincipalId = [string]$h.principal.id; PrincipalType = [string]$h.principal.type; Role = [string]$h.role }
                try {
                    Remove-GLRoleAssignment -Kind connections -Id $it.Id -AssignmentId $h.id -FabricToken $FabricToken
                    Write-GLChange @rec -Result Done
                    $out.Add((New-GLResult $it.Name $it.Id $true "removed $who ($($h.role))"))
                }
                catch {
                    Write-GLChange @rec -Result Failed -Message $_.Exception.Message
                    $out.Add((New-GLResult $it.Name $it.Id $false "$($who): $($_.Exception.Message)"))
                }
            }
        }
        catch {
            Write-GLChange @base -Result Failed -Message $_.Exception.Message
            $out.Add((New-GLResult $it.Name $it.Id $false $_.Exception.Message))
        }
        $Progress.Done++
    }
    return , $out.ToArray()
}

function Invoke-GLBulkMembers {
    # Enables or disables gateway members one at a time, each recorded as it happens.
    param(
        [Parameter(Mandatory)]$Gateway,        # Id, Name
        [Parameter(Mandatory)]$Members,        # Id, Member, Machine
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter(Mandatory)][string]$FabricToken,
        [Parameter(Mandatory)][hashtable]$Progress,
        $Audit
    )
    $verb = if ($Enabled) { 'Enable' } else { 'Disable' }
    $list = @($Members)
    $Progress.Total = $list.Count
    $Progress.Done  = 0
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $list) {
        if ($Progress.Cancel) { return , $out.ToArray() }
        $rec = @{ Audit = $Audit; Action = "$verb member"; TargetType = 'Gateway member'; Target = [string]$m.Member; TargetId = [string]$m.Id
                  Gateway = [string]$Gateway.Name; GatewayId = [string]$Gateway.Id; Details = "Machine=$($m.Machine)" }
        try {
            Set-GLMemberEnabled -GatewayId $Gateway.Id -MemberId $m.Id -Enabled $Enabled -FabricToken $FabricToken
            Write-GLChange @rec -Result Done
            $out.Add((New-GLResult $m.Member $m.Id $true "$($verb.ToLower())d"))
        }
        catch {
            Write-GLChange @rec -Result Failed -Message $_.Exception.Message
            $out.Add((New-GLResult $m.Member $m.Id $false $_.Exception.Message))
        }
        $Progress.Done++
    }
    return , $out.ToArray()
}

function Invoke-GLAccessHandover {
    <#
        Gives To exactly the roles From has, target by target - gateways and
        connections - one at a time; with -Move, From's role is taken away after.
        From's role is only removed where To has that role (or a higher one) by
        then: a grant that failed never leaves a connection without its owner.
        Who has access is read 25 targets at a time, in parallel, just before they
        are changed - never from an old list.
    #>
    param(
        [Parameter(Mandatory)]$Targets,     # Kind (gateways | connections), Id, Name, Gateway, GatewayId
        [Parameter(Mandatory)]$From,        # Id (may be empty), DisplayName, Names (UPNs or emails)
        [Parameter(Mandatory)]$To,          # Id, DisplayName, Type
        [switch]$Move,
        [Parameter(Mandatory)][string]$FabricToken,
        [Parameter(Mandatory)][hashtable]$Progress,
        $Audit
    )
    if (Test-GLPrincipalMatch -Principal ([pscustomobject]@{ id = $To.Id }) -Who $From) {
        throw "'$($To.DisplayName)' is the one handing over - choose someone else to take over."
    }
    $list = @($Targets)
    $Progress.Total = $list.Count
    $Progress.Done  = 0
    $out = [System.Collections.Generic.List[object]]::new()
    for ($c = 0; $c -lt $list.Count; $c += 25) {
        $chunk = @($list[$c..([Math]::Min($c + 25, $list.Count) - 1)])
        $read = @{}
        foreach ($kind in 'gateways', 'connections') {
            $ids = @($chunk | Where-Object Kind -eq $kind | ForEach-Object { [string]$_.Id })
            if ($ids.Count) {
                $res = Get-GLRoleAssignmentsBulk -Ids $ids -FabricToken $FabricToken -Kind $kind
                foreach ($k in $res.Keys) { $read["$kind/$k"] = $res[$k] }
            }
        }
        foreach ($tg in $chunk) {
            if ($Progress.Cancel) { return , $out.ToArray() }
            $base  = @{ Audit = $Audit; TargetType = $(if ($tg.Kind -eq 'gateways') { 'Gateway' } else { 'Connection' })
                        Target = $tg.Name; TargetId = $tg.Id; Gateway = $tg.Gateway; GatewayId = $tg.GatewayId }
            $toRec = $base + @{ Principal = $To.DisplayName; PrincipalId = $To.Id; PrincipalType = $To.Type }
            $ras = $read["$($tg.Kind)/$($tg.Id)"]
            if ($null -eq $ras) {
                Write-GLChange @toRec -Action 'Grant access' -Result Failed -Message 'who has access could not be read'
                $out.Add((New-GLResult $tg.Name $tg.Id $false 'who has access could not be read - nothing was changed'))
                $Progress.Done++
                continue
            }
            $step = Get-GLHandoverStep -Assignments $ras -From $From -To $To -Kind $tg.Kind
            if ($step.Action -eq 'None') {
                Write-GLChange @toRec -Action 'Grant access' -Result NoChange -Message "$($From.DisplayName) has no role here"
                $out.Add((New-GLResult $tg.Name $tg.Id $true "$($From.DisplayName) has no role here"))
                $Progress.Done++
                continue
            }
            $toRec.Role    = $step.Role
            $toRec.Details = "Handed over from $($From.DisplayName)"
            $note = ''
            $keepFrom = $false
            try {
                if ($step.Action -eq 'Grant') {
                    try {
                        $null = Add-GLRoleAssignment -Kind $tg.Kind -Id $tg.Id -PrincipalId $To.Id -PrincipalType $To.Type -Role $step.Role -FabricToken $FabricToken
                        Write-GLChange @toRec -Action 'Grant access' -Result Done
                        $note = "gave $($To.DisplayName) $($step.Role)"
                    }
                    catch {
                        if ($_.Exception.Message -notmatch 'already|exist|Conflict|HTTP 409') { throw }
                        # a role that appeared since it was read - not checked, so From keeps theirs
                        Write-GLChange @toRec -Action 'Grant access' -Result NoChange -Message 'already had a role'
                        $note = "$($To.DisplayName) already has a role here"
                        $keepFrom = $true
                    }
                }
                elseif ($step.Action -eq 'Raise') {
                    Set-GLRoleAssignment -Kind $tg.Kind -Id $tg.Id -AssignmentId $step.ToAssignmentId -Role $step.Role -FabricToken $FabricToken
                    $toRec.Details = "From $($step.ToRole) to $($step.Role), handed over from $($From.DisplayName)"
                    Write-GLChange @toRec -Action 'Change role' -Result Done
                    $note = "raised $($To.DisplayName) from $($step.ToRole) to $($step.Role)"
                }
                else {
                    Write-GLChange @toRec -Action 'Grant access' -Result NoChange -Message "already has $($step.ToRole)"
                    $note = "$($To.DisplayName) already has $($step.ToRole)"
                }
            }
            catch {
                $m = $_.Exception.Message
                Write-GLChange @toRec -Action $(if ($step.Action -eq 'Raise') { 'Change role' } else { 'Grant access' }) -Result Failed -Message $m
                $kept = if ($Move) { " - $($From.DisplayName) keeps it" } else { '' }
                $out.Add((New-GLResult $tg.Name $tg.Id $false "$($To.DisplayName) could not be given $($step.Role): $m$kept"))
                $Progress.Done++
                continue
            }
            if ($Move -and $keepFrom) {
                $out.Add((New-GLResult $tg.Name $tg.Id $false "$note, so $($From.DisplayName) was not removed - check it by hand"))
                $Progress.Done++
                continue
            }
            if ($Move) {
                $fromRec = $base + @{ Principal = $From.DisplayName; PrincipalId = [string]$step.FromPrincipal.id
                                      PrincipalType = [string]$step.FromPrincipal.type; Role = $step.Role; Details = "Handed over to $($To.DisplayName)" }
                try {
                    Remove-GLRoleAssignment -Kind $tg.Kind -Id $tg.Id -AssignmentId $step.FromAssignmentId -FabricToken $FabricToken
                    Write-GLChange @fromRec -Action 'Remove access' -Result Done
                    $note += ", removed $($From.DisplayName)"
                }
                catch {
                    Write-GLChange @fromRec -Action 'Remove access' -Result Failed -Message $_.Exception.Message
                    $out.Add((New-GLResult $tg.Name $tg.Id $false "$note, but $($From.DisplayName) could not be removed: $($_.Exception.Message)"))
                    $Progress.Done++
                    continue
                }
            }
            $out.Add((New-GLResult $tg.Name $tg.Id $true $note))
            $Progress.Done++
        }
    }
    return , $out.ToArray()
}

function Get-GLAccessReport {
    # Who has access to every target, read 25 at a time in parallel, as report rows.
    param([Parameter(Mandatory)]$Targets, [string]$Who, [Parameter(Mandatory)][string]$FabricToken, [Parameter(Mandatory)][hashtable]$Progress,
          [string]$GraphToken, [hashtable]$Known = @{})
    $list = @($Targets)
    $Progress.Total = $list.Count
    $Progress.Done  = 0
    $read = @{}
    for ($c = 0; $c -lt $list.Count; $c += 25) {
        if ($Progress.Cancel) { return , @() }
        $chunk = @($list[$c..([Math]::Min($c + 25, $list.Count) - 1)])
        foreach ($kind in 'gateways', 'connections') {
            $ids = @($chunk | Where-Object Kind -eq $kind | ForEach-Object { [string]$_.Id })
            if ($ids.Count) {
                $res = Get-GLRoleAssignmentsBulk -Ids $ids -FabricToken $FabricToken -Kind $kind
                foreach ($k in $res.Keys) { $read["$kind/$k"] = $res[$k] }
            }
        }
        $Progress.Done = [Math]::Min($c + 25, $list.Count)
    }
    $names = @{} + $Known
    try { $names += Get-GLPrincipalNames -Ids @($read.Values | Where-Object { $_ } | ForEach-Object { $_ } | ForEach-Object { [string]$_.principal.id }) -GraphToken $GraphToken -Known $Known } catch { }
    $rows = ConvertTo-GLAccessReportRows -Targets $list -Assignments $read -Who $Who -Names $names
    return , $rows
}

function Invoke-GLBulkCredentials {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][string]$CredentialType,
        [string]$Username,
        [string]$Password,
        [string]$EncryptionChoice = 'Keep',
        [Parameter(Mandatory)][hashtable]$PublicKeys,   # gateway id (lower case) -> publicKey
        [Parameter(Mandatory)][string]$PbiToken,
        [Parameter(Mandatory)][hashtable]$Progress,
        $Audit,
        [switch]$PortalWay,                                # the portal's way first - keeps the username readable
        [string]$PortalMethod = (Get-GLPortalCredentialMethod)
    )
    $Progress.Total = @($Items).Count
    $Progress.Done  = 0
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($it in $Items) {
        if ($Progress.Cancel) { return , $out.ToArray() }
        # never the password - only what kind of credentials and whose
        $rec = @{ Audit = $Audit; Action = 'Update credentials'; TargetType = 'Connection'; Target = $it.Name; TargetId = $it.Id
                  Gateway = $it.Gateway; GatewayId = $it.GatewayId; Details = "Type=$CredentialType; Username=$Username; Encryption=$EncryptionChoice" }
        if ($it.Connectivity -ne 'OnPremisesGateway' -or -not $it.GatewayId) {
            Write-GLChange @rec -Result Skipped -Message "$($it.Connectivity) connection"
            $out.Add((New-GLResult $it.Name $it.Id $false "skipped - $($it.Connectivity) connections are not updated here"))
        }
        else {
            $way = 'documented'; $refused = ''
            try {
                if ($PortalWay) {
                    # the portal's way first: the username stays readable afterwards
                    try {
                        $null = Set-GLConnectionCredentialPortal -GatewayId $it.GatewayId -ConnectionId $it.Id -CredentialType $CredentialType `
                            -Username $Username -Password $Password -Encryption $EncryptionChoice -PbiToken $PbiToken -Method $PortalMethod
                        $way = 'portal'
                    }
                    catch {
                        if (-not (Test-GLPortalWayRefused $_.Exception.Message)) { throw }
                        $refused = ($_.Exception.Message -replace '^PORTAL-NOT-USABLE: ', '')
                    }
                }
                if ($way -eq 'documented') {
                    $key = $PublicKeys[([string]$it.GatewayId).ToLowerInvariant()]
                    $enc = ConvertTo-GLEncryptionSetting -Current $it.Encryption -Choice $EncryptionChoice
                    Set-GLConnectionCredential -GatewayId $it.GatewayId -ConnectionId $it.Id -PublicKey $key `
                        -CredentialType $CredentialType -Username $Username -Password $Password `
                        -Privacy $it.Privacy -Encryption $enc -PbiToken $PbiToken
                }
                $rec.Details += "; Way=$(if ($way -eq 'portal') { 'like the portal (unofficial)' } else { 'documented API' })"
                Write-GLChange @rec -Result Done -Message $(if ($refused) { "the portal's way was refused: $refused" } else { '' })
                $msg = if ($way -eq 'portal') { "credentials updated ($CredentialType)" }
                       elseif ($refused) { "credentials updated ($CredentialType) the documented way - the portal's way was refused ($(if ($refused -match 'HTTP \d{3}') { $Matches[0] } else { $refused })), so the Account can be empty after a refresh" }
                       else { "credentials updated ($CredentialType)" }
                $res = New-GLResult $it.Name $it.Id $true $msg
                $res | Add-Member -NotePropertyName Way -NotePropertyValue $way
                $out.Add($res)
            }
            catch {
                Write-GLChange @rec -Result Failed -Message $_.Exception.Message
                $out.Add((New-GLResult $it.Name $it.Id $false $_.Exception.Message))
            }
        }
        $Progress.Done++
    }
    return , $out.ToArray()
}

function Backup-GLConnections {
    <#
        Writes a CSV of connections before they are deleted - everything the API
        returns about them, so they can be recreated: name, gateway, type, path,
        credential type and username, privacy, encryption, who had access, and the
        complete connection definition as JSON. Passwords cannot be included: the
        API never returns them.

        Throws if the file cannot be written. Invoke-GLBulkDelete refuses to run
        without a backup, so a failed backup means nothing is deleted.
    #>
    param(
        [Parameter(Mandatory)]$Items,
        [hashtable]$Raw = @{},            # id -> the connection object from the API
        [hashtable]$Assignments = @{},    # id -> role assignments, or $null
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Names = @{}           # principal id -> Name, Email (Graph)
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop }
    $rows = foreach ($it in $Items) {
        $id  = [string]$it.Id
        $ras = if ($Assignments.ContainsKey($id)) { $Assignments[$id] } else { $null }
        $access = if ($null -eq $ras) { (@($it.UserList) -join '; ') }
                  else {
                      (@($ras | ForEach-Object {
                          $pr  = $_.principal
                          $who = (Get-GLPrincipalLabel -Principal $pr -Names $Names).Key
                          "$who ($($pr.type), $($_.role)) [$($pr.id)]"
                      }) -join '; ')
                  }
        $json = if ($Raw.ContainsKey($id)) { $Raw[$id] | ConvertTo-Json -Depth 10 -Compress } else { '' }
        [pscustomobject][ordered]@{
            Id           = $id
            Name         = [string]$it.Name
            Connectivity = [string]$it.Connectivity
            Gateway      = [string]$it.Gateway
            GatewayId    = [string]$it.GatewayId
            Type         = [string]$it.Type
            Path         = [string]$it.Path
            Credential   = [string]$it.Credential
            Account      = [string]$it.Account
            Privacy      = [string]$it.Privacy
            Encryption   = [string]$it.Encryption
            Access       = $access
            DefinitionJson = $json
        }
    }
    @($rows) | Export-Csv -Path $Path -NoTypeInformation -Encoding utf8BOM -ErrorAction Stop
    return $Path
}

function Invoke-GLBulkDelete {
    # Refuses to delete anything that is not in the backup file - checked here, not
    # just in the window, so no path through the code can delete without one.
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$FabricToken,
        [Parameter(Mandatory)][hashtable]$Progress,
        $Audit
    )
    if (-not (Test-Path -LiteralPath $BackupPath)) { throw "No backup at '$BackupPath' - nothing was deleted." }
    $saved = @(Import-Csv -LiteralPath $BackupPath | ForEach-Object { [string]$_.Id })
    $missing = @($Items | Where-Object { $saved -notcontains [string]$_.Id })
    if ($missing.Count) { throw "$($missing.Count) connection(s) are not in the backup '$BackupPath' - nothing was deleted." }
    $Progress.Total = @($Items).Count
    $Progress.Done  = 0
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($it in $Items) {
        if ($Progress.Cancel) { return , $out.ToArray() }
        $rec = @{ Audit = $Audit; Action = 'Delete connection'; TargetType = 'Connection'; Target = $it.Name; TargetId = $it.Id
                  Gateway = $it.Gateway; GatewayId = $it.GatewayId; Details = "Backup=$BackupPath" }
        try {
            Remove-GLConnection -Id $it.Id -FabricToken $FabricToken
            Write-GLChange @rec -Result Done
            $out.Add((New-GLResult $it.Name $it.Id $true 'deleted'))
        }
        catch {
            Write-GLChange @rec -Result Failed -Message $_.Exception.Message
            $out.Add((New-GLResult $it.Name $it.Id $false $_.Exception.Message))
        }
        $Progress.Done++
    }
    return , $out.ToArray()
}

# ============================================================================
#  SETTINGS AND HISTORY
#
#  Theme, font size and what was typed into each search and name box, kept in
#  %LOCALAPPDATA%\GatewayLens\settings.json for this user only. Password boxes are
#  never recorded - they are not even passed in - and any field whose name looks
#  like a password is refused here as a second line of defence.
# ============================================================================

function Get-GLSettingsPath {
    $base = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $base) { $base = $HOME }
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $base 'GatewayLens') 'settings.json')
}

function Get-GLFontStep {
    <#
        What a key or a turn of the mouse wheel does to the text size: 1 larger,
        -1 smaller, 0 back to the default, $null nothing. Only with Ctrl held, as in
        a browser: Ctrl + wheel, Ctrl + plus or minus (main keys or number pad), Ctrl + 0.
    #>
    param([string]$Key, [int]$Delta, [bool]$Ctrl)
    if (-not $Ctrl) { return $null }
    if ($Delta -gt 0) { return 1 }
    if ($Delta -lt 0) { return -1 }
    if ($Key -in 'OemPlus', 'Add')       { return 1 }
    if ($Key -in 'OemMinus', 'Subtract') { return -1 }
    if ($Key -in 'D0', 'NumPad0')        { return 0 }
    return $null
}

function Get-GLRowHeight {
    # Grid rows as compact as the text allows: its line height - about 4/3 of the
    # font size in Segoe UI - plus a little air. 22 at the default 12, 33 at 20.
    param([int]$FontSize)
    $row = [int][math]::Ceiling($FontSize * 4 / 3) + 6
    return [pscustomobject]@{ Row = $row; Header = $row + 6 }
}

function New-GLDefaultSettings {
    # Layout: the panel sizes the user dragged to. SeenVersion: the last version whose
    # news was shown. LastAccount: who signed in last, offered on the start page.
    # ShowGone: list accounts that are not in Entra ID in the access panels too.
    # Alerts: when a gateway member goes down - each way off until turned on. The
    # webhook address is kept encrypted for this Windows account.
    # LastConnectionCount: how many the last load found - "about how many" in the progress.
    return [ordered]@{ Theme = 'Light'; FontSize = 12; History = [ordered]@{}; Layout = [ordered]@{}; SeenVersion = ''; LastAccount = ''; ShowGone = $false
                       Alerts = [ordered]@{ Desktop = $false; Sound = $false; WebhookProtected = '' }; LastConnectionCount = 0 }
}

function Read-GLSettings {
    # Missing or damaged settings fall back to the defaults - never an error.
    param([string]$Path = (Get-GLSettingsPath))
    $s = New-GLDefaultSettings
    if (-not (Test-Path -LiteralPath $Path)) { return $s }
    try {
        $j = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($j.Theme)    { $s.Theme = [string]$j.Theme }
        if ($j.FontSize) { $s.FontSize = [Math]::Max(9, [Math]::Min(20, [int]$j.FontSize)) }
        if ($j.SeenVersion) { $s.SeenVersion = [string]$j.SeenVersion }
        if ($j.ShowGone -is [bool]) { $s.ShowGone = $j.ShowGone }
        try { $s.LastConnectionCount = [Math]::Max(0, [Math]::Min(1000000, [int]$j.LastConnectionCount)) } catch { }
        if ($j.Alerts) {
            $s.Alerts.Desktop = ($j.Alerts.Desktop -eq $true)
            $s.Alerts.Sound   = ($j.Alerts.Sound -eq $true)
            if ([string]$j.Alerts.WebhookProtected -match '^[0-9a-fA-F]+$') { $s.Alerts.WebhookProtected = [string]$j.Alerts.WebhookProtected }
        }
        if ($j.LastAccount -and [string]$j.LastAccount -match '^[^\s@]+@[^\s@]+$') { $s.LastAccount = [string]$j.LastAccount }
        if ($j.Layout) {
            foreach ($p in $j.Layout.PSObject.Properties) {
                # a size that makes no sense - a damaged file - is left out, never applied
                $v = 0.0
                try { $v = [double]$p.Value } catch { continue }
                if ($p.Name -match '^[A-Za-z]+$' -and $v -ge 0 -and $v -le 4000) { $s.Layout[$p.Name] = [int]$v }
            }
        }
        if ($j.History) {
            foreach ($p in $j.History.PSObject.Properties) {
                if ($p.Name -match 'pass|pwd|secret') { continue }
                $s.History[$p.Name] = @($p.Value | ForEach-Object { [string]$_ } | Where-Object { $_ })
            }
        }
    } catch { }
    return $s
}

function Get-GLLayout {
    # The panel sizes now - from before the kiosk view, if it is showing.
    $k = $script:KioskSaved
    $log = if ($k) { $k.Log } else { $script:UI.LogRow.Height }
    $det = if ($k) { $k.Detail } else { $script:UI.GwDetailRow.Height }
    $out = [ordered]@{}
    foreach ($pair in @(@('LogHeight', $log), @('GatewayDetailHeight', $det), @('ConnectionsBottomHeight', $script:UI.CnBottomRow.Height), @('ActionsWidth', $script:UI.CnActionsCol.Width))) {
        $g = $pair[1]
        if ($g -and $g.IsAbsolute) { $out[$pair[0]] = [int]$g.Value }
    }
    return $out
}

function Set-GLLayout {
    # The sizes from the settings, each one only if it fits the window.
    param($Layout)
    if (-not $Layout) { return }
    $map = @{ LogHeight = 'LogRow'; GatewayDetailHeight = 'GwDetailRow'; ConnectionsBottomHeight = 'CnBottomRow'; ActionsWidth = 'CnActionsCol' }
    foreach ($k in $map.Keys) {
        if (-not $Layout.Contains($k)) { continue }
        $v = [double]$Layout[$k]
        if ($v -lt 0 -or $v -gt 1600) { continue }
        $part = $script:UI[$map[$k]]
        if (-not $part) { continue }
        $len = [System.Windows.GridLength]::new($v)
        if ($k -eq 'ActionsWidth') { if ($v -ge 380) { $part.Width = $len } } else { $part.Height = $len }
    }
}

function Save-GLSettings {
    param([Parameter(Mandatory)]$Settings, [string]$Path = (Get-GLSettingsPath))
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $Settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8
        return $true
    } catch { return $false }
}

function Add-GLHistory {
    # Most recent first, no duplicates (case-insensitive), at most $Max entries.
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Field, [string]$Value, [int]$Max = 20)
    if ($Field -match 'pass|pwd|secret') { return $false }
    $v = if ($Value) { $Value.Trim() } else { '' }
    if (-not $v -or $v.Length -gt 400) { return $false }
    $old  = if ($Settings.History.Contains($Field)) { @($Settings.History[$Field]) } else { @() }
    $list = @($v) + @($old | Where-Object { $_ -and -not [string]::Equals($_, $v, [System.StringComparison]::OrdinalIgnoreCase) })
    $Settings.History[$Field] = @($list | Select-Object -First $Max)
    return $true
}

function Get-GLHistory {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Field)
    if ($Settings.History.Contains($Field)) { return , @($Settings.History[$Field]) }
    return , @()
}

# ============================================================================
#  THEMES
#
#  Every colour in the window is a named brush. A theme is just values for those
#  names, so switching theme is instant and touches no control directly. The test
#  suite checks that every theme defines every brush the window uses.
# ============================================================================
$script:Themes = [ordered]@{
    Light = [ordered]@{
        WindowBg = '#F4F6FA'; Surface = '#FFFFFF'; SurfaceAlt = '#F8FAFC'; Header = '#F1F4F8'
        Border = '#E2E8F0'; BorderStrong = '#CBD5E1'; Ink = '#0F172A'; InkMuted = '#64748B'; InkFaint = '#94A3B8'
        Accent = '#2563EB'; AccentHover = '#1D4ED8'; AccentInk = '#FFFFFF'; AccentSoft = '#DBEAFE'
        Danger = '#DC2626'; DangerSoft = '#FEE2E2'; Hover = '#F1F5F9'; Selection = '#DBEAFE'; SelectionInk = '#0F172A'
        InputBg = '#FFFFFF'; LogBg = '#FFFFFF'; LogInk = '#334155'; Shadow = '#1A0F172A'; Warn = '#B45309'; Good = '#15803D'
        TileOk = '#15803D'; TileWarn = '#B45309'; TileDown = '#B91C1C'; TileIdle = '#64748B'; TileVnet = '#1D4ED8'; TileInk = '#FFFFFF'; TileBadge = '#40000000'
    }
    Dark = [ordered]@{
        WindowBg = '#0E1117'; Surface = '#161B22'; SurfaceAlt = '#1B2129'; Header = '#1F2630'
        Border = '#2A313C'; BorderStrong = '#3A4250'; Ink = '#E6EDF3'; InkMuted = '#9AA4B2'; InkFaint = '#6E7681'
        Accent = '#3B82F6'; AccentHover = '#60A5FA'; AccentInk = '#FFFFFF'; AccentSoft = '#1E3A5F'
        Danger = '#F87171'; DangerSoft = '#3B1D1D'; Hover = '#222A35'; Selection = '#1E3A5F'; SelectionInk = '#E6EDF3'
        InputBg = '#0D1117'; LogBg = '#0D1117'; LogInk = '#C9D1D9'; Shadow = '#66000000'; Warn = '#FBBF24'; Good = '#4ADE80'
        TileOk = '#166534'; TileWarn = '#92400E'; TileDown = '#991B1B'; TileIdle = '#334155'; TileVnet = '#1E40AF'; TileInk = '#F8FAFC'; TileBadge = '#40000000'
    }
    Midnight = [ordered]@{
        WindowBg = '#0B1020'; Surface = '#111933'; SurfaceAlt = '#152040'; Header = '#18244A'
        Border = '#22305C'; BorderStrong = '#2E3F75'; Ink = '#E2E8FF'; InkMuted = '#94A3D4'; InkFaint = '#6B78A8'
        Accent = '#8B5CF6'; AccentHover = '#A78BFA'; AccentInk = '#FFFFFF'; AccentSoft = '#2E2560'
        Danger = '#FB7185'; DangerSoft = '#3D1B2E'; Hover = '#1A2650'; Selection = '#2E2560'; SelectionInk = '#E2E8FF'
        InputBg = '#0B1328'; LogBg = '#0B1328'; LogInk = '#C7D2FE'; Shadow = '#66000000'; Warn = '#FBBF24'; Good = '#34D399'
        TileOk = '#047857'; TileWarn = '#B45309'; TileDown = '#BE123C'; TileIdle = '#2E3F75'; TileVnet = '#6D28D9'; TileInk = '#FFFFFF'; TileBadge = '#40000000'
    }
    Contrast = [ordered]@{
        WindowBg = '#000000'; Surface = '#000000'; SurfaceAlt = '#0A0A0A'; Header = '#000000'
        Border = '#FFFFFF'; BorderStrong = '#FFFFFF'; Ink = '#FFFFFF'; InkMuted = '#FFFF00'; InkFaint = '#C0C0C0'
        Accent = '#00FFFF'; AccentHover = '#FFFF00'; AccentInk = '#000000'; AccentSoft = '#003333'
        Danger = '#FF6060'; DangerSoft = '#330000'; Hover = '#1A1A1A'; Selection = '#0000FF'; SelectionInk = '#FFFFFF'
        InputBg = '#000000'; LogBg = '#000000'; LogInk = '#FFFFFF'; Shadow = '#00000000'; Warn = '#FFFF00'; Good = '#00FF00'
        TileOk = '#006400'; TileWarn = '#8B6B00'; TileDown = '#B00000'; TileIdle = '#333333'; TileVnet = '#00008B'; TileInk = '#FFFFFF'; TileBadge = '#80000000'
    }
}

function ConvertTo-GLColorValue {
    # '#RRGGBB' or '#AARRGGBB' -> @(A, R, G, B); throws on anything else.
    param([string]$Hex)
    if ($Hex -notmatch '^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$') { throw "Not a colour: '$Hex'" }
    $h = $Hex.Substring(1)
    if ($h.Length -eq 6) { $h = 'FF' + $h }
    return , @(0, 2, 4, 6 | ForEach-Object { [Convert]::ToByte($h.Substring($_, 2), 16) })
}

# ============================================================================
#  ACTIVITY LOG AND CHANGE RECORD
#
#  Two records, both in the log folder (%LOCALAPPDATA%\GatewayLens\logs, or
#  -LogFolder):
#    gatewaylens-<date>-<user>.log    everything the log panel shows, one file a
#                                     day, kept for 30 days
#    changes-<month>-<user>.csv       one row for every change attempted - kept,
#                                     never pruned
#  File names carry the user, so several people can share one folder (a team
#  share) without ever writing to the same file.
#  Each change is written the moment it happens, from the background job, so a
#  run that is interrupted still leaves a complete record of what it did.
#  Passwords are never written anywhere.
# ============================================================================

$script:ChangeColumns = @('TimeUtc', 'Time', 'User', 'Tenant', 'Action', 'Result', 'TargetType', 'Target', 'TargetId',
                          'Gateway', 'GatewayId', 'Principal', 'PrincipalId', 'PrincipalType', 'Role', 'Details',
                          'Message', 'RunId', 'App')

function Get-GLSafeName([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'unknown' }
    $bad = [System.IO.Path]::GetInvalidFileNameChars() + [char[]]'\/:*?"<>| '
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Text.Trim().ToCharArray()) { [void]$sb.Append($(if ($bad -contains $ch) { '_' } else { $ch })) }
    return $sb.ToString().ToLowerInvariant()
}

function Get-GLLogPath {
    param([Parameter(Mandatory)][string]$Folder, [string]$User, [datetime]$Date = (Get-Date))
    return (Join-Path $Folder ('gatewaylens-{0:yyyy-MM-dd}-{1}.log' -f $Date, (Get-GLSafeName $User)))
}

function Get-GLChangePath {
    param([Parameter(Mandatory)][string]$Folder, [string]$User, [datetime]$Date = (Get-Date))
    return (Join-Path $Folder ('changes-{0:yyyy-MM}-{1}.csv' -f $Date, (Get-GLSafeName $User)))
}

function Write-GLLogFile {
    # One line per entry; continuation lines of a multi-line entry are indented.
    param([Parameter(Mandatory)][string]$Path, [string]$Level = 'INFO', [string]$Text)
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $stamp = '{0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date)
        $lines = @($Text -split '\r?\n')
        $body  = "$stamp  {0,-5}  {1}" -f $Level, $lines[0]
        if ($lines.Count -gt 1) { $body += [Environment]::NewLine + (($lines[1..($lines.Count - 1)] | ForEach-Object { (' ' * 28) + $_ }) -join [Environment]::NewLine) }
        [System.IO.File]::AppendAllText($Path, $body + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch { return $false }
}

function Remove-GLOldLogs {
    # Daily logs older than $Days, for this user only. Change records are never removed.
    param([Parameter(Mandatory)][string]$Folder, [string]$User, [int]$Days = 30)
    if (-not (Test-Path -LiteralPath $Folder)) { return 0 }
    $cut = (Get-Date).Date.AddDays(-$Days)
    $who = [regex]::Escape((Get-GLSafeName $User))
    $n = 0
    foreach ($f in Get-ChildItem -LiteralPath $Folder -Filter 'gatewaylens-*.log' -File) {
        $m = [regex]::Match($f.Name, "^gatewaylens-(\d{4}-\d{2}-\d{2})-$who\.log$")
        if (-not $m.Success) { continue }
        $d = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        if ($d -lt $cut) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++ } catch { } }
    }
    return $n
}

function New-GLAudit {
    # What every change row shares within one run.
    param([Parameter(Mandatory)][string]$Folder, [string]$User, [string]$Tenant, [string]$Version)
    return @{ Folder = $Folder; User = $User; Tenant = $Tenant; Version = $Version; RunId = ([guid]::NewGuid().ToString('N').Substring(0, 8)) }
}

function Write-GLChange {
    <#
        One row in this month's change record. Safe to call from several background
        jobs at once: a named mutex lets one writer in at a time. A new file starts
        with a UTF-8 byte order mark, so Excel shows names with accents correctly.
        Does nothing when $Audit is $null.
    #>
    param(
        $Audit,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][ValidateSet('Done', 'Failed', 'NoChange', 'Skipped')][string]$Result,
        [string]$TargetType, [string]$Target, [string]$TargetId, [string]$Gateway, [string]$GatewayId,
        [string]$Principal, [string]$PrincipalId, [string]$PrincipalType, [string]$Role,
        [string]$Details, [string]$Message,
        [datetime]$When
    )
    if (-not $Audit) { return }
    $now = if ($PSBoundParameters.ContainsKey('When')) { $When } else { Get-Date }
    $row = [ordered]@{
        TimeUtc = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); Time = $now.ToString('yyyy-MM-dd HH:mm:ss')
        User = $Audit.User; Tenant = $Audit.Tenant; Action = $Action; Result = $Result
        TargetType = $TargetType; Target = $Target; TargetId = $TargetId; Gateway = $Gateway; GatewayId = $GatewayId
        Principal = $Principal; PrincipalId = $PrincipalId; PrincipalType = $PrincipalType; Role = $Role
        Details = $Details; Message = $Message; RunId = $Audit.RunId; App = $Audit.Version
    }
    $csv  = @([pscustomobject]$row | ConvertTo-Csv -NoTypeInformation)
    $path = Get-GLChangePath -Folder $Audit.Folder -User $Audit.User -Date $now
    $mtx  = [System.Threading.Mutex]::new($false, 'GatewayLens-change-record')
    $held = $false
    try {
        try { $held = $mtx.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not (Test-Path -LiteralPath $Audit.Folder)) { $null = New-Item -ItemType Directory -Path $Audit.Folder -Force }
        # new - or created empty by Test-GLChangeRecord - gets the BOM and the header
        if (-not (Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -eq 0) {
            [System.IO.File]::WriteAllText($path, $csv[0] + "`r`n", [System.Text.UTF8Encoding]::new($true))
        }
        [System.IO.File]::AppendAllText($path, $csv[1] + "`r`n", [System.Text.UTF8Encoding]::new($false))
    }
    finally {
        if ($held) { $mtx.ReleaseMutex() }
        $mtx.Dispose()
    }
}

function Test-GLChangeRecord {
    # Can this month's change record be written? Asked before every bulk run.
    param([Parameter(Mandatory)]$Audit)
    try {
        if (-not (Test-Path -LiteralPath $Audit.Folder)) { $null = New-Item -ItemType Directory -Path $Audit.Folder -Force -ErrorAction Stop }
        $path = Get-GLChangePath -Folder $Audit.Folder -User $Audit.User
        $fs = [System.IO.File]::Open($path, 'OpenOrCreate', 'Write', 'ReadWrite')
        $fs.Dispose()
        return $null
    }
    catch { return $_.Exception.Message }
}

function Read-GLChanges {
    # Every change record in the folder - all users - newest first.
    param([Parameter(Mandatory)][string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder)) { return , @() }
    $rows = foreach ($f in Get-ChildItem -LiteralPath $Folder -Filter 'changes-*.csv' -File) {
        try { Import-Csv -LiteralPath $f.FullName } catch { }
    }
    $out = foreach ($r in $rows) {
        $when = [datetime]::MinValue
        if ($r.TimeUtc) {
            try {
                $when = [datetime]::ParseExact($r.TimeUtc, 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal).ToLocalTime()
            } catch { }
        }
        $r | Add-Member -NotePropertyName When -NotePropertyValue $when -Force -PassThru
    }
    return , @($out | Sort-Object When -Descending)
}

# ============================================================================
#  DEMO MODE
#
#  -Demo runs the real application against Contoso, a fictional company. Only the
#  network layer is replaced: Invoke-GLRequest and Invoke-GLParallelGet answer
#  from an in-memory store instead of Microsoft, so everything above them - bulk
#  operations, encryption, the change record, the window - is the same code as in
#  real use. Nothing leaves the computer, and nothing is kept once it closes,
#  except the demo's own change record and log, in a separate folder.
#
#  The store is kept in process-wide data, so the background workers see the same
#  Contoso as the window. Each on-premises gateway has a real RSA key pair: the
#  demo decrypts the credentials it is sent, exactly as a gateway would.
# ============================================================================

function Get-GLDemoStore { return [System.AppDomain]::CurrentDomain.GetData('GatewayLens.Demo') }

function New-GLDemoId([string]$Seed) {
    # The same seed always gives the same id - stable across runs, and no id is
    # ever written into this file.
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try { $b = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("gatewaylens-demo|$Seed")) } finally { $md5.Dispose() }
    return ([guid]::new($b)).ToString()
}

function New-GLDemoStore {
    $s = [hashtable]::Synchronized(@{})
    $s.Me = 'demo.user@contoso.com'

    # ---- people ----
    $people = @(
        @('demo.user', 'Demo User'), @('jane.doe', 'Jane Doe'), @('joe.smith', 'Joe Smith'),
        @('ana.novak', 'Ana Novak'), @('raj.patel', 'Raj Patel'), @('alex.admin', 'Alex Admin')
    )
    $s.Users = @(foreach ($p in $people) {
        [pscustomobject]@{ id = New-GLDemoId "user|$($p[0])"; displayName = $p[1]; userPrincipalName = "$($p[0])@contoso.com"; mail = "$($p[0])@contoso.com" }
    })
    $s.Groups = @(
        [pscustomobject]@{ id = New-GLDemoId 'group|bi-admins';   displayName = 'BI Admins';         mail = 'bi-admins@contoso.com' }
        [pscustomobject]@{ id = New-GLDemoId 'group|finance';     displayName = 'Finance Analysts';  mail = 'finance-analysts@contoso.com' }
        [pscustomobject]@{ id = New-GLDemoId 'group|builders';    displayName = 'Report Builders';   mail = $null }
    )
    $s.Sps = @(
        [pscustomobject]@{ id = New-GLDemoId 'sp|reporting'; displayName = 'Contoso Reporting App'; appId = New-GLDemoId 'app|reporting' }
        [pscustomobject]@{ id = New-GLDemoId 'sp|pipelines'; displayName = 'Fabric Pipelines';      appId = New-GLDemoId 'app|pipelines' }
    )
    # someone who left: their account is deleted, Graph no longer knows the id,
    # and the portal leaves them out - but they still have access
    $s.Deleted = @(
        [pscustomobject]@{ id = New-GLDemoId 'user|tom.wright'; displayName = 'Tom Wright'; mail = 'tom.wright@contoso.com'; DeletedOn = (Get-Date).Date.AddDays(-12) }
        [pscustomobject]@{ id = New-GLDemoId 'user|old.admin'; displayName = ''; mail = ''; DeletedOn = $null }    # long gone - not even in the recycle bin
    )

    # ---- gateways: one of every state ----
    $s.Gateways = [System.Collections.Generic.List[object]]::new()
    $s.Members  = @{}
    $s.Live     = @{}
    $s.Rsa      = @{}
    $gw = @(
        @{ Key = 'prod';    Name = 'Contoso Prod Cluster';      Lb = 'DistributeEvenly'; Members = @(@('CTSGW-PRD01', '3000.290.10', 'Live'), @('CTSGW-PRD02', '3000.290.10', 'Live'), @('CTSGW-PRD03', '3000.290.10', 'Live')) }
        @{ Key = 'finance'; Name = 'Contoso Finance Cluster';   Lb = 'Failover';         Members = @(@('CTSGW-FIN01', '3000.290.10', 'Live'), @('CTSGW-FIN02', '3000.282.5', 'Offline')) }
        @{ Key = 'legacy';  Name = 'Legacy Warehouse Gateway';  Lb = 'Failover';         Members = @(, @('LEGGW-01', '3000.246.5', 'Offline')) }
        @{ Key = 'test';    Name = 'Contoso Test Cluster';      Lb = 'Failover';         Members = @(@('CTSGW-TST01', '3000.286.3', 'Live'), @('CTSGW-TST02', '3000.286.3', 'Timeout')) }
    )
    foreach ($g in $gw) {
        $id  = New-GLDemoId "gateway|$($g.Key)"
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $pub = $rsa.ExportParameters($false)
        $s.Rsa[$id] = $rsa
        $s.Gateways.Add([pscustomobject]@{
            id = $id; displayName = $g.Name; type = 'OnPremises'
            publicKey = [pscustomobject]@{ exponent = [Convert]::ToBase64String($pub.Exponent); modulus = [Convert]::ToBase64String($pub.Modulus) }
            version = $g.Members[0][1]; numberOfMemberGateways = $g.Members.Count; loadBalancingSetting = $g.Lb
            allowCloudConnectionRefresh = $true; allowCustomConnectors = ($g.Key -ne 'legacy')
        })
        $s.Members[$id] = [System.Collections.Generic.List[object]]::new()
        $i = 0
        foreach ($m in $g.Members) {
            $i++
            $mid = New-GLDemoId "member|$($g.Key)|$i"
            $s.Members[$id].Add([pscustomobject]@{ id = $mid; displayName = $m[0]; version = $m[1]; enabled = $true; publicKey = $null })
            $s.Live[$mid] = @{ Machine = $m[0]; Status = $m[2] }
        }
    }
    $s.Gateways.Add([pscustomobject]@{ id = New-GLDemoId 'gateway|personal'; displayName = 'Jane Doe (personal mode)'; type = 'OnPremisesPersonal'; version = '3000.290.10' })
    $s.Gateways.Add([pscustomobject]@{ id = New-GLDemoId 'gateway|vnet'; displayName = 'Analytics VNet Gateway'; type = 'VirtualNetwork'
        capacityId = New-GLDemoId 'capacity|f64'; inactivityMinutesBeforeSleep = 30; numberOfMemberGateways = 2
        virtualNetworkAzureResource = [pscustomobject]@{ subscriptionId = New-GLDemoId 'sub'; resourceGroupName = 'rg-analytics'; virtualNetworkName = 'vnet-analytics'; subnetName = 'snet-gateway' } })
    # The portal's cluster list includes VNet gateways too. Asking one for its status
    # starts it if it is asleep - counted here, so the tests can prove it is not done.
    $s.VnetMembers = @(1, 2 | ForEach-Object { [pscustomobject]@{ id = New-GLDemoId "member|vnet|$_"; displayName = "vnet-node-$_"; version = '3000.250.5'; enabled = $true } })
    $s.VnetWoken   = 0

    # ---- connections ----
    $gid = @{}; foreach ($k in 'prod', 'finance', 'legacy', 'test', 'vnet') { $gid[$k] = New-GLDemoId "gateway|$k" }
    #        name                        gateway   type               path                                              credential  account
    # each row starts with a comma: without it @( ) would flatten the rows into loose strings
    $defs = @(
        ,@('Sales DW',                    'prod',    'SQL',             'sqlprd01.contoso.local;SalesDW',                 'Windows',  'CONTOSO\svc_sales')
        ,@('Sales DW (old copy)',         'prod',    'SQL',             'sqlprd01.contoso.local;SalesDW',                 'Windows',  'CONTOSO\svc_sales')
        ,@('Sales Staging',               'prod',    'SQL',             'sqlprd01.contoso.local;SalesStage',              'Windows',  'CONTOSO\svc_sales')
        ,@('Customer 360',                'prod',    'SQL',             'sqlprd02.contoso.local;Customer360',             'Windows',  'CONTOSO\svc_crm')
        ,@('Product Catalog',             'prod',    'SQL',             'sqlprd02.contoso.local;Products',                'Basic',    'catalog_reader')
        ,@('Supply Chain Oracle',         'prod',    'Oracle',          'ora-scm01.contoso.local:1521/SCMPRD',            'Basic',    'SCM_READER')
        ,@('HR Core',                     'prod',    'SQL',             'sqlhr01.contoso.local;HRCore',                   'Windows',  'CONTOSO\svc_hr')
        ,@('Marketing Files',             'prod',    'File',            '\\files01.contoso.local\marketing\reports',      'Windows',  'CONTOSO\svc_files')
        ,@('Intranet SharePoint',         'prod',    'SharePoint',      'https://intranet.contoso.local/sites/bi',        'Windows',  'CONTOSO\svc_spo')
        ,@('Logistics Postgres',          'prod',    'PostgreSql',      'pg-log01.contoso.local:5432;logistics',          'Basic',    'log_reader')
        ,@('Warehouse Cube',              'prod',    'AnalysisServices','ssas01.contoso.local;Inventory',                 'Windows',  'CONTOSO\svc_ssas')
        ,@('Finance GL',                  'finance', 'SQL',             'sqlfin01.contoso.local;GeneralLedger',           'Windows',  'CONTOSO\svc_fin')
        ,@('Finance Budget',              'finance', 'SQL',             'sqlfin01.contoso.local;Budget',                  'Windows',  'CONTOSO\svc_fin')
        ,@('Treasury Oracle',             'finance', 'Oracle',          'ora-trs01.contoso.local:1521/TRSPRD',            'Basic',    'TRS_READ')
        ,@('AP Archive',                  'finance', 'Folder',          '\\fin-files.contoso.local\ap\archive',           'Windows',  'CONTOSO\svc_fin')
        ,@('Legacy Orders',               'legacy',  'SQL',             'sqlold01.contoso.local;Orders',                  'Windows',  'CONTOSO\svc_legacy')
        ,@('Legacy Inventory',            'legacy',  'Odbc',            'dsn=LegacyInventory',                            'Basic',    'inv_read')
        ,@('Sales DW (test)',             'test',    'SQL',             'sqltst01.contoso.local;SalesDW',                 'Windows',  'CONTOSO\svc_test')
        ,@('HR Core (test)',              'test',    'SQL',             'sqltst01.contoso.local;HRCore',                  'Windows',  'CONTOSO\svc_test')
        ,@('Web API Sandbox',             'test',    'Web',             'https://api-test.contoso.local/v1',              'Anonymous','')
        ,@('Analytics SQL',               'vnet',    'SQL',             'sqlmi-analytics.contoso.local;Analytics',        'Basic',    'analytics_reader')
        ,@('Snowflake Analytics',         '',        'Snowflake',       'contoso.snowflakecomputing.com;ANALYTICS_WH',    'Basic',    'SF_REPORTING')
        ,@('Azure SQL Sales',             '',        'SQL',             'contoso-sales.database.windows.net;sales',       'OAuth2',   '')
        ,@('Dataverse CRM',               '',        'CommonDataService','https://contoso.crm.dynamics.com',              'OAuth2',   '')
        ,@('Salesforce',                  '',        'Salesforce',      'https://login.salesforce.com',                   'OAuth2',   '')
        ,@('Exchange Rates API',          '',        'Web',             'https://api.exchangerates.example/latest',       'Anonymous','')
        ,@('Databricks Lakehouse',        '',        'Databricks',      'adb-1234.azuredatabricks.net;/sql/1.0/warehouses/a1', 'Key',  '')
    )
    $s.Connections = [System.Collections.Generic.List[object]]::new()
    $s.Accounts    = @{}
    $s.WebhookPosts = [System.Collections.Generic.List[object]]::new()   # alerts the demo "sent" - nothing leaves
    $iso = { param($d) if ($d) { $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null } }
    $now = (Get-Date).Date.AddHours(8)
    $n   = 0
    foreach ($d in $defs) {
        $n++
        $made = $now.AddDays(-(120 + 9 * $n))
        $used = if ($n % 9 -eq 4) { $null }                          # defined, never used
                elseif ($n % 7 -eq 3) { $now.AddDays(-(60 + 5 * $n)) }   # idle for months
                else { $now.AddHours(-$n) }
        $cid  = New-GLDemoId "connection|$($d[0])"
        $conn = if ($d[1] -eq 'vnet') { 'VirtualNetworkGateway' } elseif ($d[1]) { 'OnPremisesGateway' } else { 'ShareableCloud' }
        $s.Connections.Add([pscustomobject]@{
            id = $cid; displayName = $d[0]; connectivityType = $conn; gatewayId = $(if ($d[1]) { $gid[$d[1]] } else { $null })
            connectionDetails = [pscustomobject]@{ type = $d[2]; path = $d[3] }
            privacyLevel = $(if ($d[0] -like 'HR*' -or $d[0] -like 'Finance*') { 'Private' } else { 'Organizational' })
            credentialDetails = [pscustomobject]@{ credentialType = $d[4]; singleSignOnType = 'None'
                connectionEncryption = $(if ($d[2] -in 'SQL', 'PostgreSql') { 'Encrypted' } elseif ($d[2] -eq 'Oracle') { 'Any' } else { 'NotEncrypted' })
                skipTestConnection = ($d[0] -eq 'Web API Sandbox') }
            connectionRecency = [pscustomobject]@{ createdDateTime = (& $iso $made); lastBoundDateTime = (& $iso $made.AddDays(2))
                lastCredentialUsedDateTime = (& $iso $used) }
        })
        if ($d[5]) { $s.Accounts[$cid] = $d[5] }
    }
    $cn = @{}; foreach ($c in $s.Connections) { $cn[$c.displayName] = $c.id }

    # connections whose test fails, and why
    $s.StatusFail = @{
        $cn['HR Core']          = @{ Code = 'DM_GWPipeline_Gateway_DataSourceAccessError'; Message = "Login failed for user 'CONTOSO\svc_hr'." }
        $cn['AP Archive']       = @{ Code = 'DM_GWPipeline_Gateway_DataSourceAccessError'; Message = 'The network path was not found.' }
        $cn['Treasury Oracle']  = @{ Code = 'DM_GWPipeline_Gateway_DataSourceAccessError'; Message = 'ORA-28001: the password has expired.' }
    }

    # ---- who has access ----
    $s.Roles = @{}
    $me = $s.Users[0]; $jane = $s.Users[1]; $joe = $s.Users[2]; $ana = $s.Users[3]
    $admins = $s.Groups[0]; $fin = $s.Groups[1]; $app = $s.Sps[0]
    foreach ($g in $s.Gateways | Where-Object type -eq 'OnPremises') {
        $null = Add-GLDemoRole $s "gateways/$($g.id)" $me 'Admin'
        $null = Add-GLDemoRole $s "gateways/$($g.id)" $admins 'Admin'
        if ($g.displayName -like '*Prod*') { $null = Add-GLDemoRole $s "gateways/$($g.id)" $jane 'ConnectionCreator' }
    }
    foreach ($c in $s.Connections) {
        $null = Add-GLDemoRole $s "connections/$($c.id)" $me 'Owner'
        $null = Add-GLDemoRole $s "connections/$($c.id)" $admins 'Owner'
        if ($c.displayName -like 'Sales*' -or $c.displayName -like 'Customer*') { $null = Add-GLDemoRole $s "connections/$($c.id)" $jane 'User' }
        if ($c.displayName -like 'Finance*' -or $c.displayName -eq 'Treasury Oracle') { $null = Add-GLDemoRole $s "connections/$($c.id)" $fin 'User' }
        if ($c.connectivityType -eq 'ShareableCloud') { $null = Add-GLDemoRole $s "connections/$($c.id)" $app 'User' }
        if ($c.displayName -eq 'Supply Chain Oracle') { $null = Add-GLDemoRole $s "connections/$($c.id)" $ana 'UserWithReshare' }
    }
    # Joe Smith is leaving - his access is the demo's handover story
    $null = Add-GLDemoRole $s "connections/$($cn['Sales DW'])" $joe 'User'
    $null = Add-GLDemoRole $s "connections/$($cn['Sales Staging'])" $joe 'User'
    # Tom Wright left last year - his deleted account still owns two connections
    $tom = $s.Deleted[0]
    $null = Add-GLDemoRole $s "connections/$($cn['AP Archive'])" $tom 'Owner'
    $null = Add-GLDemoRole $s "connections/$($cn['Treasury Oracle'])" $tom 'User'
    # and an admin who left years ago is still an admin of the Prod gateway
    $prodGw = $s.Gateways | Where-Object { $_.displayName -like '*Prod*' } | Select-Object -First 1
    $null = Add-GLDemoRole $s "gateways/$($prodGw.id)" $s.Deleted[1] 'Admin'
    return $s
}

function Get-GLDemoPrincipal($Store, [string]$Id) {
    $u = $Store.Users | Where-Object id -eq $Id | Select-Object -First 1
    if ($u) { return [pscustomobject]@{ id = $u.id; displayName = $u.displayName; type = 'User'; userDetails = [pscustomobject]@{ userPrincipalName = $u.userPrincipalName } } }
    $g = $Store.Groups | Where-Object id -eq $Id | Select-Object -First 1
    if ($g) { return [pscustomobject]@{ id = $g.id; displayName = $g.displayName; type = 'Group'; groupDetails = [pscustomobject]@{ groupType = 'SecurityGroup'; email = $g.mail } } }
    $p = $Store.Sps | Where-Object id -eq $Id | Select-Object -First 1
    if ($p) { return [pscustomobject]@{ id = $p.id; displayName = $p.displayName; type = 'ServicePrincipal'; servicePrincipalDetails = [pscustomobject]@{ aadAppId = $p.appId } } }
    $d = @($Store.Deleted) | Where-Object { $_ -and $_.id -eq $Id } | Select-Object -First 1
    if ($d) { return [pscustomobject]@{ id = $d.id; type = 'User' } }
    return $null
}

function Add-GLDemoRole($Store, [string]$Key, $Who, [string]$Role) {
    if (-not $Store.Roles.ContainsKey($Key)) { $Store.Roles[$Key] = [System.Collections.Generic.List[object]]::new() }
    $p = Get-GLDemoPrincipal $Store $Who.id
    $a = [pscustomobject]@{ id = New-GLDemoId "ra|$Key|$($Who.id)|$Role|$([guid]::NewGuid())"; role = $Role; principal = $p }
    $Store.Roles[$Key].Add($a)
    return $a
}

function Get-GLDemoAddress([string]$Name) {
    # Stand-in DNS: a stable private address for each demo machine. The legacy one
    # is "not in DNS", to show how that looks.
    $n = $Name.Split('.')[0]
    if ($n -like 'LEG*') { throw 'No such host is known.' }
    $h = [Math]::Abs($n.GetHashCode() % 200) + 20
    $k = 0; foreach ($ch in $n.ToCharArray()) { $k = ($k * 31 + [int]$ch) % 250 }
    return @([System.Net.IPAddress]::Parse("10.20.$h.$($k + 2)"))
}

function Unprotect-GLDemoCredential($Store, [string]$GatewayId, [string]$Encrypted) {
    # What the gateway does: unwrap the AES and HMAC keys with its private RSA key,
    # check the tag, decrypt. Returns the credential JSON, or throws.
    $rsa = $Store.Rsa[$GatewayId]
    if (-not $rsa) { throw 'unknown gateway key' }
    $encKeys = [Convert]::FromBase64String($Encrypted.Substring(0, 344))
    $cipher  = [Convert]::FromBase64String($Encrypted.Substring(344))
    $keys    = $rsa.Decrypt($encKeys, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    $keyEnc  = [byte[]]$keys[2..33]; $keyMac = [byte[]]$keys[34..97]
    $tag = [byte[]]$cipher[2..33]; $iv = [byte[]]$cipher[34..49]; $ct = [byte[]]$cipher[50..($cipher.Length - 1)]
    $h = [System.Security.Cryptography.HMACSHA256]::new($keyMac)
    try { $want = $h.ComputeHash([byte[]](@(0, 0) + $iv + $ct)) } finally { $h.Dispose() }
    if ([Convert]::ToBase64String($want) -ne [Convert]::ToBase64String($tag)) { throw 'authentication tag does not match' }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try { $aes.Key = $keyEnc; $aes.IV = $iv; $plain = $aes.CreateDecryptor().TransformFinalBlock($ct, 0, $ct.Length) } finally { $aes.Dispose() }
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

function New-GLDemoPbiError([string]$Code, [string]$Message) {
    # The shape Power BI uses: the reason sits under a key literally named "pbi.error"
    return ('{"error":{"code":"' + $Code + '","pbi.error":{"code":"' + $Code + '","parameters":{},"details":[' +
            '{"code":"DM_ErrorDetailNameCode_UnderlyingErrorCode","detail":{"type":1,"value":"-2146232060"}},' +
            '{"code":"DM_ErrorDetailNameCode_UnderlyingErrorMessage","detail":{"type":1,"value":' + ($Message | ConvertTo-Json) + '}}]}}}') | ConvertFrom-Json
}

function New-GLDemoReply([int]$Status, $Body) { return [pscustomobject]@{ Status = $Status; Body = $Body } }

function New-GLDemoFabricError([int]$Status, [string]$Code, [string]$Message) {
    return (New-GLDemoReply $Status ([pscustomobject]@{ requestId = 'demo'; errorCode = $Code; message = $Message }))
}

function Invoke-GLDemoHttp {
    <#
        Answers one request from the demo store, the way the real API would: the
        same paths, the same shapes, the same status codes. Returns Status and Body;
        Status 0 means "no answer" (a member that does not respond).
    #>
    param([string]$Method = 'GET', [Parameter(Mandatory)][string]$Uri, $Body, [switch]$NoDelay)
    $s = Get-GLDemoStore
    # a little delay, so the busy indicators show - skipped when the store says Fast (tests)
    if (-not $NoDelay -and -not $s.Fast) { Start-Sleep -Milliseconds (Get-Random -Minimum 80 -Maximum 320) }
    $u = [uri]$Uri
    $path = [uri]::UnescapeDataString($u.AbsolutePath).TrimEnd('/')
    $query = [uri]::UnescapeDataString($u.Query.TrimStart('?'))
    $M = $Method.ToUpperInvariant()

    [System.Threading.Monitor]::Enter($s.SyncRoot)
    try {
        switch -Regex ($u.Host) {
            # ------------------------------------------------------------- Fabric
            'api\.fabric\.microsoft\.com' {
                if ($M -eq 'GET' -and $path -match '^/v1/gateways$') { return New-GLDemoReply 200 ([pscustomobject]@{ value = @($s.Gateways) }) }
                if ($M -eq 'GET' -and $path -match '^/v1/gateways/([^/]+)/members$') {
                    return New-GLDemoReply 200 ([pscustomobject]@{ value = @($s.Members[$Matches[1]]) })
                }
                if ($M -eq 'PATCH' -and $path -match '^/v1/gateways/([^/]+)/members/([^/]+)$') {
                    $mem = @($s.Members[$Matches[1]]) | Where-Object id -eq $Matches[2] | Select-Object -First 1
                    if (-not $mem) { return New-GLDemoFabricError 404 'EntityNotFound' 'The member was not found.' }
                    if ($null -ne $Body.enabled) { $mem.enabled = [bool]$Body.enabled }
                    return New-GLDemoReply 200 $mem
                }
                if ($M -eq 'GET' -and $path -match '^/v1/connections$') { return New-GLDemoReply 200 ([pscustomobject]@{ value = @($s.Connections) }) }
                if ($M -eq 'DELETE' -and $path -match '^/v1/connections/([^/]+)$') {
                    $c = $s.Connections | Where-Object id -eq $Matches[1] | Select-Object -First 1
                    if (-not $c) { return New-GLDemoFabricError 404 'EntityNotFound' 'The connection was not found.' }
                    [void]$s.Connections.Remove($c); $s.Roles.Remove("connections/$($c.id)")
                    return New-GLDemoReply 200 $null
                }
                if ($path -match '^/v1/(gateways|connections)/([^/]+)/roleAssignments(?:/([^/]+))?$') {
                    $key = "$($Matches[1])/$($Matches[2])"; $rid = $Matches[3]
                    if (-not $s.Roles.ContainsKey($key)) { $s.Roles[$key] = [System.Collections.Generic.List[object]]::new() }
                    $list = $s.Roles[$key]
                    # as a real tenant answers: each principal's id and type, no name - names come from Graph
                    $bare = { param($A) [pscustomobject]@{ id = $A.id; role = $A.role; principal = [pscustomobject]@{ id = $A.principal.id; type = $A.principal.type } } }
                    if ($M -eq 'GET') { return New-GLDemoReply 200 ([pscustomobject]@{ value = @($list | ForEach-Object { & $bare $_ }) }) }
                    if ($M -eq 'POST') {
                        $p = Get-GLDemoPrincipal $s ([string]$Body.principal.id)
                        if (-not $p) { return New-GLDemoFabricError 400 'PrincipalNotFound' 'The principal could not be found in the directory.' }
                        if ($list | Where-Object { $_.principal.id -eq $p.id }) { return New-GLDemoFabricError 409 'PrincipalAlreadyHasRole' 'The principal already has a role on this item.' }
                        return [pscustomobject]@{ Status = 201; Body = (& $bare (Add-GLDemoRole $s $key $p ([string]$Body.role))) }
                    }
                    if ($M -eq 'PATCH') {
                        $a = $list | Where-Object id -eq $rid | Select-Object -First 1
                        if (-not $a) { return New-GLDemoFabricError 404 'EntityNotFound' 'The role assignment was not found.' }
                        if ($a.role -eq 'Owner' -and [string]$Body.role -ne 'Owner' -and @($list | Where-Object role -eq 'Owner').Count -eq 1) {
                            return New-GLDemoFabricError 400 'LastOwnerCannotBeRemoved' 'The last owner cannot be removed.'
                        }
                        $a.role = [string]$Body.role
                        return New-GLDemoReply 200 $a
                    }
                    if ($M -eq 'DELETE') {
                        $a = $list | Where-Object id -eq $rid | Select-Object -First 1
                        if (-not $a) { return New-GLDemoFabricError 404 'EntityNotFound' 'The role assignment was not found.' }
                        if ($a.role -eq 'Owner' -and @($list | Where-Object role -eq 'Owner').Count -eq 1) {
                            return New-GLDemoFabricError 400 'LastOwnerCannotBeRemoved' 'The last owner cannot be removed.'
                        }
                        [void]$list.Remove($a)
                        return New-GLDemoReply 200 $null
                    }
                }
            }
            # ----------------------------------------------------------- Power BI
            'api\.powerbi\.com' {
                if ($M -eq 'GET' -and $path -match '^/v2\.0/myorg/me/gatewayClusters$') {
                    $v = foreach ($g in $s.Gateways | Where-Object type -eq 'OnPremises') {
                        [pscustomobject]@{ id = $g.id; name = $g.displayName; memberGateways = @(foreach ($m in $s.Members[$g.id]) {
                            [pscustomobject]@{ id = $m.id; name = $m.displayName; version = $m.version; enabled = $m.enabled
                                annotation = (@{ gatewayMachine = $s.Live[$m.id].Machine } | ConvertTo-Json -Compress) } }) }
                    }
                    $vn = $s.Gateways | Where-Object type -eq 'VirtualNetwork' | Select-Object -First 1
                    $v = @($v) + @([pscustomobject]@{ id = $vn.id; name = $vn.displayName; memberGateways = @($s.VnetMembers | ForEach-Object {
                        [pscustomobject]@{ id = $_.id; name = $_.displayName; version = $_.version; enabled = $_.enabled } }) })
                    return New-GLDemoReply 200 ([pscustomobject]@{ value = @($v) })
                }
                if ($M -eq 'GET' -and $path -match '^/v2\.0/myorg/me/gatewayClusters/[^/]+/memberGateways/([^/]+)/status$') {
                    if ($s.VnetMembers | Where-Object id -eq $Matches[1]) {
                        $s.VnetWoken++
                        return New-GLDemoReply 200 ([pscustomobject]@{ gatewayStatus = 'Live' })
                    }
                    $st = $s.Live[$Matches[1]].Status
                    if ($st -eq 'Timeout') { return [pscustomobject]@{ Status = 0; Body = $null } }
                    return New-GLDemoReply 200 ([pscustomobject]@{ gatewayStatus = $st })
                }
                if ($M -eq 'GET' -and $path -match '^/v2\.0/myorg/me/gatewayClusterDatasources$') {
                    $v = foreach ($c in $s.Connections | Where-Object connectivityType -eq 'OnPremisesGateway') {
                        $acc = $s.Accounts[$c.id]
                        [pscustomobject]@{
                            id = $c.id; clusterId = $c.gatewayId; datasourceName = $c.displayName; datasourceType = $c.connectionDetails.type
                            credentialDetails = [pscustomobject]@{ credentialType = $c.credentialDetails.credentialType
                                publicCredentialProperties = $(if ($acc) { (@(@{ name = 'username'; value = $acc }) | ConvertTo-Json -Compress -AsArray) } else { $null }) }
                            # a real tenant answers with the object id only - no email, no name
                            users = @(foreach ($a in @($s.Roles["connections/$($c.id)"])) {
                                [pscustomobject]@{ identifier = $a.principal.id
                                                   datasourceAccessRight = $(if ($a.role -eq 'Owner') { 'ReadOverrideEffectiveIdentity' } else { 'Read' }) } })
                        }
                    }
                    return New-GLDemoReply 200 ([pscustomobject]@{ value = @($v) })
                }
                if ($M -eq 'GET' -and $path -match '^/v2\.0/myorg/me/gatewayClusterDatasources/([^/]+)$') {
                    $c = $s.Connections | Where-Object { $_.id -eq $Matches[1] -and $_.connectivityType -eq 'OnPremisesGateway' } | Select-Object -First 1
                    if (-not $c) { return New-GLDemoReply 404 (New-GLDemoPbiError 'DMTS_DatasourceNotFoundError' 'The data source was not found.') }
                    $acc = $s.Accounts[$c.id]
                    $pub = $s.Rsa[$c.gatewayId].ExportParameters($false)
                    $xml = '<?xml version="1.0"?><RSAParameters xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
                           "<Exponent>$([Convert]::ToBase64String($pub.Exponent))</Exponent><Modulus>$([Convert]::ToBase64String($pub.Modulus))</Modulus></RSAParameters>"
                    $keys = [ordered]@{}
                    foreach ($mb in @($s.Members[$c.gatewayId])) { $keys[[string]$mb.id] = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($xml)) }
                    return New-GLDemoReply 200 ([pscustomobject]@{
                        id = $c.id; clusterId = $c.gatewayId; datasourceName = $c.displayName
                        credentialDetails = [pscustomobject]@{ credentialType = $c.credentialDetails.credentialType; privacyLevel = $c.privacyLevel
                            encryptedConnection = $(if ($c.credentialDetails.connectionEncryption -eq 'Encrypted') { 'Encrypted' } else { 'NotEncrypted' })
                            skipTestConnection = [bool]$c.credentialDetails.skipTestConnection; encryptionAlgorithm = 'AES'
                            publicCredentialProperties = $(if ($acc) { (@(@{ name = 'username'; value = $acc }) | ConvertTo-Json -Compress -AsArray) } else { $null }) }
                        memberGatewayPublicKeys = [pscustomobject]$keys })
                }
                if ($path -match '^/v2\.0/myorg/me/gatewayClusters/([^/]+)/datasources/([^/]+)/credentialsV2$') {
                    $gid = $Matches[1]; $cid = $Matches[2]
                    if ($M -ne (Get-GLPortalCredentialMethod)) { return New-GLDemoReply 405 ([pscustomobject]@{ error = [pscustomobject]@{ code = 'MethodNotAllowed'; message = "The requested resource does not support http method '$M'." } }) }
                    $c = $s.Connections | Where-Object { $_.id -eq $cid -and $_.gatewayId -eq $gid } | Select-Object -First 1
                    if (-not $c) { return New-GLDemoReply 404 (New-GLDemoPbiError 'DMTS_DatasourceNotFoundError' 'The data source was not found.') }
                    # like the service: credentials for every member, each one opened by the gateway
                    $given = $Body.credentialDetails
                    $user = $null; $pass = $null; $first = $null
                    foreach ($mb in @($s.Members[$gid])) {
                        $cd = $given[[string]$mb.id]
                        if (-not $cd) { return New-GLDemoReply 400 (New-GLDemoPbiError 'InvalidRequest' "No credentials for gateway member $($mb.id).") }
                        try { $plain = Unprotect-GLDemoCredential $s $gid ([string]$cd.credentials) | ConvertFrom-Json }
                        catch { return New-GLDemoReply 400 (New-GLDemoPbiError 'DM_GWPipeline_Gateway_InvalidConnectionCredentials' "The gateway could not decrypt the credentials: $($_.Exception.Message)") }
                        $user = ($plain.credentialData | Where-Object name -eq 'username').value
                        $pass = ($plain.credentialData | Where-Object { $_.name -in 'password', 'key' }).value
                        $first = $cd
                    }
                    if ($pass -eq 'wrong') { return New-GLDemoReply 400 (New-GLDemoPbiError 'DM_GWPipeline_Gateway_DataSourceAccessError' "Login failed for user '$user'.") }
                    $c.credentialDetails.credentialType = [string]$first.credentialType
                    # the portal's way: the username stays readable
                    if ($user) { $s.Accounts[$c.id] = $user } else { $s.Accounts.Remove($c.id) }
                    if ($first.privacyLevel) { $c.privacyLevel = [string]$first.privacyLevel }
                    $s.StatusFail.Remove($c.id)
                    $s.PortalCredentialCalls = 1 + [int]$s.PortalCredentialCalls
                    return New-GLDemoReply 200 $null
                }
                if ($M -eq 'GET' -and $path -match '^/v1\.0/myorg/gateways$') {
                    return New-GLDemoReply 200 ([pscustomobject]@{ value = @($s.Gateways | Where-Object type -eq 'OnPremises' | ForEach-Object {
                        [pscustomobject]@{ id = $_.id; name = $_.displayName; type = 'Resource'; publicKey = $_.publicKey } }) })
                }
                if ($path -match '^/v1\.0/myorg/gateways/([^/]+)/datasources(?:/([^/]+))?(/status)?$') {
                    $g = $s.Gateways | Where-Object id -eq $Matches[1] | Select-Object -First 1
                    $cid = $Matches[2]; $isStatus = [bool]$Matches[3]
                    if (-not $g) { return New-GLDemoReply 404 ([pscustomobject]@{ error = [pscustomobject]@{ code = 'DMTS_GatewayNotFoundError'; message = 'The gateway was not found.' } }) }
                    $c = if ($cid) { $s.Connections | Where-Object { $_.id -eq $cid -and $_.gatewayId -eq $g.id } | Select-Object -First 1 }
                    if ($M -eq 'GET' -and -not $cid) {
                        return New-GLDemoReply 200 ([pscustomobject]@{ value = @($s.Connections | Where-Object gatewayId -eq $g.id | ForEach-Object {
                            [pscustomobject]@{ id = $_.id; gatewayId = $g.id; datasourceName = $_.displayName; datasourceType = $_.connectionDetails.type; credentialType = $_.credentialDetails.credentialType } }) })
                    }
                    if ($cid -and -not $c) { return New-GLDemoReply 404 ([pscustomobject]@{ error = [pscustomobject]@{ code = 'DMTS_DatasourceNotFoundError'; message = 'The data source was not found.' } }) }
                    if ($M -eq 'GET' -and $isStatus) {
                        $up = @($s.Members[$g.id] | Where-Object { $_.enabled -and $s.Live[$_.id].Status -eq 'Live' }).Count
                        if ($up -eq 0) { return New-GLDemoReply 400 (New-GLDemoPbiError 'DM_GWPipeline_Client_GatewayUnreachable' 'The gateway is either offline or could not be reached.') }
                        $f = $s.StatusFail[$c.id]
                        if ($f) { return New-GLDemoReply 400 (New-GLDemoPbiError $f.Code $f.Message) }
                        return New-GLDemoReply 200 $null
                    }
                    if ($M -eq 'PATCH') {
                        # what a gateway does with credentials: decrypt them, then try them
                        $cd = $Body.credentialDetails
                        try { $plain = Unprotect-GLDemoCredential $s $g.id ([string]$cd.credentials) | ConvertFrom-Json }
                        catch { return New-GLDemoReply 400 (New-GLDemoPbiError 'DM_GWPipeline_Gateway_InvalidConnectionCredentials' "The gateway could not decrypt the credentials: $($_.Exception.Message)") }
                        $user = ($plain.credentialData | Where-Object name -eq 'username').value
                        $pass = ($plain.credentialData | Where-Object { $_.name -in 'password', 'key' }).value
                        if ($pass -eq 'wrong') { return New-GLDemoReply 400 (New-GLDemoPbiError 'DM_GWPipeline_Gateway_DataSourceAccessError' "Login failed for user '$user'.") }
                        $c.credentialDetails.credentialType = [string]$cd.credentialType
                        # like the real service: the documented call keeps only the encrypted
                        # credentials - the readable username, the Account column, is gone
                        $s.Accounts.Remove($c.id)
                        $s.DocumentedCredentialCalls = 1 + [int]$s.DocumentedCredentialCalls
                        if ($cd.privacyLevel) { $c.privacyLevel = [string]$cd.privacyLevel }
                        $s.StatusFail.Remove($c.id)       # good credentials fix a login failure
                        return New-GLDemoReply 200 $null
                    }
                }
            }
            # ------------------------------------- Microsoft's public gateway pages
            # Fictional versions to match Contoso: 3000.290.10 is "the newest", and
            # six monthly releases back to 3000.270 are "supported".
            'www\.microsoft\.com' {
                if ($M -eq 'GET' -and $path -eq '/en-us/download/details.aspx') {
                    $us = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
                    $published = (Get-Date).Date.AddDays(-9).AddHours(17).ToString('M/d/yyyy h:mm:ss tt', $us)
                    return New-GLDemoReply 200 ('<html><body><script>window.__DLCDetails__={"detailsSection_file_version":"3000.290.10",' +
                        '"files":[{"name":"GatewayInstall.exe","version":"3000.290.10","datePublished":"' + $published + '"}]}</script>' +
                        '<h3 class="h6">Version:</h3><p>3000.290.10</p></body></html>')
                }
            }
            'learn\.microsoft\.com' {
                if ($M -eq 'GET' -and $path -eq '/en-us/data-integration/gateway/service-gateway-monthly-updates') {
                    $inv = [System.Globalization.CultureInfo]::InvariantCulture
                    $h = foreach ($i in 0..5) { "<h2>$((Get-Date).AddMonths(-1 - $i).ToString('MMMM yyyy', $inv)) update (3000.$(290 - 4 * $i))</h2>" }
                    return New-GLDemoReply 200 ("<html><body><h1>Currently supported monthly updates</h1>$($h -join '')</body></html>")
                }
            }
            # -------------------------------------------------------------- Graph
            'graph\.microsoft\.com' {
                $notFound = New-GLDemoReply 404 ([pscustomobject]@{ error = [pscustomobject]@{ code = 'Request_ResourceNotFound'; message = 'The object does not exist.' } })
                if ($M -eq 'POST' -and $path -eq '/v1.0/directoryObjects/getByIds') {
                    $found = foreach ($id in @($Body.ids)) {
                        $u = $s.Users | Where-Object id -eq $id | Select-Object -First 1
                        if ($u) { [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = $u.id; displayName = $u.displayName; userPrincipalName = $u.userPrincipalName; mail = $u.mail }; continue }
                        $g = $s.Groups | Where-Object id -eq $id | Select-Object -First 1
                        if ($g) { [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; id = $g.id; displayName = $g.displayName; mail = $g.mail }; continue }
                        $a = $s.Sps | Where-Object id -eq $id | Select-Object -First 1
                        if ($a) { [pscustomobject]@{ '@odata.type' = '#microsoft.graph.servicePrincipal'; id = $a.id; displayName = $a.displayName; appId = $a.appId } }
                    }
                    return New-GLDemoReply 200 ([pscustomobject]@{ value = @($found) })
                }
                if ($M -eq 'POST' -and $path -eq '/v1.0/$batch') {
                    $answers = foreach ($q in @($Body.requests)) {
                        $sub = Invoke-GLDemoHttp -Method ([string]$q.method) -Uri ('https://graph.microsoft.com/v1.0' + [string]$q.url) -Body $null
                        [pscustomobject]@{ id = [string]$q.id; status = [int]$sub.Status; body = $sub.Body }
                    }
                    return New-GLDemoReply 200 ([pscustomobject]@{ responses = @($answers) })
                }
                if ($M -eq 'GET' -and $path -match '^/v1\.0/directory/deletedItems/([^/]+)$') {
                    $d = @($s.Deleted) | Where-Object { $_ -and $_.id -eq $Matches[1] -and $_.DeletedOn } | Select-Object -First 1
                    if (-not $d) { return $notFound }
                    return New-GLDemoReply 200 ([pscustomobject]@{ id = $d.id; displayName = $d.displayName; mail = $d.mail
                        userPrincipalName = ($d.id -replace '-', '') + $d.mail; deletedDateTime = $d.DeletedOn.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') })
                }
                if ($M -eq 'GET' -and $path -match '^/v1\.0/directoryObjects/([^/]+)$') {
                    $p = Get-GLDemoPrincipal $s $Matches[1]
                    if (-not $p -or (@($s.Deleted) | Where-Object { $_ -and $_.id -eq $Matches[1] })) { return $notFound }
                    return New-GLDemoReply 200 ([pscustomobject]@{ id = $p.id; displayName = $p.displayName; userPrincipalName = $p.userDetails.userPrincipalName })
                }
                if ($M -eq 'GET' -and $path -eq '/v1.0/me') {
                    $me = $s.Users | Where-Object userPrincipalName -eq $s.Me | Select-Object -First 1
                    return New-GLDemoReply 200 ([pscustomobject]@{ id = $me.id; userPrincipalName = $me.userPrincipalName })
                }
                if ($M -eq 'GET' -and $path -match '^/v1\.0/users/(.+)$') {
                    $x = $s.Users | Where-Object { $_.userPrincipalName -eq $Matches[1] -or $_.id -eq $Matches[1] } | Select-Object -First 1
                    if ($x) { return New-GLDemoReply 200 $x } else { return $notFound }
                }
                $want = if ($query -match "eq '([^']*)'") { $Matches[1] } else { '' }
                if ($M -eq 'GET' -and $path -eq '/v1.0/users')  { return New-GLDemoReply 200 ([pscustomobject]@{ value = @($s.Users  | Where-Object { $_.mail -eq $want }) }) }
                if ($M -eq 'GET' -and $path -eq '/v1.0/groups') { return New-GLDemoReply 200 ([pscustomobject]@{ value = @($s.Groups | Where-Object { $_.mail -eq $want -or $_.displayName -eq $want }) }) }
                if ($M -eq 'GET' -and $path -eq '/v1.0/servicePrincipals') { return New-GLDemoReply 200 ([pscustomobject]@{ value = @($s.Sps | Where-Object { $_.displayName -eq $want }) }) }
            }
        }
        return New-GLDemoReply 404 ([pscustomobject]@{ error = [pscustomobject]@{ code = 'DemoNotImplemented'; message = "The demo does not answer $M $path." } })
    }
    finally { [System.Threading.Monitor]::Exit($s.SyncRoot) }
}

function Enable-GLDemo {
    [System.AppDomain]::CurrentDomain.SetData('GatewayLens.Demo', (New-GLDemoStore))
    $script:AuthMode    = 'Demo'
    $script:SignedInAs  = 'demo.user@contoso.com'
    $script:TenantShown = 'contoso.example (demo)'
}

function Disable-GLDemo { [System.AppDomain]::CurrentDomain.SetData('GatewayLens.Demo', $null) }

# Everything a background worker needs. The UI thread hands each worker its own
# copy of these through the runspace pool's initial session state.
$script:WorkerFunctions = @(
    'Test-GLGuid', 'ConvertFrom-GLApiError', 'Invoke-GLRequest', 'Get-GLPaged', 'Add-GLStat',
    'Invoke-GLParallelGet', 'Get-GLLiveStatus', 'Get-GLGatewayData', 'Get-GLConnectionData', 'Get-GLRoleAssignments',
    'New-GLRoleAssignmentBody', 'Add-GLRoleAssignment', 'Remove-GLRoleAssignment', 'Set-GLRoleAssignment',
    'Test-GLPrincipalMatch', 'Get-GLHandoverStep', 'Resolve-GLHandoverFrom', 'Invoke-GLAccessHandover',
    'Get-GLPrincipalNames', 'Get-GLPrincipalLabel', 'ConvertTo-GLRoleRows', 'ConvertTo-GLTestOutcome',
    'ConvertTo-GLAccessReportRows', 'Get-GLAccessReport',
    'Resolve-GLPrincipal', 'Test-GLConnection',
    'ConvertTo-GLCredentialJson', 'ConvertTo-GLEncryptedCredential', 'New-GLCredentialDetails',
    'Set-GLConnectionCredential', 'Invoke-GLBulkMembers', 'Set-GLConnectionCredentialPortal', 'Get-GLPortalCredentialMethod',
    'ConvertFrom-GLRsaXmlKey', 'Test-GLPortalWayRefused', 'Get-GLGraphBatch', 'Get-GLMissingPrincipals', 'Get-GLMissingText',
    'Send-GLWebhook',
    'Remove-GLConnection', 'Set-GLMemberEnabled', 'Test-GLConnectionsBulk', 'Get-GLRoleAssignmentsBulk',
    'Get-GLDatasourceDirectory', 'Resolve-GLHostAddress', 'ConvertTo-GLConnectionRows', 'ConvertTo-GLLocalTime',
    'Get-GLGatewayNameMap', 'Add-GLDirectoryInfo', 'Get-GLDirectoryPrincipalIds', 'ConvertTo-GLPeopleLabels', 'Set-GLRowPeople', 'Set-GLReport',
    'Get-GLPrincipalLabel', 'Test-GLGuid', 'ConvertFrom-GLDownloadPage', 'ConvertFrom-GLReleasePage', 'Get-GLGatewayReleases', 'Split-GLList', 'ConvertTo-GLEncryptionSetting',
    'New-GLResult', 'Invoke-GLBulkGrant', 'Invoke-GLBulkRevoke', 'Invoke-GLBulkCredentials',
    'Backup-GLConnections', 'Invoke-GLBulkDelete',
    'Get-GLSafeName', 'Get-GLChangePath', 'Write-GLChange', 'Read-GLChanges',
    'Get-GLDemoStore', 'New-GLDemoId', 'Get-GLDemoPrincipal', 'Add-GLDemoRole', 'Get-GLDemoAddress',
    'Unprotect-GLDemoCredential', 'New-GLDemoPbiError', 'New-GLDemoReply', 'New-GLDemoFabricError', 'Invoke-GLDemoHttp'
)

# ============================================================================
#  SIGN-IN  -  UI thread only. Tokens are fetched here and handed to workers.
#
#  Two ways in, whichever works with nothing more to do:
#    Az.Accounts, when it is installed. Microsoft's Azure PowerShell is already
#    approved in practically every tenant, so no one has to approve GatewayLens.
#    Built-in, when it is not: GatewayLens's own app registration, which each
#    organisation approves once. Nothing has to be installed.
#
#  The built-in way is plain OAuth 2.0 against Microsoft Entra ID.
#  The browser signs the user in - on a company PC usually without a password,
#  because Edge and Chrome pass on the Windows sign-in - and sends a one-time code
#  back to a listener on this computer, which trades it for tokens (authorization
#  code with PKCE, RFC 7636). -DeviceCode signs in on another device (RFC 8628).
#  Tokens and the refresh token live in memory only - never in a file, the log or
#  the change record - so each start signs in again.
# ============================================================================
# The app registration GatewayLens signs in as: a public, multi-tenant client with
# no secret. A client id is not confidential - every sign-in page shows it.
# -ClientId overrides it, for an organisation that registers its own.
$script:BuiltInClientId = ''   # public-client-id

$script:LoginHost   = 'https://login.microsoftonline.com'
$script:TokenScopes = @{
    Fabric  = 'https://api.fabric.microsoft.com/.default'
    PowerBI = 'https://analysis.windows.net/powerbi/api/.default'
    Graph   = 'https://graph.microsoft.com/.default'
}
$script:AuthMode    = $null
$script:SignedInAs  = ''
$script:TenantShown = ''
$script:Auth        = $null
$script:InstallAz   = 'Install-Module Az.Accounts -Scope CurrentUser'

function ConvertFrom-GLToken {
    # Newer Az.Accounts versions hand the token back as a SecureString.
    param($Token)
    if ($Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $Token).Password
    }
    return [string]$Token
}

function Test-GLAzAccounts { return [bool](Get-Module -ListAvailable -Name Az.Accounts) }

function Select-GLSignIn {
    <#
        Which way to sign in: 'Az' or 'Browser'. Auto prefers Az.Accounts, because it
        needs no approval; a -ClientId given on purpose always means the built-in way.
    #>
    param([string]$Requested = 'Auto', [string]$ClientId, [string]$BuiltInId, [bool]$AzAvailable)
    $id = if ($ClientId) { $ClientId.Trim() } else { $BuiltInId }
    if ($ClientId -and -not (Test-GLGuid $id)) {
        throw "-ClientId needs an application (client) id - the one on the app registration's Overview page."
    }
    switch ($Requested) {
        'AzAccounts' {
            if ($AzAvailable) { return 'Az' }
            throw "Az.Accounts is not installed. Install it once with:`n    $($script:InstallAz)"
        }
        'Browser' {
            if (Test-GLGuid $id) { return 'Browser' }
            throw 'This copy of GatewayLens has no app registration to sign in with. Start it with -ClientId and your app''s client id - docs/sign-in.md shows how to get one.'
        }
        default {
            if ($ClientId) { return 'Browser' }
            if ($AzAvailable) { return 'Az' }
            if (Test-GLGuid $id) { return 'Browser' }
            throw "GatewayLens has no way to sign in on this computer. Install Az.Accounts once:`n    $($script:InstallAz)`nor start GatewayLens with -ClientId and your organisation's app registration - docs/sign-in.md explains both."
        }
    }
}

function ConvertTo-GLBase64Url([byte[]]$Bytes) {
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertTo-GLCodeChallenge([string]$Verifier) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (ConvertTo-GLBase64Url $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($Verifier))) }
    finally { $sha.Dispose() }
}

function New-GLPkce {
    # The verifier never leaves this computer until the code is traded for tokens,
    # so a code caught on its way back from the browser is useless to anyone else.
    $v = ConvertTo-GLBase64Url ([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    return [pscustomobject]@{ Verifier = $v; Challenge = (ConvertTo-GLCodeChallenge $v) }
}

function ConvertFrom-GLJwt([string]$Jwt) {
    # The claims only, for the name and tenant shown in the window. The token came
    # straight from Microsoft over HTTPS; the APIs check its signature, not us.
    $parts = ([string]$Jwt).Split('.')
    if ($parts.Count -lt 2) { return $null }
    $b = $parts[1].Replace('-', '+').Replace('_', '/')
    $b += '=' * ((4 - $b.Length % 4) % 4)
    try { return ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) | ConvertFrom-Json -ErrorAction Stop) }
    catch { return $null }
}

function ConvertFrom-GLQueryString([string]$Query) {
    $q = @{}
    foreach ($pair in ([string]$Query).TrimStart('?').Split('&')) {
        if (-not $pair) { continue }
        $kv  = $pair.Split('=', 2)
        $key = [uri]::UnescapeDataString($kv[0].Replace('+', ' '))
        $q[$key] = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } else { '' }
    }
    return $q
}

function New-GLAuthorizeUrl {
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][string]$RedirectUri,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Challenge,
        [string]$LoginHint
    )
    $q = [ordered]@{
        client_id             = $ClientId
        response_type         = 'code'
        redirect_uri          = $RedirectUri
        response_mode         = 'query'
        scope                 = $Scope
        state                 = $State
        code_challenge        = $Challenge
        code_challenge_method = 'S256'
    }
    if ($LoginHint) { $q.login_hint = $LoginHint }
    $pairs = foreach ($k in $q.Keys) { "$k=$([uri]::EscapeDataString([string]$q[$k]))" }
    return "$($script:LoginHost)/$([uri]::EscapeDataString($Tenant))/oauth2/v2.0/authorize?$($pairs -join '&')"
}

function Get-GLSignInHint([string]$Text) {
    # Entra's AADSTS codes, turned into what to do next.
    $t = [string]$Text
    if ($t -match 'AADSTS(65001|90094|90095)\b' -or $t -match '\bconsent_required\b') {
        return "Your organisation has not approved GatewayLens yet. An administrator approves it once for everyone - docs/sign-in.md on the GatewayLens GitHub page shows how. Or, with no approval needed, install Az.Accounts once and start GatewayLens again: $($script:InstallAz)"
    }
    if ($t -match 'AADSTS700016\b') { return 'No app registration has this client id. Check the -ClientId value.' }
    if ($t -match 'AADSTS(50011|500113)\b') { return 'The app registration needs the redirect address http://localhost - see docs/sign-in.md.' }
    if ($t -match 'AADSTS7000218\b') { return 'Device code sign-in needs "Allow public client flows" turned on in the app registration - see docs/sign-in.md.' }
    if ($t -match 'AADSTS(53000|53001|53003)\b') { return 'A sign-in policy in your organisation blocked this. Your IT team can tell you which one.' }
    if ($t -match 'AADSTS50020\b') { return 'This account is not part of that organisation. Start GatewayLens with -TenantId and your organisation''s domain.' }
    if ($t -match 'AADSTS(70008|700082|50173)\b' -or $t -match '\binvalid_grant\b') { return 'The sign-in has expired. Restart GatewayLens to sign in again.' }
    return ''
}

function Format-GLSignInError([string]$Code, [string]$Description) {
    # Entra appends trace and correlation ids on later lines - the first line is the reason.
    $first = (([string]$Description) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    $what  = @($Code, $first) | Where-Object { $_ }
    $msg   = if ($what) { $what -join ': ' } else { 'Microsoft did not say why.' }
    $hint  = Get-GLSignInHint "$Code $Description"
    if ($hint) { $msg += " $hint" }
    return $msg
}

function Invoke-GLTokenEndpoint {
    # A POST to Entra ID. Never throws: device code sign-in has to read "not yet"
    # answers, and callers turn a real failure into a message.
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][hashtable]$Form)
    try {
        $r = Invoke-RestMethod -Method Post -Uri $Uri -Body $Form -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; Body = $r; Error = ''; Description = '' }
    }
    catch {
        $err = ''; $desc = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try {
                $j = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
                if ($j.error) { $err = [string]$j.error; $desc = [string]$j.error_description }
            } catch { }
        }
        return [pscustomobject]@{ Ok = $false; Body = $null; Error = $err; Description = $desc }
    }
}

function Get-GLTokenUri([string]$Tenant, [string]$Path = 'token') {
    return "$($script:LoginHost)/$([uri]::EscapeDataString($Tenant))/oauth2/v2.0/$Path"
}

function Save-GLTokens([string]$For, $Body) {
    $script:Auth.Tokens[$For] = [pscustomobject]@{
        Value     = [string]$Body.access_token
        ExpiresOn = (Get-Date).AddSeconds([int]$Body.expires_in)
    }
    if ($Body.refresh_token) { $script:Auth.RefreshToken = [string]$Body.refresh_token }   # Entra may hand out a new one
}

function Get-GLWindowsUpn {
    # The Windows account's sign-in name, so the browser picks the right account.
    if (-not $IsWindows) { return '' }
    try {
        $u = [string](& whoami.exe /upn 2>$null)
        if ($LASTEXITCODE -eq 0 -and $u.Trim() -match '^[^@\s]+@[^@\s]+$') { return $u.Trim() }
    } catch { }
    return ''
}

function Open-GLBrowser([string]$Url) {
    try {
        if ($IsWindows)   { Start-Process $Url }
        elseif ($IsMacOS) { & open $Url }
        else              { & xdg-open $Url 2>$null }
        return $true
    } catch { return $false }
}

function Start-GLLoopback {
    # Loopback only: nothing outside this computer can reach it, and no firewall
    # prompt appears. A browser may try IPv6 first for "localhost", so listen there too.
    $v4 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $v4.Start()
    $port = ([System.Net.IPEndPoint]$v4.LocalEndpoint).Port
    $listeners = [System.Collections.Generic.List[object]]::new()
    $listeners.Add($v4)
    try {
        $v6 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::IPv6Loopback, $port)
        $v6.Start()
        $listeners.Add($v6)
    } catch { }    # no IPv6 here - IPv4 is enough
    return [pscustomobject]@{ Port = $port; Listeners = $listeners }
}

function Send-GLHttpReply($Stream, [int]$Status, [string]$Title, [string]$Text) {
    $reason = @{ 200 = 'OK'; 400 = 'Bad Request'; 404 = 'Not Found' }[$Status]
    $html = "<!doctype html><html><head><meta charset=`"utf-8`"><title>GatewayLens</title></head>" +
            "<body style=`"font-family:Segoe UI,sans-serif;margin:3em`"><h2>$Title</h2><p>$Text</p></body></html>"
    $body = [System.Text.Encoding]::UTF8.GetBytes($html)
    $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Status $reason`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
    $Stream.Write($head, 0, $head.Length)
    $Stream.Write($body, 0, $body.Length)
    $Stream.Flush()
}

function Receive-GLAuthCode {
    <#
        Waits for the browser to come back with the sign-in answer. Anything else -
        a favicon request, a browser's speculative empty connection, an answer
        carrying someone else's state - is turned away and the wait goes on.
        Returns $null when the time runs out.
    #>
    param($Listeners, [string]$State, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $ready = $null
        foreach ($l in $Listeners) { if ($l.Pending()) { $ready = $l; break } }
        if (-not $ready) { Start-Sleep -Milliseconds 100; continue }
        $client = $ready.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 2000
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 4096, $true)
            $line   = $reader.ReadLine()
            while ($true) { $h = $reader.ReadLine(); if ([string]::IsNullOrEmpty($h)) { break } }
            $path = if ($line -match '^GET (\S+) HTTP/') { $Matches[1] } else { '' }
            $q    = ConvertFrom-GLQueryString $(if ($path.Contains('?')) { $path.Substring($path.IndexOf('?') + 1) } else { '' })
            if (-not ($q.code -or $q.error)) { Send-GLHttpReply $stream 404 'Not found' ''; continue }
            if ($q.state -ne $State) {
                Send-GLHttpReply $stream 400 'This sign-in is not for this window' 'Return to GatewayLens and sign in from there.'
                continue
            }
            if ($q.error) {
                Send-GLHttpReply $stream 200 'Sign-in did not complete' 'GatewayLens shows the reason. You can close this tab.'
                return [pscustomobject]@{ Code = ''; Error = [string]$q.error; Description = [string]$q.error_description }
            }
            Send-GLHttpReply $stream 200 'You are signed in to GatewayLens' 'You can close this tab and return to GatewayLens.'
            return [pscustomobject]@{ Code = [string]$q.code; Error = ''; Description = '' }
        }
        catch { }      # a connection that sent nothing, or closed early
        finally { $client.Dispose() }
    }
    return $null
}

function Connect-GLBrowser {
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Tenant,
        [string]$LoginHint,
        [int]$TimeoutSec = 300,
        [scriptblock]$OpenBrowser = { param($u) Open-GLBrowser $u }
    )
    $scope = "$($script:TokenScopes.Fabric) openid profile offline_access"
    $pkce  = New-GLPkce
    $state = ConvertTo-GLBase64Url ([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16))
    $lb    = Start-GLLoopback
    try {
        $redirect = "http://localhost:$($lb.Port)"
        $url = New-GLAuthorizeUrl -ClientId $ClientId -Tenant $Tenant -RedirectUri $redirect -Scope $scope -State $state -Challenge $pkce.Challenge -LoginHint $LoginHint
        Write-Host 'Your browser opens to sign you in. Come back here once it says you are signed in.' -ForegroundColor Cyan
        if (-not (& $OpenBrowser $url)) {
            Write-Host "No browser opened. Open this address in one to sign in:`n  $url" -ForegroundColor Yellow
        }
        $answer = Receive-GLAuthCode -Listeners $lb.Listeners -State $state -TimeoutSec $TimeoutSec
    }
    finally { foreach ($l in $lb.Listeners) { try { $l.Stop() } catch { } } }

    if (-not $answer) {
        throw "Sign-in did not finish within $([math]::Ceiling($TimeoutSec / 60)) minute(s). Start GatewayLens again, or use -DeviceCode to sign in on another device."
    }
    if (-not $answer.Code) { throw (Format-GLSignInError $answer.Error $answer.Description) }
    $r = Invoke-GLTokenEndpoint -Uri (Get-GLTokenUri $Tenant) -Form @{
        client_id     = $ClientId
        grant_type    = 'authorization_code'
        code          = $answer.Code
        redirect_uri  = $redirect
        code_verifier = $pkce.Verifier
        scope         = $scope
    }
    if (-not $r.Ok) { throw (Format-GLSignInError $r.Error $r.Description) }
    return $r.Body
}

function Connect-GLDeviceCode {
    param([Parameter(Mandatory)][string]$ClientId, [Parameter(Mandatory)][string]$Tenant)
    $scope = "$($script:TokenScopes.Fabric) openid profile offline_access"
    $d = Invoke-GLTokenEndpoint -Uri (Get-GLTokenUri $Tenant 'devicecode') -Form @{ client_id = $ClientId; scope = $scope }
    if (-not $d.Ok) { throw (Format-GLSignInError $d.Error $d.Description) }
    Write-Host ''
    Write-Host $d.Body.message -ForegroundColor Yellow
    Write-Host ''
    $interval = if ($null -ne $d.Body.interval) { [int]$d.Body.interval } else { 5 }
    $expires  = if ($d.Body.expires_in) { [int]$d.Body.expires_in } else { 900 }
    $deadline = (Get-Date).AddSeconds($expires)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        $r = Invoke-GLTokenEndpoint -Uri (Get-GLTokenUri $Tenant) -Form @{
            client_id   = $ClientId
            grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
            device_code = [string]$d.Body.device_code
        }
        if ($r.Ok) { return $r.Body }
        if ($r.Error -eq 'authorization_pending') { continue }
        if ($r.Error -eq 'slow_down') { $interval += 5; continue }
        throw (Format-GLSignInError $r.Error $r.Description)
    }
    throw 'The device code expired before sign-in finished. Start GatewayLens again to get a new one.'
}

function Disable-GLAzBroker {
    # Az.Accounts signs in through the Windows account broker (WAM), which needs a
    # window to show its dialog on. -NoPicker also skips the subscription and tenant
    # question Az.Accounts asks in the console after signing in - with no console,
    # it would wait for an answer forever. This process only: the user's own Az
    # settings are left as they are. Versions without a setting do not need it.
    param([switch]$NoPicker)
    try { $null = Update-AzConfig -EnableLoginByWam $false -Scope Process -ErrorAction Stop -WarningAction SilentlyContinue } catch { }
    if ($NoPicker) {
        try { $null = Update-AzConfig -LoginExperienceV2 Off -Scope Process -ErrorAction Stop -WarningAction SilentlyContinue } catch { }
    }
}

function Connect-GLAz {
    # -NoWindow: started from GatewayLens.exe, there is no console window for the
    # broker, which then fails with "A window handle must be configured" - so the
    # browser signs in instead. Should the broker fail that way anyway, the browser
    # gets one more try.
    param([string]$TenantId, [switch]$DeviceCode, [string]$Account, [switch]$NoWindow)
    Import-Module Az.Accounts -ErrorAction Stop
    if ($NoWindow) { Disable-GLAzBroker -NoPicker }
    $p = @{ ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
    if ($TenantId)   { $p.TenantId = $TenantId }
    if ($DeviceCode) { $p.UseDeviceAuthentication = $true }
    if ($Account)    { $p.AccountId = $Account }
    try { $null = Connect-AzAccount @p }
    catch {
        if ($_.Exception.Message -notmatch 'window handle') { throw }
        Disable-GLAzBroker
        $null = Connect-AzAccount @p
    }
    $ctx = Get-AzContext
    $script:SignedInAs  = [string]$ctx.Account.Id
    $script:TenantShown = [string]$ctx.Tenant.Id
    $script:Auth        = $null
    $script:AuthMode    = 'Az.Accounts'
}

function Connect-GL {
    [CmdletBinding()]
    param([string]$TenantId, [switch]$DeviceCode, [string]$ClientId, [string]$Account, [string]$SignIn = 'Auto', [switch]$NoWindow)

    $how = Select-GLSignIn -Requested $SignIn -ClientId $ClientId -BuiltInId $script:BuiltInClientId -AzAvailable (Test-GLAzAccounts)
    if ($how -eq 'Az') {
        Connect-GLAz -TenantId $TenantId -DeviceCode:$DeviceCode -Account $Account -NoWindow:$NoWindow
        return
    }

    $id     = if ($ClientId) { $ClientId.Trim() } else { $script:BuiltInClientId }
    $tenant = if ($TenantId) { $TenantId.Trim() } else { 'organizations' }   # any work or school account
    $script:Auth = @{ ClientId = $id; Tenant = $tenant; RefreshToken = ''; Tokens = @{}; NoGraph = $false }

    if ($DeviceCode) {
        $body = Connect-GLDeviceCode -ClientId $id -Tenant $tenant
    }
    else {
        $hint = if ($Account) { $Account.Trim() } else { Get-GLWindowsUpn }
        $body = Connect-GLBrowser -ClientId $id -Tenant $tenant -LoginHint $hint
    }
    Save-GLTokens Fabric $body

    $claims = ConvertFrom-GLJwt $body.id_token
    if (-not $claims) { $claims = ConvertFrom-GLJwt $body.access_token }
    $who = @($claims.preferred_username, $claims.upn, $claims.unique_name, $claims.email) | Where-Object { $_ } | Select-Object -First 1
    $script:SignedInAs  = [string]$who
    $script:TenantShown = [string]$claims.tid
    if ($claims.tid) { $script:Auth.Tenant = [string]$claims.tid }   # later tokens come from the tenant actually signed in to
    $script:AuthMode = if ($DeviceCode) { 'Device code' } else { 'Browser' }
}

function Get-GLToken {
    # Fabric, Power BI or Graph. A token is reused until ten minutes before it
    # expires, so a background job never starts with one about to run out. Returns
    # $null for Graph when it is not available - callers handle that.
    param([Parameter(Mandatory)][ValidateSet('Fabric', 'PowerBI', 'Graph')][string]$For)
    if ($script:AuthMode -eq 'Demo') { return 'demo-token' }
    if ($script:AuthMode -eq 'Az.Accounts') {
        # Az.Accounts keeps and renews its own tokens - ask it each time
        $resource = $script:TokenScopes[$For] -replace '/\.default$', ''
        try {
            $t = Get-AzAccessToken -ResourceUrl $resource -ErrorAction Stop -WarningAction SilentlyContinue
            return (ConvertFrom-GLToken $t.Token)
        }
        catch {
            if ($For -eq 'Graph') { return $null }
            throw
        }
    }
    if (-not $script:Auth) { throw 'Not signed in.' }
    if ($For -eq 'Graph' -and $script:Auth.NoGraph) { return $null }

    $t = $script:Auth.Tokens[$For]
    if ($t -and $t.ExpiresOn -gt (Get-Date).AddMinutes(10)) { return $t.Value }

    $r = Invoke-GLTokenEndpoint -Uri (Get-GLTokenUri $script:Auth.Tenant) -Form @{
        client_id     = $script:Auth.ClientId
        grant_type    = 'refresh_token'
        refresh_token = $script:Auth.RefreshToken
        scope         = "$($script:TokenScopes[$For]) offline_access"
    }
    if ($r.Ok) {
        Save-GLTokens $For $r.Body
        return [string]$r.Body.access_token
    }
    if ($For -eq 'Graph') {
        # not approved for this app in this tenant - name lookups need an object id
        $script:Auth.NoGraph = $true
        return $null
    }
    throw (Format-GLSignInError $r.Error $r.Description)
}

# ============================================================================
#  SELF-TEST  -  every API once, read-only, and a plain verdict per call.
# ============================================================================
function Test-GLDemoApart {
    # The demo must never write into the real log, change record or backups.
    if ($script:AuthMode -ne 'Demo' -or -not $script:DemoRoot) { return , @() }   # an empty list: @($null).Count is 1
    $outside = @(@($script:LogFolder, $script:BackupFolder) | Where-Object { -not ([string]$_).StartsWith($script:DemoRoot) })
    return , $outside
}

function Invoke-GLSelfTest {
    $results = [System.Collections.Generic.List[object]]::new()
    function Add-Result([string]$Name, [bool]$Ok, [string]$Detail) {
        $results.Add([pscustomobject]@{ Check = $Name; Result = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
        $color = if ($Ok) { 'Green' } else { 'Red' }
        Write-Host ("  {0,-4}  {1,-44} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail) -ForegroundColor $color
    }

    Write-Host ''
    Write-Host "$($script:AppName) $($script:AppVersion) self-test" -ForegroundColor Cyan
    Write-Host "  signed in as $($script:SignedInAs) via $($script:AuthMode)" -ForegroundColor DarkGray
    Write-Host ''

    if ($script:AuthMode -eq 'Demo') {
        $outside = Test-GLDemoApart
        $apart   = @($outside).Count -eq 0
        Add-Result 'Demo: kept apart from real records' $apart $(if ($apart) { "log, changes and backups under $($script:DemoRoot)" } else { "writes to $($outside -join ', ')" })
    }

    $fab = $null; $pbi = $null; $gr = $null
    try { $fab = Get-GLToken Fabric;  Add-Result 'Token: Fabric'   $true  'issued' } catch { Add-Result 'Token: Fabric'   $false $_.Exception.Message }
    try { $pbi = Get-GLToken PowerBI; Add-Result 'Token: Power BI' $true  'issued' } catch { Add-Result 'Token: Power BI' $false $_.Exception.Message }
    $gr = Get-GLToken Graph
    Add-Result 'Token: Microsoft Graph' ([bool]$gr) $(if ($gr) { 'issued' } else { 'not available - name lookups need an object id' })

    $gateways = @(); $connections = @()
    $who = [System.Collections.Generic.List[string]]::new()      # ids in the access lists, for the Graph check
    if ($fab) {
        try {
            $gateways = Get-GLPaged -Uri 'https://api.fabric.microsoft.com/v1/gateways' -Token $fab
            $byType = ($gateways | Group-Object type | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
            Add-Result 'Fabric: list gateways' $true "$($gateways.Count) gateway(s) $(if ($byType) { "($byType)" })"
        } catch { Add-Result 'Fabric: list gateways' $false $_.Exception.Message }

        $onprem = $gateways | Where-Object { $_.type -eq 'OnPremises' } | Select-Object -First 1
        if ($onprem) {
            # creating connections and updating credentials need the gateway's public key
            try {
                $null = ConvertTo-GLEncryptedCredential -CredentialJson '{"credentialData":[]}' -Modulus $onprem.publicKey.modulus -Exponent $onprem.publicKey.exponent
                $bits = [Convert]::FromBase64String($onprem.publicKey.modulus).Length * 8
                Add-Result 'Fabric: gateway key for credentials' $true "$bits-bit key on '$($onprem.displayName)' - credentials can be encrypted"
            } catch { Add-Result 'Fabric: gateway key for credentials' $false "$($_.Exception.Message) - creating connections and updating credentials will not work" }
            try {
                $m = Get-GLPaged -Uri "https://api.fabric.microsoft.com/v1/gateways/$($onprem.id)/members" -Token $fab
                Add-Result 'Fabric: gateway members' $true "$($m.Count) member(s) on '$($onprem.displayName)'"
            } catch { Add-Result 'Fabric: gateway members' $false $_.Exception.Message }
            try {
                $ra = Get-GLRoleAssignments -Kind gateways -Id $onprem.id -FabricToken $fab
                foreach ($a in @($ra)) { if ($a.principal.id) { $who.Add([string]$a.principal.id) } }
                Add-Result 'Fabric: gateway access' $true "$($ra.Count) assignment(s)"
            } catch { Add-Result 'Fabric: gateway access' $false $_.Exception.Message }
        } else {
            Add-Result 'Fabric: gateway members' $false 'skipped - no on-premises gateway visible to this account'
        }

        try {
            $connections = Get-GLPaged -Uri 'https://api.fabric.microsoft.com/v1/connections' -Token $fab
            Add-Result 'Fabric: list connections' $true "$($connections.Count) connection(s)"
        } catch { Add-Result 'Fabric: list connections' $false $_.Exception.Message }

        $c1 = $connections | Select-Object -First 1
        if ($c1) {
            try {
                $ra = Get-GLRoleAssignments -Kind connections -Id $c1.id -FabricToken $fab
                foreach ($a in @($ra)) { if ($a.principal.id) { $who.Add([string]$a.principal.id) } }
                Add-Result 'Fabric: connection access' $true "$($ra.Count) assignment(s) on '$($c1.displayName)'"
            } catch { Add-Result 'Fabric: connection access' $false $_.Exception.Message }
        }
    }

    if ($pbi) {
        # one gateway is enough to prove the endpoint works - the app checks them all
        Write-Host '        checking live status on one gateway (up to 30s)...' -ForegroundColor DarkGray
        try {
            $vnets = @($gateways | Where-Object { [string]$_.type -eq 'VirtualNetwork' } | ForEach-Object { [string]$_.id })
            $live  = Get-GLLiveStatus -PbiToken $pbi -MaxClusters 1 -TimeoutSec 30 -SkipClusterIds $vnets
            $vals = @($live.Values)
            $up   = @($vals | Where-Object { $_.Status -eq 'Live' }).Count
            $slow = @($vals | Where-Object { $_.Status -eq 'Timeout' }).Count
            $note = if ($slow) { ", $slow did not answer in time" } else { '' }
            Add-Result 'Power BI v2: live status (unofficial)' $true "$($vals.Count) member(s), $up live$note"
        } catch { Add-Result 'Power BI v2: live status (unofficial)' $false "$($_.Exception.Message) - the Status column will show n/a" }

        try {
            $dir = Get-GLDatasourceDirectory -PbiToken $pbi -MaxPages 1
            $acc = @($dir.Values | Where-Object { $_.Account }).Count
            Add-Result 'Power BI v2: usernames and access (unofficial)' $true "$($dir.Count) data source(s) on the first page, $acc with a username"
        } catch { Add-Result 'Power BI v2: usernames and access (unofficial)' $false "$($_.Exception.Message) - Account and Users stay empty; Verify users still works" }

        $gc = $connections | Where-Object { $_.connectivityType -eq 'OnPremisesGateway' -and $_.gatewayId } | Select-Object -First 1
        if ($gc) {
            $t = Test-GLConnection -GatewayId $gc.gatewayId -ConnectionId $gc.id -PbiToken $pbi
            # a failed TEST of a working endpoint is still a working endpoint - only
            # an authorisation or not-found error means the call itself is unusable
            $usable = $t.Ok -or ($t.Message -notmatch 'HTTP (401|403|404)')
            Add-Result 'Power BI: test connection' $usable "'$($gc.displayName)': $($t.Message)"
            # Read-only: what updating credentials like the portal needs - a key per
            # member. Only someone who may manage a connection gets them, so connections
            # on a gateway this account administers come first.
            $check = 'Power BI v2: credentials like the portal (unofficial)'
            $gwOnly = @($connections | Where-Object { $_.connectivityType -eq 'OnPremisesGateway' -and $_.gatewayId })
            $cands  = @(@($gwOnly | Where-Object { $onprem -and $_.gatewayId -eq $onprem.id }) + $gwOnly | Where-Object { $_ } | Group-Object id | ForEach-Object { $_.Group[0] } | Select-Object -First 8)
            $found = $false; $denied = 0; $other = ''
            foreach ($cand in $cands) {
                try {
                    $pds  = Invoke-GLRequest -Uri "https://api.powerbi.com/v2.0/myorg/me/gatewayClusterDatasources/$($cand.id)" -Token $pbi -MaxRetry 1
                    $mkey = @(if ($pds.memberGatewayPublicKeys) { $pds.memberGatewayPublicKeys.PSObject.Properties | Where-Object { $_.Value } })
                    if ($mkey.Count) {
                        $null = ConvertFrom-GLRsaXmlKey -Base64Xml ([string]$mkey[0].Value)
                        Add-Result $check $true "$($mkey.Count) member key(s) on '$($cand.displayName)' - the username stays visible after an update"
                        $found = $true; break
                    }
                }
                catch {
                    if ($_.Exception.Message -match 'NotEnoughPermission|HTTP 40[13]') { $denied++; continue }
                    $other = $_.Exception.Message; break
                }
            }
            if (-not $found) {
                if ($other) { Add-Result $check $false "$other - updates use the documented way" }
                elseif ($denied) { Add-Result $check $true "the endpoint answers, but none of the $denied connection(s) tried is yours to manage - credentials need Owner, or Admin on the gateway, either way" }
                else { Add-Result $check $false 'no member keys - updates use the documented way, and the Account can be empty afterwards' }
            }
        }
    }

    if ($gr) {
        try {
            $me = Invoke-GLRequest -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName' -Token $gr -MaxRetry 1
            Add-Result 'Graph: read own profile' $true $me.userPrincipalName
        } catch { Add-Result 'Graph: read own profile' $false $_.Exception.Message }
        # Fabric gives only the ids of who has access - the names come from Graph
        $ids = @($who | Sort-Object -Unique)
        if ($ids.Count) {
            try {
                $n = Get-GLPrincipalNames -Ids $ids -GraphToken $gr
                $named = @($n.Values | Where-Object { -not $_.Missing }).Count
                $del   = @($n.Values | Where-Object { $_.Missing -and $_.State -in 'Deleted', 'Gone' }).Count
                $unk   = @($n.Values | Where-Object { $_.Missing -and $_.State -notin 'Deleted', 'Gone' }).Count
                $tail  = if ($named -eq 0) { ' - access lists will show object ids' } else { '' }
                if ($del) { $tail += "; $del deleted from Microsoft Entra ID - the portal does not show them, but they still have their roles" }
                if ($unk) { $tail += "; $unk Graph would not say who they are" }
                Add-Result 'Graph: names in access lists' ($named -gt 0) "$named of $($ids.Count) id(s) named$tail"
            } catch { Add-Result 'Graph: names in access lists' $false "$($_.Exception.Message) - access lists will show object ids" }
        }
    }

    # public web pages, not the tenant - no token is sent
    $rel = Get-GLGatewayReleases
    $sup = @($rel.Supported)
    $relText = if ($rel.Newest) { "newest $($rel.Newest)$(if ($sup.Count) { ", supported back to $($sup[$sup.Count - 1].Version)" })" } else { "$($rel.Log -join '; ') - version badges compare members only" }
    Add-Result 'Microsoft: newest gateway version' ([bool]$rel.Newest) $relText

    $failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
    Write-Host ''
    if ($failed -eq 0) { Write-Host 'Everything works with this account.' -ForegroundColor Green }
    else { Write-Host "$failed check(s) failed. Paste this output into an issue if you need help." -ForegroundColor Yellow }
    return ($failed -eq 0)
}

# ============================================================================
#  INSPECTION
#
#  Shows which fields Microsoft's APIs return, without showing the data itself:
#  values appear only for dates, numbers, yes/no and short type-like fields; every
#  other text value is replaced by its length. Used to find fields worth adding.
# ============================================================================
function Format-GLShape {
    param($Object, [string]$Prefix = '', [int]$Depth = 0)
    if ($null -eq $Object -or $Depth -gt 6) { return }
    foreach ($p in $Object.PSObject.Properties) {
        $path = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
        $v = $p.Value
        if ($null -eq $v) { '{0,-58} (empty)' -f $path; continue }
        if ($v -is [System.Management.Automation.PSCustomObject]) { Format-GLShape -Object $v -Prefix $path -Depth ($Depth + 1); continue }
        if ($v -is [array]) {
            '{0,-58} list of {1}' -f $path, $v.Count
            if ($v.Count -and $v[0] -is [System.Management.Automation.PSCustomObject]) { Format-GLShape -Object $v[0] -Prefix "$path[0]" -Depth ($Depth + 1) }
            continue
        }
        $text = [string]$v
        $show = if ($v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { $text }
                elseif ($v -is [datetime]) { $v.ToString('yyyy-MM-dd HH:mm:ss') + '   <- date' }
                elseif ($text -match '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}') { "$text   <- date" }
                elseif ($p.Name -match 'type|status|kind|level|state|role|right|mode|encryption|privacy' -and $text.Length -le 40) { $text }
                else { "<text, $($text.Length) characters>" }
        '{0,-58} {1}' -f $path, $show
    }
}

function Invoke-GLInspect {
    Write-Host ''
    Write-Host "$($script:AppName) $($script:AppVersion) - API field inspection" -ForegroundColor Cyan
    Write-Host '  Values are shown only for dates, numbers, yes/no and short type fields.' -ForegroundColor DarkGray
    Write-Host '  All other text is replaced by its length, so this output is safe to share.' -ForegroundColor DarkGray
    $fab = Get-GLToken Fabric
    $pbi = Get-GLToken PowerBI
    $probes = @(
        @{ Title = 'Power BI v2 gatewayClusterDatasources (unofficial) - first data source'
           Get   = { (Invoke-GLRequest -Uri 'https://api.powerbi.com/v2.0/myorg/me/gatewayClusterDatasources?$expand=users' -Token $pbi).value | Select-Object -First 1 } }
        @{ Title = 'Power BI v2 gatewayClusters (unofficial) - first gateway'
           Get   = { (Invoke-GLRequest -Uri 'https://api.powerbi.com/v2.0/myorg/me/gatewayClusters' -Token $pbi).value | Select-Object -First 1 } }
        @{ Title = 'Fabric connections (documented) - first connection'
           Get   = { (Invoke-GLRequest -Uri 'https://api.fabric.microsoft.com/v1/connections' -Token $fab).value | Select-Object -First 1 } }
        @{ Title = 'Power BI v1 gateway datasources (documented) - first data source'
           Get   = {
               $g = (Invoke-GLRequest -Uri 'https://api.powerbi.com/v1.0/myorg/gateways' -Token $pbi).value | Select-Object -First 1
               if ($g) { (Invoke-GLRequest -Uri "https://api.powerbi.com/v1.0/myorg/gateways/$($g.id)/datasources" -Token $pbi).value | Select-Object -First 1 }
           } }
    )
    foreach ($pr in $probes) {
        Write-Host ''
        Write-Host "== $($pr.Title)" -ForegroundColor Yellow
        try {
            $o = & $pr.Get
            if ($o) { Format-GLShape -Object $o | ForEach-Object { Write-Host "  $_" } }
            else    { Write-Host '  (nothing returned)' -ForegroundColor DarkGray }
        }
        catch { Write-Host "  failed: $($_.Exception.Message)" -ForegroundColor Red }
    }
    Write-Host ''
}

# ============================================================================
#  WINDOW
# ============================================================================
$script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="GatewayLens" Width="1440" Height="920" MinWidth="1100" MinHeight="680"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource WindowBg}"
        FontFamily="Segoe UI" FontSize="12" Foreground="{DynamicResource Ink}">

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="8"/>
      <RowDefinition Name="LogRow" Height="175" MinHeight="0"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Name="HeaderBar" Grid.Row="0" Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Border}" BorderThickness="0,0,0,1" Padding="16,10">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Name="TxtIdentity" VerticalAlignment="Center" Foreground="{DynamicResource InkMuted}" Margin="0,0,14,0"/>
          <Button Name="BtnSignInReal" Content="Sign in to your tenant" Style="{DynamicResource PrimaryButton}" Visibility="Collapsed" Margin="0,0,14,0"
                  ToolTip="Leave the demo and go back to the start page, to sign in with your own account."/>
          <Button Name="BtnKiosk" Style="{DynamicResource KioskButton}" Margin="0,0,14,0"
                  ToolTip="Kiosk view: full screen, gateway tiles only, nothing that changes anything - for a wall screen. F11 goes in and out, Esc leaves it.">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE7F4;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="15" VerticalAlignment="Center" Margin="0,1,8,0"/>
              <TextBlock Text="Kiosk view" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
          <TextBlock Text="Theme" Style="{DynamicResource LabelText}" Margin="0,0,6,0"/>
          <ComboBox Name="CmbTheme" Width="110" MinHeight="28"/>
          <Button Name="BtnFontDown" Content="A-" MinWidth="34" Padding="6,2" Margin="12,0,2,0" ToolTip="Smaller text - also Ctrl + mouse wheel, or Ctrl + minus"/>
          <TextBlock Name="TxtFontSize" VerticalAlignment="Center" MinWidth="22" TextAlignment="Center" Foreground="{DynamicResource InkMuted}"/>
          <Button Name="BtnFontUp" Content="A+" MinWidth="34" Padding="6,2" Margin="2,0,0,0" ToolTip="Larger text - also Ctrl + mouse wheel, or Ctrl + plus. Ctrl + 0 goes back to the default."/>
          <Button Name="BtnClearHistory" Content="Clear history" Margin="12,0,0,0"
                  ToolTip="Forget everything typed into the search and name boxes. Passwords are never kept."/>
          <Button Name="BtnHelp" Margin="8,0,0,0" MinWidth="34" Padding="8,2" ToolTip="Help, what is new, and where to report a problem (F1)">
            <TextBlock Text="?" FontWeight="Bold" FontSize="14"/>
          </Button>
        </StackPanel>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Image Name="ImgLogo" Width="30" Height="30" Margin="0,0,10,0" RenderOptions.BitmapScalingMode="HighQuality"/>
          <TextBlock Name="TxtApp" Text="GatewayLens" FontSize="19" FontWeight="SemiBold" Foreground="{DynamicResource Ink}" VerticalAlignment="Center"/>
          <TextBlock Name="TxtVersion" Margin="8,0,0,0" VerticalAlignment="Center" Foreground="{DynamicResource InkFaint}"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <TabControl Name="Tabs" Grid.Row="1" Margin="12,10,12,0" BorderBrush="{DynamicResource Border}">

      <!-- ============================ GATEWAYS ============================ -->
      <TabItem Name="TabGateways" Header="Gateways">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="8"/>
            <RowDefinition Name="GwDetailRow" Height="270" MinHeight="0"/>
          </Grid.RowDefinitions>

          <WrapPanel Name="GwToolbar" Grid.Row="0" Margin="0,0,0,8">
            <Button Name="BtnGwRefresh" Content="Refresh" Style="{DynamicResource PrimaryButton}"/>
            <CheckBox Name="ChkLive" Content="Live member status" IsChecked="True" VerticalAlignment="Center" Margin="8,0,2,0"
                      ToolTip="Online / offline per member, from the endpoint behind the portal's Manage gateways page. Not documented by Microsoft - untick it if it ever stops working."/>
            <TextBlock Text="(unofficial)" Foreground="{DynamicResource InkFaint}" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <CheckBox Name="ChkSkipVnet" Content="Skip VNet status" IsChecked="True" VerticalAlignment="Center" Margin="0,0,10,0"
                      ToolTip="Checking a VNet gateway's status starts it if it has gone to sleep, and it then uses capacity until it sleeps again. Leave this on unless you want them woken."/>
            <TextBlock Text="Auto-refresh" Style="{DynamicResource LabelText}"/>
            <ComboBox Name="CmbAutoRefresh" Width="80" MinHeight="26"/>
            <Button Name="BtnAlerts" Margin="10,0,6,0" ToolTip="Be told when a gateway member goes down, and when it is back - a Windows notification, a sound, or a message in Teams. Off until you turn it on.">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE7ED;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" VerticalAlignment="Center" Margin="0,1,7,0"/>
                <TextBlock Name="TxtAlerts" Text="Alerts" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <TextBlock Text="Filter" Style="{DynamicResource LabelText}"/>
            <ComboBox Name="TxtGwFilter" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Width="180" MinHeight="26" VerticalContentAlignment="Center"/>
            <Button Name="BtnGwCopyAll" Content="Copy all" Margin="12,0,6,0"
                    ToolTip="Every gateway and member, tab-separated - pastes straight into Excel or a ticket."/>
            <Button Name="BtnGwIpsAll" Content="Resolve IPs"
                    ToolTip="Resolve every member machine to an IP address. One block per gateway in the log, and all of it on the clipboard."/>
            <Button Name="BtnGwExport" Content="Export CSV"/>
            <Button Name="BtnGwCopyId" Content="Copy id"/>
          </WrapPanel>

          <Border Grid.Row="1" Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="10" Padding="18,10" Margin="0,0,0,8">
            <DockPanel>
              <Button Name="BtnKioskExit" DockPanel.Dock="Right" Content="Leave kiosk (Esc)" Visibility="Collapsed" VerticalAlignment="Center" Margin="16,0,0,0"/>
              <TextBlock Name="TxtGwUpdated" DockPanel.Dock="Right" FontSize="16" Foreground="{DynamicResource InkMuted}" VerticalAlignment="Center"/>
              <WrapPanel VerticalAlignment="Center">
                <TextBlock Name="TxtGwTotal" FontSize="24" FontWeight="SemiBold" Foreground="{DynamicResource Ink}" Margin="0,0,28,0"/>
                <TextBlock Name="TxtGwDown" FontSize="24" FontWeight="SemiBold" Foreground="{DynamicResource Danger}" Margin="0,0,28,0"/>
                <TextBlock Name="TxtGwDegraded" FontSize="24" FontWeight="SemiBold" Foreground="{DynamicResource Warn}" Margin="0,0,28,0"/>
                <TextBlock Name="TxtGwSummary" FontSize="14" Foreground="{DynamicResource InkMuted}" VerticalAlignment="Center"/>
              </WrapPanel>
            </DockPanel>
          </Border>

          <ListBox Name="LstGwTiles" Grid.Row="2" SelectionMode="Single" Background="Transparent" BorderThickness="0"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.VerticalScrollBarVisibility="Auto">
            <ListBox.ItemsPanel>
              <ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate>
            </ListBox.ItemsPanel>
            <ListBox.ItemContainerStyle>
              <Style TargetType="ListBoxItem">
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                      <Border Name="Ring" BorderThickness="3" CornerRadius="13" BorderBrush="Transparent" Margin="4">
                        <ContentPresenter/>
                      </Border>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsSelected" Value="True">
                          <Setter TargetName="Ring" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                        </Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </Setter.Value>
                </Setter>
              </Style>
            </ListBox.ItemContainerStyle>
            <ListBox.ItemTemplate>
              <DataTemplate>
                <Border Name="Tile" Width="270" Height="162" CornerRadius="10" Padding="16,12" Background="{DynamicResource TileIdle}" Cursor="Hand">
                  <StackPanel>
                    <DockPanel>
                      <Border Name="BadgeBox" DockPanel.Dock="Right" CornerRadius="4" Padding="6,1" Background="{DynamicResource TileBadge}" Visibility="Collapsed">
                        <TextBlock Text="{Binding Badge}" FontSize="10" FontWeight="Bold" Foreground="{DynamicResource TileInk}"/>
                      </Border>
                      <TextBlock Text="{Binding StatusText}" FontSize="13" FontWeight="Bold" Foreground="{DynamicResource TileInk}"/>
                    </DockPanel>
                    <TextBlock Text="{Binding Name}" ToolTip="{Binding Name}" FontSize="20" FontWeight="SemiBold" Foreground="{DynamicResource TileInk}"
                               TextTrimming="CharacterEllipsis" Margin="0,6,0,4"/>
                    <TextBlock Text="{Binding MembersText}" FontSize="15" Foreground="{DynamicResource TileInk}"/>
                    <TextBlock Text="{Binding VersionText}" FontSize="12" Foreground="{DynamicResource TileInk}" Opacity="0.85" TextTrimming="CharacterEllipsis"/>
                    <TextBlock Text="{Binding ConnectionsText}" FontSize="12" Foreground="{DynamicResource TileInk}" Opacity="0.85" TextTrimming="CharacterEllipsis"/>
                    <TextBlock Text="{Binding DownText}" FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource TileInk}" TextTrimming="CharacterEllipsis"/>
                  </StackPanel>
                </Border>
                <DataTemplate.Triggers>
                  <DataTrigger Binding="{Binding Status}" Value="Online">
                    <Setter TargetName="Tile" Property="Background" Value="{DynamicResource TileOk}"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding Status}" Value="Degraded">
                    <Setter TargetName="Tile" Property="Background" Value="{DynamicResource TileWarn}"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding Status}" Value="Offline">
                    <Setter TargetName="Tile" Property="Background" Value="{DynamicResource TileDown}"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding Status}" Value="VNet">
                    <Setter TargetName="Tile" Property="Background" Value="{DynamicResource TileVnet}"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding HasBadge}" Value="True">
                    <Setter TargetName="BadgeBox" Property="Visibility" Value="Visible"/>
                  </DataTrigger>
                </DataTemplate.Triggers>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
          <GridSplitter Name="GwSplitter" Grid.Row="3" HorizontalAlignment="Stretch" ResizeDirection="Rows" Background="Transparent"/>

          <Grid Name="GwDetail" Grid.Row="4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="3*" MinWidth="280"/>
              <ColumnDefinition Width="12"/>
              <ColumnDefinition Width="2*" MinWidth="260"/>
            </Grid.ColumnDefinitions>
            <GridSplitter Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" ResizeDirection="Columns" ResizeBehavior="PreviousAndNext"
                          Background="Transparent" ToolTip="Drag to share the room between members and access"/>
            <DockPanel Grid.Column="0">
              <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                  <Button Name="BtnMemberEnable" Content="Enable"/>
                  <Button Name="BtnMemberDisable" Content="Disable" Style="{DynamicResource DangerButton}"/>
                  <Button Name="BtnGwCopyCluster" Content="Copy gateway"/>
                  <Button Name="BtnGwIpsCluster" Content="Resolve IPs" Margin="0"/>
                </StackPanel>
                <TextBlock Name="TxtMembersTitle" Text="Members" Style="{DynamicResource SectionText}"/>
              </DockPanel>
              <DataGrid IsReadOnly="False" CanUserAddRows="False" CanUserDeleteRows="False" CanUserSortColumns="True" AutoGenerateColumns="True" SelectionMode="Extended" Name="GridMembers"/>
            </DockPanel>
            <DockPanel Grid.Column="2">
              <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                  <CheckBox Name="ChkGwShowGone" Visibility="Collapsed" VerticalAlignment="Center" Margin="0,0,12,0"
                            ToolTip="Accounts Microsoft Entra ID does not know any more - deleted ones. The portal leaves them out, but they still hold their roles. Show them to see or remove them."/>
                  <Button Name="BtnGwAccessAdd" Content="Add..."/>
                  <Button Name="BtnGwAccessRemove" Content="Remove" Style="{DynamicResource DangerButton}" Margin="0"/>
                </StackPanel>
                <TextBlock Text="Gateway access" Style="{DynamicResource SectionText}"/>
              </DockPanel>
              <DataGrid IsReadOnly="False" CanUserAddRows="False" CanUserDeleteRows="False" CanUserSortColumns="True" AutoGenerateColumns="True" SelectionMode="Extended" Name="GridGwAccess"/>
            </DockPanel>
          </Grid>
        </Grid>
      </TabItem>

      <!-- ============================ CONNECTIONS ============================ -->
      <TabItem Name="TabConnections" Header="Connections">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*" MinHeight="90"/>
            <RowDefinition Height="8"/>
            <RowDefinition Name="CnBottomRow" Height="330" MinHeight="120"/>
          </Grid.RowDefinitions>

          <WrapPanel Grid.Row="0" Margin="0,0,0,6">
            <TextBlock Text="Search" Style="{DynamicResource LabelText}" Margin="0,0,6,0"/>
            <ComboBox Name="TxtCnSearch" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Width="230" MinHeight="26" VerticalContentAlignment="Center"
                     ToolTip="Name, path, type, gateway or id. Several values separated by ; - a connection matching any of them is listed."/>
            <TextBlock Text="User" Style="{DynamicResource LabelText}"/>
            <ComboBox Name="TxtCnUser" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Width="170" MinHeight="26" VerticalContentAlignment="Center"
                     ToolTip="Someone with access. Needs the users loaded - tick Usernames and access, or press Verify users."/>
            <TextBlock Text="Account" Style="{DynamicResource LabelText}"/>
            <ComboBox Name="TxtCnAccount" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Width="150" MinHeight="26" VerticalContentAlignment="Center"
                     ToolTip="The username stored in the connection's credentials. Needs Usernames and access."/>
            <TextBlock Text="Gateway" Style="{DynamicResource LabelText}"/>
            <ComboBox Name="CmbCnGateway" Width="180" MinHeight="26"/>
            <TextBlock Text="Connectivity" Style="{DynamicResource LabelText}"/>
            <ComboBox Name="CmbCnConnectivity" Width="150" MinHeight="26"/>
            <TextBlock Text="Type" Style="{DynamicResource LabelText}"/>
            <ComboBox Name="CmbCnType" Width="130" MinHeight="26"/>
            <TextBlock Text="Show" Style="{DynamicResource LabelText}"/>
            <ComboBox Name="CmbCnShow" Width="250" MinHeight="26"
                      ToolTip="Cleanup views. Last used and No use recorded come from Microsoft's connection recency (preview): it records use since spring 2026 and can be up to 30 minutes behind. Duplicates: same gateway, type, path and account. Failing tests: after Verify status."/>
          </WrapPanel>

          <DockPanel Grid.Row="1" Margin="0,0,0,8">
            <TextBlock Name="TxtCnCount" DockPanel.Dock="Right" Style="{DynamicResource LabelText}"/>
            <WrapPanel>
              <Button Name="BtnCnRefresh" Content="Refresh" Style="{DynamicResource PrimaryButton}"/>
              <CheckBox Name="ChkDirectory" Content="Usernames and access" IsChecked="True" VerticalAlignment="Center" Margin="8,0,2,0"
                        ToolTip="Loads every connection's credential username and users in one call, from the endpoint the portal uses. Not documented by Microsoft."/>
              <TextBlock Text="(unofficial)" Foreground="{DynamicResource InkFaint}" VerticalAlignment="Center" Margin="0,0,12,0"/>
              <CheckBox Name="ChkCnCloud" Content="Include cloud connections" VerticalAlignment="Center" Margin="0,0,12,0"
                        ToolTip="Shareable cloud connections too. Unticked: gateway connections only - on-premises and VNet."/>
              <TextBlock Text="Gateway state" Style="{DynamicResource LabelText}"/>
              <CheckBox Name="ChkStOnline"  Content="Online"  IsChecked="True" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <CheckBox Name="ChkStPartial" Content="Partially online" IsChecked="True" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <CheckBox Name="ChkStOffline" Content="Offline" IsChecked="True" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <CheckBox Name="ChkStUnknown" Content="Unknown" IsChecked="True" VerticalAlignment="Center" Margin="0,0,12,0"/>
              <Button Name="BtnCnExclude" Content="Exclude selected rows"/>
              <Button Name="BtnCnUnexclude" Content="Show excluded"/>
              <Button Name="BtnCnExport" Content="Export CSV"/>
              <Button Name="BtnCnAccessReport" Content="Access report..."
                      ToolTip="Who can use what - one row per connection or gateway and person, read fresh from Fabric. For an audit; with the User filter set, everything that one person can access."/>
            </WrapPanel>
          </DockPanel>

          <DataGrid IsReadOnly="False" CanUserAddRows="False" CanUserDeleteRows="False" CanUserSortColumns="True" AutoGenerateColumns="True" Name="GridConnections" Grid.Row="2" SelectionMode="Extended"/>
          <GridSplitter Grid.Row="3" HorizontalAlignment="Stretch" ResizeDirection="Rows" Background="Transparent"
                        ToolTip="Drag to give the list or the panels below more room"/>

          <Grid Grid.Row="4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*" MinWidth="280"/>
              <ColumnDefinition Width="12"/>
              <ColumnDefinition Name="CnActionsCol" Width="520" MinWidth="380"/>
            </Grid.ColumnDefinitions>
            <GridSplitter Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" ResizeDirection="Columns" ResizeBehavior="PreviousAndNext"
                          Background="Transparent" ToolTip="Drag to make the actions wider or narrower"/>

            <DockPanel Grid.Column="0">
              <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                  <CheckBox Name="ChkCnShowGone" Visibility="Collapsed" VerticalAlignment="Center" Margin="0,0,12,0"
                            ToolTip="Accounts Microsoft Entra ID does not know any more - deleted ones. The portal leaves them out, but they still hold their roles. Show them to see or remove them."/>
                  <Button Name="BtnCnTest" Content="Test"/>
                  <Button Name="BtnCnCopyId" Content="Copy id"/>
                  <Button Name="BtnCnAccessAdd" Content="Add..."/>
                  <Button Name="BtnCnAccessRemove" Content="Remove" Style="{DynamicResource DangerButton}" Margin="0"/>
                </StackPanel>
                <TextBlock Name="TxtCnSelected" Text="Select a connection to see who has access." Style="{DynamicResource SectionText}" TextTrimming="CharacterEllipsis"/>
              </DockPanel>
              <DataGrid IsReadOnly="False" CanUserAddRows="False" CanUserDeleteRows="False" CanUserSortColumns="True" AutoGenerateColumns="True" SelectionMode="Extended" Name="GridCnAccess"/>
            </DockPanel>

            <Border Grid.Column="2" Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Border}" BorderThickness="1" Padding="10,8">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel>
                  <TextBlock Name="TxtBulkTitle" Text="All listed connections" Style="{DynamicResource SectionText}"/>
                  <TextBlock Text="Everything below acts on every connection in the list above, after filters and exclusions."
                             Foreground="{DynamicResource InkMuted}" FontSize="11" TextWrapping="Wrap" Margin="0,2,0,4"/>
                  <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                    <Button Name="BtnBulkStatus" Content="Verify status"/>
                    <Button Name="BtnBulkUsers" Content="Verify users"/>
                  </StackPanel>

                  <GroupBox Header="Access">
                    <StackPanel>
                      <ComboBox Name="TxtBulkPrincipals" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" MinHeight="26" VerticalContentAlignment="Center"
                               ToolTip="Emails, group names or object ids, separated by ; - all of them are applied to every listed connection."/>
                      <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                        <TextBlock Text="Type" Style="{DynamicResource LabelText}" Margin="0,0,6,0"/>
                        <ComboBox Name="CmbBulkPrincipalType" Width="120" MinHeight="26"/>
                        <TextBlock Text="Role" Style="{DynamicResource LabelText}"/>
                        <ComboBox Name="CmbBulkRole" Width="130" MinHeight="26"/>
                        <Button Name="BtnBulkGrant" Content="Grant" Margin="10,0,6,0"/>
                        <Button Name="BtnBulkRevoke" Content="Remove" Style="{DynamicResource DangerButton}"/>
                      </StackPanel>
                    </StackPanel>
                  </GroupBox>

                  <GroupBox Header="Hand over access">
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                      </Grid.ColumnDefinitions>
                      <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                      </Grid.RowDefinitions>
                      <TextBlock Grid.Row="0" Grid.Column="0" Text="From" Style="{DynamicResource LabelText}" Margin="0,0,6,0"/>
                      <ComboBox Name="TxtMoveFrom" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Grid.Row="0" Grid.Column="1" MinHeight="26" VerticalContentAlignment="Center"
                                ToolTip="Who hands over - an email, a group name or an object id. Left empty: the User filter."/>
                      <TextBlock Grid.Row="0" Grid.Column="2" Text="To" Style="{DynamicResource LabelText}" Margin="10,0,6,0"/>
                      <ComboBox Name="TxtMoveTo" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Grid.Row="0" Grid.Column="3" MinHeight="26" VerticalContentAlignment="Center"
                                ToolTip="Who takes over - an email, a group name or an object id."/>
                      <TextBlock Grid.Row="1" Grid.Column="0" Text="Type" Style="{DynamicResource LabelText}" Margin="0,6,6,0"/>
                      <ComboBox Name="CmbMoveToType" Grid.Row="1" Grid.Column="1" MinHeight="26" Margin="0,6,0,0" ToolTip="What the one taking over is."/>
                      <CheckBox Name="ChkMoveGateways" Grid.Row="1" Grid.Column="2" Grid.ColumnSpan="2" Content="Gateway clusters too" IsChecked="False" VerticalAlignment="Center" Margin="10,6,0,0"
                                ToolTip="Also the roles on every gateway cluster on the Gateways tab - admin and connection creator. Off unless you tick it."/>
                      <StackPanel Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="4" Orientation="Horizontal" Margin="0,8,0,0">
                        <Button Name="BtnCopyAccess" Content="Copy access" ToolTip="To gets exactly the same roles. From keeps theirs."/>
                        <Button Name="BtnMoveAccess" Content="Move access" Style="{DynamicResource DangerButton}"
                                ToolTip="To gets exactly the same roles, then From's are removed - only where To has them by then, so nothing is left without an owner."/>
                      </StackPanel>
                    </Grid>
                  </GroupBox>

                  <GroupBox Header="Credentials">
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                      </Grid.ColumnDefinitions>
                      <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                      </Grid.RowDefinitions>
                      <TextBlock Grid.Row="0" Grid.Column="0" Text="Type" Style="{DynamicResource LabelText}" Margin="0,0,6,0"/>
                      <ComboBox Name="CmbCredType" Grid.Row="0" Grid.Column="1" MinHeight="26"/>
                      <TextBlock Grid.Row="0" Grid.Column="2" Text="Encryption" Style="{DynamicResource LabelText}"/>
                      <ComboBox Name="CmbCredEncryption" Grid.Row="0" Grid.Column="3" MinHeight="26"/>
                      <TextBlock Grid.Row="1" Grid.Column="0" Text="Username" Style="{DynamicResource LabelText}" Margin="0,6,6,0"/>
                      <ComboBox Name="TxtCredUser" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Grid.Row="1" Grid.Column="1" MinHeight="26" Margin="0,6,0,0" VerticalContentAlignment="Center"/>
                      <TextBlock Grid.Row="1" Grid.Column="2" Text="Password" Style="{DynamicResource LabelText}" Margin="10,6,6,0"/>
                      <PasswordBox Name="PwdCred" Grid.Row="1" Grid.Column="3" MinHeight="26" Margin="0,6,0,0" VerticalContentAlignment="Center"/>
                      <StackPanel Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="4" Orientation="Horizontal" Margin="0,8,0,0">
                        <Button Name="BtnBulkCredentials" Content="Update credentials"/>
                        <CheckBox Name="ChkCredRetest" Content="Test them afterwards" IsChecked="True" VerticalAlignment="Center" Margin="4,0,0,0"
                                  ToolTip="After the update, test exactly the connections that were updated, and list the ones that still fail."/>
                      </StackPanel>
                      <StackPanel Grid.Row="3" Grid.Column="0" Grid.ColumnSpan="4" Orientation="Horizontal" Margin="0,6,0,0">
                        <CheckBox Name="ChkCredPortal" Content="Like the portal - keeps the username visible" IsChecked="True" VerticalAlignment="Center"
                                  ToolTip="Updates the credentials the way the portal does, so the Account column and the portal still show the username. Not documented by Microsoft - if it is refused, the documented way is used, and the Account can then be empty."/>
                        <TextBlock Text="(unofficial)" Foreground="{DynamicResource InkFaint}" VerticalAlignment="Center" Margin="4,0,0,0"/>
                      </StackPanel>
                    </Grid>
                  </GroupBox>

                  <Button Name="BtnBulkDelete" Content="Delete all listed connections..." Style="{DynamicResource DangerButton}"
                          HorizontalAlignment="Left" Margin="0,10,0,0"/>
                </StackPanel>
              </ScrollViewer>
            </Border>
          </Grid>
        </Grid>
      </TabItem>

    </TabControl>

    <GridSplitter Name="LogSplitter" Grid.Row="2" HorizontalAlignment="Stretch" ResizeDirection="Rows" Background="Transparent"/>

    <Border Name="LogPanel" Grid.Row="3" Margin="12,0,12,0" Background="{DynamicResource LogBg}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="8">
      <DockPanel>
        <DockPanel DockPanel.Dock="Top" Margin="10,6,8,2">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
            <ComboBox Name="TxtLogFind" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Width="190" MinHeight="26"
                      ToolTip="Show only the lines containing this text."/>
            <ComboBox Name="CmbLogLevel" Width="150" MinHeight="26" Margin="6,0,10,0"/>
            <Button Name="BtnLogCopy" Content="Copy" ToolTip="Copy what is shown."/>
            <Button Name="BtnLogSave" Content="Save..."/>
            <Button Name="BtnLogFolder" Content="Open folder" ToolTip="The daily log files and the change records."/>
            <Button Name="BtnLogClear" Content="Clear" Margin="0" ToolTip="Clear the panel. The log file keeps everything."/>
          </StackPanel>
          <TextBlock Text="Activity log" Style="{DynamicResource SectionText}"/>
        </DockPanel>
        <ListBox Name="LstLog" BorderThickness="0" Background="{DynamicResource LogBg}" Foreground="{DynamicResource LogInk}"
                 Padding="6,0,6,4" FontFamily="Consolas" SelectionMode="Extended"
                 VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling" ScrollViewer.CanContentScroll="True"
                 ScrollViewer.VerticalScrollBarVisibility="Auto" ScrollViewer.HorizontalScrollBarVisibility="Auto"
                 ToolTip="Ctrl+C copies the selected lines. Right-click for more.">
          <ListBox.ItemContainerStyle>
            <Style TargetType="ListBoxItem">
              <Setter Property="Template">
                <Setter.Value>
                  <ControlTemplate TargetType="ListBoxItem">
                    <Border Name="LineBg" Background="Transparent" Padding="2,0">
                      <ContentPresenter/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="LineBg" Property="Background" Value="{DynamicResource Hover}"/>
                      </Trigger>
                      <Trigger Property="IsSelected" Value="True">
                        <Setter TargetName="LineBg" Property="Background" Value="{DynamicResource Selection}"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </Setter.Value>
              </Setter>
            </Style>
          </ListBox.ItemContainerStyle>
          <ListBox.ItemTemplate>
            <DataTemplate>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="{Binding Time, Mode=OneWay}" Foreground="{DynamicResource InkFaint}" Margin="0,0,10,0"/>
                <TextBlock Name="LineText" Text="{Binding Text, Mode=OneWay}" Foreground="{DynamicResource LogInk}"/>
              </StackPanel>
              <DataTemplate.Triggers>
                <DataTrigger Binding="{Binding Level}" Value="Ok">
                  <Setter TargetName="LineText" Property="Foreground" Value="{DynamicResource Good}"/>
                </DataTrigger>
                <DataTrigger Binding="{Binding Level}" Value="Warn">
                  <Setter TargetName="LineText" Property="Foreground" Value="{DynamicResource Warn}"/>
                </DataTrigger>
                <DataTrigger Binding="{Binding Level}" Value="Error">
                  <Setter TargetName="LineText" Property="Foreground" Value="{DynamicResource Danger}"/>
                  <Setter TargetName="LineText" Property="FontWeight" Value="SemiBold"/>
                </DataTrigger>
              </DataTemplate.Triggers>
            </DataTemplate>
          </ListBox.ItemTemplate>
        </ListBox>
      </DockPanel>
    </Border>

    <Border Grid.Row="4" Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Border}" BorderThickness="0,1,0,0" Padding="14,5" Margin="0,8,0,0">
      <DockPanel>
        <StackPanel Name="MeterPanel" DockPanel.Dock="Right" Orientation="Horizontal" Margin="18,0,0,0">
          <TextBlock Name="TxtMeter" Foreground="{DynamicResource InkFaint}" VerticalAlignment="Center"
                     ToolTip="GatewayLens itself: its share of the CPU, the memory it uses, its background workers and threads - and the calls it made to Microsoft this session, with how many Microsoft slowed down (throttled)."/>
          <Button Name="BtnErrors" Visibility="Collapsed" Margin="10,0,0,0" MinHeight="22" Padding="10,1" Style="{DynamicResource DangerButton}"
                  ToolTip="Show only the errors in the activity log"/>
        </StackPanel>
        <Button Name="BtnCancel" DockPanel.Dock="Right" Content="Cancel" Visibility="Collapsed" Margin="10,0,0,0" MinHeight="22" Padding="10,1"/>
        <ProgressBar Name="Busy" DockPanel.Dock="Right" Width="180" Height="8" Visibility="Collapsed"/>
        <TextBlock Name="TxtStatus" Text="Ready" Foreground="{DynamicResource InkMuted}" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@

$script:StartXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="GatewayLens" Width="500" SizeToContent="Height" ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource WindowBg}"
        FontFamily="Segoe UI" FontSize="12" Foreground="{DynamicResource Ink}">
  <StackPanel Margin="36,30,36,20">
    <Image Name="StartLogo" Width="72" Height="72" HorizontalAlignment="Center" RenderOptions.BitmapScalingMode="HighQuality"/>
    <TextBlock Text="GatewayLens" FontSize="28" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,12,0,0"/>
    <TextBlock Text="The missing admin console for Power BI and Fabric data gateways" Foreground="{DynamicResource InkMuted}"
               HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" Margin="0,4,0,24"/>

    <TextBlock Text="Work account (optional)" Foreground="{DynamicResource InkMuted}" Margin="0,0,0,4"/>
    <TextBox Name="StartAccount" MinHeight="32" VerticalContentAlignment="Center" Padding="6,0"
             ToolTip="Leave it empty to choose in the browser, or type the account to sign in with - an admin account, for example."/>
    <Button Name="StartSignIn" Content="Sign in" Style="{DynamicResource PrimaryButton}" MinHeight="38" FontSize="14" Margin="0,12,0,0" IsDefault="True"/>
    <TextBlock Name="StartHow" Foreground="{DynamicResource InkFaint}" TextAlignment="Center" TextWrapping="Wrap" Margin="0,8,0,0"/>

    <Border Name="StartBusy" Visibility="Collapsed" Margin="0,14,0,0" Padding="12,10" CornerRadius="8" Background="{DynamicResource AccentSoft}">
      <StackPanel>
        <TextBlock Name="StartBusyText" Text="Finish signing in in your browser - this window waits for it." TextWrapping="Wrap"/>
        <ProgressBar IsIndeterminate="True" Height="4" Margin="0,8,0,0"/>
      </StackPanel>
    </Border>
    <Border Name="StartError" Visibility="Collapsed" Margin="0,14,0,0" Padding="12,10" CornerRadius="8" Background="{DynamicResource DangerSoft}">
      <TextBlock Name="StartErrorText" TextWrapping="Wrap"/>
    </Border>

    <Grid Margin="0,22,0,0">
      <Border Height="1" Background="{DynamicResource Border}" VerticalAlignment="Center"/>
      <TextBlock Text="  or  " HorizontalAlignment="Center" Background="{DynamicResource WindowBg}" Foreground="{DynamicResource InkFaint}"/>
    </Grid>
    <Button Name="StartDemo" Content="Try the demo - a fictional company, no sign-in" MinHeight="32" Margin="0,14,0,0"/>

    <TextBlock Text="Signs in as you - it can do what you can do in the portal, nothing more. Nothing is installed, and nothing is sent anywhere but Microsoft."
               Foreground="{DynamicResource InkFaint}" TextAlignment="Center" TextWrapping="Wrap" Margin="0,22,0,0"/>
    <DockPanel Margin="0,14,0,0">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button Name="StartHelp" Content="Help" Padding="10,2" MinHeight="24"/>
        <Button Name="StartGitHub" Content="GitHub" Padding="10,2" MinHeight="24" Margin="0"/>
      </StackPanel>
      <TextBlock Name="StartVersion" Foreground="{DynamicResource InkFaint}" VerticalAlignment="Center"/>
    </DockPanel>
  </StackPanel>
</Window>
'@

$script:AlertsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Alerts" Width="600" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="{DynamicResource WindowBg}"
        FontFamily="Segoe UI" FontSize="12" Foreground="{DynamicResource Ink}">
  <StackPanel Margin="22,18,22,16">
    <TextBlock Text="Tell me when a gateway member goes down" FontSize="17" FontWeight="SemiBold"/>
    <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource InkMuted}" Margin="0,6,0,14"
               Text="A member counts as down when it is not online two checks in a row - one slow answer wakes nobody - and you hear when it is back. Alerts come while GatewayLens is open with auto-refresh on: on a wall screen in kiosk view, or on your own PC. Whatever you choose, the taskbar button turns yellow while a gateway is degraded and red while one is offline."/>
    <CheckBox Name="AlDesktop" Content="Show a Windows notification" Margin="0,3"/>
    <CheckBox Name="AlSound" Content="Play a sound" Margin="0,3"/>
    <CheckBox Name="AlWebhook" Content="Post to a Teams channel, or start a Power Automate flow" Margin="0,3"/>
    <TextBox Name="AlUrl" MinHeight="28" Margin="24,6,0,0" VerticalContentAlignment="Center" Padding="4,0"
             ToolTip="The address of a Teams workflow or a Power Automate flow - it ends in logic.azure.com or api.powerplatform.com."/>
    <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource InkFaint}" Margin="24,6,0,0"
               Text="In Teams: on the channel, ... > Workflows > Post to a channel when a webhook request is received, and copy the address it gives you. A Power Automate flow started the same way can also send an email or open a ticket. The address is kept encrypted for your Windows account, and nothing else is sent anywhere."/>
    <StackPanel Orientation="Horizontal" Margin="24,8,0,0">
      <Button Name="AlTest" Content="Send a test"/>
      <TextBlock Name="AlTestResult" VerticalAlignment="Center" Foreground="{DynamicResource InkMuted}" TextWrapping="Wrap" Margin="6,0,0,0"/>
    </StackPanel>
    <TextBlock Name="AlError" Visibility="Collapsed" TextWrapping="Wrap" Foreground="{DynamicResource Danger}" Margin="0,12,0,0"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button Name="AlCancel" Content="Cancel" IsCancel="True" MinWidth="80"/>
      <Button Name="AlOk" Content="Save" Style="{DynamicResource PrimaryButton}" IsDefault="True" MinWidth="80" Margin="0"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

$script:InfoXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="GatewayLens" Width="600" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="{DynamicResource WindowBg}"
        FontFamily="Segoe UI" FontSize="12" Foreground="{DynamicResource Ink}">
  <StackPanel Margin="22,18,22,16">
    <DockPanel Margin="0,0,0,14">
      <Image Name="InfoLogo" Width="44" Height="44" Margin="0,0,14,0" DockPanel.Dock="Left" RenderOptions.BitmapScalingMode="HighQuality"/>
      <StackPanel VerticalAlignment="Center">
        <TextBlock Name="InfoTitle" FontSize="19" FontWeight="SemiBold"/>
        <TextBlock Name="InfoSub" Foreground="{DynamicResource InkMuted}" TextWrapping="Wrap" Margin="0,2,0,0"/>
      </StackPanel>
    </DockPanel>
    <ItemsControl Name="InfoLines">
      <ItemsControl.ItemTemplate>
        <DataTemplate>
          <DockPanel Margin="0,3">
            <TextBlock Text="-" DockPanel.Dock="Left" Margin="0,0,8,0" FontWeight="Bold" Foreground="{DynamicResource Accent}"/>
            <TextBlock Text="{Binding}" TextWrapping="Wrap"/>
          </DockPanel>
        </DataTemplate>
      </ItemsControl.ItemTemplate>
    </ItemsControl>
    <WrapPanel Name="InfoLinks" Margin="0,16,0,0"/>
    <Button Name="InfoClose" Content="Close" HorizontalAlignment="Right" Style="{DynamicResource PrimaryButton}" Margin="0,8,0,0" MinWidth="90" IsDefault="True" IsCancel="True"/>
  </StackPanel>
</Window>
'@

$script:DialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Add access" Width="470" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="{DynamicResource WindowBg}"
        FontFamily="Segoe UI" FontSize="12" Foreground="{DynamicResource Ink}">
  <StackPanel Margin="18">
    <TextBlock Name="DlgTarget" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,14"/>
    <TextBlock Text="User, group or service principal" Margin="0,0,0,4"/>
    <TextBox Name="DlgPrincipal" Height="28" VerticalContentAlignment="Center"/>
    <TextBlock Name="DlgHint" Foreground="{DynamicResource InkMuted}" FontSize="11" TextWrapping="Wrap" Margin="0,4,0,14"/>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="12"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0">
        <TextBlock Text="Principal type" Margin="0,0,0,4"/>
        <ComboBox Name="DlgType" Height="26"/>
      </StackPanel>
      <StackPanel Grid.Column="2">
        <TextBlock Text="Role" Margin="0,0,0,4"/>
        <ComboBox Name="DlgRole" Height="26"/>
      </StackPanel>
    </Grid>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button Name="DlgOk" Content="Add" IsDefault="True" MinWidth="80" Height="28" Margin="0,0,8,0"
              Style="{DynamicResource PrimaryButton}"/>
      <Button Name="DlgCancel" Content="Cancel" IsCancel="True" MinWidth="80" Height="28"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

$script:PromptXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Confirm" Width="480" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="{DynamicResource WindowBg}"
        FontFamily="Segoe UI" FontSize="12" Foreground="{DynamicResource Ink}">
  <StackPanel Margin="18">
    <TextBlock Name="PrmMessage" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <TextBlock Name="PrmAsk" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,6"/>
    <TextBox Name="PrmInput" Height="26" VerticalContentAlignment="Center"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button Name="PrmOk" Content="Continue" IsDefault="True" MinWidth="90" Height="28" Margin="0,0,8,0"
              Style="{DynamicResource DangerFilledButton}"/>
      <Button Name="PrmCancel" Content="Cancel" IsCancel="True" MinWidth="80" Height="28"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

# The look. Loaded after the window, inside a try: if anything in it is wrong, the
# classic dictionary is used instead and the window still opens.
$script:ModernStylesXaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">

  <!-- ===== buttons: one template, an overlay for hover / press works on any background ===== -->
  <Style TargetType="Button">
    <Setter Property="Background" Value="{DynamicResource Surface}"/>
    <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource BorderStrong}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="12,4"/>
    <Setter Property="Margin" Value="0,0,6,0"/>
    <Setter Property="MinHeight" Value="28"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="SnapsToDevicePixels" Value="True"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Grid>
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7"/>
            <Border x:Name="Overlay" Background="{DynamicResource Ink}" Opacity="0" CornerRadius="7"/>
            <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"
                              RecognizesAccessKey="True"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Overlay" Property="Opacity" Value="0.06"/>
            </Trigger>
            <Trigger Property="IsPressed" Value="True">
              <Setter TargetName="Overlay" Property="Opacity" Value="0.13"/>
            </Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter Property="Opacity" Value="0.45"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="{DynamicResource Accent}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Accent}"/>
    <Setter Property="Foreground" Value="{DynamicResource AccentInk}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>

  <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Foreground" Value="{DynamicResource Danger}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Danger}"/>
  </Style>

  <Style x:Key="DangerFilledButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="{DynamicResource Danger}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Danger}"/>
    <Setter Property="Foreground" Value="{DynamicResource AccentInk}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>

  <Style x:Key="KioskButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Accent}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>

  <!-- ===== splitters: a small grip in the middle shows there is something to drag ===== -->
  <Style TargetType="GridSplitter">
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="GridSplitter">
          <Border Background="Transparent">
            <Border Name="Grip" Background="{DynamicResource BorderStrong}" CornerRadius="2" Width="48" Height="4"
                    HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="ResizeDirection" Value="Columns">
              <Setter TargetName="Grip" Property="Width" Value="4"/>
              <Setter TargetName="Grip" Property="Height" Value="48"/>
            </Trigger>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Grip" Property="Background" Value="{DynamicResource Accent}"/>
            </Trigger>
            <Trigger Property="IsDragging" Value="True">
              <Setter TargetName="Grip" Property="Background" Value="{DynamicResource Accent}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- ===== text ===== -->
  <Style x:Key="LabelText" TargetType="TextBlock">
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="Foreground" Value="{DynamicResource InkMuted}"/>
    <Setter Property="Margin" Value="12,0,6,0"/>
  </Style>

  <Style x:Key="SectionText" TargetType="TextBlock">
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
  </Style>

  <Style TargetType="TextBox">
    <Setter Property="Background" Value="{DynamicResource InputBg}"/>
    <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource BorderStrong}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CaretBrush" Value="{DynamicResource Ink}"/>
    <Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/>
    <Setter Property="Padding" Value="8,2"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" SnapsToDevicePixels="True">
            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" Focusable="False"
                          VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter TargetName="Bd" Property="Opacity" Value="0.5"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="PasswordBox">
    <Setter Property="Background" Value="{DynamicResource InputBg}"/>
    <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource BorderStrong}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CaretBrush" Value="{DynamicResource Ink}"/>
    <Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/>
    <Setter Property="Padding" Value="8,2"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="PasswordBox">
          <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" SnapsToDevicePixels="True">
            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" Focusable="False"
                          VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- ===== check box ===== -->
  <Style TargetType="CheckBox">
    <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <StackPanel Orientation="Horizontal" Background="Transparent">
            <Border x:Name="Box" Width="17" Height="17" CornerRadius="5" BorderThickness="1.5" VerticalAlignment="Center"
                    BorderBrush="{DynamicResource BorderStrong}" Background="{DynamicResource InputBg}">
              <Path x:Name="Mark" Data="M 3.5,8 L 6.5,11 L 12,4.5" Stroke="{DynamicResource AccentInk}" StrokeThickness="2"
                    StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
            </Border>
            <ContentPresenter Margin="7,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True"/>
          </StackPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Box" Property="Background" Value="{DynamicResource Accent}"/>
              <Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource Accent}"/>
              <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource Accent}"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter Property="Opacity" Value="0.5"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- ===== combo box, plain and editable ===== -->
  <ControlTemplate x:Key="ComboToggle" TargetType="ToggleButton">
    <Border x:Name="Bd" Background="{DynamicResource InputBg}" BorderBrush="{DynamicResource BorderStrong}"
            BorderThickness="1" CornerRadius="7" SnapsToDevicePixels="True">
      <Path x:Name="Arrow" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"
            Data="M 0,0 L 4.5,4.5 L 9,0" Stroke="{DynamicResource InkMuted}" StrokeThickness="1.6"
            StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
      </Trigger>
      <Trigger Property="IsChecked" Value="True">
        <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
      </Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate>

  <Style TargetType="ComboBox">
    <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
    <Setter Property="SnapsToDevicePixels" Value="True"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="MaxDropDownHeight" Value="320"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ComboBox">
          <Grid>
            <ToggleButton x:Name="ToggleButton" Template="{StaticResource ComboToggle}" Focusable="False" ClickMode="Press"
                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
            <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False" Margin="10,0,28,0"
                              VerticalAlignment="Center" HorizontalAlignment="Left"
                              Content="{TemplateBinding SelectionBoxItem}"
                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                              ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"/>
            <TextBox x:Name="PART_EditableTextBox" Visibility="Hidden" Margin="3,0,26,0" VerticalAlignment="Center"
                     Focusable="True" Background="Transparent" BorderThickness="0"
                     Foreground="{DynamicResource Ink}" CaretBrush="{DynamicResource Ink}"
                     IsReadOnly="{Binding IsReadOnly, RelativeSource={RelativeSource TemplatedParent}}">
              <TextBox.Template>
                <ControlTemplate TargetType="TextBox">
                  <ScrollViewer x:Name="PART_ContentHost" Focusable="False" Margin="7,0,0,0"/>
                </ControlTemplate>
              </TextBox.Template>
            </TextBox>
            <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade"
                   IsOpen="{TemplateBinding IsDropDownOpen}">
              <Border x:Name="DropDown" Margin="0,4,0,0" Padding="4" CornerRadius="8"
                      MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                      MaxHeight="{TemplateBinding MaxDropDownHeight}"
                      Background="{DynamicResource Surface}" BorderBrush="{DynamicResource BorderStrong}" BorderThickness="1">
                <ScrollViewer SnapsToDevicePixels="True">
                  <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                </ScrollViewer>
              </Border>
            </Popup>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsEditable" Value="True">
              <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
              <Setter TargetName="ContentSite" Property="Visibility" Value="Hidden"/>
            </Trigger>
            <Trigger Property="HasItems" Value="False">
              <Setter TargetName="DropDown" Property="Visibility" Value="Collapsed"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter Property="Opacity" Value="0.5"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="ComboBoxItem">
    <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
    <Setter Property="Padding" Value="8,5"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ComboBoxItem">
          <Border x:Name="Bd" Background="Transparent" CornerRadius="5" Padding="{TemplateBinding Padding}">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsHighlighted" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Hover}"/>
            </Trigger>
            <Trigger Property="IsSelected" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentSoft}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- ===== tabs: flat, an accent line under the selected one ===== -->
  <Style TargetType="TabControl">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TabControl">
          <DockPanel>
            <Border DockPanel.Dock="Top" BorderBrush="{DynamicResource Border}" BorderThickness="0,0,0,1">
              <TabPanel IsItemsHost="True" Background="Transparent"/>
            </Border>
            <ContentPresenter ContentSource="SelectedContent" Margin="0,6,0,0"/>
          </DockPanel>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="TabItem">
    <Setter Property="Foreground" Value="{DynamicResource InkMuted}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TabItem">
          <Grid Margin="0,0,4,0">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="7,7,0,0" Padding="16,9">
              <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <Border x:Name="Line" Height="3" VerticalAlignment="Bottom" Margin="10,0" CornerRadius="2"
                    Background="{DynamicResource Accent}" Visibility="Hidden"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Hover}"/>
            </Trigger>
            <Trigger Property="IsSelected" Value="True">
              <Setter TargetName="Line" Property="Visibility" Value="Visible"/>
              <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
              <Setter Property="FontWeight" Value="SemiBold"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- ===== grids ===== -->
  <Style TargetType="DataGrid">
    <Setter Property="Background" Value="{DynamicResource Surface}"/>
    <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="RowBackground" Value="{DynamicResource Surface}"/>
    <Setter Property="AlternatingRowBackground" Value="{DynamicResource SurfaceAlt}"/>
    <Setter Property="HorizontalGridLinesBrush" Value="{DynamicResource Border}"/>
    <Setter Property="VerticalGridLinesBrush" Value="{DynamicResource Border}"/>
    <Setter Property="GridLinesVisibility" Value="Horizontal"/>
    <Setter Property="HeadersVisibility" Value="Column"/>
    <Setter Property="ColumnHeaderHeight" Value="34"/>
    <Setter Property="RowHeight" Value="28"/>
  </Style>

  <Style TargetType="DataGridColumnHeader">
    <Setter Property="Background" Value="{DynamicResource Header}"/>
    <Setter Property="Foreground" Value="{DynamicResource InkMuted}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Padding" Value="10,0"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
    <Setter Property="BorderThickness" Value="0,0,1,1"/>
    <Setter Property="HorizontalContentAlignment" Value="Left"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="DataGridColumnHeader">
          <Grid>
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}">
              <DockPanel>
                <Path x:Name="SortArrow" DockPanel.Dock="Right" Width="8" Height="5" Margin="6,0,0,0" Stretch="Fill"
                      VerticalAlignment="Center" Data="M0,0 L1,0 0.5,1 Z" Fill="{DynamicResource InkMuted}"
                      Visibility="Collapsed" RenderTransformOrigin="0.5,0.5"/>
                <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                  VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
              </DockPanel>
            </Border>
            <Thumb x:Name="PART_RightHeaderGripper" HorizontalAlignment="Right" Width="6" Cursor="SizeWE" Opacity="0"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="SortDirection" Value="Ascending">
              <Setter TargetName="SortArrow" Property="Visibility" Value="Visible"/>
              <Setter TargetName="SortArrow" Property="RenderTransform">
                <Setter.Value>
                  <RotateTransform Angle="180"/>
                </Setter.Value>
              </Setter>
            </Trigger>
            <Trigger Property="SortDirection" Value="Descending">
              <Setter TargetName="SortArrow" Property="Visibility" Value="Visible"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="DataGridRow">
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource Hover}"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style TargetType="DataGridCell">
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Padding" Value="10,0"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="DataGridCell">
          <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
            <ContentPresenter VerticalAlignment="Center"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsSelected" Value="True">
        <Setter Property="Background" Value="{DynamicResource Selection}"/>
        <Setter Property="Foreground" Value="{DynamicResource SelectionInk}"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <!-- ===== slim scroll bars ===== -->
  <Style x:Key="ScrollThumb" TargetType="Thumb">
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Thumb">
          <Border CornerRadius="4" Background="{DynamicResource BorderStrong}"/>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="ScrollPage" TargetType="RepeatButton">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="IsTabStop" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RepeatButton">
          <Border Background="Transparent"/>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="ScrollBar">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Width" Value="11"/>
    <Setter Property="MinWidth" Value="11"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" IsDirectionReversed="True" Margin="2">
            <Track.DecreaseRepeatButton>
              <RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageUpCommand"/>
            </Track.DecreaseRepeatButton>
            <Track.Thumb>
              <Thumb Style="{StaticResource ScrollThumb}"/>
            </Track.Thumb>
            <Track.IncreaseRepeatButton>
              <RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageDownCommand"/>
            </Track.IncreaseRepeatButton>
          </Track>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="Orientation" Value="Horizontal">
        <Setter Property="Width" Value="Auto"/>
        <Setter Property="MinWidth" Value="0"/>
        <Setter Property="Height" Value="11"/>
        <Setter Property="MinHeight" Value="11"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Track x:Name="PART_Track" IsDirectionReversed="False" Margin="2">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageLeftCommand"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Style="{StaticResource ScrollThumb}"/>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageRightCommand"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Trigger>
    </Style.Triggers>
  </Style>

  <!-- ===== progress, group box, tool tip ===== -->
  <Style TargetType="ProgressBar">
    <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
    <Setter Property="Background" Value="{DynamicResource Border}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ProgressBar">
          <Grid>
            <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="4"/>
            <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="4" HorizontalAlignment="Left"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsIndeterminate" Value="True">
              <Trigger.EnterActions>
                <BeginStoryboard x:Name="Pulse">
                  <Storyboard RepeatBehavior="Forever" AutoReverse="True">
                    <DoubleAnimation Storyboard.TargetName="PART_Indicator" Storyboard.TargetProperty="Opacity"
                                     From="1" To="0.3" Duration="0:0:0.8"/>
                  </Storyboard>
                </BeginStoryboard>
              </Trigger.EnterActions>
              <Trigger.ExitActions>
                <StopStoryboard BeginStoryboardName="Pulse"/>
              </Trigger.ExitActions>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="GroupBox">
    <Setter Property="Margin" Value="0,10,0,0"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="GroupBox">
          <Border BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="9" Padding="12,9">
            <DockPanel>
              <ContentPresenter DockPanel.Dock="Top" ContentSource="Header" Margin="0,0,0,7"
                                TextElement.FontWeight="SemiBold" TextElement.Foreground="{DynamicResource InkMuted}"/>
              <ContentPresenter/>
            </DockPanel>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="ToolTip">
    <Setter Property="Background" Value="{DynamicResource Surface}"/>
    <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource BorderStrong}"/>
    <Setter Property="Padding" Value="9,7"/>
    <Setter Property="MaxWidth" Value="440"/>
    <Setter Property="ContentTemplate">
      <Setter.Value>
        <DataTemplate>
          <TextBlock Text="{Binding}" TextWrapping="Wrap"/>
        </DataTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>
'@

$script:ClassicStylesXaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <!-- The fallback: standard Windows controls, theme colours where it is safe. -->
  <Style x:Key="PrimaryButton" TargetType="Button">
    <Setter Property="Background" Value="{DynamicResource Accent}"/>
    <Setter Property="Foreground" Value="{DynamicResource AccentInk}"/>
    <Setter Property="Padding" Value="12,3"/>
    <Setter Property="Margin" Value="0,0,6,0"/>
  </Style>
  <Style x:Key="DangerButton" TargetType="Button">
    <Setter Property="Foreground" Value="{DynamicResource Danger}"/>
    <Setter Property="Padding" Value="12,3"/>
    <Setter Property="Margin" Value="0,0,6,0"/>
  </Style>
  <Style x:Key="DangerFilledButton" TargetType="Button">
    <Setter Property="Background" Value="{DynamicResource Danger}"/>
    <Setter Property="Foreground" Value="{DynamicResource AccentInk}"/>
  </Style>
  <Style x:Key="KioskButton" TargetType="Button">
    <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Padding" Value="12,3"/>
    <Setter Property="Margin" Value="0,0,6,0"/>
  </Style>
  <Style TargetType="Button">
    <Setter Property="Padding" Value="12,3"/>
    <Setter Property="Margin" Value="0,0,6,0"/>
  </Style>
  <Style x:Key="LabelText" TargetType="TextBlock">
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="Foreground" Value="{DynamicResource InkMuted}"/>
    <Setter Property="Margin" Value="12,0,6,0"/>
  </Style>
  <Style x:Key="SectionText" TargetType="TextBlock">
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
  </Style>
  <Style TargetType="DataGrid">
    <Setter Property="AlternatingRowBackground" Value="{DynamicResource SurfaceAlt}"/>
    <Setter Property="GridLinesVisibility" Value="Horizontal"/>
    <Setter Property="HeadersVisibility" Value="Column"/>
    <Setter Property="RowHeight" Value="26"/>
  </Style>
</ResourceDictionary>
'@

# 64x64 PNG, the same artwork as assets/GatewayLens.ico
$script:IconPng = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAQW0lEQVR42t2be5AV1ZnAf9853fc5d2YYhqfiiohANIYEMWjMRowSsihJJIOpsmqr8k5trBU3SdVWZbPK7lp5x5RWamPcGHerNFWgsYxllvVF4mtN1hBRFFQM6KCDDMz7Prv7fPtH9713kJHXDMmES03dmT706f595/vO9+oWxvyodHVhNm6UCGDlmr3nGjWrHeFyVBc6dBpGfUVBQIVDvlU0mWmsMUAU5TBjwiHnN39PrsvoMQlU6MWYHWLsZoz+8g/fnPMcQFeX2o0bcZDc1KiPvP3A9derWb9eHMDfrO5eLiZ9nSO6zHqZjCPCaYAjZHLBAyJgDWJ9sJYorFSw5iFceNPWb87dHMOpIWEbUwBdXRvsxo1ro0svfaYtlT/1B8b6nxHjEYTDOFyExP80/j5++HcE1OYxjgW+fl1VFVQFxRhr0i0oEc7Vbi++1fsPf/zJeYN0bbBsXBsdIoA6/IoVr5zpZVvv9f38OdVan4snE3t0gH9G+PrfNMdUNAIVm+8wUa20zdUGP/Hit87ZOVoIMlrtV658bZ5NZTYbLzUnCIcDjPhHDzi54Bk1t0MDmyn4kat1S62y/IUbz3q1bg6mfurq1b0FSXn3x/BD4ckCrwJixA+rQ6HxUnOc792/4NvbC/EJKqarC7N+vbiaK96cSrUvqoXDAcZ4Jwt8/W+xxgurw4HJtS+Ssr2Z9eK6NmIEYOXlb1zkpbKPh1EpRPSkgz9oDkNoUlkvCioffPkb854wAJjw62KsKk5OZnhEQZ1gPVWNvg4gH7nitbPFeFsQ9ZPJ5UTB1wH+XPDJmKoIaiRwoXufEZE1np9LOZybMPjkwmLAWjA2/l2TMREwBqwniE180Z8GHhVEcc6kcymxusbDsNwRTejKGxPfQDlQKoEiBvwUpHwBA9VIqVaVUMH3IJMxWKtEesLh63OIagTCcs/BQjRIBDAOeGJQBIZKDusJ8+b4nLcoy7vmpjh1ukdr3mIMFCuOvf0RL+2p8swrFZ7fXaG/6MhnDb4HoZ5Q+FgLXICKLpQVV3YHCN544Y0H5Vq8ih9akmPtpQWWLMzgWeFIn509Ne59aphfPD1MXzGiLW8JVU8U/KhjLpQVa7p1XIkNivVgoOg4Y06Kr1zdwYXnZgFwSe5lDiODyCk2+Q+v9wZ8774+frVlhNYWAyjuhMA3eeWyNa/reOH7RhyXLctz/ec7KeQMYaSNlQ8jZffegO7ekP7hiEihkBNmT/WYOzNFIRt74iBUfC8+56ePDPCdX+4nmzGIgOPEwKuANxHwV15S4PrPdx4EMlh0bPrtCE9sK/HmgZBqqDiaN+F5QkfB8t4zM6xa2sL8WSlUY4347Ifb6WyzfO3OfeQy0kjZJhoeAbm061ANOFqbHyo5PrA4x81fnYEqqMZu77GtJe7YNMjegZBMSkj50tgg6zfhFIIIyoEjnRIuP7/Ap5e34VlpCPGOxwa44Rf7mdIS7wkTDa+APeOc6244VlcnBmqh0tnhccvXZpBNG5zGan/Xw4Pc9sAgDshnTMMlOsDFZRRc4u6MhUzaYD1hy64yO96scf6ZWbLp2IyWzM2ya3/A1u4K2TSjNGhi4BEwxxXkWCjVlGs/1UFHq23Y/N2/HuI/HhhEUcpVRyVwB89dvzBNiECVwUqI58Fvthf5t1/0EoSKSbTk66unMrVgqEU64fAqijnWIEcsFCvK4gUZVizLE0axum7dWeG2BwZYuijDNZ/o4HOr2pnaZqlFirGx1ojEP5h6ZAiK8sllrVy3qpOuZa08+UqJnz02gDVC5JTprR5XX9jGUNVhrEwoPALescb2dfW/cnkBk4wHoXLr/QOcMTvFv35mGqlkN1+6MMu6H+9luKINU2hsPgaKtYivru5k1ftaALjs3DyZtOHOpwb58Nl55s2IN8arzm/jjv8dpBYpYusQ44fXWABHD4+BWgidHZaL3pONNz0j/HZ7mW2vVVm3pgPfE2ph7Ptnd3h8dmU7O/bUyKQktv1kLoeS9oWVi1twDiJVjAgfXdzCXb8b5O5nhvjHVZ1Eqsxu91g6N8OD24u0+oZIJwY+doPHkNUZA5Wq470Ls0xts0QOrMBvtpbwrdA7GCKAZ2PPVQuV53dX2XMgxPdHaUD9ZlC6DwT8VaePANbAvqEQ34Mtr5fpL0W05ywKXDgvx69eLI6dLB0nfMMEjjalRYTAwfzTUo0Ir1Rx7HyjxpSC4dGtJd49L8MFC7NIYhrP7qqwfzjC9yUJaOKbMAZGqo4DIxGnT/PxROjuC/jp4/1kUoa+kuOlvTWWnRFHlQtnpfG9WHMmCn7MQOhI+TyizOr04kUU2DcYMViKsL4QqfLdu/dz6jSfae0e/3RVJ9eu7uCff95LJm2IcCCCZ6C/5Fh7QRtL5mb4z8cHeOrVMn3FkKGqI5cWioHyel/QEMDMVksuLUSjN8FxwsMhbvDwlRwVBQOFnGnE8iNlR+BorKrvCd37A379fJHbHx5g6fwsq5YW6C+FcW1AoFhVTp/u84VL2tmyu8J/PTnI7v01ymG8LziN5xssN8r35FOG1KixccGPcsXm2MpYB/vyuhnIqHMdsRA62yz3PD3Ms7srfGlFO6fP8BkqOaqhEgl89fKpBBF8f9MB0inIZiSO+7VZIJGmnJNAKt6IkXHCj2Iyx1bDi1VwoNhcmda8xfeThOVtN+t58MMH+ggdfOXyqczu8JlSsPztB9tYMCvNzQ8doGcwIJUSQte8ufq1O/JeU9OqjkqkyFEDHhlem5vgURYwJb6B13vDpKwO09os7a2W3sEo2aSa0Vo6JbzRH/Cj/+njK5dP5dbPz4qPe8IjLxbZtG2EtrwhdKP6VIkWeVaY2+k3BLBnIKAUOApZE1eOJgA+MQE9yCYOV71VwPOFl7qrDQGkfWHBqSmqoWtEd43iJ3EAlPEFVfCtkErS5FySJI1WeZIoMXDK9FbLWdPjQAjg+b1Vak4nbOXrY+aIXdpRE0QKmbSw440ae/YHDRv98HvyY9pl7CmED70r38gA68eXnpFlZptHNVHr+vnGQDFQPnBGjnwqTrIAHv9jiZQnh7rBccAftAkebd3eWugvRjz0hyKSFDwWz82weF6G4api7KiWq8QR3kApQpIsMHLxd6mmFGsO+7ZNLXDQmjWsWdyKKhgRXtpX4/dvlMmlpWliEwA/RjZ45KZFhJLNCBufHKZS00aC88UVU8ikIHRxJleP+jxPuPv/hqiGim/BM7Hn2PjMEAdKEZ4njTTXWhisRHx6WTuz2zxCF8//s2cGGA6SZGgC4RWwpy1Zd8Oxdmx83/BGX0h7i2HJvCy1UJlasMxs93j0hSKeFayNTcb3hDcHQ7a8VkZE6BkMuet3g9z/3DC5tMHR7B/0jkR8/D0FvnDhFIJI8a3wu+4y33hwH4WMIWJi4RGtZ4PH1q6KVCnkDT/6734+eHaO+bNSBKFy8dl5IoUfbjpAuabkMzFgLi28vK/Gtk37Y/8u0JIxsUkZoRo5ihWl632trLt4Ki5Jskaqjl19Aa0Zw2DVkU2ZuFo8QfAqIBd8YbceT6/OWCjWlHkzfe5cdwqtWdMoZb28t8aPH+1na3cFMUrKF3wrGCON82uRUnVKLVJmtXl8elk7H31XC06TwAo4UIzozFue7alw1c/3UAwdGV8INenzjRM+FsAXd+nx9uqshYFyxPnzs/z752bRmjXUQm3UA554pcTDL46wY2+N/nJE6OLVs1bIZwyndfj89Zk5LlvUQlvGEDrFM7HLdBqXyyONM84tb1b41IY9FANHJiVJjXB88AjIsi/t0mN/IKnZ5/M8YaAcsejUNN+7egYLkupuHQBguOLoGQwZKEWx+WQs0wuW6YVmpFeHr4bK/mLIrFY/3mBHjW3pqXDVxu5YCL4hRMcFr3UBHA/86Pqc5wnDVUc+Y7hmxRSuvqCNjC9J4yPO88duihw8tumlER7YPsxNq2c2NKFuDk0hlFl79x5GQke2YQ7HB4+APWXpuhvG06KOXSNJPK88+EKRR7YXCZwyrWBpz9l37AoZgaGK49GdRdY/2MstT/WxpadCX8WxYn5LI0IVieOB0CmntPp84LQc9708TDFSUp5J3Oixw6uAvP/vYg2YiP68iCJWKAWOSuIazzklzdmnpDl9qk9H3mJEGKpG7BkMefGtKlt7Krw2EIAohYxBjPBWMeSzS6fw/Y/OIIl+D9GE3+8t03VvXRPe3lA9OngAOf/Lo01g/P35ejgrItScUg4dgWu2zTFxfOBQjBUyKSHtxefV/bxnhX3FkM+cN4UfrDy8ED55XzcjgSOb7AnHAq+iyNJrdumJejiBeincKCqC0kyr6/NGSbPk7e7Ms8JbpYDPLZnCDz4y852F8FaZNfd1J5pgCFQblasjwY/KBU7QA0nEgKFCqEpIvPqhauNH3yG2D9QxvcXjtj/0c92De5vhdbIveCbeE5bMyHL3x+aQTxlKkcPaJtyR4JNc4E/yWMpx1fAC1VgIz/az7qFECHqoEM6bkeWeK+aQSxnKUZxgHQ18UwMmIXx9LFBlWovHbVv7ufbhwwvh3svnkPMNpShpxBwB/pB6wGSDr4+FTpmW9/jJc31c+0jPOwthepZ7V51GS8oQJDHE4eDHKIpOPvj6sVAd0/Metz7fz99vHlsIgVOWTs/yL++fznAQxbnHYeCB0dng5IWvzx2oxkJ4rh8VuOXiWY3HcETASpw7fGh2nta0jT2CGfvdhIYGKBoiMunhGxWjuhCe7+ea3/Q0vEPolMApVmBfOaIUOYzRZhtODm2oKBoaFd0fB+Sqkx3+YCFYbt3Wx5cf60EkNoG0jc3gm1t7cYfpBqmoYi0I+z2M7BDPn+mCIM6yJzl8PcILFKblPH66vZ9Xh2t0zWslVPj5qwM83VuiJfW2CtJBm6Eqvi9aDXZ4TnSzMfZiFcZ4WmxywtfHQpT2jOHxniIPvzmCCqQ9KBwWnjhpsQYMm42I3hMFpRrGmIOFMLnh62MRkE8bpmYtnVlL3j8SPKpGjNbKNVW5x2z9zvwXnEaPmkwBFXV/SfD1b5eE14HqkeBRUUe+BY3CR4tdZ79gkubFjaqRxPnsXxb8kfz8oWNGcZGIlRsBTFeX2ue+Pe+JsDp0h81N8RwanLTwaEBbu6elkTtGrjznCTaojd+yuwFZUNqRt5n0b20qtyisDoVijaecRPCqIS0Fz9VK27Pw/gMfW1gE1CDxU1IvfXfRsLjwiiiqddtsq+dUg5Nq5VsKnobV7siFVxz4+KJhboi9QVySXC+Org32hRvPepXK0CUuCrbZlg5fxTlFo79YeDQCdbRN8V1Y2xZWhi+pXvnuV9mwwdZfoW3WZDeujejaYF/81jk7K8W3Loqqw7ebdN6YXKtNqjkRqFNRncTwqqIO0UiNIC2tlmzeaHnk9lLP7ouqa5fsZMMGy9oxXp1tvj3dfMF4wfpXlms6fR0aXiapbEY1wkUBquGhN3oUDySdUHgDWIv6PliDBpWKGvsQQeWm4ifffXQvTzffnldhLYbk9fmzvtN9rqquVsLlqm6hik6L3zKbPPAqBAi9au0OjN2sIr8sfmzecwBs2GDp6nL1/W705/8B5FGCT0++JmsAAAAASUVORK5CYII='


$script:UI    = @{}
function New-GLState {
    # Everything one window knows about the tenant - new for every window, so going
    # back to the start page leaves nothing of the last session behind.
    return @{
        Gateways     = @()
        GatewayList  = @()
        Members      = @{}
        Live         = $null
        GatewayRows  = @()
        Tiles        = @()
        DownSince    = @{}
        VnetSkipped  = $true
        Releases     = $null
        Directory    = $null
        Names        = @{}         # principal id -> Name, Email - from Graph, kept for the session
        NamesWarned  = $false
        CnAccessFor  = ''
        GatewayState = @{}
        PublicKeys   = @{}
        ConnRows     = @()
        Excluded     = [System.Collections.Generic.HashSet[string]]::new()
        Populating   = $false
        LastRefresh  = $null
        AccessRows   = @{ gateways = @(); connections = @() }   # what the access panels hold, before the Entra filter
        AlertTrack   = @{}                                      # member id -> checks down in a row, told or not
    }
}
$script:State = New-GLState
# Shared with the bulk worker: it writes Total and Done, the window sets Cancel.
$script:Progress = [hashtable]::Synchronized(@{ Active = $false; Name = ''; Total = 0; Done = 0; Cancel = $false })

$script:LogEntries = [System.Collections.Generic.List[object]]::new()
$script:EarlierErrors = [System.Collections.Generic.List[object]]::new()   # from windows closed to go back to the start page

function Test-GLLogVisible($Entry) {
    $lvl = [string]$script:UI.CmbLogLevel.SelectedItem
    if ($lvl -eq 'Warnings and errors' -and $Entry.Level -in 'Info', 'Ok') { return $false }
    if ($lvl -eq 'Errors only' -and $Entry.Level -ne 'Error') { return $false }
    $f = [string]$script:UI.TxtLogFind.Text
    if ($f.Trim() -and $Entry.Line.IndexOf($f.Trim(), [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    return $true
}

function Update-GLLogView {
    # The panel shows the lines the level and the Find box let through. One new
    # collection, not thousands of adds - each add would redraw the list.
    if (-not $script:UI.LstLog) { return }
    $shown = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $script:LogEntries) { if (Test-GLLogVisible $e) { $shown.Add($e) } }
    $script:LogView = [System.Collections.ObjectModel.ObservableCollection[object]]::new($shown)
    try { $script:UI.LstLog.ItemsSource = $script:LogView } catch { }
    Step-GLLogScroll
}

function Get-GLLogScroller {
    # The list's own scroll viewer, found once the list is drawn.
    if ($script:LogScroller) { return $script:LogScroller }
    try {
        $d = $script:UI.LstLog
        if (-not ($d -is [System.Windows.DependencyObject])) { return $null }
        while ($d -and -not ($d -is [System.Windows.Controls.ScrollViewer])) {
            if ([System.Windows.Media.VisualTreeHelper]::GetChildrenCount($d) -eq 0) { return $null }
            $d = [System.Windows.Media.VisualTreeHelper]::GetChild($d, 0)
        }
        $script:LogScroller = $d
        return $d
    } catch { return $null }     # no WPF here - the tests, or Linux
}

function Test-GLLogAtEnd {
    # Is the newest line in view? Scrolled up to read, the view stays where it is.
    $sv = Get-GLLogScroller
    if (-not $sv) { return $true }
    return ($sv.VerticalOffset -ge $sv.ScrollableHeight - 1)
}

function Step-GLLogScroll {
    $sv = Get-GLLogScroller
    if ($sv) { $sv.ScrollToEnd() }
}

function Get-GLLogText {
    # The lines shown in the panel - or only the selected ones - as text.
    param([switch]$Selected)
    $src = if ($Selected -and $script:UI.LstLog) { @($script:UI.LstLog.SelectedItems) } else { @($script:LogView) }
    if ($Selected) {
        # in the order shown, not the order they were clicked
        $pick = [System.Collections.Generic.HashSet[object]]::new()
        foreach ($x in $src) { [void]$pick.Add($x) }
        $src = @($script:LogView | Where-Object { $pick.Contains($_) })
    }
    $lines = @($src | Where-Object { $_ } | ForEach-Object { [string]$_.Line })
    if ($lines.Count -eq 0) { return '' }
    return (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Write-GLLog {
    # The panel, and - once signed in - the daily log file. -FileOnly keeps detail
    # (every item of a bulk run) in the file without flooding the panel.
    # Ok is Info that went well: green in the panel.
    param([string]$Text, [ValidateSet('Info', 'Ok', 'Warn', 'Error')][string]$Level = 'Info', [switch]$FileOnly)
    if ($script:LogReady) {
        $path = Get-GLLogPath -Folder $script:LogFolder -User $script:SignedInAs
        $null = Write-GLLogFile -Path $path -Level (@{ Info = 'INFO'; Ok = 'OK'; Warn = 'WARN'; Error = 'ERROR' }[$Level]) -Text $Text
    }
    if ($FileOnly) { return }
    $tag  = @{ Info = ''; Ok = ''; Warn = 'WARN   '; Error = 'ERROR  ' }[$Level]
    $now  = Get-Date
    $line = '{0:HH:mm:ss}  {1}{2}' -f $now, $tag, $Text
    if ($script:UI.LstLog) {
        $entry = [pscustomobject]@{ Level = $Level; Line = $line; Time = $now.ToString('HH:mm:ss'); Text = "$tag$Text" }
        $script:LogEntries.Add($entry)
        if ($Level -eq 'Error') { $script:ErrorCount = [int]$script:ErrorCount + 1 }
        if ($script:LogEntries.Count -gt 5000) { $script:LogEntries.RemoveRange(0, 1000); Update-GLLogView; return }
        # not "if ($script:LogView": an empty collection counts as false, and the first line would never show
        if ($null -ne $script:LogView -and (Test-GLLogVisible $entry)) {
            $follow = Test-GLLogAtEnd
            $script:LogView.Add($entry)
            if ($follow) { Step-GLLogScroll }
        }
    }
    else { Write-Host $line }
}

function Open-GLFolder([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -ItemType Directory -Path $Path -Force }
    Start-Process explorer.exe -ArgumentList "`"$Path`""
}

# ---- appearance ------------------------------------------------------------------
$script:HistoryFields = @('TxtGwFilter', 'TxtCnSearch', 'TxtCnUser', 'TxtCnAccount', 'TxtBulkPrincipals', 'TxtCredUser', 'TxtLogFind', 'TxtMoveFrom', 'TxtMoveTo')
# the Show views on the Connections tab - Select-GLConnections knows each by its words
$script:ShowViews = @('All connections', 'Last used over 30 days ago', 'Last used over 90 days ago', 'Last used over 180 days ago',
                      'Last used over 365 days ago', 'No use recorded', 'Duplicates', 'Failing tests', 'Skip test connection on',
                      'Access by accounts not in Entra ID')

function New-GLBrush([string]$Hex) {
    $c = ConvertTo-GLColorValue $Hex
    # ::new(), not New-Object: New-Object wraps the brush in a PowerShell object, and a
    # resource dictionary stores the wrapper as it is - WPF then sees only its text form.
    $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb($c[0], $c[1], $c[2], $c[3]))
    $b.Freeze()
    return $b
}

function Set-GLTheme {
    # Every named brush on the given window (or windows) gets the theme's colour.
    param([Parameter(Mandatory)]$Target, [string]$Name)
    if (-not $script:Themes.Contains($Name)) { $Name = 'Light' }
    $t = $script:Themes[$Name]
    foreach ($w in @($Target)) {
        foreach ($k in $t.Keys) {
            # Built here and stored as the raw .NET object. A resource dictionary keeps
            # whatever it is given: a PowerShell wrapper around the brush - from New-Object,
            # or picked up on the way out of a function - reaches WPF as plain text.
            $c = ConvertTo-GLColorValue $t[$k]
            $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb($c[0], $c[1], $c[2], $c[3]))
            $b.Freeze()
            $w.Resources[$k] = $b.psobject.BaseObject
        }
    }
    return $Name
}

function Add-GLStyles {
    # Modern look, or - if that dictionary fails to load for any reason - the classic
    # one. Returns which was used. The window never fails to open because of styling.
    param([Parameter(Mandatory)]$Target)
    if ($script:StyleMode -ne 'Classic') {
        try {
            $rd = [Windows.Markup.XamlReader]::Parse($script:ModernStylesXaml)
            $Target.Resources.MergedDictionaries.Add($rd)
            $script:StyleMode = 'Modern'
            return 'Modern'
        }
        catch {
            $script:StyleMode = 'Classic'
            $script:StyleError = $_.Exception.Message
        }
    }
    $Target.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Parse($script:ClassicStylesXaml))
    return 'Classic'
}

function Get-GLIconImage {
    if ($script:IconImage) { return $script:IconImage }
    try {
        $bytes = [Convert]::FromBase64String($script:IconPng)
        $bmp = [System.Windows.Media.Imaging.BitmapImage]::new()
        $bmp.BeginInit()
        $bmp.StreamSource = [System.IO.MemoryStream]::new([byte[]]$bytes)
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()
        $bmp.Freeze()
        $script:IconImage = $bmp
    } catch { $script:IconImage = $null }
    return $script:IconImage
}

$script:RepoUrl = 'https://github.com/lukas-novacek/GatewayLens'

function Open-GLLink([string]$Url) {
    # Only web pages, in the default browser - never a file or a program.
    if ($Url -notmatch '^https://') { return }
    if (-not (Open-GLBrowser $Url)) { Write-GLLog "Could not open $Url - copy it into your browser." 'Warn' }
}

function Get-GLIssueUrl {
    # A new issue on GitHub, with what helps to answer it - and nothing about the tenant.
    $body = "GatewayLens $($script:AppVersion), PowerShell $($PSVersionTable.PSVersion), sign-in via $($script:AuthMode)`n`nWhat happened:`n`nWhat I expected:`n`n(Please leave out names, ids and anything else from your tenant.)"
    return "$($script:RepoUrl)/issues/new?body=$([uri]::EscapeDataString($body))"
}

# What the start page's own thread needs - it is a separate runspace.
$script:StartPageFunctions = @('Add-GLStyles', 'Set-GLTheme', 'ConvertTo-GLColorValue', 'Get-GLIconImage', 'Open-GLBrowser', 'Save-GLWindowImage')

function Get-GLStartPageScript {
    <#
        The start page, run on a thread of its own so it stays alive while the main
        thread signs in - a sign-in waits for the browser, and a window on the same
        thread would freeze. The two talk through one synchronized hashtable:
        the page sets Choice ('SignIn' or 'Demo') and Account; the main thread sets
        Error, or Done when the page can close. Closing the page sets Closed.
    #>
    return {
        param($Sync)
        try {
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            [xml]$x = $Sync.Xaml
            $w = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($x))
            $ui = @{}
            foreach ($n in 'StartLogo', 'StartAccount', 'StartSignIn', 'StartHow', 'StartBusy', 'StartBusyText', 'StartError', 'StartErrorText', 'StartDemo', 'StartHelp', 'StartGitHub', 'StartVersion') {
                $ui[$n] = $w.FindName($n)
            }
            $null = Add-GLStyles -Target $w
            $null = Set-GLTheme -Target $w -Name $Sync.Theme
            $w.FontSize = $Sync.FontSize
            $img = Get-GLIconImage
            if ($img) { $w.Icon = $img; $ui.StartLogo.Source = $img }
            $ui.StartAccount.Text = $Sync.Account
            $ui.StartHow.Text     = $Sync.How
            $ui.StartVersion.Text = "Version $($Sync.Version) - free and open source"
            $global:StartUi = $ui; $global:StartSync = $Sync; $global:StartWindow = $w

            $ui.StartSignIn.Add_Click({
                $global:StartSync.Account = ([string]$global:StartUi.StartAccount.Text).Trim()
                $global:StartSync.Error   = ''
                $global:StartSync.Choice  = 'SignIn'
            })
            $ui.StartDemo.Add_Click({ $global:StartSync.Choice = 'Demo' })
            $ui.StartHelp.Add_Click({ $null = Open-GLBrowser "$($global:StartSync.RepoUrl)#readme" })
            $ui.StartGitHub.Add_Click({ $null = Open-GLBrowser $global:StartSync.RepoUrl })
            $w.Add_Closing({ param($s, $e) if (-not $global:StartSync.Done) { $global:StartSync.Closed = $true } })

            $tm = [System.Windows.Threading.DispatcherTimer]::new()
            $tm.Interval = [TimeSpan]::FromMilliseconds(150)
            $tm.Add_Tick({
                $s = $global:StartSync; $u = $global:StartUi
                if ($s.Done) { $global:StartTimer.Stop(); $global:StartWindow.Close(); return }
                if ($s.Auto -and -not $s.AutoDone -and ($s.ShotDone -or -not $s.Shot)) { $s.AutoDone = $true; $s.Choice = $s.Auto }
                $busy = [bool]$s.Choice
                $u.StartBusy.Visibility   = $(if ($s.Choice -eq 'SignIn') { 'Visible' } else { 'Collapsed' })
                $u.StartError.Visibility  = $(if ($s.Error -and -not $busy) { 'Visible' } else { 'Collapsed' })
                if ($s.Error) { $u.StartErrorText.Text = [string]$s.Error }
                $u.StartSignIn.IsEnabled  = [bool]$s.CanSignIn -and -not $busy
                $u.StartDemo.IsEnabled    = -not $busy
                $u.StartAccount.IsEnabled = -not $busy
                # the picture after the page shows its real state - on the next tick, once drawn
                if ($s.Shot -and -not $s.ShotDone) {
                    if ($s.ShotWait) { $s.ShotDone = $true; try { Save-GLWindowImage -Path $s.Shot -Window $global:StartWindow } catch { } }
                    else { $s.ShotWait = $true }
                }
            })
            $global:StartTimer = $tm
            $w.Add_ContentRendered({ $global:StartSync.Shown = $true; $global:StartTimer.Start(); $null = $global:StartUi.StartAccount.Focus() })
            $null = $w.ShowDialog()
        }
        catch { $Sync.Failed = $_.Exception.Message }
    }
}

function Invoke-GLStartPage {
    <#
        Shows the start page and does what is chosen on it: signs in - on this, the
        main, thread, exactly as without the page - or goes to the demo. A failed
        sign-in is shown on the page, to try again. Returns 'SignedIn', 'Demo',
        'Closed' (the page was closed), or 'Fallback' when the page could not be
        shown - then the caller signs in the old way.
        -Auto picks for the user, and -Shot saves a picture first: smoke test, README.
    #>
    param([string]$TenantId, [string]$ClientId, [string]$Account, [string]$SignIn = 'Auto', [switch]$NoWindow, [string]$Auto, [string]$Shot)
    $settings = Read-GLSettings -Path $(if ($script:SettingsPath) { $script:SettingsPath } else { Get-GLSettingsPath })
    $how = ''; $can = $true
    try {
        $plan = Select-GLSignIn -Requested $SignIn -ClientId $ClientId -BuiltInId $script:BuiltInClientId -AzAvailable (Test-GLAzAccounts)
        $how = if ($plan -eq 'Az') { 'Signs in through Az.Accounts, in your browser - nothing to approve.' }
               else { 'Signs in in your browser. Your organisation approves GatewayLens once.' }
    }
    catch { $how = $_.Exception.Message; $can = $false }
    $theme = $settings.Theme
    if ($Shot) {
        # the README picture shows the page as most people see it
        $how = 'Signs in through Az.Accounts, in your browser - nothing to approve.'; $can = $true; $theme = 'Dark'
    }
    $sync = [hashtable]::Synchronized(@{
        Xaml = $script:StartXaml; Theme = $theme; FontSize = $settings.FontSize
        Account = $(if ($Account) { $Account } else { $settings.LastAccount }); How = $how; CanSignIn = $can
        Version = $script:AppVersion; RepoUrl = $script:RepoUrl
        Choice = $null; Error = ''; Done = $false; Closed = $false; Shown = $false; Failed = ''
        Auto = $Auto; AutoDone = $false; Shot = $Shot; ShotDone = $false; ShotWait = $false
    })
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    foreach ($n in $script:StartPageFunctions) {
        $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($n, (Get-Item "function:$n").Definition))
    }
    foreach ($v in 'ModernStylesXaml', 'ClassicStylesXaml', 'Themes', 'IconPng') {
        $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new($v, (Get-Variable -Scope Script -Name $v -ValueOnly), ''))
    }
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript((Get-GLStartPageScript).ToString()).AddArgument($sync)
    $h = $ps.BeginInvoke()
    $result = 'Fallback'
    try {
        while (-not $h.IsCompleted) {
            if ($sync.Closed) { $result = 'Closed'; break }
            if ($sync.Choice -eq 'Demo') { $result = 'Demo'; break }
            if ($sync.Choice -eq 'SignIn') {
                try {
                    Connect-GL -TenantId $TenantId -ClientId $ClientId -Account $sync.Account -SignIn $SignIn -NoWindow:$NoWindow
                    $result = if ($sync.Closed) { 'Closed' } else { 'SignedIn' }
                    break
                }
                catch {
                    $sync.Error  = "Sign-in did not work: $($_.Exception.Message)"
                    $sync.Choice = $null
                }
            }
            Start-Sleep -Milliseconds 100
        }
        if ($result -eq 'Fallback' -and $sync.Closed) { $result = 'Closed' }
    }
    finally {
        $sync.Done = $true
        $until = (Get-Date).AddSeconds(5)
        while (-not $h.IsCompleted -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 50 }
        if ($h.IsCompleted) { try { $ps.Dispose(); $rs.Dispose() } catch { } }
    }
    if ($sync.Failed) { Write-Host "The start page could not be shown ($($sync.Failed)) - signing in without it." -ForegroundColor Yellow }
    return $result
}

function Update-GLTaskbarState {
    <#
        The taskbar button says it without a sound: yellow while a gateway is
        degraded, red while one is offline - seen with the window minimised or behind
        others. The title says the same, for Alt+Tab.
    #>
    $w = $script:Window
    if (-not $w) { return }
    $st   = @($script:State.GatewayState.Values)
    $off  = @($st | Where-Object { $_ -eq 'Offline' }).Count
    $part = @($st | Where-Object { $_ -eq 'Partial' }).Count
    $bits = @()
    if ($off)  { $bits += "$off offline" }
    if ($part) { $bits += "$part degraded" }
    try {
        if (-not $w.TaskbarItemInfo) { $w.TaskbarItemInfo = [System.Windows.Shell.TaskbarItemInfo]::new() }
        $tb = $w.TaskbarItemInfo
        if ($off) { $tb.ProgressState = 'Error'; $tb.ProgressValue = 1 }
        elseif ($part) { $tb.ProgressState = 'Paused'; $tb.ProgressValue = 1 }
        else { $tb.ProgressState = 'None' }
        $tb.Description = if ($bits) { "Gateways: $($bits -join ', ')" } else { 'Gateways: all online' }
        if ($script:BaseTitle) { $w.Title = if ($bits) { "($($bits -join ', ')) $($script:BaseTitle)" } else { $script:BaseTitle } }
    } catch { }
}

function Invoke-GLAlerts {
    <#
        After each gateway refresh: who went down, who is back. The taskbar always;
        then the alerts the user turned on. -OnlyClusterIds: only those were read
        again. An alert that fails to go out is logged - never stops a refresh.
    #>
    param([string[]]$OnlyClusterIds)
    try {
        $res = Get-GLAlertEvents -Track $script:State.AlertTrack -Live $script:State.Live -OnlyClusterIds $OnlyClusterIds
        $script:State.AlertTrack = $res.Track
        Update-GLTaskbarState
        $ev = @($res.Events)
        if ($ev.Count -eq 0) { return }
        $names = @{}
        foreach ($r in @($script:State.GatewayRows)) { if ($r) { $names[([string]$r.Id).ToLowerInvariant()] = [string]$r.Name } }
        $who = @{}
        foreach ($k in @($script:State.Members.Keys)) { foreach ($m in @($script:State.Members[$k])) { if ($m) { $who[([string]$m.id).ToLowerInvariant()] = [string]$m.displayName } } }
        $msg = Format-GLAlertText -Events $ev -Live $script:State.Live -ClusterNames $names -MemberNames $who
        foreach ($l in $msg.Lines) { Write-GLLog "Alert: $l" $(if ($msg.Severity -eq 'Down') { 'Warn' } else { 'Ok' }) }
        $a = $script:Settings.Alerts
        if ($a.Desktop) { Show-GLDesktopAlert -Title $msg.Title -Text ($msg.Lines -join [Environment]::NewLine) -Severity $msg.Severity }
        if ($a.Sound) { Invoke-GLAlertSound -Severity $msg.Severity }
        $url = Unprotect-GLText $a.WebhookProtected
        if ($url) { Send-GLAlertWebhook -Url $url -Card (New-GLAlertCard -Title $msg.Title -Lines $msg.Lines -Severity $msg.Severity -Version $script:AppVersion) }
    }
    catch { Write-GLLog "Alerts: $($_.Exception.Message)" 'Warn' }
}

function Send-GLAlertWebhook {
    # In the background: a flow that is slow to answer must not hold up the window.
    param([string]$Url, $Card)
    Start-GLJob -Quiet -Name 'Sending the alert' -Arguments @{ U = $Url; B = $Card } -Work {
        param($U, $B)
        Send-GLWebhook -Url $U -Body $B
        'sent'
    } -OnDone {
        param($r, $err, $ctx)
        if (-not $err) { Write-GLLog 'Alert posted to Teams / Power Automate.' 'Ok' }
    }
}

function Show-GLDesktopAlert {
    # A Windows notification, from an icon in the notification area while alerts are on.
    param([string]$Title, [string]$Text, [string]$Severity)
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        if (-not $script:TrayIcon) {
            $ni  = [System.Windows.Forms.NotifyIcon]::new()
            $bmp = [System.Drawing.Bitmap]::new([System.IO.MemoryStream]::new([byte[]][Convert]::FromBase64String($script:IconPng)))
            $ni.Icon    = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
            $ni.Text    = $script:AppName
            $ni.Visible = $true
            $ni.Add_BalloonTipClicked({ try { $script:Window.Activate() } catch { } })
            $ni.Add_Click({ try { $script:Window.Activate() } catch { } })
            $script:TrayIcon = $ni
        }
        $t = if ($Title.Length -gt 60) { $Title.Substring(0, 60) } else { $Title }
        $x = if ($Text.Length -gt 250) { $Text.Substring(0, 247) + '...' } else { $Text }
        $kind = if ($Severity -eq 'Down') { [System.Windows.Forms.ToolTipIcon]::Warning } else { [System.Windows.Forms.ToolTipIcon]::Info }
        $script:TrayIcon.ShowBalloonTip(10000, $t, $x, $kind)
    }
    catch { Write-GLLog "The Windows notification could not be shown: $($_.Exception.Message)" 'Warn' }
}

function Remove-GLTrayIcon {
    # Gone with the window - or Windows shows a dead icon until the mouse passes over it.
    try { if ($script:TrayIcon) { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } } catch { }
    $script:TrayIcon = $null
}

function Invoke-GLAlertSound {
    # One of Windows' own sounds: a warning when a member is down, a lighter one when back.
    param([string]$Severity)
    $want = if ($Severity -eq 'Down') { 'Windows Critical Stop.wav', 'Windows Exclamation.wav' } else { 'Windows Notify System Generic.wav', 'chimes.wav' }
    foreach ($f in $want) {
        $path = Join-Path $env:WINDIR "Media\$f"
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $player = [System.Windows.Media.MediaPlayer]::new()
            $player.Open([uri]$path)
            $player.Play()
            $script:AlertPlayer = $player      # kept, or it can be collected mid-sound
        } catch { }
        return
    }
}

function Update-GLAlertsButton {
    $a = $script:Settings.Alerts
    $on = @()
    if ($a.Desktop) { $on += 'notification' }
    if ($a.Sound) { $on += 'sound' }
    if ($a.WebhookProtected) { $on += 'Teams' }
    if ($script:UI.TxtAlerts) { $script:UI.TxtAlerts.Text = if ($on) { "Alerts: $($on -join ', ')" } else { 'Alerts' } }
}

function Show-GLAlertsDialog {
    # -NoShow: built and handed back, not shown - for the smoke test.
    param([switch]$NoShow)
    [xml]$x = $script:AlertsXaml
    $dlg = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($x))
    if ($script:Window) { $dlg.Owner = $script:Window }
    Initialize-GLDialog -Dialog $dlg
    $c = @{}
    foreach ($n in 'AlDesktop', 'AlSound', 'AlWebhook', 'AlUrl', 'AlTest', 'AlTestResult', 'AlError', 'AlOk', 'AlCancel') { $c[$n] = $dlg.FindName($n) }
    $a = $script:Settings.Alerts
    $url = Unprotect-GLText $a.WebhookProtected
    $c.AlDesktop.IsChecked = [bool]$a.Desktop
    $c.AlSound.IsChecked   = [bool]$a.Sound
    $c.AlWebhook.IsChecked = [bool]$url
    $c.AlUrl.Text          = $url
    $script:AlertDlg = @{ Dialog = $dlg; C = $c }
    $c.AlTest.Add_Click({ Send-GLTestAlert })
    $c.AlOk.Add_Click({ Save-GLAlertsDialog })
    $c.AlCancel.Add_Click({ $script:AlertDlg.Dialog.Close() })
    if ($NoShow) { return $dlg }
    $null = $dlg.ShowDialog()
    $script:AlertDlg = $null
}

function Send-GLTestAlert {
    $c = $script:AlertDlg.C
    $url = ([string]$c.AlUrl.Text).Trim()
    $why = Test-GLWebhookUrl $url
    if ($why) { $c.AlTestResult.Text = $why; return }
    $c.AlTestResult.Text = 'Sending...'
    $card = New-GLAlertCard -Title 'GatewayLens test alert' -Lines @('Alerts from GatewayLens reach this channel or flow.', "Sent by $($script:SignedInAs).") -Severity 'Up' -Version $script:AppVersion
    Start-GLJob -Quiet -Name 'Sending a test alert' -Arguments @{ U = $url; B = $card } -Work {
        param($U, $B)
        Send-GLWebhook -Url $U -Body $B
        'sent'
    } -OnDone {
        param($r, $err, $ctx)
        $text = if ($err) { "Not sent - $err." } else { 'Sent. Look in the channel, or in the flow''s run history.' }
        if ($script:AlertDlg) { $script:AlertDlg.C.AlTestResult.Text = $text }
        if (-not $err) { Write-GLLog 'Test alert sent.' 'Ok' }
    }
}

function Save-GLAlertsDialog {
    $c = $script:AlertDlg.C
    $url  = ([string]$c.AlUrl.Text).Trim()
    $hook = [bool]$c.AlWebhook.IsChecked
    if ($hook) {
        $why = Test-GLWebhookUrl $url
        if ($why) { $c.AlError.Text = $why; $c.AlError.Visibility = 'Visible'; return }
    }
    $script:Settings.Alerts = [ordered]@{ Desktop = [bool]$c.AlDesktop.IsChecked; Sound = [bool]$c.AlSound.IsChecked; WebhookProtected = $(if ($hook) { Protect-GLText $url } else { '' }) }
    $null = Save-GLSettings -Settings $script:Settings -Path $script:SettingsPath
    $on = @()
    if ($c.AlDesktop.IsChecked) { $on += 'Windows notification' }
    if ($c.AlSound.IsChecked) { $on += 'sound' }
    if ($hook) { $on += 'Teams / Power Automate' }
    if ($on) {
        Write-GLLog "Alerts on: $($on -join ', '). A member counts as down after two checks in a row."
        if ([string]$script:UI.CmbAutoRefresh.SelectedItem -eq 'Off') {
            $script:UI.CmbAutoRefresh.SelectedItem = '5 min'
            Write-GLLog 'Auto-refresh is now every 5 minutes - alerts come with each refresh.'
        }
        if (-not $script:UI.ChkLive.IsChecked) { Write-GLLog 'Alerts need Live member status, which is off - tick it, or nothing can be reported.' 'Warn' }
    }
    else { Write-GLLog 'Alerts are off.'; Remove-GLTrayIcon }
    Update-GLAlertsButton
    $script:AlertDlg.Dialog.Close()
}

function Show-GLInfo {
    # A small window: a title, a few lines, and buttons that open web pages.
    param([string]$Title, [string]$Subtitle, [string[]]$Lines, $Links)
    [xml]$x = $script:InfoXaml
    $dlg = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($x))
    Initialize-GLDialog -Dialog $dlg
    if ($script:Window) { $dlg.Owner = $script:Window }
    $dlg.Title = $Title
    $dlg.FindName('InfoTitle').Text = $Title
    $dlg.FindName('InfoSub').Text = $Subtitle
    $dlg.FindName('InfoLines').ItemsSource = @($Lines)
    $img = Get-GLIconImage
    if ($img) { $dlg.FindName('InfoLogo').Source = $img }
    $panel = $dlg.FindName('InfoLinks')
    foreach ($l in @($Links)) {
        $b = [System.Windows.Controls.Button]::new()
        $b.Content = $l[0]
        $b.Tag = $l[1]
        $b.Margin = [System.Windows.Thickness]::new(0, 0, 6, 6)
        $b.Add_Click({ param($s, $e) Open-GLLink ([string]$s.Tag) })
        $null = $panel.Children.Add($b)
    }
    $dlg.FindName('InfoClose').Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).Close() })
    $null = $dlg.ShowDialog()
}

function Show-GLWhatsNew {
    Show-GLInfo -Title "What is new in $($script:AppName) $($script:WhatsNew.Version)" -Subtitle 'The highlights. The full list is on GitHub.' `
        -Lines $script:WhatsNew.Lines -Links @(@('Full changelog', "$($script:RepoUrl)/blob/main/CHANGELOG.md"), @('All releases', "$($script:RepoUrl)/releases"))
}

function Show-GLAbout {
    Show-GLInfo -Title "$($script:AppName) $($script:AppVersion)" -Subtitle 'The missing admin console for Power BI and Fabric data gateways.' -Lines @(
        'Made by Lukas Novacek. Free and open source, under the MIT licence.'
        'Signs in as you and acts with your permissions. Nothing is sent anywhere but Microsoft.'
        'Not affiliated with, endorsed by or supported by Microsoft.'
        'If it saves you time, star it on GitHub and tell a colleague who runs gateways.'
    ) -Links @(@('GatewayLens on GitHub', $script:RepoUrl), @('Report a problem', (Get-GLIssueUrl)))
}

function Add-GLHelpMenu {
    # The ? button: help pages, the news, where to report a problem, and who made it.
    $menu = [System.Windows.Controls.ContextMenu]::new()
    $items = @(
        , @('How to use GatewayLens', 'F1', "$($script:RepoUrl)#readme")
        , @('What each action needs - permissions', '', "$($script:RepoUrl)/blob/main/docs/permissions.md")
        , @("What is new in $($script:AppVersion)", '', 'news')
        , @('-', '', '')
        , @('Report a problem or suggest an idea', '', 'issue')
        , @('GatewayLens on GitHub', '', $script:RepoUrl)
        , @('-', '', '')
        , @('About GatewayLens', '', 'about')
    )
    foreach ($m in $items) {
        if ($m[0] -eq '-') { $null = $menu.Items.Add([System.Windows.Controls.Separator]::new()); continue }
        $item = [System.Windows.Controls.MenuItem]::new()
        $item.Header = $m[0]
        $item.InputGestureText = $m[1]
        $item.Tag = $m[2]
        $item.Add_Click({
            param($s, $e)
            switch ([string]$s.Tag) {
                'news'  { Show-GLWhatsNew }
                'about' { Show-GLAbout }
                'issue' { Open-GLLink (Get-GLIssueUrl) }
                default { Open-GLLink ([string]$s.Tag) }
            }
        })
        $null = $menu.Items.Add($item)
    }
    $btn = $script:UI.BtnHelp
    $menu.PlacementTarget = $btn
    $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $btn.ContextMenu = $menu
    $btn.Add_Click({ param($s, $e) $s.ContextMenu.IsOpen = $true })
}

function Initialize-GLDialog {
    # Dialogs are separate windows: they need the same look, theme, size and icon.
    param([Parameter(Mandatory)]$Dialog)
    $null = Add-GLStyles -Target $Dialog
    $null = Set-GLTheme -Target $Dialog -Name $script:Settings.Theme
    $Dialog.FontSize = $script:Settings.FontSize
    $img = Get-GLIconImage
    if ($img) { $Dialog.Icon = $img }
}

function Step-GLFontSize {
    # A- and A+, Ctrl + mouse wheel, Ctrl + plus, minus or 0 - one text size, kept in
    # the settings whenever it changes.
    param([int]$By, [switch]$Reset)
    $before = [int]$script:Settings.FontSize
    Set-GLFontSize $(if ($Reset) { [int](New-GLDefaultSettings).FontSize } else { $before + $By })
    if ([int]$script:Settings.FontSize -ne $before) { $null = Save-GLSettings -Settings $script:Settings -Path $script:SettingsPath }
}

function Set-GLFontSize([int]$Size) {
    $Size = [Math]::Max(9, [Math]::Min(20, $Size))
    $script:Settings.FontSize = $Size
    $script:Window.FontSize   = $Size
    $script:UI.TxtFontSize.Text = "$Size"
    # the rows follow the text: compact, and never cutting it off
    $h = Get-GLRowHeight -FontSize $Size
    foreach ($g in $script:Grids) {
        $grid = $script:UI[$g]
        if ($grid) { $grid.RowHeight = $h.Row; $grid.ColumnHeaderHeight = $h.Header }
    }
    if ($script:UI.LstLog) { $script:UI.LstLog.FontSize = [Math]::Max(9, $Size - 1) }
    # The tiles grow and shrink with the text, all of a tile at once - it is drawn
    # for text size 12. A layout transform, so the rows of tiles still wrap.
    $tiles = $script:UI.LstGwTiles
    if ($tiles) {
        if (-not $script:TileItemStyle) { $script:TileItemStyle = $tiles.ItemContainerStyle }
        $k  = $Size / 12.0
        $sc = [System.Windows.Media.ScaleTransform]::new($k, $k)
        $sc.Freeze()
        $st = [System.Windows.Style]::new([System.Windows.Controls.ListBoxItem], $script:TileItemStyle)
        $st.Setters.Add([System.Windows.Setter]::new([System.Windows.FrameworkElement]::LayoutTransformProperty, $sc.psobject.BaseObject))
        $tiles.ItemContainerStyle = $st
    }
}

function Get-GLTileScale {
    # How large the tiles are drawn, against their size at text size 12.
    $st = $script:UI.LstGwTiles.ItemContainerStyle
    $s  = @($st.Setters | Where-Object { $_.Property -eq [System.Windows.FrameworkElement]::LayoutTransformProperty }) | Select-Object -First 1
    if ($s) { return [double]$s.Value.ScaleX }
    return 1.0
}

function Save-GLFieldHistory([string]$Field) {
    $box = $script:UI[$Field]
    if (-not $box) { return }
    if (Add-GLHistory -Settings $script:Settings -Field $Field -Value ([string]$box.Text)) {
        $keep = $box.Text
        $box.ItemsSource = Get-GLHistory -Settings $script:Settings -Field $Field
        $box.Text = $keep
    }
}

function Clear-GLStaleChoice {
    <#
        An entry picked from the list stays selected after its text is deleted, and
        WPF only acts on a click that changes the selection - so picking it again did
        nothing. When the list opens, an entry the text no longer shows is let go.
    #>
    param($Box)
    if ($Box.SelectedIndex -lt 0 -or [string]$Box.Text -eq [string]$Box.SelectedItem) { return }
    $keep = [string]$Box.Text
    $Box.SelectedIndex = -1
    if ([string]$Box.Text -ne $keep) { $Box.Text = $keep }
}

function Initialize-GLHistory {
    foreach ($f in $script:HistoryFields) {
        $box = $script:UI[$f]
        if (-not $box) { continue }
        $box.ItemsSource = Get-GLHistory -Settings $script:Settings -Field $f
        # Remembered when the box is left or Enter is pressed - not on every keystroke.
        # The box's own Name says which field it is: a .GetNewClosure() handler would
        # run in a module of its own, where the script's functions do not exist.
        $box.Add_LostKeyboardFocus({ param($s, $e) if (-not $s.IsKeyboardFocusWithin) { Save-GLFieldHistory $s.Name } })
        $box.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Save-GLFieldHistory $s.Name } })
        $box.Add_DropDownOpened({ param($s, $e) Clear-GLStaleChoice $s })
    }
}

function Start-GLDebounce {
    <#
        A filter box asks for its list to be shown again only once typing stops:
        every keystroke used to filter and redraw thousands of rows, and deleting a
        word froze the window for half a minute.
    #>
    param([ValidateSet('Connections', 'Gateways', 'Log')][string]$What)
    if (-not $script:Debounce) { $script:Debounce = @{} }
    $tm = $script:Debounce[$What]
    if (-not $tm) {
        $tm = [System.Windows.Threading.DispatcherTimer]::new()
        $tm.Interval = [TimeSpan]::FromMilliseconds(400)
        $tm.Tag = $What
        $tm.Add_Tick({
            param($s, $e)
            $s.Stop()
            switch ([string]$s.Tag) {
                'Connections' { Show-GLConnections -Say }
                'Gateways'    { Show-GLGateways -Say }
                'Log'         { Update-GLLogView }
            }
        })
        $script:Debounce[$What] = $tm
    }
    $tm.Stop()
    $tm.Start()
}

function Add-GLTextChanged {
    # An editable combo box has no TextChanged of its own - its inner text box does.
    param($Box, [scriptblock]$Handler)
    $Box.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
                    [System.Windows.Controls.TextChangedEventHandler]$Handler)
}


# ---- background work ------------------------------------------------------------
function Initialize-GLWorkers {
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    foreach ($n in $script:WorkerFunctions) {
        $def = (Get-Item "function:$n").Definition
        $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($n, $def))
    }
    $script:Pool = [runspacefactory]::CreateRunspacePool(1, 4, $iss, $Host)
    $script:Pool.Open()
    $script:Jobs = [System.Collections.Generic.List[object]]::new()

    $script:Timer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:Timer.Add_Tick({ Receive-GLJobs })
    $script:Timer.Start()
}

function Start-GLJob {
    # -Bulk: only one at a time, gets the shared Progress object as $Progress.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Work,
        [hashtable]$Arguments = @{},
        [hashtable]$Context = @{},
        [scriptblock]$OnDone,
        [switch]$Bulk,
        [switch]$Quiet,
        [switch]$Report,       # the Work block gets $Report - a stage and counts the status bar shows
        [int]$ExpectConnections = 0
    )
    $rep = $null
    if ($Report) {
        $rep = [hashtable]::Synchronized(@{ Stage = ''; Done = 0; Total = 0; Expect = 0; ExpectConnections = $ExpectConnections })
        $Arguments['Report'] = $rep
    }
    if ($Bulk) {
        if ($script:Progress.Active) {
            Write-GLLog "Wait for '$($script:Progress.Name)' to finish, or cancel it first." 'Warn'
            return
        }
        $script:Progress.Active = $true
        $script:Progress.Name   = $Name
        $script:Progress.Total  = 0
        $script:Progress.Done   = 0
        $script:Progress.Cancel = $false
        $script:Progress.Said   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()   # Text, Level
        $Arguments['Progress']  = $script:Progress
    }
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript($Work.ToString())
    foreach ($k in $Arguments.Keys) { [void]$ps.AddParameter($k, $Arguments[$k]) }
    $script:Jobs.Add([pscustomobject]@{
        Name = $Name; PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone
        Context = $Context; Started = Get-Date; Bulk = [bool]$Bulk; Quiet = [bool]$Quiet; Report = $rep
    })
    if (-not $Quiet) { Write-GLLog "$Name..." }
    Update-GLBusy
}

function Write-GLJobSaid {
    # What a running bulk job queued for the log, in the order it happened.
    $q = $script:Progress.Said
    if (-not $q) { return }
    $m = $null
    while ($q.TryDequeue([ref]$m)) { Write-GLLog ([string]$m.Text) $(if ($m.Level) { [string]$m.Level } else { 'Info' }) }
}

function Receive-GLJobs {
    Write-GLJobSaid
    if (-not $script:Jobs -or $script:Jobs.Count -eq 0) { return }
    foreach ($job in $script:Jobs.ToArray()) {
        if (-not $job.Handle.IsCompleted) { continue }
        [void]$script:Jobs.Remove($job)

        $result = $null; $err = $null
        try {
            $out    = $job.PS.EndInvoke($job.Handle)
            $result = ConvertFrom-GLJobOutput $out
            if ($null -eq $result -and $job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].ToString() }
        }
        catch {
            $e = $_.Exception
            while ($e.InnerException) { $e = $e.InnerException }
            $err = $e.Message
        }
        finally { $job.PS.Dispose() }

        $cancelled = $false
        if ($job.Bulk) { Write-GLJobSaid }      # its last lines before its summary
        if ($job.Bulk) {
            $cancelled = [bool]$script:Progress.Cancel
            $script:Progress.Active = $false
        }
        $secs = [math]::Round(((Get-Date) - $job.Started).TotalSeconds, 1)
        if ($err) { Write-GLLog "$($job.Name) failed after ${secs}s: $err" 'Error' }
        elseif ($cancelled) { Write-GLLog "$($job.Name) was cancelled after ${secs}s - the items already done stay done." 'Warn' }
        elseif (-not $job.Quiet) { Write-GLLog "$($job.Name) - finished in ${secs}s." }
        if ($job.OnDone) {
            try { & $job.OnDone $result $err $job.Context }
            catch { Write-GLLog "$($job.Name): $($_.Exception.Message)" 'Error' }
        }
    }
    Update-GLBusy
}

function Update-GLActions {
    <#
        While a change runs, or a list is being loaded again, the buttons that would
        clash with it wait: a change to a list that is about to be replaced, a second
        change at once, a second load. Looking, filtering and copying stay open.
    #>
    $changing = [bool]$script:Progress.Active
    $loadingCn = [bool]($script:Jobs | Where-Object { $_.Name -eq 'Loading connections' })
    $loadingGw = [bool]($script:Jobs | Where-Object { $_.Name -like 'Loading gateway*' })
    $cn = -not ($changing -or $loadingCn)
    $gw = -not ($changing -or $loadingGw)
    foreach ($b in 'BtnCnRefresh', 'BtnBulkStatus', 'BtnBulkUsers', 'BtnBulkGrant', 'BtnBulkRevoke', 'BtnBulkCredentials', 'BtnBulkDelete',
                   'BtnCopyAccess', 'BtnMoveAccess', 'BtnCnAccessAdd', 'BtnCnAccessRemove', 'BtnCnTest', 'BtnCnAccessReport') {
        if ($script:UI[$b]) { $script:UI[$b].IsEnabled = $cn }
    }
    foreach ($b in 'BtnGwRefresh', 'BtnMemberEnable', 'BtnMemberDisable', 'BtnGwAccessAdd', 'BtnGwAccessRemove') {
        if ($script:UI[$b]) { $script:UI[$b].IsEnabled = $gw }
    }
}

function Reset-GLSession {
    <#
        Back to the start page: the window has closed, and the next one - in the demo
        or signed in, maybe as someone else - starts with nothing from this one.
    #>
    foreach ($tm in $script:AutoTimer, $script:ClockTimer, $script:Timer, $script:MeterTimer) { try { if ($tm) { $tm.Stop() } } catch { } }
    $script:MeterTimer = $null; $script:MeterLast = $null; $script:ErrorCount = 0
    foreach ($tm in @($script:Debounce.Values)) { try { if ($tm) { $tm.Stop() } } catch { } }
    # a smoke test still judges what went wrong before
    foreach ($e in @($script:LogEntries | Where-Object { $_.Level -eq 'Error' })) { $script:EarlierErrors.Add($e) }
    $script:State = New-GLState
    $script:UI = @{}
    $script:Window = $null
    $script:LogEntries.Clear()
    $script:LogView = $null; $script:LogScroller = $null
    $script:Debounce = $null; $script:AutoTimer = $null; $script:ClockTimer = $null; $script:NextAutoRefresh = $null
    $script:TileItemStyle = $null; $script:KioskSaved = $null; $script:BaseTitle = $null; $script:AlertDlg = $null
    Remove-GLTrayIcon
    foreach ($k in 'Active', 'Cancel') { $script:Progress[$k] = $false }
    $script:Progress.Total = 0; $script:Progress.Done = 0; $script:Progress.Name = ''
    $script:Jobs = [System.Collections.Generic.List[object]]::new()
    $script:Auth = $null; $script:SignedInAs = ''; $script:AuthMode = ''; $script:TenantShown = ''
    $script:LogReady = $false
}

function Get-GLWorkStatus {
    <#
        The status bar for the jobs running now, from what each one reports: its
        stage, and how far - "1,500 of 3,200", "about 3,235" from the last time, or
        "so far". Returns Text, and Max / Value for the bar (Max 0: no total known).
    #>
    param($Jobs)
    $parts = [System.Collections.Generic.List[string]]::new()
    $max = 0; $val = 0
    foreach ($j in @($Jobs | Where-Object { $_ })) {
        $r = $j.Report
        if (-not ($r -and $r.Stage)) { $parts.Add([string]$j.Name); continue }
        $txt = "$($j.Name): $($r.Stage)"
        $done = [int]$r.Done
        if ([int]$r.Total -gt 0) {
            $txt += ' - {0:N0} of {1:N0}' -f $done, [int]$r.Total
            if (-not $max) { $max = [int]$r.Total; $val = [Math]::Min($done, $max) }
        }
        elseif ([int]$r.Expect -gt 0) {
            $txt += $(if ($done) { ' - {0:N0} of about {1:N0}' -f $done, [int]$r.Expect } else { ' - about {0:N0}' -f [int]$r.Expect })
            if (-not $max) { $max = [int]$r.Expect; $val = [Math]::Min($done, [int]($max * 0.99)) }
        }
        elseif ($done) { $txt += ' - {0:N0} so far' -f $done }
        $parts.Add($txt)
    }
    return [pscustomobject]@{ Text = ($parts -join '   |   '); Max = $max; Value = $val }
}

function Get-GLMeterText {
    # The meter at the bottom right: this process, its workers, and the calls to Microsoft.
    param([double]$Cpu, [long]$MemoryBytes, [int]$Busy, [int]$Workers, [int]$Threads, [long]$Calls, [long]$Throttled)
    $parts = @(
        ('CPU {0:0}%' -f [Math]::Max(0, [Math]::Min(100, $Cpu)))
        ('Memory {0:N0} MB' -f ($MemoryBytes / 1MB))
        "Workers $([Math]::Min($Busy, $Workers)) of $Workers busy$(if ($Busy -gt $Workers) { ", $($Busy - $Workers) waiting" })"
        "Threads $Threads"
        ('API calls {0:N0}' -f $Calls)
    )
    if ($Throttled) { $parts += ('throttled {0:N0}' -f $Throttled) }
    return ($parts -join '    ')
}

function Update-GLMeter {
    if (-not $script:UI.TxtMeter) { return }
    try {
        $p   = [System.Diagnostics.Process]::GetCurrentProcess()
        $now = [datetime]::UtcNow
        $cpuTime = $p.TotalProcessorTime
        $cpu = 0.0
        if ($script:MeterLast) {
            $wall = ($now - $script:MeterLast.At).TotalMilliseconds
            if ($wall -gt 0) { $cpu = 100 * ($cpuTime - $script:MeterLast.Cpu).TotalMilliseconds / ($wall * [Environment]::ProcessorCount) }
        }
        $script:MeterLast = @{ At = $now; Cpu = $cpuTime }
        $st = [System.AppDomain]::CurrentDomain.GetData('GatewayLens.Stats')
        $script:UI.TxtMeter.Text = Get-GLMeterText -Cpu $cpu -MemoryBytes $p.WorkingSet64 -Busy @($script:Jobs).Count -Workers 4 -Threads $p.Threads.Count `
            -Calls ([long]$st.Calls) -Throttled ([long]$st.Throttled)
        $n = [int]$script:ErrorCount
        $script:UI.BtnErrors.Visibility = $(if ($n) { 'Visible' } else { 'Collapsed' })
        $script:UI.BtnErrors.Content = "$n error$(if ($n -ne 1) { 's' })"
    } catch { }
}

function Update-GLBusy {
    Update-GLActions
    $p = $script:Progress
    $n = $script:Jobs.Count
    if ($p.Active) {
        $script:UI.Busy.Visibility      = 'Visible'
        $script:UI.BtnCancel.Visibility = 'Visible'
        if ($p.Total -gt 0) {
            $script:UI.Busy.IsIndeterminate = $false
            $script:UI.Busy.Maximum = $p.Total
            $script:UI.Busy.Value   = $p.Done
        }
        else { $script:UI.Busy.IsIndeterminate = $true }
        $tail = if ($p.Cancel) { '  -  cancelling after the current item' } else { '' }
        $script:UI.TxtStatus.Text = "$($p.Name): $($p.Done) of $($p.Total)$tail"
    }
    elseif ($n) {
        $ws = Get-GLWorkStatus -Jobs $script:Jobs
        $script:UI.Busy.Visibility      = 'Visible'
        $script:UI.BtnCancel.Visibility = 'Collapsed'
        if ($ws.Max -gt 0) {
            $script:UI.Busy.IsIndeterminate = $false
            $script:UI.Busy.Maximum = $ws.Max
            $script:UI.Busy.Value   = $ws.Value
        }
        else { $script:UI.Busy.IsIndeterminate = $true }
        $script:UI.TxtStatus.Text = 'Working: ' + $ws.Text
        # next to the list that is loading, too
        $cn = @($script:Jobs | Where-Object { $_.Name -eq 'Loading connections' -and $_.Report -and $_.Report.Stage })[0]
        if ($cn -and $script:UI.TxtCnCount) { $script:UI.TxtCnCount.Text = 'Loading - ' + ((Get-GLWorkStatus -Jobs @($cn)).Text -replace '^Loading connections: ', '') }
    }
    else {
        $script:UI.Busy.Visibility      = 'Collapsed'
        $script:UI.BtnCancel.Visibility = 'Collapsed'
        $script:UI.TxtStatus.Text       = 'Ready'
    }
}

function Test-GLJobRunning([string]$Name) {
    return [bool]($script:Jobs | Where-Object { $_.Name -eq $Name })
}

function Get-GLTokenSafe {
    param([string]$For)
    try { return (Get-GLToken $For) }
    catch {
        Write-GLLog "Could not get a $For token: $($_.Exception.Message). Restart $($script:AppName) to sign in again." 'Error'
        return $null
    }
}

function Write-GLResults {
    # A run's outcome, then every item with what happened to it - the failures in
    # red. Past 1,000 items the rest go to the log file only, so the panel stays quick.
    param([string]$What, $Results)
    $all = @($Results)
    $bad = @($all | Where-Object { -not $_.Ok })
    $ok  = $all.Count - $bad.Count
    Write-GLLog "${What}: $ok done, $($bad.Count) not done." $(if ($bad.Count) { 'Warn' } else { 'Ok' })
    $n = 0
    foreach ($r in $all) {
        $n++
        $line = "    $($r.Name): $($r.Message)"
        if ($n -le 1000) { Write-GLLog $line $(if ($r.Ok) { 'Ok' } else { 'Error' }) } else { Write-GLLog $line -FileOnly }
    }
    if ($n -gt 1000) { Write-GLLog "    ... and $($n - 1000) more - all of them are in the log file (Open folder)." }
}

function Get-GLRunAudit {
    # No record, no change: every change starts by making sure it can be recorded.
    $a = New-GLAudit -Folder $script:LogFolder -User $script:SignedInAs -Tenant $script:TenantShown -Version $script:AppVersion
    $err = Test-GLChangeRecord -Audit $a
    if ($err) {
        Write-GLLog "Nothing was changed: the change record in $($script:LogFolder) cannot be written - $err" 'Error'
        return $null
    }
    return $a
}

function Set-GLRowColor {
    # Theme-aware: the row refers to the brush by name, so a theme switch recolours it.
    param($Row, [string]$Brush)
    if ($Brush) { $Row.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, $Brush) }
    else { $Row.ClearValue([System.Windows.Controls.Control]::ForegroundProperty) }
}

function Confirm-GL {
    param([string]$Text, [string]$Title = 'Please confirm')
    return ([System.Windows.MessageBox]::Show($Text, $Title, 'YesNo', 'Warning') -eq 'Yes')
}

function Show-GLTypedConfirm {
    # For the irreversible: the user has to type the expected text.
    param([string]$Message, [string]$Ask, [string]$Expected)
    [xml]$x = $script:PromptXaml
    $dlg = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($x))
    $dlg.Owner = $script:Window
    Initialize-GLDialog -Dialog $dlg
    $c = @{}
    foreach ($n in 'PrmMessage', 'PrmAsk', 'PrmInput', 'PrmOk') { $c[$n] = $dlg.FindName($n) }
    $c.PrmMessage.Text = $Message
    $c.PrmAsk.Text     = $Ask
    $state = @{ Ok = $false }
    $c.PrmOk.Add_Click({
        if ($c.PrmInput.Text.Trim() -ne $Expected) { $c.PrmInput.Focus(); return }
        $state.Ok = $true
        $dlg.Close()
    }.GetNewClosure())
    $dlg.Add_Loaded({ $c.PrmInput.Focus() }.GetNewClosure())
    [void]$dlg.ShowDialog()
    return $state.Ok
}

# ---- grids: read-only cells, a sort that lasts, copying ----------------------------
$script:GridSort = @{}       # grid name -> the sort the user chose, kept across new rows
$script:Grids    = @('GridMembers', 'GridGwAccess', 'GridConnections', 'GridCnAccess')

function New-GLGridColumn {
    <#
        A grid column: the value as text, and on a double-click the same value as
        read-only text, all of it selected, to copy all or part of it. Both bindings
        are one-way, so nothing is ever written back. A template column, because WPF
        refuses to open a text column whose binding is one-way.
    #>
    param([Parameter(Mandatory)][string]$Property, $Header)
    $show = [System.Windows.FrameworkElementFactory]::new([System.Windows.Controls.TextBlock])
    $b = [System.Windows.Data.Binding]::new($Property)
    $b.Mode = [System.Windows.Data.BindingMode]::OneWay
    $show.SetBinding([System.Windows.Controls.TextBlock]::TextProperty, $b)
    $edit = [System.Windows.FrameworkElementFactory]::new([System.Windows.Controls.TextBox])
    $b = [System.Windows.Data.Binding]::new($Property)
    $b.Mode = [System.Windows.Data.BindingMode]::OneWay
    $edit.SetBinding([System.Windows.Controls.TextBox]::TextProperty, $b)
    $edit.SetValue([System.Windows.Controls.TextBox]::IsReadOnlyProperty, $true)
    $edit.SetValue([System.Windows.FrameworkElement]::StyleProperty, $null)      # plain text, not the input box look
    $edit.SetValue([System.Windows.Controls.Control]::BorderThicknessProperty, [System.Windows.Thickness]::new(0))
    $edit.SetValue([System.Windows.Controls.Control]::PaddingProperty, [System.Windows.Thickness]::new(0))
    $edit.SetValue([System.Windows.Controls.Control]::VerticalContentAlignmentProperty, [System.Windows.VerticalAlignment]::Center)
    $edit.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'InputBg')
    $edit.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'Ink')
    $edit.SetResourceReference([System.Windows.Controls.Primitives.TextBoxBase]::CaretBrushProperty, 'Ink')
    $col = [System.Windows.Controls.DataGridTemplateColumn]::new()
    $col.Header = if ($null -ne $Header) { $Header } else { $Property }
    $col.SortMemberPath = $Property
    $col.CellTemplate = [System.Windows.DataTemplate]::new()
    $col.CellTemplate.VisualTree = $show
    $col.CellEditingTemplate = [System.Windows.DataTemplate]::new()
    $col.CellEditingTemplate.VisualTree = $edit
    $col.ClipboardContentBinding = [System.Windows.Data.Binding]::new($Property)
    return $col
}

function Set-GLGridItems {
    <#
        New rows for a grid, keeping the sort the user chose - WPF forgets it whenever
        the rows are replaced, which every refresh and filter does. The columns are
        made again then, and their AutoGeneratingColumn handler puts the arrow back.
        -NoSort leaves the rows in the order given.
    #>
    param([Parameter(Mandatory)]$Grid, $Items, [switch]$NoSort)
    # not -not $Grid.Items: an empty grid counts as false, and its sort would be lost
    $keep = if ($NoSort -or $null -eq $Grid.Items) { @() } else { @($Grid.Items.SortDescriptions | ForEach-Object { $_ }) }
    $script:GridSort[[string]$Grid.Name] = $keep
    try { $null = $Grid.CancelEdit() } catch { }         # a cell open for copying
    $Grid.ItemsSource = $Items
    foreach ($sd in $keep) { $Grid.Items.SortDescriptions.Add($sd) }
}

function Get-GLGridColumns($Grid) {
    # The columns as they are shown: in their order, by the property each one shows.
    return , @($Grid.Columns | Where-Object { $_.Visibility -eq 'Visible' -and $_.SortMemberPath } | Sort-Object DisplayIndex |
        ForEach-Object { [pscustomobject]@{ Header = [string]$_.Header; Property = [string]$_.SortMemberPath } })
}

function Get-GLGridText {
    # A grid's rows as clipboard text, in the order shown - the selected rows, or -All.
    param([Parameter(Mandatory)]$Grid, [switch]$All, [switch]$Headers)
    $view = @($Grid.Items | Where-Object { $_ })
    if ($All) { $rows = $view }
    else {
        $picked = [System.Collections.Generic.HashSet[object]]::new()
        foreach ($i in $Grid.SelectedItems) { [void]$picked.Add($i) }
        $rows = @($view | Where-Object { $picked.Contains($_) })
    }
    $cols = Get-GLGridColumns $Grid
    return [pscustomobject]@{ Count = @($rows).Count; Text = (ConvertTo-GLClipboardText -Rows $rows -Columns $cols -Headers:$Headers) }
}

function Copy-GLGridRows {
    param([Parameter(Mandatory)]$Grid, [switch]$All, [switch]$Headers)
    $t = Get-GLGridText -Grid $Grid -All:$All -Headers:$Headers
    if (-not $t.Count) {
        Write-GLLog $(if ($All) { 'The list is empty - nothing to copy.' } else { 'Select the rows to copy first (Ctrl or Shift for several).' }) 'Warn'
        return
    }
    [System.Windows.Clipboard]::SetText($t.Text)
    $with = if ($Headers) { ' with the column names' } else { '' }
    Write-GLLog "Copied $($t.Count) row(s)$with - they paste into Excel as cells."
}

function Copy-GLGridCell {
    param([Parameter(Mandatory)]$Grid)
    $cc = $Grid.CurrentCell
    if (-not $cc.IsValid -or -not $cc.Column.SortMemberPath) { Write-GLLog 'Click the cell to copy first.' 'Warn'; return }
    $text = ConvertTo-GLClipboardText -Rows @($cc.Item) -Columns @([pscustomobject]@{ Header = ''; Property = $cc.Column.SortMemberPath })
    if (-not $text) { Write-GLLog "That $($cc.Column.Header) is empty - nothing to copy." 'Warn'; return }
    [System.Windows.Clipboard]::SetText($text)
    Write-GLLog "Copied the $($cc.Column.Header)."
}

function Add-GLGridCopy {
    <#
        Copying from a grid: Ctrl+C the selected rows, Ctrl+Shift+C with the column
        names, and both on the right-click menu with the cell and all rows. A cell
        opened by a double-click keeps Ctrl+C for the text selected in it.
    #>
    param([Parameter(Mandatory)]$Grid)
    $menu = [System.Windows.Controls.ContextMenu]::new()
    foreach ($m in @(
            , @('Copy cell', '', 'Cell')
            , @('Copy rows', 'Ctrl+C', 'Rows')
            , @('Copy rows with column names', 'Ctrl+Shift+C', 'RowsHeaders')
            , @('Copy all rows with column names', '', 'AllHeaders'))) {
        $item = [System.Windows.Controls.MenuItem]::new()
        $item.Header = $m[0]
        $item.InputGestureText = $m[1]
        $item.Tag = $m[2]
        $item.Add_Click({
            param($s, $e)
            $g = $s.Parent.PlacementTarget
            switch ([string]$s.Tag) {
                'Cell'        { Copy-GLGridCell -Grid $g }
                'Rows'        { Copy-GLGridRows -Grid $g }
                'RowsHeaders' { Copy-GLGridRows -Grid $g -Headers }
                'AllHeaders'  { Copy-GLGridRows -Grid $g -All -Headers }
            }
        })
        $null = $menu.Items.Add($item)
    }
    $Grid.ContextMenu = $menu
    $copy = [System.Windows.Input.CommandBinding]::new([System.Windows.Input.ApplicationCommands]::Copy)
    $copy.Add_Executed({ param($s, $e) Copy-GLGridRows -Grid $s; $e.Handled = $true })
    $null = $Grid.CommandBindings.Add($copy)
    $Grid.Add_PreviewKeyDown({
        param($s, $e)
        $both = [System.Windows.Input.ModifierKeys]::Control -bor [System.Windows.Input.ModifierKeys]::Shift
        if ($e.Key -eq 'C' -and [System.Windows.Input.Keyboard]::Modifiers -eq $both -and $e.OriginalSource -isnot [System.Windows.Controls.TextBox]) {
            Copy-GLGridRows -Grid $s -Headers
            $e.Handled = $true
        }
    })
}

function Add-GLTileCopy {
    # The gateway tiles: a right-click selects the tile under the mouse and offers to
    # copy it, all of them, or its id. Ctrl+C copies the selected gateway.
    $list = $script:UI.LstGwTiles
    $menu = [System.Windows.Controls.ContextMenu]::new()
    foreach ($m in @(@('Copy this gateway', 'Ctrl+C', 'One'), @('Copy all gateways', '', 'All'), @('Copy id', '', 'Id'))) {
        $item = [System.Windows.Controls.MenuItem]::new()
        $item.Header = $m[0]
        $item.InputGestureText = $m[1]
        $item.Tag = $m[2]
        $item.Add_Click({
            param($s, $e)
            switch ([string]$s.Tag) {
                'One' { Copy-GLGateways -SelectedOnly }
                'All' { Copy-GLGateways }
                'Id'  { Copy-GLId -Grid $script:UI.LstGwTiles }
            }
        })
        $null = $menu.Items.Add($item)
    }
    $list.ContextMenu = $menu
    $list.Add_PreviewMouseRightButtonDown({
        param($s, $e)
        $d = $e.OriginalSource
        try { while ($d -and $d -isnot [System.Windows.Controls.ListBoxItem]) { $d = [System.Windows.Media.VisualTreeHelper]::GetParent($d) } } catch { $d = $null }
        if ($d) { $d.IsSelected = $true }
    })
    $copy = [System.Windows.Input.CommandBinding]::new([System.Windows.Input.ApplicationCommands]::Copy)
    $copy.Add_Executed({ param($s, $e) Copy-GLGateways -SelectedOnly; $e.Handled = $true })
    $null = $list.CommandBindings.Add($copy)
}

function Test-GLGridBehaviour {
    <#
        For the smoke test, in the real window: a header click sorts, and the sort
        survives new rows; a cell opens as read-only text and writes nothing back;
        selected rows copy with their column names. Returns what went wrong, or ''.
    #>
    param([Parameter(Mandatory)]$Grid)
    $bad = [System.Collections.Generic.List[string]]::new()
    $byName = { param($G) $G.Columns | Where-Object SortMemberPath -eq 'Name' | Select-Object -First 1 }
    $col = & $byName $Grid
    if (-not $col) { return 'the grid has no Name column' }
    $click = [System.Windows.Controls.DataGrid].GetMethod('OnSorting', [System.Reflection.BindingFlags]'Instance,NonPublic')
    foreach ($n in 1, 2) { $null = $click.Invoke($Grid, @([System.Windows.Controls.DataGridSortingEventArgs]::new((& $byName $Grid)))) }
    $descending = {
        param($Names)
        for ($i = 1; $i -lt $Names.Count; $i++) { if ([string]::Compare([string]$Names[$i - 1], [string]$Names[$i], [System.StringComparison]::CurrentCulture) -lt 0) { return $false } }
        return $true
    }
    if (-not (& $descending @($Grid.Items | ForEach-Object Name))) { $bad.Add('two clicks on the Name header did not sort it descending') }
    Show-GLConnections                                   # new rows, as every filter change makes
    if (-not (& $descending @($Grid.Items | ForEach-Object Name)) -or (& $byName $Grid).SortDirection -ne 'Descending') {
        $bad.Add('the sort, or its arrow, was lost when the rows were shown again')
    }

    $item = @($Grid.Items)[0]
    $pathCol = $Grid.Columns | Where-Object SortMemberPath -eq 'Path' | Select-Object -First 1
    $before = [string]$item.Path
    $null = $Grid.Focus()
    $Grid.ScrollIntoView($item)
    $Grid.SelectedItem = $item
    $Grid.CurrentCell = [System.Windows.Controls.DataGridCellInfo]::new($item, $pathCol)
    $Grid.UpdateLayout()
    $began = $Grid.BeginEdit()
    $Grid.UpdateLayout()
    $box = $pathCol.GetCellContent($item)
    if ($box -and $box -isnot [System.Windows.Controls.TextBox] -and [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($box)) {
        $box = [System.Windows.Media.VisualTreeHelper]::GetChild($box, 0)
    }
    if (-not $began -or $box -isnot [System.Windows.Controls.TextBox] -or -not $box.IsReadOnly) { $bad.Add('a cell did not open as read-only text') }
    else {
        $box.Text = 'CHANGED BY THE SMOKE TEST'
        $null = $Grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true)
        if ([string]$item.Path -ne $before) { $bad.Add('a cell wrote its text back into the row') }
    }

    $Grid.SelectedItems.Clear()
    foreach ($i in @(@($Grid.Items)[0..1])) { $null = $Grid.SelectedItems.Add($i) }
    $copied = Get-GLGridText -Grid $Grid -Headers
    $lines = @($copied.Text -split "`r`n")
    if ($copied.Count -ne 2 -or $lines.Count -ne 3 -or $lines[0] -notmatch "^Name`tConnectivity`t") { $bad.Add("copying 2 rows with the column names gave $($lines.Count) line(s)") }
    $Grid.SelectedItems.Clear()
    return ($bad -join '; ')
}

# ---- gateways ------------------------------------------------------------------
function Show-GLGateways {
    # Rebuilt on every refresh, so "down for" moves on even when nothing else changed.
    # -Say: the user changed the filter - the log says what is shown now.
    param([switch]$Say)
    $selId = if ($script:UI.LstGwTiles.SelectedItem) { $script:UI.LstGwTiles.SelectedItem.Id } else { $null }
    $counts = if (@($script:State.ConnRows).Count) { Get-GLConnectionCounts -Rows $script:State.ConnRows -Directory $script:State.Directory } else { $null }
    $tiles = ConvertTo-GLGatewayTiles -Rows $script:State.GatewayRows -Members $script:State.Members -DownSince $script:State.DownSince -VnetSkipped:([bool]$script:State.VnetSkipped) -Live $script:State.Live -Releases $script:State.Releases -ConnectionCounts $counts
    $shown = Select-GLByText -Rows $tiles -Text $script:UI.TxtGwFilter.Text
    $script:State.Tiles = $tiles
    $script:UI.LstGwTiles.ItemsSource = $shown
    if ($selId) {
        $again = $shown | Where-Object { $_.Id -eq $selId } | Select-Object -First 1
        if ($again) { $script:UI.LstGwTiles.SelectedItem = $again }
    }
    Update-GLGatewaySummary
    if ($Say -and @($tiles).Count) { Write-GLLog "Gateways shown: $(@($shown).Count) of $(@($tiles).Count)." }
}

function Update-GLGatewaySummary {
    $n = Get-GLGatewayCounts -Tiles $script:State.Tiles
    $script:UI.TxtGwTotal.Text    = "$($n.Total) gateway$(if ($n.Total -ne 1) { 's' })"
    $script:UI.TxtGwDown.Text     = if ($n.Offline)  { "$($n.Offline) offline" } else { '' }
    $script:UI.TxtGwDegraded.Text = if ($n.Degraded) { "$($n.Degraded) degraded" } else { '' }
    $parts = @()
    if ($script:State.Live) {
        $vals = @($script:State.Live.Values)
        $up   = @($vals | Where-Object { $_.Status -eq 'Live' }).Count
        $parts += "$up of $($vals.Count) members online"
        $slow = @($vals | Where-Object { $_.Status -eq 'Timeout' }).Count
        if ($slow) { $parts += "$slow did not answer" }
    }
    elseif ($n.Total) { $parts += 'live status is off' }
    $rel = $script:State.Releases
    if ($rel -and $rel.Newest) {
        $when = if ($rel.Published) { ', ' + $rel.Published.ToString('d MMM yyyy', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }
        $parts += "newest gateway $($rel.Newest)$when"
        if ($n.Unsupported) { $parts += "$($n.Unsupported) not supported" }
        if ($n.Behind)      { $parts += "$($n.Behind) can be updated" }
        if ($n.Mixed)       { $parts += "$($n.Mixed) on mixed versions" }
    }
    elseif ($n.Drift) { $parts += "$($n.Drift) with version drift" }
    if ($n.NearLimit) { $parts += "$($n.NearLimit) near the 1,000 connection limit" }
    if (@($script:UI.LstGwTiles.ItemsSource).Count -ne $n.Total) { $parts += "$(@($script:UI.LstGwTiles.ItemsSource).Count) shown" }
    $script:UI.TxtGwSummary.Text = $parts -join '   |   '
    Update-GLRefreshCountdown
}

function Get-GLCountdownText {
    # "Updated 22:13:58 | next in 0:42" - with auto-refresh on; "refreshing now" while it loads.
    param($LastRefresh, $NextAt, [bool]$Busy, [datetime]$Now = (Get-Date))
    if (-not $LastRefresh) { return $(if ($Busy) { 'Loading...' } else { '' }) }
    $text = 'Updated {0:HH:mm:ss}' -f $LastRefresh
    if ($Busy) { return "$text   |   refreshing now" }
    if ($NextAt) {
        $left = [Math]::Max(0, [int][Math]::Ceiling(([datetime]$NextAt - $Now).TotalSeconds))
        $text += '   |   next in {0}:{1:00}' -f [int][Math]::Floor($left / 60), ($left % 60)
    }
    return $text
}

function Update-GLRefreshCountdown {
    if (-not $script:UI.TxtGwUpdated) { return }
    $next = if ($script:AutoTimer -and $script:AutoTimer.IsEnabled) { $script:NextAutoRefresh } else { $null }
    $text = Get-GLCountdownText -LastRefresh $script:State.LastRefresh -NextAt $next -Busy (Test-GLJobRunning 'Loading gateways')
    if ([string]$script:UI.TxtGwUpdated.Text -ne $text) { $script:UI.TxtGwUpdated.Text = $text }
}

function Invoke-GLReleaseCheck {
    # Microsoft's newest gateway version: once a session, and again after 12 hours,
    # because a kiosk view can run for days.
    if (Test-GLJobRunning 'Reading the newest gateway version') { return }
    if ($script:State.Releases -and ((Get-Date) - $script:State.Releases.Checked).TotalHours -lt 12) { return }
    Start-GLJob -Quiet -Name 'Reading the newest gateway version' -Work {
        Get-GLGatewayReleases
    } -OnDone {
        param($r, $err, $ctx)
        if ($err -or -not $r) { return }
        $script:State.Releases = $r          # kept even when empty, so it is not asked again at once
        foreach ($l in $r.Log) { Write-GLLog "Gateway versions: $l" -FileOnly }
        if ($r.Newest) {
            $inv  = [System.Globalization.CultureInfo]::InvariantCulture
            $when = if ($r.Published) { ", published $($r.Published.ToString('d MMMM yyyy', $inv))" } else { '' }
            $sup  = @($r.Supported)
            $from = if ($sup.Count) { " Microsoft supports $($sup[$sup.Count - 1].Version) ($($sup[$sup.Count - 1].Name)) and later." } else { '' }
            Write-GLLog "Newest on-premises gateway: $($r.Newest)$when.$from"
        }
        else {
            Write-GLLog "Could not read the newest gateway version from Microsoft's website, so version badges compare members with each other only. The log file says why." 'Warn'
        }
        Show-GLGateways
        Update-GLGatewayDetail
    }
}

function Set-GLGatewayList {
    # Gateway objects arrive from both refreshes; keys and names come from them.
    param($Gateways)
    if (-not $Gateways) { return }
    $script:State.GatewayList = $Gateways
    foreach ($g in $Gateways) {
        if ($g.publicKey) { $script:State.PublicKeys[([string]$g.id).ToLowerInvariant()] = $g.publicKey }
    }
}

function Update-GLGatewayRows {
    <#
        Gateway rows, their states and the down times, from what the state holds -
        after a full refresh or after one cluster was read again. The connections
        are drawn again only when a gateway's state changed: redrawing thousands of
        rows takes seconds, and the auto-refresh used to do it every minute.
    #>
    $script:State.GatewayRows = ConvertTo-GLGatewayRows -Gateways $script:State.Gateways -Members $script:State.Members -Live $script:State.Live
    $before = $script:State.GatewayState
    $now = @{}
    foreach ($row in $script:State.GatewayRows) { $now[([string]$row.Id).ToLowerInvariant()] = Get-GLGatewayState $row.Online }
    $script:State.GatewayState = $now
    $script:State.LastRefresh  = Get-Date
    $script:State.DownSince    = Update-GLDownSince -DownSince $script:State.DownSince -Live $script:State.Live -Now $script:State.LastRefresh
    $changed = (-not $before) -or $before.Count -ne $now.Count -or @($now.Keys | Where-Object { $before[$_] -ne $now[$_] }).Count
    if ($changed -and @($script:State.ConnRows).Count) { Show-GLConnections }
}

function Invoke-GLClusterRefresh {
    # One gateway cluster read again - its members and their live status - after a
    # change to it. The other clusters are left as they are.
    param([Parameter(Mandatory)][string]$GatewayId, [string]$Name)
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $live = [bool]$script:UI.ChkLive.IsChecked
    $pbi  = if ($live) { Get-GLTokenSafe PowerBI } else { $null }
    Start-GLJob -Name "Loading gateway '$Name'" -Arguments @{ F = $fab; P = $pbi; G = $GatewayId } -Context @{ Id = $GatewayId; Name = $Name } -Work {
        param($F, $P, $G)
        $mem = Get-GLPaged -Uri "https://api.fabric.microsoft.com/v1/gateways/$G/members" -Token $F
        $state = $null; $warn = ''
        if ($P) {
            try { $state = Get-GLLiveStatus -PbiToken $P -OnlyClusterIds @($G) }
            catch { $warn = "Live status is unavailable (unofficial API): $($_.Exception.Message)" }
        }
        @{ Members = @($mem); Live = $state; Warn = $warn }
    } -OnDone {
        param($r, $err, $ctx)
        if ($err -or -not $r) { return }
        if ($r.Warn) { Write-GLLog $r.Warn 'Warn' }
        $script:State.Members[$ctx.Id] = $r.Members
        if ($r.Live) {
            if (-not $script:State.Live) { $script:State.Live = @{} }
            foreach ($m in $r.Members) { $script:State.Live.Remove(([string]$m.id).ToLowerInvariant()) }
            foreach ($k in $r.Live.Keys) { $script:State.Live[$k] = $r.Live[$k] }
        }
        Update-GLGatewayRows
        Invoke-GLAlerts -OnlyClusterIds @($ctx.Id)
        Show-GLGateways
        Update-GLGatewayDetail
        $on = @($r.Members | Where-Object { $_.enabled }).Count
        $up = if ($r.Live) { @($r.Live.Values | Where-Object Status -eq 'Live').Count } else { 'n/a' }
        Write-GLLog "Loaded gateway '$($ctx.Name)' again: $(@($r.Members).Count) member(s), $on enabled, $up online. The other gateways are as they were."
    }
}

function Invoke-GLGatewayRefresh {
    if (Test-GLJobRunning 'Loading gateways') { return }
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $live = [bool]$script:UI.ChkLive.IsChecked
    $pbi  = if ($live) { Get-GLTokenSafe PowerBI } else { $null }
    $skip = [bool]$script:UI.ChkSkipVnet.IsChecked

    Write-GLLog "Reading gateways: live member status $(if ($live) { 'on' } else { 'off' }), VNet gateways $(if ($skip) { 'skipped - not woken' } else { 'checked too' })."
    Start-GLJob -Report -Name 'Loading gateways' -Arguments @{ F = $fab; P = $pbi; L = $live; V = $skip } -Context @{ SkipVnet = $skip } -Work {
        param($F, $P, $L, $V, $Report)
        Get-GLGatewayData -FabricToken $F -PbiToken $P -LiveStatus:$L -CheckVnet:(-not $V) -Report $Report
    } -OnDone {
        param($r, $err, $ctx)
        if ($err -or -not $r) { return }
        foreach ($l in $r.Log) { Write-GLLog $l 'Warn' }
        $script:State.Gateways    = $r.Gateways
        $script:State.Members     = $r.Members
        $script:State.Live        = $r.Live
        $script:State.VnetSkipped = $ctx.SkipVnet
        Update-GLGatewayRows
        Invoke-GLAlerts
        Set-GLGatewayList $r.Gateways
        Show-GLGateways
        Update-GLGatewayDetail
        $members = ($r.Members.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
        Write-GLLog "Loaded all $(@($script:State.GatewayRows).Count) gateway(s) with $([int]$members) member(s). $($script:UI.TxtGwSummary.Text)" 'Ok'
        Invoke-GLReleaseCheck
    }
}

function Update-GLGatewayDetail {
    $row = $script:UI.LstGwTiles.SelectedItem
    if (-not $row) {
        Set-GLGridItems -Grid $script:UI.GridMembers -Items $null
        Show-GLAccessRows -Kind gateways -Rows @()
        $script:UI.TxtMembersTitle.Text     = 'Members'
        $script:State.AccessFor             = $null
        return
    }
    $mem = @()
    if ($script:State.Members.ContainsKey($row.Id)) { $mem = $script:State.Members[$row.Id] }
    Set-GLGridItems -Grid $script:UI.GridMembers -Items (ConvertTo-GLMemberRows -GatewayName $row.Name -Members $mem -Live $script:State.Live -Releases $script:State.Releases)
    $script:UI.TxtMembersTitle.Text    = "Members of $($row.Name)"
    if ($script:State.AccessFor -ne $row.Id) {
        $script:State.AccessFor = $row.Id
        Show-GLAccessRows -Kind gateways -Rows @()
        Update-GLAccess -Kind gateways -Id $row.Id -Name $row.Name
    }
}

function Set-GLAutoRefresh {
    if (-not $script:AutoTimer) {
        $script:AutoTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:AutoTimer.Add_Tick({
            $script:NextAutoRefresh = (Get-Date).Add($script:AutoTimer.Interval)
            if ($script:Progress.Active) { Write-GLLog 'Auto-refresh skipped - a run is still going.'; return }
            Write-GLLog 'Auto-refresh: loading the gateways again.'
            Invoke-GLGatewayRefresh
        })
    }
    if (-not $script:ClockTimer) {
        # the countdown on the Gateways tab, once a second
        $script:ClockTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:ClockTimer.Interval = [TimeSpan]::FromSeconds(1)
        $script:ClockTimer.Add_Tick({ Update-GLRefreshCountdown })
        $script:ClockTimer.Start()
    }
    $was = $script:AutoTimer.IsEnabled
    $script:AutoTimer.Stop()
    $script:NextAutoRefresh = $null
    $choice = [string]$script:UI.CmbAutoRefresh.SelectedItem
    if ($choice -match '^(\d+) min') {
        $script:AutoTimer.Interval = [TimeSpan]::FromMinutes([int]$Matches[1])
        $script:AutoTimer.Start()
        $script:NextAutoRefresh = (Get-Date).Add($script:AutoTimer.Interval)
        Write-GLLog "Gateways refresh automatically every $($Matches[1]) minute(s)."
    }
    elseif ($was) { Write-GLLog 'Auto-refresh is off.' }
    Update-GLRefreshCountdown
}

function Get-GLGatewayExport {
    # The gateway rows behind the tiles on screen, each with what its tile says.
    $byId = @{}
    foreach ($r in $script:State.GatewayRows) { $byId[$r.Id] = $r }
    $out = foreach ($tile in @($script:UI.LstGwTiles.ItemsSource)) {
        $r = $byId[$tile.Id]
        if (-not $r) { continue }
        $o = $r | Select-Object -Property *
        $o | Add-Member -NotePropertyName Status -NotePropertyValue $tile.Status -Force
        $o | Add-Member -NotePropertyName VersionDrift -NotePropertyValue $tile.Badge -Force
        $o | Add-Member -NotePropertyName Down -NotePropertyValue $tile.DownText -Force
        $o | Add-Member -NotePropertyName Connections -NotePropertyValue $tile.Connections -Force
        $o
    }
    return , @($out)
}

function Enter-GLKiosk {
    # Full screen, gateway tiles only, nothing that changes anything - for a wall screen.
    if ($script:KioskSaved) { return }
    $w = $script:Window
    $script:KioskSaved = @{
        State = $w.WindowState; Style = $w.WindowStyle; Resize = $w.ResizeMode
        Tab = $script:UI.Tabs.SelectedIndex; Log = $script:UI.LogRow.Height; Detail = $script:UI.GwDetailRow.Height
        Auto = [string]$script:UI.CmbAutoRefresh.SelectedItem
    }
    $script:UI.Tabs.SelectedItem = $script:UI.TabGateways
    foreach ($n in 'HeaderBar', 'LogPanel', 'LogSplitter', 'GwToolbar', 'GwSplitter', 'GwDetail', 'TabConnections', 'MeterPanel') { $script:UI[$n].Visibility = 'Collapsed' }
    $script:UI.LogRow.Height      = [System.Windows.GridLength]::new(0)
    $script:UI.GwDetailRow.Height = [System.Windows.GridLength]::new(0)
    $script:UI.BtnKioskExit.Visibility = 'Visible'
    $script:UI.LstGwTiles.SelectedItem = $null
    $w.WindowStyle = 'None'
    $w.ResizeMode  = 'NoResize'
    $w.WindowState = 'Normal'        # maximising again with no border covers the taskbar too
    $w.WindowState = 'Maximized'
    if ([string]$script:UI.CmbAutoRefresh.SelectedItem -eq 'Off') { $script:UI.CmbAutoRefresh.SelectedItem = '1 min' }
    Write-GLLog 'Kiosk view: gateways only, nothing can be changed here. Esc or F11 leaves it.'
}

function Exit-GLKiosk {
    $k = $script:KioskSaved
    if (-not $k) { return }
    Write-GLLog 'Kiosk view closed.'
    $script:KioskSaved = $null
    $w = $script:Window
    foreach ($n in 'HeaderBar', 'LogPanel', 'LogSplitter', 'GwToolbar', 'GwSplitter', 'GwDetail', 'TabConnections', 'MeterPanel') { $script:UI[$n].Visibility = 'Visible' }
    $script:UI.LogRow.Height      = $k.Log
    $script:UI.GwDetailRow.Height = $k.Detail
    $script:UI.BtnKioskExit.Visibility = 'Collapsed'
    $w.WindowState = 'Normal'
    $w.WindowStyle = $k.Style
    $w.ResizeMode  = $k.Resize
    $w.WindowState = $k.State
    $script:UI.Tabs.SelectedIndex = $k.Tab
    # the kiosk view turned auto-refresh on - it goes back to what it was
    if ($k.Auto -and [string]$script:UI.CmbAutoRefresh.SelectedItem -ne $k.Auto) { $script:UI.CmbAutoRefresh.SelectedItem = $k.Auto }
}

function Invoke-GLMemberEnabled {
    # Enable or disable the selected members of one gateway cluster - several at a
    # time, each named in the confirmation. Only that cluster is read again after.
    param([bool]$Enabled)
    $gw  = $script:UI.LstGwTiles.SelectedItem
    $sel = @($script:UI.GridMembers.SelectedItems | Where-Object { $_ })
    if (-not $gw -or $sel.Count -eq 0) { Write-GLLog 'Select a gateway and one or more of its members first (Ctrl or Shift for several).' 'Warn'; return }
    $state = if ($Enabled) { 'enabled' } else { 'disabled' }
    $plan  = Get-GLMemberPlan -Members $script:State.Members[$gw.Id] -Selected $sel -Enabled $Enabled
    if (@($plan.Change).Count -eq 0) { Write-GLLog "The selected member(s) are already $state." 'Warn'; return }

    $verb  = if ($Enabled) { 'Enable' } else { 'Disable' }
    $names = (@($plan.Change | ForEach-Object { "    $($_.Member)$(if ($_.Machine) { " ($($_.Machine))" })" }) -join "`n")
    $msg   = "$verb $(@($plan.Change).Count) member(s) of gateway '$($gw.Name)'?`n`n$names"
    if ($plan.Already) { $msg += "`n`n$($plan.Already) selected member(s) are already $state and are left alone." }
    if (-not $Enabled) {
        $msg += if ($plan.EnabledAfter -le 0) { "`n`nThis disables EVERY enabled member - the gateway stops serving refreshes entirely." }
                else { "`n`nRefreshes will be served by the $($plan.EnabledAfter) member(s) still enabled." }
    }
    if (-not (Confirm-GL $msg "$verb members")) { return }

    $audit = Get-GLRunAudit
    if (-not $audit) { return }
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $members = @($plan.Change | ForEach-Object { [pscustomobject]@{ Id = [string]$_.Id; Member = [string]$_.Member; Machine = [string]$_.Machine } })
    $target  = [pscustomobject]@{ Id = [string]$gw.Id; Name = [string]$gw.Name }
    Start-GLJob -Bulk -Name "$verb $($members.Count) member(s) of '$($gw.Name)'" `
        -Arguments @{ F = $fab; Gw = $target; Members = $members; E = $Enabled; A = $audit } `
        -Context @{ What = "$verb members of '$($gw.Name)'"; GatewayId = [string]$gw.Id; Name = [string]$gw.Name } -Work {
        param($F, $Gw, $Members, $E, $A, $Progress)
        Invoke-GLBulkMembers -Gateway $Gw -Members $Members -Enabled $E -FabricToken $F -Progress $Progress -Audit $A
    } -OnDone {
        param($r, $err, $ctx)
        if ($err) { return }
        Write-GLResults $ctx.What $r
        Invoke-GLClusterRefresh -GatewayId $ctx.GatewayId -Name $ctx.Name
    }
}

function Get-GLClusterBlocks {
    # Gateway name plus its member rows, for every gateway on screen (or the selected one).
    param([switch]$SelectedOnly)
    $gws = if ($SelectedOnly) { @($script:UI.LstGwTiles.SelectedItem | Where-Object { $_ }) } else { @($script:UI.LstGwTiles.ItemsSource) }
    foreach ($g in $gws) {
        $mem = @()
        if ($script:State.Members.ContainsKey($g.Id)) { $mem = $script:State.Members[$g.Id] }
        [pscustomobject]@{ Name = $g.Name; Type = $g.Type; Rows = (ConvertTo-GLMemberRows -GatewayName $g.Name -Members $mem -Live $script:State.Live -Releases $script:State.Releases) }
    }
}

function Copy-GLGateways {
    param([switch]$SelectedOnly)
    $blocks = @(Get-GLClusterBlocks -SelectedOnly:$SelectedOnly)
    if ($blocks.Count -eq 0) { Write-GLLog 'Nothing to copy - select a gateway first.' 'Warn'; return }
    $lines = @("Gateway`tMember`tMachine`tVersion`tEnabled`tStatus")
    foreach ($b in $blocks) {
        if ($b.Rows.Count) { $lines += (Format-GLClusterText -GatewayName $b.Name -MemberRows $b.Rows) }
        else { $lines += "$($b.Name)`t`t`t`t`t$($b.Type)" }
    }
    [System.Windows.Clipboard]::SetText($lines -join "`r`n")
    $n = ($blocks | ForEach-Object { $_.Rows.Count } | Measure-Object -Sum).Sum
    Write-GLLog "Copied $($blocks.Count) gateway(s) and $([int]$n) member(s) to the clipboard."
}

function Invoke-GLResolveIps {
    param([switch]$SelectedOnly)
    $blocks = @(Get-GLClusterBlocks -SelectedOnly:$SelectedOnly | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Machines = @($_.Rows | ForEach-Object { $_.Machine } | Where-Object { $_ } | Select-Object -Unique) }
    } | Where-Object { $_.Machines.Count })
    if ($blocks.Count -eq 0) {
        Write-GLLog 'No machine names to resolve. They come from live status - tick Live member status and refresh.' 'Warn'
        return
    }
    Start-GLJob -Name 'Resolving IP addresses' -Arguments @{ Blocks = $blocks; S = $script:DnsSuffixes } -Work {
        param($Blocks, $S)
        # one result - the whole list: a job's result is the LAST thing it writes
        $all = foreach ($b in $Blocks) {
            [pscustomobject]@{ Name = $b.Name; Lines = @($b.Machines | ForEach-Object { Resolve-GLHostAddress -Machine $_ -Suffixes $S }) }
        }
        , @($all)
    } -OnDone {
        param($r, $err, $ctx)
        if ($err) { return }
        $text = [System.Collections.Generic.List[string]]::new()
        foreach ($b in @($r)) {
            $block = (@($b.Name) + $b.Lines) -join "`r`n"
            Write-GLLog $block
            $text.Add($block)
        }
        [System.Windows.Clipboard]::SetText($text.ToArray() -join "`r`n`r`n")
        Write-GLLog 'IP list copied to the clipboard.'
    }
}

# ---- connections --------------------------------------------------------------
function Get-GLStateFilter {
    $s = @()
    if ($script:UI.ChkStOnline.IsChecked)  { $s += 'Online' }
    if ($script:UI.ChkStPartial.IsChecked) { $s += 'Partial' }
    if ($script:UI.ChkStOffline.IsChecked) { $s += 'Offline' }
    if ($script:UI.ChkStUnknown.IsChecked) { $s += 'Unknown' }
    if ($s.Count -eq 4) { return $null }     # all ticked = no filter
    return , $s
}

function Show-GLConnections {
    # -Say: the user changed a filter - the log says what the list shows now.
    param([switch]$Say)
    if ($script:State.Populating) { return }
    Set-GLRowGatewayState -Rows $script:State.ConnRows -GatewayState $script:State.GatewayState
    $cloud = [bool]$script:UI.ChkCnCloud.IsChecked
    $rows = Select-GLConnections -Rows $script:State.ConnRows -Text $script:UI.TxtCnSearch.Text `
        -Gateway ([string]$script:UI.CmbCnGateway.SelectedItem) `
        -Connectivity ([string]$script:UI.CmbCnConnectivity.SelectedItem) `
        -Type ([string]$script:UI.CmbCnType.SelectedItem) `
        -User $script:UI.TxtCnUser.Text -Account $script:UI.TxtCnAccount.Text `
        -States (Get-GLStateFilter) -Excluded $script:State.Excluded `
        -IncludeCloud:$cloud -Show ([string]$script:UI.CmbCnShow.SelectedItem)
    # the Duplicates view lists copies side by side - a column sort would part them
    Set-GLGridItems -Grid $script:UI.GridConnections -Items $rows -NoSort:([string]$script:UI.CmbCnShow.SelectedItem -eq 'Duplicates')
    $all = @($script:State.ConnRows | Where-Object { $cloud -or $_.Connectivity -ne 'ShareableCloud' }).Count
    $ex  = $script:State.Excluded.Count
    $txt = if ($rows.Count -eq $all) { "$all connection(s)" } else { "$($rows.Count) of $all connection(s)" }
    if ($ex) { $txt += "   ($ex excluded)" }
    $script:UI.TxtCnCount.Text   = $txt
    $script:UI.TxtBulkTitle.Text = "All $($rows.Count) listed connection(s)"
    if ($Say -and @($script:State.ConnRows).Count) { Write-GLLog "Listed: $txt." }
}

function Update-GLConnectionCombos {
    # The dropdowns offer what the list can show - cloud values only with cloud connections in.
    $cloud = [bool]$script:UI.ChkCnCloud.IsChecked
    $scope = @($script:State.ConnRows | Where-Object { $cloud -or $_.Connectivity -ne 'ShareableCloud' })
    $script:State.Populating = $true
    try {
        Set-GLComboValues $script:UI.CmbCnGateway      (Get-GLDistinct -Rows $scope -Property Gateway)
        Set-GLComboValues $script:UI.CmbCnConnectivity (Get-GLDistinct -Rows $scope -Property Connectivity)
        Set-GLComboValues $script:UI.CmbCnType         (Get-GLDistinct -Rows $scope -Property Type)
    }
    finally { $script:State.Populating = $false }
}

function Set-GLComboValues {
    param($Combo, $Values)
    $keep = [string]$Combo.SelectedItem
    $Combo.ItemsSource = $Values
    $Combo.SelectedItem = if ($keep -and ($Values -contains $keep)) { $keep } else { '(all)' }
}

function Invoke-GLConnectionRefresh {
    if (Test-GLJobRunning 'Loading connections') { return }
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $dir = [bool]$script:UI.ChkDirectory.IsChecked
    $pbi = if ($dir) { Get-GLTokenSafe PowerBI } else { $null }
    $gr  = if ($dir) { Get-GLTokenSafe Graph } else { $null }
    Write-GLLog "Reading connections: usernames and access from the unofficial API $(if ($dir) { 'on' } else { 'off' })."
    Start-GLJob -Report -ExpectConnections ([int]$script:Settings.LastConnectionCount) -Name 'Loading connections' -Arguments @{ F = $fab; P = $pbi; G = $gr; D = $dir; Known = $script:State.Names } -Work {
        param($F, $P, $G, $D, $Known, $Report)
        $data = Get-GLConnectionData -FabricToken $F -Report $Report
        $directory = $null; $warn = $null; $names = @{}; $namesWarn = ''
        if ($D -and $P) {
            try { $directory = Get-GLDatasourceDirectory -PbiToken $P -Report $Report }
            catch { $warn = "Usernames and access are unavailable (unofficial API): $($_.Exception.Message)" }
        }
        if ($directory) {
            # the directory may give only object ids - the names come from Graph
            $ids = Get-GLDirectoryPrincipalIds -Directory $directory
            try { $names = Get-GLPrincipalNames -Ids $ids -GraphToken $G -Known $Known -Report $Report } catch { $namesWarn = $_.Exception.Message }
            foreach ($k in $Known.Keys) { if (-not $names.ContainsKey($k)) { $names[$k] = $Known[$k] } }
        }
        # the rows are made here: thousands of them would hold up the window
        Set-GLReport $Report 'making the rows' -Total @($data.Connections).Count
        $rows = ConvertTo-GLConnectionRows -Connections $data.Connections -GatewayNames (Get-GLGatewayNameMap -Gateways $data.Gateways)
        Add-GLDirectoryInfo -Rows $rows -Directory $directory -Names $names
        @{ Gateways = $data.Gateways; Connections = $data.Connections; Directory = $directory; Rows = $rows; Warn = $warn; Names = $names; NamesWarn = $namesWarn }
    } -OnDone {
        param($r, $err, $ctx)
        if ($err -or -not $r) { return }
        if ($r.Warn) { Write-GLLog $r.Warn 'Warn' }
        if ($r.Names) { Add-GLNames $r.Names $r.NamesWarn }
        $script:Settings.LastConnectionCount = @($r.Connections).Count      # "about how many" next time
        Set-GLGatewayList $r.Gateways
        $rows = @($r.Rows | Where-Object { $_ })
        $script:State.ConnRows  = $rows
        $script:State.Directory = $r.Directory
        $script:State.RawConnections = @{}
        foreach ($c in $r.Connections) { $script:State.RawConnections[[string]$c.id] = $c }
        $script:State.Excluded.Clear()

        Update-GLConnectionCombos
        Show-GLConnections
        Show-GLGateways              # the tiles count the connections on each gateway
        $note = ''
        if ($r.Directory) {
            $acc = @($rows | Where-Object { $_.Account }).Count
            $note = "; usernames for $acc, users for $(@($rows | Where-Object { $_.Users -ne '' }).Count)"
            $gone = @($rows | Where-Object { $_.UnknownUsers -gt 0 }).Count
            if ($gone) { $note += ". $gone connection(s) give access to accounts that are not in Microsoft Entra ID - deleted ones, which the portal does not show: Show > Access by accounts not in Entra ID" }
        }
        $cloudRows = @($rows | Where-Object Connectivity -eq 'ShareableCloud').Count
        if ($cloudRows -and -not $script:UI.ChkCnCloud.IsChecked) { $note += ". $cloudRows cloud connection(s) are hidden - tick Include cloud connections to see them" }
        Write-GLLog "Loaded $($rows.Count) connection(s)$note." 'Ok'
    }
}

function Update-GLConnectionDetail {
    $row = $script:UI.GridConnections.SelectedItem
    $id  = if ($row) { [string]$row.Id } else { '' }
    if ($id -and $id -eq $script:State.CnAccessFor) { return }      # another cell of the same row
    $script:State.CnAccessFor = $id
    Show-GLAccessRows -Kind connections -Rows @()
    if (-not $row) { $script:UI.TxtCnSelected.Text = 'Select a connection to see who has access.'; return }
    $where = if ($row.Gateway) { " on $($row.Gateway)" } else { '' }
    $script:UI.TxtCnSelected.Text = "$($row.Name)  -  $($row.Type)$where"
    Update-GLAccess -Kind connections -Id $row.Id -Name $row.Name
}

function Get-GLListed { return , @($script:UI.GridConnections.ItemsSource | Where-Object { $_ }) }

function Invoke-GLExclude {
    $sel = @($script:UI.GridConnections.SelectedItems)
    if ($sel.Count -eq 0) { Write-GLLog 'Select the rows to exclude first (Ctrl or Shift for several).' 'Warn'; return }
    foreach ($r in $sel) { [void]$script:State.Excluded.Add([string]$r.Id) }
    Show-GLConnections
    Write-GLLog "Excluded $($sel.Count) row(s) from the list. They are not touched by any bulk action."
}

# ---- bulk -----------------------------------------------------------------------
function Invoke-GLBulkStatusUi {
    # -Only: these connections instead of the list - with -Retest, the ones whose
    # credentials were just updated.
    param($Only, [switch]$Retest)
    $listed = if ($null -ne $Only) { @($Only) } else { Get-GLListed }      # assign first - piping it would pass the whole list as ONE item
    $items  = @($listed | Where-Object { $_.Connectivity -eq 'OnPremisesGateway' -and $_.GatewayId })
    if ($items.Count -eq 0) { Write-GLLog 'No on-premises gateway connections in the list to test.' 'Warn'; return }
    if (-not $Retest -and $items.Count -gt 200 -and -not (Confirm-GL "Test $($items.Count) connections?`n`nEach test makes the gateway contact the data source, so this takes a while and puts load on the gateways. It can be cancelled.")) { return }
    $pbi = Get-GLTokenSafe PowerBI
    if (-not $pbi) { return }
    $title = if ($Retest) { "Testing the $($items.Count) updated connection(s)" } else { "Testing $($items.Count) connection(s)" }
    Start-GLJob -Bulk -Name $title -Arguments @{ P = $pbi; Items = $items } -Context @{ Retest = [bool]$Retest } -Work {
        param($P, $Items, $Progress)
        # not $I: names ignore case, so a loop over $i would overwrite it
        # Ten at a time: a test can wait up to a minute for a gateway, and each batch
        # reports as soon as it is done - so the log keeps moving.
        $Progress.Total = $Items.Count
        $all = @{}
        for ($i = 0; $i -lt $Items.Count; $i += 10) {
            if ($Progress.Cancel) { break }
            $chunk = @($Items[$i..([Math]::Min($i + 10, $Items.Count) - 1)])
            $Progress.Said.Enqueue([pscustomobject]@{ Text = "  Testing $($i + 1)-$($i + $chunk.Count) of $($Items.Count)..."; Level = 'Info' })
            $res = Test-GLConnectionsBulk -Items $chunk -PbiToken $P
            foreach ($c in $chunk) {
                $o = ConvertTo-GLTestOutcome -Result $res[[string]$c.Id] -SkipTest ([bool]$c.SkipTest) -Name $c.Name
                $all[[string]$c.Id] = [pscustomobject]@{ Status = $o.Status; Detail = $o.Detail }
                $Progress.Said.Enqueue($o)
            }
            $Progress.Done = [Math]::Min($i + 10, $Items.Count)
        }
        $all
    } -OnDone {
        param($r, $err, $ctx)
        if ($err -or -not $r) { return }
        Set-GLRowStatus -Rows $script:State.ConnRows -Status $r
        $script:UI.GridConnections.Items.Refresh()
        $vals = @($r.Values)
        $ok = @($vals | Where-Object { $_.Status -eq 'OK' }).Count
        $to = @($vals | Where-Object { $_.Status -eq 'Timeout' }).Count
        $un = @($vals | Where-Object { $_.Status -eq 'Unverified' }).Count
        $bad = $vals.Count - $ok - $to - $un
        $unText = if ($un) { ", $un OK but not verified (Skip test connection is on)" } else { '' }
        if ($ctx.Retest) {
            $level = if ($bad -or $to -or $un) { 'Warn' } else { 'Info' }
            Write-GLLog "Tested after the credential update: $ok of $($vals.Count) work, $bad still fail, $to did not answer$unText. Show > Failing tests lists the ones to look at." $level
        }
        else { Write-GLLog "Status: $ok OK, $bad failed, $to did not answer$unText. See the Status and StatusDetail columns." $(if ($bad -or $to -or $un) { 'Warn' } else { 'Info' }) }
    }
}

function Invoke-GLBulkUsersUi {
    $items = Get-GLListed
    if ($items.Count -eq 0) { Write-GLLog 'The list is empty.' 'Warn'; return }
    Start-GLUsersRead -Items $items
}

function Start-GLUsersRead {
    <#
        Who has access to these connections, read fresh from Fabric, with names from
        Graph - for Verify users, and after every change to access. Every connection
        goes to the log with its users; one that could not be read, with the reason.
        The open access panel is filled from the same answer.
    #>
    param($Items, [string]$Why = 'Reading users')
    $list = @($Items | Where-Object { $_ })
    if ($list.Count -eq 0) { return }
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $gr  = Get-GLTokenSafe Graph
    $ids = @($list | ForEach-Object { [string]$_.Id })
    $nameOf = @{}
    foreach ($c in $list) { $nameOf[[string]$c.Id] = [string]$c.Name }
    Start-GLJob -Bulk -Name "$Why of $($ids.Count) connection(s)" -Arguments @{ F = $fab; G = $gr; Ids = $ids; Known = $script:State.Names } `
        -Context @{ Ids = $ids; NameOf = $nameOf } -Work {
        param($F, $G, $Ids, $Known, $Progress)
        $Progress.Total = $Ids.Count
        $all = @{}; $errors = @{}
        for ($i = 0; $i -lt $Ids.Count; $i += 25) {
            if ($Progress.Cancel) { break }
            $chunk = @($Ids[$i..([Math]::Min($i + 25, $Ids.Count) - 1)])
            $res = Get-GLRoleAssignmentsBulk -Ids $chunk -FabricToken $F -Errors $errors
            foreach ($k in $res.Keys) { $all[$k] = $res[$k] }
            $Progress.Done = [Math]::Min($i + 25, $Ids.Count)
        }
        $names = @{}; $warn = ''
        $who = @($all.Values | Where-Object { $_ } | ForEach-Object { $_ } | ForEach-Object { [string]$_.principal.id })
        try { $names = Get-GLPrincipalNames -Ids $who -GraphToken $G -Known $Known } catch { $warn = $_.Exception.Message }
        @{ Assignments = $all; Errors = $errors; Names = $names; Warn = $warn }
    } -OnDone {
        param($r, $err, $ctx)
        if ($err -or -not $r) { return }
        Add-GLNames $r.Names $r.Warn
        $as = $r.Assignments
        Set-GLRowUsers -Rows $script:State.ConnRows -Assignments $as -Names $script:State.Names
        try { $script:UI.GridConnections.Items.Refresh() } catch { }
        $bad = 0; $n = 0
        foreach ($id in $ctx.Ids) {
            if (-not $as.ContainsKey($id)) { continue }
            $n++
            $name = $ctx.NameOf[$id]
            if ($null -eq $as[$id]) {
                $bad++
                $reason = if ($r.Errors -and $r.Errors.ContainsKey($id)) { $r.Errors[$id] } else { 'no answer' }
                $line = "    ${name}: could not be read - $reason"
                if ($n -le 1000) { Write-GLLog $line 'Warn' } else { Write-GLLog $line -FileOnly }
                continue
            }
            $line = "    ${name}: $(Format-GLAccessList (ConvertTo-GLRoleRows -Assignments $as[$id] -Names $script:State.Names))"
            if ($n -le 1000) { Write-GLLog $line } else { Write-GLLog $line -FileOnly }
        }
        if ($n -gt 1000) { Write-GLLog "    ... and $($n - 1000) more - all of them are in the log file (Open folder)." }
        $tail = if ($bad) { ", $bad could not be read - each says why above" } else { '' }
        Write-GLLog "Users read for $($n - $bad) connection(s)$tail. The User filter now works on them." $(if ($bad) { 'Warn' } else { 'Info' })
        # the open access panel shows the same answer, without asking again
        $sel = Get-GLSelectedId connections
        if ($sel -and $as.ContainsKey($sel) -and $null -ne $as[$sel]) {
            $script:State.CnAccessFor = $sel
            Show-GLAccessRows -Kind connections -Rows (ConvertTo-GLRoleRows -Assignments $as[$sel] -Names $script:State.Names)
        }
    }
}

function Invoke-GLBulkAccessUi {
    param([switch]$Revoke)
    Save-GLFieldHistory 'TxtBulkPrincipals'
    $principals = Split-GLList $script:UI.TxtBulkPrincipals.Text
    if ($principals.Count -eq 0) { Write-GLLog 'Enter one or more emails, group names or object ids first.' 'Warn'; return }
    $items = Get-GLListed
    if ($items.Count -eq 0) { Write-GLLog 'The list is empty.' 'Warn'; return }
    $ptype = [string]$script:UI.CmbBulkPrincipalType.SelectedItem
    $role  = [string]$script:UI.CmbBulkRole.SelectedItem
    $who   = ($principals | ForEach-Object { "    $_" }) -join "`n"
    $msg   = if ($Revoke) { "Remove these $($ptype.ToLower())(s) from ALL $($items.Count) listed connection(s)?`n`n$who" }
             else { "Grant $role to these $($ptype.ToLower())(s) on ALL $($items.Count) listed connection(s)?`n`n$who" }
    if (-not (Confirm-GL $msg $(if ($Revoke) { 'Remove access' } else { 'Grant access' }))) { return }

    $audit = Get-GLRunAudit
    if (-not $audit) { return }
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $gr = Get-GLTokenSafe Graph
    $name = if ($Revoke) { "Removing access on $($items.Count) connection(s)" } else { "Granting $role on $($items.Count) connection(s)" }
    Start-GLJob -Bulk -Name $name -Arguments @{ F = $fab; G = $gr; I = $items; Pr = $principals; T = $ptype; R = $role; X = [bool]$Revoke; A = $audit } `
        -Context @{ What = $(if ($Revoke) { 'Remove access' } else { 'Grant access' }); Items = $items } -Work {
        param($F, $G, $I, $Pr, $T, $R, $X, $A, $Progress)
        # resolve everyone first - one unknown name stops the run before anything changes
        $resolved = foreach ($p in $Pr) {
            $w = Resolve-GLPrincipal -Value $p -Type $T -GraphToken $G
            [pscustomobject]@{ Id = $w.Id; DisplayName = $w.DisplayName; Type = $T }
        }
        if ($X) { Invoke-GLBulkRevoke -Items $I -Principals @($resolved) -FabricToken $F -Progress $Progress -Audit $A }
        else    { Invoke-GLBulkGrant  -Items $I -Principals @($resolved) -Role $R -FabricToken $F -Progress $Progress -Audit $A }
    } -OnDone {
        param($r, $err, $ctx)
        if ($err) { return }
        Write-GLResults $ctx.What $r
        Start-GLUsersRead -Items $ctx.Items -Why 'Reading users again'      # the list shows what really happened
    }
}

function Invoke-GLHandoverUi {
    # Someone leaving, or a new owner: To gets exactly the roles From has, on every
    # listed connection - and with Gateway clusters too, on every cluster on the Gateways tab.
    param([switch]$Move)
    foreach ($f in 'TxtMoveFrom', 'TxtMoveTo') { Save-GLFieldHistory $f }
    $items    = Get-GLListed
    $fromText = ([string]$script:UI.TxtMoveFrom.Text).Trim()
    $filter   = ([string]$script:UI.TxtCnUser.Text).Trim()
    if (-not $fromText -and $filter) {
        # The User filter matches part of a name; a handover must name one person.
        # So: the one person on the listed connections the filter matches.
        $ic    = [System.StringComparison]::OrdinalIgnoreCase
        $names = @($items | ForEach-Object { if ($_.PSObject.Properties['People'] -and @($_.People).Count) { $_.People } else { $_.UserList | ForEach-Object { [pscustomobject]@{ Name = $_; Email = ''; Key = $_ } } } } |
                   Where-Object { $_ -and (@($_.Name, $_.Email, $_.Key) | Where-Object { $_ -and ([string]$_).IndexOf($filter, $ic) -ge 0 }) } |
                   ForEach-Object { [string]$_.Key } | Sort-Object -Unique)
        if ($names.Count -eq 0) { Write-GLLog "No one with access to the listed connections matches '$filter'. Press Verify users, or type From." 'Warn'; return }
        if ($names.Count -gt 1) { Write-GLLog "'$filter' matches $($names.Count) people: $(($names | Select-Object -First 5) -join ', '). Type the one who hands over in From." 'Warn'; return }
        $fromText = [string]$names[0]
    }
    $toText = ([string]$script:UI.TxtMoveTo.Text).Trim()
    if (-not $fromText -or -not $toText) { Write-GLLog 'Enter who hands over (From, or set the User filter) and who takes over (To).' 'Warn'; return }
    if ($fromText -ieq $toText) { Write-GLLog 'From and To are the same - choose someone else to take over.' 'Warn'; return }
    $gws   = if ($script:UI.ChkMoveGateways.IsChecked) { @($script:UI.LstGwTiles.ItemsSource | Where-Object { $_ }) } else { @() }
    if ($items.Count -eq 0 -and $gws.Count -eq 0) { Write-GLLog 'Nothing to hand over - the list is empty.' 'Warn'; return }
    $toType = [string]$script:UI.CmbMoveToType.SelectedItem
    $verb = if ($Move) { 'Move' } else { 'Copy' }
    $on = @("$($items.Count) listed connection(s)")
    if ($gws.Count) { $on += "$($gws.Count) gateway cluster(s) on the Gateways tab" }
    $msg = "$verb every role '$fromText' has to '$toText' ($toType)?`n`nOn $($on -join ' and ')."
    $msg += if ($Move) { "`n`nThen '$fromText' loses those roles - only where '$toText' has them by then, so nothing is left without an owner." }
            else { "`n`n'$fromText' keeps their roles." }
    $msg += "`n`nRoles that come through a group are not handed over - only the ones given to '$fromText' directly."
    if (-not (Confirm-GL $msg "$verb access")) { return }

    $audit = Get-GLRunAudit
    if (-not $audit) { return }
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $gr = Get-GLTokenSafe Graph
    $targets = @(foreach ($g in $gws) { [pscustomobject]@{ Kind = 'gateways'; Id = [string]$g.Id; Name = [string]$g.Name; Gateway = [string]$g.Name; GatewayId = [string]$g.Id } }) +
               @(foreach ($c in $items) { [pscustomobject]@{ Kind = 'connections'; Id = [string]$c.Id; Name = [string]$c.Name; Gateway = [string]$c.Gateway; GatewayId = [string]$c.GatewayId } })
    Start-GLJob -Bulk -Name "$verb access of '$fromText' to '$toText'" `
        -Arguments @{ F = $fab; G = $gr; Targets = $targets; FromText = $fromText; ToText = $toText; ToType = $toType; M = [bool]$Move; A = $audit } `
        -Context @{ What = "$verb access"; Items = $items; Gateways = $gws } -Work {
        param($F, $G, $Targets, $FromText, $ToText, $ToType, $M, $A, $Progress)
        # both looked up before anything changes - someone unknown stops the run here
        $who  = Resolve-GLHandoverFrom -Value $FromText -GraphToken $G
        $heir = Resolve-GLPrincipal -Value $ToText -Type $ToType -GraphToken $G
        $next = [pscustomobject]@{ Id = $heir.Id; DisplayName = $heir.DisplayName; Type = $ToType }
        Invoke-GLAccessHandover -Targets $Targets -From $who -To $next -Move:$M -FabricToken $F -Progress $Progress -Audit $A
    } -OnDone {
        param($r, $err, $ctx)
        if ($err) { return }
        Write-GLResults $ctx.What $r
        Start-GLUsersRead -Items $ctx.Items -Why 'Reading users again'      # the list shows what really happened
        $g = $script:UI.LstGwTiles.SelectedItem
        if ($g -and @($ctx.Gateways | Where-Object { $_.Id -eq $g.Id }).Count) { Update-GLAccess -Kind gateways -Id $g.Id -Name $g.Name }
    }
}

function Invoke-GLAccessReportUi {
    # Who can use what, read fresh - every listed connection and every gateway on the
    # Gateways tab. With the User filter set: only that person's rows.
    $items = Get-GLListed
    $gws   = @($script:UI.LstGwTiles.ItemsSource | Where-Object { $_ })
    if ($items.Count -eq 0 -and $gws.Count -eq 0) { Write-GLLog 'Nothing to report - the lists are empty.' 'Warn'; return }
    $who = ([string]$script:UI.TxtCnUser.Text).Trim()
    $dlg = [Microsoft.Win32.SaveFileDialog]::new()
    $dlg.FileName = 'gatewaylens-access-{0:yyyyMMdd-HHmm}.csv' -f (Get-Date)
    $dlg.Filter   = 'CSV files (*.csv)|*.csv'
    if (-not $dlg.ShowDialog($script:Window)) { return }
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $targets = @(foreach ($g in $gws) { [pscustomobject]@{ Kind = 'gateways'; Id = [string]$g.Id; Name = [string]$g.Name; Gateway = [string]$g.Name; Type = [string]$g.Type; Path = ''; Account = ''; LastUsed = '' } }) +
               @(foreach ($c in $items) { [pscustomobject]@{ Kind = 'connections'; Id = [string]$c.Id; Name = [string]$c.Name; Gateway = [string]$c.Gateway; Type = [string]$c.Type; Path = [string]$c.Path; Account = [string]$c.Account; LastUsed = [string]$c.LastUsed } })
    $gr = Get-GLTokenSafe Graph
    Start-GLJob -Bulk -Name "Reading who has access to $($targets.Count) item(s)" -Arguments @{ F = $fab; G = $gr; Targets = $targets; W = $who; Known = $script:State.Names } `
        -Context @{ Path = $dlg.FileName; Who = $who } -Work {
        param($F, $G, $Targets, $W, $Known, $Progress)
        Get-GLAccessReport -Targets $Targets -Who $W -FabricToken $F -Progress $Progress -GraphToken $G -Known $Known
    } -OnDone {
        param($r, $err, $ctx)
        if ($err -or $script:Progress.Cancel) { return }
        $rows = @($r | Where-Object { $_ })
        $for  = if ($ctx.Who) { " for '$($ctx.Who)'" } else { '' }
        if ($rows.Count -eq 0) { Write-GLLog "No access found${for} - nothing was saved." 'Warn'; return }
        try { $rows | Export-Csv -Path $ctx.Path -NoTypeInformation -Encoding utf8BOM -ErrorAction Stop }
        catch { Write-GLLog "The access report could not be saved: $($_.Exception.Message)" 'Error'; return }
        $bad = @($rows | Where-Object Role -eq '(could not be read)').Count
        $miss = if ($bad) { " - $bad item(s) could not be read" } else { '' }
        Write-GLLog "Access report${for}: $($rows.Count) row(s) saved to $($ctx.Path)$miss."
    }
}

function Invoke-GLBulkCredentialsUi {
    Save-GLFieldHistory 'TxtCredUser'
    $type   = [string]$script:UI.CmbCredType.SelectedItem
    $user   = $script:UI.TxtCredUser.Text.Trim()
    $secret = $script:UI.PwdCred.Password
    $encChoice = @{ 'Keep current' = 'Keep'; 'Encrypted' = 'Encrypted'; 'Not encrypted' = 'NotEncrypted' }[[string]$script:UI.CmbCredEncryption.SelectedItem]

    if ($type -in 'Windows', 'Basic' -and (-not $user -or -not $secret)) { Write-GLLog "$type credentials need a username and a password." 'Warn'; return }
    if ($type -eq 'Key' -and -not $secret) { Write-GLLog 'Put the key in the password field.' 'Warn'; return }

    $items = Get-GLListed
    $gwItems = @($items | Where-Object { $_.Connectivity -eq 'OnPremisesGateway' -and $_.GatewayId })
    if ($gwItems.Count -eq 0) { Write-GLLog 'No on-premises gateway connections in the list.' 'Warn'; return }
    if ($script:State.PublicKeys.Count -eq 0) { Write-GLLog 'Gateway keys are not loaded yet - refresh first.' 'Warn'; return }

    $skip = $items.Count - $gwItems.Count
    $msg  = "Update the credentials of $($gwItems.Count) gateway connection(s) to $type"
    if ($user) { $msg += " as $user" }
    $msg += '?'
    if ($skip) { $msg += "`n`n$skip connection(s) not on an on-premises gateway will be skipped." }
    $msg += "`n`nEvery listed connection will use these credentials from now on."
    if (-not (Confirm-GL $msg 'Update credentials')) { return }

    $audit = Get-GLRunAudit
    if (-not $audit) { return }
    $pbi = Get-GLTokenSafe PowerBI
    if (-not $pbi) { return }
    $keys = @{} + $script:State.PublicKeys
    Start-GLJob -Bulk -Name "Updating credentials on $($gwItems.Count) connection(s)" `
        -Arguments @{ P = $pbi; I = $items; T = $type; U = $user; S = $secret; E = $encChoice; K = $keys; A = $audit; W = [bool]$script:UI.ChkCredPortal.IsChecked } `
        -Context @{ Items = $gwItems; Retest = [bool]$script:UI.ChkCredRetest.IsChecked; User = $user } -Work {
        param($P, $I, $T, $U, $S, $E, $K, $A, $W, $Progress)
        Invoke-GLBulkCredentials -Items $I -CredentialType $T -Username $U -Password $S -EncryptionChoice $E -PublicKeys $K -PbiToken $P -Progress $Progress -Audit $A -PortalWay:$W
    } -OnDone {
        param($r, $err, $ctx)
        if ($err) { return }
        Write-GLResults 'Update credentials' $r
        $done = @($r | Where-Object Ok | ForEach-Object { [string]$_.Id })
        if ($ctx.User -and $done.Count) {
            # The list shows the account they use now. Microsoft's credentials API keeps
            # only the encrypted copy, not the readable username the portal saves next
            # to it - so a later refresh can show the Account empty.
            foreach ($row in $ctx.Items) { if ($done -contains [string]$row.Id) { $row.Account = $ctx.User } }
            try { $script:UI.GridConnections.Items.Refresh() } catch { }
            $plainWay = @($r | Where-Object { $_.Ok -and $_.Way -eq 'documented' }).Count
            if ($plainWay) {
                Write-GLLog "$plainWay connection(s) were updated the documented way, which stores the username encrypted only - after the next refresh their Account can be empty. They use $($ctx.User) all the same: Verify status shows it." 'Warn'
            }
        }
        if ($ctx.Retest -and -not $script:Progress.Cancel) {
            # exactly the ones that took the new credentials - a test shows whether they work
            $again = @($ctx.Items | Where-Object { $done -contains [string]$_.Id })
            if ($again.Count) { Invoke-GLBulkStatusUi -Only $again -Retest }
        }
    }
    $script:UI.PwdCred.Clear()
}

function Invoke-GLBulkDeleteUi {
    $items = Get-GLListed
    if ($items.Count -eq 0) { Write-GLLog 'The list is empty.' 'Warn'; return }
    $n    = $items.Count
    $path = Join-Path $script:BackupFolder ('deleted-connections-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))
    $ok = Show-GLTypedConfirm -Message ("This PERMANENTLY deletes $n connection(s). Every semantic model, dataflow and pipeline that uses them stops refreshing, and it cannot be undone.`n`n" +
        "A backup is written first, to:`n$path`nIt holds everything needed to recreate them - except passwords, which the API never returns. If the backup cannot be written, nothing is deleted.") `
        -Ask "Type $n to confirm" -Expected "$n"
    if (-not $ok) { return }

    $audit = Get-GLRunAudit
    if (-not $audit) { return }
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $raw = @{}
    foreach ($it in $items) { if ($script:State.RawConnections.ContainsKey([string]$it.Id)) { $raw[[string]$it.Id] = $script:State.RawConnections[[string]$it.Id] } }

    $gr = Get-GLTokenSafe Graph
    Start-GLJob -Bulk -Name "Deleting $n connection(s)" -Arguments @{ F = $fab; G = $gr; I = $items; R = $raw; B = $path; A = $audit; Known = $script:State.Names } -Context @{ Backup = $path } -Work {
        param($F, $G, $I, $R, $B, $A, $Known, $Progress)
        # 1) who has access, by name, so the backup can restore that too
        $Progress.Name = "Backing up $($I.Count) connection(s)"
        $assign = Get-GLRoleAssignmentsBulk -Ids @($I | ForEach-Object { [string]$_.Id }) -FabricToken $F
        $names = @{} + $Known
        try { $names += Get-GLPrincipalNames -Ids @($assign.Values | Where-Object { $_ } | ForEach-Object { $_ } | ForEach-Object { [string]$_.principal.id }) -GraphToken $G -Known $Known } catch { }
        # 2) the backup - if this throws, the job stops here and nothing is deleted
        $null = Backup-GLConnections -Items $I -Raw $R -Assignments $assign -Path $B -Names $names
        # 3) only now, the deletes
        $Progress.Name = "Deleting $($I.Count) connection(s)"
        $res = Invoke-GLBulkDelete -Items $I -BackupPath $B -FabricToken $F -Progress $Progress -Audit $A
        @{ Results = $res; Backup = $B }
    } -OnDone {
        param($r, $err, $ctx)
        if ($err) {
            if (-not (Test-Path -LiteralPath $ctx.Backup)) { Write-GLLog 'The backup could not be written, so nothing was deleted.' 'Error' }
            return
        }
        Write-GLLog "Backup of the deleted connections: $($r.Backup)"
        Write-GLResults 'Delete' $r.Results
        $gone = [System.Collections.Generic.HashSet[string]]::new([string[]]@($r.Results | Where-Object Ok | ForEach-Object { [string]$_.Id }))
        $script:State.ConnRows = @($script:State.ConnRows | Where-Object { -not $gone.Contains([string]$_.Id) })
        Show-GLConnections
    }
}

# ---- single-item access -----------------------------------------------------------
function Show-GLAccessRows {
    <#
        Who has access, in an access panel. By default like the portal: accounts that
        are not in Microsoft Entra ID are left out, and the checkbox above says how
        many there are. Ticked, they are listed too - to be seen, or removed.
    #>
    param([string]$Kind, $Rows)
    $all  = @($Rows | Where-Object { $_ })
    $gone = @($all | Where-Object { $_.NotInEntra })
    $script:State.AccessRows[$Kind] = $all
    $show = [bool]$script:Settings.ShowGone
    $chk  = if ($Kind -eq 'gateways') { $script:UI.ChkGwShowGone } else { $script:UI.ChkCnShowGone }
    if ($chk) {
        $chk.Visibility = $(if ($gone.Count) { 'Visible' } else { 'Collapsed' })
        $chk.Content    = "Show $($gone.Count) not in Entra ID"
        $chk.IsChecked  = $show
    }
    $items = if ($show) { $all } else { @($all | Where-Object { -not $_.NotInEntra }) }
    Set-GLGridItems -Grid (Get-GLAccessGrid $Kind) -Items $items
}

function Set-GLShowGone([bool]$Show) {
    # One choice for both panels, kept in the settings.
    $script:Settings.ShowGone = $Show
    foreach ($k in 'gateways', 'connections') { Show-GLAccessRows -Kind $k -Rows $script:State.AccessRows[$k] }
    Write-GLLog $(if ($Show) { 'Access lists now include accounts that are not in Microsoft Entra ID.' } else { 'Access lists leave out accounts that are not in Microsoft Entra ID, like the portal.' })
}

function Get-GLAccessGrid([string]$Kind) {
    if ($Kind -eq 'gateways') { return $script:UI.GridGwAccess }
    return $script:UI.GridCnAccess
}

function Get-GLSelectedId([string]$Kind) {
    $grid = if ($Kind -eq 'gateways') { $script:UI.LstGwTiles } else { $script:UI.GridConnections }
    if ($grid.SelectedItem) { return [string]$grid.SelectedItem.Id }
    return $null
}

function Add-GLNames {
    # Names from a job into the session's list. Graph refusing is said once.
    param([hashtable]$Names, [string]$Warn)
    if ($Names) { foreach ($k in $Names.Keys) { $script:State.Names[$k] = $Names[$k] } }
    if ($Warn -and -not $script:State.NamesWarned) {
        $script:State.NamesWarned = $true
        Write-GLLog "Names could not be read from Microsoft Graph, so object ids are shown instead: $Warn" 'Warn'
    }
}

function Update-GLAccess {
    # Who has access to one gateway or connection, with names from Graph.
    param([string]$Kind, [string]$Id, [string]$Name)
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $gr = Get-GLTokenSafe Graph
    Start-GLJob -Quiet -Name "Access for '$Name'" -Arguments @{ F = $fab; G = $gr; K = $Kind; I = $Id; Known = $script:State.Names } `
        -Context @{ Kind = $Kind; Id = $Id; Name = $Name } -Work {
        param($F, $G, $K, $I, $Known)
        $ras = Get-GLRoleAssignments -Kind $K -Id $I -FabricToken $F
        $names = @{}; $warn = ''
        try { $names = Get-GLPrincipalNames -Ids @($ras | ForEach-Object { [string]$_.principal.id }) -GraphToken $G -Known $Known }
        catch { $warn = $_.Exception.Message }
        @{ Assignments = @($ras); Names = $names; Warn = $warn }
    } -OnDone {
        param($r, $err, $ctx)
        if ($err -or -not $r) { return }
        Add-GLNames $r.Names $r.Warn
        $rows = ConvertTo-GLRoleRows -Assignments $r.Assignments -Names $script:State.Names
        Write-GLLog "Access for '$($ctx.Name)': $(Format-GLAccessList $rows)"
        if ((Get-GLSelectedId $ctx.Kind) -ne $ctx.Id) { return }
        Show-GLAccessRows -Kind $ctx.Kind -Rows $rows
    }
}

function Show-GLAccessDialog {
    param([string]$Target, [string[]]$Roles, [string]$DefaultRole)
    [xml]$x = $script:DialogXaml
    $dlg = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($x))
    $dlg.Owner = $script:Window
    Initialize-GLDialog -Dialog $dlg
    $c = @{}
    foreach ($n in 'DlgTarget', 'DlgPrincipal', 'DlgHint', 'DlgType', 'DlgRole', 'DlgOk') { $c[$n] = $dlg.FindName($n) }
    $c.DlgTarget.Text = $Target
    $graph = $null
    try { $graph = Get-GLToken Graph } catch { }
    $c.DlgHint.Text   = if ($graph) {
        'A user''s email or UPN, a group''s email or name, a service principal''s name - or any object id.'
    } else { 'Paste the object id. Looking people up by name needs Microsoft Graph, which your organisation has not approved for GatewayLens.' }
    $c.DlgType.ItemsSource  = $script:PrincipalTypes
    $c.DlgType.SelectedItem = 'User'
    $c.DlgRole.ItemsSource  = $Roles
    $c.DlgRole.SelectedItem = $DefaultRole
    $state = @{ Ok = $false }
    $c.DlgOk.Add_Click({
        if ([string]::IsNullOrWhiteSpace($c.DlgPrincipal.Text)) { $c.DlgPrincipal.Focus(); return }
        $state.Ok = $true
        $dlg.Close()
    }.GetNewClosure())
    $dlg.Add_Loaded({ $c.DlgPrincipal.Focus() }.GetNewClosure())
    [void]$dlg.ShowDialog()
    if (-not $state.Ok) { return $null }
    return @{ Principal = $c.DlgPrincipal.Text.Trim(); Type = [string]$c.DlgType.SelectedItem; Role = [string]$c.DlgRole.SelectedItem }
}

function Update-GLAfterAccessChange {
    # After a change to one item's access: a connection's users are read again (the
    # list and the panel), a gateway's access panel is filled again.
    param([string]$Kind, [string]$Id, [string]$Name)
    if ($Kind -eq 'connections') {
        $row = @($script:State.ConnRows | Where-Object { [string]$_.Id -eq $Id }) | Select-Object -First 1
        if ($row) { Start-GLUsersRead -Items @($row) -Why 'Reading users again'; return }
    }
    if ((Get-GLSelectedId $Kind) -eq $Id) { Update-GLAccess -Kind $Kind -Id $Id -Name $Name }
}

function Invoke-GLAddAccess {
    param([string]$Kind)
    $grid = if ($Kind -eq 'gateways') { $script:UI.LstGwTiles } else { $script:UI.GridConnections }
    $row  = $grid.SelectedItem
    if (-not $row) { Write-GLLog "Select a $($Kind.TrimEnd('s')) first." 'Warn'; return }
    $roles = if ($Kind -eq 'gateways') { $script:GatewayRoles } else { $script:ConnectionRoles }
    $def   = if ($Kind -eq 'gateways') { 'ConnectionCreator' } else { 'User' }
    $label = if ($Kind -eq 'gateways') { 'Gateway' } else { 'Connection' }
    $d = Show-GLAccessDialog -Target "$($label): $($row.Name)" -Roles $roles -DefaultRole $def
    if (-not $d) { return }
    $audit = Get-GLRunAudit
    if (-not $audit) { return }
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $gr = Get-GLTokenSafe Graph
    $gwName = if ($Kind -eq 'gateways') { $row.Name } else { $row.Gateway }
    $gwId   = if ($Kind -eq 'gateways') { $row.Id } else { $row.GatewayId }
    Start-GLJob -Name "Adding $($d.Principal) as $($d.Role)" `
        -Arguments @{ F = $fab; G = $gr; K = $Kind; I = $row.Id; P = $d.Principal; T = $d.Type; R = $d.Role; A = $audit; N = $row.Name; GN = $gwName; GI = $gwId } `
        -Context   @{ Kind = $Kind; Id = $row.Id; Name = $row.Name; Role = $d.Role } -Work {
        param($F, $G, $K, $I, $P, $T, $R, $A, $N, $GN, $GI)
        $who = Resolve-GLPrincipal -Value $P -Type $T -GraphToken $G
        $rec = @{ Audit = $A; Action = 'Grant access'; TargetType = $(if ($K -eq 'gateways') { 'Gateway' } else { 'Connection' })
                  Target = $N; TargetId = $I; Gateway = $GN; GatewayId = $GI
                  Principal = $who.DisplayName; PrincipalId = $who.Id; PrincipalType = $T; Role = $R }
        try { $null = Add-GLRoleAssignment -Kind $K -Id $I -PrincipalId $who.Id -PrincipalType $T -Role $R -FabricToken $F }
        catch { Write-GLChange @rec -Result Failed -Message $_.Exception.Message; throw }
        Write-GLChange @rec -Result Done
        [pscustomobject]@{ Who = $who.DisplayName }
    } -OnDone {
        param($r, $err, $ctx)
        if ($err -or -not $r) { return }
        Write-GLLog "Added $($r.Who) as $($ctx.Role) on '$($ctx.Name)'."
        Update-GLAfterAccessChange -Kind $ctx.Kind -Id $ctx.Id -Name $ctx.Name
    }
}

function Invoke-GLRemoveAccess {
    param([string]$Kind)
    $grid = if ($Kind -eq 'gateways') { $script:UI.LstGwTiles } else { $script:UI.GridConnections }
    $row  = $grid.SelectedItem
    $a    = (Get-GLAccessGrid $Kind).SelectedItem
    if (-not $row -or -not $a) { Write-GLLog 'Select the access entry to remove first.' 'Warn'; return }
    if (@((Get-GLAccessGrid $Kind).SelectedItems).Count -gt 1) {
        $more = if ($Kind -eq 'connections') { ' For many connections at once, use Remove in the bulk panel.' } else { '' }
        Write-GLLog "Remove takes one access entry at a time - select just one.$more" 'Warn'
        return
    }
    $who = if ($a.Detail) { "$($a.Principal) ($($a.Detail))" } else { $a.Principal }
    if (-not (Confirm-GL "Remove $who`nrole: $($a.Role)`n`nfrom '$($row.Name)'?" 'Remove access')) { return }
    $audit = Get-GLRunAudit
    if (-not $audit) { return }
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $rec = @{ Action = 'Remove access'; TargetType = $(if ($Kind -eq 'gateways') { 'Gateway' } else { 'Connection' })
              Target = $row.Name; TargetId = $row.Id
              Gateway = $(if ($Kind -eq 'gateways') { $row.Name } else { $row.Gateway })
              GatewayId = $(if ($Kind -eq 'gateways') { $row.Id } else { $row.GatewayId })
              Principal = $who; PrincipalId = [string]$a.PrincipalId; PrincipalType = [string]$a.Type; Role = [string]$a.Role }
    Start-GLJob -Name "Removing $($a.Principal)" -Arguments @{ F = $fab; K = $Kind; I = $row.Id; X = $a.Id; A = $audit; Rec = $rec } `
        -Context @{ Kind = $Kind; Id = $row.Id; Name = $row.Name; Who = $who } -Work {
        param($F, $K, $I, $X, $A, $Rec)
        try { Remove-GLRoleAssignment -Kind $K -Id $I -AssignmentId $X -FabricToken $F }
        catch { Write-GLChange -Audit $A @Rec -Result Failed -Message $_.Exception.Message; throw }
        Write-GLChange -Audit $A @Rec -Result Done
        $true
    } -OnDone {
        param($r, $err, $ctx)
        if ($err) { return }
        Write-GLLog "Removed $($ctx.Who) from '$($ctx.Name)'."
        Update-GLAfterAccessChange -Kind $ctx.Kind -Id $ctx.Id -Name $ctx.Name
    }
}

function Invoke-GLTestConnection {
    $row = $script:UI.GridConnections.SelectedItem
    if (-not $row) { Write-GLLog 'Select a connection first.' 'Warn'; return }
    if ($row.Connectivity -ne 'OnPremisesGateway' -or -not $row.GatewayId) {
        Write-GLLog "'$($row.Name)' is a $($row.Connectivity) connection - only on-premises gateway connections can be tested here." 'Warn'
        return
    }
    $pbi = Get-GLTokenSafe PowerBI
    if (-not $pbi) { return }
    Start-GLJob -Name "Testing '$($row.Name)'" -Arguments @{ P = $pbi; G = $row.GatewayId; C = $row.Id } -Context @{ Name = $row.Name } -Work {
        param($P, $G, $C)
        Test-GLConnection -GatewayId $G -ConnectionId $C -PbiToken $P
    } -OnDone {
        param($r, $err, $ctx)
        if ($err -or -not $r) { return }
        Write-GLLog "'$($ctx.Name)': $($r.Message)" $(if ($r.Ok) { 'Ok' } else { 'Error' })
    }
}

# ---- log panel --------------------------------------------------------------------
function Copy-GLLog {
    param([switch]$Selected)
    $t = Get-GLLogText -Selected:$Selected
    if (-not $t) { Write-GLLog $(if ($Selected) { 'Select the lines to copy first.' } else { 'Nothing to copy.' }) 'Warn'; return }
    [System.Windows.Clipboard]::SetText($t)
}

function Add-GLLogMenu {
    # Right-click and Ctrl+C on the log: the selected lines, or everything shown.
    $list = $script:UI.LstLog
    $menu = [System.Windows.Controls.ContextMenu]::new()
    foreach ($m in @(@('Copy selected lines', 'Ctrl+C', 'Sel'), @('Copy everything shown', '', 'All'))) {
        $item = [System.Windows.Controls.MenuItem]::new()
        $item.Header = $m[0]
        $item.InputGestureText = $m[1]
        $item.Tag = $m[2]
        $item.Add_Click({ param($s, $e) if ([string]$s.Tag -eq 'Sel') { Copy-GLLog -Selected } else { Copy-GLLog } })
        $null = $menu.Items.Add($item)
    }
    $list.ContextMenu = $menu
    $list.Add_PreviewKeyDown({
        param($s, $e)
        $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -eq [System.Windows.Input.ModifierKeys]::Control
        if ($ctrl -and $e.Key -eq 'C') { Copy-GLLog -Selected; $e.Handled = $true }
        elseif ($ctrl -and $e.Key -eq 'A') { $s.SelectAll(); $e.Handled = $true }
    })
}

function Save-GLLog {
    $t = Get-GLLogText
    if (-not $t) { Write-GLLog 'Nothing to save.' 'Warn'; return }
    $dlg = [Microsoft.Win32.SaveFileDialog]::new()
    $dlg.FileName = 'gatewaylens-log-{0:yyyyMMdd-HHmm}.txt' -f (Get-Date)
    $dlg.Filter   = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    if (-not $dlg.ShowDialog($script:Window)) { return }
    Set-Content -LiteralPath $dlg.FileName -Value $t -Encoding utf8
    Write-GLLog "Log saved to $($dlg.FileName)"
}

# ---- smoke test ---------------------------------------------------------------------
# -SmokeTest drives the real window on demo data: waits for each load to finish, then
# every theme, every tab, two text sizes, and closes. Main reports the verdict.
function Start-GLSmokeTest {
    param([switch]$Screenshots)
    if ($Screenshots) { $plan = Get-GLScreenshotPlan }
    elseif ([int]$script:SmokeRound -ge 2) { $plan = Get-GLSmokePlanAgain }
    else { $plan = Get-GLSmokePlan }
    $before = $script:Smoke
    $script:Smoke = @{ Plan = $plan; Next = 0; Deadline = (Get-Date).AddSeconds(180) }
    # what the first window found is still judged after the second
    if ($before -and [int]$script:SmokeRound -ge 2) { foreach ($k in @($before.Keys)) { if (-not $script:Smoke.ContainsKey($k)) { $script:Smoke[$k] = $before[$k] } } }
    $script:SmokeTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:SmokeTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:SmokeTimer.Add_Tick({ Step-GLSmokeTest })
    $script:SmokeTimer.Start()
}

function Get-GLScreenshotPlan {
    # What the README shows, in the order it is taken. Dark first: it looks best on GitHub.
    $plan = [System.Collections.Generic.List[object]]::new()
    $plan.Add(@{ Kind = 'Size'; Value = @(1600, 1040) })
    $plan.Add(@{ Kind = 'Theme'; Value = 'Dark' })
    $plan.Add(@{ Kind = 'Tab'; Value = 0 })
    $plan.Add(@{ Kind = 'Tile'; Value = 'Contoso Prod Cluster' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Shot'; Value = 'screenshot-gateways' })
    $plan.Add(@{ Kind = 'Tab'; Value = 1 })
    $plan.Add(@{ Kind = 'Row'; Value = 'Sales DW' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Shot'; Value = 'screenshot-connections' })
    $plan.Add(@{ Kind = 'Run'; Value = 'Status' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Shot'; Value = 'screenshot-verify-status' })
    $plan.Add(@{ Kind = 'ShowGone'; Value = $true })
    $plan.Add(@{ Kind = 'ShowView'; Value = 'Access by accounts not in Entra ID' })
    $plan.Add(@{ Kind = 'Row'; Value = 'AP Archive' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Shot'; Value = 'screenshot-deleted-accounts' })
    $plan.Add(@{ Kind = 'ShowGone'; Value = $false })
    $plan.Add(@{ Kind = 'ShowView'; Value = 'All connections' })
    $plan.Add(@{ Kind = 'Tab'; Value = 0 })
    $plan.Add(@{ Kind = 'Font'; Value = 20 })          # a wall screen is read from across the room
    $plan.Add(@{ Kind = 'Kiosk' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Shot'; Value = 'screenshot-kiosk' })
    $plan.Add(@{ Kind = 'KioskOff' })
    $plan.Add(@{ Kind = 'Font'; Value = 12 })
    $plan.Add(@{ Kind = 'Theme'; Value = 'Light' })
    $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Shot'; Value = 'screenshot-gateways-light' })
    $plan.Add(@{ Kind = 'Theme'; Value = 'Dark' })
    $plan.Add(@{ Kind = 'OpenAlerts' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'ShotAlerts'; Value = 'screenshot-alerts' })
    $plan.Add(@{ Kind = 'CloseAlerts' })
    # the tour: a few frames the README plays as one moving picture
    $plan.Add(@{ Kind = 'Size'; Value = @(1500, 960) })
    $plan.Add(@{ Kind = 'Font'; Value = 14 })
    $plan.Add(@{ Kind = 'Tab'; Value = 0 })
    $plan.Add(@{ Kind = 'Tile'; Value = 'Contoso Prod Cluster' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Frame'; Value = 2600 })
    $plan.Add(@{ Kind = 'Tab'; Value = 1 })
    $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Frame'; Value = 1400 })
    $plan.Add(@{ Kind = 'Account'; Value = 'svc_sales' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Frame'; Value = 2000 })
    $plan.Add(@{ Kind = 'Run'; Value = 'Status' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Frame'; Value = 2600 })
    $plan.Add(@{ Kind = 'Account'; Value = '' })
    $plan.Add(@{ Kind = 'ShowGone'; Value = $true })
    $plan.Add(@{ Kind = 'ShowView'; Value = 'Access by accounts not in Entra ID' })
    $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Row'; Value = 'AP Archive' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Frame'; Value = 3000 })
    $plan.Add(@{ Kind = 'ShowGone'; Value = $false })
    $plan.Add(@{ Kind = 'ShowView'; Value = 'Duplicates' })
    $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Frame'; Value = 2200 })
    $plan.Add(@{ Kind = 'ShowView'; Value = 'All connections' })
    $plan.Add(@{ Kind = 'Tab'; Value = 0 })
    $plan.Add(@{ Kind = 'Font'; Value = 20 })
    $plan.Add(@{ Kind = 'Kiosk' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Frame'; Value = 3200; Scale = 0.625 })
    $plan.Add(@{ Kind = 'KioskOff' })
    $plan.Add(@{ Kind = 'Font'; Value = 12 })
    $plan.Add(@{ Kind = 'Close' })
    return , $plan
}

function Save-GLWindowImage {
    # The window as a PNG, drawn by WPF itself - no screen capture, so nothing else
    # on the screen gets in, and it works with the window behind others.
    param([Parameter(Mandatory)][string]$Path, $Window, [double]$Scale = 1)
    $w = if ($Window) { $Window } else { $script:Window }
    # the window's own frame inside the title bar: background, margins and all
    $root = [System.Windows.Media.VisualTreeHelper]::GetChild($w, 0)
    $wd = [Math]::Max(1, [int]$root.ActualWidth); $ht = [Math]::Max(1, [int]$root.ActualHeight)
    if ($Scale -eq 1) {
        $bmp = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($wd, $ht, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($root)
    }
    else {
        # smaller, drawn again rather than shrunk - the text stays sharp
        $sw = [Math]::Max(1, [int][Math]::Round($wd * $Scale)); $sh = [Math]::Max(1, [int][Math]::Round($ht * $Scale))
        $vb = [System.Windows.Media.VisualBrush]::new($root)
        $vb.ViewboxUnits = [System.Windows.Media.BrushMappingMode]::Absolute
        $vb.Viewbox = [System.Windows.Rect]::new(0, 0, $wd, $ht)
        $vb.Stretch = [System.Windows.Media.Stretch]::Fill
        $dv = [System.Windows.Media.DrawingVisual]::new()
        $dc = $dv.RenderOpen()
        $dc.DrawRectangle($vb, $null, [System.Windows.Rect]::new(0, 0, $sw, $sh))
        $dc.Close()
        $bmp = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($sw, $sh, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($dv)
    }
    $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $enc.Interlace = [System.Windows.Media.Imaging.PngInterlaceOption]::Off     # the tour joins frames as they are
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [System.IO.File]::Create($Path)
    try { $enc.Save($fs) } finally { $fs.Dispose() }
}

function Get-GLSmokePlan {
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $script:Themes.Keys) { $plan.Add(@{ Kind = 'Theme'; Value = $t }) }
    for ($i = 0; $i -lt $script:UI.Tabs.Items.Count; $i++) { $plan.Add(@{ Kind = 'Tab'; Value = $i }) }
    $plan.Add(@{ Kind = 'Tab'; Value = 0 })
    $plan.Add(@{ Kind = 'ShowView'; Value = 'Duplicates' })
    $plan.Add(@{ Kind = 'ShowView'; Value = 'All connections' })
    $plan.Add(@{ Kind = 'Tab'; Value = 1 })
    # the search box filters once typing stops - and gives every row back when cleared
    $plan.Add(@{ Kind = 'Filter'; Value = 'Sales' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'FilterCheck' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'FilterBack' })
    $plan.Add(@{ Kind = 'Tab'; Value = 0 })
    $plan.Add(@{ Kind = 'Tile'; Value = 'Contoso Prod Cluster' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'GoneCheck' })
    $plan.Add(@{ Kind = 'AlertsCheck' })
    $plan.Add(@{ Kind = 'MeterCheck' })
    $plan.Add(@{ Kind = 'Tab'; Value = 1 })
    $plan.Add(@{ Kind = 'HistoryPick' })
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'HistoryBack' })
    $plan.Add(@{ Kind = 'GridChecks' })
    $plan.Add(@{ Kind = 'Tab'; Value = 0 })
    $plan.Add(@{ Kind = 'Kiosk' })
    $plan.Add(@{ Kind = 'KioskOff' })
    $plan.Add(@{ Kind = 'Font'; Value = 16 })
    $plan.Add(@{ Kind = 'Font'; Value = 12 })
    $plan.Add(@{ Kind = 'Theme'; Value = 'Light' })
    $plan.Add(@{ Kind = 'Restart' })       # back to the start page, and into the demo again
    return , $plan
}

function Get-GLSmokePlanAgain {
    # The second window, after the start page: it loads, and works like the first.
    $plan = [System.Collections.Generic.List[object]]::new()
    $plan.Add(@{ Kind = 'Wait' }); $plan.Add(@{ Kind = 'Wait' })
    $plan.Add(@{ Kind = 'Again' })
    $plan.Add(@{ Kind = 'Close' })
    return , $plan
}

function Step-GLSmokeTest {
    $sm = $script:Smoke
    if ((Get-Date) -gt $sm.Deadline) {
        Write-GLLog "Smoke test: timed out at step $($sm.Next) of $($sm.Plan.Count)." 'Error'
        $script:SmokeTimer.Stop()
        $script:Window.Close()
        return
    }
    if ($script:Jobs.Count -gt 0) { return }          # let every load and refresh finish first
    if ($sm.Next -ge $sm.Plan.Count) { return }
    $p = $sm.Plan[$sm.Next]
    $sm.Next++
    switch ($p.Kind) {
        'Theme' { $script:UI.CmbTheme.SelectedItem = $p.Value }
        'Tab'   { $script:UI.Tabs.SelectedIndex = $p.Value }
        'Font'  { Set-GLFontSize $p.Value; if ($p.Value -eq 16) { $sm.TileScale = Get-GLTileScale } }
        'GridChecks' { $sm.GridChecks = Test-GLGridBehaviour -Grid $script:UI.GridConnections }
        'Wait'   { }
        'Filter' {
            $sm.FilterAll = @($script:UI.GridConnections.ItemsSource).Count
            $script:UI.TxtCnSearch.Text = $p.Value
        }
        'FilterCheck' {
            $n = @($script:UI.GridConnections.ItemsSource).Count
            $sm.FilterOk = $n -gt 0 -and $n -lt $sm.FilterAll
            $script:UI.TxtCnSearch.Text = ''
        }
        'FilterBack' { $sm.FilterOk = $sm.FilterOk -and @($script:UI.GridConnections.ItemsSource).Count -eq $sm.FilterAll }
        'HistoryPick' {
            # chosen once, text deleted, then chosen again from the open list
            $b = $script:UI.TxtCnAccount
            $sm.HistoryKeep = $b.ItemsSource
            $b.ItemsSource = @('svc_sales', 'svc_hr')
            $b.SelectedItem = 'svc_sales'
            $b.Text = ''
            $b.IsDropDownOpen = $true
            $b.SelectedItem = 'svc_sales'
            $sm.HistoryOk = ([string]$b.Text -eq 'svc_sales')
            $b.IsDropDownOpen = $false
        }
        'GoneCheck' {
            # like the portal: the admin who left is not listed - until asked for
            $all = @($script:State.AccessRows.gateways).Count
            $vis = @($script:UI.GridGwAccess.ItemsSource).Count
            $chk = $script:UI.ChkGwShowGone
            $hidden = $all -eq $vis + 1 -and $chk.Visibility -eq 'Visible' -and [string]$chk.Content -match '1 not in Entra ID'
            Set-GLShowGone $true
            $shown = @($script:UI.GridGwAccess.ItemsSource).Count -eq $all
            Set-GLShowGone $false
            $sm.GoneOk = $hidden -and $shown
        }
        'MeterCheck' { Update-GLMeter; $sm.MeterOk = [string]$script:UI.TxtMeter.Text -match '^CPU \d+%.*API calls \d' }
        'AlertsCheck' {
            $d = Show-GLAlertsDialog -NoShow
            $sm.AlertsOk = [bool]($d -and $script:AlertDlg.C.AlUrl -and $script:AlertDlg.C.AlOk -and $script:AlertDlg.C.AlWebhook)
            try { $d.Close() } catch { }
            $script:AlertDlg = $null
            $tb = $script:Window.TaskbarItemInfo
            $sm.TaskbarOk = [bool]($tb -and [string]$tb.ProgressState -eq 'Error' -and $script:Window.Title -match '^\(1 offline')
        }
        'Again' {
            $sm.AgainOk = (@($script:State.ConnRows).Count -eq 27) -and (@($script:State.GatewayRows).Count -eq 5) -and
                          (@($script:LogView).Count -gt 0) -and ($script:UI.BtnSignInReal.Visibility -eq 'Visible')
        }
        'Restart' { $script:SmokeTimer.Stop(); $script:BackToStart = $true; $script:Window.Close() }
        'ShowGone' { Set-GLShowGone ([bool]$p.Value) }
        'HistoryBack' { $b = $script:UI.TxtCnAccount; $b.Text = ''; $b.ItemsSource = $sm.HistoryKeep }
        'ShowView' {
            $script:UI.CmbCnShow.SelectedItem = $p.Value
            if ($p.Value -eq 'Duplicates') { $sm.Duplicates = @($script:UI.GridConnections.ItemsSource).Count }
        }
        'Kiosk' {
            $sm.AutoBefore = [string]$script:UI.CmbAutoRefresh.SelectedItem
            Enter-GLKiosk
            $sm.KioskIn = ($script:UI.HeaderBar.Visibility -eq 'Collapsed' -and $script:UI.GwDetail.Visibility -eq 'Collapsed')
        }
        'KioskOff' {
            $sm.CountdownOk = [string]$script:UI.TxtGwUpdated.Text -match 'next in \d+:\d\d'
            Exit-GLKiosk
            $sm.KioskOk = $sm.KioskIn -and $script:UI.HeaderBar.Visibility -eq 'Visible' -and $script:UI.GwDetail.Visibility -eq 'Visible' -and -not $script:KioskSaved -and
                          [string]$script:UI.CmbAutoRefresh.SelectedItem -eq $sm.AutoBefore
        }
        'Close' { $script:SmokeTimer.Stop(); $script:Window.Close() }
        'Size'  { $script:Window.WindowState = 'Normal'; $script:Window.Width = $p.Value[0]; $script:Window.Height = $p.Value[1] }
        'Tile'  {
            $tile = @($script:UI.LstGwTiles.ItemsSource) | Where-Object { $_.Name -eq $p.Value } | Select-Object -First 1
            if ($tile) { $script:UI.LstGwTiles.SelectedItem = $tile }
        }
        'Row'   {
            $row = @($script:UI.GridConnections.ItemsSource) | Where-Object { $_.Name -eq $p.Value } | Select-Object -First 1
            if ($row) { $script:UI.GridConnections.SelectedItem = $row; $script:UI.GridConnections.ScrollIntoView($row) }
        }
        'Run'   { if ($p.Value -eq 'Status') { Invoke-GLBulkStatusUi } }
        'Shot'  {
            try { Save-GLWindowImage -Path (Join-Path $script:ShotFolder "$($p.Value).png") }
            catch { Write-GLLog "Screenshot $($p.Value): $($_.Exception.Message)" 'Error' }
        }
        'Frame' {
            # the tour's frames are the same size: the kiosk fills the screen, so it is drawn smaller
            $n = $script:TourFrames.Count + 1
            $file = Join-Path $script:FrameFolder ('frame-{0:00}.png' -f $n)
            $k = if ($p.Scale) { [double]$p.Scale } else { 0.8 }
            try { Save-GLWindowImage -Path $file -Scale $k; $script:TourFrames.Add([pscustomobject]@{ File = $file; Delay = [int]$p.Value }) }
            catch { Write-GLLog "Tour frame ${n}: $($_.Exception.Message)" 'Error' }
        }
        'Account' { $script:UI.TxtCnAccount.Text = [string]$p.Value }
        'OpenAlerts' {
            # a fictional address - the demo sends nothing anywhere
            $sm.AlertsWin = Show-GLAlertsDialog -NoShow
            $c = $script:AlertDlg.C
            $c.AlDesktop.IsChecked = $true; $c.AlWebhook.IsChecked = $true
            $c.AlUrl.Text = 'https://prod-00.westeurope.logic.azure.com:443/workflows/contoso-gateway-alerts/triggers/manual/paths/invoke'
            $sm.AlertsWin.Show()
        }
        'ShotAlerts' {
            try { Save-GLWindowImage -Path (Join-Path $script:ShotFolder "$($p.Value).png") -Window $sm.AlertsWin }
            catch { Write-GLLog "Screenshot $($p.Value): $($_.Exception.Message)" 'Error' }
        }
        'CloseAlerts' { try { $sm.AlertsWin.Close() } catch { }; $script:AlertDlg = $null }
    }
}

function Get-GLSmokeVerdict {
    # Called after the window has closed. Returns the problems found - none means pass.
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($script:StyleMode -ne 'Modern') { $problems.Add("the modern look did not load: $($script:StyleError)") }
    $entries = @($script:EarlierErrors) + @($script:LogEntries)
    foreach ($e in ($entries | Where-Object Level -eq 'Error')) { $problems.Add("logged: $($e.Line)") }
    if (-not $script:Smoke) { $problems.Add('the window never finished loading') }
    elseif ($script:Smoke.Next -lt $script:Smoke.Plan.Count) { $problems.Add("stopped at step $($script:Smoke.Next) of $($script:Smoke.Plan.Count)") }
    if (@($script:State.GatewayRows).Count -ne 5)   { $problems.Add("gateways shown: $(@($script:State.GatewayRows).Count), expected 5 - personal gateways are left out") }
    if (-not ($script:State.Releases -and $script:State.Releases.Newest)) { $problems.Add('the newest gateway version was not read from the demo''s copy of Microsoft''s pages') }
    $st = @($script:State.Tiles | ForEach-Object Status | Sort-Object -Unique)
    if (@($script:State.Tiles).Count -ne 5 -or ($st -notcontains 'Offline') -or ($st -notcontains 'VNet')) { $problems.Add("gateway tiles: $(@($script:State.Tiles).Count) with $($st -join ', '), expected 5 including Offline and VNet") }
    if ($script:Smoke -and -not $script:Smoke.MeterOk) { $problems.Add('the meter at the bottom right showed no numbers') }
    if ($script:Smoke -and -not $script:Smoke.AlertsOk) { $problems.Add('the Alerts window did not load') }
    if ($script:Smoke -and -not $script:Smoke.TaskbarOk) { $problems.Add('with a gateway offline, the taskbar button and the title did not say so') }
    if ($script:Smoke -and -not $script:Smoke.GoneOk) { $problems.Add('the gateway access list did not leave out the account that is not in Entra ID, or did not show it when asked') }
    if ($script:Smoke -and -not $script:Smoke.CountdownOk) { $problems.Add('with auto-refresh on, the Gateways tab did not count down to the next refresh') }
    if ($script:Smoke -and -not $script:Smoke.AgainOk) { $problems.Add('back to the start page and into the demo again did not give a working window') }
    if ($script:Smoke -and $script:StartPageResult -ne 'Demo') { $problems.Add("the start page did not open, or Try the demo did not work (it gave '$($script:StartPageResult)')") }
    if ($script:Smoke -and -not $script:Smoke.HistoryOk) { $problems.Add('a remembered entry could not be picked again after its text was deleted') }
    if ($script:Smoke -and -not $script:Smoke.FilterOk) { $problems.Add('the search box did not filter the connections once typing stopped, or did not give them all back when cleared') }
    if ($script:Smoke -and -not $script:Smoke.KioskOk) { $problems.Add('kiosk view did not hide and restore the window parts and the auto-refresh') }
    if ($script:Smoke -and [math]::Abs([double]$script:Smoke.TileScale - 16 / 12) -gt 0.01) { $problems.Add("tiles at text size 16 were drawn at $($script:Smoke.TileScale) of their size, expected 1.33") }
    $cg = $script:UI.GridConnections
    if ($script:Smoke -and $cg -and $cg.RowHeight -ne (Get-GLRowHeight -FontSize $script:Settings.FontSize).Row) {
        $problems.Add("grid rows are $($cg.RowHeight) high at text size $($script:Settings.FontSize), expected $((Get-GLRowHeight -FontSize $script:Settings.FontSize).Row)")
    }
    if ($script:Smoke -and $null -eq $script:Smoke.GridChecks) { $problems.Add('the grid checks did not run') }
    elseif ($script:Smoke -and $script:Smoke.GridChecks) { $problems.Add("grids: $($script:Smoke.GridChecks)") }
    if ($script:Smoke -and $script:Smoke.Duplicates -ne 2) { $problems.Add("Show > Duplicates listed $($script:Smoke.Duplicates) connection(s), expected the 2 copies of Sales DW") }
    if (@($script:State.ConnRows).Count -ne 27)     { $problems.Add("connections shown: $(@($script:State.ConnRows).Count), expected 27") }
    $outside = Test-GLDemoApart
    if (@($outside).Count) { $problems.Add("the demo wrote outside its own folder: $($outside -join ', ')") }
    return , $problems.ToArray()
}

# ---- small helpers ----------------------------------------------------------------
function Export-GLGrid {
    param($Grid, [string]$Suggested, $Data)
    # a grid's rows in the order shown, sorted as the user sorted them
    $rows = if ($null -ne $Data) { @($Data | Where-Object { $_ }) } else { @($Grid.Items | Where-Object { $_ }) }
    if ($rows.Count -eq 0) { Write-GLLog 'Nothing to export.' 'Warn'; return }
    $dlg = [Microsoft.Win32.SaveFileDialog]::new()
    $dlg.FileName = '{0}-{1:yyyyMMdd-HHmm}.csv' -f $Suggested, (Get-Date)
    $dlg.Filter   = 'CSV files (*.csv)|*.csv'
    if (-not $dlg.ShowDialog($script:Window)) { return }
    $hasUsers = $rows[0].PSObject.Properties.Name -contains 'UserList'
    $rows | ForEach-Object {
        $o = $_ | Select-Object -Property * -ExcludeProperty UserList, Source, People, UnknownUsers, NotInEntra
        if ($hasUsers -and -not $_.PSObject.Properties['UserNames']) { $o | Add-Member -NotePropertyName UserNames -NotePropertyValue (@($_.UserList) -join '; ') -Force }
        $o
    } | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding utf8BOM
    Write-GLLog "Exported $($rows.Count) row(s) to $($dlg.FileName)"
}

function Copy-GLId {
    param($Grid)
    $row = $Grid.SelectedItem
    if (-not $row) { Write-GLLog 'Select a row first.' 'Warn'; return }
    [System.Windows.Clipboard]::SetText([string]$row.Id)
    Write-GLLog "Copied $($row.Id)"
}

# ---- build and run the window ----------------------------------------------------
function Show-GLWindow {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    if (-not $script:SettingsPath) { $script:SettingsPath = Get-GLSettingsPath }
    $script:SettingsExisted = Test-Path -LiteralPath $script:SettingsPath
    $script:Settings = Read-GLSettings -Path $script:SettingsPath
    if ($script:AuthMode -ne 'Demo' -and [string]$script:SignedInAs -match '^[^\s@]+@[^\s@]+$') { $script:Settings.LastAccount = [string]$script:SignedInAs }
    # from here on, everything logged also goes to today's log file
    $script:LogReady = $true
    $pruned = Remove-GLOldLogs -Folder $script:LogFolder -User $script:SignedInAs -Days 30
    Write-GLLog ('=' * 70) -FileOnly
    Write-GLLog "$($script:AppName) $($script:AppVersion) started - $($script:SignedInAs) via $($script:AuthMode), tenant $($script:TenantShown)" -FileOnly
    if ($pruned) { Write-GLLog "Removed $pruned log file(s) older than 30 days." -FileOnly }

    [xml]$x = $script:MainXaml
    $script:Window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($x))
    foreach ($n in ([regex]::Matches($script:MainXaml, 'Name="([A-Za-z]+)"') | ForEach-Object { $_.Groups[1].Value })) {
        $script:UI[$n] = $script:Window.FindName($n)
    }

    # the look first - a failure here falls back to the classic look, never stops the window
    $mode = Add-GLStyles -Target $script:Window
    $script:Settings.Theme = Set-GLTheme -Target $script:Window -Name $script:Settings.Theme
    $img = Get-GLIconImage
    if ($img) { $script:Window.Icon = $img; $script:UI.ImgLogo.Source = $img }
    $script:UI.CmbTheme.ItemsSource  = @($script:Themes.Keys)
    $script:UI.CmbTheme.SelectedItem = $script:Settings.Theme
    Set-GLFontSize $script:Settings.FontSize
    Initialize-GLHistory
    try { Set-GLLayout $script:Settings.Layout } catch { }

    $script:Window.Title        = "$($script:AppName) $($script:AppVersion)"
    if ($script:AuthMode -eq 'Demo') {
        $script:Window.Title += '  -  DEMO (fictional data)'
        $script:UI.BtnSignInReal.Visibility = 'Visible'
    }
    $script:UI.TxtApp.Text      = $script:AppName
    $script:UI.TxtVersion.Text  = "v$($script:AppVersion)"
    $script:UI.TxtIdentity.Text = "$($script:SignedInAs)   |   tenant $($script:TenantShown)   |   $($script:AuthMode)"
    $script:BaseTitle = $script:Window.Title
    Update-GLAlertsButton

    foreach ($g in $script:Grids) {
        $script:UI[$g].Add_AutoGeneratingColumn({
            param($s, $e)
            if ($e.PropertyName -in 'GatewayId', 'PrincipalId', 'UserList', 'Source', 'People', 'UnknownUsers', 'NotInEntra') { $e.Cancel = $true; return }
            # read-only text that can be selected and copied, sorted as the user left it
            $col = New-GLGridColumn -Property $e.PropertyName -Header $e.Column.Header
            $sorted = @($script:GridSort[[string]$s.Name]) | Where-Object { $_.PropertyName -eq $e.PropertyName } | Select-Object -First 1
            if ($sorted) { $col.SortDirection = $sorted.Direction }
            $e.Column = $col
        })
        # a cell opened for copying has all its text selected, ready for Ctrl+C
        $script:UI[$g].Add_PreparingCellForEdit({
            param($s, $e)
            $cp = $e.EditingElement
            if (-not $cp) { return }
            $null = $cp.ApplyTemplate()
            $box = if ([System.Windows.Media.VisualTreeHelper]::GetChildrenCount($cp)) { [System.Windows.Media.VisualTreeHelper]::GetChild($cp, 0) }
            if ($box -is [System.Windows.Controls.TextBox]) { $null = $box.Focus(); $box.SelectAll() }
        })
        Add-GLGridCopy $script:UI[$g]
    }
    Add-GLTileCopy

    # colour on what needs attention - by brush name, so it follows the theme
    $script:UI.GridMembers.Add_LoadingRow({
        param($s, $e)
        $st = [string]$e.Row.Item.Status
        Set-GLRowColor $e.Row $(if ($st -eq 'Timeout') { 'Warn' } elseif ($st -and $st -notin 'Live', 'n/a') { 'Danger' } else { '' })
    })
    $script:UI.GridConnections.Add_LoadingRow({
        param($s, $e)
        $i = $e.Row.Item
        Set-GLRowColor $e.Row $(if ($i.Status -eq 'Failed' -or $i.GatewayState -eq 'Offline') { 'Danger' }
                                 elseif ($i.Status -in 'Timeout', 'Unverified' -or $i.GatewayState -eq 'Partial') { 'Warn' } else { '' })
    })

    # dropdown contents
    $script:UI.CmbAutoRefresh.ItemsSource       = @('Off', '1 min', '5 min', '10 min', '15 min', '30 min')
    $script:UI.CmbAutoRefresh.SelectedIndex     = 0
    $script:UI.CmbBulkPrincipalType.ItemsSource = $script:PrincipalTypes
    $script:UI.CmbBulkPrincipalType.SelectedItem = 'User'
    $script:UI.CmbBulkRole.ItemsSource          = $script:ConnectionRoles
    $script:UI.CmbBulkRole.SelectedItem         = 'User'
    $script:UI.CmbMoveToType.ItemsSource        = @('User', 'Group', 'ServicePrincipal')
    $script:UI.CmbMoveToType.SelectedItem       = 'User'
    $script:UI.CmbCnShow.ItemsSource            = $script:ShowViews
    $script:UI.CmbCnShow.SelectedIndex          = 0
    $script:UI.CmbCredType.ItemsSource          = @('Windows', 'Basic', 'Anonymous', 'Key')
    $script:UI.CmbCredType.SelectedItem         = 'Windows'
    $script:UI.CmbCredEncryption.ItemsSource    = @('Keep current', 'Encrypted', 'Not encrypted')
    $script:UI.CmbCredEncryption.SelectedIndex  = 0
    $script:UI.CmbLogLevel.ItemsSource          = @('All', 'Warnings and errors', 'Errors only')
    $script:UI.CmbLogLevel.SelectedIndex        = 0

    # appearance
    $script:UI.CmbTheme.Add_SelectionChanged({
        $script:Settings.Theme = Set-GLTheme -Target $script:Window -Name ([string]$script:UI.CmbTheme.SelectedItem)
        $null = Save-GLSettings -Settings $script:Settings -Path $script:SettingsPath
        Write-GLLog "Theme: $($script:Settings.Theme)."
    })
    $script:UI.BtnFontDown.Add_Click({ Step-GLFontSize -By -1 })
    $script:UI.BtnFontUp.Add_Click({ Step-GLFontSize -By 1 })
    # Ctrl + mouse wheel: the text size - and the list under the mouse does not scroll
    $script:Window.Add_PreviewMouseWheel({
        param($s, $e)
        $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -eq [System.Windows.Input.ModifierKeys]::Control
        $step = Get-GLFontStep -Delta $e.Delta -Ctrl $ctrl
        if ($null -eq $step) { return }
        Step-GLFontSize -By $step
        $e.Handled = $true
    })
    $script:UI.BtnClearHistory.Add_Click({
        if (-not (Confirm-GL 'Forget everything typed into the search and name boxes?' 'Clear history')) { return }
        $script:Settings.History = [ordered]@{}
        foreach ($f in $script:HistoryFields) { $script:UI[$f].ItemsSource = @() }
        $null = Save-GLSettings -Settings $script:Settings -Path $script:SettingsPath
        Write-GLLog 'History cleared.'
    })

    # gateways
    $script:UI.BtnGwRefresh.Add_Click({ Invoke-GLGatewayRefresh })
    $script:UI.ChkSkipVnet.Add_Click({
        if (-not $script:UI.ChkSkipVnet.IsChecked) { Write-GLLog 'VNet gateways are now checked too. A sleeping one starts, and uses capacity until it sleeps again.' 'Warn' }
        Invoke-GLGatewayRefresh
    })
    $script:UI.CmbAutoRefresh.Add_SelectionChanged({ Set-GLAutoRefresh })
    Add-GLTextChanged $script:UI.TxtGwFilter { Start-GLDebounce Gateways }
    $script:UI.LstGwTiles.Add_SelectionChanged({ Update-GLGatewayDetail })
    $script:UI.BtnGwExport.Add_Click({ Export-GLGrid -Data (Get-GLGatewayExport) -Suggested 'gateways' })
    $script:UI.BtnGwCopyId.Add_Click({ Copy-GLId -Grid $script:UI.LstGwTiles })
    $script:UI.BtnKiosk.Add_Click({ Enter-GLKiosk })
    $script:UI.BtnKioskExit.Add_Click({ Exit-GLKiosk })
    $script:UI.BtnSignInReal.Add_Click({ $script:BackToStart = $true; $script:Window.Close() })
    $script:UI.BtnAlerts.Add_Click({ Show-GLAlertsDialog })
    foreach ($c in 'ChkGwShowGone', 'ChkCnShowGone') { $script:UI[$c].Add_Click({ param($s, $e) Set-GLShowGone ([bool]$s.IsChecked) }) }
    Add-GLHelpMenu
    $script:UI.BtnGwCopyAll.Add_Click({ Copy-GLGateways })
    $script:UI.BtnGwCopyCluster.Add_Click({ Copy-GLGateways -SelectedOnly })
    $script:UI.BtnGwIpsAll.Add_Click({ Invoke-GLResolveIps })
    $script:UI.BtnGwIpsCluster.Add_Click({ Invoke-GLResolveIps -SelectedOnly })
    $script:UI.BtnMemberEnable.Add_Click({ Invoke-GLMemberEnabled -Enabled $true })
    $script:UI.BtnMemberDisable.Add_Click({ Invoke-GLMemberEnabled -Enabled $false })
    $script:UI.BtnGwAccessAdd.Add_Click({ Invoke-GLAddAccess -Kind gateways })
    $script:UI.BtnGwAccessRemove.Add_Click({ Invoke-GLRemoveAccess -Kind gateways })

    # connections
    $script:UI.BtnCnRefresh.Add_Click({ Invoke-GLConnectionRefresh })
    foreach ($tb in 'TxtCnSearch', 'TxtCnUser', 'TxtCnAccount') { Add-GLTextChanged $script:UI[$tb] { Start-GLDebounce Connections } }
    foreach ($cb in 'CmbCnGateway', 'CmbCnConnectivity', 'CmbCnType') { $script:UI[$cb].Add_SelectionChanged({ Show-GLConnections -Say }) }
    foreach ($ck in 'ChkStOnline', 'ChkStPartial', 'ChkStOffline', 'ChkStUnknown') { $script:UI[$ck].Add_Click({ Show-GLConnections -Say }) }
    $script:UI.CmbCnShow.Add_SelectionChanged({ Show-GLConnections -Say })
    $script:UI.ChkCnCloud.Add_Click({ Update-GLConnectionCombos; Show-GLConnections -Say })
    $script:UI.BtnCnAccessReport.Add_Click({ Invoke-GLAccessReportUi })
    $script:UI.BtnCopyAccess.Add_Click({ Invoke-GLHandoverUi })
    $script:UI.BtnMoveAccess.Add_Click({ Invoke-GLHandoverUi -Move })
    $script:UI.GridConnections.Add_SelectionChanged({ Update-GLConnectionDetail })
    $script:UI.BtnCnExclude.Add_Click({ Invoke-GLExclude })
    $script:UI.BtnCnUnexclude.Add_Click({
        $n = $script:State.Excluded.Count
        $script:State.Excluded.Clear()
        Show-GLConnections
        Write-GLLog "$n excluded row(s) are back in the list."
    })
    $script:UI.BtnCnExport.Add_Click({ Export-GLGrid -Grid $script:UI.GridConnections -Suggested 'connections' })
    $script:UI.BtnCnCopyId.Add_Click({ Copy-GLId -Grid $script:UI.GridConnections })
    $script:UI.BtnCnTest.Add_Click({ Invoke-GLTestConnection })
    $script:UI.BtnCnAccessAdd.Add_Click({ Invoke-GLAddAccess -Kind connections })
    $script:UI.BtnCnAccessRemove.Add_Click({ Invoke-GLRemoveAccess -Kind connections })
    $script:UI.BtnBulkStatus.Add_Click({ Invoke-GLBulkStatusUi })
    $script:UI.BtnBulkUsers.Add_Click({ Invoke-GLBulkUsersUi })
    $script:UI.BtnBulkGrant.Add_Click({ Invoke-GLBulkAccessUi })
    $script:UI.BtnBulkRevoke.Add_Click({ Invoke-GLBulkAccessUi -Revoke })
    $script:UI.BtnBulkCredentials.Add_Click({ Invoke-GLBulkCredentialsUi })
    $script:UI.BtnBulkDelete.Add_Click({ Invoke-GLBulkDeleteUi })

    # log panel
    Add-GLTextChanged $script:UI.TxtLogFind { Start-GLDebounce Log }
    $script:UI.CmbLogLevel.Add_SelectionChanged({ Update-GLLogView })
    $script:UI.BtnLogCopy.Add_Click({ Copy-GLLog })
    $script:UI.BtnLogSave.Add_Click({ Save-GLLog })
    $script:UI.BtnLogFolder.Add_Click({ Open-GLFolder $script:LogFolder })
    $script:UI.BtnLogClear.Add_Click({ $script:LogEntries.Clear(); $script:ErrorCount = 0; Update-GLLogView; Update-GLMeter })
    $script:UI.BtnErrors.Add_Click({ $script:UI.CmbLogLevel.SelectedItem = 'Errors only' })
    Add-GLLogMenu

    $script:UI.BtnCancel.Add_Click({
        $script:Progress.Cancel = $true
        Write-GLLog 'Cancelling after the current item...' 'Warn'
        Update-GLBusy
    })

    # Anything a handler did not expect is logged, and the window stays open.
    $script:Window.Dispatcher.Add_UnhandledException({
        param($s, $e)
        $e.Handled = $true
        $msg = $e.Exception.Message
        if ($script:LastUnexpected -and $script:LastUnexpected.Message -eq $msg -and ((Get-Date) - $script:LastUnexpected.At).TotalSeconds -lt 5) {
            $script:LastUnexpected.Count++
            return                      # the same error again at once: counted, not repeated
        }
        if ($script:LastUnexpected -and $script:LastUnexpected.Count -gt 1) {
            Write-GLLog "    (the error before happened $($script:LastUnexpected.Count) times)" 'Error'
        }
        $script:LastUnexpected = @{ Message = $msg; At = Get-Date; Count = 1 }
        Write-GLLog "Unexpected error: $msg" 'Error'
        # where it came from, for whoever has to find it - in the log file only
        Write-GLLog "    $($e.Exception.GetType().FullName): $($e.Exception.ToString() -replace '\r?\n', ' | ')" -FileOnly
    })

    # Ctrl + plus, minus or 0: the text size. Esc leaves the kiosk view, F11 goes in and out.
    $script:Window.Add_PreviewKeyDown({
        param($s, $e)
        $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -eq [System.Windows.Input.ModifierKeys]::Control
        $step = Get-GLFontStep -Key ([string]$e.Key) -Ctrl $ctrl
        if ($null -ne $step) {
            if ($step -eq 0) { Step-GLFontSize -Reset } else { Step-GLFontSize -By $step }
            $e.Handled = $true
        }
        elseif ($e.Key -eq 'Escape' -and $script:KioskSaved) { Exit-GLKiosk; $e.Handled = $true }
        elseif ($e.Key -eq 'F11') { if ($script:KioskSaved) { Exit-GLKiosk } else { Enter-GLKiosk }; $e.Handled = $true }
        elseif ($e.Key -eq 'F1' -and -not $script:KioskSaved) { Open-GLLink "$($script:RepoUrl)#readme"; $e.Handled = $true }
    })

    $script:Window.Add_Loaded({
        Update-GLLogView
        Write-GLLog "$($script:AppName) $($script:AppVersion) - signed in as $($script:SignedInAs) via $($script:AuthMode)." 'Ok'
        if ($script:AuthMode -eq 'Demo') {
            Write-GLLog 'DEMO: Contoso is fictional. Nothing leaves this computer, and changes last until the window closes.' 'Warn'
            Write-GLLog 'Try: Kiosk view (or F11) - the gateways as a wall screen. Esc leaves it.'
            Write-GLLog 'Try: Joe Smith is leaving. Connections > User joe.smith, Verify users, then Hand over access To ana.novak@contoso.com and Move access.'
            Write-GLLog 'Try: Connections > Show > Duplicates - a stale copy of Sales DW is taking a slot on the Prod cluster.'
            Write-GLLog 'Try: Connections > Verify status - five connections fail, and StatusDetail says why for each.'
            Write-GLLog "Try: HR Core cannot log in. Select it alone, update its credentials with any password except 'wrong', then verify again."
        }
        if ($script:StyleMode -eq 'Classic' -and $script:StyleError) {
            Write-GLLog "The modern look could not be loaded, so the classic one is in use: $($script:StyleError)" 'Warn'
        }
        Invoke-GLGatewayRefresh
        Invoke-GLConnectionRefresh
        if ($Kiosk) { Enter-GLKiosk }
        # after an update, once: what is new. Not on the very first start, not when driven.
        $seen = [string]$script:Settings.SeenVersion
        $script:Settings.SeenVersion = $script:AppVersion
        if (-not ($script:SmokeTest -or $script:ShotFolder -or $Kiosk) -and $script:SettingsExisted -and $seen -ne $script:AppVersion) {
            $null = $script:Window.Dispatcher.BeginInvoke([Action]{ Show-GLWhatsNew }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        }
        if ($script:SmokeTest) { Start-GLSmokeTest }
        elseif ($script:ShotFolder) { Start-GLSmokeTest -Screenshots }
    })
    $script:Window.Add_Closing({
        param($s, $e)
        if ($script:Progress.Active -and -not (Confirm-GL "'$($script:Progress.Name)' is still running. Close anyway? It stops after the current item." 'Close')) {
            $e.Cancel = $true
            $script:BackToStart = $false
            return
        }
        $script:Progress.Cancel = $true
    })
    $script:Window.Add_Closed({
        Write-GLLog 'Session ended.' -FileOnly
        foreach ($f in $script:HistoryFields) { Save-GLFieldHistory $f }
        try { $script:Settings.Layout = Get-GLLayout } catch { }
        $null = Save-GLSettings -Settings $script:Settings -Path $script:SettingsPath
        try { $script:Timer.Stop() } catch { }
        try { if ($script:AutoTimer) { $script:AutoTimer.Stop() } } catch { }
        try { if ($script:ClockTimer) { $script:ClockTimer.Stop() } } catch { }
        try { if ($script:MeterTimer) { $script:MeterTimer.Stop() } } catch { }
        Remove-GLTrayIcon
        try { $script:Pool.Close(); $script:Pool.Dispose() } catch { }
    })

    Initialize-GLWorkers
    $script:MeterTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:MeterTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:MeterTimer.Add_Tick({ Update-GLMeter })
    $script:MeterTimer.Start()
    [void]$script:Window.ShowDialog()
}

# ============================================================================
#  MAIN
# ============================================================================
if ($LoadOnly) { return }

if ($SmokeTest -or $Screenshots) {
    $Demo = $true      # -SmokeTest is the demo, driven - and $SmokeTest is already the script variable functions read
    $script:SettingsPath = Join-Path ([System.IO.Path]::GetTempPath()) ('gatewaylens-smoke-{0}.json' -f [guid]::NewGuid().ToString('N'))
}
if ($Screenshots) {
    $script:ShotFolder = [System.IO.Path]::GetFullPath($Screenshots)
    if (-not (Test-Path -LiteralPath $script:ShotFolder)) { $null = New-Item -ItemType Directory -Path $script:ShotFolder -Force }
    # the tour's frames wait outside the repository, for build/Make-Marketing.ps1 to join
    $script:FrameFolder = Join-Path ([System.IO.Path]::GetTempPath()) 'gatewaylens-tour'
    if (Test-Path -LiteralPath $script:FrameFolder) { Remove-Item -LiteralPath $script:FrameFolder -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $script:FrameFolder -Force
    $script:TourFrames = [System.Collections.Generic.List[object]]::new()
}

function Stop-GL([string]$Message) {
    # Started from GatewayLens.exe there is no console to read - show a message box too.
    Write-Host $Message -ForegroundColor Red
    if ($Launched -and $IsWindows) {
        try {
            Add-Type -AssemblyName PresentationFramework
            [void][System.Windows.MessageBox]::Show($Message, $script:AppName, 'OK', 'Error')
        } catch { }
    }
    exit 1
}

if (-not $IsWindows -and -not ($SelfTest -or $Inspect)) {
    Stop-GL "$($script:AppName) needs Windows for its window. -SelfTest and -Inspect work anywhere."
}

# WPF needs a single-threaded apartment. Relaunch in one if this console is not.
if (-not ($SelfTest -or $Inspect) -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe      = (Get-Process -Id $PID).Path
    $relaunch = @('-NoProfile', '-STA', '-File', $PSCommandPath)
    if ($TenantId)              { $relaunch += @('-TenantId', $TenantId) }
    if ($DeviceCode)            { $relaunch += '-DeviceCode' }
    if ($Account)               { $relaunch += @('-Account', $Account) }
    if ($ClientId)              { $relaunch += @('-ClientId', $ClientId) }
    if ($SignIn -ne 'Auto')     { $relaunch += @('-SignIn', $SignIn) }
    if ($DnsSuffix.Count)       { $relaunch += @('-DnsSuffix', ($DnsSuffix -join ',')) }
    if ($PSBoundParameters.ContainsKey('BackupFolder')) { $relaunch += @('-BackupFolder', $BackupFolder) }
    if ($PSBoundParameters.ContainsKey('LogFolder'))    { $relaunch += @('-LogFolder', $LogFolder) }
    if ($Launched)              { $relaunch += '-Launched' }
    if ($Demo -and -not ($SmokeTest -or $Screenshots)) { $relaunch += '-Demo' }
    if ($Kiosk)                 { $relaunch += '-Kiosk' }
    if ($SmokeTest)             { $relaunch += '-SmokeTest' }
    if ($Screenshots)           { $relaunch += @('-Screenshots', $Screenshots) }
    & $exe @relaunch
    exit $LASTEXITCODE
}

# Round and round: the window can send the user back to the start page - out of
# the demo, to sign in - and everything starts again from there.
$realLogFolder = $LogFolder; $realBackupFolder = $BackupFolder
$round = 0
while ($true) {
$round++
$script:SmokeRound = $round

# The start page: sign in when ready, or try the demo. Not for -Demo (straight in),
# a wall screen (-Kiosk), the console modes or -DeviceCode, which prints its code there
# - unless the window sent the user back to it.
$startResult = ''
if ($IsWindows -and -not ($SelfTest -or $Inspect -or $DeviceCode) -and ($round -gt 1 -or (-not $Kiosk -and (-not $Demo -or $SmokeTest -or $Screenshots)))) {
    $auto = if ($SmokeTest -or $Screenshots) { 'Demo' } else { '' }
    $shot = if ($Screenshots -and $round -eq 1) { Join-Path $script:ShotFolder 'screenshot-start.png' } else { '' }
    $startResult = Invoke-GLStartPage -TenantId $TenantId -ClientId $ClientId -Account $Account -SignIn $SignIn -NoWindow:$Launched -Auto $auto -Shot $shot
    $script:StartPageResult = $startResult
    if ($startResult -eq 'Closed') { exit 0 }
    if ($startResult -eq 'Demo') { $Demo = $true }
}

if ($Demo) {
    # demo changes and logs live apart from the real ones
    # A script's parameters ARE its script variables: by now $LogFolder already holds
    # the default path, so ask what was actually passed, not whether it has a value.
    $demoRoot = Join-Path (Join-Path $appData 'GatewayLens') 'demo'
    if (-not $PSBoundParameters.ContainsKey('LogFolder'))    { $LogFolder    = Join-Path $demoRoot 'logs' }
    if (-not $PSBoundParameters.ContainsKey('BackupFolder')) { $BackupFolder = Join-Path $demoRoot 'backups' }
    $script:DemoRoot = $demoRoot
    Enable-GLDemo
    Write-Host 'Demo mode: Contoso is fictional - no sign-in, nothing leaves this computer.' -ForegroundColor Yellow
}
elseif ($startResult -ne 'SignedIn') {
    try {
        Write-Host "Signing in..." -ForegroundColor Cyan
        # GatewayLens.exe hides the console unless -SelfTest, -Inspect or -DeviceCode needs it
        $noWindow = $Launched -and -not ($SelfTest -or $Inspect -or $DeviceCode)
        Connect-GL -TenantId $TenantId -DeviceCode:$DeviceCode -ClientId $ClientId -Account $Account -SignIn $SignIn -NoWindow:$noWindow
        Write-Host "Signed in as $($script:SignedInAs) via $($script:AuthMode)." -ForegroundColor Green
    }
    catch {
        Stop-GL "Sign-in failed: $($_.Exception.Message)"
    }
}

if ($SelfTest) {
    $ok = Invoke-GLSelfTest
    exit $(if ($ok) { 0 } else { 1 })
}
if ($Inspect) {
    Invoke-GLInspect
    exit 0
}

try { Show-GLWindow }
catch { Stop-GL "$($script:AppName) stopped: $($_.Exception.Message)" }

if (-not $script:BackToStart) { break }
# back to the start page: the demo - or the session - ends here
$script:BackToStart = $false
Reset-GLSession
if ($Demo) {
    Disable-GLDemo
    $Demo = $false
    $LogFolder = $realLogFolder; $BackupFolder = $realBackupFolder; $script:DemoRoot = $null
}
}

if ($Screenshots) {
    Remove-Item -LiteralPath $script:SettingsPath -ErrorAction SilentlyContinue
    $made = @(Get-ChildItem -LiteralPath $script:ShotFolder -Filter '*.png' | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) })
    Write-Host "$($made.Count) screenshot(s) in $($script:ShotFolder)" -ForegroundColor Green
    if ($script:TourFrames.Count) {
        $script:TourFrames | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $script:FrameFolder 'frames.json') -Encoding utf8
        Write-Host "$($script:TourFrames.Count) tour frame(s) in $($script:FrameFolder) - build/Make-Marketing.ps1 joins them" -ForegroundColor Green
    }
    exit 0
}
if ($SmokeTest) {
    $problems = Get-GLSmokeVerdict
    Remove-Item -LiteralPath $script:SettingsPath -ErrorAction SilentlyContinue
    if ($problems.Count) {
        Write-Host "Smoke test FAILED:" -ForegroundColor Red
        foreach ($p in $problems) { Write-Host "  $p" -ForegroundColor Red }
        exit 1
    }
    Write-Host "Smoke test passed: window, $($script:Themes.Count) themes, $($script:UI.Tabs.Items.Count) tabs, demo data loaded." -ForegroundColor Green
    exit 0
}
