# Msfvenom Windows Reverse Engineering Lab
This repo is for setting up a Windows 11 VM for reverse engineer msfvenom's Windows shellcode.

> [!IMPORTANT]
> You should have all the steps in [Setup Lab VM](#setup-lab-vm) finished before the scheduled meetup, since there will be a lot of topics covered in this lab.
> If you run into issues while using the [Setup Lab VM](#setup-lab-vm) instructions, DM drkstar46 in the dc303 discord channel.

## Setup Lab VM
VM Specs:
- CPU: 2x
- RAM: 4GB
- DISK: 64GB

### Setup Fresh Windows 11 Pro VM
You will need a VM with a fresh install of **Windows 11 Pro** (no license necessary for install and use in lab env). You can either use a local hypervisor on the computer you plan on using in the lab (VMWare, Hyper-V, VirtualBox, etc), or a VM provided by a VDI provider (AWS, M365, etc).

#### Download Intel/AMD x64 ISO
If you are setting up your VM on a Windows or linux computer using an Intel or AMD processor, Go to [this link](https://www.microsoft.com/en-us/software-download/windows11) and under **Download Windows 11 Disk Image (ISO) for x64 devices**, select `Windows 11 (multi-edition ISO for x64 devices)`, then click the Confirm button. 

You will then be asked to **Select the product language** (I chose English (United States)). Once selected, click the Confirm button.

This will display a button that says **64-bit Download**. Click this button and your download should begin.

#### Download ARM x64 ISO (M1+ Macs)
If you are using a Mac with the newer ARM processors, you will need to go [here](https://www.microsoft.com/en-us/software-download/windows11arm64) to download Windows 11. Select select `Windows 11 (multi-edition ISO for Arm64)`, then click the Download Now button. 

You will then be asked to **Select the product language** (I chose English (United States)). Once selected, click the Confirm button.

This will display an additional button that says **Download Now**. Click this button and your download should begin.

### Install Hypervisor tools
Make sure to install the hypervisor tools into your VM so that the screen renders better, and you can take advantage of built-in tools.

### Take a snapshot of your VM
It's good practice to take a snapshot of a clean VM setup, so that if the install script creates issues, you can start back from a good restore point instead of having to restart the whole build process.

### Run lab-setup.ps1 script

You will need to open a powershell window as administrator (right-click powershell and select "Run as Administrator"). 

Once the powershell window is open, you can run the script like so:
```powershell
iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/nick-neal/msfvenom-win-reveng-lab/refs/heads/main/lab-setup.ps1'))
```
The script will perform the following actions in your VM:

- Download and Install OpenJDK
- Download and Install Ghidra
- Download and Install WinDbg
- Download and Install Python 3.10
    - Install speakeasy-emulator module
- Download and setup SysInternal tools
- Create C:\demo directory and whitelist the directory in MSDefender
- Set powershell execution policy to unrestricted
- Download the following files from the repo:
    - listener.ps1                -> C:\demo
    - shellcode.exe               -> C:\demo
    - shellcode-annotated.exe.gzf -> C:\demo
    - cheatsheet.pdf              -> C:\demo