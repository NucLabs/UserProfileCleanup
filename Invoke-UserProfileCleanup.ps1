function Invoke-UserProfileCleanup {
    <#
    .SYNOPSIS
        Removes old files from eligible user profile folders.

    .DESCRIPTION
        Cleans aged Downloads and Temp files while skipping profiles with an active
        or disconnected RDP session. Supports -WhatIf for safe previews.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$UsersRoot = 'C:\Users',
        [datetime]$Now = [datetime]::Now
    )

#Region Helper Functions
    function Get-UserSessions {
        <#
        .SYNOPSIS
            Retrieves local user sessions and their session IDs.

        .DESCRIPTION
            Parses the output of the Windows quser command into session objects.
        #>
        $sessions = quser 2>$null

        foreach ($line in @($sessions | Select-Object -Skip 1)) {
            $parts = ($line.Trim() -replace '^>', '') -split '\s+'
            if ($parts.Count -lt 2) {
                continue
            }

            $sessionIdIndex = 0
            while ($sessionIdIndex -lt $parts.Count -and $parts[$sessionIdIndex] -notmatch '^\d+$') {
                $sessionIdIndex++
            }

            if ($sessionIdIndex -eq 0 -or $sessionIdIndex -ge $parts.Count) {
                continue
            }

            $username = $parts[0]
            $sessionName = if ($sessionIdIndex -gt 1) { $parts[1] } else { 'N/A' }
            $state = if ($sessionIdIndex + 1 -lt $parts.Count) { $parts[$sessionIdIndex + 1] } else { '' }

            [PSCustomObject]@{
                UserName     = $username
                SessionState = if ($state -match '^(Disc|Disconnected)$') { 'Disconnected' } else { 'Connected' }
                SessionType  = $sessionName
                SessionId    = [int]$parts[$sessionIdIndex]
            }
        }
    }

    function Remove-OldFiles {
        <#
        .SYNOPSIS
            Removes files older than a cutoff while honoring filename exclusions.
        #>
        param(
            [string]$Path,
            [datetime]$Cutoff,
            [string[]]$ExcludedFileNames = @()
        )

        $result = [ordered]@{
            Path           = $Path
            Exists         = Test-Path -LiteralPath $Path -PathType Container
            CandidateCount = 0
            RemovedCount   = 0
            ErrorCount     = 0
            Errors         = [System.Collections.Generic.List[string]]::new()
        }

        if (-not $result.Exists) {
            return [PSCustomObject]$result
        }

        $files = @(Get-ChildItem -LiteralPath $Path -File -Force -Recurse -ErrorAction SilentlyContinue)
        foreach ($file in $files) {
            if ($ExcludedFileNames -contains $file.Name) {
                continue
            }

            if ($file.LastWriteTime -ge $Cutoff) {
                continue
            }

            $result.CandidateCount++
            if ($PSCmdlet.ShouldProcess($file.FullName, 'Remove old file')) {
                try {
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    $result.RemovedCount++
                }
                catch {
                    $result.ErrorCount++
                    $result.Errors.Add(('{0}: {1}' -f $file.FullName, $_.Exception.Message))
                }
            }
        }

        [PSCustomObject]$result
    }
#endRegion

    $downloadCutoff = $Now.AddDays(-60)
    $tempCutoff = $Now.AddHours(-48)
    $sessions = @(Get-UserSessions)
    $rdpProfileNames = @($sessions | Where-Object {
            $_.SessionState -eq 'Disconnected' -or
            ($_.SessionState -eq 'Connected' -and $_.SessionType -match '^rdp-tcp')
        } | ForEach-Object { $_.UserName })

    $usersRootItem = Get-Item -LiteralPath $UsersRoot -Force -ErrorAction Stop
    $rootLooksLikeProfile = (Test-Path -LiteralPath (Join-Path $usersRootItem.FullName 'Downloads') -PathType Container) -or
    (Test-Path -LiteralPath (Join-Path $usersRootItem.FullName 'AppData') -PathType Container)

    if ($rootLooksLikeProfile) {
        $profiles = @($usersRootItem)
    }
    else {
        $profiles = @(Get-ChildItem -LiteralPath $usersRootItem.FullName -Directory -Force -ErrorAction Stop | Where-Object {
                $_.Name -match '^(?i:PRD|CNP|DEV|ISB|MKP|MK1|OHP|POL|ONT|RDO|SCV|SWH|ISI)'
            })
    }

    foreach ($prfl in $profiles) {
        if ($rdpProfileNames -contains $prfl.Name) {
            Write-Verbose ('Skipping profile {0}: user has an active or disconnected RDP session.' -f $prfl.Name)
            continue
        }

        Remove-OldFiles -Path (Join-Path $prfl.FullName 'Downloads') -Cutoff $downloadCutoff -ExcludedFileNames @('desktop.ini')
        Remove-OldFiles -Path (Join-Path $prfl.FullName 'AppData\Local\Temp') -Cutoff $tempCutoff
    }
}
