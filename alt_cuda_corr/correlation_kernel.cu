#include <torch/extension.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <vector>


#define BLOCK_H 4
#define BLOCK_W 8
#define BLOCK_HW BLOCK_H * BLOCK_W
#define CHANNEL_STRIDE 32


__forceinline__ __device__
bool within_bounds(int h, int w, int H, int W) {
  return h >= 0 && h < H && w >= 0 && w < W;
}

template <typename scalar_t>
__global__ void corr_forward_kernel(
    const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> fmap1, // 4-dim tensor
    const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> fmap2, // 4-dim tensor
    const torch::PackedTensorAccessor32<scalar_t,5,torch::RestrictPtrTraits> coords,// 5-dim tensor
    torch::PackedTensorAccessor32<scalar_t,5,torch::RestrictPtrTraits> corr,        // 5-dim tensor
    int r) // the output would have (2r + 1)x(2r + 1) neighbors considered. it seems that spatial addressing wrt coords+radius bounds is performed
{
  const int b = blockIdx.x; // current example index in batch
  const int h0 = blockIdx.y * blockDim.x; // blockIdx.y is index of spatial horizontal line divided by blockDim.x (i.e. blockDim.x is loop stride for h0. does it correspond to BLOCK_H?)
  const int w0 = blockIdx.z * blockDim.y; // blockIdx.z is index of spatial vertical line divided by blockDim.y (i.e. blockDim.y is loop stride for w0. does it correspond to BLOCK_W?)
  const int tid = threadIdx.x * blockDim.y + threadIdx.y;

  // fmap1, fmap2 logical dimensions are [B, H, W, C] (fmap1 and fmap2 may well have different spatial dimensions for the spatial pyramid case). do coords have same spatial dims as fmap1? or fmap2?
  const int H1 = fmap1.size(1);
  const int W1 = fmap1.size(2);
  const int H2 = fmap2.size(1);
  const int W2 = fmap2.size(2);
  const int N = coords.size(1);
  const int C = fmap1.size(3);
  
  // it seems that a block accumulates correlations for CHANNEL_STRIDE number of channels (spaced by CHANNEL_STRIDE as well) and BLOCK_HW + 1 in spatial dimensions
  __shared__ scalar_t f1[CHANNEL_STRIDE][BLOCK_HW+1]; // copy buffer for fmap1 features corresponding to the spatial block and strided channels
  __shared__ scalar_t f2[CHANNEL_STRIDE][BLOCK_HW+1]; // copy buffer for fmap1 features corresponding to the spatial block and strided channels
  __shared__ scalar_t x2s[BLOCK_HW]; // x coordinate for spatial location in the block
  __shared__ scalar_t y2s[BLOCK_HW]; // y coordinate for spatial location in the block

  // outer loop over channels?
  for (int c=0; c<C; c+=CHANNEL_STRIDE) { // stride is 32
    
    // fills shared block of feature map f1 from fmap1 (spatial block BLOCK_HW by num of channels CHANNEL_STRIDE)
    for (int k=0; k<BLOCK_HW; k+=BLOCK_HW/CHANNEL_STRIDE) { // here stride is 1
      int k1 = k + tid / CHANNEL_STRIDE;
      int h1 = h0 + k1 / BLOCK_W;
      int w1 = w0 + k1 % BLOCK_W;
      int c1 = tid % CHANNEL_STRIDE;

      auto fptr = fmap1[b][h1][w1];
      if (within_bounds(h1, w1, H1, W1))
        f1[c1][k1] = fptr[c+c1];
      else
        f1[c1][k1] = 0.0; // padded by zero. does padding happen only at the right/bottom ends of tensor because of block granularity?
    }

    __syncthreads(); // wait in all threads and ensure copy-into-f1 completion

    // copy coords into shared block memory, N = 1. this does not depend on channel c. could this be done outside the outer loop?
    for (int n=0; n<N; n++) {
      int h1 = h0 + threadIdx.x; // seems that threadIdx.x is H coordinate within the spatial block
      int w1 = w0 + threadIdx.y; // seems that threadIdx.y is the W coordinate within the spatial block (confusing that "y" ~ W coord)
      if (within_bounds(h1, w1, H1, W1)) {
        x2s[tid] = coords[b][n][h1][w1][0];
        y2s[tid] = coords[b][n][h1][w1][1];
      }

      scalar_t dx = x2s[tid] - floor(x2s[tid]); // fractional part of x2s[tid] ? are coords [0, 1]? or [-1, 1]? or [0, W]?
      scalar_t dy = y2s[tid] - floor(y2s[tid]); // fractional part of y2s[tid] ?

      // iterate over spatial neighboring patches
      int rd = 2*r + 1; // spatial diameter size (i.e. square window side)
      for (int iy=0; iy<rd+1; iy++) {
        for (int ix=0; ix<rd+1; ix++) {
          for (int k=0; k<BLOCK_HW; k+=BLOCK_HW/CHANNEL_STRIDE) {
            int k1 = k + tid / CHANNEL_STRIDE;
            int h2 = static_cast<int>(floor(y2s[k1]))-r+iy;
            int w2 = static_cast<int>(floor(x2s[k1]))-r+ix;
            int c2 = tid % CHANNEL_STRIDE;

            // copy the neighboring patch from fmap2 to f2 (with zero padding)
            auto fptr = fmap2[b][h2][w2];
            if (within_bounds(h2, w2, H2, W2))
              f2[c2][k1] = fptr[c+c2];
            else
              f2[c2][k1] = 0.0;
          }

          __syncthreads();
      
          scalar_t s = 0.0;
          for (int k=0; k<CHANNEL_STRIDE; k++)
            s += f1[k][tid] * f2[k][tid]; // compute the dot product for the spatial and channel block

          int ix_nw = H1*W1*((iy-1) + rd*(ix-1));
          int ix_ne = H1*W1*((iy-1) + rd*ix);
          int ix_sw = H1*W1*(iy + rd*(ix-1));
          int ix_se = H1*W1*(iy + rd*ix);

          scalar_t nw = s * (dy) * (dx);
          scalar_t ne = s * (dy) * (1-dx);
          scalar_t sw = s * (1-dy) * (dx);
          scalar_t se = s * (1-dy) * (1-dx);

          // corr has logical dimensions [B, N, rd*rd, H, W], rd is radius * 2 + 1, N == 1 (defined below in corr_cuda_forward)
          scalar_t* corr_ptr = &corr[b][n][0][h1][w1]; // n and 0 seem exchanged. why? what is corr.stride(1)? does it matter?

          // filling out plane corr[b, 0, 0, h1, w1]. it seems that h1, w1 run over fmap1's spatial dims
          // it seems that a given a (h1, w1) x (h2, w2) dot product is contributed to several target (h1, w1) locations? (proportional to fractional residual)
          if (iy > 0 && ix > 0 && within_bounds(h1, w1, H1, W1))
            *(corr_ptr + ix_nw) += nw;

          if (iy > 0 && ix < rd && within_bounds(h1, w1, H1, W1))
            *(corr_ptr + ix_ne) += ne;

          if (iy < rd && ix > 0 && within_bounds(h1, w1, H1, W1))
            *(corr_ptr + ix_sw) += sw;

          if (iy < rd && ix < rd && within_bounds(h1, w1, H1, W1))
            *(corr_ptr + ix_se) += se;
        }
      } 
    }
  }
}


template <typename scalar_t>
__global__ void corr_backward_kernel(
    const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> fmap1,
    const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> fmap2,
    const torch::PackedTensorAccessor32<scalar_t,5,torch::RestrictPtrTraits> coords,
    const torch::PackedTensorAccessor32<scalar_t,5,torch::RestrictPtrTraits> corr_grad,
    torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> fmap1_grad,
    torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> fmap2_grad,
    torch::PackedTensorAccessor32<scalar_t,5,torch::RestrictPtrTraits> coords_grad,
    int r)
{

  const int b = blockIdx.x;
  const int h0 = blockIdx.y * blockDim.x;
  const int w0 = blockIdx.z * blockDim.y;
  const int tid = threadIdx.x * blockDim.y + threadIdx.y;

  const int H1 = fmap1.size(1);
  const int W1 = fmap1.size(2);
  const int H2 = fmap2.size(1);
  const int W2 = fmap2.size(2);
  const int N = coords.size(1);
  const int C = fmap1.size(3);

  __shared__ scalar_t f1[CHANNEL_STRIDE][BLOCK_HW+1];
  __shared__ scalar_t f2[CHANNEL_STRIDE][BLOCK_HW+1];

  __shared__ scalar_t f1_grad[CHANNEL_STRIDE][BLOCK_HW+1];
  __shared__ scalar_t f2_grad[CHANNEL_STRIDE][BLOCK_HW+1];

  __shared__ scalar_t x2s[BLOCK_HW];
  __shared__ scalar_t y2s[BLOCK_HW];

  for (int c=0; c<C; c+=CHANNEL_STRIDE) {

    for (int k=0; k<BLOCK_HW; k+=BLOCK_HW/CHANNEL_STRIDE) {
      int k1 = k + tid / CHANNEL_STRIDE;
      int h1 = h0 + k1 / BLOCK_W;
      int w1 = w0 + k1 % BLOCK_W;
      int c1 = tid % CHANNEL_STRIDE;

      auto fptr = fmap1[b][h1][w1];
      if (within_bounds(h1, w1, H1, W1))
        f1[c1][k1] = fptr[c+c1];
      else
        f1[c1][k1] = 0.0;

      f1_grad[c1][k1] = 0.0;
    }

    __syncthreads();

    int h1 = h0 + threadIdx.x;
    int w1 = w0 + threadIdx.y;

    for (int n=0; n<N; n++) {  
      x2s[tid] = coords[b][n][h1][w1][0];
      y2s[tid] = coords[b][n][h1][w1][1];

      scalar_t dx = x2s[tid] - floor(x2s[tid]);
      scalar_t dy = y2s[tid] - floor(y2s[tid]);

      int rd = 2*r + 1;
      for (int iy=0; iy<rd+1; iy++) {
        for (int ix=0; ix<rd+1; ix++) {
          for (int k=0; k<BLOCK_HW; k+=BLOCK_HW/CHANNEL_STRIDE) {
            int k1 = k + tid / CHANNEL_STRIDE;
            int h2 = static_cast<int>(floor(y2s[k1]))-r+iy;
            int w2 = static_cast<int>(floor(x2s[k1]))-r+ix;
            int c2 = tid % CHANNEL_STRIDE;

            auto fptr = fmap2[b][h2][w2];
            if (within_bounds(h2, w2, H2, W2))
              f2[c2][k1] = fptr[c+c2];
            else
              f2[c2][k1] = 0.0;

            f2_grad[c2][k1] = 0.0;
          }

          __syncthreads();
      
          const scalar_t* grad_ptr = &corr_grad[b][n][0][h1][w1];
          scalar_t g = 0.0;

          int ix_nw = H1*W1*((iy-1) + rd*(ix-1));
          int ix_ne = H1*W1*((iy-1) + rd*ix);
          int ix_sw = H1*W1*(iy + rd*(ix-1));
          int ix_se = H1*W1*(iy + rd*ix);

          if (iy > 0 && ix > 0 && within_bounds(h1, w1, H1, W1))
            g +=  *(grad_ptr + ix_nw) * dy * dx;

          if (iy > 0 && ix < rd && within_bounds(h1, w1, H1, W1))
            g += *(grad_ptr + ix_ne) * dy * (1-dx);

          if (iy < rd && ix > 0 && within_bounds(h1, w1, H1, W1))
            g += *(grad_ptr + ix_sw) * (1-dy) * dx;

          if (iy < rd && ix < rd && within_bounds(h1, w1, H1, W1))
            g += *(grad_ptr + ix_se) * (1-dy) * (1-dx);
            
          for (int k=0; k<CHANNEL_STRIDE; k++) {
            f1_grad[k][tid] += g * f2[k][tid];
            f2_grad[k][tid] += g * f1[k][tid];
          }

          for (int k=0; k<BLOCK_HW; k+=BLOCK_HW/CHANNEL_STRIDE) {
            int k1 = k + tid / CHANNEL_STRIDE;
            int h2 = static_cast<int>(floor(y2s[k1]))-r+iy;
            int w2 = static_cast<int>(floor(x2s[k1]))-r+ix;
            int c2 = tid % CHANNEL_STRIDE;

            scalar_t* fptr = &fmap2_grad[b][h2][w2][0];
            if (within_bounds(h2, w2, H2, W2))
              atomicAdd(fptr+c+c2, f2_grad[c2][k1]);
          }
        }
      } 
    }
    __syncthreads();


    for (int k=0; k<BLOCK_HW; k+=BLOCK_HW/CHANNEL_STRIDE) {
      int k1 = k + tid / CHANNEL_STRIDE;
      int h1 = h0 + k1 / BLOCK_W;
      int w1 = w0 + k1 % BLOCK_W;
      int c1 = tid % CHANNEL_STRIDE;

      scalar_t* fptr = &fmap1_grad[b][h1][w1][0];
      if (within_bounds(h1, w1, H1, W1))
        fptr[c+c1] += f1_grad[c1][k1];
    }
  }
}



std::vector<torch::Tensor> corr_cuda_forward(
  torch::Tensor fmap1,
  torch::Tensor fmap2,
  torch::Tensor coords,
  int radius)
{
  const auto B = coords.size(0);
  const auto N = coords.size(1);
  const auto H = coords.size(2);
  const auto W = coords.size(3);

  const auto rd = 2 * radius + 1;
  auto opts = fmap1.options();
  auto corr = torch::zeros({B, N, rd*rd, H, W}, opts);
  
  const dim3 blocks(B, (H+BLOCK_H-1)/BLOCK_H, (W+BLOCK_W-1)/BLOCK_W);
  const dim3 threads(BLOCK_H, BLOCK_W);

  corr_forward_kernel<float><<<blocks, threads>>>(
    fmap1.packed_accessor32<float,4,torch::RestrictPtrTraits>(),
    fmap2.packed_accessor32<float,4,torch::RestrictPtrTraits>(),
    coords.packed_accessor32<float,5,torch::RestrictPtrTraits>(),
    corr.packed_accessor32<float,5,torch::RestrictPtrTraits>(),
    radius);

  return {corr};
}

std::vector<torch::Tensor> corr_cuda_backward(
  torch::Tensor fmap1,
  torch::Tensor fmap2,
  torch::Tensor coords,
  torch::Tensor corr_grad,
  int radius)
{
  const auto B = coords.size(0);
  const auto N = coords.size(1);

  const auto H1 = fmap1.size(1);
  const auto W1 = fmap1.size(2);
  const auto H2 = fmap2.size(1);
  const auto W2 = fmap2.size(2);
  const auto C = fmap1.size(3);

  auto opts = fmap1.options();
  auto fmap1_grad = torch::zeros({B, H1, W1, C}, opts);
  auto fmap2_grad = torch::zeros({B, H2, W2, C}, opts);
  auto coords_grad = torch::zeros({B, N, H1, W1, 2}, opts);
    
  const dim3 blocks(B, (H1+BLOCK_H-1)/BLOCK_H, (W1+BLOCK_W-1)/BLOCK_W);
  const dim3 threads(BLOCK_H, BLOCK_W);


  corr_backward_kernel<float><<<blocks, threads>>>(
    fmap1.packed_accessor32<float,4,torch::RestrictPtrTraits>(),
    fmap2.packed_accessor32<float,4,torch::RestrictPtrTraits>(),
    coords.packed_accessor32<float,5,torch::RestrictPtrTraits>(),
    corr_grad.packed_accessor32<float,5,torch::RestrictPtrTraits>(),
    fmap1_grad.packed_accessor32<float,4,torch::RestrictPtrTraits>(),
    fmap2_grad.packed_accessor32<float,4,torch::RestrictPtrTraits>(),
    coords_grad.packed_accessor32<float,5,torch::RestrictPtrTraits>(),
    radius);

  return {fmap1_grad, fmap2_grad, coords_grad};
}
