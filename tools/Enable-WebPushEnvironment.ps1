[CmdletBinding()]
param(
    [Parameter()]
    [string]$EnvironmentPath = (Join-Path $PSScriptRoot '..\.env.oci'),

    [Parameter()]
    [string]$Subject,

    [Parameter()]
    [switch]$Rotate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Base64Url {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Value
    )

    return [Convert]::ToBase64String($Value).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-EnvironmentValue {
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $prefix = "$Name="
    $line = $Lines | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) } | Select-Object -Last 1
    if ($null -eq $line) {
        return $null
    }

    return $line.Substring($prefix.Length)
}

$resolvedEnvironmentPath = [System.IO.Path]::GetFullPath($EnvironmentPath)
if (-not (Test-Path -LiteralPath $resolvedEnvironmentPath -PathType Leaf)) {
    throw "Arquivo de ambiente não encontrado: $resolvedEnvironmentPath"
}

$lines = [System.IO.File]::ReadAllLines($resolvedEnvironmentPath)
$existingPublicKey = Get-EnvironmentValue -Lines $lines -Name 'WEB_PUSH_PUBLIC_KEY'
$existingPrivateKey = Get-EnvironmentValue -Lines $lines -Name 'WEB_PUSH_PRIVATE_KEY'
if (-not $Rotate -and
    -not [string]::IsNullOrWhiteSpace($existingPublicKey) -and
    -not [string]::IsNullOrWhiteSpace($existingPrivateKey)) {
    Write-Output 'web_push=already_configured'
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Subject)) {
    $Subject = Get-EnvironmentValue -Lines $lines -Name 'FRONTEND_PUBLIC_URL'
}

$subjectUri = $null
if (-not [Uri]::TryCreate($Subject, [UriKind]::Absolute, [ref]$subjectUri) -or
    $subjectUri.Scheme -notin @('https', 'mailto')) {
    throw 'Subject inválido. Informe uma URL HTTPS ou mailto: válido.'
}

$algorithm = [System.Security.Cryptography.ECDsa]::Create(
    [System.Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256')
)
try {
    $parameters = $algorithm.ExportParameters($true)
    $publicBytes = [byte[]]::new(65)
    $publicBytes[0] = 4
    [Array]::Copy($parameters.Q.X, 0, $publicBytes, 1, 32)
    [Array]::Copy($parameters.Q.Y, 0, $publicBytes, 33, 32)
    $updates = [ordered]@{
        WEB_PUSH_ENABLED     = 'true'
        WEB_PUSH_SUBJECT     = $Subject
        WEB_PUSH_PUBLIC_KEY  = ConvertTo-Base64Url -Value $publicBytes
        WEB_PUSH_PRIVATE_KEY = ConvertTo-Base64Url -Value $parameters.D
    }
}
finally {
    $algorithm.Dispose()
}

$updatedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$updatedLines = foreach ($line in $lines) {
    $separatorIndex = $line.IndexOf('=')
    if ($separatorIndex -gt 0) {
        $name = $line.Substring(0, $separatorIndex)
        if ($updates.Contains($name)) {
            [void]$updatedNames.Add($name)
            "$name=$($updates[$name])"
            continue
        }
    }

    $line
}

$missingLines = foreach ($name in $updates.Keys) {
    if (-not $updatedNames.Contains($name)) {
        "$name=$($updates[$name])"
    }
}

if ($missingLines.Count -gt 0) {
    $updatedLines = @($updatedLines) + '' + '# Web Push (VAPID)' + @($missingLines)
}

[System.IO.File]::WriteAllLines(
    $resolvedEnvironmentPath,
    $updatedLines,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Output 'web_push=configured'
Write-Output 'private_key=stored_only_in_ignored_environment_file'
