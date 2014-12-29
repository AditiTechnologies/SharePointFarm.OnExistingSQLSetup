#
# xSharePointDatabasesHighAvailability: DSC resource to SharePoint databases to SQL High Availability (HA) Group.
#

#
# The Get-TargetResource cmdlet.
#
function Get-TargetResource
{
	param
	(	
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $AvailabilityGroupName,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $AvailabilityGroupListenerName,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
	    [string] $DatabaseBackupPath,        
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [PSCredential] $SqlAdministratorCredential,

        [parameter(Mandatory)]
        [PSCredential] $FarmAdministratorCredential
  	)     

    $returnValue = @{
        AvailabilityGroupName = $AvailabilityGroupName               
	}

	$returnValue
}

#
# The Set-TargetResource cmdlet.
#
function Set-TargetResource
{
	param
	(	
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $AvailabilityGroupName,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $AvailabilityGroupListenerName,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
	    [string] $DatabaseBackupPath,        
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [PSCredential] $SqlAdministratorCredential,

        [parameter(Mandatory)]
        [PSCredential] $FarmAdministratorCredential
  	)
   
    $databases = $null
	try
	{
		Add-PSSnapin -Name Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
	}
	catch
	{
		# Ignore and continue. This can happen if the Snapin is already loaded.
	}
    try
    {
        ($oldToken, $context, $newToken) = ImpersonateAs -cred $FarmAdministratorCredential        

        $databases = Get-SPDatabase -ErrorAction Stop
    }
    finally
    {    
        if ($context)
        {
            $context.Undo()
            $context.Dispose()
            CloseUserToken($newToken)
        }
    }

    $env:Path += ";$env:ProgramFiles\Microsoft SQL Server\Client SDK\ODBC\110\Tools\Binn"
    $sa = $SqlAdministratorCredential.UserName
    $saPassword = $SqlAdministratorCredential.GetNetworkCredential().Password    
    $dbServers = GetSqlNodes -agName $AvailabilityGroupName -agListenerName $AvailabilityGroupListenerName -sa $sa -saPassword $saPassword

    # restore database
    foreach($db in $databases.Name)
    {
        foreach($dbServer in $dbServers)
        {
            $role = [int] (sqlcmd -S $dbServer -U $sa -P $saPassword -Q "select role from sys.dm_hadr_availability_replica_states where is_local = 1" -h-1)[0]
            $dbExists = [bool] [int](sqlcmd -S $dbServer -U $sa -P $saPassword -Q "select count(*) from master.sys.databases where name = '$db'" -h-1)[0]
            $dbIsAddedToAg = [bool] [int](sqlcmd -S $dbServer -U $sa -P $saPassword -Q "select count(*) from sys.dm_hadr_database_replica_states inner join sys.databases on sys.databases.database_id = sys.dm_hadr_database_replica_states.database_id where sys.databases.name = '$db'" -h-1)[0]

            if($role -eq 1) # If PRIMARY replica
            {                
                # take backup
                Write-Verbose -Message "Backup to $DatabaseBackupPath .."
                sqlcmd -S $dbServer -U $sa -P $saPassword -Q "backup database $db to disk = '$DatabaseBackupPath\$db.bak' with format"
                sqlcmd -S $dbServer -U $sa -P $saPassword -Q "backup log $db to disk = '$DatabaseBackupPath\$db.log' with noformat"

                if(!$dbIsAddedToAg)
                {
                    sqlcmd -S $dbServer -U $sa -P $saPassword -Q "ALTER AVAILABILITY GROUP $AvailabilityGroupName ADD DATABASE $db"                
                }
            }

            elseif($role -eq 2 -or $role -eq 0 ) # If SECONDARY replica or yet to be added as a replica
            {
                $isJoinedToAg = [bool] [int](sqlcmd -S $dbServer -U $sa -P $saPassword -Q "select count(*) from sys.availability_groups where name = '$AvailabilityGroupName'" -h-1)[0]
                if(!$isJoinedToAg)
                {
                    # Join AG
                    sqlcmd -S $dbServer -U $sa -P $saPassword -Q "ALTER AVAILABILITY GROUP $AvailabilityGroupName JOIN"
                }

                # Restore DB if not exists
                if(!$dbExists)
                {
                    $query = "restore database $db from disk = '$DatabaseBackupPath\$db.bak' with norecovery"
                    Write-Verbose -Message "Query: $query"
                    sqlcmd -S $dbServer -U $sa -P $saPassword -Q $query        

                    $query = "restore log $db from disk = '$DatabaseBackupPath\$db.log' with norecovery"
                    Write-Verbose -Message "Query: $query"
	                sqlcmd -S $dbServer -U $sa -P $saPassword -Q $query                
                }
                        
                if(!$dbIsAddedToAg)
                {
                    # Add database to AG
	                sqlcmd -S $dbServer -U $sa -P $saPassword -Q "ALTER DATABASE $db SET HADR AVAILABILITY GROUP = $AvailabilityGroupName"
                }
            }
        }                
    }
}

#
# The Test-TargetResource cmdlet.
#
function Test-TargetResource
{
	param
	(	
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $AvailabilityGroupName,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $AvailabilityGroupListenerName,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
	    [string] $DatabaseBackupPath,        
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [PSCredential] $SqlAdministratorCredential,

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

function GetSqlNodes($agName, $agListenerName, $sa, $saPassword)
{
    $query = @"
select replica_server_name from sys.availability_replicas
inner join sys.availability_groups on sys.availability_replicas.group_id = sys.availability_groups.group_id
where sys.availability_groups.name = N'$agName'
"@   
    $result = (sqlcmd -S $agListenerName -U $sa -P $saPassword -Q $query -h-1)
    $sqlNodes = @()
    foreach($val in $result)
    {
        if([System.String]::IsNullOrEmpty($val) -or [System.String]::IsNullOrWhiteSpace($val) -or $val.EndsWith('rows affected)'))
        {
            continue;
        }
        $sqlNodes += @($val)
    }
    return $sqlNodes
}

Export-ModuleMember -Function *-TargetResource