[CmdletBinding()]
param(
    [Parameter()]
    [string]$EnvironmentPath = (Join-Path $PSScriptRoot '..\.env.oci'),

    [Parameter()]
    [switch]$SkipAi
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-EnvironmentFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Arquivo de ambiente não encontrado: $Path"
    }

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        $separator = $trimmed.IndexOf('=')
        if ($separator -le 0) {
            continue
        }

        $name = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if ($value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$name] = $value
    }

    return $values
}

function Get-RequiredValue {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Values,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not $Values.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace($Values[$Name])) {
        throw "Variável obrigatória ausente no ambiente local: $Name"
    }
    return [string]$Values[$Name]
}

function Invoke-CheckedRequest {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter()]
        [Microsoft.PowerShell.Commands.WebRequestMethod]$Method = 'Get',

        [Parameter()]
        [hashtable]$Headers = @{},

        [Parameter()]
        [string]$Body,

        [Parameter()]
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,

        [Parameter()]
        [int[]]$ExpectedStatus = @(200)
    )

    $parameters = @{
        Uri = $Uri
        Method = $Method
        Headers = $Headers
        SkipHttpErrorCheck = $true
        TimeoutSec = 45
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $parameters.Body = $Body
        $parameters.ContentType = 'application/json'
    }
    if ($null -ne $WebSession) {
        $parameters.WebSession = $WebSession
    }

    $response = Invoke-WebRequest @parameters
    if ($response.StatusCode -notin $ExpectedStatus) {
        throw "$Name retornou HTTP $($response.StatusCode); esperado: $($ExpectedStatus -join ', ')."
    }

    Write-Host ("{0}=ok http_status={1}" -f $Name, $response.StatusCode)
    return $response
}

$resolvedEnvironmentPath = [System.IO.Path]::GetFullPath($EnvironmentPath)
$configuration = Read-EnvironmentFile -Path $resolvedEnvironmentPath
$frontendBaseUrl = (Get-RequiredValue -Values $configuration -Name 'FRONTEND_PUBLIC_URL').TrimEnd('/')
$zrokShareName = Get-RequiredValue -Values $configuration -Name 'ZROK2_SHARE_NAME'
$email = Get-RequiredValue -Values $configuration -Name 'BFF_DEMO_EMAIL'
$password = Get-RequiredValue -Values $configuration -Name 'BFF_DEMO_PASSWORD'
$bffBaseUrl = "https://$zrokShareName.shares.zrok.io"

$session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()

try {
    Invoke-CheckedRequest -Name 'frontend_login' -Uri "$frontendBaseUrl/login" | Out-Null
    Invoke-CheckedRequest -Name 'frontend_spa_fallback' -Uri "$frontendBaseUrl/dashboard" | Out-Null
    Invoke-CheckedRequest -Name 'bff_health' -Uri "$bffBaseUrl/health" | Out-Null

    $loginBody = @{
        email = $email
        password = $password
    } | ConvertTo-Json -Compress
    $loginResponse = Invoke-CheckedRequest `
        -Name 'auth_login' `
        -Uri "$frontendBaseUrl/api/v1/auth/login" `
        -Method Post `
        -Body $loginBody `
        -WebSession $session
    $login = $loginResponse.Content | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($login.accessToken)) {
        throw 'O login não retornou accessToken.'
    }

    $headers = @{ Authorization = "Bearer $($login.accessToken)" }
    foreach ($endpoint in @(
        @{ Name = 'dashboard'; Path = '/api/v1/dashboard' },
        @{ Name = 'finance_summary'; Path = '/api/v1/finance/summary' },
        @{ Name = 'debt_summary'; Path = '/api/v1/debts/summary' },
        @{ Name = 'notifications'; Path = '/api/v1/notifications' },
        @{ Name = 'notifications_unread'; Path = '/api/v1/notifications/unread-count' }
    )) {
        $response = Invoke-CheckedRequest `
            -Name $endpoint.Name `
            -Uri "$frontendBaseUrl$($endpoint.Path)" `
            -Headers $headers
        if (@($response.Headers.Keys) -notcontains 'X-Correlation-ID') {
            throw "$($endpoint.Name) não retornou X-Correlation-ID."
        }
    }

    if (-not $SkipAi) {
        Invoke-CheckedRequest `
            -Name 'ai_analysis' `
            -Uri "$frontendBaseUrl/api/v1/ai/analyze" `
            -Method Post `
            -Headers $headers `
            -Body (@{ month = $null } | ConvertTo-Json -Compress) | Out-Null
    }

    $refreshResponse = Invoke-CheckedRequest `
        -Name 'auth_refresh' `
        -Uri "$frontendBaseUrl/api/v1/auth/refresh" `
        -Method Post `
        -WebSession $session
    $refresh = $refreshResponse.Content | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($refresh.accessToken)) {
        throw 'O refresh não retornou um novo accessToken.'
    }

    $refreshedHeaders = @{ Authorization = "Bearer $($refresh.accessToken)" }
    Invoke-CheckedRequest `
        -Name 'auth_logout' `
        -Uri "$frontendBaseUrl/api/v1/auth/logout" `
        -Method Post `
        -Headers $refreshedHeaders `
        -WebSession $session `
        -ExpectedStatus @(204) | Out-Null
    Invoke-CheckedRequest `
        -Name 'auth_refresh_after_logout' `
        -Uri "$frontendBaseUrl/api/v1/auth/refresh" `
        -Method Post `
        -WebSession $session `
        -ExpectedStatus @(401) | Out-Null

    Write-Output 'public_staging_smoke_test=passed'
}
finally {
    $password = $null
    $loginBody = $null
    $configuration.Clear()
}
