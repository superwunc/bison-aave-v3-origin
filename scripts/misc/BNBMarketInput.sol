// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import '../../src/deployments/inputs/MarketInput.sol';

/**
 * @dev Market input for Bison V3 on BNB Smart Chain (chainId 56).
 *      All values are compile-time constants so the deployment report is deterministic.
 *
 *      MAINNET CHECKLIST before running against chainId 56:
 *      - Replace roles with production multisig addresses (deployer-as-role is testnet only).
 *      - Verify WBNB / BNB-USD feed addresses on-chain (`cast` them), see reports/ for reference.
 */
contract BNBMarketInput is MarketInput {
  // WBNB on BSC mainnet
  address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  // Chainlink BNB/USD aggregator on BSC mainnet (8 decimals), verified on-chain
  address internal constant BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

  function _getMarketInput(
    address deployer
  )
    internal
    pure
    override
    returns (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory deployedContracts
    )
  {
    // TODO(mainnet): point each role to its own multisig / timelock
    roles.marketOwner = deployer;
    roles.emergencyAdmin = deployer;
    roles.poolAdmin = deployer;

    config.marketId = 'Bison V3 Market';
    config.providerId = 45392; // 0xB150, must be unique in the PoolAddressesProviderRegistry
    config.oracleDecimals = 8;
    config.flashLoanPremium = 0.0005e4; // 0.05%

    // BSC is an L1-style chain: standard Pool, not L2Pool
    flags.l2 = false;

    // Bison is the base currency of the market, USD-quoted
    config.networkBaseTokenPriceInUsdProxyAggregator = BNB_USD_FEED;
    config.marketReferenceCurrencyPriceInUsdProxyAggregator = BNB_USD_FEED;

    config.wrappedNativeToken = WBNB;
    config.salt = bytes32(0);
    // empty addresses: deploy fresh Collector (treasury) and incentives proxy
    config.treasury = address(0);
    config.incentivesProxy = address(0);

    return (roles, config, flags, deployedContracts);
  }
}
