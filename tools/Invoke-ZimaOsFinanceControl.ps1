[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Status', 'Health', 'Logs', 'Deploy', 'Restart', 'SyncEnvironment', 'SyncEnvironmentOnly', 'SyncDeployment', 'InitializePublicTunnel', 'PublicStatus', 'AutomationInfo', 'InstallAutoDeploy', 'AutoDeployStatus', 'RunAutoDeploy', 'AutoDeployLogs')]
    [string]$Action = 'Status',

    [Parameter()]
    [ValidateSet('bff', 'finance-service', 'debt-service', 'edge', 'zrok-agent')]
    [string]$Service = 'bff',

    [Parameter()]
    [ValidateRange(1, 1000)]
    [int]$Tail = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-ShellSingleQuoted {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $replacement = "'" + '"' + "'" + '"' + "'"
    return "'" + $Value.Replace("'", $replacement) + "'"
}

function Send-FileOverScp {
    param(
        [Parameter(Mandatory)]
        [string]$LocalPath,

        [Parameter(Mandatory)]
        [string]$RemotePath,

        [Parameter(Mandatory)]
        [pscustomobject]$AccessConfig
    )

    $scpInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $scpInfo.FileName = 'scp'
    $scpInfo.UseShellExecute = $false
    $scpInfo.RedirectStandardOutput = $true
    $scpInfo.RedirectStandardError = $true
    [void]$scpInfo.ArgumentList.Add('-q')
    [void]$scpInfo.ArgumentList.Add('-i')
    [void]$scpInfo.ArgumentList.Add([string]$AccessConfig.KeyPath)
    [void]$scpInfo.ArgumentList.Add('-o')
    [void]$scpInfo.ArgumentList.Add('BatchMode=yes')
    [void]$scpInfo.ArgumentList.Add('-o')
    [void]$scpInfo.ArgumentList.Add("UserKnownHostsFile=$($AccessConfig.KnownHostsPath)")
    [void]$scpInfo.ArgumentList.Add('-o')
    [void]$scpInfo.ArgumentList.Add('StrictHostKeyChecking=accept-new')
    [void]$scpInfo.ArgumentList.Add($LocalPath)
    [void]$scpInfo.ArgumentList.Add("$($AccessConfig.SshUser)@$($AccessConfig.ServerAddress):$RemotePath")

    $scpProcess = [System.Diagnostics.Process]::Start($scpInfo)
    $scpOutputTask = $scpProcess.StandardOutput.ReadToEndAsync()
    $scpErrorTask = $scpProcess.StandardError.ReadToEndAsync()
    $scpProcess.WaitForExit()
    $scpOutput = $scpOutputTask.GetAwaiter().GetResult()
    $scpError = $scpErrorTask.GetAwaiter().GetResult()
    if ($scpProcess.ExitCode -ne 0) {
        throw "Falha ao transferir '$LocalPath' pelo SSH. $scpOutput $scpError"
    }
}

$userProfilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
$vaultDirectory = Join-Path $userProfilePath '.finance-control'
$configPath = Join-Path $vaultDirectory 'zimaos-access.json'

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw 'Configuração ausente. Execute tools/Initialize-ZimaOsAccess.ps1 primeiro.'
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
foreach ($requiredProperty in @('ServerAddress', 'SshUser', 'KeyPath', 'CredentialPath', 'KnownHostsPath')) {
    if (-not $config.PSObject.Properties.Name.Contains($requiredProperty) -or [string]::IsNullOrWhiteSpace($config.$requiredProperty)) {
        throw "Propriedade obrigatória ausente: $requiredProperty."
    }
}

if ($config.ServerAddress -notmatch '^[A-Za-z0-9.-]+$') {
    throw 'Endereço do servidor inválido na configuração local.'
}
if ($config.SshUser -notmatch '^[a-z_][a-z0-9_-]*$') {
    throw 'Usuário SSH inválido na configuração local.'
}
if (-not (Test-Path -LiteralPath $config.KeyPath -PathType Leaf)) {
    throw 'Chave SSH privada não encontrada.'
}
if (-not (Test-Path -LiteralPath $config.CredentialPath -PathType Leaf)) {
    throw 'Credencial DPAPI não encontrada.'
}

$environmentUploadPath = '/DATA/.ssh/finance-control-environment.upload'
$composeUploadPath = '/DATA/.ssh/finance-control-compose.upload'
$caddyUploadPath = '/DATA/.ssh/finance-control-caddy.upload'
$autoUpdateUploadPath = '/DATA/.ssh/finance-control-auto-update.upload'
$autoUpdateServiceUploadPath = '/DATA/.ssh/finance-control-auto-update-service.upload'
$autoUpdateTimerUploadPath = '/DATA/.ssh/finance-control-auto-update-timer.upload'
if ($Action -in @('SyncEnvironment', 'SyncEnvironmentOnly')) {
    $localEnvironmentPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.env.oci'))
    if (-not (Test-Path -LiteralPath $localEnvironmentPath -PathType Leaf)) {
        throw 'Arquivo .env.oci local não encontrado.'
    }

    Send-FileOverScp -LocalPath $localEnvironmentPath -RemotePath $environmentUploadPath -AccessConfig $config
}

if ($Action -eq 'SyncDeployment') {
    $localComposePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\compose.zimaos.yml'))
    $localCaddyPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\deploy\zimaos\Caddyfile'))
    foreach ($localPath in @($localComposePath, $localCaddyPath)) {
        if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
            throw "Arquivo de implantação local não encontrado: $localPath"
        }
    }

    Send-FileOverScp -LocalPath $localComposePath -RemotePath $composeUploadPath -AccessConfig $config
    Send-FileOverScp -LocalPath $localCaddyPath -RemotePath $caddyUploadPath -AccessConfig $config
}

if ($Action -eq 'InstallAutoDeploy') {
    $autoDeployDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\deploy\zimaos'))
    $autoDeployFiles = @(
        [pscustomobject]@{
            LocalPath = Join-Path $autoDeployDirectory 'auto-update.sh'
            RemotePath = $autoUpdateUploadPath
        },
        [pscustomobject]@{
            LocalPath = Join-Path $autoDeployDirectory 'finance-control-auto-update.service'
            RemotePath = $autoUpdateServiceUploadPath
        },
        [pscustomobject]@{
            LocalPath = Join-Path $autoDeployDirectory 'finance-control-auto-update.timer'
            RemotePath = $autoUpdateTimerUploadPath
        }
    )

    foreach ($file in $autoDeployFiles) {
        if (-not (Test-Path -LiteralPath $file.LocalPath -PathType Leaf)) {
            throw "Arquivo da automação ausente: $($file.LocalPath)"
        }
        Send-FileOverScp -LocalPath $file.LocalPath -RemotePath $file.RemotePath -AccessConfig $config
    }
}

$compose = 'docker compose --env-file .env.zimaos -f compose.zimaos.yml'
$publicCompose = "$compose --profile public"
$operation = switch ($Action) {
    'Status' {
        "$compose ps"
    }
    'Health' {
        "$compose ps; $compose exec -T edge wget --quiet --output-document=/dev/null http://127.0.0.1:8080/health; printf 'edge_health=ok\n'"
    }
    'Logs' {
        "$compose logs --no-color --tail $Tail $Service"
    }
    'Deploy' {
        "$compose pull && $compose up --detach --wait"
    }
    'Restart' {
        "$compose up --detach --wait"
    }
    'SyncEnvironment' {
        "set -eu; trap 'rm -f /DATA/.ssh/finance-control-environment.upload' EXIT; docker compose --env-file /DATA/.ssh/finance-control-environment.upload -f compose.zimaos.yml config --quiet; install -o root -g root -m 600 /DATA/.ssh/finance-control-environment.upload .env.zimaos; $compose up --detach --wait bff edge"
    }
    'SyncEnvironmentOnly' {
        "set -eu; trap 'rm -f /DATA/.ssh/finance-control-environment.upload' EXIT; docker compose --env-file /DATA/.ssh/finance-control-environment.upload -f compose.zimaos.yml config --quiet; install -o root -g root -m 600 /DATA/.ssh/finance-control-environment.upload .env.zimaos; printf 'environment_synced=true\n'"
    }
    'SyncDeployment' {
        $caddyImage = 'caddy:2.10.2-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d'
        "set -eu; trap 'rm -f /DATA/.ssh/finance-control-compose.upload /DATA/.ssh/finance-control-caddy.upload' EXIT; docker compose --env-file .env.zimaos -f /DATA/.ssh/finance-control-compose.upload --profile public config --quiet; docker run --rm -v /DATA/.ssh/finance-control-caddy.upload:/etc/caddy/Caddyfile:ro $caddyImage caddy validate --config /etc/caddy/Caddyfile; install -d -o root -g root -m 755 deploy/zimaos; install -o root -g root -m 644 /DATA/.ssh/finance-control-compose.upload compose.zimaos.yml; install -o root -g root -m 644 /DATA/.ssh/finance-control-caddy.upload deploy/zimaos/Caddyfile; $publicCompose config --quiet"
    }
    'InitializePublicTunnel' {
        $initializeShare = 'set -eu; names="$(zrok2 list names --namespace-token public --json)"; if ! printf "%s" "$names" | grep -Eq "\\\"name\\\"[[:space:]]*:[[:space:]]*\\\"${ZROK2_SHARE_NAME}\\\""; then zrok2 create name "$ZROK2_SHARE_NAME" --namespace-token public; fi; if ! zrok2 agent status | grep -Fq "http://edge:8080"; then share_log=/tmp/finance-control-zrok-share.log; rm -f "$share_log"; zrok2 share public http://edge:8080 --name-selection "public:${ZROK2_SHARE_NAME}" --force-agent >"$share_log" 2>&1 & share_pid=$!; attempts=0; until zrok2 agent status | grep -Fq "http://edge:8080"; do attempts=$((attempts + 1)); if ! kill -0 "$share_pid" 2>/dev/null; then cat "$share_log" >&2; wait "$share_pid"; fi; if [ "$attempts" -ge 60 ]; then kill "$share_pid" 2>/dev/null || true; wait "$share_pid" 2>/dev/null || true; cat "$share_log" >&2; rm -f "$share_log"; echo "Timed out while creating the public share." >&2; exit 1; fi; sleep 1; done; kill "$share_pid" 2>/dev/null || true; wait "$share_pid" 2>/dev/null || true; rm -f "$share_log"; fi; zrok2 agent status | grep -Fq "http://edge:8080"; printf "public_tunnel=active\npublic_url=https://%s.shares.zrok.io\n" "$ZROK2_SHARE_NAME"'
        "$publicCompose up --detach --wait zrok-agent && $publicCompose exec -T zrok-agent sh -lc $(ConvertTo-ShellSingleQuoted -Value $initializeShare)"
    }
    'PublicStatus' {
        $publicStatus = 'set -eu; zrok2 agent status | grep -Fq "http://edge:8080"; printf "public_tunnel=active\npublic_url=https://%s.shares.zrok.io\n" "$ZROK2_SHARE_NAME"'
        "$publicCompose ps zrok-agent && $publicCompose exec -T zrok-agent sh -lc $(ConvertTo-ShellSingleQuoted -Value $publicStatus)"
    }
    'AutomationInfo' {
        "printf 'docker_compose='; docker compose version --short; " +
        "printf 'systemd='; if command -v systemctl >/dev/null 2>&1; then printf 'available\n'; else printf 'unavailable\n'; fi; " +
        "printf 'cron='; if command -v crontab >/dev/null 2>&1; then printf 'available\n'; else printf 'unavailable\n'; fi; " +
        "printf 'flock='; if command -v flock >/dev/null 2>&1; then printf 'available\n'; else printf 'unavailable\n'; fi"
    }
    'InstallAutoDeploy' {
        $verificationServicePath = '/run/finance-control-auto-update.service'
        $verificationTimerPath = '/run/finance-control-auto-update.timer'
        $installAutomation = "set -eu; " +
            "trap 'rm -f $autoUpdateUploadPath $autoUpdateServiceUploadPath $autoUpdateTimerUploadPath $verificationServicePath $verificationTimerPath' EXIT; " +
            "test -s $autoUpdateUploadPath; test -s $autoUpdateServiceUploadPath; test -s $autoUpdateTimerUploadPath; " +
            "sh -n $autoUpdateUploadPath; " +
            "install -d -o root -g root -m 755 deploy/zimaos; " +
            "install -o root -g root -m 700 $autoUpdateUploadPath deploy/zimaos/auto-update.sh; " +
            "install -o root -g root -m 644 $autoUpdateServiceUploadPath $verificationServicePath; " +
            "install -o root -g root -m 644 $autoUpdateTimerUploadPath $verificationTimerPath; " +
            "systemd-analyze verify $verificationServicePath $verificationTimerPath; " +
            "install -o root -g root -m 644 $verificationServicePath /etc/systemd/system/finance-control-auto-update.service; " +
            "install -o root -g root -m 644 $verificationTimerPath /etc/systemd/system/finance-control-auto-update.timer; " +
            "systemctl daemon-reload; " +
            "systemctl enable --now finance-control-auto-update.timer; " +
            "systemctl start finance-control-auto-update.service; " +
            "printf 'auto_deploy_installed=true\n'"
        $installAutomation
    }
    'AutoDeployStatus' {
        "printf 'timer_enabled='; systemctl is-enabled finance-control-auto-update.timer; " +
        "printf 'timer_active='; systemctl is-active finance-control-auto-update.timer; " +
        "printf 'last_result='; systemctl show finance-control-auto-update.service --property=Result --value; " +
        "printf 'last_exit_status='; systemctl show finance-control-auto-update.service --property=ExecMainStatus --value"
    }
    'RunAutoDeploy' {
        "systemctl start finance-control-auto-update.service; " +
        "printf 'last_result='; systemctl show finance-control-auto-update.service --property=Result --value; " +
        "printf 'last_exit_status='; systemctl show finance-control-auto-update.service --property=ExecMainStatus --value"
    }
    'AutoDeployLogs' {
        "journalctl --unit finance-control-auto-update.service --no-pager --lines $Tail"
    }
}

$remoteDirectory = '/DATA/AppData/finance-control'
$remoteBody = "cd $(ConvertTo-ShellSingleQuoted -Value $remoteDirectory) && $operation"
$remoteCommand = "sudo -S -p '' /bin/sh -lc $(ConvertTo-ShellSingleQuoted -Value $remoteBody)"
if ($Action -in @('SyncEnvironment', 'SyncEnvironmentOnly')) {
    $quotedUploadPath = ConvertTo-ShellSingleQuoted -Value $environmentUploadPath
    $remoteCommand = "test -s $quotedUploadPath && chmod 600 $quotedUploadPath && $remoteCommand"
}
if ($Action -eq 'SyncDeployment') {
    $quotedComposeUploadPath = ConvertTo-ShellSingleQuoted -Value $composeUploadPath
    $quotedCaddyUploadPath = ConvertTo-ShellSingleQuoted -Value $caddyUploadPath
    $remoteCommand = "test -s $quotedComposeUploadPath && test -s $quotedCaddyUploadPath && chmod 600 $quotedComposeUploadPath $quotedCaddyUploadPath && $remoteCommand"
}
if ($Action -eq 'InstallAutoDeploy') {
    $quotedAutoUpdateUploadPath = ConvertTo-ShellSingleQuoted -Value $autoUpdateUploadPath
    $quotedAutoUpdateServiceUploadPath = ConvertTo-ShellSingleQuoted -Value $autoUpdateServiceUploadPath
    $quotedAutoUpdateTimerUploadPath = ConvertTo-ShellSingleQuoted -Value $autoUpdateTimerUploadPath
    $remoteCommand = "test -s $quotedAutoUpdateUploadPath && test -s $quotedAutoUpdateServiceUploadPath && test -s $quotedAutoUpdateTimerUploadPath && chmod 600 $quotedAutoUpdateUploadPath $quotedAutoUpdateServiceUploadPath $quotedAutoUpdateTimerUploadPath && $remoteCommand"
}
$credential = Import-Clixml -LiteralPath $config.CredentialPath
if ($credential -isnot [System.Management.Automation.PSCredential]) {
    throw 'O arquivo de credencial não contém um PSCredential válido.'
}

$plainPassword = $credential.GetNetworkCredential().Password
$processInfo = [System.Diagnostics.ProcessStartInfo]::new()
$processInfo.FileName = 'ssh'
$processInfo.UseShellExecute = $false
$processInfo.RedirectStandardInput = $true
$processInfo.RedirectStandardOutput = $true
$processInfo.RedirectStandardError = $true
[void]$processInfo.ArgumentList.Add('-T')
[void]$processInfo.ArgumentList.Add('-i')
[void]$processInfo.ArgumentList.Add([string]$config.KeyPath)
[void]$processInfo.ArgumentList.Add('-o')
[void]$processInfo.ArgumentList.Add('BatchMode=yes')
[void]$processInfo.ArgumentList.Add('-o')
[void]$processInfo.ArgumentList.Add("UserKnownHostsFile=$($config.KnownHostsPath)")
[void]$processInfo.ArgumentList.Add('-o')
[void]$processInfo.ArgumentList.Add('StrictHostKeyChecking=accept-new')
[void]$processInfo.ArgumentList.Add('-o')
[void]$processInfo.ArgumentList.Add('ConnectTimeout=10')
[void]$processInfo.ArgumentList.Add("$($config.SshUser)@$($config.ServerAddress)")
[void]$processInfo.ArgumentList.Add($remoteCommand)

try {
    $process = [System.Diagnostics.Process]::Start($processInfo)
    $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
    $standardErrorTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.WriteLine($plainPassword)
    $process.StandardInput.Close()
    $process.WaitForExit()
    $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
    $standardError = $standardErrorTask.GetAwaiter().GetResult()

    if (-not [string]::IsNullOrWhiteSpace($standardOutput)) {
        Write-Output $standardOutput.TrimEnd()
    }
    if (-not [string]::IsNullOrWhiteSpace($standardError)) {
        [Console]::Error.WriteLine($standardError.TrimEnd())
    }
    if ($process.ExitCode -ne 0) {
        throw "A operação remota falhou com código $($process.ExitCode)."
    }
}
finally {
    $plainPassword = $null
    $credential = $null
}
