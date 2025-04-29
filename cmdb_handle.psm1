enum CmdbCombine {
    And
    Or
}

enum CmdbOperator {
    IsMatch
    IsNotMatch
    IsEqual
    IsNotEqual
    LessThan
    LessThanOrEqual
    GreaterThan
    GreaterThanOrEqual
}

class CmdbParam {
    [String]$field
    [String]$value
    [CmdbOperator]$operator = [CmdbOperator]::IsMatch
    [CmdbCombine]$combine = [CmdbCombine]::And

    CmdbParam ([String]$field, [String]$value) {
        $this.field = $field
        $this.value = $value
    }

    CmdbParam ([String]$field, [String]$value, [CmdbOperator]$operator, [CmdbCombine]$combine) {
        $this.field = $field
        $this.value = $value
        $this.combine = $combine
        $this.operator = $operator
    }

    [String] ToString () {
        [Hashtable]$img = @{
            field   = $this.field
            value   = $this.value
            combine = switch ($this.combine) {
                ([CmdbCombine]::And) { "AND" }
                ([CmdbCombine]::Or) { "OR" }
            }
        }
        switch ($this.operator) {
            ([CmdbOperator]::IsNotMatch) { throw "Expression requires IsNotMatch, which is not supported!" }
            ([CmdbOperator]::IsEqual) { $img.operator = "=" }
            ([CmdbOperator]::IsNotEqual) { $img.operator = "<>" }
            ([CmdbOperator]::LessThan) { $img.operator = "<" }
            ([CmdbOperator]::LessThanOrEqual) { $img.operator = "<=" }
            ([CmdbOperator]::GreaterThan) { $img.operator = ">" }
            ([CmdbOperator]::GreaterThanOrEqual) { $img.operator = ">=" }
        }
        return $img | ConvertTo-Json -Compress
    }
}

function CMDBQuery {
    param (
        [PSCredential]$Credentials,
        [String]$BaseUrl,
        [String]$Object,
        [String]$Sort,
        [String[]]$Select,
        [CmdbParam[]]$Params
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if ("TrustAllCertsPolicy" -as [type]) {} else {
        Add-Type @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) { return true; }
    }
"@
    }

    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

    [String]$select_str = @($Select | ForEach-Object { "`"$Object.$_`"" }) -join ","
    [String]$param_str = @($Params | ForEach-Object { $_.field = "$Object.$($_.field)"; $_.ToString() }) -join ","
    [String]$sort = if ($Sort) { "&sort=`"$Object.$Sort`"" }
    [String]$url = "$BaseUrl/REST/REST.php/crud/CMDB/SERVER/$Object"
    [String]$url_params = "select=[${select_str}]&params=[${param_str}]$sort"
    return Invoke-WebRequest -UseBasicParsing -Credential $Credentials -Uri "${url}?${url_params}" | ConvertFrom-Json
}
