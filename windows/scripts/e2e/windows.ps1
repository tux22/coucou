# End-to-end run of Coucou on Windows.
#
# Starts the real app (a release build), feeds it Claude Code hook events
# through the real coucou-hook.exe and its named pipe, clicks the island like a
# person would, checks what Claude Code would have received, and saves
# screenshots. Meant for a GitHub windows runner, but safe on a PC: every
# folder the app writes to (%APPDATA%, %LOCALAPPDATA%, %USERPROFILE%) is
# redirected to a throwaway one for the app and the relay.
#
#   pwsh windows/scripts/e2e/windows.ps1 [-Bin path\to\coucou.exe] [-Out dir]
#
# Close any running Coucou first: the pipe is per user, and a second instance
# hands over to the first. Exits non-zero when any check fails.

param(
  [string]$Bin = "$PSScriptRoot\..\..\target\release\coucou.exe",
  [string]$Out = "$PSScriptRoot\..\..\e2e-out"
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Input {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
  [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
  [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
  [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
  // SRCCOPY | CAPTUREBLT: without CAPTUREBLT a screen copy leaves out layered
  // windows, and the island is one. .NET's CopyFromScreen refuses the flag.
  public static void Grab(IntPtr dst, int x, int y, int w, int h) {
    IntPtr screen = GetDC(IntPtr.Zero);
    BitBlt(dst, 0, 0, w, h, screen, x, y, 0x00CC0020 | 0x40000000);
    ReleaseDC(IntPtr.Zero, screen);
  }
  public static void Click(int x, int y) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(350);
    mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
    mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
  }
}
'@

if (-not (Test-Path $Bin)) { throw "no app binary at $Bin — build it with: npx tauri build --no-bundle" }
if (Get-Process coucou -ErrorAction SilentlyContinue) { throw "Coucou is already running — quit it first" }
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path

$work = Join-Path ([IO.Path]::GetTempPath()) ("coucou-e2e-" + [Guid]::NewGuid())
foreach ($d in 'home', 'appdata', 'local') { New-Item -ItemType Directory -Force (Join-Path $work $d) | Out-Null }
$env:USERPROFILE = Join-Path $work 'home'
$env:APPDATA = Join-Path $work 'appdata'
$env:LOCALAPPDATA = Join-Path $work 'local'
$Hook = Join-Path $env:LOCALAPPDATA 'Coucou\bin\coucou-hook.exe'
$Log = Join-Path $env:LOCALAPPDATA 'Coucou\coucou.log'

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$W = $screen.Width
$PanelX = [int](($W - 720) / 2)
$failures = 0

function Check([string]$what, [bool]$ok) {
  if ($ok) { Write-Host "  ok    $what" } else { Write-Host "  FAIL  $what"; $script:failures++ }
}

# A screenshot is a nice-to-have: one that fails is reported, never fatal.
function Shot([string]$name) {
  try {
    $w = [Math]::Min(900, $W); $h = 230; $x = [int](($W - $w) / 2)
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [Input]::Grab($hdc, $x, 0, $w, $h)
    $g.ReleaseHdc($hdc)
    $bmp.Save((Join-Path $Out "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
  } catch {
    Write-Host "  (screenshot $name failed: $($_.Exception.Message))"
  }
}

# Runs the relay the way Claude Code does: JSON on stdin, decision on stdout.
function Start-Hook([string]$json) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo $Hook
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $p.StandardInput.Write($json)
  $p.StandardInput.Close()
  return $p
}
function Finish-Hook($p) {
  $out = $p.StandardOutput.ReadToEnd()
  $p.WaitForExit(15000) | Out-Null
  return $out
}
function Send-Event([string]$json) { Finish-Hook (Start-Hook $json) | Out-Null }
function Away { [Input]::SetCursorPos(200, 700) | Out-Null }

# Hooks already installed, as they would be for anyone using Coucou.
$claude = Join-Path $env:USERPROFILE '.claude'
New-Item -ItemType Directory -Force $claude | Out-Null
$hooks = [ordered]@{}
foreach ($e in 'SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure',
  'PermissionRequest', 'PermissionDenied', 'Notification', 'Stop', 'StopFailure', 'SubagentStart', 'SubagentStop') {
  $hooks[$e] = @(@{ hooks = @(@{ type = 'command'; command = $Hook; args = @($e) }) })
}
@{ hooks = $hooks } | ConvertTo-Json -Depth 8 | Set-Content -Encoding ascii (Join-Path $claude 'settings.json')

Write-Host "Coucou e2e on Windows ($($screen.Width)x$($screen.Height)) — output in $Out"
$app = Start-Process $Bin -PassThru
try {
  # ── 1. Launch ──────────────────────────────────────────────────────────────
  $deadline = (Get-Date).AddSeconds(60)
  while (-not (Test-Path $Hook) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
  Check "the relay was installed at launch" (Test-Path $Hook)
  # A PC without the Visual C++ Redistributable cannot load a binary that
  # imports it — the relay used to die there before running (0xC0000135).
  # The runner has the Redistributable, so only reading the imports shows it.
  foreach ($exe in @($Hook, (Resolve-Path $Bin).Path)) {
    $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($exe))
    $name = Split-Path $exe -Leaf
    Check "$name does not need the Visual C++ runtime DLLs" (-not ($text -imatch 'vcruntime140(_1)?\.dll|msvcp140\.dll'))
  }
  Away
  Start-Sleep 3
  Shot 'greeting'
  Start-Sleep 5

  # ── 2. A session at work ───────────────────────────────────────────────────
  $S = '"session_id":"demo-1","cwd":"C:/Users/me/coucou"'
  Send-Event "{`"hook_event_name`":`"SessionStart`",$S}"
  Start-Sleep 1.5
  [Input]::Click([int]($W / 2), 16); Start-Sleep 1.2; Away
  Send-Event "{`"hook_event_name`":`"UserPromptSubmit`",$S,`"prompt`":`"Add a Linux build`"}"; Start-Sleep 1
  Send-Event "{`"hook_event_name`":`"PreToolUse`",$S,`"tool_name`":`"Read`",`"tool_input`":{`"file_path`":`"C:/Users/me/coucou/README.md`"}}"; Start-Sleep 1
  Send-Event "{`"hook_event_name`":`"PreToolUse`",$S,`"tool_name`":`"Bash`",`"tool_input`":{`"command`":`"cargo test --workspace`"}}"; Start-Sleep 1.5
  Shot 'session-working'
  Send-Event "{`"hook_event_name`":`"Stop`",$S}"; Start-Sleep 2
  Shot 'session-finished'
  $log = Get-Content $Log -Raw
  Check "hook events reach the app through the pipe" ($log -match 'hook SessionStart' -and $log -match 'hook Stop')

  # ── 3. Two sessions ask at once ───────────────────────────────────────────
  Start-Sleep 5
  $alpha = Start-Hook '{"hook_event_name":"PermissionRequest","session_id":"alpha","cwd":"C:/Users/me/alpha","tool_name":"Bash","tool_use_id":"toolu_a","tool_input":{"command":"npm test"}}'
  Start-Sleep 1
  $beta = Start-Hook '{"hook_event_name":"PermissionRequest","session_id":"beta","cwd":"C:/Users/me/beta","tool_name":"Bash","tool_use_id":"toolu_b","tool_input":{"command":"rm -rf build"}}'
  Start-Sleep 1.5
  Shot 'approval-queue'
  Away; Start-Sleep 1
  [Input]::Click($PanelX + 302, 121)   # Allow → alpha
  $a = Finish-Hook $alpha
  Start-Sleep 1.2
  Shot 'approval-second'
  [Input]::Click($PanelX + 195, 121)   # Deny → beta
  $b = Finish-Hook $beta
  Check "Allow on the island answers allow" ($a -match '"behavior":"allow"')
  Check "Deny on the island answers deny" ($b -match '"behavior":"deny"')

  # ── 4. Denied in the terminal ─────────────────────────────────────────────
  $gamma = Start-Hook '{"hook_event_name":"PermissionRequest","session_id":"gamma","cwd":"C:/Users/me/gamma","tool_name":"Bash","tool_use_id":"toolu_c","tool_input":{"command":"make"}}'
  Start-Sleep 1.5
  Send-Event '{"hook_event_name":"PermissionDenied","session_id":"gamma","cwd":"C:/Users/me/gamma","tool_name":"Bash","tool_use_id":"toolu_c","tool_input":{"command":"make"}}'
  $c = Finish-Hook $gamma
  Check "a request denied in the terminal releases the relay silently" ([string]::IsNullOrWhiteSpace($c))

  # ── 5. Minimize with a request waiting, reopen ────────────────────────────
  $delta = Start-Hook '{"hook_event_name":"PermissionRequest","session_id":"delta","cwd":"C:/Users/me/delta","tool_name":"Bash","tool_use_id":"toolu_d","tool_input":{"command":"git push"}}'
  Start-Sleep 1.5
  [Input]::Click($PanelX + 656, 25)    # the "–" button
  Start-Sleep 1.2
  Shot 'minimized'
  [Input]::Click([int]($W / 2), 16); Start-Sleep 1.2
  Shot 'reopened'
  [Input]::Click($PanelX + 302, 121)
  $d = Finish-Hook $delta
  Check "a request survives minimize and can still be allowed" ($d -match '"behavior":"allow"')
}
finally {
  if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force }
  Start-Sleep 1
  Copy-Item $Log (Join-Path $Out 'coucou.log') -ErrorAction SilentlyContinue
}

# ── 6. Coucou closed: Claude Code is never held up ──────────────────────────
$sw = [Diagnostics.Stopwatch]::StartNew()
$closed = Finish-Hook (Start-Hook '{"hook_event_name":"PermissionRequest","session_id":"x","tool_name":"Bash","tool_input":{"command":"ls"}}')
$ms = $sw.ElapsedMilliseconds
Check "with Coucou closed the relay exits at once ($ms ms) and prints nothing" ($ms -lt 2000 -and [string]::IsNullOrWhiteSpace($closed))

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Get-ChildItem $Out | ForEach-Object { Write-Host "  $($_.Name)" }
if ($failures -gt 0) {
  # The log says what the app saw (events, acks, decisions): enough to tell a
  # missed click from a request the relay gave up on.
  Write-Host "--- coucou.log (last 60 lines) ---"
  Get-Content (Join-Path $Out 'coucou.log') -Tail 60 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
  Write-Host "$failures check(s) failed"; exit 1
}
Write-Host "all checks passed"
