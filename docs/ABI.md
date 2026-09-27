# ABI reference

Machine-readable ABIs, generated with `forge inspect <Contract> abi --json` from the pinned solc 0.8.26 build:

- `docs/abi/LaunchToken.json`
- `docs/abi/GradientNFT.json`

Regenerate after any source change:

```sh
forge inspect LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect GradientNFT abi --json > docs/abi/GradientNFT.json
```

## LaunchToken

Standard OpenZeppelin ERC-20 surface plus one constant.

| Function | Notes |
| --- | --- |
| `name()` / `symbol()` / `decimals()` | `"Gradients"`, `"GRAD"`, `18` |
| `totalSupply()` | Always `1_000_000_000e18` |
| `TOTAL_SUPPLY()` | Same value as a constant |
| `balanceOf(address)` | |
| `transfer(address,uint256)` | Returns `true`; reverts on insufficient balance |
| `approve(address,uint256)` / `allowance(address,address)` | |
| `transferFrom(address,address,uint256)` | Reverts with `ERC20InsufficientAllowance` or `ERC20InsufficientBalance` |

Events: `Transfer(address indexed from, address indexed to, uint256 value)`,
`Approval(address indexed owner, address indexed spender, uint256 value)`.

Errors (ERC-6093): `ERC20InsufficientBalance`, `ERC20InsufficientAllowance`, `ERC20InvalidSender`,
`ERC20InvalidReceiver`, `ERC20InvalidApprover`, `ERC20InvalidSpender`.

Constructor: no arguments.

## GradientNFT

Constructor: `(address token_)`, the GRAD address. The manifest supplies it as `"$token"`.

### Project functions

| Function | Mutability | Description |
| --- | --- | --- |
| `mint(uint256 quantity)` | nonpayable | Mint 1 to 10 tokens to the caller, burning `PRICE * quantity` GRAD from the caller via `transferFrom`. Requires prior `approve` on GRAD. |
| `totalMinted()` | view | Tokens minted so far (ids `1..totalMinted()` exist). |
| `burnedTotal()` | view | `PRICE * totalMinted()`; GRAD sent to the burn address through this contract. |
| `token()` | view | The GRAD token address. |
| `MAX_SUPPLY()` | pure | `1000` |
| `PRICE()` | pure | `10_000e18` |
| `MAX_PER_MINT()` | pure | `10` |
| `BURN_ADDRESS()` | pure | `0x000000000000000000000000000000000000dEaD` |
| `artOf(uint256 id)` | pure | `(uint24 colourA, uint24 colourB, uint16 angle)` for any id. |
| `svgOf(uint256 id)` | pure | The raw 512x512 SVG string for any id. |
| `tokenURI(uint256 id)` | view | `data:application/json;base64,...` for minted ids; reverts `ERC721NonexistentToken` otherwise. |

### ERC-721 surface (OpenZeppelin 5.1.0)

`name()` (`"Gradients"`), `symbol()` (`"GRADIENT"`), `balanceOf`, `ownerOf`, `approve`, `getApproved`,
`setApprovalForAll`, `isApprovedForAll`, `transferFrom`, `safeTransferFrom` (two overloads),
`supportsInterface` (ERC-165, ERC-721, ERC-721 Metadata).

### Events

| Event | Description |
| --- | --- |
| `Minted(address indexed minter, uint256 firstId, uint256 quantity)` | Once per successful `mint`; the call minted ids `firstId .. firstId + quantity - 1`. |
| `Transfer(address indexed from, address indexed to, uint256 indexed tokenId)` | Standard ERC-721; `from == 0` on mint. |
| `Approval` / `ApprovalForAll` | Standard ERC-721. |

### Errors

| Error | When |
| --- | --- |
| `InvalidQuantity(uint256 quantity)` | `quantity == 0` or `quantity > 10` |
| `ExceedsMaxSupply(uint256 requested, uint256 remaining)` | The mint would pass 1,000 tokens |
| `ZeroTokenAddress()` | Constructor given `address(0)` |
| `ERC721NonexistentToken(uint256)` | `tokenURI`, `ownerOf`, etc. on an unminted id |
| `ERC721InvalidReceiver(address)` | A contract minter without a valid `onERC721Received` (a receiver's own revert reason is bubbled instead when it supplies one) |
| `ERC20InsufficientAllowance` / `ERC20InsufficientBalance` | Bubbled from GRAD when the minter has not approved or funded the payment |
| `SafeERC20FailedOperation(address)` | Only if the token returned `false` or no data; cannot occur with the delivered GRAD |

### Frontend notes

- Cost of a mint in GRAD is `PRICE() * quantity`; remaining supply is `MAX_SUPPLY() - totalMinted()`.
- Show the user's GRAD `balanceOf` and `allowance(user, GradientNFT)` and require an `approve` for at least
  the cost before calling `mint`.
- Build the gallery from `totalMinted()` and `tokenURI(id)` for `id` in `1..totalMinted()`; owner lists come
  from `ownerOf` or from `Transfer` logs queried in chunks from the deployment block.
