# GasPriceFeesHook — Uniswap v4 Dynamic Fee Hook

Uniswap Hook Incubator (UHI) homework: *Dynamic Fees: Gas Price Fee*.

## What it does

The hook sets a different swap fee on every swap depending on the transaction's gas price. It compares that gas price with the average gas price the hook has seen so far:

| Current `tx.gasprice` vs average | LP fee |
|---|---|
| more than 10% **above** | `2500` (0.25%): gas is expensive, so the swapper gets a discount |
| within ±10% | `5000` (0.5%) = `BASE_FEE` |
| more than 10% **below** | `10000` (1%): gas is cheap, so the fee is higher |

Fees are in pips (`1_000_000` = 100%).

### How it works

| Hook | Role |
|---|---|
| `beforeInitialize` | Reverts with `MustUseDynamicFee` unless the pool's `fee` is `LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`). A static-fee pool would ignore the override fee. |
| `beforeSwap` | Computes `getFee()` and returns it with `OVERRIDE_FEE_FLAG` (`0x400000`) set. That tells the PoolManager to use this fee for this swap only. |
| `afterSwap` | Adds `tx.gasprice` as a sample to the average. |
| `constructor` | The deployment transaction's gas price is the first sample. |

v4 offers two ways to change a dynamic fee. `poolManager.updateDynamicLPFee(key, fee)` stores the new fee in the pool's `Slot0` until it is changed again, which suits fees that change once per block or less often. Returning an override fee from `beforeSwap` applies to one swap. This hook uses the override, because the fee depends on each transaction's own gas price.

### Caveats

These come from the lesson design. The tests document them.

- **Cumulative, not moving, average.** Every sample has the same weight forever, so the average reacts more slowly as the count grows. A real moving average would use a window or an EMA.
- **Only swaps (and deployment) are sampled.** Adding liquidity does not update the average (`test_liquidityDoesNotUpdateAverage`).
- **Zero-gas deployment.** If the hook is deployed with `gasprice = 0`, the average starts at 0. Every early swap then looks "expensive" and gets the discount (`test_zeroGasDeployment_startsDiscounted`).
- **Gameable.** Users choose their own gas price. Paying a slightly higher gas price for a 50% fee cut can be cheaper overall on large swaps.

## Layout

| Path | |
|---|---|
| `src/GasPriceFeesHook.sol` | The hook |
| `test/GasPriceFeesHook.t.sol` | Lesson test, extra unit tests and fuzz tests |
| `script/DeployHook.s.sol` | Mines a CREATE2 salt with `HookMiner` and deploys |

## Run the tests

```bash
git clone --recurse-submodules <this repo>
forge test -vv
forge test --gas-report
```

What the tests cover:

- `test_feeUpdatesWithGasPrice`: the lesson test. Swaps at 10, 4 and 12 gwei. The average goes 10 → 8 → 9 gwei, and lower fees give more output.
- `test_appliedFeeMatchesGasBand`: reads the fee the PoolManager actually applied from its `Swap` event (2500 / 5000 / 10000).
- `test_getFee_boundaries`: exactly ±10% still pays `BASE_FEE`, because the comparisons are strict.
- `test_revertsOnStaticFeePool`: initializing with `fee = 3000` reverts with the wrapped `MustUseDynamicFee`.
- Fuzz with `bound()`: for any gas price from 0 to 1000 gwei, the fee band and the new average are both correct. Another test runs a sequence of 5 random-gas swaps.
- Fuzz with `vm.assume()`: any gas price above 11 gwei gets the 0.25% fee.

## Deploy

Target: **Sepolia**, PoolManager `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` ([Uniswap v4 deployments](https://developers.uniswap.org/docs/protocols/v4/deployments)).

```bash
cp .env.example .env   # PRIVATE_KEY, SEPOLIA_RPC_URL, ETHERSCAN_API_KEY

forge script script/DeployHook.s.sol --rpc-url sepolia                       # dry run
forge script script/DeployHook.s.sol --rpc-url sepolia --broadcast --verify --gas-estimate-multiplier 800
```

The hook address must encode its permissions: `beforeInitialize` (`0x2000`) | `beforeSwap` (`0x80`) | `afterSwap` (`0x40`) = `...20C0`. `HookMiner` searches for a salt whose CREATE2 address ends in those bits. The deployer it uses is forge's CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C`.

The `--gas-estimate-multiplier 800` flag is needed because forge's local EVM estimates about 1.3M gas for this deploy, but the Sepolia node charges about 6.3M.

### Deployed address

| Network | GasPriceFeesHook |
|---|---|
| Sepolia | `0xd68bF9DfF0D7De7946ec4F68cF4FC051d87C20C0` (pending broadcast) |
