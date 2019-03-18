#!/bin/bash
#parameters needed
#hostlist in Slurm hostlist expression format


echo "`date` Resume invoked $0 $*" >>/var/log/power_save.log

resourceGroup="hpctesthc"

az cloud set --name AzureCloud
az login --service-principal --username 58a7c641-ea6f-4c8c-841a-ad48b421a086 --tenant d6faa5f9-0ae2-4033-8c01-30048a38deeb --password /share/nfs/apps/scripts/hpctest.pem
az account set --subscription a96c7ce0-7f4a-4b6f-a7c4-8c11818e5799
#az vm create --name $vmName --resource-group $resourceGroup --private-ip-address $staticIP --ssh-key-value "$(< ~/.ssh/id_rsa.pub)" --vnet-name $vnetName --image $vmImage --admin-username $adminUsername --size $vmSize --public-ip-address "" --nsg $nsgName --no-wait

hosts=`scontrol show hostnames $1`
for host in $hosts
do
  az vm start --resource-group $resourceGroup --no-wait --name $host
done
