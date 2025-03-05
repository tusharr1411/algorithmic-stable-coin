//SPDX-License-Identifier:MIT

pragma solidity ^0.8.24;

import {Test, console, console2} from "forge-std/Test.sol";

import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";

import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";

contract DSCEngineTest is Test {
    DSCEngine engine;
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;
    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    address[] public tokenAddresses;
    address[] public feedAddresses;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");

    uint256 public constant STARTING_WETH_BALANCE = 100 ether; // 200K USD
    uint256 public constant WETH_COLLATERAL_AMOUNT = 50 ether; // 100K USD
    uint256 public constant WETH_COLLATERAL_TO_COVER_DSC_DEBT = 20 ether; //40K USD
    uint256 public constant STARTING_WBTC_BALANCE = 100e8; //8M USD
    uint256 public constant WBTC_COLLATERAL_AMOUNT = 50e8; // 4M USD
    uint256 public constant WBTC_COLLATERAL_TO_COVER_DSC_DEBT = 20e8; // 1.6M USD

    uint256 public constant MINT_DSC_AMOUNT = 5_000e18; // 5K USD

    uint256 public constant COLLATERAL_AMOUNT = 10 ether;

    uint256 constant WBTC_PRECISION = 1e8;
    uint256 constant WETH_PRECISION = 1e18;
    uint256 constant PRICEFEED_PRECISION = 1e8;
    uint256 public currentEthPrice;
    uint256 public currentBtcPrice;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        (, int256 ethPrice,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        currentEthPrice = uint256(ethPrice);
        (, int256 btcPrice,,,) = MockV3Aggregator(btcUsdPriceFeed).latestRoundData();
        currentBtcPrice = uint256(btcPrice);
        ERC20Mock(weth).mint(USER, STARTING_WETH_BALANCE); // 100 weth
        ERC20Mock(wbtc).mint(USER, STARTING_WBTC_BALANCE); // 100 wbtc

        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_WETH_BALANCE); // 100 weth
        ERC20Mock(wbtc).mint(LIQUIDATOR, STARTING_WBTC_BALANCE); // 100 wbtc
    }

    //////////////////////////////////////////////
    ///           Conatructor Tests            ///
    //////////////////////////////////////////////

    function test_RevertsIfTokenLengthDoesNotMatchPriceFeedLength() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__tokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    }

    //////////////////////////////////////////////
    ///          View Function Tests           ///
    //////////////////////////////////////////////
    function test_getUsdValue() public view {
        uint256 btcAmount = 2e8;
        uint256 expectedValue = btcAmount * currentBtcPrice * 1e18 / (WBTC_PRECISION * PRICEFEED_PRECISION);
        uint256 actualValue = engine.getUsdValue(wbtc, btcAmount);
        console.log("expected value :", expectedValue);
        console.log("actual value :", actualValue);
        assert(expectedValue == actualValue);
    }

    function test_getTokenAmountFromUsd() public view {
        uint256 usdAmount = 80_000 * 1e18;
        uint256 expectedBtc = usdAmount * WBTC_PRECISION * PRICEFEED_PRECISION / (currentBtcPrice * 1e18);
        uint256 actualValue = engine.getTokenAmountFromUsd(wbtc, usdAmount);
        console.log("Value in ETH: %d", actualValue);
        assert(expectedBtc == actualValue);
    }

    function test_getAccountCollateralValue() public wethCollateralDeposited wbtcCollateralDeposited {
        uint256 expectedValue =
            engine.getUsdValue(wbtc, WBTC_COLLATERAL_AMOUNT) + engine.getUsdValue(weth, WETH_COLLATERAL_AMOUNT);
        uint256 actualValue = engine.getAccountCollateralValue(USER);
        assertEq(actualValue, expectedValue);
    }

    function test_getAccountCollateralBalance() public wbtcCollateralDeposited {
        uint256 expectedWbtcBalance = WBTC_COLLATERAL_AMOUNT;
        uint256 actualWbtcBalance = engine.getAccountCollateralBalance(USER, wbtc);
        assertEq(actualWbtcBalance, expectedWbtcBalance);
    }

    function test_getPriceFeedFromToken() public view {
        assertEq(ethUsdPriceFeed, engine.getPriceFeedFromToken(weth));
    }

    //////////////////////////////////////////////
    ///        depositeCollateral Tests        ///
    //////////////////////////////////////////////

    modifier wethCollateralDeposited() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), WETH_COLLATERAL_AMOUNT);
        engine.depositeCollateral(weth, WETH_COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    modifier wbtcCollateralDeposited() {
        vm.startPrank(USER);
        ERC20Mock(wbtc).approve(address(engine), WBTC_COLLATERAL_AMOUNT);
        engine.depositeCollateral(wbtc, WBTC_COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    modifier collateralDeposited() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), WETH_COLLATERAL_AMOUNT);
        engine.depositeCollateral(weth, WETH_COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    function test_RevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), WETH_COLLATERAL_AMOUNT);
        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeGraterThanZero.selector);
        engine.depositeCollateral(weth, 0);
        vm.stopPrank();
    }

    function test_RevertsIfTokenIsNotAllowedAsCollateral() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        DSCEngine dsce = new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.depositeCollateral(wbtc, WBTC_COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function test_RevertsIfTransferFromFails() public {
        vm.startPrank(USER);

        MockFailedTransferFrom mockCollateral = new MockFailedTransferFrom();
        tokenAddresses.push(address(mockCollateral));
        feedAddresses.push(ethUsdPriceFeed);
        DSCEngine dsce = new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
        mockCollateral.mint(USER, WETH_COLLATERAL_AMOUNT);
        mockCollateral.approve(address(dsce), WETH_COLLATERAL_AMOUNT);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.depositeCollateral(address(mockCollateral), WETH_COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function test_depositeCollateralAndMintDscFailsIfItBrokeHealthFactor() public wbtcCollateralDeposited {}

    function test_CanDepositeCollateralAndGetAccountInformation() public wethCollateralDeposited {
        (uint256 totalDSCMinted, uint256 collateralDepositedInUSD) = engine.getAccountInformation(USER);

        uint256 expectedDscMinted = 0;
        uint256 expectedCollateralDepositedInUSD = engine.getUsdValue(weth, WETH_COLLATERAL_AMOUNT);

        assertEq(totalDSCMinted, expectedDscMinted);
        assertEq(collateralDepositedInUSD, expectedCollateralDepositedInUSD);
    }

    ///////////////////////////////////////
    //             MintDsc Tests         //
    ///////////////////////////////////////
    function test_mintDscRevertsIfAmountIsZero() public wbtcCollateralDeposited {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeGraterThanZero.selector);
        engine.mintDsc(0);
    }

    function test_mintDscRevertsIfHelthFactorIsBroken() public wbtcCollateralDeposited {
        vm.startPrank(USER);
        uint256 collateralUsdValue = engine.getUsdValue(wbtc, WBTC_COLLATERAL_AMOUNT);
        console.log("kkkkkkkkkkk", collateralUsdValue);
        // vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        uint256 expectedHealthFactor = engine.calculateHealthFactor(collateralUsdValue, collateralUsdValue);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.mintDsc(collateralUsdValue);
    }

    function test_mintDscFailsIfMintFailed() public {
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        vm.prank(msg.sender);
        DSCEngine dsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(dsce));

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), WETH_COLLATERAL_AMOUNT);
        dsce.depositeCollateral(address(weth), WETH_COLLATERAL_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        dsce.mintDsc(MINT_DSC_AMOUNT);
        vm.stopPrank();
    }

    function test_UserCanMintAfterCollateralDeposite() public wbtcCollateralDeposited {
        vm.prank(USER);
        engine.mintDsc(MINT_DSC_AMOUNT);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, MINT_DSC_AMOUNT);
    }

    ///////////////////////////////////////////////////////
    //        depositeCollateralAndMintDsc Tests         //
    ///////////////////////////////////////////////////////

    function test_CanDepositeCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(wbtc).approve(address(engine), WBTC_COLLATERAL_AMOUNT);
        engine.depositeCollateralAndMintDsc(wbtc, WBTC_COLLATERAL_AMOUNT, MINT_DSC_AMOUNT);
        vm.stopPrank();
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, MINT_DSC_AMOUNT);
    }

    modifier collateralDepositedAndDSCMinted() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositeCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, MINT_DSC_AMOUNT);
        vm.stopPrank();
        _;
    }

    modifier wethCollateralDepositedAndDSCMinted() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), WETH_COLLATERAL_AMOUNT);
        engine.depositeCollateralAndMintDsc(weth, WETH_COLLATERAL_AMOUNT, MINT_DSC_AMOUNT);
        vm.stopPrank();
        _;
    }

    modifier wbtcCollateralDepositedAndDSCMinted() {
        vm.startPrank(USER);
        ERC20Mock(wbtc).approve(address(engine), WBTC_COLLATERAL_AMOUNT);
        engine.depositeCollateralAndMintDsc(wbtc, WBTC_COLLATERAL_AMOUNT, MINT_DSC_AMOUNT);
        vm.stopPrank();
        _;
    }

    //////////////////////////////////////////////
    ///              burnDSC tests             ///
    //////////////////////////////////////////////

    function test_revertsIfBurnAmountIsZero() public wbtcCollateralDepositedAndDSCMinted {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeGraterThanZero.selector);
        engine.burnDSC(0);
    }

    function test_CanNotBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDSC(1);
    }

    function test_revertsIfTokenTransferFromFails() public {
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        vm.prank(msg.sender);
        DSCEngine dsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(dsce));

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), WETH_COLLATERAL_AMOUNT);
        dsce.depositeCollateralAndMintDsc(weth, WETH_COLLATERAL_AMOUNT, MINT_DSC_AMOUNT);

        mockDsc.approve(address(dsce), MINT_DSC_AMOUNT);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.burnDSC(MINT_DSC_AMOUNT);
        vm.stopPrank();
    }

    function test_CanBurnPartialDsc() public wbtcCollateralDepositedAndDSCMinted {
        vm.startPrank(USER);
        dsc.approve(address(engine), MINT_DSC_AMOUNT / 2);
        engine.burnDSC(MINT_DSC_AMOUNT / 2);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, MINT_DSC_AMOUNT / 2);
        (uint256 mintedDsc,) = engine.getAccountInformation(USER);
        assertEq(mintedDsc, MINT_DSC_AMOUNT / 2);
    }

    function test_CanBurnAllDsc() public wbtcCollateralDepositedAndDSCMinted {
        vm.startPrank(USER);
        dsc.approve(address(engine), MINT_DSC_AMOUNT);
        engine.burnDSC(MINT_DSC_AMOUNT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
        (uint256 mintedDsc,) = engine.getAccountInformation(USER);
        assertEq(mintedDsc, 0);
    }

    ///////////////////////////////////
    //   redeemCollateral Tests     //
    //////////////////////////////////
    function test_revertsIfRedeemAmountIsZero() public wbtcCollateralDepositedAndDSCMinted {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeGraterThanZero.selector);
        engine.redeemCollateral(wbtc, 0);
    }

    function test_revertsIfRedeemAmountIsGreaterThanDepositedCollateral() public wbtcCollateralDepositedAndDSCMinted {
        vm.startPrank(USER);
        vm.expectRevert();
        engine.redeemCollateral(wbtc, WBTC_COLLATERAL_AMOUNT + 1);
    }

    function test_revertsIfTransferFails() public {
        vm.startPrank(msg.sender);
        MockFailedTransfer mockCollateral = new MockFailedTransfer();
        DecentralizedStableCoin _dsc = new DecentralizedStableCoin();
        tokenAddresses.push(address(mockCollateral));
        feedAddresses.push(ethUsdPriceFeed);
        DSCEngine dsce = new DSCEngine(tokenAddresses, feedAddresses, address(_dsc));
        _dsc.transferOwnership(address(dsce));
        vm.stopPrank();

        vm.startPrank(USER);
        mockCollateral.mint(USER, COLLATERAL_AMOUNT);
        mockCollateral.approve(address(dsce), COLLATERAL_AMOUNT);
        dsce.depositeCollateral(address(mockCollateral), COLLATERAL_AMOUNT);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.redeemCollateral(address(mockCollateral), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function test_revertIfRedeemBroksHelthFactor() public wbtcCollateralDepositedAndDSCMinted {
        vm.startPrank(USER);
        uint256 expectedHealthFactor = engine.calculateHealthFactor(MINT_DSC_AMOUNT, 0);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.redeemCollateral(wbtc, WBTC_COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function test_canRedeemCollateral() public wbtcCollateralDeposited {
        vm.startPrank(USER);
        uint256 userStartingBalance = ERC20Mock(wbtc).balanceOf(USER);
        engine.redeemCollateral(wbtc, WBTC_COLLATERAL_AMOUNT);
        uint256 userEndingBalance = ERC20Mock(wbtc).balanceOf(USER);
        assertEq(userStartingBalance + WBTC_COLLATERAL_AMOUNT, userEndingBalance);
        vm.stopPrank();
    }

    function test_EmitCollateralRedeemedWithCorrectArgs() public wbtcCollateralDeposited {
        vm.expectEmit(true, true, true, true, address(engine));
        emit DSCEngine.CollateralRedeemed(USER, USER, wbtc, WBTC_COLLATERAL_AMOUNT);
        vm.startPrank(USER);
        engine.redeemCollateral(wbtc, WBTC_COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////

    function test_redeemCollateralAmountShouldBeMoreThanZero() public collateralDepositedAndDSCMinted {
        vm.startPrank(USER);
        dsc.approve(address(engine), MINT_DSC_AMOUNT);
        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeGraterThanZero.selector);
        engine.redeemCollateralForDSC(weth, 0, MINT_DSC_AMOUNT);
        vm.stopPrank();
    }

    function test_CanRedeemDepositedCollateralAndBurnAllDSCMinted() public wbtcCollateralDepositedAndDSCMinted {
        vm.startPrank(USER);
        dsc.approve(address(engine), MINT_DSC_AMOUNT);
        engine.redeemCollateralForDSC(wbtc, WBTC_COLLATERAL_AMOUNT, MINT_DSC_AMOUNT);
        vm.stopPrank();

        vm.assertEq(dsc.balanceOf(USER), 0);
        vm.assertEq(ERC20Mock(wbtc).balanceOf(USER), STARTING_WBTC_BALANCE);
    }

    ///////////////////////////////////
    ///      Liquidation Tests      ///
    ///////////////////////////////////

    function test_CanNotLiquidateGoodHealthFactor() public wbtcCollateralDepositedAndDSCMinted {
        vm.startPrank(LIQUIDATOR);
        // liquidater deposite some Collateral to mint DSC // he only need MINT_DSC_AMOUNT amount of DSC to completely liquidate the USER
        ERC20Mock(weth).approve(address(engine), WETH_COLLATERAL_TO_COVER_DSC_DEBT); //40K usd amount of ETH
        engine.depositeCollateralAndMintDsc(weth, WETH_COLLATERAL_TO_COVER_DSC_DEBT, MINT_DSC_AMOUNT); //Minted 5K DSC against $40K amount of ETH
        dsc.approve(address(engine), MINT_DSC_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsOkay.selector);
        engine.liquidate(weth, USER, MINT_DSC_AMOUNT);
        vm.stopPrank();
    }

    //this test needs its own setup
    function test_CanNotLiquidateIfHealthFactorIsNotImproved() public {
        vm.startPrank(msg.sender);
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);
        MockMoreDebtDSC mockDSC = new MockMoreDebtDSC(ethUsdPriceFeed);
        DSCEngine dsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDSC));
        mockDSC.transferOwnership(address(dsce));
        vm.stopPrank();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), WETH_COLLATERAL_AMOUNT);
        dsce.depositeCollateralAndMintDsc(weth, WETH_COLLATERAL_AMOUNT, MINT_DSC_AMOUNT);
        vm.stopPrank();
        // USER deposited 100K usd of WETH and minted 5K dsc ... so helth factor = (50 ETH x 2000 /2) / 5k = 100K/5K= 10
        console.log("ddddddddddddddddddddd", dsce.getHealthFactor(USER));

        // setup liquidation scenario

        // Now liquidator mint MINT_DSC_AMOUNT(5K) of DSC by depositing WBTC_COLLATERAL_TO_COVER_DSC_DEBT wbtc (1.6M USD)
        // so liquidator helth factor will be 1600K/5K = 320
        // and he tries to burn his some DSC token against user's debt
        vm.startPrank(LIQUIDATOR);
        uint256 dscDebtToCover = MINT_DSC_AMOUNT / 2; // 2.5K
        ERC20Mock(wbtc).approve(address(dsce), WBTC_COLLATERAL_TO_COVER_DSC_DEBT);
        dsce.depositeCollateralAndMintDsc(wbtc, WBTC_COLLATERAL_TO_COVER_DSC_DEBT, MINT_DSC_AMOUNT);
        // liquidator has MINT_DSC_AMOUNT amount of DSC (5K)

        // Now make USER liquidatable by dumping ETH 91% i.e. 1ETH = 180 USD
        int256 updatedEthUsdPrice = 180e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(updatedEthUsdPrice);
        // Now user is liquidatable
        console.log("Helth Factor:", dsce.getHealthFactor(USER));
        // (WETH_COLLATERAL_AMOUNT * 180 /2)/ 5k = (50x90) /5000 = 0.9 => liquidatable
        // means he has 9000 USD of collateral backing 5000 DSC
        // means he has to brun 500 DSC to have a healthy health factor

        // so if liquidator burn his 5000 DSC against USERS then user will be liquidated -
        // liquidator will get 5000+500=5500 USD amount of WETH
        // user will still have 9000-5500 = 3500 USD weth as collateral and 5K DSC

        // Act/Assert
        mockDSC.approve(address(dsce), dscDebtToCover);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsNotImproved.selector);
        dsce.liquidate(weth, USER, dscDebtToCover);
        // so before liquidation user helth factor is 0.9
        // during liquidation when MockMoreDebtDSC.burn() called in liquidation process it dumps the ETH to zero
        // so  endingUserHealthFactor is zero and hence it doesn't improve the healthFactor of USER, hence liquidation process is reverted.
        //
        vm.stopPrank();
    }

    modifier liquidated() {
        //USER put 10 weth and Minted 100DSC
        // So health factor of user = 5*2400/100 = 120
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), WETH_COLLATERAL_AMOUNT);
        engine.depositeCollateralAndMintDsc(weth, WETH_COLLATERAL_AMOUNT, MINT_DSC_AMOUNT);
        // USER deposited 100K usd of WETH and minted 5K dsc ... so helth factor = (50 ETH x 2000 /2) / 5k = 100K/5K= 10
        vm.stopPrank();

        // Break the Health Factor of USER
        console.log("Before Price change USER healthFactor :", engine.getHealthFactor(USER));
        int256 updatedEthUsdPrice = 180e8; // 1 weth = $180
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(updatedEthUsdPrice);
        uint256 userHealthFactor = engine.getHealthFactor(USER);
        console.log("After price change USER healthFactor :", userHealthFactor); // health factor = (50x180 /2)/ 5k = (50x90) /5000 = 0.9

        vm.startPrank(LIQUIDATOR);
        // Liquidator has 100weth = 18K USD and 100wbtc = 8MUSD
        // So he Put all his weth and Mint some DSC, Just enough to pay the DSC debt he want to cover( let say full - 5K DSC)
        ERC20Mock(weth).approve(address(engine), STARTING_WETH_BALANCE); // 100 weth = 18K usd
        engine.depositeCollateralAndMintDsc(weth, STARTING_WETH_BALANCE, MINT_DSC_AMOUNT); // minted 5K dsc against 18k usd weth
        console.log("Before liquidation, LIQUIDATOR healthFactor :", engine.getHealthFactor(LIQUIDATOR)); // (18K/2)/5K = 1.8 ... quite healthy

        // Now liquidator burns his DSC on behalf of USER
        // liquidator put his 5K DSC and get 5.5K usd of weth he also has weth collateral of 100 weth (18K) and 5K DSC debt in protocol
        // liquidator will have = 5.5K usd of weth + 13k ( in protocol) = 18.5k of weth
        dsc.approve(address(engine), MINT_DSC_AMOUNT);
        engine.liquidate(weth, USER, MINT_DSC_AMOUNT);
        console.log("After liquidation, LIQUIDATOR healthFactor :", engine.getHealthFactor(LIQUIDATOR)); // 10*18/100 = 1.8
        console.log("After liquidation, USER healthFactor :", engine.getHealthFactor(USER)); // should be max as dscMint = 0
        // but the problem is liquidator can not claim hi weth from the protocol as if he do so his helth factor will be broken

        vm.stopPrank();
        _;
    }

    function test_liquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedWeth = engine.getTokenAmountFromUsd(weth, MINT_DSC_AMOUNT)
            + ((engine.getTokenAmountFromUsd(weth, MINT_DSC_AMOUNT)) * engine.getLiquidationBonus() / 100);
        uint256 hardCodedExpected = 30_555_555_555_555_555_554;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function test_UserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 wethAmountLiquidated = engine.getTokenAmountFromUsd(weth, MINT_DSC_AMOUNT)
            + (engine.getTokenAmountFromUsd(weth, MINT_DSC_AMOUNT) * engine.getLiquidationBonus()) / 100;
        uint256 expectedRemainingCollateral = WETH_COLLATERAL_AMOUNT - wethAmountLiquidated;
        uint256 actualRemainingCollateral = engine.getAccountCollateralBalance(USER, weth);
        uint256 hardCodedExpectedCollateral = 19_444_444_444_444_444_446;

        uint256 valueOfLiquidationInUSD = engine.getUsdValue(weth, wethAmountLiquidated);
        uint256 expectedUserCollateralValueInUsd =
            engine.getUsdValue(weth, WETH_COLLATERAL_AMOUNT) - (valueOfLiquidationInUSD);
        (, uint256 userCollateralValueInUsd) = engine.getAccountInformation(USER);

        assertEq(expectedRemainingCollateral, actualRemainingCollateral);
        assertEq(hardCodedExpectedCollateral, actualRemainingCollateral);

        assertEq(expectedUserCollateralValueInUsd, userCollateralValueInUsd);
    }

    function test_UserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = engine.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

    function test_LiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = engine.getAccountInformation(LIQUIDATOR);
        assertEq(liquidatorDscMinted, MINT_DSC_AMOUNT);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////
}
