#
# xSharePointManagedAccountsd: DSC resource to create managed accounts in SharePoint.
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
        [string] $DomainName
    )   

    $retvalue = @{
        ManagedAccounts = @("$DomainName\SP_Services", "$DomainName\SP_WebAppPool", "$DomainName\SP_PortalAppPool", "$DomainName\SP_ProfilesAppPool", "$DomainName\SP_SearchService")        
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
        [string] $DomainName
    )    
    
    $FarmAdministratorCredential = New-Object PSCredential $FarmAdmin, (ConvertTo-SecureString $FarmAdminPassword -AsPlainText -Force)	
		
    try
    {		
        ($oldToken, $context, $newToken) = ImpersonateAs -cred $FarmAdministratorCredential               
		
		Write-Verbose "Loading snapin.."
		Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
		
        AddManagedAccounts `
            -ManagedAccounts @("$DomainName\SP_Services", "$DomainName\SP_WebAppPool", "$DomainName\SP_PortalAppPool", "$DomainName\SP_ProfilesAppPool", "$DomainName\SP_SearchService") `
            -FarmAdminPassword $FarmAdminPassword      
        
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
        [string] $DomainName
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

function Get-AdministratorsGroup
{
    Return (Get-WmiObject -Class Win32_Group -computername $env:COMPUTERNAME -Filter "SID='S-1-5-32-544' AND LocalAccount='True'" -errorAction "Stop").Name
}

function AddManagedAccounts(
    [parameter(Mandatory)]
    [string[]] $ManagedAccounts,
    [parameter(Mandatory)]
    [string] $FarmAdminPassword
)
{
    Write-Verbose "Adding Managed Accounts"

    # Cache the members of the local Administrators group
    $builtinAdminGroup = Get-AdministratorsGroup
    $adminGroup = ([ADSI]"WinNT://$env:COMPUTERNAME/$builtinAdminGroup,group")
    # This syntax comes from Ying Li (http://myitforum.com/cs2/blogs/yli628/archive/2007/08/30/powershell-script-to-add-remove-a-domain-user-to-the-local-administrators-group-on-a-remote-machine.aspx)
    $localAdmins = $adminGroup.psbase.invoke("Members") | % {$_.GetType().InvokeMember("Name", 'GetProperty', $null, $_, $null)}

    # Ensure Secondary Logon service is enabled and started
    If ((Get-Service -Name seclogon).Status -ne "Running")
    {
        Write-Verbose "Enabling Secondary Logon service..."
        Set-Service -Name seclogon -StartupType Manual
        Start-Service -Name seclogon
    }

    ForEach ($account in $ManagedAccounts)
    {        		
        $credAccount = New-Object PsCredential $account,(ConvertTo-SecureString $FarmAdminPassword -AsPlaintext -Force)

		# The following was suggested by Matthias Einig (http://www.codeplex.com/site/users/view/matein78)
		# And inspired by http://todd-carter.com/post/2010/05/03/Give-your-Application-Pool-Accounts-A-Profile.aspx & http://blog.brainlitter.com/archive/2010/06/08/how-to-revolve-event-id-1511-windows-cannot-find-the-local-profile-on-windows-server-2008.aspx
		Write-Verbose "Creating local profile for [$account]..."
		$removeAdmin = $false
		$managedAccountDomain,$managedAccountUser = $account -Split "\\",2
		Try
		{
			# Add managed account to local admins (very) temporarily so it can log in and create its profile
			If (!($localAdmins -contains $managedAccountUser))
			{
				([ADSI]"WinNT://$env:COMPUTERNAME/$builtinAdminGroup,group").Add("WinNT://$managedAccountDomain/$managedAccountUser")
				$removeAdmin = $true
			}

			# Spawn a command window using the managed account's credentials, create the profile, and exit immediately
			Start-Process -WorkingDirectory "$env:SYSTEMROOT\System32\" -FilePath "cmd.exe" -ArgumentList "/C" -LoadUserProfile -NoNewWindow -Credential $credAccount -Wait
		}
		Catch
		{
			Write-Warning "Error attempting to create local user profile for [$account]: $_"
		}
		Finally
		{
			# Remove managed account from local admins unless it was already there
			If ($removeAdmin)
			{
				([ADSI]"WinNT://$env:COMPUTERNAME/$builtinAdminGroup,group").Remove("WinNT://$managedAccountDomain/$managedAccountUser")
			}
		}

        $managedAccount = Get-SPManagedAccount | where UserName -eq $account
        If (!$managedAccount)
        {
            Write-Verbose "Registering managed account [$account]..."
            New-SPManagedAccount -Credential $credAccount | Out-Null
            If (!$?) { Throw "Failed to create managed account" }
        }
        Else
        {
            Write-Verbose "Managed account [$account] already exists."
        }
    }
    Write-Verbose "Done Adding Managed Accounts"
}