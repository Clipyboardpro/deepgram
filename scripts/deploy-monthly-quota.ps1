# Eymen CX-008 onayı: CI + Claude merge sonrası; Auth değişmez, fake kalır.
# Pepper yalnız bellekte üretilir ve supabase secrets set ile aktarılır.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][int]$PullRequest,
  [Parameter(Mandatory=$true)][string]$ExpectedHead,
  [switch]$Approved
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 uyumu: yerel komutların stderr'i Stop altında hata sayılmasın;
# başarı yalnız $LASTEXITCODE ile denetlenir.
$PSNativeCommandUseErrorActionPreference = $false
if (-not $Approved) { throw 'Explicit CX-008 deployment approval required' }
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
$previousPassword = $env:SUPABASE_DB_PASSWORD
$pepper = $null
function Invoke-Native([scriptblock]$Command) {
  $ErrorActionPreference = 'Continue'
  & $Command
}
function Invoke-SafeSupabase([string[]]$CliArgs) {
  $result = Invoke-Native { & npx --yes supabase@2.120.0 @CliArgs 2>&1 }
  if ($LASTEXITCODE -ne 0) { $result=$null; throw 'Supabase operation failed; sensitive output suppressed' }
  $result=$null
}
try {
  $pr = (Invoke-Native { & gh pr view $PullRequest --repo Eyyogang/deepgram --json state,headRefOid,baseRefName 2>$null } | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0 -or $pr.state -ne 'MERGED' -or $pr.baseRefName -ne 'main' -or $pr.headRefOid -ne $ExpectedHead) {
    throw 'Expected CX-008 PR must already be merged by Claude; this script never merges'
  }
  $checks = @(Invoke-Native { & gh pr checks $PullRequest --repo Eyyogang/deepgram --json name,state 2>$null } | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw 'PR checks not green' }
  foreach ($name in @('supabase','standalone-postgres')) {
    if (-not ($checks | Where-Object { $_.name -eq $name -and $_.state -eq 'SUCCESS' })) { throw 'Required backend checks not green' }
  }
  $localHead = (& git rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0 -or $localHead -ne $ExpectedHead -or (& git status --porcelain)) { throw 'Deploy checkout must be the exact clean reviewed commit' }
  Invoke-Native { & git fetch origin main:refs/remotes/origin/main 2>&1 } | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Unable to verify main' }
  Invoke-Native { & git merge-base --is-ancestor $ExpectedHead origin/main 2>&1 } | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Reviewed commit not present in main' }
  $ref = 'yjtpfyowzyszeoitlubx'
  if ([IO.File]::ReadAllText((Join-Path $repoRoot 'backend/supabase/.temp/project-ref')).Trim() -ne $ref) { throw 'Linked project mismatch' }
  $secrets = Invoke-Native { & npx --yes supabase@2.120.0 secrets list --project-ref $ref --output json 2>$null } | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect secret names' }
  if ($secrets | Where-Object { $_.name -eq 'FREE_QUOTA_PEPPER' }) {
    throw 'Pepper already exists: do not rotate. Reconcile partial deploy manually without changing pepper'
  }
  $passwordLine = [IO.File]::ReadAllLines((Join-Path $repoRoot '.env.codex.local')) | Where-Object { $_ -match '^SUPABASE_DB_PASSWORD=' } | Select-Object -First 1
  if (-not $passwordLine) { throw 'Local Git-ignored DB password required' }
  $env:SUPABASE_DB_PASSWORD = ($passwordLine.Split('=',2)[1]).Trim().Trim('"').Trim("'")
  $passwordLine=$null
  Invoke-SafeSupabase -CliArgs @('db','push','--dry-run','--workdir','backend','--skip-vault')
  Invoke-SafeSupabase -CliArgs @('db','push','--workdir','backend','--skip-vault','--yes')
  Write-Output 'Reviewed CX-007/008 migrations applied.'
  $randomBytes = New-Object byte[] 32
  # .NET Framework (PowerShell 5.1) uyumlu: statik Fill/ToHexString yok.
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($randomBytes) } finally { $rng.Dispose() }
  $pepper = -join ($randomBytes | ForEach-Object { $_.ToString('x2') })
  [Array]::Clear($randomBytes,0,$randomBytes.Length)
  Invoke-SafeSupabase -CliArgs @('secrets','set','--project-ref',$ref,'FREE_QUOTA_SECONDS=900',('FREE_QUOTA_PEPPER='+$pepper))
  $pepper=$null
  Write-Output 'Monthly amount and fresh 64-character pepper installed; value not saved/logged.'
  # Sağlayıcı güvenlik sınırı; mevcut dispatcher/Vault/Deepgram anahtarına dokunmaz.
  Invoke-SafeSupabase -CliArgs @('secrets','set','--project-ref',$ref,'TRANSCRIPTION_PROVIDER=fake','TRANSCRIPTION_MODEL=fake-v1')
  Invoke-SafeSupabase -CliArgs @('functions','deploy','api','--workdir','backend','--project-ref',$ref,'--no-verify-jwt','--use-api')
  Write-Output 'Reviewed API deployed with fake provider. Auth unchanged; run approved live smoke next.'
} finally {
  $pepper=$null
  $env:SUPABASE_DB_PASSWORD=$previousPassword
  Pop-Location
}
