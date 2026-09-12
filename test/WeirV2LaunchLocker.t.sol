// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WeirV2LaunchLocker} from "../src/WeirV2LaunchLocker.sol";

contract MockPositionManager is ERC721 {
    constructor() ERC721("Mock Position", "MPOS") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract MockLaunchToken is ERC20 {
    constructor() ERC20("Mock Launch Token", "MLT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract WeirV2LaunchLockerTest is Test {
    WeirV2LaunchLocker internal locker;
    MockPositionManager internal positionManager;
    MockLaunchToken internal launchToken;

    address internal owner = makeAddr("owner");
    address internal factory = makeAddr("factory");
    address internal launchTokenAddr;

    function setUp() public {
        positionManager = new MockPositionManager();
        launchToken = new MockLaunchToken();
        launchTokenAddr = address(launchToken);
        locker = new WeirV2LaunchLocker(owner, address(positionManager));

        vm.prank(owner);
        locker.setFactory(factory);
    }

    function test_constructor_revertsOnZeroPositionManager() public {
        vm.expectRevert(WeirV2LaunchLocker.ZeroAddress.selector);
        new WeirV2LaunchLocker(owner, address(0));
    }

    function test_setFactory_onlyOnce() public {
        vm.prank(owner);
        vm.expectRevert(WeirV2LaunchLocker.AlreadyInitialized.selector);
        locker.setFactory(makeAddr("otherFactory"));
    }

    function test_setFactory_onlyOwner() public {
        WeirV2LaunchLocker fresh = new WeirV2LaunchLocker(owner, address(positionManager));
        vm.expectRevert();
        fresh.setFactory(factory);
    }

    function test_renounceOwnership_disabled() public {
        vm.prank(owner);
        vm.expectRevert(WeirV2LaunchLocker.OwnershipCannotBeRenounced.selector);
        locker.renounceOwnership();
    }

    function test_onERC721Received_onlyPositionManager() public {
        vm.expectRevert(WeirV2LaunchLocker.NotPositionManager.selector);
        locker.onERC721Received(address(0), address(0), 1, "");
    }

    function test_onERC721Received_acceptsFromPositionManager() public {
        vm.prank(address(positionManager));
        bytes4 selector = locker.onERC721Received(address(0), address(0), 1, "");
        assertEq(selector, locker.onERC721Received.selector);
    }

    function test_lockPosition_onlyFactory() public {
        positionManager.mint(address(locker), 1);
        vm.expectRevert(WeirV2LaunchLocker.NotFactory.selector);
        locker.lockPosition(launchTokenAddr, 1);
    }

    function test_lockPosition_revertsIfLockerDoesNotHoldPosition() public {
        vm.prank(factory);
        vm.expectRevert(WeirV2LaunchLocker.PositionNotHeld.selector);
        locker.lockPosition(launchTokenAddr, 1);
    }

    function test_lockPosition_succeedsAndRecordsTokenId() public {
        positionManager.mint(address(locker), 42);

        vm.prank(factory);
        locker.lockPosition(launchTokenAddr, 42);

        assertTrue(locker.isLocked(launchTokenAddr));
        assertEq(locker.lockedPositions(launchTokenAddr), 42);
    }

    function test_lockPosition_revertsIfAlreadyLocked() public {
        positionManager.mint(address(locker), 42);
        vm.prank(factory);
        locker.lockPosition(launchTokenAddr, 42);

        positionManager.mint(address(locker), 43);
        vm.prank(factory);
        vm.expectRevert(WeirV2LaunchLocker.PositionAlreadyLocked.selector);
        locker.lockPosition(launchTokenAddr, 43);
    }

    function test_lockTokenSupply_onlyFactory() public {
        vm.expectRevert(WeirV2LaunchLocker.NotFactory.selector);
        locker.lockTokenSupply(launchTokenAddr, 100e18);
    }

    function test_lockTokenSupply_revertsOnZeroToken() public {
        vm.prank(factory);
        vm.expectRevert(WeirV2LaunchLocker.ZeroAddress.selector);
        locker.lockTokenSupply(address(0), 100e18);
    }

    function test_lockTokenSupply_noOpOnZeroAmount() public {
        vm.prank(factory);
        locker.lockTokenSupply(launchTokenAddr, 0);
        assertEq(locker.lockedTokenSupply(launchTokenAddr), 0);
    }

    function test_lockTokenSupply_transfersInAndAccumulates() public {
        launchToken.mint(factory, 1_000e18);
        vm.prank(factory);
        launchToken.approve(address(locker), type(uint256).max);

        vm.prank(factory);
        locker.lockTokenSupply(launchTokenAddr, 300e18);
        vm.prank(factory);
        locker.lockTokenSupply(launchTokenAddr, 200e18);

        assertEq(locker.lockedTokenSupply(launchTokenAddr), 500e18);
        assertEq(launchToken.balanceOf(address(locker)), 500e18);
    }

    function test_isLocked_falseForUnknownToken() public {
        assertFalse(locker.isLocked(makeAddr("unknownToken")));
    }
}
