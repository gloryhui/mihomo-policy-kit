param(
    [string]$Repo = $(if ($env:MPK_REPO) { $env:MPK_REPO } else { 'gloryhui/mihomo-policy-kit' })
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Error '[codex-next] gh CLI not found'
    exit 1
}

& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Error '[codex-next] gh is not authenticated'
    exit 1
}

# Keep native-command parsing deliberately simple on Windows.
# We only ask gh for one scalar value at a time instead of transporting
# JSON/TSV through PowerShell, which avoids quoting/encoding surprises.
$issueNumberRaw = & gh issue list `
    --repo $Repo `
    --state open `
    --search '"[READY]" in:title' `
    --limit 100 `
    --json number,createdAt `
    --jq 'sort_by([.createdAt, .number]) | .[0].number // empty'

if ($LASTEXITCODE -ne 0) {
    Write-Error '[codex-next] failed to query GitHub issues'
    exit 1
}

$issueNumber = ($issueNumberRaw | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($issueNumber)) {
    Write-Host '[codex-next] no READY task'
    exit 3
}

if ($issueNumber -notmatch '^\d+$') {
    Write-Error "[codex-next] unexpected issue number output: $issueNumber"
    exit 1
}

$issueTitleRaw = & gh issue view $issueNumber `
    --repo $Repo `
    --json title `
    --jq '.title'

if ($LASTEXITCODE -ne 0) {
    Write-Error "[codex-next] failed to read issue #$issueNumber title"
    exit 1
}

$issueUrlRaw = & gh issue view $issueNumber `
    --repo $Repo `
    --json url `
    --jq '.url'

if ($LASTEXITCODE -ne 0) {
    Write-Error "[codex-next] failed to read issue #$issueNumber URL"
    exit 1
}

$issueTitle = ($issueTitleRaw | Out-String).Trim()
$issueUrl = ($issueUrlRaw | Out-String).Trim()

if ([string]::IsNullOrWhiteSpace($issueTitle) -or [string]::IsNullOrWhiteSpace($issueUrl)) {
    Write-Error "[codex-next] incomplete metadata for issue #$issueNumber"
    exit 1
}

Write-Host "NEXT_ISSUE=$issueNumber"
Write-Host "TITLE=$issueTitle"
Write-Host "URL=$issueUrl"
Write-Host ''
Write-Host 'Run:'
Write-Host "  gh issue view $issueNumber --repo $Repo"
