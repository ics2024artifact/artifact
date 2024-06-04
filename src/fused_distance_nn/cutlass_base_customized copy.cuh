/*
 * Copyright (c) 2023, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#pragma GCC diagnostic ignored "-Wtautological-compare"


#include <cutlass/cutlass.h>
#include <cutlass/gemm/device/gemm.h>
#include <cutlass/gemm/device/gemm_grouped.h>
#include <cutlass/gemm/device/gemm_universal_adapter.h>
// #include <rmm/device_uvector.hpp>

#include <cutlass/layout/matrix.h>
#include <cutlass/layout/tensor.h>
#include <cutlass/matrix_coord.h>
#include <cutlass/tensor_view.h>

#include "epilogue_elementwise.cuh"  // FusedDistanceNNEpilogueElementwise
#include "gemm_customized.h"                    // FusedDistanceNNGemm
// #include <raft/util/cudart_utils.hpp>   // getMultiProcessorCount
// #include <raft/util/cutlass_utils.cuh>  // RAFT_CUTLASS_TRY

template <typename DataT,
          typename AccT,
          typename OutT,
          typename IdxT,
          int VecLen,
          typename CGReduceOpT,
          typename DistanceFn,
          typename ReduceOpT,
          typename KVPReduceOpT>
void cutlassFusedDistanceNN(const DataT* x,
                            const DataT* y,
                            const DataT* xn,
                            const DataT* yn,
                            IdxT m,
                            IdxT n,
                            IdxT k,
                            IdxT lda,
                            IdxT ldb,
                            IdxT ldd,
                            OutT* dOutput,
                            int* mutexes,
                            CGReduceOpT cg_reduce_op,
                            DistanceFn dist_op,
                            ReduceOpT redOp,
                            KVPReduceOpT pairRedOp,
                            cudaStream_t stream,
                            int number)
{
  using EpilogueOutputOp = cutlass::epilogue::thread::FusedDistanceNNEpilogueElementwise<
    DataT,  // ElementC_
    AccT,   // ElementAccumulator_
    DataT,  // ElementCompute_
    AccT,   // ElementZ_
    OutT,   // ElementT_
    // 128 / cutlass::sizeof_bits<DataT>::value,
    1,  // Elements per access 1
    DistanceFn,
    CGReduceOpT,
    ReduceOpT,
    KVPReduceOpT>;
  constexpr int batch_count = 1;
  
  typename EpilogueOutputOp::Params epilog_op_param(
    dist_op, cg_reduce_op, redOp, pairRedOp, mutexes); 

  // Number of pipelines you want to use
  constexpr int NumStages = 3;
  // Alignment
  constexpr int Alignment = VecLen;

  // default initialize problem size with row major inputs
  auto problem_size = cutlass::gemm::GemmCoord(m, n, k);

  constexpr bool isRowMajor = true;
  using fusedDistanceNNKernel = // this kernel is designed for codegen 
    typename cutlass::gemm::kernel::GEMM_float_tester<DataT,
                                                        Alignment,
                                                        DataT,
                                                        Alignment,
                                                        AccT,
                                                        AccT,
                                                        EpilogueOutputOp,
                                                        NumStages,  // Number of pipeline stages
                                                        isRowMajor>::GemmKernel;
  if (number == 0) {
      using fusedDistanceNNKernel =
        typename cutlass::gemm::kernel::GEMM_float_0<DataT,Alignment,DataT,Alignment,AccT,AccT,EpilogueOutputOp,NumStages,isRowMajor>::GemmKernel;
  }
  //start of injection

  if (number == 1) {
      using fusedDistanceNNKernel =
        typename cutlass::gemm::kernel::GEMM_float_1<DataT,Alignment,DataT,Alignment,AccT,AccT,EpilogueOutputOp,NumStages,isRowMajor>::GemmKernel;
  }

  if (number == 2) {
      using fusedDistanceNNKernel =
        typename cutlass::gemm::kernel::GEMM_float_2<DataT,Alignment,DataT,Alignment,AccT,AccT,EpilogueOutputOp,NumStages,isRowMajor>::GemmKernel;
  }
  //end of injection

  using fusedDistanceNN = cutlass::gemm::device::GemmGrouped<fusedDistanceNNKernel>;

  int num_blocks_per_sm   = fusedDistanceNN::maximum_active_blocks();
  // int num_sms             = raft::getMultiProcessorCount();
  int num_sms             = 108;
  int full_wave           = num_blocks_per_sm * num_sms;
  // printf("************************\n%d, %d, %d\n************************\n", fusedDistanceNNKernel::Mma::Shape::kM, 
  // fusedDistanceNNKernel::Mma::Shape::kN, fusedDistanceNNKernel::Mma::Shape::kK);
  constexpr int mmaShapeM = fusedDistanceNNKernel::Mma::Shape::kM;
  constexpr int mmaShapeN = fusedDistanceNNKernel::Mma::Shape::kN;
  int columnTiles         = (problem_size.n() - 1 + mmaShapeN) / mmaShapeN;
  int rowTiles            = (problem_size.m() - 1 + mmaShapeM) / mmaShapeM;
  int totalTiles          = columnTiles * rowTiles;
  int thread_blocks =
    rowTiles < full_wave ? (totalTiles < full_wave ? totalTiles : full_wave) : rowTiles;

  typename fusedDistanceNN::Arguments arguments{
    problem_size,
    batch_count,  // num of problems.
    thread_blocks,
    epilog_op_param,
    x,
    y,
    xn,            // C matrix eq vector param, which here is A norm
    (DataT*)yn,    // this is broadcast vec, which is required to be non-const param
    dOutput,       // Output distance matrix
    (int64_t)lda,  // stride A
    (int64_t)ldb,  // stride B
    (int64_t)1,    // stride A norm
    (int64_t)ldd   // stride Output matrix
  };

  // Using the arguments, query for extra workspace required for matrix multiplication computation
  size_t workspace_size = fusedDistanceNN::get_workspace_size(arguments);
  // Allocate workspace memory
  // rmm::device_uvector<uint8_t> workspace(workspace_size, stream);
  DataT* workspace;
  cudaMalloc((void**)&workspace, workspace_size);
  // Instantiate CUTLASS kernel depending on templates
  fusedDistanceNN fusedDistanceNN_op;
  // Check the problem size is supported or not
  fusedDistanceNN_op.can_implement(arguments);
  // Initialize CUTLASS kernel with arguments and workspace pointer
  fusedDistanceNN_op.initialize(arguments, workspace, stream);
  // Launch initialized CUTLASS kernel
  fusedDistanceNN_op.run(stream);
}

#pragma GCC diagnostic pop
