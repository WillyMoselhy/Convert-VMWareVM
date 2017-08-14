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
    #Name of the VM to migrate
    [Parameter(Mandatory=$true,ValueFromPipeline = $true)]
    [string] $VMName,

    #VMM or Hyper - Currenly only VMM is developed.
    [Parameter(Mandatory=$false,Position=1)]
    [ValidateSet("VMM")]
    [string] $HVManagement = "VMM",

    #VMM server or cluster name
    [Parameter(Mandatory=$true)]
    [string] $VMMServer,

    #Credentials to connect to VMM server
    [Parameter(Mandatory=$false)]
    [pscredential] $VMMCredentials,
    
    #Name of template to use for new VM
    [Parameter(Mandatory=$true)]
    [string] $VMMTemplateName,

    #Name of VMWare vSphere Server
    [Parameter(Mandatory=$true)]
    [string] $VMWareVSphereServer,
    
    #credentials to connecto to vSphere Server
    [Parameter(Mandatory=$false)]
    [pscredential] $VMWareCredentials,

    #Copy CPU and memory configuration from VMWare to new VM
    [Parameter(Mandatory=$false)]
    [switch] $UseVMwareCPUandRAM,

    #Copy MAC address from VMWare to new VM
    [Parameter(Mandatory=$false)]
    [switch] $UseVMWareMAC,

    #Uninstall VMWare Tools from Guest OS
    [Parameter(Mandatory=$false)]
    [switch]$UninstallVMWareTools,

    #Do not check if VMWare Tools are installed before migration
    [Parameter(Mandatory=$false)]
    [switch] $IgnoreVMWareTools,

    #Location to temporary store VMDKs downloaded from VMWare Datastores
    [Parameter(Mandatory=$false)]
    [string] $StagingFolderPath,

    #Path of folder to store the new VM in (script will create a folder with the VM name)
    [Parameter(Mandatory=$true)]
    [string] $DestinationFolderPath,

    #Path to store additional disks if any - if not provided they will be saved at the same location as the VM
    [Parameter(Mandatory=$false)]
    [string] $AdditionalDisksPath,
    
    #Do not redownload VMDKs if they already exist in the staging folder
    [Parameter(Mandatory=$false)]
    [switch] $DoNotRedownload,

    #VHDX disk type to use
    [Parameter(Mandatory=$false)]
    [ValidateSet("FixedHardDisk","DynamicHardDisk")]
    [string] $VHDXType = "Dynamic",

    #Start VM after conversion is complete.
    [Parameter(Mandatory=$false)]
    [switch] $StartVM,

    #Delete downloaded VMDKs after conversion is complete
    [Parameter(Mandatory=$false)]
    [switch] $Cleanup,

    #Path of folder to store log files.
    [Parameter(Mandatory=$false)]
    [ValidateScript({
        if((Get-Item -Path $_).GetType().Name -eq "DirectoryInfo"){$true}
        else {Throw "Log Folder Path must to point to an existing folder."}
    })]
    [string] $LogFolderPath
)
#endregion

begin{
try{
    #To Calculate Conversion time
    $trace = "" #To save log as a txt
    $ScriptDuration = Get-Date
    
    #region:Functions

    function WriteInfo([string]$message,[switch]$WaitForResult){
        if($WaitForResult){
            Write-Host "[$(Get-Date -Format hh:mm:ss)] INFO:    $("`t" * $script:LogLevel)$message" -NoNewline
            $Script:Trace += "[$(Get-Date -Format hh:mm:ss)] INFO:    $("`t" * $script:LogLevel)$message" 
        }
        else{
            Write-Host "[$(Get-Date -Format hh:mm:ss)] INFO:    $("`t" * $script:LogLevel)$message"  
            $Script:Trace += "[$(Get-Date -Format hh:mm:ss)] INFO:    $("`t" * $script:LogLevel)$message`r`n" 
        }
    }

    function WriteResult([string]$message,[switch]$Pass,[switch]$Success){
        if($Pass){
            $Script:Trace += " - Pass`r`n"
            Write-Host " - Pass" -ForegroundColor Cyan
            if($message){
                $Script:Trace += "[$(Get-Date -Format hh:mm:ss)] INFO:    $("`t" * $script:LogLevel)`t$message`r`n" 
                Write-Host "[$(Get-Date -Format hh:mm:ss)] INFO:    $("`t" * $script:LogLevel)`t$message" -ForegroundColor Cyan
            }
        }
        if($Success){
            $Script:Trace += " - Success`r`n"
            Write-Host " - Success" -ForegroundColor Green
            if($message){
                $Script:Trace += "[$(Get-Date -Format hh:mm:ss)] INFO:    $("`t" * $script:LogLevel)`t$message`r`n" 
                Write-Host "[$(Get-Date -Format hh:mm:ss)] INFO:    $("`t" * $script:LogLevel)`t$message" -ForegroundColor Green
            }
        } 
    }

    
    function WriteInfoHighlighted([string]$message){
        $Script:Trace += "[$(Get-Date -Format hh:mm:ss)] INFO:    $("`t" * $script:LogLevel)$message`r`n" 
        Write-Host "[$(Get-Date -Format hh:mm:ss)] INFO:   $("`t" * $script:LogLevel)$message" -ForegroundColor Cyan
    }

    function WriteSuccess([string]$message){
        $Script:Trace += "[$(Get-Date -Format hh:mm:ss)] Success: $("`t" * $script:LogLevel)$message`r`n" 
        Write-Host "[$(Get-Date -Format hh:mm:ss)] Success: $("`t" * $script:LogLevel)$message" -ForegroundColor Green
    }

    function WriteError([string]$message){
        ""
        $Script:Trace += "[$(Get-Date -Format hh:mm:ss)] ERROR:   $("`t" * $script:LogLevel)$message`r`n" 
        Write-Host "[$(Get-Date -Format hh:mm:ss)] ERROR:   $("`t" * $script:LogLevel)$message" -ForegroundColor Red
        
    }

    function WriteErrorAndExit($message){
        $Script:Trace += "[$(Get-Date -Format hh:mm:ss)] ERROR:   $("`t" * $script:LogLevel)$message`r`n" 
        Write-Host "[$(Get-Date -Format hh:mm:ss)] ERROR:   $("`t" * $script:LogLevel)$message"  -ForegroundColor Red
        Write-Host "Press any key to continue ..."
        $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | OUT-NULL
        $HOST.UI.RawUI.Flushinputbuffer()
        Throw "Terminating Error"
    }

    #endregion
    
    #region:Begin Logging
    $loglevel = 0 #We use this variable to add tabs in log messages.
    Write-Information "Starting VMWare to Hyper-V Conversion - $(Get-date)"
    #endregion
    
    #region: Input validation

    #under development.

    #endregion

    #region:Prepare Environment
    $loglevel = 0
    WriteInfo "Preparing Environment"
        
        $loglevel = 1
        #Import MVMC Module from local folder
        WriteInfo "Importing MVMC module from local folder." -WaitForResult
        Import-Module .\MVMCCmdlet\MvmcCmdlet.psd1
        WriteResult -Pass

        #Import VMWare Core module with prefix VMWare to avoid conflicts with HV module
        WriteInfo "Importing VMWare.VimAutomation.Core." -WaitForResult
        Import-Module -Name VMware.VimAutomation.Core -Prefix VMWare
        WriteResult -Pass
        
        #Create session on vSphere server
        if($VMWareCredentials){ #Connect with supplied credentials
            WriteInfo "Connecting to vSphere server: $VMWareVSphereServer as $($VMWareCredentials.UserName)" -WaitForResult
            Connect-VMWareVIServer -Server $VMWareVSphereServer -Credential $VMWareCredentials | Out-Null
            WriteResult -Success
        }
        else{ #Connect using session credentials
            WriteInfo "Connecting to vSphere server: $VMWareVSphereServer as $($env:USERDOMAIN)\$($env:USERNAME)" -WaitForResult
            Connect-VMWareVIServer -Server $VMWareVSphereServer -Credential $VMWareCredentials | Out-Null
            WriteResult -Success
        }
        
        
        #Import VMM Module if selected and connect to VMM Server
        if($HVManagement -eq "VMM"){
            WriteInfo "Importing VMM module." -WaitForResult
            Import-Module -Name VirtualMachineManager
            WriteResult -Pass

            if($VMMCredentials){
                WriteInfo "Connecting to VMM Server: $VMMServer as $($VMMCredentials.UserName)" -WaitForResult
                Get-SCVMMServer -ComputerName $VMMServer -Credential $VMMCredentials | Out-Null
                WriteResult -Success
            }
            else{
                WriteInfo "Connecting to VMM Server: $VMMServer as $($env:USERDOMAIN)\$($env:USERNAME)" -WaitForResult
                Get-SCVMMServer -ComputerName $VMMServer -Credential $VMMCredentials | Out-Null
                WriteResult -Success        
            }
        }

        #Import Hyper-V Module if selected
            #not developled
        if($HVManagement -eq "Hyper-V"){
            WriteErrorAndExit "Hyper-V is not yet developed"
            Import-Module -Name Hyper-V
            WriteInfo -message "Imported Hyper-V module."
        }

    #endregion
    
    #region: Perform some checks
    $loglevel = 0
    WriteInfo "Performing checks."
        $loglevel = 1
        #region: Check that VM exists on VMWare and save it to a variable
        WriteInfo -message "Checking that VM '$VMName' exists on VMWare." -WaitForResult
        $VMWareVM = Get-VMWareVM -Name $VMName
        if ($VMWareVM.GetType().Name -ne "UniversalVirtualMachineImpl") {throw "VM '$VMName' not foudn on VCenter. Script will termiante."}
        WriteResult -Pass
        #endregion

        #region: Check that a VM with the same name does not exist on HV or VMM
        WriteInfo "Checking that a VM with the same name does not exist on $HVManagement." -WaitForResult
        if($HVManagement -eq "VMM"){
            if((Get-SCVirtualMachine -Name $VMName | where {$_.VirtualizationPlatform -eq "HyperV"}) -ne $null){
                WriteErrorAndExit "a VM with the same name already exists on $HVManagement."
            }
        }
        WriteResult -Pass
        #endregion

        #region: Check for snapshots
        WriteInfo "Checking that the VM has no snapshots." -WaitForResult
        $VMWareVMSnapshots = Get-VMWareSnapshot -VM $VMWareVM 
        if ($VMWareVMSnapshots -ne $null) {Throw "VM has snapshots. Please merge all and try again."}
        WriteResult -Pass        
        #endregion
        
        #region: Checks depending on Uninstall VMWare Tools option
        switch($UninstallVMWareTools){
        $true {
              WriteInfo "Uninstall VMWare Tools is selected."
              $loglevel = 2
                    #region: Check that the VM is turned on.
                    writeinfo "Checking that the VM is turned on." -WaitForResult
                    if($VMWareVM.PowerState -ne "PoweredOn"){ Throw "VM is powered off. Please turn it on and try again."}
                    WriteResult -Pass
                    #endregion
                    #region: Check that VMWare Tools are healthy
                    writeinfo "Checking that VMWare Tools are healthy." -WaitForResult
                    if($VMWareVM.ExtensionData.Guest.ToolsStatus -ne "ToolsOk") {Throw "VM Ware Tools are not healthy."}
                    WriteResult -Pass
                    #endregion
              }
        $false{
              WriteInfo "Uninstall VMWare Tools is not selected."
              $loglevel = 2
                    #region: Check that the VM is powered off
                    WriteInfo "Checking that the VM powered off." -WaitForResult
                    if ($VMWareVM.PowerState.ToString() -eq "PoweredOn") {Throw "VM is running. Please turn it off and try again."}
                    WriteResult -Pass
                    #endregion

                    #Check VMWare Tools are not installed
                    WriteInfo "Checking that the VMWare Tools is not installed." -WaitForResult
                    $VMwareToolsVersion = $VMWareVM.Guest.ToolsVersion
                    if ($VMwareToolsVersion -ne "" -and $IgnoreVMWareTools -eq $false) {Throw "VMWare Tools are installed. Please uninstall and try again. To skip this validation use '-IgnoreVMWareTools' switch."}
                    if ($VMwareToolsVersion -ne "" -and $IgnoreVMWareTools -eq $true) {WriteError "VMWare Tools are installed. Script will contiue as the 'IgnoreVMWareTools' switch is selected."}
                    WriteResult -Pass
              }
        }
        $loglevel = 1
        #endregion
        
        #region:Check that VMM template exists and save it to a variable
        WriteInfo -message "Checking that VMM template '$VMMTemplateName' exists." -WaitForResult
        $VMMTemplate = Get-SCVMTemplate -Name $VMMTemplateName
        if($VMMTemplate.GetType().FullName -eq "Microsoft.SystemCenter.VirtualMachineManager.Template"){
            WriteResult -message "Template supports generation $($VMMTemplate.Generation) VMs." -Pass
        }
        else {throw "VMM template does not exist."}
        #endregion

        #region: Check VM Has disks 
        WriteInfo "Checking that the VM has Flat disks." -WaitForResult
        $VMWareDisks = @()+ (Get-VMWareHardDisk -VM $VMWareVM -DiskType Flat)
        if ($VMWareDisks -eq @()) {Throw "VM Does not have any disks."}
        WriteResult "VM has $($VMWareDisks.Count) disk(s)." -Pass
        #endregion

        #region: Check that VM and Template have the same generation.
        if($HVManagement -eq "VMM"){
            WriteInfo "Checking that the VM is the same generation as VMM template." -WaitForResult
            if($VMWareVM.ExtensionData.Config.Firmware -eq "bios" -and $VMMTemplate.Generation -ne 1) {Throw "VM Template must be Generation 1 to support BIOS."}
            if($VMWareVM.ExtensionData.Config.Firmware -eq "efi" -and $VMMTemplate.Generation -ne 2) {Throw "VM Template must be Generation 2 to support EFI."}
            WriteResult -Pass
        }
        #endregion
    $loglevel = 0
    #endregion
   
    #region: Create some variables
    $loglevel = 0
    writeinfo "Creating Additonal Variables"
        $loglevel = 1
        #region: Copy VMWare VM CPU and RAM
        if ($UseVMwareCPUandRAM -eq $true){
            writeinfo "Copying CPU and RAM settings from VMWare." 
            $VMCPUs = $VMWareVM.NumCpu
            $VMRAM = $VMwareVM.MemoryMB
            WriteInfoHighlighted -message "New VM will have $VMCPUs processors and $VMRAM MB static memory as per VMWare specs."
        }
        #endregion

        #region:VMWare VM vNICs
        $VMWareVMNics = @() + (Get-VMWareNetworkAdapter -VM $VMWareVM)
        WriteInfoHighlighted -message "VM will have $($VMWareVMNics.Count) vNICs."
        #endregion
        
        #HV Host is always the current host.
        $VMHost = $env:COMPUTERNAME
        WriteInfoHighlighted "VM will be placed on $VMHost"
    $loglevel = 0
    #endregion
    
    #region: Uninstall VMWare Tools and Shutdown VM
    if($UninstallVMWareTools){
    $loglevel = 0
    WriteInfo "Uninstalling VMWare Tools."
        $loglevel = 1
        #region: Create PS session
        $VMFQDN = $VMWareVM.ExtensionData.Guest.HostName
        if($VMGuestCredential){
            WriteInfo "Connecting to VM using PowerShell session: $VMFQDN as $($VMGuestCredential.UserName)" -WaitForResult
            $VMPSSession = New-PSSession -ComputerName $VMFQDN -Credential $VMGuestCredential
            WriteResult -Success
        }
        else{
            WriteInfo "Connecting to VM using PowerShell session: $VMFQDN as $($env:USERDOMAIN)\$($env:USERNAME)" -WaitForResult
            $VMPSSession = New-PSSession -ComputerName $VMFQDN
            WriteResult -Success
        }
        #endregion

        #region: Invoke Powershell script
        WriteInfo "Invoking PowerShell script to unintall VMWare Tools and Shutdown VM after restart." -WaitForResult
        Invoke-Command -Session $VMPSSession -ScriptBlock{              
            try{
            #Create Powershell script using Base64
            New-Item -Path C:\ -Name PSScript -ItemType Directory | Out-Null
            $ShutdownScript = [convert]::FromBase64String("IgBTAHQAYQByAHQAaQBuAGcAIgAgAHwAIABPAHUAdAAtAEYAaQBsAGUAIABDADoAXABQAFMAUwBjAHIAaQBwAHQAXABsAG8AZwAuAHQAeAB0AA0ACgAiAFIAZQBtAG8AdgBpAG4AZwAgAFMAYwBoAGUAZAB1AGwAZQBkACAAVABhAHMAawAiACAAfAAgAEEAZABkAC0AQwBvAG4AdABlAG4AdAAgAEMAOgBcAFAAUwBTAGMAcgBpAHAAdABcAGwAbwBnAC4AdAB4AHQADQAKAFUAbgByAGUAZwBpAHMAdABlAHIALQBTAGMAaABlAGQAdQBsAGUAZABUAGEAcwBrACAALQBUAGEAcwBrAE4AYQBtAGUAIAAiAFMAaAB1AHQAZABvAHcAbgBPAG4AUwB0AGEAcgB0AHUAcAAiACAALQBDAG8AbgBmAGkAcgBtADoAJABmAGEAbABzAGUADQAKACIAUgBlAG0AbwB2AGUAZAAiACAAfAAgAEEAZABkAC0AQwBvAG4AdABlAG4AdAAgAEMAOgBcAFAAUwBTAGMAcgBpAHAAdABcAGwAbwBnAC4AdAB4AHQADQAKACIAUgBlAG0AbwB2AGkAbgBnACAAUwBjAHIAaQBwAHQAIABmAG8AbABkAGUAcgAiAA0ACgBSAGUAbQBvAHYAZQAtAEkAdABlAG0AIAAtAFAAYQB0AGgAIABDADoAXABQAFMAUwBjAHIAaQBwAHQAIAAtAFIAZQBjAHUAcgBzAGUAIAAtAEYAbwByAGMAZQAgAC0AQwBvAG4AZgBpAHIAbQA6ACQAZgBhAGwAcwBlAA0ACgAiAFIAZQBtAG8AdgBlAGQAIgANAAoAIgBTAGgAdQB0AHQAaQBuAGcAIABEAG8AdwBuACIAIAB8ACAAQQBkAGQALQBDAG8AbgB0AGUAbgB0ACAAQwA6AFwAUABTAFMAYwByAGkAcAB0AFwAbABvAGcALgB0AHgAdAAgAA0ACgBTAHQAYQByAHQALQBQAHIAbwBjAGUAcwBzACAALQBGAGkAbABlAFAAYQB0AGgAIAAiAFMAaAB1AHQAZABvAHcAbgAuAGUAeABlACIAIAAtAEEAcgBnAHUAbQBlAG4AdABMAGkAcwB0ACAAIgAtAHMAIAAtAHQAIAAzACIADQAKACIARwBvAG8AZAAgAEIAeQBlACIAIAB8ACAAQQBkAGQALQBDAG8AbgB0AGUAbgB0ACAAQwA6AFwAUABTAFMAYwByAGkAcAB0AFwAbABvAGcALgB0AHgAdAA=")
            $ShutdownScript = [System.Text.Encoding]::unicode.getstring($ShutdownScript)
            $ShutdownScript | Out-File C:\PSScript\Shutdown.ps1
                    
            #Create Scheduled Task to shutdown upon restart
            $Trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay 00:01:00
            $Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "&'C:\PSScript\Shutdown.ps1'"                    
            $regTask = Register-ScheduledTask -User SYSTEM -TaskName "ShutdownOnStartup" -Action $Action -Trigger $Trigger 

            #Uninstall VMWare Tools and restart
            $VMWareToolsGUID = (Get-ChildItem HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall | ForEach-Object {Get-ItemProperty $_.PsPath} | Where-Object {$_.DisplayName -eq "VMWare Tools"})[0].PSChildName
            Start-Process  -FilePath msiexec.exe -ArgumentList "/x $VMWareToolsGUID /quiet /forcerestart"
            }
            Catch{
                return $error[0]
            }
        }
        WriteResult -Success
        #endregion

        #region: Wait for VM to shutdown
        writeinfo "Waiting for VM to shutdown."
        $WaitDuration = Get-Date
        while ((Get-VMWareVM -Name $VMName).PowerState -ne "PoweredOff"){
            writeinfo "VM is still on, waiting for 10 seconds. Have been waiting for: $([int]((Get-date) - $WaitDuration).totalminutes) minutes."
            Start-Sleep -Seconds 10
        }
        WriteInfoHighlighted "VM is now PoweredOff."
        #endregion
        WriteSuccess "VMWare Tools uninstalled successfully."
    }
    #endregion

    #region: Create new VM
    switch ($HVManagement){
        "VMM"{
            #Create VM on VMM
            WriteInfo "Creating VM using VMM on current server '$VMHost' in '$DestinationFolderPath'." -WaitForResult
            $VM = New-SCVirtualMachine -VMTemplate $VMMTemplate -Name $VMName -VMHost $VMHost -Path $DestinationFolderPath
            WriteResult -Success

            #Create additional NICs if any
            if($VMWareVMNics.Count -gt 1){
                WriteInfo -message "Adding $($VMWareVMNics.count - 1) NICs." -WaitForResult
                for ($i=1 ; $i -le ($VMWareVMNics.Count -1) ; $i++){ #for 2 NICs we only need to create 1 as the other is already in the template.
                    New-SCVirtualNetworkAdapter -VM $VM -Synthetic -MACAddressType "Static"| Out-Null
                }
                WriteResult -Success
            }
            
            #Copy MAC address from VMWare if selected.
            if($UseVMWareMAC){
                WriteInfo -message "Copying MAC Address(es) from VMWare to new VM." -WaitForResult
                $VMMVMNics = @() + (Get-SCVirtualNetworkAdapter -VM $VM)
                for($i=0;$i -lt $VMMVMNics.Count ; $i++){
                    $MAC = $VMWareVMNics[$i].MacAddress
                    Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $VMMVMNics[$i] -MACAddress $MAC -MACAddressType "Static"
                }
                WriteResult -Success
            }

            #Copy CPU and memory settings from VMWare if selected
            if($UseVMwareCPUandRAM){
                WriteInfo "Copying CPU and memory settings from VMWare to new VM." -WaitForResult
                Set-SCVirtualMachine -VM $VM -DynamicMemoryEnabled $false -MemoryMB $VMRAM -CPUCount $VMCPUs | Out-Null
                WriteResult -Success
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
    $loglevel =1
    foreach ($VMDK in $VMWareDisks){
        $VMDKIndex = $VMWareDisks.IndexOf($VMDK)
        if($VMDKIndex -eq 0){
            #Same as VM
            $VHDXDestination = $vm.Location
        }
        else{ #Additional Disks
            #Custom location for additional disks
            if($AdditionalDisksPath -eq $null) {$VHDXDestination = $vm.Location} #Same as VM
            else {$VHDXDestination = ((Get-Item -Path $AdditionalDisksPath).FullName + "\$($VM.Name)")} #Custom Location
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
            $PSDriveName = ($VMName +"VMDS")
            New-PSDrive -Name $PSDriveName -PSProvider VimDatastore -Root "\" -Location $VMDKDatastore | Out-Null
        
            WriteInfo "Downloading: [$($VMDKDatastore.Name)] $VMDKPath to $VMDKDestination" -WaitForResult
            $Duration = Measure-Command -Expression {Copy-VMWareDatastoreItem -Item "$PSDriveName`:\$VMDKPath" -Destination $VMDKDestination}
            WriteResult -Success -message "Download complete. Duration: $($Duration.ToString())"
        
            WriteInfo "Downloading: [$($VMDKDatastore.Name)] $VMDKFlatPath to $VMDKFlatDestination"  -WaitForResult
            $Duration = Measure-Command -Expression {Copy-VMWareDatastoreItem -Item "$PSDriveName`:\$VMDKFlatPath" -Destination $VMDKFlatDestination}
            WriteResult -Success -message "Download complete. Duration: $($Duration.ToString())"

            Remove-PSDrive -Name $PSDriveName
        }
        #Convert to VHDX
        $VHDXFileName = $VMDKFileName.Replace(".vmdk",".vhdx")
        $VHDXPath = "$VHDXDestination\$VHDXFileName"

        WriteInfo "Converting VMDK file '$VMDKFileName' to VHDX: $VHDXPath" -WaitForResult
        $ConvertToParameters = @{
            SourceLiteralPath      = "$VMDKDestination"
            DestinationLiteralPath = $VHDXPath
            VhdType                = $VHDXType
            VhdFormat              = "VHDX"
        }
        $Duration = Measure-Command -Expression {ConvertTo-MvmcVirtualHardDisk @ConvertToParameters | Out-Null}
        WriteResult -Success -message "Converted VMDK to VHDX: $VHDXPath - Duration: $($Duration.ToString())"

        #Delete downloaded files
        if($Cleanup){
            WriteInfo "Deleting downloaded VMDK." -WaitForResult
            ($VMDKDestination,$VMDKFlatDestination) | Remove-Item -Force -ErrorAction Continue
            WriteResult -Success
        }
    



        #Attach VHDX to VM
        if($VMDKIndex -eq 0){
            WriteInfo "Attaching VHDX '$VHDXFileName to VM as OS Disk." -WaitForResult
            switch ($VM.Generation)
            {
                1 {New-SCVirtualDiskDrive -VM $VM -Path $VHDXDestination -FileName "$VHDXFileName" -UseLocalVirtualHardDisk -VolumeType BootAndSystem -IDE -Bus 0 -LUN 0 | Out-Null}
                2 {New-SCVirtualDiskDrive -VM $VM -Path $VHDXDestination -FileName "$VHDXFileName" -UseLocalVirtualHardDisk -VolumeType BootAndSystem -SCSI -Bus 0 -LUN 0| Out-Null}
            }
            WriteResult -Success
        }
        else{
            WriteInfo "Attaching VHDX '$VHDXFileName' VM as additional disk." -WaitForResult
            switch ($VM.Generation)
            {
                1 {
                    if($SCSICreated -eq $null){
                        New-SCVirtualScsiAdapter -VM $VM | Out-Null
                        $SCSICreated = "Created"
                    }
                    New-SCVirtualDiskDrive -VM $VM -Path $VHDXDestination -FileName "$VHDXFileName" -UseLocalVirtualHardDisk -SCSI -Bus 0 -LUN $VMDKIndex | Out-Null
                  }
                2 {New-SCVirtualDiskDrive -VM $VM -Path $VHDXDestination -FileName "$VHDXFileName" -UseLocalVirtualHardDisk -SCSI -Bus 0 -LUN ($VMDKIndex+1)| Out-Null}
            }
            WriteResult -Success
        }
    }

    #endregion

    #region: Start VM
        if($StartVM){
            WriteInfo "Starting VM" -WaitForResult
            Start-SCVirtualMachine -VM $VM | Out-Null
            WriteResult -Success
        }

    #endregion

    $ScriptDuration = ((Get-Date) - $ScriptDuration).ToString()
    WriteSuccess "VMWare to Hyper-V Conversion Completed. Duration: $ScriptDuration"
}
catch
{
    $trace += $Error[0]
    Throw $Error[0]
}
finally
{
    if(Get-PSDrive -Name "$" -ErrorAction SilentlyContinue) {Remove-PSDrive -Name "VMDS"}
    Disconnect-VMWareVIServer -Confirm:$false
    if($LogFolderPath -ne $null){
        $Path = "$((get-item $LogFolderPath).FullName)\$VMName$(Get-Date -Format yyyyMMddHHmmss).log"
        $trace | Out-File -FilePath $Path -Force
    }

}
}