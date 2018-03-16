<#
 This script creates the Azure AD applications needed for this sample and updates the configuration files
 for the visual Studio projects from the data in the Azure AD applications.

 Before running this script you need to install the AzureAD cmdlets as an administrator. 
 For this:
 1) Run Powershell as an administrator
 2) in the PowerShell window, type: Install-Module AzureAD

 There are three ways to run this script
 Option1 (interactive)
 ---------------------
 Just run . .\Configue.ps1, and you will be prompted to sign-in (email address, password, and if needed MFA). 
 The script will be run as the signed-in user and will use the tenant in which the user is defined.

 Option 2 (Interactive, but create apps in a specified tenant)
 -------------------------------------------------------------
 If you want to create the apps in a specific tenant, before you run this script
 - In the Azure portal (https://portal.azure.com), choose your active directory tenant, then go to the Properties of the tenant and copy
   the DirectoryID. This is what we'll use in this script for the tenant ID
 - run . .\Configue.ps1 -TenantId [place here the GUID representing the tenant ID]

 Option 2 (non-interactive)
 ---------------------------
 This supposes that you know the credentials of the user under which identity you want to create
 the applications. Here is an example of script you'd want to run in a PowerShell Window
   $secpasswd = ConvertTo-SecureString "[Password here]" -AsPlainText -Force
   $mycreds = New-Object System.Management.Automation.PSCredential ("[login@tenantName here]", $secpasswd)
   . .\Configure.ps1 -Credential $mycreds
#>

# Adds the requiredAccesses (expressed as a pipe separated string) to the requiredAccess structure
# The exposed permissions are in the $exposedPermissions collection, and the type of permission (Scope | Role) is 
# described in $permissionType
Function AddResourcePermission($requiredAccess, `
                               $exposedPermissions, [string]$requiredAccesses, [string]$permissionType)
{
        foreach($permission in $requiredAccesses.Trim().Split("|"))
        {
            foreach($exposedPermission in $exposedPermissions)
            {
                if ($exposedPermission.Value -eq $permission)
                 {
                    $resourceAccess = New-Object Microsoft.Open.AzureAD.Model.ResourceAccess
                    $resourceAccess.Type = $permissionType # Scope = Delegated permissions | Role = Application permissions
                    $resourceAccess.Id = $exposedPermission.Id # Read directory data
                    $requiredAccess.ResourceAccess.Add($resourceAccess)
                 }
            }
        }
}

#
# Exemple: GetRequiredPermissions "Microsoft Graph"  "Graph.Read|User.Read"
# See also: http://stackoverflow.com/questions/42164581/how-to-configure-a-new-azure-ad-application-through-powershell
Function GetRequiredPermissions([string] $applicationDisplayName, [string] $requiredDelegatedPermissions, [string]$requiredApplicationPermissions, $servicePrincipal)
{
	# If we are passed the service principal we use it directly, otherwise we find it from the display name (which might not be unique)
	if ($servicePrincipal)
	{
		$sp = $servicePrincipal
	}
	else
    {
		$sp = Get-AzureADServicePrincipal -Filter "DisplayName eq '$applicationDisplayName'"
	}
    $appid = $sp.AppId
    $requiredAccess = New-Object Microsoft.Open.AzureAD.Model.RequiredResourceAccess
    $requiredAccess.ResourceAppId = $appid 
    $requiredAccess.ResourceAccess = New-Object System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.ResourceAccess]

    # $sp.Oauth2Permissions | Select Id,AdminConsentDisplayName,Value: To see the list of all the Delegated permissions for the application:
    if ($requiredDelegatedPermissions)
    {
        AddResourcePermission $requiredAccess -exposedPermissions $sp.Oauth2Permissions -requiredAccesses $requiredDelegatedPermissions -permissionType "Scope"
    }
    
    # $sp.AppRoles | Select Id,AdminConsentDisplayName,Value: To see the list of all the Application permissions for the application
    if ($requiredApplicationPermissions)
    {
        AddResourcePermission $requiredAccess -exposedPermissions $sp.AppRoles -requiredAccesses $requiredApplicationPermissions -permissionType "Role"
    }
    return $requiredAccess
}


# Replace the value of an appsettings of a given key in an XML App.Config file.
Function ReplaceSetting([string] $configFilePath, [string] $key, [string] $newValue)
{
    [xml] $content = Get-Content $configFilePath
    $appSettings = $content.configuration.appSettings; 
    $keyValuePair = $appSettings.SelectSingleNode("descendant::add[@key='$key']")
    if ($keyValuePair)
    {
        $keyValuePair.value = $newValue;
    }
    else
    {
        Throw "Key '$key' not found in file '$configFilePath'"
    }
   $content.save($configFilePath)
}


Function ConfigureApplications
{
<#.Description
   This function creates the Azure AD applications for the sample in the provided Azure AD tenant and updates the
   configuration files in the client and service project  of the visual studio solution (App.Config and Web.Config)
   so that they are consistent with the Applications parameters
#> 
    [CmdletBinding()]
    param(
        [PSCredential] $Credential,
        [Parameter(HelpMessage='Tenant ID (This is a GUID which represents the "Directory ID" of the AzureAD tenant into which you want to create the apps')]
        [string] $tenantId
    )

   process
   {
    # $tenantId is the Active Directory Tenant. This is a GUID which represents the "Directory ID" of the AzureAD tenant
    # into which you want to create the apps. Look it up in the Azure portal in the "Properties" of the Azure AD.

    # Login to Azure PowerShell (interactive if credentials are not already provided:
    # you'll need to sign-in with creds enabling your to create apps in the tenant)
    if (!$Credential -and $TenantId)
    {
        $creds = Connect-AzureAD -TenantId $tenantId
    }
    else
    {
        if (!$TenantId)
        {
            $creds = Connect-AzureAD -Credential $Credential
        }
        else
        {
            $creds = Connect-AzureAD -TenantId $tenantId -Credential $Credential
        }
    }

    if (!$tenantId)
    {
        $tenantId = $creds.Tenant.Id
    }
    $tenant = Get-AzureADTenantDetail
    $tenantName =  ($tenant.VerifiedDomains | Where { $_._Default -eq $True }).Name

   # Create the service AAD application
   Write-Host "Creating the AAD appplication (TodoListService-ManualJwt)"
   $serviceAadApplication = New-AzureADApplication -DisplayName "TodoListService-ManualJwt" `
                                                   -HomePage "https://localhost:44324" `
                                                   -IdentifierUris "https://$tenantName/TodoListService-ManualJwt" `
                                                   -PublicClient $False
   $serviceServicePrincipal = New-AzureADServicePrincipal -AppId $serviceAadApplication.AppId -Tags {WindowsAzureActiveDirectoryIntegratedApp}
   Write-Host "Done."

   # Create the client AAD application
   Write-Host "Creating the AAD appplication (TodoListClient-ManualJwt)"
   $clientAadApplication = New-AzureADApplication -DisplayName "TodoListClient-ManualJwt" `
                                                  -ReplyUrls "https://TodoListClient-ManualJwt" `
                                                  -PublicClient $True
   $clientServicePrincipal = New-AzureADServicePrincipal -AppId $clientAadApplication.AppId -Tags {WindowsAzureActiveDirectoryIntegratedApp}
   Write-Host "Done."

   # Add Required Resources Access (from 'client' to 'service')
   Write-Host "Getting access from 'client' to 'service'"
   $requiredResourcesAccess = New-Object System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.RequiredResourceAccess]
   $requiredPermissions = GetRequiredPermissions -applicationDisplayName "TodoListService-ManualJwt" `
                                                 -requiredDelegatedPermissions "user_impersonation";
   $requiredResourcesAccess.Add($requiredPermissions)
   Set-AzureADApplication -ObjectId $clientAadApplication.ObjectId -RequiredResourceAccess $requiredResourcesAccess
   Write-Host "Granted."

   # Update config file for 'service'
   $configFile = $pwd.Path + "\..\TodoListService-ManualJwt\Web.Config"
   Write-Host "Updating the sample code ($configFile)"
   ReplaceSetting -configFilePath $configFile -key "ida:Tenant" -newValue $tenantName
   ReplaceSetting -configFilePath $configFile -key "ida:Audience" -newValue $serviceAadApplication.IdentifierUris

   # Update config file for 'client'
   $configFile = $pwd.Path + "\..\TodoListClient\App.Config"
   Write-Host "Updating the sample code ($configFile)"
   ReplaceSetting -configFilePath $configFile -key "ida:Tenant" -newValue $tenantName
   ReplaceSetting -configFilePath $configFile -key "ida:ClientId" -newValue $clientAadApplication.AppId
   ReplaceSetting -configFilePath $configFile -key "ida:RedirectUri" -newValue $clientAadApplication.ReplyUrls
   ReplaceSetting -configFilePath $configFile -key "todo:TodoListResourceId" -newValue $serviceAadApplication.IdentifierUris
   ReplaceSetting -configFilePath $configFile -key "todo:TodoListBaseAddress" -newValue $serviceAadApplication.HomePage
  }
}

# Run interactively (will ask you for the tenant ID)
ConfigureApplications -Credential $Credential -tenantId $TenantId