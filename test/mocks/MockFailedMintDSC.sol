//SPDX-License-Identifier:MIT

pragma solidity ^0.8.24;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// /*
// * @titile:MockFailedMintDSC
// * @auther:Do Kwon (The Luna guy ;-;)
// * Collateral:Exogenous ( ETH & BTC )
// * Minting:Algorithmic
// * Relative Stability : Pegged to USD
// *
// * This is the contract meant to be governed by DSCEngine.
// * @notice This contract is just the ERC20 iplementation of our stablecoin system.
// */

error MockFailedMintDSC__MustBeMoreThanZero();
error MockFailedMintDSC__BurnAmountExceedsBalance();
error MockFailedMintDSC__CanNotBeZeroAddress();

contract MockFailedMintDSC is ERC20Burnable, Ownable {
    constructor() ERC20("Decentralized Stable Coin", "DEC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balacnce = balanceOf(msg.sender);
        if (_amount <= 0) revert MockFailedMintDSC__MustBeMoreThanZero();
        if (balacnce < _amount) revert MockFailedMintDSC__BurnAmountExceedsBalance();
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) revert MockFailedMintDSC__CanNotBeZeroAddress();
        if (_amount <= 0) revert MockFailedMintDSC__MustBeMoreThanZero();
        _mint(_to, _amount);
        return false;
    }
}
