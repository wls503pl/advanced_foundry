# Cross-chain Rebase Token

1. A protocol that allows user to deposit assets into a vault, receiving rebase tokens that represent their underlying balance in return.
2. Rebase Token -> balanceOf function is dynamic to show the changing balance with time.
    - Balance increases linearly with time
    - mint tokens to users every time they perform an action (minting, burning, transferring, bridging, etc.)
3. Interest Rate
    - Individually set an interest rate or each user based on some global interest rate of the protocol at the time the user deposits into the vault.
    - This global interest rate can only decrease to incetivise/reward early adopters.