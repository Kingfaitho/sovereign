// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/SovereignTreasury.sol";

contract Mockusdc {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

}

    contract SovereignTreasuryTest is Test {
        SovereignTreasury public treasury;
        Mockusdc public usdc;

        address public owner = makeAddr("owner");
        address public founder = makeAddr("founder");
        address public passport = makeAddr("passport");
        address public stranger = makeAddr("stranger");

        uint256 constant GENESIS = 10 * 1e6; // 10 usdc

        function setUp() public {
            usdc = new Mockusdc();

            vm.prank(owner);
            treasury = new SovereignTreasury(address(usdc), founder, GENESIS);

            vm.prank(owner);
            treasury.setPassportContract(passport);

            usdc.mint(address(treasury), 10_000 * 1e6); // Fund treasury with 10k usdc
            usdc.mint(address(this), 10_000 * 1e6); // Fund test contract with 10k usdc
            usdc.approve(address(treasury), type(uint256).max);
        }

        //==============================================
        // PHASE TESTS
        //==============================================

        function test_phase_startsAtOne() public view {
            assertEq(treasury.currentPhase(), 1);
        }

        function test_phase_transitionsToTwo() public {
            vm.prank(passport);
            treasury.updateAgentCount(1_000);
            assertEq(treasury.currentPhase(), 2);
        }

        function test_phase_transitionsToThree() public {
            vm.prank(passport);
            treasury.updateAgentCount(10_000);
            assertEq(treasury.currentPhase(), 3);
        }
        
        //==============================================
        // FOUNDER CUT TESTS
        //==============================================

        function test_founderCut_phaseOne() public view {
            assertEq(treasury.currentFounderBps(), 1_000);
        }

        function test_founderBps_phaseTwo() public {
            vm.prank(passport);
            treasury.updateAgentCount(1_000);
            assertEq(treasury.currentFounderBps(), 600);
        }

        function test_founderBps_phaseThree() public {
            vm.prank(passport);
            treasury.updateAgentCount(10_000);
            assertEq(treasury.currentFounderBps(), 350);
        }

        function test_receiveFees_founderGetsCorrectCut() public {
            uint256 amount = 1_000 * 1e6; // 1000 usdc
            uint256 founderBefore = usdc.balanceOf(founder);
            
            treasury.receiveFees(amount);

            uint256 founderAfter = usdc.balanceOf(founder);
            uint256 expectedCut = (amount * 1_000) / 10_000; // 10% cut in phase one
            assertEq(founderAfter - founderBefore, expectedCut);
        }

        //==============================================
        // GENESIS TESTS
        //==============================================

        function test_claimGenesis_success() public {
            address agent = makeAddr("agent");
            uint256 before = usdc.balanceOf(agent);

            vm.prank(passport);
            treasury.claimGenesis(agent);

            assertEq(usdc.balanceOf(agent) - before, GENESIS);
        }

        function test_claimGenesis_revertsIfDouble() public {
            address agent = makeAddr("agent");

            vm.prank(passport);
            treasury.claimGenesis(agent);

            vm.prank(passport);
            vm.expectRevert(SovereignTreasury.AlreayClaimedGenesis.selector);
            treasury.claimGenesis(agent);
        }

        function test_claimGenesis_revertsIfNotPassport() public {
            vm.prank(stranger);
            vm.expectRevert(SovereignTreasury.NotPassportContract.selector);
            treasury.claimGenesis(makeAddr("agent"));
        }

        function test_updateAgentCount_success() public {
        vm.prank(passport);
        treasury.updateAgentCount(500);
        assertEq(treasury.totalActiveAgents(), 500);
        }
        
        function test_updateAgentCount_revertsIfNotPassport() public {
        vm.prank(stranger);
        vm.expectRevert(SovereignTreasury.NotPassportContract.selector);
        treasury.updateAgentCount(500);
        }
    }

