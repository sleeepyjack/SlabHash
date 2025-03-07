/*
 * Copyright 2019 Saman Ashkiani
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
 * implied. See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

template <typename KeyT, typename ValueT, uint32_t log_num_mem_blocks, uint32_t num_super_blocks>
void GpuSlabHash<KeyT, ValueT, SlabHashTypeT::ConcurrentMap, log_num_mem_blocks, num_super_blocks>::resize() {
  dynamic_allocator_->growPool();
  gpu_context_.updateAllocatorContext(dynamic_allocator_->getContextPtr());
}

template <typename KeyT, typename ValueT, uint32_t log_num_mem_blocks, uint32_t num_super_blocks>
uint32_t GpuSlabHash<KeyT, ValueT, SlabHashTypeT::ConcurrentMap, 
                     log_num_mem_blocks, num_super_blocks>::checkForPreemptiveResize(uint32_t keysAdded) {
  auto numSlabs = gpu_context_.getTotalNumSlabs();
  
  auto capacity = numSlabs * 16; // capacity in key-value size multiples
  auto finalNumKeys = gpu_context_.getTotalNumKeys() + keysAdded;
  auto finalSlabLoadFactor = (float) (finalNumKeys) / capacity;
  auto numResizes = 0;

  if(finalSlabLoadFactor >= thresh_lf_) {
    numResizes = 1;
  }

  return numResizes;
}

template <typename KeyT, typename ValueT, uint32_t log_num_mem_blocks, uint32_t num_super_blocks>
void GpuSlabHash<KeyT, ValueT, SlabHashTypeT::ConcurrentMap, 
                 log_num_mem_blocks, num_super_blocks>::buildBulk(
    KeyT* d_key,
    ValueT* d_value,
    uint32_t num_keys) {
  
  const uint32_t num_blocks = (num_keys + BLOCKSIZE_ - 1) / BLOCKSIZE_;
  CHECK_CUDA_ERROR(cudaSetDevice(device_idx_));
  auto numResizes = checkForPreemptiveResize(num_keys);
  for(auto i = 0; i < numResizes; ++i) {
    resize();
  }

  // calling the kernel for bulk build:
  build_table_kernel<KeyT, ValueT>
      <<<num_blocks, BLOCKSIZE_>>>(d_key, d_value, num_keys, gpu_context_);
  CHECK_CUDA_ERROR(cudaDeviceSynchronize());
  
  // now that the bulk insert has completed successfully, we can
  // update the total number of keys in the table
  gpu_context_.updateTotalNumKeys(num_keys);
}

template <typename KeyT, typename ValueT, uint32_t log_num_mem_blocks, uint32_t num_super_blocks>
void GpuSlabHash<KeyT, ValueT, SlabHashTypeT::ConcurrentMap, 
                 log_num_mem_blocks, num_super_blocks>::buildBulkWithUniqueKeys(
  KeyT* d_key,
  ValueT* d_value,
  uint32_t num_keys) {
  
  const uint32_t num_blocks = (num_keys + BLOCKSIZE_ - 1) / BLOCKSIZE_;
  CHECK_CUDA_ERROR(cudaSetDevice(device_idx_));
  auto numResizes = checkForPreemptiveResize(num_keys);
  for(auto i = 0; i < numResizes; ++i) {
    resize();
  }

  // calling the kernel for bulk build:
  int *num_successes;
  CHECK_CUDA_ERROR(cudaMallocManaged(&num_successes, sizeof(int)));
  *num_successes = 0;

  build_table_with_unique_keys_kernel<KeyT, ValueT>
      <<<num_blocks, BLOCKSIZE_>>>(num_successes, d_key, d_value, num_keys, gpu_context_);
  CHECK_CUDA_ERROR(cudaDeviceSynchronize());
  
  // now that the bulk insert has completed successfully, we can
  // update the total number of keys in the table
  gpu_context_.updateTotalNumKeys(*num_successes);
}

template <typename KeyT, typename ValueT, uint32_t log_num_mem_blocks, uint32_t num_super_blocks>
void GpuSlabHash<KeyT, ValueT, SlabHashTypeT::ConcurrentMap, 
                 log_num_mem_blocks, num_super_blocks>::searchIndividual(
    KeyT* d_query,
    ValueT* d_result,
    uint32_t num_queries) {
  CHECK_CUDA_ERROR(cudaSetDevice(device_idx_));
  const uint32_t num_blocks = (num_queries + BLOCKSIZE_ - 1) / BLOCKSIZE_;
  search_table<KeyT, ValueT>
      <<<num_blocks, BLOCKSIZE_>>>(d_query, d_result, num_queries, gpu_context_);
}

template <typename KeyT, typename ValueT, uint32_t log_num_mem_blocks, uint32_t num_super_blocks>
void GpuSlabHash<KeyT, ValueT, SlabHashTypeT::ConcurrentMap, 
                 log_num_mem_blocks, num_super_blocks>::searchBulk(
    KeyT* d_query,
    ValueT* d_result,
    uint32_t num_queries) {
  CHECK_CUDA_ERROR(cudaSetDevice(device_idx_));
  const uint32_t num_blocks = (num_queries + BLOCKSIZE_ - 1) / BLOCKSIZE_;
  search_table_bulk<KeyT, ValueT>
      <<<num_blocks, BLOCKSIZE_>>>(d_query, d_result, num_queries, gpu_context_);
}

template <typename KeyT, typename ValueT, uint32_t log_num_mem_blocks, uint32_t num_super_blocks>
void GpuSlabHash<KeyT, ValueT, SlabHashTypeT::ConcurrentMap, 
                 log_num_mem_blocks, num_super_blocks>::countIndividual(
    KeyT* d_query,
    uint32_t* d_count,
    uint32_t num_queries) {
  CHECK_CUDA_ERROR(cudaSetDevice(device_idx_));
  const uint32_t num_blocks = (num_queries + BLOCKSIZE_ - 1) / BLOCKSIZE_;
  count_key<KeyT, ValueT>
      <<<num_blocks, BLOCKSIZE_>>>(d_query, d_count, num_queries, gpu_context_);
}

template <typename KeyT, typename ValueT, uint32_t log_num_mem_blocks, uint32_t num_super_blocks>
void GpuSlabHash<KeyT, ValueT, SlabHashTypeT::ConcurrentMap, 
                 log_num_mem_blocks, num_super_blocks>::deleteIndividual(
    KeyT* d_key,
    uint32_t num_keys) {
  CHECK_CUDA_ERROR(cudaSetDevice(device_idx_));
  const uint32_t num_blocks = (num_keys + BLOCKSIZE_ - 1) / BLOCKSIZE_;
  delete_table_keys<KeyT, ValueT>
      <<<num_blocks, BLOCKSIZE_>>>(d_key, num_keys, gpu_context_);
}

// perform a batch of (a mixture of) updates/searches
template <typename KeyT, typename ValueT, uint32_t log_num_mem_blocks, uint32_t num_super_blocks>
void GpuSlabHash<KeyT, ValueT, SlabHashTypeT::ConcurrentMap, 
                 log_num_mem_blocks, num_super_blocks>::batchedOperation(
    KeyT* d_key,
    ValueT* d_result,
    uint32_t num_ops) {
  CHECK_CUDA_ERROR(cudaSetDevice(device_idx_));
  const uint32_t num_blocks = (num_ops + BLOCKSIZE_ - 1) / BLOCKSIZE_;
  batched_operations<KeyT, ValueT>
      <<<num_blocks, BLOCKSIZE_>>>(d_key, d_result, num_ops, gpu_context_);
}

template <typename KeyT, typename ValueT, uint32_t log_num_mem_blocks, uint32_t num_super_blocks>
std::string GpuSlabHash<KeyT, ValueT, SlabHashTypeT::ConcurrentMap, 
                        log_num_mem_blocks, num_super_blocks>::to_string() {
  std::string result;
  result += " ==== GpuSlabHash: \n";
  result += "\t Running on device \t\t " + std::to_string(device_idx_) + "\n";
  result += "\t SlabHashType:     \t\t " + gpu_context_.getSlabHashTypeName() + "\n";
  result += "\t Number of buckets:\t\t " + std::to_string(num_buckets_) + "\n";
  result += "\t d_table_ address: \t\t " +
            std::to_string(reinterpret_cast<uint64_t>(static_cast<void*>(d_table_))) +
            "\n";
  result += "\t hash function = \t\t (" + std::to_string(hf_.x) + ", " +
            std::to_string(hf_.y) + ")\n";
  return result;
}

template <typename KeyT, typename ValueT, uint32_t log_num_mem_blocks, uint32_t num_super_blocks>
double GpuSlabHash<KeyT, ValueT, SlabHashTypeT::ConcurrentMap, 
                   log_num_mem_blocks, num_super_blocks>::computeLoadFactor(
    int flag = 0) {
  uint32_t* h_bucket_pairs_count = new uint32_t[num_buckets_];
  uint32_t* d_bucket_pairs_count;
  CHECK_CUDA_ERROR(
      cudaMalloc((void**)&d_bucket_pairs_count, sizeof(uint32_t) * num_buckets_));
  CHECK_CUDA_ERROR(cudaMemset(d_bucket_pairs_count, 0, sizeof(uint32_t) * num_buckets_));

  uint32_t* h_bucket_slabs_count = new uint32_t[num_buckets_];
  uint32_t* d_bucket_slabs_count;
  CHECK_CUDA_ERROR(
      cudaMalloc((void**)&d_bucket_slabs_count, sizeof(uint32_t) * num_buckets_));
  CHECK_CUDA_ERROR(cudaMemset(d_bucket_slabs_count, 0, sizeof(uint32_t) * num_buckets_));

  //---------------------------------
  // counting the number of inserted elements:
  const uint32_t blocksize = 128;
  const uint32_t num_blocks = (num_buckets_ * 32 + blocksize - 1) / blocksize;
  bucket_count_kernel<KeyT, ValueT><<<num_blocks, blocksize>>>(
      gpu_context_, d_bucket_pairs_count, d_bucket_slabs_count, num_buckets_);
  CHECK_CUDA_ERROR(cudaMemcpy(h_bucket_pairs_count,
                              d_bucket_pairs_count,
                              sizeof(uint32_t) * num_buckets_,
                              cudaMemcpyDeviceToHost));
  CHECK_CUDA_ERROR(cudaMemcpy(h_bucket_slabs_count,
                              d_bucket_slabs_count,
                              sizeof(uint32_t) * num_buckets_,
                              cudaMemcpyDeviceToHost));
  int total_elements_stored = 0;
  int total_slabs_used = 0;
  for (int i = 0; i < num_buckets_; i++) {
    total_elements_stored += h_bucket_pairs_count[i];
    total_slabs_used += h_bucket_slabs_count[i];
  }
  if (flag) {
    printf("## Total elements stored: %d (%lu bytes).\n",
           total_elements_stored,
           total_elements_stored * (sizeof(KeyT) + sizeof(ValueT)));
    printf("## Total number of slabs used: %d.\n", total_slabs_used);
  }

  // computing load factor
  double load_factor = double(total_elements_stored * (sizeof(KeyT) + sizeof(ValueT))) /
                       double(total_slabs_used * WARP_WIDTH_ * sizeof(uint32_t));

  if (d_bucket_pairs_count)
    CHECK_ERROR(cudaFree(d_bucket_pairs_count));
  if (d_bucket_slabs_count)
    CHECK_ERROR(cudaFree(d_bucket_slabs_count));
  delete[] h_bucket_pairs_count;
  delete[] h_bucket_slabs_count;

  return load_factor;
}