param(
    [string]$SampleName = "",
    [string]$InputFolder = "",
    [switch]$AllowMultiSample,
    [switch]$ForceSampleName
)

$ErrorActionPreference = "Stop"

$ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$InputDir = Join-Path $ToolRoot "00_input_txt"
$TemplateDir = Join-Path $ToolRoot "01_origin_template"
$TemplatePath = Join-Path $TemplateDir "GPCnew.otpu"
$CTTemplatePath = Join-Path $TemplateDir "C-T-.otpu"
$RunsDir = Join-Path $ToolRoot "05_runs"
$LogsDir = Join-Path $ToolRoot "logs"

$SectionTitle = "[GPC Slice Data Table(Detector A)]"
$ExpectedHeader = "Peak# Slice# R.Time Volume M.W. Height Sub Total % Area"

# Final fixed rule:
# Prefer a sample-specific C0 / sample-0h-ps Stock Solution when present.
# If a batch contains prefixless C0 or 0h-ps input, it can be shared by the
# detected samples. The selected Stock Solution must be first in every category
# plot for that sample and its legend must be exactly "Stock Solution".

function Assert-ToolPath {
    param([string]$Path)
    $Root = [System.IO.Path]::GetFullPath($ToolRoot).TrimEnd("\")
    $Full = [System.IO.Path]::GetFullPath($Path)
    if (-not ($Full -eq $Root -or $Full.StartsWith($Root + "\"))) {
        throw "Refusing to access path outside tool folder: $Full"
    }
}

function New-Directory {
    param([string]$Path)
    Assert-ToolPath -Path $Path
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Get-UniquePath {
    param([string]$Directory, [string]$Stem, [string]$Suffix)
    Assert-ToolPath -Path $Directory
    $Candidate = Join-Path $Directory ($Stem + $Suffix)
    if (Test-Path -LiteralPath $Candidate) {
        $Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $Candidate = Join-Path $Directory ("{0}_{1}{2}" -f $Stem, $Stamp, $Suffix)
    }
    $Counter = 1
    while (Test-Path -LiteralPath $Candidate) {
        $Candidate = Join-Path $Directory ("{0}_{1}{2}" -f $Stem, $Counter, $Suffix)
        $Counter += 1
    }
    return $Candidate
}

function Get-UniqueDirectoryPath {
    param([string]$ParentDirectory, [string]$Name)
    Assert-ToolPath -Path $ParentDirectory
    $Candidate = Join-Path $ParentDirectory $Name
    if (-not (Test-Path -LiteralPath $Candidate)) { return $Candidate }
    $Counter = 1
    while ($true) {
        $Candidate = Join-Path $ParentDirectory ("{0}-{1}" -f $Name, $Counter)
        if (-not (Test-Path -LiteralPath $Candidate)) { return $Candidate }
        $Counter += 1
    }
}

function Get-UniqueDirectoryPathAnyRoot {
    param([string]$ParentDirectory, [string]$Name)
    $Candidate = Join-Path $ParentDirectory $Name
    if (-not (Test-Path -LiteralPath $Candidate)) { return $Candidate }
    $Counter = 1
    while ($true) {
        $Candidate = Join-Path $ParentDirectory ("{0}-{1}" -f $Name, $Counter)
        if (-not (Test-Path -LiteralPath $Candidate)) { return $Candidate }
        $Counter += 1
    }
}

function Convert-ToSafePathPart {
    param([string]$Text)
    $Invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $Chars = $Text.ToCharArray() | ForEach-Object { if ($Invalid -contains $_) { "_" } else { $_ } }
    $Safe = -join $Chars
    if ([string]::IsNullOrWhiteSpace($Safe)) { return "unnamed" }
    return $Safe
}

function Convert-ToSafeOriginName {
    param([string]$Text)
    $Safe = ($Text -replace "[^A-Za-z0-9]", "")
    if ([string]::IsNullOrWhiteSpace($Safe)) { $Safe = "Item" }
    if ($Safe[0] -match "\d") { $Safe = "A$Safe" }
    if ($Safe.Length -gt 18) { $Safe = $Safe.Substring(0, 18) }
    return $Safe
}

function Convert-ToOriginFolderName {
    param([string]$Category)
    if ($Category -ieq "ps") { return "Ps" }
    if ($Category -ieq "pure") { return "Pure" }
    if ($Category.Length -eq 0) { return "Category" }
    return ($Category.Substring(0, 1).ToUpper() + $Category.Substring(1))
}

function Normalize-CategoryName {
    param([string]$Category)
    $Normalized = $Category.Trim().ToLowerInvariant()
    if ($Normalized -eq "pu") { return "pure" }
    return $Normalized
}

function Test-PrefixlessStockFileName {
    param([string]$BaseName)
    return (
        $BaseName -match "^(?i:c0)$" -or
        $BaseName -match "^0(?:h)?-(?i:ps)$"
    )
}

function Escape-LabTalkString {
    param([string]$Text)
    return $Text.Replace("\", "\\").Replace('"', '\"')
}

function Format-OriginNumber {
    param([double]$Value)
    return $Value.ToString("G15", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-NiceStep {
    param([double]$Range, [int]$TargetIntervals = 5)
    if ($Range -le 0) { return 1.0 }
    $RawStep = $Range / [math]::Max($TargetIntervals, 1)
    $Power = [math]::Pow(10, [math]::Floor([math]::Log10($RawStep)))
    $Fraction = $RawStep / $Power
    if ($Fraction -le 1) { $NiceFraction = 1 }
    elseif ($Fraction -le 2) { $NiceFraction = 2 }
    elseif ($Fraction -le 2.5) { $NiceFraction = 2.5 }
    elseif ($Fraction -le 5) { $NiceFraction = 5 }
    else { $NiceFraction = 10 }
    return [double]($NiceFraction * $Power)
}

function Get-CTAxisConfig {
    param([double]$DataMaxX, [double]$DataMaxY)
    $XMaxSource = [math]::Max($DataMaxX, 1)
    $XStep = Get-NiceStep -Range $XMaxSource -TargetIntervals 5
    $XTo = [math]::Ceiling($XMaxSource / $XStep) * $XStep
    $XIntervals = [math]::Round($XTo / $XStep)
    if ($XIntervals -lt 4) {
        $XStep = Get-NiceStep -Range $XMaxSource -TargetIntervals 4
        $XTo = [math]::Ceiling($XMaxSource / $XStep) * $XStep
    }
    elseif ($XIntervals -gt 6) {
        $XStep = Get-NiceStep -Range $XMaxSource -TargetIntervals 6
        $XTo = [math]::Ceiling($XMaxSource / $XStep) * $XStep
    }

    if ($DataMaxY -le 1) {
        $YFrom = 0.0
        $YTo = 1.1
        $YStep = 0.2
    }
    else {
        $YFrom = 0.0
        $YHeadroom = $DataMaxY * 1.08
        $YStep = Get-NiceStep -Range $YHeadroom -TargetIntervals 6
        $YTo = [math]::Ceiling($YHeadroom / $YStep) * $YStep
    }

    return [pscustomobject]@{
        XFrom = 0.0
        XTo = [double]$XTo
        XStep = [double]$XStep
        YFrom = [double]$YFrom
        YTo = [double]$YTo
        YStep = [double]$YStep
    }
}

function Invoke-Origin {
    param([object]$Origin, [string]$Command)
    $Ok = $Origin.Execute($Command)
    if (-not $Ok) { throw "Origin command failed: $Command" }
}

function Set-OriginGraphTimesNewRoman {
    param([object]$Origin, [string]$GraphName)
    Invoke-Origin -Origin $Origin -Command "win -a $GraphName; layer.x.label.font=font(Times New Roman); layer.y.label.font=font(Times New Roman); xb.font=font(Times New Roman); yl.font=font(Times New Roman); legend.font=font(Times New Roman);"
    return [pscustomobject]@{
        GraphName = $GraphName
        TimesNewRomanApplied = $true
        FontSizePreserved = $true
    }
}

function Get-TextLines {
    param([string]$Path)
    $Encodings = @(
        [System.Text.Encoding]::UTF8,
        [System.Text.Encoding]::Unicode,
        [System.Text.Encoding]::Default,
        [System.Text.Encoding]::GetEncoding("gb18030"),
        [System.Text.Encoding]::GetEncoding("iso-8859-1")
    )
    foreach ($Encoding in $Encodings) {
        try { return [System.IO.File]::ReadAllLines($Path, $Encoding) }
        catch [System.Text.DecoderFallbackException] { continue }
    }
    throw "Could not read text file: $Path"
}

function Test-TargetHeader {
    param([string]$Line)
    return ((($Line.Trim() -split "\s+") -join " ") -eq $ExpectedHeader)
}

function Get-DataFileNameMetadata {
    param([string]$TxtPath)
    $Lines = Get-TextLines -Path $TxtPath
    $DataLine = $Lines | Where-Object { $_ -match "^\s*Data File Name\s+" } | Select-Object -First 1
    $OutputDateLine = $Lines | Where-Object { $_ -match "^\s*Output Date\s+" } | Select-Object -First 1
    $OutputTimeLine = $Lines | Where-Object { $_ -match "^\s*Output Time\s+" } | Select-Object -First 1
    $OutputDate = if ([string]::IsNullOrWhiteSpace($OutputDateLine)) { "" } else { ($OutputDateLine -replace "^\s*Output Date\s+", "").Trim() }
    $OutputTimeRaw = if ([string]::IsNullOrWhiteSpace($OutputTimeLine)) { "" } else { ($OutputTimeLine -replace "^\s*Output Time\s+", "").Trim() }
    $OutputTime = if ($OutputTimeRaw -match "^(?<hh>\d{1,2}):(?<mm>\d{2})") { "{0:D2}{1}" -f [int]$Matches.hh, $Matches.mm } else { "" }
    if ([string]::IsNullOrWhiteSpace($DataLine)) {
        $ParsedDate = ""
        if ($OutputDate -match "^(?<yyyy>\d{4})[-/.](?<mm>\d{1,2})[-/.](?<dd>\d{1,2})$") {
            $ParsedDate = "{0}{1:D2}{2:D2}" -f $Matches.yyyy, [int]$Matches.mm, [int]$Matches.dd
        }
        return [pscustomobject]@{ Found = $false; RawValue = ""; BaseName = ""; Stem = ""; Parsed = $null; ParsedDate = $ParsedDate; OutputDate = $OutputDate; OutputTime = $OutputTime }
    }
    $RawValue = ($DataLine -replace "^\s*Data File Name\s+", "").Trim()
    $Leaf = ($RawValue -split "[\\/]")[-1]
    $Stem = [System.IO.Path]::GetFileNameWithoutExtension($Leaf)
    $Parsed = $null
    $ParsedDate = ""
    $Segments = @($Stem -split "-")
    $MetadataPattern = ""
    if ($Segments.Count -ge 3 -and $Segments[0] -match "^(?<time>\d+(?:\.\d+)?)h$") {
        $MetadataPattern = "time-sample-category"
        $Sample = $Segments[1].Trim()
        $Category = Normalize-CategoryName -Category $Segments[2]
    }
    elseif ($Segments.Count -ge 3 -and $Segments[1] -match "^(?<time>\d+(?:\.\d+)?)h$") {
        $MetadataPattern = "sample-time-category"
        $Sample = $Segments[0].Trim()
        $Category = Normalize-CategoryName -Category $Segments[2]
    }
    if (-not [string]::IsNullOrWhiteSpace($MetadataPattern)) {
        $Parsed = [pscustomobject]@{
            Sample = $Sample
            Time = [double]$Matches.time
            TimeText = $Matches.time
            Category = $Category
            GroupKey = "$Sample-$Category"
            HasSamplePrefix = $true
            IsExplicitC0 = ($Stem -match "(?i)c0")
            IsSharedPrefixlessStock = $false
            SharedStockKind = ""
        }
        $DateSegment = $Segments[-1]
        if ($DateSegment -match "^(?<yy>\d{2})\.(?<mm>\d{1,2})\.(?<dd>\d{1,2})$") {
            $ParsedDate = "20{0}{1:D2}{2:D2}" -f $Matches.yy, [int]$Matches.mm, [int]$Matches.dd
        }
        elseif ($Segments.Count -ge 6) {
            $TrailingDate = @($Segments[-3], $Segments[-2], $Segments[-1])
            if ($TrailingDate[0] -match "^\d{2}$" -and $TrailingDate[1] -match "^\d{1,2}$" -and $TrailingDate[2] -match "^\d{1,2}$") {
                $ParsedDate = "20{0}{1:D2}{2:D2}" -f $TrailingDate[0], [int]$TrailingDate[1], [int]$TrailingDate[2]
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($ParsedDate) -and $OutputDate -match "^(?<yyyy>\d{4})[-/.](?<mm>\d{1,2})[-/.](?<dd>\d{1,2})$") {
        $ParsedDate = "{0}{1:D2}{2:D2}" -f $Matches.yyyy, [int]$Matches.mm, [int]$Matches.dd
    }
    return [pscustomobject]@{ Found = $true; RawValue = $RawValue; BaseName = $Leaf; Stem = $Stem; Parsed = $Parsed; ParsedDate = $ParsedDate; OutputDate = $OutputDate; OutputTime = $OutputTime }
}

function Get-ExternalFileNameSample {
    param([string]$BaseName)
    if ($BaseName -match "^(?<sample>.+)-(?i:c0)$") { return $Matches.sample.Trim() }
    if ($BaseName -match "^(?<sample>.+)-(?<time>\d+(?:\.\d+)?)h?-(?<category>.+)$") { return $Matches.sample.Trim() }
    return ""
}

function Get-NameParts {
    param([string]$BaseName, [string]$DefaultSampleName)
    if ($BaseName -match "^(?i:c0)$") {
        return [pscustomobject]@{
            Sample = ""
            Time = 0.0
            TimeText = "0"
            Category = "ps"
            GroupKey = ""
            HasSamplePrefix = $false
            IsExplicitC0 = $true
            IsSharedPrefixlessStock = $true
            SharedStockKind = "C0"
        }
    }
    if ($BaseName -match "^(?<sample>.+)-(?i:c0)$") {
        $ParsedSample = $Matches.sample.Trim()
        return [pscustomobject]@{
            Sample = $ParsedSample
            Time = 0.0
            TimeText = "0"
            Category = "ps"
            GroupKey = "$ParsedSample-ps"
            HasSamplePrefix = $true
            IsExplicitC0 = $true
            IsSharedPrefixlessStock = $false
            SharedStockKind = ""
        }
    }
    if ($BaseName -match "^(?<sample>.+)-(?<time>\d+(?:\.\d+)?)h?-(?<category>.+)$") {
        $ParsedSample = $Matches.sample.Trim()
        $ParsedCategory = Normalize-CategoryName -Category $Matches.category
        return [pscustomobject]@{
            Sample = $ParsedSample
            Time = [double]$Matches.time
            TimeText = $Matches.time
            Category = $ParsedCategory
            GroupKey = "$ParsedSample-$ParsedCategory"
            HasSamplePrefix = $true
            IsExplicitC0 = $false
            IsSharedPrefixlessStock = $false
            SharedStockKind = ""
        }
    }
    if ($BaseName -match "^(?<time>\d+(?:\.\d+)?)h?-(?<category>.+)$") {
        $ParsedCategory = Normalize-CategoryName -Category $Matches.category
        $ParsedTime = [double]$Matches.time
        if ($ParsedTime -eq 0 -and $ParsedCategory -ieq "ps") {
            return [pscustomobject]@{
                Sample = ""
                Time = $ParsedTime
                TimeText = $Matches.time
                Category = $ParsedCategory
                GroupKey = ""
                HasSamplePrefix = $false
                IsExplicitC0 = $false
                IsSharedPrefixlessStock = $true
                SharedStockKind = "0h-ps"
            }
        }
        $ParsedSample = $DefaultSampleName.Trim()
        if ([string]::IsNullOrWhiteSpace($ParsedSample)) { throw "Prefixless filename requires -SampleName when Data File Name is unavailable: $BaseName" }
        return [pscustomobject]@{
            Sample = $ParsedSample
            Time = $ParsedTime
            TimeText = $Matches.time
            Category = $ParsedCategory
            GroupKey = "$ParsedSample-$ParsedCategory"
            HasSamplePrefix = $false
            IsExplicitC0 = $false
            IsSharedPrefixlessStock = $false
            SharedStockKind = ""
        }
    }
    throw "Cannot parse sample/time/category from file name: $BaseName"
}

function Extract-GpcPoints {
    param([string]$TxtPath)
    $Lines = Get-TextLines -Path $TxtPath
    $InSection = $false
    $InTable = $false
    $Points = New-Object System.Collections.Generic.List[object]

    foreach ($Line in $Lines) {
        $Trimmed = $Line.Trim()
        if (-not $InSection) {
            if ($Trimmed -eq $SectionTitle) { $InSection = $true }
            continue
        }
        if (-not $InTable) {
            if (Test-TargetHeader -Line $Trimmed) { $InTable = $true }
            continue
        }
        if ($Trimmed.Length -eq 0 -or $Trimmed.StartsWith("[")) { break }

        $Columns = $Trimmed -split "\s+"
        if ($Columns.Count -lt 9) { continue }
        $X = 0.0
        $Y = 0.0
        if (-not [double]::TryParse($Columns[2], [ref]$X)) { throw "Invalid R.Time in $(Split-Path -Leaf $TxtPath): $($Columns[2])" }
        if (-not [double]::TryParse($Columns[5], [ref]$Y)) { throw "Invalid Height in $(Split-Path -Leaf $TxtPath): $($Columns[5])" }
        $Points.Add([pscustomobject]@{ X = $X; Y = $Y }) | Out-Null
    }

    if (-not $InSection) { throw "Missing section $SectionTitle in $(Split-Path -Leaf $TxtPath)" }
    if (-not $InTable) { throw "Missing target table header in $(Split-Path -Leaf $TxtPath)" }
    return $Points.ToArray()
}

function Write-XYCsv {
    param([string]$Path, [object[]]$Points)
    Assert-ToolPath -Path $Path
    $Points | ForEach-Object { [pscustomobject]@{ X = $_.X; Y = $_.Y } } |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Write-SummaryCsv {
    param([string]$Path, [object[]]$Rows)
    Assert-ToolPath -Path $Path
    $Rows | Select-Object Sample, Category, Time_h, Txt_File, Csv_File, Height_Sum |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Try-WriteSummaryXlsx {
    param([string]$Path, [object[]]$Rows)
    Assert-ToolPath -Path $Path
    $Excel = $null
    try {
        $Excel = New-Object -ComObject Excel.Application
        $Excel.Visible = $false
        $Workbook = $Excel.Workbooks.Add()
        $Sheet = $Workbook.Worksheets.Item(1)
        $Headers = @("Sample", "Category", "Time_h", "Txt_File", "Csv_File", "Height_Sum")
        for ($Col = 0; $Col -lt $Headers.Count; $Col += 1) { $Sheet.Cells.Item(1, $Col + 1).Value2 = $Headers[$Col] }
        $RowIndex = 2
        foreach ($Row in $Rows) {
            $Sheet.Cells.Item($RowIndex, 1).Value2 = [string]$Row.Sample
            $Sheet.Cells.Item($RowIndex, 2).Value2 = [string]$Row.Category
            $Sheet.Cells.Item($RowIndex, 3).Value2 = [double]$Row.Time_h
            $Sheet.Cells.Item($RowIndex, 4).Value2 = [string]$Row.Txt_File
            $Sheet.Cells.Item($RowIndex, 5).Value2 = [string]$Row.Csv_File
            $Sheet.Cells.Item($RowIndex, 6).Value2 = [double]$Row.Height_Sum
            $RowIndex += 1
        }
        $Sheet.Columns.AutoFit() | Out-Null
        $Workbook.SaveAs($Path, 51)
        $Workbook.Close($true)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($Excel -ne $null) { $Excel.Quit() | Out-Null }
    }
}

function Write-C0ComparisonCsv {
    param([string]$Path, [object[]]$Rows)
    Assert-ToolPath -Path $Path
    $Rows | Select-Object Sample, Category, Time_h, Txt_File, Csv_File, Height_Sum, C0_File, C0_Height_Sum, Difference_vs_C0, Ratio_vs_C0, Percent_vs_C0 |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Try-WriteC0ComparisonXlsx {
    param([string]$Path, [object[]]$Rows)
    Assert-ToolPath -Path $Path
    $Excel = $null
    try {
        $Excel = New-Object -ComObject Excel.Application
        $Excel.Visible = $false
        $Workbook = $Excel.Workbooks.Add()
        $Sheet = $Workbook.Worksheets.Item(1)
        $Headers = @("Sample", "Category", "Time_h", "Txt_File", "Csv_File", "Height_Sum", "C0_File", "C0_Height_Sum", "Difference_vs_C0", "Ratio_vs_C0", "Percent_vs_C0")
        for ($Col = 0; $Col -lt $Headers.Count; $Col += 1) { $Sheet.Cells.Item(1, $Col + 1).Value2 = $Headers[$Col] }
        $RowIndex = 2
        foreach ($Row in $Rows) {
            $Sheet.Cells.Item($RowIndex, 1).Value2 = [string]$Row.Sample
            $Sheet.Cells.Item($RowIndex, 2).Value2 = [string]$Row.Category
            $Sheet.Cells.Item($RowIndex, 3).Value2 = [double]$Row.Time_h
            $Sheet.Cells.Item($RowIndex, 4).Value2 = [string]$Row.Txt_File
            $Sheet.Cells.Item($RowIndex, 5).Value2 = [string]$Row.Csv_File
            $Sheet.Cells.Item($RowIndex, 6).Value2 = [double]$Row.Height_Sum
            $Sheet.Cells.Item($RowIndex, 7).Value2 = [string]$Row.C0_File
            $Sheet.Cells.Item($RowIndex, 8).Value2 = [double]$Row.C0_Height_Sum
            $Sheet.Cells.Item($RowIndex, 9).Value2 = [double]$Row.Difference_vs_C0
            if ($Row.Ratio_vs_C0 -ne "NA") { $Sheet.Cells.Item($RowIndex, 10).Value2 = [double]$Row.Ratio_vs_C0 } else { $Sheet.Cells.Item($RowIndex, 10).Value2 = "NA" }
            if ($Row.Percent_vs_C0 -ne "NA") { $Sheet.Cells.Item($RowIndex, 11).Value2 = [double]$Row.Percent_vs_C0 } else { $Sheet.Cells.Item($RowIndex, 11).Value2 = "NA" }
            $RowIndex += 1
        }
        $Sheet.Columns.AutoFit() | Out-Null
        $Workbook.SaveAs($Path, 51)
        $Workbook.Close($true)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($Excel -ne $null) { $Excel.Quit() | Out-Null }
    }
}

function Write-TimeSecondsPercentCsv {
    param([string]$Path, [object[]]$Rows)
    Assert-ToolPath -Path $Path
    $Rows | Select-Object Time_s, Percent_decimal |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Try-WriteTimeSecondsPercentXlsx {
    param([string]$Path, [object[]]$Rows)
    Assert-ToolPath -Path $Path
    $Excel = $null
    try {
        $Excel = New-Object -ComObject Excel.Application
        $Excel.Visible = $false
        $Workbook = $Excel.Workbooks.Add()
        $Sheet = $Workbook.Worksheets.Item(1)
        $Sheet.Cells.Item(1, 1).Value2 = "Time_s"
        $Sheet.Cells.Item(1, 2).Value2 = "Percent_decimal"
        $RowIndex = 2
        foreach ($Row in $Rows) {
            $Sheet.Cells.Item($RowIndex, 1).Value2 = [double]$Row.Time_s
            $Sheet.Cells.Item($RowIndex, 2).Value2 = [double]$Row.Percent_decimal
            $RowIndex += 1
        }
        $Sheet.Columns.AutoFit() | Out-Null
        $Workbook.SaveAs($Path, 51)
        $Workbook.Close($true)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($Excel -ne $null) { $Excel.Quit() | Out-Null }
    }
}

function New-TimeSecondsPercentRows {
    param([object[]]$C0Rows, [string]$Sample, [object]$LogLines)
    $Rows = New-Object System.Collections.Generic.List[object]
    $SeenStock = $false
    $CategoryRank = @{ "ps" = 0; "pure" = 1 }

    $SortedRows = @(
        $C0Rows |
            Sort-Object @{ Expression = { if ($CategoryRank.ContainsKey($_.Category.ToLower())) { $CategoryRank[$_.Category.ToLower()] } else { 99 } }; Descending = $false },
                        @{ Expression = "Category"; Descending = $false },
                        @{ Expression = "Time_h"; Descending = $false }
    )

    foreach ($Row in $SortedRows) {
        if ([double]$Row.Time_h -eq 0) {
            if ($SeenStock) {
                $LogLines.Add("time_seconds_percent skipped duplicate Stock Solution: sample=$Sample, category=$($Row.Category), csv=$($Row.Csv_File)") | Out-Null
                continue
            }
            $SeenStock = $true
        }

        $RatioText = [string]$Row.Ratio_vs_C0
        $PercentText = [string]$Row.Percent_vs_C0
        $PercentDecimal = $null
        $Source = $null
        $Parsed = 0.0

        if (-not [string]::IsNullOrWhiteSpace($RatioText) -and $RatioText -ne "NA" -and [double]::TryParse($RatioText, [ref]$Parsed)) {
            $PercentDecimal = $Parsed
            $Source = "Ratio_vs_C0"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($PercentText) -and $PercentText -ne "NA" -and [double]::TryParse($PercentText, [ref]$Parsed)) {
            $PercentDecimal = $Parsed / 100.0
            $Source = "Percent_vs_C0/100"
        }
        else {
            $LogLines.Add("time_seconds_percent skipped abnormal row: sample=$Sample, category=$($Row.Category), time=$($Row.Time_h), csv=$($Row.Csv_File), reason=no usable Ratio_vs_C0 or Percent_vs_C0") | Out-Null
            continue
        }

        if ($PercentDecimal -gt 10) {
            $LogLines.Add("time_seconds_percent warning: sample=$Sample, csv=$($Row.Csv_File), Percent_decimal=$PercentDecimal is greater than 10; check source data") | Out-Null
        }

        $TimeS = [double]$Row.Time_h * 3600.0
        $Rows.Add([pscustomobject]@{
            Time_s = $TimeS
            Percent_decimal = $PercentDecimal
        }) | Out-Null
        $LogLines.Add("time_seconds_percent row: sample=$Sample, category=$($Row.Category), time_h=$($Row.Time_h), time_s=$TimeS, percent_decimal=$PercentDecimal, source=$Source, csv=$($Row.Csv_File)") | Out-Null
    }

    return $Rows.ToArray()
}

function New-CTCategoryRows {
    param([object[]]$C0Rows, [string]$Sample, [string]$Category, [object]$LogLines)
    $Rows = New-Object System.Collections.Generic.List[object]
    $InitialPercent = if ($Category -ieq "pure") { 0.0 } else { 1.0 }
    $LogLines.Add("C-T $Category 0h baseline: sample=$Sample, before=1, after=$InitialPercent") | Out-Null
    $Rows.Add([pscustomobject]@{
        Time_s = 0.0
        Percent_decimal = $InitialPercent
    }) | Out-Null
    $LogLines.Add("C-T $Category row: sample=$Sample, time_h=0, time_s=0, percent_decimal=$InitialPercent, source=Stock Solution baseline") | Out-Null

    $CategoryRows = @(
        $C0Rows |
            Where-Object { $_.Category -ieq $Category -and [double]$_.Time_h -gt 0 } |
            Sort-Object @{ Expression = "Time_h"; Descending = $false }
    )
    foreach ($Row in $CategoryRows) {
        $RatioText = [string]$Row.Ratio_vs_C0
        $PercentText = [string]$Row.Percent_vs_C0
        $PercentDecimal = $null
        $Source = $null
        $Parsed = 0.0

        if (-not [string]::IsNullOrWhiteSpace($RatioText) -and $RatioText -ne "NA" -and [double]::TryParse($RatioText, [ref]$Parsed)) {
            $PercentDecimal = $Parsed
            $Source = "Ratio_vs_C0"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($PercentText) -and $PercentText -ne "NA" -and [double]::TryParse($PercentText, [ref]$Parsed)) {
            $PercentDecimal = $Parsed / 100.0
            $Source = "Percent_vs_C0/100"
        }
        else {
            $LogLines.Add("C-T $Category skipped abnormal row: sample=$Sample, time=$($Row.Time_h), csv=$($Row.Csv_File), reason=no usable Ratio_vs_C0 or Percent_vs_C0") | Out-Null
            continue
        }

        $TimeS = [double]$Row.Time_h * 3600.0
        $Rows.Add([pscustomobject]@{
            Time_s = $TimeS
            Percent_decimal = $PercentDecimal
        }) | Out-Null
        $LogLines.Add("C-T $Category row: sample=$Sample, time_h=$($Row.Time_h), time_s=$TimeS, percent_decimal=$PercentDecimal, source=$Source, csv=$($Row.Csv_File)") | Out-Null
    }

    return @($Rows.ToArray() | Sort-Object @{ Expression = "Time_s"; Descending = $false })
}

function Get-C0Record {
    param([object[]]$SampleRecords, [string]$Sample, [object]$LogLines)
    $Explicit = @(
        $SampleRecords |
            Where-Object { $_.CsvFile.BaseName -match "(?i)c0" -or $_.TxtFile.BaseName -match "(?i)c0" } |
            Sort-Object Time, @{ Expression = { $_.CsvFile.Name }; Descending = $false }
    )
    if ($Explicit.Count -gt 0) {
        if ($Explicit.Count -gt 1) {
            $LogLines.Add("C0 warning: sample=$Sample has multiple explicit C0 candidates; using $($Explicit[0].CsvFile.Name); candidates=$(($Explicit | ForEach-Object { $_.CsvFile.Name }) -join ', ')") | Out-Null
        }
        return $Explicit[0]
    }

    $Fallback = @(
        $SampleRecords |
            Where-Object { $_.Time -eq 0 -and $_.Category -ieq "ps" } |
            Sort-Object @{ Expression = { $_.CsvFile.Name }; Descending = $false }
    )
    if ($Fallback.Count -gt 0) {
        return $Fallback[0]
    }

    $LogLines.Add("C0 error: sample=$Sample has no explicit C0/c0 file and no sample-0h-ps fallback") | Out-Null
    return $null
}

function New-C0ComparisonRows {
    param([object[]]$SampleRecords, [object]$C0Record, [object]$LogLines)
    $Rows = New-Object System.Collections.Generic.List[object]
    $C0Height = [double]$C0Record.HeightSum
    foreach ($Record in @($SampleRecords | Sort-Object Sample, Category, Time)) {
        $Difference = [double]$Record.HeightSum - $C0Height
        if ($C0Height -eq 0) {
            $Ratio = "NA"
            $Percent = "NA"
            $LogLines.Add("C0 warning: sample=$($Record.Sample), C0 height sum is 0; ratio/percent set to NA for $($Record.CsvFile.Name)") | Out-Null
        }
        else {
            $Ratio = [double]$Record.HeightSum / $C0Height
            $Percent = $Ratio * 100
        }
        $Rows.Add([pscustomobject]@{
            Sample = $Record.Sample
            Category = $Record.Category
            Time_h = $Record.Time
            Txt_File = $Record.TxtFile.Name
            Csv_File = $Record.CsvFile.Name
            Height_Sum = [double]$Record.HeightSum
            C0_File = $C0Record.CsvFile.Name
            C0_Height_Sum = $C0Height
            Difference_vs_C0 = $Difference
            Ratio_vs_C0 = $Ratio
            Percent_vs_C0 = $Percent
        }) | Out-Null
    }
    return $Rows.ToArray()
}

function Test-OriginColumnCounts {
    param([object]$Origin, [string]$BookName, [int]$ExpectedRows)
    $ACount = 0
    $BCount = 0
    for ($Index = 1; $Index -le $ExpectedRows; $Index += 1) {
        $A = [double]$Origin.Evaluate("[$BookName]Sheet1!cell($Index,1)")
        $B = [double]$Origin.Evaluate("[$BookName]Sheet1!cell($Index,2)")
        if (-not [double]::IsNaN($A) -and [math]::Abs($A + 1.23456789E-300) -gt 1E-305) { $ACount += 1 }
        if (-not [double]::IsNaN($B) -and [math]::Abs($B + 1.23456789E-300) -gt 1E-305) { $BCount += 1 }
    }
    return [pscustomobject]@{ ACount = $ACount; BCount = $BCount }
}

function Get-OriginPlotCount {
    param([object]$Origin, [string]$GraphName)
    $Layer = $Origin.FindGraphLayer($GraphName)
    if ($null -eq $Layer) { return -1 }
    $Count = 0
    foreach ($DataObject in @($Layer.DataObjectBases)) { if ($null -ne $DataObject) { $Count += 1 } }
    return $Count
}

function Get-OriginPlotNames {
    param([object]$Origin, [string]$GraphName, [object[]]$FallbackNames)
    $Layer = $Origin.FindGraphLayer($GraphName)
    if ($null -eq $Layer) { return $FallbackNames }
    $Names = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($DataObject in @($Layer.DataObjectBases)) {
            if ($null -eq $DataObject) { continue }
            $Name = $null
            try { $Name = $DataObject.LongName } catch {}
            if ([string]::IsNullOrWhiteSpace($Name)) { try { $Name = $DataObject.Name } catch {} }
            if (-not [string]::IsNullOrWhiteSpace($Name)) { $Names.Add($Name) | Out-Null }
        }
    }
    catch {
        return $FallbackNames
    }
    if ($Names.Count -eq 0) { return $FallbackNames }
    return $Names.ToArray()
}

function Add-OriginWorkbook {
    param([object]$Origin, [object]$Record, [string]$BookName)
    $Points = $Record.Points
    $Rows = New-Object "object[,]" $Points.Count, 2
    for ($Index = 0; $Index -lt $Points.Count; $Index += 1) {
        $Rows[$Index, 0] = $Points[$Index].X
        $Rows[$Index, 1] = $Points[$Index].Y
    }
    Invoke-Origin -Origin $Origin -Command "newbook name:=$BookName option:=lsname; wks.ncols=2; wks.nrows=$($Points.Count);"
    $Origin.PutWorksheet($BookName, $Rows, 0, 0) | Out-Null

    # Stock Solution is always sample-0h-ps and must never be labeled as "0 h".
    $Legend = if ($Record.IsStockSolution) { "Stock Solution" } else { "{0:g} h" -f $Record.Time }
    $EscapedLegend = Escape-LabTalkString -Text $Legend
    $LongName = Escape-LabTalkString -Text $Record.CsvFile.BaseName
    Invoke-Origin -Origin $Origin -Command "win -a $BookName;"
    Invoke-Origin -Origin $Origin -Command "page.longname$=`"$LongName`";"
    Invoke-Origin -Origin $Origin -Command "col(1)[L]$=`"R.Time`"; col(2)[L]$=`"$EscapedLegend`"; wks.col1.type=4; wks.col2.type=1;"

    $Counts = Test-OriginColumnCounts -Origin $Origin -BookName $BookName -ExpectedRows $Points.Count
    if ($Counts.BCount -eq 0) { throw "B column is empty after Origin import: $($Record.CsvFile.Name)" }
    if ($Counts.ACount -ne $Points.Count -or $Counts.BCount -ne $Points.Count) {
        throw "Origin import count mismatch for $($Record.CsvFile.Name): A=$($Counts.ACount), B=$($Counts.BCount), expected=$($Points.Count)"
    }
    return [pscustomobject]@{
        Record = $Record
        BookName = $BookName
        Legend = $Legend
        ACount = $Counts.ACount
        BCount = $Counts.BCount
        MinX = ($Points | Measure-Object -Property X -Minimum).Minimum
        MaxX = ($Points | Measure-Object -Property X -Maximum).Maximum
        MinY = ($Points | Measure-Object -Property Y -Minimum).Minimum
        MaxY = ($Points | Measure-Object -Property Y -Maximum).Maximum
    }
}

function Read-TimeSecondsPercentCsv {
    param([string]$Path, [string]$Sample)
    Assert-ToolPath -Path $Path
    if (-not (Test-Path -LiteralPath $Path)) { throw "time_seconds_percent CSV not found for sample ${Sample}: $Path" }
    $Header = Get-Content -LiteralPath $Path -TotalCount 1
    $HeaderColumns = @(($Header -replace '"', '').Split(","))
    if ($HeaderColumns.Count -ne 2 -or $HeaderColumns[0] -ne "Time_s" -or $HeaderColumns[1] -ne "Percent_decimal") {
        throw "time_seconds_percent CSV for sample $Sample must contain exactly Time_s and Percent_decimal columns: $Path"
    }
    $Rows = New-Object System.Collections.Generic.List[object]
    foreach ($Row in @(Import-Csv -LiteralPath $Path)) {
        $TimeS = 0.0
        $PercentDecimal = 0.0
        if (-not [double]::TryParse([string]$Row.Time_s, [ref]$TimeS)) {
            throw "Non-numeric Time_s in $Path for sample ${Sample}: $($Row.Time_s)"
        }
        if (-not [double]::TryParse([string]$Row.Percent_decimal, [ref]$PercentDecimal)) {
            throw "Non-numeric Percent_decimal in $Path for sample ${Sample}: $($Row.Percent_decimal)"
        }
        $Rows.Add([pscustomobject]@{ X = $TimeS; Y = $PercentDecimal }) | Out-Null
    }
    if ($Rows.Count -eq 0) { throw "time_seconds_percent CSV has no data rows for sample ${Sample}: $Path" }
    return $Rows.ToArray()
}

function Add-OriginTimePercentWorkbook {
    param([object]$Origin, [object[]]$Rows, [string]$BookName, [string]$Sample, [string]$Label)
    $Data = New-Object "object[,]" $Rows.Count, 2
    for ($Index = 0; $Index -lt $Rows.Count; $Index += 1) {
        $Data[$Index, 0] = [double]$Rows[$Index].X
        $Data[$Index, 1] = [double]$Rows[$Index].Y
    }
    Invoke-Origin -Origin $Origin -Command "newbook name:=$BookName option:=lsname; wks.ncols=2; wks.nrows=$($Rows.Count);"
    $Origin.PutWorksheet($BookName, $Data, 0, 0) | Out-Null
    Invoke-Origin -Origin $Origin -Command "win -a $BookName;"
    Invoke-Origin -Origin $Origin -Command "page.longname$=`"$Label`";"
    Invoke-Origin -Origin $Origin -Command "col(1)[L]$=`"Time_s`"; col(2)[L]$=`"$Label`"; wks.col1.type=4; wks.col2.type=1;"

    $Counts = Test-OriginColumnCounts -Origin $Origin -BookName $BookName -ExpectedRows $Rows.Count
    if ($Counts.BCount -eq 0) { throw "B column is empty after Origin C-T import for sample $Sample" }
    if ($Counts.ACount -ne $Rows.Count -or $Counts.BCount -ne $Rows.Count) {
        throw "Origin C-T import count mismatch for sample ${Sample}: A=$($Counts.ACount), B=$($Counts.BCount), expected=$($Rows.Count)"
    }
    return [pscustomobject]@{
        BookName = $BookName
        Label = $Label
        ACount = $Counts.ACount
        BCount = $Counts.BCount
        MinX = ($Rows | Measure-Object -Property X -Minimum).Minimum
        MaxX = ($Rows | Measure-Object -Property X -Maximum).Maximum
        MinY = ($Rows | Measure-Object -Property Y -Minimum).Minimum
        MaxY = ($Rows | Measure-Object -Property Y -Maximum).Maximum
    }
}

function Add-OriginCTGraphToGpcProject {
    param(
        [object]$Origin,
        [string]$Sample,
        [string]$PsCsv,
        [string]$PureCsv,
        [string]$PngPath,
        [string]$TifPath
    )

    if (-not (Test-Path -LiteralPath $CTTemplatePath)) { throw "C-T Origin template not found: $CTTemplatePath" }
    $PsRows = @(Read-TimeSecondsPercentCsv -Path $PsCsv -Sample $Sample)
    $PureRows = @(Read-TimeSecondsPercentCsv -Path $PureCsv -Sample $Sample)
    $ProjectFolderName = "Total"
    Invoke-Origin -Origin $Origin -Command "pe_cd /; pe_mkdir `"Total`"; pe_cd `"Total`";"

    $PsSeries = Add-OriginTimePercentWorkbook -Origin $Origin -Rows $PsRows -BookName "PS" -Sample $Sample -Label "PS"
    $PureSeries = Add-OriginTimePercentWorkbook -Origin $Origin -Rows $PureRows -BookName "Pure" -Sample $Sample -Label "Pure"

    $GraphName = "CT"
    $EscapedTemplate = Escape-LabTalkString -Text $CTTemplatePath
    Invoke-Origin -Origin $Origin -Command "win -a PS; worksheet -s 2 0 2 0;"
    Invoke-Origin -Origin $Origin -Command "worksheet -p 200 `"$EscapedTemplate`";"
    $CreatedGraphName = $Origin.LTStr("page.name$")
    if ([string]::IsNullOrWhiteSpace($CreatedGraphName) -or $CreatedGraphName -eq "PS") {
        throw "C-T template graph page was not created for sample $Sample. Refusing to use a default blank graph."
    }
    Invoke-Origin -Origin $Origin -Command "page.name$=`"$GraphName`";"
    Invoke-Origin -Origin $Origin -Command "page.longname$=`"C-T`";"
    $GraphName = $Origin.LTStr("page.name$")

    $BeforeCount = Get-OriginPlotCount -Origin $Origin -GraphName $GraphName
    Invoke-Origin -Origin $Origin -Command "win -a $GraphName; plotxy iy:=[Pure]Sheet1!(1,2) plot:=200 ogl:=1;"
    $AfterCount = Get-OriginPlotCount -Origin $Origin -GraphName $GraphName
    if ($AfterCount -ne ($BeforeCount + 1)) {
        throw "Pure curve was not added to C-T graph for sample $Sample. Before=$BeforeCount, after=$AfterCount"
    }

    $FinalPlotCount = Get-OriginPlotCount -Origin $Origin -GraphName $GraphName
    if ($FinalPlotCount -ne 2) { throw "C-T graph must contain exactly two curves for sample $Sample. Got $FinalPlotCount" }
    Invoke-Origin -Origin $Origin -Command "win -a $GraphName; legend -r;"
    $PsFirstX = [double]$Origin.Evaluate("[PS]Sheet1!cell(1,1)")
    $PsFirstY = [double]$Origin.Evaluate("[PS]Sheet1!cell(1,2)")
    $PureFirstX = [double]$Origin.Evaluate("[Pure]Sheet1!cell(1,1)")
    $PureFirstY = [double]$Origin.Evaluate("[Pure]Sheet1!cell(1,2)")

    $SeriesForRange = @($PsSeries, $PureSeries)
    $DataMinX = ($SeriesForRange | Measure-Object -Property MinX -Minimum).Minimum
    $DataMaxX = ($SeriesForRange | Measure-Object -Property MaxX -Maximum).Maximum
    $DataMinY = ($SeriesForRange | Measure-Object -Property MinY -Minimum).Minimum
    $DataMaxY = ($SeriesForRange | Measure-Object -Property MaxY -Maximum).Maximum
    $AxisConfig = Get-CTAxisConfig -DataMaxX $DataMaxX -DataMaxY $DataMaxY
    Invoke-Origin -Origin $Origin -Command "win -a $GraphName; rescale;"
    Invoke-Origin -Origin $Origin -Command ("layer.x.from={0}; layer.x.to={1}; layer.x.inc={2}; layer.y.from={3}; layer.y.to={4}; layer.y.inc={5};" -f
        (Format-OriginNumber $AxisConfig.XFrom),
        (Format-OriginNumber $AxisConfig.XTo),
        (Format-OriginNumber $AxisConfig.XStep),
        (Format-OriginNumber $AxisConfig.YFrom),
        (Format-OriginNumber $AxisConfig.YTo),
        (Format-OriginNumber $AxisConfig.YStep)
    )
    Invoke-Origin -Origin $Origin -Command "win -a $GraphName; layer.x.label.font=font(Times New Roman); layer.y.label.font=font(Times New Roman); xb.font=font(Times New Roman); yl.font=font(Times New Roman); legend.font=font(Times New Roman);"

    $XFrom = [double]$Origin.Evaluate("layer.x.from")
    $XTo = [double]$Origin.Evaluate("layer.x.to")
    $XStep = [double]$Origin.Evaluate("layer.x.inc")
    $YFrom = [double]$Origin.Evaluate("layer.y.from")
    $YTo = [double]$Origin.Evaluate("layer.y.to")
    $YStep = [double]$Origin.Evaluate("layer.y.inc")
    if ($XFrom -gt $DataMinX -or $XTo -lt $DataMaxX -or $YFrom -gt $DataMinY -or $YTo -lt $DataMaxY) {
        throw "C-T axis does not cover all data for sample $Sample. Axis x=$XFrom..$XTo y=$YFrom..$YTo; data x=$DataMinX..$DataMaxX y=$DataMinY..$DataMaxY"
    }

    $FontResult = Set-OriginGraphTimesNewRoman -Origin $Origin -GraphName $GraphName

    $PngDirectory = Escape-LabTalkString -Text (Split-Path -Parent $PngPath)
    $PngFile = Escape-LabTalkString -Text (Split-Path -Leaf $PngPath)
    $TifDirectory = Escape-LabTalkString -Text (Split-Path -Parent $TifPath)
    $TifFile = Escape-LabTalkString -Text (Split-Path -Leaf $TifPath)
    Invoke-Origin -Origin $Origin -Command "win -a $GraphName; expGraph type:=png path:=`"$PngDirectory`" filename:=`"$PngFile`" overwrite:=replace;"
    Invoke-Origin -Origin $Origin -Command "win -a $GraphName; expGraph type:=tif path:=`"$TifDirectory`" filename:=`"$TifFile`" overwrite:=replace;"

    return [pscustomobject]@{
        Sample = $Sample
        Template = $CTTemplatePath
        ProjectFolder = $ProjectFolderName
        PsCsv = $PsCsv
        PureCsv = $PureCsv
        IntegratedIntoGpcProject = $true
        SeparateCtOpjuGenerated = $false
        Png = $PngPath
        Tif = $TifPath
        GraphName = $GraphName
        PsBookName = $PsSeries.BookName
        PureBookName = $PureSeries.BookName
        PsACount = $PsSeries.ACount
        PsBCount = $PsSeries.BCount
        PureACount = $PureSeries.ACount
        PureBCount = $PureSeries.BCount
        PsRowCount = $PsRows.Count
        PureRowCount = $PureRows.Count
        PsFirstX = $PsFirstX
        PsFirstY = $PsFirstY
        PureFirstX = $PureFirstX
        PureFirstY = $PureFirstY
        PsPreviewRows = @($PsRows | Select-Object -First 5)
        PurePreviewRows = @($PureRows | Select-Object -First 5)
        PlotCount = $FinalPlotCount
        PlotNames = @(Get-OriginPlotNames -Origin $Origin -GraphName $GraphName -FallbackNames @("PS", "Pure"))
        XFrom = $XFrom
        XTo = $XTo
        XStep = $XStep
        YFrom = $YFrom
        YTo = $YTo
        YStep = $YStep
        TimesNewRomanApplied = $true
        FontSizePreserved = $true
    }
}

function Build-OriginCategory {
    param([object]$Origin, [object]$Group, [string]$PngPath, [string]$TifPath)

    if ($Group.Records.Count -eq 0 -or -not $Group.Records[0].IsStockSolution) {
        throw "Group $($Group.GroupKey) does not start with Stock Solution."
    }

    $FolderName = Convert-ToOriginFolderName -Category $Group.Category
    $EscapedFolder = Escape-LabTalkString -Text $FolderName
    Invoke-Origin -Origin $Origin -Command "pe_cd /; pe_mkdir `"$EscapedFolder`"; pe_cd `"$EscapedFolder`";"

    $Series = New-Object System.Collections.Generic.List[object]
    $SafeGroup = Convert-ToSafeOriginName -Text $Group.GroupKey
    for ($Index = 0; $Index -lt $Group.Records.Count; $Index += 1) {
        $BookName = "{0}B{1:D2}" -f $SafeGroup, ($Index + 1)
        if ($BookName.Length -gt 24) { $BookName = "GB{0:D2}" -f ($Index + 1) }
        $Series.Add((Add-OriginWorkbook -Origin $Origin -Record $Group.Records[$Index] -BookName $BookName)) | Out-Null
    }

    $GraphName = (Convert-ToSafeOriginName -Text "${FolderName}GPC")
    $First = $Series[0]
    $EscapedTemplate = Escape-LabTalkString -Text $TemplatePath
    Invoke-Origin -Origin $Origin -Command "win -a $($First.BookName); worksheet -s 2 0 2 0;"
    Invoke-Origin -Origin $Origin -Command "worksheet -p 200 `"$EscapedTemplate`";"
    $CreatedGraphName = $Origin.LTStr("page.name$")
    if ([string]::IsNullOrWhiteSpace($CreatedGraphName) -or $CreatedGraphName -eq $First.BookName) {
        throw "Template graph page was not created for group $($Group.GroupKey). Refusing to use a default blank graph."
    }
    Invoke-Origin -Origin $Origin -Command "page.name$=`"$GraphName`";"
    $GraphName = $Origin.LTStr("page.name$")

    $FailedAdds = New-Object System.Collections.Generic.List[string]
    for ($Index = 1; $Index -lt $Series.Count; $Index += 1) {
        $Item = $Series[$Index]
        $BeforeCount = Get-OriginPlotCount -Origin $Origin -GraphName $GraphName
        Invoke-Origin -Origin $Origin -Command "win -a $GraphName; plotxy iy:=[$($Item.BookName)]Sheet1!(1,2) plot:=200 ogl:=1;"
        $AfterCount = Get-OriginPlotCount -Origin $Origin -GraphName $GraphName
        if ($AfterCount -ne ($BeforeCount + 1)) {
            $FailedAdds.Add("$($Item.Record.CsvFile.Name): expected plot count $($BeforeCount + 1), got $AfterCount") | Out-Null
        }
    }
    if ($FailedAdds.Count -gt 0) { throw "Some CSV files were not successfully added for $($Group.GroupKey): $($FailedAdds -join '; ')" }

    $FinalPlotCount = Get-OriginPlotCount -Origin $Origin -GraphName $GraphName
    if ($FinalPlotCount -ne $Series.Count) { throw "Final plot count mismatch for $($Group.GroupKey). Expected $($Series.Count), got $FinalPlotCount" }
    if ($Series[0].Legend -ne "Stock Solution") { throw "First legend is not Stock Solution for $($Group.GroupKey): $($Series[0].Legend)" }

    $DataMinX = ($Series | Measure-Object -Property MinX -Minimum).Minimum
    $DataMaxX = ($Series | Measure-Object -Property MaxX -Maximum).Maximum
    $DataMinY = ($Series | Measure-Object -Property MinY -Minimum).Minimum
    $DataMaxY = ($Series | Measure-Object -Property MaxY -Maximum).Maximum
    $XRange = [math]::Max($DataMaxX - $DataMinX, 0.001)
    $YRange = [math]::Max($DataMaxY - $DataMinY, 1)
    Invoke-Origin -Origin $Origin -Command "win -a $GraphName; legend -r; rescale;"
    Invoke-Origin -Origin $Origin -Command ("layer.x.from={0}; layer.x.to={1}; layer.y.from={2}; layer.y.to={3};" -f
        (Format-OriginNumber ($DataMinX - ($XRange * 0.03))),
        (Format-OriginNumber ($DataMaxX + ($XRange * 0.03))),
        (Format-OriginNumber ($DataMinY - ($YRange * 0.08))),
        (Format-OriginNumber ($DataMaxY + ($YRange * 0.08)))
    )

    $XFrom = [double]$Origin.Evaluate("layer.x.from")
    $XTo = [double]$Origin.Evaluate("layer.x.to")
    $YFrom = [double]$Origin.Evaluate("layer.y.from")
    $YTo = [double]$Origin.Evaluate("layer.y.to")
    if ($XFrom -gt $DataMinX -or $XTo -lt $DataMaxX -or $YFrom -gt $DataMinY -or $YTo -lt $DataMaxY) {
        throw "Axis does not cover all data for $($Group.GroupKey). Axis x=$XFrom..$XTo y=$YFrom..$YTo; data x=$DataMinX..$DataMaxX y=$DataMinY..$DataMaxY"
    }

    $FontResult = Set-OriginGraphTimesNewRoman -Origin $Origin -GraphName $GraphName

    $PngDirectory = Escape-LabTalkString -Text (Split-Path -Parent $PngPath)
    $PngFile = Escape-LabTalkString -Text (Split-Path -Leaf $PngPath)
    $TifDirectory = Escape-LabTalkString -Text (Split-Path -Parent $TifPath)
    $TifFile = Escape-LabTalkString -Text (Split-Path -Leaf $TifPath)
    Invoke-Origin -Origin $Origin -Command "win -a $GraphName; expGraph type:=png path:=`"$PngDirectory`" filename:=`"$PngFile`" overwrite:=replace;"
    Invoke-Origin -Origin $Origin -Command "win -a $GraphName; expGraph type:=tif path:=`"$TifDirectory`" filename:=`"$TifFile`" overwrite:=replace;"

    return [pscustomobject]@{
        GroupKey = $Group.GroupKey
        Sample = $Group.Sample
        Category = $Group.Category
        OriginFolder = $FolderName
        GraphName = $GraphName
        Series = $Series.ToArray()
        PlotCount = $FinalPlotCount
        ExpectedPlotCount = $Series.Count
        StockSolution = $Group.StockSolution
        StockIncluded = ($Series.Count -gt 0 -and $Series[0].Record.IsStockSolution)
        StockFirst = ($Series.Count -gt 0 -and $Series[0].Legend -eq "Stock Solution")
        PlotNames = @(Get-OriginPlotNames -Origin $Origin -GraphName $GraphName -FallbackNames ($Series | ForEach-Object { $_.Legend }))
        FailedAdds = $FailedAdds.ToArray()
        XFrom = $XFrom
        XTo = $XTo
        YFrom = $YFrom
        YTo = $YTo
        Png = $PngPath
        Tif = $TifPath
        TimesNewRomanApplied = $FontResult.TimesNewRomanApplied
        FontSizePreserved = $FontResult.FontSizePreserved
    }
}

function Move-ProcessedTxtBySample {
    param([object[]]$InputFiles, [string]$RunDate, [object]$LogLines)
    $ArchiveResults = New-Object System.Collections.Generic.List[object]
    $ArchiveDirs = New-Object System.Collections.Generic.List[object]

    foreach ($SampleGroup in @($InputFiles | Group-Object Sample | Sort-Object Name)) {
        $Sample = $SampleGroup.Name
        $SafeSample = Convert-ToSafePathPart -Text $Sample
        $ArchiveName = "{0}-{1}" -f $RunDate, $SafeSample
        $ArchiveDir = Get-UniqueDirectoryPathAnyRoot -ParentDirectory $ActiveInputDir -Name $ArchiveName
        if (-not (Test-Path -LiteralPath $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir | Out-Null }
        $ArchiveDirs.Add([pscustomobject]@{ Sample = $Sample; ArchiveDir = $ArchiveDir }) | Out-Null
        $LogLines.Add("sample archive folder: sample=$Sample, folder=$ArchiveDir") | Out-Null

        foreach ($InputFile in @($SampleGroup.Group)) {
            $TxtFile = $InputFile.TxtFile
        $Destination = Get-UniquePath -Directory $ArchiveDir -Stem $TxtFile.BaseName -Suffix $TxtFile.Extension
        try {
            Move-Item -LiteralPath $TxtFile.FullName -Destination $Destination
                $ArchiveResults.Add([pscustomobject]@{ Sample = $Sample; File = $TxtFile.Name; Archived = $true; Method = "move"; Destination = $Destination; ArchiveDir = $ArchiveDir }) | Out-Null
                $LogLines.Add("archived txt: sample=$Sample, file=$($TxtFile.Name), method=move, destination=$Destination") | Out-Null
        }
        catch {
            try {
                Copy-Item -LiteralPath $TxtFile.FullName -Destination $Destination
                    $ArchiveResults.Add([pscustomobject]@{ Sample = $Sample; File = $TxtFile.Name; Archived = $true; Method = "copy"; Destination = $Destination; ArchiveDir = $ArchiveDir }) | Out-Null
                    $LogLines.Add("archived txt: sample=$Sample, file=$($TxtFile.Name), method=copy after move failed, destination=$Destination, move_error=$($_.Exception.Message)") | Out-Null
            }
            catch {
                    $ArchiveResults.Add([pscustomobject]@{ Sample = $Sample; File = $TxtFile.Name; Archived = $false; Method = "failed"; Destination = ""; Error = $_.Exception.Message; ArchiveDir = $ArchiveDir }) | Out-Null
                    $LogLines.Add("archive failed: sample=$Sample, file=$($TxtFile.Name), error=$($_.Exception.Message)") | Out-Null
                }
            }
        }
    }

    return [pscustomobject]@{
        Results = $ArchiveResults.ToArray()
        ArchiveDirs = $ArchiveDirs.ToArray()
    }
}

Assert-ToolPath -Path $ToolRoot
Assert-ToolPath -Path $TemplatePath
Assert-ToolPath -Path $CTTemplatePath
New-Directory -Path $RunsDir
New-Directory -Path $LogsDir

$ActiveInputDir = if ([string]::IsNullOrWhiteSpace($InputFolder)) { $InputDir } else { [System.IO.Path]::GetFullPath($InputFolder) }
if (-not (Test-Path -LiteralPath $ActiveInputDir)) { throw "Input folder not found: $ActiveInputDir" }
if (-not (Test-Path -LiteralPath $TemplatePath)) { throw "Origin template not found: $TemplatePath" }
if (-not (Test-Path -LiteralPath $CTTemplatePath)) { throw "C-T Origin template not found: $CTTemplatePath" }

$IgnoredSubfolders = @(Get-ChildItem -LiteralPath $ActiveInputDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
$TxtFiles = @(Get-ChildItem -LiteralPath $ActiveInputDir -File -Filter "*.txt" | Sort-Object Name)
Write-Output "Current input mode: root txt only"
Write-Output "Input folder: $ActiveInputDir"
Write-Output "Input txt files to process:"
foreach ($TxtFile in $TxtFiles) { Write-Output "- $($TxtFile.Name)" }
Write-Output "Ignored subfolders:"
if ($IgnoredSubfolders.Count -eq 0) { Write-Output "- <none>" } else { foreach ($Folder in $IgnoredSubfolders) { Write-Output "- $($Folder.Name)" } }
if ($TxtFiles.Count -eq 0) {
    $NoInputLog = Join-Path $LogsDir ("no_input_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    [System.IO.File]::WriteAllLines(
        $NoInputLog,
        @(
            "run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            "input folder: $ActiveInputDir",
            "message: no root-level txt files found; no run folder was created",
            "child folders are ignored by design"
        ),
        [System.Text.Encoding]::UTF8
    )
    throw "No root-level txt files found in $ActiveInputDir. No run folder was created. See log: $NoInputLog"
}

$FallbackSampleName = $SampleName.Trim()
if ([string]::IsNullOrWhiteSpace($FallbackSampleName)) {
    $InputLeaf = Split-Path -Leaf $ActiveInputDir
    if (-not [string]::IsNullOrWhiteSpace($InputLeaf) -and $InputLeaf -ne "00_input_txt") {
        $FallbackSampleName = $InputLeaf
    }
}

$PreScanMetadata = @(
    foreach ($TxtFile in $TxtFiles) {
        $Metadata = Get-DataFileNameMetadata -TxtPath $TxtFile.FullName
        [pscustomobject]@{
            TxtFile = $TxtFile
            Metadata = $Metadata
        }
    }
)
$PreScanSamples = @(
    $PreScanMetadata |
        Where-Object { $null -ne $_.Metadata.Parsed -and -not [string]::IsNullOrWhiteSpace($_.Metadata.Parsed.Sample) } |
        ForEach-Object { $_.Metadata.Parsed.Sample } |
        Sort-Object -Unique
)
$PreScanResolvedSamples = @(
    @(
        foreach ($Item in $PreScanMetadata) {
        $DataFileSample = if ($null -ne $Item.Metadata.Parsed) { $Item.Metadata.Parsed.Sample } else { "" }
        $ExternalFileSample = Get-ExternalFileNameSample -BaseName $Item.TxtFile.BaseName
        if (-not [string]::IsNullOrWhiteSpace($DataFileSample)) { $DataFileSample }
        elseif (-not [string]::IsNullOrWhiteSpace($ExternalFileSample)) { $ExternalFileSample }
        elseif (-not [string]::IsNullOrWhiteSpace($SampleName.Trim())) { $SampleName.Trim() }
        }
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)
$SampleNameProvided = -not [string]::IsNullOrWhiteSpace($SampleName.Trim())
$SampleOverrideEnabled = $SampleNameProvided -and $ForceSampleName
if (-not $SampleOverrideEnabled -and -not $AllowMultiSample -and $PreScanResolvedSamples.Count -gt 1) {
    Write-Output "Sample detection summary:"
    foreach ($Item in $PreScanMetadata) {
        $DataFileSample = if ($null -ne $Item.Metadata.Parsed) { $Item.Metadata.Parsed.Sample } else { "" }
        Write-Output ("- File: {0}, DataFileSample = {1}, EffectiveSample = ERROR" -f $Item.TxtFile.Name, $(if ([string]::IsNullOrWhiteSpace($DataFileSample)) { '<none>' } else { $DataFileSample }))
    }
    Write-Output "ERROR: Multiple sample names detected in single-sample mode."
    Write-Output "Detected samples: $($PreScanResolvedSamples -join ', ')"
    Write-Output "This may be caused by inconsistent Data File Name metadata."
    Write-Output 'Please fix file metadata, rerun with -AllowMultiSample, or explicitly force one sample with:'
    Write-Output '-SampleName "<sample>" -ForceSampleName'
    throw "ERROR: Multiple sample names detected in single-sample mode. Detected samples: $($PreScanResolvedSamples -join ', ')"
}
$PreScanDates = @(
    $PreScanMetadata |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Metadata.ParsedDate) } |
        ForEach-Object { $_.Metadata.ParsedDate } |
        Sort-Object -Unique
)
$PreScanTimes = @(
    $PreScanMetadata |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Metadata.OutputTime) } |
        ForEach-Object { $_.Metadata.OutputTime } |
        Sort-Object -Unique
)
$RunDate = if ($PreScanDates.Count -gt 0) { ($PreScanDates | Sort-Object -Descending | Select-Object -First 1) } else { Get-Date -Format "yyyyMMdd" }
$LatestDateTimes = @(
    $PreScanMetadata |
        Where-Object { $_.Metadata.ParsedDate -eq $RunDate -and -not [string]::IsNullOrWhiteSpace($_.Metadata.OutputTime) } |
        ForEach-Object { $_.Metadata.OutputTime } |
        Sort-Object -Unique
)
$RunTime = if ($LatestDateTimes.Count -gt 0) { ($LatestDateTimes | Sort-Object -Descending | Select-Object -First 1) } elseif ($PreScanTimes.Count -gt 0) { ($PreScanTimes | Sort-Object -Descending | Select-Object -First 1) } else { "" }
$RunSample = if ($SampleOverrideEnabled) {
    Convert-ToSafePathPart -Text $SampleName.Trim()
}
elseif ($PreScanResolvedSamples.Count -eq 1) {
    Convert-ToSafePathPart -Text $PreScanResolvedSamples[0]
}
elseif ($PreScanResolvedSamples.Count -gt 1) {
    "MultiSample"
}
elseif (-not [string]::IsNullOrWhiteSpace($FallbackSampleName)) {
    Convert-ToSafePathPart -Text $FallbackSampleName
}
else {
    "Sample"
}
$RunStem = if ([string]::IsNullOrWhiteSpace($RunTime)) { "{0}-{1}_GPC_Run" -f $RunDate, $RunSample } else { "{0}_{1}-{2}_GPC_Run" -f $RunDate, $RunTime, $RunSample }
$RunDir = Get-UniqueDirectoryPath -ParentDirectory $RunsDir -Name $RunStem
New-Directory -Path $RunDir
$RunName = Split-Path -Leaf $RunDir

$InputCopyDir = Join-Path $RunDir "input_txt_copy"
$ProcessedCsvDir = Join-Path $RunDir "processed_csv"
$OriginProjectDir = Join-Path $RunDir "origin_project"
$ExportFiguresDir = Join-Path $RunDir "export_figures"
$RunLogDir = Join-Path $RunDir "logs"
foreach ($Dir in @($InputCopyDir, $ProcessedCsvDir, $OriginProjectDir, $ExportFiguresDir, $RunLogDir)) { New-Directory -Path $Dir }

$LogPath = Join-Path $RunLogDir "run_gpc_origin_autoplot.log"
$LogLines = New-Object System.Collections.Generic.List[string]
$Failures = New-Object System.Collections.Generic.List[string]
$LogLines.Add("run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
$LogLines.Add("tool root: $ToolRoot") | Out-Null
$LogLines.Add("run folder: $RunDir") | Out-Null
$LogLines.Add("detected samples from Data File Name: $(if ($PreScanSamples.Count -gt 0) { $PreScanSamples -join ', ' } else { '<none>' })") | Out-Null
$LogLines.Add("resolved samples before plotting: $(if ($PreScanResolvedSamples.Count -gt 0) { $PreScanResolvedSamples -join ', ' } else { '<none>' })") | Out-Null
$LogLines.Add("detected dates from metadata: $(if ($PreScanDates.Count -gt 0) { $PreScanDates -join ', ' } else { '<fallback current date>' })") | Out-Null
$LogLines.Add("detected output times: $(if ($PreScanTimes.Count -gt 0) { $PreScanTimes -join ', ' } else { '<none>' })") | Out-Null
$LogLines.Add("final run folder name: $RunName") | Out-Null
$LogLines.Add("input folder: $ActiveInputDir") | Out-Null
$LogLines.Add("Current input mode: root txt only") | Out-Null
$LogLines.Add("Input txt files to process: $(($TxtFiles | ForEach-Object { $_.Name }) -join ', ')") | Out-Null
$LogLines.Add("Ignored subfolders: $(if ($IgnoredSubfolders.Count -eq 0) { '<none>' } else { ($IgnoredSubfolders | ForEach-Object { $_.Name }) -join ', ' })") | Out-Null
$LogLines.Add("SampleName parameter: $(if ([string]::IsNullOrWhiteSpace($SampleName)) { '<none>' } else { $SampleName })") | Out-Null
$LogLines.Add("AllowMultiSample parameter: $AllowMultiSample") | Out-Null
$LogLines.Add("ForceSampleName parameter: $ForceSampleName") | Out-Null
$LogLines.Add("SampleName override enabled: $SampleOverrideEnabled") | Out-Null
$LogLines.Add("default sample name for unresolved files: $FallbackSampleName") | Out-Null
$TemplateFiles = @(Get-ChildItem -LiteralPath $TemplateDir -File -Filter "*.otpu" | Sort-Object Name)
$LogLines.Add("template files detected: $(($TemplateFiles | ForEach-Object { $_.FullName }) -join '; ')") | Out-Null
$LogLines.Add("GPC template used: $TemplatePath") | Out-Null
$LogLines.Add("C-T template used: $CTTemplatePath") | Out-Null
$LogLines.Add("input child folders skipped: only root-level txt files in active input folder are read") | Out-Null

Write-Output "Detected samples:"
if ($PreScanResolvedSamples.Count -eq 0) { Write-Output "- <none>" } else { foreach ($Item in $PreScanResolvedSamples) { Write-Output "- $Item" } }
Write-Output "Detected dates:"
if ($PreScanDates.Count -eq 0) { Write-Output "- <fallback current date>" } else { foreach ($Item in $PreScanDates) { Write-Output "- $Item" } }
Write-Output "Detected output time:"
if ($PreScanTimes.Count -eq 0) { Write-Output "- <none>" } else { foreach ($Item in $PreScanTimes) { Write-Output "- $Item" } }
Write-Output "Run folder:"
Write-Output $RunDir
Write-Output "GPC font normalization:"
Write-Output "Times New Roman"
Write-Output "Sample detection summary:"
foreach ($Item in $PreScanMetadata) {
    $DataFileSample = if ($null -ne $Item.Metadata.Parsed) { $Item.Metadata.Parsed.Sample } else { "" }
    $ExternalFileSample = Get-ExternalFileNameSample -BaseName $Item.TxtFile.BaseName
    $SampleNameUsedAsFallback = $false
    $EffectiveSampleForPreview = if ($SampleOverrideEnabled) {
        $SampleName.Trim()
    }
    elseif (-not [string]::IsNullOrWhiteSpace($DataFileSample)) {
        $DataFileSample
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ExternalFileSample)) {
        $ExternalFileSample
    }
    else {
        $SampleNameUsedAsFallback = -not [string]::IsNullOrWhiteSpace($SampleName.Trim())
        $FallbackSampleName
    }
    if (-not $SampleOverrideEnabled -and $SampleNameProvided -and -not [string]::IsNullOrWhiteSpace($DataFileSample) -and $DataFileSample -ne $SampleName.Trim()) {
        $WarningMessage = "WARNING: Data File Name sample is $DataFileSample, but -SampleName is $($SampleName.Trim()). Since -ForceSampleName is not set, using Data File Name sample: $DataFileSample."
        Write-Warning $WarningMessage
        $LogLines.Add($WarningMessage) | Out-Null
    }
    Write-Output "file = $($Item.TxtFile.Name)"
    Write-Output "DataFileNameSample = $(if ([string]::IsNullOrWhiteSpace($DataFileSample)) { '<none>' } else { $DataFileSample })"
    Write-Output "ExternalFileNameSample = $(if ([string]::IsNullOrWhiteSpace($ExternalFileSample)) { '<none>' } else { $ExternalFileSample })"
    Write-Output "SampleNameParameter = $(if ([string]::IsNullOrWhiteSpace($SampleName)) { '<none>' } else { $SampleName })"
    Write-Output "ForceSampleName = $ForceSampleName"
    Write-Output "FinalEffectiveSample = $(if ([string]::IsNullOrWhiteSpace($EffectiveSampleForPreview)) { '<unresolved>' } else { $EffectiveSampleForPreview })"
    Write-Output "SampleNameUsedAsFallback = $SampleNameUsedAsFallback"
    $LogLines.Add("sample detection: file=$($Item.TxtFile.Name), DataFileNameSample=$(if ([string]::IsNullOrWhiteSpace($DataFileSample)) { '<none>' } else { $DataFileSample }), ExternalFileNameSample=$(if ([string]::IsNullOrWhiteSpace($ExternalFileSample)) { '<none>' } else { $ExternalFileSample }), SampleNameParameter=$(if ([string]::IsNullOrWhiteSpace($SampleName)) { '<none>' } else { $SampleName }), ForceSampleName=$ForceSampleName, FinalEffectiveSample=$(if ([string]::IsNullOrWhiteSpace($EffectiveSampleForPreview)) { '<unresolved>' } else { $EffectiveSampleForPreview }), SampleNameUsedAsFallback=$SampleNameUsedAsFallback") | Out-Null
}

$Records = New-Object System.Collections.Generic.List[object]
$InputFileInfos = New-Object System.Collections.Generic.List[object]
foreach ($TxtFile in $TxtFiles) {
    $Metadata = $null
    $MetadataSource = ""
    $Parts = $null
    try {
        Write-Output "Extracting: $($TxtFile.Name)"
        $Metadata = ($PreScanMetadata | Where-Object { $_.TxtFile.FullName -eq $TxtFile.FullName } | Select-Object -First 1).Metadata
        if ($Metadata.Found -and $null -ne $Metadata.Parsed) {
            $Parts = $Metadata.Parsed
            $MetadataSource = "Data File Name"
        }
        else {
            $Parts = Get-NameParts -BaseName $TxtFile.BaseName -DefaultSampleName $FallbackSampleName
            $MetadataSource = "External txt filename"
        }
        if ($SampleOverrideEnabled) {
            $Parts.Sample = $SampleName.Trim()
            $Parts.GroupKey = "$($Parts.Sample)-$($Parts.Category)"
        }
        $LogLines.Add("parse: txt=$($TxtFile.Name), metadata_source=$MetadataSource, data_file_name=$($Metadata.RawValue), data_file_name_found=$($Metadata.Found), data_file_name_basename=$($Metadata.BaseName), Sample=$($Parts.Sample), Time_h=$($Parts.Time), Category=$($Parts.Category), Date=$($Metadata.ParsedDate), Output_Time=$($Metadata.OutputTime), Has_Sample_Prefix=$($Parts.HasSamplePrefix)") | Out-Null
        Write-Output "parse: $($TxtFile.Name)"
        Write-Output "metadata_source = $MetadataSource"
        Write-Output "Data File Name basename = $(if ($Metadata.Found) { $Metadata.BaseName } else { '<not found>' })"
        Write-Output "Sample = $($Parts.Sample)"
        Write-Output "Time_h = $($Parts.Time)"
        Write-Output "Category = $($Parts.Category)"
        Write-Output "Has_Sample_Prefix = $($Parts.HasSamplePrefix)"
        $SafeSample = Convert-ToSafePathPart -Text $(if ($Parts.IsSharedPrefixlessStock) { "__shared_stock__" } else { $Parts.Sample })
        $SafeCategory = Convert-ToSafePathPart -Text $Parts.Category
        $CopyPath = Get-UniquePath -Directory $InputCopyDir -Stem $TxtFile.BaseName -Suffix $TxtFile.Extension
        Copy-Item -LiteralPath $TxtFile.FullName -Destination $CopyPath

        if ($Parts.Time -eq 0 -and $Parts.Category -ine "ps") {
            $LogLines.Add("skipped: $($TxtFile.Name), reason=0h non-ps is not plotted by default; Stock Solution must come from sample-0h-ps") | Out-Null
            continue
        }

        $Points = @(Extract-GpcPoints -TxtPath $TxtFile.FullName)
        $CategoryCsvDir = Join-Path (Join-Path $ProcessedCsvDir $SafeSample) $SafeCategory
        New-Directory -Path $CategoryCsvDir
        $CsvPath = Get-UniquePath -Directory $CategoryCsvDir -Stem $TxtFile.BaseName -Suffix ".csv"
        Write-XYCsv -Path $CsvPath -Points $Points
        $HeightSum = ($Points | Measure-Object -Property Y -Sum).Sum

        $CanServeAsSharedPrefixlessStock = Test-PrefixlessStockFileName -BaseName $TxtFile.BaseName
        $Records.Add([pscustomobject]@{
            TxtFile = $TxtFile
            TxtCopy = Get-Item -LiteralPath $CopyPath
            CsvFile = Get-Item -LiteralPath $CsvPath
            Sample = $Parts.Sample
            Category = $Parts.Category
            Time = $Parts.Time
            TimeText = $Parts.TimeText
            GroupKey = $Parts.GroupKey
            HasSamplePrefix = $Parts.HasSamplePrefix
            IsExplicitC0 = $Parts.IsExplicitC0
            IsSharedPrefixlessStock = $Parts.IsSharedPrefixlessStock
            CanServeAsSharedPrefixlessStock = $CanServeAsSharedPrefixlessStock
            SharedStockKind = $Parts.SharedStockKind
            Points = $Points
            HeightSum = [double]$HeightSum
        }) | Out-Null
        $InputFileInfos.Add([pscustomobject]@{ TxtFile = $TxtFile; Sample = $Parts.Sample; Category = $Parts.Category; Time = $Parts.Time; HasSamplePrefix = $Parts.HasSamplePrefix; IsSharedPrefixlessStock = $Parts.IsSharedPrefixlessStock; CanServeAsSharedPrefixlessStock = $CanServeAsSharedPrefixlessStock }) | Out-Null
        $LogLines.Add("extracted: $($TxtFile.Name), sample=$($Parts.Sample), category=$($Parts.Category), time=$($Parts.Time), points=$($Points.Count), height_sum=$HeightSum, csv=$CsvPath") | Out-Null
        Write-Output "OK: $($TxtFile.Name), points = $($Points.Count)"
    }
    catch {
        $Reason = $_.Exception.Message
        $Failures.Add("$($TxtFile.Name): $Reason") | Out-Null
        $LogLines.Add("skipped extraction failure: file=$($TxtFile.Name), reason=$Reason, data_file_name_found=$(if ($null -ne $Metadata) { $Metadata.Found } else { $false }), data_file_name_basename=$(if ($null -ne $Metadata) { $Metadata.BaseName } else { '' }), metadata_source=$MetadataSource, parsed=$(if ($null -ne $Parts) { $true } else { $false }), points=0") | Out-Null
        Write-Output "FAILED: $($TxtFile.Name), reason = $Reason"
        Write-Output "Data File Name found = $(if ($null -ne $Metadata) { $Metadata.Found } else { $false })"
        Write-Output "Data File Name basename = $(if ($null -ne $Metadata -and $Metadata.Found) { $Metadata.BaseName } else { '<not found>' })"
        Write-Output "metadata_source = $(if ([string]::IsNullOrWhiteSpace($MetadataSource)) { '<none>' } else { $MetadataSource })"
        Write-Output "Parsed Time/Sample/Category = $(if ($null -ne $Parts) { 'True' } else { 'False' })"
        Write-Output "Extracted points = 0"
    }
}

if ($Records.Count -eq 0) {
    $LogLines.Add("failures before Origin: no plottable CSV records were extracted; skipped=$(($Failures) -join '; ')") | Out-Null
    [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
    throw "No plottable CSV records were extracted. See log: $LogPath"
}
if ($Failures.Count -gt 0) {
    $LogLines.Add("skipped failed input files: $($Failures -join '; ')") | Out-Null
}

$SharedPrefixlessStocks = @(
    $Records |
        Where-Object { $_.CanServeAsSharedPrefixlessStock } |
        Sort-Object @{ Expression = { if ($_.IsExplicitC0) { 0 } else { 1 } } }, @{ Expression = { $_.CsvFile.Name }; Descending = $false }
)
$ActualSampleRecords = @($Records | Where-Object { -not $_.IsSharedPrefixlessStock })
$DetectedSamples = @($ActualSampleRecords | Select-Object -ExpandProperty Sample -Unique | Sort-Object)
if ($DetectedSamples.Count -eq 0) {
    $LogLines.Add("failures before Origin: only shared prefixless Stock Solution files were extracted; no sample records were detected") | Out-Null
    [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
    throw "No sample records were detected after extraction. Shared Stock Solution input alone is not enough to plot."
}
if ($SharedPrefixlessStocks.Count -gt 0) {
    foreach ($SharedStock in $SharedPrefixlessStocks) {
        $Message = "Shared prefixless Stock Solution detected: $($SharedStock.TxtFile.Name)"
        Write-Output $Message
        $LogLines.Add($Message) | Out-Null
    }
}
if ($DetectedSamples.Count -eq 1 -and $SharedPrefixlessStocks.Count -gt 0) {
    foreach ($SharedStock in $SharedPrefixlessStocks) {
        $SharedStock.Sample = $DetectedSamples[0]
        $SharedStock.GroupKey = "$($DetectedSamples[0])-$($SharedStock.Category)"
    }
    foreach ($InputInfo in @($InputFileInfos | Where-Object { $_.IsSharedPrefixlessStock })) {
        $InputInfo.Sample = $DetectedSamples[0]
    }
}

$SummaryRows = @(
    $Records |
        Sort-Object Sample, Category, Time |
        ForEach-Object {
            [pscustomobject]@{
                Sample = $_.Sample
                Category = $_.Category
                Time_h = $_.Time
                Txt_File = $_.TxtFile.Name
                Csv_File = $_.CsvFile.Name
                Height_Sum = $_.HeightSum
            }
        }
)
$SummaryCsvPath = Join-Path $ExportFiguresDir "height_sum_summary.csv"
Write-SummaryCsv -Path $SummaryCsvPath -Rows $SummaryRows
$SummaryXlsxPath = Join-Path $ExportFiguresDir "height_sum_summary.xlsx"
$XlsxCreated = Try-WriteSummaryXlsx -Path $SummaryXlsxPath -Rows $SummaryRows
$LogLines.Add("height summary csv: $SummaryCsvPath") | Out-Null
$LogLines.Add("height summary xlsx: $(if ($XlsxCreated) { $SummaryXlsxPath } else { 'not created; Excel COM unavailable or failed' })") | Out-Null
foreach ($Row in $SummaryRows) {
    $LogLines.Add("height sum: sample=$($Row.Sample), category=$($Row.Category), time=$($Row.Time_h), txt=$($Row.Txt_File), csv=$($Row.Csv_File), height_sum=$($Row.Height_Sum)") | Out-Null
}
foreach ($DetectedSampleName in @($Records | Select-Object -ExpandProperty Sample -Unique | Sort-Object)) {
    $SampleSummaryDir = Join-Path $ExportFiguresDir (Convert-ToSafePathPart -Text $DetectedSampleName)
    New-Directory -Path $SampleSummaryDir
    $SampleSummaryPath = Join-Path $SampleSummaryDir ("height_sum_summary_{0}.csv" -f (Convert-ToSafePathPart -Text $DetectedSampleName))
    Write-SummaryCsv -Path $SampleSummaryPath -Rows @($SummaryRows | Where-Object { $_.Sample -eq $DetectedSampleName })
    $LogLines.Add("sample height summary: $SampleSummaryPath") | Out-Null
}

$Samples = $DetectedSamples
$Categories = @($Records | Select-Object -ExpandProperty Category -Unique | Sort-Object)
$LogLines.Add("samples: $($Samples -join ', ')") | Out-Null
$LogLines.Add("categories: $($Categories -join ', ')") | Out-Null
Write-Output "Detected samples: $($Samples -join ', ')"

$GroupsBySample = @(
    $ActualSampleRecords |
        Group-Object Sample |
        Sort-Object Name |
        ForEach-Object {
            $Sample = $_.Name
            $SampleRecords = @($_.Group)
            $SampleExplicitStocks = @($SampleRecords | Where-Object { $_.IsExplicitC0 } | Sort-Object @{ Expression = { $_.CsvFile.Name }; Descending = $false })
            $SampleFallbackStocks = @($SampleRecords | Where-Object { $_.Time -eq 0 -and $_.Category -ieq "ps" -and -not $_.IsExplicitC0 } | Sort-Object @{ Expression = { $_.CsvFile.Name }; Descending = $false })
            $SharedExplicitStocks = @($SharedPrefixlessStocks | Where-Object { $_.IsExplicitC0 } | Sort-Object @{ Expression = { $_.CsvFile.Name }; Descending = $false })
            $SharedFallbackStocks = @($SharedPrefixlessStocks | Where-Object { $_.Time -eq 0 -and $_.Category -ieq "ps" -and -not $_.IsExplicitC0 } | Sort-Object @{ Expression = { $_.CsvFile.Name }; Descending = $false })
            $Stock = @()
            $StockMatchMode = ""
            if ($SampleExplicitStocks.Count -gt 0) {
                $Stock = $SampleExplicitStocks
                $StockMatchMode = "sample-specific C0"
            }
            elseif ($SampleFallbackStocks.Count -gt 0) {
                $Stock = $SampleFallbackStocks
                $StockMatchMode = "sample-specific 0h-ps"
            }
            elseif ($SharedExplicitStocks.Count -gt 0) {
                $Stock = $SharedExplicitStocks
                $StockMatchMode = "shared prefixless C0"
            }
            elseif ($SharedFallbackStocks.Count -gt 0) {
                $Stock = $SharedFallbackStocks
                $StockMatchMode = "shared prefixless 0h-ps"
            }
            if ($Stock.Count -eq 0) { throw "Missing Stock Solution file for sample $Sample. Expected sample-specific C0 / ${Sample}-0h-ps or shared prefixless C0 / 0h-ps." }
            if ($Stock.Count -gt 1) { throw "Multiple Stock Solution candidates for sample ${Sample}: $(($Stock | ForEach-Object { $_.CsvFile.Name }) -join ', ')" }
            $StockRecord = $Stock[0]
            $PsRecords = @($SampleRecords | Where-Object { $_.Category -ieq "ps" })
            $PureRecords = @($SampleRecords | Where-Object { $_.Category -ieq "pure" })
            if ($PsRecords.Count -eq 0) { throw "No valid ps data for sample $Sample." }
            if ($PureRecords.Count -eq 0) { throw "No valid pure data for sample $Sample." }
            $CategoryGroups = New-Object System.Collections.Generic.List[object]
            foreach ($Category in @($SampleRecords | Select-Object -ExpandProperty Category -Unique | Sort-Object)) {
                $CategoryRecords = @(
                    $SampleRecords |
                        Where-Object { $_.Category -eq $Category -and $_.Time -ne 0 } |
                        Sort-Object @{ Expression = "Time"; Descending = $false }, @{ Expression = { $_.CsvFile.Name }; Descending = $false }
                )
                $StockForGroup = $StockRecord.PSObject.Copy()
                $StockForGroup | Add-Member -NotePropertyName IsStockSolution -NotePropertyValue $true -Force
                $RecordsForGroup = New-Object System.Collections.Generic.List[object]
                $RecordsForGroup.Add($StockForGroup) | Out-Null
                foreach ($Record in $CategoryRecords) {
                    $NormalRecord = $Record.PSObject.Copy()
                    $NormalRecord | Add-Member -NotePropertyName IsStockSolution -NotePropertyValue $false -Force
                    $RecordsForGroup.Add($NormalRecord) | Out-Null
                }
                $CategoryGroups.Add([pscustomobject]@{
                    GroupKey = "$Sample-$Category"
                    Sample = $Sample
                    Category = $Category
                    StockSolution = $StockRecord
                    Records = $RecordsForGroup.ToArray()
                }) | Out-Null
            }
            [pscustomobject]@{ Sample = $Sample; StockSolution = $StockRecord; StockMatchMode = $StockMatchMode; Groups = $CategoryGroups.ToArray() }
        }
)

foreach ($SampleGroup in $GroupsBySample) {
    $StockMessage = "Sample $($SampleGroup.Sample) Stock Solution = $($SampleGroup.StockSolution.TxtFile.Name)"
    $ModeMessage = "Stock Solution match mode = $($SampleGroup.StockMatchMode)"
    Write-Output $StockMessage
    Write-Output $ModeMessage
    $LogLines.Add("sample stock solution: sample=$($SampleGroup.Sample), stock=$($SampleGroup.StockSolution.CsvFile.Name), source_txt=$($SampleGroup.StockSolution.TxtFile.Name), match_mode=$($SampleGroup.StockMatchMode)") | Out-Null
    foreach ($Group in $SampleGroup.Groups) {
        $LogLines.Add("group: $($Group.GroupKey)") | Out-Null
        $LogLines.Add("group files: $(($Group.Records | ForEach-Object { $_.CsvFile.Name }) -join ', ')") | Out-Null
        $LogLines.Add("group legend order: $(($Group.Records | ForEach-Object { if ($_.IsStockSolution) { 'Stock Solution' } else { '{0:g} h' -f $_.Time } }) -join ', ')") | Out-Null
    }
}

$Origin = $null
$Results = New-Object System.Collections.Generic.List[object]
$SampleProjectResults = New-Object System.Collections.Generic.List[object]
$C0ComparisonResults = New-Object System.Collections.Generic.List[object]
$CTResults = New-Object System.Collections.Generic.List[object]
try {
    $Origin = New-Object -ComObject Origin.ApplicationSI
    $Origin.Visible = 1
    foreach ($SampleGroup in $GroupsBySample) {
        $Origin.NewProject() | Out-Null
        $SafeSample = Convert-ToSafePathPart -Text $SampleGroup.Sample
        $SampleProjectDir = Join-Path $OriginProjectDir $SafeSample
        New-Directory -Path $SampleProjectDir
        $SampleOpjuPath = Get-UniquePath -Directory $SampleProjectDir -Stem ("{0}_GPC" -f $SafeSample) -Suffix ".opju"
        $SampleRecordsForC0 = @($ActualSampleRecords | Where-Object { $_.Sample -eq $SampleGroup.Sample })
        if ($SampleGroup.StockSolution.Sample -ne $SampleGroup.Sample) {
            $SharedStockForC0 = $SampleGroup.StockSolution.PSObject.Copy()
            $SharedStockForC0.Sample = $SampleGroup.Sample
            $SharedStockForC0.GroupKey = "$($SampleGroup.Sample)-$($SharedStockForC0.Category)"
            $SampleRecordsForC0 += $SharedStockForC0
        }
        $C0Record = Get-C0Record -SampleRecords $SampleRecordsForC0 -Sample $SampleGroup.Sample -LogLines $LogLines
        $C0CsvPath = $null
        $C0XlsxPath = $null
        $C0XlsxCreated = $false
        $TimeSecondsPercentCsvPath = $null
        $TimeSecondsPercentXlsxPath = $null
        $TimeSecondsPercentXlsxCreated = $false
        $TimeSecondsPercentRows = @()
        $CTPsCsvPath = $null
        $CTPureCsvPath = $null
        $CTPsRows = @()
        $CTPureRows = @()
        if ($null -ne $C0Record) {
            $C0Rows = @(New-C0ComparisonRows -SampleRecords $SampleRecordsForC0 -C0Record $C0Record -LogLines $LogLines)
            $C0CsvPath = Join-Path $SampleProjectDir ("height_sum_vs_C0_{0}.csv" -f $SafeSample)
            $C0XlsxPath = Join-Path $SampleProjectDir ("height_sum_vs_C0_{0}.xlsx" -f $SafeSample)
            Write-C0ComparisonCsv -Path $C0CsvPath -Rows $C0Rows
            $C0XlsxCreated = Try-WriteC0ComparisonXlsx -Path $C0XlsxPath -Rows $C0Rows
            $TimeSecondsPercentRows = @(New-TimeSecondsPercentRows -C0Rows $C0Rows -Sample $SampleGroup.Sample -LogLines $LogLines)
            $TimeSecondsPercentCsvPath = Join-Path $SampleProjectDir ("time_seconds_percent_{0}.csv" -f $SafeSample)
            $TimeSecondsPercentXlsxPath = Join-Path $SampleProjectDir ("time_seconds_percent_{0}.xlsx" -f $SafeSample)
            Write-TimeSecondsPercentCsv -Path $TimeSecondsPercentCsvPath -Rows $TimeSecondsPercentRows
            $TimeSecondsPercentXlsxCreated = Try-WriteTimeSecondsPercentXlsx -Path $TimeSecondsPercentXlsxPath -Rows $TimeSecondsPercentRows
            $CTPsRows = @(New-CTCategoryRows -C0Rows $C0Rows -Sample $SampleGroup.Sample -Category "ps" -LogLines $LogLines)
            $CTPureRows = @(New-CTCategoryRows -C0Rows $C0Rows -Sample $SampleGroup.Sample -Category "pure" -LogLines $LogLines)
            $CTPsCsvPath = Join-Path $SampleProjectDir ("C-T_PS_{0}.csv" -f $SafeSample)
            $CTPureCsvPath = Join-Path $SampleProjectDir ("C-T_Pure_{0}.csv" -f $SafeSample)
            Write-TimeSecondsPercentCsv -Path $CTPsCsvPath -Rows $CTPsRows
            Write-TimeSecondsPercentCsv -Path $CTPureCsvPath -Rows $CTPureRows
            $LogLines.Add("C0 file: sample=$($SampleGroup.Sample), file=$($C0Record.CsvFile.Name)") | Out-Null
            $LogLines.Add("C0 height sum: sample=$($SampleGroup.Sample), C0_Height_Sum=$($C0Record.HeightSum)") | Out-Null
            foreach ($Row in $C0Rows) {
                $LogLines.Add("C0 comparison: sample=$($Row.Sample), category=$($Row.Category), time=$($Row.Time_h), csv=$($Row.Csv_File), height_sum=$($Row.Height_Sum), C0=$($Row.C0_File), C0_height_sum=$($Row.C0_Height_Sum), difference=$($Row.Difference_vs_C0), ratio=$($Row.Ratio_vs_C0), percent=$($Row.Percent_vs_C0)") | Out-Null
            }
            $LogLines.Add("C0 comparison csv: $C0CsvPath") | Out-Null
            $LogLines.Add("C0 comparison xlsx: $(if ($C0XlsxCreated) { $C0XlsxPath } else { 'not created; Excel COM unavailable or failed' })") | Out-Null
            $LogLines.Add("time_seconds_percent csv: $TimeSecondsPercentCsvPath") | Out-Null
            $LogLines.Add("time_seconds_percent xlsx: $(if ($TimeSecondsPercentXlsxCreated) { $TimeSecondsPercentXlsxPath } else { 'not created; Excel COM unavailable or failed' })") | Out-Null
            $LogLines.Add("time_seconds_percent rows: sample=$($SampleGroup.Sample), rows=$($TimeSecondsPercentRows.Count), merged_categories=$(($C0Rows | Select-Object -ExpandProperty Category -Unique | Sort-Object) -join ', ')") | Out-Null
            $LogLines.Add("C-T PS csv: $CTPsCsvPath") | Out-Null
            $LogLines.Add("C-T Pure csv: $CTPureCsvPath") | Out-Null
            $LogLines.Add("C-T PS rows: sample=$($SampleGroup.Sample), rows=$($CTPsRows.Count)") | Out-Null
            $LogLines.Add("C-T Pure rows: sample=$($SampleGroup.Sample), rows=$($CTPureRows.Count)") | Out-Null
        }
        else {
            $LogLines.Add("C0 comparison skipped: sample=$($SampleGroup.Sample), reason=no C0 file found") | Out-Null
        }
        $OriginFolders = New-Object System.Collections.Generic.List[string]

        foreach ($Group in $SampleGroup.Groups) {
            $SafeCategory = Convert-ToSafePathPart -Text $Group.Category
            $GroupFigureDir = Join-Path (Join-Path $ExportFiguresDir $SafeSample) $SafeCategory
            New-Directory -Path $GroupFigureDir
            $OutputStem = "{0}_{1}_GPC" -f $SafeSample, $SafeCategory
            $PngPath = Get-UniquePath -Directory $GroupFigureDir -Stem $OutputStem -Suffix ".png"
            $TifPath = Get-UniquePath -Directory $GroupFigureDir -Stem $OutputStem -Suffix ".tif"
            $Result = Build-OriginCategory -Origin $Origin -Group $Group -PngPath $PngPath -TifPath $TifPath
            $Results.Add($Result) | Out-Null
            $OriginFolders.Add($Result.OriginFolder) | Out-Null

            $LogLines.Add("origin group: $($Result.GroupKey)") | Out-Null
            $LogLines.Add("origin folder: $($Result.OriginFolder)") | Out-Null
            $LogLines.Add("origin stock solution: $($Result.StockSolution.CsvFile.Name)") | Out-Null
            $LogLines.Add("origin stock included: $($Result.StockIncluded)") | Out-Null
            $LogLines.Add("origin stock first: $($Result.StockFirst)") | Out-Null
            $LogLines.Add("origin import counts: $(($Result.Series | ForEach-Object { '{0}: A={1}, B={2}' -f $_.Record.CsvFile.Name, $_.ACount, $_.BCount }) -join '; ')") | Out-Null
            $LogLines.Add("origin plot count: $($Result.PlotCount) / expected count: $($Result.ExpectedPlotCount)") | Out-Null
            $LogLines.Add("origin plot names: $(($Result.PlotNames) -join ', ')") | Out-Null
            $LogLines.Add("origin legends: $(($Result.Series | ForEach-Object { $_.Legend }) -join ', ')") | Out-Null
            $LogLines.Add("GPC graph font normalization: sample=$($Result.Sample), graph=$($Result.GraphName), times_new_roman=$($Result.TimesNewRomanApplied), font_size_preserved=$($Result.FontSizePreserved)") | Out-Null
            $LogLines.Add("png: $($Result.Png)") | Out-Null
            $LogLines.Add("tif: $($Result.Tif)") | Out-Null
        }

        $C0ComparisonResults.Add([pscustomobject]@{
            Sample = $SampleGroup.Sample
            C0File = if ($null -ne $C0Record) { $C0Record.CsvFile.Name } else { "" }
            C0HeightSum = if ($null -ne $C0Record) { $C0Record.HeightSum } else { $null }
            Csv = $C0CsvPath
            Xlsx = $C0XlsxPath
            XlsxCreated = $C0XlsxCreated
            TimeSecondsCsv = $TimeSecondsPercentCsvPath
            TimeSecondsXlsx = $TimeSecondsPercentXlsxPath
            TimeSecondsXlsxCreated = $TimeSecondsPercentXlsxCreated
            TimeSecondsRows = $TimeSecondsPercentRows
            CTPsCsv = $CTPsCsvPath
            CTPureCsv = $CTPureCsvPath
            CTPsRows = $CTPsRows
            CTPureRows = $CTPureRows
        }) | Out-Null
        $LogLines.Add("sample opju: sample=$($SampleGroup.Sample), opju=$SampleOpjuPath") | Out-Null

        if ([string]::IsNullOrWhiteSpace($TimeSecondsPercentCsvPath) -or -not (Test-Path -LiteralPath $TimeSecondsPercentCsvPath)) {
            throw "Cannot build C-T graph for sample $($SampleGroup.Sample): time_seconds_percent CSV was not created."
        }
        $CTFigureDir = Join-Path (Join-Path $ExportFiguresDir $SafeSample) "C-T"
        New-Directory -Path $CTFigureDir
        $CTPngPath = Get-UniquePath -Directory $CTFigureDir -Stem ("{0}_C-T" -f $SafeSample) -Suffix ".png"
        $CTTifPath = Get-UniquePath -Directory $CTFigureDir -Stem ("{0}_C-T" -f $SafeSample) -Suffix ".tif"
        if ([string]::IsNullOrWhiteSpace($CTPsCsvPath) -or -not (Test-Path -LiteralPath $CTPsCsvPath)) {
            throw "Cannot build C-T graph for sample $($SampleGroup.Sample): C-T PS CSV was not created."
        }
        if ([string]::IsNullOrWhiteSpace($CTPureCsvPath) -or -not (Test-Path -LiteralPath $CTPureCsvPath)) {
            throw "Cannot build C-T graph for sample $($SampleGroup.Sample): C-T Pure CSV was not created."
        }
        $CTResult = Add-OriginCTGraphToGpcProject -Origin $Origin -Sample $SampleGroup.Sample -PsCsv $CTPsCsvPath -PureCsv $CTPureCsvPath -PngPath $CTPngPath -TifPath $CTTifPath
        $CTResults.Add($CTResult) | Out-Null
        $OriginFolders.Add("Total") | Out-Null
        Assert-ToolPath -Path $SampleOpjuPath
        $Origin.Save($SampleOpjuPath) | Out-Null
        $SampleGraphResults = @($Results | Where-Object { $_.Sample -eq $SampleGroup.Sample })
        $SampleProjectResults.Add([pscustomobject]@{ Sample = $SampleGroup.Sample; Opju = $SampleOpjuPath; OriginFolders = $OriginFolders.ToArray(); GraphPages = @($SampleGraphResults | ForEach-Object { $_.GraphName }) + @($CTResult.GraphName); GraphFontResults = $SampleGraphResults }) | Out-Null
        $LogLines.Add("sample opju folders: sample=$($SampleGroup.Sample), folders=$(($OriginFolders.ToArray()) -join ', ')") | Out-Null
        $LogLines.Add("C-T graph sample: $($SampleGroup.Sample)") | Out-Null
        $LogLines.Add("C-T project folder: $($CTResult.ProjectFolder)") | Out-Null
        $LogLines.Add("C-T PS workbook: $($CTResult.PsBookName), csv=$($CTResult.PsCsv), A=$($CTResult.PsACount), B=$($CTResult.PsBCount)") | Out-Null
        $LogLines.Add("C-T Pure workbook: $($CTResult.PureBookName), csv=$($CTResult.PureCsv), A=$($CTResult.PureACount), B=$($CTResult.PureBCount)") | Out-Null
        $LogLines.Add("C-T template used: $($CTResult.Template)") | Out-Null
        $LogLines.Add("C-T plot count: $($CTResult.PlotCount), plot names=$(($CTResult.PlotNames) -join ', ')") | Out-Null
        $LogLines.Add("C-T Times New Roman applied: $($CTResult.TimesNewRomanApplied)") | Out-Null
        $LogLines.Add("C-T font size preserved: $($CTResult.FontSizePreserved)") | Out-Null
        $LogLines.Add("C-T x axis: from=$($CTResult.XFrom), to=$($CTResult.XTo), major_step=$($CTResult.XStep)") | Out-Null
        $LogLines.Add("C-T y axis: from=$($CTResult.YFrom), to=$($CTResult.YTo), major_step=$($CTResult.YStep)") | Out-Null
        $LogLines.Add("Integrated C-T into GPC project = True") | Out-Null
        $LogLines.Add("GPC OPJU path: $SampleOpjuPath") | Out-Null
        $LogLines.Add("Total folder created = True") | Out-Null
        $LogLines.Add("Total\\PS workbook rows: $($CTResult.PsRowCount)") | Out-Null
        $LogLines.Add("Total\\Pure workbook rows: $($CTResult.PureRowCount)") | Out-Null
        $LogLines.Add("Total\\C-T graph created = True") | Out-Null
        $LogLines.Add("C-T png: $($CTResult.Png)") | Out-Null
        $LogLines.Add("C-T tif: $($CTResult.Tif)") | Out-Null
        $LogLines.Add("Separate C-T OPJU generated = False") | Out-Null
    }
}
catch {
    $Failures.Add("Origin: $($_.Exception.Message)") | Out-Null
    $LogLines.Add("failure: $($_.Exception.Message)") | Out-Null
    [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
    throw
}
finally {
    if ($Origin -ne $null) { $Origin.Exit() | Out-Null }
}

$GeneratedOpju = @(Get-ChildItem -LiteralPath $OriginProjectDir -Recurse -Filter "*_GPC.opju" -ErrorAction SilentlyContinue)
$GeneratedCTOpju = @(Get-ChildItem -LiteralPath $OriginProjectDir -Recurse -Filter "*_C-T.opju" -ErrorAction SilentlyContinue)
$GeneratedPng = @(Get-ChildItem -LiteralPath $ExportFiguresDir -Recurse -Filter "*.png" -ErrorAction SilentlyContinue)
$GeneratedTif = @(Get-ChildItem -LiteralPath $ExportFiguresDir -Recurse -Filter "*.tif" -ErrorAction SilentlyContinue)
$SummaryCsvExists = Test-Path -LiteralPath $SummaryCsvPath
$SummaryXlsxExists = Test-Path -LiteralPath $SummaryXlsxPath
if ($GeneratedOpju.Count -lt 1 -or $GeneratedPng.Count -lt 1 -or $GeneratedTif.Count -lt 1 -or -not $SummaryCsvExists) {
    $Message = "ERROR: No Origin project, exported figures, or height summary were generated. opju=$($GeneratedOpju.Count), png=$($GeneratedPng.Count), tif=$($GeneratedTif.Count), summary_csv=$SummaryCsvExists"
    $LogLines.Add($Message) | Out-Null
    [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
    throw $Message
}
if ($GeneratedCTOpju.Count -gt 0) {
    $Message = "ERROR: C-T OPJU should not be generated separately. C-T must be integrated into <sample>_GPC.opju under Total folder."
    $LogLines.Add($Message) | Out-Null
    [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
    throw $Message
}
foreach ($Project in $SampleProjectResults) {
    foreach ($Required in @("Ps", "Pure")) {
        $SampleCategories = @($Results | Where-Object { $_.Sample -eq $Project.Sample } | Select-Object -ExpandProperty OriginFolder)
        if (($SampleCategories -contains $Required) -eq $false -and (@($Records | Where-Object { $_.Sample -eq $Project.Sample -and $_.Category -ieq $Required }).Count -gt 0)) {
            $Message = "ERROR: Expected Origin folder $Required for sample $($Project.Sample), but it was not created."
            $LogLines.Add($Message) | Out-Null
            [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
            throw $Message
        }
    }
}
foreach ($Project in $SampleProjectResults) {
    $Comparison = $C0ComparisonResults | Where-Object { $_.Sample -eq $Project.Sample } | Select-Object -First 1
    if ($null -eq $Comparison -or [string]::IsNullOrWhiteSpace($Comparison.Csv) -or -not (Test-Path -LiteralPath $Comparison.Csv)) {
        $Message = "ERROR: Missing C0 comparison CSV for sample $($Project.Sample)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    if ((Split-Path -Parent $Comparison.Csv) -ne (Split-Path -Parent $Project.Opju)) {
        $Message = "ERROR: C0 comparison CSV is not in the same folder as OPJU for sample $($Project.Sample)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    $Header = (Get-Content -LiteralPath $Comparison.Csv -TotalCount 1)
    foreach ($RequiredColumn in @("C0_Height_Sum", "Difference_vs_C0", "Ratio_vs_C0", "Percent_vs_C0")) {
        if ($Header -notmatch [regex]::Escape($RequiredColumn)) {
            $Message = "ERROR: C0 comparison CSV for sample $($Project.Sample) does not contain required column $RequiredColumn"
            $LogLines.Add($Message) | Out-Null
            [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
            throw $Message
        }
    }
    $LogLines.Add("C0 self check: sample=$($Project.Sample), csv=$($Comparison.Csv), same_folder_as_opju=True, xlsx_created=$($Comparison.XlsxCreated)") | Out-Null

    if ([string]::IsNullOrWhiteSpace($Comparison.TimeSecondsCsv) -or -not (Test-Path -LiteralPath $Comparison.TimeSecondsCsv)) {
        $Message = "ERROR: Missing time_seconds_percent CSV for sample $($Project.Sample)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    if ((Split-Path -Parent $Comparison.TimeSecondsCsv) -ne (Split-Path -Parent $Project.Opju)) {
        $Message = "ERROR: time_seconds_percent CSV is not in the same folder as OPJU for sample $($Project.Sample)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    $TimeRows = @(Import-Csv -LiteralPath $Comparison.TimeSecondsCsv)
    $TimeHeader = (Get-Content -LiteralPath $Comparison.TimeSecondsCsv -TotalCount 1)
    $TimeHeaderColumns = @(($TimeHeader -replace '"', '').Split(","))
    if ($TimeHeaderColumns.Count -ne 2 -or $TimeHeaderColumns[0] -ne "Time_s" -or $TimeHeaderColumns[1] -ne "Percent_decimal") {
        $Message = "ERROR: time_seconds_percent CSV for sample $($Project.Sample) must contain exactly Time_s and Percent_decimal columns"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    foreach ($TimeRow in $TimeRows) {
        $ParsedTime = 0.0
        $ParsedPercent = 0.0
        if (-not [double]::TryParse([string]$TimeRow.Time_s, [ref]$ParsedTime) -or -not [double]::TryParse([string]$TimeRow.Percent_decimal, [ref]$ParsedPercent)) {
            $Message = "ERROR: time_seconds_percent CSV for sample $($Project.Sample) contains non-numeric values"
            $LogLines.Add($Message) | Out-Null
            [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
            throw $Message
        }
        if ($ParsedPercent -gt 10) {
            $LogLines.Add("time_seconds_percent self check warning: sample=$($Project.Sample), Percent_decimal=$ParsedPercent is greater than 10; confirm it is a ratio, not percent") | Out-Null
        }
    }
    $RowsAtZero = @($TimeRows | Where-Object { [double]$_.Time_s -eq 0 })
    if ($RowsAtZero.Count -gt 1) {
        $Message = "ERROR: time_seconds_percent CSV for sample $($Project.Sample) contains duplicate 0 second Stock Solution rows"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    $OriginalComparisonRows = @(Import-Csv -LiteralPath $Comparison.Csv)
    if (@($OriginalComparisonRows | Where-Object { [double]$_.Time_h -eq 2 }).Count -gt 0 -and @($TimeRows | Where-Object { [double]$_.Time_s -eq 7200 }).Count -lt 1) {
        $Message = "ERROR: time_seconds_percent CSV for sample $($Project.Sample) is missing 7200 seconds for 2 h"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    $LogLines.Add("time_seconds_percent self check: sample=$($Project.Sample), csv=$($Comparison.TimeSecondsCsv), same_folder_as_opju=True, columns=Time_s|Percent_decimal, rows=$($TimeRows.Count), xlsx_created=$($Comparison.TimeSecondsXlsxCreated), ps_and_pure_merged=True") | Out-Null

    $CTResult = $CTResults | Where-Object { $_.Sample -eq $Project.Sample } | Select-Object -First 1
    if ($null -eq $CTResult) {
        $Message = "ERROR: Missing C-T result for sample $($Project.Sample)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    $SeparateCtOpjus = @(Get-ChildItem -LiteralPath (Split-Path -Parent $Project.Opju) -File -Filter ("{0}_C-T*.opju" -f (Convert-ToSafePathPart -Text $Project.Sample)) -ErrorAction SilentlyContinue)
    if ($SeparateCtOpjus.Count -gt 0) {
        $Message = "ERROR: C-T OPJU should not be generated separately. C-T must be integrated into $($Project.Sample)_GPC.opju under Total folder."
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    if (-not (Test-Path -LiteralPath $CTResult.Png)) {
        $Message = "ERROR: Missing C-T PNG for sample $($Project.Sample): $($CTResult.Png)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    if (-not (Test-Path -LiteralPath $CTResult.Tif)) {
        $Message = "ERROR: Missing C-T TIFF for sample $($Project.Sample): $($CTResult.Tif)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    if ($CTResult.Template -ne $CTTemplatePath) {
        $Message = "ERROR: C-T graph used wrong template for sample $($Project.Sample): $($CTResult.Template)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    if ($CTResult.Template -eq $TemplatePath) {
        $Message = "ERROR: C-T graph incorrectly used GPC template for sample $($Project.Sample)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    foreach ($CTCsv in @($CTResult.PsCsv, $CTResult.PureCsv)) {
        if ([string]::IsNullOrWhiteSpace($CTCsv) -or -not (Test-Path -LiteralPath $CTCsv)) {
            $Message = "ERROR: Missing split C-T CSV for sample $($Project.Sample): $CTCsv"
            $LogLines.Add($Message) | Out-Null
            [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
            throw $Message
        }
        $CTHeader = Get-Content -LiteralPath $CTCsv -TotalCount 1
        $CTColumns = @(($CTHeader -replace '"', '').Split(","))
        if ($CTColumns.Count -ne 2 -or $CTColumns[0] -ne "Time_s" -or $CTColumns[1] -ne "Percent_decimal") {
            $Message = "ERROR: Split C-T CSV must contain exactly Time_s and Percent_decimal columns: $CTCsv"
            $LogLines.Add($Message) | Out-Null
            [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
            throw $Message
        }
    }
    if ($CTResult.PsBookName -ne "PS" -or $CTResult.PureBookName -ne "Pure") {
        $Message = "ERROR: C-T workbooks must be named PS and Pure for sample $($Project.Sample). Got PS=$($CTResult.PsBookName), Pure=$($CTResult.PureBookName)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    if ($CTResult.PsBCount -eq 0 -or $CTResult.PureBCount -eq 0) {
        $Message = "ERROR: C-T PS/Pure workbooks must both have non-empty B columns for sample $($Project.Sample). PS B=$($CTResult.PsBCount), Pure B=$($CTResult.PureBCount)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    $PsCsvRows = @(Import-Csv -LiteralPath $CTResult.PsCsv)
    $PureCsvRows = @(Import-Csv -LiteralPath $CTResult.PureCsv)
    if ($PsCsvRows.Count -eq 0 -or [double]$PsCsvRows[0].Time_s -ne 0 -or [double]$PsCsvRows[0].Percent_decimal -ne 1) {
        $Message = "ERROR: C-T PS CSV first data row must be Time_s=0 and Percent_decimal=1 for sample $($Project.Sample)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    if ($PureCsvRows.Count -eq 0 -or [double]$PureCsvRows[0].Time_s -ne 0 -or [double]$PureCsvRows[0].Percent_decimal -ne 0) {
        $Message = "ERROR: C-T Pure CSV first data row must be Time_s=0 and Percent_decimal=0 for sample $($Project.Sample)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    $PureSourceTimes = @(
        $OriginalComparisonRows |
            Where-Object { $_.Category -ieq "pure" -and [double]$_.Time_h -gt 0 } |
            Sort-Object @{ Expression = { [double]$_.Time_h }; Descending = $false } |
            ForEach-Object { [double]$_.Time_h }
    )
    if ($PureSourceTimes.Count -gt 0 -and $PureCsvRows.Count -le 1) {
        $Message = "ERROR: C-T Pure CSV for sample $($Project.Sample) has only baseline row although pure time points exist: $(($PureSourceTimes) -join ', ')"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    $PureCsvTimes = @($PureCsvRows | Sort-Object @{ Expression = { [double]$_.Time_s }; Descending = $false } | ForEach-Object { [double]$_.Time_s })
    $PurePreview = @($PureCsvRows | Select-Object -First 10 | ForEach-Object { "{0},{1}" -f $_.Time_s, $_.Percent_decimal })
    $LogLines.Add("C-T Pure source Time_h: sample=$($Project.Sample), times=$(($PureSourceTimes) -join ', ')") | Out-Null
    $LogLines.Add("C-T Pure output Time_s: sample=$($Project.Sample), times=$(($PureCsvTimes) -join ', ')") | Out-Null
    $LogLines.Add("C-T Pure csv first 10 rows: sample=$($Project.Sample), rows=$(($PurePreview) -join '; ')") | Out-Null
    if ($CTResult.PureRowCount -ne $PureCsvRows.Count) {
        $Message = "ERROR: Origin Pure workbook row count does not match C-T Pure CSV for sample $($Project.Sample). Origin=$($CTResult.PureRowCount), CSV=$($PureCsvRows.Count)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    if ($PureSourceTimes.Count -gt 0 -and $CTResult.PureRowCount -le 1) {
        $Message = "ERROR: Origin Pure workbook has only one point although pure time points exist for sample $($Project.Sample)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    if ($CTResult.PsFirstX -ne 0 -or $CTResult.PsFirstY -ne 1) {
        $Message = "ERROR: Origin PS workbook first row must be Time_s=0 and Percent_decimal=1 for sample $($Project.Sample). Got $($CTResult.PsFirstX), $($CTResult.PsFirstY)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    if ($CTResult.PureFirstX -ne 0 -or $CTResult.PureFirstY -ne 0) {
        $Message = "ERROR: Origin Pure workbook first row must be Time_s=0 and Percent_decimal=0 for sample $($Project.Sample). Got $($CTResult.PureFirstX), $($CTResult.PureFirstY)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    if ($CTResult.PlotCount -ne 2) {
        $Message = "ERROR: C-T graph must have two curves for sample $($Project.Sample). Got $($CTResult.PlotCount)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    $PlotNames = @($CTResult.PlotNames)
    $HasPsPlot = @($PlotNames | Where-Object { $_ -match "^(?i:PS)(?:_B)?$" }).Count -gt 0
    $HasPurePlot = @($PlotNames | Where-Object { $_ -match "^(?i:Pure)(?:_B)?$" }).Count -gt 0
    if (-not $HasPsPlot -or -not $HasPurePlot) {
        $Message = "ERROR: C-T legend/plot names must include PS and Pure for sample $($Project.Sample). Got: $(($PlotNames) -join ', ')"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    $LogLines.Add("C-T Pure 0h check: sample=$($Project.Sample), csv=$($CTResult.PureCsv), before=1, after=0, origin_first_row=$($CTResult.PureFirstX),$($CTResult.PureFirstY)") | Out-Null
    $LogLines.Add("C-T PS 0h check: sample=$($Project.Sample), csv=$($CTResult.PsCsv), expected=1, origin_first_row=$($CTResult.PsFirstX),$($CTResult.PsFirstY)") | Out-Null
    $LogLines.Add("C-T formatting check: sample=$($Project.Sample), times_new_roman=$($CTResult.TimesNewRomanApplied), font_size_preserved=$($CTResult.FontSizePreserved), x_axis=$($CTResult.XFrom)..$($CTResult.XTo), x_major_step=$($CTResult.XStep), y_axis=$($CTResult.YFrom)..$($CTResult.YTo), y_major_step=$($CTResult.YStep)") | Out-Null
    if (@($Project.OriginFolders | Where-Object { $_ -eq "Total" }).Count -eq 0) {
        $Message = "ERROR: Total folder was not recorded for sample $($Project.Sample)"
        $LogLines.Add($Message) | Out-Null
        [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
        throw $Message
    }
    $LogLines.Add("C-T self check: sample=$($Project.Sample), project_folder=$($CTResult.ProjectFolder), integrated_into_gpc_project=$($CTResult.IntegratedIntoGpcProject), separate_ct_opju_generated=$($CTResult.SeparateCtOpjuGenerated), png=$($CTResult.Png), tif=$($CTResult.Tif), template=$($CTResult.Template), PS_workbook=True, Pure_workbook=True, plot_count=$($CTResult.PlotCount), legends=$(($PlotNames) -join ', ')") | Out-Null
}

$ArchiveInfo = Move-ProcessedTxtBySample -InputFiles $InputFileInfos.ToArray() -RunDate $RunDate -LogLines $LogLines
$ArchiveResults = @($ArchiveInfo.Results)
$ArchiveDirs = @($ArchiveInfo.ArchiveDirs)
$Unarchived = @($ArchiveResults | Where-Object { -not $_.Archived })
if ($Unarchived.Count -gt 0) {
    $Message = "ERROR: Some txt files could not be archived: $(($Unarchived | ForEach-Object { $_.File }) -join ', ')"
    $LogLines.Add($Message) | Out-Null
    [System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)
    throw $Message
}
$Residual = @(Get-ChildItem -LiteralPath $ActiveInputDir -File -Filter "*.txt" | Where-Object { ($InputFileInfos | ForEach-Object { $_.TxtFile.Name }) -contains $_.Name })
if ($Residual.Count -gt 0) {
    $LogLines.Add("archive warning: root input still contains processed txt: $(($Residual | ForEach-Object { $_.Name }) -join ', ')") | Out-Null
}
else {
    $LogLines.Add("archive check: root input contains no processed txt files") | Out-Null
}

$LogLines.Add("self check: gpc_opju=$($GeneratedOpju.Count), ct_opju=$($GeneratedCTOpju.Count), png=$($GeneratedPng.Count), tif=$($GeneratedTif.Count), summary_csv=$SummaryCsvExists, summary_xlsx=$SummaryXlsxExists, archive_dirs=$(($ArchiveDirs | ForEach-Object { $_.ArchiveDir }) -join ', ')") | Out-Null
if ($Failures.Count -gt 0) { $LogLines.Add("failures: $($Failures -join '; ')") | Out-Null } else { $LogLines.Add("failures: none") | Out-Null }
[System.IO.File]::WriteAllLines($LogPath, $LogLines, [System.Text.Encoding]::UTF8)

Write-Output "run folder: $RunDir"
Write-Output "txt files read: $($TxtFiles.Count)"
Write-Output "csv files generated: $($Records.Count)"
Write-Output "samples: $($Samples -join ', ')"
Write-Output "default sample name for unresolved files: $FallbackSampleName"
Write-Output "template files detected: $(($TemplateFiles | ForEach-Object { $_.FullName }) -join '; ')"
Write-Output "GPC template: $TemplatePath"
Write-Output "C-T template: $CTTemplatePath"
Write-Output "height summary csv: $SummaryCsvPath"
Write-Output "height summary xlsx: $(if ($SummaryXlsxExists) { $SummaryXlsxPath } else { 'not created' })"
foreach ($Project in $SampleProjectResults) {
    Write-Output "sample opju: $($Project.Opju)"
    Write-Output "origin folders: $(($Project.OriginFolders) -join ', ')"
}
foreach ($Comparison in $C0ComparisonResults) {
    Write-Output "C0 comparison sample: $($Comparison.Sample)"
    Write-Output "C0 file: $($Comparison.C0File)"
    Write-Output "C0 height sum: $($Comparison.C0HeightSum)"
    Write-Output "C0 comparison csv: $($Comparison.Csv)"
    Write-Output "C0 comparison xlsx: $(if ($Comparison.XlsxCreated) { $Comparison.Xlsx } else { 'not created' })"
    Write-Output "time seconds percent csv: $($Comparison.TimeSecondsCsv)"
    Write-Output "time seconds percent xlsx: $(if ($Comparison.TimeSecondsXlsxCreated) { $Comparison.TimeSecondsXlsx } else { 'not created' })"
}
foreach ($CTResult in $CTResults) {
    Write-Output "C-T sample: $($CTResult.Sample)"
    Write-Output "C-T project folder: $($CTResult.ProjectFolder)"
    Write-Output "C-T PS workbook: $($CTResult.PsBookName), rows=$($CTResult.PsRowCount), A=$($CTResult.PsACount), B=$($CTResult.PsBCount)"
    Write-Output "C-T Pure workbook: $($CTResult.PureBookName), rows=$($CTResult.PureRowCount), A=$($CTResult.PureACount), B=$($CTResult.PureBCount)"
    Write-Output "C-T PS first row: $($CTResult.PsFirstX), $($CTResult.PsFirstY)"
    Write-Output "C-T Pure first row: $($CTResult.PureFirstX), $($CTResult.PureFirstY)"
    Write-Output "C-T PS csv: $($CTResult.PsCsv)"
    Write-Output "C-T Pure csv: $($CTResult.PureCsv)"
    Write-Output "Integrated C-T into GPC project: $($CTResult.IntegratedIntoGpcProject)"
    Write-Output "C-T png: $($CTResult.Png)"
    Write-Output "C-T tif: $($CTResult.Tif)"
    Write-Output "C-T plot count: $($CTResult.PlotCount)"
    Write-Output "C-T legends: $(($CTResult.PlotNames) -join ', ')"
    Write-Output "C-T Times New Roman applied: $($CTResult.TimesNewRomanApplied)"
    Write-Output "C-T font size preserved: $($CTResult.FontSizePreserved)"
    Write-Output "C-T X axis: $($CTResult.XFrom) .. $($CTResult.XTo), major step = $($CTResult.XStep)"
    Write-Output "C-T Y axis: $($CTResult.YFrom) .. $($CTResult.YTo), major step = $($CTResult.YStep)"
    Write-Output "C-T PS data preview: $(($CTResult.PsPreviewRows | ForEach-Object { '{0},{1}' -f $_.X, $_.Y }) -join '; ')"
    Write-Output "C-T Pure data preview: $(($CTResult.PurePreviewRows | ForEach-Object { '{0},{1}' -f $_.X, $_.Y }) -join '; ')"
}
foreach ($Result in $Results) {
    Write-Output "group: $($Result.GroupKey)"
    Write-Output "curves: $(($Result.Series | ForEach-Object { $_.Legend }) -join ', ')"
    Write-Output "plot count: $($Result.PlotCount) / expected count: $($Result.ExpectedPlotCount)"
    Write-Output "png: $($Result.Png)"
    Write-Output "tif: $($Result.Tif)"
}
Write-Output "archived txt: True"
Write-Output "archive folders: $(($ArchiveDirs | ForEach-Object { $_.ArchiveDir }) -join ', ')"
Write-Output "self check: gpc_opju=$($GeneratedOpju.Count), separate_ct_opju=$($GeneratedCTOpju.Count), png=$($GeneratedPng.Count), tif=$($GeneratedTif.Count), summary_csv=$SummaryCsvExists, summary_xlsx=$SummaryXlsxExists"
Write-Output "log: $LogPath"
