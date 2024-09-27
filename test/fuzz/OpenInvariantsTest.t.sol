// //SPDX-License-Identifier:MIT

// pragma solidity 0.8.24;

// //have our invariants aka properties that our system should always hold

// //Okay now what are our invariants here ?

// // 1. Total value of DSC minted should be less than the total value of collateral
// // 2. Getter view functions should never revert // Everngreen invariant

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

// import {ERC20Mock} from "../mocks/ERC20Mock.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantTest is StdInvariant, Test {
//     // DeployDSC deployer;
//     DSCEngine engine;
//     HelperConfig helperConfig;
//     DecentralizedStableCoin dsc;

//     address public ethUsdPriceFeed;
//     address public btcUsdPriceFeed;
//     address public weth;
//     address public wbtc;
//     uint256 public deployerKey;

//     function setUp() external {
//         DeployDSC deployer = new DeployDSC();
//         console.log("kjkkk", address(deployer));
//         (dsc, engine, helperConfig) = deployer.run();
//         console.log("jjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjj");

//         (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();

//         console.log(address(engine));
//         targetContract(address(engine));
//         console.log("jjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjj");

//     }

//     function invariant_protocolMustHaveMoreCollateralValueThanTotalDSCSupply() public view {
//         // get the value of all the collateral in  protocol
//         // Compare it to all the debt ( DSC)

//         uint256 totalDSCSupply = dsc.totalSupply();
//         uint256 ethCollateralInProtocol = ERC20Mock(weth).balanceOf(address(engine));
//         uint256 btcCollateralInProtocol = ERC20Mock(wbtc).balanceOf(address(engine));

//         uint256 ethCollateralUSDValue = engine.getUsdValue(weth, ethCollateralInProtocol);
//         uint256 btcCollateralUSDValue =  engine.getUsdValue(wbtc, btcCollateralInProtocol);
//         console.log("bbbbbbbbbbb", btcCollateralUSDValue);
//         uint256 totalUSDValueOfCollaterals = ethCollateralUSDValue + btcCollateralUSDValue;

//         assert( totalDSCSupply <= totalUSDValueOfCollaterals);

//     }

// }
