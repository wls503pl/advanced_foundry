# DSC Protocol Design Documentation

> **Last Updated:** December 18, 2025  
> **Author:** Peile Wu  
> **Status:** 🚧 In Development

---

## Table of Contents

-   [Overview](#overview)
-   [DSC.sol - Token Contract](#dscsol---token-contract)
-   [DSCEngine.sol - Core Engine](#dscenginesol---core-engine)
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
┌─────────────┐
│   DSC.sol   │  ERC20 stablecoin token
└──────┬──────┘
       │ owned by
       ↓
┌─────────────┐
│ DSCEngine   │  Collateral & minting logic
└─────────────┘
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
  └───────────────┬───────────┘
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

### Custom Errors

```solidity
error DSCEngine__NeedsMoreThanZero();
error DSCEngine__AddressLengthOfTokenAndPriceFeedNotMatch();
error DSCEngine__NotAllowedToken();
error DSCEngine__TransferFailed();
```

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

1. Records user's debt: `s_dscMinted[user] += amountDscToMint`
2. Checks health factor to ensure position is safe
3. If healthy, DSCEngine calls `DSC.mint()` to create tokens

**Example:**

```
User has $2000 collateral, mints 1000 DSC
→ s_dscMinted[user] += 1000e18
→ _revertIfHealthFactorIsBroken(user)  // Validates 200% collateralization
→ DSC.mint(user, 1000e18)
```

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
function _revertIfHealthFactorIsBroken(address user) internal view
```

Validates user's position is safe after operations like minting or withdrawing collateral. Reverts if health factor drops below minimum threshold.

#### \_getAccountInformation()

```solidity
function _getAccountInformation(address user) private view
    returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
```

Helper function that returns both user's debt and collateral value in one call.

#### \_healthFactor()

```solidity
function _healthFactor(address user) private view returns (uint256)
```

Calculates how close a position is to liquidation:

-   Health Factor > 1: Safe
-   Health Factor = 1: At liquidation threshold
-   Health Factor < 1: Can be liquidated

**Formula:** `(Collateral Value × Liquidation Threshold) / DSC Minted`

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

---

## Contract Interaction

### How DSC.sol and DSCEngine.sol Work Together

```
┌──────────────────────────────────────────────────┐
│                      User                        │
└──────────────────┬───────────────────────────────┘
                   │
        ┌──────────┴──────────┐
        │                     │
        ↓ (deposit/mint)      ↓ (no direct access)
┌─────────────────┐       ┌──────────────┐
│   DSCEngine     │       │   DSC.sol    │
│                 │──────→│              │
│ - Validates     │ mint()│ - Token only │
│ - Tracks        │←──────│              │
│   collateral    │ burn()│              │
└─────────────────┘       └──────────────┘
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

**3. Mint DSC**

```
User → DSCEngine.mintDsc(amount)
  ↓
DSCEngine checks collateral value via Chainlink
  ↓
DSCEngine validates health factor
  ↓
DSCEngine → DSC.mint(user, amount)
  ↓
DSC tokens created and sent to user
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

-   DSC.sol = Token logic only
-   DSCEngine.sol = Business logic (collateralization rules)

**Security:**

-   Users cannot directly mint/burn DSC
-   DSCEngine enforces collateralization at all times
-   Single point of control for protocol rules

**Upgradeability:**

-   Can upgrade DSCEngine logic without changing token
-   DSC token remains stable and trusted

---

## Current Implementation Status

| Component             | Status         | Functionality                                |
| --------------------- | -------------- | -------------------------------------------- |
| **DSC.sol**           | ✅ Complete    | Token with controlled mint/burn              |
| **DSCEngine.sol**     | 🚧 Partial     | Collateral deposit & minting implemented     |
| Chainlink Integration | ✅ Complete    | Price feeds connected, USD value calculation |
| Minting Logic         | ✅ Complete    | Basic minting with health factor check       |
| Health Factor         | 🚧 In Progress | Framework ready, calculation logic pending   |
| Redemption            | ⏳ Pending     | -                                            |
| Liquidation           | ⏳ Pending     | -                                            |

---

<div align="center">
  <i>Documentation updated as development progresses</i>
</div>
