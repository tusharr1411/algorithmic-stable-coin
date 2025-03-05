//SPDX-License-Identifier:MIT

//Handler is going to narrow down the way we call functions

pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";

import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator public ethPriceFeed;
    uint256 MAX_COLLATERAL_DEPOSITE_SIZE = type(uint96).max;

    uint256 public varr;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;
        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
        ethPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
    }

    //redeem collateral <-
    function depositeCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        collateralAmount = bound(collateralAmount, 1, MAX_COLLATERAL_DEPOSITE_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, collateralAmount);
        collateral.approve(address(engine), collateralAmount);
        engine.depositeCollateral(address(collateral), collateralAmount);

        vm.stopPrank();
    }

    // // Only the DSCEngine can mint DSC!
    // // this will break our invariants as minted dsc should be backed by collateral in DSC Engine
    // function mint(uint256 amountDscToMint) public {
    //     amountDscToMint = bound(amountDscToMint, 0, MAX_COLLATERAL_DEPOSITE_SIZE);
    //     if (amountDscToMint == 0) {
    //         return; // Or use vm.assume
    //     }
    //     vm.prank(dsc.owner());
    //     dsc.mint(msg.sender, amountDscToMint);
    // }

    function mintDsc(uint256 amountDscToMint) public {
        amountDscToMint = bound(amountDscToMint, 0, MAX_COLLATERAL_DEPOSITE_SIZE);
        vm.assume(amountDscToMint > 0);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(msg.sender);
        uint256 healthFactor = engine.calculateHealthFactor(totalDscMinted + amountDscToMint, collateralValueInUsd);
        vm.assume(healthFactor >= 1e18);
        vm.prank(msg.sender);
        engine.mintDsc(amountDscToMint);
        varr++;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = engine.getAccountCollateralBalance(msg.sender, address(collateral));
        collateralAmount = bound(collateralAmount, 0, maxCollateralToRedeem);

        if (collateralAmount == 0) {
            return; // Or use vm.assume
        }

        uint256 usdValueOfCollateralAmount = engine.getUsdValue(address(collateral), collateralAmount);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(msg.sender);
        uint256 healthFactor =
            engine.calculateHealthFactor(totalDscMinted, collateralValueInUsd - usdValueOfCollateralAmount);
        vm.assume(healthFactor >= 1e18);

        vm.startPrank(msg.sender);
        engine.redeemCollateral(address(collateral), collateralAmount);
        vm.stopPrank();
    }

    // // this breaks the protocol
    // function updateCollateralPrice(uint96 price) public{
    //     int256 priceInt =int256(uint256(price));
    //     ethPriceFeed.updateAnswer(priceInt);
    // }

    // Helper functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
