[CmdletBinding()]
param (
    [string]$Mode = "region",
    [string]$SavePath = "",
    [switch]$CopyToClipboard,
    [int]$DelayMs = 0,
    [string]$ShowMagnifier = "true"
)

$csPath = Join-Path $PSScriptRoot "capture.cs"
if (-not (Test-Path $csPath)) {
    $csPath = "c:\Coding\MyProjects\Raycast Screenshot Extention\assets\scripts\capture.cs"
}

$csSource = Get-Content -Raw -Path $csPath
Add-Type -TypeDefinition $csSource -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.dll

$passArgs = @("-Mode", $Mode)
if ($SavePath -ne "") {
    $passArgs += @("-SavePath", $SavePath)
}
if ($CopyToClipboard) {
    $passArgs += @("-CopyToClipboard")
}
if ($DelayMs -gt 0) {
    $passArgs += @("-DelayMs", "$DelayMs")
}
$passArgs += @("-ShowMagnifier", $ShowMagnifier)

[Program]::Main([string[]]$passArgs)
