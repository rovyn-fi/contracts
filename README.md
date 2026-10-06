# Rovyn contracts

Smart contracts used by [Rovyn](https://rovyn.fi) on Robinhood Chain (chain ID 4663).

| Contract | Address | File |
|---|---|---|
| Limit orders | `0x02420b146ce5c33e8fa2af928c07858b8a5162f1` | [RovynLimitOrders.sol](RovynLimitOrders.sol) |
| Fee router | `0xc4C48136d6204009AbA72d3d47dc8d2a60262FDA` | [RovynFeeRouter.sol](RovynFeeRouter.sol) |

## RovynLimitOrders

Gasless limit and stop orders.

- You sign an order (EIP-712). **Your funds stay in your wallet until the order fills.**
- When the price is reached, the Rovyn keeper fills the order. The contract checks that you receive **at least the amount you signed for**, or the whole fill reverts.
- Only the keeper can fill, and only through two allow-listed swap contracts.
- Everything the swap returns goes to you. The contract keeps no surplus.
- Each order can be filled once. You can cancel it on-chain at any time with `cancel(nonce)`.
- Smart-contract wallets are supported (EIP-1271).

Compiled with Solidity 0.8.28.

## RovynFeeRouter

The fee layer for direct Uniswap routes.

- The fee is taken from the input asset and split between the rewards pool and the treasury.
- The swap and the fee transfers are atomic: if the swap fails, the whole transaction reverts.
- Token approvals are limited to the trade amount and revoked after execution.
- The Uniswap Universal Router and Permit2 addresses are immutable.
- Ownership transfer is two-step. Emergency rescue works only while the contract is paused.

## License

MIT
