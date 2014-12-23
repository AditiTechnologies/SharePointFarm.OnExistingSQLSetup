#
# xSharePointWebApplication: DSC resource to create an empty SharePoint web application.
#

#
# The Get-TargetResource cmdlet.
#
function Get-TargetResource
{
    param
    (	
        [Parameter(Mandatory)]
        [string]$WebAppName,
    
        [Parameter(Mandatory)]
        [string]$AppPoolName,
    
        [Parameter(Mandatory)]
        [string]$AppPoolAccount,
    
        [Parameter(Mandatory)]
        [string]$SiteUrl,

        [Parameter(Mandatory)]
        [Uint32]$Port,

        [Parameter(Mandatory)]
        [Uint32]$ProbePort,
    
        [Parameter(Mandatory)]
        [string]$SiteName,
    
        [Parameter(Mandatory)]
        [string]$SiteTemplate,
    
        [Parameter(Mandatory)]
        [string]$SiteOwner,
		
		[parameter(Mandatory)]
        [PSCredential] $FarmAdministratorCredential,
        
        [parameter(Mandatory)]
        [PSCredential] $SqlAdministratorCredential,

        [UInt32] $RetryCount = 3
    )

    

    $retvalue = @{
        WebAppName = $WebAppName;
        AppPoolName = $AppPoolName;
        AppPoolAccount = $AppPoolAccount;
        SiteUrl = $SiteUrl;
        SiteName = $SiteName;
        SiteOwner = $SiteOwner;
        SiteTemplate = $SiteTemplate
    }
}

#
# The Set-TargetResource cmdlet.
#
function Set-TargetResource
{
    param
    (        
        [Parameter(Mandatory)]
        [string]$WebAppName,
    
        [Parameter(Mandatory)]
        [string]$AppPoolName,
    
        [Parameter(Mandatory)]
        [string]$AppPoolAccount,
    
        [Parameter(Mandatory)]
        [string]$SiteUrl,

        [Parameter(Mandatory)]
        [Uint32]$Port,

        [Parameter(Mandatory)]
        [Uint32]$ProbePort,
    
        [Parameter(Mandatory)]
        [string]$SiteName,
    
        [Parameter(Mandatory)]
        [string]$SiteTemplate,
    
        [Parameter(Mandatory)]
        [string]$SiteOwner,
		
		[parameter(Mandatory)]
        [PSCredential] $FarmAdministratorCredential,
        
        [parameter(Mandatory)]
        [PSCredential] $SqlAdministratorCredential,

        [UInt32] $RetryCount = 3
    )   
		
    try
    {
        ($oldToken, $context, $newToken) = ImpersonateAs -cred $FarmAdministratorCredential               
		
		Write-Verbose "Loading snapin.."
		Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
		
        $SiteUrl = $SiteUrl.Trim('/').ToLower()

	    $existingWebApp = Get-SPWebApplication | where {$_.Url.Trim('/') -eq $SiteUrl}
	    if (!$existingWebApp)
	    {
		    CreateWebApplicationWithRetries -RetryCount $RetryCount -WebAppName $WebAppName -SiteUrl $SiteUrl -SiteTemplate $SiteTemplate `
                                 -SiteOwner $SiteOwner -AppPoolName $AppPoolName -AppPoolAccount $AppPoolAccount `
                                 -SqlAdministratorCredential $SqlAdministratorCredential                                 
	    }
	    else
	    {
		    Write-Verbose "Web application at [$SiteUrl] already exists: [$($existingWebApp.Name)]."
	    }

        Import-Module WebAdministration -DisableNameChecking -ErrorAction Stop

        Write-Verbose "Adding firewall rule 'LB Health Check $ProbePort'"
        $cmd = "netsh advfirewall firewall add rule name=""LB Health Check $ProbePort"" protocol=TCP dir=in localport=$ProbePort action=allow"
        Invoke-Expression $cmd | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "'$cmd' returned $LASTEXITCODE."
        }

        Write-Verbose "Configure default website to listen for Health Checks"
        Set-WebBinding -Name 'Default Web Site' -BindingInformation "*:80:" -PropertyName Port -Value $ProbePort | Out-Null
        if (!$?) { Throw $Error[0] }
        Set-ItemProperty 'IIS:\Sites\Default Web Site' -Name serverAutoStart -Value True -Force

        Write-Verbose "Restarting IIS"
        iisreset | Out-Null
        Start-WebSite "Default Web Site"
        if (!$?) { Throw $Error[0] }
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
        [Parameter(Mandatory)]
        [string]$WebAppName,
    
        [Parameter(Mandatory)]
        [string]$AppPoolName,
    
        [Parameter(Mandatory)]
        [string]$AppPoolAccount,
    
        [Parameter(Mandatory)]
        [string]$SiteUrl,

        [Parameter(Mandatory)]
        [Uint32]$Port,

        [Parameter(Mandatory)]
        [Uint32]$ProbePort,
    
        [Parameter(Mandatory)]
        [string]$SiteName,
    
        [Parameter(Mandatory)]
        [string]$SiteTemplate,
    
        [Parameter(Mandatory)]
        [string]$SiteOwner,
		
		[parameter(Mandatory)]
        [PSCredential] $FarmAdministratorCredential,
        
        [parameter(Mandatory)]
        [PSCredential] $SqlAdministratorCredential,

        [UInt32] $RetryCount = 3
    )

    # Set-TargetResource is idempotent
    return $false
}

function CreateWebApplicationWithRetries
{
    param(
       $RetryCount,
       $WebAppName,
       $SiteUrl,
       $SiteTemplate,
       $SiteOwner,
       $AppPoolName,
       $AppPoolAccount,
       $SqlAdministratorCredential
    )
    for($count = 0; $count -lt $RetryCount; $count++)
    {
        try
        {
            Write-Verbose "Creating web application [$SiteUrl]"
		    # Check if the App Pool exists...
		    $appPoolAccountSwitch = ""
		    if (!(Get-SPWebApplication | where { $_.ApplicationPool.Name -eq $AppPoolName })) {
			    $appPoolAccountSwitch = @{ApplicationPoolAccount = $AppPoolAccount}
		    }
		    $hostHeader = $SiteUrl -replace "http://", "" -replace "https://", ""
		    $authProvider = New-SPAuthenticationProvider -UseWindowsIntegratedAuthentication -UseBasicAuthentication
		    $spwebapp = New-SPWebApplication -Name $WebAppName `
										     -URL $SiteUrl `
										     -Port $Port `
										     -HostHeader $hostHeader `
										     -ApplicationPool $AppPoolName @appPoolAccountSwitch `
										     -AuthenticationProvider $authProvider `
                                             -DatabaseCredentials $SqlAdministratorCredential `
										     -DatabaseName "SP_WSS_Content"
		    if (!$?) { Throw $Error[0] }
		    Write-Verbose "Created Web Application [$WebAppName] at [http:\\${SiteUrl}:$Port]."

		    $spsite = New-SPSite -Name $SiteName -URL $SiteUrl -Template $SiteTemplate -OwnerAlias $SiteOwner
		    if (!$?) { Throw $Error[0] }
		    Write-Verbose "Created site collection [$SiteName]."
    
		    New-SPAlternateUrl -WebApplication $SiteUrl -URL $SiteUrl -Zone Default
		    if (!$?) { Throw $Error[0] }
		    Write-Verbose "Added Alternative Access Mapping for Web App."
            break
        }
        catch
        {
            # If this is the last retry attempt then give up and re-throw...
            if($count -eq ($RetryCount - 1))
            {
                Throw
            }
            else
            {
                $errorMessage = $_.Exception.Message
                Write-Verbose "Commencing retry since web application could not be created. Error :: $errorMessage"
                $spwebapp = Get-SPWebApplication $WebAppName
                if($spwebapp)
                {
                    $spwebapp | Remove-SPWebApplication -Confirm:$false
                }
            }
        }
    }
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
