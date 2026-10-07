# Salt okunur CLI diff; yalnız allowlist alanlarını gösterir, sırları basmaz.
param([string]$ProjectRef = 'yjtpfyowzyszeoitlubx')
$repoRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $repoRoot 'backend/supabase/config.toml'
$safePaths = @('auth.enable_signup','auth.email.enable_signup','auth.email.enable_confirmations',
  'auth.enable_anonymous_sign_ins','auth.minimum_password_length','auth.password_requirements',
  'auth.site_url','auth.additional_redirect_urls','auth.external.apple.enabled')
$localFields = @{}
$section = ''
foreach ($line in [IO.File]::ReadAllLines($configPath)) {
  if ($line -match '^\[([^\]]+)\]$') { $section = $Matches[1] }
  elseif ($line -match '^([a-z_]+)\s*=\s*(.+)$') {
    $fieldPath = $section + '.' + $Matches[1]
    if ($fieldPath -in $safePaths) { $localFields[$fieldPath] = ConvertFrom-Json $Matches[2] }
  }
}
$diffRaw = & npx --yes supabase@2.120.0 config diff --project-ref $ProjectRef --workdir (Join-Path $repoRoot 'backend') --output-format json
if ($LASTEXITCODE -ne 0) { throw 'Read-only Auth config inspection failed' }
$diff = $diffRaw | ConvertFrom-Json
try {
  foreach ($fieldPath in $safePaths) {
    $change = $diff.changes | Where-Object { ($_.path -join '.') -eq $fieldPath } | Select-Object -First 1
    $unmanaged = @($diff.unmanaged | Where-Object { ($_ -join '.') -eq $fieldPath }).Count -gt 0
    $remoteValue = $null
    if ($change) { $remoteValue = $change.remote }
    elseif (-not $unmanaged) { $remoteValue = $localFields[$fieldPath] }
    [PSCustomObject]@{
      Field = $fieldPath
      Remote = $remoteValue
      Evidence = if ($change) { 'remote in read-only diff' } elseif ($unmanaged) { 'unmanaged: unavailable' } else { 'declared local equals remote (no diff)' }
    }
  }
} finally { $diffRaw = $null; $diff = $null }
