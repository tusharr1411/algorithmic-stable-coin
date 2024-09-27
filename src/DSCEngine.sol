//SPDX-License-Identifier:MIT

pragma solidity ^0.8.24;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {console} from "forge-std/Test.sol";

/**
 * @title : DSC Engiine
 * @author Do Kown ( the stable coin legend)
 * The system is designed to be as minimal as possible and have the tokens maintain a 1 token == $1 peg.
 * This stable coin has following properties
 * - Exogenous Collateral
 * - Dollar pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI has no governance no fees and was only backed by WETH and WBTC
 * Our system should always be "over collateralize. At no point should the value of all the collateral <= the $ backed value of all the DSC.
 * @notice This contract is the core of our system. It habdles all the logic mining and redeeming DSC, as well as depositing & Withdrawing collateral.
 * @notice This contract is VERY LOOSELY based on the MakerDAO DSS(DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////////////////////////////////
    ///                 Errors                  ///
    ///////////////////////////////////////////////
    error DSCEngine_AmountMustBeGraterThanZero();
    error DSCEngine__tokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsOkay();
    error DSCEngine__HealthFactorIsNotImproved();

    ///////////////////////////////////////////////
    ///            State Variables              ///
    ///////////////////////////////////////////////
    uint256 private constant ADITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10%
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    DecentralizedStableCoin immutable i_dsc;
    mapping(address token => address priceFeed) private s_priceFeeds; //tokenToPriceFeeds
    mapping(address user => mapping(address token => uint256 amount)) private s_CollateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    ///////////////////////////////////////////////
    ///                Events                   ///
    ///////////////////////////////////////////////

    event CollateralDeposited(
        address indexed user, address indexed tokenCollateralAddress, uint256 indexed amountCollateral
    );
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed collateralTokenAddress,
        uint256 redeemedAmount
    );

    ///////////////////////////////////////////////
    ///               Modifiers                 ///
    ///////////////////////////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine_AmountMustBeGraterThanZero();
        }
        _;
    }

    modifier isAllowedToken(address tokenAddress) {
        if (s_priceFeeds[tokenAddress] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    ///////////////////////////////////////////////
    ///              Constructor                ///
    ///////////////////////////////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__tokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////////////////////////
    ///          External Functions            ///
    //////////////////////////////////////////////

    /**
     * @param collateralTokenAddress the address of the token to deposite as collateral
     * @param collateralAmount amount of collateral to deposite
     * @param amountDscToMint the amount of DSC to mint
     * @notice this function will deposite collateral and mint token in one transaction
     */
    function depositeCollateralAndMintDsc(
        address collateralTokenAddress,
        uint256 collateralAmount,
        uint256 amountDscToMint
    ) external {
        depositeCollateral(collateralTokenAddress, collateralAmount);
        mintDsc(amountDscToMint);
    }

    /**
     * @param collateralTokenAddress collateral address to redeem
     * @param collateralAmount amount of collateral to redeem
     * @param amountDscToBurn the amount of DSC to burn
     * @notice this function burn DSC and redeem underlying collateral in one transaction
     */
    function redeemCollateralForDSC(address collateralTokenAddress, uint256 collateralAmount, uint256 amountDscToBurn)
        external
    {
        burnDSC(amountDscToBurn);
        redeemCollateral(collateralTokenAddress, collateralAmount);
    }

    //////////////////////////////////////////////
    ///            Public Functions            ///
    //////////////////////////////////////////////

    /**
     * @notice follows CEI pattern
     * @param tokenCollateralAddress the address of the token to deposite as collateral
     * @param collateralAmount the amount of collateral to deposite
     */
    function depositeCollateral(address tokenCollateralAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_CollateralDeposited[msg.sender][tokenCollateralAddress] += collateralAmount;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, collateralAmount);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) revert DSCEngine__TransferFailed();
    }

    /**
     * @notice follwo CEI
     * @param amountDscToMint the amount of Decentralized Stable Coin to Mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) revert DSCEngine__MintFailed();
    }

    // In order to redeem collateral
    // 1. health factor should not be broken after collateral pulled out
    // CEI
    function redeemCollateral(address collateralTokenAddress, uint256 collateralAmountToRedeem)
        public
        moreThanZero(collateralAmountToRedeem)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, collateralTokenAddress, collateralAmountToRedeem);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //q I think here is an error of underflow
    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDSC(msg.sender, msg.sender, amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // $100 ETH backing $50 DSC
    // But ETH price dropped ans 20$ ETH holding $50 DSC
    // so it's better to liquidate them much before that

    // So if someone is almost under collateral them liquidate them
    // late say $75 ETH holding $50 DSC( but it's much lesser than the liquidation threshold of 200 %)
    // So  close thier position , liquidtor can deposit 50 $ DSC and can take the $75 ETH and burn the $50 DSC

    /**
     * @param collateralAddress collateral token address
     * @param user to whom you want to liquidate
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     *
     * @notice you can partially liquidate a user.
     * @notice you will get a liquidation bonus for taking users fund
     * @notice this function is working assume the protocol will be roughly 200% over collateralized in order for this to work
     * @notice
     */
    function liquidate(address collateralAddress, address user, uint256 debtToCover)
        public
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            // make sure user is liquidatable
            revert DSCEngine__HealthFactorIsOkay();
        }
        //Now we want to burn their "DSC" "debt" and take their collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateralAddress, debtToCover);
        // And give them 10% bonus
        // We should implement a feature to liquidate in the event the protocol is insolvent and swap extra amount into a treasury
        // (though we are not gonna do it rn)
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / 100;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(user, msg.sender, collateralAddress, totalCollateralToRedeem);

        // now burn DSC against USER
        _burnDSC(msg.sender, user, debtToCover);
        uint256 endingUserHealthFactor = _healthFactor(user);

        console.log("Helth Factor inside:", getHealthFactor(user));

        if (endingUserHealthFactor <= startingUserHealthFactor) revert DSCEngine__HealthFactorIsNotImproved();
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    ///////////////////////////////////////////////////////////
    ///          Internal and Private  Functions            ///
    ///////////////////////////////////////////////////////////
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _revertIfHealthFactorIsBroken(address user) private view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) revert DSCEngine__BreaksHealthFactor(userHealthFactor);
    }

    /**
     * @notice returns how close to liquidation s user is
     * @notice If a user go below 1 they can be liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        //Total DSC minted
        // Total collateral Value ( in dollar)
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        private
        pure
        returns (uint256)
    {
        //health factor 1 means user has reched the liquidation limits
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _redeemCollateral(
        address from,
        address to,
        address collateralTokenAddress,
        uint256 collateralAmountToRedeem
    ) private moreThanZero(collateralAmountToRedeem) {
        s_CollateralDeposited[from][collateralTokenAddress] -= collateralAmountToRedeem;
        emit CollateralRedeemed(from, to, collateralTokenAddress, collateralAmountToRedeem);
        // return the money
        bool success = IERC20(collateralTokenAddress).transfer(to, collateralAmountToRedeem);
        console.log("herejjjjjjjjjjj");
        if (!success) revert DSCEngine__TransferFailed();
        // _revertIfHealthFactorIsBroken(from);
    }

    /**
     * @dev Low-level internal function, do not call unless the function calling it is checking for health factors being broken
     */
    function _burnDSC(address from, address onBehalfOf, uint256 amount) private moreThanZero(amount) {
        s_DscMinted[onBehalfOf] -= amount;
        bool success = i_dsc.transferFrom(from, address(this), amount);
        if (!success) revert DSCEngine__TransferFailed();
        i_dsc.burn(amount);
    }

    //////////////////////////////////////////////
    ///     Public View and Pure Functions     ///
    //////////////////////////////////////////////

    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalAccountCollateralUSDValue;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            uint256 userDeposites = s_CollateralDeposited[user][s_collateralTokens[i]];
            if (userDeposites > 0) {
                totalAccountCollateralUSDValue += getUsdValue(s_collateralTokens[i], userDeposites);
            }
        }
        return totalAccountCollateralUSDValue;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return (usdAmountInWei * PRECISION) / (uint256(price) * ADITIONAL_FEED_PRECISION);
    }

    function getPriceFeedFromToken(address tokenAddress) public view returns (address) {
        return s_priceFeeds[tokenAddress];
    }

    function getAccountInformation(address user) public view returns (uint256, uint256) {
        return _getAccountInformation(user);
    }

    function getHealthFactor(address user) public view returns (uint256) {
        return _healthFactor(user);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        public
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }
}
