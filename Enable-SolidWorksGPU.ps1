<#
.SYNOPSIS
    SOLIDWORKS Hardware Acceleration & RealView Graphics Enabler (Universal GPU Patcher)
.DESCRIPTION
    Enables OpenGL Hardware Acceleration, Enhanced Graphics Performance, Windows High-Performance
    GPU binding, and RealView Graphics shaders in SOLIDWORKS (2015-2026+) for unsupported/unlisted
    NVIDIA GeForce (including RTX 20/30/40/50-series), AMD Radeon RX, and Intel Arc/Iris GPUs.
     Does not modify GPU driver binaries or void warranties.
.PARAMETER Auto
    Run non-interactively (CLI mode) and automatically patch all detected GPUs and SOLIDWORKS versions.
.PARAMETER Restore
    Restore the most recent registry backup created by this tool.
.PARAMETER CustomRenderer
    Optional custom OpenGL Renderer string to add (e.g., "NVIDIA GeForce RTX 5050/PCIe/SSE2").
.PARAMETER ShaderWorkarounds
    Hex/Int DWORD value for Gl2Shaders Workarounds (default: 0x00032408 for modern RTX/Radeon/Arc).
#>
[CmdletBinding()]
param(
    [switch]$Auto,
    [switch]$Restore,
    [string]$CustomRenderer = "",
    [int]$ShaderWorkarounds = 0x00032408,
    [int]$VendorWorkarounds = 0x04000000
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$BackupDir = Join-Path $ScriptDir "backups"

function Get-SolidWorksInstallations {
    $installs = @()
    # Check HKCU Software\SolidWorks\SOLIDWORKS 20XX
    if (Test-Path "HKCU:\Software\SolidWorks") {
        Get-ChildItem -Path "HKCU:\Software\SolidWorks" -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match "^SOLIDWORKS \d{4}$" } |
            ForEach-Object {
                $verName = $_.PSChildName
                $exePath = $null
                $hklmSetup = "HKLM:\SOFTWARE\SolidWorks\$verName\Setup"
                if (Test-Path $hklmSetup) {
                    $folder = (Get-ItemProperty -Path $hklmSetup -Name "SolidWorks Folder" -ErrorAction SilentlyContinue)."SolidWorks Folder"
                    if ($folder) {
                        $candidate = Join-Path $folder "SLDWORKS.exe"
                        if (Test-Path $candidate) { $exePath = $candidate }
                    }
                }
                $installs += [PSCustomObject]@{
                    VersionName = $verName
                    RegPathHKCU = "HKCU:\Software\SolidWorks\$verName"
                    ExePath     = $exePath
                }
            }
    }
    return $installs
}

function Get-DetectedGPUs {
    $gpus = [System.Collections.Generic.List[PSCustomObject]]::new()

    # 1. Check HKCU:\Software\SolidWorks\AllowList\Current (SOLIDWORKS 2022+)
    if (Test-Path "HKCU:\Software\SolidWorks\AllowList\Current") {
        $cur = Get-ItemProperty -Path "HKCU:\Software\SolidWorks\AllowList\Current" -ErrorAction SilentlyContinue
        if ($cur.Renderer) {
            $gpus.Add([PSCustomObject]@{
                Source      = "SOLIDWORKS AllowList (Active)"
                Vendor      = if ($cur.Vendor) { $cur.Vendor } else { "NVIDIA Corporation" }
                Renderer    = $cur.Renderer
                Workarounds = $cur.Workarounds
            })
        }
    }

    # 2. Check legacy HKCU:\Software\SolidWorks\SOLIDWORKS 20XX\Performance\Graphics\Hardware\Current
    if (Test-Path "HKCU:\Software\SolidWorks") {
        Get-ChildItem -Path "HKCU:\Software\SolidWorks" -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match "^SOLIDWORKS \d{4}$" } |
            ForEach-Object {
                $legacyCurPath = "$($_.PSPath)\Performance\Graphics\Hardware\Current"
                if (Test-Path $legacyCurPath) {
                    $cur = Get-ItemProperty -Path $legacyCurPath -ErrorAction SilentlyContinue
                    if ($cur.Renderer -and -not ($gpus | Where-Object { $_.Renderer -eq $cur.Renderer })) {
                        $gpus.Add([PSCustomObject]@{
                            Source      = "$($_.PSChildName) Hardware\Current"
                            Vendor      = if ($cur.Vendor) { $cur.Vendor } else { "NVIDIA Corporation" }
                            Renderer    = $cur.Renderer
                            Workarounds = $cur.Workarounds
                        })
                    }
                }
            }
    }

    # 3. Check Windows WMI/CIM Video Controllers (catches GPUs even if SW hasn't run on them yet)
    Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.Name
        if ($name -and $name -notmatch "Microsoft Basic|Parsec|Virtual|Remote") {
            $vendor = switch -Regex ($name) {
                "\b(NVIDIA|GeForce|Quadro|RTX|GTX|Tesla|Titan)\b" { "NVIDIA Corporation"; break }
                "\b(AMD|Radeon|FirePro|ATI)\b"                    { "ATI Technologies Inc."; break }
                "\b(Intel|Arc|Iris|UHD|HD Graphics)\b"            { "Intel"; break }
                default                                           { "Other" }
            }
            $openglGuess = if ($vendor -eq "NVIDIA Corporation") { "$name/PCIe/SSE2" } else { $name }
            if (-not ($gpus | Where-Object { $_.Renderer -eq $openglGuess -or $_.Renderer -eq $name })) {
                $gpus.Add([PSCustomObject]@{
                    Source      = "Windows WMI VideoController"
                    Vendor      = $vendor
                    Renderer    = $openglGuess
                    Workarounds = $null
                })
            }
        }
    }

    if ($CustomRenderer) {
        $gpus.Add([PSCustomObject]@{
            Source      = "User Custom Input"
            Vendor      = "NVIDIA Corporation"
            Renderer    = $CustomRenderer
            Workarounds = $null
        })
    }

    return $gpus
}

function Backup-SolidWorksRegistry {
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupFile = Join-Path $BackupDir "sw-gpu-backup-$timestamp.reg"
    & reg.exe export "HKCU\Software\SolidWorks" $backupFile /y | Out-Null
    return $backupFile
}

function Restore-SolidWorksRegistry {
    if (-not (Test-Path $BackupDir)) {
        throw "No backup directory found at $BackupDir"
    }
    $latest = Get-ChildItem -Path $BackupDir -Filter "sw-gpu-backup-*.reg" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $latest) {
        throw "No backup .reg files found in $BackupDir"
    }
    & reg.exe import $latest.FullName
    return $latest.FullName
}

function Set-LiteralRegistrySubKeyDWord {
    param(
        [string]$BaseSubKey,
        [string]$LiteralChildName,
        [string]$ValueName,
        [int]$ValueData
    )
    $parent = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($BaseSubKey, $true)
    if ($parent) {
        $child = $parent.CreateSubKey($LiteralChildName, $true)
        if ($child) {
            $child.SetValue($ValueName, $ValueData, [Microsoft.Win32.RegistryValueKind]::DWord)
            $child.Close()
        }
        $parent.Close()
    }
}

function Enable-SolidWorksGPUAcceleration {
    param(
        [PSCustomObject[]]$GPUs,
        [PSCustomObject[]]$Installs,
        [int]$ShaderFlags = 0x00032408,
        [int]$VendorFlags = 0x04000000
    )

    $log = [System.Collections.Generic.List[string]]::new()

    # 1. Backup Registry first
    try {
        $backupPath = Backup-SolidWorksRegistry
        $log.Add("[Backup] Saved HKCU\Software\SolidWorks to: $backupPath")
    } catch {
        $log.Add("[Warning] Could not export full registry backup: $($_.Exception.Message)")
    }

    # 2. Bind SLDWORKS.exe to High-Performance GPU in Windows Graphics Settings
    $gpuPrefKey = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
    if (-not (Test-Path $gpuPrefKey)) {
        New-Item -Path $gpuPrefKey -Force | Out-Null
    }
    foreach ($inst in $Installs) {
        if ($inst.ExePath) {
            Set-ItemProperty -Path $gpuPrefKey -Name $inst.ExePath -Value "GpuPreference=2;" -Type String
            $log.Add("[Windows GPU] Bound $($inst.VersionName) ($($inst.ExePath)) -> High Performance (GpuPreference=2;)")
        }
    }

    # 3. Patch AllowList & Legacy Hardware keys for each detected GPU
    foreach ($gpu in $GPUs) {
        $rawRenderer = $gpu.Renderer.Trim()
        $strippedRenderer = ($rawRenderer -replace "/PCIe.*$", "" -replace "/SSE2.*$", "").Trim()
        $noNvidiaPrefix = ($strippedRenderer -replace "^NVIDIA\s+", "").Trim()

        # Candidate key names so exact match, stripped match, and prefix match all succeed
        $candidates = @(
            $rawRenderer,
            $strippedRenderer,
            $noNvidiaPrefix
        )
        if ($strippedRenderer -match "GeForce RTX") {
            $candidates += "NVIDIA GeForce RTX"
            $candidates += "GeForce RTX"
            $candidates += "GeForce"
        } elseif ($strippedRenderer -match "GeForce GTX") {
            $candidates += "NVIDIA GeForce GTX"
            $candidates += "GeForce GTX"
            $candidates += "GeForce"
        } elseif ($strippedRenderer -match "Radeon RX") {
            $candidates += "AMD Radeon RX"
            $candidates += "Radeon RX"
        } elseif ($strippedRenderer -match "Arc") {
            $candidates += "Intel(R) Arc(TM)"
        }
        $candidates = $candidates | Where-Object { $_ } | Select-Object -Unique

        # Determine target Gl2Shaders buckets and Vendor buckets
        $shaderBuckets = @("NV40", "Other")
        $vendorBuckets = @("NVIDIA Corporation")
        if ($gpu.Vendor -match "\b(AMD|ATI)\b" -or $rawRenderer -match "\b(Radeon|FirePro)\b") {
            $shaderBuckets = @("RV900", "R420", "Other")
            $vendorBuckets = @("ATI Technologies Inc.", "Advanced Micro Devices")
        } elseif ($gpu.Vendor -match "\bIntel\b" -or $rawRenderer -match "\b(Intel|Arc|Iris)\b") {
            $shaderBuckets = @("Other")
            $vendorBuckets = @("Intel")
        }

        # 3a. Modern SOLIDWORKS (2022-2026+) AllowList
        foreach ($sb in $shaderBuckets) {
            $baseKey = "Software\SolidWorks\AllowList\Gl2Shaders\$sb"
            foreach ($cand in $candidates) {
                Set-LiteralRegistrySubKeyDWord -BaseSubKey $baseKey -LiteralChildName $cand -ValueName "Workarounds" -ValueData $ShaderFlags
            }
        }
        foreach ($vb in $vendorBuckets) {
            $baseKey = "Software\SolidWorks\AllowList\$vb"
            foreach ($cand in $candidates) {
                Set-LiteralRegistrySubKeyDWord -BaseSubKey $baseKey -LiteralChildName $cand -ValueName "Workarounds" -ValueData $VendorFlags
            }
        }

        # 3b. Per-version Legacy SOLIDWORKS keys & Performance flags
        foreach ($inst in $Installs) {
            $verName = $inst.VersionName
            foreach ($sb in $shaderBuckets) {
                $baseKey = "Software\SolidWorks\$verName\Performance\Graphics\Hardware\Gl2Shaders\$sb"
                foreach ($cand in $candidates) {
                    Set-LiteralRegistrySubKeyDWord -BaseSubKey $baseKey -LiteralChildName $cand -ValueName "Workarounds" -ValueData $ShaderFlags
                }
            }
            foreach ($vb in $vendorBuckets) {
                $baseKey = "Software\SolidWorks\$verName\Performance\Graphics\Hardware\$vb"
                foreach ($cand in $candidates) {
                    Set-LiteralRegistrySubKeyDWord -BaseSubKey $baseKey -LiteralChildName $cand -ValueName "Workarounds" -ValueData $VendorFlags
                }
            }

            $perfKey = "HKCU:\Software\SolidWorks\$verName\Performance"
            if (Test-Path $perfKey) {
                # Enable Enhanced Graphics Performance (Pipeline 2020) and GPU Silhouette Edges, disable Software OpenGL
                Set-ItemProperty -Path $perfKey -Name "Use Performance Pipeline 2020" -Value 1 -Type DWord -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $perfKey -Name "Use GPU Silhouette Edges" -Value 1 -Type DWord -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $perfKey -Name "OGL Display Shaders" -Value 1 -Type DWord -ErrorAction SilentlyContinue
                if (Get-ItemProperty -Path $perfKey -Name "Software OpenGL" -ErrorAction SilentlyContinue) {
                    Set-ItemProperty -Path $perfKey -Name "Software OpenGL" -Value 0 -Type DWord -ErrorAction SilentlyContinue
                }
            }
        }

        $log.Add("[Patched GPU] '$rawRenderer' -> Gl2Shaders ($($shaderBuckets -join ', ')) = 0x$($ShaderFlags.ToString('X8')), Vendor = 0x$($VendorFlags.ToString('X8'))")
    }

    # 4. Update AllowList\Current Workarounds if present
    if (Test-Path "HKCU:\Software\SolidWorks\AllowList\Current") {
        Set-ItemProperty -Path "HKCU:\Software\SolidWorks\AllowList\Current" -Name "Workarounds" -Value $VendorFlags -Type DWord
        $log.Add("[AllowList\Current] Updated active Workarounds to 0x$($VendorFlags.ToString('X8'))")
    }

    return $log
}

# --- Execution Mode ---
$installs = @(Get-SolidWorksInstallations)
$gpus = @(Get-DetectedGPUs)

if ($Restore) {
    $restored = Restore-SolidWorksRegistry
    Write-Host "Successfully restored registry backup: $restored" -ForegroundColor Green
    exit 0
}

if ($Auto) {
    Write-Host "=== SOLIDWORKS GPU Hardware Acceleration & RealView Enabler ===" -ForegroundColor Cyan
    $logs = Enable-SolidWorksGPUAcceleration -GPUs $gpus -Installs $installs -ShaderFlags $ShaderWorkarounds -VendorFlags $VendorWorkarounds
    foreach ($line in $logs) {
        Write-Host $line -ForegroundColor Green
    }
    Write-Host "`nDone! Please restart SOLIDWORKS for changes to take effect." -ForegroundColor Yellow
    exit 0
}

# --- GUI Mode (Windows Forms) ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "SOLIDWORKS GPU Hardware Acceleration & RealView Enabler"
$form.Size = New-Object System.Drawing.Size(680, 520)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 32)
$form.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "SOLIDWORKS GPU & RealView Hardware Enabler"
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 14)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(118, 185, 0)
$titleLabel.Location = New-Object System.Drawing.Point(20, 16)
$titleLabel.Size = New-Object System.Drawing.Size(620, 30)
$form.Controls.Add($titleLabel)

$subLabel = New-Object System.Windows.Forms.Label
$subLabel.Text = "Unlocks OpenGL Hardware Acceleration, Enhanced Graphics Performance, and RealView Shaders on GeForce RTX (including 50-series), Radeon RX, and Intel Arc GPUs without modifying drivers."
$subLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 186, 198)
$subLabel.Location = New-Object System.Drawing.Point(20, 48)
$subLabel.Size = New-Object System.Drawing.Size(625, 40)
$form.Controls.Add($subLabel)

$gpuGroup = New-Object System.Windows.Forms.GroupBox
$gpuGroup.Text = "Detected GPUs & SOLIDWORKS Installations"
$gpuGroup.ForeColor = [System.Drawing.Color]::FromArgb(210, 215, 225)
$gpuGroup.Location = New-Object System.Drawing.Point(20, 95)
$gpuGroup.Size = New-Object System.Drawing.Size(625, 130)
$form.Controls.Add($gpuGroup)

$infoBox = New-Object System.Windows.Forms.TextBox
$infoBox.Multiline = $true
$infoBox.ReadOnly = $true
$infoBox.ScrollBars = "Vertical"
$infoBox.BackColor = [System.Drawing.Color]::FromArgb(34, 37, 46)
$infoBox.ForeColor = [System.Drawing.Color]::FromArgb(230, 235, 245)
$infoBox.BorderStyle = "FixedSingle"
$infoBox.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$infoBox.Location = New-Object System.Drawing.Point(12, 24)
$infoBox.Size = New-Object System.Drawing.Size(600, 94)

$summaryLines = @()
if ($installs.Count -gt 0) {
    foreach ($i in $installs) {
        $summaryLines += "SOLIDWORKS : $($i.VersionName) $(if ($i.ExePath) { "($($i.ExePath))" } else { '(Registry Found)' })"
    }
} else {
    $summaryLines += "SOLIDWORKS : Generic / AllowList Mode (No per-version key found yet)"
}
foreach ($g in $gpus) {
    $summaryLines += "GPU        : $($g.Renderer) [$($g.Source)]"
}
$infoBox.Text = ($summaryLines -join "`r`n")
$gpuGroup.Controls.Add($infoBox)

$customLabel = New-Object System.Windows.Forms.Label
$customLabel.Text = "Additional Custom GPU / Renderer Name (Optional):"
$customLabel.Location = New-Object System.Drawing.Point(20, 236)
$customLabel.Size = New-Object System.Drawing.Size(340, 22)
$form.Controls.Add($customLabel)

$customInput = New-Object System.Windows.Forms.TextBox
$customInput.BackColor = [System.Drawing.Color]::FromArgb(34, 37, 46)
$customInput.ForeColor = [System.Drawing.Color]::White
$customInput.BorderStyle = "FixedSingle"
$customInput.Location = New-Object System.Drawing.Point(365, 234)
$customInput.Size = New-Object System.Drawing.Size(280, 24)
$customInput.Text = ""
$form.Controls.Add($customInput)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = "Vertical"
$logBox.BackColor = [System.Drawing.Color]::FromArgb(16, 18, 23)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(140, 230, 150)
$logBox.BorderStyle = "FixedSingle"
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logBox.Location = New-Object System.Drawing.Point(20, 270)
$logBox.Size = New-Object System.Drawing.Size(625, 135)
$logBox.Text = "Ready. Click 'Enable Hardware Acceleration & RealView' to patch your registry.`r`n(An automatic backup of HKCU\Software\SolidWorks will be saved to the backups/ folder.)"
$form.Controls.Add($logBox)

$applyBtn = New-Object System.Windows.Forms.Button
$applyBtn.Text = "Enable Hardware Acceleration & RealView"
$applyBtn.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10.5)
$applyBtn.BackColor = [System.Drawing.Color]::FromArgb(118, 185, 0)
$applyBtn.ForeColor = [System.Drawing.Color]::FromArgb(15, 18, 22)
$applyBtn.FlatStyle = "Flat"
$applyBtn.Location = New-Object System.Drawing.Point(20, 420)
$applyBtn.Size = New-Object System.Drawing.Size(410, 44)
$applyBtn.Add_Click({
    try {
        $targetGpus = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($g in $gpus) { $targetGpus.Add($g) }
        if ($customInput.Text.Trim()) {
            $targetGpus.Add([PSCustomObject]@{
                Source      = "Custom User Input"
                Vendor      = "NVIDIA Corporation"
                Renderer    = $customInput.Text.Trim()
                Workarounds = $null
            })
        }
        $res = Enable-SolidWorksGPUAcceleration -GPUs $targetGpus -Installs $installs -ShaderFlags $ShaderWorkarounds -VendorFlags $VendorWorkarounds
        $logBox.Text = ($res -join "`r`n") + "`r`n`r`n[SUCCESS] Restart SOLIDWORKS to activate Hardware OpenGL & RealView Graphics!"
        [System.Windows.Forms.MessageBox]::Show(
            "Hardware Acceleration and RealView Graphics have been enabled!`n`nPlease restart SOLIDWORKS if it is currently open.",
            "Success",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } catch {
        $logBox.Text = "[ERROR] $($_.Exception.Message)"
    }
})
$form.Controls.Add($applyBtn)

$restoreBtn = New-Object System.Windows.Forms.Button
$restoreBtn.Text = "Restore Backup"
$restoreBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$restoreBtn.BackColor = [System.Drawing.Color]::FromArgb(52, 57, 70)
$restoreBtn.ForeColor = [System.Drawing.Color]::White
$restoreBtn.FlatStyle = "Flat"
$restoreBtn.Location = New-Object System.Drawing.Point(445, 420)
$restoreBtn.Size = New-Object System.Drawing.Size(200, 44)
$restoreBtn.Add_Click({
    try {
        $file = Restore-SolidWorksRegistry
        $logBox.Text = "[RESTORED] Imported registry backup from:`r`n$file"
    } catch {
        $logBox.Text = "[ERROR] $($_.Exception.Message)"
    }
})
$form.Controls.Add($restoreBtn)

[void]$form.ShowDialog()
