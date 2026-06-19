param(
    [Alias("Rk8sRepo")]
    [string]$Repo = "e:/Programme/NJU/Rust/rk8s",
    [int]$Runs = 3,
    [int]$Threads = 0,
    [int]$MemLimitMB,
    [long]$Mem = 2147483648,
    [switch]$Hash,
    [switch]$CacheStats,
    [string]$PackPath,
    [string]$BaselineRef = "5747f2c",
    [string]$TargetRef = "HEAD",
    [string]$GitInternalRepo,
    [string]$OutJson = "./target/bench-rk8s-pack.json",
    [string]$OutCsv = "./target/bench-rk8s-pack.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-PackPath {
    param([string]$RepoPath, [string]$OverridePath)

    if ($OverridePath) {
        if (-not (Test-Path $OverridePath)) {
            throw "PackPath not found: $OverridePath"
        }
        return (Resolve-Path $OverridePath).Path
    }

    $objPack = Join-Path $RepoPath ".git/objects/pack"
    if (-not (Test-Path $objPack)) {
        throw "Cannot find pack directory: $objPack"
    }

    $packs = @(Get-ChildItem -Path $objPack -Filter "*.pack" | Sort-Object Length -Descending)
    if (-not $packs -or $packs.Count -eq 0) {
        throw "No .pack files found under: $objPack"
    }

    return $packs[0].FullName
}

function Get-BenchOutputData {
    param([string[]]$Lines)

    $vals = @{}
    foreach ($line in $Lines) {
        if ($line -match '^RESULT\s+([A-Za-z0-9_]+)=(.+)$') {
            $vals[$matches[1]] = $matches[2].Trim()
        }
    }

    if (-not $vals.ContainsKey("elapsed_ms")) {
        throw "benchmark output missing RESULT elapsed_ms"
    }

    return [pscustomobject]@{
        elapsed_ms = [double]$vals["elapsed_ms"]
        objects_by_pack = if ($vals.ContainsKey("objects_by_pack")) { [long]$vals["objects_by_pack"] } else { 0 }
        objects_by_callback = if ($vals.ContainsKey("objects_by_callback")) { [long]$vals["objects_by_callback"] } else { 0 }
        signature = if ($vals.ContainsKey("signature")) { $vals["signature"] } else { "" }
        cache_try_get_calls = if ($vals.ContainsKey("cache_try_get_calls")) { [long]$vals["cache_try_get_calls"] } else { 0 }
        cache_try_get_hits = if ($vals.ContainsKey("cache_try_get_hits")) { [long]$vals["cache_try_get_hits"] } else { 0 }
        cache_lookup_misses = if ($vals.ContainsKey("cache_lookup_misses")) { [long]$vals["cache_lookup_misses"] } else { 0 }
        cache_disk_fallbacks = if ($vals.ContainsKey("cache_disk_fallbacks")) { [long]$vals["cache_disk_fallbacks"] } else { 0 }
        cache_hit_rate = if ($vals.ContainsKey("cache_hit_rate")) { [double]$vals["cache_hit_rate"] } else { 0.0 }
    }
}

function Get-Stats {
    param([double[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) {
        return [pscustomobject]@{ avg = 0.0; min = 0.0; max = 0.0; median = 0.0; stddev = 0.0 }
    }

    $n = [double]$Values.Count
    $sum = 0.0
    foreach ($v in $Values) { $sum += $v }
    $avg = $sum / $n

    $sorted = @($Values | Sort-Object)
    $min = $sorted[0]
    $max = $sorted[$sorted.Count - 1]
    if ($sorted.Count % 2 -eq 1) {
        $median = $sorted[[int]($sorted.Count / 2)]
    } else {
        $upper = [int]($sorted.Count / 2)
        $lower = $upper - 1
        $median = ($sorted[$lower] + $sorted[$upper]) / 2.0
    }

    $sq = 0.0
    foreach ($v in $Values) {
        $d = $v - $avg
        $sq += $d * $d
    }
    $variance = $sq / $n
    $stddev = [Math]::Sqrt($variance)

    return [pscustomobject]@{
        avg = [Math]::Round($avg, 6)
        min = [Math]::Round($min, 6)
        max = [Math]::Round($max, 6)
        median = [Math]::Round($median, 6)
        stddev = [Math]::Round($stddev, 6)
    }
}

function Get-DeltaPct {
    param([double]$Baseline, [double]$Target)

    if ($Baseline -eq 0.0) { return 0.0 }
    return (($Target - $Baseline) / $Baseline) * 100.0
}

function Copy-BenchmarkExample {
    param(
        [string]$SourceRoot,
        [string]$TargetRoot
    )

    $sourceExample = Join-Path $SourceRoot "examples/decode_pack_bench.rs"
    $targetExample = Join-Path $TargetRoot "examples/decode_pack_bench.rs"

    if (-not (Test-Path $sourceExample)) {
        throw "Missing source benchmark example: $sourceExample"
    }

    if (-not (Test-Path $targetExample)) {
        Write-Host "[warn] baseline ref missing examples/decode_pack_bench.rs; copying from working tree"
        Copy-Item -Path $sourceExample -Destination $targetExample -Force
    }
}

function Test-HasFeatureFlag {
    param(
        [string]$ProjectRoot,
        [string]$FeatureName
    )

    $cargoToml = Join-Path $ProjectRoot "Cargo.toml"
    if (-not (Test-Path $cargoToml)) {
        return $false
    }

    $text = Get-Content -Path $cargoToml -Raw
    $featureSection = [regex]::Match($text, '(?ms)^\[features\].*?(?=^\[[^\]]+\]|\z)')
    if (-not $featureSection.Success) {
        return $false
    }

    return [regex]::IsMatch($featureSection.Value, ('(?m)^' + [regex]::Escape($FeatureName) + '\s*='))
}

function Invoke-CargoCommand {
    param(
        [string]$WorkingDirectory,
        [string[]]$Arguments
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process -FilePath "cargo" -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $stdout = if (Test-Path $stdoutFile) { @(Get-Content -Path $stdoutFile) } else { @() }
        $stderr = if (Test-Path $stderrFile) { @(Get-Content -Path $stderrFile) } else { @() }

        if ($process.ExitCode -ne 0) {
            if (@($stderr).Count -gt 0) {
                $stderr | Out-Host
            }
            if (@($stdout).Count -gt 0) {
                $stdout | Out-Host
            }
            throw "cargo command failed with exit code $($process.ExitCode)"
        }

        return @($stdout + $stderr)
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $stdoutFile, $stderrFile
    }
}

function Invoke-BenchmarkForRef {
    param(
        [string]$Ref,
        [string]$Pack,
        [string]$WorktreeRoot,
        [string]$ActiveRoot,
        [string]$Config,
        [int]$ThreadsArg,
        [long]$MemArg,
        [bool]$EnableHash,
        [bool]$EnableCacheStats
    )

    $isHead = ($Ref -eq "HEAD")
    if ($isHead) {
        $root = $ActiveRoot
    } else {
        $shortRef = ($Ref -replace '[^A-Za-z0-9_.-]', '_')
        $root = Join-Path $WorktreeRoot ("bench-" + $shortRef)

        if (-not (Test-Path $root)) {
            Write-Host "[info] creating baseline worktree for ref=$Ref at $root"
            $oldLfsSkip = $env:GIT_LFS_SKIP_SMUDGE
            try {
                $env:GIT_LFS_SKIP_SMUDGE = "1"
                & git -C $ActiveRoot worktree add --detach $root $Ref | Out-Host
            } finally {
                $env:GIT_LFS_SKIP_SMUDGE = $oldLfsSkip
            }

            if ($LASTEXITCODE -ne 0) {
                throw "failed to create worktree for ref=$Ref"
            }

            Copy-BenchmarkExample -SourceRoot $ActiveRoot -TargetRoot $root
        }
    }

    $hasBenchCacheStats = Test-HasFeatureFlag -ProjectRoot $root -FeatureName "bench_cache_stats"
    $featureArgs = @()
    if ($EnableCacheStats -and $hasBenchCacheStats) {
        $featureArgs = @("--features", "bench_cache_stats")
    }

    Write-Host "[build] ref=$Ref bench_cache_stats=$($EnableCacheStats -and $hasBenchCacheStats)"
    try {
        $buildArgs = @("build", "--example", "decode_pack_bench") + $featureArgs + @("--profile", $Config)
        Invoke-CargoCommand -WorkingDirectory $root -Arguments $buildArgs | Out-Host

        $cmd = @("run", "--example", "decode_pack_bench")
        $cmd += $featureArgs
        $cmd += @("--profile", $Config, "--")
        $cmd += @("--pack", $Pack)
        if ($ThreadsArg -gt 0) { $cmd += @("--threads", "$ThreadsArg") }
        if ($MemArg -gt 0) { $cmd += @("--mem-limit-mb", "$([Math]::Round($MemArg / 1MB))") }
        if ($EnableHash) { $cmd += @("--hash") }

        $out = Invoke-CargoCommand -WorkingDirectory $root -Arguments $cmd
        return Get-BenchOutputData -Lines $out
    } finally {
    }
}

$repoPath = (Resolve-Path $Repo).Path
$pack = Resolve-PackPath -RepoPath $repoPath -OverridePath $PackPath
$config = "release"
$root = if ($GitInternalRepo) { (Resolve-Path $GitInternalRepo).Path } else { (Resolve-Path (Join-Path $PSScriptRoot "..")).Path }
$headRef = (& git -C $root rev-parse --short HEAD).Trim()
$resolvedMem = if ($PSBoundParameters.ContainsKey("MemLimitMB")) { [long]$MemLimitMB * 1024 * 1024 } else { [long]$Mem }

if (-not $TargetRef -or $TargetRef -eq "HEAD") {
    $TargetRef = "HEAD"
}
if (-not $BaselineRef) {
    throw "BaselineRef cannot be empty"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$tmpWorktreeRoot = Join-Path $env:TEMP ("git-internal-bench-" + $timestamp)
New-Item -ItemType Directory -Path $tmpWorktreeRoot | Out-Null

Write-Host "Benchmark plan"
Write-Host "  repo      : $repoPath"
Write-Host "  pack      : $pack"
Write-Host "  baseline  : $BaselineRef"
Write-Host "  target    : $TargetRef (current=$headRef)"
Write-Host "  runs      : $Runs"
Write-Host "  threads   : $Threads"
Write-Host "  mem bytes : $resolvedMem"
Write-Host "  hash      : $Hash"
Write-Host "  cache stat: $CacheStats"
Write-Host "  mode      : ABBA per round"

if ($headRef -ne "" -and $headRef -ne $BaselineRef -and $TargetRef -eq "HEAD") {
    Write-Host "[note] current HEAD ($headRef) differs from baseline ($BaselineRef), comparison will be baseline vs current working tree"
}

$rows = New-Object System.Collections.Generic.List[object]

try {
    for ($i = 1; $i -le $Runs; $i++) {
        foreach ($phase in @("A1", "B1", "B2", "A2")) {
            $label = if ($phase.StartsWith("A")) { "baseline" } else { "target" }
            $ref = if ($label -eq "baseline") { $BaselineRef } else { $TargetRef }

            Write-Host "[run] round=$i phase=$phase label=$label ref=$ref"
            $res = Invoke-BenchmarkForRef -Ref $ref -Pack $pack -WorktreeRoot $tmpWorktreeRoot -ActiveRoot $root -Config $config -ThreadsArg $Threads -MemArg $resolvedMem -EnableHash:$Hash -EnableCacheStats:$CacheStats

            $rows.Add([pscustomobject]@{
                round = $i
                phase = $phase
                label = $label
                ref = $ref
                elapsed_ms = $res.elapsed_ms
                objects_by_pack = $res.objects_by_pack
                objects_by_callback = $res.objects_by_callback
                signature = $res.signature
                cache_try_get_calls = $res.cache_try_get_calls
                cache_try_get_hits = $res.cache_try_get_hits
                cache_lookup_misses = $res.cache_lookup_misses
                cache_disk_fallbacks = $res.cache_disk_fallbacks
                cache_hit_rate = $res.cache_hit_rate
            })
        }
    }
}
finally {
    if (Test-Path $tmpWorktreeRoot) {
        Write-Host "[cleanup] removing temporary worktrees"
        $wts = (& git -C $root worktree list --porcelain) -join "`n"
        foreach ($line in ($wts -split "`n")) {
            if ($line -like "worktree *") {
                $wtPath = $line.Substring(9).Trim()
                if ($wtPath -like "$tmpWorktreeRoot*") {
                    & git -C $root worktree remove --force "$wtPath" | Out-Null
                }
            }
        }
        Remove-Item -Recurse -Force $tmpWorktreeRoot
    }
}

$baselineRows = @($rows | Where-Object { $_.label -eq "baseline" })
$targetRows = @($rows | Where-Object { $_.label -eq "target" })

if ($baselineRows.Count -eq 0 -or $targetRows.Count -eq 0) {
    throw "missing baseline or target rows"
}

$baselineTimes = @($baselineRows | ForEach-Object { [double]$_.elapsed_ms })
$targetTimes = @($targetRows | ForEach-Object { [double]$_.elapsed_ms })
$baselineHitRates = @($baselineRows | ForEach-Object { [double]$_.cache_hit_rate })
$targetHitRates = @($targetRows | ForEach-Object { [double]$_.cache_hit_rate })

$baselineStats = Get-Stats -Values $baselineTimes
$targetStats = Get-Stats -Values $targetTimes
$baselineHitStats = Get-Stats -Values $baselineHitRates
$targetHitStats = Get-Stats -Values $targetHitRates

$deltaAvgPct = Get-DeltaPct -Baseline $baselineStats.avg -Target $targetStats.avg
$deltaMedianPct = Get-DeltaPct -Baseline $baselineStats.median -Target $targetStats.median
$deltaStddevPct = Get-DeltaPct -Baseline $baselineStats.stddev -Target $targetStats.stddev
$deltaHitMedianPct = if ($baselineHitStats.median -eq 0.0) { $null } else { Get-DeltaPct -Baseline $baselineHitStats.median -Target $targetHitStats.median }
$deltaHitMedianAbs = $targetHitStats.median - $baselineHitStats.median

$outDir = Split-Path -Parent $OutJson
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

$summary = [pscustomobject]@{
    meta = [pscustomobject]@{
        repo = $repoPath
        pack = $pack
        runs = $Runs
        order = "ABBA"
        threads = $Threads
        mem = $resolvedMem
        hash = [bool]$Hash
        cache_stats = [bool]$CacheStats
        baseline_ref = $BaselineRef
        target_ref = $TargetRef
        current_head = $headRef
    }
    baseline = [pscustomobject]@{
        sample_count = $baselineRows.Count
        elapsed_ms = $baselineStats
        cache_hit_rate = $baselineHitStats
    }
    target = [pscustomobject]@{
        sample_count = $targetRows.Count
        elapsed_ms = $targetStats
        cache_hit_rate = $targetHitStats
    }
    compare = [pscustomobject]@{
        elapsed_avg_delta_pct = [Math]::Round($deltaAvgPct, 6)
        elapsed_median_delta_pct = [Math]::Round($deltaMedianPct, 6)
        elapsed_stddev_delta_pct = [Math]::Round($deltaStddevPct, 6)
        cache_hit_rate_median_abs_delta = [Math]::Round($deltaHitMedianAbs, 6)
        cache_hit_rate_median_delta_pct = if ($null -eq $deltaHitMedianPct) { $null } else { [Math]::Round($deltaHitMedianPct, 6) }
        interpretation = "negative elapsed delta means target faster"
    }
    samples = $rows
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $OutJson -Encoding UTF8
$rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Benchmark result"
Write-Host "  baseline elapsed avg    : $($baselineStats.avg) ms"
Write-Host "  baseline elapsed median : $($baselineStats.median) ms"
Write-Host "  baseline elapsed stddev : $($baselineStats.stddev) ms"
Write-Host "  target elapsed avg      : $($targetStats.avg) ms"
Write-Host "  target elapsed median   : $($targetStats.median) ms"
Write-Host "  target elapsed stddev   : $($targetStats.stddev) ms"
Write-Host "  delta avg               : $([Math]::Round($deltaAvgPct, 3)) %"
Write-Host "  delta median            : $([Math]::Round($deltaMedianPct, 3)) %"
Write-Host "  delta stddev            : $([Math]::Round($deltaStddevPct, 3)) %"
Write-Host "  baseline hit median     : $($baselineHitStats.median)"
Write-Host "  target hit median       : $($targetHitStats.median)"
Write-Host "  hit-rate median abs     : $([Math]::Round($deltaHitMedianAbs, 6))"
if ($null -eq $deltaHitMedianPct) {
    Write-Host "  hit-rate median delta   : N/A"
} else {
    Write-Host "  hit-rate median delta   : $([Math]::Round($deltaHitMedianPct, 3)) %"
}
Write-Host "  json output             : $OutJson"
Write-Host "  csv output              : $OutCsv"
