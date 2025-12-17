# DSC Protocol Design Documentation

> **Last Updated:** December 17, 2025  
> **Author:** Peile Wu  
> **Status:** 🚧 In Development

---

## Table of Contents

-   [Design Philosophy](#design-philosophy)
-   [System Architecture](#system-architecture)
-   [Current Implementation](#current-implementation)

---

## Design Philosophy

### Core Concept

DSC is a **decentralized algorithmic stablecoin** maintaining 1:1 USD peg through cryptocurrency over-collateralization.

### Three Pillars

**1. Relative Stability (Peg to $1.00)**

-   Chainlink Price Feeds for real-time valuation
-   Redemption mechanism ensures price stability

**2. Algorithmic Minting (Decentralized)**

-   No central authority controls supply
-   Users mint only with sufficient collateral

**3. Exogenous Collateral (Crypto-backed)**

-   wETH (Wrapped Ethereum)
-   wBTC (Wrapped Bitcoin)

---

## System Architecture

### Contract Structure

```
DSC Protocol = DSC Token + DSCEngine

DSC.sol         - ERC20 stablecoin token
DSCEngine.sol   - Core protocol logic (handles collateral & minting)
```

### Inheritance Design

```
ERC20 (OpenZeppelin)
  ↓
ERC20Burnable (OpenZeppelin)     Ownable (OpenZeppelin)
  ↓                                     ↓
  └──────────────────┬──────────────────┘
                     ↓
                   DSC.sol
```

**Why this structure?**

-   `ERC20` - Standard token functionality
-   `ERC20Burnable` - Burn capability for collateral redemption
-   `Ownable` - Only DSCEngine can mint/burn tokens

---

## Current Implementation

### DSC Token Contract

**File:** `src/DSC.sol`

**Core Functions:**

```solidity
// Minting - Only DSCEngine can mint
function mint(address _to, uint256 _amount) external onlyOwner
  └─ Uses: ERC20._mint()

// Burning - Only DSCEngine can burn
function burn(uint256 _amount) public override onlyOwner
  └─ Uses: ERC20Burnable.burn() → ERC20._burn()
```

**Key Design Decisions:**

1. **Why Ownable?**

    - Users don't directly mint/burn DSC tokens
    - All operations go through DSCEngine which enforces collateralization rules
    - Owner will be set to DSCEngine after deployment

2. **Why override burn()?**

    - Standard ERC20Burnable allows anyone to burn their tokens
    - We need DSCEngine to control burning as part of collateral redemption

3. **Constructor pattern:**
    ```solidity
    constructor()
      ERC20("Decentralized Stable Coin", "DSC")
      Ownable(msg.sender)  // OpenZeppelin v5.0+ requirement
    ```

**Function Dependencies:**

```
mint()
  └─ ERC20._mint() + Ownable.onlyOwner

burn()
  └─ ERC20.balanceOf()
  └─ ERC20Burnable.burn() → ERC20._burn()
```
