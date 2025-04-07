using module .\cmdb_handle.psm1

[String]$creds_path = "$HOME\.cmdb_cache_creds"
[String]$settings_path = "$PSScriptRoot\settings.json"

function ConvertTo-Hashtable {
    [CmdletBinding()]
    param(
        [parameter(ValueFromPipeline)]
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

function GetSettings {
    return Get-Content -Path $settings_path -ErrorAction Stop | ConvertFrom-Json | ConvertTo-Hashtable
}
function SaveSettings {
    param ([Hashtable]$settings)
    $settings | ConvertTo-Json -Compress | Set-Content -Path $settings_path
}

function ShowHelp {
    param ([String]$file)
    Write-Host (@(Get-Content "$PSScriptRoot\static\$file.help") -join "`r`n")
}

function ShiftPrompt {
    [System.Console]::SetCursorPosition(0, $Host.UI.RawUI.CursorPosition.Y - 1)
    [System.Console]::Write(" " * [System.Console]::WindowWidth)
}

function DeleteStoredCredentials {
    if (Test-Path $creds_path) {
        Remove-Item -Path $creds_path
    }
}

function EnsureCredentials {
    param ([Ref]$creds, [PSCustomObject]$fallback = $null)
    if ($creds.Value) { return }
    try { $creds.Value = LoadOrUiGetCreds $creds_path}
    catch {
        if ($null -eq $fallback) { throw }
        $creds.Value = $fallback
        $Host.UI.WriteErrorLine($_.Exception.Message)
        $Host.UI.WriteErrorLine("Reverted to previous credentials")
    }
}

function SendRequest {
    param (
        [String]$Object,
        [String[]]$Select,
        [String]$expr,
        [Ref]$creds
    )
    try {
        [PSCustomObject]$term = EvaluateExpression $expr
        Write-Host ">> $(RenderAst $term)"
        EnsureCredentials $creds
        [Hashtable]$qparams = @{
            Credentials = $creds.Value
            Object = $Object
            Select = $Select
            Sort = "HOSTID"
            Params = ConvertToParams $term
        }
        Write-Host (CMDBQuery @qparams | ConvertTo-Json)
    } catch {
        $Host.UI.WriteErrorLine($_.Exception.Message)
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 401) {
            DeleteStoredCredentials; $creds.Value = $null
            $Host.UI.WriteErrorLine("Previously stored credentials have now been deleted.")
        }
    }
}

function Reauthorize {
    param ([Ref]$creds)
    [PSCredential]$old_creds = $null
    if ($creds.Value) {
        $old_creds = $creds.Value
        $creds.Value = $null
        DeleteStoredCredentials
    }
    try { EnsureCredentials $creds $old_creds }
    catch { $Host.UI.WriteErrorLine($_.Exception.Message) }   
}

function RequestLoop {
    param ([String]$Object, [String[]]$Select, [Ref]$creds)
    [Bool]$r_loop = $true
    while ($r_loop) {
        [String]$expr = (Read-Host "`n[R] Enter Command or Expression").Trim()
        switch ($true) {
            ($expr -eq "") { ShiftPrompt }
            ($expr -in "help", "h", "?") { ShowHelp req }
            ($expr -in "exit", "quit", "q") { $r_loop = $false }
            ($expr -in "clear", "c") { Clear-Host }
            ($expr -in "reauth", "r") { Reauthorize $creds }
            default { SendRequest $Object $Select $expr $creds }
        }
    }
}

function SolveExpr {
    param ([String]$expr)
    try {
        [PSCustomObject]$term = EvaluateExpression $expr
        Write-Host ">> $(RenderAst $term)"
    } catch { $Host.UI.WriteErrorLine($_.Exception.Message) }
    
}
function LogicLoop {
    [Bool]$r_loop = $true
    while ($r_loop) {
        [String]$expr = (Read-Host "`n[L] Enter Command or Expression").Trim()
        switch ($true) {
            ($expr -eq "") { ShiftPrompt }
            ($expr -in "help", "h", "?") { ShowHelp solv }
            ($expr -in "exit", "quit", "q") { $r_loop = $false }
            ($expr -in "clear", "c") { Clear-Host }
            default { SolveExpr $expr }
        }
    }
}

function ShowSelection {
    param([String[]]$select)
    Write-Host "Current selection: [$($select -join ", ")]"
}

function ToggleSelection {
    param ([String[]]$select, [String]$field)
    if ($field -in $select) { $select = @($select | Where-Object { $_ -ne $field }) }
    else { $select += $field }
    ShowSelection $select
    return $select
}

function SelectLoop {
    param ([String[]]$select)
    [Bool]$s_loop = $true
    ShowSelection $select
    while ($s_loop) {
        [String]$expr = (Read-Host "`n[S] Enter Command or Field").Trim()
        switch ($true) {
            ($expr -eq "") { ShiftPrompt }
            ($expr -in "help", "h", "?") { ShowHelp sel }
            ($expr -in "exit", "quit", "q") { $s_loop = $false }
            ($expr -in "show", "s") { ShowSelection $select }
            ($expr -in "clear", "c") { Clear-Host }
            default { $select = ToggleSelection $select $expr.ToUpper() }
        }
    }; return $select
}

function SetObject {
    param ([String]$object)
    Write-Host "Object is currently set to '$object'."
    Write-Host "Enter a new target or leave blank to cancel."
    [String]$new = Read-Host "`n[O] New target cmdb-object"
    if ($new) { $object = $new.ToUpper().Trim() }
    Write-Host "Object is now set to '$object'."
    return $object
}

function Terminal {
    if ($null -eq (Get-Module "parser")) { Import-Module "$PSScriptRoot\parser.psm1" }
    if ($null -eq (Get-Module "ui_functions")) { Import-Module "$PSScriptRoot\ui_functions.psm1" }
    try { [Hashtable]$s = GetSettings }
    catch { [Hashtable]$s = @{
        obj = "TBLHOST"
        select = @{ TBLHOST = @("HOSTID") }
    } }
    [PSCredential]$creds = $null
    [Bool]$t_loop = $true
    Write-Host "====== CMDB - TERMINAL ======"
    Write-Host "Type 'help' to list commands!"
    try {
        while ($t_loop) {
            [String]$expr = (Read-Host "`nEnter Command").Trim()
            switch ($true) {
                ($expr -eq "") { ShiftPrompt }
                ($expr -in "help", "h", "?") { ShowHelp term }
                ($expr -in "object", "o") { $s.obj = SetObject $s.obj }
                ($expr -in "select", "s") { $s.select[$s.obj] = SelectLoop $s.select[$s.obj] }
                ($expr -in "request", "r") { RequestLoop $s.obj $s.select[$s.obj] ([Ref]$creds) }
                ($expr -in "logic", "l") { LogicLoop }
                ($expr -in "exit", "quit", "q") { $t_loop = $false }
                ($expr -in "clear", "c") { Clear-Host }
                default {
                    Write-Host "Command '$expr' is invalid."
                    Write-Host "Type 'help' to list commands!"
                }
            }
        }
    } finally {
        SaveSettings $s
        if ($null -ne (Get-Module "parser")) { Remove-Module "parser" }
    }
}

Terminal
