#
# xSharePointCentralAdmin: DSC resource to create central admin site for SharePoint farm.
#

#
# The Get-TargetResource cmdlet.
#
function Get-TargetResource
{
    param
    (	
        [parameter(Mandatory)]
        [Uint32] $CAWebPort,
		
        [parameter(Mandatory)]
        [string] $AltUrl,

		[parameter(Mandatory)]
        [PSCredential] $FarmAdministratorCredential
    )   

    $retvalue = @{
        CAWebPort = $CAWebPort;
        AltUrl = $AltUrl;
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
        [Uint32] $CAWebPort,
		
        [parameter(Mandatory)]
        [string] $AltUrl,

		[parameter(Mandatory)]
        [PSCredential] $FarmAdministratorCredential
    )   
	
    try
    {
        ($oldToken, $context, $newToken) = ImpersonateAs -cred $FarmAdministratorCredential        
		
		Write-Verbose "Loading snapin.."
		Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
        
		CreateCentralAdmin -CAWebPort $CAWebPort -AltUrl $AltUrl
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
        [Uint32] $CAWebPort,
		
        [parameter(Mandatory)]
        [string] $AltUrl,

		[parameter(Mandatory)]
        [PSCredential] $FarmAdministratorCredential
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

Function CreateCentralAdmin(
    [parameter(Mandatory)]
    [Uint32] $CAWebPort,		
    [parameter(Mandatory)]
    [string] $AltUrl
)
{
	$hostAndPort = "$($env:COMPUTERNAME):$CAWebPort"
    $centralAdmin = Get-SPWebApplication -IncludeCentralAdministration | where Url -like "*$hostAndPort*"
	if (!$centralAdmin)
	{
		$err = $null
		Try
		{
			# Check if there is already a Central Admin provisioned in the farm; if not, create one
			If (!(Get-SPWebApplication -IncludeCentralAdministration | where Url -like "*:$CAWebPort*"))
			{
				Write-Verbose "Creating Central Admin site on port [$CAWebPort]..."
				$args = @{Port=$CAWebPort; WindowsAuthProvider="NTLM"}
			}
			Else #Create a Central Admin site locally, with an AAM to the existing Central Admin
			{
				Write-Verbose "Creating local Central Admin site..."
				$args = ""
			}
			New-SPCentralAdministration @args -ErrorVariable err
			If (!$?) {Throw "Error creating Central Admin site: $err"}

			$centralAdmin = Get-SPWebApplication -IncludeCentralAdministration | where Url -like "*$hostAndPort*"
		}
		Catch
		{
			If ($err -like "*update conflict*")
			{
				Write-Warning "A concurrency error occured, trying again."
				CreateCentralAdmin - $CAWebPort -AltUrl $AltUrl
				return
			}
			Throw
		}
	}

	if ($centralAdmin.Status -eq "Provisioning")
	{
		Write-Verbose "Waiting for Central Admin site..."
		Do
		{
			Start-Sleep 1
			$centralAdmin = Get-SPWebApplication -IncludeCentralAdministration | where Url -like "*$hostAndPort*"
		} While ($centralAdmin.Status -eq "Provisioning")
	}
	if ($centralAdmin.Status -eq "Online")
	{
		Write-Verbose "Central Admin site created. Url: $($centralAdmin.Url)"
	}
	else
	{
		Write-Warning "Failed to start Central Admin site. Status: $($centralAdmin.Status)."
	}

    Write-Verbose "Adding Alternative Access Mapping for Central Admin site: [$AltUrl]"
    New-SPAlternateUrl -WebApplication "http://$hostAndPort" -Url $AltUrl -Zone Internet	
}
