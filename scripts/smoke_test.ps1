# mihomo-policy-kit V0.1 真实订阅 Smoke Test（Windows + PowerShell 7）
#
# 用法：
#   $env:MPK_SOURCE_URL='https://your-airport/...'
#   pwsh -File scripts/smoke_test.ps1
#
# 行为：
#   - 从环境变量读取真实订阅（日志/回显不打印真实 URL）
#   - 分别执行 upstream 与 china_compat 两套构建
#   - 输出 source / provider / final 的 proxies 数量
#   - 存在 mihomo 时自动执行 `mihomo -t`
#   - 产物写入 gitignored 的 dist/
# 注意：不要在 GitHub Actions 中配置真实机场 Secret。

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

if (-not $env:MPK_SOURCE_URL) {
    Write-Error '[smoke] MPK_SOURCE_URL is not set (real subscription smoke requires it)'
    exit 2
}

if (-not (Get-Command ruby -ErrorAction SilentlyContinue)) {
    Write-Error '[smoke] ruby not found'
    exit 2
}

# Provider 需要 bash（Git Bash / WSL2）
if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    Write-Error '[smoke] bash not found; provider requires Git Bash or WSL2'
    exit 2
}

$configFile = Join-Path $Root 'config\config.yaml'
if (-not (Test-Path $configFile)) {
    Write-Error "[smoke] missing config: $configFile (copy config/config.example.yaml to config/config.yaml)"
    exit 2
}

$ruby = (Get-Command ruby).Source
$buildScript = Join-Path $Root 'scripts\build.rb'

$profiles = @('upstream', 'china_compat')
$failures = @()

foreach ($profile in $profiles) {
    Write-Host ''
    Write-Host "==== smoke: dns_profile=$profile ===="
    Write-Host '[smoke] building (subscription URL is read from MPK_SOURCE_URL, never printed)'
    & $ruby $buildScript $configFile $profile
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[smoke] FAILED dns_profile=$profile" -ForegroundColor Red
        $failures += $profile
        continue
    }
    Write-Host "[smoke] OK dns_profile=$profile" -ForegroundColor Green
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "=== smoke FAILED for: $($failures -join ', ') ===" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '=== smoke summary (proxies counts are logged by scripts/build.rb above) ==='
Write-Host '=== artifacts: dist/mihomo.yaml (upstream) / dist/mihomo-china-compat.yaml (china_compat) ==='

# 提示 mihomo -t：由 write_and_test 在 mihomo 存在时自动执行
if (Get-Command mihomo -ErrorAction SilentlyContinue) {
    Write-Host '=== mihomo found: core validation ran during build above ==='
} else {
    Write-Host '=== mihomo not found: core validation skipped (install mihomo for -t check) ==='
}
Write-Host '=== smoke OK ==='