[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $TargetSQLServer,

    [Parameter(Mandatory)]
    [string] $AdminSshPublicKey,

    [string] $Location = "eastus2",
    [string] $Prefix = "customer-pls-lab",
    [int] $TargetPort = 1433,
    [string[]] $ConsumerSubscriptionIds = @((az account show --query id -o tsv)),
    [switch] $AutoApproveConsumers
)

$ErrorActionPreference = "Stop"
$templateFile = Join-Path $PSScriptRoot "azuredeploy.json"
$autoApprovalSubscriptionIds = if ($AutoApproveConsumers) { $ConsumerSubscriptionIds } else { @() }
$consumerSubscriptionIdsJson = ConvertTo-Json -Compress -InputObject @($ConsumerSubscriptionIds)
$autoApprovalSubscriptionIdsJson = ConvertTo-Json -Compress -InputObject @($autoApprovalSubscriptionIds)

az group create `
    --name $ResourceGroupName `
    --location $Location `
    --output none

az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $templateFile `
    --parameters `
        prefix=$Prefix `
        targetSQLServer=$TargetSQLServer `
        targetPort=$TargetPort `
        adminSshPublicKey=$AdminSshPublicKey `
        "consumerSubscriptionIds=$consumerSubscriptionIdsJson" `
        "autoApprovalSubscriptionIds=$autoApprovalSubscriptionIdsJson" `
    --output json