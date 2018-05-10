#!/bin/bash
#parameters needed
#hostlist in Slurm hostlist expression format


echo "`date` Resume invoked $0 $*" >>/var/log/power_save.log

resourceGroup="hpctest2"

az cloud set --name AzureUSGovernment
az login
az account set --subscription d9eabcc0-f041-4271-b900-25ec822ae637
#az vm create --name $vmName --resource-group $resourceGroup --private-ip-address $staticIP --ssh-key-value "$(< ~/.ssh/id_rsa.pub)" --vnet-name $vnetName --image $vmImage --admin-username $adminUsername --size $vmSize --public-ip-address "" --nsg $nsgName --no-wait

hosts=`scontrol show hostnames $1`
for host in $hosts
do
  az vm start --resource-group $resourceGroup --no-wait --name $host
done
