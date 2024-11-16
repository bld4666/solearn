// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC165Upgradeable.sol";
import {IERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ERC721PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721PausableUpgradeable.sol";
import {ERC721URIStorageUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import {IERC721MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/IERC721MetadataUpgradeable.sol";
import {EIP712Upgradeable, ECDSAUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IHybridModel} from "./interfaces/IHybridModel.sol";
import {IModel} from "./interfaces/IModel.sol";
import {IWorkerHub} from "./interfaces/IWorkerHub.sol";
import {TransferHelper} from "./lib/TransferHelper.sol";
import {SystemPromptManagerStorage} from "./storages/SystemPromptManagerStorage.sol";
import "hardhat/console.sol";

contract SystemPromptManager is
    SystemPromptManagerStorage,
    EIP712Upgradeable,
    ERC721EnumerableUpgradeable,
    ERC721PausableUpgradeable,
    ERC721URIStorageUpgradeable,
    OwnableUpgradeable
{
    string private constant VERSION = "v0.0.1";
    uint256 private constant PORTION_DENOMINATOR = 10000;

    receive() external payable {}

    modifier onlyManager() {
        if (msg.sender != owner() && !isManager[msg.sender])
            revert Unauthorized();
        _;
    }

    function initialize(
        string calldata _name,
        string calldata _symbol,
        uint256 _mintPrice,
        address _royaltyReceiver,
        uint16 _royaltyPortion,
        uint256 _nextTokenId,
        address _hybridModel,
        address _workerHub
    ) external initializer {
        require(
            _hybridModel != address(0) && _workerHub != address(0),
            "Zero address"
        );

        __ERC721_init(_name, _symbol);
        __ERC721Pausable_init();
        __Ownable_init();

        mintPrice = _mintPrice;
        royaltyReceiver = _royaltyReceiver;
        royaltyPortion = _royaltyPortion;
        nextTokenId = _nextTokenId;
        hybridModel = _hybridModel;
        workerHub = _workerHub;

        isManager[owner()] = true;
    }

    function version() external pure returns (string memory) {
        return VERSION;
    }

    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    function authorizeManager(address _account) external onlyOwner {
        if (isManager[_account]) revert Authorized();
        isManager[_account] = true;
        emit ManagerAuthorization(_account);
    }

    function deauthorizeManager(address _account) external onlyOwner {
        if (!isManager[_account]) revert Unauthorized();
        isManager[_account] = false;
        emit ManagerDeauthorization(_account);
    }

    function updateMintPrice(uint256 _mintPrice) external onlyOwner {
        mintPrice = _mintPrice;
        emit MintPriceUpdate(_mintPrice);
    }

    function updateRoyaltyReceiver(
        address _royaltyReceiver
    ) external onlyOwner {
        royaltyReceiver = _royaltyReceiver;
        emit RoyaltyReceiverUpdate(_royaltyReceiver);
    }

    function updateRoyaltyPortion(uint16 _royaltyPortion) external onlyOwner {
        royaltyPortion = _royaltyPortion;
        emit RoyaltyPortionUpdate(_royaltyPortion);
    }

    function mint_(
        address _to,
        string calldata _uri,
        bytes calldata _data,
        uint _fee,
        uint256 agentId
    ) internal returns (uint256) {
        if (_data.length == 0) revert InvalidNFTData();

        _safeMint(_to, agentId);
        _setTokenURI(agentId, _uri);

        datas[agentId].fee = _fee;
        datas[agentId].sysPrompts.push(_data);

        emit NewToken(agentId, _uri, _data, _fee, _to);

        return agentId;
    }

    function _wrapMint(
        address _to,
        string calldata _uri,
        bytes calldata _data,
        uint _fee,
        uint256 _squadId
    ) internal returns (uint256) {
        require(msg.value >= mintPrice, "Invalid minting fee");

        while (datas[nextTokenId].sysPrompts.length != 0) {
            nextTokenId++;
        }
        uint256 agentId = nextTokenId++;

        mint_(_to, _uri, _data, _fee, agentId);

        if (_squadId != 0) {
            require(_squadId <= currenSquadId, "Invalid squad id");
            _moveAgentToSquad(_convertUintToArray(agentId), _squadId);
        }

        return agentId;
    }

    function _convertUintToArray(
        uint256 num
    ) internal pure returns (uint256[] memory) {
        uint256[] memory newArray = new uint256[](1); // Create a new array with a size of 1
        newArray[0] = num; // Assign the uint256 value to the first element of the array
        return newArray;
    }

    /// @notice This function open minting role to public users
    function mint(
        address _to,
        string calldata _uri,
        bytes calldata _data,
        uint _fee
    ) external payable returns (uint256) {
        return _wrapMint(_to, _uri, _data, _fee, 0);
    }

    function mint(
        address _to,
        string calldata _uri,
        bytes calldata _data,
        uint _fee,
        uint256 _squadId
    ) external payable returns (uint256) {
        return _wrapMint(_to, _uri, _data, _fee, _squadId);
    }

    function withdraw(address _to, uint _value) external onlyOwner {
        (bool success, ) = _to.call{value: _value}("");
        if (!success) revert FailedTransfer();
    }

    function updateAgentURI(uint256 _agentId, string calldata _uri) external {
        require(msg.sender == _ownerOf(_agentId), "Invalid token owner");
        require(bytes(_uri).length != 0, "Invalid URI");

        _setTokenURI(_agentId, _uri);
        emit AgentURIUpdate(_agentId, _uri);
    }

    function updateAgentData(
        uint256 _agentId,
        bytes calldata _sysPrompt,
        uint256 _promptIdx
    ) external {
        require(_sysPrompt.length != 0, "Invalid system prompt input");
        require(msg.sender == _ownerOf(_agentId), "Invalid agent owner");
        uint256 len = datas[_agentId].sysPrompts.length;
        require(_promptIdx < len, "Invalid prompt index");

        emit AgentDataUpdate(
            _agentId,
            _promptIdx,
            datas[_agentId].sysPrompts[_promptIdx],
            _sysPrompt
        );

        datas[_agentId].sysPrompts[_promptIdx] = _sysPrompt;
    }

    function getHashToSign(
        uint256 _agentId,
        bytes calldata _sysPrompt,
        uint256 _promptIdx,
        uint256 _randomNonce
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _sysPrompt,
                _agentId,
                _promptIdx,
                _randomNonce,
                address(this),
                block.chainid
            )
        );

        return ECDSAUpgradeable.toEthSignedMessageHash(structHash);
    }

    function _hasUpdatePromptPermission(
        uint256 _agentId,
        bytes calldata _sysPrompt,
        uint256 _promptIdx,
        uint256 _randomNonce,
        bytes calldata _signature
    ) internal returns (bool) {
        address agentOwner = _ownerOf(_agentId);
        require(!signaturesUsed[agentOwner][_signature], "Signature used");

        bytes32 hash = getHashToSign(
            _agentId,
            _sysPrompt,
            _promptIdx,
            _randomNonce
        );
        address signer = ECDSAUpgradeable.recover(hash, _signature);
        require(signer == agentOwner, "Invalid signature");
        signaturesUsed[agentOwner][_signature] = true;

        return true;
    }

    function updateAgentDataWithSignature(
        uint256 _agentId,
        bytes calldata _sysPrompt,
        uint256 _promptIdx,
        uint256 _randomNonce,
        bytes calldata _signature
    ) external {
        require(_sysPrompt.length != 0, "Invalid system prompt input");
        require(
            _hasUpdatePromptPermission(
                _agentId,
                _sysPrompt,
                _promptIdx,
                _randomNonce,
                _signature
            ),
            "Invalid agent owner signature"
        );
        uint256 len = datas[_agentId].sysPrompts.length;
        require(_promptIdx < len, "Invalid prompt index");

        emit AgentDataUpdate(
            _agentId,
            _promptIdx,
            datas[_agentId].sysPrompts[_promptIdx],
            _sysPrompt
        );

        datas[_agentId].sysPrompts[_promptIdx] = _sysPrompt;
    }

    function getHashToSign(
        uint256 _agentId,
        string calldata _uri,
        uint256 _randomNonce
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _uri,
                _agentId,
                _randomNonce,
                address(this),
                block.chainid
            )
        );
        return ECDSAUpgradeable.toEthSignedMessageHash(structHash);
    }

    function _hasUpdateUriPermission(
        uint256 _agentId,
        string calldata _uri,
        uint256 _randomNonce,
        bytes calldata _signature
    ) internal returns (bool) {
        address agentOwner = _ownerOf(_agentId);
        require(!signaturesUsed[agentOwner][_signature], "Signature used");

        bytes32 hash = getHashToSign(_agentId, _uri, _randomNonce);
        address signer = ECDSAUpgradeable.recover(hash, _signature);

        require(signer == agentOwner, "Invalid signature");
        signaturesUsed[agentOwner][_signature] = true;

        return true;
    }

    function updateAgentUriWithSignature(
        uint256 _agentId,
        string calldata _uri,
        uint256 _randomNonce,
        bytes calldata _signature
    ) external {
        require(bytes(_uri).length != 0, "Invalid URI");
        require(
            _hasUpdateUriPermission(_agentId, _uri, _randomNonce, _signature),
            "Invalid agent owner signature"
        );

        _setTokenURI(_agentId, _uri);
        emit AgentURIUpdate(_agentId, _uri);
    }

    function addNewAgentData(
        uint256 _agentId,
        bytes calldata _sysPrompt
    ) external {
        require(_sysPrompt.length != 0, "Invalid data input");
        require(msg.sender == _ownerOf(_agentId), "Invalid token owner");

        datas[_agentId].sysPrompts.push(_sysPrompt);

        emit AgentDataAddNew(_agentId, datas[_agentId].sysPrompts);
    }

    function updateAgentFee(uint256 _agentId, uint _fee) external {
        require(msg.sender == _ownerOf(_agentId), "Invalid token owner");

        if (datas[_agentId].fee != _fee) {
            datas[_agentId].fee = _fee;
        }

        emit AgentFeeUpdate(_agentId, _fee);
    }

    function setHybridModel(address _hybridModel) external onlyOwner {
        hybridModel = _hybridModel;
    }

    function claimFee() external {
        uint256 totalFee = earnedFees[msg.sender];
        earnedFees[msg.sender] = 0;
        (bool success, ) = owner().call{value: totalFee}("");
        if (!success) revert FailedTransfer();

        emit FeesClaimed(msg.sender, totalFee);
    }

    function _concatSystemPrompts(
        uint256 _agentId
    ) internal virtual returns (bytes memory) {
        bytes[] memory sysPrompts = datas[_agentId].sysPrompts;
        uint256 len = sysPrompts.length;
        bytes memory concatedPrompt;

        for (uint256 i = 0; i < len; i++) {
            concatedPrompt = abi.encodePacked(
                concatedPrompt,
                sysPrompts[i],
                ";"
            );
        }

        return concatedPrompt;
    }

    function topUpPoolBalance(uint256 _agentId) external payable {
        poolBalance[_agentId] += msg.value;

        emit TopUpPoolBalance(_agentId, msg.sender, msg.value);
    }

    function getAgentFee(uint256 _agentId) external view returns (uint256) {
        return datas[_agentId].fee;
    }

    function getAgentSystemPrompt(
        uint256 _agentId
    ) external view returns (bytes[] memory) {
        return datas[_agentId].sysPrompts;
    }

    function infer(
        uint256 _agentId,
        bytes calldata _calldata,
        string calldata _externalData,
        bool _flag
    ) external payable {
        (uint256 estFeeWH, bytes memory fwdData) = _infer(_agentId, _calldata);

        uint256 inferId = IHybridModel(hybridModel).infer{value: estFeeWH}(
            fwdData,
            msg.sender,
            _flag
        );

        emit InferencePerformed(
            _agentId,
            msg.sender,
            fwdData,
            datas[_agentId].fee,
            _externalData,
            inferId
        );
    }

    function infer(
        uint256 _agentId,
        bytes calldata _calldata,
        string calldata _externalData
    ) external payable {
        (uint256 estFeeWH, bytes memory fwdData) = _infer(_agentId, _calldata);

        uint256 inferId = IHybridModel(hybridModel).infer{value: estFeeWH}(
            fwdData,
            msg.sender
        );

        emit InferencePerformed(
            _agentId,
            msg.sender,
            fwdData,
            datas[_agentId].fee,
            _externalData,
            inferId
        );
    }

    function _infer(
        uint256 _agentId,
        bytes calldata _calldata
    ) internal returns (uint256, bytes memory) {
        require(
            datas[_agentId].sysPrompts.length != 0,
            "Invalid system prompt"
        );
        require(msg.value >= datas[_agentId].fee, "Invalid fee");

        bytes memory fwdData = abi.encodePacked(
            _concatSystemPrompts(_agentId),
            _calldata
        );
        uint256 estFeeWH = IWorkerHub(workerHub).getMinFeeToUse(hybridModel);

        if (msg.value < estFeeWH && poolBalance[_agentId] >= estFeeWH) {
            unchecked {
                poolBalance[_agentId] -= estFeeWH;
            }

            if (msg.value > 0) {
                TransferHelper.safeTransferNative(
                    _ownerOf(_agentId),
                    msg.value
                );
            }
        } else if (msg.value >= estFeeWH) {
            uint256 remain = msg.value - estFeeWH;
            if (remain > 0) {
                TransferHelper.safeTransferNative(_ownerOf(_agentId), remain);
            }
        } else {
            revert("Insufficient funds");
        }

        return (estFeeWH, fwdData);
    }

    function dataOf(
        uint256 _agentId
    ) external view returns (TokenMetaData memory) {
        return datas[_agentId];
    }

    function royaltyInfo(
        uint256 _agentId,
        uint256 _salePrice
    ) external view returns (address, uint256) {
        _agentId;
        return (
            royaltyReceiver,
            (_salePrice * royaltyPortion) / PORTION_DENOMINATOR
        );
    }

    function tokenURI(
        uint256 _agentId
    )
        public
        view
        override(
            ERC721Upgradeable,
            ERC721URIStorageUpgradeable,
            IERC721MetadataUpgradeable
        )
        returns (string memory)
    {
        return super.tokenURI(_agentId);
    }

    function supportsInterface(
        bytes4 _interfaceId
    )
        public
        view
        override(
            ERC721Upgradeable,
            ERC721EnumerableUpgradeable,
            ERC721URIStorageUpgradeable,
            IERC165Upgradeable
        )
        returns (bool)
    {
        return
            _interfaceId == type(IERC2981Upgradeable).interfaceId ||
            super.supportsInterface(_interfaceId);
    }

    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256 _agentId,
        uint256 _batchSize
    )
        internal
        override(
            ERC721Upgradeable,
            ERC721EnumerableUpgradeable,
            ERC721PausableUpgradeable
        )
    {
        super._beforeTokenTransfer(_from, _to, _agentId, _batchSize);
    }

    function _burn(
        uint256 _agentId
    ) internal override(ERC721Upgradeable, ERC721URIStorageUpgradeable) {
        super._burn(_agentId);
    }

    function totalSquad() external view returns (uint256) {
        return _allSquads.length;
    }

    function inscreaseIterator(uint256 i) private pure returns (uint256) {
        unchecked {
            return i + 1;
        }
    }

    function _moveAgentToSquad(
        uint256[] memory _agentIds,
        uint256 _toSquadId
    ) private {
        uint256 len = _agentIds.length;

        require(
            msg.sender == squadInfo[_toSquadId].owner,
            "Invalid squad owner"
        );
        require(
            _toSquadId <= currenSquadId && _toSquadId > 0,
            "Invalid squad id"
        );

        for (uint256 i = 0; i < len; inscreaseIterator(i)) {
            require(
                _ownerOf(_agentIds[i]) == msg.sender,
                "Invalid agent owner"
            );
            require(_agentIds[i] < nextTokenId, "Invalid agent id");

            uint256 fromSquad = agentToSquadId[_agentIds[i]];
            agentToSquadId[_agentIds[i]] = _toSquadId;

            if (fromSquad != _toSquadId) {
                if (fromSquad != 0) {
                    squadInfo[fromSquad].numAgents--;
                }
                squadInfo[_toSquadId].numAgents++;
            }
        }
    }

    function moveAgentToSquad(
        uint256[] calldata _agentIds,
        uint256 _toSquadId
    ) external {
        _moveAgentToSquad(_agentIds, _toSquadId);

        emit SquadUpdated(_toSquadId, msg.sender, _agentIds);
    }

    function createSquad(uint256[] calldata _agentIds) external {
        uint256 squadId = ++currenSquadId;
        squadInfo[squadId].owner = msg.sender;
        squadBalance[msg.sender]++;

        _moveAgentToSquad(_agentIds, squadId);

        _addSquadToAllSquadsEnumeration(squadId);
        _addSquadToOwnerEnumeration(msg.sender, squadId);

        emit SquadCreated(squadId, msg.sender, _agentIds);
    }

    function _addSquadToOwnerEnumeration(address to, uint256 squadId) private {
        uint256 length = squadBalance[to];
        ownedSquads[to][length] = squadId;
        ownedSquadsIndex[squadId] = length;
    }

    function _addSquadToAllSquadsEnumeration(uint256 squadId) private {
        _allSquadsIndex[squadId] = _allSquads.length;
        _allSquads.push(squadId);
    }

    function _removeSquadFromOwnerEnumeration(
        address from,
        uint256 squadId
    ) private {
        uint256 lastSquadIndex = squadBalance[from] - 1;
        uint256 squadIndex = ownedSquadsIndex[squadId];

        if (squadIndex != lastSquadIndex) {
            uint256 lastSquadId = ownedSquads[from][lastSquadIndex];
            ownedSquads[from][squadIndex] = lastSquadId;
            ownedSquadsIndex[lastSquadId] = squadIndex;
        }

        delete ownedSquadsIndex[squadId];
        delete ownedSquads[from][lastSquadIndex];
    }

    function _removeSquadFromAllSquadsEnumeration(uint256 squadId) private {
        uint256 lastSquadIndex = _allSquads.length - 1;
        uint256 squadIndex = _allSquadsIndex[squadId];

        uint256 lastSquadId = _allSquads[lastSquadIndex];

        _allSquads[squadIndex] = lastSquadId;
        _allSquadsIndex[lastSquadId] = squadIndex;

        delete _allSquadsIndex[squadId];
        _allSquads.pop();
    }
}
