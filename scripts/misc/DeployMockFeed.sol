// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';
import 'forge-std/console.sol';

import {MockAggregator} from '../../src/contracts/mocks/oracle/CLAggregators/MockAggregator.sol';

/**
 * @dev Deploys a mock BNB/USD aggregator for the testnet market config.
 *      Run BEFORE DeployAaveV3MarketBNBTestnet and paste the printed address into
 *      scripts/misc/BNBTestnetMarketInput.sol (BNB_USD_MOCK_FEED).
 */
contract Default is Script {
  function run() external {
    vm.startBroadcast();
    MockAggregator feed = new MockAggregator(600e8); // placeholder $600 BNB
    vm.stopBroadcast();
    console.log('MockFeed:', address(feed));
  }
}
