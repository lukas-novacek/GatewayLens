<#
.SYNOPSIS
    The README's pictures, all from the demo: the screenshots, the moving tour and
    the social preview image.

.DESCRIPTION
    Runs GatewayLens.ps1 -Screenshots, which drives the real window on Contoso -
    fictional, nothing real can get into the pictures - then joins the tour's
    frames into one animated PNG (assets/screenshot-tour.png), and draws the image
    GitHub, LinkedIn and others show when the repository is shared
    (assets/social-preview.png - upload it under Settings > General > Social
    preview, GitHub has no API for it).

    Needs Windows: the window is WPF.

.EXAMPLE
    pwsh -NoProfile -File build/Make-Marketing.ps1
#>
#Requires -Version 7.2
[CmdletBinding()]
param([switch]$SkipScreenshots)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $root 'assets'
$app    = Join-Path $root 'GatewayLens.ps1'

if (-not $IsWindows) { throw 'The pictures are drawn by WPF - run this on Windows.' }

# ---- 1. the screenshots and the tour's frames, from the real window
if (-not $SkipScreenshots) {
    & (Get-Process -Id $PID).Path -NoProfile -File $app -Screenshots $assets
    if ($LASTEXITCODE) { throw "GatewayLens -Screenshots failed ($LASTEXITCODE)." }
}

# the app's own functions and colours, for what is drawn below
. $app -LoadOnly
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$bgv = ConvertTo-GLColorValue $script:Themes['Dark'].WindowBg
$bg  = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb($bgv[0], $bgv[1], $bgv[2], $bgv[3]))
$bg.Freeze()

# ---- 2. the tour: frames into one animated PNG
# APNG, not GIF: a GIF has 256 colours, and screenshots of a window come out
# speckled. Every browser plays APNG; anything that does not shows the first frame.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class GlApng
{
    static readonly uint[] Table = MakeTable();

    static uint[] MakeTable()
    {
        var t = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            uint c = n;
            for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            t[n] = c;
        }
        return t;
    }

    static uint Crc(byte[] type, byte[] data)
    {
        uint c = 0xFFFFFFFFu;
        foreach (byte b in type) c = Table[(c ^ b) & 0xFF] ^ (c >> 8);
        foreach (byte b in data) c = Table[(c ^ b) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFFu;
    }

    static void Be32(Stream s, uint v) { s.WriteByte((byte)(v >> 24)); s.WriteByte((byte)(v >> 16)); s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)v); }

    static byte[] Be32(uint v) { return new[] { (byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v }; }

    static void Chunk(Stream s, string type, byte[] data)
    {
        byte[] t = Encoding.ASCII.GetBytes(type);
        Be32(s, (uint)data.Length);
        s.Write(t, 0, 4);
        s.Write(data, 0, data.Length);
        Be32(s, Crc(t, data));
    }

    static List<KeyValuePair<string, byte[]>> Read(string path)
    {
        byte[] all = File.ReadAllBytes(path);
        var list = new List<KeyValuePair<string, byte[]>>();
        int i = 8;
        while (i + 8 <= all.Length)
        {
            int len = (all[i] << 24) | (all[i + 1] << 16) | (all[i + 2] << 8) | all[i + 3];
            string type = Encoding.ASCII.GetString(all, i + 4, 4);
            byte[] data = new byte[len];
            Array.Copy(all, i + 8, data, 0, len);
            list.Add(new KeyValuePair<string, byte[]>(type, data));
            i += 12 + len;
        }
        return list;
    }

    public static void Write(string[] frames, int[] delaysMs, string outPath)
    {
        var first = Read(frames[0]);
        byte[] ihdr = first.Find(c => c.Key == "IHDR").Value;
        using (var fs = File.Create(outPath))
        {
            fs.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }, 0, 8);
            Chunk(fs, "IHDR", ihdr);
            var actl = new List<byte>(Be32((uint)frames.Length));
            actl.AddRange(Be32(0));                                  // plays for ever
            Chunk(fs, "acTL", actl.ToArray());
            uint seq = 0;
            for (int f = 0; f < frames.Length; f++)
            {
                var chunks = f == 0 ? first : Read(frames[f]);
                byte[] h = chunks.Find(c => c.Key == "IHDR").Value;
                for (int b = 0; b < 13; b++) if (h[b] != ihdr[b]) throw new InvalidOperationException("Frame " + (f + 1) + " is not the same size and kind as the first.");
                var fctl = new List<byte>(Be32(seq++));
                fctl.AddRange(new ArraySegment<byte>(ihdr, 0, 8));    // width, height
                fctl.AddRange(Be32(0)); fctl.AddRange(Be32(0));       // x, y
                ushort d = (ushort)Math.Min(65535, Math.Max(1, delaysMs[f]));
                fctl.Add((byte)(d >> 8)); fctl.Add((byte)d);          // delay: d / 1000 s
                fctl.Add(3); fctl.Add(232);                           // 1000
                fctl.Add(0); fctl.Add(0);                             // keep, replace
                Chunk(fs, "fcTL", fctl.ToArray());
                foreach (var c in chunks)
                {
                    if (c.Key != "IDAT") continue;
                    if (f == 0) { Chunk(fs, "IDAT", c.Value); continue; }
                    var fd = new List<byte>(Be32(seq++));
                    fd.AddRange(c.Value);
                    Chunk(fs, "fdAT", fd.ToArray());
                }
            }
            Chunk(fs, "IEND", new byte[0]);
        }
    }
}
'@

$frameDir = Join-Path ([System.IO.Path]::GetTempPath()) 'gatewaylens-tour'
$manifest = Join-Path $frameDir 'frames.json'
if (Test-Path -LiteralPath $manifest) {
    $frames = @(Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json)
    # the kiosk frame is drawn at the screen's size: every frame is brought to the first one's size
    $firstImg = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($frames[0].File), 'None', 'OnLoad')
    $W = $firstImg.PixelWidth; $H = $firstImg.PixelHeight
    $files = foreach ($f in $frames) {
        $img = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($f.File), 'None', 'OnLoad')
        if ($img.PixelWidth -eq $W -and $img.PixelHeight -eq $H) { $f.File; continue }
        $dv = [System.Windows.Media.DrawingVisual]::new()
        $dc = $dv.RenderOpen()
        $k  = [Math]::Min($W / $img.PixelWidth, $H / $img.PixelHeight)
        $w2 = $img.PixelWidth * $k; $h2 = $img.PixelHeight * $k
        $dc.DrawRectangle($bg, $null, [System.Windows.Rect]::new(0, 0, $W, $H))
        $dc.DrawImage($img, [System.Windows.Rect]::new(($W - $w2) / 2, ($H - $h2) / 2, $w2, $h2))
        $dc.Close()
        $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($W, $H, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($dv)
        $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
        $enc.Interlace = 'Off'
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $out = [System.IO.Path]::ChangeExtension($f.File, '.fit.png')
        $fs = [System.IO.File]::Create($out)
        try { $enc.Save($fs) } finally { $fs.Dispose() }
        $out
    }
    $tour = Join-Path $assets 'screenshot-tour.png'
    [GlApng]::Write([string[]]@($files), [int[]]@($frames | ForEach-Object { [int]$_.Delay }), $tour)
    Write-Host ("Tour: {0} frames, {1:N1} MB -> {2}" -f @($files).Count, ((Get-Item $tour).Length / 1MB), $tour) -ForegroundColor Green
    Remove-Item -LiteralPath $frameDir -Recurse -Force -ErrorAction SilentlyContinue
}
else { Write-Host 'No tour frames found - run without -SkipScreenshots first.' -ForegroundColor Yellow }

# ---- 2b. the cleanup report, on a tenant the size the report is made for
# The demo has a few dozen connections - its clusters look empty against 1,000.
# This is a larger Contoso, made up here, put through the app's own report.
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($edge) {
    $rng  = [System.Random]::new(7)
    $now  = Get-Date
    $fmt  = { param($d) $d.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
    $what = 'Sales DW', 'HR Core', 'Finance Budget', 'Supply Chain', 'Customer 360', 'Marketing Files', 'Inventory', 'Treasury', 'Payroll', 'Logistics', 'Pricing', 'Service Desk'
    $kind = 'SQL', 'SQL', 'SQL', 'Oracle', 'File', 'SharePoint'
    $people = 'jane.doe@contoso.com', 'joe.smith@contoso.com', 'ana.novak@contoso.com', 'bi-admins@contoso.com', 'finance-analysts@contoso.com', 'li.wei@contoso.com', 'omar.haddad@contoso.com'
    $rows = [System.Collections.Generic.List[object]]::new()
    $counts = @{}
    $n = 0
    foreach ($c in @(@('Contoso EMEA Cluster', 1000), @('Contoso Prod Cluster', 968), @('Contoso Finance Cluster', 641), @('Contoso Sales Cluster', 412), @('Contoso Test Cluster', 187))) {
        $gid = 'cluster-' + ($c[0] -replace '\W', '').ToLowerInvariant()
        $counts[$gid] = $c[1]
        for ($i = 1; $i -le $c[1]; $i++) {
            $n++
            $made = $now.AddDays(-$rng.Next(200, 1100)).AddMinutes(-$rng.Next(0, 1440))
            $roll = $rng.NextDouble()
            $used = if ($roll -lt 0.52) { $now.AddDays(-$rng.Next(0, 30)) } elseif ($roll -lt 0.64) { $now.AddDays(-$rng.Next(31, 120)) }
                    elseif ($roll -lt 0.75) { $now.AddDays(-$rng.Next(121, 365)) } elseif ($roll -lt 0.84) { $now.AddDays(-$rng.Next(366, 700)) }
                    elseif ($roll -lt 0.97) { $null } else { 'none' }
            $base = $what[$rng.Next(0, $what.Count)]
            $path = 'sql{0:000}.contoso.local;{1}' -f $rng.Next(1, 400), ($base -replace '\W', '').ToLowerInvariant()
            $type = $kind[$rng.Next(0, $kind.Count)]
            # a few copies of the one before - the duplicates a big tenant collects
            if ($rng.NextDouble() -lt 0.04 -and $rows.Count) {
                $twin = $rows[$rows.Count - 1]
                if ($twin.GatewayId -eq $gid) { $path = $twin.Path; $base = $twin.Name -replace ' \d+$', ''; $type = $twin.Type }
            }
            $noData = ($used -eq 'none')
            $u = if ($noData -or $null -eq $used) { $null } else { $used }
            $rows.Add([pscustomobject]@{
                Name = "$base $i"; Connectivity = 'OnPremisesGateway'; Gateway = $c[0]; GatewayId = $gid; Type = $type
                Path = $path; Account = 'CONTOSO\svc_' + ($base -replace '\W', '').ToLowerInvariant()
                Created = $(if ($noData) { '' } else { & $fmt $made }); LastLinked = $(if ($noData) { '' } else { & $fmt $made.AddDays(2) })
                LastUsed = $(if ($u) { & $fmt $u } else { '' }); UnusedDays = $(if ($u) { [int][math]::Floor(($now - $u).TotalDays) } else { $null })
                Id = "c$n"; Users = [string]$rng.Next(1, 9); Cleanup = ''; CanGo = $false
            })
        }
    }
    Set-GLCleanupReasons -Rows $rows -Now $now
    $owners = @{}
    foreach ($r in @($rows | Where-Object { $_.Cleanup })) { $owners[$r.Id] = @($people[$rng.Next(0, $people.Count)]) }
    $reportDir = Join-Path ([System.IO.Path]::GetTempPath()) ('gatewaylens-report-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $reportDir -Force
    $report = Join-Path $reportDir 'cleanup-report.html'
    $null = Save-GLCleanupReport -Path $report -Rows $rows -Owners $owners -Counts $counts -NoOpen `
        -Meta @{ Version = $script:AppVersion; Who = 'demo.user@contoso.com'; Tenant = 'contoso.example'; When = $now }
    $shotFile = Join-Path $assets 'screenshot-cleanup-report.png'
    # one quoted line: a temp folder can have a space in it, and Start-Process does not quote
    $argLine = "--headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 `"--user-data-dir=$(Join-Path $reportDir 'edge')`" " +
               "--window-size=1280,1240 `"--screenshot=$shotFile`" `"$(([Uri]::new($report)).AbsoluteUri)`""
    $null = Start-Process -FilePath $edge -PassThru -Wait -WindowStyle Hidden -ArgumentList $argLine
    if (Test-Path -LiteralPath $shotFile) { Write-Host "Cleanup report -> $shotFile" -ForegroundColor Green } else { Write-Host 'Edge did not draw the cleanup report.' -ForegroundColor Yellow }
    Remove-Item -LiteralPath $reportDir -Recurse -Force -ErrorAction SilentlyContinue
}
else { Write-Host 'No Edge to draw the cleanup report with.' -ForegroundColor Yellow }

# ---- 3. the social preview: what a shared link shows
$xaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="1280" Height="640" ClipToBounds="True"
      Background="{DynamicResource WindowBg}" TextOptions.TextFormattingMode="Ideal">
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="600"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>
  <Canvas Name="Cards" Grid.Column="0" Grid.ColumnSpan="2"/>
  <StackPanel Grid.Column="0" Margin="64,66,30,40">
    <StackPanel Orientation="Horizontal">
      <Image Name="Logo" Width="88" Height="88"/>
      <TextBlock Text="GatewayLens" FontFamily="Segoe UI" FontSize="60" FontWeight="SemiBold" Foreground="{DynamicResource Ink}" VerticalAlignment="Center" Margin="22,0,0,0"/>
    </StackPanel>
    <TextBlock Text="The missing admin console for Power BI and Fabric data gateways" FontFamily="Segoe UI" FontSize="32" FontWeight="SemiBold"
               Foreground="{DynamicResource Ink}" TextWrapping="Wrap" Margin="0,30,0,0" LineHeight="40"/>
    <WrapPanel Name="Chips" Margin="0,26,0,0"/>
    <TextBlock Text="Free and open source, for gateway admins" FontFamily="Segoe UI" FontSize="20" Foreground="{DynamicResource InkMuted}" Margin="0,16,0,0"/>
    <TextBlock Text="github.com/lukas-novacek/GatewayLens" FontFamily="Segoe UI" FontSize="20" FontWeight="SemiBold" Foreground="{DynamicResource Accent}" Margin="0,4,0,0"/>
  </StackPanel>
</Grid>
'@
$card = [Windows.Markup.XamlReader]::Parse($xaml)
$null = Set-GLTheme -Target $card -Name 'Dark'
$logo = Get-GLIconImage
if ($logo) { $card.FindName('Logo').Source = $logo }
# three screens as cards, back to front - each one whole, nothing cut off
$cards = $card.FindName('Cards')
foreach ($c in @(
        @{ File = 'screenshot-kiosk.png';       X = 628; Y = 34;  W = 470 }
        @{ File = 'screenshot-connections.png'; X = 690; Y = 150; W = 500 }
        @{ File = 'screenshot-gateways.png';    X = 752; Y = 276; W = 500 })) {
    $img = [System.Windows.Media.Imaging.BitmapImage]::new()
    $img.BeginInit(); $img.UriSource = [Uri]::new((Join-Path $assets $c.File)); $img.CacheOption = 'OnLoad'; $img.EndInit()
    $b = [System.Windows.Controls.Border]::new()
    $b.Width  = $c.W
    $b.Height = [Math]::Round($c.W * $img.PixelHeight / $img.PixelWidth)
    $b.CornerRadius = [System.Windows.CornerRadius]::new(10)
    $b.BorderThickness = [System.Windows.Thickness]::new(1.5)
    $b.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'BorderStrong')
    $b.Background = [System.Windows.Media.ImageBrush]::new($img)
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($b, [System.Windows.Media.BitmapScalingMode]::HighQuality)
    $sh = [System.Windows.Media.Effects.DropShadowEffect]::new()
    $sh.BlurRadius = 34; $sh.ShadowDepth = 6; $sh.Opacity = 0.7; $sh.Direction = 270
    $b.Effect = $sh
    [System.Windows.Controls.Canvas]::SetLeft($b, $c.X)
    [System.Windows.Controls.Canvas]::SetTop($b, $c.Y)
    $null = $cards.Children.Add($b)
}
# the jobs admins do every week, the biggest time-saver first
foreach ($chip in 'Bulk credential updates', 'Bulk access grants', 'Access migration', 'Cleanup for the 1,000 limit', 'Live gateway monitoring', 'Offline alerts') {
    $b = [System.Windows.Controls.Border]::new()
    $b.CornerRadius = [System.Windows.CornerRadius]::new(19)
    $b.Padding = [System.Windows.Thickness]::new(16, 6, 16, 7)
    $b.Margin  = [System.Windows.Thickness]::new(0, 0, 10, 10)
    $b.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'AccentSoft')
    $tb = [System.Windows.Controls.TextBlock]::new()
    $tb.Text = $chip
    $tb.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI')
    $tb.FontSize = 20
    $tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Ink')
    $b.Child = $tb
    $null = $card.FindName('Chips').Children.Add($b)
}
$size = [System.Windows.Size]::new(1280, 640)
$card.Measure($size); $card.Arrange([System.Windows.Rect]::new($size)); $card.UpdateLayout()
$rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(1280, 640, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
$rtb.Render($card)
$enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
$preview = Join-Path $assets 'social-preview.png'
$fs = [System.IO.File]::Create($preview)
try { $enc.Save($fs) } finally { $fs.Dispose() }
Write-Host "Social preview -> $preview (upload it under Settings > General > Social preview)" -ForegroundColor Green
