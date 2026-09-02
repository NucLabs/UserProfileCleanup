function Invoke-UserProfileCleanup {
    <#
    .SYNOPSIS
        Removes old files from eligible user profile folders.

    .DESCRIPTION
        Cleans aged Downloads and Temp files while preserving active session folders
        and Downloads desktop.ini files. Supports -WhatIf for safe previews.
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

    function Get-SessionIdsForProfile {
        <#
        .SYNOPSIS
            Gets connected session IDs for a user profile.
        #>
        param([string]$ProfileName)

        @($sessions | Where-Object {
                $_.UserName -ieq $ProfileName -and
                $_.SessionState -eq 'Connected' -and
                $null -ne $_.SessionId
            } | ForEach-Object { [string]$_.SessionId })
    }

    function Remove-OldFiles {
        <#
        .SYNOPSIS
            Removes files older than a cutoff while honoring exclusions.
        #>
        param(
            [string]$Path,
            [datetime]$Cutoff,
            [string[]]$ProtectedPaths = @(),
            [string[]]$ExcludedFileNames = @()
        )

        $result = [ordered]@{
            Path           = $Path
            Exists         = Test-Path -LiteralPath $Path -PathType Container
            CandidateCount = 0
            RemovedCount   = 0
            ProtectedCount = 0
            ErrorCount     = 0
            Errors         = [System.Collections.Generic.List[string]]::new()
        }

        if (-not $result.Exists) {
            return [PSCustomObject]$result
        }

        $normalizedProtectedPaths = @($ProtectedPaths | ForEach-Object {
                [System.IO.Path]::GetFullPath($_).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
            })

        $files = @(Get-ChildItem -LiteralPath $Path -File -Force -Recurse -ErrorAction SilentlyContinue)
        foreach ($file in $files) {
            if ($ExcludedFileNames -contains $file.Name) {
                continue
            }

            if ($file.LastWriteTime -ge $Cutoff) {
                continue
            }

            $result.CandidateCount++
            $filePath = [System.IO.Path]::GetFullPath($file.FullName)
            $isProtected = $normalizedProtectedPaths | Where-Object {
                $filePath.Equals($_, [System.StringComparison]::OrdinalIgnoreCase) -or
                $filePath.StartsWith($_ + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
            }

            if ($isProtected) {
                $result.ProtectedCount++
                continue
            }

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

    foreach ($profile in $profiles) {
        $tempPath = Join-Path $profile.FullName 'AppData\Local\Temp'
        $protectedPaths = @(Get-SessionIdsForProfile $profile.Name | ForEach-Object {
                Join-Path $tempPath $_
            })

        Remove-OldFiles -Path (Join-Path $profile.FullName 'Downloads') -Cutoff $downloadCutoff -ExcludedFileNames @('desktop.ini')
        Remove-OldFiles -Path $tempPath -Cutoff $tempCutoff -ProtectedPaths $protectedPaths
    }
}
