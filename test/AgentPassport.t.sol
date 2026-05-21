// SPDX-license-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AgentPassport.sol";

contract AgentPassportTest is Test {

    AgentPassport public passport;
    
    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public samuel = makeAddr("samuel");
    address public agentOne = makeAddr("agentOne");
    address public stranger = makeAddr("stranger");

    function setUp() public { vm.startPrank(owner);
    passport = new AgentPassport(treasury, 0.01 ether);
    vm.stopPrank();
    vm.deal(samuel, 1 ether);
    }

    //=====================================================
    // DEVELOPER VERIFICATION TESTS
    //=====================================================

    function test_verifyDeveloper_success() public{
        vm.prank(owner);
        passport.verifyDeveloper(samuel);
        assertTrue(passport.isVerifiedDeveloper(samuel));
    }

    function test_verifyDeveloper_revertsIfNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        passport.verifyDeveloper(samuel);
    }

    function test_verifyDeveloper_revertsIfAlreadyVerified() public {
        vm.prank(owner);
        passport.verifyDeveloper(samuel);

        vm.prank(owner);
        vm.expectRevert(AgentPassport.AlreadyVerified.selector);
        passport.verifyDeveloper(samuel);
    }

    //=====================================================
    //MINTING TESTS
    //=====================================================

    function test_mintPassport_success() public {
        vm.prank(owner);
        passport.verifyDeveloper(samuel);

        vm.prank(samuel);
        uint256 tokenId = passport.mintPassport{value: 0.01 ether}
        (agentOne, AgentPassport.Niche.DIGITAL_MARKETING, 1, "Runs ad campaigns and social media");

        assertEq(tokenId, 1);
        assertEq(passport.totalAgents(), 1);
        assertEq(passport.ownerOf(1), agentOne);
    }

    function test_mintPassport_revertsIfNotVerified()
    public{
        vm.prank(stranger);
        vm.expectRevert();
        passport.mintPassport{value: 0.01 ether}
        (agentOne, AgentPassport.Niche.DIGITAL_MARKETING, 1, "Runs ad campaigns");
    }

    function test_mintPassport_revertsIfFeeTooLow()
    public{
        vm.prank(owner);
        passport.verifyDeveloper(samuel);

        vm.prank(samuel);
        vm.expectRevert(AgentPassport.InsufficientMintingFee.selector);
        passport.mintPassport{value: 0.001 ether}(agentOne, AgentPassport.Niche.DIGITAL_MARKETING, 1, "Runs ad campaigns");
        }
}