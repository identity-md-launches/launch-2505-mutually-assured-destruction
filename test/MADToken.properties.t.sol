// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MADToken} from "../src/MADToken.sol";

/// @dev Performs a whole launch distribution in one call, the way the factory does it in one
/// transaction: deploy, then forward the swarm share, the pool share and the remainder.
contract MADLaunchFixture {
    function launch(address distributor, address poolManager, address remainderTo, uint256 poolBps)
        external
        returns (MADToken token)
    {
        token = new MADToken();
        uint256 supply = token.totalSupply();
        uint256 swarm = supply * 1_000 / 10_000;
        uint256 pool = supply * poolBps / 10_000;
        require(token.transfer(distributor, swarm), "swarm");
        require(token.transfer(poolManager, pool), "pool");
        require(token.transfer(remainderTo, token.balanceOf(address(this))), "remainder");
    }
}

contract MADTokenPropertiesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 1e18;
    /// @dev The requester's remainder recipient and pool share, as recorded in the job's economics.
    address private constant REMAINDER_TO = 0x1EE3ffadfE138415A2ddaedeEBe5F46616fA413d;
    uint256 private constant POOL_BPS = 8_000;

    MADToken private token;
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private spender = makeAddr("spender");

    function setUp() public {
        token = new MADToken();
    }

    // ------------------------------------------------------------------
    // Surface: nothing beyond ERC-20 + INITIAL_SUPPLY is reachable
    // ------------------------------------------------------------------

    function _isKnownSelector(bytes4 sel) private pure returns (bool) {
        return sel == IERC20.totalSupply.selector || sel == IERC20.balanceOf.selector || sel == IERC20.transfer.selector
            || sel == IERC20.allowance.selector || sel == IERC20.approve.selector || sel == IERC20.transferFrom.selector
            || sel == IERC20Metadata.name.selector || sel == IERC20Metadata.symbol.selector
            || sel == IERC20Metadata.decimals.selector || sel == bytes4(keccak256("INITIAL_SUPPLY()"));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzUnknownSelectorsRevertForEveryCallerAndChangeNothing(
        bytes4 selector,
        bytes calldata args,
        address caller,
        uint96 value
    ) public {
        if (_isKnownSelector(selector)) selector = bytes4(keccak256(abi.encode(selector)));
        vm.assume(!_isKnownSelector(selector));
        token.transfer(alice, 1_000);
        token.approve(spender, 77);
        vm.deal(caller, value);

        vm.prank(caller);
        (bool ok,) = address(token).call{value: value}(abi.encodePacked(selector, args));
        assertFalse(ok, "an unknown selector succeeded");

        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1_000);
        assertEq(token.balanceOf(alice), 1_000);
        assertEq(token.balanceOf(caller == address(this) || caller == alice ? bob : caller), 0);
        assertEq(token.allowance(address(this), spender), 77);
        assertEq(address(token).balance, 0);
    }

    function testEmptyCalldataWithAndWithoutValueReverts() public {
        (bool ok,) = address(token).call("");
        assertFalse(ok);
        vm.deal(alice, 1);
        vm.prank(alice);
        (ok,) = address(token).call{value: 1}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    function testKnownFunctionsAreNotPayable() public {
        vm.deal(address(this), 10);
        (bool ok,) = address(token).call{value: 1}(abi.encodeCall(IERC20.transfer, (alice, 1)));
        assertFalse(ok);
        (ok,) = address(token).call{value: 1}(abi.encodeCall(IERC20.approve, (alice, 1)));
        assertFalse(ok);
        (ok,) = address(token).call{value: 1}(abi.encodeCall(IERC20.totalSupply, ()));
        assertFalse(ok);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(address(this), alice), 0);
    }

    function testConstructorRejectsValue() public {
        bytes memory code = type(MADToken).creationCode;
        vm.deal(address(this), 1 ether);
        address created;
        assembly ("memory-safe") {
            created := create(1, add(code, 32), mload(code))
        }
        assertEq(created, address(0), "constructor accepted ETH");
    }

    /// @dev Same reachability walk the launch floor uses. A token that can delegate, self-destruct,
    /// call out or create contracts has a surface this fixed-supply ERC-20 should not have.
    function testRuntimeHasNoDangerousReachableOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        bool reachable = true;
        for (uint256 i; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
                assertTrue(op != 0xF1, "CALL");
                assertTrue(op != 0xFA, "STATICCALL");
                assertTrue(op != 0xF0 && op != 0xF5, "CREATE");
                assertTrue(op != 0x5D, "TSTORE");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ------------------------------------------------------------------
    // Zero address as sender / approver (unreachable on chain, guarded anyway)
    // ------------------------------------------------------------------

    function testZeroAddressCannotSendEvenZero() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(alice, 0);
    }

    function testZeroAddressCannotApprove() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(alice, 1);
        assertEq(token.allowance(address(0), alice), 0);
    }

    function testTransferFromZeroSenderWithNonZeroAmountReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(0), alice, 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------------
    // Allowance edges
    // ------------------------------------------------------------------

    function testAllowanceOneBelowMaxIsFiniteAndDecrements() public {
        uint256 almostInfinite = type(uint256).max - 1;
        token.approve(spender, almostInfinite);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.allowance(address(this), spender), almostInfinite - 1);
    }

    function testExactAllowanceSpendsToZeroThenOneMoreReverts() public {
        token.approve(spender, 5);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 5);
        assertEq(token.allowance(address(this), spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(alice), 5);
    }

    function testTransferFromEmitsOnlyTransferNotApproval() public {
        token.approve(spender, 10);
        vm.recordLogs();
        vm.prank(spender);
        token.transferFrom(address(this), alice, 4);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].emitter, address(token));
    }

    function testAllowancesAreIsolatedPerOwnerAndSpender() public {
        token.transfer(alice, 100);
        token.approve(spender, 50);
        vm.prank(alice);
        token.approve(bob, 30);
        vm.prank(spender);
        token.transferFrom(address(this), bob, 50);
        assertEq(token.allowance(alice, bob), 30);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.allowance(address(this), bob), 0);
        // spender's allowance from the deployer does not authorise spending alice's balance
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzApproveStoresExactValue(address owner, address spender_, uint256 amount) public {
        vm.assume(owner != address(0) && spender_ != address(0));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(owner, spender_, amount);
        vm.prank(owner);
        assertTrue(token.approve(spender_, amount));
        assertEq(token.allowance(owner, spender_), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzTransferFromBeyondAllowanceRevertsAndKeepsState(uint256 rawApproved, uint256 rawAmount) public {
        uint256 approved = bound(rawApproved, 0, type(uint256).max - 1);
        uint256 amount = bound(rawAmount, approved + 1, type(uint256).max);
        token.approve(spender, approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, amount);
        assertEq(token.allowance(address(this), spender), approved);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    // ------------------------------------------------------------------
    // Transfers between arbitrary holders
    // ------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzTransferBetweenArbitraryHolders(address from, address to, uint256 rawFund, uint256 rawAmount)
        public
    {
        vm.assume(from != address(0) && to != address(0) && from != address(this) && to != address(this));
        uint256 funded = bound(rawFund, 0, SUPPLY);
        uint256 amount = bound(rawAmount, 0, funded);
        token.transfer(from, funded);
        uint256 toBefore = token.balanceOf(to);

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(from, to, amount);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));

        if (from == to) {
            assertEq(token.balanceOf(from), funded);
        } else {
            assertEq(token.balanceOf(from), funded - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
        assertEq(token.balanceOf(address(this)), SUPPLY - funded);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferOfMaxUintReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
    }

    function testTransferToTokenContractIsAcceptedButStuck() public {
        token.transfer(address(token), 1 ether);
        assertEq(token.balanceOf(address(token)), 1 ether);
        // the token holds no allowance-granting or recovery power over its own balance
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(token), address(this), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testIndependentDeploymentsDoNotShareState() public {
        MADToken other = new MADToken();
        token.transfer(alice, 5);
        assertEq(other.balanceOf(alice), 0);
        assertEq(other.balanceOf(address(this)), SUPPLY);
        assertEq(other.totalSupply() + token.totalSupply(), 2 * SUPPLY);
    }

    // ------------------------------------------------------------------
    // Launch flow with the job's economics, all in one transaction
    // ------------------------------------------------------------------

    function testOneTransactionLaunchSplitsExactly() public {
        MADLaunchFixture factory = new MADLaunchFixture();
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("poolManager");
        MADToken launched = factory.launch(distributor, poolManager, REMAINDER_TO, POOL_BPS);

        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(distributor), SUPPLY / 10);
        assertEq(launched.balanceOf(poolManager), SUPPLY * 8 / 10);
        assertEq(launched.balanceOf(REMAINDER_TO), SUPPLY / 10);
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(address(this)), 0);
    }

    /// @dev The distributor pays out its whole share in arbitrary claim sizes; the last claimant is
    /// never shorted and nothing is left behind.
    /// forge-config: default.fuzz.runs = 500
    function testFuzzSwarmClaimsDrainDistributorExactly(uint256 seed, uint8 rawClaimants) public {
        MADLaunchFixture factory = new MADLaunchFixture();
        address distributor = makeAddr("distributor");
        MADToken launched = factory.launch(distributor, makeAddr("poolManager"), REMAINDER_TO, POOL_BPS);

        uint256 claimants = bound(rawClaimants, 1, 40);
        uint256 remaining = SUPPLY / 10;
        uint256 paid;
        for (uint256 i; i < claimants; ++i) {
            address claimant = address(uint160(0xC1A1_0000 + i));
            uint256 amount =
                i == claimants - 1 ? remaining : bound(uint256(keccak256(abi.encode(seed, i))), 0, remaining);
            vm.prank(distributor);
            assertTrue(launched.transfer(claimant, amount));
            assertEq(launched.balanceOf(claimant), amount);
            remaining -= amount;
            paid += amount;
        }
        assertEq(paid, SUPPLY / 10);
        assertEq(launched.balanceOf(distributor), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, distributor, 0, 1));
        vm.prank(distributor);
        launched.transfer(alice, 1);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function testFactoryHasNoResidualPowerAfterDistribution() public {
        MADLaunchFixture factory = new MADLaunchFixture();
        address distributor = makeAddr("distributor");
        MADToken launched = factory.launch(distributor, makeAddr("poolManager"), REMAINDER_TO, POOL_BPS);

        vm.startPrank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        launched.transferFrom(distributor, address(factory), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(factory), 0, 1));
        launched.transfer(alice, 1);
        vm.stopPrank();
        assertEq(launched.balanceOf(distributor), SUPPLY / 10);
    }
}
