// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import {Random} from "./lib/Random.sol";
import {Set} from "./lib/Set.sol";
import {TransferHelper} from "./lib/TransferHelper.sol";

import {WorkerHubStorage} from "./storages/WorkerHubStorage.sol";

contract WorkerHub is
WorkerHubStorage,
OwnableUpgradeable,
PausableUpgradeable,
ReentrancyGuardUpgradeable {
    using Random for Random.Randomizer;
    using Set for Set.AddressSet;
    using Set for Set.Uint256Set;

    string constant private VERSION = "v0.0.1";
    uint256 constant private PERCENTAGE_DENOMINATOR = 100_00;

    receive() external payable {}

    function initialize(
        address _treasury,
        uint16 _feePercentage,
        uint256 _minnerMinimumStake,
        uint256 _validatorMinimumStake,
        uint40 _miningTimeLimit,
        uint8 _minnerRequirement,
        uint256 _blocksPerEpoch,
        uint256 _rewardPerEpochBasedOnPerf,
        uint40 _unstakeDelayTime
    ) external initializer {
        __Ownable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        treasury = _treasury;
        feePercentage = _feePercentage;
        minnerMinimumStake = _minnerMinimumStake;
        validatorMinimumStake = _validatorMinimumStake;
        miningTimeLimit = _miningTimeLimit;
        minnerRequirement = _minnerRequirement;
        blocksPerEpoch = _blocksPerEpoch;
        rewardPerEpochBasedOnPerf = _rewardPerEpochBasedOnPerf;
        unstakeDelayTime = _unstakeDelayTime;
        maximumTier = 1;
        lastBlock = block.number;
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

    function getModelAddresses() external view returns (address[] memory) {
        return modelAddresses.values;
    }

    function getMiningAssignments() external view returns (AssignmentInfo[] memory) {
        uint256[] memory assignmentIds = assignmentsByMinner[msg.sender].values;
        uint256 assignmentNumber = assignmentIds.length;

        uint256 counter = 0;
        for (uint256 i = 0; i < assignmentNumber; ++i)
            if (isAssignmentPending(assignmentIds[i])) counter++;

        counter = 0;
        AssignmentInfo[] memory result = new AssignmentInfo[](counter);
        for (uint256 i = 0; i < assignmentNumber; ++i)
            if (isAssignmentPending(assignmentIds[i])) {
                Assignment storage assignment = assignments[assignmentIds[i]];
                Inference storage inference = inferences[assignment.inferenceId];
                result[counter++] = AssignmentInfo(
                    assignmentIds[i],
                    assignment.inferenceId,
                    inference.value,
                    inference.input,
                    inference.modelAddress,
                    inference.creator,
                    inference.expiredAt
                );
            }

        return result;
    }

    function getMinnerAddresses() external view returns (address[] memory) {
        return minnerAddresses.values;
    }

    function getMinners() external view returns (WorkerInfo[] memory) {
        address[] memory addresses = minnerAddresses.values;
        uint256 minnerNumber = addresses.length;
        WorkerInfo[] memory result = new WorkerInfo[](minnerNumber);
        for (uint256 i = 0; i < minnerNumber; ++i) {
            Worker memory minner = minners[addresses[i]];
            result[i] = WorkerInfo(
                addresses[i],
                minner.stake,
                minner.commitment,
                minner.modelAddress,
                minner.lastClaimedEpoch,
                minner.activeTime,
                minner.tier
            );
        }
        return result;
    }

    function getValidatorAddresses() external view returns (address[] memory) {
        return validatorAddresses.values;
    }

    function getValidators() external view returns (WorkerInfo[] memory) {
        address[] memory addresses = validatorAddresses.values;
        uint256 validatorNumber = addresses.length;
        WorkerInfo[] memory result = new WorkerInfo[](validatorNumber);
        for (uint256 i = 0; i < validatorNumber; ++i) {
            Worker memory validator = validators[addresses[i]];
            result[i] = WorkerInfo(
                addresses[i],
                validator.stake,
                validator.commitment,
                validator.modelAddress,
                validator.lastClaimedEpoch,
                validator.activeTime,
                validator.tier
            );
        }
        return result;
    }

    function isAssignmentPending(uint256 _assignmentId) public view returns (bool) {
        return assignments[_assignmentId].output.length == 0
            && block.timestamp < inferences[assignments[_assignmentId].inferenceId].expiredAt;
    }

    function getInferences(uint256[] calldata _inferenceIds) external view returns (InferenceInfo[] memory) {
        uint256 inferenceNumber = _inferenceIds.length;
        InferenceInfo[] memory result = new InferenceInfo[](inferenceNumber);
        for (uint256 i = 0; i < inferenceNumber; ++i) {
            Inference storage inference = inferences[_inferenceIds[i]];
            result[i] = InferenceInfo(
                _inferenceIds[i],
                inference.input,
                inference.status == InferenceStatus.Solved
                    ? assignments[inference.assignments[inference.firstSubmissionId]].output
                    : bytes(""),
                inference.value,
                inference.disputingAddress,
                inference.modelAddress,
                inference.expiredAt,
                inference.status,
                inference.creator
            );
        }
        return result;
    }

    function registerModel(address _model, uint16 _tier, uint256 _minimumFee) external onlyOwner {
        _updateEpoch();

        Model storage model = models[_model];
        if (model.tier != 0) revert AlreadyRegistered();

        model.minimumFee = _minimumFee;
        model.tier = _tier;
        modelAddresses.insert(_model);

        emit ModelRegistration(_model, _tier, _minimumFee);
    }

    function unregisterModel(address _model) external onlyOwner {
        _updateEpoch();

        Model storage model = models[_model];
        if (model.tier == 0) revert NotRegistered();

        model.tier = 0;
        modelAddresses.erase(_model);

        emit ModelUnregistration(_model);
    }

    function registerMinner(uint16 tier) external payable whenNotPaused {
        _updateEpoch();

        if (tier == 0 || tier > maximumTier) revert InvalidTier();
        if (msg.value < minnerMinimumStake) revert StakeTooLow();

        Worker storage minner = minners[msg.sender];
        if (minner.tier != 0) revert AlreadyRegistered();

        minner.stake = msg.value;
        minner.tier = tier;
        minner.lastClaimedEpoch = currentEpoch;

        address modelAddress = modelAddresses.values[randomizer.randomUint256() % modelAddresses.size()];
        minner.modelAddress = modelAddress;
        minnerAddressesByModel[modelAddress].insert(msg.sender);

        minnerAddresses.insert(msg.sender);

        emit MinnerRegistration(msg.sender, tier, msg.value);
    }

    function unregisterMinner() external nonReentrant {
        _updateEpoch();

        Worker storage minner = minners[msg.sender];
        if (minner.tier == 0) revert NotRegistered();

        minner.tier = 0;

        TransferHelper.safeTransferNative(msg.sender, minner.stake);
        minner.stake = 0;
        minner.commitment = 0;

        minnerAddresses.erase(msg.sender);
        minnerAddressesByModel[minner.modelAddress].erase(msg.sender);
        minner.modelAddress = address(0);

        minnerUnstakeRequests[msg.sender] = UnstakeRequest(
            minner.stake,
            uint40(block.timestamp + unstakeDelayTime)
        );

        _claimReward(msg.sender);

        emit MinnerUnregistration(msg.sender);
    }

    function increaseMinnerStake() external payable whenNotPaused {
        _updateEpoch();

        Worker storage minner = minners[msg.sender];
        if (minner.tier == 0) revert NotRegistered();

        minner.stake += msg.value;

        emit MinnerExtraStake(msg.sender, msg.value);
    }

    function unstakeForMinner() external {
        _updateEpoch();

        UnstakeRequest storage unstakeRequest = minnerUnstakeRequests[msg.sender];
        if (block.timestamp < unstakeRequest.unlockAt) revert StillBeingLocked();

        uint256 stake = unstakeRequest.stake;
        if (stake == 0) revert NullStake();
        TransferHelper.safeTransferNative(msg.sender, stake);

        emit MinnerUnstake(msg.sender, stake);
    }

    function registerValidator(uint16 tier) external payable whenNotPaused {
        _updateEpoch();

        if (tier == 0 || tier > maximumTier) revert InvalidTier();
        if (msg.value < validatorMinimumStake) revert StakeTooLow();

        Worker storage validator = validators[msg.sender];
        if (validator.tier != 0) revert AlreadyRegistered();

        validator.stake = msg.value;
        validator.tier = tier;
        validator.lastClaimedEpoch = currentEpoch;

        address modelAddress = modelAddresses.values[randomizer.randomUint256() % modelAddresses.size()];
        validator.modelAddress = modelAddress;
        validatorAddressesByModel[modelAddress].insert(msg.sender);

        validatorAddresses.insert(msg.sender);

        emit ValidatorRegistration(msg.sender, tier, msg.value);
    }

    function unregisterValidator() external nonReentrant {
        _updateEpoch();

        Worker storage validator = validators[msg.sender];
        if (validator.tier == 0) revert NotRegistered();

        validator.tier = 0;

        TransferHelper.safeTransferNative(msg.sender, validator.stake);
        validator.stake = 0;
        validator.commitment = 0;

        validatorAddresses.erase(msg.sender);
        validatorAddressesByModel[validator.modelAddress].erase(msg.sender);
        validator.modelAddress = address(0);

        validatorUnstakeRequests[msg.sender] = UnstakeRequest(
            validator.stake,
            uint40(block.timestamp + unstakeDelayTime)
        );

        emit ValidatorUnregistration(msg.sender);
    }

    function increaseValidatorStake() external payable whenNotPaused {
        _updateEpoch();

        Worker storage validator = validators[msg.sender];
        if (validator.tier == 0) revert NotRegistered();

        validator.stake += msg.value;

        emit ValidatorExtraStake(msg.sender, msg.value);
    }

    function unstakeForValidator() external {
        _updateEpoch();

        UnstakeRequest storage unstakeRequest = validatorUnstakeRequests[msg.sender];
        if (block.timestamp < unstakeRequest.unlockAt) revert StillBeingLocked();

        uint256 stake = unstakeRequest.stake;
        if (stake == 0) revert NullStake();
        TransferHelper.safeTransferNative(msg.sender, stake);

        emit ValidatorUnstake(msg.sender, stake);
    }

    function infer(bytes calldata _input, address _creator) external payable whenNotPaused returns (uint256) {
        Model storage model = models[msg.sender];
        if (model.tier == 0) revert Unauthorized();
        if (msg.value < model.minimumFee) revert FeeTooLow();
        uint256 inferenceId = ++inferenceNumber;
        Inference storage inference = inferences[inferenceId];

        uint256 fee = msg.value * feePercentage / PERCENTAGE_DENOMINATOR;
        uint256 value = msg.value - fee;

        inference.input = _input;
        inference.value = value;
        inference.creator = _creator;
        inference.modelAddress = msg.sender;

        TransferHelper.safeTransferNative(treasury, fee);

        emit NewInference(inferenceId, _creator, value);

        _assignMinners(inferenceId);

        return inferenceId;
    }

    function _assignMinners(uint256 _inferenceId) private {
        uint40 expiredAt = uint40(block.timestamp + miningTimeLimit);
        inferences[_inferenceId].expiredAt = expiredAt;
        inferences[_inferenceId].status = InferenceStatus.Solving;

        address model = inferences[_inferenceId].modelAddress;

        Set.AddressSet storage minners = minnerAddressesByModel[model];
        uint256 n = minnerRequirement;
        address[] memory selectedMinners = new address[](n);

        for (uint256 i = 0; i < n; ++i) {
            address minner = minners.values[randomizer.randomUint256() % minners.size()];
            minners.erase(minner);
            uint256 assignmentId = ++assignmentNumber;
            assignments[assignmentId].inferenceId = _inferenceId;
            assignments[assignmentId].worker = minner;
            selectedMinners[i] = minner;
            assignmentsByMinner[msg.sender].insert(assignmentId);
            assignmentsByInference[_inferenceId].insert(assignmentId);
            emit NewAssignment(assignmentId, _inferenceId, minner, expiredAt);
        }

        for (uint256 i = 0; i < n; ++i) minners.insert(selectedMinners[i]);
    }

    // this internal function update new epoch
    function _updateEpoch() internal {
        if (blocksPerEpoch > 0) {
            uint256 epochPassed = (block.number - lastBlock) / blocksPerEpoch;
            if (epochPassed > 0) {
                for (; epochPassed > 0; epochPassed--) {
                    rewardInEpoch[currentEpoch].totalMinner = minnerAddresses.size();
                    currentEpoch++;
                    rewardInEpoch[currentEpoch].perfReward = rewardPerEpochBasedOnPerf;
                    rewardInEpoch[currentEpoch].epochReward = rewardPerEpoch;
                }
                lastBlock = block.number;
            }
        } else {
            lastBlock = block.number;
        }
    }


    function submitSolution(uint256 _assigmentId, bytes calldata _data) public virtual whenNotPaused {
        _updateEpoch();
        address _msgSender = msg.sender;

        Assignment memory clonedAssignments = assignments[_assigmentId];

        if (_msgSender != clonedAssignments.worker) revert Unauthorized();
        if (clonedAssignments.output.length != 0) revert AlreadySubmitted();

        Inference memory clonedInference = inferences[clonedAssignments.inferenceId];

        if (clonedInference.expiredAt < block.timestamp) {
            if (clonedInference.assignments.length == 0) {
                _assignMinners(clonedAssignments.inferenceId);
                return;
            } else {
                revert("Expire time");
            }
        }

        Inference storage inference = inferences[clonedAssignments.inferenceId];

        assignments[_assigmentId].output = _data; //Record the solution
        inference.status = InferenceStatus.Solved;
        inference.assignments.push(_assigmentId);

        if (inference.assignments.length == 1) {
            uint256 curEpoch = currentEpoch;
            minnerTaskCompleted[_msgSender][curEpoch] += 1;
            rewardInEpoch[curEpoch].totalTaskCompleted += 1;
            TransferHelper.safeTransferNative(_msgSender, clonedInference.value);
        }

        emit SolutionSubmission(_msgSender, _assigmentId);
    }

    function _handleDisputeSuccess(uint256 _inferId) internal {
        // TODO
    }


    function disputeInfer(uint256 _assignmentId) public virtual {
        // TODO
    }

    function resolveInference(uint256 _inferenceId) public virtual {
        _updateEpoch();

        Inference storage inference = inferences[_inferenceId];
        if (inference.status == InferenceStatus.Solving && block.timestamp > inference.expiredAt) {
            uint256[] storage assignmentIds = assignmentsByInference[_inferenceId].values;
            uint256 assignmentNumber = assignmentIds.length;
            for (uint256 i = 0; i < assignmentNumber; ++i) {
                assignments[assignmentIds[i]].worker = address(0);
            }
            _assignMinners(_inferenceId);
        }
    }

    function _claimReward(address _minner) internal whenNotPaused {
        uint256 rewardAmount = rewardToClaim(_minner);
        minners[_minner].lastClaimedEpoch = currentEpoch;
        if (rewardAmount > 0) {
            TransferHelper.safeTransferNative(_minner, rewardAmount);

            emit RewardClaim(_minner, rewardAmount);
        }
    }

    // minner claim reward
    function claimReward(address _minner) public virtual nonReentrant {
        _claimReward(_minner);
    }

    // @dev admin functions
    function setNewRewardInEpoch(uint256 _newRewardAmount) public virtual onlyOwner {
        _updateEpoch();
        emit RewardPerEpoch(rewardPerEpoch, _newRewardAmount);

        rewardPerEpoch = _newRewardAmount;
    }

    function setNewRewardInEpochBasedOnPerf(uint256 _newRewardAmount) public virtual onlyOwner {
        _updateEpoch();
        emit RewardPerEpochBasedOnPerf(rewardPerEpoch, _newRewardAmount);

        rewardPerEpochBasedOnPerf = _newRewardAmount;
    }

    function setBlocksPerEpoch(uint256 _blocks) public virtual onlyOwner {
        _updateEpoch();
        if (_blocks == 0) revert InvalidBlockValue();

        emit BlocksPerEpoch(blocksPerEpoch, _blocks);

        blocksPerEpoch = _blocks;
    }

    // sum reward of an minner since last claimed epoch
    function rewardToClaim(address _minner) public virtual returns(uint256) {
        _updateEpoch();

        uint256 totalReward;
        uint256 lastEpoch = currentEpoch;
        if (minners[_minner].stake <= 0 || lastEpoch <= minners[_minner].lastClaimedEpoch) {
            totalReward = 0;
        } else {
            uint256 lastClaimed = uint256(minners[_minner].lastClaimedEpoch);
            uint256 perfReward;
            uint256 epochReward;
            uint256 currentMinner;
            for (; lastClaimed < lastEpoch; lastClaimed++) {
                MinnerEpochState memory state = rewardInEpoch[lastClaimed];
                uint256 totalTaskCompleted = state.totalTaskCompleted;
                // reward at epoch
                (perfReward, epochReward, currentMinner) = (state.perfReward, state.epochReward, state.totalMinner);
                if (totalTaskCompleted > 0 && perfReward > 0) {
                    totalReward += perfReward * minnerTaskCompleted[_minner][lastClaimed] / totalTaskCompleted;
                }

                if (currentMinner > 0 && epochReward > 0) {
                    totalReward += epochReward / currentMinner;
                }
            }
        }

        return totalReward;
    }
}
