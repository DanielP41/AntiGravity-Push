[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Message,

    [Parameter(Mandatory = $false)]
    [string]$Title = "Antigravity Push",

    [Parameter(Mandatory = $false)]
    [string]$Keys,

    [Parameter(Mandatory = $false)]
    [int]$Priority = 3,

    [Parameter(Mandatory = $false)]
    [switch]$Listen
)

$ErrorActionPreference = "Continue"
$Host.UI.RawUI.WindowTitle = "Antigravity Push"

$script:ConfigPath = "$PSScriptRoot\config.json"
$script:HistoryPath = "$PSScriptRoot\history.json"
$script:Config = $null
$script:History = @()

function Load-Config {
    if (Test-Path $script:ConfigPath) {
        $script:Config = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
        return $true
    }
    return $false
}

function Save-Config {
    $script:Config | ConvertTo-Json | Set-Content $script:ConfigPath -Encoding UTF8
}

function Load-History {
    if (Test-Path $script:HistoryPath) {
        $script:History = Get-Content $script:HistoryPath -Raw | ConvertFrom-Json
        if ($script:History -isnot [array]) { $script:History = @($script:History) }
    }
    else {
        $script:History = @()
    }
}

function Save-History {
    $script:History | ConvertTo-Json -Depth 10 | Set-Content $script:HistoryPath -Encoding UTF8
}

function Add-HistoryEntry {
    param($Msg, $Title, $Keys)
    Load-History
    $id = [guid]::NewGuid().ToString()
    $entry = [PSCustomObject]@{
        id        = $id
        timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        title     = $Title
        message   = $Msg
        keys      = $Keys
        response  = $null
    }
    $script:History = @($entry) + $script:History
    if ($script:History.Count -gt 15) { $script:History = $script:History[0..14] }
    Save-History
    return $id
}

function Update-HistoryEntry {
    param($Id, $Response)
    Load-History
    $found = $false
    foreach ($entry in $script:History) {
        if ($entry.id -eq $Id) {
            $entry.response = $Response
            $found = $true
            break
        }
    }
    if ($found) { Save-History }
}

function Show-History {
    Load-History
    if ($script:History.Count -eq 0) {
        Write-Host "  No notifications sent yet." -ForegroundColor DarkGray
        return
    }

    Write-Host "  LAST 15 NOTIFICATIONS:" -ForegroundColor Yellow
    Write-Host "  -------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  TIMESTAMP           MESSAGE                   RESPONSE" -ForegroundColor Gray
    Write-Host "  -------------------------------------------------------" -ForegroundColor DarkGray
    
    foreach ($h in $script:History) {
        $ts = $h.timestamp
        $msg = if ($h.message.Length -gt 25) { $h.message.Substring(0, 22) + "..." } else { $h.message.PadRight(25) }
        $resp = if ($h.response) { $h.response } else { "-" }
        
        $color = if ($h.response) { "Green" } else { "DarkGray" }
        Write-Host "  $ts  " -NoNewline -ForegroundColor Gray
        Write-Host "$msg " -NoNewline -ForegroundColor White
        Write-Host "$resp" -ForegroundColor $color
    }
}

Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

function Send-Keystroke {
    param([string]$Keys)

    $terminalNames = @("WindowsTerminal", "powershell", "pwsh", "cmd")
    $proc = $null
    foreach ($name in $terminalNames) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ($p.MainWindowHandle -ne 0 -and $p.MainWindowTitle -and $p.MainWindowTitle -ne "Antigravity Push") {
                $proc = $p; break
            }
        }
        if ($proc) { break }
    }

    if ($proc) {
        try { [Microsoft.VisualBasic.Interaction]::AppActivate($proc.Id); Start-Sleep -Milliseconds 200 } catch { }
    }

    # Handle special keys or raw text
    $sendKeys = $Keys
    if ($Keys.Length -gt 1 -and $Keys -notmatch "^\{.+\}$") {
        # Treat as raw text, escape special characters for SendKeys
        $sendKeys = $Keys -replace "\+", "{+}" -replace "\^", "{^}" -replace "%", "{%}" -replace "~", "{~}" -replace "\(", "{(}" -replace "\)", "{)}" -replace "\[", "{[}" -replace "\]", "{]}" -replace "\{", "{{}" -replace "\}", "{}}"
        $sendKeys = $sendKeys + "{ENTER}"
    }
    else {
        $sendKeys = $Keys -replace "\\n", "{ENTER}" -replace "`n", "{ENTER}"
        if ([string]::IsNullOrWhiteSpace($sendKeys)) { $sendKeys = "{ENTER}" }
        if ($sendKeys -notmatch "\{ENTER\}$" -and $sendKeys.Length -le 2) { $sendKeys = $sendKeys + "{ENTER}" }
    }

    try {
        $wshell = New-Object -ComObject WScript.Shell
        $wshell.SendKeys($sendKeys)
        return $true
    }
    catch {
        try { [System.Windows.Forms.SendKeys]::SendWait($sendKeys); return $true } catch { return $false }
    }
}

function Start-Listener {
    param([switch]$SingleResponse, [string]$HistoryId)

    $server = $script:Config.ntfy.server
    $topic = $script:Config.ntfy.topic
    $responseTopic = "$topic-response"
    $sseUrl = "$server/$responseTopic/sse"
    $waitingForInput = $false

    while ($true) {
        try {
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add("Accept", "text/event-stream")
            $stream = $webClient.OpenRead($sseUrl)
            $reader = New-Object System.IO.StreamReader($stream)

            Write-Host "  CONNECTED!" -ForegroundColor Green
            if ($waitingForInput) {
                Write-Host "  WAITING FOR TEXT INPUT (type in ntfy app)..." -ForegroundColor Magenta
            }
            else {
                Write-Host "  Waiting for phone responses..." -ForegroundColor Gray
            }
            Write-Host "  Close this window to stop." -ForegroundColor DarkGray
            Write-Host ""

            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($line -match "^data:\s*(.+)$") {
                    $jsonData = $Matches[1]
                    try {
                        $event = $jsonData | ConvertFrom-Json
                        if ($event.event -eq "message" -and $event.message) {
                            $key = $null
                            $isTest = $false
                            $isRawText = $false

                            try {
                                # Try to parse as JSON action response
                                $actionData = $event.message | ConvertFrom-Json
                                $key = $actionData.key
                                if ($actionData.test) { $isTest = $true }
                            }
                            catch {
                                # Use raw message if waiting for input
                                if ($waitingForInput) {
                                    $key = $event.message
                                    $isRawText = $true
                                }
                            }

                            if ($key) {
                                $timestamp = Get-Date -Format "HH:mm:ss"

                                if ($key -eq "__INPUT__") {
                                    Write-Host "  [$timestamp] Input mode requested..." -ForegroundColor Magenta
                                    $waitingForInput = $true
                                    # Send feedback notification
                                    Send-Notification -Msg "Escribe tu texto y envialo aqui..." -Title "Esperando Texto" -Prio 2 -NoHistory
                                    continue
                                }

                                if ($waitingForInput -and $isRawText) {
                                    Write-Host "  [$timestamp] Received text: '$key'" -ForegroundColor Magenta
                                    $waitingForInput = $false
                                }
                                elseif ($waitingForInput -and -not $isRawText) {
                                    # Received a button press while waiting for text, cancel input mode
                                    $waitingForInput = $false
                                }
                                
                                Write-Host "  [$timestamp] Response: $key" -ForegroundColor Yellow
                                
                                # Update History
                                if ($HistoryId) { Update-HistoryEntry -Id $HistoryId -Response $key }
                                else {
                                    Load-History
                                    foreach ($h in $script:History) {
                                        if ($null -eq $h.response) {
                                            $h.response = $key
                                            Save-History
                                            break
                                        }
                                    }
                                }

                                if (-not $isTest) {
                                    $result = Send-Keystroke -Keys $key
                                    if ($result) { 
                                        Write-Host "  [$timestamp] Keystroke sent!" -ForegroundColor Green 
                                        if ($SingleResponse) {
                                            $reader.Close(); $stream.Close()
                                            return
                                        }
                                    }
                                    else { Write-Host "  [$timestamp] Failed!" -ForegroundColor Red }
                                }
                                else {
                                    Write-Host "  [$timestamp] Test - no keystroke" -ForegroundColor Cyan
                                }
                            }
                        }
                    }
                    catch { }
                }
            }
            $reader.Close(); $stream.Close()
        }
        catch {
            Write-Host "  Connection lost. Reconnecting..." -ForegroundColor Red
        }
        Start-Sleep -Seconds 5
    }
}

function Send-Notification {
    param(
        [string]$Msg,
        [string]$Title = "Antigravity Push",
        [string[]]$KeyActions,
        [int]$Prio = 3,
        [switch]$NoHistory
    )

    $server = $script:Config.ntfy.server
    $topic = $script:Config.ntfy.topic

    $actions = @()
    if ($KeyActions) {
        foreach ($ka in $KeyActions) {
            $label = $ka.Trim()
            $key = $label.ToLower().Substring(0, 1) # Default to first letter if not specified
            if ($label -match "\[(.+)\]") {
                $key = $Matches[1]
                $label = $label -replace "\[.+\]", ""
            }
            
            if ($key -eq "input") { $key = "__INPUT__" }

            $actions += @{ action = "http"; label = $label; url = "$server/$topic-response"; method = "POST"; body = "@{key='$key'}" -replace "'", '"' }
        }
    }

    $notification = @{
        topic    = $topic
        title    = $Title
        message  = $Msg
        priority = $Prio
        tags     = @("robot")
        actions  = $actions
    }

    try {
        $json = $notification | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri $server -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -ContentType "application/json; charset=utf-8" | Out-Null
        Write-Host "  Sent! Check your phone." -ForegroundColor Green
        
        if (-not $NoHistory) {
            $histId = Add-HistoryEntry -Msg $Msg -Title $Title -Keys ($keyList -join ", ")
            return $histId
        }
        return $true
    }
    catch {
        Write-Host "  Failed to send notification: $_" -ForegroundColor Red
        return $false
    }
}

function Send-TestNotification {
    Send-Notification -Msg "If you see this, it works!" -Title "Antigravity Push - Test" -KeyActions @("Yes [y]", "No [n]")
}

function Show-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  =======================================================" -ForegroundColor Cyan
    Write-Host "     _    _   _ _____ ___ ____ ____      _ __     __ ___ _____ __   __ " -ForegroundColor Cyan
    Write-Host "    / \  | \ | |_   _|_ _/ ___|  _ \    / \\ \   / /|_ _|_   _| \ \ / / " -ForegroundColor Cyan
    Write-Host "   / _ \ |  \| | | |  | | |  _| |_) |  / _ \\ \ / /  | |  | |    \ V /  " -ForegroundColor Cyan
    Write-Host "  / ___ \| |\  | | |  | | |_| |  _ <  / ___ \\ V /   | |  | |     | |   " -ForegroundColor Cyan
    Write-Host " /_/   \_\_| \_| |_|  |__\____|_| \_\/_/   \_\\_/    |_|  |_|     |_|   " -ForegroundColor Cyan
    Write-Host "  =======================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Menu {
    Show-Header

    Write-Host "  Topic:  $($script:Config.ntfy.topic)" -ForegroundColor White
    Write-Host "  Server: $($script:Config.ntfy.server)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  -------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    
    Show-History
    
    Write-Host ""
    Write-Host "  -------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [1] Activate Antigravity Push" -ForegroundColor Green
    Write-Host "  [2] Send test notification" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [3] Change topic" -ForegroundColor Gray
    Write-Host "  [4] Change server" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [Q] Quit" -ForegroundColor Red
    Write-Host ""
    Write-Host "  -------------------------------------------------------" -ForegroundColor DarkGray
}

function Show-Setup {
    Show-Header
    Write-Host "  INITIAL SETUP" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  You need a unique topic name." -ForegroundColor White
    Write-Host "  Choose something hard to guess, e.g.: antigravity-x7k9" -ForegroundColor Gray
    Write-Host ""

    $topic = Read-Host "  Enter topic name"
    if (-not $topic) {
        Write-Host "  Topic required!" -ForegroundColor Red
        Start-Sleep -Seconds 2
        Show-Setup
        return
    }

    $script:Config = [PSCustomObject]@{
        ntfy = [PSCustomObject]@{
            server = "https://ntfy.sh"
            topic  = $topic
        }
    }
    Save-Config

    Write-Host ""
    Write-Host "  Saved!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  IMPORTANT: Install the ntfy app on your phone" -ForegroundColor Yellow
    Write-Host "  and subscribe to topic: $topic" -ForegroundColor White
    Write-Host ""
    Write-Host "  iOS:     https://apps.apple.com/app/ntfy/id1625396347" -ForegroundColor Gray
    Write-Host "  Android: https://play.google.com/store/apps/details?id=io.heckel.ntfy" -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Press Enter to continue"
}

function Main-Loop {
    while ($true) {
        Show-Menu
        $choice = Read-Host "  Choice"

        switch ($choice.ToUpper()) {
            "1" {
                Show-Header
                Write-Host "  ACTIVATING ANTIGRAVITY PUSH" -ForegroundColor Green
                Write-Host ""
                Write-Host "  Starting listener..." -ForegroundColor Yellow
                Start-Listener
            }
            "2" {
                Write-Host ""
                Send-TestNotification
                Write-Host ""
                Read-Host "  Press Enter"
            }
            "3" {
                Write-Host ""
                $newTopic = Read-Host "  New topic name"
                if ($newTopic) {
                    $script:Config.ntfy.topic = $newTopic
                    Save-Config
                    Write-Host "  Topic changed!" -ForegroundColor Green
                }
                Start-Sleep -Seconds 1
            }
            "4" {
                Write-Host ""
                Write-Host "  Current: $($script:Config.ntfy.server)" -ForegroundColor Gray
                $newServer = Read-Host "  New server URL"
                if ($newServer) {
                    $script:Config.ntfy.server = $newServer
                    Save-Config
                    Write-Host "  Server changed!" -ForegroundColor Green
                }
                Start-Sleep -Seconds 1
            }
            "Q" {
                Write-Host ""
                Write-Host "  Goodbye!" -ForegroundColor Cyan
                Write-Host ""
                exit 0
            }
        }
    }
}

# --- ENTRY POINT ---

if (-not (Load-Config)) {
    Show-Setup
}

if ($Message) {
    # CLI Mode
    $keyList = if ($Keys) { $Keys -split "," } else { @() }
    $histId = Send-Notification -Msg $Message -Title $Title -KeyActions $keyList -Prio $Priority
    
    if ($Listen) {
        Write-Host ""
        Write-Host "  Auto-starting listener (Waiting for single response)..." -ForegroundColor Yellow
        Start-Listener -SingleResponse -HistoryId $histId
    }
    exit 0
}

Main-Loop
