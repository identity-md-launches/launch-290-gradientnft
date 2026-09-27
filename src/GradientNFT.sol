// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Gradients (GRADIENT)
/// @notice An on-chain generative ERC-721 of at most 1,000 linear gradients, paid for in GRAD.
///
///         - Each token costs exactly 10,000 GRAD. The payment is one `safeTransferFrom` straight
///           from the minter to the dead address (a burn). This contract never holds GRAD.
///         - Token ids run from 1 to 1,000 in mint order. A mint that would pass 1,000 reverts whole.
///         - The art is a pure function of the id (keccak256 of the id), so the mint order alone
///           decides which gradient a minter receives. No block data is involved.
///         - There is no owner, admin, withdraw, pause, upgrade, payable function, receive or
///           fallback. The contract never holds ETH or GRAD, so there is nothing to withdraw.
///
/// @dev Checks-effects-interactions: the minted counter is advanced and the GRAD payment is taken
///      before any `_safeMint`, so a re-entrant `onERC721Received` sees the updated counter and
///      can only mint by paying again and by staying under the cap.
contract GradientNFT is ERC721 {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /// @notice Maximum number of tokens that can ever exist (ids 1..MAX_SUPPLY).
    uint256 public constant MAX_SUPPLY = 1_000;

    /// @notice Price of one token in GRAD minor units (10,000 GRAD at 18 decimals).
    uint256 public constant PRICE = 10_000e18;

    /// @notice Largest quantity accepted by a single `mint` call.
    uint256 public constant MAX_PER_MINT = 10;

    /// @notice Where every GRAD payment is sent. Nobody holds this key; the payment is a burn.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice The GRAD token used as the working currency.
    IERC20 public immutable token;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    uint256 private _minted;

    // ------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------

    /// @notice Emitted once per successful `mint` call, in addition to the ERC-721 `Transfer` events.
    /// @param minter The account that paid and received the tokens.
    /// @param firstId The first id minted by this call; the call minted `firstId .. firstId + quantity - 1`.
    /// @param quantity How many tokens the call minted.
    event Minted(address indexed minter, uint256 firstId, uint256 quantity);

    /// @notice `quantity` was 0 or above `MAX_PER_MINT`.
    error InvalidQuantity(uint256 quantity);

    /// @notice Minting `requested` tokens would exceed `MAX_SUPPLY`; only `remaining` are left.
    error ExceedsMaxSupply(uint256 requested, uint256 remaining);

    /// @notice The constructor was given the zero address as the GRAD token.
    error ZeroTokenAddress();

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @param token_ Address of the GRAD ERC-20 (supplied by the launch manifest as `$token`).
    constructor(address token_) ERC721("Gradients", "GRADIENT") {
        if (token_ == address(0)) revert ZeroTokenAddress();
        token = IERC20(token_);
    }

    // ------------------------------------------------------------------
    // Minting
    // ------------------------------------------------------------------

    /// @notice Mint `quantity` gradients to the caller, burning `PRICE * quantity` GRAD from the caller.
    /// @dev The caller must have approved this contract for at least `PRICE * quantity` GRAD.
    ///      Reverts whole if `quantity` is outside 1..MAX_PER_MINT or if the cap would be exceeded.
    /// @param quantity Number of tokens to mint, between 1 and `MAX_PER_MINT` inclusive.
    function mint(uint256 quantity) external {
        if (quantity == 0 || quantity > MAX_PER_MINT) revert InvalidQuantity(quantity);

        uint256 minted = _minted;
        uint256 remaining = MAX_SUPPLY - minted;
        if (quantity > remaining) revert ExceedsMaxSupply(quantity, remaining);

        // Effects: reserve the id range before any external call.
        uint256 firstId = minted + 1;
        _minted = minted + quantity;

        // Interaction 1: take the whole payment straight from the minter to the burn address.
        // quantity <= MAX_PER_MINT, so PRICE * quantity cannot overflow.
        token.safeTransferFrom(msg.sender, BURN_ADDRESS, PRICE * quantity);

        emit Minted(msg.sender, firstId, quantity);

        // Interaction 2: hand out the reserved ids. A re-entrant receiver sees the updated counter.
        for (uint256 i = 0; i < quantity; ++i) {
            _safeMint(msg.sender, firstId + i);
        }
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Number of tokens minted so far. Tokens are never burned, so this is also the supply.
    function totalMinted() external view returns (uint256) {
        return _minted;
    }

    /// @notice Total GRAD (minor units) sent to the burn address through this contract.
    function burnedTotal() external view returns (uint256) {
        return PRICE * _minted;
    }

    /// @notice The gradient parameters for an id: two 24-bit RGB colours and an angle in degrees.
    /// @dev Pure function of the id; defined for every id, but only ids 1..MAX_SUPPLY can exist.
    ///      h = keccak256(abi.encodePacked(id)); colourA = h[0..2], colourB = h[3..5],
    ///      angle = uint16(h[6..7]) % 360.
    function artOf(uint256 id) public pure returns (uint24 colourA, uint24 colourB, uint16 angle) {
        uint256 h = uint256(keccak256(abi.encodePacked(id)));
        // Each value is masked to fewer bits than its target type before the cast, so nothing truncates.
        // forge-lint: disable-next-line(unsafe-typecast)
        colourA = uint24((h >> 232) & 0xFFFFFF);
        // forge-lint: disable-next-line(unsafe-typecast)
        colourB = uint24((h >> 208) & 0xFFFFFF);
        // forge-lint: disable-next-line(unsafe-typecast)
        angle = uint16(((h >> 192) & 0xFFFF) % 360);
    }

    /// @notice The raw 512x512 SVG for an id (not base64-encoded). Pure function of the id.
    function svgOf(uint256 id) public pure returns (string memory) {
        (uint24 a, uint24 b, uint16 angle) = artOf(id);
        string memory hexA = _hex6(a);
        string memory hexB = _hex6(b);
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">',
            '<defs><linearGradient id="g" gradientTransform="rotate(',
            uint256(angle).toString(),
            ' 0.5 0.5)"><stop offset="0" stop-color="#',
            hexA,
            '"/><stop offset="1" stop-color="#',
            hexB,
            '"/></linearGradient></defs><rect width="512" height="512" fill="url(#g)"/></svg>'
        );
    }

    /// @inheritdoc ERC721
    /// @dev Reverts with `ERC721NonexistentToken` for ids that have not been minted. Everything
    ///      interpolated into the JSON and SVG is either a decimal number or lowercase hex digits.
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);

        (uint24 a, uint24 b, uint16 angle) = artOf(id);
        string memory hexA = _hex6(a);
        string memory hexB = _hex6(b);
        string memory idStr = id.toString();

        string memory json = string.concat(
            '{"name":"Gradient #',
            idStr,
            '","description":"A 512x512 linear gradient generated on-chain from its token id.",',
            '"attributes":[{"trait_type":"Colour A","value":"#',
            hexA,
            '"},{"trait_type":"Colour B","value":"#',
            hexB,
            '"},{"trait_type":"Angle","value":',
            uint256(angle).toString(),
            '}],"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svgOf(id))),
            '"}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    /// @dev Six lowercase hex digits for a 24-bit value, without a prefix.
    function _hex6(uint24 value) private pure returns (string memory) {
        bytes16 alphabet = "0123456789abcdef";
        bytes memory out = new bytes(6);
        for (uint256 i = 0; i < 6; ++i) {
            out[5 - i] = alphabet[value & 0xF];
            value >>= 4;
        }
        return string(out);
    }
}
