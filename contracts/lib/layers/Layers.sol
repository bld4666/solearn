// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "../tensors/Tensors.sol";
import "../tensors/Tensor1DMethods.sol";
import "../tensors/Tensor2DMethods.sol";
import "../tensors/Tensor3DMethods.sol";
import "../tensors/Tensor4DMethods.sol";
import { Float32x32, fromInt, toInt } from "./../Float32x32/Lib32x32.sol";

// import "hardhat/console.sol";

error TooMuchData();

library Layers {
	event TestRNNOutput(Float32x32[] data);
	event TestDense(Float32x32[] x, Float32x32[] w, Float32x32 tmp, Float32x32 b, Float32x32 y, Float32x32 res);

	using Tensor1DMethods for Tensors.Tensor1D;
	using Tensor2DMethods for Tensors.Tensor2D;
	using Tensor3DMethods for Tensors.Tensor3D;
	using Tensor4DMethods for Tensors.Tensor4D;

	enum LayerType {
        Input,
        Dense,
        Flatten,
        Rescale,
        MaxPooling2D,
        Conv2D,
        Embedding,
        SimpleRNN,
        LSTM
    }

	enum InputType {
		Image,
		Token,
		Scalar
	}
    
	struct SingleLayerConfig {
		bytes conf;
		uint256 ind;
	}

	struct InputImageLayer {
		uint layerIndex;
		uint[3] inputDim;
	}

	struct InputTokenLayer {
		uint layerIndex;
	}

	struct InputScalarLayer {
		uint layerIndex;
	}

	struct RescaleLayer {
		uint layerIndex; // index within the model
		Float32x32 scale;
		Float32x32 offset;
	}

	struct FlattenLayer {
		uint layerIndex;
	}

	struct DenseLayer {
		uint layerIndex;
		Tensors.ActivationFunc activation;
		uint out_dim;
		Tensors.Tensor2D w;
		Tensors.Tensor1D b;
		uint ptrLayer;
		uint ptr;
	}

	struct MaxPooling2DLayer {
		uint layerIndex;
		uint[2] size;
		uint[2] stride;
		Tensors.PaddingType padding;
	}

	struct Conv2DLayer {
		uint layerIndex;
		Tensors.ActivationFunc activation;
		uint filters;
		uint[2] stride;
		Tensors.PaddingType padding;
		Tensors.Tensor4D w;
		Tensors.Tensor1D b;
		uint ptrLayer;
		uint ptr;
	}

	struct EmbeddingLayer {
		uint layerIndex;
		uint inputDim;
		uint outputDim;
		Tensors.Tensor2D w;
		uint ptrLayer;
		uint ptr;
	}

	struct SimpleRNNLayer {
		uint layerIndex;
		uint units;
		Tensors.ActivationFunc activation;
		Tensors.Tensor2D wx;
		Tensors.Tensor2D wh;
		Tensors.Tensor1D b;
		uint ptrLayer;
		uint ptr;
	}

	struct LSTMCell {
		uint units;
		Tensors.ActivationFunc activation;
		Tensors.ActivationFunc recurrentActivation;
		
		Tensors.Tensor2D kernel_i;
		Tensors.Tensor2D kernel_f;
		Tensors.Tensor2D kernel_c;
		Tensors.Tensor2D kernel_o;
		Tensors.Tensor2D recurrentKernel_i;
		Tensors.Tensor2D recurrentKernel_f;
		Tensors.Tensor2D recurrentKernel_c;
		Tensors.Tensor2D recurrentKernel_o;
		Tensors.Tensor1D bias_i;
		Tensors.Tensor1D bias_f;
		Tensors.Tensor1D bias_c;
		Tensors.Tensor1D bias_o;
	}

	struct LSTM {
		uint layerIndex;
		uint inputUnits;
		LSTMCell cell;
		uint ptr;
		uint ptrLayer;
	}
	
	function forward(LSTMCell memory layer, Float32x32[] memory x, Float32x32[][] memory states) internal returns (Float32x32[] memory, Float32x32[] memory) {
		Float32x32[] memory c;
		Float32x32[] memory o;
		{
			if (states.length == 0) {
				// make new
				states = new Float32x32[][](2);
				states[0] = new Float32x32[](layer.units);
				states[1] = new Float32x32[](layer.units);
			}

			Tensors.Tensor1D memory h_tm1 = Tensor1DMethods.from(states[0]);
			Tensors.Tensor1D memory c_tm1 = Tensor1DMethods.from(states[1]);

			Tensors.Tensor1D memory x_i = Tensor1DMethods.matMul(Tensor1DMethods.from(x), layer.kernel_i);
			Tensors.Tensor1D memory x_f = Tensor1DMethods.matMul(Tensor1DMethods.from(x), layer.kernel_f);
			Tensors.Tensor1D memory x_c = Tensor1DMethods.matMul(Tensor1DMethods.from(x), layer.kernel_c);
			Tensors.Tensor1D memory x_o = Tensor1DMethods.matMul(Tensor1DMethods.from(x), layer.kernel_o);

			x_i = Tensor1DMethods.add(x_i, layer.bias_i);
			x_f = Tensor1DMethods.add(x_f, layer.bias_f);
			x_c = Tensor1DMethods.add(x_c, layer.bias_c);
			x_o = Tensor1DMethods.add(x_o, layer.bias_o);

			Float32x32[][] memory xArr = new Float32x32[][](4);
			xArr[0] = x_i.mat;
			xArr[1] = x_f.mat;
			xArr[2] = x_c.mat;
			xArr[3] = x_o.mat;

			Float32x32[][] memory h_tm1_mat = new Float32x32[][](4);
			h_tm1_mat[0] = h_tm1.mat;
			h_tm1_mat[1] = h_tm1.mat;
			h_tm1_mat[2] = h_tm1.mat;
			h_tm1_mat[3] = h_tm1.mat;

			(c, o) = _compute_carry_and_output(layer, xArr, h_tm1_mat, c_tm1.mat);
		}
		Float32x32[] memory h = Tensor1DMethods.from(o).mul(Tensor1DMethods.from(c).activation(layer.activation)).mat;
		return (h, c);
	}

	function _compute_carry_and_output(LSTMCell memory layer, Float32x32[][] memory x, Float32x32[][] memory h_tm1, Float32x32[] memory c_tm1) internal returns (Float32x32[] memory, Float32x32[] memory) {
		Tensors.Tensor1D memory i = Tensor1DMethods.from(x[0]).add(Tensor1DMethods.matMul(Tensor1DMethods.from(h_tm1[0]), layer.recurrentKernel_i)).activation(layer.recurrentActivation);
		Tensors.Tensor1D memory f = Tensor1DMethods.from(x[1]).add(Tensor1DMethods.matMul(Tensor1DMethods.from(h_tm1[1]), layer.recurrentKernel_f)).activation(layer.recurrentActivation);
		Float32x32[] memory c = f.mul(Tensor1DMethods.from(c_tm1)).add(i.mul(Tensor1DMethods.from(x[2]).add(Tensor1DMethods.matMul(Tensor1DMethods.from(h_tm1[2]), layer.recurrentKernel_c)).activation(layer.activation))).mat;
		Float32x32[] memory o = Tensor1DMethods.from(x[3]).add(Tensor1DMethods.matMul(Tensor1DMethods.from(h_tm1[3]), layer.recurrentKernel_o)).activation(layer.recurrentActivation).mat;
		
		return (c, o);
	}

	function forward(LSTM memory layer, Float32x32[] memory _x, Float32x32[][] memory states) internal returns (Float32x32[][] memory, Float32x32[][] memory) {
		Float32x32[][] memory res = new Float32x32[][](1);
		// TODO: check
		Float32x32[] memory x = new Float32x32[](layer.inputUnits);
		for (uint i = 0; i < _x.length; i++) {
			x[i] = _x[i];
		}

		Float32x32[][] memory newStates = new Float32x32[][](2);
		for (uint i = 0; i < res.length; i++) {
			(Float32x32[] memory h, Float32x32[] memory c) = forward(layer.cell, x, states);
			newStates[0] = h;
			newStates[1] = c;
			res[i] = h;
		}

		return (res, newStates);
	}
		
	function forward(FlattenLayer memory layer, Float32x32[][][] memory mat) internal pure returns (Float32x32[] memory) {
		Tensors.Tensor3D memory xt = Tensor3DMethods.from(mat);
		return Tensor3DMethods.flat(xt.mat);
	}

	function forward(RescaleLayer memory layer, Float32x32[][][] memory x) internal pure returns (Float32x32[][][] memory) {
		uint n = x.length;
		uint m = x[0].length;
		uint p = x[0][0].length;

		Float32x32[][][] memory y = new Float32x32[][][](n);
		for (uint i = 0; i < n; i++) {
			y[i] = new Float32x32[][](m);
			for (uint j = 0; j < m; j++) {
				y[i][j] = new Float32x32[](p);
				for (uint k = 0; k < p; k++) {
					y[i][j][k] = x[i][j][k].mul(layer.scale) + layer.offset;					
				}
			}
		}
		return y;
	}

	function forward(DenseLayer memory layer, Float32x32[] memory x) internal returns (Float32x32[] memory) {
		Tensors.Tensor1D memory xt = Tensor1DMethods.from(x);
		Tensors.Tensor2D memory wt = layer.w;
		Tensors.Tensor1D memory bt = layer.b;
		
		if (wt.m == 1 && bt.count() == 1) {
			Tensors.Tensor1D memory wt1 = Tensor1DMethods.zerosTensor(wt.n);
			for (uint i = 0; i < wt.n; i++) {
				wt1.mat[i] = wt.mat[i][0];
			}

			Tensors.Tensor1D memory y = xt.matMul(wt1).add(bt);
			Tensors.Tensor1D memory zt = y.activation(layer.activation);
			return zt.mat;
		}
		// console.log("Prepare to matMul");
		Tensors.Tensor1D memory tmp = xt.matMul(wt);
		// Float32x32[] memory w_col = new Float32x32[](wt.n);
		// for(uint i = 0; i < wt.n; ++i) {
		// 	w_col[i] = wt.mat[i][34];
		// }
		// console.log("Prepare to add");
		Tensors.Tensor1D memory y = tmp.add(bt);
		// console.log("Prepare to activation");
		Tensors.Tensor1D memory zt = y.activation(layer.activation);
		// emit TestDense(xt.mat, w_col, tmp.mat[34], bt.mat[34], y.mat[34], zt.mat[34]);
		return zt.mat;
	}

	function forward(DenseLayer memory layer, Float32x32[][] memory x) internal view returns (Float32x32[][] memory) {
		Tensors.Tensor2D memory xt = Tensor2DMethods.from(x);
		Tensors.Tensor2D memory wt = layer.w;
		Tensors.Tensor1D memory bt = layer.b;
		Tensors.Tensor2D memory y = xt.matMul(wt).add(bt);
		Tensors.Tensor2D memory zt = y.activation(layer.activation);

		return zt.mat;
	}

	function forward(MaxPooling2DLayer memory layer, Float32x32[][][] memory x) internal pure returns (Float32x32[][][] memory) {
		Tensors.Tensor3D memory xt = Tensor3DMethods.from(x);
		Tensors.Tensor3D memory yt = xt.maxPooling2D(layer.stride, layer.size, layer.padding);
		return yt.mat;
	}

	function forward(Conv2DLayer memory layer, Float32x32[][][] memory x) internal view returns (Float32x32[][][] memory) {
		Tensors.Tensor3D memory xt = Tensor3DMethods.from(x);
		Tensors.Tensor4D memory wt = layer.w;
		Tensors.Tensor1D memory bt = layer.b;
		Tensors.Tensor3D memory yt = xt.conv2D(wt, layer.stride, layer.padding).add(bt);
		Tensors.Tensor3D memory zt = yt.activation(layer.activation);
		return zt.mat;
	}

	function forward(EmbeddingLayer memory layer, uint x) internal pure returns (Float32x32[] memory) {
		return layer.w.mat[x];
	}

	function forward(SimpleRNNLayer memory layer, Float32x32[] memory x, Float32x32[][] memory states) internal returns (Float32x32[] memory, Float32x32[][] memory) {
		Tensors.Tensor1D memory x_t = Tensor1DMethods.from(x);
		Tensors.Tensor1D memory h_t = Tensor1DMethods.from(states[0]);
		Tensors.Tensor1D memory yx_t = Tensor1DMethods.matMul(x_t, layer.wx);
		Tensors.Tensor1D memory yh_t = Tensor1DMethods.matMul(h_t, layer.wh);
		Tensors.Tensor1D memory y_t = Tensor1DMethods.add(Tensor1DMethods.add(yx_t, yh_t), layer.b);
		Tensors.Tensor1D memory z_t = Tensor1DMethods.activation(y_t, layer.activation);
		emit TestRNNOutput(z_t.mat);
		states[0] = z_t.mat;
		return (states[0], states);
	}

	function appendWeights(DenseLayer storage layer, Float32x32[] memory x) internal returns (uint) {
		uint ptrLayer = layer.ptrLayer;
		uint ptr = layer.ptr;
		uint idx = 0;
		if (ptrLayer == 0) {
			uint m = layer.w.m;
			uint cnt = layer.w.n * layer.w.m;
			while (idx < x.length && ptr < cnt) {
				layer.w.mat[ptr / m].push(x[idx]);
				ptr++; idx++;
			}
			if (ptr == cnt) { ++ptrLayer; ptr = 0; }
		}
		if (ptrLayer == 1) {
			uint n = layer.b.n; 
			while (idx < x.length && ptr < n) {
				layer.b.mat.push(x[idx]);
				ptr++; idx++;
			}
			if (ptr == n) { ++ptrLayer; ptr = 0; }
		}
		if (idx < x.length) {
			revert TooMuchData();
		}
		layer.ptrLayer = ptrLayer;
		layer.ptr = ptr;
		return idx;
	}

	function appendWeights(LSTM storage layer, Float32x32[] memory x) internal returns (uint) {
		// will overwrite the weights
		uint currentWeight = 0;
		for (uint i = 0; i < layer.inputUnits; i++) {
			for (uint j = 0; j < layer.cell.units; j++) {
				layer.cell.kernel_i.mat[i][j] = x[currentWeight];
				currentWeight++;
			}
			for (uint j = 0; j < layer.cell.units; j++) {
				layer.cell.kernel_f.mat[i][j] = x[currentWeight];
				currentWeight++;
			}
			for (uint j = 0; j < layer.cell.units; j++) {
				layer.cell.kernel_c.mat[i][j] = x[currentWeight];
				currentWeight++;
			}
			for (uint j = 0; j < layer.cell.units; j++) {
				layer.cell.kernel_o.mat[i][j] = x[currentWeight];
				currentWeight++;
			}
		}

		for (uint i = 0; i < layer.cell.units; i++) {
			for (uint j = 0; j < layer.cell.units; j++) {
				layer.cell.recurrentKernel_i.mat[i][j] = x[currentWeight];
				currentWeight++;
			}
			for (uint j = 0; j < layer.cell.units; j++) {
				layer.cell.recurrentKernel_f.mat[i][j] = x[currentWeight];
				currentWeight++;
			}
			for (uint j = 0; j < layer.cell.units; j++) {
				layer.cell.recurrentKernel_c.mat[i][j] = x[currentWeight];
				currentWeight++;
			}
			for (uint j = 0; j < layer.cell.units; j++) {
				layer.cell.recurrentKernel_o.mat[i][j] = x[currentWeight];
				currentWeight++;
			}
		}
		
		for (uint i = 0; i < layer.cell.units; i++) {
			layer.cell.bias_i.mat[i] = x[currentWeight];
			currentWeight++;
		}
		for (uint i = 0; i < layer.cell.units; i++) {
			layer.cell.bias_f.mat[i] = x[currentWeight];
			currentWeight++;
		}
		for (uint i = 0; i < layer.cell.units; i++) {
			layer.cell.bias_c.mat[i] = x[currentWeight];
			currentWeight++;
		}
		for (uint i = 0; i < layer.cell.units; i++) {
			layer.cell.bias_o.mat[i] = x[currentWeight];
			currentWeight++;
		}
		return currentWeight;
	}

	function appendWeightsPartial(LSTM storage layer, Float32x32[] memory x) internal returns (uint) {
		// can append weights to the end, at the cost of slightly higher gas
		LSTMCell storage cell = layer.cell;
		uint ptrLayer = layer.ptrLayer;
		uint ptr = layer.ptr;
		uint idx = 0;
		// kernel
		if (ptrLayer == 0) {
			uint m = cell.kernel_i.m;
			uint k = 4 * m;
			uint cnt = cell.kernel_i.n * k;
			while (idx < x.length && ptr < cnt) {
				uint i = ptr / k;
				uint part = (ptr % k) / m;
				uint j = ptr % m;
				if (part == 0) {
					cell.kernel_i.mat[i][j] = x[idx];
				} else if (part == 1) {
					cell.kernel_f.mat[i][j] = x[idx];
				} else if (part == 2) {
					cell.kernel_c.mat[i][j] = x[idx];
				} else { // if (part == 3) 
					cell.kernel_o.mat[i][j] = x[idx];
				}
				ptr++; idx++;
			}
			if (ptr == cnt) { ++ptrLayer; ptr = 0; }
		}
		// recurrentKernel
		if (ptrLayer == 1) {
			uint m = cell.recurrentKernel_i.m;
			uint k = 4 * m;
			uint cnt = cell.recurrentKernel_i.n * k;
			while (idx < x.length && ptr < cnt) {
				uint i = ptr / k;
				uint part = (ptr % k) / m;
				uint j = ptr % m;
				if (part == 0) {
					cell.recurrentKernel_i.mat[i][j] = x[idx];
				} else if (part == 1) {
					cell.recurrentKernel_f.mat[i][j] = x[idx];
				} else if (part == 2) {
					cell.recurrentKernel_c.mat[i][j] = x[idx];
				} else { // if (part == 3) 
					cell.recurrentKernel_o.mat[i][j] = x[idx];
				}
				ptr++; idx++;
			}
			if (ptr == cnt) { ++ptrLayer; ptr = 0; }
		}
		// bias
		if (ptrLayer == 2) {
			uint n = cell.bias_i.n;
			uint k = 4 * n;
			while (idx < x.length && ptr < k) {
				uint part = (ptr % k) / n;
				uint i = ptr % n;
				if (part == 0) {
					cell.bias_i.mat[i] = x[idx];
				} else if (part == 1) {
					cell.bias_f.mat[i] = x[idx];
				} else if (part == 2) {
					cell.bias_c.mat[i] = x[idx];
				} else { // if (part == 3) 
					cell.bias_o.mat[i] = x[idx];
				}
				ptr++; idx++;
			}
			if (ptr == k) { ++ptrLayer; ptr = 0; }
		}
		layer.ptrLayer = ptrLayer;
		layer.ptr = ptr;
		return idx;
	}

	function appendWeights(Conv2DLayer storage layer, Float32x32[] memory x) internal returns (uint) {
		uint ptrLayer = layer.ptrLayer;
		uint ptr = layer.ptr;
		uint idx = 0;
		if (ptrLayer == 0) {
			uint m = layer.w.m;
			uint p = layer.w.p;
			uint q = layer.w.q;
			uint cnt = layer.w.n * layer.w.m * layer.w.p * layer.w.q;
			while (idx < x.length && ptr < cnt) {
				layer.w.mat[ptr / (m * p * q)][ptr / (p * q) % m][ptr / q % p].push(x[idx]);
				ptr++; idx++;
			}
			if (ptr == cnt) { ++ptrLayer; ptr = 0; }
		}
		if (ptrLayer == 1) {
			uint n = layer.b.n; 
			while (idx < x.length && ptr < n) {
				layer.b.mat.push(x[idx]);
				ptr++; idx++;
			}
			if (ptr == n) { ++ptrLayer; ptr = 0; }
		}
		if (idx < x.length) {
			revert TooMuchData();
		}
		layer.ptrLayer = ptrLayer;
		layer.ptr = ptr;
		return idx;
	}

	function appendWeights(EmbeddingLayer storage layer, Float32x32[] memory x) internal returns (uint) {
		uint ptrLayer = layer.ptrLayer;
		uint ptr = layer.ptr;
		uint idx = 0;
		if (ptrLayer == 0) {
			uint m = layer.w.m;
			uint cnt = layer.w.n * layer.w.m;
			while (idx < x.length && ptr < cnt) {
				layer.w.mat[ptr / m].push(x[idx]);
				ptr++; idx++;
			}
			if (ptr == cnt) { ++ptrLayer; ptr = 0; }
		}
		if (idx < x.length) {
			revert TooMuchData();
		}
		layer.ptrLayer = ptrLayer;
		layer.ptr = ptr;
		return idx;
	}

	function appendWeights(SimpleRNNLayer storage layer, Float32x32[] memory x) internal returns (uint) {
		uint ptrLayer = layer.ptrLayer;
		uint ptr = layer.ptr;
		uint idx = 0;
		if (ptrLayer == 0) {
			uint m = layer.wx.m;
			uint cnt = layer.wx.n * layer.wx.m;
			while (idx < x.length && ptr < cnt) {
				layer.wx.mat[ptr / m].push(x[idx]);
				ptr++; idx++;
			}
			if (ptr == cnt) { ++ptrLayer; ptr = 0; }
		}
		if (ptrLayer == 1) {
			uint m = layer.wh.m;
			uint cnt = layer.wh.n * layer.wh.m;
			while (idx < x.length && ptr < cnt) {
				layer.wh.mat[ptr / m].push(x[idx]);
				ptr++; idx++;
			}
			if (ptr == cnt) { ++ptrLayer; ptr = 0; }
		}
		if (ptrLayer == 2) {
			uint n = layer.b.n; 
			while (idx < x.length && ptr < n) {
				layer.b.mat.push(x[idx]);
				ptr++; idx++;
			}
			if (ptr == n) { ++ptrLayer; ptr = 0; }
		}
		if (idx < x.length) {
			revert TooMuchData();
		}
		layer.ptrLayer = ptrLayer;
		layer.ptr = ptr;
		return idx;
	}

	function makeDenseLayer(SingleLayerConfig memory slc, uint256[] memory dim) internal pure returns (DenseLayer memory layer, uint256[] memory out_dim, uint256 requiredWeights) {
		(, uint8 actv, uint256 d) = abi.decode(
			slc.conf,
			(uint8, uint8, uint256)
		);
		console.log(dim[0], d);
		layer = Layers.DenseLayer(
			slc.ind,
			Tensors.ActivationFunc(actv),
			d,
			Tensor2DMethods.emptyTensor(dim[0], d),
			Tensor1DMethods.emptyTensor(d),
			0,
			0
		);
		out_dim = new uint[](1);
		out_dim[0] = d;
		requiredWeights = layer.w.count() + layer.b.count();
	}

	function makeLSTMLayer(SingleLayerConfig memory slc, uint256 dim) internal pure returns (LSTM memory layer, uint256 out_dim, uint256 requiredWeights) {
		(, uint8 actv, uint8 ractv, uint256 numUnits, uint256 numInputs) = abi.decode(
			slc.conf,
			(uint8, uint8, uint8, uint256, uint256)
		);
		layer = Layers.LSTM(
			slc.ind,
			numInputs,
			Layers.LSTMCell(
				numUnits,
				Tensors.ActivationFunc(actv),
				Tensors.ActivationFunc(ractv),
				
				Tensor2DMethods.zerosTensor(numInputs, numUnits),
				Tensor2DMethods.zerosTensor(numInputs, numUnits),
				Tensor2DMethods.zerosTensor(numInputs, numUnits),
				Tensor2DMethods.zerosTensor(numInputs, numUnits),
				Tensor2DMethods.zerosTensor(numUnits, numUnits),
				Tensor2DMethods.zerosTensor(numUnits, numUnits),
				Tensor2DMethods.zerosTensor(numUnits, numUnits),
				Tensor2DMethods.zerosTensor(numUnits, numUnits),
				Tensor1DMethods.zerosTensor(numUnits),
				Tensor1DMethods.zerosTensor(numUnits),
				Tensor1DMethods.zerosTensor(numUnits),
				Tensor1DMethods.zerosTensor(numUnits)
			),
			0,
			0
		);
		out_dim = numUnits;
		requiredWeights = 4 * numInputs * numUnits + 4 * numUnits * numUnits + 4 * numUnits;
	}

	function makeFlattenLayer(SingleLayerConfig memory slc, uint256[] memory dim) internal pure returns (FlattenLayer memory layer, uint256[] memory out_dim) {
		layer = FlattenLayer(slc.ind);
		out_dim = new uint256[](1);
		out_dim[0] = dim[0] * dim[1] * dim[2];
	}

	function makeRescaleLayer(SingleLayerConfig memory slc) internal returns (RescaleLayer memory layer) {
		(, Float32x32 scale, Float32x32 offset) = abi.decode(
			slc.conf,
			(uint8, Float32x32, Float32x32)
		);
		// console.logInt(Float32x32.unwrap(scale));
		// console.logInt(Float32x32.unwrap(offset));
		layer = RescaleLayer(
			slc.ind,
			scale,
			offset
		);
	}

	function makeMaxPooling2DLayer(SingleLayerConfig memory slc, uint256[] memory dim) internal pure returns (MaxPooling2DLayer memory layer, uint256[] memory out_dim) {
		(, uint256[2] memory size, uint256[2] memory stride, uint8 padding) = abi.decode(
			slc.conf,
			(uint8, uint256[2], uint256[2], uint8)
		);
		layer = Layers.MaxPooling2DLayer(
			slc.ind,
			size,
			stride,
			Tensors.PaddingType(padding)
		);
 		uint256[2] memory out;
    	(out, ) = Tensors.getConvSize(
			[dim[0], dim[1]],
			size,
			stride,
			Tensors.PaddingType(padding)
		);
		out_dim = new uint[](3);
		out_dim[0] = out[0];
		out_dim[1] = out[1];
		out_dim[2] = dim[2];
	}

	function makeConv2DLayer(SingleLayerConfig memory slc, uint256[] memory dim) internal pure returns (Conv2DLayer memory layer, uint256[] memory out_dim, uint256 requiredWeights) {
		(, uint8 actv, uint256 filters, uint256[2] memory size, uint256[2] memory stride, uint8 padding) = abi.decode(
				slc.conf,
				(uint8, uint8, uint256, uint256[2], uint256[2], uint8)
		);
		layer = Layers.Conv2DLayer(
			slc.ind,
			Tensors.ActivationFunc(actv),
			filters,
			stride,
			Tensors.PaddingType(padding),
			Tensor4DMethods.emptyTensor(size[0], size[1], dim[2], filters),
			Tensor1DMethods.emptyTensor(filters),
			0,
			0
		);

		uint256[2] memory out;
		(out, ) = Tensors.getConvSize(
			[dim[0], dim[1]],
			size,
			stride,
			Tensors.PaddingType(padding)
		);
		out_dim = new uint[](3);
		out_dim[0] = out[0];
		out_dim[1] = out[1];
		out_dim[2] = filters;
		requiredWeights = size[0] * size[1] * dim[2] * filters + filters;
	}

	function makeEmbeddingLayer(SingleLayerConfig memory slc) internal pure returns (EmbeddingLayer memory layer, uint256 out_dim, uint256 requiredWeights) {
		(, uint256 inputDim, uint256 outputDim) = abi.decode(
			slc.conf,
			(uint8, uint256, uint256)
		);
		layer = Layers.EmbeddingLayer(
			slc.ind,
			inputDim,
			outputDim,
			Tensor2DMethods.emptyTensor(inputDim, outputDim),
			0,
			0
		);
		out_dim = outputDim;
		requiredWeights = layer.w.count();
	}

	function makeSimpleRNNLayer(SingleLayerConfig memory slc, uint256 dim) internal pure returns (SimpleRNNLayer memory layer, uint256 out_dim, uint256 requiredWeights) {
		(, uint8 actv, uint256 units) = abi.decode(
			slc.conf,
			(uint8, uint8, uint256)
		);
		layer = Layers.SimpleRNNLayer(
			slc.ind,
			units,
			Tensors.ActivationFunc(actv),
			Tensor2DMethods.emptyTensor(dim, units),
			Tensor2DMethods.emptyTensor(units, units),
			Tensor1DMethods.emptyTensor(units),
			0,
			0
		);
		out_dim = units;
		requiredWeights = layer.wx.count() + layer.wh.count() + layer.b.count();
	}

	function makeInputImageLayer(SingleLayerConfig memory slc) internal pure returns (InputImageLayer memory layer, uint256[] memory out_dim) {
		uint[3] memory ipd_dim;
		(, , ipd_dim) = abi.decode(
			slc.conf,
			(uint8, uint8, uint256[3])
		);
		layer = Layers.InputImageLayer(
			slc.ind,
			ipd_dim
		);
		// console.log(ipd_dim[0], ipd_dim[1], ipd_dim[2]);
		out_dim = new uint[](3);
		out_dim[0] = ipd_dim[0];
		out_dim[1] = ipd_dim[1];
		out_dim[2] = ipd_dim[2];
	}
	
	function makeInputTokenLayer(SingleLayerConfig memory slc) internal pure returns (InputTokenLayer memory layer, uint256[] memory out_dim) {
		layer = Layers.InputTokenLayer(
			slc.ind
		);
		out_dim = new uint[](1);
		out_dim[0] = 1;
	}
	
	function makeInputScalarLayer(SingleLayerConfig memory slc) internal pure returns (InputScalarLayer memory layer, uint256[] memory out_dim) {
		layer = Layers.InputScalarLayer(
			slc.ind
		);
		out_dim = new uint[](1);
		out_dim[0] = 1;
	}
}
