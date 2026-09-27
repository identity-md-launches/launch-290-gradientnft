// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {GradientNFT} from "../src/GradientNFT.sol";

/// @dev Drives GradientNFT with a handful of funded actors performing valid and invalid mints,
///      transfers and stray ETH sends, tracking what should have been burned.
contract MintHandler is Test {
    uint256 internal constant PRICE = 10_000e18;

    LaunchToken public immutable token;
    GradientNFT public immutable nft;
    address[] public actors;

    uint256 public ghostBurned;
    uint256 public ghostMinted;
    uint256 public successfulMints;
    uint256 public failedMints;

    constructor(LaunchToken token_, GradientNFT nft_) {
        token = token_;
        nft = nft_;
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @dev Quantity 0..12 covers both invalid edges; allowance is set exactly to the amount due
    ///      only some of the time so missing-allowance failures also occur.
    function mint(uint256 actorSeed, uint256 quantity, bool approveFirst) external {
        address actor = actors[actorSeed % actors.length];
        quantity = bound(quantity, 0, 12);

        vm.startPrank(actor);
        if (approveFirst) token.approve(address(nft), PRICE * quantity);
        try nft.mint(quantity) {
            successfulMints++;
            ghostMinted += quantity;
            ghostBurned += PRICE * quantity;
        } catch {
            failedMints++;
        }
        vm.stopPrank();
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 id) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 minted = nft.totalMinted();
        if (minted == 0) return;
        id = bound(id, 1, minted);
        if (nft.ownerOf(id) != from) return;
        vm.prank(from);
        nft.transferFrom(from, to, id);
    }

    function sendEth(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1 ether);
        vm.deal(actor, amount);
        vm.prank(actor);
        (bool ok,) = address(nft).call{value: amount}("");
        ok; // expected to fail; the invariant checks the balance
    }

    function sendGradDirectly(uint256 actorSeed, uint256 amount) external {
        // A user can always push GRAD to any address, including the NFT contract. This is out of
        // the contract's control, so the handler records that it happened and the invariant below
        // asserts the contract itself never moved GRAD into its own balance.
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(actor) / 10);
        if (amount == 0) return;
        vm.prank(actor);
        token.transfer(address(nft), amount);
        strayGrad += amount;
    }

    uint256 public strayGrad;
}

contract GradientNFTInvariantTest is Test {
    uint256 internal constant PRICE = 10_000e18;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LaunchToken internal token;
    GradientNFT internal nft;
    MintHandler internal handler;

    function setUp() public {
        token = new LaunchToken();
        nft = new GradientNFT(address(token));
        handler = new MintHandler(token, nft);

        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            token.transfer(handler.actors(i), PRICE * 400);
        }

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = MintHandler.mint.selector;
        selectors[1] = MintHandler.transfer.selector;
        selectors[2] = MintHandler.sendEth.selector;
        selectors[3] = MintHandler.sendGradDirectly.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_deadBalanceEqualsBurnedTotal() public view {
        assertEq(token.balanceOf(DEAD), nft.burnedTotal());
        assertEq(nft.burnedTotal(), PRICE * nft.totalMinted());
        assertEq(token.balanceOf(DEAD), handler.ghostBurned());
        assertEq(nft.totalMinted(), handler.ghostMinted());
    }

    function invariant_capNeverExceeded() public view {
        assertLe(nft.totalMinted(), nft.MAX_SUPPLY());
    }

    function invariant_contractNeverAccumulatesValueByItself() public view {
        assertEq(address(nft).balance, 0, "no ETH ever accepted");
        // The only GRAD the contract can hold is what users pushed to it directly, never a payment.
        assertEq(token.balanceOf(address(nft)), handler.strayGrad());
    }

    function invariant_everyMintedIdHasAnOwnerAndSupplyIsConserved() public view {
        uint256 minted = nft.totalMinted();
        uint256 held;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            held += nft.balanceOf(handler.actors(i));
        }
        assertEq(held, minted, "every minted token is owned by an actor");
        if (minted > 0) nft.ownerOf(minted);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY(), "GRAD supply is fixed");
    }
}
