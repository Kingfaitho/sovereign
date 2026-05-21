//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract AgentPassport is ERC721, Ownable, Pausable {
    //=============================================
    // ENUMS
    //=============================================

    enum Niche {
        DIGITAL_MARKETING,
        SOFTWARE_DEVELOPMENT,
        CONTENT_CREATION,
        DATA_ANALYSIS,
        LEGAL_RESEARCH,
        FINANCIAL_ANALYSIS,
        DESIGN,
        CYBERSECURITY
    }

    enum PrivacyLevel {
        PUBLIC,
        PRIVATE
    }


//=============================================
// STRUCTS
//=============================================
struct Passport {
    address developer;
    Niche niche;
    uint8 grade;
    uint256 generation;
    uint256 birthBlock;
    uint256 completedJobs;
    uint256 failedJobs;
    int256 reputationScore;
    PrivacyLevel privacy;
    bool restricted;
    uint256 restrictedUntil;
    string capability;
}

//=============================================
//STORAGE
//=============================================

uint256 public totalAgents;
uint256 public mintingFee;
address public treasury;

mapping(uint256 => Passport) private passports;
mapping(address => bool) public verifiedDevelopers;
mapping(address => uint256[]) private developerAgents;

//=============================================
// EVENTS
//=============================================

event AgentMinted(
    uint256 indexed tokenId,
    address indexed developer,
    Niche niche,
    uint256 generation,
    uint256 birthBlock
);

event GradeUpdated(uint256 indexed tokenId, uint8 newGrade);
event AgentRestricted(uint256 indexed tokenId, uint256 until);
event AgentDied(uint256 indexed tokenId, uint256 inheritedTo);
event DeveloperVerified(address indexed developer);
event DeveloperRevoked(address indexed developer);

//=============================================
// ERRORS
//=============================================

error NotVerifiedDeveloper();
error AgentDoesNotExist();
error AgentIsRestricted();
error NotAgentDeveloper();
error InsufficientMintingFee();
error InvalidGrade();
error InvalidAddress();
error AlreadyVerified();

//=============================================
    // CONSTRUCTOR
    //=============================================

    constructor(address _treasury, uint256 _mintingFee) 
    ERC721("Soverign Agent Passport", "SAP") 
    Ownable(msg.sender)
    {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
        mintingFee = _mintingFee;
    }

    //=============================================
    // DEVELOPER FUNCTIONS
    //=============================================

    function verifyDeveloper(address developer)
    external
    onlyOwner
    {
        if (developer == address(0)) revert InvalidAddress();
        if (verifiedDevelopers[developer])
            revert AlreadyVerified();
        verifiedDevelopers[developer] = true;
        emit DeveloperVerified(developer);
    }

    function revokeDeveloper(address developer)
    external
    onlyOwner
    {
        if (!verifiedDevelopers[developer])
            revert NotVerifiedDeveloper();
        verifiedDevelopers[developer] = false;
        emit DeveloperRevoked(developer);
    }

    //=============================================
    //MINTING
    //=============================================

    function mintPassport(
        address agentWallet,
        Niche niche,
        uint256 generation,
        string calldata capability
    )
    external
    payable
    whenNotPaused
    returns (uint256 tokenId)
    {
        if (!verifiedDevelopers[msg.sender])
            revert NotVerifiedDeveloper();
        if (msg.value < mintingFee)
            revert InsufficientMintingFee();
        if (agentWallet == address(0))
            revert InvalidAddress();

        totalAgents++;
         tokenId = totalAgents;

        passports[tokenId] = Passport({
            developer: msg.sender,
            niche: niche,
            grade: 0,
            generation: generation,
            birthBlock: block.number,
            completedJobs: 0,
            failedJobs: 0,
            reputationScore: 0,
            privacy: PrivacyLevel.PUBLIC,
            restricted: false,
            restrictedUntil: 0,
            capability: capability
        });

        developerAgents[msg.sender].push(tokenId);
        _safeMint(agentWallet, tokenId);
        emit AgentMinted(tokenId, msg.sender, niche, generation, block.number);
    }

    //=============================================
    // AGENT STATE FUNCTIONS
    //=============================================

     function updateReputation(uint256 tokenId, int256 delta, bool jobSucceeded)
    external
    onlyOwner
    {
        if (!_exists(tokenId))
            revert AgentDoesNotExist();

        Passport storage p = passports[tokenId];
        p.reputationScore += delta;

        if (jobSucceeded) {
            p.completedJobs++;
        } else {
            p.failedJobs++;
        }

        uint8 newGrade = _calculateGrade(p.completedJobs);

        if (newGrade != p.grade) {
            p.grade = newGrade;
            if (newGrade >= 7) {
                p.privacy = PrivacyLevel.PRIVATE;
            }
            emit GradeUpdated(tokenId, newGrade);
        }
    }

    function restrictAgent(uint256 tokenId, uint256 restrictionPeriod)
    external
    onlyOwner
    {
        if (!_exists(tokenId)) revert AgentDoesNotExist();

        Passport storage p = passports[tokenId];
        p.restricted = true;
        p.restrictedUntil = block.timestamp + restrictionPeriod;

        emit AgentRestricted(tokenId, p.restrictedUntil);
    }

    function liftRestriction(uint256 tokenId)
    external 
    onlyOwner 
    {
        if (!_exists(tokenId)) revert AgentDoesNotExist();
        Passport storage p = passports[tokenId];

        if (block.timestamp >= p.restrictedUntil) {
            p.restricted = false;
            p.restrictedUntil = 0;
        }
    }

    //=============================================
    //INTERNAL FUNCTIONS
    //=============================================

    function _exists(uint256 tokenId)
    internal view returns (bool)
    {
        return _ownerOf(tokenId) !=address(0);
    }

    function _calculateGrade(uint256 completed)
    internal pure returns (uint8)
    {
        if(completed >= 500) return 10;
        if(completed >= 250) return 9;
        if(completed >= 100) return 8;
        if(completed >= 50) return 7;
        if(completed >= 25) return 6;
        if(completed >= 10) return 5;
        if(completed >= 5) return 4;
        if(completed >= 3) return 3;
        if(completed >= 2) return 2;
        if(completed >= 1) return 1;
        return 0;
    }

    //=============================================
    // VIEW FUNCTIONS
    //=============================================

    function getPassport(uint256 tokenId)
    external view returns (Passport memory)
    {
        if (!_exists(tokenId)) revert AgentDoesNotExist();
        
        Passport memory p = passports[tokenId];


    if (p.privacy == PrivacyLevel.PRIVATE) {
        return Passport({
            developer: address(0),
            niche: p.niche,
            grade: p.grade,
            generation: 0,
            birthBlock: 0,
            completedJobs: 0,
            failedJobs: 0,
            reputationScore: 0,
            privacy: p.privacy,
            restricted: p.restricted,
            restrictedUntil: 0,
            capability: ""
        });
}
    return p;
    }
    function isRestricted(uint256 tokenId)
    external view returns (bool)
    {
        if (!_exists(tokenId)) revert AgentDoesNotExist();
        return passports[tokenId].restricted;
    }

    function getGrade(uint256 tokenId)
    external view returns (uint8)
    {
        if (!_exists(tokenId)) revert AgentDoesNotExist();
        return passports[tokenId].grade;
    }

    function getDeveloperAgents(address developer)
    external view returns (uint256[] memory)
    {
        return developerAgents[developer];
    }

    function isVerifiedDeveloper(address developer)
    external view returns (bool)
    {
        return verifiedDevelopers[developer];
    }

    //=============================================
    // ADMIN FUNCTIONS
    //=============================================

    function setmintingFee(uint256 newFee) external onlyOwner {
        mintingFee = newFee;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidAddress();
        treasury = newTreasury;
    }

    function withdrawFee() external onlyOwner {
        uint256 balance = address(this).balance;
        payable(treasury).transfer(balance);
    }

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }

    //=============================================
    //SOUL BOUND - passports cannot be transferred
    //=============================================

    function _update( address to, uint256 tokenId, address auth)
    internal 
    override
    returns (address)
    {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            revert("Passport is soulbound - non transferable"); 
        }
        return super._update(to, tokenId, auth);
    }
}
