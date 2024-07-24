// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {MyGovernor} from "../src/MyGovernor.sol";
import {GovToken} from "../src/GovToken.sol";
import {TimeLock} from "../src/TimeLock.sol";
import {Box} from "../src/Box.sol";

contract MyGovernorTest is Test {
    GovToken token;
    TimeLock timelock;
    MyGovernor governor;
    Box box;

    address public USER = makeAddr("user");
    uint256 public constant INITIAL_SUPPLY = 100 ether;

    address[] proposers;
    address[] executors;

    uint256[] values;
    bytes[] calldatas;
    address[] targets;

    uint256 public constant MIN_DELAY = 3600; // 1 hour - after vote passes
    uint256 public constant VOTING_DELAY = 7400; // how many blocks till a vote is active
    uint256 public constant VOTING_PERIOD = 50400; // 1 week

    function setUp() public {
        token = new GovToken();
        token.mint(USER, INITIAL_SUPPLY);

        vm.startPrank(USER);
        // if you mint token it doesn't mean you have voting power
        //Delegates votes from the sender to `delegatee`.
        token.delegate(USER);
        timelock = new TimeLock(MIN_DELAY, proposers, executors, USER); // arrays are empty, everyone can propose, everyone can execute
        governor = new MyGovernor(token, timelock);

        // we have to grant some roles
        // timelock has default roles
        // also we need to remove ourselves as the admin of the timelock
        // we do not want to single centralized entity to have power over it

        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();

        // only the governor can actually propose stuff
        timelock.grantRole(proposerRole, address(governor));
        timelock.grantRole(executorRole, address(0)); // anyone can execute

        timelock.revokeRole(adminRole, address(this));
        vm.stopPrank();

        // should we set DAO as owner?
        // no, we should set timelock as owner
        // DAO owns timelock, and timelock owns box
        box = new Box(address(timelock));
    }

    function testCantUpdateBoxWithoutGovernance() public {
        vm.expectRevert();
        box.store(1);
    }

    function testGovernanceUpdatesBox() public {
        uint256 valueToStore = 999;

        // we need to propose that box updates the stored value to 999
        string memory description = "store 1 in Box";
        bytes memory encodedFunctionCall = abi.encodeWithSignature("store(uint256)", valueToStore);

        values.push(0); // empty, we are not gonna send any eth
        calldatas.push(encodedFunctionCall);
        targets.push(address(box)); // contract to make transaction

        // 1. Propose to the DAO
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // View the state of the proposal
        // return 0 bc it is not active yet bc of delay
        console.log("Proposal State: ", uint256(governor.state(proposalId)));

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.roll(block.number + VOTING_DELAY + 1);

        // return 1 bc now it is active
        console.log("Proposal State: ", uint256(governor.state(proposalId)));

        // 2. Vote
        string memory reason = "cuz blue frog is cool";
        // enum VoteType {
        // Against, // 0
        // For, // 1
        // Abstain // 2
        // }

        uint8 voteWay = 1; // voting yes
        vm.prank(USER);
        governor.castVoteWithReason(proposalId, voteWay, reason);

        // 1 week later
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.roll(block.number + VOTING_PERIOD + 1);

        // 3. Queue the TX
        // queue means it past but we have to wait
        bytes32 descriptionHash = keccak256(abi.encodePacked(description));
        governor.queue(targets, values, calldatas, descriptionHash);

        // 1 hour later
        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.roll(block.number + MIN_DELAY + 1);      

        // 4. Execute
        governor.execute(targets, values, calldatas, descriptionHash);

        assert(box.getNumber() == valueToStore);
    }
}
