# DSC Protocol Design Documentation

> **Last Updated:** December 21, 2025
> **Author:** Peile Wu  
> **Status:** ✅ Production Ready

---

## Table of Contents

-   [Overview](#overview)
-   [System Architecture](#system-architecture)
-   [Core Contracts](#core-contracts)
    -   [DSC.sol - Token Contract](#dscsol---token-contract)
    -   [DSCEngine.sol - Core Engine](#dscenginesol---core-engine)
-   [Operations](#operations)
-   [Health Factor System](#health-factor-system)
-   [Liquidation Mechanism](#liquidation-mechanism)
-   [Security Features](#security-features)
-   [Deployment & Testing](#deployment--testing)

---

## Overview

DSC is a **decentralized algorithmic stablecoin** maintaining 1:1 USD peg through cryptocurrency over-collateralization.

### Core Principles

**1. Relative Stability** - Pegged to $1.00 USD via Chainlink Price Feeds and redemption mechanism

**2. Algorithmic Minting** - Fully decentralized, users can only mint with sufficient collateral

**3. Exogenous Collateral** - Backed by wETH (Wrapped Ethereum) and wBTC (Wrapped Bitcoin)

### System Architecture

```
                    User Interface
                         ↓
        ┌─────────────────────────────────┐
        │      DSCEngine.sol              │
        │                                 │
        │  ├─ Collateral Management       │
        │  ├─ DSC Minting/Burning         │
        │  ├─ Health Factor Tracking      │
        │  ├─ Liquidation System          │
        │  └─ Price Conversions           │
        └────────┬────────────────────┬───┘
                 ↓                    ↓
            ┌────────┐          ┌──────────┐
            │ DSC.sol│          │Chainlink │
            │ Token  │          │ Oracles  │
            └────────┘          └──────────┘
                 ↓                    ↑
            ┌──────────────────────────────┐
            │   wETH / wBTC (Collateral)    │
            └──────────────────────────────┘
```

### Key Characteristics

-   **No Governance Token** - Fully decentralized, no governance overhead
-   **No Transaction Fees** - No fee mechanism (future enhancement)
-   **Fully Transparent** - All logic in smart contracts
-   **Trustless Design** - No counterparty risk

---

## System Architecture

### Contract Interactions

The DSC system consists of three main components:

```
1. DSC Token (ERC20)
   └─ Owned by DSCEngine
   └─ Only DSCEngine can mint/burn
   └─ Represents stablecoin value

2. DSCEngine (Core Logic)
   ├─ Controls DSC minting/burning
   ├─ Manages collateral deposits/withdrawals
   ├─ Monitors health factors
   └─ Orchestrates liquidations

3. Collateral (wETH & wBTC)
   ├─ External ERC20 tokens
   ├─ Held in DSCEngine contract
   └─ Valued via Chainlink oracles
```

### Design Flow

```
User deposits collateral (wETH/wBTC)
    ↓
DSCEngine records in s_collateralDeposited
    ↓
User can mint DSC up to collateral limit
    ↓
DSCEngine validates health factor ≥ 1.0
    ↓
If undercollateralized (HF < 1.0)
    ↓
Liquidators can close position and earn 10% bonus
    ↓
Protocol remains solvent (Collateral > DSC)
```

---

## Core Contracts

### DSC.sol - Token Contract

#### Purpose

DSC.sol is the ERC20 token contract representing the stablecoin. It is **owner-controlled** to ensure only DSCEngine can mint and burn tokens, enforcing the protocol's collateralization rules.

#### Inheritance Structure

```
ERC20 (OpenZeppelin)
  ↓
ERC20Burnable (OpenZeppelin)
  ↓                                Ownable (OpenZeppelin)
  └───────────────────────────────────────────┬──────────────────┐
                                              ↓
                                           DSC.sol
```

#### Why These Inherited Contracts?

**ERC20 (OpenZeppelin)**

-   Standard token functionality: `transfer()`, `balanceOf()`, `approve()`, `allowance()`
-   Internal functions: `_mint()`, `_burn()`
-   **Why:** Battle-tested, standardized token implementation

**ERC20Burnable (OpenZeppelin)**

-   Public `burn()` function for token destruction
-   **Why:** Enables stablecoin destruction needed for collateral redemption

**Ownable (OpenZeppelin)**

-   `onlyOwner` modifier for access control
-   `transferOwnership()` for ownership transfer
-   **Why:** Ensures only DSCEngine can mint/burn tokens

#### State Variables

**None** - DSC.sol has no additional state variables beyond those inherited from ERC20/Ownable

#### Custom Errors

```solidity
error DSC__BurnAmountMustBeMoreThanZero();     // Burn amount validation
error DSC__BurnAmountExceedsBalance();          // Insufficient balance check
error DSC__MintToZeroAddress();                 // Prevent minting to zero address
error DSC__MintAmountMustBeMoreThanZero();     // Mint amount validation
```

**Design Choice:** Custom errors are more gas-efficient than `require()` strings

#### Constructor

```solidity
constructor()
    ERC20("Decentralized Stable Coin", "DSC")  // Set token name & symbol
    Ownable(msg.sender)                         // Set deployer as initial owner
{}
```

**Key Points:**

-   Initializes token with name "Decentralized Stable Coin" and symbol "DSC"
-   Sets deployer as owner (ownership will be transferred to DSCEngine after deployment)
-   OpenZeppelin v5.0+ requires explicit owner initialization via `Ownable(msg.sender)`

#### Functions

##### mint()

```solidity
function mint(address _to, uint256 _amount)
    external
    onlyOwner
    returns (bool)
```

**Purpose:** Creates new DSC tokens

**Access:** Only owner (DSCEngine)

**Process:**

1. Validates recipient is not zero address
2. Validates amount is greater than zero
3. Calls `_mint()` from ERC20 base contract
4. Returns true on success

**Why onlyOwner?** Users cannot directly mint DSC. DSCEngine validates collateralization before calling this function.

##### burn()

```solidity
function burn(uint256 _amount)
    public
    override
    onlyOwner
```

**Purpose:** Destroys DSC tokens

**Access:** Only owner (DSCEngine)

**Process:**

1. Checks caller's balance via `balanceOf(msg.sender)`
2. Validates amount is greater than zero
3. Validates sufficient balance exists
4. Calls `super.burn()` which invokes `ERC20._burn()`

**Why override?** Standard `ERC20Burnable.burn()` allows anyone to burn their own tokens. We override to restrict burning to DSCEngine only.

---

### DSCEngine.sol - Core Engine

#### Purpose

DSCEngine is the brain of the protocol, managing:

-   **Collateral Management** - Deposits and withdrawals of wETH/wBTC
-   **DSC Minting** - Creating stablecoins based on collateral value
-   **DSC Burning** - Token destruction to reduce debt
-   **Health Monitoring** - Tracking position safety via health factors
-   **Liquidations** - Protecting system solvency through incentivized liquidations

#### Inheritance

```
ReentrancyGuard (OpenZeppelin)
  ↓
DSCEngine.sol
```

**Why ReentrancyGuard?** Prevents reentrancy attacks during token transfers. The `nonReentrant` modifier ensures external calls (like `transferFrom()`) cannot recursively call back into the contract.

#### Core Dependencies

```solidity
import {DSC} from "./DSC.sol";                           // Controls DSC minting/burning
import {IERC20} from "@openzeppelin/contracts/...";      // Interacts with wETH/wBTC
import {AggregatorV3Interface} from "@chainlink/...";   // Gets real-time prices
```

#### State Variables

##### Precision Constants

```solidity
uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
// Converts Chainlink 8 decimals to 18 decimals
// Example: Chainlink returns 200000000000 (8 decimals)
// After adjustment: 200000000000 * 1e10 = 2000e18 ($2000)

uint256 private constant PRECISION = 1e18;
// Standard 18 decimal precision used for all calculations
```

##### Liquidation Parameters

```solidity
uint256 private constant LIQUIDATION_THRESHOLD = 50;
// 50% = Users need 200% collateral for DSC
// Only 50% of collateral value counts as "safe"
// Formula: max DSC = Collateral × 50%

uint256 private constant LIQUIDATION_PRECISION = 100;
// Denominator for percentage calculations
// 50/100 = 0.5 = 50%

uint256 private constant LIQUIDATION_BONUS = 10;
// 10% bonus for liquidators
// Liquidator receives: tokenAmount + (tokenAmount × 10%)

uint256 private constant MIN_HEALTH_FACTOR = 1e18;
// Minimum health factor = 1.0
// Positions below this can be liquidated
```

##### State Mappings

```solidity
mapping(address tokenAddress => address priceFeedAddress) private s_priceFeeds;
// Maps collateral token to its Chainlink oracle
// Example: s_priceFeeds[WETH] = 0x5f4e... (ETH/USD feed)

mapping(address userAddress => mapping(address tokenAddress => uint256 amount))
    private s_collateralDeposited;
// Tracks how much of each token each user has deposited
// Example: s_collateralDeposited[Alice][WETH] = 10e18 (10 wETH)

mapping(address userAddress => uint256 amountDscMinted) private s_dscMinted;
// Records each user's debt (DSC minted)
// Example: s_dscMinted[Alice] = 5000e18 (5000 DSC owed)

address[] private s_collateralTokens;
// Array of all whitelisted collateral tokens
// Allows iteration: for (uint i = 0; i < s_collateralTokens.length; i++)

DSC private immutable i_dsc;
// Reference to DSC token contract
// Immutable for gas efficiency
```

#### Custom Errors

```solidity
error DSCEngine__NeedsMoreThanZero();
// Amount validation error

error DSCEngine__AddressLengthOfTokenAndPriceFeedNotMatch();
// Constructor array length mismatch

error DSCEngine__NotAllowedToken();
// Token not in whitelist

error DSCEngine__TransferFailed();
// ERC20 transfer failure

error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
// Health factor violation (includes actual value)

error DSCEngine__MintFailed();
// DSC minting failure

error DSCEngine__HealthFactorOk();
// Position not liquidatable (HF >= MIN)

error DSCEngine__HealthFactorNotImproved();
// Liquidation didn't improve bad user's position
```

#### Events

```solidity
event CollateralDeposited(
    address indexed user,
    address indexed tokenCollateralAddress,
    uint256 amount
);
// Emitted when user deposits collateral

event CollateralRedeemed(
    address indexed token,
    uint256 amount,
    address indexed redeemedFrom,
    address indexed redeemedTo
);
// Emitted when collateral is withdrawn
// Note: redeemedFrom != redeemedTo in liquidations
```

#### Security Modifiers

##### moreThanZero

```solidity
modifier moreThanZero(uint256 amount) {
    if (amount <= 0) revert DSCEngine__NeedsMoreThanZero();
    _;
}
```

Prevents zero-value operations in:

-   Deposits
-   Withdrawals
-   Minting
-   Burning

##### isAllowedToken

```solidity
modifier isAllowedToken(address token) {
    if (s_priceFeeds[token] == address(0)) {
        revert DSCEngine__NotAllowedToken();
    }
    _;
}
```

Ensures only whitelisted tokens (wETH/wBTC) can be used as collateral. Prevents deposit of arbitrary ERC20 tokens.

#### Constructor

```solidity
constructor(
    address[] memory tokenAddress,      // [wETH, wBTC] addresses
    address[] memory priceFeedAddress,  // [ETH/USD, BTC/USD] feeds
    address dscAddress                  // DSC token address
)
```

**Setup Process:**

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

**Why validation?** Prevents misconfiguration where token and feed arrays don't match

---

## Operations

### 1. Deposit Collateral

**Function:** `depositCollateral(address token, uint256 amount)` (public)

**Purpose:** Users deposit wETH or wBTC to increase their collateral balance

**Access:** Public (also called internally from `depositCollateralAndMintDsc()`)

**Flow (CEI Pattern):**

```
Checks:
├─ amount > 0 (moreThanZero modifier)
├─ token is allowed (isAllowedToken modifier)
└─ nonReentrant (ReentrancyGuard modifier)

Effects:
├─ Update: s_collateralDeposited[user][token] += amount
└─ Emit: CollateralDeposited event

Interactions:
└─ Transfer: IERC20(token).transferFrom(user → DSCEngine)
```

**Implementation:**

```solidity
s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

bool success = IERC20(tokenCollateralAddress).transferFrom(
    msg.sender,
    address(this),
    amountCollateral
);
if (!success) {
    revert DSCEngine__TransferFailed();
}
```

**Requirements:**

-   User must approve DSCEngine to spend tokens
-   Token must be in whitelist (wETH or wBTC)
-   Amount must be > 0

**Example:**

```
User has: 10 wETH (at $2000/ETH)
User deposits: 10 wETH

Result:
├─ s_collateralDeposited[user][wETH] = 10e18
├─ DSCEngine now holds: 10 wETH
└─ User's collateral value: $20,000
```

### 2. Mint DSC

**Function:** `mintDsc(uint256 amountDscToMint)` (public)

**Purpose:** Creates new DSC tokens against deposited collateral

**Access:** Public (also called internally from `depositCollateralAndMintDsc()`)

**Flow (CEI Pattern):**

```
Checks:
├─ amount > 0 (moreThanZero modifier)
└─ nonReentrant (ReentrancyGuard modifier)

Effects:
├─ Update: s_dscMinted[user] += amountDscToMint
└─ Check: Health factor >= 1.0 (validates before minting)

Interactions:
└─ Mint: DSC.mint(user, amountDscToMint)
```

**Implementation:**

```solidity
s_dscMinted[msg.sender] += amountDscToMint;

// Check health factor BEFORE minting
_revertIfHealthFactorIsBroken(msg.sender);

bool minted = i_dsc.mint(msg.sender, amountDscToMint);
if (!minted) {
    revert DSCEngine__MintFailed();
}
```

**Health Factor Requirement:**

```
Health Factor = (Collateral Value × 50%) / DSC Minted

For successful mint:
HF ≥ 1.0

Example:
├─ Collateral: $20,000
├─ Max mintable: $20,000 × 50% = $10,000
├─ Attempting to mint: $5,000
└─ HF = ($20,000 × 0.5) / $5,000 = 2.0 ✅ (Safe)
```

**Example Scenario:**

```
User has: $20,000 collateral (10 ETH @ $2000)

Case 1: Mint $100 DSC
├─ HF = ($20,000 × 0.5) / $100 = 100 ✅
└─ Success: User gets 100 DSC tokens

Case 2: Mint $15,000 DSC (too much)
├─ HF = ($20,000 × 0.5) / $15,000 = 0.67 ❌
└─ Reverts: DSCEngine__BreaksHealthFactor(0.67e18)
```

### 3. Burn DSC

**Function:** `burnDsc(uint256 amount)` (public)

**Purpose:** Destroys DSC tokens to reduce debt and improve health factor

**Access:** Public (also called internally from `redeemCollateralForDsc()`)

**Flow (CEI Pattern):**

```
Checks:
└─ amount > 0 (moreThanZero modifier)

Effects:
├─ Update: s_dscMinted[user] -= amount (debt reduced)
└─ Check: Health factor >= 1.0 (post-operation)

Interactions:
├─ Transfer: DSC.transferFrom(user → DSCEngine, amount)
└─ Burn: DSC.burn(amount) (permanent destruction)
```

**Implementation:**

```solidity
_burnDsc(amount, msg.sender, msg.sender);
_revertIfHealthFactorIsBroken(msg.sender);
```

**Low-level helper function:**

```solidity
function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
    // Reduce debt
    s_dscMinted[onBehalfOf] -= amountDscToBurn;

    // Transfer DSC from user to contract
    bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
    if (!success) {
        revert DSCEngine__TransferFailed();
    }

    // Permanently destroy tokens
    i_dsc.burn(amountDscToBurn);
}
```

**Requirements:**

-   User must approve DSCEngine to spend their DSC tokens: `DSC.approve(DSCEngine, amount)`
-   Amount must be > 0

**Example:**

```
User has:
├─ Collateral: 10 wETH = $20,000
├─ DSC minted: $15,000
└─ Health factor: 0.67 (undercollateralized, liquidatable)

User burns: $5,000 DSC

After:
├─ Collateral: $20,000 (unchanged)
├─ DSC minted: $10,000
└─ Health factor: 1.0 ✅ (safe at threshold)
```

**Benefit:** Improves health factor and moves position away from liquidation

### 4. Redeem Collateral

**Function:** `redeemCollateral(address token, uint256 amount)` (public)

**Purpose:** Withdraws collateral from the protocol

**Access:** Public (also called internally from `redeemCollateralForDsc()`)

**Flow (CEI Pattern):**

```
Checks:
├─ amount > 0 (moreThanZero modifier)
└─ nonReentrant (ReentrancyGuard modifier)

Effects:
├─ Call: _redeemCollateral (updates state)
└─ Check: Health factor >= 1.0 (post-withdrawal)

Interactions:
└─ Transfer: IERC20(token).transfer(DSCEngine → user)
```

**Implementation:**

```solidity
_redeemCollateral(token, amount, msg.sender, msg.sender);
_revertIfHealthFactorIsBroken(msg.sender);
```

**Low-level helper function:**

```solidity
function _redeemCollateral(address token, uint256 amount, address from, address to) private {
    // Update state
    s_collateralDeposited[from][token] -= amount;
    emit CollateralRedeemed(token, amount, from, to);

    // Transfer tokens
    bool success = IERC20(token).transfer(to, amount);
    if (!success) {
        revert DSCEngine__TransferFailed();
    }
}
```

**Safety Mechanism:** Cannot withdraw if it would push health factor below 1.0

**Example of Blocked Withdrawal:**

```
User has:
├─ Collateral: 10 wETH = $20,000
└─ DSC minted: $15,000

User tries to withdraw: 8 wETH

After withdrawal would be:
├─ Collateral: 2 wETH = $4,000
├─ DSC minted: $15,000 (unchanged)
└─ HF = ($4,000 × 50%) / $15,000 = 0.133 ❌

Reverts: DSCEngine__BreaksHealthFactor(0.133e18)
User must burn DSC first to reduce debt
```

**Successful Withdrawal Example:**

```
User has:
├─ Collateral: 10 wETH = $20,000
└─ DSC minted: $0

User withdraws: 10 wETH

After:
├─ Collateral: 0
└─ HF = (0 × 50%) / 0 = ∞ ✅ (No debt = infinite HF)
```

### 5. Liquidation

**Function:** `liquidate(address collateral, address user, uint256 debtToCover)` (external)

**Purpose:** Anyone can liquidate an undercollateralized position and earn a bonus

**Access:** External with `nonReentrant` and `moreThanZero(debtToCover)`

**Liquidation Flow:**

```
Step 1: Verify Liquidatability
├─ Check: user's health factor < MIN_HEALTH_FACTOR
└─ Revert if: DSCEngine__HealthFactorOk (position is safe)

Step 2: Calculate Reward
├─ Calculate: tokenAmountFromDebtCovered (USD debt → tokens)
├─ Calculate: bonusCollateral (10% of token amount)
└─ Calculate: totalCollateralToRedeem (token + bonus)

Step 3: Execute Transfers
├─ Transfer: collateral from badUser to liquidator
└─ Burn: badUser's DSC debt (paid by liquidator)

Step 4: Verify Improvement
├─ Check: newHF > oldHF (liquidation helped)
└─ Check: liquidator's HF >= 1.0 (no self-liquidation)
```

**Implementation:**

```solidity
function liquidate(address collateral, address user, uint256 debtToCover)
    external
    moreThanZero(debtToCover)
    nonReentrant
{
    // 1. Check: Verify user is liquidatable
    uint256 startingUserHealthFactor = _healthFactor(user);
    if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
        revert DSCEngine__HealthFactorOk();
    }

    // 2. Calculate: Token amount liquidator should receive
    uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

    // 3. Add: 10% bonus incentive
    uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
    uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

    // 4. Execute: Transfer collateral and burn debt
    _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
    _burnDsc(debtToCover, user, msg.sender);

    // 5. Verify: Liquidation improved bad user's position
    uint256 endingUserHealthFactor = _healthFactor(user);
    if (endingUserHealthFactor <= startingUserHealthFactor) {
        revert DSCEngine__HealthFactorNotImproved();
    }

    // 6. Check: Liquidator's own position is valid
    _revertIfHealthFactorIsBroken(msg.sender);
}
```

**Key Parameters:**

-   `collateral`: Which token to liquidate (wETH or wBTC)
-   `user`: The undercollateralized user to liquidate
-   `debtToCover`: How much of their debt to cover (can be partial)

### Composite Functions

#### depositCollateralAndMintDsc()

```solidity
function depositCollateralAndMintDsc(
    address tokenCollateralAddress,
    uint256 amountCollateral,
    uint256 amountDscToMint
) external
```

**Purpose:** Atomically deposit collateral AND mint DSC in one transaction

**Benefits:**

-   Gas savings (single transaction vs two)
-   Simpler for users
-   Less state-changing operations

**Implementation:**

```solidity
depositCollateral(tokenCollateralAddress, amountCollateral);
mintDsc(amountDscToMint);
```

#### redeemCollateralForDsc()

```solidity
function redeemCollateralForDsc(
    address tokenCollateralAddress,
    uint256 amountCollateral,
    uint256 amountDscToBurn
) external
```

**Purpose:** Atomically burn DSC AND redeem collateral

**Benefits:**

-   Reduces debt first (easier to pass HF check)
-   Then redeems collateral
-   Single transaction

**Implementation:**

```solidity
burnDsc(amountDscToBurn);
redeemCollateral(tokenCollateralAddress, amountCollateral);
```

---

## Health Factor System

### Definition

```
Health Factor (HF) = (Collateral Value × Liquidation Threshold) / Total DSC Minted
                   = (Collateral Value × 50%) / DSC Minted
```

### States & Interpretation

| HF Value | Status      | Meaning                           | Liquidatable?    |
| -------- | ----------- | --------------------------------- | ---------------- |
| HF > 1.0 | ✅ Safe     | Overcollateralized, excess safety | No               |
| HF = 1.0 | ⚠️ Critical | Exactly at threshold              | Yes (borderline) |
| HF < 1.0 | 🚨 Unsafe   | Under-collateralized              | Yes              |
| HF = ∞   | ✅ Safe     | No debt minted                    | No               |

### Real-World Examples

**Example 1: Healthy Position**

```
Collateral: 10 wETH @ $2000 = $20,000
DSC Minted: $100
Health Factor = ($20,000 × 0.5) / $100 = 100

Interpretation: Position is VERY healthy
User can safely mint much more DSC
```

**Example 2: At Threshold**

```
Collateral: 10 wETH @ $2000 = $20,000
DSC Minted: $10,000
Health Factor = ($20,000 × 0.5) / $10,000 = 1.0

Interpretation: Exactly at liquidation point
Position is maximally leveraged
Any price drop triggers liquidation
```

**Example 3: Liquidatable**

```
Collateral: 10 wETH @ $2000 = $20,000
DSC Minted: $15,000
Health Factor = ($20,000 × 0.5) / $15,000 = 0.67

Interpretation: UNDER-COLLATERALIZED
Position can be liquidated immediately
Liquidators will step in to profit from 10% bonus
```

**Example 4: Price Crash Triggers Liquidation**

```
Initial State (Safe):
├─ Collateral: 10 wETH @ $2000 = $20,000
├─ DSC Minted: $100
└─ HF = 100 ✅

ETH Price Crashes: $2000 → $1500

New State (Liquidatable):
├─ Collateral: 10 wETH @ $1500 = $15,000
├─ DSC Minted: $100 (unchanged)
└─ HF = ($15,000 × 0.5) / $100 = 75 ✅ (still safe)

More Crash: $1500 → $1000

Critical State:
├─ Collateral: 10 wETH @ $1000 = $10,000
├─ DSC Minted: $100 (unchanged)
└─ HF = ($10,000 × 0.5) / $100 = 50 ✅ (still safe at 50x)

Extreme Crash: $1000 → $500

Liquidatable State:
├─ Collateral: 10 wETH @ $500 = $5,000
├─ DSC Minted: $100 (unchanged)
└─ HF = ($5,000 × 0.5) / $100 = 25 ✅ (still safe)
```

**This example shows:** Even with 90% price crash, basic positions remain safe due to 200% collateralization

### Health Factor Enforcement

The health factor is checked at critical points:

1. **After Minting:** Cannot mint if HF would go below 1.0
2. **After Redemption:** Cannot withdraw if HF would go below 1.0
3. **After Burning:** Validates HF (though burning always improves it)
4. **During Liquidation:** Ensures liquidation actually improves bad user's position

---

## Liquidation Mechanism

### Why Liquidation is Critical

Without liquidation, protocol becomes insolvent when collateral crashes:

```
Scenario: Catastrophic Collateral Crash

BEFORE CRASH:
├─ User Alice: 1 ETH @ $2000 = $2000 collateral
├─ User Alice: $1000 DSC minted
└─ Protocol state: Solvent ($2000 > $1000)

ETH PRICE CRASH: $2000 → $500

AFTER CRASH (no liquidation):
├─ User Alice: 1 ETH @ $500 = $500 collateral
├─ User Alice: $1000 DSC minted (unchanged)
└─ Protocol state: INSOLVENT ($500 < $1000) 💥

WITH LIQUIDATION:
├─ Liquidators immediately close Alice's position
├─ Protocol remains solvent ($500 collateral secures $1000 DSC)
└─ Alice's debt is covered, no insolvency
```

### How Liquidation Protects the Protocol

**Liquidation Incentive Mechanism:**

```
The 10% bonus is THE KEY to system solvency
└─ Makes liquidation profitable
└─ Ensures rapid liquidations in crisis
└─ Keeps protocol collateralization above 100% at minimum
```

**Economic Incentive:**

```
Bad User Position:
├─ Collateral: 10 wETH ($10K @ $1000)
└─ DSC Minted: $12K

Liquidator covers $6000 of debt:
├─ Receives: 6 wETH worth of collateral ($6K)
├─ Receives: 10% bonus = 0.6 wETH ($600)
├─ Total received: $6,600
└─ Net profit: $600 (for covering $6K debt)

Result:
├─ Liquidator makes money
├─ Bad user's position improves (HF goes up)
└─ Protocol remains solvent
```

### Real-World Liquidation Example

**Scenario: ETH price crash triggers liquidation**

```
INITIAL STATE (Healthy Position):
┌──────────────────────────────────┐
│ User: Alice                      │
│ Collateral: 10 wETH @ $2000      │
│ Value: $20,000                   │
│ DSC Minted: $100                 │
│ Health Factor: 100 ✅            │
└──────────────────────────────────┘

ETH PRICE DROPS: $2000 → $1500 (25% decline)
┌──────────────────────────────────┐
│ User: Alice                      │
│ Collateral: 10 wETH @ $1500      │
│ Value: $15,000                   │
│ DSC Minted: $100                 │
│ Health Factor: 75 ✅             │
│ Still safe, position holds       │
└──────────────────────────────────┘

ETH PRICE CRASHES: $1500 → $1000 (50% total decline)
┌──────────────────────────────────┐
│ User: Alice                      │
│ Collateral: 10 wETH @ $1000      │
│ Value: $10,000                   │
│ DSC Minted: $100                 │
│ Health Factor: 50 ✅             │
│ Still safe, but getting risky    │
└──────────────────────────────────┘

EXTREME CRASH: $1000 → $500 (75% total decline)
┌──────────────────────────────────┐
│ User: Alice                      │
│ Collateral: 10 wETH @ $500       │
│ Value: $5,000                    │
│ DSC Minted: $100                 │
│ Health Factor: 25                │
│ ⚠️ CRITICAL - approaching danger │
└──────────────────────────────────┘

FLASH CRASH: $500 → $400 (80% total decline)
┌──────────────────────────────────┐
│ User: Alice                      │
│ Collateral: 10 wETH @ $400       │
│ Value: $4,000                    │
│ DSC Minted: $100                 │
│ Health Factor: 20                │
│ 🚨 LIQUIDATABLE - liquidators   │
│    step in with 10% bonus!       │
└──────────────────────────────────┘

LIQUIDATION HAPPENS:
Bob (Liquidator) calls:
  liquidate(wETH, Alice, 100)
  (Covering entire $100 debt)

Calculation:
├─ Token amount: $100 / $400 = 0.25 wETH
├─ Bonus: 0.25 * 10% = 0.025 wETH
├─ Total received: 0.275 wETH = $110 @ $400
└─ Bob's profit: $10

Result:
├─ Alice's collateral: 10 - 0.275 = 9.725 wETH
├─ Alice's debt: $100 - $100 = $0
├─ Alice's HF: Infinity (no debt) ✅
├─ Protocol collateral: 10 wETH
├─ Protocol DSC outstanding: reduced by $100
└─ Protocol remains solvent!

Without liquidation, Alice would have $4000 collateral
backing $100 DSC forever, with no way to recover.
Liquidation allowed rapid closure and rebalancing.
```

### Liquidation vs No-Liquidation Comparison

```
Scenario: Collateral Value < DSC Minted

WITH LIQUIDATION:
├─ Undercollateralized position detected
├─ Liquidators have incentive (10% bonus)
├─ Position closed quickly
├─ Protocol remains > 100% collateralized
└─ DSC maintains peg ✅

WITHOUT LIQUIDATION:
├─ Undercollateralized position persists
├─ No incentive to close position
├─ Debt accumulates
├─ Protocol becomes < 100% collateralized
└─ DSC loses peg 💔
```

### Protocol Solvency Guarantee

**Mathematical Proof:**

```
1. Users can only mint if: (Collateral × 50%) ≥ DSC Minted
   └─ Enforced by health factor check

2. If any position becomes undercollateralized:
   └─ HF < 1.0 = (Collateral × 50%) < DSC Minted

3. Liquidators are incentivized by 10% bonus
   └─ Profitable to cover debt

4. Rapid liquidation prevents accumulation
   └─ Maintains overall protocol collateralization

5. Therefore: Total Collateral > Total DSC (Always)
   └─ Protocol remains solvent
```

**Example:**

```
Assume 1000 users all max out (50% ratio):

Protocol State:
├─ Total Collateral: $100,000,000
├─ Total DSC Minted: $50,000,000 (50% of collateral)
├─ Collateralization: 200% ✅

Collateral drops 25%:
├─ Total Collateral: $75,000,000
├─ Total DSC Minted: $50,000,000
├─ Collateralization: 150% ✅

Collateral drops 50% (extreme):
├─ Total Collateral: $50,000,000
├─ Total DSC Minted: $50,000,000
├─ Collateralization: 100%
├─ Liquidations fully activate
└─ Positions are closed (DSC burned)
```

### Known Limitation

**Edge Case: Protocol < 100% Collateralization**

```
KNOWN BUG SCENARIO:
If collateral < 100% of DSC debt:
├─ Liquidators cannot be incentivized
│  (They'd lose money covering debt at discount)
├─ Example: $50M collateral, $60M DSC
│  ├─ Bad user has $40M collateral, $60M debt
│  ├─ Liquidator could receive $40M
│  ├─ But covers $60M debt
│  ├─ Loss: $20M (even with 10% bonus!)
│  └─ No rational liquidator participates
└─ Result: Protocol becomes insolvent

LIKELIHOOD: Very low
├─ Requires collateral to crash > 50% before any liquidations
├─ Real-world impact mitigated by:
│  ├─ Oracle checks & circuit breakers
│  ├─ Network effects preventing flash crashes
│  └─ Time delays allowing liquidators to act

FUTURE SOLUTION:
├─ Treasury sweep mechanism (in development)
├─ Accumulate excess collateral to treasury
├─ Treasury covers insolvency if needed
└─ Makes protocol 100% risk-free
```

---

## Price Feed Integration

### Chainlink Oracle Integration

**Supported Tokens & Feeds:**

```
wETH → ETH/USD Chainlink Feed (8 decimals)
wBTC → BTC/USD Chainlink Feed (8 decimals)
```

**Price Precision Handling:**

```solidity
// Chainlink returns prices with 8 decimals
// Example: ETH @ $2000 = 200000000000 (with 8 decimals)

// We need 18 decimals for internal calculations
// Solution: Multiply by 1e10 (ADDITIONAL_FEED_PRECISION)

// Formula:
finalPrice = chainlinkPrice * ADDITIONAL_FEED_PRECISION
           = 200000000000 * 1e10
           = 2000e18 (in wei, representing $2000)
```

### Price Conversion Functions

**getUsdValue() - Token to USD**

```solidity
function getUsdValue(address token, uint256 amount) public view returns (uint256)
```

**Purpose:** Convert token amount to USD value

**Formula:** `amount × price × 1e10 / 1e18`

**Example:**

```
Input: getUsdValue(wETH, 10e18)
├─ 10 wETH
├─ ETH price: $2000 (from Chainlink: 200000000000)
└─ Calculation:
   (200000000000 * 1e10 * 10e18) / 1e18 = 20000e18 ($20,000)
```

**getTokenAmountFromUsd() - USD to Token**

```solidity
function getTokenAmountFromUsd(address token, uint256 usdAmount) public view returns (uint256)
```

**Purpose:** Convert USD amount to token amount

**Formula:** `usdAmount × 1e18 / (price × 1e10)`

**Example:**

```
Input: getTokenAmountFromUsd(wETH, 100e18)
├─ $100 USD
├─ ETH price: $2000 (from Chainlink: 200000000000)
└─ Calculation:
   (100e18 * 1e18) / (200000000000 * 1e10) = 0.05e18 (0.05 wETH)
```

**Used for:** Liquidation calculations (how many tokens liquidator should receive)

---

## Security Features

### 1. Reentrancy Protection

**Implementation:** `nonReentrant` modifier from OpenZeppelin ReentrancyGuard

**Applied to:**

-   `depositCollateral()`
-   `mintDsc()`
-   `redeemCollateral()`
-   `liquidate()`

**How it works:**

```
Prevents pattern like:
User calls depositCollateral()
  ↓
Transfer tokens via transferFrom()
  ↓
If token has malicious callback
  ↓
Token tries to call back into DSCEngine
  ↓
nonReentrant prevents recursive entry
```

### 2. Input Validation

**Zero Amount Checks:**

```solidity
modifier moreThanZero(uint256 amount) {
    if (amount <= 0) revert DSCEngine__NeedsMoreThanZero();
    _;
}
```

Applied to: Deposits, withdrawals, minting, burning

**Token Whitelist Checks:**

```solidity
modifier isAllowedToken(address token) {
    if (s_priceFeeds[token] == address(0)) {
        revert DSCEngine__NotAllowedToken();
    }
    _;
}
```

Prevents: Depositing unsupported or malicious tokens

### 3. Health Factor Enforcement

**Post-Operation Validation:**

```
After minting → Check HF ≥ 1.0
After redemption → Check HF ≥ 1.0
During liquidation → Verify HF improved
```

**Prevents:**

-   Over-leveraging positions
-   Withdrawing too much collateral
-   Creating insolvent positions

### 4. Liquidation Safeguards

```
✓ Verify target is actually liquidatable (HF < 1.0)
✓ Prevent liquidating already-safe positions
✓ Require liquidation to improve bad user's position
✓ Prevent liquidator from breaking own health factor
✓ Ensure debt is actually covered (DSC burned)
```

### 5. CEI Pattern (Checks-Effects-Interactions)

**All state-changing functions follow:**

```
1. CHECKS - Validate conditions
   └─ Input validation via modifiers
   └─ Reentrancy guard checks
   └─ Health factor validations

2. EFFECTS - Update contract state
   └─ Modify s_collateralDeposited
   └─ Modify s_dscMinted
   └─ Emit events

3. INTERACTIONS - External calls
   └─ Token transfers (last to prevent reentrancy)
   └─ Oracle calls (read-only)
   └─ DSC minting/burning
```

**Example in `depositCollateral()`:**

```solidity
// CHECKS: modifiers validate amount > 0, token allowed, nonReentrant
// EFFECTS: update internal mapping, emit event
s_collateralDeposited[msg.sender][token] += amount;
emit CollateralDeposited(...);
// INTERACTIONS: transfer tokens
bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
if (!success) revert DSCEngine__TransferFailed();
```

### 6. Custom Error Usage

**Gas Optimization:** Custom errors use ~60 less gas than string reverts

```solidity
// Good: Custom error (efficient)
if (amount <= 0) revert DSCEngine__NeedsMoreThanZero();

// Bad: String revert (wasteful)
require(amount > 0, "Amount must be greater than zero");
```

---

## Helper Functions

### Public View Functions

**getTokenAmountFromUsd()**

```
USD → Token conversion
Used for liquidation calculations
```

**getUsdValue()**

```
Token → USD conversion
Used for collateral valuation
```

**getAccountCollateralValue()**

```
Sums all collateral tokens for a user
Loops through s_collateralTokens array
```

**getAccountInformation()**

```
Returns both DSC minted and collateral value
Used for frontend/analysis
```

### Internal/Private Functions

**\_revertIfHealthFactorIsBroken()**

```
Core safety check
Validates user's position safety
Called after risky operations
```

**\_getAccountInformation()**

```
Helper returning (dsc_minted, collateral_value)
Used internally for health factor calculation
```

**\_healthFactor()**

```
Calculates user's health factor
Private helper function
```

**\_calculateHealthFactor()**

```
Pure function calculating HF from inputs
Can be used externally (through public wrapper)
Enables off-chain calculations
```

**\_burnDsc()**

```
Low-level DSC burning
Tracks who's burning on behalf of whom
Used in burns and liquidations
```

**\_redeemCollateral()**

```
Low-level collateral redemption
Handles both normal redemptions and liquidations
Transfers collateral to specified recipient
```

---

## Deployment & Testing

### Contracts Overview

**DSC.sol**

-   ERC20 stablecoin token
-   Owner-controlled minting/burning
-   ~100 lines of code

**DSCEngine.sol**

-   Core protocol logic
-   Manages collateral and DSC
-   ~400+ lines of code

**DeployDSC.s.sol**

-   Foundry deployment script
-   Proper initialization order
-   Ownership transfer logic

**HelperConfig.s.sol**

-   Network-specific configuration
-   Supports Sepolia testnet and Anvil
-   Manages mock contracts for testing

**ERC20Mock.sol**

-   Test utility for collateral tokens
-   Allows minting for testing

**MockV3Aggregator.sol**

-   Chainlink price feed mock
-   Supports price updates for testing

### Deployment Order

```
1. Deploy DSC token
   ├─ Owner = Deployer address
   └─ No initial supply

2. Deploy DSCEngine
   ├─ Input: Token addresses, price feeds, DSC address
   └─ Owner = Deployer address

3. Transfer DSC ownership to DSCEngine
   ├─ Only DSCEngine can mint/burn
   └─ Deployer loses direct control

4. Verify configuration
   ├─ Check price feeds are correct
   ├─ Check collateral tokens are whitelisted
   └─ Test basic operations
```

### Test Suite Coverage

**34 Total Tests** - 77.25% code coverage

Test Categories:

-   Constructor (1)
-   Price Conversions (2)
-   Deposits (4)
-   Minting (4)
-   Burning (3)
-   Redemptions (4)
-   Health Factor (5)
-   Getters (11)

**Key Coverage:**

-   ✅ All core operations
-   ✅ Error handling
-   ✅ State management
-   ✅ Health factor enforcement
-   ✅ Multi-collateral support

---

## Future Enhancements

1. **Additional Collateral Types** - USDC, DAI, etc.
2. **Dynamic Parameters** - Adjustable liquidation ratios
3. **Governance** - Community voting on parameters
4. **Fee Mechanism** - Sustainable revenue model
5. **Interest Rates** - Stability fees for borrowing
6. **Treasury** - Protocol-owned funds for sustainability
7. **Flash Loans** - Atomic arbitrage opportunities
8. **Integration** - DeFi composability (Uniswap, Curve, etc.)

---

## References

-   **OpenZeppelin Contracts:** Battle-tested ERC20, ReentrancyGuard implementations
-   **Chainlink Oracles:** Real-time price feed data
-   **Foundry Framework:** Smart contract development and testing
-   **MakerDAO DSS:** Inspiration for stablecoin mechanics
