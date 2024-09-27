//SPDX-License-Identifier:MIT

//Handler is going to narrow down the way we call functions

pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";

import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    uint256 MAX_COLLATERAL_DEPOSITE_SIZE = type(uint96).max;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;
        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
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

    function redeemCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = engine.getAccountCollateralBalance(msg.sender, address(weth));
        collateralAmount = bound(collateralAmount, 0, maxCollateralToRedeem);

        if(collateralAmount ==0){
            return; // aur use vm.assume
        }

        vm.startPrank(msg.sender);

        engine.redeemCollateral(address(collateral), collateralAmount);

        vm.stopPrank();
    }

    // Helper functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
