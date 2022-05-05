// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import {TestFixture} from "./utils/TestFixture.sol";
import {StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SugarVault} from "../examples/SugarVault.sol";
import "forge-std/console.sol";

// TODO: add more tests for failures and edge cases
contract SugarVaultTest is TestFixture {
    SugarVault public sugar;

    function setUp() public override {
        super.setUp();

        sugar = new SugarVault(address(vaultWrapper));
        vm.label(address(sugar), "sugar");
    }

    function testSetupOk() public {
        console.log("address of sugar contract", address(sugar));
        assertTrue(address(0) != address(sugar));
        assertEq(address(sugar.vault()), address(vaultWrapper));
        assertEq(address(sugar.token()), address(want));
    }

    function testStartSharingYield(uint256 _amount) public {
        // setup
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), whale, _amount);
        vm.startPrank(whale);
        want.approve(address(sugar), _amount);

        // execution
        uint256 shares = sugar.startSharingYield(user, _amount);
        vm.stopPrank();

        // asserts
        assertEq(sugar.tokenBalances(whale), _amount);
        assertEq(
            sugar.shareBalances(whale),
            vaultWrapper.convertToShares(_amount)
        );
        assertEq(shares, vaultWrapper.convertToShares(_amount));
        assertEq(
            vaultWrapper.balanceOf(address(sugar)),
            vaultWrapper.convertToShares(_amount)
        );
        assertEq(want.balanceOf(whale), 0);
    }

    function testStopSharingYield(uint256 _amount) public {
        // setup
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), whale, _amount);
        vm.startPrank(whale);
        want.approve(address(sugar), _amount);
        sugar.startSharingYield(user, _amount);

        // execution
        sugar.stopSharingYield();
        vm.stopPrank();

        // asserts
        assertEq(want.balanceOf(whale), _amount);
        assertEq(sugar.tokenBalances(whale), 0);
        assertEq(sugar.shareBalances(whale), 0);
        assertEq(vaultWrapper.balanceOf(address(sugar)), 0);
    }

    function testClaimYield(uint256 _amount) public {
        // setup
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), whale, _amount);
        deal(address(want), address(this), _amount / 2);
        vm.startPrank(whale);
        want.approve(address(sugar), _amount);
        uint256 initialShares = sugar.startSharingYield(user, _amount);
        vm.stopPrank();

        // Harvest 1: Send funds through the strategy
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);
        // Airdrop gains to the strategy
        want.transfer(address(strategy), want.balanceOf(address(this)));
        // Harvest 2: Realize profit
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        skip(6 hours);

        // execution
        uint256 claimable = sugar.claimable(whale, user);
        vm.prank(user);
        uint256 _claimed = sugar.claimYield(whale);
        vm.prank(whale);
        sugar.stopSharingYield();

        // asserts
        assertRelApproxEq(claimable, _claimed, 10**2);
        assertEq(want.balanceOf(user), _claimed);
        assertGt(initialShares, sugar.shareBalances(whale));
        assertTrue(want.balanceOf(whale) >= _amount);
        assertTrue(
            vaultWrapper.convertToAssets(sugar.shareBalances(whale)) >=
                sugar.tokenBalances(whale)
        );
    }
}
