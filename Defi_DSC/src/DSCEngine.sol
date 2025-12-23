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
import {OracleLib} from "./libraries/OracleLib.sol";

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
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////
    // Type
    ///////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////
    // State Variables
    ///////////////////

    // Price feed precision adjustments
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    // Standard precision for internal calculations
    uint256 private constant PRECISION = 1e18;
    // Liquidation threshold: 50% means you need $200 collateral for $100 debt
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    // Used as divisor for liquidation threshold percentage calculations
    uint256 private constant LIQUIDATION_PRECISION = 100;
    // Liquidation bonus: liquidators receive 10% extra collateral as incentive
    uint256 private constant LIQUIDATION_BONUS = 10;
    // Minimum health factor: position gets liquidated when it drops below 1.0
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    // Maps each collateral token to its Chainlink price feed oracle
    mapping(address tokenAddress => address priceFeedAddress) private s_priceFeeds;

    // Maps user address to their collateral deposits (user -> token -> amount)
    mapping(address userAddress => mapping(address tokenAddress => uint256 amount)) private s_collateralDeposited;

    // Maps user address to the amount of DSC they have minted
    mapping(address userAddress => uint256 amountDscMinted) private s_dscMinted;

    // Array of all allowed collateral token addresses for iteration
    address[] private s_collateralTokens;

    // Reference to the DSC stablecoin contract for minting/burning operations
    DSC private immutable i_dsc;

    ///////////////////
    // Events
    ///////////////////
    event CollateralDeposited(address indexed user, address indexed tokenCollateralAddress, uint256 amount);
    /// @notice Emitted when user redeems (withdraws) collateral from the protocol
    event CollateralRedeemed(
        address indexed token, uint256 amount, address indexed redeemedFrom, address indexed redeemedTo
    );

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
        // Effects: Update user's collateral balance in our accounting
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        // Interactions: Transfer collateral tokens from user to this contract
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
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
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
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
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
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Liquidates an undercollateralized position
     * @dev Anyone can liquidate a position when health factor falls below minimum threshold
     * Liquidator pays off part/all of the debt and receives collateral at a discount
     * Incentivizes maintaining system overcollateralization
     * You can partially liquidate a user and receive a liquidation bonus for taking their funds
     * This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
     * A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     * @param collateral The ERC20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor. Their healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the user's health factor
     *
     * Follows CEI patterns: Checks, Effects, Interactions
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // Check: Verify user's position is actually liquidatable (health factor below minimum)
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // Calculate how many tokens the liquidator should receive for covering the debt
        // Example: If covering $100 DSC debt and ETH costs $1000, liquidator gets 0.1 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        // Add 10% bonus to incentivize liquidators (e.g., for 0.1 ETH debt, give 0.11 ETH)
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        // Calculate total collateral to transfer to liquidator
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        // Effects & Interactions: Transfer the bad user's collateral to the liquidator
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);

        // Burn the bad user's DSC debt
        _burnDsc(debtToCover, user, msg.sender);

        // Check: Verify liquidation actually improved the user's position
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        // Check: Ensure liquidator's own health factor isn't broken by paying the debt
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    ///////////////////
    // Public Functions
    ///////////////////

    /**
     * @notice Converts a USD amount to the equivalent token amount using current price feed
     * @dev Fetches price from Chainlink oracle with staleness check via OracleLib
     * @param token The collateral token address (wETH or wBTC)
     * @param usdAmountInWei The USD amount to convert (in wei, 18 decimals)
     * @return The equivalent amount of tokens (in wei, 18 decimals)
     * @dev Reverts if oracle price data is stale (older than 3 hours)
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // Fetch current token price from Chainlink oracle
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        // Formula: (USD amount * PRECISION) / (token price * price feed precision)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
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

    /**
     * @notice Calculates the total USD value of all collateral deposited by a user
     * @dev Loops through all collateral tokens (wETH, wBTC) and sums their USD values
     * Uses Chainlink price feeds to get real-time prices
     * @param user The address of the user whose collateral value to calculate
     * @return totalCollateralValueInUsd The total value of user's collateral in USD (18 decimals)
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // Loop through each collateral token, get the amount they have deposited
        // and map it to the price to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    /**
     * @notice Retrieves a user's account information including DSC minted and collateral value
     * @dev Returns both debt and collateral in a single call
     * @param user The address of the user
     * @return totalDscMinted The total amount of DSC tokens minted by the user
     * @return collateralValueInUsd The total USD value of the user's collateral
     */
    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    /**
     * @notice Calculates health factor from debt and collateral amounts
     * @dev Pure function that can be used for off-chain calculations
     * Separated from _healthFactor to allow external/public access
     * @param totalDscMinted The total DSC debt amount
     * @param collateralValueInUsd The total collateral value in USD
     * @return The calculated health factor (in wei, 18 decimals)
     */
    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
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
     * @notice Burns DSC tokens and removes them from circulation
     * @dev Low-level internal function that handles DSC burning
     * Don't call unless the function calling it is checking for health factors being broken
     * Updates the user's DSC minted balance, transfers DSC from user to contract, then burns it
     * @param amountDscToBurn The amount of DSC tokens to burn
     * @param onBehalfOf The user whose debt is being reduced
     * @param dscFrom The address to transfer DSC tokens from (usually the liquidator)
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        // Effects: Reduce the user's DSC debt balance
        s_dscMinted[onBehalfOf] -= amountDscToBurn;

        // Interactions: Transfer DSC from user/liquidator to contract
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        // Permanently remove DSC tokens from circulation
        i_dsc.burn(amountDscToBurn);
    }

    /**
     * @notice Transfers collateral tokens to a recipient
     * @dev Low-level internal function for updating collateral state and transferring tokens
     * Handles both withdrawals and liquidations
     * @param tokenCollateralAddress The collateral token to transfer
     * @param amountCollateral The amount of collateral to transfer
     * @param from The user whose collateral is being withdrawn (affects state tracking)
     * @param to The recipient of the collateral tokens
     */
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        // Effects: Update state - reduce user's collateral balance
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(tokenCollateralAddress, amountCollateral, from, to);

        // Interactions: Transfer tokens from contract to recipient
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

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
     * @notice Calculates health factor from debt and collateral amounts (internal helper)
     * @dev Used internally to compute health factor without external dependencies
     * Returns max uint256 if user has no debt (infinite health factor)
     * @param totalDscMinted The total DSC debt amount
     * @param collateralValueInUsd The total collateral value in USD
     * @return The calculated health factor (in wei, 18 decimals)
     */
    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        private
        pure
        returns (uint256)
    {
        // Handle case where user has no debt: health factor is infinite (max uint256)
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }

        // Apply liquidation threshold (50%): only 50% of collateral value counts toward safety
        // Example: $200 collateral becomes $100 after threshold
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        // Calculate health factor: adjusted collateral / total debt
        // Health Factor = 1.0 means exactly at liquidation threshold
        return ((collateralAdjustedForThreshold * PRECISION) / totalDscMinted);
    }

    /**
     * @notice Calculates the health factor of a user's position
     * @dev Health factor determines how close a position is to liquidation
     * Returns how close to liquidation a user position is
     * If it goes below 1, liquidation will be triggered
     * Formula: (Collateral Value * Liquidation Threshold / 100) / Total DSC Minted
     * @param user The address of the user
     * @return The health factor value (if below 1, position can be liquidated)
     */
    function _healthFactor(address user) private view returns (uint256) {
        // Get user's DSC minted amount and collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        // Delegate calculation to pure function for reusability
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    ///////////////////////////////////
    // View & Pure Functions (Getter)
    ///////////////////////////////////

    /**
     * @notice Returns the health factor of a user's position
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
     *
     * @return The health factor value (in wei, 18 decimals)
     */
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /**
     * @notice Get the minimum health factor required by the protocol
     * @return The minimum health factor (1e18 = 1.0)
     */
    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    /**
     * @notice Get the liquidation threshold percentage
     * @return The liquidation threshold (50 = 50%)
     */
    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    /**
     * @notice Get the liquidation bonus percentage
     * @return The bonus percentage (10 = 10%)
     */
    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    /**
     * @notice Get the precision for liquidation calculations
     * @return The precision value (100)
     */
    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    /**
     * @notice Get the standard precision for internal calculations
     * @return The precision value (1e18)
     */
    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    /**
     * @notice Get the Chainlink price feed precision adjustment
     * @return The adjustment factor (1e10)
     */
    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    /**
     * @notice Get the DSC token contract address
     * @return The address of the DSC contract
     */
    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    /**
     * @notice Get the price feed address for a collateral token
     * @param token The collateral token address
     * @return The Chainlink price feed address
     */
    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    /**
     * @notice Get all supported collateral tokens
     * @return Array of whitelisted collateral token addresses
     */
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    /**
     * @notice Get the collateral balance of a user for a specific token
     * @param user The user address
     * @param token The collateral token address
     * @return The amount of collateral deposited
     */
    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}
