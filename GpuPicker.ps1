param([switch]$Headless, [switch]$LibraryOnly, [switch]$SmokeTest,
      [string]$DataDirectory = "$PSScriptRoot\data")
$ErrorActionPreference = 'Stop'

function Get-AppRule([string]$Path) {
    # Only known Squirrel installations get automatic version-folder matching.
    if ($Path -match '(?i)\\(Discord(?:Canary|PTB)?)\\app-[^\\]+\\Discord(?:Canary|PTB)?\.exe$') {
        return ($Path -replace '\\app-[^\\]+\\', '\app-*\')
    }
    return $Path
}
function Resolve-AppRule([string]$Rule) {
    if ($Rule -match '^[^\\:]+![^\\]+$') { return $Rule }
    if ($Rule.Contains('\app-*\')) {
        $parts = $Rule -split [regex]::Escape('\app-*\'), 2
        if (Test-Path -LiteralPath $parts[0]) {
            Get-ChildItem -LiteralPath $parts[0] -Directory -Filter 'app-*' | ForEach-Object {
                $candidate = Join-Path $_.FullName $parts[1]
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate }
            }
        }
    } elseif (Test-Path -LiteralPath $Rule -PathType Leaf) { $Rule }
}
function Convert-PreferenceChoice([string]$Choice) {
    # Keep inventories saved by earlier versions compatible with the generic labels.
    if ($Choice -eq 'AMD integrated') { return 'Power saving' }
    if ($Choice -eq 'NVIDIA') { return 'High performance' }
    return $Choice
}
function Get-PreferenceLabel([string]$Value) {
    if ($Value -match '(?:^|;)SpecificAdapter=') { return 'Specific adapter (Windows)' }
    if ($Value -match '(?:^|;)GpuPreference=1(?:;|$)') { return 'Power saving' }
    if ($Value -match '(?:^|;)GpuPreference=2(?:;|$)') { return 'High performance' }
    return 'Windows decides'
}
function Merge-Preference([string]$Value, [string]$Choice) {
    $parts = @($Value -split ';' | Where-Object { $_ -and $_ -notmatch '^(GpuPreference|SpecificAdapter)=' })
    if ($Choice -eq 'Power saving') { $parts += 'GpuPreference=1' }
    elseif ($Choice -eq 'High performance') { $parts += 'GpuPreference=2' }
    if ($parts.Count) { return ($parts -join ';') + ';' }
    return ''
}
function Open-StoreLock([string]$Path) {
    try { return [IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch {
        $cause = $_.Exception
        while ($cause.InnerException) { $cause = $cause.InnerException }
        # Sharing/lock violations mean another instance is alive, not broken storage.
        if ($cause -is [IO.IOException] -and ($cause.HResult -band 65535) -in @(32,33)) { return $null }
        throw
    }
}
if ($LibraryOnly) { return }

Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:apps = @()
$script:store = Join-Path $DataDirectory 'apps.json'
$script:registry = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$script:notes = ''
function Save-Apps {
    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    $json = ConvertTo-Json -InputObject @($script:apps) -Depth 4
    $temp = "$script:store.tmp"
    [IO.File]::WriteAllText($temp, $json)
    if (Test-Path -LiteralPath $script:store) {
        [IO.File]::Replace($temp, $script:store, "$script:store.bak")
    } else { [IO.File]::Move($temp, $script:store) }
}
function Read-Preference([string]$Path) {
    if (Test-Path $script:registry) {
        return (Get-Item $script:registry).GetValue($Path, '')
    }
    return ''
}
function Discover-Apps {
    $script:running = @{}
    $script:memory = @{}
    $script:notes = ''
    $script:windowsPreferences = @{}
    $script:packageKeys = @{}
    if (Test-Path $script:registry) {
        $key = Get-Item $script:registry
        foreach ($name in $key.GetValueNames()) { $script:windowsPreferences[$name] = [string]$key.GetValue($name) }
    }
    try {
        foreach ($package in Get-AppxPackage -ErrorAction Stop) {
            try {
                $manifest = Get-AppxPackageManifest -Package $package.PackageFullName -ErrorAction Stop
                foreach ($entry in $manifest.Package.Applications.Application) {
                    if ($entry.Executable -and $entry.Id) {
                        $exe = Join-Path $package.InstallLocation ([string]$entry.Executable)
                        $script:packageKeys[$exe] = "$($package.PackageFamilyName)!$($entry.Id)"
                    }
                }
            } catch { }
        }
    } catch { $script:notes += 'Packaged-app lookup unavailable. ' }
    # Import Windows entries even if the application is not running.
    foreach ($name in $script:windowsPreferences.Keys) {
        if ($script:windowsPreferences[$name] -notmatch '(?:GpuPreference|SpecificAdapter)=') { continue }
        $rule = Get-AppRule $name
        $existing = @($script:apps | Where-Object Rule -eq $rule)
        if (!$existing.Count) {
            $displayName = [IO.Path]::GetFileNameWithoutExtension($name)
            if ($name -match '^[^\\:]+![^\\]+$') { $displayName = (($name -split '_')[0] -split '\.')[-1] }
            $script:apps += [pscustomobject]@{Name=$displayName;Rule=$rule;Choice='Unassigned'}
        }
    }
    $script:gpuText = 'NVIDIA snapshot unavailable.'
    try {
        $smi = Get-Command nvidia-smi.exe -ErrorAction Stop
        $lines = & $smi.Source --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0) { $script:gpuText = (@($lines) | ForEach-Object {
            $v = $_ -split ',\s*'; "$($v[0]): $($v[1]) / $($v[2]) MiB used"
        }) -join ' | ' }
    } catch { }
    # WDDM nvidia-smi cannot reliably report per-process memory. Windows estimates
    # include shared allocations: never sum these rows as physical VRAM usage.
    try {
        $samples = (Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
        foreach ($s in $samples) {
            if ($s.InstanceName -match '^pid_(\d+)_') {
                $id = [int]$Matches[1]
                if (!$script:memory.ContainsKey($id)) { $script:memory[$id] = 0.0 }
                $script:memory[$id] += $s.CookedValue / 1MB
            }
        }
    } catch { $script:notes = 'Per-app counters unavailable. ' }
    $inaccessible = 0
    foreach ($p in Get-Process) {
        try { $path = $p.Path } catch { $path = $null }
        if (!$path) { $inaccessible++; continue }
        # Keep the list focused on user applications, not protected Windows services.
        if ($path.StartsWith($env:windir + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $rule = Get-AppRule $path
        if ($script:packageKeys.ContainsKey($path)) {
            $packageRule = $script:packageKeys[$path]
            # Replace a previous path-only row with the stable packaged app identity.
            $oldRows = @($script:apps | Where-Object Rule -eq $rule)
            $target = @($script:apps | Where-Object Rule -eq $packageRule)
            if ($target.Count -and $oldRows.Count) {
                if ($target[0].Choice -eq 'Unassigned') { $target[0].Choice = $oldRows[0].Choice }
                $script:apps = @($script:apps | Where-Object Rule -ne $rule)
            } elseif ($oldRows.Count) { $oldRows[0].Rule = $packageRule }
            $rule = $packageRule
        }
        if (!$script:running.ContainsKey($rule)) { $script:running[$rule] = @{ Count=0; MiB=0.0; HasMemory=$false } }
        $script:running[$rule].Count++
        if ($script:memory.ContainsKey($p.Id)) {
            $script:running[$rule].MiB += $script:memory[$p.Id]
            $script:running[$rule].HasMemory = $true
        }
        if (!@($script:apps | Where-Object Rule -eq $rule).Count) {
            $pref = Read-Preference $path
            $choice = 'Unassigned'
            if ($pref -match 'GpuPreference=1(?:;|$)') { $choice = 'Power saving' }
            elseif ($pref -match 'GpuPreference=2(?:;|$)') { $choice = 'High performance' }
            $script:apps += [pscustomobject]@{ Name=$p.ProcessName; Rule=$rule; Choice=$choice }
        }
    }
    foreach ($app in $script:apps) {
        $labels = @(foreach ($name in $script:windowsPreferences.Keys) {
            if ((Get-AppRule $name) -eq $app.Rule) { Get-PreferenceLabel $script:windowsPreferences[$name] }
        }) | Select-Object -Unique
        $current = 'Windows decides'
        if (@($labels).Count -eq 1) { $current = [string]$labels }
        elseif (@($labels).Count -gt 1) { $current = 'Mixed (installed versions)' }
        $app | Add-Member -NotePropertyName WindowsSetting -NotePropertyValue $current -Force
        if ($app.Choice -eq 'Unassigned' -and $current -in @('Power saving','High performance')) { $app.Choice = $current }
    }
    $script:notes += "$inaccessible processes had no readable executable path."
    Save-Apps
}
function Apply-Apps {
    $changed = 0
    foreach ($app in $script:apps) {
        if ($app.Choice -eq 'Unassigned') { continue }
        foreach ($path in @(Resolve-AppRule $app.Rule)) {
            $old = [string](Read-Preference $path)
            $new = Merge-Preference $old $app.Choice
            if ($old -eq $new) { continue }
            # One original-value backup per path, retained across later changes.
            $backupFile = Join-Path $DataDirectory 'original-preferences.json'
            $backups = @()
            if (Test-Path -LiteralPath $backupFile) { $loaded = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json; $backups = @($loaded) }
            if (!@($backups | Where-Object Path -eq $path).Count) {
                $backups += [pscustomobject]@{ Path=$path; Value=$old }
                [IO.File]::WriteAllText($backupFile, (ConvertTo-Json -InputObject $backups))
            }
            New-Item -Path $script:registry -Force | Out-Null
            if ($new) { New-ItemProperty -Path $script:registry -Name $path -Value $new -PropertyType String -Force | Out-Null }
            else { Remove-ItemProperty -Path $script:registry -Name $path -ErrorAction SilentlyContinue }
            $app | Add-Member -NotePropertyName WindowsSetting -NotePropertyValue (Get-PreferenceLabel $new) -Force
            $changed++
        }
    }
    return $changed
}
try {
    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    # Serialize GUI/headless access to the tiny store; no permanent background worker.
    $script:lock = Open-StoreLock (Join-Path $DataDirectory 'session.lock')
    if (!$script:lock) {
        if ($Headless) { Write-Output 'Skipped: GPU Picker is already open or syncing.' }
        else {
            $shell = New-Object -ComObject WScript.Shell
            if (!$shell.AppActivate('GPU Picker')) {
                [void][Windows.Forms.MessageBox]::Show('GPU Picker is already open or syncing. Close the existing window or try again after the sync finishes.','GPU Picker')
            }
        }
        return
    }
    if (Test-Path -LiteralPath $script:store) {
        $loaded = Get-Content -LiteralPath $script:store -Raw | ConvertFrom-Json
        $script:apps = @($loaded)
        foreach ($app in $script:apps) {
            $app.Choice = Convert-PreferenceChoice $app.Choice
            if (!$app.Rule -or $app.Choice -notin @('Unassigned','Power saving','High performance','Windows decides')) {
                throw 'Invalid apps.json. Restore apps.json.bak before continuing.'
            }
        }
    }
    if ($Headless) {
        Discover-Apps
        $count = Apply-Apps
        Write-Output "Applied $count changes. $script:gpuText $script:notes"
        return
    }
    $form = New-Object Windows.Forms.Form
    $form.Text = 'GPU Picker'
    $form.Size = New-Object Drawing.Size(1050,600)
    $form.MinimumSize = New-Object Drawing.Size(800,420)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object Drawing.Font('Segoe UI',10)
    $top = New-Object Windows.Forms.FlowLayoutPanel
    $top.Dock = 'Top'; $top.Height = 45
    $sync = New-Object Windows.Forms.Button; $sync.Text = 'Sync'; $sync.Width = 100
    $save = New-Object Windows.Forms.Button; $save.Text = 'Save && apply'; $save.Width = 130
    $add = New-Object Windows.Forms.Button; $add.Text = 'Add .exe'; $add.Width = 100
    $top.Controls.AddRange(@($sync,$save,$add))
    $info = New-Object Windows.Forms.Label
    $info.Dock = 'Top'; $info.Height = 62; $info.Padding = New-Object Windows.Forms.Padding(8)
    $status = New-Object Windows.Forms.Label
    $status.Dock = 'Bottom'; $status.Height = 64; $status.Padding = New-Object Windows.Forms.Padding(8)
    $grid = New-Object Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
    $grid.RowHeadersVisible = $false; $grid.AutoSizeColumnsMode = 'Fill'; $grid.BackgroundColor = [Drawing.Color]::White
    foreach ($name in @('Application','Running','GPU MiB*','Windows setting')) {
        $i = $grid.Columns.Add($name,$name); $grid.Columns[$i].ReadOnly = $true
    }
    $choices = New-Object Windows.Forms.DataGridViewComboBoxColumn
    $choices.Name = 'Preference'; $choices.HeaderText = 'Use GPU'
    $choices.Items.AddRange(@('Unassigned','Power saving','High performance','Windows decides'))
    [void]$grid.Columns.Add($choices)
    $i = $grid.Columns.Add('Rule','Executable / update rule'); $grid.Columns[$i].ReadOnly = $true
    $grid.Columns['Rule'].FillWeight = 260
    $grid.Columns['Running'].FillWeight = 55
    function Capture-Choices {
        [void]$grid.EndEdit()
        foreach ($row in $grid.Rows) { $row.Tag.Choice = [string]$row.Cells['Preference'].Value }
    }
    function Fill-Grid {
        $grid.Rows.Clear()
        foreach ($app in @($script:apps | Sort-Object @{Expression={ $_.Choice -ne 'Unassigned' }},Name)) {
            $run = $script:running[$app.Rule]
            $live = 'No'; $mem = '-'
            if ($run) {
                $live = "Yes ($($run.Count))"
                if ($run.HasMemory) { $mem = [math]::Round($run.MiB,1).ToString() }
            }
            $idx = $grid.Rows.Add($app.Name,$live,$mem,$app.WindowsSetting,$app.Choice,$app.Rule)
            $grid.Rows[$idx].Tag = $app
            if ($app.Choice -eq 'Unassigned') { $grid.Rows[$idx].DefaultCellStyle.BackColor = [Drawing.Color]::LightYellow }
        }
        $info.Text = "$script:gpuText`r`nSnapshot: $(Get-Date -Format 'HH:mm:ss')  |  *Per-app estimates across ALL GPUs; shared allocations can be counted repeatedly."
        $status.Text = "Preferences apply after restarting the app. Check which GPU Windows assigns to Power saving and High performance in Graphics settings.`r`n$script:notes"
    }
    function Ui-Action([scriptblock]$Action) {
        $form.UseWaitCursor = $true
        try { & $Action } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'GPU Picker') }
        finally { $form.UseWaitCursor = $false }
    }
    $sync.Add_Click({ Ui-Action { Capture-Choices; Save-Apps; Discover-Apps; $count = Apply-Apps; Fill-Grid; $status.Text += " Applied $count changes." } })
    $save.Add_Click({ Ui-Action { Capture-Choices; Save-Apps; $count = Apply-Apps; Fill-Grid; $status.Text = "Saved choices; applied $count changes. Restart affected apps to use the new GPU." } })
    $add.Add_Click({
        $dialog = New-Object Windows.Forms.OpenFileDialog; $dialog.Filter = 'Applications (*.exe)|*.exe'
        if ($dialog.ShowDialog() -eq 'OK') { Ui-Action {
            Capture-Choices
            $rule = Get-AppRule $dialog.FileName
            if (!@($script:apps | Where-Object Rule -eq $rule).Count) {
                $script:apps += [pscustomobject]@{Name=[IO.Path]::GetFileNameWithoutExtension($dialog.FileName);Rule=$rule;Choice='Unassigned'}
            }
            Save-Apps; Fill-Grid
        } }
        $dialog.Dispose()
    })
    $form.Controls.AddRange(@($grid,$info,$top,$status))
    $form.Add_Shown({ Ui-Action { Discover-Apps; Fill-Grid }; if ($SmokeTest) { $form.Close() } })
    [void]$form.ShowDialog()
    $form.Dispose()
} catch {
    if ($Headless -or $SmokeTest) { throw }
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'GPU Picker could not start')
} finally { if ($script:lock) { $script:lock.Dispose() } }
