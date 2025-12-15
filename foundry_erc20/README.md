# ERC20 Token Project

A Foundry-based ERC20 token implementation project with both manual and OpenZeppelin implementations.

## Project Structure

```
foundry_erc20/
├── src/
│   ├── OurToken.sol          # OpenZeppelin ERC20 implementation
│   └── MannualToken.sol      # Manual ERC20 implementation
├── script/
│   └── DeployOurToken.s.sol  # Deployment script
├── test/
│   └── OurTokenTest.t.sol    # Test suite
└── foundry.toml              # Foundry configuration
```

## Contracts

### OurToken.sol

Standard ERC20 token built with OpenZeppelin contracts.

-   **Name**: OurToken
-   **Symbol**: OT
-   **Initial Supply**: 1000 tokens (configurable)

### MannualToken.sol

Educational implementation of basic ERC20 functionality from scratch.

-   Demonstrates core token mechanics
-   Basic transfer functionality
-   Balance tracking

## Prerequisites

-   [Foundry](https://book.getfoundry.sh/getting-started/installation)
-   [Git](https://git-scm.com/downloads)

## Installation

```bash
# Clone the repository
git clone <your-repo-url>
cd foundry_erc20

# Install dependencies
make install
```

## Usage

### Build

```bash
forge build
```

### Test

```bash
forge test
```

Run tests with verbosity:

```bash
forge test -vvv
```

### Deploy

**Local Anvil:**

```bash
# Start local node
make anvil

# Deploy (in another terminal)
make deploy
```

**Sepolia Testnet:**

```bash
# Set up .env file with:
# SEPOLIA_RPC_URL=<your-rpc-url>
# ACCOUNT=<your-account-name>
# SENDER=<your-address>
# ETHERSCAN_API_KEY=<your-api-key>

make deploy-sepolia
```

## Testing

The test suite includes:

-   Balance checks after deployment
-   Transfer functionality
-   Allowance and approval mechanism
-   TransferFrom functionality

Example test run:

```bash
forge test --match-test testBobBalance
forge test --match-test testAllowancesWorks
```

## Features

-   ✅ ERC20 standard implementation
-   ✅ Minting on deployment
-   ✅ Transfer capabilities
-   ✅ Approval/TransferFrom mechanism
-   ✅ Comprehensive test coverage
-   ✅ Deployment scripts for multiple networks

## Configuration

Edit `foundry.toml` to customize:

-   Source directory
-   Output directory
-   Libraries
-   Remappings

## Security

⚠️ **Important**: This is an educational project. For production use:

-   Conduct thorough security audits
-   Use established libraries (OpenZeppelin)
-   Test extensively on testnets before mainnet deployment

## Learn More

-   [Foundry Book](https://book.getfoundry.sh/)
-   [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
-   [ERC20 Standard](https://eips.ethereum.org/EIPS/eip-20)

## License

MIT
