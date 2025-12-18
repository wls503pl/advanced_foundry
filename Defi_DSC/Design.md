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

DSCEngine is the core protocol logic handling:

-   Collateral deposits and withdrawals
-   DSC minting based on collateral value
-   Liquidation of undercollateralized positions
-   Health factor monitoring

### Inheritance

```
ReentrancyGuard (OpenZeppelin)
  ↓
DSCEngine.sol
```

### Why ReentrancyGuard?

**ReentrancyGuard (OpenZeppelin)** provides:

-   `nonReentrant` modifier - Prevents reentrancy attacks
-   Internal state tracking to detect recursive calls

**Why use it:** During collateral deposits/withdrawals, external token transfers could callback into the contract. `nonReentrant` prevents malicious reentrancy attacks.

**How it works:**

```solidity
uint256 private _status = 1;

modifier nonReentrant() {
    require(_status != 2, "ReentrancyGuard: reentrant call");
    _status = 2;  // Lock
    _;
    _status = 1;  // Unlock
}
```

### External Dependencies

**1. IERC20 (OpenZeppelin)**

Interface for ERC20 token interactions:

-   `transferFrom()` - Pull tokens from user to contract
-   `transfer()` - Send tokens from contract to user

**Why use it:** Need to interact with wETH and wBTC tokens

**2. DSC (Custom)**

Reference to the DSC token contract to call:

-   `mint()` - Create new DSC tokens
-   `burn()` - Destroy DSC tokens

**Why use it:** DSCEngine controls token supply based on collateral

### State Variables

```solidity
// Maps collateral token address → Chainlink price feed address
mapping(address => address) private s_priceFeeds;

// Maps user address → (collateral token → deposited amount)
mapping(address => mapping(address => uint256)) private s_collateralDeposited;

// Immutable reference to DSC token contract
DSC private immutable i_dsc;
```

**Naming convention:**

-   `s_` prefix = storage variable
-   `i_` prefix = immutable variable

**Purpose:**

-   `s_priceFeeds` - Links each collateral type to its USD price oracle
-   `s_collateralDeposited` - Tracks how much collateral each user has deposited
-   `i_dsc` - Enables DSCEngine to mint/burn DSC tokens

### Custom Errors

```solidity
error DSCEngine__NeedsMoreThanZero();
error DSCEngine__AddressLengthOfTokenAndPriceFeedNotMatch();
error DSCEngine__NotAllowedToken();
error DSCEngine__TransferFailed();
```

### Events

```solidity
event CollateralDeposited(
    address indexed user,
    address indexed tokenCollateralAddress,
    uint256 amount
);
```

**Purpose:** Emit events for off-chain tracking and indexing

### Modifiers

#### moreThanZero

```solidity
modifier moreThanZero(uint256 amount) {
    if (amount == 0) {
        revert DSCEngine__NeedsMoreThanZero();
    }
    _;
}
```

**Purpose:** Prevents zero-value operations (deposits, withdrawals, minting, burning)

**Used in:** All functions that accept amount parameters

#### isAllowedToken

```solidity
modifier isAllowedToken(address tokenAddress) {
    if (s_priceFeeds[tokenAddress] == address(0)) {
        revert DSCEngine__NotAllowedToken();
    }
    _;
}
```

**Purpose:** Validates token is whitelisted (only wETH/wBTC allowed)

**How it works:** If token has no price feed configured, it's not allowed

**Used in:** All collateral-related functions

### Constructor

```solidity
constructor(
    address[] memory tokenAddress,
    address[] memory priceFeedAddress,
    address dscAddress
)
```

**Purpose:** Initializes the protocol with supported collateral types and their price feeds

**Parameters:**

-   `tokenAddress[]` - Array of collateral token addresses (e.g., [wETH, wBTC])
-   `priceFeedAddress[]` - Array of Chainlink oracle addresses (e.g., [ETH/USD, BTC/USD])
-   `dscAddress` - Address of the DSC token contract

**Process:**

1. Validates both arrays have the same length
2. Maps each token to its price feed: `s_priceFeeds[tokenAddress[i]] = priceFeedAddress[i]`
3. Stores DSC contract reference: `i_dsc = DSC(dscAddress)`

**Example initialization:**

```solidity
new DSCEngine(
    [0xC02a...wETH, 0x2260...wBTC],     // Collateral tokens
    [0x5f4e...ETH_USD, 0xF403...BTC_USD], // Price feeds
    0x1234...DSC_address                  // DSC token
);
```

### Implemented Functions

#### depositCollateral()

```solidity
function depositCollateral(
    address tokenCollateralAddress,
    uint256 amountCollateral
) external
  moreThanZero(amountCollateral)
  isAllowedToken(tokenCollateralAddress)
  nonReentrant
```

**Purpose:** Users deposit wETH or wBTC as collateral

**Parameters:**

-   `tokenCollateralAddress` - Address of collateral token (wETH or wBTC)
-   `amountCollateral` - Amount to deposit

**Security checks (via modifiers):**

1. `moreThanZero` - Amount must be > 0
2. `isAllowedToken` - Token must be whitelisted
3. `nonReentrant` - Prevents reentrancy attacks

**Process (follows CEI pattern):**

**Checks:** Done via modifiers before function body executes

**Effects:** Update state first

```solidity
s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
```

**Interactions:** External calls last

```solidity
bool success = IERC20(tokenCollateralAddress).transferFrom(
    msg.sender,
    address(this),
    amountCollateral
);
if (!success) revert DSCEngine__TransferFailed();
```

**Why CEI pattern?** Prevents reentrancy vulnerabilities by updating state before external calls

**Dependencies:**

-   `IERC20.transferFrom()` - Pulls tokens from user (requires prior approval)

**Example flow:**

```
User approves DSCEngine: wETH.approve(DSCEngine, 10 ether)
  ↓
User calls: depositCollateral(wETH_address, 10 ether)
  ↓
Check: 10 ether > 0 ✓
Check: wETH is allowed ✓
Check: Not a reentrant call ✓
  ↓
Effect: s_collateralDeposited[user][wETH] += 10 ether
Effect: Emit CollateralDeposited event
  ↓
Interaction: wETH.transferFrom(user, DSCEngine, 10 ether)
```

### Design Patterns

**CEI (Checks-Effects-Interactions)**

All functions follow this pattern:

1. **Checks** - Validate inputs via modifiers
2. **Effects** - Update state variables
3. **Interactions** - Call external contracts

**Benefits:**

-   Prevents reentrancy attacks
-   Makes code easier to audit
-   Standard security best practice

---

## Contract Interaction

### How DSC.sol and DSCEngine.sol Work Together

```
┌──────────────────────────────────────────────────────┐
│                      User                             │
└───────────────────┬──────────────────────────────────┘
                    │
         ┌──────────┴──────────┐
         │                     │
         ↓ (deposit)           ↓ (no direct access)
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

**3. Mint DSC (not yet implemented)**

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

| Component             | Status      | Functionality                         |
| --------------------- | ----------- | ------------------------------------- |
| **DSC.sol**           | ✅ Complete | Token with controlled mint/burn       |
| **DSCEngine.sol**     | 🚧 Partial  | Collateral deposit system implemented |
| Chainlink Integration | ⏳ Pending  | Price feed setup in constructor       |
| Minting Logic         | ⏳ Pending  | -                                     |
| Redemption            | ⏳ Pending  | -                                     |
| Liquidation           | ⏳ Pending  | -                                     |
| Health Factor         | ⏳ Pending  | -                                     |

---

<div align="center">
  <i>Documentation updated as development progresses</i>
</div>
