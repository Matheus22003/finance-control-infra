[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$ServerAddress = '192.168.3.9',

    [Parameter()]
    [ValidatePattern('^[a-z_][a-z0-9_-]*$')]
    [string]$SshUser = 'jonas',

    [Parameter()]
    [switch]$SkipCredential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-PrivateDirectoryAcl {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $systemIdentity = 'NT AUTHORITY\SYSTEM'
    $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $allow = [System.Security.AccessControl.AccessControlType]::Allow

    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $currentIdentity,
        $fullControl,
        $inheritanceFlags,
        $propagationFlags,
        $allow
    ))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $systemIdentity,
        $fullControl,
        $inheritanceFlags,
        $propagationFlags,
        $allow
    ))

    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Read-SudoCredential {
    param(
        [Parameter(Mandatory)]
        [string]$UserName
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'Finance Control — credencial do ZimaOS'
    $form.Size = [System.Drawing.Size]::new(460, 220)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    $description = [System.Windows.Forms.Label]::new()
    $description.Location = [System.Drawing.Point]::new(24, 20)
    $description.Size = [System.Drawing.Size]::new(400, 48)
    $description.Text = "Digite a senha sudo do usuário '$UserName'." + [Environment]::NewLine + 'Ela será criptografada pelo Windows DPAPI.'

    $passwordBox = [System.Windows.Forms.TextBox]::new()
    $passwordBox.Location = [System.Drawing.Point]::new(24, 78)
    $passwordBox.Size = [System.Drawing.Size]::new(400, 28)
    $passwordBox.UseSystemPasswordChar = $true

    $okButton = [System.Windows.Forms.Button]::new()
    $okButton.Location = [System.Drawing.Point]::new(248, 126)
    $okButton.Size = [System.Drawing.Size]::new(84, 30)
    $okButton.Text = 'Salvar'
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $cancelButton = [System.Windows.Forms.Button]::new()
    $cancelButton.Location = [System.Drawing.Point]::new(340, 126)
    $cancelButton.Size = [System.Drawing.Size]::new(84, 30)
    $cancelButton.Text = 'Cancelar'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton
    [void]$form.Controls.AddRange(@($description, $passwordBox, $okButton, $cancelButton))
    [void]$form.Add_Shown({
        $form.Activate()
        [void]$passwordBox.Focus()
    })

    try {
        if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            throw 'A captura da credencial foi cancelada.'
        }
        if ([string]::IsNullOrEmpty($passwordBox.Text)) {
            throw 'A senha não pode ficar vazia.'
        }

        $securePassword = ConvertTo-SecureString -String $passwordBox.Text -AsPlainText -Force
        return [System.Management.Automation.PSCredential]::new($UserName, $securePassword)
    }
    finally {
        $passwordBox.Clear()
        $form.Dispose()
    }
}

function New-PasswordlessSshKey {
    param(
        [Parameter(Mandatory)]
        [string]$KeyPath
    )

    if (Test-Path -LiteralPath $KeyPath -PathType Leaf) {
        return
    }

    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = 'ssh-keygen'
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    [void]$processInfo.ArgumentList.Add('-q')
    [void]$processInfo.ArgumentList.Add('-t')
    [void]$processInfo.ArgumentList.Add('ed25519')
    [void]$processInfo.ArgumentList.Add('-f')
    [void]$processInfo.ArgumentList.Add($KeyPath)
    [void]$processInfo.ArgumentList.Add('-N')
    [void]$processInfo.ArgumentList.Add('')
    [void]$processInfo.ArgumentList.Add('-C')
    [void]$processInfo.ArgumentList.Add('finance-control-zimaos-deploy')

    $process = [System.Diagnostics.Process]::Start($processInfo)
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        throw "ssh-keygen falhou. $standardOutput $standardError"
    }
}

$userProfilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
$vaultDirectory = Join-Path $userProfilePath '.finance-control'
$sshDirectory = Join-Path $vaultDirectory 'ssh'
$credentialDirectory = Join-Path $vaultDirectory 'credentials'
$keyPath = Join-Path $sshDirectory 'zimaos_ed25519'
$credentialPath = Join-Path $credentialDirectory 'zimaos-sudo.xml'
$knownHostsPath = Join-Path $sshDirectory 'known_hosts'
$configPath = Join-Path $vaultDirectory 'zimaos-access.json'

foreach ($directory in @($vaultDirectory, $sshDirectory, $credentialDirectory)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory)
        Set-PrivateDirectoryAcl -Path $directory
    }
}

New-PasswordlessSshKey -KeyPath $keyPath

$config = [ordered]@{
    ServerAddress = $ServerAddress
    SshUser = $SshUser
    KeyPath = $keyPath
    CredentialPath = $credentialPath
    KnownHostsPath = $knownHostsPath
}
$config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding utf8

if (-not $SkipCredential) {
    $credential = Read-SudoCredential -UserName $SshUser
    $credential | Export-Clixml -LiteralPath $credentialPath -Force
    Write-Output 'Credencial sudo armazenada com criptografia DPAPI.'
}

Write-Output "Configuração: $configPath"
Write-Output "Chave pública: $keyPath.pub"
Write-Output "Credencial: $credentialPath"
