using './main.bicep'

param location = 'australiaeast'
param resourceGroupName = 'stepup-rg'
param aksName = 'stepup-aks'
param acrName = 'stepupacr2026' 
param nodeVmSize = 'Standard_D2s_v3'
param nodeCount = 1
