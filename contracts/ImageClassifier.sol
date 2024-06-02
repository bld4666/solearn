// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./thirdparty/solidity-stringutils/strings.sol";
import "./lib/layers/Layers.sol";
import "./lib/Utils.sol";
import { IModelRegPublic } from "./interfaces/IModelReg.sol";
import { IImageClassifier } from "./interfaces/IImageClassifier.sol";
import { IOnchainModel } from "./interfaces/IOnchainModel.sol";
// import "hardhat/console.sol";

error NotTokenOwner();
error InsufficientMintPrice();
error InsufficientEvalPrice();
error TransferFailed();
error UnknownTokenNotInVocabs();
error IncorrectModelId();
error NotModelRegistry();
error IncorrectInputLayerType();

contract ImageClassifier is IImageClassifier, Ownable {
    using Layers for Layers.RescaleLayer;
    using Layers for Layers.FlattenLayer;
    using Layers for Layers.DenseLayer;
    using Layers for Layers.MaxPooling2DLayer;
    using Layers for Layers.Conv2DLayer;
    using Tensor1DMethods for Tensors.Tensor1D;

    Model public model;
    address public modelInterface;

    function getInfo()
        public
        view
        returns (
            uint256[3] memory,
            string memory,
            string[] memory,
            Info[] memory
        )
    {
        return (
            model.input[0].inputDim,
            model.modelName,
            model.classesName,
            model.layers
        );
    }

    function getDenseLayer(
        uint256 layerIdx
    )
        public
        view
        returns (
            uint256 dim_in,
            uint256 dim_out,
            Float32x32[][] memory w,
            Float32x32[] memory b
        )
    {
        Layers.DenseLayer memory layer = model.dense[layerIdx];
        dim_in = layer.w.n;
        dim_out = layer.w.m;
        w = layer.w.mat;
        b = layer.b.mat;
    }

    function getConv2DLayer(
        uint256 layerIdx
    )
        public
        view
        returns (
            uint256 n,
            uint256 m,
            uint256 p,
            uint256 q,
            Float32x32[][][][] memory w,
            Float32x32[] memory b
        )
    {
        Layers.Conv2DLayer memory layer = model.conv2D[layerIdx];
        n = layer.w.n;
        m = layer.w.m;
        p = layer.w.p;
        q = layer.w.q;
        w = layer.w.mat;
        b = layer.b.mat;
    }

    function forward(Float32x32[][][] memory x1) public returns (Float32x32[] memory) {
        Float32x32[] memory x2;
        for (uint256 i = 0; i < model.layers.length; i++) {
            Info memory layerInfo = model.layers[i];
            if (layerInfo.layerType == Layers.LayerType.Rescale) {
                x1 = model.rescale[layerInfo.layerIndex].forward(x1);
            } else if (layerInfo.layerType == Layers.LayerType.Flatten) {
                x2 = model.flatten[layerInfo.layerIndex].forward(x1);
            } else if (layerInfo.layerType == Layers.LayerType.Dense) {
                x2 = model.dense[layerInfo.layerIndex].forward(x2);
            } else if (layerInfo.layerType == Layers.LayerType.MaxPooling2D) {
                x1 = model.maxPooling2D[layerInfo.layerIndex].forward(x1);
            } else if (layerInfo.layerType == Layers.LayerType.Conv2D) {
                x1 = model.conv2D[layerInfo.layerIndex].forward(x1);
            }

            // the last layer
            if (i == model.layers.length - 1) {
                Tensors.Tensor1D memory xt = Tensor1DMethods.from(x2);
                Float32x32[] memory result = xt.softmax().mat;
                return result;
            }
        }
        return x2;
    }

    function classifyImage(Float32x32[][][] memory image) internal returns (string memory, Float32x32) {
        Float32x32[] memory r2 = forward(image);
        uint256 maxInd = 0;
        for (uint256 i = 1; i < r2.length; i++) {
            if (r2[i].gt(r2[maxInd])) {
                maxInd = i;
            }
        }
        return (model.classesName[maxInd], r2[maxInd]);
    }

    function infer(bytes calldata _data) external returns (bytes memory) {
        if (msg.sender != modelInterface) revert Unauthorized();

        Float32x32[][][] memory image = abi.decode(_data, (Float32x32[][][]));
        (string memory className, Float32x32 confidence) = classifyImage(image);
        return abi.encode(className, confidence);
    }
    
    function setClassesName(
        string[] memory classesName
    ) external onlyOwner {
        model.classesName = classesName;
    }

    function setOnchainModel(
        bytes[] calldata layersConfig
    ) external onlyOwner {
        if (model.layers.length > 0) {
            delete model.input;
            delete model.dense;
            delete model.flatten;
            delete model.rescale;
            delete model.conv2D;
            delete model.maxPooling2D;
            delete model.layers;
        }

        model.requiredWeights = 0;
        model.appendedWeights = 0;
        uint256[] memory dim;
        for (uint256 i = 0; i < layersConfig.length; i++) {
            dim = makeLayer(
                Layers.SingleLayerConfig(layersConfig[i], i),
                dim
            );
        }
    }

    function isReady() external view returns (bool) {
        return model.appendedWeights == model.requiredWeights;
    }

    function appendWeights(
        Float32x32[] memory weights,
        uint256 layerInd,
        Layers.LayerType layerType
    ) external onlyOwner {
        uint appendedWeights;
        if (layerType == Layers.LayerType.Dense) {
            appendedWeights = model.dense[layerInd].appendWeights(weights);
        } else if (layerType == Layers.LayerType.Conv2D) {
            appendedWeights = model.conv2D[layerInd].appendWeights(weights);
        }
        model.appendedWeights += appendedWeights;
    }

    function makeLayer(
        Layers.SingleLayerConfig memory slc,
        uint256[] memory dim
    ) internal returns (uint256[] memory) {
        uint8 layerType = abi.decode(slc.conf, (uint8));
        if (layerType == uint8(Layers.LayerType.Input)) {
            (, uint8 inputType) = abi.decode(slc.conf, (uint8, uint8));
            if (inputType != uint8(Layers.InputType.Image)) {
                revert IncorrectInputLayerType();
            }
            (Layers.InputImageLayer memory layer, uint[] memory out_dim) = Layers
                .makeInputImageLayer(slc);
            model.input.push(layer);
            model.layers.push(Info(Layers.LayerType.Input, model.input.length - 1));
            dim = out_dim;
        } else if (layerType == uint8(Layers.LayerType.Dense)) {
            (Layers.DenseLayer memory layer, uint[] memory out_dim, uint weights) = Layers
                .makeDenseLayer(slc, dim);
            model.dense.push(layer);
            model.requiredWeights += weights;
            model.layers.push(Info(Layers.LayerType.Dense, model.dense.length - 1));
            dim = out_dim;
        } else if (layerType == uint8(Layers.LayerType.Flatten)) {
            (Layers.FlattenLayer memory layer, uint[] memory out_dim) = Layers
                .makeFlattenLayer(slc, dim);
            model.flatten.push(layer);
            model.layers.push(Info(Layers.LayerType.Flatten, model.flatten.length - 1));
            dim = out_dim;
        } else if (layerType == uint8(Layers.LayerType.Rescale)) {
            Layers.RescaleLayer memory layer = Layers.makeRescaleLayer(slc);
            model.rescale.push(layer);

            uint256 index = model.rescale.length - 1;
            model.layers.push(Info(Layers.LayerType.Rescale, index));
        } else if (layerType == uint8(Layers.LayerType.MaxPooling2D)) {
            (Layers.MaxPooling2DLayer memory layer, uint[] memory out_dim) = Layers
                .makeMaxPooling2DLayer(slc, dim);
            model.maxPooling2D.push(layer);
            dim = out_dim;

            uint256 index = model.maxPooling2D.length - 1;
            model.layers.push(Info(Layers.LayerType.MaxPooling2D, index));
        } else if (layerType == uint8(Layers.LayerType.Conv2D)) {
            (Layers.Conv2DLayer memory layer, uint[] memory out_dim, uint weights) = Layers
                .makeConv2DLayer(slc, dim);
            model.conv2D.push(layer);
            model.requiredWeights += weights;
            dim = out_dim;

            uint256 index = model.conv2D.length - 1;
            model.layers.push(Info(Layers.LayerType.Conv2D, index));
        }
        return dim;
    }

    function setModelInterface(address _interface) external onlyOwner {
        modelInterface = _interface;
    }
}
