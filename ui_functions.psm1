function UiGetCreds {
    Add-Type -AssemblyName PresentationFramework

    [Xml]$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" 
    Title="Insert CMDB API Credentials" Height="160" Width="340"
    WindowStartupLocation="CenterScreen">
    <Grid>
        <Label Content="Username:" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="10,10,0,0"/>
        <Label Content="Password:" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="10,40,0,0"/>
        <TextBox Name="UsernameBox" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="100,15,0,0" Width="210"/>
        <PasswordBox Name="PasswordBox" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="100,45,0,0" Width="210"/>
        <Button Name="OKButton" Content="OK" Width="60" Height="25" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="100,80,0,0"/>
        <Button Name="CancelButton" Content="Cancel" Width="60" Height="25" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="180,80,0,0"/>
        <Label Name="Feedback" Content="" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="10,115,0,0"/>
    </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $XAML
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $UsernameBox = $window.FindName("UsernameBox")
    $PasswordBox = $window.FindName("PasswordBox")
    $OKButton = $window.FindName("OKButton")
    $CancelButton = $window.FindName("CancelButton")
    $FeedbackLabel = $window.FindName("Feedback")

    $OKButton.Add_Click({
        [String]$plain_passwd = $PasswordBox.Password
        [String]$username = $UsernameBox.Text
        if ($username -and $plain_passwd) {
            $window.Close()
            Write-Host "Received Credentials"
            if (-not $username.ToLower().StartsWith("neo\")) { $username = "neo\$username" }
            [SecureString]$password = ConvertTo-SecureString $plain_passwd -AsPlainText -Force
            [PSCredential]$Script:DialogCredential = New-Object System.Management.Automation.PSCredential ($username, $password)
        }

        $window.Height = 200
        $FeedbackLabel.Content = "Credentials are incomplete!`r`nPlease fill out both username and password!"
    })

    $CancelButton.Add_Click({
        Write-Host "User cancelled input."
        $Script:DialogCredential = $null
        $window.Close()
    })

    Write-Host "Displaying Credential Dialogue"
    $window.ShowDialog() | Out-Null
    if ($null -eq $Script:DialogCredential) { throw "No Credentials were Supplied!" }
    return ($Script:DialogCredential)
}

function SaveCreds {
    [CmdletBinding()]
    param ([PSCredential]$Creds, [String]$CPath)
    [String]$username = $Creds.UserName
    [String]$encrypted_pwd = $Creds.Password | ConvertFrom-SecureString
    "$username`r`n$encrypted_pwd" | Set-Content -Path $CPath
}

function LoadOrUiGetCreds {
    [CmdletBinding()]
    param ([String]$CPath)
    if (-not (Test-Path $CPath)) {
        [PSCredential]$creds = UiGetCreds
        SaveCreds $creds $CPath
        return $creds
    }
    [String[]]$cred_parts = (Get-Content -Path $Cpath).Split([System.Environment]::NewLine)
    [String]$username = $cred_parts[0]
    [String]$plain_passwd = $cred_parts[1]
    if (-not ($username -and $plain_passwd)) { Remove-Item $CPath; return (LoadOrUiGetCreds) }
    [SecureString]$password = $cred_parts[1] | ConvertTo-SecureString
    return (New-Object System.Management.Automation.PSCredential ($username, $password))
}

function FormatCreds {
    param ([PSCredential]$creds)
    return "$($creds.UserName)`r`n$($creds.Password | ConvertFrom-SecureString)"
}

function UiUpdateCacheForced {
    [CmdletBinding()]
    param ([String]$CPath = "$HOME\.cmdb_cache_creds")

    if ($null -eq (Get-Module update_cache)) { Import-Module "$PSScriptRoot\update_cache.psm1" }

    try {
        [PSCredential]$creds = LoadOrUiGetCreds $CPath
        UpdateCache -CmdbCredentials $creds -ForceUpdate
        if (-not (Test-Path $CPath)) { FormatCreds $creds | Set-Content -Path $CPath }
    } catch {
        if ($_.Exception.Message.Contains("401") -and (Test-Path $CPath)) { Remove-Item -Path $CPath }
        msg.exe * $_.Exception.Message; throw $_.Exception
    } finally {
        if ($null -ne (Get-Module update_cache)) { Remove-Module update_cache }
    }
}
