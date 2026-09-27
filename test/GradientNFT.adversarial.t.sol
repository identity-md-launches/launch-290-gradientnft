// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {GradientNFT} from "../src/GradientNFT.sol";
import {ObservedReentrantMinter} from "./utils/ObservedReentrantMinter.sol";

contract GradientNFTAdversarialTest is Test {
    uint256 private constant PRICE = 10_000e18;
    uint256 private constant CAP = 1_000;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant INITIAL_DEAD_BALANCE = 17;

    LaunchToken private token;
    GradientNFT private nft;
    address[4] private actors;

    function setUp() public {
        token = new LaunchToken();
        nft = new GradientNFT(address(token));
        // Check the dead address's *gain*, independently of its pre-existing balance.
        token.transfer(DEAD, INITIAL_DEAD_BALANCE);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("order-actor-", vm.toString(i)));
            token.transfer(actors[i], PRICE * CAP);
        }
    }

    function _assertAccounting(uint256 expectedMinted) private view {
        assertEq(nft.totalMinted(), expectedMinted);
        assertLe(expectedMinted, CAP);
        assertEq(token.balanceOf(DEAD) - INITIAL_DEAD_BALANCE, PRICE * expectedMinted);
        assertEq(nft.burnedTotal(), PRICE * expectedMinted);
        assertEq(token.balanceOf(address(nft)), 0);
        assertEq(address(nft).balance, 0);
    }

    function _mint(address actor, uint256 quantity) private {
        vm.startPrank(actor);
        token.approve(address(nft), PRICE * quantity);
        nft.mint(quantity);
        vm.stopPrank();
    }

    function _fill(uint256 quantity) private {
        while (quantity != 0) {
            uint256 batch = quantity > 10 ? 10 : quantity;
            _mint(actors[3], batch);
            quantity -= batch;
        }
    }

    function _assertMissing(uint256 id) private {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        nft.ownerOf(id);
    }

    function _receiver(uint256 funds, uint256 allowance) private returns (ObservedReentrantMinter receiver) {
        receiver = new ObservedReentrantMinter(nft, token);
        token.transfer(address(receiver), funds);
        receiver.approve(allowance);
    }

    /// @dev Every run varies both batch sizes and the order of callers, and audits every assigned id.
    function testFuzz_quantityAndMintOrder(uint256 seed, uint8 lengthSeed) public {
        uint256 length = bound(lengthSeed, 2, 40);
        uint256 minted;
        uint256[4] memory balances;
        for (uint256 i; i < length; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 actorIndex = seed % actors.length;
            uint256 quantity = (seed >> 8) % 10 + 1;
            address actor = actors[actorIndex];
            uint256 payerBefore = token.balanceOf(actor);

            vm.recordLogs();
            _mint(actor, quantity);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 payments;
            uint256 announcements;
            for (uint256 j; j < logs.length; ++j) {
                if (
                    logs[j].emitter == address(token)
                        && logs[j].topics[0] == keccak256("Transfer(address,address,uint256)")
                ) {
                    ++payments;
                    assertEq(logs[j].topics[1], bytes32(uint256(uint160(actor))));
                    assertEq(logs[j].topics[2], bytes32(uint256(uint160(DEAD))));
                    assertEq(abi.decode(logs[j].data, (uint256)), PRICE * quantity);
                }
                if (
                    logs[j].emitter == address(nft) && logs[j].topics[0] == keccak256("Minted(address,uint256,uint256)")
                ) {
                    ++announcements;
                    assertEq(logs[j].topics[1], bytes32(uint256(uint160(actor))));
                    (uint256 firstId, uint256 count) = abi.decode(logs[j].data, (uint256, uint256));
                    assertEq(firstId, minted + 1);
                    assertEq(count, quantity);
                }
            }
            assertEq(payments, 1, "one direct payment per batch");
            assertEq(announcements, 1, "one Minted event per batch");
            for (uint256 id = minted + 1; id <= minted + quantity; ++id) {
                assertEq(nft.ownerOf(id), actor);
            }
            minted += quantity;
            balances[actorIndex] += quantity;
            assertEq(token.balanceOf(actor), payerBefore - PRICE * quantity);
            assertEq(token.allowance(actor, address(nft)), 0);
            for (uint256 j; j < actors.length; ++j) {
                assertEq(nft.balanceOf(actors[j]), balances[j]);
            }
            _assertAccounting(minted);
        }
        _assertMissing(minted + 1);
    }

    function testFuzz_invalidQuantityIsAtomic(uint256 quantity, uint8 prefixSeed) public {
        // Retain the full uint256 domain: large inputs must hit validation, never arithmetic panics.
        vm.assume(quantity == 0 || quantity > 10);
        uint256 prefix = bound(prefixSeed, 0, 10);
        _fill(prefix);
        uint256 balanceBefore = token.balanceOf(actors[0]);
        vm.startPrank(actors[0]);
        token.approve(address(nft), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(GradientNFT.InvalidQuantity.selector, quantity));
        nft.mint(quantity);
        vm.stopPrank();
        assertEq(token.allowance(actors[0], address(nft)), type(uint256).max);
        assertEq(token.balanceOf(actors[0]), balanceBefore);
        assertEq(nft.balanceOf(actors[0]), 0);
        _assertAccounting(prefix);
        _assertMissing(prefix + 1);
    }

    function testFuzz_allowanceOneUnitShortRollsBack(uint8 quantitySeed, uint8 prefixSeed) public {
        uint256 quantity = bound(quantitySeed, 1, 10);
        uint256 prefix = bound(prefixSeed, 0, 10);
        _fill(prefix);
        uint256 cost = PRICE * quantity;
        uint256 beforeBalance = token.balanceOf(actors[0]);
        vm.startPrank(actors[0]);
        token.approve(address(nft), cost - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(nft), cost - 1, cost)
        );
        nft.mint(quantity);
        vm.stopPrank();
        assertEq(token.allowance(actors[0], address(nft)), cost - 1);
        assertEq(token.balanceOf(actors[0]), beforeBalance);
        _assertAccounting(prefix);
        _assertMissing(prefix + 1);
        // The failed call must not reserve ids or poison the next attempt.
        _mint(actors[0], quantity);
        assertEq(nft.ownerOf(prefix + 1), actors[0]);
        _assertAccounting(prefix + quantity);
    }

    function testFuzz_balanceOneUnitShortRestoresSpentAllowance(uint8 quantitySeed) public {
        uint256 quantity = bound(quantitySeed, 1, 10);
        uint256 cost = PRICE * quantity;
        address poor = makeAddr("one-unit-short");
        token.transfer(poor, cost - 1);
        vm.startPrank(poor);
        token.approve(address(nft), cost);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, cost - 1, cost));
        nft.mint(quantity);
        vm.stopPrank();
        assertEq(token.allowance(poor, address(nft)), cost);
        assertEq(token.balanceOf(poor), cost - 1);
        _assertAccounting(0);
        _assertMissing(1);
        token.transfer(poor, 1);
        vm.prank(poor);
        nft.mint(quantity);
        assertEq(token.allowance(poor, address(nft)), 0);
        _assertAccounting(quantity);
    }

    function testFuzz_nearCapRejectsWholeBatchThenSellsOut(uint8 remainingSeed, uint8 excessSeed) public {
        uint256 remaining = bound(remainingSeed, 1, 9);
        uint256 quantity = bound(excessSeed, remaining + 1, 10);
        _fill(CAP - remaining);
        uint256 balanceBefore = token.balanceOf(actors[0]);
        vm.startPrank(actors[0]);
        token.approve(address(nft), PRICE * quantity);
        vm.expectRevert(abi.encodeWithSelector(GradientNFT.ExceedsMaxSupply.selector, quantity, remaining));
        nft.mint(quantity);
        vm.stopPrank();
        assertEq(token.balanceOf(actors[0]), balanceBefore);
        assertEq(token.allowance(actors[0], address(nft)), PRICE * quantity);
        _assertAccounting(CAP - remaining);
        _assertMissing(CAP - remaining + 1);
        _mint(actors[1], remaining);
        for (uint256 id = CAP - remaining + 1; id <= CAP; ++id) {
            assertEq(nft.ownerOf(id), actors[1]);
        }
        vm.prank(actors[0]);
        vm.expectRevert(abi.encodeWithSelector(GradientNFT.ExceedsMaxSupply.selector, 1, 0));
        nft.mint(1);
        _assertAccounting(CAP);
        _assertMissing(CAP + 1);
    }

    function testFuzz_paidReentryReservesWholeOuterRange(uint8 outerSeed, uint8 innerSeed, uint8 prefixSeed) public {
        uint256 outer = bound(outerSeed, 1, 10);
        uint256 inner = bound(innerSeed, 1, 10);
        uint256 prefix = bound(prefixSeed, 0, 20);
        _fill(prefix);
        ObservedReentrantMinter receiver = _receiver(PRICE * (outer + inner), PRICE * (outer + inner));
        receiver.mint(outer, inner, 0);

        assertTrue(receiver.attempted());
        assertTrue(receiver.succeeded());
        assertFalse(receiver.callbackAccountingMismatch());
        assertEq(receiver.firstCallbackSupply(), prefix + outer);
        assertEq(receiver.firstCallbackBurnGain(), PRICE * outer);
        assertEq(receiver.callbackCount(), outer + inner);
        assertEq(receiver.receivedIds(0), prefix + 1);
        for (uint256 i; i < inner; ++i) {
            assertEq(receiver.receivedIds(i + 1), prefix + outer + i + 1);
        }
        for (uint256 i = 1; i < outer; ++i) {
            assertEq(receiver.receivedIds(inner + i), prefix + i + 1);
        }
        for (uint256 id = prefix + 1; id <= prefix + outer + inner; ++id) {
            assertEq(nft.ownerOf(id), address(receiver));
        }
        assertEq(nft.balanceOf(address(receiver)), outer + inner);
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(token.allowance(address(receiver), address(nft)), 0);
        _assertAccounting(prefix + outer + inner);
    }

    function testFuzz_reentryCannotSpendMissingFundsOrAllowance(uint8 outerSeed, uint8 innerSeed, bool missingFunds)
        public
    {
        uint256 outer = bound(outerSeed, 1, 10);
        uint256 inner = bound(innerSeed, 1, 10);
        uint256 funds = PRICE * (outer + inner) - (missingFunds ? 1 : 0);
        uint256 allowance = PRICE * (outer + inner) - (missingFunds ? 0 : 1);
        ObservedReentrantMinter receiver = _receiver(funds, allowance);
        receiver.mint(outer, inner, 0);
        assertTrue(receiver.attempted());
        assertFalse(receiver.succeeded());
        assertFalse(receiver.callbackAccountingMismatch());
        bytes memory expected = missingFunds
            ? abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(receiver), PRICE * inner - 1, PRICE * inner
            )
            : abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(nft), PRICE * inner - 1, PRICE * inner
            );
        assertEq(receiver.innerError(), expected);
        assertEq(receiver.callbackCount(), outer);
        assertEq(nft.balanceOf(address(receiver)), outer);
        assertEq(token.balanceOf(address(receiver)), funds - PRICE * outer);
        assertEq(token.allowance(address(receiver), address(nft)), allowance - PRICE * outer);
        for (uint256 id = 1; id <= outer; ++id) {
            assertEq(nft.ownerOf(id), address(receiver));
        }
        _assertAccounting(outer);
        _assertMissing(outer + 1);
    }

    function testFuzz_reentryCannotExceedRemainingSupply(uint8 outerSeed, uint8 gapSeed) public {
        uint256 outer = bound(outerSeed, 1, 10);
        uint256 gap = bound(gapSeed, 0, 9);
        uint256 prefix = CAP - outer - gap;
        _fill(prefix);
        uint256 inner = gap + 1;
        ObservedReentrantMinter receiver = _receiver(PRICE * 20, type(uint256).max);
        receiver.mint(outer, inner, 0);
        assertTrue(receiver.attempted());
        assertFalse(receiver.succeeded());
        assertFalse(receiver.callbackAccountingMismatch());
        assertEq(receiver.innerError(), abi.encodeWithSelector(GradientNFT.ExceedsMaxSupply.selector, inner, gap));
        assertEq(receiver.callbackCount(), outer);
        assertEq(nft.balanceOf(address(receiver)), outer);
        assertEq(token.balanceOf(address(receiver)), PRICE * (20 - outer));
        _assertAccounting(prefix + outer);
        _assertMissing(prefix + outer + 1);
        if (gap != 0) _mint(actors[0], gap);
        _assertAccounting(CAP);
    }

    function testFuzz_reentrantInvalidQuantity(uint256 inner) public {
        vm.assume(inner == 0 || inner > 10);
        ObservedReentrantMinter receiver = _receiver(PRICE * 20, type(uint256).max);
        receiver.mint(1, inner, 0);
        assertTrue(receiver.attempted());
        assertFalse(receiver.succeeded());
        assertEq(receiver.innerError(), abi.encodeWithSelector(GradientNFT.InvalidQuantity.selector, inner));
        assertFalse(receiver.callbackAccountingMismatch());
        assertEq(receiver.callbackCount(), 1);
        _assertAccounting(1);
        _assertMissing(2);
    }

    function testFuzz_lateReceiverRejectionRollsBackOuterAndNestedMint(uint8 outerSeed, uint8 innerSeed) public {
        uint256 outer = bound(outerSeed, 2, 10);
        uint256 inner = bound(innerSeed, 1, 10);
        uint256 cost = PRICE * (outer + inner);
        ObservedReentrantMinter receiver = _receiver(cost, cost);
        // Nested mint completes in the first callback; rejection happens on the last outer id.
        vm.expectRevert(abi.encodeWithSelector(ObservedReentrantMinter.CallbackRejected.selector, outer));
        receiver.mint(outer, inner, outer);
        _assertAccounting(0);
        assertEq(token.balanceOf(address(receiver)), cost);
        assertEq(token.allowance(address(receiver), address(nft)), cost);
        assertEq(nft.balanceOf(address(receiver)), 0);
        assertEq(receiver.callbackCount(), 0, "receiver state also rolls back");
        for (uint256 id = 1; id <= outer + inner; ++id) {
            _assertMissing(id);
        }
        receiver.mint(outer, inner, 0);
        assertTrue(receiver.succeeded());
        assertFalse(receiver.callbackAccountingMismatch());
        _assertAccounting(outer + inner);
    }
}
