$VMMCreds = Get-Credential
$test = New-PSSession -ComputerName DCVMMHA -Credential $VMMCreds

Invoke-Command -Session $test -ScriptBlock {
    #Import-Module VirtualMachineManager
    get-scvirtualmachine -Name CL2
}

Invoke-Command -Session $test -ScriptBlock {
    Remove-Module -Name virtualmachinemanager
}

Get-PSSession | Remove-PSSession


$SplattingRocks = @{
    HVManagement          = "VMM"
    VMMServer             = "DCVMMHA"
    VMMCredentials        = $VMMCredentials 
    VMWareVCenterServer   = "srvVC6"
    VMWareCredentials     = $VMWareCredentials 
    VMName                = "CL2" 
    UseVMwareCPUandRAM    = $true
    VMMTemplateName       = "Blank Generation 1 Template"
    DestinationFolderPath = "C:\ClusterStorage\Volume1"
}
.\Convert-VMWareVM.ps1 @SplattingRocks 