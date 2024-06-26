// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./lib/layers/Layers.sol";
import "hardhat/console.sol";
import './lib/Utils.sol';

import {IModel} from "./interfaces/IModel.sol";
import {IModelCollection} from './interfaces/IModelCollection.sol';

error NotTokenOwner();
error InsufficientEvalPrice();
error TransferFailed();
error InvalidOutput();
error InvalidInput();
error IncorrectModelId();
error NotModelRegistry();

// interface IModelReg is IERC721Upgradeable {
//     function modelAddr(uint256 tokenId) external view returns (address);
//     function evalPrice() external view returns (uint256);
//     function royaltyReceiver() external view returns (address);
// }

contract MelodyRNN is IModel, Ownable {
    using Layers for Layers.RescaleLayer;
    using Layers for Layers.FlattenLayer;
    using Layers for Layers.DenseLayer;
    using Layers for Layers.MaxPooling2DLayer;
    using Layers for Layers.Conv2DLayer;
    using Layers for Layers.EmbeddingLayer;
    using Layers for Layers.LSTM;
    using Tensor1DMethods for Tensors.Tensor1D;
    using Tensor2DMethods for Tensors.Tensor2D;
    using Tensor3DMethods for Tensors.Tensor3D;
    using Tensor4DMethods for Tensors.Tensor4D;
    int256 constant VOCAB_SIZE = 130;

    Model public model;
    IModelCollection public modelCollection;
    uint256 public modelId;

    uint256 version;
    VocabInfo public vocabInfo;

    event NewMelody(uint256 indexed tokenId, SD59x18[] melody);

    event Forwarded(
        uint256 indexed tokenId,
        uint256 fromLayerIndex,
        uint256 toLayerIndex,
        SD59x18[][][] outputs1,
        SD59x18[] outputs2
    );

    event Deployed(
        address indexed owner,
        uint256 indexed tokenId
    );

    struct Model {
        uint256[3] inputDim;
        string modelName;
        uint256 numLayers;
        Info[] layers;
        uint256 requiredWeights;
        uint256 appendedWeights;
        Layers.RescaleLayer[] r;
        Layers.FlattenLayer[] f;
        Layers.DenseLayer[] d;
        Layers.LSTM[] lstm;
        Layers.EmbeddingLayer[] embedding;
    }

    struct Info {
        LayerType layerType;
        uint256 layerIndex;
    }
    
    struct VocabInfo {
        bool hasVocab;
        uint256[] vocabs;
    }

    enum LayerType {
        Dense,
        Flatten,
        Rescale,
        Input,
        MaxPooling2D,
        Conv2D,
        Embedding,
        SimpleRNN,
        LSTM
    }

    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner() && modelId > 0 && msg.sender != modelCollection.ownerOf(modelId)) {
            revert NotTokenOwner();
        }
        _;
    }

    modifier onlyMintedModel() {
        if (modelId == 0) {
            revert IncorrectModelId();
        }
        _;
    }

    constructor(string memory _modelName, address _modelCollection) Ownable() {
        model.modelName = _modelName;
        modelCollection = IModelCollection(_modelCollection);        
        version = 1;
    }



    // function initialize(string memory _modelName, address _modelRegistry) public initializer {
    //     __Ownable_init();
    //     model.modelName = _modelName;
    //     modelRegistry = IModelReg(_modelRegistry);        
    //     version = 1;
    // }

    // function afterUpgrade() public {}

    function getInfo(
    )
        public
        view
        returns (
            uint256[3] memory,
            string memory,
            Info[] memory
        )
    {
        Model storage m = model;
        return (
            model.inputDim,
            model.modelName,
            m.layers
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
            SD59x18[][] memory w,
            SD59x18[] memory b
        )
    {
        Layers.DenseLayer memory layer = model.d[layerIdx];
        dim_in = layer.w.n;
        dim_out = layer.w.m;
        w = layer.w.mat;
        b = layer.b.mat;
    }

    function getLSTMLayer(
        uint256 layerIdx
    )
        public
        view
        returns (
            uint256,
            uint256,
            SD59x18[][] memory,
            SD59x18[][] memory,
            SD59x18[] memory
        )
    {
        Layers.LSTM memory layer = model.lstm[layerIdx];
        Layers.LSTMCell memory cell = layer.cell;
        uint256 inputUnits = layer.inputUnits;
        uint256 units = cell.units;
        return (
            inputUnits,
            units,
            cell.kernel_f.mat,
            cell.recurrentKernel_f.mat,
            cell.bias_f.mat
        );
    }

    function forward(
        Model memory model,
        uint256 input,
        SD59x18[][][] memory states,
        bool isGenerating
    ) internal view returns (SD59x18[] memory, SD59x18[][][] memory) {
        SD59x18[] memory x2;
        SD59x18[][] memory x2Ext;
        for (uint256 i = 0; i < model.layers.length; i++) {
            Info memory layerInfo = model.layers[i];

            // add more layers
            if (layerInfo.layerType == LayerType.Embedding) {
                x2 = model.embedding[layerInfo.layerIndex].forward(input);
                // console.log("embedding ", layerInfo.layerIndex);
                // for(uint j = 0; j < x2.length; ++j) {
                //     console.logInt(x2[j].intoInt256());
                // }
            } else if (layerInfo.layerType == LayerType.Dense) {
                if (i < model.layers.length - 1 || isGenerating) {
                    x2 = model.d[layerInfo.layerIndex].forward(x2);
                    // console.log("dense ", layerInfo.layerIndex);
                    // for(uint j = 0; j < x2.length; ++j) {
                    //     console.logInt(x2[j].intoInt256());
                    // }
                }                
            } else if (layerInfo.layerType == LayerType.LSTM) {
                if (x2.length == 0) {
                    x2 = new SD59x18[](1);
                    x2[0] = sd(int(input) * 1e18 / VOCAB_SIZE);
                }

                Layers.LSTM memory lstm = model.lstm[layerInfo.layerIndex];
                (x2Ext, states[layerInfo.layerIndex]) = lstm.forward(x2, states[layerInfo.layerIndex]);
                x2 = x2Ext[0];

                // console.log("states[0] of lstm", layerInfo.layerIndex);
                // for(uint j = 0; j < states[layerInfo.layerIndex][0].length; ++j) {
                //     console.logInt(states[layerInfo.layerIndex][0][j].intoInt256());
                // }
                // console.log("states[1] of lstm", layerInfo.layerIndex);
                // for(uint j = 0; j < states[layerInfo.layerIndex][1].length; ++j) {
                //     console.logInt(states[layerInfo.layerIndex][1][j].intoInt256());
                // }
            }
        }
        return (x2, states);
    }

    function decodeTokens(SD59x18[] memory tokens) internal view returns (SD59x18[] memory) {
        VocabInfo storage info = vocabInfo;
        for(uint i = 0; i < tokens.length; ++i) {
            uint256 id = tokens[i].intoUint256() / 1e18;
            tokens[i] = sd(int256(info.vocabs[id] * 1e18));
        }
        return tokens;
    }

    function sampleWithTemperature(SD59x18[] memory probabilities, int256 seed) public pure returns (uint256) {
        uint256 n = probabilities.length;
        SD59x18[] memory p = new SD59x18[](n);
        SD59x18 sumNewProbs;
        for (uint256 i=0; i<n; i++) {
            // p[i] = probabilities[i].ln() / temperature;
            // p[i] = p[i].exp();
            p[i] = probabilities[i];
            sumNewProbs = sumNewProbs + p[i];
        }
        for (uint256 i=0; i<n; i++) {
            p[i] = p[i] / sumNewProbs;
        }
        // sample
        SD59x18 r = sd(seed % 1e18).abs();
        uint256 choice = 0;
        for (uint256 i=0; i<n; i++) {
            r = r - p[i];
            if (r.unwrap() < 0) {
                choice = i;
                break;
            }
        }

        return choice;
    }

    function getVocabs() public view returns (uint256[] memory) {
        return vocabInfo.vocabs;
    }

    function getToken(
        SD59x18[] memory x2,
        SD59x18 temperature,
        uint256 seed 
    ) internal view returns (uint256) {
        SD59x18[] memory tmp = Utils.clone(x2);
        for(uint i = 0; i < tmp.length; ++i) {
            tmp[i] = tmp[i] / temperature;
        }

        Tensors.Tensor1D memory xt = Tensor1DMethods.from(tmp);
        SD59x18[] memory probs = xt.softmax().mat;
        uint256 outputToken = Utils.getWeightedRandom(probs, seed);

        return outputToken;
    }

    function generateMelodyTest(
        uint256 _modelId,
        uint256 noteCount,
        SD59x18[] calldata x
    ) public view onlyMintedModel returns (SD59x18[] memory, SD59x18[][][] memory) {
        if (_modelId != modelId) revert IncorrectModelId();

        Model memory model = model;
        uint256 seed = uint256(keccak256(abi.encodePacked(x)));

        SD59x18 temperature = sd(1e18);
        SD59x18[] memory r2;
        SD59x18[][][] memory states = new SD59x18[][][](model.lstm.length);
        for (uint256 i=0; i<x.length-1; i++) {
            (r2, states) = forward(model, x[i].intoUint256() / 1e18, states, false);
        }

        SD59x18[] memory result = new SD59x18[](noteCount);
        uint256 inputToken = x[x.length - 1].intoUint256() / 1e18;
        for (uint256 i=0; i<noteCount; i++) {
            (r2, states) = forward(model, inputToken, states, true);
            uint256 nxtToken = getToken(r2, temperature, seed);
            if (vocabInfo.hasVocab) {
                nxtToken = vocabInfo.vocabs[nxtToken];
            }
            result[i] = sd(int256(nxtToken) * 1e18);
            seed = uint256(keccak256(abi.encodePacked(seed)));
            inputToken = nxtToken;
        }
        return (result, states);
    }

    function generateMelody(
        uint256 _modelId,
        uint256 noteCount,
        SD59x18[] calldata x
    ) external onlyMintedModel {
        if (_modelId != modelId) revert IncorrectModelId();
        
        Model memory model = model;
        uint256 seed = uint256(keccak256(abi.encodePacked(x)));

        SD59x18 temperature = sd(1e18);
        SD59x18[] memory r2;
        SD59x18[][][] memory states = new SD59x18[][][](model.lstm.length);
        for (uint256 i=0; i<x.length-1; i++) {
            (r2, states) = forward(model, x[i].intoUint256() / 1e18, states, false);
        }

        SD59x18[] memory result = new SD59x18[](noteCount);
        uint256 inputToken = x[x.length - 1].intoUint256() / 1e18;
        for (uint256 i=0; i<noteCount; i++) {
            (r2, states) = forward(model, inputToken, states, true);
            uint256 nxtToken = getToken(r2, temperature, seed);
            if (vocabInfo.hasVocab) {
                nxtToken = vocabInfo.vocabs[nxtToken];
            }
            result[i] = sd(int256(nxtToken) * 1e18);
            seed = uint256(keccak256(abi.encodePacked(seed)));
            inputToken = nxtToken;
        }

        emit NewMelody(modelId, result);
    }


    function setModel(
        bytes[] calldata layers_config
    ) external onlyOwnerOrOperator {

        if (model.numLayers > 0) {
            model.numLayers = 0;
            delete model.d;
            delete model.f;
            delete model.r;
            delete model.lstm;
            delete model.embedding;
            delete model.layers;
        }

        loadModel(layers_config);
    }

    function appendWeights(
        SD59x18[] memory weights,
        uint256 layerInd,
        LayerType layerType
    ) external onlyOwnerOrOperator {
        uint appendedWeights;
        if (layerType == LayerType.Dense) {
            appendedWeights = model.d[layerInd].appendWeights(weights);
        } else if (layerType == LayerType.LSTM) {
            appendedWeights = model.lstm[layerInd].appendWeightsPartial(weights);
        } else if (layerType == LayerType.Embedding) {
            appendedWeights = model.embedding[layerInd].appendWeights(weights);
        }
        
        model.appendedWeights += appendedWeights;
        if (model.appendedWeights == model.requiredWeights && modelId > 0) {
            emit Deployed(modelCollection.modelAddressOf(modelId), modelId);
        }
    }
    
    function setVocabs(
        uint256[] memory vocabs
    ) external onlyOwnerOrOperator {
        VocabInfo storage info = vocabInfo;
        info.vocabs = vocabs;
        info.hasVocab = true;
    }

    function makeLayer(
        Layers.SingleLayerConfig memory slc,
        uint256[3] memory dim1,
        uint256 dim2
    ) internal returns (uint256[3] memory, uint256) {
        uint8 layerType = abi.decode(slc.conf, (uint8));

        // add more layers
        if (layerType == uint8(LayerType.Dense)) {
            (Layers.DenseLayer memory layer, uint out_dim2, uint weights) = Layers
                .makeDenseLayer(slc, dim2);
            model.d.push(layer);
            model.requiredWeights += weights;
            dim2 = out_dim2;

            uint256 index = model.d.length - 1;
            model.layers.push(Info(LayerType.Dense, index));
        } else if (layerType == uint8(LayerType.Embedding)) {
            (Layers.EmbeddingLayer memory layer, uint out_dim2, uint weights) = Layers
                .makeEmbeddingLayer(slc);
            model.embedding.push(layer);
            model.requiredWeights += weights;
            dim2 = out_dim2;

            uint256 index = model.embedding.length - 1;
            model.layers.push(Info(LayerType.Embedding, index));
        } else if (layerType == uint8(LayerType.Flatten)) {
            (Layers.FlattenLayer memory layer, uint out_dim2) = Layers
                .makeFlattenLayer(slc, dim1);
            model.f.push(layer);
            dim2 = out_dim2;

            uint256 index = model.f.length - 1;
            model.layers.push(Info(LayerType.Flatten, index));
        } else if (layerType == uint8(LayerType.Rescale)) {
            Layers.RescaleLayer memory layer = Layers.makeRescaleLayer(slc);
            model.r.push(layer);

            uint256 index = model.r.length - 1;
            model.layers.push(Info(LayerType.Rescale, index));
        } else if (layerType == uint8(LayerType.Input)) {
            (, uint8 inputType) = abi.decode(slc.conf, (uint8, uint8));
            if (inputType == 0) {
                dim2 = 1;
            } else if (inputType == 1) {
                (, , uint256[3] memory ipd) = abi.decode(
                    slc.conf,
                    (uint8, uint8, uint256[3])
                );
                model.inputDim = ipd;
                dim1 = ipd;
            }

            // NOTE: there is only one layer type input
            model.layers.push(Info(LayerType.Input, 0));
        } else if (layerType == uint8(LayerType.LSTM)) {
            (Layers.LSTM memory layer, uint256 out_dim, uint256 rw) = Layers
                .makeLSTMLayer(slc, dim2);
            model.lstm.push(layer);
            model.requiredWeights += rw;
            dim1 = dim1;
            dim2 = out_dim;

            uint256 index = model.lstm.length - 1;
            model.layers.push(Info(LayerType.LSTM, index));
        }
        return (dim1, dim2);
    }

    function loadModel(
        bytes[] calldata layersConfig
    ) internal {
        model.numLayers = layersConfig.length;
        model.requiredWeights = 0;
        model.appendedWeights = 0;
        uint256[3] memory dim1;
        uint256 dim2;
        for (uint256 i = 0; i < layersConfig.length; i++) {
            (dim1, dim2) = makeLayer(
                Layers.SingleLayerConfig(layersConfig[i], i),
                dim1,
                dim2
            );
        }
    }

    function setModelId(uint256 _modelId) external {
        if (msg.sender != address(modelCollection)) {
            revert NotModelRegistry();
        }
        if (modelId > 0 || modelCollection.modelAddressOf(_modelId) != address(this)) {
            revert IncorrectModelId();
        }

        modelId = _modelId;
        if (model.appendedWeights == model.requiredWeights && modelId > 0) {
            emit Deployed(modelCollection.modelAddressOf(modelId), modelId);
        }
    }
}
