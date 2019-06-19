# x509-forest-of-trust
Solidity contract that parses and verifies X.509 certificate chains and stores them in parent pointer trees on the ETH blockchain. An ETH account can then prove ownerhip of a verified certificate in the tree.

Useful for:
  1) associating a domain with an Ethereum address
  2) verifying HTTP responses on chain using Signed HTTP Exchanges / web packages
