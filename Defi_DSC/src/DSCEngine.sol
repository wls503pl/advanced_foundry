// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DSC} from "./DSC.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Peile Wu
 * @notice Core contract of the DSC system handling minting, redeeming, collateral management and liquidation
 *
 * The system maintains a 1:1 peg to USD with the following properties:
 * - Exogenous Collateral (wETH & wBTC)
 * - Dollar Pegged
 * - Algorithmically Stabilized
 *
 * Similar to DAI: no governance, no fees, backed only by wBTC and wETH.
 *
 * @dev The DSC system MUST always be overcollateralized.
 * The total value of all collateral must always exceed the total value of all minted DSC.
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////
    // Errors
    ///////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__AddressLengthOfTokenAndPriceFeedNotMatch();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();

    ///////////////////
    // State Variables
    ///////////////////

    // Minimum collateral ratio required
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // Double value of the collateral
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // or 1 ???

    // token address -> price feed address
    mapping(address tokenAddress => address priceFeedAddress) private s_priceFeeds;

    // user address -> (token address -> amount)
    mapping(address userAddress => mapping(address tokenAddress => uint256 amount)) private s_collateralDeposited;

    // user address -> amount of DSC minted
    mapping(address userAddress => uint256 amountDscMinted) private s_dscMinted;

    // List of collateral token addresses
    address[] private s_collateralTokens;

    // DSC token contract
    DSC private immutable i_dsc;

    ///////////////////
    // Events
    ///////////////////
    event CollateralDeposited(address indexed user, address indexed tokenCollateralAddress, uint256 amount);
    /// @notice Emitted when user redeems (withdraws) collateral from the protocol
    event CollateralRedeemed(address indexed user, address indexed tokenCollateralAddress, uint256 amount);

    ///////////////////
    // Modifiers
    ///////////////////
    /**
     * @notice Validates that the amount is greater than zero
     * @dev Used to prevent zero-value operations in deposits, withdrawals, minting, and burning
     * @param amount The amount to validate
     */
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    /**
     * @notice Validates that the token address is whitelisted as collateral
     * @dev Only wETH and wBTC are allowed as collateral in this system
     * Prevents users from depositing unsupported tokens
     * @param tokenAddress The ERC20 token address to validate
     */
    modifier isAllowedToken(address tokenAddress) {
        if (s_priceFeeds[tokenAddress] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////////
    // Constructor
    ///////////////////

    /**
     * @notice Initializes the DSCEngine contract with collateral tokens and their price feeds
     * @dev Sets up the mapping between collateral tokens and Chainlink oracles, and connects to DSC contract
     *
     * @param tokenAddress Array of ERC20 token addresses allowed as collateral (e.g., WETH, WBTC)
     * @param priceFeedAddress Array of Chainlink price feed addresses (e.g., ETH/USD, BTC/USD)
     *        Must match tokenAddress array length and order
     * @param dscAddress Address of the pre-deployed DecentralizedStableCoin contract
     *
     * Requirements:
     * - Both arrays must have equal length (each token needs exactly one price feed)
     * - dscAddress must be a valid deployed DSC contract
     *
     * Example:
     * tokenAddress     = [WETH, WBTC]
     * priceFeedAddress = [ETH/USD Feed, BTC/USD Feed]
     * dscAddress       = DSC Contract Address
     */
    constructor(address[] memory tokenAddress, address[] memory priceFeedAddress, address dscAddress) {
        // Ensure each token has exactly one corresponding price feed
        // Prevents misconfiguration where arrays don't match
        if (tokenAddress.length != priceFeedAddress.length) {
            revert DSCEngine__AddressLengthOfTokenAndPriceFeedNotMatch();
        }

        // Create mapping: collateral token → its USD price feed
        // This enables us to fetch real-time prices for collateral valuation
        // e.g., s_priceFeeds[WETH] = 0x5f4e...(ETH/USD Chainlink feed)
        for (uint256 i = 0; i < tokenAddress.length; i++) {
            s_priceFeeds[tokenAddress[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddress[i]);
        }

        // Store reference to DSC stablecoin contract
        // NOTE: This is type-casting, NOT creating a new contract
        // DSC must be deployed first, then its address is passed here
        // Allows this engine to mint/burn DSC when users deposit/withdraw collateral
        i_dsc = DSC(dscAddress);
    }

    ///////////////////
    // External Functions
    ///////////////////

    /**
     * @notice Deposits collateral and mints DSC in a single transaction
     * @dev Combines depositCollateral() and mintDsc() for gas efficiency
     * User deposits wETH/wBTC and receives newly minted DSC based on collateralization ratio
     * @param tokenCollateralAddress The address of the collateral token (wETH or wBTC)
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC tokens to mint
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice Deposits collateral to the protocol
     * @notice Follows CEI(Checks, Effects, Interactions) pattern
     * @dev User deposits wETH or wBTC to increase their collateral balance
     * Can be used to improve health factor or prepare for minting DSC
     * Changed from external to public to allow internal calls from depositCollateralAndMintDsc()
     * @param tokenCollateralAddress The address of the collateral token (wETH or wBTC)
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        // Effects: Update state
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        // Interactions: Transfer tokens from user to contract
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice Redeems collateral by burning DSC tokens
     * @dev Combines burnDsc() and redeemCollateral() in a single transaction for user convenience
     * User burns their DSC tokens to get back their collateral (wETH/wBTC)
     * The amount of collateral returned is the actual amount deposited, adjusted for current accounting
     * Health factor is automatically checked after collateral withdrawal
     * @param tokenCollateralAddress The address of the collateral token to withdraw
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC tokens to burn
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
    }

    /**
     * @notice Withdraws collateral from the protocol
     * @dev User withdraws wETH/wBTC collateral if health factor remains above minimum threshold.
     * Cannot withdraw if it would make position undercollateralized
     * Changed from external to public to allow internal calls from redeemCollateralForDsc()
     * Follows CEI pattern: update state, emit event, transfer tokens, then validate health factor
     * @param tokenCollateralAddress The address of the collateral token to withdraw
     * @param amountCollateral The amount of collateral to redeem
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // Effects: Reduce user's collateral balance
        s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);

        // Interactions: Transfer collateral back to user
        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        // Check: Ensure withdrawal doesn't break health factor
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Mints DSC tokens against deposited collateral
     * @dev Creates new DSC tokens for the user based on their collateral value
     * Requires sufficient collateral to maintain overcollateralization ratio
     * Changed from external to public to allow internal calls from depositCollateralAndMintDsc()
     * @param amountDscToMint The amount of DSC tokens to mint
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;

        // if minted too much DSC ($500 DSC, $200 wETH)
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * @notice Burns DSC tokens to reduce debt and improve health factor
     * @dev Destroys DSC tokens to decrease user's minted DSC balance
     * Improves health factor and frees up collateral for withdrawal
     * Changed from external to public to allow internal calls from redeemCollateralForDsc()
     * User must approve this contract to spend their DSC tokens before calling
     * @param amount The amount of DSC tokens to burn
     */
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        // Effects: Reduce DSC minted by this user
        s_dscMinted[msg.sender] -= amount;
        
        // Interactions: Transfer DSC from user to contract
        bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        
        // Burn the DSC tokens (permanently remove from circulation)
        i_dsc.burn(amount);
        // Check: Validate health factor after debt reduction (should always pass)
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Liquidates an undercollateralized position
     * @dev Anyone can liquidate a position when health factor falls below minimum threshold
     * Liquidator pays off part/all of the debt and receives collateral at a discount
     * Incentivizes maintaining system overcollateralization
     */
    function liquidate() external {}

    ///////////////////
    // Public Functions
    ///////////////////

    /**
     * @notice Calculates the total USD value of all collateral deposited by a user
     * @dev Loops through all collateral tokens (wETH, wBTC) and sums their USD values
     * Uses Chainlink price feeds to get real-time prices
     * @param user The address of the user whose collateral value to calculate
     * @return totalCollateralValueInUsd The total value of user's collateral in USD (18 decimals)
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited
        // and map it to the price to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    /**
     * @notice Converts a token amount to its USD value
     * @dev Uses Chainlink price feed to get current token price and calculates USD value
     * @param token The address of the token (wETH or wBTC)
     * @param amount The amount of tokens to convert
     * @return The USD value of the token amount (18 decimals)
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }

    ///////////////////////////////
    // Internal Functions
    ///////////////////////////////

    /**
     * @notice Checks if a user's health factor is below the minimum threshold and reverts if true
     * @dev Called after operations that could affect health factor (minting, withdrawing collateral)
     * Ensures the system remains overcollateralized by preventing risky operations
     * @param user The address of the user to check
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        // Check health factor (if they have enough collateral)
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            // Revert if health factor is below minimum threshold
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////
    // Private Functions
    ///////////////////////////////

    /**
     * @notice Retrieves a user's account information including DSC minted and collateral value
     * @dev Helper function to get both values in a single call, used for health factor calculation
     * @param user The address of the user
     * @return totalDscMinted The total amount of DSC tokens minted by the user
     * @return collateralValueInUsd The total USD value of the user's collateral
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @notice Calculates the health factor of a user's position
     * @dev Health factor determines how close a position is to liquidation
     * Returns how close to liquidation a user position is
     * If it goes below 1, liquidation will be triggered
     * @param user The address of the user
     * @return The health factor value (if below 1, position can be liquidated)
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return ((collateralAdjustedForThreshold * PRECISION) / totalDscMinted);
    }

    ///////////////////////////////////
    // View & Pure Functions
    ///////////////////////////////////

    /**
     * @notice Returns the health factor of a position
     * @dev Health Factor = (Collateral Value * Liquidation Threshold) / Total DSC Minted
     *
     * Health Factor > 1: Position is healthy (safe)
     * Health Factor = 1: Position is at liquidation threshold
     * Health Factor < 1: Position is undercollateralized (can be liquidated)
     *
     * Example: If liquidation threshold is 50%
     * - $200 collateral, $100 DSC minted → Health Factor = (200 * 0.5) / 100 = 1.0
     * - $200 collateral, $80 DSC minted → Health Factor = (200 * 0.5) / 80 = 1.25 (healthy)
     * - $200 collateral, $120 DSC minted → Health Factor = (200 * 0.5) / 120 = 0.83 (liquidatable)
     */
    function getHealthFactor() external view {}
}