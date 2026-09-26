// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import '../../src/deployments/inputs/MarketInput.sol';

/**
 * @dev Market input for Bison V3 on BNB Smart Chain TESTNET (chapel, chainId 97).
 *      Roles = deployer (testnet convention). All addresses verified on-chain 2026-09-23.
 *
 *      bStock is mainnet-only; on testnet list mock/test assets via a listing payload.
 */
contract BNBTestnetMarketInput is MarketInput {
  // WBNB on BSC testnet, verified via PancakeSwap testnet Router.WETH()
  address internal constant WBNB_TESTNET = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
  // Mock BNB/USD aggregator deployed by DeployMockFeed.sol (Chainlink has no reliable
  // public BNB/USD feed on chapel; testnet markets use mocks, mainnet uses the real feed)
  address internal constant BNB_USD_MOCK_FEED = 0x2cF3A243b009bf87CB61c74e2dCBb320A07300ec;

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
    roles.marketOwner = deployer;
    roles.emergencyAdmin = deployer;
    roles.poolAdmin = deployer;

    config.marketId = 'Bison V3 Testnet Market';
    config.providerId = 45392; // 0xB150
    config.oracleDecimals = 8;
    config.flashLoanPremium = 0.0005e4;

    flags.l2 = false;

    config.networkBaseTokenPriceInUsdProxyAggregator = BNB_USD_MOCK_FEED;
    config.marketReferenceCurrencyPriceInUsdProxyAggregator = BNB_USD_MOCK_FEED;

    config.wrappedNativeToken = WBNB_TESTNET;
    config.salt = bytes32(0);
    config.treasury = address(0);
    config.incentivesProxy = address(0);

    return (roles, config, flags, deployedContracts);
  }
}
