param(
    [string]$Rk8sRepo = "e:\Programme\NJU\Rust\rk8s",
    [string]$GitInternalRepo = "e:\Programme\NJU\Rust\git-internal",
    [int]$Runs = 3,
    [int]$Threads = 2,
    [int]$MemLimitMB = 512,
    [string]$PackPath = ""
)

$ErrorActionPreference = "Stop"

function Require-Command([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "required command not found: $name"
    }
}

Require-Command git
Require-Command cargo

if (-not (Test-Path $Rk8sRepo)) {
    throw "rk8s repo not found: $Rk8sRepo"
}
if (-not (Test-Path $GitInternalRepo)) {
    throw "git-internal repo not found: $GitInternalRepo"
}

$rk8sGitDir = Join-Path $Rk8sRepo ".git"
if (-not (Test-Path $rk8sGitDir)) {
    throw "rk8s repo does not contain .git directory: $Rk8sRepo"
}

$rk8sCommit = (git -C $Rk8sRepo rev-parse --short HEAD).Trim()
Write-Host "rk8s commit: $rk8sCommit"
if (-not $rk8sCommit.StartsWith("beff41b")) {
    Write-Warning "rk8s is not at commit beff41b (current: $rk8sCommit). Results may differ from grading baseline."
}

if ([string]::IsNullOrWhiteSpace($PackPath)) {
    $packDir = Join-Path $rk8sGitDir "objects\pack"
    $packCandidates = @(Get-ChildItem -Path $packDir -Filter "*.pack" -File -ErrorAction SilentlyContinue)

    if ($packCandidates.Count -eq 0) {
        Write-Host "No existing pack found in rk8s repo, running git gc to generate pack files..."
        git -C $Rk8sRepo gc --aggressive --prune=now
        $packCandidates = @(Get-ChildItem -Path $packDir -Filter "*.pack" -File -ErrorAction SilentlyContinue)
    }

    if ($packCandidates.Count -eq 0) {
        throw "no pack files found under $packDir"
    }

    $PackPath = ($packCandidates | Sort-Object Length -Descending | Select-Object -First 1).FullName
    Write-Host "Using largest existing pack from rk8s repo: $PackPath"
}

if (-not (Test-Path $PackPath)) {
    throw "pack file not found: $PackPath"
}

Set-Location $GitInternalRepo
Write-Host "Building decode benchmark example in release mode..."
cargo build --release --example decode_pack_bench

$exe = Join-Path $GitInternalRepo "target\release\examples\decode_pack_bench.exe"
if (-not (Test-Path $exe)) {
    throw "benchmark executable not found: $exe"
}

$outDir = Join-Path $GitInternalRepo "scripts\out"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$results = @()
for ($i = 1; $i -le $Runs; $i++) {
    Write-Host "Run $i / $Runs"
    $output = & $exe --pack $PackPath --threads $Threads --mem-limit-mb $MemLimitMB --hash sha1 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host $output
        throw "benchmark run failed at iteration $i"
    }

    $elapsedLine = ($output | Select-String "^RESULT elapsed_ms=").Line
    $objPackLine = ($output | Select-String "^RESULT objects_by_pack=").Line
    $objCbLine = ($output | Select-String "^RESULT objects_by_callback=").Line
    $sigLine = ($output | Select-String "^RESULT signature=").Line

    $elapsedMs = [int]($elapsedLine -replace "^RESULT elapsed_ms=", "")
    $objByPack = [int]($objPackLine -replace "^RESULT objects_by_pack=", "")
    $objByCb = [int]($objCbLine -replace "^RESULT objects_by_callback=", "")
    $sig = ($sigLine -replace "^RESULT signature=", "")

    $results += [pscustomobject]@{
        run = $i
        elapsed_ms = $elapsedMs
        objects_by_pack = $objByPack
        objects_by_callback = $objByCb
        signature = $sig
        pack_path = $PackPath
        rk8s_commit = $rk8sCommit
        threads = $Threads
        mem_limit_mb = $MemLimitMB
    }
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonPath = Join-Path $outDir "rk8s-pack-bench-$timestamp.json"
$csvPath = Join-Path $outDir "rk8s-pack-bench-$timestamp.csv"
$results | ConvertTo-Json -Depth 4 | Set-Content -Path $jsonPath -Encoding utf8
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8

$avg = [Math]::Round((($results | Measure-Object -Property elapsed_ms -Average).Average), 2)
$min = ($results | Measure-Object -Property elapsed_ms -Minimum).Minimum
$max = ($results | Measure-Object -Property elapsed_ms -Maximum).Maximum

Write-Host ""
Write-Host "Benchmark complete"
Write-Host "Average elapsed_ms: $avg"
Write-Host "Min elapsed_ms: $min"
Write-Host "Max elapsed_ms: $max"
Write-Host "Saved JSON: $jsonPath"
Write-Host "Saved CSV:  $csvPath"
