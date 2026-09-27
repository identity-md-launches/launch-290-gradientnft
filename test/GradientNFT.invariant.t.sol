// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {GradientNFT} from "../src/GradientNFT.sol";
import {ObservedReentrantMinter} from "./utils/ObservedReentrantMinter.sol";

/// @dev Drives GradientNFT with a handful of funded actors performing valid and invalid mints,
///      transfers and stray ETH sends, tracking what should have been burned.
contract MintHandler is Test {
    uint256 internal constant PRICE = 10_000e18;

    LaunchToken public immutable token;
    GradientNFT public immutable nft;
    ObservedReentrantMinter public immutable receiver;
    address[] public actors;

    uint256 public ghostBurned;
    uint256 public ghostMinted;
    uint256 public successfulMints;
    uint256 public failedMints;
    // Sticky evidence survives handler returns even with Foundry's fail_on_revert = false.
    bool public unexpectedBehavior;
    mapping(uint256 => address) public expectedOwner;

    constructor(LaunchToken token_, GradientNFT nft_) {
        token = token_;
        nft = nft_;
        receiver = new ObservedReentrantMinter(nft_, token_);
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @dev Model both success and failure: an implementation that always reverts must fail too.
    function mint(uint256 actorSeed, uint256 quantity, bool approveFirst) external {
        address actor = actors[actorSeed % actors.length];
        quantity = bound(quantity, 0, 12);
        uint256 cost = PRICE * quantity;
        uint256 allowance = approveFirst ? cost : 0;
        uint256 balanceBefore = token.balanceOf(actor);
        uint256 nftBalanceBefore = nft.balanceOf(actor);
        uint256 mintedBefore = ghostMinted;

        bytes memory expectedError;
        if (quantity == 0 || quantity > 10) {
            expectedError = abi.encodeWithSelector(GradientNFT.InvalidQuantity.selector, quantity);
        } else if (quantity > 1_000 - mintedBefore) {
            expectedError =
                abi.encodeWithSelector(GradientNFT.ExceedsMaxSupply.selector, quantity, 1_000 - mintedBefore);
        } else if (allowance < cost) {
            expectedError =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(nft), allowance, cost);
        } else if (balanceBefore < cost) {
            expectedError =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, actor, balanceBefore, cost);
        }

        vm.startPrank(actor);
        token.approve(address(nft), allowance);
        try nft.mint(quantity) {
            successfulMints++;
            if (expectedError.length != 0) {
                unexpectedBehavior = true;
            } else {
                ghostMinted += quantity;
                ghostBurned += cost;
                for (uint256 id = mintedBefore + 1; id <= ghostMinted; ++id) {
                    expectedOwner[id] = actor;
                }
                if (
                    token.balanceOf(actor) != balanceBefore - cost
                        || nft.balanceOf(actor) != nftBalanceBefore + quantity
                        || token.allowance(actor, address(nft)) != allowance - cost
                ) unexpectedBehavior = true;
            }
        } catch (bytes memory reason) {
            failedMints++;
            if (
                expectedError.length == 0 || keccak256(reason) != keccak256(expectedError)
                    || token.balanceOf(actor) != balanceBefore || nft.balanceOf(actor) != nftBalanceBefore
                    || token.allowance(actor, address(nft)) != allowance
            ) unexpectedBehavior = true;
        }
        vm.stopPrank();
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 id) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 minted = ghostMinted;
        if (minted == 0) return;
        id = bound(id, 1, minted);
        if (expectedOwner[id] != from) return;
        vm.prank(from);
        try nft.transferFrom(from, to, id) {
            expectedOwner[id] = to;
        } catch {
            unexpectedBehavior = true;
        }
    }

    /// @dev Interleave nested mints with EOA mints and transfers, using a fresh finite allowance.
    function reenter(uint256 outerSeed, uint256 innerSeed, bool approveInner) external {
        uint256 outer = bound(outerSeed, 1, 10);
        uint256 inner = bound(innerSeed, 1, 10);
        uint256 allowance = PRICE * (outer + (approveInner ? inner : 0));
        uint256 funds = token.balanceOf(address(receiver));
        uint256 minted = ghostMinted;
        uint256 owned = nft.balanceOf(address(receiver));
        receiver.approve(allowance);
        bytes memory outerError = _receiverError(outer, minted, allowance, funds);
        try receiver.mint(outer, inner, 0) {
            if (outerError.length != 0) {
                unexpectedBehavior = true;
                return;
            }
            bytes memory innerError =
                _receiverError(inner, minted + outer, allowance - PRICE * outer, funds - PRICE * outer);
            bool innerExpected = innerError.length == 0;
            uint256 added = outer + (innerExpected ? inner : 0);
            ghostMinted += added;
            ghostBurned += PRICE * added;
            successfulMints += innerExpected ? 2 : 1;
            if (!innerExpected) failedMints++;
            for (uint256 id = minted + 1; id <= ghostMinted; ++id) {
                expectedOwner[id] = address(receiver);
            }
            if (
                !receiver.attempted() || receiver.succeeded() != innerExpected
                    || keccak256(receiver.innerError()) != keccak256(innerError)
                    || receiver.callbackAccountingMismatch() || receiver.callbackCount() != added
                    || receiver.firstCallbackSupply() != minted + outer
                    || receiver.firstCallbackBurnGain() != PRICE * (minted + outer)
                    || token.balanceOf(address(receiver)) != funds - PRICE * added
                    || token.allowance(address(receiver), address(nft)) != allowance - PRICE * added
                    || nft.balanceOf(address(receiver)) != owned + added
            ) unexpectedBehavior = true;
        } catch (bytes memory reason) {
            failedMints++;
            if (
                outerError.length == 0 || keccak256(reason) != keccak256(outerError)
                    || token.balanceOf(address(receiver)) != funds
                    || token.allowance(address(receiver), address(nft)) != allowance
                    || nft.balanceOf(address(receiver)) != owned
            ) unexpectedBehavior = true;
        }
    }

    function _receiverError(uint256 quantity, uint256 minted, uint256 allowance, uint256 funds)
        private
        view
        returns (bytes memory)
    {
        if (quantity > 1_000 - minted) {
            return abi.encodeWithSelector(GradientNFT.ExceedsMaxSupply.selector, quantity, 1_000 - minted);
        }
        if (allowance < PRICE * quantity) {
            return abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(nft), allowance, PRICE * quantity
            );
        }
        if (funds < PRICE * quantity) {
            return abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(receiver), funds, PRICE * quantity
            );
        }
        return bytes("");
    }

    function sendEth(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1 ether);
        vm.deal(actor, amount);
        vm.prank(actor);
        (bool ok,) = address(nft).call{value: amount}("");
        if (ok) unexpectedBehavior = true;
    }
}

contract GradientNFTInvariantTest is Test {
    uint256 internal constant PRICE = 10_000e18;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LaunchToken internal token;
    GradientNFT internal nft;
    MintHandler internal handler;
    uint256 internal initialDeadBalance;

    function setUp() public virtual {
        token = new LaunchToken();
        nft = new GradientNFT(address(token));
        token.transfer(DEAD, 17);
        initialDeadBalance = token.balanceOf(DEAD);
        handler = new MintHandler(token, nft);

        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            token.transfer(handler.actors(i), PRICE * 400);
        }
        token.transfer(address(handler.receiver()), PRICE * 400);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = MintHandler.mint.selector;
        selectors[1] = MintHandler.transfer.selector;
        selectors[2] = MintHandler.sendEth.selector;
        selectors[3] = MintHandler.reenter.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_deadBalanceEqualsBurnedTotal() public view {
        assertEq(token.balanceOf(DEAD) - initialDeadBalance, nft.burnedTotal());
        assertEq(nft.burnedTotal(), PRICE * nft.totalMinted());
        assertEq(token.balanceOf(DEAD) - initialDeadBalance, handler.ghostBurned());
        assertEq(nft.totalMinted(), handler.ghostMinted());
    }

    function invariant_capNeverExceeded() public view {
        assertEq(nft.MAX_SUPPLY(), 1_000);
        assertLe(nft.totalMinted(), 1_000);
    }

    /// @dev Covers mint, transfer and ordinary ETH-call sequences. Unsolicited ERC20 transfers
    /// and forced ETH violate the unconditional custody requirement; see the defect report.
    function invariant_mintAndTransferPathsHoldNoValue() public view {
        assertEq(address(nft).balance, 0, "no ETH ever accepted");
        assertEq(token.balanceOf(address(nft)), 0, "no GRAD retained");
    }

    function invariant_callsMatchTheIndependentModel() public view {
        assertFalse(handler.unexpectedBehavior(), "unexpected success, revert or non-atomic failure");
    }

    function invariant_everyMintedIdHasAnOwnerAndSupplyIsConserved() public view {
        uint256 minted = nft.totalMinted();
        uint256 held = nft.balanceOf(address(handler.receiver()));
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            held += nft.balanceOf(handler.actors(i));
        }
        assertEq(held, minted, "every minted token is owned by an actor");
        for (uint256 id = 1; id <= minted; ++id) {
            assertEq(nft.ownerOf(id), handler.expectedOwner(id));
        }
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY(), "GRAD supply is fixed");
    }

    function test_handlerExercisesSuccessfulAndRejectedMints() public {
        handler.mint(0, 2, true);
        handler.mint(1, 1, false);
        handler.mint(2, 0, true);
        handler.mint(3, 11, true);
        handler.reenter(1, 1, true);
        handler.reenter(1, 1, false);
        assertGt(handler.successfulMints(), 0);
        assertGe(handler.failedMints(), 3);
        invariant_callsMatchTheIndependentModel();
        invariant_deadBalanceEqualsBurnedTotal();
        invariant_mintAndTransferPathsHoldNoValue();
        invariant_everyMintedIdHasAnOwnerAndSupplyIsConserved();
    }
}

/// @dev The configured invariant depth is 24: start close to sellout so random sequences exercise
/// partial batches, exact sellout, and repeated calls after the cap without changing configuration.
contract GradientNFTNearCapInvariantTest is GradientNFTInvariantTest {
    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 98; ++i) {
            handler.mint(i, 10, true);
        }
        handler.mint(2, 5, true);
        assertEq(nft.totalMinted(), 985);
        assertFalse(handler.unexpectedBehavior());
    }
}
