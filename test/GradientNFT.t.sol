// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {GradientNFT} from "../src/GradientNFT.sol";
import {Base64Decoder} from "./utils/Base64Decoder.sol";
import {ReentrantMinter, RejectingReceiver, NonReceiver} from "./utils/Receivers.sol";

contract GradientNFTTest is Test {
    using Base64Decoder for string;

    uint256 internal constant PRICE = 10_000e18;
    uint256 internal constant MAX_SUPPLY = 1_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    string internal constant JSON_PREFIX = "data:application/json;base64,";
    string internal constant SVG_PREFIX = "data:image/svg+xml;base64,";

    LaunchToken internal token;
    GradientNFT internal nft;

    address internal treasury = makeAddr("treasury"); // holds the launch supply in tests
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.prank(treasury);
        token = new LaunchToken();
        nft = new GradientNFT(address(token));

        _fund(alice, PRICE * 200);
        _fund(bob, PRICE * 200);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _fund(address who, uint256 amount) internal {
        vm.prank(treasury);
        token.transfer(who, amount);
    }

    /// @dev Mint `quantity` as `who`, approving exactly the price first.
    function _mintAs(address who, uint256 quantity) internal {
        vm.startPrank(who);
        token.approve(address(nft), PRICE * quantity);
        nft.mint(quantity);
        vm.stopPrank();
    }

    /// @dev Bring the minted counter to `target` using a fresh, well-funded minter.
    function _mintUpTo(uint256 target) internal {
        address filler = makeAddr("filler");
        uint256 current = nft.totalMinted();
        require(target >= current && target <= MAX_SUPPLY, "bad target");
        _fund(filler, PRICE * (target - current));
        vm.startPrank(filler);
        token.approve(address(nft), type(uint256).max);
        while (current < target) {
            uint256 q = target - current > 10 ? 10 : target - current;
            nft.mint(q);
            current += q;
        }
        vm.stopPrank();
    }

    function _assertHoldsNothing() internal view {
        assertEq(token.balanceOf(address(nft)), 0, "contract must hold no GRAD");
        assertEq(address(nft).balance, 0, "contract must hold no ETH");
    }

    /// @dev Independent reference implementation of the art derivation, by byte indexing.
    function _refArt(uint256 id) internal pure returns (uint24 a, uint24 b, uint16 angle) {
        bytes32 h = keccak256(abi.encodePacked(id));
        a = (uint24(uint8(h[0])) << 16) | (uint24(uint8(h[1])) << 8) | uint24(uint8(h[2]));
        b = (uint24(uint8(h[3])) << 16) | (uint24(uint8(h[4])) << 8) | uint24(uint8(h[5]));
        angle = uint16(((uint16(uint8(h[6])) << 8) | uint16(uint8(h[7]))) % 360);
    }

    function _hex6(uint24 v) internal pure returns (string memory) {
        bytes16 alphabet = "0123456789abcdef";
        bytes memory out = new bytes(6);
        for (uint256 i = 0; i < 6; ++i) {
            out[5 - i] = alphabet[v & 0xF];
            v >>= 4;
        }
        return string(out);
    }

    // ------------------------------------------------------------------
    // Construction and constants
    // ------------------------------------------------------------------

    function test_constructorStoresTokenAndMetadata() public view {
        assertEq(address(nft.token()), address(token));
        assertEq(nft.name(), "Gradients");
        assertEq(nft.symbol(), "GRADIENT");
        assertEq(nft.MAX_SUPPLY(), MAX_SUPPLY);
        assertEq(nft.PRICE(), PRICE);
        assertEq(nft.MAX_PER_MINT(), 10);
        assertEq(nft.BURN_ADDRESS(), DEAD);
        assertEq(nft.totalMinted(), 0);
        assertEq(nft.burnedTotal(), 0);
        _assertHoldsNothing();
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(GradientNFT.ZeroTokenAddress.selector);
        new GradientNFT(address(0));
    }

    function test_constructorNeedsNoTokenBalance() public {
        // Deploy from an address that holds no GRAD at all; the constructor must not need any.
        address deployer = makeAddr("factory");
        vm.prank(deployer);
        GradientNFT fresh = new GradientNFT(address(token));
        assertEq(token.balanceOf(address(fresh)), 0);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_noPayableEntryPoints() public {
        vm.deal(alice, 2 ether);
        vm.startPrank(alice);
        (bool ok,) = address(nft).call{value: 1 ether}("");
        assertFalse(ok, "receive/fallback must not exist");
        (ok,) = address(nft).call{value: 1 ether}(abi.encodeWithSignature("mint(uint256)", 1));
        assertFalse(ok, "mint must not be payable");
        (ok,) = address(nft).call{value: 1 ether}(abi.encodeWithSignature("nothingHere()"));
        assertFalse(ok, "unknown selector must revert");
        vm.stopPrank();
        assertEq(address(nft).balance, 0);
    }

    function test_noOwnerOrAdminSelectors() public {
        string[6] memory signatures = [
            "owner()",
            "withdraw()",
            "withdraw(address,uint256)",
            "pause()",
            "setPrice(uint256)",
            "transferOwnership(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(nft).call(abi.encodeWithSignature(signatures[i], alice, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
    }

    // ------------------------------------------------------------------
    // Successful minting
    // ------------------------------------------------------------------

    function test_mintOneBurnsExactPriceAndAssignsIdOne() public {
        uint256 aliceBefore = token.balanceOf(alice);

        vm.startPrank(alice);
        token.approve(address(nft), PRICE);

        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(alice, DEAD, PRICE);
        vm.expectEmit(true, true, true, true, address(nft));
        emit GradientNFT.Minted(alice, 1, 1);
        vm.expectEmit(true, true, true, true, address(nft));
        emit IERC721.Transfer(address(0), alice, 1);
        nft.mint(1);
        vm.stopPrank();

        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.totalMinted(), 1);
        assertEq(nft.burnedTotal(), PRICE);
        assertEq(token.balanceOf(DEAD), PRICE, "dead address gains exactly the price");
        assertEq(token.balanceOf(alice), aliceBefore - PRICE);
        assertEq(token.allowance(alice, address(nft)), 0, "allowance consumed exactly");
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY(), "burn to dead does not change supply");
        _assertHoldsNothing();
    }

    function test_mintTenAssignsSequentialIds() public {
        vm.startPrank(alice);
        token.approve(address(nft), PRICE * 10);
        vm.expectEmit(true, true, true, true, address(nft));
        emit GradientNFT.Minted(alice, 1, 10);
        nft.mint(10);
        vm.stopPrank();

        for (uint256 id = 1; id <= 10; ++id) {
            assertEq(nft.ownerOf(id), alice);
        }
        assertEq(nft.balanceOf(alice), 10);
        assertEq(nft.totalMinted(), 10);
        assertEq(token.balanceOf(DEAD), PRICE * 10);
        _assertHoldsNothing();
    }

    function test_consecutiveMintersGetConsecutiveRanges() public {
        _mintAs(alice, 3);
        vm.startPrank(bob);
        token.approve(address(nft), PRICE * 4);
        vm.expectEmit(true, true, true, true, address(nft));
        emit GradientNFT.Minted(bob, 4, 4);
        nft.mint(4);
        vm.stopPrank();
        _mintAs(alice, 2);

        assertEq(nft.ownerOf(3), alice);
        assertEq(nft.ownerOf(4), bob);
        assertEq(nft.ownerOf(7), bob);
        assertEq(nft.ownerOf(8), alice);
        assertEq(nft.ownerOf(9), alice);
        assertEq(nft.totalMinted(), 9);
        assertEq(nft.burnedTotal(), PRICE * 9);
        assertEq(token.balanceOf(DEAD), PRICE * 9);
        _assertHoldsNothing();
    }

    function testFuzz_mintValidQuantity(uint256 quantity) public {
        quantity = bound(quantity, 1, 10);
        uint256 before = token.balanceOf(alice);
        _mintAs(alice, quantity);
        assertEq(nft.totalMinted(), quantity);
        assertEq(nft.balanceOf(alice), quantity);
        assertEq(token.balanceOf(DEAD), PRICE * quantity);
        assertEq(token.balanceOf(alice), before - PRICE * quantity);
        assertEq(nft.burnedTotal(), token.balanceOf(DEAD));
        _assertHoldsNothing();
    }

    // ------------------------------------------------------------------
    // Quantity validation
    // ------------------------------------------------------------------

    function test_mintZeroReverts() public {
        vm.startPrank(alice);
        token.approve(address(nft), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(GradientNFT.InvalidQuantity.selector, 0));
        nft.mint(0);
        vm.stopPrank();
        assertEq(nft.totalMinted(), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_mintElevenReverts() public {
        vm.startPrank(alice);
        token.approve(address(nft), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(GradientNFT.InvalidQuantity.selector, 11));
        nft.mint(11);
        vm.stopPrank();
        assertEq(nft.totalMinted(), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function testFuzz_mintAboveTenReverts(uint256 quantity) public {
        quantity = bound(quantity, 11, type(uint256).max);
        vm.startPrank(alice);
        token.approve(address(nft), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(GradientNFT.InvalidQuantity.selector, quantity));
        nft.mint(quantity);
        vm.stopPrank();
    }

    /// @dev A quantity large enough to overflow PRICE * quantity is rejected by the range check,
    ///      not by arithmetic, so it can never be used to pay less than the price.
    function test_hugeQuantityCannotOverflowPrice() public {
        uint256 overflowing = type(uint256).max / PRICE + 1;
        vm.startPrank(alice);
        token.approve(address(nft), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(GradientNFT.InvalidQuantity.selector, overflowing));
        nft.mint(overflowing);
        vm.expectRevert(abi.encodeWithSelector(GradientNFT.InvalidQuantity.selector, type(uint256).max));
        nft.mint(type(uint256).max);
        vm.stopPrank();
        assertEq(nft.totalMinted(), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    // ------------------------------------------------------------------
    // Supply cap
    // ------------------------------------------------------------------

    function test_mintTenAt995Reverts() public {
        _mintUpTo(995);
        vm.startPrank(alice);
        token.approve(address(nft), PRICE * 10);
        vm.expectRevert(abi.encodeWithSelector(GradientNFT.ExceedsMaxSupply.selector, 10, 5));
        nft.mint(10);
        vm.stopPrank();
        assertEq(nft.totalMinted(), 995, "no partial mint");
        assertEq(nft.balanceOf(alice), 0, "no partial mint");
        assertEq(token.balanceOf(DEAD), PRICE * 995, "no payment taken on revert");
        assertEq(token.balanceOf(alice), PRICE * 200, "minter keeps funds on revert");
    }

    function test_mintExactlyToCapThenOneMoreReverts() public {
        _mintUpTo(995);
        _mintAs(alice, 5);
        assertEq(nft.totalMinted(), MAX_SUPPLY);
        assertEq(nft.ownerOf(1000), alice);
        assertEq(token.balanceOf(DEAD), PRICE * MAX_SUPPLY);
        assertEq(nft.burnedTotal(), PRICE * MAX_SUPPLY);

        vm.startPrank(bob);
        token.approve(address(nft), PRICE * 10);
        vm.expectRevert(abi.encodeWithSelector(GradientNFT.ExceedsMaxSupply.selector, 1, 0));
        nft.mint(1);
        vm.expectRevert(abi.encodeWithSelector(GradientNFT.ExceedsMaxSupply.selector, 10, 0));
        nft.mint(10);
        vm.stopPrank();

        assertEq(nft.totalMinted(), MAX_SUPPLY);
        assertEq(token.balanceOf(DEAD), PRICE * MAX_SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1001));
        nft.ownerOf(1001);
        _assertHoldsNothing();
    }

    function test_everyIdOneToThousandIsOwnedAfterSellout() public {
        _mintUpTo(MAX_SUPPLY);
        for (uint256 id = 1; id <= MAX_SUPPLY; ++id) {
            assertEq(nft.ownerOf(id), makeAddr("filler"));
        }
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        nft.ownerOf(0);
    }

    // ------------------------------------------------------------------
    // Payment failures
    // ------------------------------------------------------------------

    function test_missingAllowanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(nft), 0, PRICE)
        );
        nft.mint(1);
        assertEq(nft.totalMinted(), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_insufficientAllowanceForQuantityReverts() public {
        vm.startPrank(alice);
        token.approve(address(nft), PRICE * 2);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(nft), PRICE * 2, PRICE * 3)
        );
        nft.mint(3);
        vm.stopPrank();
        assertEq(nft.totalMinted(), 0);
    }

    function test_insufficientBalanceReverts() public {
        address poor = makeAddr("poor");
        _fund(poor, PRICE - 1);
        vm.startPrank(poor);
        token.approve(address(nft), PRICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, PRICE - 1, PRICE));
        nft.mint(1);
        vm.stopPrank();
        assertEq(nft.totalMinted(), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    // ------------------------------------------------------------------
    // Safe-mint receivers and re-entrancy
    // ------------------------------------------------------------------

    function test_rejectingReceiverRollsBackWholeMint() public {
        RejectingReceiver r = new RejectingReceiver(nft, token);
        _fund(address(r), PRICE * 10);
        r.approve(PRICE * 10);

        // OpenZeppelin bubbles the receiver's own revert reason when it supplies one.
        vm.expectRevert("no thanks");
        r.mint(3);

        assertEq(nft.totalMinted(), 0, "counter rolled back");
        assertEq(token.balanceOf(DEAD), 0, "payment rolled back");
        assertEq(token.balanceOf(address(r)), PRICE * 10);
    }

    function test_nonReceiverContractCannotMint() public {
        NonReceiver r = new NonReceiver(nft, token);
        _fund(address(r), PRICE);
        r.approve(PRICE);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)));
        r.mint(1);
        assertEq(nft.totalMinted(), 0);
    }

    function test_reentrantReceiverCannotExceedCap() public {
        _mintUpTo(990);
        ReentrantMinter r = new ReentrantMinter(nft, token);
        _fund(address(r), PRICE * 50);
        r.approve(type(uint256).max);

        r.mint(10, 1); // re-enters with mint(1) from the first onERC721Received

        assertTrue(r.reentered(), "callback must have re-entered");
        assertFalse(r.reentrySucceeded(), "re-entrant mint must fail at the cap");
        assertEq(r.reentryError(), abi.encodeWithSelector(GradientNFT.ExceedsMaxSupply.selector, 1, 0));
        assertEq(r.callbacks(), 10);
        assertEq(nft.totalMinted(), MAX_SUPPLY);
        assertEq(nft.balanceOf(address(r)), 10);
        assertEq(token.balanceOf(DEAD), PRICE * MAX_SUPPLY, "exactly the cap was paid for");
        assertEq(token.balanceOf(address(r)), PRICE * 40);
        _assertHoldsNothing();
    }

    function test_reentrantReceiverCannotMintUnpaid() public {
        ReentrantMinter r = new ReentrantMinter(nft, token);
        _fund(address(r), PRICE * 2); // exactly enough for the outer mint of 2, nothing more
        r.approve(type(uint256).max);

        r.mint(2, 1);

        assertTrue(r.reentered());
        assertFalse(r.reentrySucceeded(), "re-entrant mint must fail without payment");
        assertEq(
            r.reentryError(),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(r), 0, PRICE)
        );
        assertEq(nft.totalMinted(), 2);
        assertEq(nft.balanceOf(address(r)), 2);
        assertEq(token.balanceOf(DEAD), PRICE * 2);
        assertEq(token.balanceOf(address(r)), 0);
        _assertHoldsNothing();
    }

    function test_reentrantReceiverWithAllowanceOnlyForOuterCallCannotMintMore() public {
        ReentrantMinter r = new ReentrantMinter(nft, token);
        _fund(address(r), PRICE * 100);
        r.approve(PRICE * 3); // allowance covers only the outer mint of 3

        r.mint(3, 2);

        assertTrue(r.reentered());
        assertFalse(r.reentrySucceeded());
        assertEq(
            r.reentryError(),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(nft), 0, PRICE * 2)
        );
        assertEq(nft.totalMinted(), 3);
        assertEq(token.balanceOf(DEAD), PRICE * 3);
    }

    /// @dev A funded re-entrant receiver may mint again, but it pays in full and its ids come after
    ///      the whole outer batch, so the counter and the burn stay consistent.
    function test_fundedReentrantMintPaysAndGetsIdsAfterOuterBatch() public {
        ReentrantMinter r = new ReentrantMinter(nft, token);
        _fund(address(r), PRICE * 20);
        r.approve(type(uint256).max);

        vm.expectEmit(true, true, true, true, address(nft));
        emit GradientNFT.Minted(address(r), 1, 4);
        vm.expectEmit(true, true, true, true, address(nft));
        emit GradientNFT.Minted(address(r), 5, 2);
        r.mint(4, 2);

        assertTrue(r.reentrySucceeded());
        assertEq(nft.totalMinted(), 6);
        assertEq(nft.balanceOf(address(r)), 6);
        assertEq(r.callbacks(), 6);
        for (uint256 id = 1; id <= 6; ++id) {
            assertEq(nft.ownerOf(id), address(r));
        }
        assertEq(token.balanceOf(DEAD), PRICE * 6, "every token paid for");
        assertEq(token.balanceOf(address(r)), PRICE * 14);
        assertEq(nft.burnedTotal(), PRICE * 6);
        _assertHoldsNothing();
    }

    // ------------------------------------------------------------------
    // Accounting invariants over a mixed sequence
    // ------------------------------------------------------------------

    function test_burnedTotalTracksDeadBalanceAcrossMixedSequence() public {
        _mintAs(alice, 7);
        _mintAs(bob, 1);
        vm.prank(alice);
        vm.expectRevert();
        nft.mint(5); // no allowance: fails, changes nothing
        _mintAs(bob, 10);
        _mintAs(alice, 2);

        assertEq(nft.totalMinted(), 20);
        assertEq(nft.burnedTotal(), PRICE * 20);
        assertEq(token.balanceOf(DEAD), PRICE * 20);
        assertEq(nft.balanceOf(alice) + nft.balanceOf(bob), 20);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(DEAD), PRICE * 400);
        _assertHoldsNothing();
    }

    function test_transfersDoNotAffectCounters() public {
        _mintAs(alice, 2);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.totalMinted(), 2);
        assertEq(nft.burnedTotal(), PRICE * 2);
    }

    // ------------------------------------------------------------------
    // tokenURI and art
    // ------------------------------------------------------------------

    function test_tokenURIRevertsForUnmintedIds() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        nft.tokenURI(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        nft.tokenURI(0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1000));
        nft.tokenURI(1000);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1001));
        nft.tokenURI(1001);

        _mintAs(alice, 3);
        nft.tokenURI(3); // now exists
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 4));
        nft.tokenURI(4);
    }

    function test_tokenURIDecodesToJsonContainingSvg() public {
        _mintAs(alice, 1);
        string memory uri = nft.tokenURI(1);

        string memory json = string(uri.stripPrefix(JSON_PREFIX).decode());
        assertEq(vm.parseJsonString(json, ".name"), "Gradient #1");
        assertEq(vm.parseJsonString(json, ".attributes[0].trait_type"), "Colour A");
        assertEq(vm.parseJsonString(json, ".attributes[1].trait_type"), "Colour B");
        assertEq(vm.parseJsonString(json, ".attributes[2].trait_type"), "Angle");

        (uint24 a, uint24 b, uint16 angle) = _refArt(1);
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), string.concat("#", _hex6(a)));
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), string.concat("#", _hex6(b)));
        assertEq(vm.parseJsonUint(json, ".attributes[2].value"), angle);

        string memory image = vm.parseJsonString(json, ".image");
        string memory svg = string(image.stripPrefix(SVG_PREFIX).decode());
        assertTrue(svg.contains('<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512"'), "svg header");
        assertTrue(svg.contains("<linearGradient"), "one linearGradient");
        assertTrue(svg.contains(string.concat('stop-color="#', _hex6(a), '"')), "colour A in svg");
        assertTrue(svg.contains(string.concat('stop-color="#', _hex6(b), '"')), "colour B in svg");
        assertTrue(svg.contains(string.concat("rotate(", vm.toString(uint256(angle)), " 0.5 0.5)")), "angle in svg");
        assertTrue(svg.contains("</svg>"), "svg closes");
        assertEq(svg, nft.svgOf(1), "image is exactly svgOf(id)");
    }

    function test_tokenURIIsByteIdenticalAcrossCalls() public {
        _mintAs(alice, 2);
        string memory first = nft.tokenURI(2);
        string memory second = nft.tokenURI(2);
        assertEq(keccak256(bytes(first)), keccak256(bytes(second)));

        // Unchanged by unrelated state: more mints, transfers, other blocks.
        _mintAs(bob, 5);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 2);
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 1 days);
        string memory third = nft.tokenURI(2);
        assertEq(keccak256(bytes(first)), keccak256(bytes(third)));
    }

    function test_tokenURIMatchesReferenceEncoding() public {
        _mintAs(alice, 1);
        (uint24 a, uint24 b, uint16 angle) = _refArt(1);
        string memory expectedSvg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">',
            '<defs><linearGradient id="g" gradientTransform="rotate(',
            vm.toString(uint256(angle)),
            ' 0.5 0.5)"><stop offset="0" stop-color="#',
            _hex6(a),
            '"/><stop offset="1" stop-color="#',
            _hex6(b),
            '"/></linearGradient></defs><rect width="512" height="512" fill="url(#g)"/></svg>'
        );
        string memory expectedJson = string.concat(
            '{"name":"Gradient #1","description":"A 512x512 linear gradient generated on-chain from its token id.",',
            '"attributes":[{"trait_type":"Colour A","value":"#',
            _hex6(a),
            '"},{"trait_type":"Colour B","value":"#',
            _hex6(b),
            '"},{"trait_type":"Angle","value":',
            vm.toString(uint256(angle)),
            '}],"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(expectedSvg)),
            '"}'
        );
        string memory expected = string.concat(JSON_PREFIX, Base64.encode(bytes(expectedJson)));
        assertEq(nft.tokenURI(1), expected);
    }

    function testFuzz_artOfMatchesByteIndexedReference(uint256 id) public view {
        (uint24 a, uint24 b, uint16 angle) = nft.artOf(id);
        (uint24 ra, uint24 rb, uint16 rangle) = _refArt(id);
        assertEq(a, ra);
        assertEq(b, rb);
        assertEq(angle, rangle);
        assertLt(angle, 360);
    }

    /// @dev Only decimal digits and lowercase hex digits are interpolated: the output alphabet is fixed.
    function testFuzz_svgContainsOnlySafeCharacters(uint256 id) public view {
        id = bound(id, 1, MAX_SUPPLY);
        bytes memory svg = bytes(nft.svgOf(id));
        for (uint256 i = 0; i < svg.length; ++i) {
            uint8 c = uint8(svg[i]);
            bool ok = (c >= 0x20 && c <= 0x7E); // printable ASCII only
            assertTrue(ok, "non-printable byte in svg");
            assertTrue(c != 0x3C || svg[i + 1] != 0x21, "no <! constructs"); // no <!ENTITY / <!DOCTYPE
        }
    }

    function testFuzz_tokenURIForEveryMintedIdDecodes(uint256 id) public {
        id = bound(id, 1, 30);
        _mintUpTo(30);
        string memory json = string(nft.tokenURI(id).stripPrefix(JSON_PREFIX).decode());
        assertEq(vm.parseJsonString(json, ".name"), string.concat("Gradient #", vm.toString(id)));
        string memory svg = string(vm.parseJsonString(json, ".image").stripPrefix(SVG_PREFIX).decode());
        assertEq(svg, nft.svgOf(id));
    }

    function test_artIsAPureFunctionOfIdNotMinter() public {
        // Two different deployments and minters yield identical art for the same id.
        GradientNFT other = new GradientNFT(address(token));
        _mintAs(alice, 1);
        vm.startPrank(bob);
        token.approve(address(other), PRICE);
        other.mint(1);
        vm.stopPrank();
        assertEq(nft.tokenURI(1), other.tokenURI(1));
    }
}
