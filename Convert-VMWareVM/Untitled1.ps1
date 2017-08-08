cd C:\Convert-VMWareVM

#$VMMCredentials = Get-Credential
#$VMWareCredentials = Get-Credential

$SplattingRocks = @{
    HVManagement          = "VMM"
    VMMServer             = "DCVMMHA"
    VMMCredentials        = $VMMCredentials 
    VMWareVCenterServer   = "srvVC6"
    VMWareCredentials     = $VMWareCredentials 
    VMName                = "Arch-Lic" 
    UseVMwareCPUandRAM    = $true
    VMMTemplateName       = "Blank Generation 1 Template"
    DestinationFolderPath = "C:\ClusterStorage\Volume5"
    AdditionalDisksPath   = "C:\ClusterStorage\Volume3"
    StagingFolderPath     = "C:\VMWareMigrate"
    SaveAdditionalDisksInDifferentLocation = $true
    DoNotRedownload       = $true
    VHDXType              = "FixedHardDisk"
    Cleanup               = $true
    StartVM               = $true
}
.\Convert-VMWareVM.ps1 @SplattingRocks 
