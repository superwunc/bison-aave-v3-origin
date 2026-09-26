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
import {IPoolDataProvider} from '../../src/contracts/interfaces/IPoolDataProvider.sol';
import {ACLManager} from '../../src/contracts/protocol/configuration/ACLManager.sol';

/**
 * @dev Listing payload for ONE bStock-shaped asset (18-dec equity token, USD 8-dec feed).
 */
contract StockListing is AaveV3Payload {
  address public immutable ASSET;
  address public immutable FEED;
  string internal SYMBOL; // set once in constructor (strings cannot be immutable)
  address public immutable ATOKEN_IMPL;
  address public immutable VTOKEN_IMPL;

  constructor(
    IEngine engine,
    address asset,
    address feed,
    string memory symbol,
    address aTokenImpl,
    address vTokenImpl
  ) AaveV3Payload(engine) {
    ASSET = asset;
    FEED = feed;
    SYMBOL = symbol;
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
        asset: ASSET,
        assetSymbol: SYMBOL,
        priceFeed: FEED,
        rateStrategyParams: IEngine.InterestRateInputData({
          optimalUsageRatio: 45_00,
          baseVariableBorrowRate: 0,
          variableRateSlope1: 7_00,
          variableRateSlope2: 80_00
        }),
        enabledToBorrow: EngineFlags.ENABLED, // borrow enabled so the smoke test can borrow
        flashloanable: EngineFlags.DISABLED,
        ltv: 25_00,
        liqThreshold: 45_00,
        liqBonus: 7_50,
        reserveFactor: 20_00,
        supplyCap: 1_000,
        borrowCap: 200,
        liqProtocolFee: 10_00
      }),
      implementations: IEngine.TokenImplementations({aToken: ATOKEN_IMPL, vToken: VTOKEN_IMPL})
    });
    return listings;
  }
}

/**
 * @dev bStock smoke test on the locally deployed Bison V3 market.
 *      Uses shape-equivalent tokens (18 decimals like real bStock) seeded with REAL prices
 *      captured from Lista's Atlas oracles on BSC mainnet:
 *        TSLAB = 37605188858 (8 dec)  NVDAB = 22687879027 (8 dec)
 *      Real-contract behaviour (transfer hooks etc.) is deferred to the BSC testnet run.
 */
contract SmokeTestBNBStock is Script {
  using stdJson for string;

  string internal constant REPORT =
    'reports/1790058183-market-deployment.json'; // local anvil default; override via MARKET_REPORT env

  function _report() internal view returns (string memory) {
    return vm.envOr('MARKET_REPORT', REPORT);
  }
  int256 internal constant TSLAB_PRICE = 37605188858; // $376.05 from Atlas on BSC
  int256 internal constant NVDAB_PRICE = 22687879027; // $226.88 from Atlas on BSC

  struct Assets {
    address tslab;
    address tslabFeed;
    address nvdab;
    address nvdabFeed;
  }

  Assets internal assets;
  uint256 internal tc0; // account snapshot before the trade
  uint256 internal dc0;

  function run() external {
    string memory json = vm.readFile(_report());
    address eoa = msg.sender;

    vm.startBroadcast();
    _deployAssets(eoa);
    _list(json, assets.tslab, assets.tslabFeed, 'TSLAB');
    _list(json, assets.nvdab, assets.nvdabFeed, 'NVDAB');
    _supplyBorrow(json, eoa);
    vm.stopBroadcast();

    _assert(json, eoa);
  }

  function _deployAssets(address owner) internal {
    assets.tslab = address(new TestnetERC20('Tesla bStock', 'TSLAB', 18, owner));
    assets.tslabFeed = address(new MockAggregator(TSLAB_PRICE));
    TestnetERC20(assets.tslab).mint(owner, 500e18);
    assets.nvdab = address(new TestnetERC20('Nvidia bStock', 'NVDAB', 18, owner));
    assets.nvdabFeed = address(new MockAggregator(NVDAB_PRICE));
    TestnetERC20(assets.nvdab).mint(owner, 500e18);
  }

  function _list(string memory json, address asset, address feed, string memory symbol) internal {
    StockListing payload = new StockListing(
      IEngine(json.readAddress('.configEngine')),
      asset,
      feed,
      symbol,
      json.readAddress('.aToken'),
      json.readAddress('.variableDebtToken')
    );
    ACLManager(json.readAddress('.aclManager')).addPoolAdmin(address(payload));
    payload.execute();
  }

  function _supplyBorrow(string memory json, address eoa) internal {
    IPool pool = IPool(json.readAddress('.poolProxy'));
    (tc0, dc0, , , , ) = pool.getUserAccountData(eoa);
    TestnetERC20(assets.tslab).approve(address(pool), 100e18);
    pool.supply(assets.tslab, 100e18, eoa, 0);
    pool.borrow(assets.tslab, 10e18, 2, 0, eoa);
  }

  function _assert(string memory json, address eoa) internal view {
    IPool pool = IPool(json.readAddress('.poolProxy'));
    IAaveOracle oracle = IAaveOracle(json.readAddress('.aaveOracle'));
    (uint256 tc, uint256 dc, , uint256 lt, uint256 ltv, uint256 hf) =
      pool.getUserAccountData(eoa);

    console.log('aTSLAB  :', pool.getReserveAToken(assets.tslab));
    console.log('TSLAB price (8 dec):', oracle.getAssetPrice(assets.tslab));
    console.log('NVDAB price (8 dec):', oracle.getAssetPrice(assets.nvdab));
    console.log('collateral (usd):', tc / 1e8);
    console.log('debt       (usd):', dc / 1e8);
    console.log('LT / LTV:', lt, ltv);
    console.log('health factor (x1e18):', hf / 1e18);

    require(oracle.getAssetPrice(assets.tslab) == uint256(TSLAB_PRICE), 'TSLAB price mismatch');
    require(oracle.getAssetPrice(assets.nvdab) == uint256(NVDAB_PRICE), 'NVDAB price mismatch');
    // delta assertions: 100 TSLAB supplied / 10 TSLAB borrowed at $376.05
    require(tc - tc0 == 37605.188858e8, 'collateral delta should be 100 TSLAB * $376.05');
    require(dc - dc0 == 3760.5188858e8, 'debt delta should be 10 TSLAB * $376.05');
    require(hf > 1e18, 'unhealthy');
    // per-reserve risk params check via ProtocolDataProvider
    IPoolDataProvider pdp = IPoolDataProvider(json.readAddress('.protocolDataProvider'));
    (, uint256 ltvTslab, uint256 ltTslab, , , , , , , ) =
      pdp.getReserveConfigurationData(assets.tslab);
    require(ltvTslab == 25_00, 'TSLAB LTV mismatch');
    require(ltTslab == 45_00, 'TSLAB LT mismatch');
    console.log('BSTOCK SMOKE TEST PASS: bStock-shaped assets listed via Atlas-style feeds, supply/borrow OK');
  }
}
