#
# xSharePointFarm: DSC resource to create SharePoint farm on Windows Azure VM.
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
		FarmCreated = !($spFarm -eq $null);
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

        CreateFarm -FarmAdmin $FarmAdmin -FarmAdminPassword $FarmAdminPassword -FarmPassphrase $FarmPassphrase `
                         -DbServer $DbServer -ConfigurationDbName $ConfigurationDbName -CAContentDbName $CAContentDbName `
                         -SqlAdministratorCredential $SqlAdministratorCredential
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

function CreateFarm(
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
    [PSCredential] $SqlAdministratorCredential
)
{    
    $farmCredential = New-Object PSCredential $FarmAdmin, (ConvertTo-SecureString $FarmAdminPassword -AsPlainText -Force)
	$secPhrase = ConvertTo-SecureString $FarmPassphrase -AsPlainText -Force

	# Look for an existing farm and join the farm if not already joined, or create a new farm
	Write-Verbose "Checking farm membership in [$ConfigurationDbName]..."
	$spFarm = $null
	Try 
	{ 
		$spFarm = Get-SPFarm | where Name -eq $ConfigurationDbName -ErrorAction SilentlyContinue 
	} 
	Catch {}

	If (!$spFarm)
	{
		New-SPConfigurationDatabase -DatabaseName $ConfigurationDbName -DatabaseServer $DbServer -DatabaseCredentials $SqlAdministratorCredential -AdministrationContentDatabaseName $CAContentDbName -Passphrase $secPhrase -FarmCredentials $farmCredential
		
		If (!$?) 
		{
			Throw "Error creating new farm configuration database"
		}
		Write-Verbose "Created new farm on [$ConfigurationDbName]."			
	}
	Else
	{
		Write-Verbose "Already joined to farm on [$ConfigurationDbName]."
	}
}
