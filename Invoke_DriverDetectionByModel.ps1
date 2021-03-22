param (
	[parameter(Mandatory = $true, HelpMessage = "Set the URI for the ConfigMgr WebService.")]
	[ValidateNotNullOrEmpty()]
	[string]$URI,
	
	[parameter(Mandatory = $true, HelpMessage = "Specify the known secret key for the ConfigMgr WebService.")]
	[ValidateNotNullOrEmpty()]
	[string]$SecretKey,
	
	[parameter(Mandatory = $false, HelpMessage = "Define a filter used when calling ConfigMgr WebService to only return objects matching the filter.")]
	[ValidateNotNullOrEmpty()]
	[string]$Filter = "Driver"
)
Begin {
	# Load Microsoft.SMS.TSEnvironment COM object
	try {
		$TSEnvironment = New-Object -ComObject Microsoft.SMS.TSEnvironment -ErrorAction Continue
	}
	catch [System.Exception] {
		Write-Warning -Message "Unable to construct Microsoft.SMS.TSEnvironment object"
	}
}
Process {
	# Set Log Path
    $LogsDirectory = "C:\Windows\temp"

# Functions

    function Invoke-Executable {
		param (
			[parameter(Mandatory = $true, HelpMessage = "Specify the file name or path of the executable to be invoked, including the extension")]
			[ValidateNotNullOrEmpty()]
			[string]$FilePath,
			[parameter(Mandatory = $false, HelpMessage = "Specify arguments that will be passed to the executable")]
			[ValidateNotNull()]
			[string]$Arguments
		)
		
		# Construct a hash-table for default parameter splatting
		$SplatArgs = @{
			FilePath = $FilePath
			NoNewWindow = $true
			Passthru = $true
			ErrorAction = "Stop"
		}
		
		# Add ArgumentList param if present
		if (-not ([System.String]::IsNullOrEmpty($Arguments))) {
			$SplatArgs.Add("ArgumentList", $Arguments)
		}
		
		# Invoke executable and wait for process to exit
		try {
			$Invocation = Start-Process @SplatArgs
			$Invocation.WaitForExit()
		}
		catch [System.Exception] {
			Write-Warning -Message $_.Exception.Message; break
		}
		
		return $Invocation.ExitCode
	}
	
    function Write-CMLogEntry {
		param (
			[parameter(Mandatory = $true, HelpMessage = "Value added to the log file.")]
			[ValidateNotNullOrEmpty()]
			[string]$Value,
			[parameter(Mandatory = $true, HelpMessage = "Severity for the log entry. 1 for Informational, 2 for Warning and 3 for Error.")]
			[ValidateNotNullOrEmpty()]
			[ValidateSet("1", "2", "3")]
			[string]$Severity,
			[parameter(Mandatory = $false, HelpMessage = "Name of the log file that the entry will written to.")]
			[ValidateNotNullOrEmpty()]
			[string]$FileName = "UA_ApplyDriverPackage.log"
		)
		# Determine log file location
		$LogFilePath = Join-Path -Path $LogsDirectory -ChildPath $FileName
		
		# Construct time stamp for log entry
		if (-not(Test-Path -Path 'variable:global:TimezoneBias')) {
			[string]$global:TimezoneBias = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
			if ($TimezoneBias -match "^-") {
				$TimezoneBias = $TimezoneBias.Replace('-', '+')
			}
			else {
				$TimezoneBias = '-' + $TimezoneBias
			}
		}
		$Time = -join @((Get-Date -Format "HH:mm:ss.fff"), $TimezoneBias)
		
		# Construct date for log entry
		$Date = (Get-Date -Format "MM-dd-yyyy")
		
		# Construct context for log entry
		$Context = $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
		
		# Construct final log entry
		$LogText = "<![LOG[$($Value)]LOG]!><time=""$($Time)"" date=""$($Date)"" component=""ApplyDriverPackage"" context=""$($Context)"" type=""$($Severity)"" thread=""$($PID)"" file="""">"
		
		# Add value to log file
		try {
			Out-File -InputObject $LogText -Append -NoClobber -Encoding Default -FilePath $LogFilePath -ErrorAction Stop
		}
		catch [System.Exception] {
			Write-Warning -Message "Unable to append log entry to ApplyDriverPackage.log file. Error message at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
		}
	}

    function Invoke-CMDownloadContent {
		param (
			[parameter(Mandatory = $true, ParameterSetName = "NoPath", HelpMessage = "Specify a PackageID that will be downloaded.")]
			[Parameter(ParameterSetName = "CustomPath")]
			[ValidateNotNullOrEmpty()]
			#[ValidatePattern("^[A-Z0-9]{3}[A-F0-9]{5}$")]
			[string]$PackageID,
			[parameter(Mandatory = $true, ParameterSetName = "NoPath", HelpMessage = "Specify the download location type.")]
			[Parameter(ParameterSetName = "CustomPath")]
			[ValidateNotNullOrEmpty()]
			[ValidateSet("Custom", "TSCache", "CCMCache")]
			[string]$DestinationLocationType,
			[parameter(Mandatory = $true, ParameterSetName = "NoPath", HelpMessage = "Save the download location to the specified variable name.")]
			[Parameter(ParameterSetName = "CustomPath")]
			[ValidateNotNullOrEmpty()]
			[string]$DestinationVariableName,
			[parameter(Mandatory = $true, ParameterSetName = "CustomPath", HelpMessage = "When location type is specified as Custom, specify the custom path.")]
			[ValidateNotNullOrEmpty()]
			[string]$CustomLocationPath
		)
		# Set OSDDownloadDownloadPackages
		Write-CMLogEntry -Value "Setting task sequence variable OSDDownloadDownloadPackages to: $($PackageID)" -Severity 1
		$TSEnvironment.Value("OSDDownloadDownloadPackages") = "$($PackageID)"
		
		# Set OSDDownloadDestinationLocationType
		Write-CMLogEntry -Value "Setting task sequence variable OSDDownloadDestinationLocationType to: $($DestinationLocationType)" -Severity 1
		$TSEnvironment.Value("OSDDownloadDestinationLocationType") = "$($DestinationLocationType)"
		
		# Set OSDDownloadDestinationVariable
		Write-CMLogEntry -Value "Setting task sequence variable OSDDownloadDestinationVariable to: $($DestinationVariableName)" -Severity 1
		$TSEnvironment.Value("OSDDownloadDestinationVariable") = "$($DestinationVariableName)"
		
		# Set OSDDownloadDestinationPath
		if ($DestinationLocationType -like "Custom") {
			Write-CMLogEntry -Value "Setting task sequence variable OSDDownloadDestinationPath to: $($CustomLocationPath)" -Severity 1
			$TSEnvironment.Value("OSDDownloadDestinationPath") = "$($CustomLocationPath)"
		}
		
		# Invoke download of package content
		try {
			Write-CMLogEntry -Value "Starting package content download process, this might take some time" -Severity 1
			
			if ($TSEnvironment.Value("_SMSTSInWinPE") -eq $false) {
				Write-CMLogEntry -Value "Starting package content download process (FullOS), this might take some time" -Severity 1
				$ReturnCode = Invoke-Executable -FilePath (Join-Path -Path $env:windir -ChildPath "CCM\OSDDownloadContent.exe")
			}
			else {
				Write-CMLogEntry -Value "Starting package content download process (WinPE), this might take some time" -Severity 1
				$ReturnCode = Invoke-Executable -FilePath "OSDDownloadContent.exe"
			}
			
			# Match on return code
			if ($ReturnCode -eq 0) {
				Write-CMLogEntry -Value "Successfully downloaded package content with PackageID: $($PackageID)" -Severity 1
			}
			else {
				Write-CMLogEntry -Value "Package content download process failed with return code $($ReturnCode)" -Severity 2
			}
		}
		catch [System.Exception] {
			Write-CMLogEntry -Value "An error occurred while attempting to download package content. Error message at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" -Severity 3; exit 12
		}
		
		return $ReturnCode
	}




$ComputerManufacturer = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Manufacturer).Trim()
    switch -Wildcard ($ComputerManufacturer) {
		"*Microsoft*" {
			$ComputerManufacturer = "Microsoft"
			$ComputerModel = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Model).Trim()
		}
		"*HP*" {
			$ComputerManufacturer = "Hewlett-Packard"
			$ComputerModel = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Model).Trim()
		}
		"*Hewlett-Packard*" {
			$ComputerManufacturer = "Hewlett-Packard"
			$ComputerModel = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Model).Trim()
		}
		"*Dell*" {
			$ComputerManufacturer = "Dell"
			$ComputerModel = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Model).Trim()
		}
		"*Lenovo*" {
			$ComputerManufacturer = "Lenovo"
			$ComputerModel = (Get-WmiObject -Class Win32_ComputerSystemProduct | Select-Object -ExpandProperty Version).Trim()
		}
		"*Panasonic*" {
			$ComputerManufacturer = "Panasonic Corporation"
			$ComputerModel = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Model).Trim()
		}
		"*Viglen*" {
			$ComputerManufacturer = "Viglen"
			$ComputerModel = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Model).Trim()
		}
		"*VMware*" {
			$ComputerManufacturer = "VMware"
			$ComputerModel = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Model).Trim()
		}
	}
$PackageList = New-Object -TypeName System.Collections.ArrayList
$WebService = New-WebServiceProxy -Uri $URI -ErrorAction Stop
$Packages = $WebService.GetCMPackage($SecretKey, $Filter)
foreach ($Package in $Packages) {
    if ($ComputerManufacturer -match $Package.PackageManufacturer) {
			Write-CMLogEntry -Value "Attempting to find a match for driver package: $($Package.PackageName) ($($Package.PackageID))" -Severity 1
			$DetectionContinue = $true
	}
    else {
			$DetectionContinue = $false
	}
    if ($DetectionContinue -eq $true) {
		# Computer detection method matching
		$ComputerDetectionResult = $false
		switch ($ComputerManufacturer) {
			"Hewlett-Packard" {
				$PackageNameComputerModel = $Package.PackageName.Replace("Hewlett-Packard", "HP").Replace(" - ", ":").Split(":").Trim()[1]
			}
			Default {
				$PackageNameComputerModel = $Package.PackageName.Replace($ComputerManufacturer, "").Replace(" - ", ":").Split(":").Trim()[1]
			}
		}

		if ($PackageNameComputerModel -like $ComputerModel) {
			Write-CMLogEntry -Value "Match found for computer model: ($($ComputerModel))" -Severity 1
			$ComputerDetectionResult = $true
											
			# Computer detection failed
			if ($ComputerDetectionResult -ne $true) {
				Write-CMLogEntry -Value "Unable to match computer model using detection method" -Severity 1
			}
		}
	}
    if ($ComputerDetectionResult -eq $true) {
		if (($Package.PackageManufacturer -match $ComputerManufacturer)) {
			# Match operating system criteria per manufacturer for Windows 10 packages only
			Write-CMLogEntry -Value "Attempting to match driver package name for $($ComputerManufacturer)" -Severity 1

			# Add package to list if match is found
			Write-CMLogEntry -Value "Match found for manufacturer, operating system and architecture: $($Package.PackageName) ($($Package.PackageID))" -Severity 1
			Write-CMLogEntry -Value "Adding driver package to list of packages to process" -Severity 1
			$PackageList.Add($Package) | Out-Null
		}
		else {
			Write-CMLogEntry -Value "Driver package does not meet computer model, manufacturer and operating system and architecture criteria: $($Package.PackageName) ($($Package.PackageID))" -Severity 1
		}
	}
	else {
		Write-CMLogEntry -Value "Driver package does not meet computer model criteria: $($Package.PackageName) ($($Package.PackageID))" -Severity 1
	}
}

# Process matching items in package list
		if ($PackageList -ne $null) {
					try {
						# Attempt to download driver package content
						Write-CMLogEntry -Value "Driver package list contains a single match, attempting to download driver package content - $($PackageList[0].PackageID)" -Severity 1
						$DownloadInvocation = Invoke-CMDownloadContent -PackageID $PackageList[0].PackageID -DestinationLocationType Custom -DestinationVariableName "OSDDriverPackage" -CustomLocationPath "%_SMSTSMDataPath%\DriverPackage"
						try {
							if ($DownloadInvocation -eq 0) {
								$OSDDriverPackageLocation = $($TSEnvironment.Value('OSDDriverPackage01'))
								Write-CMLogEntry -Value "Driver files storage location set to $($OSDDriverPackageLocation)" -Severity 1
								
								# Apply drivers recursively from downloaded driver package location
								Write-CMLogEntry -Value "Driver package content downloaded successfully, attempting to apply drivers using dism.exe located in: $($OSDDriverPackageLocation)" -Severity 1
								
								# Apply drivers recursively
								$ApplyDriverInvocation = Invoke-Executable -FilePath "Dism.exe" -Arguments "/Image:$($TSEnvironment.Value('OSDTargetSystemDrive'))\ /Add-Driver /Driver:$($OSDDriverPackageLocation) /Recurse"
								
								# Validate driver injection
								if ($ApplyDriverInvocation -eq 0) {
									Write-CMLogEntry -Value "Successfully applied drivers using dism.exe" -Severity 1
								}
								else {
									Write-CMLogEntry -Value "An error occurred while applying drivers (single package match). Continuing with warning code: $($ApplyDriverInvocation). See DISM.log for more details" -Severity 2
								}
							}
							else {
								Write-CMLogEntry -Value "Driver package content download process returned an unhandled exit code: $($DownloadInvocation)" -Severity 3; exit 13
							}
						}
						catch [System.Exception] {
							Write-CMLogEntry -Value "An error occurred while applying drivers (single package match). Error message at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" -Severity 3; exit 14
						}
                    }
					catch [System.Exception] {
						Write-CMLogEntry -Value "An error occurred while downloading driver package content (single package match). Error message at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" -Severity 3; exit 5
					}
		}







} #End Process