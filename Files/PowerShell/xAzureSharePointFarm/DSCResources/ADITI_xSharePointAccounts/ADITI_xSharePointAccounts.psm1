#
# xSharePointAccounts: DSC resource to create Active Directory user accounts for SharePoint.
#

#
# The Get-TargetResource cmdlet.
#
function Get-TargetResource
{
    param
    (	
        [parameter(Mandatory)]
        [string] $OuName,

        [parameter(Mandatory)]
        [string] $FarmAdminPassword,
        
        [parameter(Mandatory)]
        [PSCredential] $DomainAdministratorCredential
    )

    

    $retvalue = @{
        Accounts = "SP_Services", "SP_WebAppPool", "SP_PortalAppPool", "SP_ProfilesAppPool", `
                    "SP_SearchService", "SP_ProfileSync", "SP_SearchContent", "SP_SuperCacheUser", "SP_CacheSuperReader"        
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
        [string] $OuName,

        [parameter(Mandatory)]
        [string] $FarmAdminPassword,
        
        [parameter(Mandatory)]
        [PSCredential] $DomainAdministratorCredential
    )

    CreateADUser -ADUserName "SP_Services" -Password $FarmAdminPassword -DomainAdministratorCredential $DomainAdministratorCredential -OuName $OuName
    CreateADUser -ADUserName "SP_WebAppPool" -Password $FarmAdminPassword -DomainAdministratorCredential $DomainAdministratorCredential -OuName $OuName
    CreateADUser -ADUserName "SP_PortalAppPool" -Password $FarmAdminPassword -DomainAdministratorCredential $DomainAdministratorCredential -OuName $OuName
    CreateADUser -ADUserName "SP_ProfilesAppPool" -Password $FarmAdminPassword -DomainAdministratorCredential $DomainAdministratorCredential -OuName $OuName
    CreateADUser -ADUserName "SP_SearchService" -Password $FarmAdminPassword -DomainAdministratorCredential $DomainAdministratorCredential -OuName $OuName

    CreateADUser -ADUserName "SP_ProfileSync" -Password $FarmAdminPassword -DomainAdministratorCredential $DomainAdministratorCredential -OuName $OuName
    CreateADUser -ADUserName "SP_SearchContent" -Password $FarmAdminPassword -DomainAdministratorCredential $DomainAdministratorCredential -OuName $OuName
    CreateADUser -ADUserName "SP_SuperCacheUser" -Password $FarmAdminPassword -DomainAdministratorCredential $DomainAdministratorCredential -OuName $OuName
    CreateADUser -ADUserName "SP_CacheSuperReader" -Password $FarmAdminPassword -DomainAdministratorCredential $DomainAdministratorCredential -OuName $OuName
}

# 
# Test-TargetResource
#

function Test-TargetResource  
{
    param
    (	
        [parameter(Mandatory)]
        [string] $OuName,

        [parameter(Mandatory)]
        [string] $FarmAdminPassword,
        
        [parameter(Mandatory)]
        [PSCredential] $DomainAdministratorCredential
    )

    # Set-TargetResource is idempotent
    return $false
}

function CreateADUser(
    [Parameter(Mandatory)]
    [string]$ADUserName,
    [Parameter(Mandatory)]
    [string]$Password,
    [parameter(Mandatory)]
    [PSCredential] $DomainAdministratorCredential,
    # OrgUnit. Will be created if necessary. Optional.
    [string]$OuName)
{
	# Get the logged-on user's domain in DN form 
	$Mydom = (Get-ADDomain -Credential $DomainAdministratorCredential -ErrorAction Stop).DistinguishedName 

	# Build the full DN of the target path
	$path = "CN=Users,$Mydom"
	if ($OuName)
	{
		# Check if the target OU exists. If not, create it. 
		$OU = Get-ADOrganizationalUnit -Credential $DomainAdministratorCredential -Filter { Name -eq $OuName } -ErrorAction SilentlyContinue
		if (!$OU)
		{
			Write-Verbose "Creating OrganizationalUnit [$OuName] in [$Mydom]"
			New-ADOrganizationalUnit -Credential $DomainAdministratorCredential -Name $OuName -Path $Mydom
			if (!$?)
			{
				# It may have created the OU despite reporting errors. Let's check.
				$OU = Get-ADOrganizationalUnit -Credential $DomainAdministratorCredential -Filter { Name -eq $OuName } -ErrorAction SilentlyContinue
				if (!$OU) { Throw "Failed to create OrganizationalUnit [$OuName]." }
				Write-Verbose "OrganizationalUnit [$OuName] exists."
			}
		}

		$path = "OU=$OuName,$Mydom" 
	}
    
	# Create user if needed
	$distinguishedName = "CN=$ADUserName,$path"
    Write-Verbose -Message "ADUser: $distinguishedName"
	$user = Get-ADUser -Credential $DomainAdministratorCredential -Filter { DistinguishedName -eq $distinguishedName } -ErrorAction SilentlyContinue
	if (!$user)
	{
		Write-Verbose "Creating AD User [$ADUserName ($distinguishedName)]"
		New-ADUser -SamAccountName $ADUserName `
				   -Name $ADUserName `
				   -Path $path `
				   -Enabled $true `
				   -ChangePasswordAtLogon $false `
				   -PasswordNeverExpires $true `
                   -Credential $DomainAdministratorCredential `
				   -AccountPassword (ConvertTo-SecureString $Password -AsPlainText -force) | Out-Null
		if (!$?)
		{
			# It may have created the User despite reporting errors. Let's check.
			$user = Get-ADUser -Credential $DomainAdministratorCredential -Filter { DistinguishedName -eq $distinguishedName } -ErrorAction SilentlyContinue
			if (!$user) { Throw "Failed to create AD User [$ADUserName ($distinguishedName)]." }
			Write-Verbose "AD User [$($user.Name) ($($user.DistinguishedName))] exists."
		}
	}
	else
	{
		Write-Verbose "AD User [$($user.Name) ($($user.DistinguishedName))] already exists."
	}
}
