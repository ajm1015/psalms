# Config
$WinPE = "C:\WinPE"
$ADKBase = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit"
$ADK   = "$ADKBase\Windows Preinstallation Environment"
$ISO   = "C:\ISO\Win11.iso"
$USB   = "D:"
$ErrorActionPreference = "Stop"

# Set environment variables that copype.cmd needs
$env:WinPERoot = $ADK
$env:OSCDImgRoot = "$ADKBase\Deployment Tools\amd64\Oscdimg"
$env:DandIRoot = "$ADKBase\Deployment Tools"
$env:Path = "$ADKBase\Deployment Tools\amd64\DISM;$env:Path"

# Clean up previous attempts
if (Test-Path $WinPE) { Remove-Item $WinPE -Recurse -Force }

# Mount ISO and create WinPE
$vol = (Mount-DiskImage $ISO -PassThru | Get-Volume).DriveLetter
& "$ADK\copype.cmd" amd64 $WinPE

# Mount boot.wim and add startup script
dism /Mount-Wim /WimFile:"$WinPE\media\sources\boot.wim" /Index:1 /MountDir:"$WinPE\mount"
if ($LASTEXITCODE -ne 0) { throw "DISM mount failed" }

@"
wpeinit
cls
echo.
echo  ██╗███╗   ███╗ █████╗  ██████╗ ██╗███╗   ██╗ ██████╗
echo  ██║████╗ ████║██╔══██╗██╔════╝ ██║████╗  ██║██╔════╝
echo  ██║██╔████╔██║███████║██║  ███╗██║██╔██╗ ██║██║  ███╗
echo  ██║██║╚██╔╝██║██╔══██║██║   ██║██║██║╚██╗██║██║   ██║
echo  ██║██║ ╚═╝ ██║██║  ██║╚██████╔╝██║██║ ╚████║╚██████╔╝
echo  ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝╚═╝  ╚═══╝ ╚═════╝
echo.
echo  Windows 11 Auto Deploy
echo  ========================================
echo.

@rem High performance power plan (prevents CPU throttling on laptops)
powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

@rem Find USB drive by looking for our scripts folder
for %%d in (C D E F G H) do if exist %%d:\scripts\partition.txt set USB=%%d:
if not defined USB (echo USB DRIVE NOT FOUND & pause & exit)
echo Found USB at %USB%

echo Running diskpart...
diskpart /s %USB%\scripts\partition.txt
if errorlevel 1 (echo DISKPART FAILED & pause & exit)

echo Applying Windows image...
dism /Apply-Image /ImageFile:%USB%\sources\install.swm /SWMFile:%USB%\sources\install*.swm /Index:1 /ApplyDir:W:\
if errorlevel 1 (echo DISM FAILED & pause & exit)

echo Setting up boot...
bcdboot W:\Windows /s S: /f UEFI
if errorlevel 1 (echo BCDBOOT FAILED & pause & exit)

echo SUCCESS! Press any key to reboot...
pause
wpeutil reboot
"@ | Set-Content "$WinPE\mount\Windows\System32\startnet.cmd"

# Increase WinPE scratch space (default 32MB is a bottleneck for DISM)
dism /Image:"$WinPE\mount" /Set-ScratchSpace:512

dism /Unmount-Wim /MountDir:"$WinPE\mount" /Commit
if ($LASTEXITCODE -ne 0) { throw "DISM unmount failed, error code: $LASTEXITCODE" }

# Create partition script
mkdir "$WinPE\media\scripts" -Force | Out-Null

@"
select disk 0
clean
convert gpt
create partition efi size=100
format fs=fat32 quick label=System
assign letter=S
create partition msr size=16
create partition primary
format fs=ntfs quick label=Windows
assign letter=W
exit
"@ | Set-Content "$WinPE\media\scripts\partition.txt"

# Copy install.wim, split for FAT32, then clean up
Copy-Item "${vol}:\sources\install.wim" "$WinPE\media\sources\"
Dismount-DiskImage $ISO

dism /Split-Image /ImageFile:"$WinPE\media\sources\install.wim" /SWMFile:"$WinPE\media\sources\install.swm" /FileSize:3800
if ($LASTEXITCODE -ne 0) { throw "DISM split failed" }
Remove-Item "$WinPE\media\sources\install.wim" -Force

# Prepare USB manually (MakeWinPEMedia.cmd fails on drives >32GB due to FAT32 limit)
# Cap partition to media size + 512MB buffer so FAT32 format works on any size drive
$mediaSizeMB = [math]::Ceiling((Get-ChildItem "$WinPE\media" -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB) + 512
$usbDisk = (Get-Partition -DriveLetter ($USB.TrimEnd(':'))).DiskNumber
$dpScript = "$env:TEMP\prep_usb.txt"
@"
select disk $usbDisk
clean
create partition primary size=$mediaSizeMB
format fs=fat32 quick label=WinPE
assign letter=$($USB.TrimEnd(':'))
active
exit
"@ | Set-Content $dpScript

diskpart /s $dpScript
if ($LASTEXITCODE -ne 0) { throw "DiskPart USB prep failed ($LASTEXITCODE)" }
Remove-Item $dpScript -Force

# Copy WinPE media to USB (multithreaded for speed)
robocopy "$WinPE\media" "$USB\" /E /MT:16 /NFL /NDL /NJH /NJS
if ($LASTEXITCODE -ge 8) { throw "Robocopy failed ($LASTEXITCODE)" }
