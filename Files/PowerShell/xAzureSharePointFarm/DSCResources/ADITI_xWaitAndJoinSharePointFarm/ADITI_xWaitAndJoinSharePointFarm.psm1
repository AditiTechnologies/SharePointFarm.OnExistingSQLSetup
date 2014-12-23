#
# xWaitAndJoinSharePointFarm: DSC resource to wait for SharePoint farm to get created and then join it.
#

#
# The Get-TargetResource cmdlet.
#
function Get-TargetResource
{
    param
    (	
        [parameter(Mandatory)]
        [string] $FarmAdmin,

        [parameter(Mandatory)]
        [string] $FarmAdminPassword,

        [parameter(Mandatory)]
        [string] $FarmPassphrase,

        [parameter(Mandatory)]
        [string] $DbServer,

        [parameter(Mandatory)]
        [string] $ConfigurationDbName,

        [parameter(Mandatory)]
        [string] $CAContentDbName,

		[parameter(Mandatory)]
		[UInt64] $RetryIntervalSec,
        
		[parameter(Mandatory)]
		[UInt32] $RetryCount,
		
        [parameter(Mandatory)]
        [string] $LogLocation,

        [parameter(Mandatory)]
        [Uint32] $LogDiskSpaceUsageGB,			
        
        [parameter(Mandatory)]
        [PSCredential] $SqlAdministratorCredential
    )       
	
	$spFarm = $null
	$FarmAdministratorCredential = New-Object PSCredential $FarmAdmin, (ConvertTo-SecureString $FarmAdminPassword -AsPlainText -Force)
	try
    {		
        ($oldToken, $context, $newToken) = ImpersonateAs -cred $FarmAdministratorCredential
		
		Write-Verbose "Loading snapin.."
		Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue			
	
		Try 
		{ 
			$spFarm = Get-SPFarm | where Name -eq $ConfigurationDbName -ErrorAction SilentlyContinue 
		}
		Catch {}
	}
	finally
    {
        if ($context)
        {
            $context.Undo()
            $context.Dispose()
            CloseUserToken($newToken)
        }
		Write-Verbose "Removing snapin.."
		Remove-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
    }
	
    $retvalue = @{
        DbServer = $DbServer;
        ConfigurationDbName = $ConfigurationDbName;
        CAContentDbName = $CAContentDbName;
		JoinedToFarm = !($spFarm -eq $null);
    }
}

#
# The Set-TargetResource cmdlet.
#
function Set-TargetResource
{
    param
    (        
        [parameter(Mandatory)]
        [string] $FarmAdmin,

        [parameter(Mandatory)]
        [string] $FarmAdminPassword,

        [parameter(Mandatory)]
        [string] $FarmPassphrase,

        [parameter(Mandatory)]
        [string] $DbServer,

        [parameter(Mandatory)]
        [string] $ConfigurationDbName,

        [parameter(Mandatory)]
        [string] $CAContentDbName,

		[parameter(Mandatory)]
		[UInt64] $RetryIntervalSec,
        
		[parameter(Mandatory)]
		[UInt32] $RetryCount,
		
        [parameter(Mandatory)]
        [string] $LogLocation,

        [parameter(Mandatory)]
        [Uint32] $LogDiskSpaceUsageGB,
        
        [parameter(Mandatory)]
        [PSCredential] $SqlAdministratorCredential
    )       
	
    $FarmAdministratorCredential = New-Object PSCredential $FarmAdmin, (ConvertTo-SecureString $FarmAdminPassword -AsPlainText -Force)
    try
    {		
        ($oldToken, $context, $newToken) = ImpersonateAs -cred $FarmAdministratorCredential  
		
		Write-Verbose "Loading snapin.."
		Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
		
        # disable loopback to fix 401s from SP Webs Service calls
        New-ItemProperty HKLM:\System\CurrentControlSet\Control\Lsa -Name DisableLoopbackCheck -Value 1 -PropertyType dword -Force -ErrorAction Ignore | Out-Null

        JoinFarm -FarmAdmin $FarmAdmin -FarmAdminPassword $FarmAdminPassword -FarmPassphrase $FarmPassphrase `
                         -DbServer $DbServer -ConfigurationDbName $ConfigurationDbName -CAContentDbName $CAContentDbName `
                         -RetryIntervalSec $RetryIntervalSec -RetryCount $RetryCount `
						 -SqlAdministratorCredential $SqlAdministratorCredential

        Write-Verbose "Configuring SharePoint..."
        
        ConfigureLogging -LogLocation $LogLocation -LogDiskSpaceUsageGB $LogDiskSpaceUsageGB
                
        ConfigureSharePoint

    }
    finally
    {
        if ($context)
        {
            $context.Undo()
            $context.Dispose()
            CloseUserToken($newToken)
        }
		Write-Verbose "Removing snapin.."
		Remove-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
    }
}

# 
# Test-TargetResource
#

function Test-TargetResource  
{
    param
    (        
        [parameter(Mandatory)]
        [string] $FarmAdmin,

        [parameter(Mandatory)]
        [string] $FarmAdminPassword,

        [parameter(Mandatory)]
        [string] $FarmPassphrase,       

        [parameter(Mandatory)]
        [string] $DbServer,

        [parameter(Mandatory)]
        [string] $ConfigurationDbName,

        [parameter(Mandatory)]
        [string] $CAContentDbName,

		[parameter(Mandatory)]
		[UInt64] $RetryIntervalSec,
        
		[parameter(Mandatory)]
		[UInt32] $RetryCount,
		
        [parameter(Mandatory)]
        [string] $LogLocation,

        [parameter(Mandatory)]
        [Uint32] $LogDiskSpaceUsageGB,			
        
        [parameter(Mandatory)]
        [PSCredential] $SqlAdministratorCredential
    )

    # Set-TargetResource is idempotent
    return $false
}


function Get-ImpersonatetLib
{
    if ($script:ImpersonateLib)
    {
        return $script:ImpersonateLib
    }

    $sig = @'
[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool LogonUser(string lpszUsername, string lpszDomain, string lpszPassword, int dwLogonType, int dwLogonProvider, ref IntPtr phToken);

[DllImport("kernel32.dll")]
public static extern Boolean CloseHandle(IntPtr hObject);
'@ 
   $script:ImpersonateLib = Add-Type -PassThru -Namespace 'Lib.Impersonation' -Name ImpersonationLib -MemberDefinition $sig 

   return $script:ImpersonateLib
    
}

function ImpersonateAs([PSCredential] $cred)
{
    [IntPtr] $userToken = [Security.Principal.WindowsIdentity]::GetCurrent().Token
    $userToken
    $ImpersonateLib = Get-ImpersonatetLib

    $bLogin = $ImpersonateLib::LogonUser($cred.GetNetworkCredential().UserName, $cred.GetNetworkCredential().Domain, $cred.GetNetworkCredential().Password, 
    9, 0, [ref]$userToken)
    
    if ($bLogin)
    {
        $Identity = New-Object Security.Principal.WindowsIdentity $userToken
        $context = $Identity.Impersonate()
    }
    else
    {
        throw "Can't Logon as User $cred.GetNetworkCredential().UserName."
    }
    $context, $userToken
}

function CloseUserToken([IntPtr] $token)
{
    $ImpersonateLib = Get-ImpersonatetLib

    $bLogin = $ImpersonateLib::CloseHandle($token)
    if (!$bLogin)
    {
        throw "Can't close token"
    }
}

function JoinFarm(
    [Parameter(Mandatory)]
    [string]$DbServer, 
    [Parameter(Mandatory)]
    [string]$FarmPassphrase,
    [Parameter(Mandatory)]
    [string]$FarmAdmin,    
    [Parameter(Mandatory)]
    [string]$FarmAdminPassword,
    [Parameter(Mandatory)]
    [string]$ConfigurationDbName,
    [Parameter(Mandatory)]
    [string]$CAContentDbName,
	[parameter(Mandatory)]
	[UInt64] $RetryIntervalSec,
    [parameter(Mandatory)]
	[UInt32] $RetryCount,
    [parameter(Mandatory)]
    [PSCredential] $SqlAdministratorCredential	
)
{    
    $farmCredential = New-Object PSCredential $FarmAdmin, (ConvertTo-SecureString $FarmAdminPassword -AsPlainText -Force)
	$secPhrase = ConvertTo-SecureString $FarmPassphrase -AsPlainText -Force
	$joinedFarm = $false
	$spFarm = $null
	
	Try 
	{ 
		$spFarm = Get-SPFarm | where Name -eq $ConfigurationDbName -ErrorAction SilentlyContinue 
	}
	Catch {}	
	
	If(!$spFarm)
	{
		for ($count = 0; $count -lt $RetryCount; $count++)
		{
			Write-Verbose "Attempting to join farm on [$ConfigurationDbName]..."
			Connect-SPConfigurationDatabase -DatabaseName $ConfigurationDbName -Passphrase $secPhrase -DatabaseServer $DbServer -DatabaseCredentials $SqlAdministratorCredential -ErrorAction SilentlyContinue
			
			If (!$?)
			{			
				Write-Verbose "No existing SharePoint farm found on [$ConfigurationDbName]. Will retry again after $RetryIntervalSec sec ..."
				Start-Sleep -Seconds $RetryIntervalSec				
			}
			Else
			{
				Write-Verbose "Joined farm on [$ConfigurationDbName]..."
				$joinedFarm = $true
				break
			}
		}
	}
	Else
	{
		Write-Verbose "Already joined to farm on [$ConfigurationDbName]."
		$joinedFarm = $true
	}
	
	If (!$joinedFarm)
    {
        throw "SharePoint farm not found after $count attempt with $RetryIntervalSec sec interval"
    }
}

function ConfigureLogging(
    [Parameter(Mandatory)]
    [string]$LogLocation, 
    [Parameter(Mandatory)]
    [Uint32]$LogDiskSpaceUsageGB
)
{
	If(Test-Path $env:BrewmasterDir\Logs\SPLoggingConfigured.txt)
	{
		return
	}
	
    # Configure logging
    Write-Verbose "Setting log location [$LogLocation] and enabling EventLog Flood Protection"
    Set-SPLogLevel -TraceSeverity Monitorable | Out-Null
    Set-SPDiagnosticConfig -LogLocation $LogLocation -EventLogFloodProtectionEnabled | Out-Null
    if ($LogDiskSpaceUsageGB > 0)
    {
        Write-Verbose "Limiting log size to [$LogDiskSpaceUsageGB GB]"
        Set-SPDiagnosticConfig -LogMaxDiskSpaceUsageEnabled -LogDiskSpaceUsageGB $LogDiskSpaceUsageGB | Out-Null
    }
	
	New-Item $env:BrewmasterDir\Logs\SPLoggingConfigured.txt -type file -force -value "SharePoint logging configured sucessfully..."
}

function ConfigureSharePoint()
{
	If(Test-Path $env:BrewmasterDir\Logs\SPConfigured.txt)
	{
		return
	}
	
    # Install help collections
    Write-Verbose "Install help collections..."
    Install-SPHelpCollection -All | Out-Null
                
    # Secure the SharePoint resources
    Write-Verbose "Securing SharePoint resources..."
    Initialize-SPResourceSecurity | Out-Null
                    
    # Install services
    Write-Verbose "Installing services..."
    Install-SPService | Out-Null
                    
    # Register SharePoint features
    Write-Verbose "Registering SharePoint features..."
    Install-SPFeature -AllExistingFeatures -Force | Out-Null

    # Install application content files
    Write-Verbose "Installing application content files..."
    Install-SPApplicationContent | Out-Null

    # Let's make sure the SharePoint Timer Service (SPTimerV4) is running
    # Per workaround in http://www.paulgrimley.com/2010/11/side-effects-of-attaching-additional.html
    $timersvc = Get-Service SPTimerV4
    If ($timersvc.Status -eq "Stopped")
    {
        Write-Verbose "Starting $($timersvc.DisplayName) service..."
        Start-Service $timersvc
        If (!$?) {Throw "Could not start $($timersvc.DisplayName) service!"}
    }
	
	New-Item $env:BrewmasterDir\Logs\SPConfigured.txt -type file -force -value "SharePoint configured sucessfully..."
}
