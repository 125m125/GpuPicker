$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\GpuPicker.ps1" -LibraryOnly
function Assert($ok, $message) { if (!$ok) { throw $message } }
Assert ((Merge-Preference 'AutoHDREnable=1;GpuPreference=2;' 'Power saving') -eq 'AutoHDREnable=1;GpuPreference=1;') 'Must preserve unrelated flags'
Assert ((Merge-Preference 'GpuPreference=1;Other=abc;' 'Windows decides') -eq 'Other=abc;') 'Reset must preserve unrelated flags'
Assert ((Get-PreferenceLabel 'AutoHDREnable=1;GpuPreference=1;') -eq 'Power saving') 'Import Windows power-saving assignment'
Assert ((Get-PreferenceLabel 'GpuPreference=2;') -eq 'High performance') 'Import high-performance assignment'
Assert ((Get-PreferenceLabel 'SpecificAdapter=abc;GpuPreference=2;') -eq 'Specific adapter (Windows)') 'Do not mislabel explicit adapter'
Assert ((Resolve-AppRule 'OpenAI.Codex_2p2nqsd0c76g0!App') -eq 'OpenAI.Codex_2p2nqsd0c76g0!App') 'Packaged identities are registry targets, not file paths'
$root = Join-Path $env:TEMP ('GpuPicker-test-' + [guid]::NewGuid())
try {
 New-Item "$root\Discord\app-1.0","$root\Discord\app-2.0" -ItemType Directory -Force | Out-Null
 $lockPath = Join-Path $root 'session.lock'
 $held = Open-StoreLock $lockPath
 try { Assert ($null -eq (Open-StoreLock $lockPath)) 'Second launch should skip an occupied lock' }
 finally { $held.Dispose() }
 $reopened = Open-StoreLock $lockPath
 Assert ($null -ne $reopened) 'A leftover lock file must not prevent reopening'
 $reopened.Dispose()
 $failed = $false
 try { Open-StoreLock (Join-Path $root 'missing\session.lock') } catch { $failed = $true }
 Assert $failed 'Real storage errors must not be hidden'
 New-Item "$root\Discord\app-1.0\Discord.exe","$root\Discord\app-2.0\Discord.exe" -ItemType File | Out-Null
 $rule = Get-AppRule "$root\Discord\app-1.0\Discord.exe"
 Assert ($rule -eq "$root\Discord\app-*\Discord.exe") 'Discord version must be generalized'
 Assert (@(Resolve-AppRule $rule).Count -eq 2) 'Both installed versions must resolve'
 Assert ((Get-AppRule "$root\Other\v1\other.exe") -eq "$root\Other\v1\other.exe") 'Do not broaden arbitrary applications'

 # Custom version-folder rules must stay scoped to the selected installation.
 New-Item "$root\Other\version-1","$root\Other\version-2","$root\Other\nested\version-3" -ItemType Directory -Force | Out-Null
 New-Item "$root\Other\version-1\other.exe","$root\Other\version-2\other.exe","$root\Other\nested\version-3\other.exe" -ItemType File | Out-Null
 $current = "$root\Other\version-1\other.exe"
 $custom = "$root\Other\version-*\other.exe"
 Assert (@(Get-RulePreview $custom $current @() $current).Count -eq 2) 'Preview only direct matching version folders'
 Assert (@(Resolve-AppRule $custom).Count -eq 2) 'Custom rule resolves all installed versions'
 $savedApps = @([pscustomobject]@{Rule=$custom;Choice='High performance'})
 Assert ((Get-AppRule "$root\Other\version-2\other.exe" $savedApps) -eq $custom) 'Discovery reuses a saved custom rule'
 Assert (Test-AppRuleMatch $custom "$root\Other\version-2\other.exe") 'Registry entries match the custom rule'
 Assert (!(Test-AppRuleMatch $custom "$root\Other\nested\version-3\other.exe")) 'Star cannot cross folder boundaries'
 foreach ($bad in @("$root\*\version-1\other.exe", "$root\Other\version-*\*.exe", "$root\Other\version-?\other.exe", "$root\Other\missing-*\other.exe", "$root\Other\..\other.exe", 'Package_123!App')) {
  $rejected = $false
  try { Get-RulePreview $bad $current @() $current | Out-Null } catch { $rejected = $true }
  Assert $rejected "Reject unsafe or nonmatching rule: $bad"
 }
 $rejected = $false
 try { Get-RulePreview $custom $current @([pscustomobject]@{Rule="$root\Other\version-2\other.exe"}) $current | Out-Null } catch { $rejected = $true }
 Assert $rejected 'Reject overlap with another managed row'

 # Exercise the real apply routine against an in-memory registry, never user preferences.
 $ast = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\GpuPicker.ps1",[ref]$null,[ref]$null)
 $definition = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Apply-Apps'},$true)
 Invoke-Expression $definition.Extent.Text
 $DataDirectory = $root
 $script:registry = 'test-registry'
 $script:fake = @{}
 function Read-Preference($Path) { return $script:fake[$Path] }
 function New-Item { param($Path,[switch]$Force) }
 function New-ItemProperty { param($Path,$Name,$Value,$PropertyType,[switch]$Force) $script:fake[$Name]=$Value }
 function Remove-ItemProperty { param($Path,$Name,$ErrorAction) $script:fake.Remove($Name) }
 $script:apps = @([pscustomobject]@{Rule=$custom;Choice='Power saving'})
 $first = $current
 $script:fake[$first] = 'AutoHDREnable=1;GpuPreference=2;'
 Assert ((Apply-Apps) -eq 2) 'Apply both custom-rule versions'
 Assert ($script:fake[$first] -eq 'AutoHDREnable=1;GpuPreference=1;') 'Keep HDR setting'
 Assert ((Apply-Apps) -eq 0) 'Second apply must be idempotent'
 $script:apps[0].Choice = 'Windows decides'
 Assert ((Apply-Apps) -eq 2) 'Reset both versions'
 Assert ($script:fake[$first] -eq 'AutoHDREnable=1;') 'Reset must preserve HDR'
 $loaded = Get-Content "$root\original-preferences.json" -Raw | ConvertFrom-Json
 $backup = @($loaded)
 Assert ($backup.Count -eq 2) 'Backup each path only once'
 Assert (($backup | Where-Object Path -eq $first).Value -eq 'AutoHDREnable=1;GpuPreference=2;') 'Retain original preference'

 # Exercise discovery with two running versions and two existing Windows entries.
 $definition = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Discover-Apps'},$true)
 Invoke-Expression $definition.Extent.Text
 $script:registry = $root
 $second = "$root\Other\version-2\other.exe"
 $script:fake = @{}
 $script:fake[$current] = 'GpuPreference=2;'
 $script:fake[$second] = 'GpuPreference=2;'
 $registryKey = New-Object PSObject
 $registryKey | Add-Member ScriptMethod GetValueNames { return @($script:fake.Keys) }
 $registryKey | Add-Member ScriptMethod GetValue { param($name) return $script:fake[$name] }
 function Get-Item { return $registryKey }
 function Get-AppxPackage { }
 function Get-Command { throw 'No NVIDIA snapshot in this test' }
 function Get-Counter { throw 'No GPU counters in this test' }
 function Get-Process {
  [pscustomobject]@{Path=$current;ProcessName='other';Id=101}
  [pscustomobject]@{Path=$second;ProcessName='other';Id=102}
 }
 function Save-Apps { }
 $script:apps = @([pscustomobject]@{Name='Other';Rule=$custom;Choice='High performance'})
 Discover-Apps
 Assert ($script:apps.Count -eq 1) 'Sync must not recreate rows for versions covered by a custom rule'
 Assert ($script:running[$custom].Count -eq 2) 'Both running versions belong to the custom row'
 Assert ($script:apps[0].WindowsSetting -eq 'High performance') 'Windows assignments are aggregated through the custom rule'

} finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }


Assert ((Convert-PreferenceChoice 'AMD integrated') -eq 'Power saving') 'Migrate saved AMD choice'
Assert ((Convert-PreferenceChoice 'NVIDIA') -eq 'High performance') 'Migrate saved NVIDIA choice'
foreach ($choice in @('Power saving','High performance','Windows decides','Unassigned','invalid')) {
 Assert ((Convert-PreferenceChoice $choice) -eq $choice) 'Preserve other choices for existing validation'
}
Assert ((Merge-Preference '' 'High performance') -eq 'GpuPreference=2;') 'Apply generic high-performance preference'
'All checks passed.'
