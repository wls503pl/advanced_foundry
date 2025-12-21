# DSC Protocol Design Documentation

> **Last Updated:** December 20, 2025
> **Author:** Peile Wu  
> **Status:** 🚧 In Development

---

## Table of Contents

-   [Overview](#overview)
-   [DSC.sol - Token Contract](#dscsol---token-contract)
-   [DSCEngine.sol - Core Engine](#dscenginesol---core-engine)
-   [Liquidation Mechanism](#liquidation-mechanism)
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
┌──────────────────────────────┐
│     DSC.sol          │  ERC20 stablecoin token
└──────────────────────┬────────┘
           │ owned by
           ↓
┌──────────────────────────────────────────────────────┐
│      DSCEngine.sol                   │  Collateral & minting logic
└──────────────────────────┬──────────────────────────┘
           ↓
           │ uses
           │
    ┌──────────┴──────────┐
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
  └────────────────────────────────────────┬──────────────────────────┘
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
-   **Liquidations** - Protecting system solvency through incentivized liquidations

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
uint256 private constant LIQUIDATION_BONUS = 10;             // 10% bonus for liquidators
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
-   `LIQUIDATION_BONUS = 10`: Liquidators receive 10% extra collateral as incentive (110% total)
-   `MIN_HEALTH_FACTOR = 1e18`: Represents 1.0 in 18-decimal precision. Positions below this can be liquidated

**Example:** With $2000 collateral, user can mint maximum $1000 DSC (50% ratio)

### Custom Errors

```solidity
error DSCEngine__NeedsMoreThanZero();                      // Amount validation
error DSCEngine__AddressLengthOfTokenAndPriceFeedNotMatch();  // Constructor array mismatch
error DSCEngine__NotAllowedToken();                        // Unsupported token
error DSCEngine__TransferFailed();                         // ERC20 transfer failure
error DSCEngine__BreaksHealthFactor(uint256 healthFactor); // Includes actual HF value
error DSCEngine__MintFailed();                             // DSC minting failure
error DSCEngine__HealthFactorOk();                         // Position not liquidatable
error DSCEngine__HealthFactorNotImproved();                // Liquidation didn't improve position
```

### Events

```solidity
event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
event CollateralRedeemed(address indexed token, uint256 amount, address indexed redeemedFrom, address indexed redeemedTo);
```

**Note:** `CollateralRedeemed` now tracks both `redeemedFrom` and `redeemedTo` addresses to support liquidations where collateral is transferred to a different address than the depositor.

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

#### depositCollateralAndMintDsc()

```solidity
function depositCollateralAndMintDsc(
    address tokenCollateralAddress,
    uint256 amountCollateral,
    uint256 amountDscToMint
) external
```

**Purpose:** Users deposit collateral and mint DSC in one transaction for gas efficiency

**Process:**

1. Call `depositCollateral()` to deposit wETH/wBTC
2. Call `mintDsc()` to mint DSC against the collateral
3. Health factor is validated after minting

**Example:**

```
User calls: depositCollateralAndMintDsc(wETH, 10e18, 5000e18)
├─ depositCollateral(wETH, 10e18)
│  ├─ Update: s_collateralDeposited[user][wETH] += 10e18
│  ├─ Emit: CollateralDeposited event
│  └─ Transfer: 10 wETH from user to DSCEngine
└─ mintDsc(5000e18)
   ├─ Update: s_dscMinted[user] += 5000e18
   ├─ Check: Health factor >= 1.0
   └─ Mint: 5000 DSC tokens to user
```

**Gas benefit:** Compared to calling `depositCollateral()` and `mintDsc()` separately, this saves gas by combining validation checks.

#### depositCollateral()

```solidity
function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
    public
    moreThanZero(amountCollateral)
    isAllowedToken(tokenCollateralAddress)
    nonReentrant
```

**Purpose:** Users deposit wETH or wBTC as collateral

**Changed to `public`:** Allows internal calls from `depositCollateralAndMintDsc()` while remaining callable externally

**CEI Pattern (Checks-Effects-Interactions):**

1. **Checks:** Modifiers validate amount > 0, token is allowed, prevents reentrancy
2. **Effects:** Update user's collateral balance, emit event
3. **Interactions:** Transfer tokens from user to contract

**Implementation:**

```solidity
// Effects: Update user's collateral balance in our accounting
s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

// Interactions: Transfer collateral tokens from user to this contract
bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
if (!success) {
    revert DSCEngine__TransferFailed();
}
```

**Example:**

```
User deposits 10 ETH
├─ Check: amount > 0 ✓
├─ Check: wETH is allowed ✓
├─ Check: nonReentrant ✓
├─ Effect: s_collateralDeposited[user][wETH] += 10e18
├─ Emit: CollateralDeposited(user, wETH, 10e18)
└─ Transfer: wETH.transferFrom(user, DSCEngine, 10e18)
```

#### redeemCollateralForDsc()

```solidity
function redeemCollateralForDsc(
    address tokenCollateralAddress,
    uint256 amountCollateral,
    uint256 amountDscToBurn
) external
```

**Purpose:** Users burn DSC tokens and redeem their collateral in one transaction

**Process:**

1. Call `burnDsc()` to burn the user's DSC tokens
2. Call `redeemCollateral()` to withdraw their collateral
3. Health factor is validated during collateral withdrawal

**Example scenario:**

```
User has:
- Collateral: 10 wETH (worth $20,000)
- DSC minted: 8000

User calls: redeemCollateralForDsc(wETH, 5e18, 4000e18)
├─ burnDsc(4000e18)
│  ├─ Update: s_dscMinted[user] -= 4000e18
│  ├─ Transfer: 4000 DSC from user to DSCEngine
│  └─ Burn: 4000 DSC (permanent destruction)
└─ redeemCollateral(wETH, 5e18)
   ├─ Update: s_collateralDeposited[user][wETH] -= 5e18
   ├─ Emit: CollateralRedeemed(user, wETH, 5e18)
   ├─ Transfer: 5 wETH from DSCEngine back to user
   └─ Check: Health factor >= 1.0
```

**Why call burnDsc first?** Reduces debt before checking health factor, making it easier for the health factor check to pass

#### redeemCollateral()

```solidity
function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
    public
    moreThanZero(amountCollateral)
    nonReentrant
```

**Purpose:** Users withdraw their collateral from the protocol

**Changed to `public`:** Allows internal calls from `redeemCollateralForDsc()` while remaining callable externally

**Implementation:**

```solidity
// Low-level helper function that updates state and transfers tokens
_redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);

// Check: Ensure withdrawal doesn't break health factor
_revertIfHealthFactorIsBroken(msg.sender);
```

**Safety mechanism:** Cannot withdraw if it would push health factor below 1.0

**Example of blocked withdrawal:**

```
User has:
- Collateral: 10 wETH = $20,000
- DSC minted: 15,000

User tries to withdraw 8 wETH:
├─ New collateral = 2 wETH = $4,000
├─ Health factor = ($4,000 × 50%) / $15,000 = 0.133 ✗
└─ Reverts: DSCEngine__BreaksHealthFactor(0.133e18)
   User must burn DSC first to reduce debt
```

#### mintDsc()

```solidity
function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant
```

**Purpose:** Users mint DSC stablecoins against their collateral

**Changed to `public`:** Allows internal calls from `depositCollateralAndMintDsc()` while remaining callable externally

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
├─ s_dscMinted[user] += 900e18
├─ Health Factor = ($2000 × 50%) / $900 = 1.11 ✓ (Safe)
├─ DSC.mint(user, 900e18) succeeds
└─ User receives 900 DSC tokens

User tries to mint 200 more DSC (total 1100):
├─ s_dscMinted[user] += 200e18
├─ Health Factor = ($2000 × 50%) / $1100 = 0.91 ✗ (Unsafe)
└─ Reverts: DSCEngine__BreaksHealthFactor(0.91e18)
```

**Safety mechanism:** Cannot mint DSC if it would push health factor below 1.0

#### burnDsc()

```solidity
function burnDsc(uint256 amount) public moreThanZero(amount)
```

**Purpose:** Users burn DSC tokens to reduce their debt and improve health factor

**Changed to `public`:** Allows internal calls from `redeemCollateralForDsc()` while remaining callable externally

**Implementation:**

```solidity
// Low-level helper function that reduces debt and burns tokens
_burnDsc(amount, msg.sender, msg.sender);

// Validate health factor (should always pass since debt is reduced)
_revertIfHealthFactorIsBroken(msg.sender);
```

**Example:**

```
User has:
- Collateral: 10 wETH = $20,000
- DSC minted: 15,000
- Health factor: 0.67 (liquidatable)

User burns 5,000 DSC:
├─ s_dscMinted[user] -= 5000e18 → now 10,000
├─ Transfer: 5000 DSC from user to DSCEngine
├─ Burn: 5000 DSC (permanent destruction)
├─ Health factor: ($20,000 × 50%) / $10,000 = 1.0 ✓
└─ Position becomes healthy
```

**Why approve is needed:** User must call `DSC.approve(DSCEngine, amount)` before calling `burnDsc()` to allow DSCEngine to spend their DSC tokens

---

## Liquidation Mechanism

### Overview

The liquidation mechanism is **critical to protocol solvency**. It ensures the protocol always remains overcollateralized by incentivizing liquidators to quickly close undercollateralized positions.

**Core principle:** Liquidators receive a financial incentive (10% bonus) to cover the debt of risky positions, protecting the protocol from insolvency.

### Why Liquidation Matters

Without liquidation, a scenario could occur where:

```
Scenario: Collateral Plummets
┌─────────────────────────────────────────────────────┐
│ 1. User deposits: 1 ETH @ $2000 = $2000            │
│ 2. User mints: $1000 DSC                           │
│ 3. ETH price crashes: $2000 → $1000                │
│ 4. User's collateral: $1000 < DSC minted: $1000    │
│ 5. Protocol is now INSOLVENT!                      │
│    Total DSC in circulation > Total collateral     │
└─────────────────────────────────────────────────────┘
```

**Without liquidation:** The protocol has no mechanism to recover and DSC would lose its peg.

**With liquidation:** Any liquidator can immediately close the position and prevent insolvency.

### liquidate() Function

```solidity
function liquidate(
    address collateral,        // Collateral to liquidate (wETH or wBTC)
    address user,              // User whose position is unsafe
    uint256 debtToCover        // DSC debt amount to cover
) external moreThanZero(debtToCover) nonReentrant
```

**Purpose:** Anyone can liquidate an undercollateralized position and earn a bonus

**Liquidation Flow:**

```solidity
// 1. Check: Verify user's position is actually liquidatable
uint256 startingUserHealthFactor = _healthFactor(user);
if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
    revert DSCEngine__HealthFactorOk();
}

// 2. Calculate token amount from debt (e.g., $100 DSC debt → 0.1 ETH)
uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

// 3. Add 10% liquidation bonus incentive
uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

// 4. Calculate total collateral to transfer to liquidator
uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

// 5. Effects & Interactions: Transfer bad user's collateral to liquidator
_redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);

// 6. Burn the bad user's DSC debt
_burnDsc(debtToCover, user, msg.sender);

// 7. Check: Verify liquidation actually improved the position
uint256 endingUserHealthFactor = _healthFactor(user);
if (endingUserHealthFactor <= startingUserHealthFactor) {
    revert DSCEngine__HealthFactorNotImproved();
}

// 8. Check: Ensure liquidator's own health factor isn't broken
_revertIfHealthFactorIsBroken(msg.sender);
```

### Liquidation Incentive Mechanism

**The 10% bonus is the key to system solvency:**

```
Bad User Position:
- Collateral: $140 ETH
- DSC Minted: $100

Liquidator covers $100 debt:
├─ Receives: 0.1 ETH worth of collateral ($100)
├─ Receives 10% bonus: 0.01 ETH ($10)
└─ Total received: 0.11 ETH ($110)

Result: Liquidator makes $10 profit for protecting the protocol
        Bad user's position is closed
        Protocol remains solvent
```

**Why this works:**

1. **Profitable for liquidators:** 10% return incentivizes quick action
2. **Protective for protocol:** Undercollateralized positions are quickly eliminated
3. **Fair for bad debtors:** They get their excess collateral back ($30 in example)

### Real-World Liquidation Example

```
Scenario: ETH price crash triggers liquidation

BEFORE LIQUIDATION:
┌──────────────────────────────────────────┐
│ User: Alice                              │
│ Collateral: 10 wETH @ $2000 = $20,000   │
│ DSC Minted: $15,000                      │
│ Health Factor: ($20,000 × 50%) / $15,000 = 0.67 ✗ (LIQUIDATABLE)
└──────────────────────────────────────────┘

ETH PRICE CRASHES: $2000 → $1500
┌──────────────────────────────────────────┐
│ User: Alice                              │
│ Collateral: 10 wETH @ $1500 = $15,000   │
│ DSC Minted: $15,000 (unchanged)          │
│ Health Factor: ($15,000 × 50%) / $15,000 = 0.5 ✗ (VERY LIQUIDATABLE)
└──────────────────────────────────────────┘

LIQUIDATOR CALLS: liquidate(wETH, Alice, 9000)
(Covering $9,000 of Alice's $15,000 debt)

1. Calculate token amount: $9000 DSC → 6 wETH
   (getTokenAmountFromUsd(wETH, 9000e18) = 6e18)

2. Add bonus: 6 wETH × 10% = 0.6 wETH

3. Total transfer: 6 + 0.6 = 6.6 wETH to liquidator

4. Burn Alice's debt: -$9,000 DSC

AFTER LIQUIDATION (Partial):
┌──────────────────────────────────────────┐
│ User: Alice                              │
│ Collateral: 3.4 wETH @ $1500 = $5,100   │
│ DSC Minted: $6,000 (reduced from $15,000)
│ Health Factor: ($5,100 × 50%) / $6,000 = 0.425 ✗ (STILL LIQUIDATABLE)
│ → More liquidators can cover the remaining $6,000 debt
│
│ Liquidator: Bob (earned 0.6 wETH = $900 profit)
│ This incentive ensures quick liquidation in crisis
└──────────────────────────────────────────┘
```

### Protocol Solvency Guarantee

**With the liquidation bonus system:**

```
Protocol Invariant:
Total Collateral Value > Total DSC Minted (always)

Why:
- Users can only mint if: (collateral × 50%) ≥ DSC minted
- When position becomes undercollateralized:
  - Liquidators are incentivized by 10% bonus
  - Quick liquidations prevent cascade failures
  - Protocol's total collateral stays > total DSC

Example Math (200% overcollateralization required):
┌─────────────────────────────────────────┐
│ If all users maxed out:                 │
│ Total Collateral: $100 million          │
│ Max DSC mintable: $50 million (50%)      │
│ → 200% collateralized at max            │
│
│ Even if collateral drops 20%:           │
│ New Collateral: $80 million             │
│ DSC Minted: $50 million (stays same)    │
│ → Still 160% collateralized             │
│ → Positions not liquidated yet          │
│
│ If collateral drops 50%:                │
│ New Collateral: $50 million             │
│ DSC Minted: $50 million                 │
│ → At liquidation threshold              │
│ → Liquidators jump in (10% bonus!)      │
│ → Positions quickly closed              │
│ → Protocol remains solvent              │
└─────────────────────────────────────────┘
```

### Known Limitations

**The system assumes roughly 200% collateralization at all times.** A known edge case exists:

```
Known Bug Scenario (extreme edge case):
├─ Protocol collateral drops below 100%
├─ (e.g., collateral = $50M, DSC minted = $60M)
├─ Liquidators can't be incentivized
│  (They'd lose money covering debt at discount)
├─ Example: $60M debt, $40M collateral
│  → Even at 10% bonus: liquidator receives $40M + $4M = $44M
│  → But they cover $60M debt → lose $16M
│  → No rational liquidator would participate
│
└─ Mitigation: This requires catastrophic collateral collapse BEFORE
   liquidations can execute (e.g., flash crash not caught by oracles)
   Proper oracle design and circuit breakers prevent this in practice
```

**Future Enhancement:** Implement protocol treasury sweep for insolvency:

```solidity
// Pseudo-code for future improvement (as noted in code comments)
// If protocol becomes insolvent, sweep extra collateral to treasury
// Example: liquidate more than debt coverage to accumulate treasury funds
uint256 treasurySweep = excessCollateral * TREASURY_SWEEP_RATIO;
treasury.transfer(treasurySweep);
```

---

### Public View Functions

#### getTokenAmountFromUsd()

```solidity
function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256)
```

**Purpose:** Converts a USD amount to the equivalent token amount using current price feed

**Used by liquidation:** Calculates how many ETH/BTC the liquidator should receive for covering DSC debt

**Formula:** `(USD amount × PRECISION) / (token price × price feed precision)`

**Example:**

```
Input: getTokenAmountFromUsd(wETH, 9000e18)
- USD amount: $9000
- ETH price: $1500 (from Chainlink)
- Calculation: (9000e18 × 1e18) / (150000000000 × 1e10)
- Output: 6e18 (6 ETH)
```

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

**Purpose:** Converts token amount to its USD value

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

**Purpose:** Validates user's position safety after risky operations

**When called:**

-   After minting DSC
-   After withdrawing collateral
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

#### \_healthFactor()

```solidity
function _healthFactor(address user) private view returns (uint256)
```

**Purpose:** Calculates how close a position is to liquidation

**Formula breakdown:**

```
Health Factor = (Collateral Value × Liquidation Threshold) / DSC Minted
             = (Collateral Value × 50%) / DSC Minted
```

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

#### \_burnDsc()

```solidity
function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private
```

**Purpose:** Low-level internal function for burning DSC tokens

**Parameters:**

-   `amountDscToBurn`: DSC amount to destroy
-   `onBehalfOf`: User whose debt is being reduced
-   `dscFrom`: Address to transfer DSC from (can be liquidator)

**Used by:**

-   `burnDsc()` - User reduces their own debt
-   `redeemCollateralForDsc()` - User burns DSC to redeem collateral
-   `liquidate()` - Liquidator covers bad user's debt

**Example (liquidation):**

```
liquidate() calls: _burnDsc(9000, alice, bob)
├─ onBehalfOf = alice (whose debt is reduced)
├─ dscFrom = bob (liquidator pays the debt)
└─ Effect: alice's debt -9000, bob's DSC -9000
```

#### \_redeemCollateral()

```solidity
function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to) private
```

**Purpose:** Low-level internal function for transferring collateral

**Parameters:**

-   `tokenCollateralAddress`: Token to transfer (wETH or wBTC)
-   `amountCollateral`: Amount to transfer
-   `from`: User whose collateral is withdrawn
-   `to`: Recipient of collateral (can be different in liquidations)

**Used by:**

-   `redeemCollateral()` - User withdraws own collateral
-   `redeemCollateralForDsc()` - User redeems collateral
-   `liquidate()` - Transfer bad user's collateral to liquidator

**Example (liquidation):**

```
liquidate() calls: _redeemCollateral(wETH, 6.6, alice, bob)
├─ from = alice (whose collateral is withdrawn)
├─ to = bob (liquidator receives collateral)
└─ Effect: Transfer 6.6 wETH from DSCEngine to bob
           (deducted from alice's collateral)
```

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

### MockV3Aggregator.sol

Chainlink price feed mock for simulating oracle responses in tests.

**Constructor Parameters:**

```solidity
constructor(
    uint8 _decimals,          // Decimal places (8 for Chainlink feeds)
    int256 _initialAnswer     // Initial price (e.g., 200000000000 for $2000)
)
```

### HelperConfig.s.sol

Configuration contract for environment-specific addresses (Sepolia testnet and local Anvil).

**Key Structure:**

```solidity
struct NetworkConfig {
    address wETH_UsdPriceFeed;    // Chainlink ETH/USD feed
    address wBTC_UsdPriceFeed;    // Chainlink BTC/USD feed
    address wETH;                 // wETH token address
    address wBTC;                 // wBTC token address
    uint256 deployerKey;          // Private key for transactions
}
```

### DeployDSC.s.sol

Foundry script that deploys the entire DSC protocol with proper ownership transfer.

### Testing with DSCEngineTest.t.sol

Comprehensive unit tests using Foundry framework.
