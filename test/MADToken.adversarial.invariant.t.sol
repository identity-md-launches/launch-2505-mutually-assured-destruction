// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MADToken} from "../src/MADToken.sol";

/// @dev Drives the token with valid and invalid calls alike. Invalid calls must revert with the
/// exact ERC-6093 error and leave every balance and allowance untouched. Recipients may be fresh
/// fuzzed addresses; every address that ever receives tokens is tracked so balances can be summed.
contract AdversarialHandler is Test {
    MADToken private immutable token;
    address[] public holders;
    mapping(address => bool) private tracked;

    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    /// @dev Cumulative amounts: what each owner has granted, and what each spender has taken.
    mapping(address => mapping(address => uint256)) public granted;
    mapping(address => mapping(address => bool)) public grantedInfinite;
    mapping(address => mapping(address => uint256)) public spent;
    mapping(address => uint256) public received;
    mapping(address => uint256) public sent;

    uint256 public successfulMoves;
    uint256 public probedCalls;
    uint256 private constant MAX_TRACKED = 12;

    constructor(MADToken token_, address[] memory initial) {
        token = token_;
        for (uint256 i; i < initial.length; ++i) {
            _track(initial[i]);
        }
        expectedBalance[initial[0]] = token_.totalSupply();
        received[initial[0]] = token_.totalSupply();
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function _track(address a) private {
        if (!tracked[a]) {
            tracked[a] = true;
            holders.push(a);
        }
    }

    function _saturatingAdd(uint256 a, uint256 b) private pure returns (uint256) {
        unchecked {
            uint256 c = a + b;
            return c < a ? type(uint256).max : c;
        }
    }

    function _pick(uint256 seed) private view returns (address) {
        return holders[seed % holders.length];
    }

    /// @dev Either an existing holder or (while room remains) a fresh nonzero fuzzed address.
    function _recipient(uint256 seed, address fresh) private returns (address) {
        bool special = uint160(fresh) <= 0xff || fresh == VM_ADDRESS || fresh == CONSOLE || fresh == address(this);
        if (!special && holders.length < MAX_TRACKED && seed % 4 == 0) {
            _track(fresh);
            return fresh;
        }
        return _pick(seed);
    }

    function _move(address from, address to, uint256 amount) private {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        sent[from] += amount;
        received[to] += amount;
        ++successfulMoves;
    }

    // ---------------- valid actions ----------------

    function transfer(uint256 fromSeed, uint256 toSeed, address fresh, uint256 amountSeed) external {
        address from = _pick(fromSeed);
        address to = _recipient(toSeed, fresh);
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        // Mix in the edges: zero, max and max - 1.
        if (amount % 7 == 0) amount = type(uint256).max;
        else if (amount % 7 == 1) amount = type(uint256).max - 1;
        else if (amount % 7 == 2) amount = 0;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
        if (amount == type(uint256).max) grantedInfinite[owner][spender] = true;
        else granted[owner][spender] = _saturatingAdd(granted[owner][spender], amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, address fresh, uint256 amountSeed)
        external
    {
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        address to = _recipient(toSeed, fresh);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 available = expectedBalance[owner] < allowed ? expectedBalance[owner] : allowed;
        uint256 amount = bound(amountSeed, 0, available);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        spent[owner][spender] += amount;
        _move(owner, to, amount);
    }

    // ---------------- invalid actions: must revert exactly and change nothing ----------------

    function overdrawTransfer(uint256 fromSeed, uint256 toSeed, uint256 excessSeed) external {
        address from = _pick(fromSeed);
        address to = _pick(toSeed);
        uint256 balance = expectedBalance[from];
        uint256 amount = bound(excessSeed, balance + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(to, amount);
        ++probedCalls;
    }

    function transferToZero(uint256 fromSeed, uint256 amountSeed) external {
        address from = _pick(fromSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
        ++probedCalls;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _pick(ownerSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
        ++probedCalls;
    }

    function overspendAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excessSeed) external {
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        address to = _pick(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        if (allowed == type(uint256).max) return;
        uint256 amount = bound(excessSeed, allowed + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ++probedCalls;
    }

    /// @dev Allowance covers the amount but the owner's balance does not: the allowance must survive.
    function spendBeyondBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excessSeed) external {
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        address to = _pick(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        if (allowed <= balance) return;
        uint256 amount = bound(excessSeed, balance + 1, allowed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ++probedCalls;
    }

    function unknownCall(uint256 callerSeed, bytes4 selector, bytes calldata args) external {
        address caller = _pick(callerSeed);
        if (
            selector == token.transfer.selector || selector == token.transferFrom.selector
                || selector == token.approve.selector
        ) selector = bytes4(keccak256(abi.encode(selector)));
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        // View functions may succeed; nothing state-changing exists. Balances are checked by the invariants.
        ok;
        ++probedCalls;
    }
}

contract MADTokenAdversarialInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 1e18;
    MADToken private token;
    AdversarialHandler private handler;

    function setUp() public {
        token = new MADToken();
        address[] memory initial = new address[](5);
        initial[0] = makeAddr("whale");
        initial[1] = makeAddr("holder 1");
        initial[2] = makeAddr("holder 2");
        initial[3] = makeAddr("holder 3");
        initial[4] = address(token);
        handler = new AdversarialHandler(token, initial);
        assertTrue(token.transfer(initial[0], SUPPLY));

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = AdversarialHandler.transfer.selector;
        selectors[1] = AdversarialHandler.approve.selector;
        selectors[2] = AdversarialHandler.transferFrom.selector;
        selectors[3] = AdversarialHandler.overdrawTransfer.selector;
        selectors[4] = AdversarialHandler.transferToZero.selector;
        selectors[5] = AdversarialHandler.approveZeroSpender.selector;
        selectors[6] = AdversarialHandler.overspendAllowance.selector;
        selectors[7] = AdversarialHandler.spendBeyondBalance.selector;
        selectors[8] = AdversarialHandler.unknownCall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_supplyIsFixedAndFullyAccounted() public view {
        assertEq(token.totalSupply(), SUPPLY);
        uint256 sum;
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            address h = handler.holders(i);
            uint256 balance = token.balanceOf(h);
            assertEq(balance, handler.expectedBalance(h), "balance diverged from model");
            assertEq(balance, handler.received(h) - handler.sent(h), "balance is not inflow minus outflow");
            sum += balance;
        }
        assertEq(sum, SUPPLY, "tokens appeared or vanished");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), handler.expectedBalance(address(handler)));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_noSpenderTakesMoreThanGranted() public view {
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.holders(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.holders(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
                if (!handler.grantedInfinite(owner, spender)) {
                    assertLe(handler.spent(owner, spender), handler.granted(owner, spender), "spent beyond approvals");
                }
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_tokenNeverHoldsEther() public view {
        assertEq(address(token).balance, 0);
    }
}

/// @dev The launch as a state machine: the factory holds the supply, forwards the swarm share,
/// the pool share and the remainder once each, in any order; afterwards the distributor pays
/// claims and traders move tokens in and out of the pool manager.
contract LaunchHandler is Test {
    MADToken public immutable token;
    address public immutable factory;
    address public immutable distributor;
    address public immutable poolManager;
    address public immutable remainderTo;
    address[3] public traders;

    uint256 public immutable swarmShare;
    uint256 public immutable poolShare;

    bool public swarmSent;
    bool public poolSeeded;
    bool public remainderSent;
    uint256 public claimed;
    uint256 public bought;
    uint256 public sold;
    mapping(address => uint256) public claimedBy;

    constructor(MADToken token_, address factory_, address remainderTo_, uint256 poolBps) {
        token = token_;
        factory = factory_;
        remainderTo = remainderTo_;
        distributor = makeAddr("launch distributor");
        poolManager = makeAddr("launch pool manager");
        traders = [makeAddr("trader 0"), makeAddr("trader 1"), makeAddr("trader 2")];
        uint256 supply = token_.totalSupply();
        swarmShare = supply * 1_000 / 10_000;
        poolShare = supply * poolBps / 10_000;
    }

    function sendSwarm() external {
        if (swarmSent) return;
        vm.prank(factory);
        assertTrue(token.transfer(distributor, swarmShare));
        swarmSent = true;
    }

    function seedPool() external {
        if (poolSeeded) return;
        vm.prank(factory);
        assertTrue(token.transfer(poolManager, poolShare));
        poolSeeded = true;
    }

    /// @dev The remainder is whatever the factory still holds once the swarm and pool shares are out.
    function forwardRemainder() external {
        if (remainderSent || !swarmSent || !poolSeeded) return;
        uint256 rest = token.balanceOf(factory);
        vm.prank(factory);
        assertTrue(token.transfer(remainderTo, rest));
        remainderSent = true;
    }

    function claim(uint256 who, uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 0, swarmShare - claimed);
        if (!swarmSent) amount = 0;
        address claimant = address(uint160(uint256(keccak256(abi.encode("claimant", who % 50)))));
        vm.prank(distributor);
        assertTrue(token.transfer(claimant, amount));
        claimed += amount;
        claimedBy[claimant] += amount;
    }

    function overClaim(uint256 excessSeed) external {
        uint256 balance = token.balanceOf(distributor);
        uint256 amount = bound(excessSeed, balance + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, distributor, balance, amount)
        );
        vm.prank(distributor);
        token.transfer(traders[0], amount);
    }

    function buy(uint256 traderSeed, uint256 amountSeed) external {
        address trader = traders[traderSeed % 3];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(poolManager));
        vm.prank(poolManager);
        assertTrue(token.transfer(trader, amount));
        bought += amount;
    }

    function sell(uint256 traderSeed, uint256 amountSeed) external {
        address trader = traders[traderSeed % 3];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(trader));
        uint256 before = token.balanceOf(poolManager);
        vm.prank(trader);
        assertTrue(token.transfer(poolManager, amount));
        assertEq(token.balanceOf(poolManager), before + amount, "the pool received short");
        sold += amount;
    }

    /// @dev Nobody but the holder moves the holder's tokens: the factory, distributor and pool
    /// manager hold no allowance over anyone.
    function privilegedPull(uint256 actorSeed, uint256 victimSeed) external {
        address[3] memory privileged = [factory, distributor, poolManager];
        address actor = privileged[actorSeed % 3];
        address victim = traders[victimSeed % 3];
        if (token.allowance(victim, actor) != 0) return;
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, actor, 0, 1));
        vm.prank(actor);
        token.transferFrom(victim, actor, 1);
    }
}

contract MADLaunchInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 1e18;
    address private constant REMAINDER_TO = 0x1EE3ffadfE138415A2ddaedeEBe5F46616fA413d;
    MADToken private token;
    LaunchHandler private handler;
    address private factory;

    function setUp() public {
        factory = makeAddr("launch factory");
        vm.prank(factory);
        token = new MADToken();
        handler = new LaunchHandler(token, factory, REMAINDER_TO, 8_000);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = LaunchHandler.sendSwarm.selector;
        selectors[1] = LaunchHandler.seedPool.selector;
        selectors[2] = LaunchHandler.forwardRemainder.selector;
        selectors[3] = LaunchHandler.claim.selector;
        selectors[4] = LaunchHandler.overClaim.selector;
        selectors[5] = LaunchHandler.buy.selector;
        selectors[6] = LaunchHandler.sell.selector;
        selectors[7] = LaunchHandler.privilegedPull.selector;
        selectors[8] = LaunchHandler.seedPool.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_launchAccountingIsExact() public view {
        assertEq(token.totalSupply(), SUPPLY);
        uint256 swarm = handler.swarmShare();
        uint256 pool = handler.poolShare();
        assertEq(swarm + pool + SUPPLY / 10, SUPPLY, "shares do not add up to the supply");

        uint256 factoryExpected = SUPPLY;
        if (handler.swarmSent()) factoryExpected -= swarm;
        if (handler.poolSeeded()) factoryExpected -= pool;
        if (handler.remainderSent()) factoryExpected = 0;
        assertEq(token.balanceOf(factory), factoryExpected, "factory balance");

        uint256 distributorExpected = handler.swarmSent() ? swarm - handler.claimed() : 0;
        assertEq(token.balanceOf(handler.distributor()), distributorExpected, "distributor balance");
        assertLe(handler.claimed(), swarm, "claimed more than the swarm share");

        uint256 poolExpected = handler.poolSeeded() ? pool + handler.sold() - handler.bought() : 0;
        assertEq(token.balanceOf(handler.poolManager()), poolExpected, "pool balance");

        assertEq(token.balanceOf(REMAINDER_TO), handler.remainderSent() ? SUPPLY / 10 : 0, "remainder");

        uint256 tradersHeld;
        for (uint256 i; i < 3; ++i) {
            tradersHeld += token.balanceOf(handler.traders(i));
        }
        assertEq(tradersHeld, handler.bought() - handler.sold(), "traders hold what they net bought");
    }

    /// @dev Once a phase has happened it cannot be undone: the swarm share stays out of the factory.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_factoryNeverRegainsDistributedShares() public view {
        if (handler.remainderSent()) assertEq(token.balanceOf(factory), 0);
        if (handler.swarmSent()) assertLe(token.balanceOf(factory), SUPPLY - handler.swarmShare());
    }
}
