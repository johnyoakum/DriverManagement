# Set Initial Variables
$DriverCatalog = "http://downloads.dell.com/catalog/DriverPackCatalog.cab"
$LocalDriverCache = "{DellDriverCabXMLFileDownloadLocation}"
$URI = "{Location of Config Manager Web Service}"
$SecretKey = "{Secret Key for Webservice}"
$Filter = "Drivers"
$MECMDrivers = @()
$DellDrivers = @()
$DriverCabDownloadLocation = "{DellDriverCabDownloadLocation}"
$DriverStorageBasePath = "E:\Sources\Drivers\Dell"
$LogFileName = "DellAutomatedDrivers_$(Get-Date -Format yyyyMMddTHHmm).log"

# ********************** Functions **************************
function Write-CMLogEntry {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'Value added to the log file.')]
        [ValidateNotNullOrEmpty()]
        [string]$Value,
        [parameter(Mandatory = $true, HelpMessage = 'Severity for the log entry. 1 for Informational, 2 for Warning and 3 for Error.')]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('1', '2', '3')]
        [string]$Severity
    )
    # Determine log file location
    $LogFilePath = Join-Path -Path {LogFilePath} -ChildPath $LogFileName
		
    # Construct time stamp for log entry
    $Time = -join @((Get-Date -Format 'HH:mm:ss.fff'), '+', (Get-WmiObject -Class Win32_TimeZone | Select-Object -ExpandProperty Bias))
		
    # Construct date for log entry
    $Date = (Get-Date -Format 'MM-dd-yyyy')
		
    # Construct context for log entry
    $Context = $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
		
    # Construct final log entry
    $LogText = "<![LOG[$($Value)]LOG]!><time=""$($Time)"" date=""$($Date)"" component=""DellAutomatedDrivers"" context=""$($Context)"" type=""$($Severity)"" thread=""$($PID)"" file="""">"
		
    # Add value to log file
    try {
        Out-File -InputObject $LogText -Append -NoClobber -Encoding Default -FilePath $LogFilePath -ErrorAction Stop
    }
    catch {
        Write-Warning -Message "Unable to append log entry to PackageMapping.log file. Error message at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    }
}


# Test for Available Space
$Drives = Get-CimInstance -Class CIM_LogicalDisk | Select-Object @{Name="Size(GB)";Expression={$_.size/1gb}}, @{Name="Free Space(GB)";Expression={$_.freespace/1gb}}, @{Name="Free (%)";Expression={"{0,6:P0}" -f(($_.freespace/1gb) / ($_.size/1gb))}}, DeviceID, DriveType | Where-Object DriveType -EQ '3'
$DriveSpace = $Drives | Where-Object DeviceID -eq "E:"
If($DriveSpace.'Free Space(GB)' -le 100) {
    Write-CMLogEntry -Value "Not enough free space on drive, exiting script..." -Severity 3
    exit 1
}

# **********************   Get All Drivers Availble through Dell Enterprise Cab Files *******************

# Download Driver Cab Listing
Write-CMLogEntry -Value "Removing Old Catalog if it exists" -Severity 1
If(Test-Path $LocalDriverCache\DriverPackCatalog.cab){Remove-Item -path C:\DellDrivers\* -recurse}

Write-CMLogEntry -Value "Downloading Dell Driver Pack Catalog" -Severity 1
(New-Object System.Net.WebClient).DownloadFile($DriverCatalog, "$LocalDriverCache\DriverPackCatalog.cab")

If(!(Test-Path $LocalDriverCache\DriverPackCatalog.cab)){
    Write-CMLogEntry -Value "Error... Unable to download new cab file" -Severity 3
    exit 1
}

Write-CMLogEntry -Value "Expanding Driver Cab File XML" -Severity 1
expand "$LocalDriverCache\DriverPackCatalog.cab" "$LocalDriverCache\DriverPackCatalog.xml" | out-string | write-verbose

# Import in XML file for processing
Write-CMLogEntry -Value "Importing Driver Catalog XML File" -Severity 1
[xml]$DellDriverCatalog = get-content "$LocalDriverCache\DriverPackCatalog.xml" -ErrorAction Stop

# Filter out items that do not support Windows 10
Write-CMLogEntry -Value "Filtering out the list to only get Windows 10 Drivers" -Severity 1
$SupportedList = $DellDriverCatalog.DriverPackManifest.DriverPackage | 
    Where-Object { $_.SupportedOperatingSystems.OperatingSystem.osCode -match "(Windows10)" }

# Store the models of computers that Dell can autoupdate packages for
Write-CMLogEntry -Value "Storing only those models that Dell can update packages for" -Severity 1
$DellModelsFound = $SupportedList.SupportedSystems.Brand.Model.Name.Trim()

ForEach($SupportedModel in $SupportedList){
    ForEach($Model in $SupportedModel.SupportedSystems.Brand.Model.Name.Trim()) {
    $DellDrivers += [PSCustomObject]@{
        Model = $Model
        Version = $SupportedModel.dellVersion
    }
    }
}

$DellFilteredDrivers = $DellDrivers | Sort-Object Model -Unique

# **********************   Get list of Dell drivers listed in MECM   **********************************

# Create the web service to get the drivers we have published in MECM
Write-CMLogEntry -Value "Creating the webservice to get existing driver packages from SCCM" -Severity 1
$WebService = New-WebServiceProxy -Uri $URI -ErrorAction Stop

# Get all the driver package details from MECM
Write-CMLogEntry -Value "Getting Current list of driver packages from MECM" -Severity 1
$Packages = $WebService.GetCMPackage($SecretKey, $Filter)

# Filter driver packages to just those from Dell
Write-CMLogEntry -Value "Filtering out driver packages that are only Dell" -Severity 1
$DellPackages = $Packages | Where-Object {$_.PackageManufacturer -eq "Dell"} | Select-Object -Property PackageName,PackageVersion


ForEach ($DellPackage in $DellPackages) {
    #Create a new array with just the model names
        $MECMDrivers += [PSCustomObject]@{
            Model = $DellPackage.PackageName.SubString(15,$DellPackage.PackageName.Length - 32)
            Version = $DellPackage.PackageVersion
        }
}

# Pull only those that have updated drivers
$ComparisonResults = Compare-Object -ReferenceObject $DellFilteredDrivers -DifferenceObject $MECMDrivers -Property Model, Version -IncludeEqual | Where-Object {$_.SideIndicator -eq "<="}

# *********************** Compare list of drivers we have versus ones we do not have ******************

$DriversToGet = $ComparisonResults.Model | Get-Unique -AsString

Write-CMLogEntry -Value "List of Models Updating" -Severity 1

ForEach($Model in $DriversToGet){
    Write-CMLogEntry -Value "`t$Model" -Severity 1
}

# Create the Web Client to download the cab file with
$wc = New-Object System.Net.WebClient

#Set MECM Variables
$SiteCode = "{SiteCode}" # Site code 
$ProviderMachineName = "{SiteServerFQDN}" # SMS Provider machine name

# Import in the Config Manager PowerShell Module
if((Get-Module ConfigurationManager) -eq $null) {
    Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1"
}

# Create the MECM Drive
if((Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue) -eq $null) {
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName
}
    	
# Downlad driver packs from Dell, create package in MECM and distribute content
Write-CMLogEntry -Value "Beginning to download drivers from Dell" -Severity 1
ForEach ($Driver in $DriversToGet){
    If ($Driver -ne 'Venue 8 Pro 5830'){
    Write-Host "Getting drivers for $Driver"
    

    Set-Location $DriverCabDownloadLocation

    # Get the driver package to download
    $cabSelected = $DellDriverCatalog.DriverPackManifest.DriverPackage | Where-Object { ($_.SupportedSystems.Brand.Model.Name -eq "$Driver" ) -and ($_.SupportedOperatingSystems.OperatingSystem.majorVersion -eq "10" ) -and ($_.SupportedOperatingSystems.OperatingSystem.osArch -eq "x64")}
    Write-Host $cabSelected

    #$cabDownloadLink = "http://" + $DellDriverCatalog.DriverPackManifest.baseLocation + $cabSelected.path
    $cabDownloadLink = "http://" + $DellDriverCatalog.DriverPackManifest.baseLocation + "/" + $cabSelected.path
    Write-Host $cabDownloadLink

    # Get the filename of the cab file
    $Filename = [System.IO.Path]::GetFileName($cabDownloadLink)
    Write-Host $Filename

    # Set the Destination Path to download the cab file to
    $downlodDestination = "$DriverCabDownloadLocation\$Filename"
    Write-Host $downlodDestination

    # Download the cab file to the download location
    Write-CMLogEntry -Value "Downloading the driver pack for $Driver" -Severity 1
    $wc.DownloadFile($cabDownloadLink, $downlodDestination) | Out-Null
    
    # Test to see if the path already exists of where to store the drivers to and if doesn't exist, create it
    If (!(Test-Path $DriverStorageBasePath\$Driver)){new-item -Path $DriverStorageBasePath -Name $Driver –itemtype directory}
    
    # Remove all files existing in that current location to make it available for updating drivers
    Write-CMLogEntry -Value "Removing existing drivers at $DriverStorageBasePath\$Driver" -Severity 1
    If (Test-Path $DriverStorageBasePath\$Driver){
        Remove-Item $DriverStorageBasePath\$Driver\* -Recurse -Force
    }

    # Expand the cab file into the Driver storage Folder
    Write-CMLogEntry -Value "Expanding $Driver drivers to $DriverStorageBasePath\$Driver" -Severity 1
    Expand $downlodDestination "$DriverStorageBasePath\$Driver" /f:* | Out-Null
	
	# Copy in the USB-C driver for the docks/adapters that they are using at the Dell Factory
	#Write-CMLogEntry -Value "Copying the USB-C driver to the package directory" -Severity 1
	#Copy-Item $ScriptPathParent\"USBC Driver" "$DriverStorageBasePath\$Driver" -Force

    # *********************   Create the package in MECM for the drivers
    
    # Set the current location to be the site code.
    Set-Location "$($SiteCode):\"
    
    # Set Name of Driver Package
    $CMPackage = "Drivers - Dell $Driver - Windows 10 x64"

    # Get the version of drivers for storing
    $DriverRevision = $Filename.Substring(($Filename.Length - 13),3)

	# Check For Driver Package
	$ConfiMgrPackage = Get-CMPackage -Name $CMPackage -Fast | Select-Object PackageID, Version, Name
    
    If ( [string]::IsNullOrEmpty($ConfiMgrPackage) ){
    
        # Create the new package
        Write-CMLogEntry -Value "Driver Pack does not exist, creating it now..." -Severity 1
        Write-CMLogEntry -Value "Creating Driver Pack for $Driver" -Severity 1
	    New-CMPackage -Name "$CMPackage" -path "{\\PathtoContentforpackage}\$Driver" -Manufacturer "Dell"  -Version $DriverRevision | Out-Null

	    # Check For Driver Package
	    $ConfiMgrPackage = Get-CMPackage -Name $CMPackage -Fast | Select-Object PackageID, Version, Name

        # Move Driver package into right folder in MECM
        Write-CMLogEntry -Value "Moving Driver pack into the correct folder in MECM" -Severity 1
	    Move-CMObject -FolderPath {$SiteCode":\Package\Drivers\Dell}" -ObjectID $ConfiMgrPackage.PackageID | Out-Null
    
        # Distribute the drivers to the distribution poiints
        Write-CMLogEntry -Value "Distributing Driver pack to distribution points" -Severity 1
        Start-CMContentDistribution -PackageID $ConfiMgrPackage.PackageID -DistributionPointGroupName "{NameOfDistributionPointGroup}"

    }
    else {
        # Create the new package
        Write-CMLogEntry -Value "`tUpdating Driver Package for $Driver" -Severity 1
	    Set-CMPackage -Id $ConfiMgrPackage.PackageID -path "{\\PathtoContentforpackage}\$Driver" -Version $DriverRevision | Out-Null

        # Distribute the drivers to the distribution poiints
        Write-CMLogEntry -Value "Distributing Driver pack to distribution points" -Severity 1
        Update-CMDistributionPoint -PackageID $ConfiMgrPackage.PackageID
    }

    }
}
}
Write-CMLogEntry -Value "Deleting Downloaded Driver Cab Files" -Severity 1
Remove-Item -Path $($DriverCabDownloadLocation)\* -recurse

Write-CMLogEntry -Value "***************   Script Complete    *****************" -Severity 1