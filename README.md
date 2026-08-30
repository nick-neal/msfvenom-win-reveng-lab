# Msfvenom Windows Reverse Engineering Lab
This repo is for setting up a Windows 11 VM for reverse engineer msfvenom's Windows shellcode.

> [!IMPORTANT]
> You should have all the steps in [Setup Lab VM](#setup-lab-vm) finished before the scheduled meetup, since there will be a lot of topics covered in this lab.
> If you run into issues while using the [Setup Lab VM](#setup-lab-vm) instructions, DM drkstar46 in the dc303 discord channel.

## Setup Lab VM
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

### Run lab-setup.ps1 script
You will need to open a powershell window as administrator and run the `lab-setup.ps1` script provided in this repo. The script will perform the following actions in your VM:

- Download and Install OpenJDK
- Download and Install Ghidra
- Download and Install WinDbg
- Download and Install Python 3.10
    - Install speakeasy-emulator module
- Create C:\demo directory and whitelist the directory in MSDefender
- Download the following files from the  repo:
    - listener.ps1  -> C:\demo
        - `Unblock-File -Path "C:\demo\listen.ps1"`
    - shellcode.exe -> C:\demo
        - `Unblock-File -Path "C:\demo\shellcode.exe"`
    - notes.pdf     -> C:\Users\$env:USERNAME\Desktop