<#
    .NOTES
        Created by Walid AlMoselhy - Please visit this page for detail <ANCHOR FOR GITHUB AND BLOG>
    .SYNOPSIS
        Copies a VM from VCenter to HyperV or VMM.
    .DESCRIPTION
        This script is best run on a Hyper-V server where you will run the VM on. 
        
        The script will create a new VM with desired configuration, download VMDK files from VMWare,
        Convert the VMDK files to VHDX and attach the VHDX files to the new VM.

        More testing was performed on the process with VMM than directly to Hyper-V. And without VMM
        the script will not automatically add the VM as a cluster resource.

        It requires that you install VMWare PowerCLI module using the Install-Module command or by 
        copying the module and its dependencies into C:\Program Files\WindowsPowerShell\Modules.

        It also depends on a PowerShell module from the MVMC software. As the software used to be free
        and is now discontiued, its binaries are included with this script and should in the same
        folder as .\MVMCCmdlet.

    .PARAMETER VMName
        ANCHOR FOR PARAMETER 1
    .PARAMETER SourceFolderPath
        ANCHOR FOR PARAMETER 2      
    .EXAMPLE
        ANCHOR FOR EXAMPLES
#>

#Requires -Modules VMware.VimAutomation.Core

#region: Parameters
[CmdletBinding()]
Param(
    [Parameter(Mandatory=$true,Position=1)]
    [ValidateSet("Hyper-V","VMM")]
    [string] $HVManagement,

    [Parameter(Mandatory=$false,Position=1)]
    [string] $VMMServer,

    [Parameter(Mandatory=$false,Position=2)]
    [pscredential] $VMMCredentials,
    
    [Parameter(Mandatory=$false,Position=2)]
    [string] $VMMTemplateName,

    [Parameter(Mandatory=$false,Position=3)]
    [string] $VMWareVCenterServer,
    
    [Parameter(Mandatory=$false,Position=4)]
    [pscredential] $VMWareCredentials,

    [Parameter(Mandatory=$true,Position=4)]
    [string] $VMName,

    [Parameter(Mandatory=$false,Position=4)]
    [switch] $UseVMwareCPUandRAM,

    [Parameter(Mandatory=$false,Position=4)]
    [switch] $UseVMWareMAC,

    [Parameter(Mandatory=$false,Position=4)]
    [int] $VMCPUs,

    [Parameter(Mandatory=$false,Position=4)]
    [int] $VMRAM,

    [Parameter(Mandatory=$false,Position=4)]
    [switch] $IgnoreVMWareTools,

    [Parameter(Mandatory=$false,Position=4)]
    [string] $StagingFolderPath,

    [Parameter(Mandatory=$false,Position=4)]
    [string] $DestinationFolderPath,

    [Parameter(Mandatory=$false,Position=4)]
    [switch] $SaveAdditionalDisksInDifferentLocation,

    [Parameter(Mandatory=$false,Position=4)]
    [string] $AdditionalDisksPath,
    
    [Parameter(Mandatory=$false,Position=4)]
    [switch] $DoNotRedownload,

    [Parameter(Mandatory=$false,Position=4)]
    [ValidateSet("FixedHardDisk","DynamicHardDisk")]
    [string] $VHDXType = "Dynamic",

    [Parameter(Mandatory=$false,Position=4)]
    [switch] $StartVM,

    [Parameter(Mandatory=$false,Position=4)]
    [switch] $Cleanup
)
#endregion

begin{
try{
    #To Calculate Conversion time
    $ScriptDuration = Get-Date
    
    #region:Functions

    function WriteInfo($message){
        Write-Host $message
    }

    function WriteInfoHighlighted($message){
        Write-Host $message -ForegroundColor Cyan
    }

    function WriteSuccess($message)
    {
        Write-Host $message -ForegroundColor Green
    }

    function WriteError($message)
    {
        Write-Host $message -ForegroundColor Red
    }

    function WriteErrorAndExit($message){
        Write-Host $message -ForegroundColor Red
        Write-Host "Press any key to continue ..."
        $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | OUT-NULL
        $HOST.UI.RawUI.Flushinputbuffer()
        #Exit
        Throw "Terminating Error"
    }

    #endregion
    
    #region: Input validation

    

    #endregion

    #region:Prepare Enviroments

        #Import MVMC Module from local folder
        Import-Module .\MVMCCmdlet\MvmcCmdlet.psd1
        WriteInfo "Imported MVMCCmdlet module."

        #Import VMWare Core module with prefix VMWare to avoid conflicts with HV module
        Import-Module -Name VMware.VimAutomation.Core -Prefix VMWare
        WriteInfo -message "Imported VMware.VimAutomation.Core module."
        
        #Create session on VCenter server
        Connect-VMWareVIServer -Server $VMWareVCenterServer -Credential $VMWareCredentials | Out-Null
        WriteInfoHighlighted -message "Connected to VCenter Server: $VMWareVCenterServer"
        
        #Import VMM Module if selected and connect to VMM Server
        if($HVManagement -eq "VMM"){
            Import-Module -Name VirtualMachineManager
            WriteInfo -message "Imported VMM module."

            Get-SCVMMServer -ComputerName $VMMServer -Credential $VMMCredentials | Out-Null
            WriteInfoHighlighted -message "Connected to VMM Server: $VMMServer"
        }

        #Import Hyper-V Module if selected

        if($HVManagement -eq "Hyper-V"){
            Import-Module -Name Hyper-V
            WriteInfo -message "Imported Hyper-V module."
        }

    #endregion
    
    #region: Perform some checks
        #Check that a VM with the same name does not exist on HV or VMM (warning only)

        #Check that VM exists on VMWare and save it to a variable
        WriteInfo -message "Checking that VM '$VMName' exists on VMWare."
        $VMWareVM = Get-VMWareVM -Name $VMName
        if ($VMWareVM.GetType().Name -ne "UniversalVirtualMachineImpl") {throw "VM '$VMName' not foudn on VCenter. Script will termiante."}
        WriteInfoHighlighted -message "VM Found."

        #Check that the VM is not powered on.
        WriteInfo "Checking that the VM is not running."
        if ($VMWareVM.PowerState.ToString() -eq "PoweredOn") {Throw "VM is running. Please turn it off and try again."}
        WriteInfoHighlighted "VM is currently powered off."

        #Check for snapshots
        WriteInfo "Checking that the VM has no snapshots."
        $VMWareVMSnapshots = Get-VMWareSnapshot -VM $VMWareVM 
        if ($VMWareVMSnapshots -ne $null) {Throw "VM has snapshots. Please merge all and try again."}
        WriteInfoHighlighted "VM has no snapshots."

        #Check VMWare Tools are not installed
        WriteInfo "Checking that the VMWare Tools is not installed."
        $VMwareToolsVersion = $VMWareVM.Guest.ToolsVersion
        if ($VMwareToolsVersion -ne "" -and $IgnoreVMWareTools -eq $false) {Throw "VMWare Tools are installed. Please uninstall and try again. To skip this validation use '-IgnoreVMWareTools' switch."}
        if ($VMwareToolsVersion -ne "" -and $IgnoreVMWareTools -eq $true) {WriteError "VMWare Tools are installed. Script will contiue as the 'IgnoreVMWareTools' switch is selected."}
        WriteInfoHighlighted "VMWare Tools are not installed."
        
        #Check that VMM template exists and save it to a variable
        WriteInfo -message "Checking that VMM template '$VMMTemplateName' exists."
        $VMMTemplate = Get-SCVMTemplate -Name $VMMTemplateName
        if($VMMTemplate.GetType().FullName -eq "Microsoft.SystemCenter.VirtualMachineManager.Template"){
            WriteInfoHighlighted -message "VMM Template found. Supports generation $($VMMTemplate.Generation) VMs."
        }
        else {throw "VMM template does not exist."}

        #Check VM Has disks 

        WriteInfo "Checking that the VM has disks."
        $VMWareDisks = @()+ (Get-VMWareHardDisk -VM $VMWareVM)
        if ($VMWareDisks -eq @()) {Throw "VM Does not have any disks."}
        WriteInfoHighlighted "VM has $($VMWareDisks.Count) disk(s)."

        ###Check that VM and Template have the same generation.###
        if($HVManagement -eq "VMM"){
            WriteInfo "Checking that the VM is the same generation as VMM template."
            if($VMWareVM.ExtensionData.Config.Firmware -eq "bios" -and $VMMTemplate.Generation -ne 1) {Throw "VM Template must be Generation 1 to support BIOS."}
            if($VMWareVM.ExtensionData.Config.Firmware -eq "efi" -and $VMMTemplate.Generation -ne 2) {Throw "VM Template must be Generation 2 to support EFI."}
            WriteInfoHighlighted "Template generation match VMWare."
        }
    #endregion
    

    #region: Create some variables
        #VMWare VM Object and specs   
        WriteInfo "Getting VM specs from VMWare."
        if ($UseVMwareCPUandRAM -eq $true){
            $VMCPUs = $VMWareVM.NumCpu
            $VMRAM = $VMwareVM.MemoryMB
            WriteInfoHighlighted -message "New VM will have $VMCPUs processors and $VMRAM MB static memory as per VMWare specs."
        }

        #VMWare VM vNICs
        $VMWareVMNics = @() + (Get-VMWareNetworkAdapter -VM $VMWareVM)
        WriteInfoHighlighted -message "VM will have $($VMWareVMNics.Count) vNICs."

        
        #HV Host is always the current host.
        $VMHost = $env:COMPUTERNAME




        

    #endregion
    
    #region: Create new VM
    switch ($HVManagement){
        "VMM"{
            #Create VM on VMM
            WriteInfo "Creating VM using VMM on current server '$VMHost' in '$DestinationFolderPath'."
            $VM = New-SCVirtualMachine -VMTemplate $VMMTemplate -Name $VMName -VMHost $VMHost -Path $DestinationFolderPath
            WriteSuccess "VM Created."

            #Create additional NICs if any
            if($VMWareVMNics.Count -gt 1){
                WriteInfo -message "Adding $($VMWareVMNics.count - 1) NICs."
                for ($i=1 ; $i -le ($VMWareVMNics.Count -1) ; $i++){ #for 2 NICs we only need to create 1 as the other is already in the template.
                    New-SCVirtualNetworkAdapter -VM $VM -Synthetic -MACAddressType "Static"| Out-Null
                }
                WriteSuccess -message "NICs added."
            }
            
            #Copy MAC address from VMWare if selected.
            if($UseVMWareMAC){
                WriteInfo -message "Copying MAC Address(es) from VMWare to new VM."
                $VMMVMNics = @() + (Get-SCVirtualNetworkAdapter -VM $VM)
                for($i=0;$i -lt $VMMVMNics.Count ; $i++){
                    $MAC = $VMWareVMNics[$i].MacAddress
                    Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $VMMVMNics[$i] -MACAddress $MAC -MACAddressType "Static"
                }
                WriteSuccess "MAC Address(es) Copied."
            }

            #Copy CPU and memory settings from VMWare if selected
            if($UseVMwareCPUandRAM){
                WriteInfo "Copying CPU and memory settings from VMWare to new VM."
                Set-SCVirtualMachine -VM $VM -DynamicMemoryEnabled $false -MemoryMB $VMRAM -CPUCount $VMCPUs | Out-Null
                WriteSuccess "CPU and memory setting copied."
            }

        }
        
        "Hyper-V"{
            #Not yet developed.
            Throw "This part is not yet developed."
        }
    }

    #endregion

    #region: Download and convert VMDKs to VHDX
    WriteInfoHighlighted "Processing VMDKs."
    foreach ($VMDK in $VMWareDisks){
        $VMDKIndex = $VMWareDisks.IndexOf($VMDK)
        if($VMDKIndex -eq 0){
            #Same as VM
            $VHDXDestination = $vm.Location
        }
        else{ #Additional Disks
            #Custom location for additional disks
            if($AdditionalDisksPath -eq $null) {$VHDXDestination = $vm.Location} #Same as VM
            else {$VHDXDestination = ((Get-Item -Path $AdditionalDisksPath).FullName + "\")} #Custom Location
        }
        
        #Download VMDK
        $VMDKDatastore = Get-VMWareDatastore -ID ($VMDK.ExtensionData.Backing.Datastore)
        $VMDKPath = $VMDK.Filename.Split("] ")[-1].replace("/","\")
        $VMDKFileName = $VMDKPath.Split("\")[-1]
        $VMDKFlatPath = $VMDKPath.Replace(".vmdk","-flat.vmdk")
        $VMDKFlatFileName = $VMDKFlatPath.Split("\")[-1]
        
        $VMDKDestination = "$StagingFolderPath\$VMDKFileName"
        $VMDKFlatDestination = "$StagingFolderPath\$VMDKFlatFileName"

        if($DoNotRedownload -and (Test-Path -Path $VMDKDestination) -and (Test-Path -Path $VMDKFlatDestination)){
            WriteInfoHighlighted -message "`tSkipping download of $($VMDK.Filename) as it is already downloaded."
        }
        else{
            New-PSDrive -Name "VMDS" -PSProvider VimDatastore -Root "\" -Location $VMDKDatastore | Out-Null
        
            WriteInfo "`tDownloading: [$($VMDKDatastore.Name)] $VMDKPath to $VMDKDestination" 
            $Duration = Measure-Command -Expression {Copy-VMWareDatastoreItem -Item "VMDS:\$VMDKPath" -Destination $VMDKDestination}
            WriteSuccess "`tDownload complete. Duration: $($Duration.ToString())"
        
            WriteInfo "`tDownloading: [$($VMDKDatastore.Name)] $VMDKFlatPath to $VMDKFlatDestination" 
            $Duration = Measure-Command -Expression {Copy-VMWareDatastoreItem -Item "VMDS:\$VMDKFlatPath" -Destination $VMDKFlatDestination}
            WriteSuccess "`tDownload complete. Duration: $($Duration.ToString())"

            Remove-PSDrive -Name "VMDS"
        }
        #Convert to VHDX
        WriteInfo "`tConverting VMDK file '$VMDKFileName' to VHDX."
        $VHDXFileName = $VMDKFileName.Replace(".vmdk",".vhdx")
        $VHDXPath = "$VHDXDestination\$VHDXFileName"

        $ConvertToParameters = @{
            SourceLiteralPath      = "$VMDKDestination"
            DestinationLiteralPath = $VHDXPath
            VhdType                = $VHDXType
            VhdFormat              = "VHDX"
        }
        $Duration = Measure-Command -Expression {ConvertTo-MvmcVirtualHardDisk @ConvertToParameters | Out-Null}
        WriteSuccess "`tConverted VMDK to VHDX: $VHDXPath - Duration: $($Duration.ToString())"

        #Delete downloaded files
        if($Cleanup){
            WriteInfo "`tDeleting downloaded VMDK."
            ($VMDKDestination,$VMDKFlatDestination) | Remove-Item -Force -ErrorAction Continue
            WriteSuccess "`tVMDKs deleted. (unless you see an error!)"
        }
    



        #Attach VHDX to VM
        if($VMDKIndex -eq 0){
            WriteInfo "`tAttaching VHDX to VM as OS Disk."
            switch ($VM.Generation)
            {
                1 {New-SCVirtualDiskDrive -VM $VM -Path $VHDXDestination -FileName "$VHDXFileName" -UseLocalVirtualHardDisk -VolumeType BootAndSystem -IDE -Bus 0 -LUN 0 | Out-Null}
                2 {New-SCVirtualDiskDrive -VM $VM -Path $VHDXDestination -FileName "$VHDXFileName" -UseLocalVirtualHardDisk -VolumeType BootAndSystem -SCSI -Bus 0 -LUN 0| Out-Null}
            }
            WriteSuccess "`tVHDX '$VHDXFileName' attached."     
        }
        else{
            WriteInfo "`tAttaching VHDX to VM as additional disk."
            switch ($VM.Generation)
            {
                1 {New-SCVirtualDiskDrive -VM $VM -Path $VHDXDestination -FileName "$VHDXFileName" -UseLocalVirtualHardDisk -SCSI -Bus 0 -LUN $VMDKIndex | Out-Null}
                2 {New-SCVirtualDiskDrive -VM $VM -Path $VHDXDestination -FileName "$VHDXFileName" -UseLocalVirtualHardDisk -SCSI -Bus 0 -LUN ($VMDKIndex+1)| Out-Null}
            }
            WriteSuccess "`tVHDX '$VHDXFileName' attached."              
        }
    }

    #endregion

    #region: Start VM
        if($StartVM){
            WriteInfo "Starting VM"
            Start-SCVirtualMachine -VM $VM | Out-Null
            WriteInfoHighlighted "VM Started"
        }

    #endregion

    $ScriptDuration = ((Get-Date) - $ScriptDuration).ToString()
    WriteSuccess "VMWare to Hyper-V Conversion Completed. Duration: $ScriptDuration"
}
catch
{
    Throw $Error[0]
}
finally
{
    if(Get-PSDrive -Name "VMDS" -ErrorAction SilentlyContinue) {Remove-PSDrive -Name "VMDS"}
    Disconnect-VMWareVIServer -Confirm:$false
}
}