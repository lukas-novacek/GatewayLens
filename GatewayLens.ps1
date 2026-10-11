<#
.SYNOPSIS
    GatewayLens - a lightweight desktop console for Microsoft on-premises data
    gateways and the connections that run on them, for Power BI and Microsoft Fabric.

.DESCRIPTION
    One PowerShell script. No database, no server components, nothing to install
    beyond a sign-in module. It talks to Microsoft's REST APIs as the signed-in user:

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
    Sign in with a device code instead of a browser window. Az.Accounts only.

.PARAMETER AuthModule
    Auto (default) uses Az.Accounts if installed, otherwise MicrosoftPowerBIMgmt.

.PARAMETER DnsSuffix
    Extra DNS suffixes to try when resolving gateway machine names to IP
    addresses, for names Windows does not resolve on its own. Optional.

.PARAMETER BackupFolder
    Where the automatic backup is written before connections are deleted.
    Default: Documents\GatewayLens\backups.

.PARAMETER LogFolder
    Where the daily log files and the change records are kept. Default:
    %LOCALAPPDATA%\GatewayLens\logs. Point several people at one shared folder
    and the Activity tab shows everyone's changes - each person writes only to
    files carrying their own name.

.PARAMETER Demo
    Opens GatewayLens on Contoso, a fictional company, with no sign-in and no
    tenant: gateways online, offline and slow, connections that fail for real-looking
    reasons, people and groups. Every button works against that data and nothing
    leaves the computer. The demo keeps its own log and change record, apart from
    the real ones. Good for trying things out and for screenshots.

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
    [ValidateSet('Auto', 'Az', 'PowerBIMgmt')]
    [string]$AuthModule = 'Auto',
    [string[]]$DnsSuffix = @(),
    [string]$BackupFolder,
    [string]$LogFolder,
    [switch]$SelfTest,
    [switch]$Inspect,
    [switch]$Demo,
    [switch]$Launched,
    [switch]$LoadOnly
)

$script:AppName    = 'GatewayLens'
# Documents can be missing (non-Windows, or an unusual profile), and this line runs
# whenever the script loads - so fall back rather than fail.
$docs = [Environment]::GetFolderPath('MyDocuments')
if (-not $docs) { $docs = $HOME }
if (-not $docs) { $docs = [System.IO.Path]::GetTempPath() }
$script:BackupFolder = if ($BackupFolder) { $BackupFolder } else { Join-Path (Join-Path $docs 'GatewayLens') 'backups' }
$appData = [Environment]::GetFolderPath('LocalApplicationData')
if (-not $appData) { $appData = $docs }
$script:LogFolder = if ($LogFolder) { $LogFolder } else { Join-Path (Join-Path $appData 'GatewayLens') 'logs' }
$script:DnsSuffixes = @($DnsSuffix | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# Strict mode, if the caller's session has it on, would make every optional field in
# an API answer an error - Microsoft's APIs leave fields out freely, and this script
# reads them defensively instead. So the script sets its own rules.
Set-StrictMode -Off

$script:AppVersion = '0.5.1'

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

function ConvertFrom-GLToken {
    # Newer Az.Accounts versions hand the token back as a SecureString.
    param($Token)
    if ($Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $Token).Password
    }
    return [string]$Token
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
        [int]$MaxPages = 500
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

        Returns a hashtable keyed by lower-case member id.
    #>
    param(
        [Parameter(Mandatory)][string]$PbiToken,
        [int]$TimeoutSec = 30,
        [int]$MaxClusters = 0
    )
    $base     = 'https://api.powerbi.com/v2.0/myorg/me/gatewayClusters'
    $r        = Invoke-GLRequest -Uri $base -Token $PbiToken
    $clusters = @($r.value | Where-Object { $_ })
    if ($MaxClusters -gt 0) { $clusters = @($clusters | Select-Object -First $MaxClusters) }

    $members = foreach ($c in $clusters) {
        foreach ($mg in $c.memberGateways) {
            if ($null -eq $mg) { continue }
            [pscustomobject]@{ Member = $mg; Uri = "$base/$($c.id)/memberGateways/$($mg.id)/status" }
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
        [switch]$LiveStatus
    )
    $base     = 'https://api.fabric.microsoft.com/v1'
    $log      = [System.Collections.Generic.List[string]]::new()
    $gateways = Get-GLPaged -Uri "$base/gateways" -Token $FabricToken

    $members = @{}
    foreach ($g in $gateways) {
        if ([string]$g.type -ne 'OnPremises') { continue }   # personal and VNet gateways have no member list
        try {
            $m = Get-GLPaged -Uri "$base/gateways/$($g.id)/members" -Token $FabricToken
            $members[[string]$g.id] = $m
        }
        catch { $log.Add("Members of '$($g.displayName)': $($_.Exception.Message)") }
    }

    $live = $null
    if ($LiveStatus -and $PbiToken) {
        try { $live = Get-GLLiveStatus -PbiToken $PbiToken }
        catch { $log.Add("Live status is unavailable (unofficial API): $($_.Exception.Message)") }
    }

    return @{ Gateways = $gateways; Members = $members; Live = $live; Log = $log.ToArray() }
}

function Get-GLConnectionData {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FabricToken)
    $base        = 'https://api.fabric.microsoft.com/v1'
    $gateways    = Get-GLPaged -Uri "$base/gateways"    -Token $FabricToken
    $connections = Get-GLPaged -Uri "$base/connections" -Token $FabricToken
    return @{ Gateways = $gateways; Connections = $connections }
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
        throw "Looking up '$v' by name needs Microsoft Graph, which is only available when signed in with Az.Accounts. Paste the object id instead."
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
    param([string]$GatewayName, $Members, [hashtable]$Live)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $Members) {
        $l = $null
        if ($Live) { $l = $Live[([string]$m.id).ToLowerInvariant()] }
        $rows.Add([pscustomobject]@{
            Gateway = $GatewayName
            Member  = [string]$m.displayName
            Machine = if ($l) { [string]$l.Machine } else { '' }
            Version = [string]$m.version
            Enabled = $m.enabled
            Status  = if ($l) { [string]$l.Status } else { 'n/a' }
            Id      = [string]$m.id
        })
    }
    return , $rows.ToArray()
}

function Get-GLGatewayNameMap {
    param($Gateways)
    $map = @{}
    foreach ($g in $Gateways) { $map[([string]$g.id).ToLowerInvariant()] = [string]$g.displayName }
    return $map
}

function ConvertTo-GLConnectionRows {
    param($Connections, [hashtable]$GatewayNames)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $Connections) {
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
            Status       = ''
            StatusDetail = ''
            Credential   = [string]$c.credentialDetails.credentialType
            SingleSignOn = [string]$c.credentialDetails.singleSignOnType
            Privacy      = [string]$c.privacyLevel
            Encryption   = [string]$c.credentialDetails.connectionEncryption
            Id           = [string]$c.id
            GatewayId    = $gid
            UserList     = @()
        })
    }
    return , $rows.ToArray()
}

function ConvertTo-GLRoleRows {
    param($Assignments)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $Assignments) {
        $p = $a.principal
        $detail = ''
        if     ($p.userDetails.userPrincipalName)      { $detail = [string]$p.userDetails.userPrincipalName }
        elseif ($p.groupDetails.email)                 { $detail = [string]$p.groupDetails.email }
        elseif ($p.servicePrincipalDetails.aadAppId)   { $detail = "app $($p.servicePrincipalDetails.aadAppId)" }
        $rows.Add([pscustomobject]@{
            Principal   = if ($p.displayName) { [string]$p.displayName } else { [string]$p.id }
            Detail      = $detail
            Type        = [string]$p.type
            Role        = [string]$a.role
            Id          = [string]$a.id
            PrincipalId = [string]$p.id
        })
    }
    return , $rows.ToArray()
}

function Select-GLConnections {
    <#
        The Connections tab filters. '(all)' or empty means "no filter".
          Text      several values separated by ; or new lines - a row matches ANY
          User      someone with access (needs Users loaded)
          Account   the username stored in the credentials (needs Account loaded)
          States    gateway states to keep: Online, Offline, Partial, Unknown
          Excluded  ids to leave out
    #>
    param($Rows, [string]$Text, [string]$Gateway, [string]$Connectivity, [string]$Type,
          [string]$User, [string]$Account, [string[]]$States, $Excluded)
    $terms = @()
    if ($Text) { $terms = @($Text -split '[;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $u = if ($User) { $User.Trim() } else { '' }
    $a = if ($Account) { $Account.Trim() } else { '' }
    $ic = [System.StringComparison]::OrdinalIgnoreCase
    $out = foreach ($r in $Rows) {
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
            foreach ($x in $r.UserList) { if (([string]$x).IndexOf($u, $ic) -ge 0) { $hit = $true; break } }
            if (-not $hit) { continue }
        }
        $r
    }
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
    # Account and users from the unofficial bulk directory.
    param($Rows, [hashtable]$Directory)
    if (-not $Directory) { return }
    foreach ($r in $Rows) {
        $d = $Directory[([string]$r.Id).ToLowerInvariant()]
        if (-not $d) { continue }
        $r.Account  = [string]$d.Account
        $r.UserList = @($d.Users | ForEach-Object { [string]$_.Principal } | Where-Object { $_ })
        $r.Users    = [string]$r.UserList.Count
    }
}

function Set-GLRowUsers {
    # Users from Fabric role assignments (Verify users). $Assignments: id -> list, or $null on failure.
    param($Rows, [hashtable]$Assignments)
    foreach ($r in $Rows) {
        if (-not $Assignments.ContainsKey([string]$r.Id)) { continue }
        $list = $Assignments[[string]$r.Id]
        if ($null -eq $list) { $r.Users = 'error'; continue }
        $r.UserList = @($list | ForEach-Object {
            $p = $_.principal
            @($p.userDetails.userPrincipalName, $p.groupDetails.email, $p.displayName, $p.id) | Where-Object { $_ } | Select-Object -First 1
        } | Where-Object { $_ })
        $r.Users = [string]$r.UserList.Count
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
    if ($r -is [psobject] -and $null -ne $r.BaseObject -and
        $r.BaseObject -isnot [System.Management.Automation.PSCustomObject]) {
        $r = $r.BaseObject
    }
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
            $out = New-Object System.IO.MemoryStream
            for ($i = 0; $i -lt $plain.Length; $i += 85) {
                $len = [Math]::Min(85, $plain.Length - $i)
                $seg = New-Object byte[] $len
                [Array]::Copy($plain, $i, $seg, 0, $len)
                $enc = $rsa.Encrypt($seg, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA1)
                $out.Write($enc, 0, $enc.Length)
            }
            return [Convert]::ToBase64String($out.ToArray())
        }

        # 2048-bit and larger: AES-256-CBC + HMAC-SHA256, both keys wrapped with RSA-OAEP-SHA256
        $keyEnc = New-Object byte[] 32
        $keyMac = New-Object byte[] 64
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

function ConvertTo-GLConnectionDetails {
    <#
        The connectionDetails JSON string for a new gateway data source. Built from
        whichever of server / database / path / url / connectionString are filled
        in; an explicit JSON value wins, for anything this does not cover.
    #>
    param([string]$Server, [string]$Database, [string]$Path, [string]$Url, [string]$ConnectionString, [string]$Json)
    if (-not [string]::IsNullOrWhiteSpace($Json)) {
        try { $null = $Json | ConvertFrom-Json -ErrorAction Stop } catch { throw "ConnectionDetailsJson is not valid JSON: $Json" }
        return $Json.Trim()
    }
    $d = [ordered]@{}
    if ($Server)           { $d.server           = $Server.Trim() }
    if ($Database)         { $d.database         = $Database.Trim() }
    if ($Path)             { $d.path             = $Path.Trim() }
    if ($Url)              { $d.url              = $Url.Trim() }
    if ($ConnectionString) { $d.connectionString = $ConnectionString.Trim() }
    if ($d.Count -eq 0) { throw 'No connection details - fill in a server, path, url, connection string or JSON.' }
    return ($d | ConvertTo-Json -Compress)
}

function New-GLGatewayConnection {
    # Documented Power BI endpoint: Gateways - Create Datasource.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GatewayId,
        $PublicKey,   # checked inside, so a missing key gets a clear message
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DataSourceType,
        [Parameter(Mandatory)][string]$ConnectionDetails,
        [Parameter(Mandatory)][string]$CredentialType,
        [string]$Username,
        [string]$Password,
        [string]$Privacy = 'Organizational',
        [string]$Encryption = 'Encrypted',
        [Parameter(Mandatory)][string]$PbiToken
    )
    $body = [ordered]@{
        dataSourceType    = $DataSourceType
        connectionDetails = $ConnectionDetails
        datasourceName    = $Name
        credentialDetails = New-GLCredentialDetails -CredentialType $CredentialType -Username $Username -Password $Password `
                                -PublicKey $PublicKey -Privacy $Privacy -Encryption $Encryption
    }
    return Invoke-GLRequest -Method POST -Uri "https://api.powerbi.com/v1.0/myorg/gateways/$GatewayId/datasources" `
        -Token $PbiToken -Body $body -MaxRetry 2
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
    # Who has access to many connections, one documented Fabric call each, in parallel.
    param([Parameter(Mandatory)][string[]]$Ids, [Parameter(Mandatory)][string]$FabricToken)
    $map = @{}
    foreach ($id in $Ids) { $map["https://api.fabric.microsoft.com/v1/connections/$id/roleAssignments"] = $id }
    $out = @{}
    if ($map.Count -eq 0) { return $out }
    $res = Invoke-GLParallelGet -Uris @($map.Keys) -Token $FabricToken -TimeoutSec 60
    foreach ($u in $map.Keys) {
        $r = $res[$u]
        $out[$map[$u]] = if ($r -and $r.Ok -and $r.Body) { @($r.Body.value) } else { $null }
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
            Account  - the username stored in the credentials, if any
            Users    - list of @{ Principal; Right }
    #>
    param([Parameter(Mandatory)][string]$PbiToken, [int]$MaxPages = 200)
    $next  = 'https://api.powerbi.com/v2.0/myorg/me/gatewayClusterDatasources?$expand=users'
    $out   = @{}
    $pages = 0
    while ($next -and $pages -lt $MaxPages) {
        $pages++
        $r = Invoke-GLRequest -Uri $next -Token $PbiToken
        foreach ($ds in $r.value) {
            if (-not $ds -or -not $ds.id) { continue }
            $account = ''
            $pcp = $ds.credentialDetails.publicCredentialProperties
            if ($pcp) {
                try {
                    $props = if ($pcp -is [string]) { $pcp | ConvertFrom-Json -ErrorAction Stop } else { $pcp }
                    $u = $props | Where-Object { $_.name -eq 'username' } | Select-Object -First 1
                    if ($u) { $account = [string]$u.value }
                } catch { }
            }
            $users = foreach ($x in $ds.users) {
                if (-not $x) { continue }
                $who = @($x.emailAddress, $x.userPrincipalName, $x.displayName, $x.identifier, $x.id) | Where-Object { $_ } | Select-Object -First 1
                [pscustomobject]@{ Principal = [string]$who; Right = [string](@($x.datasourceAccessRight, $x.role) | Where-Object { $_ } | Select-Object -First 1) }
            }
            $out[([string]$ds.id).ToLowerInvariant()] = [pscustomobject]@{ Account = $account; Users = @($users) }
        }
        $next = $null
        $nl = $r.PSObject.Properties['@odata.nextLink']
        if ($nl -and $nl.Value) { $next = [string]$nl.Value }
    }
    return $out
}

function ConvertFrom-GLConnectionString {
    <#
        Server and database from an ordinary connection string - "Data Source=x;
        Initial Catalog=y", "Server=x;Database=y", "Host=x;Port=1521;Service Name=z"
        and so on. Anything unrecognised is left for the user to fill in.
    #>
    param([string]$Text)
    $result = [ordered]@{ Server = ''; Database = ''; Type = '' }
    if ([string]::IsNullOrWhiteSpace($Text)) { return [pscustomobject]$result }
    $kv = @{}
    foreach ($part in ($Text -split ';')) {
        $i = $part.IndexOf('=')
        if ($i -le 0) { continue }
        $kv[$part.Substring(0, $i).Trim().ToLowerInvariant()] = $part.Substring($i + 1).Trim().Trim('"', "'")
    }
    $server = @('data source', 'server', 'address', 'addr', 'network address', 'host', 'hostname', 'dsn') |
        ForEach-Object { $kv[$_] } | Where-Object { $_ } | Select-Object -First 1
    $db = @('initial catalog', 'database', 'dbname', 'catalog', 'service name', 'servicename', 'sid') |
        ForEach-Object { $kv[$_] } | Where-Object { $_ } | Select-Object -First 1
    if ($server -and $kv['port'] -and $server -notmatch '[:,]\d+$') { $server = "$($server):$($kv['port'])" }
    # an empty pipeline yields PowerShell's "nothing" value, which [string] does not
    # reliably turn into '' - so say it explicitly
    $result.Server   = if ($server) { [string]$server } else { '' }
    $result.Database = if ($db)     { [string]$db }     else { '' }
    # a guess, only where the keywords are unambiguous - the user can change it
    if ($kv.ContainsKey('initial catalog') -or $kv.ContainsKey('integrated security') -or $kv.ContainsKey('trustservercertificate')) { $result.Type = 'Sql' }
    elseif ($kv.ContainsKey('service name') -or $kv.ContainsKey('servicename') -or $kv.ContainsKey('sid')) { $result.Type = 'Oracle' }
    return [pscustomobject]$result
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
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($it in $Items) {
        foreach ($p in $Principals) {
            if ($Progress.Cancel) { return , $out.ToArray() }
            $rec = @{ Audit = $Audit; Action = 'Grant access'; TargetType = 'Connection'; Target = $it.Name; TargetId = $it.Id
                      Gateway = $it.Gateway; GatewayId = $it.GatewayId; Principal = $p.DisplayName; PrincipalId = $p.Id
                      PrincipalType = $p.Type; Role = $Role }
            try {
                $null = Add-GLRoleAssignment -Kind connections -Id $it.Id -PrincipalId $p.Id -PrincipalType $p.Type -Role $Role -FabricToken $FabricToken
                Write-GLChange @rec -Result Done
                $out.Add((New-GLResult $it.Name $it.Id $true "granted $Role to $($p.DisplayName)"))
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
                $who = if ($h.principal.displayName) { $h.principal.displayName } else { $h.principal.id }
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
        $Audit
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
            try {
                $key = $PublicKeys[([string]$it.GatewayId).ToLowerInvariant()]
                $enc = ConvertTo-GLEncryptionSetting -Current $it.Encryption -Choice $EncryptionChoice
                Set-GLConnectionCredential -GatewayId $it.GatewayId -ConnectionId $it.Id -PublicKey $key `
                    -CredentialType $CredentialType -Username $Username -Password $Password `
                    -Privacy $it.Privacy -Encryption $enc -PbiToken $PbiToken
                Write-GLChange @rec -Result Done
                $out.Add((New-GLResult $it.Name $it.Id $true "credentials updated ($CredentialType)"))
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
        [Parameter(Mandatory)][string]$Path
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
                          $who = @($pr.userDetails.userPrincipalName, $pr.groupDetails.email, $pr.displayName, $pr.id) | Where-Object { $_ } | Select-Object -First 1
                          "$who ($($pr.type), $($_.role))"
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

function Invoke-GLBulkCreate {
    <#
        Rows from the Create tab: Gateway (name or id), Name, Type, Server,
        Database, Path, Url, ConnectionString, ConnectionDetailsJson,
        CredentialType, Username, Privacy, Encryption. The password is one value
        for the whole run - it is never stored in a row or a CSV.
    #>
    param(
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)]$Gateways,                 # Fabric gateway objects
        [string]$DefaultGateway,
        [string]$Password,
        [Parameter(Mandatory)][string]$PbiToken,
        [Parameter(Mandatory)][hashtable]$Progress,
        $Audit
    )
    $byKey = @{}
    foreach ($g in $Gateways) {
        if ([string]$g.type -ne 'OnPremises') { continue }
        $byKey[([string]$g.id).ToLowerInvariant()] = $g
        $byKey[([string]$g.displayName).ToLowerInvariant()] = $g
    }
    $Progress.Total = @($Rows).Count
    $Progress.Done  = 0
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $Rows) {
        if ($Progress.Cancel) { return , $out.ToArray() }
        $name = [string]$r.Name
        $rec  = @{ Audit = $Audit; Action = 'Create connection'; TargetType = 'Connection'; Target = $name; Gateway = [string]$r.Gateway }
        try {
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'the row has no Name' }
            if ([string]::IsNullOrWhiteSpace([string]$r.Type)) { throw 'the row has no Type (Sql, Oracle, File, Web, ...)' }
            $gwName = if ([string]$r.Gateway) { [string]$r.Gateway } else { $DefaultGateway }
            if (-not $gwName) { throw 'no gateway - fill in the Gateway column or pick a default' }
            $g = $byKey[$gwName.Trim().ToLowerInvariant()]
            if (-not $g) { throw "no on-premises gateway called '$gwName'" }

            $details = ConvertTo-GLConnectionDetails -Server $r.Server -Database $r.Database -Path $r.Path -Url $r.Url `
                -ConnectionString $r.ConnectionString -Json $r.ConnectionDetailsJson
            $ctype = if ([string]$r.CredentialType) { [string]$r.CredentialType } else { 'Windows' }
            $priv  = if ([string]$r.Privacy) { [string]$r.Privacy } else { 'Organizational' }
            $encr  = if ([string]$r.Encryption -eq 'NotEncrypted') { 'NotEncrypted' } else { 'Encrypted' }

            $rec.Gateway   = [string]$g.displayName
            $rec.GatewayId = [string]$g.id
            $rec.Details   = "Type=$($r.Type); Credential=$ctype; Username=$($r.Username); Privacy=$priv; Details=$details"
            $res = New-GLGatewayConnection -GatewayId $g.id -PublicKey $g.publicKey -Name $name -DataSourceType ([string]$r.Type) `
                -ConnectionDetails $details -CredentialType $ctype -Username ([string]$r.Username) -Password $Password `
                -Privacy $priv -Encryption $encr -PbiToken $PbiToken
            Write-GLChange @rec -Result Done -TargetId ([string]$res.id)
            $out.Add((New-GLResult $name ([string]$res.id) $true "created on $($g.displayName)"))
        }
        catch {
            Write-GLChange @rec -Result Failed -Message $_.Exception.Message
            $out.Add((New-GLResult $name '' $false $_.Exception.Message))
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

function New-GLDefaultSettings {
    return [ordered]@{ Theme = 'Light'; FontSize = 12; History = [ordered]@{} }
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
        if ($j.History) {
            foreach ($p in $j.History.PSObject.Properties) {
                if ($p.Name -match 'pass|pwd|secret') { continue }
                $s.History[$p.Name] = @($p.Value | ForEach-Object { [string]$_ } | Where-Object { $_ })
            }
        }
    } catch { }
    return $s
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
        InputBg = '#FFFFFF'; LogBg = '#FFFFFF'; LogInk = '#334155'; Shadow = '#1A0F172A'; Warn = '#B45309'
    }
    Dark = [ordered]@{
        WindowBg = '#0E1117'; Surface = '#161B22'; SurfaceAlt = '#1B2129'; Header = '#1F2630'
        Border = '#2A313C'; BorderStrong = '#3A4250'; Ink = '#E6EDF3'; InkMuted = '#9AA4B2'; InkFaint = '#6E7681'
        Accent = '#3B82F6'; AccentHover = '#60A5FA'; AccentInk = '#FFFFFF'; AccentSoft = '#1E3A5F'
        Danger = '#F87171'; DangerSoft = '#3B1D1D'; Hover = '#222A35'; Selection = '#1E3A5F'; SelectionInk = '#E6EDF3'
        InputBg = '#0D1117'; LogBg = '#0D1117'; LogInk = '#C9D1D9'; Shadow = '#66000000'; Warn = '#FBBF24'
    }
    Midnight = [ordered]@{
        WindowBg = '#0B1020'; Surface = '#111933'; SurfaceAlt = '#152040'; Header = '#18244A'
        Border = '#22305C'; BorderStrong = '#2E3F75'; Ink = '#E2E8FF'; InkMuted = '#94A3D4'; InkFaint = '#6B78A8'
        Accent = '#8B5CF6'; AccentHover = '#A78BFA'; AccentInk = '#FFFFFF'; AccentSoft = '#2E2560'
        Danger = '#FB7185'; DangerSoft = '#3D1B2E'; Hover = '#1A2650'; Selection = '#2E2560'; SelectionInk = '#E2E8FF'
        InputBg = '#0B1328'; LogBg = '#0B1328'; LogInk = '#C7D2FE'; Shadow = '#66000000'; Warn = '#FBBF24'
    }
    Contrast = [ordered]@{
        WindowBg = '#000000'; Surface = '#000000'; SurfaceAlt = '#0A0A0A'; Header = '#000000'
        Border = '#FFFFFF'; BorderStrong = '#FFFFFF'; Ink = '#FFFFFF'; InkMuted = '#FFFF00'; InkFaint = '#C0C0C0'
        Accent = '#00FFFF'; AccentHover = '#FFFF00'; AccentInk = '#000000'; AccentSoft = '#003333'
        Danger = '#FF6060'; DangerSoft = '#330000'; Hover = '#1A1A1A'; Selection = '#0000FF'; SelectionInk = '#FFFFFF'
        InputBg = '#000000'; LogBg = '#000000'; LogInk = '#FFFFFF'; Shadow = '#00000000'; Warn = '#FFFF00'
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
#  share) without ever writing to the same file; the Activity tab reads them all.
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
    $sb = New-Object System.Text.StringBuilder
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

function Select-GLChanges {
    param($Rows, [string]$Text, [string]$Action, [string]$Result, [int]$Days = 0, [string]$User)
    $ic  = [System.StringComparison]::OrdinalIgnoreCase
    $cut = if ($Days -gt 0) { (Get-Date).Date.AddDays(1 - $Days) } else { [datetime]::MinValue }
    $out = foreach ($r in $Rows) {
        if ($r.When -lt $cut) { continue }
        if ($Action -and $Action -ne '(all)' -and $r.Action -ne $Action) { continue }
        if ($Result -and $Result -ne '(all)' -and $r.Result -ne $Result) { continue }
        if ($User   -and $User   -ne '(all)' -and $r.User   -ne $User)   { continue }
        if ($Text) {
            $hay = "$($r.Target)|$($r.Gateway)|$($r.Principal)|$($r.Details)|$($r.Message)|$($r.TargetId)|$($r.RunId)|$($r.User)"
            if ($hay.IndexOf($Text.Trim(), $ic) -lt 0) { continue }
        }
        $r
    }
    return , @($out)
}

function Test-GLUndoable {
    # Only changes with an exact opposite can be undone.
    param($Row)
    return ($Row.Result -eq 'Done' -and $Row.Action -in 'Grant access', 'Remove access', 'Enable member', 'Disable member')
}

function Invoke-GLUndo {
    <#
        Reverses recorded changes: a grant is removed, a removal is granted again
        with the same role, a member is switched back. Every undo is recorded as a
        change of its own, marked as the undo of the original.
    #>
    param(
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)][string]$FabricToken,
        $Audit,
        [Parameter(Mandatory)][hashtable]$Progress
    )
    $Progress.Total = @($Rows).Count
    $Progress.Done  = 0
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $Rows) {
        if ($Progress.Cancel) { return , $out.ToArray() }
        $note = "undo of $($r.Action), $($r.Time) by $($r.User), run $($r.RunId)"
        $kind = if ($r.TargetType -eq 'Gateway') { 'gateways' } else { 'connections' }
        $common = @{ Audit = $Audit; TargetType = $r.TargetType; Target = $r.Target; TargetId = $r.TargetId; Gateway = $r.Gateway; GatewayId = $r.GatewayId
                     Principal = $r.Principal; PrincipalId = $r.PrincipalId; PrincipalType = $r.PrincipalType; Role = $r.Role; Details = $note }
        try {
            if (-not (Test-GLUndoable $r)) {
                $out.Add((New-GLResult $r.Target $r.TargetId $false "$($r.Action) ($($r.Result)) cannot be undone"))
            }
            elseif ($r.Action -eq 'Grant access') {
                $ras  = Get-GLRoleAssignments -Kind $kind -Id $r.TargetId -FabricToken $FabricToken
                $hits = @($ras | Where-Object { [string]$_.principal.id -eq $r.PrincipalId -and [string]$_.role -eq $r.Role })
                if ($hits.Count -eq 0) {
                    Write-GLChange @common -Action 'Remove access' -Result NoChange -Message 'no longer had that access'
                    $out.Add((New-GLResult $r.Target $r.TargetId $true "$($r.Principal) no longer had $($r.Role)"))
                }
                foreach ($h in $hits) {
                    Remove-GLRoleAssignment -Kind $kind -Id $r.TargetId -AssignmentId $h.id -FabricToken $FabricToken
                    Write-GLChange @common -Action 'Remove access' -Result Done
                    $out.Add((New-GLResult $r.Target $r.TargetId $true "removed $($r.Principal) ($($r.Role)) again"))
                }
            }
            elseif ($r.Action -eq 'Remove access') {
                $null = Add-GLRoleAssignment -Kind $kind -Id $r.TargetId -PrincipalId $r.PrincipalId -PrincipalType $r.PrincipalType -Role $r.Role -FabricToken $FabricToken
                Write-GLChange @common -Action 'Grant access' -Result Done
                $out.Add((New-GLResult $r.Target $r.TargetId $true "granted $($r.Role) to $($r.Principal) again"))
            }
            else {
                $enable = $r.Action -eq 'Disable member'
                Set-GLMemberEnabled -GatewayId $r.GatewayId -MemberId $r.TargetId -Enabled $enable -FabricToken $FabricToken
                Write-GLChange @common -Action $(if ($enable) { 'Enable member' } else { 'Disable member' }) -Result Done
                $out.Add((New-GLResult $r.Target $r.TargetId $true "$(if ($enable) { 'enabled' } else { 'disabled' }) again"))
            }
        }
        catch {
            $m = $_.Exception.Message
            $opposite = @{ 'Grant access' = 'Remove access'; 'Remove access' = 'Grant access'; 'Enable member' = 'Disable member'; 'Disable member' = 'Enable member' }[$r.Action]
            if ($opposite) { Write-GLChange @common -Action $opposite -Result Failed -Message $m }
            $out.Add((New-GLResult $r.Target $r.TargetId $false $m))
        }
        $Progress.Done++
    }
    return , $out.ToArray()
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

    # ---- gateways: one of every state ----
    $s.Gateways = [System.Collections.Generic.List[object]]::new()
    $s.Members  = @{}
    $s.Live     = @{}
    $s.Rsa      = @{}
    $gw = @(
        @{ Key = 'prod';    Name = 'Contoso Prod Cluster';      Lb = 'DistributeEvenly'; Members = @(@('CTSGW-PRD01', '3000.290.10', 'Live'), @('CTSGW-PRD02', '3000.290.10', 'Live'), @('CTSGW-PRD03', '3000.290.10', 'Live')) }
        @{ Key = 'finance'; Name = 'Contoso Finance Cluster';   Lb = 'Failover';         Members = @(@('CTSGW-FIN01', '3000.290.10', 'Live'), @('CTSGW-FIN02', '3000.282.5', 'Offline')) }
        @{ Key = 'legacy';  Name = 'Legacy Warehouse Gateway';  Lb = 'Failover';         Members = @(, @('LEGGW-01', '3000.246.5', 'Offline')) }
        @{ Key = 'test';    Name = 'Contoso Test Cluster';      Lb = 'Failover';         Members = @(@('CTSGW-TST01', '3000.290.10', 'Live'), @('CTSGW-TST02', '3000.290.10', 'Timeout')) }
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

    # ---- connections ----
    $gid = @{}; foreach ($k in 'prod', 'finance', 'legacy', 'test', 'vnet') { $gid[$k] = New-GLDemoId "gateway|$k" }
    #        name                        gateway   type               path                                              credential  account
    # each row starts with a comma: without it @( ) would flatten the rows into loose strings
    $defs = @(
        ,@('Sales DW',                    'prod',    'SQL',             'sqlprd01.contoso.local;SalesDW',                 'Windows',  'CONTOSO\svc_sales')
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
    foreach ($d in $defs) {
        $cid  = New-GLDemoId "connection|$($d[0])"
        $conn = if ($d[1] -eq 'vnet') { 'VirtualNetworkGateway' } elseif ($d[1]) { 'OnPremisesGateway' } else { 'ShareableCloud' }
        $s.Connections.Add([pscustomobject]@{
            id = $cid; displayName = $d[0]; connectivityType = $conn; gatewayId = $(if ($d[1]) { $gid[$d[1]] } else { $null })
            connectionDetails = [pscustomobject]@{ type = $d[2]; path = $d[3] }
            privacyLevel = $(if ($d[0] -like 'HR*' -or $d[0] -like 'Finance*') { 'Private' } else { 'Organizational' })
            credentialDetails = [pscustomobject]@{ credentialType = $d[4]; singleSignOnType = 'None'
                connectionEncryption = $(if ($d[2] -in 'SQL', 'PostgreSql') { 'Encrypted' } elseif ($d[2] -eq 'Oracle') { 'Any' } else { 'NotEncrypted' }); skipTestConnection = $false }
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
    # matching the demo's change history
    $null = Add-GLDemoRole $s "connections/$($cn['Sales DW'])" $joe 'User'
    $null = Add-GLDemoRole $s "connections/$($cn['Sales Staging'])" $joe 'User'
    return $s
}

function Get-GLDemoPrincipal($Store, [string]$Id) {
    $u = $Store.Users | Where-Object id -eq $Id | Select-Object -First 1
    if ($u) { return [pscustomobject]@{ id = $u.id; displayName = $u.displayName; type = 'User'; userDetails = [pscustomobject]@{ userPrincipalName = $u.userPrincipalName } } }
    $g = $Store.Groups | Where-Object id -eq $Id | Select-Object -First 1
    if ($g) { return [pscustomobject]@{ id = $g.id; displayName = $g.displayName; type = 'Group'; groupDetails = [pscustomobject]@{ groupType = 'SecurityGroup'; email = $g.mail } } }
    $p = $Store.Sps | Where-Object id -eq $Id | Select-Object -First 1
    if ($p) { return [pscustomobject]@{ id = $p.id; displayName = $p.displayName; type = 'ServicePrincipal'; servicePrincipalDetails = [pscustomobject]@{ aadAppId = $p.appId } } }
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
                    if ($M -eq 'GET') { return New-GLDemoReply 200 ([pscustomobject]@{ value = @($list) }) }
                    if ($M -eq 'POST') {
                        $p = Get-GLDemoPrincipal $s ([string]$Body.principal.id)
                        if (-not $p) { return New-GLDemoFabricError 400 'PrincipalNotFound' 'The principal could not be found in the directory.' }
                        if ($list | Where-Object { $_.principal.id -eq $p.id }) { return New-GLDemoFabricError 409 'PrincipalAlreadyHasRole' 'The principal already has a role on this item.' }
                        return [pscustomobject]@{ Status = 201; Body = (Add-GLDemoRole $s $key $p ([string]$Body.role)) }
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
                    return New-GLDemoReply 200 ([pscustomobject]@{ value = @($v) })
                }
                if ($M -eq 'GET' -and $path -match '^/v2\.0/myorg/me/gatewayClusters/[^/]+/memberGateways/([^/]+)/status$') {
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
                            users = @(foreach ($a in @($s.Roles["connections/$($c.id)"])) {
                                [pscustomobject]@{ emailAddress = @($a.principal.userDetails.userPrincipalName, $a.principal.groupDetails.email) | Where-Object { $_ } | Select-Object -First 1
                                                   displayName = $a.principal.displayName; identifier = $a.principal.id
                                                   datasourceAccessRight = $(if ($a.role -eq 'Owner') { 'ReadOverrideEffectiveIdentity' } else { 'Read' }) } })
                        }
                    }
                    return New-GLDemoReply 200 ([pscustomobject]@{ value = @($v) })
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
                    if ($M -in 'PATCH', 'POST') {
                        # what a gateway does with credentials: decrypt them, then try them
                        $cd = $Body.credentialDetails
                        try { $plain = Unprotect-GLDemoCredential $s $g.id ([string]$cd.credentials) | ConvertFrom-Json }
                        catch { return New-GLDemoReply 400 (New-GLDemoPbiError 'DM_GWPipeline_Gateway_InvalidConnectionCredentials' "The gateway could not decrypt the credentials: $($_.Exception.Message)") }
                        $user = ($plain.credentialData | Where-Object name -eq 'username').value
                        $pass = ($plain.credentialData | Where-Object { $_.name -in 'password', 'key' }).value
                        if ($pass -eq 'wrong') { return New-GLDemoReply 400 (New-GLDemoPbiError 'DM_GWPipeline_Gateway_DataSourceAccessError' "Login failed for user '$user'.") }
                        if ($M -eq 'PATCH') {
                            $c.credentialDetails.credentialType = [string]$cd.credentialType
                            if ($user) { $s.Accounts[$c.id] = $user } else { $s.Accounts.Remove($c.id) }
                            if ($cd.privacyLevel) { $c.privacyLevel = [string]$cd.privacyLevel }
                            $s.StatusFail.Remove($c.id)       # good credentials fix a login failure
                            return New-GLDemoReply 200 $null
                        }
                        $name = [string]$Body.datasourceName
                        if ($s.Connections | Where-Object { $_.gatewayId -eq $g.id -and $_.displayName -eq $name }) {
                            return New-GLDemoReply 400 ([pscustomobject]@{ error = [pscustomobject]@{ code = 'DuplicateDatasourceName'; message = "A data source called '$name' already exists on this gateway." } })
                        }
                        $det = [string]$Body.connectionDetails | ConvertFrom-Json
                        $pth = (@($det.server, $det.database, $det.path, $det.url, $det.connectionString) | Where-Object { $_ }) -join ';'
                        $new = [pscustomobject]@{
                            id = New-GLDemoId "connection|$name|$([guid]::NewGuid())"; displayName = $name; connectivityType = 'OnPremisesGateway'; gatewayId = $g.id
                            connectionDetails = [pscustomobject]@{ type = [string]$Body.dataSourceType; path = $pth }
                            privacyLevel = [string]$cd.privacyLevel
                            credentialDetails = [pscustomobject]@{ credentialType = [string]$cd.credentialType; singleSignOnType = 'None'; connectionEncryption = [string]$cd.encryptedConnection; skipTestConnection = $false }
                        }
                        $s.Connections.Add($new)
                        if ($user) { $s.Accounts[$new.id] = $user }
                        $null = Add-GLDemoRole $s "connections/$($new.id)" ($s.Users | Where-Object userPrincipalName -eq $s.Me | Select-Object -First 1) 'Owner'
                        return [pscustomobject]@{ Status = 201; Body = [pscustomobject]@{ id = $new.id; gatewayId = $g.id; datasourceName = $name; datasourceType = $new.connectionDetails.type } }
                    }
                }
            }
            # -------------------------------------------------------------- Graph
            'graph\.microsoft\.com' {
                $notFound = New-GLDemoReply 404 ([pscustomobject]@{ error = [pscustomobject]@{ code = 'Request_ResourceNotFound'; message = 'The object does not exist.' } })
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

function Initialize-GLDemoHistory {
    # A week of earlier changes - two people - so the Activity tab has a story to
    # tell from the start, including changes that can be undone. Written once.
    param([Parameter(Mandatory)][string]$Folder)
    if (Get-ChildItem -LiteralPath $Folder -Filter 'changes-*.csv' -ErrorAction SilentlyContinue) { return }
    $s = Get-GLDemoStore
    $cn = @{}; foreach ($c in $s.Connections) { $cn[$c.displayName] = $c }
    $gn = @{}; foreach ($g in $s.Gateways) { $gn[$g.displayName] = $g }
    $u = @{}; foreach ($x in $s.Users) { $u[$x.displayName] = $x }
    $fin = $s.Groups[1]
    $finGw = $gn['Contoso Finance Cluster']
    $fin02 = $s.Members[$finGw.id] | Where-Object displayName -eq 'CTSGW-FIN02'
    $rows = @(
        @{ Ago = 6.2; By = 'alex.admin@contoso.com'; Action = 'Update credentials'; Result = 'Done'; C = 'Finance GL'; Details = 'Type=Windows; Username=CONTOSO\svc_fin; Encryption=Keep' }
        @{ Ago = 5.1; By = 'alex.admin@contoso.com'; Action = 'Grant access'; Result = 'Done'; C = 'Finance GL'; P = $fin; PType = 'Group'; Role = 'User' }
        @{ Ago = 4.3; By = 'alex.admin@contoso.com'; Action = 'Enable member'; Result = 'Done'; Member = $fin02; Gw = $finGw }
        @{ Ago = 2.4; By = 'demo.user@contoso.com';  Action = 'Grant access'; Result = 'Done'; C = 'Sales DW'; P = $u['Joe Smith']; PType = 'User'; Role = 'User' }
        @{ Ago = 2.4; By = 'demo.user@contoso.com';  Action = 'Grant access'; Result = 'NoChange'; C = 'Sales Staging'; P = $u['Joe Smith']; PType = 'User'; Role = 'User'; Message = 'already had access' }
        @{ Ago = 1.2; By = 'demo.user@contoso.com';  Action = 'Remove access'; Result = 'Done'; C = 'Customer 360'; P = $u['Raj Patel']; PType = 'User'; Role = 'User' }
        @{ Ago = 1.1; By = 'demo.user@contoso.com';  Action = 'Update credentials'; Result = 'Failed'; C = 'HR Core'; Details = 'Type=Windows; Username=CONTOSO\svc_hr; Encryption=Keep'; Message = "HTTP 400 : DM_GWPipeline_Gateway_DataSourceAccessError: Login failed for user 'CONTOSO\svc_hr'." }
        @{ Ago = 0.2; By = 'demo.user@contoso.com';  Action = 'Delete connection'; Result = 'Done'; Name = 'Budget 2019 (old)'; Details = 'Backup=deleted-connections-demo.csv' }
    )
    $runs = @{}
    foreach ($r in $rows) {
        if (-not $runs.ContainsKey("$($r.By)|$($r.Ago)")) { $runs["$($r.By)|$($r.Ago)"] = New-GLAudit -Folder $Folder -User $r.By -Tenant 'contoso.example (demo)' -Version $script:AppVersion }
        $a = $runs["$($r.By)|$($r.Ago)"]
        $p = @{ Audit = $a; Action = $r.Action; Result = $r.Result; When = (Get-Date).AddDays(-$r.Ago); Details = $r.Details; Message = $r.Message }
        if ($r.C) {
            $c = $cn[$r.C]; $g = $s.Gateways | Where-Object id -eq $c.gatewayId | Select-Object -First 1
            $p += @{ TargetType = 'Connection'; Target = $c.displayName; TargetId = $c.id; Gateway = [string]$g.displayName; GatewayId = [string]$c.gatewayId }
        }
        elseif ($r.Member) {
            $p += @{ TargetType = 'Gateway member'; Target = $r.Member.displayName; TargetId = $r.Member.id; Gateway = $r.Gw.displayName; GatewayId = $r.Gw.id }
            $p.Details = "Machine=$($r.Member.displayName)"
        }
        else { $p += @{ TargetType = 'Connection'; Target = $r.Name; TargetId = (New-GLDemoId "connection|$($r.Name)") } }
        if ($r.P) {
            $name = if ($r.P.userPrincipalName) { "$($r.P.displayName) <$($r.P.userPrincipalName)>" } else { "$($r.P.displayName) <$($r.P.mail)>" }
            $p += @{ Principal = $name; PrincipalId = $r.P.id; PrincipalType = $r.PType; Role = $r.Role }
        }
        Write-GLChange @p
    }
}

# Everything a background worker needs. The UI thread hands each worker its own
# copy of these through the runspace pool's initial session state.
$script:WorkerFunctions = @(
    'Test-GLGuid', 'ConvertFrom-GLToken', 'ConvertFrom-GLApiError', 'Invoke-GLRequest', 'Get-GLPaged',
    'Invoke-GLParallelGet', 'Get-GLLiveStatus', 'Get-GLGatewayData', 'Get-GLConnectionData', 'Get-GLRoleAssignments',
    'New-GLRoleAssignmentBody', 'Add-GLRoleAssignment', 'Remove-GLRoleAssignment',
    'Resolve-GLPrincipal', 'Test-GLConnection',
    'ConvertTo-GLCredentialJson', 'ConvertTo-GLEncryptedCredential', 'New-GLCredentialDetails',
    'Set-GLConnectionCredential', 'ConvertTo-GLConnectionDetails', 'New-GLGatewayConnection',
    'Remove-GLConnection', 'Set-GLMemberEnabled', 'Test-GLConnectionsBulk', 'Get-GLRoleAssignmentsBulk',
    'Get-GLDatasourceDirectory', 'Resolve-GLHostAddress', 'Split-GLList', 'ConvertTo-GLEncryptionSetting',
    'New-GLResult', 'Invoke-GLBulkGrant', 'Invoke-GLBulkRevoke', 'Invoke-GLBulkCredentials',
    'Backup-GLConnections', 'Invoke-GLBulkDelete', 'Invoke-GLBulkCreate',
    'Get-GLSafeName', 'Get-GLChangePath', 'Write-GLChange', 'Read-GLChanges', 'Test-GLUndoable', 'Invoke-GLUndo',
    'Get-GLDemoStore', 'New-GLDemoId', 'Get-GLDemoPrincipal', 'Add-GLDemoRole', 'Get-GLDemoAddress',
    'Unprotect-GLDemoCredential', 'New-GLDemoPbiError', 'New-GLDemoReply', 'New-GLDemoFabricError', 'Invoke-GLDemoHttp'
)

# ============================================================================
#  SIGN-IN  -  UI thread only. Tokens are fetched here and handed to workers.
# ============================================================================
$script:AuthMode   = $null
$script:SignedInAs = ''
$script:TenantShown = ''

function Connect-GL {
    [CmdletBinding()]
    param([string]$TenantId, [switch]$DeviceCode, [string]$AuthModule = 'Auto')

    $mode = $AuthModule
    if ($mode -eq 'Auto') {
        if (Get-Module -ListAvailable -Name Az.Accounts) { $mode = 'Az' }
        elseif (Get-Module -ListAvailable -Name MicrosoftPowerBIMgmt.Profile) { $mode = 'PowerBIMgmt' }
        else {
            throw "No sign-in module found. Install one, for example:`n    Install-Module Az.Accounts -Scope CurrentUser"
        }
    }

    switch ($mode) {
        'Az' {
            Import-Module Az.Accounts -ErrorAction Stop
            $p = @{ ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
            if ($TenantId)   { $p.TenantId = $TenantId }
            if ($DeviceCode) { $p.UseDeviceAuthentication = $true }
            $null = Connect-AzAccount @p
            $ctx = Get-AzContext
            $script:SignedInAs  = [string]$ctx.Account.Id
            $script:TenantShown = [string]$ctx.Tenant.Id
        }
        'PowerBIMgmt' {
            Import-Module MicrosoftPowerBIMgmt.Profile -ErrorAction Stop
            if ($DeviceCode) { Write-Warning 'Device code sign-in needs Az.Accounts - using the browser instead.' }
            $p = @{ ErrorAction = 'Stop' }
            if ($TenantId) { $p.Tenant = $TenantId }
            $acct = Connect-PowerBIServiceAccount @p
            $script:SignedInAs  = [string]$acct.UserName
            $script:TenantShown = [string]$acct.TenantId
        }
    }
    $script:AuthMode = $mode
}

function Get-GLToken {
    # Fabric, Power BI or Graph. Returns $null for Graph when it is not available
    # (MicrosoftPowerBIMgmt cannot issue Graph tokens) - callers handle that.
    param([Parameter(Mandatory)][ValidateSet('Fabric', 'PowerBI', 'Graph')][string]$For)
    switch ($script:AuthMode) {
        'Demo' { return 'demo-token' }
        'Az' {
            $resource = @{
                Fabric  = 'https://api.fabric.microsoft.com'
                PowerBI = 'https://analysis.windows.net/powerbi/api'
                Graph   = 'https://graph.microsoft.com'
            }[$For]
            try {
                $t = Get-AzAccessToken -ResourceUrl $resource -ErrorAction Stop -WarningAction SilentlyContinue
                return (ConvertFrom-GLToken $t.Token)
            }
            catch {
                if ($For -eq 'Graph') { return $null }
                throw
            }
        }
        'PowerBIMgmt' {
            if ($For -eq 'Graph') { return $null }
            # One Power BI token - the Fabric API accepts it too.
            $h = Get-PowerBIAccessToken -AsString -ErrorAction Stop
            return ([string]$h -replace '^Bearer\s+', '')
        }
        default { throw 'Not signed in.' }
    }
}

# ============================================================================
#  SELF-TEST  -  every API once, read-only, and a plain verdict per call.
# ============================================================================
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

    $fab = $null; $pbi = $null; $gr = $null
    try { $fab = Get-GLToken Fabric;  Add-Result 'Token: Fabric'   $true  'issued' } catch { Add-Result 'Token: Fabric'   $false $_.Exception.Message }
    try { $pbi = Get-GLToken PowerBI; Add-Result 'Token: Power BI' $true  'issued' } catch { Add-Result 'Token: Power BI' $false $_.Exception.Message }
    $gr = Get-GLToken Graph
    Add-Result 'Token: Microsoft Graph' ([bool]$gr) $(if ($gr) { 'issued' } else { 'not available - name lookups need an object id' })

    $gateways = @(); $connections = @()
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
                Add-Result 'Fabric: connection access' $true "$($ra.Count) assignment(s) on '$($c1.displayName)'"
            } catch { Add-Result 'Fabric: connection access' $false $_.Exception.Message }
        }
    }

    if ($pbi) {
        # one gateway is enough to prove the endpoint works - the app checks them all
        Write-Host '        checking live status on one gateway (up to 30s)...' -ForegroundColor DarkGray
        try {
            $live = Get-GLLiveStatus -PbiToken $pbi -MaxClusters 1 -TimeoutSec 30
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
        }
    }

    if ($gr) {
        try {
            $me = Invoke-GLRequest -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName' -Token $gr -MaxRetry 1
            Add-Result 'Graph: read own profile' $true $me.userPrincipalName
        } catch { Add-Result 'Graph: read own profile' $false $_.Exception.Message }
    }

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
      <RowDefinition Height="6"/>
      <RowDefinition Height="175"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Border}" BorderThickness="0,0,0,1" Padding="16,10">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Name="TxtIdentity" VerticalAlignment="Center" Foreground="{DynamicResource InkMuted}" Margin="0,0,18,0"/>
          <TextBlock Text="Theme" Style="{DynamicResource Label}" Margin="0,0,6,0"/>
          <ComboBox Name="CmbTheme" Width="110" Height="28"/>
          <Button Name="BtnFontDown" Content="A-" MinWidth="34" Padding="6,2" Margin="12,0,2,0" ToolTip="Smaller text"/>
          <TextBlock Name="TxtFontSize" VerticalAlignment="Center" MinWidth="22" TextAlignment="Center" Foreground="{DynamicResource InkMuted}"/>
          <Button Name="BtnFontUp" Content="A+" MinWidth="34" Padding="6,2" Margin="2,0,0,0" ToolTip="Larger text"/>
          <Button Name="BtnClearHistory" Content="Clear history" Margin="12,0,0,0"
                  ToolTip="Forget everything typed into the search and name boxes. Passwords are never kept."/>
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
      <TabItem Header="Gateways">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="6"/>
            <RowDefinition Height="270"/>
          </Grid.RowDefinitions>

          <DockPanel Grid.Row="0" Margin="0,0,0,8">
            <TextBlock Name="TxtGwSummary" DockPanel.Dock="Right" Style="{DynamicResource Label}"/>
            <WrapPanel>
              <Button Name="BtnGwRefresh" Content="Refresh" Style="{DynamicResource Primary}"/>
              <CheckBox Name="ChkLive" Content="Live member status" IsChecked="True" VerticalAlignment="Center" Margin="8,0,2,0"
                        ToolTip="Online / offline per member, from the endpoint behind the portal's Manage gateways page. Not documented by Microsoft - untick it if it ever stops working."/>
              <TextBlock Text="(unofficial)" Foreground="{DynamicResource InkFaint}" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <CheckBox Name="ChkVnet" Content="Include VNet gateways" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <TextBlock Text="Auto-refresh" Style="{DynamicResource Label}"/>
              <ComboBox Name="CmbAutoRefresh" Width="80" Height="26"/>
              <TextBlock Text="Filter" Style="{DynamicResource Label}"/>
              <ComboBox Name="TxtGwFilter" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Width="180" Height="26" VerticalContentAlignment="Center"/>
              <Button Name="BtnGwCopyAll" Content="Copy all" Margin="12,0,6,0"
                      ToolTip="Every gateway and member, tab-separated - pastes straight into Excel or a ticket."/>
              <Button Name="BtnGwIpsAll" Content="Resolve IPs"
                      ToolTip="Resolve every member machine to an IP address. One block per gateway in the log, and all of it on the clipboard."/>
              <Button Name="BtnGwExport" Content="Export CSV"/>
              <Button Name="BtnGwCopyId" Content="Copy id"/>
            </WrapPanel>
          </DockPanel>

          <DataGrid IsReadOnly="True" CanUserAddRows="False" AutoGenerateColumns="True" SelectionMode="Single" Name="GridGateways" Grid.Row="1"/>
          <GridSplitter Grid.Row="2" HorizontalAlignment="Stretch" ResizeDirection="Rows" Background="Transparent"/>

          <Grid Grid.Row="3">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="3*"/>
              <ColumnDefinition Width="12"/>
              <ColumnDefinition Width="2*"/>
            </Grid.ColumnDefinitions>
            <DockPanel Grid.Column="0">
              <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                  <Button Name="BtnMemberEnable" Content="Enable"/>
                  <Button Name="BtnMemberDisable" Content="Disable" Style="{DynamicResource Danger}"/>
                  <Button Name="BtnGwCopyCluster" Content="Copy gateway"/>
                  <Button Name="BtnGwIpsCluster" Content="Resolve IPs" Margin="0"/>
                </StackPanel>
                <TextBlock Name="TxtMembersTitle" Text="Members" Style="{DynamicResource Section}"/>
              </DockPanel>
              <DataGrid IsReadOnly="True" CanUserAddRows="False" AutoGenerateColumns="True" SelectionMode="Single" Name="GridMembers"/>
            </DockPanel>
            <DockPanel Grid.Column="2">
              <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                  <Button Name="BtnGwAccessAdd" Content="Add..."/>
                  <Button Name="BtnGwAccessRemove" Content="Remove" Style="{DynamicResource Danger}" Margin="0"/>
                </StackPanel>
                <TextBlock Text="Gateway access" Style="{DynamicResource Section}"/>
              </DockPanel>
              <DataGrid IsReadOnly="True" CanUserAddRows="False" AutoGenerateColumns="True" SelectionMode="Single" Name="GridGwAccess"/>
            </DockPanel>
          </Grid>
        </Grid>
      </TabItem>

      <!-- ============================ CONNECTIONS ============================ -->
      <TabItem Header="Connections">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="6"/>
            <RowDefinition Height="330"/>
          </Grid.RowDefinitions>

          <WrapPanel Grid.Row="0" Margin="0,0,0,6">
            <TextBlock Text="Search" Style="{DynamicResource Label}" Margin="0,0,6,0"/>
            <ComboBox Name="TxtCnSearch" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Width="230" Height="26" VerticalContentAlignment="Center"
                     ToolTip="Name, path, type, gateway or id. Several values separated by ; - a connection matching any of them is listed."/>
            <TextBlock Text="User" Style="{DynamicResource Label}"/>
            <ComboBox Name="TxtCnUser" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Width="170" Height="26" VerticalContentAlignment="Center"
                     ToolTip="Someone with access. Needs the users loaded - tick Usernames and access, or press Verify users."/>
            <TextBlock Text="Account" Style="{DynamicResource Label}"/>
            <ComboBox Name="TxtCnAccount" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Width="150" Height="26" VerticalContentAlignment="Center"
                     ToolTip="The username stored in the connection's credentials. Needs Usernames and access."/>
            <TextBlock Text="Gateway" Style="{DynamicResource Label}"/>
            <ComboBox Name="CmbCnGateway" Width="180" Height="26"/>
            <TextBlock Text="Connectivity" Style="{DynamicResource Label}"/>
            <ComboBox Name="CmbCnConnectivity" Width="150" Height="26"/>
            <TextBlock Text="Type" Style="{DynamicResource Label}"/>
            <ComboBox Name="CmbCnType" Width="130" Height="26"/>
          </WrapPanel>

          <DockPanel Grid.Row="1" Margin="0,0,0,8">
            <TextBlock Name="TxtCnCount" DockPanel.Dock="Right" Style="{DynamicResource Label}"/>
            <WrapPanel>
              <Button Name="BtnCnRefresh" Content="Refresh" Style="{DynamicResource Primary}"/>
              <CheckBox Name="ChkDirectory" Content="Usernames and access" IsChecked="True" VerticalAlignment="Center" Margin="8,0,2,0"
                        ToolTip="Loads every connection's credential username and users in one call, from the endpoint the portal uses. Not documented by Microsoft."/>
              <TextBlock Text="(unofficial)" Foreground="{DynamicResource InkFaint}" VerticalAlignment="Center" Margin="0,0,12,0"/>
              <TextBlock Text="Gateway state" Style="{DynamicResource Label}"/>
              <CheckBox Name="ChkStOnline"  Content="Online"  IsChecked="True" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <CheckBox Name="ChkStPartial" Content="Partially online" IsChecked="True" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <CheckBox Name="ChkStOffline" Content="Offline" IsChecked="True" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <CheckBox Name="ChkStUnknown" Content="Unknown" IsChecked="True" VerticalAlignment="Center" Margin="0,0,12,0"/>
              <Button Name="BtnCnExclude" Content="Exclude selected rows"/>
              <Button Name="BtnCnUnexclude" Content="Show excluded"/>
              <Button Name="BtnCnExport" Content="Export CSV"/>
            </WrapPanel>
          </DockPanel>

          <DataGrid IsReadOnly="True" CanUserAddRows="False" AutoGenerateColumns="True" Name="GridConnections" Grid.Row="2" SelectionMode="Extended"/>
          <GridSplitter Grid.Row="3" HorizontalAlignment="Stretch" ResizeDirection="Rows" Background="Transparent"/>

          <Grid Grid.Row="4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="12"/>
              <ColumnDefinition Width="520"/>
            </Grid.ColumnDefinitions>

            <DockPanel Grid.Column="0">
              <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                  <Button Name="BtnCnTest" Content="Test"/>
                  <Button Name="BtnCnCopyId" Content="Copy id"/>
                  <Button Name="BtnCnAccessAdd" Content="Add..."/>
                  <Button Name="BtnCnAccessRemove" Content="Remove" Style="{DynamicResource Danger}" Margin="0"/>
                </StackPanel>
                <TextBlock Name="TxtCnSelected" Text="Select a connection to see who has access." Style="{DynamicResource Section}" TextTrimming="CharacterEllipsis"/>
              </DockPanel>
              <DataGrid IsReadOnly="True" CanUserAddRows="False" AutoGenerateColumns="True" SelectionMode="Single" Name="GridCnAccess"/>
            </DockPanel>

            <Border Grid.Column="2" Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Border}" BorderThickness="1" Padding="10,8">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel>
                  <TextBlock Name="TxtBulkTitle" Text="All listed connections" Style="{DynamicResource Section}"/>
                  <TextBlock Text="Everything below acts on every connection in the list above, after filters and exclusions."
                             Foreground="{DynamicResource InkMuted}" FontSize="11" TextWrapping="Wrap" Margin="0,2,0,4"/>
                  <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                    <Button Name="BtnBulkStatus" Content="Verify status"/>
                    <Button Name="BtnBulkUsers" Content="Verify users"/>
                  </StackPanel>

                  <GroupBox Header="Access">
                    <StackPanel>
                      <ComboBox Name="TxtBulkPrincipals" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Height="26" VerticalContentAlignment="Center"
                               ToolTip="Emails, group names or object ids, separated by ; - all of them are applied to every listed connection."/>
                      <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                        <TextBlock Text="Type" Style="{DynamicResource Label}" Margin="0,0,6,0"/>
                        <ComboBox Name="CmbBulkPrincipalType" Width="120" Height="26"/>
                        <TextBlock Text="Role" Style="{DynamicResource Label}"/>
                        <ComboBox Name="CmbBulkRole" Width="130" Height="26"/>
                        <Button Name="BtnBulkGrant" Content="Grant" Margin="10,0,6,0"/>
                        <Button Name="BtnBulkRevoke" Content="Remove" Style="{DynamicResource Danger}"/>
                      </StackPanel>
                    </StackPanel>
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
                      </Grid.RowDefinitions>
                      <TextBlock Grid.Row="0" Grid.Column="0" Text="Type" Style="{DynamicResource Label}" Margin="0,0,6,0"/>
                      <ComboBox Name="CmbCredType" Grid.Row="0" Grid.Column="1" Height="26"/>
                      <TextBlock Grid.Row="0" Grid.Column="2" Text="Encryption" Style="{DynamicResource Label}"/>
                      <ComboBox Name="CmbCredEncryption" Grid.Row="0" Grid.Column="3" Height="26"/>
                      <TextBlock Grid.Row="1" Grid.Column="0" Text="Username" Style="{DynamicResource Label}" Margin="0,6,6,0"/>
                      <ComboBox Name="TxtCredUser" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Grid.Row="1" Grid.Column="1" Height="26" Margin="0,6,0,0" VerticalContentAlignment="Center"/>
                      <TextBlock Grid.Row="1" Grid.Column="2" Text="Password" Style="{DynamicResource Label}" Margin="10,6,6,0"/>
                      <PasswordBox Name="PwdCred" Grid.Row="1" Grid.Column="3" Height="26" Margin="0,6,0,0" VerticalContentAlignment="Center"/>
                      <Button Name="BtnBulkCredentials" Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="4" Content="Update credentials"
                              HorizontalAlignment="Left" Margin="0,8,0,0"/>
                    </Grid>
                  </GroupBox>

                  <Button Name="BtnBulkDelete" Content="Delete all listed connections..." Style="{DynamicResource Danger}"
                          HorizontalAlignment="Left" Margin="0,10,0,0"/>
                </StackPanel>
              </ScrollViewer>
            </Border>
          </Grid>
        </Grid>
      </TabItem>

      <!-- ============================ CREATE ============================ -->
      <TabItem Header="Create connections">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <WrapPanel Grid.Row="0" Margin="0,0,0,8">
            <TextBlock Text="Default gateway" Style="{DynamicResource Label}" Margin="0,0,6,0"/>
            <ComboBox Name="CmbCreateGateway" Width="200" Height="26"
                      ToolTip="Used for every row whose Gateway column is empty."/>
            <Button Name="BtnCreateAdd" Content="+ row" Margin="12,0,6,0"/>
            <Button Name="BtnCreateRemove" Content="- row"/>
            <Button Name="BtnCreateClear" Content="Clear"/>
            <Button Name="BtnCreateLoad" Content="Load CSV..." Margin="12,0,6,0"/>
            <Button Name="BtnCreateTemplate" Content="Save CSV template..."/>
            <TextBlock Text="Password for this run" Style="{DynamicResource Label}" Margin="16,0,6,0"/>
            <PasswordBox Name="PwdCreate" Width="160" Height="26" VerticalContentAlignment="Center"
                         ToolTip="Used for every Windows, Basic or Key row. Never stored in the grid or in a CSV."/>
            <Button Name="BtnCreateRun" Content="Create all" Style="{DynamicResource Primary}" Margin="12,0,0,0"/>
          </WrapPanel>

          <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="12"/>
              <ColumnDefinition Width="340"/>
            </Grid.ColumnDefinitions>
            <DataGrid Name="GridCreate" Grid.Column="0" IsReadOnly="False" CanUserAddRows="True" AutoGenerateColumns="True" SelectionMode="Extended"/>
            <DockPanel Grid.Column="2">
              <TextBlock DockPanel.Dock="Top" Text="Paste connection strings, one per line" Style="{DynamicResource Section}" Margin="0,0,0,6"/>
              <Button DockPanel.Dock="Bottom" Name="BtnCreateParse" Content="Add rows from connection strings" Margin="0,8,0,0" HorizontalAlignment="Left"/>
              <TextBlock DockPanel.Dock="Bottom" Foreground="{DynamicResource InkMuted}" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,0"
                         Text="Server and database are read from each line; the type is filled in where the keywords make it clear. Common types: Sql, Oracle, AnalysisServices, File, Folder, Web, OData, SharePointList, Odbc, Extension - for connectors not covered by server / path / url, put the JSON in ConnectionDetailsJson."/>
              <TextBox Name="TxtCreateStrings" AcceptsReturn="True" VerticalContentAlignment="Top" TextWrapping="NoWrap" FontFamily="Consolas" FontSize="11"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
            </DockPanel>
          </Grid>
        </Grid>
      </TabItem>
      <!-- ============================ ACTIVITY ============================ -->
      <TabItem Name="TabActivity" Header="Activity">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <DockPanel Grid.Row="0" Margin="0,0,0,8">
            <TextBlock Name="TxtActCount" DockPanel.Dock="Right" Style="{DynamicResource Label}"/>
            <WrapPanel>
              <Button Name="BtnActRefresh" Content="Refresh" Style="{DynamicResource Primary}"/>
              <TextBlock Text="Period" Style="{DynamicResource Label}"/>
              <ComboBox Name="CmbActPeriod" Width="100" Height="26"/>
              <TextBlock Text="Action" Style="{DynamicResource Label}"/>
              <ComboBox Name="CmbActAction" Width="160" Height="26"/>
              <TextBlock Text="Result" Style="{DynamicResource Label}"/>
              <ComboBox Name="CmbActResult" Width="100" Height="26"/>
              <TextBlock Text="User" Style="{DynamicResource Label}"/>
              <ComboBox Name="CmbActUser" Width="200" Height="26"/>
              <TextBlock Text="Search" Style="{DynamicResource Label}"/>
              <ComboBox Name="TxtActFind" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Width="190" Height="26"
                        ToolTip="Connection, gateway, person, details or run id."/>
              <Button Name="BtnActUndo" Content="Undo selected..." Style="{DynamicResource Danger}" Margin="14,0,6,0"
                      ToolTip="Reverse your own completed access changes and member enable / disable. Each undo is recorded too."/>
              <Button Name="BtnActExport" Content="Export CSV"/>
              <Button Name="BtnActFolder" Content="Open folder" ToolTip="Where the change records and daily logs are kept."/>
            </WrapPanel>
          </DockPanel>
          <DataGrid Name="GridActivity" Grid.Row="1" IsReadOnly="True" CanUserAddRows="False" AutoGenerateColumns="True" SelectionMode="Extended"/>
        </Grid>
      </TabItem>
    </TabControl>

    <GridSplitter Grid.Row="2" HorizontalAlignment="Stretch" ResizeDirection="Rows" Background="Transparent"/>

    <Border Grid.Row="3" Margin="12,0,12,0" Background="{DynamicResource LogBg}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="8">
      <DockPanel>
        <DockPanel DockPanel.Dock="Top" Margin="10,6,8,2">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
            <ComboBox Name="TxtLogFind" IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" Width="190" Height="26"
                      ToolTip="Show only the lines containing this text."/>
            <ComboBox Name="CmbLogLevel" Width="150" Height="26" Margin="6,0,10,0"/>
            <Button Name="BtnLogCopy" Content="Copy" ToolTip="Copy what is shown."/>
            <Button Name="BtnLogSave" Content="Save..."/>
            <Button Name="BtnLogFolder" Content="Open folder" ToolTip="The daily log files and the change records."/>
            <Button Name="BtnLogClear" Content="Clear" Margin="0" ToolTip="Clear the panel. The log file keeps everything."/>
          </StackPanel>
          <TextBlock Text="Activity log" Style="{DynamicResource Section}"/>
        </DockPanel>
        <TextBox Name="TxtLog" IsReadOnly="True" BorderThickness="0" Background="{DynamicResource LogBg}" Foreground="{DynamicResource LogInk}"
                 VerticalContentAlignment="Top" Padding="8,2,8,6" FontFamily="Consolas" FontSize="11" TextWrapping="NoWrap"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
      </DockPanel>
    </Border>

    <Border Grid.Row="4" Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Border}" BorderThickness="0,1,0,0" Padding="14,5" Margin="0,8,0,0">
      <DockPanel>
        <Button Name="BtnCancel" DockPanel.Dock="Right" Content="Cancel" Visibility="Collapsed" Margin="10,0,0,0" MinHeight="22" Padding="10,1"/>
        <ProgressBar Name="Busy" DockPanel.Dock="Right" Width="180" Height="8" Visibility="Collapsed"/>
        <TextBlock Name="TxtStatus" Text="Ready" Foreground="{DynamicResource InkMuted}" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>
  </Grid>
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
              Style="{DynamicResource Primary}"/>
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
              Style="{DynamicResource DangerFilled}"/>
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

  <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="{DynamicResource Accent}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Accent}"/>
    <Setter Property="Foreground" Value="{DynamicResource AccentInk}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>

  <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Foreground" Value="{DynamicResource Danger}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Danger}"/>
  </Style>

  <Style x:Key="DangerFilled" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="{DynamicResource Danger}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Danger}"/>
    <Setter Property="Foreground" Value="{DynamicResource AccentInk}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>

  <!-- ===== text ===== -->
  <Style x:Key="Label" TargetType="TextBlock">
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="Foreground" Value="{DynamicResource InkMuted}"/>
    <Setter Property="Margin" Value="12,0,6,0"/>
  </Style>

  <Style x:Key="Section" TargetType="TextBlock">
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
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
            <Thumb x:Name="PART_RightHeaderGripper" HorizontalAlignment="Right" Width="6" Cursor="SizeWE" Opacity="0"/>
          </Grid>
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
  <Style x:Key="Primary" TargetType="Button">
    <Setter Property="Background" Value="{DynamicResource Accent}"/>
    <Setter Property="Foreground" Value="{DynamicResource AccentInk}"/>
    <Setter Property="Padding" Value="12,3"/>
    <Setter Property="Margin" Value="0,0,6,0"/>
  </Style>
  <Style x:Key="Danger" TargetType="Button">
    <Setter Property="Foreground" Value="{DynamicResource Danger}"/>
    <Setter Property="Padding" Value="12,3"/>
    <Setter Property="Margin" Value="0,0,6,0"/>
  </Style>
  <Style x:Key="DangerFilled" TargetType="Button">
    <Setter Property="Background" Value="{DynamicResource Danger}"/>
    <Setter Property="Foreground" Value="{DynamicResource AccentInk}"/>
  </Style>
  <Style TargetType="Button">
    <Setter Property="Padding" Value="12,3"/>
    <Setter Property="Margin" Value="0,0,6,0"/>
  </Style>
  <Style x:Key="Label" TargetType="TextBlock">
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="Foreground" Value="{DynamicResource InkMuted}"/>
    <Setter Property="Margin" Value="12,0,6,0"/>
  </Style>
  <Style x:Key="Section" TargetType="TextBlock">
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
$script:State = @{
    Gateways     = @()
    GatewayList  = @()
    Members      = @{}
    Live         = $null
    GatewayRows  = @()
    GatewayState = @{}
    PublicKeys   = @{}
    ConnRows     = @()
    Excluded     = [System.Collections.Generic.HashSet[string]]::new()
    Populating   = $false
    LastRefresh  = $null
}
# Shared with the bulk worker: it writes Total and Done, the window sets Cancel.
$script:Progress = [hashtable]::Synchronized(@{ Active = $false; Name = ''; Total = 0; Done = 0; Cancel = $false })

$script:CreateColumns = @('Gateway', 'Name', 'Type', 'Server', 'Database', 'Path', 'Url', 'ConnectionString',
                          'ConnectionDetailsJson', 'CredentialType', 'Username', 'Privacy', 'Encryption', 'Result')

$script:LogEntries = [System.Collections.Generic.List[object]]::new()

function Test-GLLogVisible($Entry) {
    $lvl = [string]$script:UI.CmbLogLevel.SelectedItem
    if ($lvl -eq 'Warnings and errors' -and $Entry.Level -eq 'Info') { return $false }
    if ($lvl -eq 'Errors only' -and $Entry.Level -ne 'Error') { return $false }
    $f = [string]$script:UI.TxtLogFind.Text
    if ($f.Trim() -and $Entry.Line.IndexOf($f.Trim(), [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    return $true
}

function Update-GLLogView {
    $shown = @($script:LogEntries | Where-Object { Test-GLLogVisible $_ } | ForEach-Object Line)
    $script:UI.TxtLog.Text = if ($shown.Count) { ($shown -join [Environment]::NewLine) + [Environment]::NewLine } else { '' }
    $script:UI.TxtLog.ScrollToEnd()
}

function Write-GLLog {
    # The panel, and - once signed in - the daily log file. -FileOnly keeps detail
    # (every item of a bulk run) in the file without flooding the panel.
    param([string]$Text, [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info', [switch]$FileOnly)
    if ($script:LogReady) {
        $path = Get-GLLogPath -Folder $script:LogFolder -User $script:SignedInAs
        $null = Write-GLLogFile -Path $path -Level (@{ Info = 'INFO'; Warn = 'WARN'; Error = 'ERROR' }[$Level]) -Text $Text
    }
    if ($FileOnly) { return }
    $tag  = @{ Info = ''; Warn = 'WARN   '; Error = 'ERROR  ' }[$Level]
    $line = '{0:HH:mm:ss}  {1}{2}' -f (Get-Date), $tag, $Text
    if ($script:UI.TxtLog) {
        $entry = [pscustomobject]@{ Level = $Level; Line = $line }
        $script:LogEntries.Add($entry)
        if ($script:LogEntries.Count -gt 5000) { $script:LogEntries.RemoveRange(0, 1000); Update-GLLogView; return }
        if (Test-GLLogVisible $entry) {
            $script:UI.TxtLog.AppendText($line + [Environment]::NewLine)
            $script:UI.TxtLog.ScrollToEnd()
        }
    }
    else { Write-Host $line }
}

function Open-GLFolder([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -ItemType Directory -Path $Path -Force }
    Start-Process explorer.exe -ArgumentList "`"$Path`""
}

# ---- appearance ------------------------------------------------------------------
$script:HistoryFields = @('TxtGwFilter', 'TxtCnSearch', 'TxtCnUser', 'TxtCnAccount', 'TxtBulkPrincipals', 'TxtCredUser', 'TxtLogFind', 'TxtActFind')

function New-GLBrush([string]$Hex) {
    $c = ConvertTo-GLColorValue $Hex
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($c[0], $c[1], $c[2], $c[3]))
    $b.Freeze()
    return $b
}

function Set-GLTheme {
    # Every named brush on the given window (or windows) gets the theme's colour.
    param([Parameter(Mandatory)]$Target, [string]$Name)
    if (-not $script:Themes.Contains($Name)) { $Name = 'Light' }
    $t = $script:Themes[$Name]
    foreach ($w in @($Target)) {
        foreach ($k in $t.Keys) { $w.Resources[$k] = New-GLBrush $t[$k] }
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
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.StreamSource = New-Object System.IO.MemoryStream (, $bytes)
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()
        $bmp.Freeze()
        $script:IconImage = $bmp
    } catch { $script:IconImage = $null }
    return $script:IconImage
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

function Set-GLFontSize([int]$Size) {
    $Size = [Math]::Max(9, [Math]::Min(20, $Size))
    $script:Settings.FontSize = $Size
    $script:Window.FontSize   = $Size
    $script:UI.TxtFontSize.Text = "$Size"
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

function Initialize-GLHistory {
    foreach ($f in $script:HistoryFields) {
        $box = $script:UI[$f]
        if (-not $box) { continue }
        $box.ItemsSource = Get-GLHistory -Settings $script:Settings -Field $f
        $name = $f
        # remembered when the box is left or Enter is pressed - not on every keystroke
        $box.Add_LostKeyboardFocus({ param($s, $e) if (-not $s.IsKeyboardFocusWithin) { Save-GLFieldHistory $name } }.GetNewClosure())
        $box.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Save-GLFieldHistory $name } }.GetNewClosure())
    }
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

    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
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
        [switch]$Quiet
    )
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
        $Arguments['Progress']  = $script:Progress
    }
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript($Work.ToString())
    foreach ($k in $Arguments.Keys) { [void]$ps.AddParameter($k, $Arguments[$k]) }
    $script:Jobs.Add([pscustomobject]@{
        Name = $Name; PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone
        Context = $Context; Started = Get-Date; Bulk = [bool]$Bulk
    })
    if (-not $Quiet) { Write-GLLog "$Name..." }
    Update-GLBusy
}

function Receive-GLJobs {
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
        if ($job.Bulk) {
            $cancelled = [bool]$script:Progress.Cancel
            $script:Progress.Active = $false
        }
        $secs = [math]::Round(((Get-Date) - $job.Started).TotalSeconds, 1)
        if ($err) { Write-GLLog "$($job.Name) failed after ${secs}s: $err" 'Error' }
        elseif ($cancelled) { Write-GLLog "$($job.Name) was cancelled after ${secs}s - the items already done stay done." 'Warn' }
        if ($job.OnDone) {
            try { & $job.OnDone $result $err $job.Context }
            catch { Write-GLLog "$($job.Name): $($_.Exception.Message)" 'Error' }
        }
    }
    Update-GLBusy
}

function Update-GLBusy {
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
        $script:UI.Busy.Visibility      = 'Visible'
        $script:UI.Busy.IsIndeterminate = $true
        $script:UI.BtnCancel.Visibility = 'Collapsed'
        $script:UI.TxtStatus.Text       = 'Working: ' + (($script:Jobs | ForEach-Object Name) -join ', ')
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
    param([string]$What, $Results)
    $all = @($Results)
    $bad = @($all | Where-Object { -not $_.Ok })
    $ok  = $all.Count - $bad.Count
    Write-GLLog "${What}: $ok done, $($bad.Count) not done." $(if ($bad.Count) { 'Warn' } else { 'Info' })
    foreach ($b in ($bad | Select-Object -First 60)) { Write-GLLog "    $($b.Name): $($b.Message)" 'Error' }
    if ($bad.Count -gt 60) { Write-GLLog "    ... and $($bad.Count - 60) more." 'Error' }
    foreach ($g in ($all | Where-Object Ok)) { Write-GLLog "    $($g.Name): $($g.Message)" -FileOnly }
    if ($script:UI.Tabs -and $script:UI.Tabs.SelectedItem -eq $script:UI.TabActivity) { Invoke-GLActivityRefresh }
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
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
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

# ---- gateways ------------------------------------------------------------------
function Show-GLGateways {
    $selId = if ($script:UI.GridGateways.SelectedItem) { $script:UI.GridGateways.SelectedItem.Id } else { $null }
    $rows = $script:State.GatewayRows
    if (-not $script:UI.ChkVnet.IsChecked) { $rows = @($rows | Where-Object { $_.Type -ne 'VirtualNetwork' }) }
    $rows = Select-GLByText -Rows $rows -Text $script:UI.TxtGwFilter.Text
    $script:UI.GridGateways.ItemsSource = $rows
    if ($selId) {
        $again = $rows | Where-Object { $_.Id -eq $selId } | Select-Object -First 1
        if ($again) { $script:UI.GridGateways.SelectedItem = $again }
    }
    Update-GLGatewaySummary
}

function Update-GLGatewaySummary {
    $parts = @()
    if ($script:State.LastRefresh) { $parts += 'Refreshed {0:HH:mm:ss}' -f $script:State.LastRefresh }
    if ($script:State.Live) {
        $vals = @($script:State.Live.Values)
        $up   = @($vals | Where-Object { $_.Status -eq 'Live' }).Count
        $parts += "$up of $($vals.Count) members online"
        $slow = @($vals | Where-Object { $_.Status -eq 'Timeout' }).Count
        if ($slow) { $parts += "$slow did not answer" }
    }
    $parts += "$(@($script:UI.GridGateways.ItemsSource).Count) gateway(s) shown"
    $script:UI.TxtGwSummary.Text = $parts -join '   |   '
}

function Update-GLCreateGateways {
    $names = @($script:State.GatewayList | Where-Object { $_.type -eq 'OnPremises' } | ForEach-Object { [string]$_.displayName } | Sort-Object -Unique)
    $keep = [string]$script:UI.CmbCreateGateway.SelectedItem
    $script:UI.CmbCreateGateway.ItemsSource = @('(none)') + $names
    $script:UI.CmbCreateGateway.SelectedItem = if ($keep -and $names -contains $keep) { $keep } else { '(none)' }
}

function Set-GLGatewayList {
    # Gateway objects arrive from both refreshes; keys and names come from them.
    param($Gateways)
    if (-not $Gateways) { return }
    $script:State.GatewayList = $Gateways
    foreach ($g in $Gateways) {
        if ($g.publicKey) { $script:State.PublicKeys[([string]$g.id).ToLowerInvariant()] = $g.publicKey }
    }
    Update-GLCreateGateways
}

function Invoke-GLGatewayRefresh {
    if (Test-GLJobRunning 'Loading gateways') { return }
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $live = [bool]$script:UI.ChkLive.IsChecked
    $pbi  = if ($live) { Get-GLTokenSafe PowerBI } else { $null }

    Start-GLJob -Name 'Loading gateways' -Arguments @{ F = $fab; P = $pbi; L = $live } -Work {
        param($F, $P, $L)
        Get-GLGatewayData -FabricToken $F -PbiToken $P -LiveStatus:$L
    } -OnDone {
        param($r, $err, $ctx)
        if ($err -or -not $r) { return }
        foreach ($l in $r.Log) { Write-GLLog $l 'Warn' }
        $script:State.Gateways    = $r.Gateways
        $script:State.Members     = $r.Members
        $script:State.Live        = $r.Live
        $script:State.GatewayRows = ConvertTo-GLGatewayRows -Gateways $r.Gateways -Members $r.Members -Live $r.Live
        $script:State.GatewayState = @{}
        foreach ($row in $script:State.GatewayRows) {
            $script:State.GatewayState[([string]$row.Id).ToLowerInvariant()] = Get-GLGatewayState $row.Online
        }
        $script:State.LastRefresh = Get-Date
        Set-GLGatewayList $r.Gateways
        Show-GLGateways
        Update-GLGatewayDetail
        if ($script:State.ConnRows.Count) { Show-GLConnections }   # connections take the new states
        $members = ($r.Members.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
        Write-GLLog "Loaded $($r.Gateways.Count) gateway(s) with $([int]$members) member(s). $($script:UI.TxtGwSummary.Text)"
    }
}

function Update-GLGatewayDetail {
    $row = $script:UI.GridGateways.SelectedItem
    if (-not $row) {
        $script:UI.GridMembers.ItemsSource  = $null
        $script:UI.GridGwAccess.ItemsSource = $null
        $script:UI.TxtMembersTitle.Text     = 'Members'
        $script:State.AccessFor             = $null
        return
    }
    $mem = @()
    if ($script:State.Members.ContainsKey($row.Id)) { $mem = $script:State.Members[$row.Id] }
    $script:UI.GridMembers.ItemsSource = ConvertTo-GLMemberRows -GatewayName $row.Name -Members $mem -Live $script:State.Live
    $script:UI.TxtMembersTitle.Text    = "Members of $($row.Name)"
    if ($script:State.AccessFor -ne $row.Id) {
        $script:State.AccessFor = $row.Id
        $script:UI.GridGwAccess.ItemsSource = $null
        Update-GLAccess -Kind gateways -Id $row.Id -Name $row.Name
    }
}

function Set-GLAutoRefresh {
    if (-not $script:AutoTimer) {
        $script:AutoTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:AutoTimer.Add_Tick({ if (-not $script:Progress.Active) { Invoke-GLGatewayRefresh } })
    }
    $script:AutoTimer.Stop()
    $choice = [string]$script:UI.CmbAutoRefresh.SelectedItem
    if ($choice -match '^(\d+) min') {
        $script:AutoTimer.Interval = [TimeSpan]::FromMinutes([int]$Matches[1])
        $script:AutoTimer.Start()
        Write-GLLog "Gateways refresh automatically every $($Matches[1]) minute(s)."
    }
}

function Invoke-GLMemberEnabled {
    param([bool]$Enabled)
    $gw = $script:UI.GridGateways.SelectedItem
    $m  = $script:UI.GridMembers.SelectedItem
    if (-not $gw -or -not $m) { Write-GLLog 'Select a gateway and one of its members first.' 'Warn'; return }
    if ([bool]$m.Enabled -eq $Enabled) { Write-GLLog "'$($m.Member)' is already $(if ($Enabled) { 'enabled' } else { 'disabled' })." 'Warn'; return }

    $verb  = if ($Enabled) { 'Enable' } else { 'Disable' }
    $extra = ''
    if (-not $Enabled) {
        $on = @($script:State.Members[$gw.Id] | Where-Object { $_.enabled }).Count
        $extra = if ($on -le 1) { "`n`nThis is the LAST enabled member - the gateway will stop serving refreshes entirely." }
                 else { "`n`nRefreshes will be served by the other $($on - 1) enabled member(s)." }
    }
    $where = if ($m.Machine) { " ($($m.Machine))" } else { '' }
    if (-not (Confirm-GL "$verb member '$($m.Member)'$where of gateway '$($gw.Name)'?$extra" "$verb member")) { return }

    $audit = Get-GLRunAudit
    if (-not $audit) { return }
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $rec = @{ Action = "$verb member"; TargetType = 'Gateway member'; Target = [string]$m.Member; TargetId = [string]$m.Id
              Gateway = [string]$gw.Name; GatewayId = [string]$gw.Id; Details = "Machine=$($m.Machine)" }
    Start-GLJob -Name "$verb '$($m.Member)'" -Arguments @{ F = $fab; G = $gw.Id; M = $m.Id; E = $Enabled; A = $audit; Rec = $rec } `
        -Context @{ What = "$($verb)d '$($m.Member)' of '$($gw.Name)'." } -Work {
        param($F, $G, $M, $E, $A, $Rec)
        try { Set-GLMemberEnabled -GatewayId $G -MemberId $M -Enabled $E -FabricToken $F }
        catch { Write-GLChange -Audit $A @Rec -Result Failed -Message $_.Exception.Message; throw }
        Write-GLChange -Audit $A @Rec -Result Done
        $true
    } -OnDone {
        param($r, $err, $ctx)
        if ($err) { return }
        Write-GLLog $ctx.What
        Invoke-GLGatewayRefresh
    }
}

function Get-GLClusterBlocks {
    # Gateway name plus its member rows, for every gateway on screen (or the selected one).
    param([switch]$SelectedOnly)
    $gws = if ($SelectedOnly) { @($script:UI.GridGateways.SelectedItem | Where-Object { $_ }) } else { @($script:UI.GridGateways.ItemsSource) }
    foreach ($g in $gws) {
        $mem = @()
        if ($script:State.Members.ContainsKey($g.Id)) { $mem = $script:State.Members[$g.Id] }
        [pscustomobject]@{ Name = $g.Name; Type = $g.Type; Rows = (ConvertTo-GLMemberRows -GatewayName $g.Name -Members $mem -Live $script:State.Live) }
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
    Start-GLJob -Name 'Resolving IP addresses' -Arguments @{ B = $blocks; S = $script:DnsSuffixes } -Work {
        param($B, $S)
        foreach ($b in $B) {
            [pscustomobject]@{ Name = $b.Name; Lines = @($b.Machines | ForEach-Object { Resolve-GLHostAddress -Machine $_ -Suffixes $S }) }
        }
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
    if ($script:State.Populating) { return }
    Set-GLRowGatewayState -Rows $script:State.ConnRows -GatewayState $script:State.GatewayState
    $rows = Select-GLConnections -Rows $script:State.ConnRows -Text $script:UI.TxtCnSearch.Text `
        -Gateway ([string]$script:UI.CmbCnGateway.SelectedItem) `
        -Connectivity ([string]$script:UI.CmbCnConnectivity.SelectedItem) `
        -Type ([string]$script:UI.CmbCnType.SelectedItem) `
        -User $script:UI.TxtCnUser.Text -Account $script:UI.TxtCnAccount.Text `
        -States (Get-GLStateFilter) -Excluded $script:State.Excluded
    $script:UI.GridConnections.ItemsSource = $rows
    $all = $script:State.ConnRows.Count
    $ex  = $script:State.Excluded.Count
    $txt = if ($rows.Count -eq $all) { "$all connection(s)" } else { "$($rows.Count) of $all connection(s)" }
    if ($ex) { $txt += "   ($ex excluded)" }
    $script:UI.TxtCnCount.Text   = $txt
    $script:UI.TxtBulkTitle.Text = "All $($rows.Count) listed connection(s)"
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
    Start-GLJob -Name 'Loading connections' -Arguments @{ F = $fab; P = $pbi; D = $dir } -Work {
        param($F, $P, $D)
        $data = Get-GLConnectionData -FabricToken $F
        $directory = $null; $warn = $null
        if ($D -and $P) {
            try { $directory = Get-GLDatasourceDirectory -PbiToken $P }
            catch { $warn = "Usernames and access are unavailable (unofficial API): $($_.Exception.Message)" }
        }
        @{ Gateways = $data.Gateways; Connections = $data.Connections; Directory = $directory; Warn = $warn }
    } -OnDone {
        param($r, $err, $ctx)
        if ($err -or -not $r) { return }
        if ($r.Warn) { Write-GLLog $r.Warn 'Warn' }
        Set-GLGatewayList $r.Gateways
        $names = Get-GLGatewayNameMap -Gateways $r.Gateways
        $rows  = ConvertTo-GLConnectionRows -Connections $r.Connections -GatewayNames $names
        Add-GLDirectoryInfo -Rows $rows -Directory $r.Directory
        $script:State.ConnRows = $rows
        $script:State.RawConnections = @{}
        foreach ($c in $r.Connections) { $script:State.RawConnections[[string]$c.id] = $c }
        $script:State.Excluded.Clear()

        $script:State.Populating = $true
        try {
            Set-GLComboValues $script:UI.CmbCnGateway      (Get-GLDistinct -Rows $rows -Property Gateway)
            Set-GLComboValues $script:UI.CmbCnConnectivity (Get-GLDistinct -Rows $rows -Property Connectivity)
            Set-GLComboValues $script:UI.CmbCnType         (Get-GLDistinct -Rows $rows -Property Type)
        }
        finally { $script:State.Populating = $false }
        Show-GLConnections
        $note = ''
        if ($r.Directory) {
            $acc = @($rows | Where-Object { $_.Account }).Count
            $note = "; usernames for $acc, users for $(@($rows | Where-Object { $_.Users -ne '' }).Count)"
        }
        Write-GLLog "Loaded $($r.Connections.Count) connection(s)$note."
    }
}

function Update-GLConnectionDetail {
    $row = $script:UI.GridConnections.SelectedItem
    $script:UI.GridCnAccess.ItemsSource = $null
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
    $listed = Get-GLListed      # assign first - piping it would pass the whole list as ONE item
    $items  = @($listed | Where-Object { $_.Connectivity -eq 'OnPremisesGateway' -and $_.GatewayId })
    if ($items.Count -eq 0) { Write-GLLog 'No on-premises gateway connections in the list to test.' 'Warn'; return }
    if ($items.Count -gt 200 -and -not (Confirm-GL "Test $($items.Count) connections?`n`nEach test makes the gateway contact the data source, so this takes a while and puts load on the gateways. It can be cancelled.")) { return }
    $pbi = Get-GLTokenSafe PowerBI
    if (-not $pbi) { return }
    Start-GLJob -Bulk -Name "Testing $($items.Count) connection(s)" -Arguments @{ P = $pbi; I = $items } -Work {
        param($P, $I, $Progress)
        $Progress.Total = $I.Count
        $all = @{}
        for ($i = 0; $i -lt $I.Count; $i += 20) {
            if ($Progress.Cancel) { break }
            $chunk = @($I[$i..([Math]::Min($i + 20, $I.Count) - 1)])
            $res = Test-GLConnectionsBulk -Items $chunk -PbiToken $P
            foreach ($k in $res.Keys) { $all[$k] = $res[$k] }
            $Progress.Done = [Math]::Min($i + 20, $I.Count)
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
        Write-GLLog "Status: $ok OK, $($vals.Count - $ok - $to) failed, $to did not answer. See the Status and StatusDetail columns."
    }
}

function Invoke-GLBulkUsersUi {
    $items = Get-GLListed
    if ($items.Count -eq 0) { Write-GLLog 'The list is empty.' 'Warn'; return }
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    $ids = @($items | ForEach-Object { [string]$_.Id })
    Start-GLJob -Bulk -Name "Reading users of $($ids.Count) connection(s)" -Arguments @{ F = $fab; I = $ids } -Work {
        param($F, $I, $Progress)
        $Progress.Total = $I.Count
        $all = @{}
        for ($i = 0; $i -lt $I.Count; $i += 25) {
            if ($Progress.Cancel) { break }
            $chunk = @($I[$i..([Math]::Min($i + 25, $I.Count) - 1)])
            $res = Get-GLRoleAssignmentsBulk -Ids $chunk -FabricToken $F
            foreach ($k in $res.Keys) { $all[$k] = $res[$k] }
            $Progress.Done = [Math]::Min($i + 25, $I.Count)
        }
        $all
    } -OnDone {
        param($r, $err, $ctx)
        if ($err -or -not $r) { return }
        Set-GLRowUsers -Rows $script:State.ConnRows -Assignments $r
        $script:UI.GridConnections.Items.Refresh()
        $bad = @($r.Values | Where-Object { $null -eq $_ }).Count
        Write-GLLog "Users read for $($r.Count - $bad) connection(s)$(if ($bad) { ", $bad could not be read" }). The User filter now works on them."
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
        -Context @{ What = $(if ($Revoke) { 'Remove access' } else { 'Grant access' }) } -Work {
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
        Write-GLLog 'Press Verify users to see the result in the list.'
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
        -Arguments @{ P = $pbi; I = $items; T = $type; U = $user; S = $secret; E = $encChoice; K = $keys; A = $audit } -Work {
        param($P, $I, $T, $U, $S, $E, $K, $A, $Progress)
        Invoke-GLBulkCredentials -Items $I -CredentialType $T -Username $U -Password $S -EncryptionChoice $E -PublicKeys $K -PbiToken $P -Progress $Progress -Audit $A
    } -OnDone {
        param($r, $err, $ctx)
        if ($err) { return }
        Write-GLResults 'Update credentials' $r
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

    Start-GLJob -Bulk -Name "Deleting $n connection(s)" -Arguments @{ F = $fab; I = $items; R = $raw; B = $path; A = $audit } -Context @{ Backup = $path } -Work {
        param($F, $I, $R, $B, $A, $Progress)
        # 1) who has access, so the backup can restore that too
        $Progress.Name = "Backing up $($I.Count) connection(s)"
        $assign = Get-GLRoleAssignmentsBulk -Ids @($I | ForEach-Object { [string]$_.Id }) -FabricToken $F
        # 2) the backup - if this throws, the job stops here and nothing is deleted
        $null = Backup-GLConnections -Items $I -Raw $R -Assignments $assign -Path $B
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
function Get-GLAccessGrid([string]$Kind) {
    if ($Kind -eq 'gateways') { return $script:UI.GridGwAccess }
    return $script:UI.GridCnAccess
}

function Get-GLSelectedId([string]$Kind) {
    $grid = if ($Kind -eq 'gateways') { $script:UI.GridGateways } else { $script:UI.GridConnections }
    if ($grid.SelectedItem) { return [string]$grid.SelectedItem.Id }
    return $null
}

function Update-GLAccess {
    param([string]$Kind, [string]$Id, [string]$Name)
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    Start-GLJob -Name "Access for '$Name'" -Arguments @{ F = $fab; K = $Kind; I = $Id } -Context @{ Kind = $Kind; Id = $Id } -Work {
        param($F, $K, $I)
        Get-GLRoleAssignments -Kind $K -Id $I -FabricToken $F
    } -OnDone {
        param($r, $err, $ctx)
        if ($err) { return }
        if ((Get-GLSelectedId $ctx.Kind) -ne $ctx.Id) { return }
        (Get-GLAccessGrid $ctx.Kind).ItemsSource = ConvertTo-GLRoleRows -Assignments $r
    }
}

function Show-GLAccessDialog {
    param([string]$Target, [string[]]$Roles, [string]$DefaultRole)
    [xml]$x = $script:DialogXaml
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $dlg.Owner = $script:Window
    Initialize-GLDialog -Dialog $dlg
    $c = @{}
    foreach ($n in 'DlgTarget', 'DlgPrincipal', 'DlgHint', 'DlgType', 'DlgRole', 'DlgOk') { $c[$n] = $dlg.FindName($n) }
    $c.DlgTarget.Text = $Target
    $c.DlgHint.Text   = if ($script:AuthMode -eq 'Az') {
        'A user''s email or UPN, a group''s email or name, a service principal''s name - or any object id.'
    } else { 'Paste the object id. Looking people up by name needs Az.Accounts.' }
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

function Invoke-GLAddAccess {
    param([string]$Kind)
    $grid = if ($Kind -eq 'gateways') { $script:UI.GridGateways } else { $script:UI.GridConnections }
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
        if ((Get-GLSelectedId $ctx.Kind) -eq $ctx.Id) { Update-GLAccess -Kind $ctx.Kind -Id $ctx.Id -Name $ctx.Name }
    }
}

function Invoke-GLRemoveAccess {
    param([string]$Kind)
    $grid = if ($Kind -eq 'gateways') { $script:UI.GridGateways } else { $script:UI.GridConnections }
    $row  = $grid.SelectedItem
    $a    = (Get-GLAccessGrid $Kind).SelectedItem
    if (-not $row -or -not $a) { Write-GLLog 'Select the access entry to remove first.' 'Warn'; return }
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
        if ((Get-GLSelectedId $ctx.Kind) -eq $ctx.Id) { Update-GLAccess -Kind $ctx.Kind -Id $ctx.Id -Name $ctx.Name }
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
        Write-GLLog "'$($ctx.Name)': $($r.Message)" $(if ($r.Ok) { 'Info' } else { 'Error' })
    }
}

# ---- create ----------------------------------------------------------------------
function Initialize-GLCreateTable {
    $t = New-Object System.Data.DataTable 'Create'
    foreach ($c in $script:CreateColumns) { [void]$t.Columns.Add($c, [string]) }
    $script:CreateTable = $t
    $script:UI.GridCreate.ItemsSource = $t.DefaultView
}

function Add-GLCreateRow {
    param([hashtable]$Values = @{})
    $r = $script:CreateTable.NewRow()
    $r['CredentialType'] = 'Windows'
    $r['Privacy']        = 'Organizational'
    $r['Encryption']     = 'Encrypted'
    foreach ($k in $Values.Keys) { if ($script:CreateTable.Columns.Contains($k)) { $r[$k] = [string]$Values[$k] } }
    $script:CreateTable.Rows.Add($r)
}

function Remove-GLCreateRows {
    $rows = @($script:UI.GridCreate.SelectedItems | Where-Object { $_ -is [System.Data.DataRowView] } | ForEach-Object { $_.Row })
    foreach ($r in $rows) { $script:CreateTable.Rows.Remove($r) }
}

function Import-GLCreateCsv {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'CSV files (*.csv)|*.csv'
    if (-not $dlg.ShowDialog($script:Window)) { return }
    $recs = @(Import-Csv -Path $dlg.FileName)
    if ($recs.Count -eq 0) { Write-GLLog 'The file has no rows.' 'Warn'; return }
    $cols = @($recs[0].PSObject.Properties.Name)
    if ($cols | Where-Object { $_ -match 'pass|secret|key$' -and $_ -ne 'ConnectionDetailsJson' }) {
        Write-GLLog 'A password-like column in the file was ignored - passwords are only ever taken from the password box.' 'Warn'
    }
    $unknown = @($cols | Where-Object { $script:CreateColumns -notcontains $_ })
    foreach ($rec in $recs) {
        $v = @{}
        foreach ($c in $script:CreateColumns) {
            if ($c -eq 'Result') { continue }
            $p = $rec.PSObject.Properties | Where-Object { $_.Name -eq $c } | Select-Object -First 1
            if ($p -and $null -ne $p.Value) { $v[$c] = [string]$p.Value }
        }
        Add-GLCreateRow -Values $v
    }
    Write-GLLog "Loaded $($recs.Count) row(s) from $($dlg.FileName)$(if ($unknown) { "; columns not used: $($unknown -join ', ')" })."
}

function Save-GLCreateTemplate {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.FileName = 'gatewaylens-create-template.csv'
    $dlg.Filter   = 'CSV files (*.csv)|*.csv'
    if (-not $dlg.ShowDialog($script:Window)) { return }
    $example = [ordered]@{
        Gateway = 'My Gateway Cluster'; Name = 'Sales database'; Type = 'Sql'; Server = 'sql01.contoso.com'; Database = 'Sales'
        Path = ''; Url = ''; ConnectionString = ''; ConnectionDetailsJson = ''; CredentialType = 'Windows'
        Username = 'CONTOSO\svc_reader'; Privacy = 'Organizational'; Encryption = 'Encrypted'
    }
    [pscustomobject]$example | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding utf8BOM
    Write-GLLog "Template saved to $($dlg.FileName). Fill it in, then Load CSV. Passwords never go in the file."
}

function Add-GLRowsFromStrings {
    $lines = @($script:UI.TxtCreateStrings.Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -eq 0) { Write-GLLog 'Paste one or more connection strings first.' 'Warn'; return }
    foreach ($l in $lines) {
        $p = ConvertFrom-GLConnectionString $l
        if ($p.Server) {
            Add-GLCreateRow -Values @{ Name = "$($p.Server) $($p.Database)".Trim(); Type = $p.Type; Server = $p.Server; Database = $p.Database }
        }
        else {
            Add-GLCreateRow -Values @{ Name = ''; Type = 'Odbc'; ConnectionString = $l }
        }
    }
    Write-GLLog "Added $($lines.Count) row(s). Check the Name and Type columns before creating."
}

function Invoke-GLCreateUi {
    $script:UI.GridCreate.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true) | Out-Null
    $refs = @($script:CreateTable.Rows | Where-Object { $_.RowState -ne 'Deleted' })
    if ($refs.Count -eq 0) { Write-GLLog 'Add some rows first.' 'Warn'; return }
    $rows = foreach ($r in $refs) {
        $o = [ordered]@{}
        foreach ($c in $script:CreateColumns) { $o[$c] = [string]$r[$c] }
        [pscustomobject]$o
    }
    $secret = $script:UI.PwdCreate.Password
    $needs  = @($rows | Where-Object { $_.CredentialType -in '', 'Windows', 'Basic', 'Key' }).Count
    if ($needs -and -not $secret) { Write-GLLog "$needs row(s) need a password - enter it in 'Password for this run'." 'Warn'; return }
    if (@($script:State.GatewayList).Count -eq 0) { Write-GLLog 'Gateways are not loaded yet - refresh first.' 'Warn'; return }
    $default = [string]$script:UI.CmbCreateGateway.SelectedItem
    if ($default -eq '(none)') { $default = '' }
    if (-not (Confirm-GL "Create $($rows.Count) connection(s)?" 'Create connections')) { return }

    $audit = Get-GLRunAudit
    if (-not $audit) { return }
    $pbi = Get-GLTokenSafe PowerBI
    if (-not $pbi) { return }
    Start-GLJob -Bulk -Name "Creating $($rows.Count) connection(s)" `
        -Arguments @{ P = $pbi; R = @($rows); G = $script:State.GatewayList; D = $default; S = $secret; A = $audit } `
        -Context @{ Refs = $refs } -Work {
        param($P, $R, $G, $D, $S, $A, $Progress)
        Invoke-GLBulkCreate -Rows $R -Gateways $G -DefaultGateway $D -Password $S -PbiToken $P -Progress $Progress -Audit $A
    } -OnDone {
        param($r, $err, $ctx)
        if ($err) { return }
        $res = @($r)
        for ($i = 0; $i -lt $res.Count -and $i -lt $ctx.Refs.Count; $i++) {
            $ctx.Refs[$i]['Result'] = if ($res[$i].Ok) { "OK  $($res[$i].Id)" } else { "FAILED  $($res[$i].Message)" }
        }
        Write-GLResults 'Create' $res
        if (@($res | Where-Object Ok).Count) { Write-GLLog 'Refresh the Connections tab to see the new connections.' }
    }
    $script:UI.PwdCreate.Clear()
}

# ---- activity -------------------------------------------------------------------
function Invoke-GLActivityRefresh {
    if (Test-GLJobRunning 'Reading the change record') { return }
    Start-GLJob -Quiet -Name 'Reading the change record' -Arguments @{ D = $script:LogFolder } -Work {
        param($D)
        Read-GLChanges -Folder $D
    } -OnDone {
        param($r, $err, $ctx)
        if ($err) { return }
        $script:State.Changes = @($r | Where-Object { $_ })
        $script:State.Populating = $true
        try {
            Set-GLComboValues $script:UI.CmbActAction (Get-GLDistinct -Rows $script:State.Changes -Property Action)
            Set-GLComboValues $script:UI.CmbActUser   (Get-GLDistinct -Rows $script:State.Changes -Property User)
        }
        finally { $script:State.Populating = $false }
        Show-GLActivity
    }
}

function Show-GLActivity {
    if ($script:State.Populating) { return }
    $days = @{ 'Today' = 1; '7 days' = 7; '30 days' = 30; '90 days' = 90; 'All' = 0 }[[string]$script:UI.CmbActPeriod.SelectedItem]
    $rows = Select-GLChanges -Rows $script:State.Changes -Text $script:UI.TxtActFind.Text `
        -Action ([string]$script:UI.CmbActAction.SelectedItem) -Result ([string]$script:UI.CmbActResult.SelectedItem) `
        -User ([string]$script:UI.CmbActUser.SelectedItem) -Days $(if ($null -eq $days) { 7 } else { $days })
    $view = foreach ($r in $rows) {
        [pscustomobject][ordered]@{
            When = $(if ($r.When -gt [datetime]::MinValue) { $r.When.ToString('yyyy-MM-dd HH:mm:ss') } else { $r.Time })
            User = $r.User; Action = $r.Action; Result = $r.Result; Target = $r.Target; Gateway = $r.Gateway
            Principal = $r.Principal; Role = $r.Role; Details = $r.Details; Message = $r.Message; Run = $r.RunId
            Source = $r
        }
    }
    $script:UI.GridActivity.ItemsSource = @($view)
    $all = @($script:State.Changes).Count
    $fail = @($rows | Where-Object Result -eq 'Failed').Count
    $txt = if ($rows.Count -eq $all) { "$all change(s)" } else { "$($rows.Count) of $all change(s)" }
    if ($fail) { $txt += "   ($fail failed)" }
    $script:UI.TxtActCount.Text = $txt
}

function Invoke-GLUndoUi {
    $sel = @($script:UI.GridActivity.SelectedItems | ForEach-Object { $_.Source } | Where-Object { $_ })
    if ($sel.Count -eq 0) { Write-GLLog 'Select the changes to undo first (Ctrl or Shift for several).' 'Warn'; return }
    $mine   = @($sel | Where-Object { $_.User -eq $script:SignedInAs })
    $ok     = @($mine | Where-Object { Test-GLUndoable $_ })
    $others = $sel.Count - $mine.Count
    $cannot = $mine.Count - $ok.Count
    if ($ok.Count -eq 0) {
        Write-GLLog 'None of the selected changes can be undone. Undo works on your own completed access changes, and on member enable / disable.' 'Warn'
        return
    }
    $summary = ($ok | Group-Object Action | ForEach-Object { "    $($_.Count) x $($_.Name)" }) -join "`n"
    $msg = "Undo $($ok.Count) change(s)?`n`n$summary"
    if ($cannot) { $msg += "`n`n$cannot selected change(s) cannot be undone and are left alone." }
    if ($others) { $msg += "`n$others change(s) made by other people are left alone - undo works on your own changes." }
    $msg += "`n`nEach undo is recorded as a change of its own."
    if (-not (Confirm-GL $msg 'Undo changes')) { return }
    $audit = Get-GLRunAudit
    if (-not $audit) { return }
    $fab = Get-GLTokenSafe Fabric
    if (-not $fab) { return }
    Start-GLJob -Bulk -Name "Undoing $($ok.Count) change(s)" -Arguments @{ F = $fab; R = $ok; A = $audit } -Work {
        param($F, $R, $A, $Progress)
        Invoke-GLUndo -Rows $R -FabricToken $F -Audit $A -Progress $Progress
    } -OnDone {
        param($r, $err, $ctx)
        if ($err) { return }
        Write-GLResults 'Undo' $r
        Invoke-GLActivityRefresh
    }
}

# ---- log panel --------------------------------------------------------------------
function Copy-GLLog {
    $t = $script:UI.TxtLog.Text
    if (-not $t) { Write-GLLog 'Nothing to copy.' 'Warn'; return }
    [System.Windows.Clipboard]::SetText($t)
}

function Save-GLLog {
    $t = $script:UI.TxtLog.Text
    if (-not $t) { Write-GLLog 'Nothing to save.' 'Warn'; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.FileName = 'gatewaylens-log-{0:yyyyMMdd-HHmm}.txt' -f (Get-Date)
    $dlg.Filter   = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    if (-not $dlg.ShowDialog($script:Window)) { return }
    Set-Content -LiteralPath $dlg.FileName -Value $t -Encoding utf8
    Write-GLLog "Log saved to $($dlg.FileName)"
}

# ---- small helpers ----------------------------------------------------------------
function Export-GLGrid {
    param($Grid, [string]$Suggested)
    $rows = @($Grid.ItemsSource | Where-Object { $_ })
    if ($rows.Count -eq 0) { Write-GLLog 'Nothing to export.' 'Warn'; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.FileName = '{0}-{1:yyyyMMdd-HHmm}.csv' -f $Suggested, (Get-Date)
    $dlg.Filter   = 'CSV files (*.csv)|*.csv'
    if (-not $dlg.ShowDialog($script:Window)) { return }
    $hasUsers = $rows[0].PSObject.Properties.Name -contains 'UserList'
    $rows | ForEach-Object {
        $o = $_ | Select-Object -Property * -ExcludeProperty UserList, Source
        if ($hasUsers) { $o | Add-Member -NotePropertyName UserNames -NotePropertyValue (@($_.UserList) -join '; ') -Force }
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
    $script:Settings = Read-GLSettings
    # from here on, everything logged also goes to today's log file
    $script:LogReady = $true
    $pruned = Remove-GLOldLogs -Folder $script:LogFolder -User $script:SignedInAs -Days 30
    Write-GLLog ('=' * 70) -FileOnly
    Write-GLLog "$($script:AppName) $($script:AppVersion) started - $($script:SignedInAs) via $($script:AuthMode), tenant $($script:TenantShown)" -FileOnly
    if ($pruned) { Write-GLLog "Removed $pruned log file(s) older than 30 days." -FileOnly }

    [xml]$x = $script:MainXaml
    $script:Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
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

    $script:Window.Title        = "$($script:AppName) $($script:AppVersion)"
    if ($script:AuthMode -eq 'Demo') {
        $script:Window.Title += '  -  DEMO (fictional data)'
        Initialize-GLDemoHistory -Folder $script:LogFolder
    }
    $script:UI.TxtApp.Text      = $script:AppName
    $script:UI.TxtVersion.Text  = "v$($script:AppVersion)"
    $script:UI.TxtIdentity.Text = "$($script:SignedInAs)   |   tenant $($script:TenantShown)   |   $($script:AuthMode)"

    foreach ($g in 'GridGateways', 'GridMembers', 'GridGwAccess', 'GridConnections', 'GridCnAccess', 'GridActivity') {
        $script:UI[$g].Add_AutoGeneratingColumn({
            param($s, $e)
            if ($e.PropertyName -in 'GatewayId', 'PrincipalId', 'UserList', 'Source') { $e.Cancel = $true }
        })
    }

    # colour on what needs attention - by brush name, so it follows the theme
    $script:UI.GridGateways.Add_LoadingRow({
        param($s, $e)
        $st = Get-GLGatewayState $e.Row.Item.Online
        Set-GLRowColor $e.Row $(if ($st -eq 'Offline') { 'Danger' } elseif ($st -eq 'Partial') { 'Warn' } else { '' })
    })
    $script:UI.GridMembers.Add_LoadingRow({
        param($s, $e)
        $st = [string]$e.Row.Item.Status
        Set-GLRowColor $e.Row $(if ($st -eq 'Timeout') { 'Warn' } elseif ($st -and $st -notin 'Live', 'n/a') { 'Danger' } else { '' })
    })
    $script:UI.GridConnections.Add_LoadingRow({
        param($s, $e)
        $i = $e.Row.Item
        Set-GLRowColor $e.Row $(if ($i.Status -eq 'Failed' -or $i.GatewayState -eq 'Offline') { 'Danger' }
                                 elseif ($i.Status -eq 'Timeout' -or $i.GatewayState -eq 'Partial') { 'Warn' } else { '' })
    })
    $script:UI.GridActivity.Add_LoadingRow({
        param($s, $e)
        $r = [string]$e.Row.Item.Result
        Set-GLRowColor $e.Row $(if ($r -eq 'Failed') { 'Danger' } elseif ($r -in 'NoChange', 'Skipped') { 'InkMuted' } else { '' })
    })

    # dropdown contents
    $script:UI.CmbAutoRefresh.ItemsSource       = @('Off', '1 min', '5 min', '10 min', '15 min', '30 min')
    $script:UI.CmbAutoRefresh.SelectedIndex     = 0
    $script:UI.CmbBulkPrincipalType.ItemsSource = $script:PrincipalTypes
    $script:UI.CmbBulkPrincipalType.SelectedItem = 'User'
    $script:UI.CmbBulkRole.ItemsSource          = $script:ConnectionRoles
    $script:UI.CmbBulkRole.SelectedItem         = 'User'
    $script:UI.CmbCredType.ItemsSource          = @('Windows', 'Basic', 'Anonymous', 'Key')
    $script:UI.CmbCredType.SelectedItem         = 'Windows'
    $script:UI.CmbCredEncryption.ItemsSource    = @('Keep current', 'Encrypted', 'Not encrypted')
    $script:UI.CmbCredEncryption.SelectedIndex  = 0
    $script:UI.CmbLogLevel.ItemsSource          = @('All', 'Warnings and errors', 'Errors only')
    $script:UI.CmbLogLevel.SelectedIndex        = 0
    $script:UI.CmbActPeriod.ItemsSource         = @('Today', '7 days', '30 days', '90 days', 'All')
    $script:UI.CmbActPeriod.SelectedItem        = '30 days'
    $script:UI.CmbActResult.ItemsSource         = @('(all)', 'Done', 'Failed', 'NoChange', 'Skipped')
    $script:UI.CmbActResult.SelectedIndex       = 0
    $script:UI.CmbActAction.ItemsSource         = @('(all)')
    $script:UI.CmbActAction.SelectedIndex       = 0
    $script:UI.CmbActUser.ItemsSource           = @('(all)')
    $script:UI.CmbActUser.SelectedIndex         = 0
    $script:UI.CmbCreateGateway.ItemsSource     = @('(none)')
    $script:UI.CmbCreateGateway.SelectedIndex   = 0
    Initialize-GLCreateTable

    # appearance
    $script:UI.CmbTheme.Add_SelectionChanged({
        $script:Settings.Theme = Set-GLTheme -Target $script:Window -Name ([string]$script:UI.CmbTheme.SelectedItem)
        $null = Save-GLSettings -Settings $script:Settings
    })
    $script:UI.BtnFontDown.Add_Click({ Set-GLFontSize ($script:Settings.FontSize - 1); $null = Save-GLSettings -Settings $script:Settings })
    $script:UI.BtnFontUp.Add_Click({ Set-GLFontSize ($script:Settings.FontSize + 1); $null = Save-GLSettings -Settings $script:Settings })
    $script:UI.BtnClearHistory.Add_Click({
        if (-not (Confirm-GL 'Forget everything typed into the search and name boxes?' 'Clear history')) { return }
        $script:Settings.History = [ordered]@{}
        foreach ($f in $script:HistoryFields) { $script:UI[$f].ItemsSource = @() }
        $null = Save-GLSettings -Settings $script:Settings
        Write-GLLog 'History cleared.'
    })

    # gateways
    $script:UI.BtnGwRefresh.Add_Click({ Invoke-GLGatewayRefresh })
    $script:UI.ChkVnet.Add_Click({ Show-GLGateways })
    $script:UI.CmbAutoRefresh.Add_SelectionChanged({ Set-GLAutoRefresh })
    Add-GLTextChanged $script:UI.TxtGwFilter { Show-GLGateways }
    $script:UI.GridGateways.Add_SelectionChanged({ Update-GLGatewayDetail })
    $script:UI.BtnGwExport.Add_Click({ Export-GLGrid -Grid $script:UI.GridGateways -Suggested 'gateways' })
    $script:UI.BtnGwCopyId.Add_Click({ Copy-GLId -Grid $script:UI.GridGateways })
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
    foreach ($tb in 'TxtCnSearch', 'TxtCnUser', 'TxtCnAccount') { Add-GLTextChanged $script:UI[$tb] { Show-GLConnections } }
    foreach ($cb in 'CmbCnGateway', 'CmbCnConnectivity', 'CmbCnType') { $script:UI[$cb].Add_SelectionChanged({ Show-GLConnections }) }
    foreach ($ck in 'ChkStOnline', 'ChkStPartial', 'ChkStOffline', 'ChkStUnknown') { $script:UI[$ck].Add_Click({ Show-GLConnections }) }
    $script:UI.GridConnections.Add_SelectionChanged({ Update-GLConnectionDetail })
    $script:UI.BtnCnExclude.Add_Click({ Invoke-GLExclude })
    $script:UI.BtnCnUnexclude.Add_Click({ $script:State.Excluded.Clear(); Show-GLConnections })
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

    # create
    $script:UI.BtnCreateAdd.Add_Click({ Add-GLCreateRow })
    $script:UI.BtnCreateRemove.Add_Click({ Remove-GLCreateRows })
    $script:UI.BtnCreateClear.Add_Click({ $script:CreateTable.Rows.Clear() })
    $script:UI.BtnCreateLoad.Add_Click({ Import-GLCreateCsv })
    $script:UI.BtnCreateTemplate.Add_Click({ Save-GLCreateTemplate })
    $script:UI.BtnCreateParse.Add_Click({ Add-GLRowsFromStrings })
    $script:UI.BtnCreateRun.Add_Click({ Invoke-GLCreateUi })

    # log panel
    Add-GLTextChanged $script:UI.TxtLogFind { Update-GLLogView }
    $script:UI.CmbLogLevel.Add_SelectionChanged({ Update-GLLogView })
    $script:UI.BtnLogCopy.Add_Click({ Copy-GLLog })
    $script:UI.BtnLogSave.Add_Click({ Save-GLLog })
    $script:UI.BtnLogFolder.Add_Click({ Open-GLFolder $script:LogFolder })
    $script:UI.BtnLogClear.Add_Click({ $script:LogEntries.Clear(); $script:UI.TxtLog.Clear() })

    # activity
    $script:UI.BtnActRefresh.Add_Click({ Invoke-GLActivityRefresh })
    $script:UI.BtnActFolder.Add_Click({ Open-GLFolder $script:LogFolder })
    $script:UI.BtnActExport.Add_Click({ Export-GLGrid -Grid $script:UI.GridActivity -Suggested 'gatewaylens-changes' })
    $script:UI.BtnActUndo.Add_Click({ Invoke-GLUndoUi })
    Add-GLTextChanged $script:UI.TxtActFind { Show-GLActivity }
    foreach ($cb in 'CmbActPeriod', 'CmbActAction', 'CmbActResult', 'CmbActUser') { $script:UI[$cb].Add_SelectionChanged({ Show-GLActivity }) }
    # SelectionChanged bubbles up from every list inside the tabs - only react to the tabs themselves
    $script:UI.Tabs.Add_SelectionChanged({
        param($s, $e)
        if ($e.OriginalSource -ne $script:UI.Tabs) { return }
        if ($script:UI.Tabs.SelectedItem -eq $script:UI.TabActivity) { Invoke-GLActivityRefresh }
    })

    $script:UI.BtnCancel.Add_Click({
        $script:Progress.Cancel = $true
        Write-GLLog 'Cancelling after the current item...' 'Warn'
        Update-GLBusy
    })

    $script:Window.Add_Loaded({
        Write-GLLog "$($script:AppName) $($script:AppVersion) - signed in as $($script:SignedInAs) via $($script:AuthMode)."
        if ($script:AuthMode -eq 'Demo') {
            Write-GLLog 'DEMO: Contoso is fictional. Nothing leaves this computer, and changes last until the window closes.' 'Warn'
            Write-GLLog 'Try: Connections > Verify status - three connections fail, each for a different reason.'
            Write-GLLog "Try: HR Core cannot log in. Select it alone, update its credentials with any password except 'wrong', then verify again."
            Write-GLLog 'Try: the Activity tab has a week of history from two people - Joe Smith''s access to Sales DW can be undone.'
        }
        if ($script:StyleMode -eq 'Classic' -and $script:StyleError) {
            Write-GLLog "The modern look could not be loaded, so the classic one is in use: $($script:StyleError)" 'Warn'
        }
        Invoke-GLGatewayRefresh
        Invoke-GLConnectionRefresh
    })
    $script:Window.Add_Closing({
        param($s, $e)
        if ($script:Progress.Active -and -not (Confirm-GL "'$($script:Progress.Name)' is still running. Close anyway? It stops after the current item." 'Close')) {
            $e.Cancel = $true
            return
        }
        $script:Progress.Cancel = $true
    })
    $script:Window.Add_Closed({
        Write-GLLog 'Session ended.' -FileOnly
        foreach ($f in $script:HistoryFields) { Save-GLFieldHistory $f }
        $null = Save-GLSettings -Settings $script:Settings
        try { $script:Timer.Stop() } catch { }
        try { if ($script:AutoTimer) { $script:AutoTimer.Stop() } } catch { }
        try { $script:Pool.Close(); $script:Pool.Dispose() } catch { }
    })

    Initialize-GLWorkers
    [void]$script:Window.ShowDialog()
}

# ============================================================================
#  MAIN
# ============================================================================
if ($LoadOnly) { return }

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
    if ($AuthModule -ne 'Auto') { $relaunch += @('-AuthModule', $AuthModule) }
    if ($DnsSuffix.Count)       { $relaunch += @('-DnsSuffix', ($DnsSuffix -join ',')) }
    if ($BackupFolder)          { $relaunch += @('-BackupFolder', $BackupFolder) }
    if ($LogFolder)             { $relaunch += @('-LogFolder', $LogFolder) }
    if ($Launched)              { $relaunch += '-Launched' }
    if ($Demo)                  { $relaunch += '-Demo' }
    & $exe @relaunch
    exit $LASTEXITCODE
}

if ($Demo) {
    # demo changes and logs live apart from the real ones
    $demoRoot = Join-Path (Join-Path $appData 'GatewayLens') 'demo'
    if (-not $LogFolder)    { $script:LogFolder    = Join-Path $demoRoot 'logs' }
    if (-not $BackupFolder) { $script:BackupFolder = Join-Path $demoRoot 'backups' }
    Enable-GLDemo
    Write-Host 'Demo mode: Contoso is fictional - no sign-in, nothing leaves this computer.' -ForegroundColor Yellow
}
else {
    try {
        Write-Host "Signing in..." -ForegroundColor Cyan
        Connect-GL -TenantId $TenantId -DeviceCode:$DeviceCode -AuthModule $AuthModule
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
