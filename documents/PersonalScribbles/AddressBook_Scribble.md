# do we want to timelock ?

Risk: Malicious address updates by compromised governance  
Mitigation: Multi-signature governance with timelock delays for sensitive changes


# No Interface Version Checking [integration issue]
When contracts fetch addresses from AddressBook, there's no verification that the returned contract implements the expected interface version.
- do we really want/need to implement `ERC165`?
