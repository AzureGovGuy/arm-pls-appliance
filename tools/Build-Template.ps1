<#
.SYNOPSIS
    Embeds cloud-init/forwarder.yaml into the cloudInitTemplate variable of azuredeploy.json.

.DESCRIPTION
    cloud-init/forwarder.yaml is the source of truth for instance configuration. Keeping it as a
    real YAML file makes it reviewable, lintable and testable on a throwaway VM; ARM needs the
    same content as a single escaped JSON string so the template stays self-contained and
    deployable straight from the portal button.

    This script performs that one-way projection. Run it after every edit to the YAML.

    Deployment-time substitution is deliberately left to ARM: the template still replaces
    __FORWARD_MAP__ and __HEALTH_PORT__ with parameter values via replace(), so a single built
    azuredeploy.json serves every target and port without rebuilding.

.PARAMETER Verify
    Makes no changes. Exits non-zero if azuredeploy.json does not already contain the current
    YAML, so drift fails a pull request instead of shipping a template whose embedded
    configuration silently disagrees with the file people actually review.

.EXAMPLE
    ./tools/Build-Template.ps1

.EXAMPLE
    ./tools/Build-Template.ps1 -Verify
#>
[CmdletBinding()]
param(
    [switch] $Verify
)

$ErrorActionPreference = 'Stop'

$repoRoot     = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $repoRoot 'azuredeploy.json'
$cloudInitPath = Join-Path $repoRoot 'cloud-init/forwarder.yaml'

foreach ($path in @($templatePath, $cloudInitPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required file not found: $path" }
}

# Normalise to LF. The file is authored on Windows but consumed by cloud-init on Linux, and a
# stray CR inside a systemd unit or a shell script is both fatal and very hard to see.
$cloudInit = (Get-Content -LiteralPath $cloudInitPath -Raw) -replace "`r`n", "`n"

foreach ($token in @('__FORWARD_MAP__', '__HEALTH_PORT__')) {
    if ($cloudInit -notmatch [regex]::Escape($token)) {
        throw "$cloudInitPath is missing the $token placeholder that azuredeploy.json substitutes at deployment time."
    }
}

# ConvertTo-Json on a bare string yields a fully escaped JSON string literal, quotes included.
$encoded = ConvertTo-Json -InputObject $cloudInit -Compress

$template = Get-Content -LiteralPath $templatePath -Raw

# Matches a complete JSON string value, honouring backslash escapes, so a rebuild over an
# already-populated template replaces the whole previous value rather than stopping at the
# first escaped quote inside it.
$pattern = '("cloudInitTemplate"\s*:\s*)"(?:[^"\\]|\\.)*"'

if ($template -notmatch $pattern) {
    throw "Could not locate the cloudInitTemplate variable in $templatePath."
}

# A literal $ or backslash in the replacement would otherwise be treated as a regex substitution.
$replacement = '${1}' + $encoded.Replace('$', '$$')
$updated = [regex]::Replace($template, $pattern, $replacement, 1)

if ($Verify) {
    if ($updated -ceq $template) {
        Write-Host "In sync: azuredeploy.json matches cloud-init/forwarder.yaml."
        exit 0
    }
    Write-Error "Out of sync: azuredeploy.json does not match cloud-init/forwarder.yaml. Run tools/Build-Template.ps1."
    exit 1
}

# Prove the projection produced valid JSON before overwriting the template.
$null = $updated | ConvertFrom-Json

if ($updated -ceq $template) {
    Write-Host "No change: azuredeploy.json already matches cloud-init/forwarder.yaml."
    return
}

Set-Content -LiteralPath $templatePath -Value $updated -NoNewline -Encoding utf8
Write-Host ("Embedded {0} bytes of cloud-init into {1}." -f $cloudInit.Length, (Split-Path -Leaf $templatePath))
