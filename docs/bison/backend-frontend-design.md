# Bison V3 后端 API 与前端 设计文档

> 版本:v1.0(2026-09-23)
> 适用:Bison V3 市场(BSC testnet 已部署 / BSC mainnet 规划中)
> 配套仓库:`bison-aave-v3-origin`(Aave v3.7 fork)

---

## 1. 目标与范围

| 项目 | 内容 |
|---|---|
| 后端 | 只读 API 服务,聚合链上 Pool 数据,为前端/第三方提供 REST + WebSocket 接口 |
| 前端 | 市场行情页、资产列表、用户仓位(Dashboard)、存款/借款操作入口 |
| 范围内 | 储备/利率/价格/用户仓位/历史事件/清算/激励查询;交易模拟报价(staticCall) |
| 范围外 | 私钥托管、签名中继(relayer)、链上写交易(前端直接与 Pool 交互) |

**设计原则:后端 100% 只读。** 所有资金操作由前端直接对合约签名发起,后端不碰私钥,大幅降低安全面。

---

## 2. 总体架构

```
┌──────────┐   REST / WS    ┌─────────────────────────────────────┐
│  前端    │ ◄────────────► │            后端 API 服务             │
│ (Next.js)│                │  ┌─────────┐  ┌──────────────────┐  │
└──────────┘                │  │ API 层  │  │  链上数据层        │  │
     │  直接签名发交易       │  └─────────┘  │ ┌──────────────┐ │  │
     ▼                     │  ┌─────────┐  │ │ Reader(Calls)│ │  │
┌──────────┐                │  │ 缓存层   │◄─┤ │ (multicall)  │ │  │
│ BSC RPC  │◄───────────────┼──┤ Redis   │  │ └──────────────┘ │  │
└──────────┘                │  └─────────┘  │ ┌──────────────┐ │  │
     ▲                      │  ┌─────────┐  │ │ Indexer      │ │  │
     │  logs / headers      │  │ Postgres│◄─┤ │ (事件→DB)    │ │  │
     └──────────────────────┼──└─────────┘  │ └──────────────┘ │  │
                            └───────────────┴──────────────────┘──►│
```

三层数据来源,按实时性要求选择:

| 数据 | 来源 | 延迟 |
|---|---|---|
| 全市场快照(储备/利率/价格/配置) | 合约 `view` 调用(multicall 聚合) | 15–30s 定时刷新 |
| 用户仓位 | `Pool.getUserAccountData` + `UiPoolDataProviderV3.getUserReservesData` | 请求时实时读 + 短缓存(5s) |
| 历史(交易/清算/利率曲线) | 事件索引到 Postgres | 随区块(≈0.75s) |
| 实时推送 | 订阅 `ReserveDataUpdated` / `Supply` / `Borrow` 等事件 → WS | 秒级 |

> 不引入 The Graph 子图作为首选项:数据量不大(单市场,储备数 < 50),自建 Indexer(ethers/viem + Postgres)更可控、零外部依赖;后期规模大了可平滑加子图。

---

## 3. 合约数据源清单(已部署地址)

| 合约 | 用途 | 关键方法 |
|---|---|---|
| `UiPoolDataProviderV3` | **市场聚合数据主入口** | `getReservesData(provider)` → 全部储备+基准货币;`getUserReservesData(provider,user)`;`getEModes(provider)` |
| `AaveProtocolDataProvider` | 单储备配置/统计 | `getReserveConfigurationData`、`getReserveCaps`、`getReserveData`、`getATokenTotalSupply`、`getTotalDebt` |
| `Pool` | 用户账户聚合 | `getUserAccountData(user)` → (collateral, debt, availableBorrows, LT, LTV, HF) |
| `WalletBalanceProvider` | 钱包余额 | `getUserWalletBalances(provider, user)` |
| `AaveOracle` | 价格 | `getAssetsPrices(assets)`、`getAssetPrice(asset)` |
| `RewardsController` + `UiIncentiveDataProviderV3` | 激励 | `getRewardsData(asset)`、`getFullReservesIncentiveData` |
| `PoolAddressesProvider` | 地址解析(全部合约地址的根) | `getPool()`、`getPriceOracle()`… |

**地址配置:全部从部署报告 JSON 派生一个 chain config 文件,后端/前端共用一份:**

```jsonc
// config/chains/97.json —— 由 reports/1790097453-market-deployment.json 生成
{
  "chainId": 97,
  "name": "BSC Testnet",
  "rpc": ["https://bsc-testnet-rpc.publicnode.com"],
  "addressesProvider": "0xf83Bd48D289e72DD846C2c2Bc30fF824e307095E",
  "pool": "0x3dab6CA8029298adb2a04691787934BAd8F0dC84",
  "uiPoolDataProvider": "0xD96e91A599F5f427708f2d95530B45FE1999Cf63",
  "protocolDataProvider": "0xcB5AA2B357F4Ee429d360342159a099Ca6a9080A",
  "walletBalanceProvider": "0x375F7d4677eA9D467930B32307c58B5c4747Ed86",
  "aaveOracle": "0x73Af59363200e6b38e7C351892Fa25C864edaAa5",
  "wrappedNative": "0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd",
  "baseCurrency": { "unit": "1e8", "decimals": 8, "symbol": "USD" }
}
```

---

## 4. API 设计(REST,前缀 `/v1`)

### 4.0 通用约定

- **金额单位**:一律返回**最小单位整数 + decimals 字段**,由前端格式化显示(避免浮点/精度损失)。USD 值为 8 位精度(市场基准货币)。
- **响应包裹**:`{ "data": ..., "meta": { "chainId": 97, "block": 132555872, "timestamp": 1790097800 } }`
- **错误**:`{ "error": { "code": "RESERVE_NOT_FOUND", "message": "..." } }`,HTTP 状态码 4xx/5xx。
- 限流:公开接口 60 req/min/IP;WS 单连接 50 订阅。

### 4.1 市场与储备

#### `GET /v1/markets/summary` — 市场总览(首页顶栏)

```jsonc
{
  "data": {
    "marketId": "Bison V3 Testnet Market",
    "totalPoolUsd": "12570518885800",      // 总抵押品 USD(8 dec)
    "totalBorrowUsd": "376051888580",
    "availableLiquidityUsd": "12194466997220",
    "utilizationAvg": "0.312",             // 可读字符串,前端展示用
    "reserveCount": 3,
    "baseCurrencyPriceUsd": "600000000"    // BNB 价(mock feed 期间)
  }
}
```

#### `GET /v1/reserves` — 储备列表

直接映射 `UiPoolDataProviderV3.getReservesData()`,一次 RPC 得全量:

```jsonc
{
  "data": [{
    "underlyingAsset": "0x5b19...",
    "symbol": "TSLAB",
    "decimals": 18,
    "priceUsd": "37605188858",
    "isActive": true, "isFrozen": false, "isPaused": false,
    "usageAsCollateralEnabled": true,
    "borrowingEnabled": true, "flashLoanEnabled": false,
    "ltv": "2500", "liquidationThreshold": "4500",
    "liquidationBonus": "7500",             // = 1 + bonus(750 bips)
    "reserveFactor": "2000",
    "supplyCap": "1000", "borrowCap": "200",   // 最小单位
    "interest": {                              // 来自 ReserveDataUpdated/IR strategy
      "liquidityRate": "23148024227900000000", // per-annum ray(1e27)
      "variableBorrowRate": "70000000000000000000000000",
      "utilizationRate": "0.1",
      "optimalUsageRatio": "4500",
      "slope1": "700", "slope2": "8000", "baseRate": "0"
    },
    "totals": {
      "availableLiquidity": "900000000000000000000", // 最小单位
      "totalSupplied": "1000000000000000000000",
      "totalBorrowed": "100000000000000000000",
      "aTokenSupply": "1000000000000000000000",
      "liquidityIndex": "1000000000000000000000000000", // ray
      "variableBorrowIndex": "1000000000000000000000000000"
    },
    "emodeId": 0,
    "siloedBorrowing": false,
    "oracle": "0xf569..."
  }]
}
```

#### `GET /v1/reserves/{asset}` — 单储备详情(列表数据 + caps + eMode 规则)

#### `GET /v1/reserves/{asset}/rates/history?from=&to=&interval=1h` — 利率/利用率曲线

来自 Indexer 对 `ReserveDataUpdated(reserve, liquidityRate, variableBorrowRate, liquidityIndex, variableBorrowIndex)` 的落库,聚合到指定 interval。

#### `GET /v1/emodes` — eMode 类别(v3.7 含 `isolated` 标志、`collateralBitmap`)

### 4.2 用户

#### `GET /v1/users/{address}/account` — 账户总览(Dashboard 头部)

`Pool.getUserAccountData` 直读:

```jsonc
{
  "data": {
    "address": "0xbe71...",
    "totalCollateralUsd": "3760518885800",
    "totalDebtUsd": "376051888580",
    "availableBorrowsUsd": "3268451114240",
    "currentLiquidationThreshold": "4500",
    "ltv": "2500",
    "healthFactor": "4500000000000000000",   // 18 dec;< 1e18 即有清算风险
    "isInIsolationMode": false,              // v3.7 isolated eMode 状态
    "inEModeCategory": 0
  }
}
```

#### `GET /v1/users/{address}/positions` — 分资产仓位

`UiPoolDataProviderV3.getUserReservesData` + `getUserAccountData` 合成:

```jsonc
{
  "data": [{
    "underlyingAsset": "0x5b19...",
    "symbol": "TSLAB",
    "supplied": "100000000000000000000",      // aToken 余额(计利息后,由 scaled×index 算)
    "scaledSupplied": "100000000000000000000",
    "usageAsCollateral": true,
    "borrowed": "10000000000000000000",
    "scaledBorrowed": "10000000000000000000",
    "suppliedUsd": "3760518885800",
    "borrowedUsd": "376051888580",
    "canBeCollateral": true,
    "rewardBalance": []                        // incentives
  }]
}
```

#### `GET /v1/users/{address}/wallet` — 钱包余额(可供应额度)

`WalletBalanceProvider.getUserWalletBalances`,仅返回已上架资产。

#### `GET /v1/users/{address}/history?type=supply,borrow,liquidation&from=&to=&page=` — 交易历史

Indexer 事件合成:`Supply`/`Withdraw`/`Borrow`/`Repay`/`LiquidationCall`/`ReserveUsedAsCollateralEnabled|Disabled`。

### 4.3 价格与模拟

#### `GET /v1/prices` — 全部资产 USD 价格(来自 AaveOracle,与协议清算用价**同源**)

#### `POST /v1/simulate/{action}` — 交易模拟报价(**staticCall,不上链**)

`action ∈ {supply, withdraw, borrow, repay}`,body: `{ "asset", "amount", "user" }`。
后端对 Pool 做 `eth_call` 模拟,返回执行后的预期状态,供前端确认框展示:

```jsonc
// POST /v1/simulate/borrow  { "asset": "0x5b19...", "amount": "10000000000000000000" }
{
  "data": {
    "ok": true,
    "healthFactorBefore": "4500000000000000000",
    "healthFactorAfter": "3029411764705882352",
    "revertReason": null
  }
}
// 不满足条件时: { "ok": false, "revertReason": "COLLATERAL_CANNOT_COVER_NEW_BORROW" }
```

### 4.4 运维接口

- `GET /v1/health` — 服务健康 + RPC 连接状态 + 链上最新块滞后告警
- `GET /v1/config` — 当前 chain config(前端启动时拉取,切换 testnet/mainnet)

### 4.5 WebSocket `wss://.../ws`

客户端订阅消息:`{ "op": "subscribe", "channel": "...", "params": {...} }`

| channel | 推送内容 | 触发 |
|---|---|---|
| `market` | 全市场摘要(每 15s 或有事件时) | 定时 + 事件 |
| `reserves` | 储备利率/价格变化 | `ReserveDataUpdated` 日志 |
| `user:{address}` | 该用户 HF/仓位变化 | 该地址相关的 Supply/Borrow/… 日志 |
| `liquidations` | 清算流水 | `LiquidationCall` 日志 |

---

## 5. 后端技术方案

| 组件 | 选型 | 说明 |
|---|---|---|
| 语言/框架 | **Node.js + Fastify**(或 NestJS)| 与前端同语言,`viem` 生态成熟;Go 亦可 |
| 链上交互 | **viem + multicall3** | `getReservesData` 单调用即全量;其余场景 multicall 合并 |
| 缓存 | Redis | `reserves:summary` TTL 15s;`user:{addr}` TTL 5s;价格 TTL 10s |
| 事件索引 | 自建 Indexer(viem `watchEvent` + 启动回扫)→ Postgres | 表:`events`(原始)、`reserve_snapshots`(利率时序)、`liquidations` |
| 任务 | 定时器(快照刷新)+ 事件驱动(实时) | 启动时从最近 N 块回补缺口(按事件块高断点续传) |
| 部署 | Docker;环境变量指定 chain config 路径 | testnet/mainnet 同一镜像不同 env |

**RPC 策略**:主 RPC + 备用 RPC 列表,`view` 全部走 multicall(单储备一轮 < 10 个调用);关键读失败时降级返回缓存(标 `meta.stale=true`)。

---

## 6. 前端项目概览

| 项 | 选型/方案 |
|---|---|
| 框架 | Next.js(React)+ TypeScript + wagmi/viem + RainbowKit(钱包连接) |
| 数据 | 服务端:react-query 调本 API(轮询/WS 混合);**合约读也走后端**,前端不直连 RPC(除发交易) |
| 发交易 | 前端直接 `Pool.supply/borrow/...`(wagmi `useWriteContract`),后端 `/simulate` 做前置校验 |

### 页面结构

```
/                     市场总览:TVL、总借款、储备列表(利率/利用率/LTV/caps)
/reserves/[asset]     资产详情:利率曲线(后端 history)、价格、配置、供应/借款面板
/dashboard            我的仓位(需连钱包):总净值、HF 仪表盘、各资产存借明细、钱包余额
/dashboard/history    交易历史(分页表格,事件合成)
/liquidations         清算监控(运营/风控视角,公开)
```

**关键交互**:
- 供应/借款弹窗先调 `POST /v1/simulate/*` 展示"操作后 HF",再拉起钱包签名
- HF < 1.5 时 Dashboard 顶部风险横幅(WS 推送驱动)
- v3.7 特性展示:eMode 进入/退出入口、isolated eMode 资产标识(bStock 类若启用)

---

## 7. 安全与注意事项

1. **后端零私钥**:无任何 write 路径;`/simulate` 仅 staticCall。
2. 用户地址参数校验(`0x[40hex]`),防注入;历史查询强制分页 + 最大时间窗。
3. RPC 供应商密钥仅存在于后端;前端只知后端域名。
4. 价格展示注明来源是 **AaveOracle(协议清算同源价)**,与 CEX 价可能有偏差——避免用户误解清算触发条件。
5. testnet 阶段 MockFeed 价格固定 $600,前端对 `priceOracle` 合约打 `isMock` 标签(chain config 中标记)。

## 8. 里程碑建议

| 阶段 | 内容 | 依赖 |
|---|---|---|
| M1(3–5 天)| 后端:config + `/reserves` `/markets/summary` `/users/*/account`(纯读)+ 缓存 | 无 |
| M2(3 天)| Indexer:事件落库 + `/history` `/rates/history` + WS | M1 |
| M3(3–5 天)| 前端:总览页 + 资产详情 + Dashboard(只读部分) | M1 |
| M4(3 天)| `/simulate` + 前端交易流程(签名直连 Pool)+ eMode/isolated 展示 | M1–M3 |
| M5 | 主网上线适配:真实 Chainlink feed、BscScan 验证、多签角色、监控告警 | 主网部署 |
