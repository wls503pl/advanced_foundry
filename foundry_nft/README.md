# Basic NFT with IPFS - Technical Guide

## Technologies Used

-   **Solidity ^0.8.18**: Smart contract language
-   **Foundry**: Development framework (forge, cast, anvil)
-   **OpenZeppelin ERC721**: NFT standard implementation
-   **foundry-devops**: Utility library for contract address management
-   **IPFS**: Decentralized storage for NFT metadata and assets
-   **IPFS Desktop**: GUI client for IPFS node management

## Smart Contract Architecture

### BasicNFT.sol

```solidity
contract BasicNFT is ERC721 {
    uint256 private s_tokenCounter;
    mapping(uint256 => string) private s_tokenIdToUri;

    constructor() ERC721("Pikachu", "PKC") {
        s_tokenCounter = 0;
    }

    function mintNFT(string memory tokenUri) public {
        s_tokenIdToUri[s_tokenCounter] = tokenUri;
        _safeMint(msg.sender, s_tokenCounter);
        s_tokenCounter++;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return s_tokenIdToUri[tokenId];
    }
}
```

**Key Features**:

-   Inherits OpenZeppelin's ERC721 implementation
-   Token counter tracks total minted NFTs
-   Mapping stores IPFS URI for each token ID
-   Custom `tokenURI` override to return IPFS metadata

## IPFS Integration Workflow

### 1. Install IPFS Desktop

Download from: https://github.com/ipfs/ipfs-desktop/releases

### 2. Upload Asset File

-   Open IPFS Desktop
-   Drag and drop image/GIF file
-   Copy the CID (Content Identifier)

**Example**: `QmTCoshZqeFsUNrcGAhsqKrnNQg54kqzACdD1MEbDJYPLs`

### 3. Create JSON Metadata

Create `metadata.json` with ERC721 standard format:

```json
{
    "name": "Pikachu",
    "description": "Pikachu NFT - A legendary electric-type Pokemon",
    "image": "ipfs://QmTCoshZqeFsUNrcGAhsqKrnNQg54kqzACdD1MEbDJYPLs",
    "attributes": [
        {
            "trait_type": "Type",
            "value": "Electric"
        },
        {
            "trait_type": "Token Symbol",
            "value": "PKC"
        }
    ]
}
```

**Important**: The `image` field references the asset CID from step 2.

### 4. Upload JSON Metadata

-   Upload `metadata.json` to IPFS Desktop
-   Copy the JSON file's CID

**Example**: `QmQNxRp7HCoUBnsUTQLc1cQcHP682uj8fdHBNEXCGHkk6n`

### 5. Use JSON CID in Contract

```solidity
string public constant PIKACHU_URI =
    "ipfs://QmQNxRp7HCoUBnsUTQLc1cQcHP682uj8fdHBNEXCGHkk6n";
```

## File Persistence with Pinata

IPFS files are only available when nodes are online. Use pinning services for permanence:

1. Register at https://pinata.cloud
2. Navigate to Upload → By CID
3. Pin both the asset CID and JSON CID
4. Files remain accessible even when local node is offline

## Testing Strategy

### BasicNFTTest.t.sol

```solidity
contract BasicNFTTest is Test {
    DeployBasicNFT public deployer;
    BasicNFT public basicNFT;
    address public USER = makeAddr("user");
    string public constant _PKC_ = "ipfs://QmQNxRp7HCoUBnsUTQLc1cQcHP682uj8fdHBNEXCGHkk6n";

    function setUp() public {
        deployer = new DeployBasicNFT();
        basicNFT = deployer.run();
    }

    function testNameIsCorrect() public view {
        string memory expectedName = "Pikachu";
        string memory actualName = basicNFT.name();
        assert(keccak256(abi.encodePacked(expectedName)) == keccak256(abi.encodePacked(actualName)));
    }

    function testMint_Balance() public {
        vm.prank(USER);
        basicNFT.mintNFT(_PKC_);

        assert(basicNFT.balanceOf(USER) == 1);
        assert(keccak256(abi.encodePacked(_PKC_)) == keccak256(abi.encodePacked(basicNFT.tokenURI(0))));
    }
}
```

**Test Coverage**:

-   Name validation using `keccak256` hash comparison
-   Minting functionality with `vm.prank` for user simulation
-   Balance verification after mint
-   TokenURI correctness check

## Scripts

### DeployBasicNFT.s.sol

```solidity
contract DeployBasicNFT is Script {
    function run() external returns (BasicNFT) {
        vm.startBroadcast();
        BasicNFT basicNft = new BasicNFT();
        vm.stopBroadcast();
        return basicNft;
    }
}
```

### Interactions.s.sol

```solidity
contract MintBasicNFT is Script {
    string public constant _PKC_ = "ipfs://QmQNxRp7HCoUBnsUTQLc1cQcHP682uj8fdHBNEXCGHkk6n";

    function run() external {
        address mostRecentlyDeployed = DevOpsTools.get_most_recent_deployment("BasicNFT", block.chainid);
        mintNftOnContract(mostRecentlyDeployed);
    }

    function mintNftOnContract(address contractAddress) public {
        vm.startBroadcast();
        BasicNFT(contractAddress).mintNFT(_PKC_);
        vm.stopBroadcast();
    }
}
```

**Purpose**: Mint NFTs on already deployed contracts without redeployment.

**Key Features**:

-   Uses `foundry-devops` to fetch the most recent deployment address
-   Separates minting logic from deployment
-   Enables interaction with existing contracts across different chains

## Commands

```bash
# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install Cyfrin/foundry-devops --no-commit

# Run tests
forge test

# Deploy to local anvil
forge script script/DeployBasicNFT.s.sol --rpc-url http://localhost:8545 --private-key $PRIVATE_KEY --broadcast

# Deploy to testnet
forge script script/DeployBasicNFT.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast

# Mint NFT on deployed contract
forge script script/Interactions.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

## IPFS Gateway Access

Verify uploaded content via public gateways:

```
https://ipfs.io/ipfs/[CID]
https://cloudflare-ipfs.com/ipfs/[CID]
https://gateway.pinata.cloud/ipfs/[CID]
```

## NFT Metadata Structure

```
Smart Contract (tokenURI)
    ↓
JSON Metadata (ipfs://QmQNx...)
    ├─ name: "Pikachu"
    ├─ description: "..."
    └─ image: "ipfs://QmTCo..."
              ↓
         Asset File (GIF/PNG)
```

## Key Concepts

**Content Addressing**: IPFS uses cryptographic hashes (CIDs) instead of location-based URLs. Same content = same CID.

**Decentralization**: Files are distributed across multiple nodes, eliminating single points of failure.

**Immutability**: Content cannot be changed without generating a new CID, providing built-in version control.

**ERC721 Standard**: `tokenURI` function must return metadata URI. NFT marketplaces (OpenSea, Rarible) parse this to display NFT information.

**foundry-devops**: Tracks deployed contracts via broadcast artifacts in `broadcast/` directory. `DevOpsTools.get_most_recent_deployment()` retrieves the latest contract address for a given chain, enabling seamless interaction without hardcoding addresses.
