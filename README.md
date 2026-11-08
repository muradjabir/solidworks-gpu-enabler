# SOLIDWORKS GPU Hardware Acceleration & RealView Enabler

A lightweight, driver-safe utility and GUI installer that unlocks **OpenGL Hardware Acceleration**, **Enhanced Graphics Performance (Pipeline 2020)**, **Windows High-Performance GPU Binding**, and **RealView Graphics** shaders in **SOLIDWORKS (2015–2026+)** on consumer GPUs:

- **NVIDIA GeForce** (RTX 50-series including RTX 5050 / 5060 / 5070 / 5080 / 5090, RTX 40 / 30 / 20-series, GTX 16 / 10-series, TITAN)
- **AMD Radeon** (Radeon RX 9000 / 7000 / 6000 / 5000-series & Radeon iGPUs)
- **Intel** (Arc A/B-series, Iris Xe, UHD Graphics)

> **No Driver Modding Required:** Instead of patching NVIDIA/AMD driver `.inf` files or flashing vBIOS, this tool updates the local SOLIDWORKS GPU `AllowList` and `Gl2Shaders` registry tables under `HKEY_CURRENT_USER` and backs up your registry automatically before making changes.

---

## Features

1. **Universal SOLIDWORKS Support**:
   - **SOLIDWORKS 2022–2026+**: Patches `HKCU\Software\SolidWorks\AllowList\Gl2Shaders` and vendor keys (`NVIDIA Corporation`, `ATI Technologies Inc.`, `Intel`).
   - **SOLIDWORKS 2015–2021**: Patches legacy `HKCU\Software\SolidWorks\SOLIDWORKS 20XX\Performance\Graphics\Hardware` keys.
2. **Smart Renderer Matching**:
   - Reads the exact OpenGL renderer string recorded by SOLIDWORKS (e.g., `NVIDIA GeForce RTX 5050/PCIe/SSE2`), as well as Windows WMI `Win32_VideoController` devices, and registers literal `/PCIe/SSE2`, stripped card names, and family prefixes.
3. **Windows Hybrid Laptop GPU Fix**:
   - Automatically binds all detected `SLDWORKS.exe` installations to **High Performance (`GpuPreference=2;`)** in `HKCU\Software\Microsoft\DirectX\UserGpuPreferences` so laptops don't fall back to integrated graphics.
4. **Automatic Registry Backups & 1-Click Restore**:
   - Saves a timestamped `.reg` snapshot in `backups/` before applying any changes.

---

## Quick Start

### Option 1: Interactive GUI Installer
1. Download or clone this repository.
2. Double-click **[`Install-SolidWorksGPU.bat`](Install-SolidWorksGPU.bat)**.
3. Click **Enable Hardware Acceleration & RealView** and restart SOLIDWORKS.

### Option 2: Silent / CLI Mode
Run in PowerShell to automatically detect and patch all GPUs and SOLIDWORKS versions:

```powershell
.\Enable-SolidWorksGPU.ps1 -Auto
```

Specify a custom OpenGL renderer string if configuring ahead of first launch:

```powershell
.\Enable-SolidWorksGPU.ps1 -Auto -CustomRenderer "NVIDIA GeForce RTX 5050/PCIe/SSE2"
```

Restore the most recent registry backup:

```powershell
.\Enable-SolidWorksGPU.ps1 -Restore
```

---

## Verifying in SOLIDWORKS

1. Close and reopen **SOLIDWORKS**.
2. With **no files open**, go to **Tools** → **Options** → **System Options** → **Performance**:
   - Confirm **Use Software OpenGL** is **unchecked**.
   - Confirm **Enhanced graphics performance (requires SOLIDWORKS restart)** at the bottom is **checked**.
3. Open any 3D part or assembly and enable **View Settings** → **RealView Graphics** in the Heads-Up View toolbar.

---

## License

MIT License — see [LICENSE](LICENSE).
