// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AgentPassport.sol";
import "../src/SovereignTreasury.sol";
import "../src/SovereignEscrow.sol";

contract MockUSDC {
    string  public name     = "USD Coin";
    string  public symbol   = "USDC";
    uint8   public decimals = 6;

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

contract Deploy is Script {
    function run() external {
        uint256 deployerKey     = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer        = vm.addr(deployerKey);
        address treasuryWallet  = vm.envAddress("TREASURY_ADDRESS");

        console.log("=== SOVEREIGN PROTOCOL - LOCAL DEPLOYMENT ===");
        console.log("Deployer: ", deployer);
        console.log("Treasury: ", treasuryWallet);
        console.log("=============================================");

        vm.startBroadcast(deployerKey);

        // Step 1 - Deploy MockUSDC
        MockUSDC usdc = new MockUSDC();
        console.log("MockUSDC deployed:          ", address(usdc));

        // Step 2 - Mint 1,000,000 USDC to deployer for testing
        usdc.mint(deployer, 1_000_000 * 1e6);
        console.log("Minted 1,000,000 USDC to deployer");

        // Step 3 - Deploy AgentPassport
        AgentPassport passport = new AgentPassport(
            treasuryWallet,
            0.001 ether
        );
        console.log("AgentPassport deployed:     ", address(passport));

        // Step 4 - Deploy SovereignTreasury
        SovereignTreasury treasury = new SovereignTreasury(
            address(usdc),
            deployer,
            1_000_000
        );
        console.log("SovereignTreasury deployed: ", address(treasury));

        // Step 5 - Deploy SovereignEscrow
        SovereignEscrow escrow = new SovereignEscrow(
            address(usdc),
            address(passport),
            address(treasury)
        );
        console.log("SovereignEscrow deployed:   ", address(escrow));

        // Step 6 - Wire treasury to passport
        treasury.setPassportContract(address(passport));
        console.log("Treasury wired to Passport");

        // Step 7 - Verify developer (deployer becomes first verified developer)
        passport.verifyDeveloper(deployer);
        console.log("Deployer verified as developer");

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("MOCK_USDC=",        address(usdc));
        console.log("PASSPORT_ADDRESS=", address(passport));
        console.log("TREASURY_ADDRESS=", address(treasury));
        console.log("ESCROW_ADDRESS=",   address(escrow));
        console.log("===========================");
    }
}
