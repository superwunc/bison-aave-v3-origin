// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import '../../src/contracts/extensions/v3-config-engine/AaveV3Payload.sol';

/**
 * @dev bStock (Lista tokenized US equities) listing payload for the Bison V3 market on BSC.
 *      Price feeds are Lista's Atlas multi-oracle aggregators — verified on BSC mainnet to be
 *      Chainlink-aggregator compatible (decimals()/latestAnswer()/latestRoundData()).
 *
 *      Addresses sourced from https://docs.bsc.lista.org/for-developer/multi-oracle/multi-oracle-bstock
 *      Risk params below are CONSERVATIVE TEST DEFAULTS — bStock trades only during US market
 *      hours (stale oracle risk on weekends/overnight), so low LTV and tight caps.
 *      !!! MUST be reviewed by risk before any production listing !!!
 */
contract BNBStockListing is AaveV3Payload {
  // TSLAB (bStock) + Atlas oracle
  address internal constant TSLAB = 0x5b1910eAaD6450E50f816082Aa078C41F10C292f;
  address internal constant TSLAB_FEED = 0xf569C3e52e797219eCFDc1659c3250B0BbDC693C;
  // NVDAB (bStock) + Atlas oracle
  address internal constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
  address internal constant NVDAB_FEED = 0x2bd759006b423BFF444181A13C96a6b134E557BB;

  address public immutable ATOKEN_IMPL;
  address public immutable VTOKEN_IMPL;

  constructor(IEngine engine, address aTokenImpl, address vTokenImpl) AaveV3Payload(engine) {
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
    IEngine.ListingWithCustomImpl[] memory listings = new IEngine.ListingWithCustomImpl[](2);

    // TSLAB: enabled as collateral with low LTV, small caps
    listings[0] = IEngine.ListingWithCustomImpl({
      base: IEngine.Listing({
        asset: TSLAB,
        assetSymbol: 'TSLAB',
        priceFeed: TSLAB_FEED,
        rateStrategyParams: IEngine.InterestRateInputData({
          optimalUsageRatio: 45_00,
          baseVariableBorrowRate: 0,
          variableRateSlope1: 7_00,
          variableRateSlope2: 80_00
        }),
        enabledToBorrow: EngineFlags.DISABLED, // supply-only initially
        flashloanable: EngineFlags.DISABLED,
        ltv: 25_00,
        liqThreshold: 45_00,
        liqBonus: 7_50,
        reserveFactor: 20_00,
        supplyCap: 1_000, // 1k TSLAB (~$376k) — tight initial cap
        borrowCap: 0,
        liqProtocolFee: 10_00
      }),
      implementations: IEngine.TokenImplementations({aToken: ATOKEN_IMPL, vToken: VTOKEN_IMPL})
    });

    // NVDAB: fully passive first (LTV 0), observe oracle behaviour before enabling collateral
    listings[1] = IEngine.ListingWithCustomImpl({
      base: IEngine.Listing({
        asset: NVDAB,
        assetSymbol: 'NVDAB',
        priceFeed: NVDAB_FEED,
        rateStrategyParams: IEngine.InterestRateInputData({
          optimalUsageRatio: 45_00,
          baseVariableBorrowRate: 0,
          variableRateSlope1: 7_00,
          variableRateSlope2: 80_00
        }),
        enabledToBorrow: EngineFlags.DISABLED,
        flashloanable: EngineFlags.DISABLED,
        ltv: 0,
        liqThreshold: 0, // not collateral at listing
        liqBonus: 0,
        reserveFactor: 20_00,
        supplyCap: 500,
        borrowCap: 0,
        liqProtocolFee: 0
      }),
      implementations: IEngine.TokenImplementations({aToken: ATOKEN_IMPL, vToken: VTOKEN_IMPL})
    });

    return listings;
  }
}
