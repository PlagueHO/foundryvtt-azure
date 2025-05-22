param location string = 'global'
param vnetId string
param vnetLinkName string
param dnsZoneName string = 'privatelink.file.${environment().suffixes.storage}'

// Create the Private DNS Zone for Azure Files
resource filePrivateDNSZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  location: location
  name: dnsZoneName
}

// Link the DNS Zone to the VNET
resource dnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  name: vnetLinkName
  location: location
  parent: filePrivateDNSZone
  properties: {
    virtualNetwork: {
      id: vnetId
    }
    registrationEnabled: false
  }
}

output dnsZoneId string = filePrivateDNSZone.id
