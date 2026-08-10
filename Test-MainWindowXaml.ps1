<#
.SYNOPSIS
    Loads the main window's XAML and checks every control the code binds to.

.DESCRIPTION
    SlideshowVideoTool.ps1 resolves roughly ninety controls by name at start-up
    and throws if one is missing. That check is sound, but it only fires when
    the application is actually launched, which makes any layout edit a matter
    of opening the window and hoping.

    This does the same check in a couple of seconds without a window. It reads
    the XAML and the $controlNames list out of the script itself, so it cannot
    drift from what the application really asks for: adding a name to that list
    without adding the control fails here too.

    Run it after any change to the interface.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $root 'SlideshowVideoTool.ps1'
$text = [IO.File]::ReadAllText($scriptPath)

function Get-HereString {
    # Returns the contents of the assignment "$Name = @'  ...  '@".
    param([string]$Source, [string]$Name)
    # The secondary windows are assigned inside functions, so the assignment is
    # indented; only the closing '@ must sit at the start of its line.
    $pattern = "(?ms)^\s*\`$$Name\s*=\s*@'\r?\n(.*?)\r?\n'@\s*$"
    $match = [regex]::Match($Source, $pattern)
    if (-not $match.Success) { throw "Could not find the here-string assigned to `$$Name." }
    return $match.Groups[1].Value
}

$failures = [Collections.Generic.List[string]]::new()

# --- The main window -------------------------------------------------------

$xaml = Get-HereString -Source $text -Name 'xaml'
try {
    $reader = [Xml.XmlNodeReader]::new([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
}
catch {
    throw "The main window XAML does not parse: $($_.Exception.Message)"
}
Write-Host 'Main window XAML parsed.' -ForegroundColor DarkGray

# The list the application itself walks at start-up.
$listMatch = [regex]::Match($text, "(?ms)^\`$controlNames\s*=\s*@\((.*?)^\)")
if (-not $listMatch.Success) { throw 'Could not find the $controlNames list.' }
$required = [regex]::Matches($listMatch.Groups[1].Value, "'([A-Za-z0-9_]+)'") |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object -Unique

foreach ($name in $required) {
    if ($null -eq $window.FindName($name)) {
        $failures.Add("Main window is missing the control '$name'.")
    }
}
Write-Host "Checked $($required.Count) bound controls." -ForegroundColor DarkGray

# Anything the code touches as a variable but forgot to list would still crash
# at run time, so catch that here rather than in front of the person using it.
$body = $text.Substring($text.IndexOf("`$controlNames"))
$declared = [regex]::Matches($xaml, 'x:Name="([A-Za-z0-9_]+)"') |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object -Unique
foreach ($name in $declared) {
    if ($required -contains $name) { continue }
    # A name used as $Foo.Something in the body but never resolved is a bug.
    if ($body -match "\`$$name\s*\.") {
        $failures.Add("'$name' is used in code but never resolved in the `$controlNames list.")
    }
}

# --- The secondary windows -------------------------------------------------

foreach ($variable in @('editorXaml', 'historyXaml', 'queueXaml')) {
    if ($text -notmatch "(?m)^\s*\`$$variable\s*=\s*@'") { continue }
    $secondary = Get-HereString -Source $text -Name $variable
    try {
        $secondaryReader = [Xml.XmlNodeReader]::new([xml]$secondary)
        [void][Windows.Markup.XamlReader]::Load($secondaryReader)
        Write-Host "$variable parsed." -ForegroundColor DarkGray
    }
    catch {
        $failures.Add("$variable does not parse: $($_.Exception.Message)")
    }
}

# --- Result ----------------------------------------------------------------

Write-Host ''
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "  $failure" -ForegroundColor Red }
    Write-Host ''
    throw "$($failures.Count) interface problem(s) found."
}
Write-Host 'All main window controls resolved.' -ForegroundColor Green
