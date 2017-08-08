$Password = "" | ConvertTo-SecureString -AsPlainText -Force
$VMwareCreds = New-Object -TypeName pscredential -ArgumentList ("DMSD\ayman",$Password)

$VIServer = "srvVC6"

$IgnoreVMWareTools = $false

$VMName = "CairoCA"

$StagingPath = (Get-Item "C:\VMWareMigrate").FullName

Import-Module VMware.VimAutomation.Core -Prefix VMWare | Out-Null

Connect-VMWareVIServer -Server $VIServer -Credential $VMwareCreds | Out-Null

#Get VM object from VMWare
$VMWareVM = Get-VMWareVM -Name $VMName

#Check the VM is turned off
$VMWareVMStatus = $VMWareVM.PowerState
if ($VMWareVMStatus.ToString() -eq "PoweredOn") {Throw "VM is running. Please turn it off and try again."}

#Check for snapshots
$VMWareVMSnapshots = Get-VMWareSnapshot -VM $VMWareVM 
if ($VMWareVMSnapshots -ne $null) {Throw "VM has snapshots. Please merge all and try again."}

#Check VMWare Tools are not installed

$VMwareToolsVersion = $VMWareVM.Guest.ToolsVersion
if ($VMWareVMSnapshots -eq "" -and $IgnoreVMWareTools -eq $false) {Throw "VMWare Tools are installed. Please uninstall and try again. To skip this validation use '-IgnoreVMWareTools' switch."}

#Check VM Has disks 

$VMWareDisks = @()+ (Get-VMWareHardDisk -VM $VMWareVM)
if ($VMWareDisks -eq @()) {Throw "VM Does not have any disks."}

#VM bios or efi for Hyper-V Generation
$VMFirmware = $VMWareVM.ExtensionData.Config.Firmware

#VM NIC information
$VMWareVMNics = @() + (Get-VMWareNetworkAdapter -VM $VMWareVM)

#Download, Convert, and attach VMDK Files
foreach ($VMDK in $VMWareDisks){
    $VMDKDatastore = Get-VMWareDatastore -ID ($VMDK.ExtensionData.Backing.Datastore)
    $VMDKPath = $VMDK.Filename.Split("] ")[-1].replace("/","\")
    $VMDKFileName = $VMDK.Filename.Split("/")[-1]
    $VMDKFlatPath = $VMDKPath.Replace(".vmdk","-flat.vmdk")
    $VMDKFlatFileName = $VMDKFileName.Replace(".vmdk","-flat.vmdk")
    
    $VHDXFileName = $VMDKFileName.Replace(".vmdk",".vhdx")

    if(Get-PSDrive -Name vmds -ErrorAction SilentlyContinue) {Remove-PSDrive -Name VMDS}

    New-PSDrive -Name VMDS -PSProvider VimDatastore -Root "\" -Location $VMDKDatastore
    
    Set-Location -Path C:
    
    Copy-VMWareDatastoreItem -Item "VMDS:\$VMDKPath" -Destination "$StagingPath\$VMDKFileName"

    Copy-VMWareDatastoreItem -Item "VMDS:\$VMDKFlatPath" -Destination "$StagingPath\$VMDKFlatFileName"

    import-module "\\walid\d$\Temp\MVMCCmdlet\MvmcCmdlet.psd1"

    ConvertTo-MvmcVirtualHardDisk -VhdType FixedHardDisk -VhdFormat Vhdx -SourceLiteralPath "$StagingPath\$VMDKFileName" -DestinationLiteralPath "$StagingPath\$VHDXFileName"
}

$VMWareVMOSDisk = $VMWareDisks[0]

