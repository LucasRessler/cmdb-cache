function ConvertTo-Hashtable {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [PSCustomObject]$input_object
    )
    process {
        function ConvertRecursive ([Object]$obj) {
            if ($obj -is [Array]) {
                return @($obj | ForEach-Object {
                    if ($_ -is [String] -or $_ -is [Boolean] -or $_ -is [Int] -or $_ -is [Double]) { $_ }
                    else { ConvertRecursive $_ }
                })
            } elseif ($obj -is [PSCustomObject]) {
                [Hashtable]$hash = @{}
                foreach ($key in $obj.PSObject.Properties.Name) {
                    $hash[$key] = ConvertRecursive $obj.$key
                }; return $hash
            } else { return $obj }
        }; ConvertRecursive $input_object
    }
}

function LynxDistance {
    param (
        [String]$query,
        [String]$target,
        [Int]$max_backstep = 4,
        [Int]$miss_penalty = 16,
        [Float]$space_weight = 0.5,
        [Float]$symbol_weight = 0.5
    )

    [Bool]$r = $false
    [Int]$lq = $query.Length
    [Int]$lt = $target.Length
    [Int]$i = 0; [Int]$m = 0; [Int]$n = 1
    [Float]$w = 1
    for ($c = 0; $c -lt $lq; $c++) {
        if ($query[$c] -match '\s') { $w = $space_weight; $n++; $r = $false; continue }
        if ($query[$c] -match '[\W\d_]') { $w = $symbol_weight }
        [Int]$d = 0; [Int]$t = 0
        while ($t -gt 0 -or $target[$i + $d] -ne $query[$c]) {
            if ($d -le $max_backstep) { $d *= -1 }
            if ($d -ge 0) { $d++ }
            if ($r) { $n++; $r = $false }
            if ($i + $d -ge 0 -and $i + $d -lt $lt) { $t = 0 }
            else { $t++; if ($t -gt 1) { $m += $miss_penalty * $w; $d = 0; break } }
        }
        $m += [Math]::Abs($d * $w)
        $i += $d + 1
        $r = $true
        $w = 1

    }
    return $n * ($m + $lt - $i)
}

function ClosestMatch {
    param ([String]$needle, [String[]]$haystack, [Int]$threshold = 120, [Int]$min_querylen = 3)
    if ($needle.Length -lt $min_querylen) { throw "Weak query" }
    [PSCustomObject[]]$scored = $haystack | ForEach-Object {
        try { [PSCustomobject]@{ v = $_; d = LynxDistance $needle $_ } }
        catch { $null }
    } | Where-Object { $_ -and $_.d -lt $threshold }
    if ($scored.Count -eq 0) { throw "No match found" }
    [PSCustomObject[]]$sorted = $scored | Sort-Object -Property d
    [PSCustomObject]$best = $sorted[0]
    if ((LynxDistance (";" * [Math]::Floor($needle.Length / 2)) $best.v) -le $best.d) { throw "Inconclusive results" }
    return $best.v
}

function PrettyList {
    param ([String[]]$list)
    [Int]$max_len = ($list | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    [Int]$max_number_cols = [Math]::Floor([System.Console]::BufferWidth / ($max_len + 4))
    [Int]$min_number_rows = [Math]::Floor($list.Count / $max_number_cols)
    [Int]$max_number_rows = [Math]::Max($min_number_rows, [System.Console]::BufferHeight - 6)
    [Int]$num_cols = [Math]::Min([Math]::Ceiling($list.Count / $max_number_rows), $max_number_cols)
    [Int]$num_rows = [Math]::Ceiling($list.Count / $num_cols)
    [String[]]$rows = @()
    for ($i = 0; $i -lt $list.Count; $i++) {
        [String]$s = $list[$i] -replace "%>", (" " * ($max_len - $list[$i].Length + 2))
        [String]$f = "  $s$(" " * (2 + $max_len - $s.Length))"
        [Int]$r = $i % $num_rows
        if ($rows[$r]) { $rows[$r] += $f}
        else { $rows += $f }
    }
    [String]$out = ""
    if ($num_cols -gt 1) { $out += ("-" * ($num_cols * ($max_len + 4))) + "`r`n" }
    $out += $rows -join "`r`n"
    return $out
}
