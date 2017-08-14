# Convert-VMWareVM
A PowerShell script that converts a VMWare VM on VCenter to Hyper-V VM.

## Notice
This script is still a work in progress. so proceed with caution. 
At the time being it requires VMM to work, in a future release I will include a Hyper-V only option or maybe Hyper-V with clustering. 

*If you are using Hyper-V on a production scale, I highly recommend you implement VMM to manage it.

## Prerequisites
PowerCLI must be installed on the computer running the script.
VMM console must be installed on the computer running hte script.
VMM templates WITHOUT DISKS witht the same generation as the VMWare VM - BIOS = G1, EFI = G2

## Usage
Run the script on the Hyper-V server that will host the VM. In a clustered environment, run on the node where the VM will be created on then move it as desired.
  
## Example

The below example will convert VM1 and VM2:

"VM1","VM2" | foreach {$SplattingRocks = @{
    HVManagement          = "VMM"
    VMMServer             = "VMMServerFQDN"
    #VMMCredentials        = $VMMCredentials 
    VMWareVSphereServer   = "vSphereServerFQDN"
    VMWareCredentials     = $VMWareCredentials
    VMName                = $_ 
    UseVMwareCPUandRAM    = $true
    VMMTemplateName       = "Blank Generation 1 Template"
    DestinationFolderPath = "C:\ClusterStorage\Volume5"
    AdditionalDisksPath   = "C:\ClusterStorage\Volume1"
    StagingFolderPath     = "C:\VMWareMigrate"
    #DoNotRedownload       = $true
    VHDXType              = "FixedHardDisk"
    Cleanup               = $true
    StartVM               = $true
    LogFolderPath         = "C:\temp"
    UninstallVMWareTools  = $true
} ;
& '.\Convert-VMWare2.ps1' @SplattingRocks }
