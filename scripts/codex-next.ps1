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

# Do not pipe gh JSON into ConvertFrom-Json here.
# On native Windows/PowerShell, native-command output can be surfaced as
# multiple strings and encoding/line handling differs from Unix hosts.
# Let gh's built-in jq support select and serialize the single task instead.
$row = & gh issue list `
    --repo $Repo `
    --state open `
    --search '"[READY]" in:title' `
    --limit 100 `
    --json number,title,url,createdAt `
    --jq 'sort_by([.createdAt, .number]) | .[0] | if . == null then empty else [.number, .title, .url] | @tsv end'

if ($LASTEXITCODE -ne 0) {
    Write-Error '[codex-next] failed to query GitHub issues'
    exit 1
}

$rowText = ($row | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($rowText)) {
    Write-Host '[codex-next] no READY task'
    exit 3
}

$parts = $rowText -split "`t", 3
if ($parts.Count -ne 3) {
    Write-Error '[codex-next] unexpected gh output format'
    exit 1
}

$issueNumber = $parts[0]
$issueTitle = $parts[1]
$issueUrl = $parts[2]

Write-Host "NEXT_ISSUE=$issueNumber"
Write-Host "TITLE=$issueTitle"
Write-Host "URL=$issueUrl"
Write-Host ''
Write-Host 'Run:'
Write-Host "  gh issue view $issueNumber --repo $Repo"
