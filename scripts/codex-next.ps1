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

$json = & gh issue list `
    --repo $Repo `
    --state open `
    --search '"[READY]" in:title' `
    --limit 100 `
    --json number,title,url,createdAt

if ($LASTEXITCODE -ne 0) {
    Write-Error '[codex-next] failed to query GitHub issues'
    exit 1
}

$issues = @($json | ConvertFrom-Json)
if ($issues.Count -eq 0) {
    Write-Host '[codex-next] no READY task'
    exit 3
}

$issue = $issues |
    Sort-Object @{ Expression = { [datetime]$_.createdAt } }, @{ Expression = { [int]$_.number } } |
    Select-Object -First 1

Write-Host "NEXT_ISSUE=$($issue.number)"
Write-Host "TITLE=$($issue.title)"
Write-Host "URL=$($issue.url)"
Write-Host ''
Write-Host 'Run:'
Write-Host "  gh issue view $($issue.number) --repo $Repo"
