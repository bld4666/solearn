// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "../tensors-cuda/Tensors.sol";
import "../tensors-cuda/Tensor1DMethods.sol";
import "../tensors-cuda/Tensor2DMethods.sol";
import "../tensors-cuda/Tensor3DMethods.sol";
import "../tensors-cuda/Tensor4DMethods.sol";
import { SD59x18, sd } from "@prb/math/src/SD59x18.sol";

import "hardhat/console.sol";

error TooMuchData();

library Layers {
	event TestRNNOutput(SD59x18[] data);
	event TestDense(SD59x18[] x, SD59x18[] w, SD59x18 tmp, SD59x18 b, SD59x18 y, SD59x18 res);

	using Tensor1DMethods for Tensors.Tensor1D;
	using Tensor2DMethods for Tensors.Tensor2D;
	using Tensor3DMethods for Tensors.Tensor3D;
	using Tensor4DMethods for Tensors.Tensor4D;

	struct SingleLayerConfig {
		bytes conf;
		uint256 ind;
	}

	struct RescaleLayer {
		uint layerIndex; // index within the model
		SD59x18 scale;
		SD59x18 offset;
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
	
	function forward(LSTMCell memory layer, SD59x18[] memory x, SD59x18[][] memory states) internal returns (SD59x18[] memory, SD59x18[] memory) {
		SD59x18[] memory c;
		SD59x18[] memory o;
		{
			if (states.length == 0) {
				// make new
				states = new SD59x18[][](2);
				states[0] = new SD59x18[](layer.units);
				states[1] = new SD59x18[](layer.units);
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

			SD59x18[][] memory xArr = new SD59x18[][](4);
			xArr[0] = x_i.mat;
			xArr[1] = x_f.mat;
			xArr[2] = x_c.mat;
			xArr[3] = x_o.mat;

			SD59x18[][] memory h_tm1_mat = new SD59x18[][](4);
			h_tm1_mat[0] = h_tm1.mat;
			h_tm1_mat[1] = h_tm1.mat;
			h_tm1_mat[2] = h_tm1.mat;
			h_tm1_mat[3] = h_tm1.mat;

			(c, o) = _compute_carry_and_output(layer, xArr, h_tm1_mat, c_tm1.mat);
		}
		SD59x18[] memory h = Tensor1DMethods.from(o).mul(Tensor1DMethods.from(c).activation(layer.activation)).mat;
		return (h, c);
	}

	function _compute_carry_and_output(LSTMCell memory layer, SD59x18[][] memory x, SD59x18[][] memory h_tm1, SD59x18[] memory c_tm1) internal returns (SD59x18[] memory, SD59x18[] memory) {
		Tensors.Tensor1D memory i = Tensor1DMethods.from(x[0]).add(Tensor1DMethods.matMul(Tensor1DMethods.from(h_tm1[0]), layer.recurrentKernel_i)).activation(layer.recurrentActivation);
		Tensors.Tensor1D memory f = Tensor1DMethods.from(x[1]).add(Tensor1DMethods.matMul(Tensor1DMethods.from(h_tm1[1]), layer.recurrentKernel_f)).activation(layer.recurrentActivation);
		SD59x18[] memory c = f.mul(Tensor1DMethods.from(c_tm1)).add(i.mul(Tensor1DMethods.from(x[2]).add(Tensor1DMethods.matMul(Tensor1DMethods.from(h_tm1[2]), layer.recurrentKernel_c)).activation(layer.activation))).mat;
		SD59x18[] memory o = Tensor1DMethods.from(x[3]).add(Tensor1DMethods.matMul(Tensor1DMethods.from(h_tm1[3]), layer.recurrentKernel_o)).activation(layer.recurrentActivation).mat;
		
		return (c, o);
	}

	function forward(LSTM memory layer, SD59x18[] memory _x, SD59x18[][] memory states) internal returns (SD59x18[][] memory, SD59x18[][] memory) {
		SD59x18[][] memory res = new SD59x18[][](1);
		// TODO: check
		SD59x18[] memory x = new SD59x18[](layer.cell.units);
		for (uint i = 0; i < _x.length; i++) {
			x[i] = _x[i];
		}

		SD59x18[][] memory newStates = new SD59x18[][](2);
		for (uint i = 0; i < res.length; i++) {
			(SD59x18[] memory h, SD59x18[] memory c) = forward(layer.cell, x, states);
			newStates[0] = h;
			newStates[1] = c;
			res[i] = h;
		}

		return (res, newStates);
	}
		
	function forward(FlattenLayer memory layer, SD59x18[][][] memory mat) internal pure returns (SD59x18[] memory) {
		Tensors.Tensor3D memory xt = Tensor3DMethods.from(mat);
		return Tensor3DMethods.flat(xt.mat);
	}

	function forward(RescaleLayer memory layer, SD59x18[][][] memory x) internal pure returns (SD59x18[][][] memory) {
		uint n = x.length;
		uint m = x[0].length;
		uint p = x[0][0].length;

		SD59x18[][][] memory y = new SD59x18[][][](n);
		for (uint i = 0; i < n; i++) {
			y[i] = new SD59x18[][](m);
			for (uint j = 0; j < m; j++) {
				y[i][j] = new SD59x18[](p);
				for (uint k = 0; k < p; k++) {
					y[i][j][k] = x[i][j][k].mul(layer.scale) + layer.offset;					
				}
			}
		}
		return y;
	}

	function forward(DenseLayer memory layer, SD59x18[] memory x) internal returns (SD59x18[] memory) {
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
		Tensors.Tensor1D memory tmp = xt.matMul(wt);
		SD59x18[] memory w_col = new SD59x18[](wt.n);
		for(uint i = 0; i < wt.n; ++i) {
			w_col[i] = wt.mat[i][34];
		}
		Tensors.Tensor1D memory y = tmp.add(bt);
		Tensors.Tensor1D memory zt = y.activation(layer.activation);
		emit TestDense(xt.mat, w_col, tmp.mat[34], bt.mat[34], y.mat[34], zt.mat[34]);
		return zt.mat;
	}

	function forward(MaxPooling2DLayer memory layer, SD59x18[][][] memory x) internal pure returns (SD59x18[][][] memory) {
		Tensors.Tensor3D memory xt = Tensor3DMethods.from(x);
		Tensors.Tensor3D memory yt = xt.maxPooling2D(layer.stride, layer.size, layer.padding);
		return yt.mat;
	}

	function forward(Conv2DLayer memory layer, SD59x18[][][] memory x) internal pure returns (SD59x18[][][] memory) {
		Tensors.Tensor3D memory xt = Tensor3DMethods.from(x);
		Tensors.Tensor4D memory wt = layer.w;
		Tensors.Tensor1D memory bt = layer.b;
		Tensors.Tensor3D memory yt = xt.conv2D(wt, layer.stride, layer.padding).add(bt);
		Tensors.Tensor3D memory zt = yt.activation(layer.activation);
		return zt.mat;
	}

	function forward(EmbeddingLayer memory layer, uint x) internal pure returns (SD59x18[] memory) {
		return layer.w.mat[x];
	}

	function forward(SimpleRNNLayer memory layer, SD59x18[] memory x, SD59x18[][] memory states) internal returns (SD59x18[] memory, SD59x18[][] memory) {
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

	function appendWeights(DenseLayer storage layer, SD59x18[] memory x) internal returns (uint) {
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

	function appendWeights(LSTM storage layer, SD59x18[] memory x) internal returns (uint) {
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

	function appendWeightsPartial(LSTM storage layer, SD59x18[] memory x) internal returns (uint) {
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

	function appendWeights(Conv2DLayer storage layer, SD59x18[] memory x) internal returns (uint) {
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

	function appendWeights(EmbeddingLayer storage layer, SD59x18[] memory x) internal returns (uint) {
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

	function appendWeights(SimpleRNNLayer storage layer, SD59x18[] memory x) internal returns (uint) {
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

	function makeDenseLayer(SingleLayerConfig memory slc, uint256 dim) internal pure returns (DenseLayer memory layer, uint256 out_dim, uint256 requiredWeights) {
		(, uint8 actv, uint256 d) = abi.decode(
			slc.conf,
			(uint8, uint8, uint256)
		);
		layer = Layers.DenseLayer(
			slc.ind,
			Tensors.ActivationFunc(actv),
			d,
			Tensor2DMethods.emptyTensor(dim, d),
			Tensor1DMethods.emptyTensor(d),
			0,
			0
		);
		out_dim = d;
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

	function makeFlattenLayer(SingleLayerConfig memory slc, uint256[3] memory dim) internal pure returns (FlattenLayer memory layer, uint256 out_dim) {
		layer = FlattenLayer(slc.ind);
		out_dim = dim[0] * dim[1] * dim[2];
	}

	function makeRescaleLayer(SingleLayerConfig memory slc) internal pure returns (RescaleLayer memory layer) {
		(, SD59x18 scale, SD59x18 offset) = abi.decode(
			slc.conf,
			(uint8, SD59x18, SD59x18)
		);
		layer = RescaleLayer(
			slc.ind,
			scale,
			offset
		);
	}

	function makeMaxPooling2DLayer(SingleLayerConfig memory slc, uint256[3] memory dim) internal pure returns (MaxPooling2DLayer memory layer, uint256[3] memory out_dim) {
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
		out_dim = [out[0], out[1], dim[2]];
	}

	function makeConv2DLayer(SingleLayerConfig memory slc, uint256[3] memory dim) internal pure returns (Conv2DLayer memory layer, uint256[3] memory out_dim, uint256 requiredWeights) {
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
		out_dim = [out[0], out[1], filters];
		requiredWeights = layer.w.count() + layer.b.count();
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
}
