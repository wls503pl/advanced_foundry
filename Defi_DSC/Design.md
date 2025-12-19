# DSC Protocol Design Documentation

> **Last Updated:** December 19, 2025  
> **Author:** Peile Wu  
> **Status:** 🚧 In Development

---

## Table of Contents

-   [Overview](#overview)
-   [DSC.sol - Token Contract](#dscsol---token-contract)
-   [DSCEngine.sol - Core Engine](#dscenginesol---core-engine)
-   [Deployment & Testing](#deployment--testing)
-   [Contract Interaction](#contract-interaction)

---

## Overview

DSC is a **decentralized algorithmic stablecoin** maintaining 1:1 USD peg through cryptocurrency over-collateralization.

### Core Principles

**1. Relative Stability** - Pegged to $1.00 USD via Chainlink Price Feeds and redemption mechanism

**2. Algorithmic Minting** - Fully decentralized, users can only mint with sufficient collateral

**3. Exogenous Collateral** - Backed by wETH (Wrapped Ethereum) and wBTC (Wrapped Bitcoin)

### System Architecture

```
┌──────────────────┐
│    DSC.sol       │  ERC20 stablecoin token
└──────────┬───────┘
           │ owned by
           ↓
┌──────────────────────────┐
│     DSCEngine.sol        │  Collateral & minting logic
└──────────────────────────┘
           ↑
           │ uses
           │
    ┌──────┴──────┐
    │             │
 wETH          wBTC
(Collateral)  (Collateral)
```

---

## DSC.sol - Token Contract

### Contract Purpose

DSC.sol is the ERC20 token contract representing the stablecoin. It is **not** directly accessible to users - all minting and burning operations are controlled by DSCEngine to enforce collateralization rules.

### Inheritance Structure

```
ERC20 (OpenZeppelin)
  ↓
ERC20Burnable (OpenZeppelin)
  ↓                           Ownable (OpenZeppelin)
  └─────────────────────────────┬──────────────────────┘
                  ↓
                DSC.sol
```

### Why These Inherited Contracts?

**1. ERC20 (OpenZeppelin)**

Standard ERC20 implementation providing:

-   `transfer()` - Send tokens between addresses
-   `balanceOf()` - Check token balance
-   `approve()` / `allowance()` - Approve spending
-   `_mint()` - Internal function to create tokens
-   `_burn()` - Internal function to destroy tokens

**Why use it:** Provides battle-tested, standardized token functionality

**2. ERC20Burnable (OpenZeppelin)**

Extends ERC20 with:

-   `burn()` - Public function to burn own tokens
-   `burnFrom()` - Burn tokens from another address (with approval)

**Why use it:** Enables token destruction needed for collateral redemption

**3. Ownable (OpenZeppelin)**

Access control mechanism providing:

-   `onlyOwner` modifier - Restricts function access
-   `owner()` - Returns current owner address
-   `transferOwnership()` - Transfer contract ownership

**Why use it:** Ensures only DSCEngine can mint/burn tokens

### State Variables

**None** - DSC.sol has no additional state variables beyond those inherited from ERC20/Ownable

### Custom Errors

```solidity
error DSC__BurnAmountMustBeMoreThanZero();     // Burn amount validation
error DSC__BurnAmountExceedsBalance();          // Insufficient balance check
error DSC__MintToZeroAddress();                 // Prevent minting to zero address
error DSC__MintAmountMustBeMoreThanZero();     // Mint amount validation
```

**Design choice:** Custom errors are more gas-efficient than `require()` strings

### Constructor

```solidity
constructor()
    ERC20("Decentralized Stable Coin", "DSC")  // Set token name & symbol
    Ownable(msg.sender)                         // Set deployer as initial owner
{}
```

**Key points:**

-   Initializes token with name "Decentralized Stable Coin" and symbol "DSC"
-   Sets deployer as owner (ownership will be transferred to DSCEngine after deployment)
-   OpenZeppelin v5.0+ requires explicit owner initialization via `Ownable(msg.sender)`

### Functions

#### mint()

```solidity
function mint(address _to, uint256 _amount)
    external
    onlyOwner
    returns (bool)
```

**Purpose:** Creates new DSC tokens

**Access:** Only owner (DSCEngine)

**Parameters:**

-   `_to` - Recipient address
-   `_amount` - Amount to mint

**Process:**

1. Validates recipient is not zero address
2. Validates amount is greater than zero
3. Calls `_mint()` from ERC20 base contract
4. Returns true on success

**Why onlyOwner?** Users cannot directly mint DSC. DSCEngine validates collateralization before calling this function.

**Dependency:** `ERC20._mint()` - Creates tokens and updates total supply

#### burn()

```solidity
function burn(uint256 _amount)
    public
    override
    onlyOwner
```

**Purpose:** Destroys DSC tokens

**Access:** Only owner (DSCEngine)

**Parameters:**

-   `_amount` - Amount to burn

**Process:**

1. Checks caller's balance via `balanceOf(msg.sender)`
2. Validates amount is greater than zero
3. Validates sufficient balance exists
4. Calls `super.burn()` which invokes `ERC20._burn()`

**Why override?** Standard `ERC20Burnable.burn()` allows anyone to burn their own tokens. We override to restrict burning to DSCEngine only, as burning is part of the collateral redemption process.

**Why onlyOwner?** DSCEngine needs to control burning to maintain proper accounting of minted DSC vs collateral.

**Dependency chain:**

```
burn() → super.burn() → ERC20Burnable.burn() → ERC20._burn()
```

### Design Decisions Summary

| Decision               | Reason                                        |
| ---------------------- | --------------------------------------------- |
| Inherit ERC20          | Standard token functionality                  |
| Inherit ERC20Burnable  | Need burn capability for redemptions          |
| Inherit Ownable        | Restrict minting/burning to DSCEngine         |
| Override burn()        | Prevent users from burning directly           |
| Custom errors          | Gas optimization                              |
| onlyOwner on mint/burn | Enforce collateralization rules via DSCEngine |

---

## DSCEngine.sol - Core Engine

### Contract Purpose

DSCEngine is the brain of the protocol, managing:

-   **Collateral Management** - Deposits and withdrawals of wETH/wBTC
-   **DSC Minting** - Creating stablecoins based on collateral value
-   **Health Monitoring** - Tracking position safety via health factors
-   **Liquidations** - Protecting system solvency

### Inheritance

```
ReentrancyGuard (OpenZeppelin)
  ↓
DSCEngine.sol
```

**Why ReentrancyGuard?** Prevents reentrancy attacks during token transfers. The `nonReentrant` modifier ensures external calls (like `transferFrom()`) cannot recursively call back into the contract.

### Core Dependencies

```solidity
import {DSC} from "./DSC.sol";                           // Controls DSC minting/burning
import {IERC20} from "@openzeppelin/contracts/...";      // Interacts with wETH/wBTC
import {AggregatorV3Interface} from "@chainlink/...";   // Gets real-time prices
```

### State Variables

```solidity
// Precision constants for calculations
uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;  // Converts Chainlink 8 decimals → 18 decimals
uint256 private constant PRECISION = 1e18;                   // Standard 18 decimal precision
uint256 private constant LIQUIDATION_THRESHOLD = 50;         // 50% = 200% collateralization required
uint256 private constant LIQUIDATION_PRECISION = 100;        // Denominator for threshold calculation
uint256 private constant MIN_HEALTH_FACTOR = 1e18;          // Minimum health factor = 1.0

// Token → Price Feed mapping
mapping(address => address) private s_priceFeeds;

// User → (Token → Amount) nested mapping
mapping(address => mapping(address => uint256)) private s_collateralDeposited;

// User → DSC Minted amount
mapping(address => uint256) private s_dscMinted;

// List of supported collateral tokens
address[] private s_collateralTokens;

// Reference to DSC token contract
DSC private immutable i_dsc;
```

**Key mappings:**

-   `s_priceFeeds`: Links each collateral token to its Chainlink oracle (e.g., wETH → ETH/USD feed)
-   `s_collateralDeposited`: Tracks how much of each token each user has deposited
-   `s_dscMinted`: Records each user's debt (how much DSC they've minted)

**Liquidation constants explained:**

-   `LIQUIDATION_THRESHOLD = 50`: Users can borrow up to 50% of their collateral value (requires 200% collateralization)
-   `LIQUIDATION_PRECISION = 100`: Used as denominator in percentage calculations (50/100 = 0.5)
-   `MIN_HEALTH_FACTOR = 1e18`: Represents 1.0 in 18-decimal precision. Positions below this can be liquidated

**Example:** With $2000 collateral, user can mint maximum $1000 DSC (50% ratio)

### Custom Errors

```solidity
error DSCEngine__NeedsMoreThanZero();
error DSCEngine__AddressLengthOfTokenAndPriceFeedNotMatch();
error DSCEngine__NotAllowedToken();
error DSCEngine__TransferFailed();
error DSCEngine__BreaksHealthFactor(uint256 healthFactor);  // Reports the actual health factor value
error DSCEngine__MintFailed();
```

**New errors added (Dec 18, 2025):**

-   `DSCEngine__BreaksHealthFactor`: Includes the calculated health factor for debugging
-   `DSCEngine__MintFailed`: Catches failures in the DSC minting process

### Events

```solidity
event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
```

### Security Modifiers

#### moreThanZero

```solidity
modifier moreThanZero(uint256 amount) {
    if (amount <= 0) revert DSCEngine__NeedsMoreThanZero();
    _;
}
```

Prevents zero-value operations in deposits, withdrawals, minting, and burning.

#### isAllowedToken

```solidity
modifier isAllowedToken(address token) {
    if (s_priceFeeds[token] == address(0)) revert DSCEngine__NotAllowedToken();
    _;
}
```

Ensures only whitelisted tokens (wETH/wBTC) can be used as collateral.

### Constructor

```solidity
constructor(
    address[] memory tokenAddress,      // [wETH, wBTC]
    address[] memory priceFeedAddress,  // [ETH/USD feed, BTC/USD feed]
    address dscAddress                  // DSC token contract
)
```

**Setup process:**

1. Validates arrays are same length
2. Maps each collateral token to its Chainlink price feed
3. Stores collateral token addresses for iteration
4. Connects to DSC token contract

**Example:**

```solidity
new DSCEngine(
    [0xC02a...wETH, 0x2260...wBTC],
    [0x5f4e...ETH/USD, 0xF4...BTC/USD],
    0x1234...DSC
);
```

### Implemented Functions

#### depositCollateral()

```solidity
function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
    external
    moreThanZero(amountCollateral)
    isAllowedToken(tokenCollateralAddress)
    nonReentrant
```

**Purpose:** Users deposit wETH or wBTC as collateral

**CEI Pattern (Checks-Effects-Interactions):**

1. **Checks:** Modifiers validate amount > 0, token is allowed, prevents reentrancy
2. **Effects:** Update user's collateral balance, emit event
3. **Interactions:** Transfer tokens from user to contract

**Example:**

```
User deposits 10 ETH
→ s_collateralDeposited[user][wETH] += 10e18
→ wETH.transferFrom(user, DSCEngine, 10e18)
```

#### mintDsc()

```solidity
function mintDsc(uint256 amountDscToMint)
    external
    moreThanZero(amountDscToMint)
    nonReentrant
```

**Purpose:** Users mint DSC stablecoins against their collateral

**Process:**

1. Records user's debt: `s_dscMinted[msg.sender] += amountDscToMint`
2. Validates health factor via `_revertIfHealthFactorIsBroken(msg.sender)`
3. Calls `i_dsc.mint(msg.sender, amountDscToMint)` to create tokens
4. Reverts with `DSCEngine__MintFailed` if minting returns false

**Implementation:**

```solidity
s_dscMinted[msg.sender] += amountDscToMint;

// Prevent over-leveraging: revert if health factor < 1.0
_revertIfHealthFactorIsBroken(msg.sender);

bool minted = i_dsc.mint(msg.sender, amountDscToMint);
if (!minted) {
    revert DSCEngine__MintFailed();
}
```

**Example scenario:**

```
User has $2000 collateral (wETH), attempts to mint 900 DSC:
→ s_dscMinted[user] += 900e18
→ Health Factor = ($2000 × 50%) / $900 = 1.11 ✓ (Safe)
→ DSC.mint(user, 900e18) succeeds
→ User receives 900 DSC tokens

User tries to mint 200 more DSC (total 1100):
→ s_dscMinted[user] += 200e18
→ Health Factor = ($2000 × 50%) / $1100 = 0.91 ✗ (Unsafe)
→ Reverts with DSCEngine__BreaksHealthFactor(0.91e18)
```

**Safety mechanism:** Cannot mint DSC if it would push health factor below 1.0

### Public View Functions

#### getAccountCollateralValue()

```solidity
function getAccountCollateralValue(address user) public view returns (uint256)
```

**Purpose:** Calculates total USD value of a user's collateral

**Process:**

1. Loops through all collateral tokens (wETH, wBTC)
2. Gets deposited amount for each
3. Converts to USD using `getUsdValue()`
4. Sums total value

**Example:**

```
User has:
- 2 wETH @ $2000 = $4000
- 0.1 wBTC @ $40000 = $4000
Total: $8000
```

#### getUsdValue()

```solidity
function getUsdValue(address token, uint256 amount) public view returns (uint256)
```

**Purpose:** Converts token amount to USD value

**Precision handling:**

```solidity
// Chainlink returns price with 8 decimals
// Token amounts use 18 decimals
// Result needs 18 decimals

return (price * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
```

**Example:**

```
1 ETH at $2000:
- Chainlink price = 200000000000 (8 decimals)
- Amount = 1e18 (1 ETH)
- Result = (200000000000 * 1e10 * 1e18) / 1e18 = 2000e18 ($2000)
```

### Internal/Private Helper Functions

#### \_revertIfHealthFactorIsBroken()

```solidity
function _revertIfHealthFactorIsBroken(address user) internal view {
    uint256 userHealthFactor = _healthFactor(user);
    if (userHealthFactor < MIN_HEALTH_FACTOR) {
        revert DSCEngine__BreaksHealthFactor(userHealthFactor);
    }
}
```

**Purpose:** Validates user's position safety after risky operations

**When called:**

-   After minting DSC
-   After withdrawing collateral (future implementation)
-   Before any operation that could reduce health factor

**Why it matters:** This is the core safety mechanism preventing users from over-leveraging their positions.

#### \_getAccountInformation()

```solidity
function _getAccountInformation(address user) private view
    returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
```

**Purpose:** Helper function retrieving both debt and collateral values

**Returns:**

-   `totalDscMinted`: Amount of DSC user has borrowed
-   `collateralValueInUsd`: Total USD value of user's deposited collateral

**Why useful:** Combines two state reads into one function call, used by `_healthFactor()`

#### \_healthFactor()

```solidity
function _healthFactor(address user) private view returns (uint256) {
    (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
    uint256 collateralAdjustedForThreshold =
        (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
    return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
}
```

**Purpose:** Calculates how close a position is to liquidation

**Formula breakdown:**

```
Health Factor = (Collateral Value × Liquidation Threshold) / DSC Minted
             = (Collateral Value × 50%) / DSC Minted
```

**Step-by-step calculation:**

1. Get user's collateral value (in USD)
2. Apply 50% threshold: `collateralAdjustedForThreshold = collateralValue × 50 / 100`
3. Divide by DSC minted and scale to 18 decimals

**Interpretation:**

| Health Factor | Status          | Meaning               | Can Be Liquidated? |
| ------------- | --------------- | --------------------- | ------------------ |
| > 1.0         | ✅ Safe         | Over-collateralized   | No                 |
| = 1.0         | ⚠️ At Threshold | Exactly at 200% ratio | Yes (borderline)   |
| < 1.0         | ❌ Unsafe       | Under-collateralized  | Yes                |

**Real-world examples:**

```
Example 1: Healthy Position
- Collateral: $2000 wETH
- DSC Minted: $800
- Calculation: ($2000 × 0.5) / $800 = 1.25
- Status: ✅ Healthy (125% of minimum)

Example 2: At Liquidation Threshold
- Collateral: $2000 wETH
- DSC Minted: $1000
- Calculation: ($2000 × 0.5) / $1000 = 1.0
- Status: ⚠️ Exactly at threshold

Example 3: Liquidatable Position
- Collateral: $2000 wETH
- DSC Minted: $1200
- Calculation: ($2000 × 0.5) / $1200 = 0.833
- Status: ❌ Can be liquidated
```

**Edge case handling:**

If `totalDscMinted = 0`, the function would divide by zero. This is prevented by the system design:

-   Users must deposit collateral first (`depositCollateral()`)
-   They can only mint if health factor check passes
-   Health factor is only checked when DSC is minted, so `totalDscMinted > 0` when this function is called

### Design Patterns

**CEI (Checks-Effects-Interactions)**

All state-changing functions follow this pattern to prevent reentrancy:

1. **Checks:** Input validation via modifiers
2. **Effects:** Update contract state
3. **Interactions:** Call external contracts

**Example in depositCollateral():**

```solidity
// Checks: moreThanZero, isAllowedToken, nonReentrant
// Effects:
s_collateralDeposited[msg.sender][token] += amount;
emit CollateralDeposited(...);
// Interactions:
IERC20(token).transferFrom(msg.sender, address(this), amount);
```

**Example in mintDsc():**

```solidity
// Checks: moreThanZero, nonReentrant
// Effects:
s_dscMinted[msg.sender] += amountDscToMint;
_revertIfHealthFactorIsBroken(msg.sender);  // Additional validation
// Interactions:
bool minted = i_dsc.mint(msg.sender, amountDscToMint);
```

---

## Deployment & Testing

### ERC20Mock.sol

Custom mock ERC20 token for local testing on Anvil/Foundry.

**Constructor Parameters:**

```solidity
constructor(
    string memory name,           // Token name (e.g., "Wrapped Ether")
    string memory symbol,         // Token symbol (e.g., "WETH")
    address initialHolder,        // Initial recipient of minted tokens
    uint256 initialSupply         // Amount to mint to initialHolder
)
```

**Example usage in tests:**

```solidity
ERC20Mock wETH = new ERC20Mock("Wrapped Ether", "WETH", msg.sender, 1000e18);
ERC20Mock wBTC = new ERC20Mock("Wrapped Bitcoin", "WBTC", msg.sender, 1000e8);
```

**Available functions:**

-   `mint(address to, uint256 amount)` - Mint tokens (public)
-   `burn(address from, uint256 amount)` - Burn tokens (public)
-   Standard ERC20 functions: `transfer()`, `approve()`, `balanceOf()`

### MockV3Aggregator.sol

Chainlink price feed mock for simulating oracle responses in tests. Source: Chainlink test utilities.

**Constructor Parameters:**

```solidity
constructor(
    uint8 _decimals,          // Decimal places (8 for Chainlink feeds)
    int256 _initialAnswer     // Initial price (e.g., 200000000000 for $2000 with 8 decimals)
)
```

**Key Functions:**

-   `latestRoundData()` - Returns current price, mimics actual Chainlink interface
-   `updateAnswer(int256 _answer)` - Update current price for testing different scenarios
-   `getRoundData(uint80 _roundId)` - Get historical price data by round ID
-   `description()` - Returns contract identifier

**Why this design matters:**

The mock implements the exact same `latestRoundData()` interface that DSCEngine expects from Chainlink's `AggregatorV3Interface`. This allows DSCEngine to work identically whether using real Chainlink feeds or mock feeds in tests.

**Example usage in HelperConfig:**

```solidity
MockV3Aggregator wETH_USDPriceFeed = new MockV3Aggregator(8, 2000e8);      // $2000 with 8 decimals
MockV3Aggregator wBTC_USDPriceFeed = new MockV3Aggregator(8, 80000e8);     // $80,000 with 8 decimals
```

This allows tests to:

-   Simulate price movements by calling `updateAnswer()`
-   Test edge cases (extreme prices, flash crashes)
-   Avoid external dependencies and ensure deterministic test results

### HelperConfig.s.sol

Configuration contract that sets up environment-specific addresses for both Sepolia testnet and local Anvil development.

**Structure:**

```solidity
struct NetworkConfig {
    address wETH_UsdPriceFeed;    // Chainlink ETH/USD feed
    address wBTC_UsdPriceFeed;    // Chainlink BTC/USD feed
    address wETH;                 // wETH token address
    address wBTC;                 // wBTC token address
    uint256 deployerKey;          // Private key for transactions
}
```

**Configuration Constants:**

```solidity
uint8 DECIMALS = 8;              // Chainlink oracle decimals
int256 ETH_USD_PRICE = 2000e8;   // Mock ETH price: $2000
int256 BTC_USD_PRICE = 80000e8;  // Mock BTC price: $80,000
uint256 DEFAULT_ANVIL_KEY = 0xac097...  // Default Anvil private key
```

**Network Configurations:**

**Sepolia (Ethereum testnet):**

```solidity
function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
    return NetworkConfig({
        wETH_UsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
        wBTC_UsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
        wETH: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
        wBTC: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
        deployerKey: vm.envUint("PRIVATE_KEY")  // Read from .env
    });
}
```

**Anvil/Local (default):**

```solidity
function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory)
```

**Process:**

1. Check if already initialized (early return to save gas)
2. Deploy `MockV3Aggregator` for ETH and BTC price feeds
3. Deploy `ERC20Mock` tokens (wETH and wBTC) with initial supply
4. Return configuration pointing to locally deployed contracts

### DeployDSC.s.sol

Foundry script that deploys the entire DSC protocol.

**Deployment Flow:**

```solidity
function run() external returns (DSC, DSCEngine) {
    // 1. Get network configuration
    HelperConfig helperConfig = new HelperConfig();
    (address wethUsdPriceFeed, address wbtcUsdPriceFeed,
     address weth, address wbtc, uint256 deployerKey) = helperConfig.activeNetworkConfig();

    // 2. Prepare arrays for DSCEngine
    tokenAddresses = [weth, wbtc];
    priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

    // 3. Deploy contracts
    vm.startBroadcast(deployerKey);
    DSC dsc = new DSC();
    DSCEngine dscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    vm.stopBroadcast();

    // 4. Transfer DSC ownership to DSCEngine
    dsc.transferOwnership(address(dscEngine));

    return (dsc, dscEngine);
}
```

**Key Points:**

-   DSC is deployed first (before DSCEngine can reference it)
-   DSCEngine receives DSC address in constructor
-   Ownership of DSC is transferred to DSCEngine immediately
-   Returns both contracts for use in tests/verification

**Running the script:**

```bash
# Local (Anvil)
forge script script/DeployDSC.s.sol --rpc-url http://localhost:8545 --broadcast

# Sepolia
forge script script/DeployDSC.s.sol --rpc-url https://eth-sepolia.alchemyapi.io/v2/YOUR_KEY --broadcast --verify
```

---

## Contract Interaction

### How DSC.sol and DSCEngine.sol Work Together

```
┌──────────────────────────────────────────────────────────────┐
│                      User                        │
└──────────────────┬─────────────────────────────────────────┘
                   │
        ┌──────────┴──────────┐
        │                     │
        ↓ (deposit/mint)      ↓ (no direct access)
┌──────────────────────┐      ┌──────────────────┐
│   DSCEngine          │      │   DSC.sol        │
│                      │◄─────│                  │
│ - Validates          │ mint()│ - Token only     │
│ - Tracks             │─────►│                  │
│   collateral         │ burn()│                  │
└──────────────────────┘      └──────────────────┘
```

### Interaction Flow

**1. Deployment**

```
Deploy DSC.sol
  ↓
Deploy DSCEngine.sol (pass DSC address)
  ↓
Transfer DSC ownership to DSCEngine
  ↓
DSCEngine now controls DSC minting/burning
```

**2. Deposit Collateral**

```
User → DSCEngine.depositCollateral(wETH, amount)
  ↓
DSCEngine validates and tracks collateral
  ↓
wETH transferred from user to DSCEngine
```

**3. Mint DSC (Complete Flow)**

```
User → DSCEngine.mintDsc(amount)
  ↓
DSCEngine: s_dscMinted[user] += amount
  ↓
DSCEngine checks collateral value via Chainlink
  ↓
DSCEngine calculates health factor
  ↓
IF health factor >= 1.0:
  DSCEngine → DSC.mint(user, amount)
  ↓
  DSC tokens created and sent to user
ELSE:
  Revert with DSCEngine__BreaksHealthFactor
```

**4. Burn & Redeem (not yet implemented)**

```
User → DSCEngine.redeemCollateralForDsc(amount)
  ↓
User → DSC.approve(DSCEngine, amount)
  ↓
DSCEngine → DSC.burn(amount)
  ↓
DSCEngine returns collateral to user
```

### Why This Design?

**Separation of Concerns:**

-   DSC.sol = Token logic only (ERC20 standard)
-   DSCEngine.sol = Business logic (collateralization rules, health factors, liquidations)

**Security:**

-   Users cannot directly mint/burn DSC
-   DSCEngine enforces collateralization at all times via health factor checks
-   Single point of control for protocol rules

**Upgradeability:**

-   Can upgrade DSCEngine logic without changing token contract
-   DSC token remains stable and trusted
-   Ownership transfer mechanism allows protocol evolution

---

## Current Implementation Status

| Component             | Status      | Functionality                                |
| --------------------- | ----------- | -------------------------------------------- |
| **DSC.sol**           | ✅ Complete | Token with controlled mint/burn              |
| **DSCEngine.sol**     | 🚧 Partial  | Core minting & health monitoring implemented |
| Chainlink Integration | ✅ Complete | Price feeds connected, USD value calculation |
| Collateral Deposit    | ✅ Complete | Users can deposit wETH/wBTC                  |
| Minting Logic         | ✅ Complete | Minting with health factor validation        |
| Health Factor System  | ✅ Complete | Calculation, validation, and safety checks   |
| Deployment Scripts    | ✅ Complete | DeployDSC, HelperConfig, ERC20Mock           |
| Redemption            | ⏳ Pending  | Burn DSC and withdraw collateral             |
| Liquidation           | ⏳ Pending  | Liquidate undercollateralized positions      |

### Recent Updates (Dec 19, 2025)

**✅ Deployment Infrastructure Complete**

-   `ERC20Mock.sol` - Simple ERC20 for testing collateral tokens
-   `HelperConfig.s.sol` - Network-aware configuration (Sepolia & Anvil)
-   `DeployDSC.s.sol` - Foundry script for full protocol deployment
-   Support for both testnet (Sepolia) and local (Anvil) environments
-   Automatic ownership transfer from DSC to DSCEngine post-deployment

**✅ Testing Environment Ready**

-   Mock price feeds via `MockV3Aggregator` (ETH: $2000, BTC: $80,000)
-   Mock ERC20 tokens via `ERC20Mock` with mint/burn capabilities
-   Configurable deployment across multiple networks (Sepolia & Anvil)
-   Modular test mocks allow isolated unit testing and scenario simulation

<div align="center">
  <i>Documentation updated as development progresses</i>
</div>
