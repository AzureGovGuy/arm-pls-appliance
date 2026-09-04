[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,23}=[^:]+(:\d+)?$')]
    [string[]] $Target,

    [Parameter(Mandatory)]
    [string] $AdminSshPublicKey,

    [string] $Location = "eastus2",
    [string] $Prefix = "customer-pls-lab",
    [string] $DeploymentName = "pls-appliance",
    [int] $BackendPortBase = 11433,
    [int] $InstanceCount = 2,
    [string] $VmSize = "Standard_D2s_v5",
    [string[]] $AvailabilityZones = @("1", "2", "3"),

    # Off by default. The data path never uses the internet, this template's cloud-init installs
    # no packages, and a supported Azure Linux Agent pulls extension packages through the fabric
    # controller on 168.63.129.16. Enable only for in-guest OS patching.
    [switch] $EnableInternetEgress,

    # Optional private CIDR allowed to reach SSH. No rule is created when omitted.
    [string] $AdminSourceAddressPrefix = "",

    # Set false for a staged bring-up. The health endpoint reports Unhealthy until the target
    # accepts TCP, so enabling repairs before the target exists replaces every instance once the
    # grace period expires, and each replacement is unhealthy for the same reason.
    [bool] $EnableAutomaticRepairs = $true,

    [string[]] $ConsumerSubscriptionIds = @((az account show --query id -o tsv)),
    [switch] $AutoApproveConsumers,

    # Prints the change set without deploying.
    [switch] $WhatIf
)

$ErrorActionPreference = "Stop"
$templateFile = Join-Path $PSScriptRoot "azuredeploy.json"

# The template embeds cloud-init/forwarder.yaml. Deploying a template whose embedded copy has
# drifted from the reviewed YAML is the one failure this script can cheaply prevent.
& (Join-Path $PSScriptRoot "tools/Build-Template.ps1") -Verify
if ($LASTEXITCODE -ne 0) {
    throw "azuredeploy.json is out of sync with cloud-init/forwarder.yaml. Run tools/Build-Template.ps1."
}

$autoApprovalSubscriptionIds = if ($AutoApproveConsumers) { $ConsumerSubscriptionIds } else { @() }

# Get-Content -Raw keeps the trailing newline, which Azure rejects as a malformed key. This must
# happen before the parameter document is built, not after.
$AdminSshPublicKey = $AdminSshPublicKey.Trim()

# Each -Target becomes its own load balancer frontend and its own Private Link Service, so the
# consumer connects to the server's real hostname on its real port. Accepts "name=host" or
# "name=host:port"; the port defaults to 1433.
$targets = @($Target | ForEach-Object {
        $label, $endpoint = $_.Split('=', 2)
        $address, $port = $endpoint.Split(':', 2)
        [ordered]@{
            name = $label
            host = $address
            port = if ($port) { [int] $port } else { 1433 }
        }
    })

$duplicateNames = @($targets.name | Group-Object | Where-Object Count -gt 1)
if ($duplicateNames) {
    throw "Duplicate target names: $($duplicateNames.Name -join ', '). Each target name must be unique; it is used in resource names."
}

# Parameters go in a file rather than on the command line. `--parameters key=value` requires the
# value to survive PowerShell's argument handling, which strips the inner double quotes from a
# JSON literal: an array arrives as [{name:sqlu1}] and az rejects it. A parameters file has no
# quoting to lose.
$parameterValues = [ordered]@{
    prefix                      = $Prefix
    targets                     = $targets
    backendPortBase             = $BackendPortBase
    adminSshPublicKey           = $AdminSshPublicKey
    instanceCount               = $InstanceCount
    vmSize                      = $VmSize
    enableInternetEgress        = $EnableInternetEgress.IsPresent
    enableAutomaticRepairs      = $EnableAutomaticRepairs
    adminSourceAddressPrefix    = $AdminSourceAddressPrefix
    availabilityZones           = @($AvailabilityZones)
    consumerSubscriptionIds     = @($ConsumerSubscriptionIds)
    autoApprovalSubscriptionIds = @($autoApprovalSubscriptionIds)
}

$parameterDocument = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = [ordered]@{}
}
foreach ($name in $parameterValues.Keys) {
    $parameterDocument.parameters[$name] = @{ value = $parameterValues[$name] }
}

$parameterPath = Join-Path ([System.IO.Path]::GetTempPath()) ("pls-appliance-{0}.parameters.json" -f [guid]::NewGuid().ToString('N'))
[System.IO.File]::WriteAllText($parameterPath, (ConvertTo-Json -InputObject $parameterDocument -Depth 10))

# Only create the resource group when it is absent. Re-issuing the create against an existing
# group with a different -Location fails rather than silently doing nothing, and resources follow
# the group's region because the template defaults location to resourceGroup().location.
$rgExists = (az group exists --name $ResourceGroupName --output tsv)
if ($rgExists -ne "true") {
    az group create `
        --name $ResourceGroupName `
        --location $Location `
        --output none
}

$deploymentArgs = @(
    "--resource-group", $ResourceGroupName,
    "--name", $DeploymentName,
    "--template-file", $templateFile,
    "--parameters", "@$parameterPath"
)

try {
    if ($WhatIf) {
        az deployment group what-if @deploymentArgs
        return
    }

    $result = az deployment group create @deploymentArgs --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $result) {
        throw "Deployment '$DeploymentName' failed. For the failing resource and message, run: az deployment operation group list -g $ResourceGroupName -n $DeploymentName --query ""[?properties.provisioningState=='Failed'].properties.statusMessage"""
    }

    # The aliases are the only outputs a consumer needs. Print them rather than making the
    # operator dig them back out of the deployment.
    Write-Host ""
    Write-Host "Create one managed private endpoint per row, using the target's own FQDN as the"
    Write-Host "endpoint resource name, then connect on Port. BackendPort is internal plumbing."
    Write-Host ""
    $result.properties.outputs.privateLinkServices.value |
        Select-Object @{ n = 'Target'; e = { $_.name } },
                      @{ n = 'Endpoint'; e = { $_.target } },
                      @{ n = 'Port'; e = { $_.consumerPort } },
                      @{ n = 'BackendPort'; e = { $_.backendPort } },
                      @{ n = 'Alias'; e = { $_.alias } } |
        Format-Table -AutoSize

    Write-Host "Allow-list $($result.properties.outputs.forwarderSubnetPrefix.value) on each target's firewall."
}
finally {
    Remove-Item -LiteralPath $parameterPath -Force -ErrorAction SilentlyContinue
}
