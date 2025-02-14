param location string = 'global'
param vnetId string
param dnsZoneName string = 'privatelink.file.${environment().suffixes.storage}'

// Create the Private DNS Zone for Azure Files
resource filePrivateDNSZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  location: location
  name: dnsZoneName
}

// Link the DNS Zone to the VNET
resource dnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: 'vnetLink'
  parent: filePrivateDNSZone
  properties: {
    virtualNetwork: {
      id: vnetId
    }
    registrationEnabled: false
  }
}

output dnsZoneId string = filePrivateDNSZone.id
