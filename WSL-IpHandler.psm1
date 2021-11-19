$ErrorActionPreference = 'Stop'

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'ArgumentsCompleters.ps1' -Resolve) | Out-Null
. (Join-Path $PSScriptRoot 'WindowsCommandsUTF16Converters.ps1' -Resolve) | Out-Null
. (Join-Path $PSScriptRoot 'FunctionsWslConfig.ps1' -Resolve) | Out-Null
. (Join-Path $PSScriptRoot 'FunctionsHostsFile.ps1' -Resolve) | Out-Null
. (Join-Path $PSScriptRoot 'FunctionsPrivateData.ps1' -Resolve) | Out-Null

function Install-WslIpHandler {
    <#
    .SYNOPSIS
    Installs WSL IP Addresses handler into a specified WSL Instance

    .DESCRIPTION
    Installs WSL IP Addresses handler into a specified WSL Instance optionally with specific IP address within certain Subnet.

    There are 2 modes of operations:
      - Dynamic
      - Static

    To operate in the Dynamic Mode the only required parameter is WslInstanceName.
    In this mode the following will happen:
    @ specified WSL instance's file system:
        a) a new script will be created: /usr/local/bin/wsl-iphandler.sh
        b) a new startup script created: /etc/profile.d/run-wsl-iphandler.sh. This actually start script in a).
        c) sudo permission will be created at: /etc/sudoers.d/wsl-iphandler to enable passwordless start of script a).
        d) /etc/wsl.conf will be modified to store Host names / IP offset
    @ Windows host file system:
        a) New [ip_offsets] section in ~/.wslconfig will be created to store ip_offset for a specified WSL Instance. This offset will be used by bash startup script to create an IP Address at start time.
        b) When bash startup script on WSL instance side is executed it will create (if not present already) a record binding its current IP address to it's host name (which is set by WslHostName parameter)

    To operate in Static Mode at the very least one parameter has to be specified: GatewayIpAddress.
    In this mode the following will happen:
    @ specified WSL instance's file system:
        a) the same scripts will be created as in Static Mode.
        b) /etc/wsl.conf will be modified to store Host names / IP Addresses
           Note that if parameter WslInstanceIpAddress is not specified a first available IP address will be selected and will be used until the WSL-IpHandler is Uninstalled. Otherwise specified IP address will be used.
    @ Windows host file system:
        a) New [static_ips] section in ~/.wslconfig will be created to store ip address for a specified WSL Instance. This ip address will be used by bash startup script to bind this IP Address at start time to eth0 interface.
        b) The same as for Static Mode.
        c) Powershell profile file (CurrentUserAllHosts) will be modified: This module will be imported and an alias `wsl` to Invoke-WslExe will be created).

    .PARAMETER WslInstanceName
    Required. Name of the WSL Instance as listed by `wsl.exe -l` command

    .PARAMETER GatewayIpAddress
    Optional. IP v4 Address of the gateway. This IP Address will appear in properties of Network Adapter (vEthernet (WSL)).

    .PARAMETER PrefixLength
    Optional. Defaults to 24. Length of WSL Subnet.

    .PARAMETER DNSServerList
    Optional. Defaults to GatewayIpAddress.

    .PARAMETER WslInstanceIpAddress
    Optional. Static IP Address of WSL Instance. It will be assigned to the instance when it starts. This address will be also added to Windows HOSTS file so that a given WSL Instance can be accessed via its WSLHostName.

    .PARAMETER WslHostName
    Optional. Defaults to WslInstanceName. The name to use to access the WSL Instance on WSL SubNet. This name together with WslInstanceIpAddress are added to Windows HOSTS file.

    .PARAMETER WindowsHostName
    Optional. Defaults to `windows`. Name of Windows Host that can be used to access windows host from WSL Instance. This will be added to /etc/hosts on WSL Instance system.

    .PARAMETER DontModifyPsProfile
    Optional. If specifies will not modify Powershell Profile (default profile: CurrentUserAllHosts). Otherwise profile will be modified to Import this module and create an Alias `wsl` which will transparently pass through any and all paramaters to `wsl.exe` and, if necessary, initialize beforehand WSL Hyper-V network adapter to allow usage of Static IP Addresses. Will be ignored in Dynamic Mode.

    .PARAMETER UseScheduledTaskOnUserLogOn
    When present - a new Scheduled Task will be created: WSL-IpHandlerTask. It will be triggered at user LogOn. This task execution is equivalent to running Set-WslNetworkAdapter command. It will create WSL Hyper-V Network Adapter when user Logs On.

    .PARAMETER AnyUserLogOn
    When this parameter is present - The Scheduled Task will be set to run when any user logs on. Otherwise (default behavior) - the task will run only when current user (who executed Install-WslIpHandler command) logs on.

    .PARAMETER BackupWslConfig
    Optional. If specified will create backup of ~/.wslconfig before modifications.

    .EXAMPLE
    ------------------------------------------------------------------------------------------------
    Install-WslIpHandler -WslInstanceName Ubuntu

    Will install WSL IP Handler in Dynamic Mode. IP address of WSL Instance will be set when the instance starts and address will be based on whatever SubNet will be set by Windows system.
    This IP address might be different after Windows restarts as it depends on what Gateway IP address Windows assigns to vEthernet (WSL) network adapter.
    The actual IP address of WSL Instance can always be checked with command: `hostname -I`.

    ------------------------------------------------------------------------------------------------
    Install-WslIpHandler -WslInstanceName Ubuntu -GatewayIpAddress 172.16.0.1

    Will install WSL IP Handler in Static Mode. IP address of WSL Instance will be set automatically to the first available in SubNet 172.16.0.0/24, excluding Gateway IP address.
    From WSL Instance shell prompt Windows Host will be accessible at 172.16.0.1 or simply as `windows`, i.e. two below commands will yield the same result:
    ping 172.16.0.1
    ping windows

    ------------------------------------------------------------------------------------------------
    Install-WslIpHandler -WslInstanceName Ubuntu -GatewayIpAddress 172.16.0.1 -WslInstanceIpAddress 172.16.0.2

    Will install WSL IP Handler in Static Mode. IP address of WSL Instance will be set to 172.16.0.2. This IP Address will stay the same as long as wsl instance is started through this module's alias `wsl` (which shadows `wsl` command) and until Uninstall-WslIpHandler is executed.

    .NOTES
    Use Powershell command prompt to launch WSL Instance(s) in Static Mode, especially after system restart.
    Executing `wsl.exe` from within Windows cmd.exe after Windows restarts will allow Windows to take control over WSL network setup and will break Static IP functionality.

    To mannerly take control over WSL Network setup use this module's command: Set-WslNetworkConfig
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [Parameter(ParameterSetName = 'Dynamic')]
        [Parameter(ParameterSetName = 'Static')]
        [Alias('Name')]
        [string]$WslInstanceName,

        [Parameter(Mandatory, ParameterSetName = 'Static')][Alias('Gateway')]
        [ipaddress]$GatewayIpAddress,

        [Parameter(ParameterSetName = 'Static')][Alias('Prefix')]
        [int]$PrefixLength = 24,

        [Parameter(ParameterSetName = 'Static')][Alias('DNS')]
        [string]$DNSServerList, # String with Comma separated ipaddresses/hosts

        [Parameter(ParameterSetName = 'Static')][Alias('IpAddress')]
        [ipaddress]$WslInstanceIpAddress,

        [ValidateNotNullOrEmpty()]
        [string]$WslHostName = $WslInstanceName,

        [string]$WindowsHostName = 'windows',

        [Parameter(ParameterSetName = 'Static')]
        [switch]$DontModifyPsProfile,

        [Parameter(ParameterSetName = 'Static')]
        [switch]$UseScheduledTaskOnUserLogOn,

        [Parameter(ParameterSetName = 'Static')]
        [switch]$AnyUserLogOn,

        [switch]$BackupWslConfig,

        [Parameter()]
        [string[]]$DynamicAdapters = @('Ethernet', 'Default Switch')
    )


    Write-Host "PowerShell installing WSL-IpHandler to $WslInstanceName..."
    #region PS Autorun
    # Get Path to PS Script that injects (if needed) IP-host to windows hosts on every WSL launch
    $WinHostsEditScript = Get-SourcePath 'WinHostsEdit'
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$WinHostsEditScript='$WinHostsEditScript'"
    #endregion PS Autorun

    #region Bash Installation Script Path
    $BashInstallScript = Get-SourcePath 'BashInstall'
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$BashInstallScript='$BashInstallScript'"
    #endregion Bash Installation Script Path

    #region WSL Autorun Script Path
    # Get Path to bash script that assigns IP to wsl instance and launches PS autorun script
    $BashAutorunScriptSource = Get-SourcePath 'BashAutorun'
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$BashAutorunScriptSource='$BashAutorunScriptSource'"
    $BashAutorunScriptTarget = Get-ScriptLocation 'BashAutorun'
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$BashAutorunScriptTarget='$BashAutorunScriptTarget'"
    #endregion WSL Autorun Script Path

    #region Save Network Parameters to .wslconfig and Setup Network Adapters
    $configModified = $false

    Set-WslConfigValue -SectionName (Get-NetworkSectionName) -KeyName (Get-WindowsHostNameKeyName) -Value $WindowsHostName -Modified ([ref]$configModified)

    if ($null -ne $GatewayIpAddress) {
        Set-WslNetworkConfig -GatewayIpAddress $GatewayIpAddress -PrefixLength $PrefixLength -DNSServerList $DNSServerList -Modified ([ref]$configModified)

        $setParams = @{
            GatewayIpAddress = $GatewayIpAddress
            PrefixLength     = $PrefixLength
            DNSServerList    = $DNSServerList
            DynamicAdapters  = $DynamicAdapters
        }
        Set-WslNetworkAdapter @setParams

        Write-Verbose "Setting Static IP Address: $($WslInstanceIpAddress.IPAddressToString) for $WslInstanceName."
        Set-WslInstanceStaticIpAddress -WslInstanceName $WslInstanceName -GatewayIpAddress $GatewayIpAddress -PrefixLength $PrefixLength -WslInstanceIpAddress $WslInstanceIpAddress.IPAddressToString -Modified ([ref]$configModified)

        $WslHostIpOrOffset = $WslInstanceIpAddress.IPAddressToString

        if ($UseScheduledTaskOnUserLogOn) {
            Write-Verbose 'Registering WSL-IpHandler scheduled task...'
            Set-WslScheduledTask @setParams
        }
    }
    else {
        $WslIpOffset = Get-WslIpOffset $WslInstanceName
        Write-Verbose "Setting Automatic IP Offset: $WslIpOffset for $WslInstanceName."
        Set-WslIpOffset $WslInstanceName $WslIpOffset -Modified ([ref]$configModified)

        $WslHostIpOrOffset = $WslIpOffset
    }

    if ($configModified) {
        Write-Verbose "Saving Configuration in .wslconfig $($BackupWslConfig ? 'with Backup ' : '')..."
        Write-WslConfig -Backup:$BackupWslConfig
    }
    #endregion Save Network Parameters to .wslconfig and Setup Network Adapters

    #region Run Bash Installation Script
    $BashInstallScriptWslPath = '$(wslpath "' + "$BashInstallScript" + '")'
    $BashInstallParams = @("`"$BashAutorunScriptSource`"", "$BashAutorunScriptTarget",
        "`"$WinHostsEditScript`"", "$WindowsHostName", "$WslHostName", "$WslHostIpOrOffset"
    )
    Write-Verbose "Running Bash WSL installation script: $BashInstallScript"

    $debug_var = if ($DebugPreference -gt 0) { 'DEBUG=1' } else { '' }
    $verbose_var = if ($VerbosePreference -gt 0) { 'VERBOSE=1' } else { '' }

    $bashInstallScriptOutput = wsl.exe -d $WslInstanceName sudo -E env '"PATH=$PATH"' $debug_var $verbose_var bash $BashInstallScriptWslPath @BashInstallParams

    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Head and tail from Bash Installation Script Output:"
    Write-Debug "$($bashInstallScriptOutput | Select-Object -First 5)"
    Write-Debug "$($bashInstallScriptOutput | Select-Object -Last 5)"

    if ($bashInstallScriptOutput -and ($bashInstallScriptOutput | Where-Object { $_.StartsWith('[Error') } | Measure-Object).Count -gt 0) {
        Write-Error "Error(s) occurred while running Bash Installation script: $BashInstallScriptWslPath with parameters: $($BashInstallParams | Out-String)`n$($bashInstallScriptOutput -join "`n")"
        return
    }
    #endregion Run Bash Installation Script

    #region Set Content to Powershell Profile
    if ($PSCmdlet.ParameterSetName -eq 'Static' -and -not $DontModifyPsProfile) {
        Write-Verbose "Modifying Powershell Profile: $($profile.CurrentUserAllHosts) ..."
        Set-ProfileContent
    }
    #endregion Set Content to Powershell Profile

    #region Restart WSL Instance
    Write-Verbose "Terminating running instances of $WslInstanceName ..."
    wsl.exe -t $WslInstanceName
    #endregion Restart WSL Instance

    #region Test IP and host Assignments
    try {
        Write-Verbose "Testing Activation of WSL IP Handler on $WslInstanceName ..."
        Test-WslInstallation -WslInstanceName $WslInstanceName -WslHostName $WslHostName -WindowsHostName $WindowsHostName
    }
    catch {
        Write-Host "PowerShell finished installation of WSL-IpHandler to $WslInstanceName with Errors:"
        Write-Debug "${fn} ScriptStackTrace: $($_.ScriptStackTrace)"
        Write-Host "$_" -ForegroundColor Red
        return
    }
    finally {
        Write-Verbose 'Finished Testing Activation of WSL IP Handler.'
        wsl.exe -t $WslInstanceName
    }

    #endregion Test IP and host Assignments

    Write-Host "PowerShell successfully installed WSL-IpHandler to $WslInstanceName."
}

function Uninstall-WslIpHandler {
    <#
    .SYNOPSIS
    Uninstall WSL IP Handler from WSL Instance

    .DESCRIPTION
    Uninstall WSL IP Handler from WSL Instance with the specified name.

    .PARAMETER WslInstanceName
    Required. Name of the WSL Instance to Uninstall WSL Handler from (should be one of the names listed by `wsl.exe -l` command).

    .PARAMETER BackupWslConfig
    Optional. If specified ~/.wslconfig file will backed up before modifications.

    .EXAMPLE
    Uninstall-WslIpHandler -WslInstanceName Ubuntu

    .NOTES
    When the instance specified in WslInstanceName parameter is the LAST one (there are no other instances for which static IP address has been assigned) This command will also reset
    #>
    [CmdletBinding()]
    param (
        [AllowNull()][AllowEmptyString()]
        [Alias('Name')]
        [string]$WslInstanceName,

        [switch]$BackupWslConfig
    )


    Write-Host "PowerShell Uninstalling WSL-IpHandler from $WslInstanceName..."
    #region Bash UnInstallation Script Path
    $BashUninstallScript = Get-SourcePath 'BashUninstall'
    #endregion Bash InInstallation Script Path

    #region WSL Autorun
    # Get Path to bash script that assigns IP to wsl instance and launches PS autorun script
    $BashAutorunScriptName = Split-Path -Leaf (Get-SourcePath 'BashAutorun')
    $BashAutorunScriptTarget = Get-ScriptLocation 'BashAutorun'
    #endregion WSL Autorun

    #region Remove Bash Autorun
    $BashUninstallScriptWslPath = '$(wslpath "' + "$BashUninstallScript" + '")'
    $BashUninstallParams = "$BashAutorunScriptName", "$BashAutorunScriptTarget"

    Write-Verbose "Running Bash WSL Uninstall script $BashUninstallScript"
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$DebugPreference=$DebugPreference"
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$VerbosePreference=$VerbosePreference"

    $debug_var = if ($DebugPreference -gt 0) { 'DEBUG=1' } else { '' }
    $verbose_var = if ($VerbosePreference -gt 0) { 'VERBOSE=1' } else { '' }

    $bashUninstallScriptOutput = wsl.exe -d $WslInstanceName sudo -E env '"PATH=$PATH"' $debug_var $verbose_var bash $BashUninstallScriptWslPath @BashUninstallParams

    if ($bashUninstallScriptOutput -and ($bashUninstallScriptOutput | Where-Object { $_.StartsWith('[Error') } | Measure-Object).Count -gt 0) {
        Write-Debug "Bash Uninstall Script returned:`n$bashUninstallScriptOutput"
    }

    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Removed Bash Autorun scripts."
    #endregion Remove Bash Autorun

    #region Restart WSL Instance
    wsl.exe -t $WslInstanceName
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Restarted $WslInstanceName"
    #endregion Restart WSL Instance

    #region Remove WSL Instance Static IP from .wslconfig
    $wslconfigModified = $false
    Remove-WslInstanceStaticIpAddress -WslInstanceName $WslInstanceName -Modified ([ref]$wslconfigModified)
    #endregion Remove WSL Instance Static IP from .wslconfig

    #region Remove WSL Instance IP Offset from .wslconfig
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Removing IP address offset for $WslInstanceName from .wslconfig..."
    Remove-WslConfigValue (Get-WslIpOffsetSectionName) $WslInstanceName -Modified ([ref]$wslconfigModified)
    #endregion Remove WSL Instance IP Offset from .wslconfig

    #region Remove WSL Network Configuration from .wslconfig
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Removing WSL Network Configuration for $WslInstanceName ..."
    Remove-WslNetworkConfig -Modified ([ref]$wslconfigModified)
    #endregion Remove WSL Network Configuration from .wslconfig

    #region Remove WSL Instance IP from windows hosts file
    $hostsModified = $false
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Removing record for $WslInstanceName from Windows Hosts ..."
    $content = (Get-HostsFileContent)
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Removing Host: $WslInstanceName from $($content.Count) Windows Hosts records ..."
    $content = Remove-HostFromRecords -Records $content -HostName $WslInstanceName -Modified ([ref]$hostsModified)
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Setting Windows Hosts file with $($content.Count) records ..."
    #endregion Remove WSL Instance IP from windows hosts file

    #region Save Modified .wslconfig and hosts Files
    if ($wslconfigModified) { Write-WslConfig -Backup:$BackupWslConfig }
    if ($hostsModified) { Write-HostsFileContent -Records $content }
    #endregion Save Modified .wslconfig and hosts Files

    #region Remove Content from Powershell Profile and ScheduledTask
    # Remove Profile Content if there are no more Static IP assignments
    if ((Get-WslConfigSectionCount (Get-StaticIpAddressesSectionName)) -le 0) {
        Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Removing Powershell Profile Modifications ..."
        Remove-ProfileContent
        Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Removing Scheduled Task ..."
        Remove-WslScheduledTask
    }
    #endregion Remove Content from Powershell Profile and ScheduledTask

    Write-Host "PowerShell successfully uninstalled WSL-IpHandler from $WslInstanceName!"
}

function Set-ProfileContent {
    <#
    .SYNOPSIS
    Modifies Powershell profile to set alias `wsl` -> Invoke-WslExe

    .DESCRIPTION
    Modifies Powershell profile file (by default CurrentUserAllHosts) to set alias `wsl` -> Invoke-WslExe.

    .PARAMETER ProfilePath
    Optional. Path to Powershell profile. Defaults to value of $Profile.CurrentUserAllhosts.

    .EXAMPLE
    Set-ProfileContent

    Modifies the default location for CurrentUserAllhosts.

    ------------------------------------------------------------------------------------------------
    Set-ProfileContent $Profile.AllUsersAllHosts

    Modifies the system profile file.

    .NOTES
    Having `wsl` alias in profile allows to automatically enable WSL Network Adapter with manually setting it up before launching WSL instance.
    #>
    [CmdletBinding()]
    param($ProfilePath = $profile.CurrentUserAllHosts)

    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: ProfilePath: $ProfilePath"

    $handlerContent = Get-ProfileContent

    $modulePath = Split-Path $MyInvocation.MyCommand.Module.Path
    $modulesFolder = Split-Path (Split-Path $modulePath)

    # If module was not installed in a standard location replace module name with module's path
    if (-not $Env:PSModulePath.contains($modulesFolder, 'OrdinalIgnoreCase')) {
        $handlerContent = $handlerContent -replace 'Import-Module WSL-IpHandler', "Import-Module '$modulePath'"
    }

    $content = (Get-Content -Path $ProfilePath -ErrorAction SilentlyContinue) ?? @()

    $anyHandlerContentMissing = $false
    foreach ($line in $handlerContent) {
        if ($line -notin $content) { $anyHandlerContentMissing = $true; break }
    }

    if ($anyHandlerContentMissing) {
        # Safeguard to avoid duplication in case user manually edits profile file
        $content = $content | Where-Object { $handlerContent -notcontains $_ }
        $content += $handlerContent
        Set-Content -Path $ProfilePath -Value $content -Force
        Write-Warning "Powershell profile was modified: $ProfilePath.`nThe changes will take effect after Powershell session is restarted!"
        # . $ProfilePath  # !!! DONT DO THAT -> IT Removes ALL Sourced functions (i.e. '. File.ps1')
    }
}

function Remove-ProfileContent {
    <#
    .SYNOPSIS
    Removes modifications made by Set-ProfileContent command.

    .DESCRIPTION
    Removes modifications made by Set-ProfileContent command.

    .PARAMETER ProfilePath
    Optional. Path to Powershell profile. Defaults to value of $Profile.CurrentUserAllhosts.
    #>
    [CmdletBinding()]
    param($ProfilePath = $Profile.CurrentUserAllHosts)


    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: ProfilePath: $ProfilePath"

    $handlerContent = Get-ProfileContent

    $modulePath = $MyInvocation.MyCommand.Module.Path
    $modulesFolder = Split-Path (Split-Path $modulePath)

    # If module was not installed in a standard location replace module name with module's path
    if (-not $Env:PSModulePath.contains($modulesFolder, 'OrdinalIgnoreCase')) {
        Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$moduleFolder: $moduleFolder not in `$Env:PSModulePath"
        $handlerContent = $handlerContent -replace 'Import-Module WSL-IpHandler', "Import-Module '$modulePath'"
    }

    $content = (Get-Content -Path $ProfilePath -ErrorAction SilentlyContinue) ?? @()
    if ($content) {
        $content = $content | Where-Object { $handlerContent -notcontains $_ }
        # $content = (($content -join "`n") -replace ($handlerContent -join "`n")) -split "`n"
        Set-Content -Path $ProfilePath -Value $content -Force
    }
}

function Set-WslInstanceStaticIpAddress {
    <#
    .SYNOPSIS
    Sets Static IP Address for the specified WSL Instance.

    .DESCRIPTION
    Sets Static IP Address for the specified WSL Instance. Given WslInstanceIpAddress will be validated against specified GatewayIpAddress and PrefixLength, error will be thrown if it is incorrect.

    .PARAMETER WslInstanceName
    Required. Name of WSL Instance as listed by `wsl.exe -l` command.

    .PARAMETER GatewayIpAddress
    Required. Gateway IP v4 Address of vEthernet (WSL) network adapter.

    .PARAMETER PrefixLength
    Optional. Defaults to 24. WSL network SubNet Length.

    .PARAMETER WslInstanceIpAddress
    Required. IP v4 Address to assign to WSL Instance.

    .PARAMETER Modified
    Optional. Reference to boolean variable. Will be set to True if given parameters will lead to change of existing settings. If this parameter is specified - any occuring changes will have to be saved with Write-WslConfig command. This parameter cannot be used together with BackupWslConfig parameter.

    .PARAMETER BackupWslConfig
    Optional. If given - original version of .wslconfig file will be saved as backup. This parameter cannot be used together with Modified parameter.

    .EXAMPLE
    Set-WslInstanceStaticIpAddress -WslInstanceName Ubuntu -GatewayIpAddress 172.16.0.1 -WslInstanceIpAddress 172.16.0.11

    Will set Ubuntu WSL Instance Static IP address to 172.16.0.11

    .NOTES
    This command only checks against specified Gateway IP Address, not actual one (even if it exists). Any changes made will require restart of WSL instance for them to take effect.
    #>
    param (
        [Parameter(Mandatory)]
        [Alias('Name')]
        [string]$WslInstanceName,

        [Parameter(Mandatory)][Alias('Gateway')]
        [ipaddress]$GatewayIpAddress,

        [Alias('Prefix')]
        [int]$PrefixLength = 24,

        [Alias('IpAddress')]
        [ipaddress]$WslInstanceIpAddress,

        [Parameter(Mandatory, ParameterSetName = 'SaveExternally')]
        [ref]$Modified,

        [Parameter(ParameterSetName = 'SaveHere')]
        [switch]$BackupWslConfig
    )


    if ($PSCmdlet.ParameterSetName -eq 'SaveHere') {
        $localModified = $false
        $Modified = [ref]$localModified
    }

    $sectionName = Get-StaticIpAddressesSectionName

    if ($null -eq $WslInstanceIpAddress) {
        $existingIp = Get-WslConfigValue -SectionName $sectionName -KeyName $WslInstanceName -DefaultValue $null -Modified $Modified
        if ($existingIp) {
            Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$WslInstanceIpAddress is `$null. Using existing assignment:  for $WslInstanceName = $existingIp"
            $WslInstanceIpAddress = $existingIp
        }
        else {
            Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$WslInstanceIpAddress is `$null. Getting Available Static Ip Address."
            $WslInstanceIpAddress = Get-AvailableStaticIpAddress $GatewayIpAddress
        }
    }

    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$WslInstanceName=$WslInstanceName `$GatewayIpAddress=$GatewayIpAddress `$PrefixLength=$PrefixLength `$WslInstanceIpAddress=$($WslInstanceIpAddress ? $WslInstanceIpAddress.IPAddressToString : "`$null")"

    $null = Test-ValidStaticIpAddress -IpAddress $WslInstanceIpAddress -GatewayIpAddress $GatewayIpAddress -PrefixLength $PrefixLength


    Set-WslConfigValue $sectionName $WslInstanceName $WslInstanceIpAddress.IPAddressToString -Modified $Modified -UniqueValue

    if ($PSCmdlet.ParameterSetName -eq 'SaveHere' -and $localModified) {
        Write-WslConfig -Backup:$BackupWslConfig
    }
}

function Remove-WslInstanceStaticIpAddress {
    <#
    .SYNOPSIS
    Removes Static IP Address for the specified WSL Instance from .wslconfig.

    .DESCRIPTION
    Removes Static IP Address for the specified WSL Instance from .wslconfig.

    .PARAMETER WslInstanceName
    Required. Name of WSL Instance as listed by `wsl.exe -l` command.

    .PARAMETER Modified
    Optional. Reference to boolean variable. Will be set to True if given parameters will lead to change of existing settings. If this parameter is specified - any occuring changes will have to be saved with Write-WslConfig command. This parameter cannot be used together with BackupWslConfig parameter.

    .PARAMETER BackupWslConfig
    Optional. If given - original version of .wslconfig file will be saved as backup. This parameter cannot be used together with Modified parameter.

    .EXAMPLE
    Remove-WslInstanceStaticIpAddress -WslInstanceName Ubuntu

    Will remove Static IP address for Ubuntu WSL Instance.
    #>
    param (
        [Parameter(Mandatory)]
        [Alias('Name')]
        [string]$WslInstanceName,

        [Parameter(Mandatory, ParameterSetName = 'SaveExternally')]
        [ref]$Modified,

        [Parameter(ParameterSetName = 'SaveHere')]
        [switch]$BackupWslConfig
    )

    if ($PSCmdlet.ParameterSetName -eq 'SaveHere') {
        $localModified = $false
        $Modified = [ref]$localModified
    }

    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$WslInstanceName=$WslInstanceName"
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Before Calling Remove-WslConfigValue `$Modified=$($Modified.Value)"

    Remove-WslConfigValue (Get-StaticIpAddressesSectionName) $WslInstanceName -Modified $Modified
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: After Calling Remove-WslConfigValue `$Modified=$($Modified.Value)"

    if ($PSCmdlet.ParameterSetName -eq 'SaveHere' -and $localModified) {
        Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Calling Write-WslConfig -Backup:$BackupWslConfig"
        Write-WslConfig -Backup:$BackupWslConfig
    }
}

function Set-WslNetworkConfig {
    <#
    .SYNOPSIS
    Sets WSL Network Adapter parameters, which are stored in .wslconfig file

    .DESCRIPTION
    Sets WSL Network Adapter parameters, which are stored in .wslconfig file

    .PARAMETER GatewayIpAddress
    Required. Gateway IP v4 Address of vEthernet (WSL) network adapter.

    .PARAMETER PrefixLength
    Optional. Defaults to 24. WSL network SubNet Length.

    .PARAMETER DNSServerList
    Optional. Defaults to GatewayIpAddress. DNS servers to set for the network adapater. The list is a string with comma separated servers.

    .PARAMETER Modified
    Optional. Reference to boolean variable. Will be set to True if given parameters will lead to change of existing settings. If this parameter is specified - any occuring changes will have to be saved with Write-WslConfig command. This parameter cannot be used together with BackupWslConfig parameter.

    .PARAMETER BackupWslConfig
    Optional. If given - original version of .wslconfig file will be saved as backup. This parameter cannot be used together with Modified parameter.

    .EXAMPLE
    Set-WslNetworkConfig -GatewayIpAddress 172.16.0.1 -BackupWslConfig

    Will set Gateway IP Address to 172.16.0.1, SubNet length to 24 and DNS Servers to 172.16.0.1.
    Will save the changes in .wslconfig and create backup version of the file.

    .NOTES
    This command only changes parameters of the network adapter in .wslconfig file, without any effect on active adapter (if it exists). To apply these settings use command Set-WslNetworkAdapter.
    #>
    param (
        [Parameter(Mandatory)][Alias('Gateway')]
        [ipaddress]$GatewayIpAddress,

        [Alias('Prefix')]
        [int]$PrefixLength = 24,

        [Alias('DNS')]
        [string]$DNSServerList, # String with Comma separated ipaddresses/hosts

        [Parameter(Mandatory, ParameterSetName = 'SaveExternally')]
        [ref]$Modified,

        [Parameter(ParameterSetName = 'SaveHere')]
        [switch]$BackupWslConfig
    )


    if ($PSCmdlet.ParameterSetName -eq 'SaveHere') {
        $localModified = $false
        $Modified = [ref]$localModified
    }

    $DNSServerList = $DNSServerList ? $DNSServerList : $GatewayIpAddress
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Seting Wsl Network Parameters: GatewayIpAddress=$GatewayIpAddress PrefixLength=$PrefixLength DNSServerList=$DNSServerList"

    Set-WslConfigValue (Get-NetworkSectionName) (Get-GatewayIpAddressKeyName) $GatewayIpAddress.IPAddressToString -Modified $Modified

    Set-WslConfigValue (Get-NetworkSectionName) (Get-PrefixLengthKeyName) $PrefixLength -Modified $Modified

    Set-WslConfigValue (Get-NetworkSectionName) (Get-DnsServersKeyName) $DNSServerList -Modified $Modified

    if ($PSCmdlet.ParameterSetName -eq 'SaveHere' -and $localModified) {
        Write-WslConfig -Backup:$BackupWslConfig
    }
}

function Remove-WslNetworkConfig {
    <#
    .SYNOPSIS
    Removes all WSL network adapter parameters that are set by Set-WslNetworkConfig command.

    .DESCRIPTION
    Removes all WSL network adapter parameters that are set by Set-WslNetworkConfig command: -GatewayIpAddress, -PrefixLength, -DNSServerList. If there are any static ip address assignments in a .wslconfig file there will be a warning and command will have no effect. To override this limitation use -Force parameter.

    .PARAMETER Modified
    Optional. Reference to boolean variable. Will be set to True if given parameters will lead to change of existing settings. If this parameter is specified - any occuring changes will have to be saved with Write-WslConfig command. This parameter cannot be used together with BackupWslConfig parameter.

    .PARAMETER BackupWslConfig
    Optional. If given - original version of .wslconfig file will be saved as backup. This parameter cannot be used together with Modified parameter.

    .PARAMETER Force
    Optional. If specified will clear network parameters from .wslconfig file even if there are static ip address assignments remaining. This might make those static ip addresses invalid.

    .EXAMPLE
    Remove-WslNetworkConfig -Force

    Clears GatewayIpAddress, PrefixLength and DNSServerList settings from .wsl.config file, without saving a backup.

    .NOTES
    This command only clears parameters of the network adapter in .wslconfig file, without any effect on active adapter (if it exists). To remove adapter itself use command Remove-WslNetworkAdapter.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ParameterSetName = 'SaveExternally')]
        [ref]$Modified,

        [Parameter(ParameterSetName = 'SaveHere')]
        [switch]$BackupWslConfig,

        [switch]$Force
    )
    if ($PSCmdlet.ParameterSetName -eq 'SaveHere') {
        $localModified = $false
        $Modified = [ref]$localModified
    }

    $networkSectionName = (Get-NetworkSectionName)
    $staticIpSectionName = (Get-StaticIpAddressesSectionName)

    if ( $Force -or (Get-WslConfigSectionCount $staticIpSectionName) -le 0) {
        Remove-WslConfigValue $networkSectionName (Get-GatewayIpAddressKeyName) -Modified $Modified

        Remove-WslConfigValue $networkSectionName (Get-PrefixLengthKeyName) -Modified $Modified

        Remove-WslConfigValue $networkSectionName (Get-DnsServersKeyName) -Modified $Modified

        Remove-WslConfigValue $networkSectionName (Get-WindowsHostNameKeyName) -Modified $Modified
    }
    else {
        $staticIpSection = Get-WslConfigSection $staticIpSectionName
        Write-Warning "Network Parameters in .wslconfig will not be removed because there are Static IP Addresses remaining in .wslconfig:`n$(($staticIpSection.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)"}) -join "`n")"`

    }

    if ($PSCmdlet.ParameterSetName -eq 'SaveHere' -and $localModified) {
        Write-WslConfig -Backup:$BackupWslConfig
    }
}

function Set-WslNetworkAdapter {
    <#
    .SYNOPSIS
    Sets up WSL network adapter. Requires Administrator privileges.

    .DESCRIPTION
    Sets up WSL network adapter. Requires Administrator privileges. If executed from non elevated powershell prompt - will ask for confirmation to grant required permissions. Any running WSL Instances will be shutdown before the adapter is installed. If there is adapter with required parameters - no changes will be made.

    .PARAMETER GatewayIpAddress
    Optional. Gateway IP v4 Address of vEthernet (WSL) network adapter. Defaults to the setting in .wslconfig file. If there is not value in .wslconfig will issue a warning and exit.

    .PARAMETER PrefixLength
    Optional. Defaults to 24. WSL network SubNet Length.

    .PARAMETER DNSServerList
    Optional. Defaults to GatewayIpAddress. DNS servers to set for the network adapater. The list is a string with comma separated servers.

    .EXAMPLE
    Set-WslNetworkConfig -GatewayIpAddress 172.16.0.1
    Set-WslNetworkAdapter

    First command will set Gateway IP Address to 172.16.0.1, SubNet length to 24 and DNS Servers to 172.16.0.1 saving the settings in .wslconfig file.
    Second command will actually put these settings in effect. If there was active WSL network adapter in the system - it will be removed beforehand. Any running WSL instances will be shutdown.

    .NOTES
    Executing this command with specified parameters will not save these settings to .wslconfig. To save settings use command Set-WslNetworkConfig.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][Alias('Gateway')]
        [ipaddress]$GatewayIpAddress,

        [Parameter()][Alias('Prefix')]
        [int]$PrefixLength,

        [Parameter()][Alias('DNS')]
        [string]$DNSServerList, # Comma separated ipaddresses/hosts

        [Parameter()]
        [string[]]$DynamicAdapters = @('Ethernet', 'Default Switch')
    )

    $networkSectionName = (Get-NetworkSectionName)

    $GatewayIpAddress ??= Get-WslConfigValue -SectionName $networkSectionName -KeyName (Get-GatewayIpAddressKeyName) -DefaultValue $null

    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$GatewayIpAddress: $GatewayIpAddress"

    if ($null -eq $GatewayIpAddress) {
        $msg = 'Gateway IP Address is not specified neither as parameter nor in .wslconfig. WSL Hyper-V Network Adapter will be managed by Windows!'
        Throw $msg
    }

    $PrefixLength = $PSBoundParameters.ContainsKey('PrefixLength') ? $PrefixLength : (Get-WslConfigValue -SectionName $networkSectionName -KeyName (Get-PrefixLengthKeyName) -DefaultValue 24)

    $DNSServerList = [string]::IsNullOrWhiteSpace($DNSServerList) ? (Get-WslConfigValue -SectionName $networkSectionName -KeyName (Get-DnsServersKeyName) -DefaultValue $GatewayIpAddress) : $DNSServerList

    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$GatewayIpAddress='$GatewayIpAddress'; `$PrefixLength=$PrefixLength; `$DNSServerList='$DNSServerList'"

    $wslNetworkAlias = 'vEthernet (WSL)'
    $wslNetworkConnection = Get-NetIPAddress -InterfaceAlias $wslNetworkAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue

    # Check if there is existing WSL Adapter
    if ($null -ne $wslNetworkConnection) {
        Write-Verbose "$($MyInvocation.MyCommand.Name) Hyper-V VM Adapter 'WSL' already exists."
        Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$wslNetworkConnection`n$($wslNetworkConnection | Out-String)"

        # Check if existing WSL Adapter has required settings
        if ($wslNetworkConnection.IPAddress -eq $GatewayIpAddress -and $wslNetworkConnection.PrefixLength -eq $PrefixLength) {
            Write-Verbose "Hyper-V VM Adapter 'WSL' already has required GatewayAddress: '$GatewayIpAddress' and PrefixLength: '$PrefixLength'!"
            return
        }
    }

    # Setup required WSL adapter
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Shutting down all WSL instances before Setting up WSL Network Adapter..."
    wsl.exe --shutdown

    . (Join-Path $PSScriptRoot 'FunctionsPSElevation.ps1' -Resolve) | Out-Null
    $setAdapterScript = Join-Path $PSScriptRoot 'Set-WslNetworkAdapter.ps1' -Resolve

    $scriptParameters = @{
        GatewayIpAddress = $GatewayIpAddress
        PrefixLength     = $PrefixLength
        DNSServerList    = $DNSServerList
        DynamicAdapters  = $DynamicAdapters
    }
    $commonParameters = FilterCommonParameters $PSBoundParameters
    if (IsElevated) {
        Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: & $setAdapterScript -ScriptParameters $(& {$args} @scriptParameters) $(& { $args } @commonParameters)"

        & $setAdapterScript @scriptParameters @commonParameters
    }
    else {
        Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Invoke-ScriptElevated $setAdapterScript -ScriptParameters $(& {$args} @scriptParameters) $(& { $args } @commonParameters)"

        Invoke-ScriptElevated $setAdapterScript -ScriptParameters $scriptParameters -Encode @commonParameters
    }
}

function Remove-WslNetworkAdapter {
    <#
    .SYNOPSIS
    Removes WSL Network Adapter from the system if there is any.

    .DESCRIPTION
    Removes WSL Network Adapter from the system if there is any. If there is none - does nothing. Requires Administrator privileges. If executed from non elevated powershell prompt - will ask for confirmation to grant required permissions.

    .EXAMPLE
    Remove-WslNetworkAdapter

    .NOTES
    Executing this command will cause all running WSL instances to be shutdown.
    #>
    [CmdletBinding()]
    param()
    . (Join-Path $PSScriptRoot 'FunctionsPSElevation.ps1' -Resolve) | Out-Null
    $removeAdapterScript = Join-Path $PSScriptRoot 'Remove-WslNetworkAdapter.ps1' -Resolve

    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: & $removeAdapterScript $(& {$args} @PsBoundParameters)"
    & $removeAdapterScript @PsBoundParameters
}

function Set-WslScheduledTask {
    <#
    .SYNOPSIS
    Creates a new Scheduled Task: WSL-IpHandlerTask that will be triggered at user LogOn.
    This task execution is equivalent to running Set-WslNetworkAdapter command. It will create WSL Hyper-V Network Adapter when user logs on.

    .DESCRIPTION
    Creates Scheduled Task named 'WSL-IpHandlerTask' under 'WSL-IpHandler' folder.
    The task will be executed with Highest level of privileges under SYSTEM account.
    It will run in background without any interaction with user.
    After it is finished there will be WSL Hyper-V network adapter with network properties specified with this command.

    .PARAMETER GatewayIpAddress
    Mandatory. IP v4 Address of the gateway. This IP Address will appear in properties of Network Adapter (vEthernet (WSL)).

    .PARAMETER PrefixLength
    Optional. Defaults to 24. Length of WSL Subnet.

    .PARAMETER DNSServerList
    Optional. Defaults to GatewayIpAddress.

    .PARAMETER DynamicAdapters
    Array of strings - names of Hyper-V Network Adapters that can be moved to other IP network space to free space for WSL adapter. Defaults to: `'Ethernet', 'Default Switch'`

    .PARAMETER AnyUserLogOn
    When this parameter is present - The Scheduled Task will be set to run when any user logs on. Otherwise (default behavior) - the task will run only when current user (who executed Install-WslIpHandler command) logs on.

    .EXAMPLE
    Set-WslScheduledTask -GatewayIpAddress 172.16.0.1

    Creates scheduled task that will be executed on current user logon.

    .EXAMPLE
    Set-WslScheduledTask -GatewayIpAddress 172.16.0.1 -AllUsers

    Creates scheduled task that will be executed when any user logs on.

    .NOTES
    The task created can be found in Task Scheduler UI.
    #>
    param (
        [Parameter(Mandatory)]
        [Alias('Gateway')]
        [ipaddress]$GatewayIpAddress,

        [Parameter()]
        [Alias('Prefix')]
        [int]$PrefixLength = 24,

        [Parameter()]
        [Alias('DNS')]
        [string]$DNSServerList = $GatewayIpAddress, # String with Comma separated ipaddresses/hosts

        [Parameter()]
        [string[]]$DynamicAdapters = @('Ethernet', 'Default Switch'),

        [switch]$AnyUserLogOn
    )


    $elevationScript = Join-Path $PSScriptRoot 'FunctionsPSElevation.ps1' -Resolve
    . $elevationScript

    $scriptPath = Join-Path $PSScriptRoot 'Set-WslNetworkAdapter.ps1' -Resolve
    $taskName = Get-ScheduledTaskName
    $taskPath = Get-ScheduledTaskPath
    $taskDescription = Get-ScheduledTaskDescription
    $psExe = GetPowerShellExecutablePath

    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Task Name: $taskName"
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Task Path: $taskPath"
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Task Description: $taskDescription"
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Powershell Executable Path: $psExe"

    $DynamicAdaptersString = ($DynamicAdapters | ForEach-Object { "'$_'" }) -join ','
    $scriptArguments = @(
        '-Gateway'
        $GatewayIpAddress
        '-Prefix'
        $PrefixLength
        '-DNS'
        "'$DNSServerList'"
        '-DynamicAdapters'
        $DynamicAdaptersString
    )
    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: scriptArguments: $scriptArguments"

    $psExeArguments = @(
        '-NoLogo'
        '-NoProfile'
        '-WindowStyle Hidden'
        '-Command'
        "`""  # Opening Double Quote of Command Parameter with optional single quotes inside
        "& '$scriptPath'"
    )
    $psExeArguments += @($scriptArguments -join ' ')
    $psExeArguments += "`""  # Closing Double Quote of Command Parameter

    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: psExeArguments: $psExeArguments"

    $actionParams = @{
        Execute  = "`"$psExe`""
        Argument = $psExeArguments -join ' '
    }
    $action = New-ScheduledTaskAction @actionParams

    $triggerParams = @{
        AtLogOn = $true
    }
    if (-not $AnyUserLogOn) {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $triggerParams.User = $currentUser
    }
    $trigger = New-ScheduledTaskTrigger @triggerParams

    $settingsParams = @{
        DisallowHardTerminate   = $false
        AllowStartIfOnBatteries = $true
        DontStopOnIdleEnd       = $true
        ExecutionTimeLimit      = (New-TimeSpan -Minutes 5)
        Compatibility           = 'Win8'
    }
    $settings = New-ScheduledTaskSettingsSet @settingsParams

    $registrationParams = @{
        TaskName    = $taskName
        TaskPath    = $taskPath
        Description = $taskDescription
        Action      = $action
        Settings    = $settings
        Trigger     = $trigger
        RunLevel    = 'Highest'
        Force       = $true
        User        = 'NT AUTHORITY\SYSTEM'
    }
    if (IsElevated) {
        Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Invoking Register-ScheduledTask $registrationParams"
        Register-ScheduledTask @registrationParams | Out-Null
    }
    else {
        $command = @(
            'Import-Module WSL-IpHandler;'
            'Set-WslScheduledTask'
        )
        $command += $scriptArguments
        $commandString = $command -join ' '
        Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Invoking Invoke-CommandElevated $commandString"
        Invoke-CommandElevated $commandString -Encode
    }
}

function Remove-WslScheduledTask {
    <#
    .SYNOPSIS
    Removes WSL-IpHandlerTask Scheduled Task created with Set-WslScheduledTask command.

    .EXAMPLE
    Remove-WslScheduledTask
    #>
    [CmdletBinding()]
    param ()

    $elevationScript = Join-Path $PSScriptRoot 'FunctionsPSElevation.ps1' -Resolve
    . $elevationScript

    $taskName = Get-ScheduledTaskName
    $taskPath = Get-ScheduledTaskPath

    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Checking if $taskName exists..."

    $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue

    if (-not $existingTask) {
        Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: $taskName does not exist - nothing to remove."
        return
    }

    Write-Verbose "Removing Scheduled Task: ${taskPath}${taskName}"
    if (IsElevated) {
        Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
    }
    else {
        $arguments = "-TaskName '$taskName' -TaskPath '$taskPath' -Confirm:`$false -ErrorAction SilentlyContinue"
        Invoke-CommandElevated "Unregister-ScheduledTask $arguments"
    }

    if ((Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue)) {
        Write-Error "Failed to remove Scheduled Task: ${taskPath}${taskName}"
    }
}

function Test-WslInstallation {
    <#
    .SYNOPSIS
    Tests if WSL Handler has been installed successfully.

    .DESCRIPTION
    Tests if WSL Handler has been installed successfully. This command is run automatically during execution of Install-WslHandler command. The tests are made by pinging once WSL instance and Windows host to/from each other.

    .PARAMETER WslInstanceName
    Required. Name of WSL Instance as listed by `wsl.exe -l` command.

    .PARAMETER WslHostName
    Optional. Defaults to WslInstanceName. The name to use to access the WSL Instance on WSL SubNet.

    .PARAMETER WindowsHostName
    Optional. Defaults to `windows`. Name of Windows Host that can be used to access windows host from WSL Instance.

    .EXAMPLE
    Test-WslInstallation -WslInstanceName Ubuntu
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Alias('Name')]
        [string]$WslInstanceName,

        [ValidateNotNullOrEmpty()]
        [string]$WslHostName = $WslInstanceName,

        [ValidateNotNullOrEmpty()]
        [string]$WindowsHostName
    )


    $networkSectionName = (Get-NetworkSectionName)
    $failed = $false

    if (-not $PSBoundParameters.ContainsKey('WindowsHostName')) {
        $WindowsHostName = Get-WslConfigValue -SectionName $networkSectionName -KeyName (Get-WindowsHostNameKeyName) -DefaultValue 'windows'
    }

    $error_message = @()

    $bashTestCommand = "ping -c1 $WindowsHostName 2>&1"
    Write-Verbose "Testing Ping from WSL instance ${WslInstanceName}: `"$bashTestCommand`" ..."
    $wslTest = (wsl.exe -d $WslInstanceName env BASH_ENV=/etc/profile bash -c `"$bashTestCommand`") -join "`n"

    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$wslTest: $wslTest"

    if ($wslTest -notmatch ', 0% packet loss') {
        Write-Verbose "Ping from WSL Instance $WslInstanceName failed:`n$wslTest"
        Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: TypeOf `$wslTest: $($wslTest.Gettype())"

        $failed = $true
        $error_message += "Pinging $WindowsHostName from $WslInstanceName failed:`n$wslTest"
    }

    # Before testing WSL IP address - make sure WSL Instance is up and running
    # if (-not (Get-WslIsRunning $WslInstanceName)) {
    #     $runCommand = 'sleep 60; exit'  # Even after 'exit' wsl instance should be running in background
    #     Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Running WSL instance $WslInstanceName for testing ping from Windows."
    #     $wslJob = wsl.exe -d $WslInstanceName env BASH_ENV=/etc/profile bash -c `"$runCommand`" &
    #     Start-Sleep -Seconds 3  # let WSL startup before pinging
    # }

    # if (Get-WslIsRunning $WslInstanceName) {
    # Write-Verbose "Testing Ping from Windows to WSL instance ${WslInstanceName} ..."
    # $windowsTest = $(ping -n 1 $WslHostName) -join "`n"

    # Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$windowsTest: $windowsTest"

    # if ($windowsTest -notmatch 'Lost = 0 \(0% loss\)') {
    #     Write-Verbose "Ping from Windows to WSL instance ${WslInstanceName} failed:`n$windowsTest"
    #     $failed = $true
    #     $error_message += "`nPinging $WslHostName from Windows failed:`n$windowsTest"
    #     }
    # }
    # else {
    #     $failed = $true
    #     $error_message += "Could not start WSL Instance: $WslInstanceName to test Ping from Windows"
    # }

    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Starting WSL instance $WslInstanceName for testing ping from Windows."
    $runCommand = 'sleep 30; exit'
    $wslJob = wsl.exe -d $WslInstanceName env BASH_ENV=/etc/profile bash -c `"$runCommand`" &
    Start-Sleep -Seconds 3  # let WSL startup before pinging

    Write-Verbose "Testing Ping from Windows to WSL instance ${WslInstanceName} ..."
    $windowsTest = $(ping -n 1 $WslHostName) -join "`n"

    Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$windowsTest result: $windowsTest"

    if ($windowsTest -notmatch 'Lost = 0 \(0% loss\)') {
        Write-Verbose "Ping from Windows to WSL instance ${WslInstanceName} failed:`n$windowsTest"
        $failed = $true
        $error_message += "`nPinging $WslHostName from Windows failed:`n$windowsTest"
    }

    $wslJob.StopJob()
    $wslJob.Dispose()

    if ($failed) {
        Write-Verbose "$($MyInvocation.MyCommand.Name) on $WslInstanceName Failed!"
        Write-Error ($error_message -join "`n") -ErrorAction Stop
    }
    else {
        Write-Host "Test of WSL-IpHandler Installation on $WslInstanceName Succeeded!" -ForegroundColor Green
    }
}

function Update-WslIpHandlerModule {
    <#
    .SYNOPSIS
    Downloads latest master.zip from this Modules repository at github.com and updates local Module's files

    .DESCRIPTION
    Updates local Module's files to the latest available at Module's repository at github.com.
    If `git` is available uses `git pull origin master`, otherwise Invoke-WebRequest will be used to download master.zip and expand it to Module's directory replacing all files with downloaded ones.

    .PARAMETER GitExePath
    Path to git.exe if it can not be located with environment's PATH variable.

    .PARAMETER DoNotUseGit
    If given will update module using Invoke-WebRequest command (built-in in Powershell) even if git.exe is on PATH.

    .PARAMETER Force
    If given will update module even if there is version mismatch between installed version and version in repository.

    .EXAMPLE
    Update-WslIpHandlerModule

    Will update this module using git.exe if it can be located, otherwise will use Invoke-WebRequest to download latest master.zip from repository and overwrite all existing file in WSL-IpHandler module's folder.

    .NOTES
    The default update mode is to use git.exe if it can be located with PATH.
    Adding -GitExePath parameter will allow to use git.exe that is not on PATH.
    All files in this Module's folder will be removed before update!
    #>
    [CmdletBinding()]
    param(
        [Parameter(ParameterSetName = 'Name+Git')]
        [Parameter(ParameterSetName = 'Path+Git')]
        [ValidateScript({ Test-Path $_ -PathType Leaf -Include 'git.exe' })]
        [Alias('Git')]
        [string]$GitExePath,

        [Parameter(ParameterSetName = 'Name+Http')]
        [Parameter(ParameterSetName = 'Path+Http')]
        [switch]$Force
    )
    $params = @{
        ModuleNameOrPath = $MyInvocation.MyCommand.Module.ModuleBase
        GithubUserName   = $MyInvocation.MyCommand.Module.Author
        Branch           = 'master'
    }
    $updateScript = Join-Path $PSScriptRoot 'Update-WslIpHandlerModule.ps1' -Resolve

    & $updateScript @params @PSBoundParameters
}

function Uninstall-WslIpHandlerModule {
    [CmdletBinding()]
    param()
    $moduleLocation = Split-Path $MyInvocation.MyCommand.Module.Path
    $prompt = 'Please confirm that the following directory should be irreversibly DELETED:'
    if ($PSCmdlet.ShouldContinue($moduleLocation, $prompt)) {
        $moduleName = $MyInvocation.MyCommand.ModuleName
        Remove-Module $moduleName -Force
        if ((Get-Location).Path.Contains($moduleLocation)) {
            Set-Location (Split-Path $moduleLocation)
        }
        Write-Verbose "Removing $moduleLocation..."
        Remove-Item -Path $moduleLocation -Recurse -Force
    }
    else {
        Write-Verbose 'Uninstall operation was canceled!'
    }
}

function Invoke-WslExe {
    <#
    .SYNOPSIS
    Takes any parameters and passes them transparently to wsl.exe. If parameter(s) requires actually starting up WSL Instance - will set up WSL Network Adapter using settings in .wslconfig. Requires administrator privileges if required adapter is not active.

    .DESCRIPTION
    This command acts a wrapper around `wsl.exe` taking all it's parameters and passing them along.
    Before actually executing `wsl.exe` this command checks if WSL Network Adapter with required parameters is active (i.e. checks if network parameters in .wslconfig are in effect). If active adapter parameters are different from those in .wslconfig - active adapter is removed and new one with required parameters is activated. Requires administrator privileges if required adapter is not active.

    .PARAMETER Timeout
    Number of seconds to wait for vEthernet (WSL) Network Connection to become available when WSL Hyper-V Network Adapter had to be created.

    .EXAMPLE
    wsl -l -v

    Will list all installed WSL instances with their detailed status.

    wsl -d Ubuntu

    Will check if WSL Network Adapter is active and if not initialize it. Then it will execute `wsl.exe -d Ubuntu`. Thus allowing to use WSL instances with static ip addressed without manual interaction with network settings, etc.

    .NOTES
    During execution of Install-WslHandler, when a static mode of operation is specified, there will be an alias created: `wsl` for Invoke-WslExe. When working in Powershell this alias shadows actual windows `wsl` command to enable effortless operation in Static IP Mode. When there is a need to execute actual windows `wsl` command from withing Powershell use `wsl.exe` (i.e. with extension) to execute native Windows command.
    #>
    param([int]$Timeout = 30)
    function ArgsAreExec {
        param($arguments)
        $nonExecArgs = @(
            '-l', '--list',
            '--shutdown',
            '--terminate', '-t',
            '--status',
            '--update',
            '--set-default', '-s'
            '--help',
            '--install',
            '--set-default-version',
            '--export',
            '--import',
            '--set-version',
            '--unregister'
        )
        $allArgsAreExec = $true
        foreach ($a in $arguments) {
            if ($a -in $nonExecArgs) {
                $allArgsAreExec = $false
                break
            }
        }
        $allArgsAreExec
    }
    function IsWslNetworkAvailable {
        if ($null -eq (Get-NetIPAddress -InterfaceAlias $vEthernetWsl -AddressFamily IPv4 -ErrorAction SilentlyContinue)) { $false }
        else { $false }
    }
    $argsCopy = $args.Clone()
    $setWslAdapterParams = @{}

    $DebugPreferenceOriginal = $DebugPreference
    if ('-debug' -in $argsCopy) {
        $DebugPreference = 'Continue'
        $argsCopy = ($argsCopy | Where-Object { $_ -notlike '-debug' }) ?? @()
        $setWslAdapterParams.Debug = $true
    }

    if ('-verbose' -in $argsCopy) {
        $VerbosePreference = 'Continue'
        $argsCopy = ($argsCopy | Where-Object { $_ -notlike '-verbose' }) ?? @()
        $setWslAdapterParams.Verbose = $true
    }

    $vEthernetWsl = 'vEthernet (WSL)'
    $timer = [system.diagnostics.stopwatch]::StartNew()

    if ($argsCopy.Count -eq 0 -or (ArgsAreExec $argsCopy)) {
        Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: `$args: $argsCopy"
        Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Passed arguments require Setting WSL Network Adapter."

        Set-WslNetworkAdapter @setWslAdapterParams

        while ($timer.Elapsed.TotalSeconds -lt $Timeout -and (-not (IsWslNetworkAvailable))) {
            $totalSecs = [math]::Round($timer.Elapsed.TotalSeconds, 0)
            Write-Debug "Still waiting for WSL Network Connection to be initialized after [$totalSecs] seconds..."
            Start-Sleep -Seconds 3
        }
    }

    if ((IsWslNetworkAvailable)) {
        $totalSecs = [math]::Round($timer.Elapsed.TotalSeconds, 0)
        Write-Debug "$vEthernetWsl Network Connection has been initialized after [$totalSecs] seconds."

        Write-Debug "$($MyInvocation.MyCommand.Name) [$($MyInvocation.ScriptLineNumber)]: Invoking wsl.exe $argsCopy"
        $DebugPreference = $DebugPreferenceOriginal
        & wsl.exe @argsCopy @PSBoundParameters
    }
    else {
        $msg = "$vEthernetWsl Network is NOT available after $Timeout seconds of waiting. Try increasing timeout with 'wsl -Timeout 60'."
        Throw $msg
    }

}

Set-Alias -Name wsl -Value Invoke-WslExe

Register-ArgumentCompleter -CommandName Install-WslIpHandler -ParameterName WslInstanceName -ScriptBlock $Function:WslNameCompleter

Register-ArgumentCompleter -CommandName Uninstall-WslIpHandler -ParameterName WslInstanceName -ScriptBlock $Function:WslNameCompleter

Register-ArgumentCompleter -CommandName Set-WslInstanceStaticIpAddress -ParameterName WslInstanceName -ScriptBlock $Function:WslNameCompleter

Register-ArgumentCompleter -CommandName Remove-WslInstanceStaticIpAddress -ParameterName WslInstanceName -ScriptBlock $Function:WslNameCompleter

Register-ArgumentCompleter -CommandName Test-WslInstallation -ParameterName WslInstanceName -ScriptBlock $Function:WslNameCompleter
