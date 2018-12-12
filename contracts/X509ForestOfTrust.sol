pragma solidity  ^0.5.1;

import "./Ownable.sol";
import "asn1-decode/contracts/Asn1Decode.sol";
//import "solidity-bytes-utils/contracts/BytesUtils.sol";
import "sig-verify-algs/contracts/Algorithm.sol";
import "ens-namehash/contracts/ENSNamehash.sol";
import "ethereum-datetime/contracts/DateTime.sol";

/*
 * @dev Stores validated X.509 certificate chains in parent pointer trees.
 * @dev The root of each tree is a CA root certificate
 */
contract X509ForestOfTrust is Ownable {
  using Asn1Decode for bytes;
  using BytesUtils for bytes;
  using ENSNamehash for bytes;

  constructor(address sha256WithRSAEncryption, address _dateTime) public {
    bytes32 a = 0x2a864886f70d01010b0000000000000000000000000000000000000000000000;
    algs[a] = Algorithm(sha256WithRSAEncryption);
    dateTime = DateTime(_dateTime);
    cshxOid = 0x551d130000000000000000000000000000000000000000000000000000000000; // change to actual oid of canSignHttpExchanges
  }

  DateTime dateTime;

  struct Certificate {
    address owner;
    bytes32 parentId;
    bytes pubKey;
    uint serialNumber;
    uint validNotAfter;
    bool cshx; // canSignHttpExchanges
  }
  // certId => cert ; certId == keccak256(cert.pubKey)
  mapping (bytes32 => Certificate) public certs;
  // keccak256(commonName) => certId
  mapping (bytes32 => bytes32[]) public certIdsFromCN;
  // sha256Fingerprint => certId or ensNamehash(commonName) => keccak256(commonName)
  mapping (bytes32 => bytes32) public refs;
  // Signature verification contracts
  mapping(bytes32 => Algorithm) private algs;
  // OID of canSignHttpExchanges since spec may change
  bytes32 private cshxOid;

  event CertAdded(bytes32);
  event CertClaimed(bytes32);
  event AlgSet(bytes32, address);

  /*
   * @dev Add a self-signed X.509 certificate to the root of a new tree
   * @param cert A DER-encoded self-signed X.509 certificate
   * @param cshx Look for canSignHttpExchanges extension
   */
  function addRootCert(bytes memory cert, bool cshx)
  public
  {
    uint node;
    // Get pub key
    node = cert.root();
    node = cert.firstChildOf(node);
    node = cert.firstChildOf(node);
    node = cert.nextSiblingOf(node);
    node = cert.nextSiblingOf(node);
    node = cert.nextSiblingOf(node);
    node = cert.nextSiblingOf(node);
    node = cert.nextSiblingOf(node);
    node = cert.nextSiblingOf(node);
    // Set parent/self pub key
    certs[cert.keccakOfAllBytesAt(node)].pubKey = cert.allBytesAt(node);
    addCert(cert, cert.keccakOfAllBytesAt(node), cshx);
  }

  /*
   * @dev Add a X.509 certificate to an existing tree/chain
   * @param cert A DER-encoded X.509 certificate
   * @param parentId The keccak256 hash of parent cert's public key
   * @param cshx Look for canSignHttpExchanges extension
   */
  function addCert(bytes memory cert, bytes32 parentId, bool cshx)
  public
  {
    bytes32 certId;
    uint serialNumber;
    uint validNotAfter;
    uint node1;
    uint node2;
    uint node3;

    node1 = cert.root();
    node1 = cert.firstChildOf(node1);
    node2 = cert.firstChildOf(node1);
    node2 = cert.nextSiblingOf(node2);
    // Extract serial number
    serialNumber = cert.uintAt(node2);

    node2 = cert.nextSiblingOf(node2);
    node2 = cert.firstChildOf(node2);
    node3 = cert.nextSiblingOf(node1);
    node3 = cert.nextSiblingOf(node3);
    // Verify signature
    require( algs[cert.bytes32At(node2)].verify(certs[parentId].pubKey, cert.allBytesAt(node1), cert.bytesAt(node3)), "Signature doesnt match");

    node1 = cert.firstChildOf(node1);
    node1 = cert.nextSiblingOf(node1);
    node1 = cert.nextSiblingOf(node1);
    node1 = cert.nextSiblingOf(node1);
    node1 = cert.nextSiblingOf(node1);

    // Get timestamps
    node2 = cert.firstChildOf(node1);
    require(toTimestamp(cert.bytesAt(node2)) <= now, "Invalid cert");
    node2 = cert.nextSiblingOf(node2);
    validNotAfter = toTimestamp(cert.bytesAt(node2));
    require(now <= validNotAfter, "Invalid cert");

    node1 = cert.nextSiblingOf(node1);
    node2 = cert.nextSiblingOf(node1);
    // Get public key and calculate certId from it
    certId = cert.keccakOfAllBytesAt(node2);
    if (certId != parentId)
      certs[certId].pubKey = cert.allBytesAt(node2);

    // Get commonName and add references from it
    node2 = cert.firstChildOf(node1);
    while (Asn1Decode.isChildOf(node2, node1)) {
      node3 = cert.firstChildOf(node2);
      node3 = cert.firstChildOf(node3);
      if ( cert.bytes32At(node3) == 0x5504030000000000000000000000000000000000000000000000000000000000 ) {
        node3 = cert.nextSiblingOf(node3);
        certIdsFromCN[cert.keccakOfBytesAt(node3)].push(certId);
        refs[toEnsNamehash(cert.bytesAt(node3))] = cert.keccakOfBytesAt(node3);
        break;
      }
      node2 = cert.nextSiblingOf(node2);
    }

    certs[certId].parentId = parentId;
    certs[certId].serialNumber = serialNumber;
    certs[certId].validNotAfter = validNotAfter;

    // Add reference from sha256 fingerprint
    refs[sha256(cert)] = certId;

    if (cshx) {
      node1 = cert.nextSiblingOf(node1);
      node1 = cert.nextSiblingOf(node1);
      node1 = cert.firstChildOf(node1);
      node2 = cert.firstChildOf(node1);
      while (Asn1Decode.isChildOf(node2, node1)) {
        node3 = cert.firstChildOf(node2);
        if ( cert.bytes32At(node3) == cshxOid ) {
          certs[certId].cshx = true;
          break;
        }
        node2 = cert.nextSiblingOf(node2);
      }
    }

    // Fire event
    emit CertAdded(certId);
  }

  /**
   * @dev The return values of this function are used to proveOwnership() of a
   *      certificate that exists in the certs mapping.
   * @return Some unique bytes to be signed
   * @return The block number used to create the first return value
   */
  function signThis()
  external view returns (bytes memory, uint)
  {
    return ( abi.encodePacked(msg.sender, blockhash(block.number - 1)), block.number -1 );
  }

  /**
   * @dev An account calls this method to prove ownership of a certificate.
   *      If successful, certs[certId].owner will be set to caller's address.
   * @param certId The keccak256 hash of target certificate's public key
   * @param signature signThis()[0] signed with certificate's private key
   * @param blockNumber The value of signThis()[1] (must be > block.number - 256)
   * @param sigAlg The OID of the algorithm used to sign `signature`
   */
  function proveOwnership(bytes32 certId, bytes calldata signature, uint blockNumber, bytes32 sigAlg)
  external returns (bool)
  {
    bytes memory message;
    // Only accept proof if it's less than 256 blocks old
    // This is the most time I can give since blockhash() can only return the 256 most recent
    require( block.number - blockNumber < 256 );
    // Verify signature, which proves ownership
    message = abi.encodePacked(msg.sender, blockhash(blockNumber));
    require( algs[sigAlg].verify(certs[certId].pubKey, message, signature) );

    certs[certId].owner = msg.sender;

    emit CertClaimed(certId);
  }

  function rootOf(bytes32 certId)
  public view returns (bytes32)
  {
    while (certId != certs[certId].parentId) {
      certId = certs[certId].parentId;
    }
    return certId;
  }

  function certIdsFromCNLength(bytes32 commonNameHash)
  public view returns (uint)
  {
    return certIdsFromCN[commonNameHash].length;
  }

  function owners(bytes32 certId)
  public view returns (address)
  {
    return certs[certId].owner;
  }

  function toTimestamp(bytes memory x509Time)
  private view returns (uint)
  {
    uint16 yrs;  uint8 mnths;
    uint8  dys;  uint8 hrs;
    uint8  mins; uint8 secs;
    uint8  offset;

    if (x509Time.length == 13) {
      if (uint8(x509Time[0])-48 < 5) yrs += 2000;
      else yrs += 1900;
    }
    else {
      yrs += (uint8(x509Time[0])-48) * 1000 + (uint8(x509Time[1])-48) * 100;
      offset = 2;
    }
    yrs +=  (uint8(x509Time[offset+0])-48)*10 + uint8(x509Time[offset+1])-48;
    mnths = (uint8(x509Time[offset+2])-48)*10 + uint8(x509Time[offset+3])-48;
    dys +=  (uint8(x509Time[offset+4])-48)*10 + uint8(x509Time[offset+5])-48;
    hrs +=  (uint8(x509Time[offset+6])-48)*10 + uint8(x509Time[offset+7])-48;
    mins += (uint8(x509Time[offset+8])-48)*10 + uint8(x509Time[offset+9])-48;
    secs += (uint8(x509Time[offset+10])-48)*10 + uint8(x509Time[offset+11])-48;

    return dateTime.toTimestamp(yrs, mnths, dys, hrs, mins, secs);
  }

  function toEnsNamehash(bytes memory dn)
  private pure returns (bytes32)
  {
    // if common name starts with 'www.'
    if (dn[0] == 0x77 && dn[1] == 0x77 && dn[2] == 0x77 && dn[3] == 0x2e)
      // omit 'www.'
      return dn.substring(4, dn.length-4).namehash();

    return dn.namehash();
  }

  function setAlg(bytes32 oid, address alg)
  public onlyOwner
  {
    algs[oid] = Algorithm(alg);
    emit AlgSet(oid, alg);
  }

  function setCshxOid(bytes32 _cshxOid)
  public onlyOwner
  {
    cshxOid = _cshxOid;
  }
}