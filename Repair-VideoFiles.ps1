<#
.SYNOPSIS
Repair-VideoFiles.ps1 - Repairs MP4 video files by remuxing and (when needed) re-encoding, then verifies the result.

.DESCRIPTION
Designed for partially corrupted or container/timestamp-broken MP4 files — common with CCTV incident exports and bad trim operations.
Workflow per input file:
1) Pass 1 (Remux): stream-copy the primary video stream to a new MP4 container with regenerated timestamps.
2) Verify: validate MP4 container readability (ffprobe) and run a short decode health check (ffmpeg) to detect corruption/timestamp issues.
3) Pass 2 (Re-encode if needed): re-encode the source to H.264 with automatic hardware-encoder selection (Intel QSV / NVIDIA NVENC / AMD AMF)
   and CPU fallback (libx264) if hardware encode fails.
4) Log: write results to _verify_log.csv (input/output/status/action/severity/encoder/details).

.NOTES
- Requires ffmpeg and ffprobe. The script detects them in PATH automatically.
  If not found, it offers to install via: winget install -e --id Gyan.FFmpeg
  winget will prompt for UAC elevation; the script itself does not require admin rights.
- Outputs:
  - *_fixed.mp4           => remux-only output (when verification passes)
  - *_fixed_reencode.mp4  => re-encoded output (when remux verification fails or decode health indicates issues)
  - _verify_log.csv       => processing log for audit/traceability
- Depending on settings, the script may keep both *_fixed.mp4 (remux artifact) and *_fixed_reencode.mp4 (final) for some inputs.
  Use _verify_log.csv "output" column as the authoritative list of final deliverables.

.PARAMETER None
This script prompts interactively for:
- Source directory containing .mp4 files
- Output directory for repaired files and log

.EXAMPLE
PS> .\Repair-VideoFiles.ps1
(then provide Source directory and Output directory when prompted)

#>
# Repair-VideoFiles.ps1

Set-StrictMode -Version Latest

$script:currentProcess = $null
$script:bestEncoder = $null

$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
  if ($script:currentProcess -and -not $script:currentProcess.HasExited) {
    Write-Host "`n`nAborting FFmpeg process..." -ForegroundColor Yellow
    $script:currentProcess.Kill()
  }
}

function Unquote([string]$s) {
  $t = ($s + "").Trim()
  if (($t.StartsWith('"') -and $t.EndsWith('"')) -or ($t.StartsWith("'") -and $t.EndsWith("'"))) {
    return $t.Substring(1, $t.Length - 2)
  }
  $t
}

function QuoteArg([string]$s) {
  '"' + ($s -replace '"', '\"') + '"'
}

function RunExeSimple([string]$exe, [string[]]$argsList) {
  $argStr = ($argsList -join ' ')
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = $argStr
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  [pscustomobject]@{ Code = $p.ExitCode; Out = $stdout; Err = $stderr }
}

function DetectBestEncoder([string]$ffmpeg) {
  Write-Host "Detecting best H.264 encoder...`n" -ForegroundColor Cyan

  $r = RunExeSimple $ffmpeg @('-encoders')
  if ($r.Code -ne 0) {
    Write-Host "  X Failed to query encoders (using CPU fallback)`n" -ForegroundColor Yellow
    return [pscustomobject]@{ Name = 'libx264'; Label = 'x264 (CPU)'; Args = @('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23', '-pix_fmt', 'yuv420p') }
  }

  $encoders = $r.Out
  
  if ($encoders -match 'h264_nvenc') {
    Write-Host "  Testing NVENC (NVIDIA)... " -NoNewline -ForegroundColor Gray
    $test = RunExeSimple $ffmpeg @('-f', 'lavfi', '-i', 'color=size=64x64:duration=0.1', '-c:v', 'h264_nvenc', '-f', 'null', '-')
    if ($test.Code -eq 0) {
      Write-Host "OK Available" -ForegroundColor Green
      Write-Host ""
      return [pscustomobject]@{
        Name    = 'h264_nvenc'
        Label   = 'NVENC (NVIDIA GPU)'
        PreArgs = @()
        OutArgs = @('-c:v', 'h264_nvenc', '-preset', 'p4', '-cq', '23', '-pix_fmt', 'yuv420p')
      }
    }
    Write-Host "X Not available" -ForegroundColor DarkGray
  }

  if ($encoders -match 'h264_qsv') {
    Write-Host "  Testing QSV (Intel)... " -NoNewline -ForegroundColor Gray
    $test = RunExeSimple $ffmpeg @('-f', 'lavfi', '-i', 'color=size=64x64:duration=0.1', '-c:v', 'h264_qsv', '-f', 'null', '-')
    if ($test.Code -eq 0) {
      Write-Host "OK Available" -ForegroundColor Green
      Write-Host ""
      return [pscustomobject]@{
        Name    = 'h264_qsv'
        Label   = 'QSV (Intel iGPU)'
        PreArgs = @()
        OutArgs = @('-c:v', 'h264_qsv', '-preset', 'veryfast', '-global_quality', '23', '-pix_fmt', 'nv12')
      }
    }
    Write-Host "X Not available" -ForegroundColor DarkGray
  }

  if ($encoders -match 'h264_amf') {
    Write-Host "  Testing AMF (AMD)... " -NoNewline -ForegroundColor Gray
    $test = RunExeSimple $ffmpeg @('-f', 'lavfi', '-i', 'color=size=64x64:duration=0.1', '-c:v', 'h264_amf', '-f', 'null', '-')
    if ($test.Code -eq 0) {
      Write-Host "OK Available" -ForegroundColor Green
      Write-Host ""
      return [pscustomobject]@{
        Name    = 'h264_amf'
        Label   = 'AMF (AMD GPU)'
        PreArgs = @()
        OutArgs = @('-c:v', 'h264_amf', '-quality', 'speed', '-qp_i', '23', '-qp_p', '23', '-pix_fmt', 'yuv420p')
      }
    }
    Write-Host "X Not available" -ForegroundColor DarkGray
  }

  Write-Host "  Using x264 (CPU fallback)`n" -ForegroundColor Yellow
  return [pscustomobject]@{
    Name    = 'libx264'
    Label   = 'x264 (CPU)'
    PreArgs = @()
    OutArgs = @('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23', '-pix_fmt', 'yuv420p')
  }
}

function RunFFmpegWithProgress([string]$ffmpeg, [string[]]$argsList, [string]$label, [double]$durationSec) {
  $argStr = ($argsList -join ' ')
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ffmpeg
  $psi.Arguments = $argStr
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  
  $script:currentProcess = $p
  
  $stderrBuffer = New-Object System.Text.StringBuilder
  $stdoutBuffer = New-Object System.Text.StringBuilder
  
  $stderrHandler = {
    if ($EventArgs.Data) {
      [void]$Event.MessageData.AppendLine($EventArgs.Data)
    }
  }
  
  $stdoutHandler = {
    if ($EventArgs.Data) {
      [void]$Event.MessageData.AppendLine($EventArgs.Data)
    }
  }
  
  $stderrEvent = $null
  $stdoutEvent = $null
  $stderrEvent = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -Action $stderrHandler -MessageData $stderrBuffer
  $stdoutEvent = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action $stdoutHandler -MessageData $stdoutBuffer
  
  [void]$p.Start()
  $p.BeginErrorReadLine()
  $p.BeginOutputReadLine()

  $lastPct = -1
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $maxWaitSeconds = 300
  $lastUpdateTime = $sw.Elapsed.TotalSeconds

  try {
    while (-not $p.HasExited) {
      Start-Sleep -Milliseconds 300
      
      if ($sw.Elapsed.TotalSeconds -gt $maxWaitSeconds) {
        Write-Host "`n  Timeout reached (5 min), killing process..." -ForegroundColor Red
        $p.Kill()
        $p.WaitForExit()
        throw "Encoding timeout"
      }

      try {
        if ([Console]::KeyAvailable) {
          $key = [Console]::ReadKey($true)
          if ($key.Key -eq 'C' -and $key.Modifiers -band [ConsoleModifiers]::Control) {
            Write-Host "`n`nCtrl+C detected. Stopping FFmpeg..." -ForegroundColor Yellow
            $p.Kill()
            $p.WaitForExit()
            throw "User cancelled"
          }
        }
      }
      catch {}

      # Show spinner if no progress updates for >5s
      $currentTime = $sw.Elapsed.TotalSeconds
      if ((($currentTime - $lastUpdateTime) -gt 5) -and ($lastPct -lt 0)) {
        $spinner = @('|', '/', '-', '\')
        $idx = [Math]::Floor($currentTime) % 4
        Write-Host "`r  $label $($spinner[$idx]) " -NoNewline -ForegroundColor Cyan
      }

      $stderr = $stderrBuffer.ToString()
      $timeLine = ($stderr -split "`n" | Where-Object { $_ -match 'time=(\d+):(\d+):(\d+\.\d+)' } | Select-Object -Last 1)

      if ($timeLine -and $timeLine -match 'time=(\d+):(\d+):(\d+\.\d+)') {
        $hrs = [int]$matches[1]
        $mins = [int]$matches[2]
        $secs = [double]$matches[3]
        $currentSec = ($hrs * 3600) + ($mins * 60) + $secs

        if ($durationSec -gt 0) {
          $pct = [Math]::Min(100, [Math]::Floor(($currentSec / $durationSec) * 100))
          if ($pct -ne $lastPct -and $pct -ge 0) {
            $lastPct = $pct
            $elapsed = $sw.Elapsed.TotalSeconds
            $eta = if ($pct -gt 0) { [Math]::Ceiling(($elapsed / $pct) * (100 - $pct)) } else { 0 }
            $barLen = [Math]::Floor($pct / 2)
            $bar = ('#' * $barLen) + ('-' * (50 - $barLen))
            Write-Host "`r  $label [$bar] $pct% ETA: $($eta)s " -NoNewline -ForegroundColor Cyan
          }
        }
      }
    }

    $p.WaitForExit()
    $p.CancelErrorRead()
    $p.CancelOutputRead()
    
    Start-Sleep -Milliseconds 100

    # Clear entire progress line
    Write-Host ("`r" + (" " * 100)) -NoNewline
    Write-Host "`r" -NoNewline

    [pscustomobject]@{ 
      Code = $p.ExitCode
      Out  = $stdoutBuffer.ToString()
      Err  = $stderrBuffer.ToString()
    }

  }
  finally {
    $script:currentProcess = $null
    
    if ($stderrEvent) { Unregister-Event -SourceIdentifier $stderrEvent.Name -ErrorAction SilentlyContinue }
    if ($stdoutEvent) { Unregister-Event -SourceIdentifier $stdoutEvent.Name -ErrorAction SilentlyContinue }
    Get-Job | Where-Object { $_.State -eq 'Completed' } | Remove-Job -ErrorAction SilentlyContinue
    
    if ($p -and -not $p.HasExited) { 
      try { $p.Kill() } catch {}
    }
  }
}

function GetDuration([string]$ffprobe, [string]$path) {
  $r = RunExeSimple $ffprobe @('-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', (QuoteArg $path))
  if ($r.Code -eq 0 -and $r.Out.Trim() -match '^\d+(\.\d+)?$') {
    return [double]$r.Out.Trim()
  }
  return 0
}

function ToCsvSafe([string]$s) {
  if ($null -eq $s) { return "" }
  ($s -replace '"', "''" -replace "`r?`n", " | ").Trim()
}

function TestMp4Container([string]$ffprobe, [string]$path) {
  $r = RunExeSimple $ffprobe @('-v', 'error', '-print_format', 'json', '-show_entries', 'format=format_name', (QuoteArg $path))
  if ($r.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Detail = ("ffprobe_failed: " + (ToCsvSafe $r.Err)) } }

  $j = $r.Out | ConvertFrom-Json
  $fmt = $j.format.format_name
  $ok = ($fmt -like "*mp4*")
  [pscustomobject]@{ Ok = $ok; Detail = ("format_name=" + $fmt) }
}

function DecodeHealth([string]$ffmpeg, [string]$path) {
  $r = RunExeSimple $ffmpeg @('-v', 'error', '-t', '30', '-fflags', '+genpts', '-err_detect', 'ignore_err', '-i', (QuoteArg $path), '-f', 'null', '-')

  $e = ToCsvSafe $r.Err
  if ($r.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Severity = "FAIL"; Detail = $e } }

  if ($e -match '(?i)error while decoding|invalid data found|corrupt|concealing') {
    return [pscustomobject]@{ Ok = $false; Severity = "FAIL"; Detail = $e }
  }

  if ($e -match '(?i)non[- ]monotonic|pts has no value|timestamps are unset') {
    return [pscustomobject]@{ Ok = $true; Severity = "WARN"; Detail = $e }
  }

  if ($e.Length -gt 0) {
    return [pscustomobject]@{ Ok = $true; Severity = "WARN"; Detail = $e }
  }

  [pscustomobject]@{ Ok = $true; Severity = "OK"; Detail = "" }
}

function Resolve-FFmpegBinaries {
  # 1. Check PATH first
  $ff = Get-Command 'ffmpeg'  -ErrorAction SilentlyContinue
  $fp = Get-Command 'ffprobe' -ErrorAction SilentlyContinue

  if ($ff -and $fp) {
    return @{ ffmpeg = $ff.Source; ffprobe = $fp.Source }
  }

  Write-Host ""
  Write-Host "  ffmpeg/ffprobe not found in PATH." -ForegroundColor Yellow

  # 2. Check winget availability
  $wg = Get-Command 'winget' -ErrorAction SilentlyContinue
  if (-not $wg) {
    Write-Host "  winget is not available on this system." -ForegroundColor Red
    Write-Host "  Install ffmpeg manually from https://ffmpeg.org/download.html and ensure" -ForegroundColor Red
    Write-Host "  ffmpeg.exe and ffprobe.exe are in your PATH, then re-run this script." -ForegroundColor Red
    exit 1
  }

  $ans = Read-Host "  Install ffmpeg via winget? (winget will prompt for UAC) [Y/N]"
  if ($ans -notmatch '^[Yy]') {
    Write-Host "  Aborted. Install ffmpeg manually and re-run." -ForegroundColor Red
    exit 1
  }

  Write-Host "  Running: winget install -e --id Gyan.FFmpeg" -ForegroundColor Cyan
  winget install -e --id Gyan.FFmpeg

  if ($LASTEXITCODE -ne 0) {
    Write-Host "  winget install failed (exit $LASTEXITCODE)." -ForegroundColor Red
    Write-Host "  Install ffmpeg manually from https://ffmpeg.org/download.html and re-run." -ForegroundColor Red
    exit 1
  }

  # 3. Refresh PATH from registry so we don't need a new terminal
  $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
  $userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
  $env:PATH = $machinePath + ';' + $userPath

  $ff = Get-Command 'ffmpeg'  -ErrorAction SilentlyContinue
  $fp = Get-Command 'ffprobe' -ErrorAction SilentlyContinue

  if (-not $ff -or -not $fp) {
    Write-Host "  ffmpeg installed but not yet detectable in PATH." -ForegroundColor Yellow
    Write-Host "  Please restart your terminal and re-run this script." -ForegroundColor Yellow
    exit 1
  }

  Write-Host "  ffmpeg ready: $($ff.Source)" -ForegroundColor Green
  return @{ ffmpeg = $ff.Source; ffprobe = $fp.Source }
}

# --- main ---
$_bins = Resolve-FFmpegBinaries
$ffmpeg = $_bins.ffmpeg
$ffprobe = $_bins.ffprobe

$script:bestEncoder = DetectBestEncoder $ffmpeg

$srcDir = Unquote (Read-Host "`nSource directory — full path to folder with .mp4 files (e.g. D:\Footage, \\server\share, C:\Users\YourName\Videos; quotes optional)")
$outDir = Unquote (Read-Host "Output directory — full path for repaired files (e.g. D:\Output, C:\Users\YourName\Desktop\Repaired; avoid C:\... root; quotes optional)")

if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) { throw "Input dir not found: $srcDir" }
New-Item -ItemType Directory -Force -LiteralPath $outDir | Out-Null

$log = Join-Path $outDir "_verify_log.csv"
"input,output,status,action,decode_severity,encoder,details" | Out-File -Encoding utf8 $log

$files = @(Get-ChildItem -LiteralPath $srcDir -Filter *.mp4 -File | Where-Object { $_.BaseName -notmatch '_fixed(_reencode)?$' })
$total = $files.Count
$i = 0

Write-Host "Found $total file(s) to process.`n" -ForegroundColor Cyan
Write-Host "Press Ctrl+C to abort at any time.`n" -ForegroundColor DarkGray

foreach ($file in $files) {
  $i++
  $in = $file.FullName
  $out = Join-Path $outDir ($file.BaseName + "_fixed.mp4")
  $out2 = Join-Path $outDir ($file.BaseName + "_fixed_reencode.mp4")

  Write-Host "[$i/$total] " -NoNewline -ForegroundColor Yellow
  Write-Host $file.Name -ForegroundColor White

  $dur = GetDuration $ffprobe $in

  # Pass 1: remux with soft timeout (validates output even on timeout)
  Write-Host "  -> Remuxing (stream copy)... " -NoNewline -ForegroundColor Gray
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  $remuxArgs = @(
    '-hide_banner', '-loglevel', 'error', '-y', '-fflags', '+genpts',
    '-i', (QuoteArg $in),
    '-map', '0:v:0', '-c:v', 'copy', '-an',
    '-movflags', '+faststart',
    (QuoteArg $out)
  )

  $remuxJob = Start-Job -ScriptBlock {
    param($exe, $argStr)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $argStr
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    
    @{ Code = $p.ExitCode; Err = $stderr }
  } -ArgumentList $ffmpeg, ($remuxArgs -join ' ')

  # Remux watchdog: stop only if output stops growing (stall), plus a hard cap
  $hardCapSec = 90     # absolute max wall time for remux (reduce freely: 90–180 typical)
  $stallSec = 15      # declare "hung" if output size doesn't grow for this long
  $pollMs = 500     # polling interval

  $t0 = Get-Date
  $lastGrow = $null
  $lastSize = 0L

  while ($true) {
    $j = Get-Job -Id $remuxJob.Id -ErrorAction SilentlyContinue
    if ($null -eq $j -or $j.State -ne 'Running') { break }

    if (Test-Path -LiteralPath $out) {
      $sz = (Get-Item -LiteralPath $out).Length
      if ($sz -gt $lastSize) {
        $lastSize = $sz
        $lastGrow = Get-Date
      }
    }

    $elapsed = (New-TimeSpan -Start $t0 -End (Get-Date)).TotalSeconds
    $stalled = if ($null -ne $lastGrow) { (New-TimeSpan -Start $lastGrow -End (Get-Date)).TotalSeconds } else { 0 }

    if ($elapsed -ge $hardCapSec -or $stalled -ge $stallSec) { break }

    Start-Sleep -Milliseconds $pollMs
  }

  $remuxFinished = ((Get-Job -Id $remuxJob.Id -ErrorAction SilentlyContinue).State -ne 'Running')

  if (-not $remuxFinished) {
    # We bailed due to stall/hard-cap. Stop job, but treat output as OK if it's playable.
    Stop-Job $remuxJob -ErrorAction SilentlyContinue
    Remove-Job $remuxJob -Force -ErrorAction SilentlyContinue
    $sw.Stop()

    # Ensure any leftover ffmpeg (from the job) releases the output file handle
    Start-Sleep -Milliseconds 800
    Get-Process ffmpeg -ErrorAction SilentlyContinue |
      Where-Object { $_.StartTime -ge $t0 } |
      Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800


    if ((Test-Path -LiteralPath $out) -and (Get-Item -LiteralPath $out).Length -gt 1MB) {
      Write-Host "slow/stalled (cap=$hardCapSec s, stall=$stallSec s) but output exists" -ForegroundColor Yellow
      # Continue to Verify step
    }
    else {
      Write-Host "TIMEOUT (cap=$hardCapSec s or stall=$stallSec s, no output)" -ForegroundColor Red
      """$in"",""$out"",FAIL,remux,FAIL,n/a,""Remux stalled/capped (cap=$hardCapSec s, stall=$stallSec s)""" | Add-Content -Encoding utf8 $log
      continue
    }
  }
  else {
    $r1 = Receive-Job $remuxJob
    Remove-Job $remuxJob
    $sw.Stop()


    if ($r1.Code -ne 0 -or -not (Test-Path -LiteralPath $out)) {
      Write-Host "FAIL ($($sw.Elapsed.TotalSeconds.ToString('F1'))s)" -ForegroundColor Red
      """$in"",""$out"",FAIL,remux,FAIL,n/a,""$(ToCsvSafe $r1.Err)""" | Add-Content -Encoding utf8 $log
      continue
    }

    Write-Host "done ($($sw.Elapsed.TotalSeconds.ToString('F1'))s)" -ForegroundColor Green
  }


  # Verify
  Write-Host "  -> Verifying... " -NoNewline -ForegroundColor Gray
  $m = TestMp4Container $ffprobe $out
  $d = DecodeHealth $ffmpeg $out

  if ($m.Ok -and $d.Ok) {
    Write-Host "OK ($($d.Severity))" -ForegroundColor Green
    """$in"",""$out"",OK,remux,$($d.Severity),n/a,""$(ToCsvSafe ($m.Detail + " " + $d.Detail))""" | Add-Content -Encoding utf8 $log
    continue
  }

  Write-Host "needs re-encode" -ForegroundColor Yellow

  # Don't delete the remux output; it may still be locked on some timeouts.
  # Keep it as an artifact, and write re-encode to _fixed_reencode.mp4 anyway.

  # Pass 2: re-encode with GPU (automatic CPU fallback)
  $sw.Restart()
  $usedEncoder = $script:bestEncoder.Name

  try {
    $encArgs = @('-y') + $script:bestEncoder.PreArgs + @('-i', (QuoteArg $in)) + $script:bestEncoder.OutArgs + @(
      '-an', '-vf', 'setpts=PTS-STARTPTS',
      '-movflags', '+faststart',
      (QuoteArg $out2)
    )

    $r2 = RunFFmpegWithProgress $ffmpeg $encArgs ("-> Re-encoding (" + $script:bestEncoder.Label + ")") $dur
    $sw.Stop()

    # If GPU failed, retry with CPU
    if (($r2.Code -ne 0 -or -not (Test-Path -LiteralPath $out2)) -and $script:bestEncoder.Name -ne 'libx264') {
      Write-Host "`r                                                                                    " -NoNewline
      Write-Host "`r  -> Re-encoding ($($script:bestEncoder.Label))... FAIL (GPU incompatible, retrying with CPU)" -ForegroundColor Yellow
      
      if (Test-Path -LiteralPath $out2) { Remove-Item -LiteralPath $out2 -Force }
      
      $sw.Restart()
      $cpuArgs = @(
        '-y', '-i', (QuoteArg $in),
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23', '-pix_fmt', 'yuv420p',
        '-an', '-vf', 'setpts=PTS-STARTPTS',
        '-movflags', '+faststart',
        (QuoteArg $out2)
      )
      
      $r2 = RunFFmpegWithProgress $ffmpeg $cpuArgs "-> Re-encoding (x264 CPU)" $dur
      $sw.Stop()
      $usedEncoder = 'libx264'
      Write-Host "`r                                                                                    " -NoNewline
      Write-Host "`r  -> Re-encoding (x264 CPU fallback)... " -NoNewline -ForegroundColor Gray
    }
    else {
      Write-Host "`r                                                                                    " -NoNewline
      Write-Host "`r  -> Re-encoding ($($script:bestEncoder.Label))... " -NoNewline -ForegroundColor Gray
    }

    if ($r2.Code -ne 0 -or -not (Test-Path -LiteralPath $out2)) {
      Write-Host "FAIL ($($sw.Elapsed.TotalSeconds.ToString('F1'))s)" -ForegroundColor Red
      """$in"",""$out2"",FAIL,reencode,FAIL,$usedEncoder,""$(ToCsvSafe $r2.Err)""" | Add-Content -Encoding utf8 $log
      continue
    }

    $m2 = TestMp4Container $ffprobe $out2
    $d2 = DecodeHealth $ffmpeg $out2
    $status = if ($m2.Ok -and $d2.Ok) { "OK" } else { "FAIL" }

    if ($status -eq "OK") {
      Write-Host "done ($($sw.Elapsed.TotalSeconds.ToString('F1'))s)" -ForegroundColor Green
    }
    else {
      Write-Host "completed but issues remain ($($sw.Elapsed.TotalSeconds.ToString('F1'))s)" -ForegroundColor Yellow
    }

    """$in"",""$out2"",$status,reencode,$($d2.Severity),$usedEncoder,""$(ToCsvSafe ($m2.Detail + " " + $d2.Detail))""" | Add-Content -Encoding utf8 $log

  }
  catch {
    if ($_.Exception.Message -eq "Encoding timeout") {
      Write-Host "`n  Encoding timed out, skipping file." -ForegroundColor Red
      """$in"",""$out2"",FAIL,reencode,FAIL,$usedEncoder,""Encoding timeout (5 min)""" | Add-Content -Encoding utf8 $log
    }
    else {
      Write-Host "`n`nAborted by user." -ForegroundColor Red
      break
    }
  }
}

Write-Host "`nDone. Log: $log" -ForegroundColor Cyan
