//SPDX-License-Identifier:MIT

pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed collateralTokenAddress,
        uint256 redeemedAmount
    );

    DSCEngine engine;
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;
    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;

    address[] public tokenAddresses;
    address[] public feedAddresses;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");

    uint256 public constant COLLATERAL_AMOUNT = 10 ether;
    uint256 public constant MINT_DSC_AMOUNT = 100e18; // 100 USD
    uint256 public constant COLLATERAL_TO_COVER = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE); // 100 weth
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE); // 100 wbtc

        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE); // 100 weth
        ERC20Mock(wbtc).mint(LIQUIDATOR, STARTING_ERC20_BALANCE); // 100 wbtc
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
    function test_GetUsdValue() public view {
        uint256 ethAmount = 2;
        uint256 expectedValue = 2 * 2400;
        uint256 actualValue = engine.getUsdValue(weth, ethAmount);
        console.log("Value in USD: %d", actualValue);
        assert(expectedValue == actualValue);
    }

    function test_getTokenAmountFromUsd() public view {
        uint256 usdAmount = 2400 * 1e18;
        uint256 expectedValue = (2400 * 1e18) / 2400;
        uint256 actualValue = engine.getTokenAmountFromUsd(weth, usdAmount);
        console.log("Value in ETH: %d", actualValue);
        assert(expectedValue == actualValue);
    }

    function test_getAccountCollateralValue() public view {}
    function test_getPriceFeedFromToken() public view {}

    //////////////////////////////////////////////
    ///        depositeCollateral Tests        ///
    //////////////////////////////////////////////

    modifier collateralDeposited() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositeCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    function test_RevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);
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
        dsce.depositeCollateral(wbtc, COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function test_RevertsIfTransferFromFails() public {
        vm.startPrank(USER);

        MockFailedTransferFrom mockCollateral = new MockFailedTransferFrom();
        tokenAddresses.push(address(mockCollateral));
        feedAddresses.push(ethUsdPriceFeed);
        DSCEngine dsce = new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
        mockCollateral.mint(USER, COLLATERAL_AMOUNT);
        mockCollateral.approve(address(dsce), COLLATERAL_AMOUNT);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.depositeCollateral(address(mockCollateral), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function test_CanDepositeCollateralAndGetAccountInformation() public collateralDeposited {
        (uint256 totalDSCMinted, uint256 collateralDepositedInUSD) = engine.getAccountInformation(USER);

        uint256 expectedDscMinted = 0;
        uint256 expectedCollateralDepositedInUSD = engine.getUsdValue(weth, COLLATERAL_AMOUNT);

        assertEq(totalDSCMinted, expectedDscMinted);
        assertEq(collateralDepositedInUSD, expectedCollateralDepositedInUSD);
    }

    ///////////////////////////////////////
    //             MintDsc Tests         //
    ///////////////////////////////////////
    function test_mintDscRevertsIfAmountIsZero() public collateralDeposited {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeGraterThanZero.selector);
        engine.mintDsc(0);
    }

    function test_mintDscRevertsIfHelthFactorIsBroken() public collateralDeposited {
        vm.startPrank(USER);
        uint256 collateralUsdValue = engine.getUsdValue(weth, COLLATERAL_AMOUNT);
        console.log("kkkkkkkkkkk", collateralUsdValue);
        // vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        uint256 expectedHealthFactor = engine.calculateHealthFactor(collateralUsdValue, collateralUsdValue);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.mintDsc(collateralUsdValue);
    }

    function test_mintDscFailsIfMintFailed() public collateralDeposited {
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        vm.prank(msg.sender);
        DSCEngine dsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));

        mockDsc.transferOwnership(address(dsce));

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_AMOUNT);
        dsce.depositeCollateral(address(weth), COLLATERAL_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        dsce.mintDsc(MINT_DSC_AMOUNT);
        vm.stopPrank();
    }

    function test_UserCanMintAfterCollateralDeposite() public collateralDeposited {
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
        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositeCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, MINT_DSC_AMOUNT);
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

    //////////////////////////////////////////////
    ///              burnDSC tests             ///
    //////////////////////////////////////////////

    function test_revertsIfBurnAmountIsZero() public collateralDepositedAndDSCMinted {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeGraterThanZero.selector);
        engine.burnDSC(0);
    }

    function test_CanNotBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDSC(1);
    }

    function test_revertsIfTokenTransferFromFails() public collateralDepositedAndDSCMinted {}

    function test_CanBurnAllDsc() public collateralDepositedAndDSCMinted {
        vm.startPrank(USER);
        dsc.approve(address(engine), MINT_DSC_AMOUNT);
        engine.burnDSC(MINT_DSC_AMOUNT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////
    //   redeemCollateral Tests     //
    //////////////////////////////////
    function test_revertsIfRedeemAmountIsZero() public collateralDepositedAndDSCMinted {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeGraterThanZero.selector);
        engine.redeemCollateral(weth, 0);
    }

    function test_revertsIfTransferFails() public {
        vm.startPrank(msg.sender);
        MockFailedTransfer mockCollateral = new MockFailedTransfer();
        DecentralizedStableCoin mockDSC = new DecentralizedStableCoin();
        tokenAddresses.push(address(mockCollateral));
        feedAddresses.push(ethUsdPriceFeed);
        DSCEngine dsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDSC));
        mockDSC.transferOwnership(address(dsce));
        vm.stopPrank();

        vm.startPrank(USER);
        mockCollateral.mint(USER, COLLATERAL_AMOUNT);
        mockCollateral.approve(address(dsce), COLLATERAL_AMOUNT);
        dsce.depositeCollateral(address(mockCollateral), COLLATERAL_AMOUNT);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.redeemCollateral(address(mockCollateral), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function test_revertIfRedeemBroksHelthFactor() public collateralDepositedAndDSCMinted {
        vm.startPrank(USER);
        uint256 expectedHealthFactor = engine.calculateHealthFactor(MINT_DSC_AMOUNT, 0);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.redeemCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function test_canRedeemCollateral() public collateralDeposited {
        vm.startPrank(USER);
        uint256 userStartingBalance = ERC20Mock(weth).balanceOf(USER);
        engine.redeemCollateral(weth, COLLATERAL_AMOUNT);
        uint256 userEndingBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userStartingBalance + COLLATERAL_AMOUNT, userEndingBalance);
        vm.stopPrank();
    }

    function test_EmitCollateralRedeemedWithCorrectArgs() public collateralDeposited {
        vm.expectEmit(true, true, true, true, address(engine));
        emit CollateralRedeemed(USER, USER, weth, COLLATERAL_AMOUNT);
        vm.startPrank(USER);
        engine.redeemCollateral(weth, COLLATERAL_AMOUNT);
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

    function test_CanRedeemDepositedCollateralAndBurnAllDSCMinted() public collateralDepositedAndDSCMinted {
        vm.startPrank(USER);
        dsc.approve(address(engine), MINT_DSC_AMOUNT);
        engine.redeemCollateralForDSC(weth, COLLATERAL_AMOUNT, MINT_DSC_AMOUNT);
        vm.stopPrank();

        vm.assertEq(dsc.balanceOf(USER), 0);
        vm.assertEq(ERC20Mock(weth).balanceOf(USER), 100 ether);
    }

    ///////////////////////////////////
    ///      Liquidation Tests      ///
    ///////////////////////////////////

    function test_CanNotLiquidateGoodHealthFactor() public collateralDepositedAndDSCMinted {
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_TO_COVER);
        engine.depositeCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, MINT_DSC_AMOUNT);
        dsc.approve(address(engine), MINT_DSC_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsOkay.selector);
        engine.liquidate(weth, USER, MINT_DSC_AMOUNT);
        vm.stopPrank();
    }

    //this test needs its own setup
    function test_CanNotLiquidateIfHealthFactorIsNotImproved() public {
        vm.startPrank(msg.sender);
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        MockMoreDebtDSC mockDSC = new MockMoreDebtDSC(ethUsdPriceFeed);
        DSCEngine dsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDSC));
        mockDSC.transferOwnership(address(dsce));
        vm.stopPrank();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_AMOUNT);
        dsce.depositeCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, MINT_DSC_AMOUNT);
        vm.stopPrank();

        // now setup liquidation scenario
        //let say someone mint 1 ether of DSC and burn thema against the debt of USER

        vm.startPrank(LIQUIDATOR);
        uint256 dscDebtToCover = 10 ether; // 10 DSC
        uint256 collateralToCover = 10 ether; // equal to 24000 DSC means he can mint 1200 DSC
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositeCollateralAndMintDsc(weth, collateralToCover, MINT_DSC_AMOUNT);
        mockDSC.approve(address(dsce), dscDebtToCover);

        // int256 updatedEthUsdPrice = 20e8;// means 1 ETH = 20 DSC// and user deposited 10 ETH ==200 DSC means can hold 100 DSC so use 18e8
        // But make sure it does not break the health factor of liquidator
        int256 updatedEthUsdPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(updatedEthUsdPrice);
        // Now user is liquidatable
        console.log("Helth Factor:", dsce.getHealthFactor(USER));

        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsNotImproved.selector);
        dsce.liquidate(weth, USER, dscDebtToCover);
        // this is failing because Just after the the buring  DSC we have dumped the ETH price so health factor of USER is zero
        // Health factor of Liquidator is also zero but we are checking DSCEngine__HealthFactorIsNotImproved error before it.
        vm.stopPrank();
    }

    modifier liquidated() {
        //USER put 10 weth and Minted 100DSC
        // So health factor of user = 5*2400/100 = 120
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositeCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, MINT_DSC_AMOUNT);
        vm.stopPrank();

        // Break the Health Factor of USER
        console.log("Before Price change USER healthFactor :", engine.getHealthFactor(USER));
        int256 updatedEthUsdPrice = 18e8; // 1 weth = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(updatedEthUsdPrice);
        uint256 userHealthFactor = engine.getHealthFactor(USER);
        console.log("After price change USER healthFactor :", userHealthFactor); // health factor = 5*18/100 = 0.9

        vm.startPrank(LIQUIDATOR);
        // Liquidator has 100weth and 100wbtc
        // So he Put 20 weth and Mint some DSC, Just enough to pay the DSC debt he want to cover( let say full - 100DSC)
        ERC20Mock(weth).approve(address(engine), COLLATERAL_TO_COVER); // 20 weth
        engine.depositeCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, MINT_DSC_AMOUNT);
        console.log("Before liquidation, LIQUIDATOR healthFactor :", engine.getHealthFactor(LIQUIDATOR)); // 10*18/100 = 1.8

        // Now liquidator burns his DSC on behalf of USER
        dsc.approve(address(engine), MINT_DSC_AMOUNT);
        engine.liquidate(weth, USER, MINT_DSC_AMOUNT);
        console.log("After liquidation, LIQUIDATOR healthFactor :", engine.getHealthFactor(LIQUIDATOR)); // 10*18/100 = 1.8
        console.log("After liquidation, USER healthFactor :", engine.getHealthFactor(USER)); // should be max as dscMint = 0

        vm.stopPrank();
        _;
    }

    function test_liquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedWeth = 80 ether + engine.getTokenAmountFromUsd(weth, MINT_DSC_AMOUNT)
            + ((engine.getTokenAmountFromUsd(weth, MINT_DSC_AMOUNT)) * engine.getLiquidationBonus() / 100);
        uint256 hardCodedExpected = 86_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function test_UserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 wethAmountLiquidated = engine.getTokenAmountFromUsd(weth, MINT_DSC_AMOUNT)
            + (engine.getTokenAmountFromUsd(weth, MINT_DSC_AMOUNT) * engine.getLiquidationBonus()) / 100;
        uint256 valueOfLiquidationInUSD = engine.getUsdValue(weth, wethAmountLiquidated);
        uint256 expectedUserCollateralValueInUsd =
            engine.getUsdValue(weth, COLLATERAL_AMOUNT) - (valueOfLiquidationInUSD);

        (, uint256 userCollateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
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
