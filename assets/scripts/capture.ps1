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

$source = Get-Content -Raw -Path $csPath
Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.dll

$passArgs = New-Object System.Collections.Generic.List[string]
$passArgs.Add("-Mode")
$passArgs.Add($Mode)

if ($SavePath -ne "") {
    $passArgs.Add("-SavePath")
    $passArgs.Add($SavePath)
}

if ($CopyToClipboard) {
    $passArgs.Add("-CopyToClipboard")
}

if ($DelayMs -gt 0) {
    $passArgs.Add("-DelayMs")
    $passArgs.Add("$DelayMs")
}

if ($ShowMagnifier -eq "false") {
    $passArgs.Add("-ShowMagnifier")
    $passArgs.Add("false")
}

[Program]::Main($passArgs.ToArray())
