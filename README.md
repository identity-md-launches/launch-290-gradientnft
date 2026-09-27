# Gradients (GRAD) and GradientNFT

Solidity contracts for the Gradients project launch on Sepolia (chain id 11155111), built with Foundry.

| Contract      | File                  | Role                                                                 |
| ------------- | --------------------- | -------------------------------------------------------------------- |
| `LaunchToken` | `src/LaunchToken.sol` | Fixed-supply ERC-20 **Gradients (GRAD)**, the launch and working currency |
| `GradientNFT` | `src/GradientNFT.sol` | ERC-721 **Gradients (GRADIENT)**, at most 1,000 on-chain gradients paid for in GRAD |

ABI exports live in `docs/abi/LaunchToken.json` and `docs/abi/GradientNFT.json`; `docs/ABI.md` describes them.

## Quick start

```sh
forge build
forge test
forge fmt --check
```

The compiler is pinned to `solc = "0.8.26"` in `foundry.toml`, with `bytecode_hash = "none"`. Dependencies
(forge-std 1.9.7 and OpenZeppelin Contracts 5.1.0) are vendored as ordinary files under `lib/`; there are no
git submodules and no network access is needed to build or test. Tests read no environment variables and pass in
any order and in parallel.

## LaunchToken (GRAD)

- ERC-20 named `Gradients`, symbol `GRAD`, 18 decimals.
- No constructor arguments. The constructor mints exactly **1,000,000,000 GRAD** (`10^27` minor units) to
  `msg.sender` and nothing else can ever be minted.
- No owner, mint, pause, blocklist, fee, hook or upgrade path. The runtime contains no `DELEGATECALL`,
  `CALLCODE` or `SELFDESTRUCT`.
- It does not accept ETH.

On Sepolia the deployer is the ProjectFactory, which routes the whole supply to the ETH/GRAD launch pool and the
reward distributor. No application contract needs a GRAD balance at deploy time; users obtain GRAD by swapping
Sepolia ETH in the launch pool.

## GradientNFT (GRADIENT)

An OpenZeppelin ERC-721 whose art is generated entirely on-chain.

### Parameters (all source constants)

| Name           | Value                                        | Meaning                                                   |
| -------------- | -------------------------------------------- | --------------------------------------------------------- |
| `name`         | `Gradients`                                  | ERC-721 name                                              |
| `symbol`       | `GRADIENT`                                   | ERC-721 symbol                                            |
| `MAX_SUPPLY`   | `1000`                                       | Token ids 1 to 1,000, assigned in mint order              |
| `PRICE`        | `10_000e18`                                  | 10,000 GRAD per token                                     |
| `MAX_PER_MINT` | `10`                                         | `mint(quantity)` accepts 1 to 10                          |
| `BURN_ADDRESS` | `0x000000000000000000000000000000000000dEaD` | Every payment goes here; nobody controls this address     |
| `token`        | constructor argument (`$token`)              | The GRAD address, stored as an immutable, exposed as `token()` |

The constructor takes exactly one argument, the GRAD address, and reverts only if it is the zero address. It
performs no token calls, needs no balance, and sets no owner.

### Minting

`mint(uint256 quantity)`:

1. Reverts with `InvalidQuantity` unless `1 <= quantity <= 10`.
2. Reverts with `ExceedsMaxSupply` if `totalMinted() + quantity > 1000`. There is never a partial mint.
3. Reserves the id range `totalMinted()+1 .. totalMinted()+quantity` by advancing the counter.
4. Moves `10,000e18 * quantity` GRAD with a single `SafeERC20.safeTransferFrom(msg.sender, BURN_ADDRESS, ...)`.
   The minter must have approved GradientNFT for at least that amount. GradientNFT never holds GRAD.
5. Emits `Minted(minter, firstId, quantity)`.
6. Calls `_safeMint` for each reserved id, which emits the ERC-721 `Transfer` events and, for contract
   minters, invokes `onERC721Received`.

Because the counter is advanced and the payment is taken before any `_safeMint`, a re-entrant
`onERC721Received` sees the updated counter. It can mint again only by paying again and only while the cap
allows, and its ids follow the whole outer batch. This is tested with a re-entrant receiver at the cap, one
with no funds left, one with allowance only for the outer call, and one that is fully funded.

`PRICE * quantity` cannot overflow because `quantity` is bounded to 10 before the multiplication.

### Views and events

- `totalMinted()` number of tokens minted (tokens are never burned, so also the supply).
- `burnedTotal()` equals `PRICE * totalMinted()`, the GRAD sent to the burn address by this contract.
- `MAX_SUPPLY`, `PRICE`, `MAX_PER_MINT`, `BURN_ADDRESS`, `token()`.
- `artOf(id)` returns the two 24-bit colours and the angle; `svgOf(id)` returns the raw SVG. Both are pure and
  are provided for the website and for independent verification.
- `tokenURI(id)` reverts with `ERC721NonexistentToken` for unminted ids.
- Events: ERC-721 `Transfer` / `Approval` / `ApprovalForAll`, plus `Minted(address indexed minter, uint256 firstId, uint256 quantity)`.

### Art

`tokenURI(id)` returns `data:application/json;base64,<json>` where the JSON is

```json
{"name":"Gradient #<id>","description":"...","attributes":[
  {"trait_type":"Colour A","value":"#rrggbb"},
  {"trait_type":"Colour B","value":"#rrggbb"},
  {"trait_type":"Angle","value":<0-359>}],
 "image":"data:image/svg+xml;base64,<svg>"}
```

and the SVG is a 512x512 image with one `linearGradient` rotated by the angle. The parameters come from
`h = keccak256(abi.encodePacked(id))`: colour A is bytes 0-2 of `h`, colour B is bytes 3-5, both as lowercase
`#rrggbb`, and the angle is `uint16(bytes 6-7) % 360`. Only decimal numbers and lowercase hex digits are ever
interpolated into the JSON or SVG, so no id can inject markup.

**The art is a pure function of the id and involves no block data.** Ids are handed out sequentially, so the
order in which mints land on-chain decides who receives which gradient. Anyone can compute the art for every id
in advance, and a minter can see exactly which ids their transaction will receive if it is the next to be
included. There is no randomness in this contract and none is claimed.

### What GradientNFT cannot do

- It has no owner, admin, withdraw, pause, price-setting or upgrade function.
- It has no `payable` function, no `receive` and no `fallback`, so it cannot receive ETH.
- It never transfers GRAD to itself. The only GRAD movement is the burn from the minter.
- Its runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` and fits EIP-170.

Anyone can still push GRAD (or any other ERC-20) directly to the contract address with a plain `transfer`.
Such tokens are stuck by design: there is no withdraw path and the contract has nothing to do with them.
This is a property of every contract without a sweep function and is documented rather than mitigated,
because adding a sweep would introduce a privileged role the workflow excludes.

## Deployment

The Sepolia launch is done by the ProjectFactory from `launch.json`, which a separate manifest assignment
writes. The parameters this source implies for that manifest are:

| Item                       | Value                                                        |
| -------------------------- | ------------------------------------------------------------ |
| Launch token               | `LaunchToken` (`src/LaunchToken.sol`), no constructor args    |
| Application contract       | `GradientNFT` (`src/GradientNFT.sol`)                         |
| `GradientNFT` constructor  | one `address` argument, `["$token"]`                          |
| Privileged roles           | none; there is no `$owner` argument anywhere                  |
| Chain                      | Sepolia, 11155111                                            |
| Pool                       | ETH/GRAD, seeded by the factory with the launch token only    |

Both constructors run with the factory as `msg.sender`. `LaunchToken` mints to that sender, as the factory
requires. `GradientNFT` does not read `msg.sender` at all.

`script/Deploy.s.sol` is a local helper (anvil) that reproduces the same two steps in order; `deploy()` takes
no configuration and is covered by `test/Deploy.t.sol`. It is not the launch path and this repository never
holds or uses a wallet key.

## Operational responsibilities

- **Nobody operates GradientNFT.** There is no key to protect, no parameter to tune and no funds to custody.
  After deployment the only actions are user mints and ERC-721 transfers.
- **Liquidity and price discovery** belong to the factory-seeded ETH/GRAD pool. The GRAD price of a mint is
  fixed at 10,000 GRAD; its ETH cost floats with the pool.
- **Burned GRAD is gone.** Payments go to the dead address and cannot be recovered or redistributed. There are
  no payouts, refunds or royalties in the contract.
- **Sell-out is final.** Once 1,000 tokens exist, `mint` reverts forever. No further supply can be added.
- **Frontend (later stage).** The mint page reads the GRAD address from `token()`, shows balance and allowance,
  requires an `approve` before each paying action, and builds its gallery from `totalMinted()`, `tokenURI(id)`
  and `Minted` / `Transfer` logs. It must tell users GRAD comes from swapping Sepolia ETH in the launch pool.

## Assumptions

- GRAD is the standard OpenZeppelin ERC-20 delivered in this repository: no fee on transfer, no rebasing,
  boolean-returning. `SafeERC20` is still used so a false return or missing boolean would revert rather than
  mint unpaid.
- The factory supplies a non-zero GRAD address as `$token`. A zero address reverts the constructor.
- Sepolia block gas limits comfortably cover a 10-token mint (roughly 0.6M gas including the ERC-20 transfer).
- Wallets and marketplaces render `data:` URIs; the JSON and SVG are plain ASCII and under 2 KB per token.

## Tests

`forge test` runs 47 tests across four suites:

- `test/LaunchToken.t.sol` metadata, exact supply and recipient, transfer and allowance behaviour, absence of
  mint/admin selectors, ETH rejection.
- `test/GradientNFT.t.sol` construction; successful mints of 1, 10 and mixed sequences with exact burn
  accounting and event checks; quantity 0, 11 and overflow-sized quantities; the quantity-10 mint at 995
  reverting whole; minting exactly to 1,000 and one more reverting; missing allowance and insufficient
  balance; rejecting and non-receiver contracts rolling back; re-entrant receivers at the cap, unfunded,
  under-approved and funded; `tokenURI` reverting for unminted ids, decoding to JSON containing the SVG,
  being byte-identical across calls and blocks, and matching an independent reference encoding; the art
  derivation matching a byte-indexed reference under fuzzing; the SVG output alphabet being printable ASCII.
- `test/GradientNFT.invariant.t.sol` a handler with valid and invalid mints, transfers, stray ETH sends and
  stray GRAD pushes, asserting that the dead balance always equals `burnedTotal()`, the cap is never exceeded,
  the contract never accumulates value by itself, and every minted token has an owner.
- `test/Deploy.t.sol` the local deploy helper and a factory-style deployment from an arbitrary caller.

Tests passing are not a security audit. The workflow requires an independent adversarial review of the cap
and payment under re-entrancy, price overflow for large quantities, JSON/SVG injection, and any path that
could leave GRAD or ETH in the contract, before deployment.

## Layout

```
foundry.toml          compiler pin, bytecode_hash = "none", ffi off, no fs permissions
remappings.txt        forge-std and @openzeppelin/contracts
src/                  LaunchToken.sol, GradientNFT.sol
script/Deploy.s.sol   local deployment helper
test/                 Foundry tests and small helpers under test/utils
docs/abi/             ABI JSON for both contracts
docs/ABI.md           human-readable interface description
lib/                  vendored forge-std and OpenZeppelin (plain files)
```
