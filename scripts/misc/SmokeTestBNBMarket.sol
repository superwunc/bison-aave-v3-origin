// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';
import 'forge-std/StdJson.sol';
import 'forge-std/console.sol';

import '../../src/contracts/extensions/v3-config-engine/AaveV3Payload.sol';
import {TestnetERC20} from '../../src/contracts/mocks/testnet-helpers/TestnetERC20.sol';
import {MockAggregator} from '../../src/contracts/mocks/oracle/CLAggregators/MockAggregator.sol';
import {IPool} from '../../src/contracts/interfaces/IPool.sol';
import {IAaveOracle} from '../../src/contracts/interfaces/IAaveOracle.sol';
import {ACLManager} from '../../src/contracts/protocol/configuration/ACLManager.sol';

/**
 * @dev Listing payload for the BNB market smoke test, following the production pattern:
 *      the payload contract is granted POOL_ADMIN and delegatecalls the ConfigEngine.
 */
contract BNBSmokeListing is AaveV3Payload {
  address public immutable USDX;
  address public immutable USDX_FEED;
  address public immutable ATOKEN_IMPL;
  address public immutable VTOKEN_IMPL;

  constructor(
    IEngine engine,
    address owner,
    address aTokenImpl,
    address vTokenImpl
  ) AaveV3Payload(engine) {
    USDX = address(new TestnetERC20('Mock USDT', 'USDT', 18, owner)); // mimics BSC USDT (18 dec)
    USDX_FEED = address(new MockAggregator(1e8)); // $1.00
    ATOKEN_IMPL = aTokenImpl;
    VTOKEN_IMPL = vTokenImpl;
  }

  function getPoolContext() public pure override returns (IEngine.PoolContext memory) {
    return IEngine.PoolContext({networkName: 'BNB Chain', networkAbbreviation: 'BNB'});
  }

  function newListingsCustom()
    public
    view
    override
    returns (IEngine.ListingWithCustomImpl[] memory)
  {
    IEngine.ListingWithCustomImpl[] memory listings = new IEngine.ListingWithCustomImpl[](1);
    listings[0] = IEngine.ListingWithCustomImpl({
      base: IEngine.Listing({
        asset: USDX,
        assetSymbol: 'USDT',
        priceFeed: USDX_FEED,
        rateStrategyParams: IEngine.InterestRateInputData({
          optimalUsageRatio: 90_00,
          baseVariableBorrowRate: 0,
          variableRateSlope1: 4_00,
          variableRateSlope2: 60_00
        }),
        enabledToBorrow: EngineFlags.ENABLED,
        flashloanable: EngineFlags.ENABLED,
        ltv: 75_00,
        liqThreshold: 78_00,
        liqBonus: 5_00,
        reserveFactor: 10_00,
        supplyCap: EngineFlags.KEEP_CURRENT, // unlimited
        borrowCap: EngineFlags.KEEP_CURRENT,
        liqProtocolFee: 10_00
      }),
      implementations: IEngine.TokenImplementations({aToken: ATOKEN_IMPL, vToken: VTOKEN_IMPL})
    });
    return listings;
  }
}

/**
 * @dev End-to-end smoke test against a deployed Bison V3 market (anvil dry-run).
 *      Reads the market report, lists a mock 18-decimals stable via a POOL_ADMIN payload
 *      (the same flow a real listing proposal uses), then supplies and borrows it.
 */
contract SmokeTestBNBMarket is Script {
  using stdJson for string;

  string internal constant REPORT = 'reports/1790058183-market-deployment.json';

  function run() external {
    address deployer = msg.sender;
    string memory json = vm.readFile(REPORT);

    IPool pool = IPool(json.readAddress('.poolProxy'));
    ACLManager acl = ACLManager(json.readAddress('.aclManager'));
    IAaveOracle oracle = IAaveOracle(json.readAddress('.aaveOracle'));
    address engine = json.readAddress('.configEngine');

    vm.startBroadcast();

    // 1. deploy listing payload (also deploys the mock USDT + feed)
    BNBSmokeListing payload = new BNBSmokeListing(
      IEngine(engine),
      deployer,
      json.readAddress('.aToken'),
      json.readAddress('.variableDebtToken')
    );

    // 2. grant it POOL_ADMIN and execute the listing
    acl.addPoolAdmin(address(payload));
    payload.execute();

    // 3. supply & borrow from the deployer EOA
    TestnetERC20 usdx = TestnetERC20(payload.USDX());
    usdx.mint(deployer, 1_000_000e18);
    usdx.approve(address(pool), 100_000e18);
    pool.supply(address(usdx), 100_000e18, deployer, 0);
    pool.borrow(address(usdx), 50_000e18, 2, 0, deployer);

    vm.stopBroadcast();

    // 4. on-chain assertions (view calls)
    address aUsdx = pool.getReserveAToken(address(usdx));
    address vUsdx = pool.getReserveVariableDebtToken(address(usdx));
    (uint256 tc, uint256 dc, , , , uint256 hf) = pool.getUserAccountData(deployer);

    console.log('aUSDT  :', aUsdx);
    console.log('vUSDT  :', vUsdx);
    console.log('oracle price (usd, 8 dec):', oracle.getAssetPrice(address(usdx)));
    // base currency of this market is USD (8 decimals)
    console.log('collateral (usd, 8 dec):', tc / 1e8);
    console.log('debt      (usd, 8 dec):', dc / 1e8);
    console.log('health factor (x1e18)  :', hf / 1e18);

    require(aUsdx.code.length > 0, 'aToken not initialized');
    require(vUsdx.code.length > 0, 'debtToken not initialized');
    // 100k supplied, 50k borrowed out
    require(usdx.balanceOf(aUsdx) == 50_000e18, 'aToken balance mismatch');
    require(tc == 100_000e8, 'collateral mismatch');
    require(dc == 50_000e8, 'debt mismatch');
    require(hf > 1e18, 'unhealthy right after borrow');
    console.log('SMOKE TEST PASS: payload listing -> supply -> borrow all worked on the live market');
  }
}
