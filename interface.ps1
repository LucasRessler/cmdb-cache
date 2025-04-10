using module .\cmdb_handle.psm1
using module .\utils.psm1

[String]$creds_path = "$HOME\.cmdb_cache_creds"
[String]$static_path = "$PSScriptRoot\static"
[String]$settings_path = "$PSScriptRoot\settings.json"
[String]$objects_path = "$static_path\cmdb_objects.json"

function GetObjectList {
    try { return Get-Content -Path $objects_path -ErrorAction Stop | ConvertFrom-Json | ConvertTo-Hashtable }
    catch { return @{} }
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
    Write-Host (@(Get-Content "$static_path\$file.help") -join "`r`n")
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
    try { $creds.Value = LoadOrUiGetCreds $creds_path }
    catch {
        if ($null -eq $fallback) { throw }
        $creds.Value = $fallback
        $Host.UI.WriteErrorLine($_.Exception.Message)
        $Host.UI.WriteErrorLine("Reverted to previous credentials")
    }
}

function SendRequest {
    param (
        [Hashtable]$settings,
        [String]$expr,
        [Ref]$creds
    )
    [String]$object = $settings.obj
    [String[]]$select = $settings.select[$object]
    try {
        [PSCustomObject]$term = EvaluateExpression $expr
        Write-Host ">> $(RenderAst $term)"
        EnsureCredentials $creds
        [Hashtable]$qparams = @{
            Credentials = $creds.Value
            Object      = $object
            Select      = $select
            Sort        = "HOSTID"
            Params      = ConvertToParams $term
        }
        Write-Host (CMDBQuery @qparams | ConvertTo-Json)
    }
    catch {
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
    param ([Hashtable]$settings, [Ref]$creds)
    [Bool]$r_loop = $true
    while ($r_loop) {
        [String]$expr = (Read-Host "`n[R] Enter Command or Expression").Trim()
        switch ($true) {
            ($expr -eq "") { ShiftPrompt }
            ($expr -in "help", "h", "?") { ShowHelp req }
            ($expr -in "exit", "quit", "q") { $r_loop = $false }
            ($expr -in "clear", "c") { Clear-Host }
            ($expr -in "reauth", "r") { Reauthorize $creds }
            default { SendRequest $settings $expr $creds }
        }
    }
}

function SolveExpr {
    param ([String]$expr)
    try {
        [PSCustomObject]$term = EvaluateExpression $expr
        Write-Host ">> $(RenderAst $term)"
    }
    catch { $Host.UI.WriteErrorLine($_.Exception.Message) }
    
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
    param ([Hashtable]$settings, [Hashtable]$obj_list, [String]$field)
    if ($obj_list -and $obj_list[$settings.obj]) {
        try { $field = ClosestMatch -needle $field -haystack $obj_list[$settings.obj].Keys }
        catch {
            $Host.UI.WriteErrorLine("Could not find a close enough match for '$field' in $($settings.obj)")
            $Host.UI.WriteErrorLine("Type 'valid' to list all valid keys!")
            return
        }
    }
    [String[]]$select = $settings.select[$settings.obj]
    if ($field -notin $select) { $select += $field; Write-Host "Added '$field' to selection." }
    else { $select = @($select | Where-Object { $_ -ne $field }); Write-Host "Removed '$field' from selection." }
    $settings.select[$settings.obj] = $select; ShowSelection $select
}
function ShowValidKeys {
    param ([Hashtable]$settings, [Hashtable]$obj_list)
    if ($null -eq $obj_list) { $Host.UI.WriteErrorLine("Could not find an object list! :("); return }
    if ($null -eq $obj_list[$settings.obj]) { $Host.UI.WriteErrorLine("Could not find '$($settings.obj)' in the object list! :("); return }
    [String[]]$fields = $obj_list[$settings.obj].Keys; [Array]::Sort($fields)
    Write-Host "Valid Fields for $($settings.obj):`r`n$(PrettyList $fields)"
}
function SelectLoop {
    param ([Hashtable]$settings, [Hashtable]$obj_list )
    [Bool]$s_loop = $true
    ShowSelection $settings.select[$settings.obj]
    while ($s_loop) {
        [String]$expr = (Read-Host "`n[S] Enter Command or Field").Trim()
        switch ($true) {
            ($expr -eq "") { ShiftPrompt }
            ($expr -in "help", "h", "?") { ShowHelp sel }
            ($expr -in "exit", "quit", "q") { $s_loop = $false }
            ($expr -in "valid", "v") { ShowValidKeys $settings $obj_list }
            ($expr -in "show", "s") { ShowSelection $settings.select[$settings.obj] }
            ($expr -in "clear", "c") { Clear-Host }
            default { ToggleSelection $settings $obj_list $expr.ToUpper() }
        }
    }
}

function ShowObject {
    param ([String]$object)
    Write-Host "Current target object: '$object'"
}
function ShowValidObjects {
    param ([Hashtable]$object_list)
    if ($null -eq $object_list) { $Host.UI.WriteErrorLine("Could not find an object list! :("); return }
    [String[]]$objects = $object_list.Keys; [Array]::Sort($objects)
    Write-Host "Valid CMDB Objects:`r`n$(PrettyList $objects)"
}
function SetObject {
    param ([Hashtable]$settings, [Hashtable]$obj_list, [String]$object)
    if ($obj_list) {
        try { $object = ClosestMatch -needle $object -haystack $obj_list.Keys }
        catch {
            $Host.UI.WriteErrorLine("Could not find a close enough match for '$object'")
            $Host.UI.WriteErrorLine("Type 'valid' to list all valid Objects!")
            return
        }
    }
    $settings.obj = $object; ShowObject $object
}
function ObjectLoop {
    param ([Hashtable]$settings, [Hashtable]$obj_list)
    [Bool]$o_loop = $true
    ShowObject $settings.obj
    while ($o_loop) {
        [String]$expr = (Read-Host "`n[O] Enter Command or Object").Trim()
        switch ($true) {
            ($expr -eq "") { ShiftPrompt }
            ($expr -in "help", "h", "?") { ShowHelp obj }
            ($expr -in "exit", "quit", "q") { $o_loop = $false }
            ($expr -in "valid", "v") { ShowValidObjects $obj_list }
            ($expr -in "show", "s") { ShowObject $settings.obj }
            ($expr -in "clear", "c") { Clear-Host }
            default { SetObject $settings $obj_list $expr.ToUpper() }
        }
    }
}

function Terminal {
    if ($null -eq (Get-Module "parser")) { Import-Module "$PSScriptRoot\parser.psm1" }
    if ($null -eq (Get-Module "ui_functions")) { Import-Module "$PSScriptRoot\ui_functions.psm1" }
    try { [Hashtable]$settings = GetSettings }
    catch {
        [Hashtable]$settings = @{
            obj    = "TBLHOST"
            select = @{ TBLHOST = @("HOSTID") }
        } 
    }
    [Hashtable]$obj_list = GetObjectList
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
                ($expr -in "object", "o") { ObjectLoop $settings $obj_list }
                ($expr -in "select", "s") { SelectLoop $settings $obj_list }
                ($expr -in "request", "r") { RequestLoop $settings ([Ref]$creds) }
                ($expr -in "logic", "l") { LogicLoop }
                ($expr -in "exit", "quit", "q") { $t_loop = $false }
                ($expr -in "clear", "c") { Clear-Host }
                default {
                    Write-Host "Command '$expr' is invalid."
                    Write-Host "Type 'help' to list commands!"
                }
            }
        }
    }
    finally {
        SaveSettings $settings
        if ($null -ne (Get-Module "parser")) { Remove-Module "parser" }
    }
}

Terminal
