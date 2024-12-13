// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {TransferHelper} from "./lib/TransferHelper.sol";
import {PromptSchedulerStorage, Set} from "./storages/PromptSchedulerStorage.sol";
import {IStakingHub} from "./interfaces/IStakingHub.sol";

contract PromptScheduler is
    PromptSchedulerStorage,
    Ownable,
    Pausable,
    ReentrancyGuard
{
    using Set for Set.Uint256Set;

    string private constant VERSION = "v0.0.2";
    uint256 internal constant PERCENTAGE_DENOMINATOR = 100_00;
    uint256 private constant BLOCK_PER_YEAR = 365 days / 2; // 2s per block

    receive() external payable {}

    constructor(
        address wEAI_,
        address stakingHub_,
        uint8 minerRequirement_,
        uint40 submitDuration_,
        uint16 feeRatioMinerValidator_,
        uint40 batchPeriod_
    ) {
        if (stakingHub_ == address(0) || wEAI_ == address(0))
            revert InvalidAddress();
        if (batchPeriod_ == 0) revert InvalidValue();

        _wEAI = wEAI_;
        _stakingHub = stakingHub_;
        _feeRatioMinerValidator = feeRatioMinerValidator_;
        _minerRequirement = minerRequirement_;
        _submitDuration = submitDuration_;
        _lastBatchTimestamp = block.timestamp;
        _batchPeriod = batchPeriod_;
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

    function setWEAIAddress(address wEAI) external onlyOwner {
        if (wEAI == address(0)) revert InvalidAddress();
        _wEAI = wEAI;
    }

    function infer(
        uint32 modelId,
        bytes calldata input,
        address creator,
        bool flag
    ) external whenNotPaused returns (uint64) {
        return _infer(modelId, input, creator, flag);
    }

    function infer(
        uint32 modelId,
        bytes calldata input,
        address creator
    ) external whenNotPaused returns (uint64) {
        return _infer(modelId, input, creator, false);
    }

    function _infer(
        uint32 modelId,
        bytes calldata input,
        address creator,
        bool flag
    ) internal virtual returns (uint64) {
        (address miner, uint256 modelFee) = IStakingHub(_stakingHub)
            .validateModelAndChooseRandomMiner(modelId, _minerRequirement);

        uint64 inferId = ++_inferenceNumber;
        Inference storage inference = _inferences[inferId];
        uint32 lModelId = modelId;

        inference.value = modelFee;
        inference.modelId = lModelId;
        inference.creator = creator;
        inference.input = input;

        _assignMiners(inferId, lModelId, miner);

        // transfer model fee (fee to use model) to staking hub
        TransferHelper.safeTransferFrom(
            _wEAI,
            msg.sender,
            address(this),
            modelFee
        );

        emit NewInference(inferId, creator, lModelId, modelFee, input, flag);

        return inferId;
    }

    function _assignMiners(
        uint64 inferId,
        uint32 modelId,
        address miner
    ) internal {
        uint40 expiredAt = uint40(block.number + _submitDuration);
        _inferences[inferId].submitTimeout = expiredAt;
        _inferences[inferId].status = InferenceStatus.Solving;
        _inferences[inferId].processedMiner = miner;
        _inferencesByMiner[miner].insert(inferId);

        emit NewAssignment(inferId, miner, expiredAt);

        // append to batch
        uint64 batchId = uint64(
            (block.timestamp - _lastBatchTimestamp) / _batchPeriod
        );
        uint64[] storage inferIds = _batchInfos[modelId][batchId].inferIds;
        inferIds.push(inferId);

        emit AppendToBatch(batchId, modelId, inferId);
    }

    function _validateSolution(bytes calldata data) internal pure virtual {
        if (data.length == 0) revert InvalidData();
    }

    function _validateInference(uint64 inferId) internal view virtual {
        // Check the msg sender is the assigned miner
        if (msg.sender != _inferences[inferId].processedMiner)
            revert OnlyAssignedWorker();

        if (uint40(block.number) > _inferences[inferId].submitTimeout)
            revert SubmitTimeout();

        if (_inferences[inferId].status != InferenceStatus.Solving) {
            revert InvalidInferenceStatus();
        }

        if (_inferences[inferId].output.length != 0) revert AlreadySubmitted();
    }

    function submitSolution(
        uint64 inferId,
        bytes calldata solution
    ) external virtual whenNotPaused {
        _validateSolution(solution);
        _validateInference(inferId);

        // Check whether the miner is available (the miner has previously joined).
        // An inactive miner or one that does not belong to the correct model is not allowed to submit a solution.
        IStakingHub(_stakingHub).validateMiner(msg.sender);

        Inference storage inference = _inferences[inferId];
        inference.output = solution; //Record the solution
        inference.status = InferenceStatus.Commit;

        // transfer fee to miner
        uint256 minerFee = (inference.value * _feeRatioMinerValidator) /
            PERCENTAGE_DENOMINATOR;
        TransferHelper.safeTransfer(_wEAI, msg.sender, minerFee);

        // calculate accumulated fee for validators
        uint64 currentBatchId = uint64(
            (block.timestamp - _lastBatchTimestamp) / _batchPeriod
        );
        uint32 modelId = inference.modelId;
        if (inferId < _batchInfos[modelId][currentBatchId].inferIds[0]) {
            currentBatchId--;
        }

        _batchInfos[modelId][currentBatchId].validatorFee +=
            inference.value -
            minerFee;

        emit InferenceStatusUpdate(inferId, InferenceStatus.Commit);
        emit SolutionSubmission(msg.sender, inferId);
    }

    function getInferenceInfo(
        uint64 inferId
    ) external view returns (Inference memory) {
        return _inferences[inferId];
    }

    function getInferenceByMiner(
        address miner
    ) external view returns (uint256[] memory) {
        return _inferencesByMiner[miner].values;
    }
}
