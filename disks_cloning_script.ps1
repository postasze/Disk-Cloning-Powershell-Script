#************************************************ *****************************
#*
#* Module Name: Disk cloning program/script
#*
#* Abstract: This is a PowerShell Script file for performing cloning procedure using Macrium Reflect program.
#* 					 Modify to add your own functionality if required.
#*
#* Returns: 0 - Success.
#* 					1 - Error: Invalid XML.
#* 					2 - Error: Cloning failed.
#* 					3 - Error: Not elevated (script will try to execute elevated). That means script was ran without administrator privileges
#* 					4 - Error: No external USB disks connected to computer found (script will only clone to disks attached as external USB).
#* 					5 - Error: No USB disk with correct serial number found (although script can still clone to USB disks with previously unknown serial numbers).
#* 					6 - Error: No USB disk with enough empty space found (script will only clone to USB disks with enough space to contain source disk).
#* 					7 - Error: No source disk found.
#* 					8 - Error: No valid xml file for cloning found.
#* 					9 - Script stopped by the user.
#* 					10 - Error: Couldn't create scheduled, periodic cloning task
#* 					11 - Warning: Cloning procedure was already performed in the current week
#*
#************************************************ *****************************
Param([switch]$s, [switch]$full, [switch]$inc, [switch]$diff, [String]$freq, [String]$g)

[string] $UserName = [Environment]::UserName;
[string] $ScriptPath = $MyInvocation.MyCommand.Definition;
[string] $ReflectFilesPath = "C:\Users\$UserName\Documents\Reflect\";
[string] $ReflectExePath = "C:\Program Files\Macrium\Reflect\Reflect.exe";
[string] $DefaultXmlFilePath = "C:\Users\$UserName\Documents\Reflect\Default_cloning_scheme.xml";
[string] $LogFilePath = "C:\Users\$UserName\Documents\Reflect\cloning_info_log.txt";
[System.IO.FileInfo] $ChosenXmlFile = $null;

#[System.Collections.Generic.List[long]] $AllDiskIDs = [System.Collections.Generic.List[long]]@();
[System.Collections.ArrayList] $ViableTargetDiskDrives = [System.Collections.ArrayList]@();
[System.Collections.ArrayList] $USBDiskDrives = [System.Collections.ArrayList]@();
#[System.Collections.Generic.List[long]] $ViableTargetDiskIDs = [System.Collections.Generic.List[long]]@();
#[System.Collections.Generic.List[string]] $CorrectXmlFiles = [System.Collections.Generic.List[string]]@();
[System.Collections.ArrayList] $CorrectXmlFiles = [System.Collections.ArrayList]@();

#[long] $MainDiskDriveID = 0;
#[long] $TargetDiskDriveID = 0;
[long] $TotalSizeOfMainDisk = 0;
[long] $UsedSpaceInMainDisk = 0;
[long] $FreeSpaceInMainDisk = 0;
[int] $IntReturnValue = 0;
[bool] $BoolReturnValue = $false;

$SourceDiskDrive = $null;
$TargetDiskDrive = $null;

#************************************************ *****************************
#* Func: Main
#*
#* Desc: This is main function of this program/script. It manages the whole cloning procedure
#*
#************************************************ *****************************
Function Main()
{
	Write-Host "`r`n`r`nProgram/script for automatic cloning of hard drives every week`r`n";
	Write-Host "This program/script uses .xml files located in this folder: $ReflectFilesPath`r`n";

	LogScriptRun -log_file_path $LogFilePath;

	[bool] $CheckResult = CheckAdministratorPrivileges;
	if($CheckResult -eq $false) {
		return 3;
	}

	#DisplayScriptParameters;
	DisplayDetailedDisksInfo;

	$IntReturnValue = ManageScheduledCloningTask -script_path $ScriptPath;
	if($IntReturnValue -eq 10) {
		return 10;
	}

	$BoolReturnValue = CheckPreviousCloningAttempts -log_file_path $LogFilePath;
	if($BoolReturnValue -eq $true) {
		Write-Host "The program/script performed the cloning procedure earlier this week"
		Write-Host "One cloning procedure per week is enough";
		return 11;
	}
	else {
		Write-Host "No cloning procedures have been performed successfully this week";
		Write-Host "The program/script will attempt to perform the cloning procedure at this time";
	}

	$SourceDiskDrive = GetMainDiskDrive;

	if($SourceDiskDrive -eq $null) {
	Write-Host "Problem locating the main source disk for the clone routine";
		return 7;
	}

	$TotalSizeOfMainDisk, $UsedSpaceInMainDisk, $FreeSpaceInMainDisk = CalculateMainDiskSize($SourceDiskDrive);

	$USBDiskDrives = CheckDisksConnectedViaUSB;

	if(($USBDiskDrives -eq $null) -or ($USBDiskDrives.Count -eq 0)) {
		Write-Host "Unfortunately, the program/script could not find any external target hard drives connected to the computer via USB"
		Write-Host "You can try to connect a USB drive of sufficient size or check whether the target hard drive is properly connected via USB and whether it is not damaged";
		return 4;
	}

	$ViableTargetDiskDrives = FindViableTargetDisks -usb_disk_drives $USBDiskDrives -used_space_in_main_disk $UsedSpaceInMainDisk;

	if($ViableTargetDiskDrives.Count -eq 0) {
		Write-Host "Unfortunately, the program/script was unable to find any hard drive connected via USB to the computer that was large enough to contain an entire clone of the main source drive.";
		Write-Host("Source main disk space used in gigabytes: {0:F2} GB" -f $($UsedSpaceInMainDisk/1GB));
		Write-Host "Total sizes of hard drives connected to the computer via USB port";
		foreach($USBDiskDrive in $USBDiskDrives) {
			Write-Host ("Disk with ID {0:X8} has free space in gigabytes: {1:F2} GB" -f $($USBDiskDrive.Signature), $($USBDiskDrive.Size/1GB));
		}
		Write-Host "You can try to free up space on the main source disk, or try to connect a larger target hard drive, or check if everything is OK with the target hard drive connected via USB";
		return 6;
	}
	elseif($ViableTargetDiskDrives.Count -eq 1) {
		$TargetDiskDrive = $ViableTargetDiskDrives[0];
	}

	$CorrectXmlFiles = CheckExistenceOfCorrectXmlFiles -reflect_files_path $ReflectFilesPath -source_disk_drive $SourceDiskDrive -target_disk_drives $ViableTargetDiskDrives;

	if($CorrectXmlFiles.Count -gt 0) {
		Write-Host "Found valid xml files that can be used for the cloning procedure";
		$CorrectXmlFiles | ForEach-Object { Write-Host $_.FullName };
		$ChosenXmlFile = SelectBestXmlFile -correct_xml_files @($CorrectXmlFiles);
		$TargetDiskDrive = SelectTargetDiskFromXmlFile -chosen_xml_file $ChosenXmlFile -target_disk_drives $ViableTargetDiskDrives;
	}
	else {
		Write-Host "No valid xml file found to use for cloning procedure";

		if($ViableTargetDiskDrives.Count -gt 1) {
			$TargetDiskDrive = SelectBestTargetDiskDrive -target_disk_drives $ViableTargetDiskDrives -default_xml_file_path $DefaultXmlFilePath;
		}

		$ChosenXmlFile = CreateNewCloningXmlFile -reflect_files_path $ReflectFilesPath -source_disk_drive $SourceDiskDrive -target_disk_drive $TargetDiskDrive -default_xml_file $DefaultXmlFilePath;
	}

	if($ChosenXmlFile -eq $null) {
		Write-Host "Problem finding a valid xml file for the clone routine in this folder $ReflectFilesPath";
		Write-Host "You can create a new valid xml file for the clone routine using Macrium Reflect"
		return 8;
	}

	StartReflectPrograms;

	[bool] $ValidationResult = ValidateXmlFile -reflect_exe_path $ReflectExePath -chosen_xml_file $ChosenXmlFile;
	if($ValidationResult -eq $false) {
		return 1;
	}

	$IntReturnValue = FormatTargetDisk -target_disk_drive $TargetDiskDrive;
	if($IntReturnValue -eq 9) {
		Write-Host "Unfortunately, the cloning procedure cannot continue without properly formatting the target disk";
		return 9;
	}

	$CloningResultCode = PerformCloningProcedure -reflect_exe_path $ReflectExePath -chosen_xml_file $ChosenXmlFile;

	LogCloningProcedure -log_file_path $LogFilePath -source_disk_id $($SourceDiskDrive.Signature.ToString("X8")) -target_disk_id $($TargetDiskDrive.Signature.ToString("X8"));

	#Write-Host "`r`nProgram/script ended with the following code $CloningResultCode.`r`n";
	#exit $CloningResultCode;
	return $CloningResultCode;
}

#************************************************ *****************************
#* Func: CheckAdministratorPrivileges
#*
#* Desc: Checks administrator privileges and elevates this script for UAC
#* if script doesn't have administrator privileges yet.
#* This means that only one UAC Elevation prompt is displayed and
#* functions/programs will not fail if they require admin privileges.
#*
#************************************************ *****************************
Function CheckAdministratorPrivileges()
{
	# Only elevate if not ran from the task scheduler.
	Write-Host "`r`n * Checking if the program/script was run with administrator privileges`r`n" # -NoNewLine;
	#Write-Host "s: $s"
	#if (-Not $s)
	#{
		# Check to see if the script is currently running "as Administrator"
		if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator"))
		{
			Write-Host 'The program/script was not properly run with administrator privileges.';
			Write-Host "The program must be run with administrator privileges by right-clicking on the program and selecting run as administrator";
			return $false;
		}
	#}
	Write-Host 'The program/script was successfully launched with administrator privileges.';
	return $true;
}

#************************************************ *****************************
#* Func: StartReflectPrograms
#*
#* Desc: This is an auxiliary function. It starts all foreground and background Macrium Reflect programs that are necessary for cloning procedure
#* This function also starts MacriumService and sets its startup as manual so that it can be launched
#* Background programs that this function starts: ReflectMonitor.exe and ReflectUI.exe
#*
#************************************************ *****************************
Function StartReflectPrograms()
{
	Write-Host "";
	Write-Host "Enabling Macrium ReflectUI.exe and ReflectMonitor.exe to run in the background if they are not running";
	Start-Process -FilePath "C:\Program Files\Macrium\Common\ReflectUI.exe";
	Start-Process -FilePath "C:\Program Files\Macrium\Common\ReflectMonitor.exe";

	Write-Host "Enable MacriumService if not running";
	Set-Service -Name "MacriumService" -StartupType Manual;
	Start-Service -Name "MacriumService" -ErrorAction SilentlyContinue;
}

#************************************************ *****************************
#* Func: StopReflectPrograms
#*
#* Desc: This is an auxiliary function. It stops all foreground and background Macrium Reflect programs when they are no longer needed
#* This function also stops MacriumService and disables it so that it doesn't start automatically with Windows startup
#* This function also turns off automatic startup of ReflectUI.exe which is set as automatic startup program after installation of Macrium Reflect
#* Foreground programs that this function stops: Reflect.exe, and ReflectBin.exe
#* Background programs that this function stops: ReflectMonitor.exe and ReflectUI.exe
#*
#************************************************ *****************************
Function StopReflectPrograms()
{
	Write-Host "";
	Write-Host "Disabling Macrium Reflect.exe and ReflectBin.exe if running";
	if(-not ((Get-Process -Name "Reflect" -ErrorAction SilentlyContinue) -eq $null)) {
		Stop-Process -Name "Reflect";
	}
	if(-not ((Get-Process -Name "ReflectBin" -ErrorAction SilentlyContinue) -eq $null)) {
		Stop-Process -Name "ReflectBin";
	}

	Write-Host "Disabling Macrium ReflectUI.exe and ReflectMonitor.exe programs running in the background if they are running";
	if(-not ((Get-Process -Name "ReflectUI" -ErrorAction SilentlyContinue) -eq $null)) {
		Stop-Process -Name "ReflectUI";
	}
	if(-not ((Get-Process -Name "ReflectMonitor" -ErrorAction SilentlyContinue) -eq $null)) {
		Stop-Process -Name "ReflectMonitor";
	}

	Write-Host "Disabling the MacriumService service if it is running";
	if(-not ((Get-Service -Name "MacriumService" -ErrorAction SilentlyContinue) -eq $null)) {
		Stop-Service -Name "MacriumService" -Force -ErrorAction SilentlyContinue;
		Set-Service -Name "MacriumService" -StartupType Disabled -ErrorAction SilentlyContinue;
		Stop-Process -Name "MacriumService" -Force -ErrorAction SilentlyContinue;
		Stop-Process -Name "MacriumService.exe" -Force -ErrorAction SilentlyContinue;

		#if(!((Get-Service -Name "MacriumService" | select Status) -ceq 'Stopped')) {
			taskkill /f /t /im "MacriumService.exe" 1>$null 2>&1
		#}
	}
}

#************************************************ *****************************
#* Func: DisplayScriptParameters
#*
#* Desc: This is an auxiliary function that displays the parameters with which this script was invoked.
#*
#************************************************ *****************************
Function DisplayScriptParameters()
{
	Write-Host "`r`nDisplaying parameters with which this program/script was launched (not very important):";

	Write-Host "s: $s"
	Write-Host "full: $full"
	Write-Host "inc: $inc"
	Write-Host "diff: $diff"
	Write-Host "freq: $freq"
	Write-Host "g: $g"
}

#************************************************ *****************************
#* Func: DisplayGeneralDisksInfo
#*
#* Desc: This is an auxiliary function that displays basic information of all disks attached to computer.
#*
#************************************************ *****************************
Function DisplayGeneralDisksInfo()
{
	Write-Host "`r`nDisplay general information about disks connected to the computer:";
	Get-WmiObject -Class Win32_DiskDrive | select Description, DeviceID, MediaType, Model, Partitions, SerialNumber, Signature, Size, Status, SystemName
}

#************************************************ *****************************
#* Func: DisplayDetailedDisksInfo
#*
#* Desc: This is an auxiliary function that displays all useful information of all disks attached to computer.
#*
#************************************************ *****************************
Function DisplayDetailedDisksInfo()
{
	Write-Host "`r`nDisplay detailed information about disks connected to the computer:";

	$diskDrives = Get-WmiObject -Class win32_diskdrive;
	Out-Host -InputObject "Number of detected hard drives connected to the computer: $($diskDrives.Count)`r`n" ;

	foreach($diskDrive in $diskDrives)
	{
		Out-Host -InputObject "Disk device name: $($diskDrive.DeviceID.substring(4))";
		Out-Host -InputObject "Disk index: $($diskDrive.Index)";
		Out-Host -InputObject "Disk model name: $($diskDrive.Model)";
		Out-Host -InputObject "Disk Description: $($diskDrive.Description)";
		Out-Host -InputObject "Disk type: $($diskDrive.MediaType)";
		Out-Host -InputObject "Disk Interface: $($diskDrive.InterfaceType)";
		Out-Host -InputObject "Number of disk partitions: $($diskDrive.Partitions)";
		Out-Host -InputObject "Disk serial number: $($diskDrive.SerialNumber)";
		Out-Host -InputObject "Disk ID (decimal): $($diskDrive.Signature)";
		Out-Host -InputObject "Disk ID (hex): $($diskDrive.signature.ToString("X8"))";
		Out-Host -InputObject "Disk size in bytes: $($diskDrive.Size) B";
		Out-Host -InputObject ("Disk size in gigabytes: {0:F2} GB" -f $($diskDrive.Size/1GB));
		#Out-Host -InputObject ("Disk size in gigabytes: {0:F2} GB" -f $($diskDrive.Size/[Math]::Pow(1024, 3)));
		Out-Host -InputObject "Disk Status: $($diskDrive.Status)";
		Out-Host -InputObject "Name of the computer to which the disk is connected: $($diskDrive.SystemName)";

		# Partitions information
		Out-Host -InputObject "`r`n Display information about disk partitions:`r`n";

		$partitions = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID=`"$($diskDrive.DeviceID.replace('\','\\'))`"} WHERE AssocClass = Win32_DiskDriveToDiskPartition";

		foreach($partition in $partitions)
		{
			Out-Host -InputObject "Partition name: $($partition.Name)";
			#Out-Host -InputObject "Partition name: $($partition.Caption)";
			Out-Host -InputObject "Index of the disk containing this partition: $($partition.DiskIndex)";
			Out-Host -InputObject "Partition Index: $($partition.Index)";
			Out-Host -InputObject "Partition description: $($partition.Description)";
			Out-Host -InputObject "Partition size in bytes: $($partition.Size) B";
			Out-host -InputObject ("Partition size in gigabytes: {0:F2} GB" -f $($partition.Size/1GB));
			#Out-Host -InputObject "Partition Free Space: $($partition.FreeSpace)";

			Out-Host -InputObject "`r`n Display information about volumes inside the partition:`r`n";
			$volumes = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID=`"$($partition.DeviceID)`"} WHERE AssocClass = Win32_LogicalDiskToPartition";

			foreach($volume in $volumes)
			{
				Out-Host -InputObject "Volume name: $($volume.name)";
				#Out-Host -InputObject "VolumeName: $($volume.VolumeName)";
				Out-Host -InputObject "Total volume size in bytes: $($volume.Size) B";
				Out-Host -InputObject ("Total volume size in gigabytes: {0:F2} GB" -f $($volume.Size/1GB));
				Out-Host -InputObject "Volume free space in bytes: $($volume.FreeSpace) B";
				Out-Host -InputObject ("Volume free space in gigabytes: {0:F2} GB" -f $($volume.FreeSpace/1GB));
				#Out-Host -InputObject " Serial Number: $($volume.serialnumber)";
				$volumeInfo = Get-WmiObject -Class Win32_Volume | where { $_.Name -eq "$($volume.name)\" } | select SerialNumber, FileSystem, Label;
				Out-Host -InputObject "Volume serial number: $($volumeInfo.serialnumber)";
				Out-Host -InputObject "Volume file system type: $($volumeInfo.FileSystem)";
				Out-Host -InputObject "Volume Label: $($volumeInfo.Label)";
			}
			Out-Host -InputObject "";
		}
		Out-Host -InputObject "";
	}
}

#************************************************ *****************************
#* Func: GetMainDiskDrive
#*
#* Desc: This is an auxiliary function that returns the main source disk drive
#*
#************************************************ *****************************
Function GetMainDiskDrive()
{
	$main_disk_drive = $null;
	$disk_drives = Get-WmiObject -Class win32_diskdrive

	foreach($disk_drive in $disk_drives)
	{
		$partitions = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID=`"$($disk_drive.DeviceID.replace('\','\\'))`"} WHERE AssocClass = Win32_DiskDriveToDiskPartition"

		foreach($partition in $partitions)
		{
			$volumes = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID=`"$($partition.DeviceID)`"} WHERE AssocClass = Win32_LogicalDiskToPartition"

			foreach($volume in $volumes)
			{
				if($($volume.name) -eq 'C:') {
					#Out-Host -InputObject ("Main disk decimal ID: {0}" -f $disk_drive.Signature);
					$main_disk_drive = $disk_drive;
					Out-Host -InputObject ("`r`nMain disk ID (decimal): {0}" -f $main_disk_drive.Signature);
					Out-Host -InputObject ("Main disk ID (hex): {0:X8}`r`n" -f $main_disk_drive.Signature);
					return $main_disk_drive;
				}
			}
		}
	}
	return $main_disk_drive;
}

#************************************************ *****************************
#* Func: CalculateMainDiskSize
#*
#* Desc: This is an auxiliary function that calculates total space size,
#* used space size and free space size in main source disk drive
#*
#***************************************************************************************
Function CalculateMainDiskSize($main_disk_drive)
{
	#$main_disk_drive = Get-WmiObject -Class win32_diskdrive | where { $_.Signature -eq "$($main_disk_drive_ID)" };

	Out-Host -InputObject "";
	Out-Host -InputObject "Calculating used space on the main source disk`r`n";

	#Out-Host -InputObject "main_disk_drive_ID: $($main_disk_drive_ID)";
	#Out-Host -InputObject ("Main disk ID (decimal): {0:D}" -f $main_disk_drive_ID);
	#Out-Host -InputObject ("Main disk ID (hex): {0:X8}" -f $main_disk_drive_ID);
	#Out-Host -InputObject "Full name of the main source disk: $($main_disk_drive)";
	#Out-Host -InputObject "main_disk_drive count: $($main_disk_drive.Count)";

	# main disk drive space calculation
	[long] $total_size_of_main_disk = $($main_disk_drive.Size);
	[long] $used_space_in_main_disk = 0;
	[long] $free_space_in_main_disk = $($main_disk_drive.Size);

	$partitions = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID=`"$($main_disk_drive.DeviceID.replace('\','\\'))`"} WHERE AssocClass = Win32_DiskDriveToDiskPartition"

	foreach($partition in $partitions)
	{
		$used_space_in_main_disk += $($partition.Size);
		$free_space_in_main_disk -= $($partition.Size);

		$volumes = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID=`"$($partition.DeviceID)`"} WHERE AssocClass = Win32_LogicalDiskToPartition"

		foreach($volume in $volumes)
		{
			$used_space_in_main_disk -= $($volume.FreeSpace);
			$free_space_in_main_disk += $($volume.FreeSpace);
		}
	}

	Out-Host -InputObject ("Total size of main source disk in bytes: {0} B" -f $total_size_of_main_disk);
	Out-Host -InputObject ("Total size of main source disk in gigabytes: {0:F2} GB" -f $($total_size_of_main_disk/1GB));
	Out-Host -InputObject ("Used space of the main source disk in bytes: {0} B" -f $used_space_in_main_disk);
	Out-Host -InputObject ("Source main disk space used in gigabytes: {0:F2} GB" -f $($used_space_in_main_disk/1GB));
	Out-Host -InputObject ("Free space of the main source disk in bytes: {0} B" -f $free_space_in_main_disk);
	Out-Host -InputObject ("Free space of the main source disk in gigabytes: {0:F2} GB" -f $($free_space_in_main_disk/1GB));

	return $total_size_of_main_disk, $used_space_in_main_disk, $free_space_in_main_disk;
}

#************************************************ *****************************
#* Func: CheckDisksConnectedViaUSB
#*
#* Desc: This is an auxiliary function which checks whether there are any disk drives connected to
#* the computer through the USB port. This function returns the number of disk drives connected to
#* the computer through the USB port or returns 0 if there are no disks connected through the USB port
#*
#************************************************ *****************************
Function CheckDisksConnectedViaUSB()
{
	Out-Host -InputObject "";
	Out-Host -InputObject "Searching for hard drives connected to the computer via the USB`r`n port";

	[array] $usb_disk_drives = Get-WmiObject -Query "SELECT * FROM Win32_DiskDrive WHERE (InterfaceType = 'SCSI' OR InterfaceType = 'USB') AND (MediaType = 'External hard disk media' OR MediaType = 'Removable media')";
	#[array] $usb_disk_drives = Get-WmiObject -Class Win32_DiskDrive | where { (($_.InterfaceType -eq "SCSI" -or $_.InterfaceType -eq "USB")) -and (($_.MediaType = 'External hard disk media') -or ($_.MediaType = 'Removable media')) };

	Write-Host "Number of detected hard drives connected via USB to the computer: $($usb_disk_drives.Count)";

	#foreach($usb_disk_drive in $usb_disk_drives)
	for ($i=0; $i -lt $usb_disk_drives.Count; $i++)
	{
		[long] $disk_ID = $usb_disk_drives[$i].Signature;
		Write-Host("Hard disk number {0} connected via USB port:" -f ($i+1));
		Write-Host ("ID of the hard disk connected via USB port (decimal): {0}" -f $disk_ID);
		Write-Host ("USB connected hard disk ID (hex): {0:X8}" -f $disk_ID);
		Out-Host -InputObject ("Size of the hard drive connected via USB port in gigabytes: {0:F2} GB" -f $($usb_disk_drives[$i].Size/1GB));
	}
	Write-Host "";
	return $usb_disk_drives;
}

#************************************************ *****************************
#* Func: FindViableTargetDisks
#*
#* Desc: This is an auxiliary function that extracts IDs of all viable disk drives
#* attached to computer through the USB port with enough space to hold source disk and
#* also doesn't consider internal disk drives like those connected through SATA cable.
#*
#************************************************ *****************************
Function FindViableTargetDisks([array] $usb_disk_drives, [long] $used_space_in_main_disk)
{
	Out-Host -InputObject "";
	Out-Host -InputObject "Search for external hard drives of sufficient size to contain in itself the entire source disk`r`n";

	#[array] $viable_target_disk_drives = Get-WmiObject -Query "SELECT * FROM Win32_DiskDrive WHERE (InterfaceType = 'SCSI' OR InterfaceType = 'USB') AND (MediaType = 'External hard disk media' OR MediaType = 'Removable media')" ;
	#[array] $viable_target_disk_drives = Get-WmiObject -Query "SELECT * FROM Win32_DiskDrive WHERE (InterfaceType = 'SCSI' OR InterfaceType = 'USB') AND (MediaType = 'External hard disk media' OR MediaType = 'Removable media') AND (Size > $used_space_in_main_disk)";
	#[array] $viable_target_disk_ids = Get-WmiObject -Class Win32_DiskDrive | select Signature | where { (($_.InterfaceType -eq "SCSI" -or $_.InterfaceType -eq "USB")) -and (($_.MediaType = 'External hard disk media') -or ($_.MediaType = 'Removable media')) -and ($_.Size -gt $used_space_in_main_disk) };

	[array] $viable_target_disk_drives = $usb_disk_drives | Where-Object { ($_.Size -gt $used_space_in_main_disk) } | Select-Object;

	#Out-Host -InputObject ("viable_target_disk_ids: {0}" -f $viable_target_disk_ids);
	#Out-Host -InputObject $viable_target_disk_ids;
	#foreach($viable_target_disk_id in $viable_target_disk_ids)
	#{
	# Write-Host ("Target disk ID (decimal): {0}" -f $viable_target_disk_id);
	# Write-Host ("Target disk ID (hex): {0:X8}" -f $viable_target_disk_id);
	#}

	Out-Host -InputObject ("Number of detected target disks connected via USB of sufficient size to clone the main source disk: {0}" -f $viable_target_disk_drives.Count);

	#foreach($viable_target_disk_drive in $viable_target_disk_drives)
	for ($i=0; $i -lt $viable_target_disk_drives.Count; $i++)
	{
		[long] $disk_ID = $viable_target_disk_drives[$i].Signature;
		Write-Host("Target disk number: {0}" -f ($i+1));
		Write-Host("Target disk ID (decimal): {0}" -f $disk_ID);
		Write-Host("Target disk ID (hex): {0:X8}" -f $disk_ID);
		Out-Host -InputObject ("Target disk size in gigabytes: {0:F2} GB" -f $($viable_target_disk_drives[$i].Size/1GB));
	}
	Write-Host "";
	#return $viable_target_disk_ids;
	return $viable_target_disk_drives;
}

#************************************************ *****************************
#* Func: CheckExistenceOfCorrectXmlFiles
#*
#* Desc: This is an auxiliary function that searches for correct Xml files in Reflect program directory
#* Correct Xml file should contain both source disk drive and target disk drive for cloning procedure
#* This function returns a list of correct Xml files or empty list if no correct Xml files were found
#*
#************************************************ *****************************
Function CheckExistenceOfCorrectXmlFiles([string] $reflect_files_path, $source_disk_drive, $target_disk_drives)
{
	[System.Collections.ArrayList] $correct_xml_files = [System.Collections.ArrayList]@();
	#[System.Collections.Generic.List[string]] $correct_xml_files = [System.Collections.Generic.List[string]]@();
	$xml_files = Get-ChildItem -Path $reflect_files_path -Filter *.xml;
	[string] $source_disk_id_in_xml_file = '';
	[string] $target_disk_id_in_xml_file = '';
	[string] $source_disk_id_hexadecimally = $source_disk_drive.Signature.ToString("X8");
	[string[]] $target_disk_ids_hexadecimally = $target_disk_drives | ForEach-Object { $_.Signature.ToString("X8"); };

	Write-Host "";
	Write-Host "Checking whether xml files already exist in the Macrium Reflect folder containing the correct information about the cloning procedure`r`n";

	Write-Host "List of all .xml files in Macrium Reflect folder:";

	for ($i=0; $i -lt $xml_files.Count; $i++) {
	Write-Host("File $($i+1): {0}" -f $xml_files[$i].FullName);
	#Get-Content $xml_files[$i].FullName | Write-Host;

	#[regex] $source_disk_pattern = [regex]::Escape(' <source_disk id="006BDEF5">1</source_disk>');
	[regex] $source_disk_pattern = [regex](' <source_disk id="(?<disk_id>.*)">(?<source_disk_number>.*)</source_disk>');
	[regex] $target_disk_pattern = [regex](' <target_disk id="(?<disk_id>.*)">(?<target_disk_number>.*)</target_disk>');

	[System.IO.StreamReader] $xml_file_reader = [System.IO.File]::OpenText($xml_files[$i].FullName);
	try {
		while(($file_line = $xml_file_reader.ReadLine()) -ne $null) {
			# process the line of a file
			#Write-Host $file_line;
			if($file_line -match $source_disk_pattern) {
				Write-Host("Source disk ID in this xml file: {0}" -f $matches['disk_id']);
				Write-Host("Source disk number in this xml file: {0}" -f $matches['source_disk_number']);
				$source_disk_id_in_xml_file = $matches['disk_id'];
			}
			if($file_line -match $target_disk_pattern) {
				Write-Host("The target disk ID in this xml file: {0}" -f $matches['disk_id']);
				Write-Host("Target disk number in this xml file: {0}" -f $matches['target_disk_number']);
				$target_disk_id_in_xml_file = $matches['disk_id'];
			}
		}
	}
	finally {
		$xml_file_reader.Close();
	}

	if($source_disk_id_in_xml_file -ceq $source_disk_id_hexadecimally) {
		foreach($target_disk_id_hexadecimally in $target_disk_ids_hexadecimally) {
			if($target_disk_id_in_xml_file -ceq $target_disk_id_hexadecimally) {
					Write-Host "This xml file contains valid IDs of the source disk and target disk connected to the computer";
					Write-Host "This xml file can be used to perform the cloning procedure";
					Write-Host("{0}" -f $xml_files[$i].FullName);
					Write-Host $xml_files[$i];
					[void]$correct_xml_files.Add($xml_files[$i]);
					#[void]$correct_xml_files.Add($xml_files[$i].FullName);
				}
			}
		}
		Write-Host "";
	}
	Write-Host "";
	return $correct_xml_files;
}

#************************************************ *****************************
#* Func: SelectBestXmlFile
#*
#* Desc: This is an auxiliary function that select the xml with newest creation
#* date timestamp. Such file should be most relevant for the cloning procedure
#*
#************************************************ *****************************
Function SelectBestXmlFile([System.Collections.ArrayList] $correct_xml_files)
{
	Write-Host "";
	Write-Host "Selecting the most up-to-date xml file in the Macrium Reflect folder containing the correct cloning procedure`r`n information";

	if(($correct_xml_files -eq $null) -or ($correct_xml_files.Count -eq 0)) {
		Write-Host "The function was called with an invalid list of valid xml files"
		return;
	}

	[System.IO.FileInfo] $most_recent_xml_file = ($correct_xml_files | Sort-Object -Property CreationTime | Select-Object -Last 1);
	Write-Host "Selected file: $($most_recent_xml_file.FullName), created on: $($most_recent_xml_file.CreationTime)";

	return $most_recent_xml_file;
}

#************************************************ *****************************
#* Func: SelectTargetDiskFromXmlFile
#*
#* Desc: This is an auxiliary function that select returns a disk drive which has the same ID as written in xml file
#*
#************************************************ *****************************
Function SelectTargetDiskFromXmlFile([System.IO.FileInfo] $chosen_xml_file, $target_disk_drives)
{
	[string] $target_disk_id_in_xml_file = '';
	[regex] $target_disk_pattern = [regex](' <target_disk id="(?<disk_id>.*)">(?<target_disk_number>.*)</target_disk>');
	$target_disk_drive = $null;

	[System.IO.StreamReader] $xml_file_reader = [System.IO.File]::OpenText($chosen_xml_file.FullName);
	try {
		while(($input_line = $xml_file_reader.ReadLine()) -ne $null) {
			if($input_line -match $target_disk_pattern) {
				$target_disk_id_in_xml_file = $matches['disk_id'];
			}
		}
	}
	finally {
		$xml_file_reader.Close();
	}
	foreach($target_disk in $target_disk_drives) {
		if($target_disk.Signature.ToString("X8") -ceq $target_disk_id_in_xml_file) {
			$target_disk_drive = $target_disk
		break;
		}
	}
	return $target_disk_drive;
}

#************************************************ *****************************
#* Func: SelectBestTargetDiskDrive
#*
#* Desc: This is an auxiliary function that selects the best target disk drive candidate for cloning
#* procedure if there are more than 1 target disk drive candidate. Target disk drive with ID present
#* in default_cloning_scheme.xml file have highest priority. If target disk drive with ID is not
#* present in default_cloning_scheme.xml file then priority has a disk drive with largest capacity
#*
#************************************************ *****************************
Function SelectBestTargetDiskDrive($target_disk_drives, [string] $default_xml_file_path)
{
	$best_target_disk = $null;
	#[string] $new_xml_file_name = 'cloning_scheme.xml';
	#[string] $full_new_xml_file_path_name = '';

	Write-Host "";
	Write-Host "Selecting the most suitable target hard disk as a candidate for the cloning procedure`r`n";

	if(($target_disk_drives -eq $null) -or ($target_disk_drives.Count -eq 0)) {
		Write-Host "The function was called with an invalid list of available hard drives"
		return;
	}

	[bool] $file_existence_return_value = Test-Path $default_xml_file_path -PathType Leaf;
	if($file_existence_return_value -eq $false) {
		Write-Host "Xml file with default settings for cloning procedure`r`n not found";
		return;
	}

		 [regex] $target_disk_pattern = [regex](' <target_disk id="(?<disk_id>.*)">(?<target_disk_number>.*)</target_disk>');
	[System.IO.StreamReader] $xml_file_reader = [System.IO.File]::OpenText($default_xml_file_path);
	try {
		while(($file_line = $xml_file_reader.ReadLine()) -ne $null) {
			if($file_line -match $target_disk_pattern) {
				$target_disk_id_in_xml_file = $matches['disk_id'];
			}
		}
	}
	finally {
		$xml_file_reader.Close();
	}
	Write-Host ("Target disk ID in default xml file: {0}`r`n" -f $target_disk_id_in_xml_file);

	foreach($target_disk in $target_disk_drives) {
		if($target_disk.Signature -eq $target_disk_id_in_xml_file) {
			$best_target_disk = $target_disk;
			return $best_target_disk;
		}
	}

	Write-Host ("All available hard drives have IDs different from the target drive in the default xml file: {0}" -f $target_disk_id_in_xml_file);
	Write-Host "Selecting the largest available hard disk as the target disk for the cloning procedure";

	$best_target_disk = $target_disk_drives | Sort-Object -Descending -Property Size | select -First 1;

	Write-Host ("Identifier of the selected target disk for the cloning procedure: {0:X8}`r`n" -f $($TargetDiskDrive.Signature));

	return $best_target_disk;
}

#************************************************ *****************************
#* Func: CreateNewCloningXmlFile
#*
#* Desc: This is an auxiliary function that creates new correct xml cloning scheme file
#* This file bases on Default_cloning_scheme.xml file and replaces its old information with new
#* correct information like newly found source disk drive ID or newly found target disk drive ID
#*
#************************************************ *****************************
Function CreateNewCloningXmlFile([string] $reflect_files_path, $source_disk_drive, $target_disk_drive, [string] $default_xml_file_name)
{
	[string] $new_xml_file_name = 'cloning_scheme.xml';
	[string] $full_new_xml_file_path_name = '';
	[System.IO.FileInfo] $new_created_xml_file = $null;
	$input_line = $null;
	$output_line = $null;

	if(($source_disk_drive -eq $null) -or ($target_disk_drive -eq $null) -or ($default_xml_file_name -eq $null)) {
		Write-Host "The function was called with incorrect source and/or target disk IDs and/or with an incorrect default xml file";
		return;
	}

	Write-Host "";
	Write-Host "Creating a new xml file in the Macrium Reflect folder containing the correct information about the cloning procedure`r`n";

	<#[int] $file_index = 0;
	while($true) {
		# checking the existence of an xml file with specified name
		$file_existence_return_value = Test-Path $full_new_xml_file_path_name -PathType Leaf;
		if($file_existence_return_value -eq $true) {
			Write-Host 'xml file already exists';
			$file_index++;
			$new_xml_file_name = 'cloning_scheme_' + $file_index.ToString() + '.xml';
			$full_new_xml_file_path_name = $reflect_files_path + $new_xml_file_name;
			continue;
		}
		else {
			break;
		}
	}#>

	# Get current timestamp including current year, month, day, hour, minute and second
	$current_timestamp = Get-Date;
	# Use the custom format to specify datetime format
	[string] $date_string = $current_timestamp.ToString("HH_mm_ss_dd_MM_yyyy");
	$new_xml_file_name = 'cloning_scheme_' + $date_string.ToString() + '.xml';
	$full_new_xml_file_path_name = $reflect_files_path + $new_xml_file_name;

	[regex] $source_disk_pattern = [regex](' <source_disk id="(?<disk_id>.*)">(?<source_disk_number>.*)</source_disk>');
	[regex] $target_disk_pattern = [regex](' <target_disk id="(?<disk_id>.*)">(?<target_disk_number>.*)</target_disk>');

	[System.IO.StreamReader] $xml_file_reader = [System.IO.File]::OpenText($default_xml_file_name);
	try {
		while(($input_line = $xml_file_reader.ReadLine()) -ne $null) {
			$output_line = $input_line;
			if($input_line -match $source_disk_pattern) {
				$output_line = ' <source_disk id="' + $source_disk_drive.Signature.ToString("X8") + '">' + $matches['source_disk_number'] + '</source_disk>';
			}
			elseif($input_line -match $target_disk_pattern) {
				$output_line = ' <target_disk id="' + $target_disk_drive.Signature.ToString("X8") + '">' + $matches['target_disk_number'] + '</target_disk>';
			}
			Add-Content -path $full_new_xml_file_path_name -value $output_line;
			}
		}
	finally {
		$xml_file_reader.Close();
	}

	Write-Host "A new xml file has been created in the Macrium Reflect folder containing the correct information about the cloning procedure:";
	Write-Host $full_new_xml_file_path_name;

	$new_created_xml_file = Get-Item -Path $full_new_xml_file_path_name;

	return $new_created_xml_file;
}

#************************************************ *****************************
#* Func: ValidateXmlFile
#*
#* Desc: This is an auxiliary function that uses Macrium Reflect program to
#* validate xml file to see whether xml file is correct or conatins some errors
#*
#************************************************ *****************************
Function ValidateXmlFile([string] $reflect_exe_path, [System.IO.FileInfo] $chosen_xml_file)
{
	[string] $reflect_parameters = "-v `"$($chosen_xml_file.FullName)`"";

	Write-Host "";
	Write-Host "Validating the xml file containing information about the cloning procedure";
	Write-Host "$reflect_exe_path $reflect_parameters";

	$validation_result = (Start-Process -FilePath `"$reflect_exe_path`" -ArgumentList $reflect_parameters -PassThru -Wait).ExitCode;
	Write-Host "Checking the xml file with the following result/code: $validation_result";
	if($validation_result -eq 0) {
		Write-Host "The xml file is valid";
		return $true;
	}
	else {
		Write-Host "The xml file contains errors. You can try to create a new xml file using Macrium Reflect and you can delete the erroneous xml files from the Macrium Reflect folder";
		return $false;
	}
	return $false;
}

#************************************************ *****************************
#* Func: FormatTargetDisk
#*
#* Desc: This is an auxiliary function that formats/cleans target disk drive so that it can be used for cloning
#*procedure. A user is given 30 seconds period to abort formatting of the target disk drive if necessary
#*
#************************************************ *****************************
Function FormatTargetDisk($target_disk_drive)
{
	$pressedKey = $null;
	Write-Host "";
	Write-Host "Formatting the target hard drive so that it can be used for the cloning procedure`r`n";
	Write-Host "Target hard drive ID: $($target_disk_drive.Signature.ToString("X8"))";
	Write-Host "Number of partitions in target hard disk: $($target_disk_drive.Partitions)";

	if($($target_disk_drive.Partitions) -le 0) {
		Write-Host "The target hard disk is already formatted and has no partitions";
		return;
	}

	Write-Host "Note: This operation will delete all data on the target disk";
	Write-Host "30 seconds to cancel operation";
	Write-Host "If no key is pressed for 30 seconds, the target disk will continue to be formatted and the cloning procedure will continue";
	Write-Host "Click Enter if you want to continue formatting the target disk and continue the cloning procedure without waiting 30 seconds";
	Write-Host "Click any key other than Enter if you want to cancel the formatting of the target disk and cancel the cloning procedure";

	[string] $delayMessageString1 = "Click Enter if you want to continue formatting the target disk and continue the cloning procedure without waiting 30 seconds";
	[string] $delayMessageString2 = "Click any key other than Enter if you want to cancel the formatting of the target disk and cancel the cloning procedure";

	$pressedKey = InterruptibleDelay -delay_time_in_seconds 30 -delay_message_string_1 $delayMessageString1 -delay_message_string_2 $delayMessageString2;
	if(-not (($pressedKey -eq $null) -or ($pressedKey -eq 13))) { # 13 is an ascii code for Enter button
		Write-Host "The formatting of the target disk was interrupted by the user";
		return 9;
	}

	$partitions = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID=`"$($target_disk_drive.DeviceID.replace('\','\\'))`"} WHERE AssocClass = Win32_DiskDriveToDiskPartition"

	foreach($partition in $partitions)
	{
		Write-Host "Deleting partition number $($partition.Index) on hard disk number $($partition.DiskIndex)";
		# there is some weird bug that partition index has to be incremented by 1 because they are numbered starting from 1
		Remove-Partition -DiskNumber $($partition.DiskIndex) -PartitionNumber $($partition.Index+1) -Confirm:$false;
	}
	#$partitions | Get-Member | Write-Host;
  #clear-disk -number x -removedata -removeoem -confirm:$false
	Write-Host "The target hard disk has been formatted correctly";
	return 0;
}

#************************************************ *****************************
#* Func: PerformCloningProcedure
#*
#* Desc: Calls Reflect.exe passing an XML BDF as a parameter.
#*
#************************************************ *****************************
Function PerformCloningProcedure([string] $reflect_exe_path, [System.IO.FileInfo] $chosen_xml_file)
{
[int] $cloning_result = 2; # by default result value equal to 2 means that cloning was unsuccessful, this can be changed later
	Write-Host "`r`n * Executing clone routine`r`n" # -NoNewLine;

	[string] $type_parameter = GetBackupTypeParameter;
	[string] $frequency_parameter = GetFrequencyParameter;
	[string] $guid_parameter = GetGuidParameter;
  
	# below is important line of this script which contains all parameters that will be passed to Macrium Reflect program
	[string] $reflect_parameters = "-e -w $type_parameter `"$($chosen_xml_file.FullName)`" $frequency_parameter $guid_parameter";
	Write-Host "$reflect_exe_path $reflect_parameters";

	# below is the most important instruction of this script which basically does the cloning procedure based on xml file and parameters
	$cloning_result = (Start-Process -FilePath `"$reflect_exe_path`" -ArgumentList $reflect_parameters -PassThru -Wait).ExitCode;

	Write-Host "`r`nEnd of cloning procedure.`r`n";
	Write-Host "`r`nProgram reflect.exe returned the following code: $cloning_result`r`n";

	switch ($cloning_result)
	{
		2 { OnXmlValidationError; break; }
		1 { OnCloningError; break; }
		0 { OnCloningSuccess; break; }
	}
	return $cloning_result;
}

#************************************************ *****************************
#* Func: GetBackupTypeParameter
#*
#* Desc: Determines the backup type from command line parameter
#* "-full": Full backup
#* "-inc" : Incremental backup
#* "-diff": Differential backup
#*
#************************************************ *****************************
Function GetBackupTypeParameter()
{
   if ($full -eq $true) { return '-full'; };
   if ($inc -eq $true) { return '-inc'; };
   if ($diff -eq $true) { return '-diff'; };
   return ''; #Clone
}

#************************************************ *****************************
#* Func: GetFrequencyParameter
#*
#* Desc: Gets the Schedule Frequency
#* "-once"
#* "-daily"
#* "-intradaily"
#* "-weekly"
#* "-monthly"
#* "-event"
#*
#************************************************ *****************************
Function GetFrequencyParameter()
{
   if ($freq -eq 'once') { return '-freq once'; };
   if ($freq -eq 'daily') { return '-freq daily'; };
   if ($freq -eq 'intradaily') { return '-freq intradaily'; };
   if ($freq -eq 'weekly') { return '-freq weekly'; };
   if ($freq -eq 'monthly') { return '-freq monthly'; };
   if ($freq -eq 'event') { return '-freq event'; };
   return '';
}

#************************************************ *****************************
#* Func: GetGuidParameter
#*
#* Desc: Gets the Schedule guide
#*
#************************************************ *****************************
Function GetGuidParameter()
{
   return '-g ' + $g;
}

#************************************************ *****************************
#* Func: OnXmlValidationError
#*
#* Desc: Called when a cloning fails due to an XML validation error.
#* This is here to be modified for your own uses.
#*
#************************************************ *****************************
Function OnXmlValidationError()
{
   Write-Warning "`r`n ! Problem with loading the XML file correctly ($($ChosenXmlFile.FullName)).`r`n";
   # Handle invalid XML error
}

#************************************************ *****************************
#* Func: OnCloningError
#*
#* Desc: Called when cloning fails.
#* This is here to be modified for your own uses.
#*
#************************************************ *****************************
Function OnCloningError()
{
   Write-Warning "`r`n ! Problem performing cloning procedure from this xml file ($($ChosenXmlFile.FullName)).`r`n";
   # Handle cloning error
}

#************************************************ *****************************
#* Func: OnCloningSuccess
#*
#* Desc: Called when cloning succeeds.
#* This is here to be modified for your own uses.
#*
#************************************************ *****************************
Function OnCloningSuccess()
{
   Write-Host "`r`n * Disk clone successful ($($ChosenXmlFile.FullName)).`r`n";
   # Handle cloning success
}

#************************************************ *****************************
#* Func: ManageScheduledCloningTask
#*
#* Desc: This is an auxiliary function. It checks if a cheduled cloning task exists in Windows
#*TaskScheduler. If a scheduled cloning task doesn't exist then this function creates a new task
#* for cloning procedure. This scheduled cloning task uses this script automatically for several
#* attempts to perform cloning procedure every once in a specified period of time, e.g. a week
#* Currently this script is set to do cloning attempt every friday, saturday and sunday at 22:00
#*
#************************************************ *****************************
Function ManageScheduledCloningTask([string] $script_path)
{
	[string] $cloning_task_name = "ScheduledCloningTask";
	$task_creation_result = $null;

	Write-Host "";
	Write-Host "Manage a disk cloning task that automatically repeats at a specified period of time, e.g. weekly";

	#Trigger
	#$middayTrigger = New-JobTrigger -Daily -At "12:40 AM"
	#$midNightTrigger = New-JobTrigger -Daily -At "12:00 PM"
	#$atStartUpEveryMinuteTrigger = New-JobTrigger -Once -At $(Get-Date) -RepetitionInterval $([timespan]::FromMinutes("1")) -RepeatIndefinitely

	#Options
	#$option1 = New-ScheduledJobOption –StartIfIdle

	#$scriptPath1 = 'C:\Path and file name 1.PS1'
	#$scriptPath2 = "C:\Path and file name 2.PS1"
	#$scriptPath3 = "C:\Users\Administrator\Desktop\interruptible_timer_script.ps1"

	#Register-ScheduledJob -Name ResetProdCache -FilePath $scriptPath1 -Trigger $middayTrigger,$midNightTrigger -ScheduledJobOption $option1
	#Register-ScheduledJob -Name TestProdPing -FilePath $scriptPath2 -Trigger $atStartupeveryFiveMinutesTrigger

	#Register-ScheduledJob -Name TestProdPing -FilePath $scriptPath2 -Trigger $atStartUpEveryMinuteTrigger

	Write-Host "Checking whether a periodic automatic hard disk cloning task has already been created previously"
	$cloning_task_exists = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {$_.TaskName -ceq $cloning_task_name };

	[string] $powershell_executable = "C:\WINDOWS\system32\WindowsPowerShell\v1.0\Powershell.exe";
	[string] $parameter_list = " -NoLogo -ExecutionPolicy Bypass -File `'" + $script_path + "`'";
	[string] $scheduled_task_command = $powershell_executable + $parameter_list;

	if($cloning_task_exists) {
		Write-Host "A periodic automatic hard disk cloning task already exists on the system";
	} else {
		Write-Host "Creating a new periodic automatic hard disk cloning task with administrator privileges";
		#$task_creation_result = schtasks /create /tn $cloning_task_name /sc minute /mo 1 /rl 'Highest' /tr $scheduled_task_command;
		$task_creation_result = schtasks /create /tn $cloning_task_name /sc weekly /st 22:00 /d FRI,SAT,SUN /rl 'Highest' /tr $scheduled_task_command;
	if($task_creation_result -eq $null){
		Write-Host "Error while creating a new periodic automatic hard disk cloning task";
		return 10;
	}
	else {
		Write-Host "Creation of new periodic auto-clone hard disk task successfully";
	}
	}

	Write-Host "";
	return 0;
}

#************************************************ *****************************
#* Func: LogScriptRun, LogScriptReturnValue
#*
#* Desc: Below are auxiliary functions which write information logs about this
#* script performance in specified log file
#*
#************************************************ *****************************
Function LogScriptRun([string] $log_file_path)
{
	# Get current timestamp including current year, month, day, hour, minute and second
	$current_timestamp = Get-Date;
	# Use the custom format to specify datetime format
	[string] $date_string = $current_timestamp.ToString("yyyy-MM-dd HH:mm:ss:");
	[string] $log_string = $date_string + "`r`n	A program/script for automatic periodic hard disk cloning has been run";

	if(($log_file_path -eq $null) -or ($log_file_path -eq "")) {
	Write-Host "The function was called with an invalid path to the file containing information about cloning procedures";
	return;
	}

	Add-Content -path $log_file_path -value $log_string;
}

Function LogCloningProcedure([string] $log_file_path, [string] $source_disk_id, [string] $target_disk_id)
{
	[string] $log_string = "	The program/script has performed a cloning procedure from the source hard disk with ID $source_disk_id to the target hard disk with ID $target_disk_id";

	if(($log_file_path -eq $null) -or ($log_file_path -eq "") -or ($source_disk_id -eq $null) -or ($source_disk_id -eq "") -or ($target_disk_id -eq $null) -or ($target_disk_id -eq "")) {
		Write-Host "The function was called with invalid parameters";
		return;
	}

	Add-Content -path $log_file_path -value $log_string;
}

Function LogScriptReturnValue([string] $log_file_path, [int] $return_value)
{
	[string] $log_string = "	The program/script for automatic hard disk cloning returned the following code: $return_value";
	[string] $result_description = TranslateReturnCodeToDescription -return_code $return_value;
	$log_string += "`r`n	Description of the returned code: " + $result_description;

	Add-Content -path $log_file_path -value $log_string;
}
  
Function TranslateReturnCodeToDescription([int] $return_code)
{
#[string] $result_description;
   switch ($return_code)
   {
     0 { return "Hard disk cloning procedure completed successfully"; }
     1 { return "Macrium Reflect returned an error while performing the cloning procedure"; }
     2 { return "Macrium Reflect returned an error while verifying the xml file with the definition of the cloning procedure"; }
     3 { return "The program/script was run without administrator privileges, which are needed for the cloning procedure"; }
     4 { return "The program/script could not find any external hard drive connected via USB to the computer"; }
     5 { return "The program/script could not find any external hard drive connected via USB port with the correct serial number"; }
     6 { return "The program/script could not find any USB-connected external hard drive of sufficient size to store the entire source drive"; }
     7 { return "The program/script could not find any source disk for the cloning procedure"; }
     8 { return "The program/script could not find or create the correct xml file with the cloning procedure definition"; }
     9 { return "The program/script was stopped manually by the user"; }
     10 { return "The program/script could not properly create a periodic task for automatic hard disk cloning"; }
     11 { return "The program/script has already performed the cloning procedure earlier this week. One cloning procedure per week is enough"; }
   }
return "";
}
  
#*****************************************************************************
#* Func: CheckPreviousCloningAttempts
#*
#* Desc: This is an auxiliary function that checks cloning log file to verify if there was
#* already a successful cloning attempt in the current week. Only 1 successful cloning procedure is
#* necessary per week. Currently this script works in a way that it does 3 cloning attempts per week
#* Every Friday, Saturday and Sunday at 22:00 hour. If in the current week there was already a
#* successful cloning procedure then all next cloning attempts are immediately aborted
#* It is completely fine if in some weeks there were skipped cloning procedures, for example,
#* because of no external USB disks connected to the computer. This function return $true if
#* cloning procedure was already completed in the current week and return $false otherwise
#*
#************************************************ *****************************
Function CheckPreviousCloningAttempts([string] $log_file_path)
{
	#[System.DateTime] $cloning_date_time = $null;
	$input_line = $null;
	$output_line = $null;
	[System.DateTime] $current_date_time = Get-Date;
	[int] $current_week_of_year = $(Get-Culture).Calendar.GetWeekOfYear(($current_date_time),[System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday);


	if(($log_file_path -eq $null) -or ($log_file_path -eq "")) {
		Write-Host "The function was called with an invalid path to the file containing information about cloning procedures";
		return $false;
	}

	Write-Host "";
	Write-Host "Checking in the file containing information about cloning procedures whether a cloning procedure has already been performed this week. ";
	Write-Host "Only 1 cloning procedure per week is required. A total of 3 attempts are made per week on Friday, Saturday and Sunday at 22:00";
	Write-Host "If there is no external USB hard drive inserted for cloning during one week, nothing is lost. There is no need to clone every week";

	# checking the existence of cloning info log file with specified path name
	$log_file_existence_return_value = Test-Path $log_file_path -PathType Leaf;
	if($log_file_existence_return_value -eq $false) {
		Write-Host "The function was called with an invalid path to the file containing information about cloning procedures";
		return $false;
	}

	[regex] $date_pattern = [regex]('(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}): (\d{2}):');
	[regex] $return_value_pattern = [regex]('	The program/script for automatic hard disk cloning returned the following code: (?<return_value>.*)');

	[System.IO.StreamReader] $log_file_reader = [System.IO.File]::OpenText($log_file_path);
	try {
		while(($input_line = $log_file_reader.ReadLine()) -ne $null)
		{
			if($input_line -match $date_pattern) {
				#[System.DateTime] $cloning_date_time = Get-Date -format "yyyy-MM-dd HH:mm:ss" $input_line.substring(0, 19);
				[System.DateTime] $cloning_date_time = [datetime]::ParseExact($input_line, 'yyyy-MM-dd HH:mm:ss:', [cultureinfo]::InvariantCulture);
				$cloning_week_of_year = $(Get-Culture).Calendar.GetWeekOfYear(($cloning_date_time),[System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday);
				if($cloning_week_of_year -eq $current_week_of_year) {
					while($true)
					{
						$first_character = $log_file_reader.Peek();
						# 9 is an ascii code for horizontal tabulation special character
						if(($first_character -eq $null) -or ($first_character -ne 9)) {
							break;
						}
						$input_line = $log_file_reader.ReadLine();
						if($input_line -match $return_value_pattern) {
							if($matches['return_value'] -ceq '0') {
								Write-Host "	The program/script successfully performed the cloning procedure on: $($cloning_date_time.ToString('dd-MM-yyyy HH:mm:ss'))";
								return $true;
							}
						}
					}
				}
			}
		}
	}
	finally {
		$log_file_reader.Close();
	}

	Write-Host "";
	return $false;
}

#************************************************ *****************************
#* Func: InterruptibleDelay
#*
#* Desc: Utility function which makes a timed delay in the working of the script while displaying the delay progress
#* Amount of delay and delay messages can be provided as arguments
#* Pressing any key on keyboard interrupts this delay and returns pressed key
#*
#************************************************ *****************************
Function InterruptibleDelay([int] $delay_time_in_seconds, [string] $delay_message_string_1, [string] $delay_message_string_2)
{
	[int] $timer_duration_in_seconds = $delay_time_in_seconds; # Seconds in total for timer countdown
	$timer_interval_in_seconds = 1;
	[System.DateTime] $start_time = Get-Date;
	$pressed_key = $null;

	[System.Timers.Timer] $timer = New-Object System.Timers.Timer;
	[long] $timer.Interval = $timer_interval_in_seconds * 1000; # Interval has to be provided in millisecons, hence multiplication by 1000
	[System.Collections.Hashtable] $timer_data =
	@{
		StartTime = $start_time;
		TimerDurationInSeconds = $timer_duration_in_seconds ;
		DelayMessageString1 = $delay_message_string_1;
		DelayMessageString2 = $delay_message_string_2;
	};

	[System.Management.Automation.ScriptBlock] $timer_instruction_block = 
	{
		$start_time = $Event.MessageData.StartTime;
		$timer_duration_in_seconds = $Event.MessageData.TimerDurationInSeconds;
		$delay_message_string_1 = $Event.MessageData.DelayMessageString1;
		$delay_message_string_2 = $Event.MessageData.DelayMessageString2;

		[System.DateTime] $current_time = Get-Date;
		[System.TimeSpan] $elapsed_time = $current_time - $start_time;
		[long] $elapsed_seconds = [math]::Floor($elapsed_time.TotalSeconds);
		[long] $remaining_seconds = $timer_duration_in_seconds - $elapsed_seconds;
		[double] $elapsed_percentage = ($elapsed_seconds / $timer_duration_in_seconds) * 100;

		Write-Progress -PercentComplete $elapsed_percentage -Activity "Program/script paused for $timer_duration_in_seconds seconds, $elapsed_seconds seconds elapsed, $remaining_seconds seconds left, $($elapsed_percentage.ToString("F2"))% time elapsed" -Status $delay_message_string_1 -CurrentOperation $delay_message_string_2;
	}

	$timer_task = Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action $timer_instruction_block -MessageData $timer_data;
	$timer.Start() # Start the timer

	try {
		while ($true) {
			[System.DateTime] $current_time = Get-Date;
			[System.TimeSpan] $elapsed_time = $current_time - $start_time;
			[long] $elapsed_seconds = [math]::Floor($elapsed_time.TotalSeconds);

			if($elapsed_seconds -ge $timer_duration_in_seconds) {
				break;
		}

		if([System.Console]::KeyAvailable) {
			$pressed_key = [Console]::ReadKey($true).Key
				break;
			}
		}
	} finally {
		Write-Progress -PercentComplete 100 -Activity "Continuing program/script operation" -Status "100%";
		$timer.Stop();
		Remove-Job $timer_task -Force;
	}
	return $pressed_key;
}

#************************************************ *****************************
#* Func: EndScriptWithUserInput
#*
#* Desc: Utility function which has similar functionality as pause function in CMD.
#* This function prevents the script from exiting instantly after finishing other
#* functions which might be unwanted. Instead with this function this script doesn't
#* exit instantly but displays the message and waits for the user to press any key
#*
#************************************************ *****************************
Function EndScriptWithUserInput([string] $message)
{
	# Check if running Powershell ISE
	if ($psISE)
	{
		Add-Type -AssemblyName System.Windows.Forms
		[System.Windows.Forms.MessageBox]::Show("$message")
	}
	else
	{
		Write-Host "$message" -ForegroundColor White
		$pressedKey = $host.ui.RawUI.ReadKey("NoEcho, IncludeKeyDown")
	}
}

# Run the Main function of the script
$ScriptReturnValue = Main;
LogScriptReturnValue -log_file_path $LogFilePath -return_value $ScriptReturnValue;
StopReflectPrograms;

Write-Host "";
Write-Host "The hard disk cloning program/script returned the following code: $ScriptReturnValue";
Write-Host "End of program/script";
Write-Host "The program/script window will close automatically after 5 minutes";
Write-Host "You can press any key to close the program/script window now";

[string] $delayMessageString_1 = "End of program/script execution. The program/script window will close automatically after 5 minutes";
[string] $delayMessageString_2 = "You can press any key to close the program/script window now";
$pressed_key = InterruptibleDelay -delay_time_in_seconds (5*60) -delay_message_string_1 $delayMessageString_1 -delay_message_string_2 $delayMessageString_2;
#EndScriptWithUserInput "Press any key to end this program/script";
#Pause;
