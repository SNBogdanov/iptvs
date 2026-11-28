[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $BuildDirectory,

  # Product version, three numeric components (`1.2.3`); MSI packs each field
  # into 0..255 and compares exactly these three when upgrading.
  [Parameter(Mandatory = $true)]
  [string] $Version,

  [Parameter(Mandatory = $true)]
  [string] $OutputPath,

  # Permanent product identity — see the template's comment. Never change it.
  [string] $UpgradeCode = 'B2F1C0DE-3E4A-4C55-9B7E-1D5C2A8F6E31',

  # Optional Authenticode signing of the produced MSI. Not needed to install.
  [string] $PfxPath = '',
  [string] $PfxPassword = '',
  [string] $TimestampUrl = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path $BuildDirectory).Path
$repo = Split-Path -Parent $PSScriptRoot
$template = Join-Path $repo 'windows\packaging\Product.wxs.in'
$icon = Join-Path $repo 'windows\runner\resources\app_icon.ico'
$licenseRtf = Join-Path $repo 'windows\packaging\license.rtf'
$bannerBmp = Join-Path $repo 'windows\packaging\WixUIBannerBmp.bmp'
$dialogBmp = Join-Path $repo 'windows\packaging\WixUIDialogBmp.bmp'
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
  throw "Version must have exactly three numeric components (for example 1.2.3): $Version"
}
$major = [int]$Matches[1]
$minor = [int]$Matches[2]
$patch = [int]$Matches[3]
if ($major -gt 255 -or $minor -gt 255 -or $patch -gt 255) {
  throw "Every MSI version field must be between 0 and 255: $Version"
}
foreach ($needed in @('iptvs.exe', 'flutter_windows.dll', 'libmpv-2.dll', 'data\flutter_assets\AssetManifest.bin')) {
  if (-not (Test-Path (Join-Path $root $needed) -PathType Leaf)) {
    throw "Windows release payload is missing $needed"
  }
}

function ConvertTo-XmlText([string] $value) {
  return [System.Security.SecurityElement]::Escape($value)
}

$files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName)

# ---- Directories ----------------------------------------------------------
# One id per relative directory. The tree is emitted by walking the directory
# paths in **lexicographic order** and keeping a stack of open `<Directory>`
# elements: a path's parent is its own prefix, so the stack pops until the
# current top *is* that parent. Sorting by depth (the previous scheme) put a
# depth-4 directory under whatever depth-3 directory happened to be last
# alphabetically — `data\flutter_assets\packages\app` landed under `shaders`.
$dirIds = @{ '' = 'INSTALLFOLDER' }
$dirs = New-Object System.Collections.Generic.List[string]
$counter = 0
foreach ($file in $files) {
  $relative = $file.DirectoryName.Substring($root.Length).TrimStart('\')
  if ($relative -eq '') { continue }
  $accumulated = ''
  foreach ($segment in $relative.Split('\')) {
    if ($accumulated -ne '') { $accumulated = "$accumulated\$segment" } else { $accumulated = $segment }
    if ($dirs.Contains($accumulated)) { continue }
    $counter++
    $dirs.Add($accumulated)
    $dirIds[$accumulated] = "D_$counter"
  }
}

$directoryXml = New-Object System.Text.StringBuilder
$open = New-Object System.Collections.Generic.List[string]
foreach ($path in ($dirs | Sort-Object)) {
  $depth = $path.Split('\').Count
  $parent = if ($depth -gt 1) { $path.Substring(0, $path.LastIndexOf('\')) } else { '' }
  while ($open.Count -gt 0 -and $open[$open.Count - 1] -ne $parent) {
    $open.RemoveAt($open.Count - 1)
    [void]$directoryXml.AppendLine(('        ' + ('  ' * $open.Count) + '</Directory>'))
  }
  $name = $path.Split('\')[-1]
  [void]$directoryXml.AppendLine(('        ' + ('  ' * $open.Count) + '<Directory Id="' + $dirIds[$path] + '" Name="' + (ConvertTo-XmlText $name) + '">'))
  $open.Add($path)
}
while ($open.Count -gt 0) {
  $open.RemoveAt($open.Count - 1)
  [void]$directoryXml.AppendLine(('        ' + ('  ' * $open.Count) + '</Directory>'))
}

# ---- Stable component GUIDs ------------------------------------------------
# `Guid="*"` would generate a new GUID for every build. With
# `MajorUpgrade Schedule="afterInstallExecute"` the old product is removed
# *after* the new one is installed, so its components would key the same file
# paths under different GUIDs and could delete the files the new product just
# wrote (the Samsung install with shortcuts but no program files). A GUID
# derived from the install-relative path keeps one component identity across
# versions, which is what MSI's upgrade rules expect.
function New-StableComponentGuid {
  param([Parameter(Mandatory = $true)][string] $Key)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(('iptvs-msi:' + $Key.ToLowerInvariant())))
  } finally {
    $sha.Dispose()
  }
  $bytes = New-Object byte[] 16
  [Array]::Copy($hash, $bytes, 16)
  # RFC 4122 version 5 / variant bits, so the value is a well-formed UUID.
  $bytes[7] = [byte](($bytes[7] -band 0x0F) -bor 0x50)
  $bytes[8] = [byte](($bytes[8] -band 0x3F) -bor 0x80)
  return ([guid]::new($bytes)).ToString().ToUpperInvariant()
}

# ---- Components -----------------------------------------------------------
$componentXml = New-Object System.Text.StringBuilder
$index = 0
foreach ($file in $files) {
  $index++
  $relative = $file.DirectoryName.Substring($root.Length).TrimStart('\')
  if ($relative -eq '') { $directoryId = 'INSTALLFOLDER' } else { $directoryId = $dirIds[$relative] }
  # Key the GUID on the install-relative path, not the enumeration order or the
  # source path, so it survives a moved build directory and a changed file order.
  $componentKey = (($relative + '\' + $file.Name).TrimStart('\'))
  [void]$componentXml.AppendLine('      <Component Id="C_' + $index.ToString('D4') + '" Directory="' + $directoryId + '" Guid="' + (New-StableComponentGuid $componentKey) + '">')
  [void]$componentXml.AppendLine('        <File Id="F_' + $index.ToString('D4') + '" Source="' + (ConvertTo-XmlText $file.FullName) + '" KeyPath="yes" />')
  [void]$componentXml.AppendLine('      </Component>')
}

$manifest = [System.IO.File]::ReadAllText($template)
$manifest = $manifest.Replace('@VERSION@', $Version)
$manifest = $manifest.Replace('@UPGRADE_CODE@', $UpgradeCode)
$manifest = $manifest.Replace('@ICON_PATH@', (ConvertTo-XmlText $icon))
$manifest = $manifest.Replace('@LICENSE_RTF@', (ConvertTo-XmlText $licenseRtf))
$manifest = $manifest.Replace('@BANNER_BMP@', (ConvertTo-XmlText $bannerBmp))
$manifest = $manifest.Replace('@DIALOG_BMP@', (ConvertTo-XmlText $dialogBmp))
$manifest = $manifest.Replace('@DIRECTORIES@', $directoryXml.ToString())
$manifest = $manifest.Replace('@COMPONENTS@', $componentXml.ToString())
foreach ($token in @('@VERSION@', '@UPGRADE_CODE@', '@ICON_PATH@', '@LICENSE_RTF@', '@BANNER_BMP@', '@DIALOG_BMP@', '@DIRECTORIES@', '@COMPONENTS@')) {
  if ($manifest.Contains($token)) {
    throw "MSI template token was not replaced: $token"
  }
}

$wix = (Get-Command 'wix.exe' -ErrorAction SilentlyContinue).Source
if (-not $wix) { $wix = Join-Path $env:USERPROFILE '.dotnet\tools\wix.exe' }
if (-not (Test-Path $wix -PathType Leaf)) { $wix = 'C:\Windows\ServiceProfiles\LocalService\.dotnet\tools\wix.exe' }
if (-not (Test-Path $wix -PathType Leaf)) { throw 'WiX v4 not found (dotnet tool install --global wix).' }

$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$wxs = Join-Path $outputDirectory 'Product.wxs'
[System.IO.File]::WriteAllText($wxs, $manifest, (New-Object System.Text.UTF8Encoding($false)))

if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }
& $wix build $wxs -arch x64 -ext WixToolset.UI.wixext -ext WixToolset.Util.wixext -o $OutputPath
if ($LASTEXITCODE -ne 0) { throw "wix build failed: exit $LASTEXITCODE" }
if (-not (Test-Path $OutputPath -PathType Leaf)) { throw "wix build reported success but produced no package" }

if (-not [string]::IsNullOrWhiteSpace($PfxPath)) {
  $signtool = (Get-ChildItem (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin') -Filter 'signtool.exe' -Recurse -File |
    Where-Object { $_.DirectoryName -match '[\\/]x64$' } |
    Sort-Object { [version] $_.Directory.Parent.Name } -Descending | Select-Object -First 1).FullName
  if (-not $signtool) { throw 'signtool.exe not found in the Windows SDK.' }
  $signArgs = @('sign', '/fd', 'SHA256', '/f', $PfxPath)
  if ($PfxPassword) { $signArgs += @('/p', $PfxPassword) }
  if ($TimestampUrl) { $signArgs += @('/tr', $TimestampUrl, '/td', 'SHA256') }
  $signArgs += $OutputPath
  & $signtool @signArgs
  if ($LASTEXITCODE -ne 0) { throw "signtool failed: exit $LASTEXITCODE" }
}

Write-Host ("Built MSI {0} from {1} files: {2}" -f $Version, $files.Count, $OutputPath)
