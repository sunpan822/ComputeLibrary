/*
 * Copyright (c) 2018-2019 ARM Limited.
 *
 * SPDX-License-Identifier: MIT
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to
 * deal in the Software without restriction, including without limitation the
 * rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
 * sell copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
#include "helpers.h"

#if defined(FUSED_ACTIVATION)
#include "activation_layer.cl"
#define ACTIVATION_FUNC(x) ACTIVATION_OP(FUSED_ACTIVATION, x)
#else /* defined(FUSED_ACTIVATION) */
#define ACTIVATION_FUNC(x) (x)
#endif /* defined(FUSED_ACTIVATION) */

#if defined(NUM_TILES_X) && defined(OUTPUT_TILE_W) && defined(OUTPUT_TILE_H)
#if defined(VEC_SIZE) && VEC_SIZE == 2
/** This OpenCL kernel performs Winograd output transform when the output tile is 2x2/2x1 or 1x2, the filter size 3x3/3x1 or 1x3 and the data layout is NCHW
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=2
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=2
 * @note If this kernel is used to perform Winograd output transform 3x1, -DWINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL has to be passed at compile time
 * @note If this kernel is used to perform Winograd output transform 1x3, -DWINOGRAD_OUTPUT_TRANSFORM_VERTICAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 * @note It is possible to select the activation function to apply using -DFUSED_ACTIVATION e.g. -DFUSED_ACTIVATION=relu
 * @note A, B variables required by some activation functions are set using -DA_VAL= and -DB_VAL= respectively.
 * @note Vector size should be given as a preprocessor argument using -DVEC_SIZE=size. Accepted values are -DVEC_SIZE=2 (for output_tile_size 2x2, 2x1, 1x2) and -DVEC_SIZE=4 (for output_tile_size 4x4, 4x1, 1x4)
 * @note Select data type should be given too with -DSELECT_DATA_TYPE e.g -DSELECT_DATA_TYPE=int
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_2x2_3x3_nchw(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst)
#if defined(HAS_BIAS)
    ,
    VECTOR_DECLARATION(bias)
#endif // defined(HAS_BIAS)
)
{
    // Each thread stores a 2x2/2x1 or 1x2 tile accordingly with the filter size
#if defined(SRC_DEPTH)
    Tensor4D       src             = CONVERT_TO_TENSOR4D_STRUCT(src, SRC_DEPTH);
    const __global uchar *src_addr = tensor4D_offset(&src, 0, 0, 0, 0);
#else  /* defined(SRC_DEPTH) */
    Tensor3D       src             = CONVERT_TO_TENSOR3D_STRUCT(src);
    const __global uchar *src_addr = tensor3D_offset(&src, 0, 0, 0);
#endif /* defined(SRC_DEPTH) */

    // Load the values across the 16 or 4 channels to compose the 4x4 or 4x1 tile
    DATA_TYPE d00 = *((__global DATA_TYPE *)(src_addr + 0 * src_stride_z));
    DATA_TYPE d01 = *((__global DATA_TYPE *)(src_addr + 1 * src_stride_z));
    DATA_TYPE d02 = *((__global DATA_TYPE *)(src_addr + 2 * src_stride_z));
    DATA_TYPE d03 = *((__global DATA_TYPE *)(src_addr + 3 * src_stride_z));

#if defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    // Compute the 2x1 or 1x2 output tile
    // out00 = d00 + d01 + d02
    // out01 = d01 - d02 - d03

    float out00 = d00 + d01 + d02;
    float out01 = d01 - d02 - d03;
#else  // defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

    DATA_TYPE d10 = *((__global DATA_TYPE *)(src_addr + 4 * src_stride_z));
    DATA_TYPE d11 = *((__global DATA_TYPE *)(src_addr + 5 * src_stride_z));
    DATA_TYPE d12 = *((__global DATA_TYPE *)(src_addr + 6 * src_stride_z));
    DATA_TYPE d13 = *((__global DATA_TYPE *)(src_addr + 7 * src_stride_z));

    DATA_TYPE d20 = *((__global DATA_TYPE *)(src_addr + 8 * src_stride_z));
    DATA_TYPE d21 = *((__global DATA_TYPE *)(src_addr + 9 * src_stride_z));
    DATA_TYPE d22 = *((__global DATA_TYPE *)(src_addr + 10 * src_stride_z));
    DATA_TYPE d23 = *((__global DATA_TYPE *)(src_addr + 11 * src_stride_z));

    DATA_TYPE d30 = *((__global DATA_TYPE *)(src_addr + 12 * src_stride_z));
    DATA_TYPE d31 = *((__global DATA_TYPE *)(src_addr + 13 * src_stride_z));
    DATA_TYPE d32 = *((__global DATA_TYPE *)(src_addr + 14 * src_stride_z));
    DATA_TYPE d33 = *((__global DATA_TYPE *)(src_addr + 15 * src_stride_z));

    // Compute the 2x2 output tile
    float k0 = d01 + d11 + d21;
    float k1 = d02 + d12 + d22;
    float k2 = d11 - d21 - d31;
    float k3 = d12 - d22 - d32;

    // out00 = d00 + d10 + d20 + d01 + d11 + d21 + d02 + d12 + d22
    // out01 = d01 + d11 + d21 - (d02 + d12 + d22) - (d03 + d13 + d23)
    // out10 = d10 - d20 - d30 + (d11 - d21 - d31) + (d12 - d22 - d32)
    // out11 = d11 - d21 - d31 - (d12 - d22 - d32) - (d13 - d23 - d33)

    float out00 = d10;
    float out01 = -d13;
    float out10 = d10;
    float out11 = -d13;

    out00 += d00 + d20 + k0 + k1;
    out01 += k0 - k1 - (d03 + d23);
    out10 += -d20 - d30 + k2 + k3;
    out11 += k2 - k3 + d23 + d33;
#endif // defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

    int y_in  = get_global_id(1);
    int x_out = (y_in % NUM_TILES_X) * OUTPUT_TILE_W;
    int y_out = (y_in / NUM_TILES_X) * OUTPUT_TILE_H;
    int z_out = get_global_id(0);
#if defined(SRC_DEPTH)
    int batch = get_global_id(2) / SRC_DEPTH;
#endif /* defined(SRC_DEPTH) */

#if defined(HAS_BIAS)
    // Add bias
    Vector bias = CONVERT_TO_VECTOR_STRUCT_NO_STEP(bias);

    float b = (float) * ((__global DATA_TYPE *)(vector_offset(&bias, z_out)));

    out00 += (float)b;
    out01 += (float)b;
#endif // defined(HAS_BIAS)

    // Get output address
#if defined(SRC_DEPTH)
    __global uchar *dst_addr = dst_ptr + dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z + batch * dst_stride_w;
#else  /* defined(SRC_DEPTH) */
    __global uchar *dst_addr = dst_ptr + dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z;
#endif /* defined(SRC_DEPTH) */

    // Store the output tile
#if defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    const const VEC_DATA_TYPE(DATA_TYPE, 2)
    out0_dt                                            = ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 2))(out00, out01), VEC_DATA_TYPE(DATA_TYPE, 2)));
    *((__global DATA_TYPE *)(dst_addr + 0 * dst_stride_y)) = out0_dt.s0;
    *((__global DATA_TYPE *)(dst_addr + 1 * dst_stride_y)) = out0_dt.s1;
#else  // defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    vstore2(ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 2))(out00, out01), VEC_DATA_TYPE(DATA_TYPE, 2))), 0, (__global DATA_TYPE *)(dst_addr + 0 * dst_stride_y));
#endif // defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

#if !defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) && !defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
#if defined(HAS_BIAS)
    // Add bias
    out10 += (DATA_TYPE)b;
    out11 += (DATA_TYPE)b;
#endif // defined(HAS_BIAS)
    vstore2(ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 2))(out10, out11), VEC_DATA_TYPE(DATA_TYPE, 2))), 0, (__global DATA_TYPE *)(dst_addr + 1 * dst_stride_y));
#endif // !defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) && !defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
}

#define COMPUTE_TMP_COL_2x2_7x7(col, d0, d1, d2, d3, d4, d5, d6, d7) \
    ({                                                               \
        col.s0 = d0 + d1 + d2 + d3 + d4 + d5 + d6;                   \
        col.s1 = -d1 + d2 - 2 * d3 + 2 * d4 + -3 * d5 + 3 * d6 + d7; \
    })

/** This OpenCL kernel performs Winograd output transform when the output tile is 2x2/2x1 or 1x2, the filter size 7x7/7x1 or 1x7 and the data layout is NHWC
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=2
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=2
 * @note If this kernel is used to perform Winograd output transform 7x1, -DWINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL has to be passed at compile time
 * @note If this kernel is used to perform Winograd output transform 1x7, -DWINOGRAD_OUTPUT_TRANSFORM_VERTICAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_2x2_7x7_nhwc(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst),
#if defined(HAS_BIAS)
    VECTOR_DECLARATION(bias),
#endif // defined(HAS_BIAS)
    int dst_size)
{
    // Each thread stores a 4x4/4x1 or 1x4 tile
#if defined(SRC_DEPTH)
    Tensor4D       src             = CONVERT_TO_TENSOR4D_STRUCT(src, SRC_DEPTH);
    const __global uchar *src_addr = tensor4D_offset(&src, 0, 0, 0, 0);
#else  /* defined(SRC_DEPTH) */
    Tensor3D       src             = CONVERT_TO_TENSOR3D_STRUCT(src);
    const __global uchar *src_addr = tensor3D_offset(&src, 0, 0, 0);
#endif /* defined(SRC_DEPTH) */

    int y_in  = get_global_id(1);
    int x_out = get_global_id(0);
    int y_out = (y_in % NUM_TILES_X) * OUTPUT_TILE_W;
    int z_out = (y_in / NUM_TILES_X) * OUTPUT_TILE_H;
#if defined(SRC_DEPTH)
    int batch = get_global_id(2) / SRC_DEPTH;
#endif /* defined(SRC_DEPTH) */

#if defined(SRC_DEPTH)
    __global uchar *dst_addr = dst_ptr + dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z + batch * dst_stride_w;
#else  /* defined(SRC_DEPTH) */

    __global uchar *dst_addr = dst_ptr + dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z;
#endif /* defined(SRC_DEPTH) */

    // Load the values across the channels to compose the input tile
    DATA_TYPE d00 = *((__global DATA_TYPE *)(src_addr + 0 * src_stride_z));
    DATA_TYPE d01 = *((__global DATA_TYPE *)(src_addr + 1 * src_stride_z));
    DATA_TYPE d02 = *((__global DATA_TYPE *)(src_addr + 2 * src_stride_z));
    DATA_TYPE d03 = *((__global DATA_TYPE *)(src_addr + 3 * src_stride_z));
    DATA_TYPE d04 = *((__global DATA_TYPE *)(src_addr + 4 * src_stride_z));
    DATA_TYPE d05 = *((__global DATA_TYPE *)(src_addr + 5 * src_stride_z));
    DATA_TYPE d06 = *((__global DATA_TYPE *)(src_addr + 6 * src_stride_z));
    DATA_TYPE d07 = *((__global DATA_TYPE *)(src_addr + 7 * src_stride_z));

#if defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    // Compute out00, out01, out02 and out03
    float out00 = d00 + d01 + d02 + d03 + d04 + d05 + d06;
    float out01 = -d01 + d02 - 2.f * d03 + 2.0f * d04 - 3.0f * d05 + 3.0f * d06 + d07;

#if defined(HAS_BIAS)
    // Add bias
    Vector bias = CONVERT_TO_VECTOR_STRUCT_NO_STEP(bias);

    float b = (float) * ((__global DATA_TYPE *)(vector_offset(&bias, x_out)));

    out00 += (float)b;
    out01 += (float)b;
#endif // defined(HAS_BIAS)

    // Store the output tile
#if defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    // Get output address
#if defined(SRC_DEPTH)
    int2 offset = (int2)(dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z + batch * dst_stride_w);
#else                                                                         /* defined(SRC_DEPTH) */
    int2 offset = (int2)(dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z);
#endif                                                                        /* defined(SRC_DEPTH) */
    offset = min(offset + (int2)(0, 1) * (int2)dst_stride_z, (int2)dst_size); // If address is beyond the last plane, clamp it to dst_size (which points to the last padding).

    VEC_DATA_TYPE(DATA_TYPE, 2)
    out0_dt                                      = ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 2))(out00, out01), VEC_DATA_TYPE(DATA_TYPE, 2)));
    *(__global DATA_TYPE *)(dst_ptr + offset.s0) = out0_dt.s0;
    *(__global DATA_TYPE *)(dst_ptr + offset.s1) = out0_dt.s1;
#else  // defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    // Get output address
    int offset = dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z;
    VEC_DATA_TYPE(DATA_TYPE, 2)
    out0_dt                                                      = ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 2))(out00, out01), VEC_DATA_TYPE(DATA_TYPE, 2)));
    *(__global DATA_TYPE *)(dst_ptr + 0 * dst_stride_y + offset) = out0_dt.s0;
    *(__global DATA_TYPE *)(dst_ptr + 1 * dst_stride_y + offset) = out0_dt.s1;
#endif // defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

#else // defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

    DATA_TYPE d10 = *((__global DATA_TYPE *)(src_addr + 8 * src_stride_z));
    DATA_TYPE d11 = *((__global DATA_TYPE *)(src_addr + 9 * src_stride_z));
    DATA_TYPE d12 = *((__global DATA_TYPE *)(src_addr + 10 * src_stride_z));
    DATA_TYPE d13 = *((__global DATA_TYPE *)(src_addr + 11 * src_stride_z));
    DATA_TYPE d14 = *((__global DATA_TYPE *)(src_addr + 12 * src_stride_z));
    DATA_TYPE d15 = *((__global DATA_TYPE *)(src_addr + 13 * src_stride_z));
    DATA_TYPE d16 = *((__global DATA_TYPE *)(src_addr + 14 * src_stride_z));
    DATA_TYPE d17 = *((__global DATA_TYPE *)(src_addr + 15 * src_stride_z));

    DATA_TYPE d20 = *((__global DATA_TYPE *)(src_addr + 16 * src_stride_z));
    DATA_TYPE d21 = *((__global DATA_TYPE *)(src_addr + 17 * src_stride_z));
    DATA_TYPE d22 = *((__global DATA_TYPE *)(src_addr + 18 * src_stride_z));
    DATA_TYPE d23 = *((__global DATA_TYPE *)(src_addr + 19 * src_stride_z));
    DATA_TYPE d24 = *((__global DATA_TYPE *)(src_addr + 20 * src_stride_z));
    DATA_TYPE d25 = *((__global DATA_TYPE *)(src_addr + 21 * src_stride_z));
    DATA_TYPE d26 = *((__global DATA_TYPE *)(src_addr + 22 * src_stride_z));
    DATA_TYPE d27 = *((__global DATA_TYPE *)(src_addr + 23 * src_stride_z));

    DATA_TYPE d30 = *((__global DATA_TYPE *)(src_addr + 24 * src_stride_z));
    DATA_TYPE d31 = *((__global DATA_TYPE *)(src_addr + 25 * src_stride_z));
    DATA_TYPE d32 = *((__global DATA_TYPE *)(src_addr + 26 * src_stride_z));
    DATA_TYPE d33 = *((__global DATA_TYPE *)(src_addr + 27 * src_stride_z));
    DATA_TYPE d34 = *((__global DATA_TYPE *)(src_addr + 28 * src_stride_z));
    DATA_TYPE d35 = *((__global DATA_TYPE *)(src_addr + 29 * src_stride_z));
    DATA_TYPE d36 = *((__global DATA_TYPE *)(src_addr + 30 * src_stride_z));
    DATA_TYPE d37 = *((__global DATA_TYPE *)(src_addr + 31 * src_stride_z));

    DATA_TYPE d40 = *((__global DATA_TYPE *)(src_addr + 32 * src_stride_z));
    DATA_TYPE d41 = *((__global DATA_TYPE *)(src_addr + 33 * src_stride_z));
    DATA_TYPE d42 = *((__global DATA_TYPE *)(src_addr + 34 * src_stride_z));
    DATA_TYPE d43 = *((__global DATA_TYPE *)(src_addr + 35 * src_stride_z));
    DATA_TYPE d44 = *((__global DATA_TYPE *)(src_addr + 36 * src_stride_z));
    DATA_TYPE d45 = *((__global DATA_TYPE *)(src_addr + 37 * src_stride_z));
    DATA_TYPE d46 = *((__global DATA_TYPE *)(src_addr + 38 * src_stride_z));
    DATA_TYPE d47 = *((__global DATA_TYPE *)(src_addr + 39 * src_stride_z));

    DATA_TYPE d50 = *((__global DATA_TYPE *)(src_addr + 40 * src_stride_z));
    DATA_TYPE d51 = *((__global DATA_TYPE *)(src_addr + 41 * src_stride_z));
    DATA_TYPE d52 = *((__global DATA_TYPE *)(src_addr + 42 * src_stride_z));
    DATA_TYPE d53 = *((__global DATA_TYPE *)(src_addr + 43 * src_stride_z));
    DATA_TYPE d54 = *((__global DATA_TYPE *)(src_addr + 44 * src_stride_z));
    DATA_TYPE d55 = *((__global DATA_TYPE *)(src_addr + 45 * src_stride_z));
    DATA_TYPE d56 = *((__global DATA_TYPE *)(src_addr + 46 * src_stride_z));
    DATA_TYPE d57 = *((__global DATA_TYPE *)(src_addr + 47 * src_stride_z));

    DATA_TYPE d60 = *((__global DATA_TYPE *)(src_addr + 48 * src_stride_z));
    DATA_TYPE d61 = *((__global DATA_TYPE *)(src_addr + 49 * src_stride_z));
    DATA_TYPE d62 = *((__global DATA_TYPE *)(src_addr + 50 * src_stride_z));
    DATA_TYPE d63 = *((__global DATA_TYPE *)(src_addr + 51 * src_stride_z));
    DATA_TYPE d64 = *((__global DATA_TYPE *)(src_addr + 52 * src_stride_z));
    DATA_TYPE d65 = *((__global DATA_TYPE *)(src_addr + 53 * src_stride_z));
    DATA_TYPE d66 = *((__global DATA_TYPE *)(src_addr + 54 * src_stride_z));
    DATA_TYPE d67 = *((__global DATA_TYPE *)(src_addr + 55 * src_stride_z));

    DATA_TYPE d70 = *((__global DATA_TYPE *)(src_addr + 56 * src_stride_z));
    DATA_TYPE d71 = *((__global DATA_TYPE *)(src_addr + 57 * src_stride_z));
    DATA_TYPE d72 = *((__global DATA_TYPE *)(src_addr + 58 * src_stride_z));
    DATA_TYPE d73 = *((__global DATA_TYPE *)(src_addr + 59 * src_stride_z));
    DATA_TYPE d74 = *((__global DATA_TYPE *)(src_addr + 60 * src_stride_z));
    DATA_TYPE d75 = *((__global DATA_TYPE *)(src_addr + 61 * src_stride_z));
    DATA_TYPE d76 = *((__global DATA_TYPE *)(src_addr + 62 * src_stride_z));
    DATA_TYPE d77 = *((__global DATA_TYPE *)(src_addr + 63 * src_stride_z));

    // Compute the 8x2 intermediate tensor
    VEC_DATA_TYPE(float, 2)
    tmp_col0, tmp_col1, tmp_col2, tmp_col3, tmp_col4, tmp_col5, tmp_col6, tmp_col7;

    COMPUTE_TMP_COL_2x2_7x7(tmp_col0, d00, d10, d20, d30, d40, d50, d60, d70);
    COMPUTE_TMP_COL_2x2_7x7(tmp_col1, d01, d11, d21, d31, d41, d51, d61, d71);
    COMPUTE_TMP_COL_2x2_7x7(tmp_col2, d02, d12, d22, d32, d42, d52, d62, d72);
    COMPUTE_TMP_COL_2x2_7x7(tmp_col3, d03, d13, d23, d33, d43, d53, d63, d73);
    COMPUTE_TMP_COL_2x2_7x7(tmp_col4, d04, d14, d24, d34, d44, d54, d64, d74);
    COMPUTE_TMP_COL_2x2_7x7(tmp_col5, d05, d15, d25, d35, d45, d55, d65, d75);
    COMPUTE_TMP_COL_2x2_7x7(tmp_col6, d06, d16, d26, d36, d46, d56, d66, d76);
    COMPUTE_TMP_COL_2x2_7x7(tmp_col7, d07, d17, d27, d37, d47, d57, d67, d77);

    // Compute the 2x2 output tile
    VEC_DATA_TYPE(float, 2)
    out_col0 = tmp_col0 + tmp_col1 + tmp_col2 + tmp_col3 + tmp_col4 + tmp_col5 + tmp_col6;
    VEC_DATA_TYPE(float, 2)
    out_col1 = -tmp_col1 + tmp_col2 - 2 * tmp_col3 + 2 * tmp_col4 - 3 * tmp_col5 + 3 * tmp_col6 + tmp_col7;

#if defined(HAS_BIAS)
    // Add bias
    Vector bias = CONVERT_TO_VECTOR_STRUCT_NO_STEP(bias);

    DATA_TYPE b = (float) * ((__global DATA_TYPE *)(vector_offset(&bias, x_out)));

    out_col0 += (VEC_DATA_TYPE(float, 2))b;
    out_col1 += (VEC_DATA_TYPE(float, 2))b;

#endif // defined(HAS_BIAS)
    // Get output address
#if defined(SRC_DEPTH)
    int2 offset = (int2)(dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z + batch * dst_stride_w);
#else  /* defined(SRC_DEPTH) */
    int2 offset = (int2)(dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z);
#endif /* defined(SRC_DEPTH) */
    offset      = min(offset + (int2)(0, 1) * (int2)dst_stride_z, (int2)dst_size); // If address is beyond the last plane, clamp it to dst_size (which points to the last padding).
    int2 mult_y = min((int2)dst_size - offset, (int2)1);                           // If out of bound, we don't want to increase dst_stride_y, so we set the multiplier to 0. It will be 1 otherwise.

    // Store the output tile
    VEC_DATA_TYPE(DATA_TYPE, VEC_SIZE)
    out_col0_dt = ACTIVATION_FUNC(CONVERT(out_col0, VEC_DATA_TYPE(DATA_TYPE, VEC_SIZE)));
    VEC_DATA_TYPE(DATA_TYPE, VEC_SIZE)
    out_col1_dt = ACTIVATION_FUNC(CONVERT(out_col1, VEC_DATA_TYPE(DATA_TYPE, VEC_SIZE)));

    *(__global DATA_TYPE *)(dst_ptr + mult_y.s0 * 0 * (int)dst_stride_y + offset.s0) = out_col0_dt.s0;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s0 * 1 * (int)dst_stride_y + offset.s0) = out_col1_dt.s0;

    *(__global DATA_TYPE *)(dst_ptr + mult_y.s1 * 0 * (int)dst_stride_y + offset.s1)     = out_col0_dt.s1;
    *(__global     DATA_TYPE *)(dst_ptr + mult_y.s1 * 1 * (int)dst_stride_y + offset.s1) = out_col1_dt.s1;

#endif // !defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) && !defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
}
#endif // defined(VEC_SIZE) && VEC_SIZE == 2

#if defined(VEC_SIZE) && VEC_SIZE == 4
/** This OpenCL kernel performs Winograd output transform when the output tile is 4x4, the filter size 3x3 and the data layout is NCHW
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=4
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=4
 * @note If this kernel is used to perform Winograd output transform 3x1, -DWINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL has to be passed at compile time
 * @note If this kernel is used to perform Winograd output transform 1x3, -DWINOGRAD_OUTPUT_TRANSFORM_VERTICAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_4x4_3x3_nchw(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst)
#if defined(HAS_BIAS)
    ,
    VECTOR_DECLARATION(bias)
#endif // defined(HAS_BIAS)
)
{
    // Each thread stores a 4x4/4x1 or 1x4 tile
#if defined(SRC_DEPTH)
    Tensor4D       src             = CONVERT_TO_TENSOR4D_STRUCT(src, SRC_DEPTH);
    const __global uchar *src_addr = tensor4D_offset(&src, 0, 0, 0, 0);
#else  /* defined(SRC_DEPTH) */
    Tensor3D       src                                                                   = CONVERT_TO_TENSOR3D_STRUCT(src);
    const __global uchar *src_addr                                                       = tensor3D_offset(&src, 0, 0, 0);
#endif /* defined(SRC_DEPTH) */

    // Load the values across the channels to compose the 6x6 or 6x1 tile
    DATA_TYPE d00 = *((__global DATA_TYPE *)(src_addr + 0 * src_stride_z));
    DATA_TYPE d01 = *((__global DATA_TYPE *)(src_addr + 1 * src_stride_z));
    DATA_TYPE d02 = *((__global DATA_TYPE *)(src_addr + 2 * src_stride_z));
    DATA_TYPE d03 = *((__global DATA_TYPE *)(src_addr + 3 * src_stride_z));
    DATA_TYPE d04 = *((__global DATA_TYPE *)(src_addr + 4 * src_stride_z));
    DATA_TYPE d05 = *((__global DATA_TYPE *)(src_addr + 5 * src_stride_z));

#if defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    // Compute out00, out01, out02 and out03
    float out00 = d00 + d01 + d02 + d03 + d04;
    float out01 = d01 - d02 + 2.0f * d03 - 2.0f * d04;
    float out02 = d01 + d02 + 4.0f * d03 + 4.0f * d04;
    float out03 = d01 - d02 + 8.0f * d03 - 8.0f * d04 + d05;
#else  // defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

    DATA_TYPE d10 = *((__global DATA_TYPE *)(src_addr + 6 * src_stride_z));
    DATA_TYPE d11 = *((__global DATA_TYPE *)(src_addr + 7 * src_stride_z));
    DATA_TYPE d12 = *((__global DATA_TYPE *)(src_addr + 8 * src_stride_z));
    DATA_TYPE d13 = *((__global DATA_TYPE *)(src_addr + 9 * src_stride_z));
    DATA_TYPE d14 = *((__global DATA_TYPE *)(src_addr + 10 * src_stride_z));
    DATA_TYPE d15 = *((__global DATA_TYPE *)(src_addr + 11 * src_stride_z));

    DATA_TYPE d20 = *((__global DATA_TYPE *)(src_addr + 12 * src_stride_z));
    DATA_TYPE d21 = *((__global DATA_TYPE *)(src_addr + 13 * src_stride_z));
    DATA_TYPE d22 = *((__global DATA_TYPE *)(src_addr + 14 * src_stride_z));
    DATA_TYPE d23 = *((__global DATA_TYPE *)(src_addr + 15 * src_stride_z));
    DATA_TYPE d24 = *((__global DATA_TYPE *)(src_addr + 16 * src_stride_z));
    DATA_TYPE d25 = *((__global DATA_TYPE *)(src_addr + 17 * src_stride_z));

    DATA_TYPE d30 = *((__global DATA_TYPE *)(src_addr + 18 * src_stride_z));
    DATA_TYPE d31 = *((__global DATA_TYPE *)(src_addr + 19 * src_stride_z));
    DATA_TYPE d32 = *((__global DATA_TYPE *)(src_addr + 20 * src_stride_z));
    DATA_TYPE d33 = *((__global DATA_TYPE *)(src_addr + 21 * src_stride_z));
    DATA_TYPE d34 = *((__global DATA_TYPE *)(src_addr + 22 * src_stride_z));
    DATA_TYPE d35 = *((__global DATA_TYPE *)(src_addr + 23 * src_stride_z));

    DATA_TYPE d40 = *((__global DATA_TYPE *)(src_addr + 24 * src_stride_z));
    DATA_TYPE d41 = *((__global DATA_TYPE *)(src_addr + 25 * src_stride_z));
    DATA_TYPE d42 = *((__global DATA_TYPE *)(src_addr + 26 * src_stride_z));
    DATA_TYPE d43 = *((__global DATA_TYPE *)(src_addr + 27 * src_stride_z));
    DATA_TYPE d44 = *((__global DATA_TYPE *)(src_addr + 28 * src_stride_z));
    DATA_TYPE d45 = *((__global DATA_TYPE *)(src_addr + 29 * src_stride_z));

    DATA_TYPE d50 = *((__global DATA_TYPE *)(src_addr + 30 * src_stride_z));
    DATA_TYPE d51 = *((__global DATA_TYPE *)(src_addr + 31 * src_stride_z));
    DATA_TYPE d52 = *((__global DATA_TYPE *)(src_addr + 32 * src_stride_z));
    DATA_TYPE d53 = *((__global DATA_TYPE *)(src_addr + 33 * src_stride_z));
    DATA_TYPE d54 = *((__global DATA_TYPE *)(src_addr + 34 * src_stride_z));
    DATA_TYPE d55 = *((__global DATA_TYPE *)(src_addr + 35 * src_stride_z));

    // Compute out00, out01, out02 and out03
    float out00 = (float)d01 + (float)d21 + (float)d41 + (float)d11 + (float)d31;
    float out01 = (float)d01 + (float)d21 + (float)d41 + (float)d11 + (float)d31;
    float out02 = (float)d01 + (float)d21 + (float)d41 + (float)d11 + (float)d31;
    float out03 = (float)d01 + d21 + (float)d41 + (float)d11 + (float)d31;

    float k0 = d03 + d04 + d13 + d14 + d23 + d24 + d33 + d34 + d43 + d44;
    float k1 = 2.0f * d03 - 2.0f * d04 + 2.0f * d13 - 2.0f * d14 + 2.0f * d23 - 2.0f * d24 + 2.0f * d33 - 2.0f * d34 + 2.0f * d43 - 2.0f * d44;

    out00 += k0 + d00 + d02 + d10 + d12 + d20 + d22 + d30 + d32 + d40 + d42;
    out01 += k1 - d02 - d12 - d22 - d32 - d42;
    out02 += 4.0f * k0 + d02 + d12 + d22 + d32 + d42;
    out03 += 4.0f * k1 - d02 - d12 - d22 - d32 - d42 + d05 + d15 + d25 + d35 + d45;

    // Compute out10, out11, out12 and out13
    float out10 = d11 - d21 + 2.0f * d31 - 2.0f * d41;
    float out11 = d11 - d21 + 2.0f * d31 - 2.0f * d41;
    float out12 = d11 - d21 + 2.0f * d31 - 2.0f * d41;
    float out13 = d11 - d21 + 2.0f * d31 - 2.0f * d41;

    k0 = d13 + d14 - d23 - d24 + 2.0f * d33 + 2.0f * d34 - 2.0f * d43 - 2.0f * d44;
    k1 = 2.0f * d13 - 2.0f * d14 - 2.0f * d23 + 2.0f * d24 + 4.0f * d33 - 4.0f * d34 - 4.0f * d43 + 4.0f * d44;

    out10 += k0 + d10 + d12 - d20 - d22 + 2.0f * d30 + 2.0f * d32 - 2.0f * d40 - 2.0f * d42;
    out11 += k1 - d12 + d22 - 2.0f * d32 + 2.0f * d42;
    out12 += 4.0f * k0 + d12 - d22 + 2.0f * d32 - 2.0f * d42;
    out13 += 4.0f * k1 - d12 + d15 + d22 - d25 - 2.0f * d32 + 2.0f * d35 + 2.0f * d42 - 2.0f * d45;

    // Compute out20, out21, out22 and out23
    float out20 = d11 + d21 + 4.0f * d31 + 4.0f * d41;
    float out21 = d11 + d21 + 4.0f * d31 + 4.0f * d41;
    float out22 = d11 + d21 + 4.0f * d31 + 4.0f * d41;
    float out23 = d11 + d21 + 4.0f * d31 + 4.0f * d41;

    k0 = d13 + d14 + d23 + d24 + 4.0f * d33 + 4.0f * d34 + 4.0f * d43 + 4.0f * d44;
    k1 = 2.0f * d13 - 2.0f * d14 + 2.0f * d23 - 2.0f * d24 + 8.0f * d33 - 8.0f * d34 + 8.0f * d43 - 8.0f * d44;

    out20 += k0 + d10 + d12 + d20 + d22 + 4.0f * d30 + 4.0f * d32 + 4.0f * d40 + 4.0f * d42;
    out21 += k1 - d12 - d22 - 4.0f * d32 - 4.0f * d42;
    out22 += 4.0f * k0 + d12 + d22 + 4.0f * d32 + 4.0f * d42;
    out23 += 4.0f * k1 - d12 + d15 - d22 + d25 - 4.0f * d32 + 4.0f * d35 - 4.0f * d42 + 4.0f * d45;

    // Compute out30, out31, out32 and out33
    float out30 = d11 - d21 + 8.0f * d31 - 8.0f * d41 + d51;
    float out31 = d11 - d21 + 8.0f * d31 - 8.0f * d41 + d51;
    float out32 = d11 - d21 + 8.0f * d31 - 8.0f * d41 + d51;
    float out33 = d11 - d21 + 8.0f * d31 - 8.0f * d41 + d51;

    k0 = d13 + d14 - d23 - d24 + 8.0f * d33 + 8.0f * d34 - 8.0f * d43 - 8.0f * d44 + d53 + d54;
    k1 = 2.0f * d13 - 2.0f * d14 - 2.0f * d23 + 2.0f * d24 + 16.0f * d33 - 16.0f * d34 - 16.0f * d43 + 16.0f * d44 + 2.0f * d53 - 2.0f * d54;

    out30 += k0 + d10 + d12 - d20 - d22 + 8.0f * d30 + 8.0f * d32 - 8.0f * d40 - 8.0f * d42 + d50 + d52;
    out31 += k1 - d12 + d22 - 8.0f * d32 + 8.0f * d42 - d52;
    out32 += 4.0f * k0 + d12 - d22 + 8.0f * d32 - 8.0f * d42 + d52;
    out33 += 4.0f * k1 - d12 + d15 + d22 - d25 - 8.0f * d32 + 8.0f * d35 + 8.0f * d42 - 8.0f * d45 - d52 + d55;
#endif // defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

    int y_in  = get_global_id(1);
    int x_out = (y_in % NUM_TILES_X) * OUTPUT_TILE_W;
    int y_out = (y_in / NUM_TILES_X) * OUTPUT_TILE_H;
    int z_out = get_global_id(0);
#if defined(SRC_DEPTH)
    int batch = get_global_id(2) / SRC_DEPTH;
#endif /* defined(SRC_DEPTH) */

#if defined(HAS_BIAS)
    // Add bias
    Vector bias = CONVERT_TO_VECTOR_STRUCT_NO_STEP(bias);

    float b = (float) * ((__global DATA_TYPE *)(vector_offset(&bias, z_out)));

    out00 += (float)b;
    out01 += (float)b;
    out02 += (float)b;
    out03 += (float)b;
#endif // defined(HAS_BIAS)

    // Get output address
#if defined(SRC_DEPTH)
    __global uchar *dst_addr = dst_ptr + dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z + batch * dst_stride_w;
#else  /* defined(SRC_DEPTH) */
    __global uchar *dst_addr = dst_ptr + dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z;
#endif /* defined(SRC_DEPTH) */

    // Store the output tile
#if defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    VEC_DATA_TYPE(DATA_TYPE, 4)
    out0_dt                                                = ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out00, out01, out02, out03), VEC_DATA_TYPE(DATA_TYPE, 4)));
    *((__global DATA_TYPE *)(dst_addr + 0 * dst_stride_y)) = out0_dt.s0;
    *((__global DATA_TYPE *)(dst_addr + 1 * dst_stride_y)) = out0_dt.s1;
    *((__global DATA_TYPE *)(dst_addr + 2 * dst_stride_y)) = out0_dt.s2;
    *((__global DATA_TYPE *)(dst_addr + 3 * dst_stride_y)) = out0_dt.s3;
#else  // defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    vstore4(ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out00, out01, out02, out03), VEC_DATA_TYPE(DATA_TYPE, 4))), 0, (__global DATA_TYPE *)(dst_addr + 0 * dst_stride_y));
#endif // defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

#if !defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) && !defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
#if defined(HAS_BIAS)
    // Add bias
    out10 += (float)b;
    out11 += (float)b;
    out12 += (float)b;
    out13 += (float)b;

    out20 += (float)b;
    out21 += (float)b;
    out22 += (float)b;
    out23 += (float)b;

    out30 += (float)b;
    out31 += (float)b;
    out32 += (float)b;
    out33 += (float)b;
#endif // defined(HAS_BIAS)
    vstore4(ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out10, out11, out12, out13), VEC_DATA_TYPE(DATA_TYPE, 4))), 0, (__global DATA_TYPE *)(dst_addr + 1 * dst_stride_y));
    vstore4(ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out20, out21, out22, out23), VEC_DATA_TYPE(DATA_TYPE, 4))), 0, (__global DATA_TYPE *)(dst_addr + 2 * dst_stride_y));
    vstore4(ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out30, out31, out32, out33), VEC_DATA_TYPE(DATA_TYPE, 4))), 0, (__global DATA_TYPE *)(dst_addr + 3 * dst_stride_y));
#endif // !defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) && !defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
}

/** This OpenCL kernel performs Winograd output transform when the output tile is 4x4, 4x1 or 1x4, the filter size 3x3, 3x1 or 1x3 and the data layout is NHWC
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=4
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=4
 * @note If this kernel is used to perform Winograd output transform 3x1, -DWINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL has to be passed at compile time
 * @note If this kernel is used to perform Winograd output transform 1x3, -DWINOGRAD_OUTPUT_TRANSFORM_VERTICAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 * @param[in]  dst_size                          Size of the destination tensor, minus the last padding
 */
__kernel void winograd_output_transform_4x4_3x3_nhwc(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst),
#if defined(HAS_BIAS)
    VECTOR_DECLARATION(bias),
#endif // defined(HAS_BIAS)
    int dst_size)
{
    // Each thread stores a 4x4/4x1 or 1x4 tile
#if defined(SRC_DEPTH)
    Tensor4D       src             = CONVERT_TO_TENSOR4D_STRUCT(src, SRC_DEPTH);
    const __global uchar *src_addr = tensor4D_offset(&src, 0, 0, 0, 0);
#else  /* defined(SRC_DEPTH) */
    Tensor3D       src             = CONVERT_TO_TENSOR3D_STRUCT(src);
    const __global uchar *src_addr = tensor3D_offset(&src, 0, 0, 0);
#endif /* defined(SRC_DEPTH) */

    // Load the values across the 36 channels to compose the 6x6 or 6x1 tile
    DATA_TYPE d00 = *((__global DATA_TYPE *)(src_addr + 0 * src_stride_z));
    DATA_TYPE d01 = *((__global DATA_TYPE *)(src_addr + 1 * src_stride_z));
    DATA_TYPE d02 = *((__global DATA_TYPE *)(src_addr + 2 * src_stride_z));
    DATA_TYPE d03 = *((__global DATA_TYPE *)(src_addr + 3 * src_stride_z));
    DATA_TYPE d04 = *((__global DATA_TYPE *)(src_addr + 4 * src_stride_z));
    DATA_TYPE d05 = *((__global DATA_TYPE *)(src_addr + 5 * src_stride_z));

#if defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    // Compute out00, out01, out02 and out03
    float out00 = d00 + d01 + d02 + d03 + d04;
    float out01 = d01 - d02 + 2.0f * d03 - 2.0f * d04;
    float out02 = d01 + d02 + 4.0f * d03 + 4.0f * d04;
    float out03 = d01 - d02 + 8.0f * d03 - 8.0f * d04 + d05;
#else  // defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

    DATA_TYPE d10 = *((__global DATA_TYPE *)(src_addr + 6 * src_stride_z));
    DATA_TYPE d11 = *((__global DATA_TYPE *)(src_addr + 7 * src_stride_z));
    DATA_TYPE d12 = *((__global DATA_TYPE *)(src_addr + 8 * src_stride_z));
    DATA_TYPE d13 = *((__global DATA_TYPE *)(src_addr + 9 * src_stride_z));
    DATA_TYPE d14 = *((__global DATA_TYPE *)(src_addr + 10 * src_stride_z));
    DATA_TYPE d15 = *((__global DATA_TYPE *)(src_addr + 11 * src_stride_z));

    DATA_TYPE d20 = *((__global DATA_TYPE *)(src_addr + 12 * src_stride_z));
    DATA_TYPE d21 = *((__global DATA_TYPE *)(src_addr + 13 * src_stride_z));
    DATA_TYPE d22 = *((__global DATA_TYPE *)(src_addr + 14 * src_stride_z));
    DATA_TYPE d23 = *((__global DATA_TYPE *)(src_addr + 15 * src_stride_z));
    DATA_TYPE d24 = *((__global DATA_TYPE *)(src_addr + 16 * src_stride_z));
    DATA_TYPE d25 = *((__global DATA_TYPE *)(src_addr + 17 * src_stride_z));

    DATA_TYPE d30 = *((__global DATA_TYPE *)(src_addr + 18 * src_stride_z));
    DATA_TYPE d31 = *((__global DATA_TYPE *)(src_addr + 19 * src_stride_z));
    DATA_TYPE d32 = *((__global DATA_TYPE *)(src_addr + 20 * src_stride_z));
    DATA_TYPE d33 = *((__global DATA_TYPE *)(src_addr + 21 * src_stride_z));
    DATA_TYPE d34 = *((__global DATA_TYPE *)(src_addr + 22 * src_stride_z));
    DATA_TYPE d35 = *((__global DATA_TYPE *)(src_addr + 23 * src_stride_z));

    DATA_TYPE d40 = *((__global DATA_TYPE *)(src_addr + 24 * src_stride_z));
    DATA_TYPE d41 = *((__global DATA_TYPE *)(src_addr + 25 * src_stride_z));
    DATA_TYPE d42 = *((__global DATA_TYPE *)(src_addr + 26 * src_stride_z));
    DATA_TYPE d43 = *((__global DATA_TYPE *)(src_addr + 27 * src_stride_z));
    DATA_TYPE d44 = *((__global DATA_TYPE *)(src_addr + 28 * src_stride_z));
    DATA_TYPE d45 = *((__global DATA_TYPE *)(src_addr + 29 * src_stride_z));

    DATA_TYPE d50 = *((__global DATA_TYPE *)(src_addr + 30 * src_stride_z));
    DATA_TYPE d51 = *((__global DATA_TYPE *)(src_addr + 31 * src_stride_z));
    DATA_TYPE d52 = *((__global DATA_TYPE *)(src_addr + 32 * src_stride_z));
    DATA_TYPE d53 = *((__global DATA_TYPE *)(src_addr + 33 * src_stride_z));
    DATA_TYPE d54 = *((__global DATA_TYPE *)(src_addr + 34 * src_stride_z));
    DATA_TYPE d55 = *((__global DATA_TYPE *)(src_addr + 35 * src_stride_z));

    // Compute out00, out01, out02 and out03
    float out00 = d01 + d21 + d41 + d11 + d31;
    float out01 = d01 + d21 + d41 + d11 + d31;
    float out02 = d01 + d21 + d41 + d11 + d31;
    float out03 = d01 + d21 + d41 + d11 + d31;

    float k0 = d03 + d04 + d13 + d14 + d23 + d24 + d33 + d34 + d43 + d44;
    float k1 = 2.0f * d03 - 2.0f * d04 + 2.0f * d13 - 2.0f * d14 + 2.0f * d23 - 2.0f * d24 + 2.0f * d33 - 2.0f * d34 + 2.0f * d43 - 2.0f * d44;

    out00 += k0 + d00 + d02 + d10 + d12 + d20 + d22 + d30 + d32 + d40 + d42;
    out01 += k1 - d02 - d12 - d22 - d32 - d42;
    out02 += 4.0f * k0 + d02 + d12 + d22 + d32 + d42;
    out03 += 4.0f * k1 - d02 - d12 - d22 - d32 - d42 + d05 + d15 + d25 + d35 + d45;

    // Compute out10, out11, out12 and out13
    float out10 = d11 - d21 + 2.0f * d31 - 2.0f * d41;
    float out11 = d11 - d21 + 2.0f * d31 - 2.0f * d41;
    float out12 = d11 - d21 + 2.0f * d31 - 2.0f * d41;
    float out13 = d11 - d21 + 2.0f * d31 - 2.0f * d41;

    k0 = d13 + d14 - d23 - d24 + 2.0f * d33 + 2.0f * d34 - 2.0f * d43 - 2.0f * d44;
    k1 = 2.0f * d13 - 2.0f * d14 - 2.0f * d23 + 2.0f * d24 + 4.0f * d33 - 4.0f * d34 - 4.0f * d43 + 4.0f * d44;

    out10 += k0 + d10 + d12 - d20 - d22 + 2.0f * d30 + 2.0f * d32 - 2.0f * d40 - 2.0f * d42;
    out11 += k1 - d12 + d22 - 2.0f * d32 + 2.0f * d42;
    out12 += 4.0f * k0 + d12 - d22 + 2.0f * d32 - 2.0f * d42;
    out13 += 4.0f * k1 - d12 + d15 + d22 - d25 - 2.0f * d32 + 2.0f * d35 + 2.0f * d42 - 2.0f * d45;

    // Compute out20, out21, out22 and out23
    float out20 = d11 + d21 + 4.0f * d31 + 4.0f * d41;
    float out21 = d11 + d21 + 4.0f * d31 + 4.0f * d41;
    float out22 = d11 + d21 + 4.0f * d31 + 4.0f * d41;
    float out23 = d11 + d21 + 4.0f * d31 + 4.0f * d41;

    k0 = d13 + d14 + d23 + d24 + 4.0f * d33 + 4.0f * d34 + 4.0f * d43 + 4.0f * d44;
    k1 = 2.0f * d13 - 2.0f * d14 + 2.0f * d23 - 2.0f * d24 + 8.0f * d33 - 8.0f * d34 + 8.0f * d43 - 8.0f * d44;

    out20 += k0 + d10 + d12 + d20 + d22 + 4.0f * d30 + 4.0f * d32 + 4.0f * d40 + 4.0f * d42;
    out21 += k1 - d12 - d22 - 4.0f * d32 - 4.0f * d42;
    out22 += 4.0f * k0 + d12 + d22 + 4.0f * d32 + 4.0f * d42;
    out23 += 4.0f * k1 - d12 + d15 - d22 + d25 - 4.0f * d32 + 4.0f * d35 - 4.0f * d42 + 4.0f * d45;

    // Compute out30, out31, out32 and out33
    float out30 = d11 - d21 + 8.0f * d31 - 8.0f * d41 + d51;
    float out31 = d11 - d21 + 8.0f * d31 - 8.0f * d41 + d51;
    float out32 = d11 - d21 + 8.0f * d31 - 8.0f * d41 + d51;
    float out33 = d11 - d21 + 8.0f * d31 - 8.0f * d41 + d51;

    k0 = d13 + d14 - d23 - d24 + 8.0f * d33 + 8.0f * d34 - 8.0f * d43 - 8.0f * d44 + d53 + d54;
    k1 = 2.0f * d13 - 2.0f * d14 - 2.0f * d23 + 2.0f * d24 + 16.0f * d33 - 16.0f * d34 - 16.0f * d43 + 16.0f * d44 + 2.0f * d53 - 2.0f * d54;

    out30 += k0 + d10 + d12 - d20 - d22 + 8.0f * d30 + 8.0f * d32 - 8.0f * d40 - 8.0f * d42 + d50 + d52;
    out31 += k1 - d12 + d22 - 8.0f * d32 + 8.0f * d42 - d52;
    out32 += 4.0f * k0 + d12 - d22 + 8.0f * d32 - 8.0f * d42 + d52;
    out33 += 4.0f * k1 - d12 + d15 + d22 - d25 - 8.0f * d32 + 8.0f * d35 + 8.0f * d42 - 8.0f * d45 - d52 + d55;
#endif // defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

    int y_in  = get_global_id(1);
    int x_out = get_global_id(0);
    int y_out = (y_in % NUM_TILES_X) * OUTPUT_TILE_W;
    int z_out = (y_in / NUM_TILES_X) * OUTPUT_TILE_H;
#if defined(SRC_DEPTH)
    int batch = get_global_id(2) / SRC_DEPTH;
#endif /* defined(SRC_DEPTH) */

#if defined(HAS_BIAS)
    // Add bias
    Vector bias = CONVERT_TO_VECTOR_STRUCT_NO_STEP(bias);

    DATA_TYPE b = (DATA_TYPE) * ((__global DATA_TYPE *)(vector_offset(&bias, x_out)));

    out00 += (DATA_TYPE)b;
    out01 += (DATA_TYPE)b;
    out02 += (DATA_TYPE)b;
    out03 += (DATA_TYPE)b;
#if !defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) & !defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    out10 += (DATA_TYPE)b;
    out11 += (DATA_TYPE)b;
    out12 += (DATA_TYPE)b;
    out13 += (DATA_TYPE)b;

    out20 += (DATA_TYPE)b;
    out21 += (DATA_TYPE)b;
    out22 += (DATA_TYPE)b;
    out23 += (DATA_TYPE)b;

    out30 += (DATA_TYPE)b;
    out31 += (DATA_TYPE)b;
    out32 += (DATA_TYPE)b;
    out33 += (DATA_TYPE)b;
#endif // !defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) & !defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

#endif // defined(HAS_BIAS)

#if defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
#if defined(SRC_DEPTH)
    int4 offset = (int4)(dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z + batch * dst_stride_w);
#else                                                                               /* defined(SRC_DEPTH) */
    int4       offset                                            = (int4)(dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z);
#endif                                                                              /* defined(SRC_DEPTH) */
    offset = min(offset + (int4)(0, 1, 2, 3) * (int4)dst_stride_z, (int4)dst_size); // If address is beyond the last plane, clamp it to dst_size (which points to the last padding).

    // Store the 1x4 output tile
    VEC_DATA_TYPE(DATA_TYPE, 4)
    out0_dt                                        = ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out00, out01, out02, out03), VEC_DATA_TYPE(DATA_TYPE, 4)));
    *((__global DATA_TYPE *)(dst_ptr + offset.s0)) = out0_dt.s0;
    *((__global DATA_TYPE *)(dst_ptr + offset.s1)) = out0_dt.s1;
    *((__global DATA_TYPE *)(dst_ptr + offset.s2)) = out0_dt.s2;
    *((__global DATA_TYPE *)(dst_ptr + offset.s3)) = out0_dt.s3;
#elif defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL)
    // Store the 4x1 output tile
    int offset = dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z;
    int mult_y = min(dst_size - offset, 1);

    VEC_DATA_TYPE(DATA_TYPE, 4)
    out0_dt                                                                 = ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out00, out01, out02, out03), VEC_DATA_TYPE(DATA_TYPE, 4)));
    *((__global DATA_TYPE *)(dst_ptr + mult_y * 0 * dst_stride_y + offset)) = out0_dt.s0;
    *((__global DATA_TYPE *)(dst_ptr + mult_y * 1 * dst_stride_y + offset)) = out0_dt.s1;
    *((__global DATA_TYPE *)(dst_ptr + mult_y * 2 * dst_stride_y + offset)) = out0_dt.s2;
    *((__global DATA_TYPE *)(dst_ptr + mult_y * 3 * dst_stride_y + offset)) = out0_dt.s3;
#else // defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL)
    // Get output address
#if defined(SRC_DEPTH)
    int4 offset = (int4)(dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z + batch * dst_stride_w);
#else  /* defined(SRC_DEPTH) */
    int4 offset = (int4)(dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z);
#endif /* defined(SRC_DEPTH) */
    offset      = min(offset + (int4)(0, 1, 2, 3) * (int4)dst_stride_z, (int4)dst_size); // If address is beyond the last plane, clamp it to dst_size (which points to the last padding).
    int4 mult_y = min((int4)dst_size - offset, (int4)1);                                 // If out of bound, we don't want to increase dst_stride_y, so we set the multiplier to 0. It will be 1 otherwise.

    // Store the 4x4 output tile
    VEC_DATA_TYPE(DATA_TYPE, 4)
    out0_dt = ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out00, out01, out02, out03), VEC_DATA_TYPE(DATA_TYPE, 4)));
    VEC_DATA_TYPE(DATA_TYPE, 4)
    out1_dt = ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out10, out11, out12, out13), VEC_DATA_TYPE(DATA_TYPE, 4)));
    VEC_DATA_TYPE(DATA_TYPE, 4)
    out2_dt = ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out20, out21, out22, out23), VEC_DATA_TYPE(DATA_TYPE, 4)));
    VEC_DATA_TYPE(DATA_TYPE, 4)
    out3_dt                                                                       = ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out30, out31, out32, out33), VEC_DATA_TYPE(DATA_TYPE, 4)));
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s0 * 0 * dst_stride_y + offset.s0)) = out0_dt.s0;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s0 * 1 * dst_stride_y + offset.s0)) = out0_dt.s1;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s0 * 2 * dst_stride_y + offset.s0)) = out0_dt.s2;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s0 * 3 * dst_stride_y + offset.s0)) = out0_dt.s3;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s1 * 0 * dst_stride_y + offset.s1)) = out1_dt.s0;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s1 * 1 * dst_stride_y + offset.s1)) = out1_dt.s1;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s1 * 2 * dst_stride_y + offset.s1)) = out1_dt.s2;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s1 * 3 * dst_stride_y + offset.s1)) = out1_dt.s3;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s2 * 0 * dst_stride_y + offset.s2)) = out2_dt.s0;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s2 * 1 * dst_stride_y + offset.s2)) = out2_dt.s1;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s2 * 2 * dst_stride_y + offset.s2)) = out2_dt.s2;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s2 * 3 * dst_stride_y + offset.s2)) = out2_dt.s3;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s3 * 0 * dst_stride_y + offset.s3)) = out3_dt.s0;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s3 * 1 * dst_stride_y + offset.s3)) = out3_dt.s1;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s3 * 2 * dst_stride_y + offset.s3)) = out3_dt.s2;
    *((__global DATA_TYPE *)(dst_ptr + mult_y.s3 * 3 * dst_stride_y + offset.s3)) = out3_dt.s3;

#endif // defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL)
}

#define COMPUTE_TMP_COL(col, d0, d1, d2, d3, d4, d5, d6, d7, comm_fact)  \
    ({                                                                   \
        comm_fact.s0 = d1 + d2;                                          \
        comm_fact.s1 = d3 + d4;                                          \
        comm_fact.s2 = d5 + d6;                                          \
        \
        col.s0 = comm_fact.s0 + comm_fact.s1 + 8.f * comm_fact.s2 + d0;  \
        col.s2 = comm_fact.s0 + 4.f * comm_fact.s1 + 2.f * comm_fact.s2; \
        \
        comm_fact.s0 = d1 - d2;                                          \
        comm_fact.s1 = d3 - d4;                                          \
        comm_fact.s2 = d5 - d6;                                          \
        \
        col.s1 = comm_fact.s0 + 2.f * comm_fact.s1 + 4.f * comm_fact.s2; \
        col.s3 = comm_fact.s0 + 8.f * comm_fact.s1 + comm_fact.s2 + d7;  \
    })

/** This OpenCL kernel performs Winograd output transform when the output tile is 4x4/4x1 or 1x4, the filter size 5x5/5x1 or 1x5 and the data layout is NCHW
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=4
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=4
 * @note If this kernel is used to perform Winograd output transform 3x1, -DWINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL has to be passed at compile time
 * @note If this kernel is used to perform Winograd output transform 1x3, -DWINOGRAD_OUTPUT_TRANSFORM_VERTICAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_4x4_5x5_nchw(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst)
#if defined(HAS_BIAS)
    ,
    VECTOR_DECLARATION(bias)
#endif // defined(HAS_BIAS)
)
{
    // Each thread stores a 4x4/4x1 or 1x4 tile
#if defined(SRC_DEPTH)
    Tensor4D       src             = CONVERT_TO_TENSOR4D_STRUCT(src, SRC_DEPTH);
    const __global uchar *src_addr = tensor4D_offset(&src, 0, 0, 0, 0);
#else  /* defined(SRC_DEPTH) */

    Tensor3D       src             = CONVERT_TO_TENSOR3D_STRUCT(src);
    const __global uchar *src_addr = tensor3D_offset(&src, 0, 0, 0);
#endif /* defined(SRC_DEPTH) */

    // Compute output address
    int y_in  = get_global_id(1);
    int x_out = (y_in % NUM_TILES_X) * OUTPUT_TILE_W;
    int y_out = (y_in / NUM_TILES_X) * OUTPUT_TILE_H;
    int z_out = get_global_id(0);
#if defined(SRC_DEPTH)
    int batch = get_global_id(2) / SRC_DEPTH;
#endif /* defined(SRC_DEPTH) */

#if defined(SRC_DEPTH)
    __global uchar *dst_addr = dst_ptr + dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z + batch * dst_stride_w;
#else  /* defined(SRC_DEPTH) */

    __global uchar *dst_addr = dst_ptr + dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z;
#endif /* defined(SRC_DEPTH) */

    // Load the values across the channels to compose the input tile
    DATA_TYPE d00 = *((__global DATA_TYPE *)(src_addr + 0 * src_stride_z));
    DATA_TYPE d01 = *((__global DATA_TYPE *)(src_addr + 1 * src_stride_z));
    DATA_TYPE d02 = *((__global DATA_TYPE *)(src_addr + 2 * src_stride_z));
    DATA_TYPE d03 = *((__global DATA_TYPE *)(src_addr + 3 * src_stride_z));
    DATA_TYPE d04 = *((__global DATA_TYPE *)(src_addr + 4 * src_stride_z));
    DATA_TYPE d05 = *((__global DATA_TYPE *)(src_addr + 5 * src_stride_z));
    DATA_TYPE d06 = *((__global DATA_TYPE *)(src_addr + 6 * src_stride_z));
    DATA_TYPE d07 = *((__global DATA_TYPE *)(src_addr + 7 * src_stride_z));

#if defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    // Compute out00, out01, out02 and out03
    float out00 = d00 + d01 + d02 + d03 + d04 + 8.0f * d05 + 8.0f * d06;
    float out01 = d01 - d02 + 2.0f * d03 - 2.0f * d04 + 4.0f * d05 - 4.0f * d06;
    float out02 = d01 + d02 + 4.0f * d03 + 4.0f * d04 + 2.0f * d05 + 2.0f * d06;
    float out03 = d01 - d02 + 8.0f * d03 - 8.0f * d04 + d05 - d06 + d07;

#if defined(HAS_BIAS)
    // Add bias
    Vector bias = CONVERT_TO_VECTOR_STRUCT_NO_STEP(bias);

    float b = (float) * ((__global DATA_TYPE *)(vector_offset(&bias, z_out)));

    out00 += (DATA_TYPE)b;
    out01 += (DATA_TYPE)b;
    out02 += (DATA_TYPE)b;
    out03 += (DATA_TYPE)b;
#endif // defined(HAS_BIAS)

    // Store the output tile
#if defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    VEC_DATA_TYPE(DATA_TYPE, 4)
    out0_dt                                                = ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out00, out01, out02, out03), VEC_DATA_TYPE(DATA_TYPE, 4)));
    *((__global DATA_TYPE *)(dst_addr + 0 * dst_stride_y)) = out0_dt.s0;
    *((__global DATA_TYPE *)(dst_addr + 1 * dst_stride_y)) = out0_dt.s1;
    *((__global DATA_TYPE *)(dst_addr + 2 * dst_stride_y)) = out0_dt.s2;
    *((__global DATA_TYPE *)(dst_addr + 3 * dst_stride_y)) = out0_dt.s3;
#else  // defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    vstore4(ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out00, out01, out02, out03), VEC_DATA_TYPE(DATA_TYPE, 4))), 0, (__global DATA_TYPE *)(dst_addr));
#endif // defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

#else // defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

    DATA_TYPE d10 = *((__global DATA_TYPE *)(src_addr + 8 * src_stride_z));
    DATA_TYPE d11 = *((__global DATA_TYPE *)(src_addr + 9 * src_stride_z));
    DATA_TYPE d12 = *((__global DATA_TYPE *)(src_addr + 10 * src_stride_z));
    DATA_TYPE d13 = *((__global DATA_TYPE *)(src_addr + 11 * src_stride_z));
    DATA_TYPE d14 = *((__global DATA_TYPE *)(src_addr + 12 * src_stride_z));
    DATA_TYPE d15 = *((__global DATA_TYPE *)(src_addr + 13 * src_stride_z));
    DATA_TYPE d16 = *((__global DATA_TYPE *)(src_addr + 14 * src_stride_z));
    DATA_TYPE d17 = *((__global DATA_TYPE *)(src_addr + 15 * src_stride_z));

    DATA_TYPE d20 = *((__global DATA_TYPE *)(src_addr + 16 * src_stride_z));
    DATA_TYPE d21 = *((__global DATA_TYPE *)(src_addr + 17 * src_stride_z));
    DATA_TYPE d22 = *((__global DATA_TYPE *)(src_addr + 18 * src_stride_z));
    DATA_TYPE d23 = *((__global DATA_TYPE *)(src_addr + 19 * src_stride_z));
    DATA_TYPE d24 = *((__global DATA_TYPE *)(src_addr + 20 * src_stride_z));
    DATA_TYPE d25 = *((__global DATA_TYPE *)(src_addr + 21 * src_stride_z));
    DATA_TYPE d26 = *((__global DATA_TYPE *)(src_addr + 22 * src_stride_z));
    DATA_TYPE d27 = *((__global DATA_TYPE *)(src_addr + 23 * src_stride_z));

    DATA_TYPE d30 = *((__global DATA_TYPE *)(src_addr + 24 * src_stride_z));
    DATA_TYPE d31 = *((__global DATA_TYPE *)(src_addr + 25 * src_stride_z));
    DATA_TYPE d32 = *((__global DATA_TYPE *)(src_addr + 26 * src_stride_z));
    DATA_TYPE d33 = *((__global DATA_TYPE *)(src_addr + 27 * src_stride_z));
    DATA_TYPE d34 = *((__global DATA_TYPE *)(src_addr + 28 * src_stride_z));
    DATA_TYPE d35 = *((__global DATA_TYPE *)(src_addr + 29 * src_stride_z));
    DATA_TYPE d36 = *((__global DATA_TYPE *)(src_addr + 30 * src_stride_z));
    DATA_TYPE d37 = *((__global DATA_TYPE *)(src_addr + 31 * src_stride_z));

    DATA_TYPE d40 = *((__global DATA_TYPE *)(src_addr + 32 * src_stride_z));
    DATA_TYPE d41 = *((__global DATA_TYPE *)(src_addr + 33 * src_stride_z));
    DATA_TYPE d42 = *((__global DATA_TYPE *)(src_addr + 34 * src_stride_z));
    DATA_TYPE d43 = *((__global DATA_TYPE *)(src_addr + 35 * src_stride_z));
    DATA_TYPE d44 = *((__global DATA_TYPE *)(src_addr + 36 * src_stride_z));
    DATA_TYPE d45 = *((__global DATA_TYPE *)(src_addr + 37 * src_stride_z));
    DATA_TYPE d46 = *((__global DATA_TYPE *)(src_addr + 38 * src_stride_z));
    DATA_TYPE d47 = *((__global DATA_TYPE *)(src_addr + 39 * src_stride_z));

    DATA_TYPE d50 = *((__global DATA_TYPE *)(src_addr + 40 * src_stride_z));
    DATA_TYPE d51 = *((__global DATA_TYPE *)(src_addr + 41 * src_stride_z));
    DATA_TYPE d52 = *((__global DATA_TYPE *)(src_addr + 42 * src_stride_z));
    DATA_TYPE d53 = *((__global DATA_TYPE *)(src_addr + 43 * src_stride_z));
    DATA_TYPE d54 = *((__global DATA_TYPE *)(src_addr + 44 * src_stride_z));
    DATA_TYPE d55 = *((__global DATA_TYPE *)(src_addr + 45 * src_stride_z));
    DATA_TYPE d56 = *((__global DATA_TYPE *)(src_addr + 46 * src_stride_z));
    DATA_TYPE d57 = *((__global DATA_TYPE *)(src_addr + 47 * src_stride_z));

    DATA_TYPE d60 = *((__global DATA_TYPE *)(src_addr + 48 * src_stride_z));
    DATA_TYPE d61 = *((__global DATA_TYPE *)(src_addr + 49 * src_stride_z));
    DATA_TYPE d62 = *((__global DATA_TYPE *)(src_addr + 50 * src_stride_z));
    DATA_TYPE d63 = *((__global DATA_TYPE *)(src_addr + 51 * src_stride_z));
    DATA_TYPE d64 = *((__global DATA_TYPE *)(src_addr + 52 * src_stride_z));
    DATA_TYPE d65 = *((__global DATA_TYPE *)(src_addr + 53 * src_stride_z));
    DATA_TYPE d66 = *((__global DATA_TYPE *)(src_addr + 54 * src_stride_z));
    DATA_TYPE d67 = *((__global DATA_TYPE *)(src_addr + 55 * src_stride_z));

    DATA_TYPE d70 = *((__global DATA_TYPE *)(src_addr + 56 * src_stride_z));
    DATA_TYPE d71 = *((__global DATA_TYPE *)(src_addr + 57 * src_stride_z));
    DATA_TYPE d72 = *((__global DATA_TYPE *)(src_addr + 58 * src_stride_z));
    DATA_TYPE d73 = *((__global DATA_TYPE *)(src_addr + 59 * src_stride_z));
    DATA_TYPE d74 = *((__global DATA_TYPE *)(src_addr + 60 * src_stride_z));
    DATA_TYPE d75 = *((__global DATA_TYPE *)(src_addr + 61 * src_stride_z));
    DATA_TYPE d76 = *((__global DATA_TYPE *)(src_addr + 62 * src_stride_z));
    DATA_TYPE d77 = *((__global DATA_TYPE *)(src_addr + 63 * src_stride_z));

    // Compute the 8x4 intermediate tensor
    VEC_DATA_TYPE(float, 4)
    comm_fact0, comm_fact1, comm_fact2;
    VEC_DATA_TYPE(float, 4)
    tmp_col0, tmp_col1, tmp_col2, tmp_col3, tmp_col4, tmp_col5, tmp_col6, tmp_col7;

    COMPUTE_TMP_COL(tmp_col0, d00, d10, d20, d30, d40, d50, d60, d70, comm_fact0);
    COMPUTE_TMP_COL(tmp_col1, d01, d11, d21, d31, d41, d51, d61, d71, comm_fact0);
    COMPUTE_TMP_COL(tmp_col2, d02, d12, d22, d32, d42, d52, d62, d72, comm_fact0);
    COMPUTE_TMP_COL(tmp_col3, d03, d13, d23, d33, d43, d53, d63, d73, comm_fact0);
    COMPUTE_TMP_COL(tmp_col4, d04, d14, d24, d34, d44, d54, d64, d74, comm_fact0);
    COMPUTE_TMP_COL(tmp_col5, d05, d15, d25, d35, d45, d55, d65, d75, comm_fact0);
    COMPUTE_TMP_COL(tmp_col6, d06, d16, d26, d36, d46, d56, d66, d76, comm_fact0);
    COMPUTE_TMP_COL(tmp_col7, d07, d17, d27, d37, d47, d57, d67, d77, comm_fact0);

    // Compute the 4x4 output tile
    comm_fact0 = tmp_col1 + tmp_col2;
    comm_fact1 = tmp_col3 + tmp_col4;
    comm_fact2 = tmp_col5 + tmp_col6;

    VEC_DATA_TYPE(float, 4)
    out_col0 = comm_fact0 + comm_fact1 + (float)8.f * comm_fact2 + tmp_col0;
    VEC_DATA_TYPE(float, 4)
    out_col2 = comm_fact0 + (float)4.f * comm_fact1 + (float)2.f * comm_fact2;

    comm_fact0 = tmp_col1 - tmp_col2;
    comm_fact1 = tmp_col3 - tmp_col4;
    comm_fact2 = tmp_col5 - tmp_col6;

    VEC_DATA_TYPE(float, 4)
    out_col1 = comm_fact0 + (float)2.f * comm_fact1 + (float)4.f * comm_fact2;
    VEC_DATA_TYPE(float, 4)
    out_col3 = comm_fact0 + (float)8.f * comm_fact1 + comm_fact2 + tmp_col7;

#if defined(HAS_BIAS)
    // Add bias
    Vector bias = CONVERT_TO_VECTOR_STRUCT_NO_STEP(bias);

    float b = (float) * ((__global DATA_TYPE *)(vector_offset(&bias, z_out)));

    out_col0 += (VEC_DATA_TYPE(float, 4))b;
    out_col1 += (VEC_DATA_TYPE(float, 4))b;
    out_col2 += (VEC_DATA_TYPE(float, 4))b;
    out_col3 += (VEC_DATA_TYPE(float, 4))b;
#endif // defined(HAS_BIAS)

    // Store the output tile
    vstore4(ACTIVATION_FUNC((VEC_DATA_TYPE(DATA_TYPE, 4))(out_col0.s0, out_col1.s0, out_col2.s0, out_col3.s0)), 0, (__global DATA_TYPE *)(dst_addr + 0 * dst_stride_y));
    vstore4(ACTIVATION_FUNC((VEC_DATA_TYPE(DATA_TYPE, 4))(out_col0.s1, out_col1.s1, out_col2.s1, out_col3.s1)), 0, (__global DATA_TYPE *)(dst_addr + 1 * dst_stride_y));
    vstore4(ACTIVATION_FUNC((VEC_DATA_TYPE(DATA_TYPE, 4))(out_col0.s2, out_col1.s2, out_col2.s2, out_col3.s2)), 0, (__global DATA_TYPE *)(dst_addr + 2 * dst_stride_y));
    vstore4(ACTIVATION_FUNC((VEC_DATA_TYPE(DATA_TYPE, 4))(out_col0.s3, out_col1.s3, out_col2.s3, out_col3.s3)), 0, (__global DATA_TYPE *)(dst_addr + 3 * dst_stride_y));
#endif // !defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) && !defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
}

/** This OpenCL kernel performs Winograd output transform when the output tile is 4x4/4x1 or 1x4, the filter size 5x5/5x1 or 1x5 and the data layout is NHWC
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=4
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=4
 * @note If this kernel is used to perform Winograd output transform 5x1, -DWINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL has to be passed at compile time
 * @note If this kernel is used to perform Winograd output transform 1x5, -DWINOGRAD_OUTPUT_TRANSFORM_VERTICAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_4x4_5x5_nhwc(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst),
#if defined(HAS_BIAS)
    VECTOR_DECLARATION(bias),
#endif // defined(HAS_BIAS)
    int dst_size)
{
    // Each thread stores a 4x4/4x1 or 1x4 tile
#if defined(SRC_DEPTH)
    Tensor4D       src             = CONVERT_TO_TENSOR4D_STRUCT(src, SRC_DEPTH);
    const __global uchar *src_addr = tensor4D_offset(&src, 0, 0, 0, 0);
#else  /* defined(SRC_DEPTH) */
    Tensor3D       src             = CONVERT_TO_TENSOR3D_STRUCT(src);
    const __global uchar *src_addr = tensor3D_offset(&src, 0, 0, 0);
#endif /* defined(SRC_DEPTH) */

    int y_in  = get_global_id(1);
    int x_out = get_global_id(0);
    int y_out = (y_in % NUM_TILES_X) * OUTPUT_TILE_W;
    int z_out = (y_in / NUM_TILES_X) * OUTPUT_TILE_H;
#if defined(SRC_DEPTH)
    int batch = get_global_id(2) / SRC_DEPTH;
#endif /* defined(SRC_DEPTH) */

    // Load the values across the channels to compose the input tile
    DATA_TYPE d00 = *((__global DATA_TYPE *)(src_addr + 0 * src_stride_z));
    DATA_TYPE d01 = *((__global DATA_TYPE *)(src_addr + 1 * src_stride_z));
    DATA_TYPE d02 = *((__global DATA_TYPE *)(src_addr + 2 * src_stride_z));
    DATA_TYPE d03 = *((__global DATA_TYPE *)(src_addr + 3 * src_stride_z));
    DATA_TYPE d04 = *((__global DATA_TYPE *)(src_addr + 4 * src_stride_z));
    DATA_TYPE d05 = *((__global DATA_TYPE *)(src_addr + 5 * src_stride_z));
    DATA_TYPE d06 = *((__global DATA_TYPE *)(src_addr + 6 * src_stride_z));
    DATA_TYPE d07 = *((__global DATA_TYPE *)(src_addr + 7 * src_stride_z));

#if defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    // Compute out00, out01, out02 and out03
    float out00 = d00 + d01 + d02 + d03 + d04 + 8.0f * d05 + 8.0f * d06;
    float out01 = d01 - d02 + 2.0f * d03 - 2.0f * d04 + 4.0f * d05 - 4.0f * d06;
    float out02 = d01 + d02 + 4.0f * d03 + 4.0f * d04 + 2.0f * d05 + 2.0f * d06;
    float out03 = d01 - d02 + 8.0f * d03 - 8.0f * d04 + d05 - d06 + d07;

#if defined(HAS_BIAS)
    // Add bias
    Vector bias = CONVERT_TO_VECTOR_STRUCT_NO_STEP(bias);

    float b = (float) * ((__global DATA_TYPE *)(vector_offset(&bias, x_out)));

    out00 += (float)b;
    out01 += (float)b;
    out02 += (float)b;
    out03 += (float)b;
#endif // defined(HAS_BIAS)

    // Store the output tile
#if defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    // Get output address
#if defined(SRC_DEPTH)
    int4 offset = (int4)(dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z + batch * dst_stride_w);
#else                                                                               /* defined(SRC_DEPTH) */
    int4 offset = (int4)(dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z);
#endif                                                                              /* defined(SRC_DEPTH) */
    offset = min(offset + (int4)(0, 1, 2, 3) * (int4)dst_stride_z, (int4)dst_size); // If address is beyond the last plane, clamp it to dst_size (which points to the last padding).

    VEC_DATA_TYPE(DATA_TYPE, 4)
    out0_dt                                      = ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out00, out01, out02, out03), VEC_DATA_TYPE(DATA_TYPE, 4)));
    *(__global DATA_TYPE *)(dst_ptr + offset.s0) = out0_dt.s0;
    *(__global DATA_TYPE *)(dst_ptr + offset.s1) = out0_dt.s1;
    *(__global DATA_TYPE *)(dst_ptr + offset.s2) = out0_dt.s2;
    *(__global DATA_TYPE *)(dst_ptr + offset.s3) = out0_dt.s3;
#else  // defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
    // Get output address
    int offset = dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z;
    VEC_DATA_TYPE(DATA_TYPE, 4)
    out0_dt                                                      = ACTIVATION_FUNC(CONVERT((VEC_DATA_TYPE(float, 4))(out00, out01, out02, out03), VEC_DATA_TYPE(DATA_TYPE, 4)));
    *(__global DATA_TYPE *)(dst_ptr + 0 * dst_stride_y + offset) = out0_dt.s0;
    *(__global DATA_TYPE *)(dst_ptr + 1 * dst_stride_y + offset) = out0_dt.s1;
    *(__global DATA_TYPE *)(dst_ptr + 2 * dst_stride_y + offset) = out0_dt.s2;
    *(__global DATA_TYPE *)(dst_ptr + 3 * dst_stride_y + offset) = out0_dt.s3;
#endif // defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

#else // defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)

    DATA_TYPE d10 = *((__global DATA_TYPE *)(src_addr + 8 * src_stride_z));
    DATA_TYPE d11 = *((__global DATA_TYPE *)(src_addr + 9 * src_stride_z));
    DATA_TYPE d12 = *((__global DATA_TYPE *)(src_addr + 10 * src_stride_z));
    DATA_TYPE d13 = *((__global DATA_TYPE *)(src_addr + 11 * src_stride_z));
    DATA_TYPE d14 = *((__global DATA_TYPE *)(src_addr + 12 * src_stride_z));
    DATA_TYPE d15 = *((__global DATA_TYPE *)(src_addr + 13 * src_stride_z));
    DATA_TYPE d16 = *((__global DATA_TYPE *)(src_addr + 14 * src_stride_z));
    DATA_TYPE d17 = *((__global DATA_TYPE *)(src_addr + 15 * src_stride_z));

    DATA_TYPE d20 = *((__global DATA_TYPE *)(src_addr + 16 * src_stride_z));
    DATA_TYPE d21 = *((__global DATA_TYPE *)(src_addr + 17 * src_stride_z));
    DATA_TYPE d22 = *((__global DATA_TYPE *)(src_addr + 18 * src_stride_z));
    DATA_TYPE d23 = *((__global DATA_TYPE *)(src_addr + 19 * src_stride_z));
    DATA_TYPE d24 = *((__global DATA_TYPE *)(src_addr + 20 * src_stride_z));
    DATA_TYPE d25 = *((__global DATA_TYPE *)(src_addr + 21 * src_stride_z));
    DATA_TYPE d26 = *((__global DATA_TYPE *)(src_addr + 22 * src_stride_z));
    DATA_TYPE d27 = *((__global DATA_TYPE *)(src_addr + 23 * src_stride_z));

    DATA_TYPE d30 = *((__global DATA_TYPE *)(src_addr + 24 * src_stride_z));
    DATA_TYPE d31 = *((__global DATA_TYPE *)(src_addr + 25 * src_stride_z));
    DATA_TYPE d32 = *((__global DATA_TYPE *)(src_addr + 26 * src_stride_z));
    DATA_TYPE d33 = *((__global DATA_TYPE *)(src_addr + 27 * src_stride_z));
    DATA_TYPE d34 = *((__global DATA_TYPE *)(src_addr + 28 * src_stride_z));
    DATA_TYPE d35 = *((__global DATA_TYPE *)(src_addr + 29 * src_stride_z));
    DATA_TYPE d36 = *((__global DATA_TYPE *)(src_addr + 30 * src_stride_z));
    DATA_TYPE d37 = *((__global DATA_TYPE *)(src_addr + 31 * src_stride_z));

    DATA_TYPE d40 = *((__global DATA_TYPE *)(src_addr + 32 * src_stride_z));
    DATA_TYPE d41 = *((__global DATA_TYPE *)(src_addr + 33 * src_stride_z));
    DATA_TYPE d42 = *((__global DATA_TYPE *)(src_addr + 34 * src_stride_z));
    DATA_TYPE d43 = *((__global DATA_TYPE *)(src_addr + 35 * src_stride_z));
    DATA_TYPE d44 = *((__global DATA_TYPE *)(src_addr + 36 * src_stride_z));
    DATA_TYPE d45 = *((__global DATA_TYPE *)(src_addr + 37 * src_stride_z));
    DATA_TYPE d46 = *((__global DATA_TYPE *)(src_addr + 38 * src_stride_z));
    DATA_TYPE d47 = *((__global DATA_TYPE *)(src_addr + 39 * src_stride_z));

    DATA_TYPE d50 = *((__global DATA_TYPE *)(src_addr + 40 * src_stride_z));
    DATA_TYPE d51 = *((__global DATA_TYPE *)(src_addr + 41 * src_stride_z));
    DATA_TYPE d52 = *((__global DATA_TYPE *)(src_addr + 42 * src_stride_z));
    DATA_TYPE d53 = *((__global DATA_TYPE *)(src_addr + 43 * src_stride_z));
    DATA_TYPE d54 = *((__global DATA_TYPE *)(src_addr + 44 * src_stride_z));
    DATA_TYPE d55 = *((__global DATA_TYPE *)(src_addr + 45 * src_stride_z));
    DATA_TYPE d56 = *((__global DATA_TYPE *)(src_addr + 46 * src_stride_z));
    DATA_TYPE d57 = *((__global DATA_TYPE *)(src_addr + 47 * src_stride_z));

    DATA_TYPE d60 = *((__global DATA_TYPE *)(src_addr + 48 * src_stride_z));
    DATA_TYPE d61 = *((__global DATA_TYPE *)(src_addr + 49 * src_stride_z));
    DATA_TYPE d62 = *((__global DATA_TYPE *)(src_addr + 50 * src_stride_z));
    DATA_TYPE d63 = *((__global DATA_TYPE *)(src_addr + 51 * src_stride_z));
    DATA_TYPE d64 = *((__global DATA_TYPE *)(src_addr + 52 * src_stride_z));
    DATA_TYPE d65 = *((__global DATA_TYPE *)(src_addr + 53 * src_stride_z));
    DATA_TYPE d66 = *((__global DATA_TYPE *)(src_addr + 54 * src_stride_z));
    DATA_TYPE d67 = *((__global DATA_TYPE *)(src_addr + 55 * src_stride_z));

    DATA_TYPE d70 = *((__global DATA_TYPE *)(src_addr + 56 * src_stride_z));
    DATA_TYPE d71 = *((__global DATA_TYPE *)(src_addr + 57 * src_stride_z));
    DATA_TYPE d72 = *((__global DATA_TYPE *)(src_addr + 58 * src_stride_z));
    DATA_TYPE d73 = *((__global DATA_TYPE *)(src_addr + 59 * src_stride_z));
    DATA_TYPE d74 = *((__global DATA_TYPE *)(src_addr + 60 * src_stride_z));
    DATA_TYPE d75 = *((__global DATA_TYPE *)(src_addr + 61 * src_stride_z));
    DATA_TYPE d76 = *((__global DATA_TYPE *)(src_addr + 62 * src_stride_z));
    DATA_TYPE d77 = *((__global DATA_TYPE *)(src_addr + 63 * src_stride_z));

    // Compute the 8x4 intermediate tensor
    VEC_DATA_TYPE(float, 4)
    comm_fact0, comm_fact1, comm_fact2;
    VEC_DATA_TYPE(float, 4)
    tmp_col0, tmp_col1, tmp_col2, tmp_col3, tmp_col4, tmp_col5, tmp_col6, tmp_col7;

    COMPUTE_TMP_COL(tmp_col0, d00, d10, d20, d30, d40, d50, d60, d70, comm_fact0);
    COMPUTE_TMP_COL(tmp_col1, d01, d11, d21, d31, d41, d51, d61, d71, comm_fact0);
    COMPUTE_TMP_COL(tmp_col2, d02, d12, d22, d32, d42, d52, d62, d72, comm_fact0);
    COMPUTE_TMP_COL(tmp_col3, d03, d13, d23, d33, d43, d53, d63, d73, comm_fact0);
    COMPUTE_TMP_COL(tmp_col4, d04, d14, d24, d34, d44, d54, d64, d74, comm_fact0);
    COMPUTE_TMP_COL(tmp_col5, d05, d15, d25, d35, d45, d55, d65, d75, comm_fact0);
    COMPUTE_TMP_COL(tmp_col6, d06, d16, d26, d36, d46, d56, d66, d76, comm_fact0);
    COMPUTE_TMP_COL(tmp_col7, d07, d17, d27, d37, d47, d57, d67, d77, comm_fact0);

    // Compute the output tile
    comm_fact0 = tmp_col1 + tmp_col2;
    comm_fact1 = tmp_col3 + tmp_col4;
    comm_fact2 = tmp_col5 + tmp_col6;

    VEC_DATA_TYPE(float, 4)
    out_col0 = comm_fact0 + comm_fact1 + 8.f * comm_fact2 + tmp_col0;
    VEC_DATA_TYPE(float, 4)
    out_col2 = comm_fact0 + 4.f * comm_fact1 + 2.f * comm_fact2;

    comm_fact0 = tmp_col1 - tmp_col2;
    comm_fact1 = tmp_col3 - tmp_col4;
    comm_fact2 = tmp_col5 - tmp_col6;

    VEC_DATA_TYPE(float, 4)
    out_col1 = comm_fact0 + 2.f * comm_fact1 + 4.f * comm_fact2;
    VEC_DATA_TYPE(float, 4)
    out_col3 = comm_fact0 + 8.f * comm_fact1 + comm_fact2 + tmp_col7;

#if defined(HAS_BIAS)
    // Add bias
    Vector bias = CONVERT_TO_VECTOR_STRUCT_NO_STEP(bias);

    DATA_TYPE b = (float) * ((__global DATA_TYPE *)(vector_offset(&bias, x_out)));

    out_col0 += (VEC_DATA_TYPE(float, 4))b;
    out_col1 += (VEC_DATA_TYPE(float, 4))b;
    out_col2 += (VEC_DATA_TYPE(float, 4))b;
    out_col3 += (VEC_DATA_TYPE(float, 4))b;
#endif // defined(HAS_BIAS)
    // Get output address
#if defined(SRC_DEPTH)
    int4 offset = (int4)(dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z + batch * dst_stride_w);
#else  /* defined(SRC_DEPTH) */
    int4 offset = (int4)(dst_offset_first_element_in_bytes + x_out * sizeof(DATA_TYPE) + y_out * dst_stride_y + z_out * dst_stride_z);
#endif /* defined(SRC_DEPTH) */
    offset      = min(offset + (int4)(0, 1, 2, 3) * (int4)dst_stride_z, (int4)dst_size); // If address is beyond the last plane, clamp it to dst_size (which points to the last padding).
    int4 mult_y = min((int4)dst_size - offset, (int4)1);                                 // If out of bound, we don't want to increase dst_stride_y, so we set the multiplier to 0. It will be 1 otherwise.

    // Store the output tile
    VEC_DATA_TYPE(DATA_TYPE, VEC_SIZE)
    out_col0_dt = ACTIVATION_FUNC(CONVERT(out_col0, VEC_DATA_TYPE(DATA_TYPE, VEC_SIZE)));
    VEC_DATA_TYPE(DATA_TYPE, VEC_SIZE)
    out_col1_dt = ACTIVATION_FUNC(CONVERT(out_col1, VEC_DATA_TYPE(DATA_TYPE, VEC_SIZE)));
    VEC_DATA_TYPE(DATA_TYPE, VEC_SIZE)
    out_col2_dt = ACTIVATION_FUNC(CONVERT(out_col2, VEC_DATA_TYPE(DATA_TYPE, VEC_SIZE)));
    VEC_DATA_TYPE(DATA_TYPE, VEC_SIZE)
    out_col3_dt = ACTIVATION_FUNC(CONVERT(out_col3, VEC_DATA_TYPE(DATA_TYPE, VEC_SIZE)));

    *(__global DATA_TYPE *)(dst_ptr + mult_y.s0 * 0 * (int)dst_stride_y + offset.s0) = out_col0_dt.s0;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s0 * 1 * (int)dst_stride_y + offset.s0) = out_col1_dt.s0;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s0 * 2 * (int)dst_stride_y + offset.s0) = out_col2_dt.s0;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s0 * 3 * (int)dst_stride_y + offset.s0) = out_col3_dt.s0;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s1 * 0 * (int)dst_stride_y + offset.s1) = out_col0_dt.s1;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s1 * 1 * (int)dst_stride_y + offset.s1) = out_col1_dt.s1;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s1 * 2 * (int)dst_stride_y + offset.s1) = out_col2_dt.s1;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s1 * 3 * (int)dst_stride_y + offset.s1) = out_col3_dt.s1;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s2 * 0 * (int)dst_stride_y + offset.s2) = out_col0_dt.s2;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s2 * 1 * (int)dst_stride_y + offset.s2) = out_col1_dt.s2;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s2 * 2 * (int)dst_stride_y + offset.s2) = out_col2_dt.s2;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s2 * 3 * (int)dst_stride_y + offset.s2) = out_col3_dt.s2;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s3 * 0 * (int)dst_stride_y + offset.s3) = out_col0_dt.s3;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s3 * 1 * (int)dst_stride_y + offset.s3) = out_col1_dt.s3;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s3 * 2 * (int)dst_stride_y + offset.s3) = out_col2_dt.s3;
    *(__global DATA_TYPE *)(dst_ptr + mult_y.s3 * 3 * (int)dst_stride_y + offset.s3) = out_col3_dt.s3;
#endif // defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL) || defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
}
#endif // defined(VEC_SIZE) && VEC_SIZE == 4

#if defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL)
#if defined(VEC_SIZE) && VEC_SIZE == 2
/** This OpenCL kernel performs Winograd output transform when the output tile is 2x1, the filter size 3x1 and the data layout is NCHW
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=2
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=1
 * @note -DWINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_2x1_3x1_nchw(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst)
#if defined(HAS_BIAS)
    ,
    VECTOR_DECLARATION(bias)
#endif // defined(HAS_BIAS)
)
{
    winograd_output_transform_2x2_3x3_nchw(src_ptr,
                                           src_stride_x,
                                           src_step_x,
                                           src_stride_y,
                                           src_step_y,
                                           src_stride_z,
                                           src_step_z,
                                           src_stride_w,
                                           src_step_w,
                                           src_offset_first_element_in_bytes,
                                           dst_ptr,
                                           dst_stride_x,
                                           dst_step_x,
                                           dst_stride_y,
                                           dst_step_y,
                                           dst_stride_z,
                                           dst_step_z,
                                           dst_stride_w,
                                           dst_step_w,
                                           dst_offset_first_element_in_bytes
#if defined(HAS_BIAS)
                                           ,
                                           bias_ptr,
                                           bias_stride_x,
                                           bias_step_x,
                                           bias_offset_first_element_in_bytes
#endif // defined(HAS_BIAS)
                                          );
}

/** This OpenCL kernel performs Winograd output transform when the output tile is 2x1, the filter size 7x1 and the data layout is NHWC
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=2
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=1
 * @note -DWINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_2x1_7x1_nhwc(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst),
#if defined(HAS_BIAS)
    VECTOR_DECLARATION(bias),
#endif // defined(HAS_BIAS)
    int dst_size)
{
    winograd_output_transform_2x2_7x7_nhwc(src_ptr,
                                           src_stride_x,
                                           src_step_x,
                                           src_stride_y,
                                           src_step_y,
                                           src_stride_z,
                                           src_step_z,
                                           src_stride_w,
                                           src_step_w,
                                           src_offset_first_element_in_bytes,
                                           dst_ptr,
                                           dst_stride_x,
                                           dst_step_x,
                                           dst_stride_y,
                                           dst_step_y,
                                           dst_stride_z,
                                           dst_step_z,
                                           dst_stride_w,
                                           dst_step_w,
                                           dst_offset_first_element_in_bytes,
#if defined(HAS_BIAS)
                                           bias_ptr,
                                           bias_stride_x,
                                           bias_step_x,
                                           bias_offset_first_element_in_bytes,
#endif // defined(HAS_BIAS)
                                           dst_size);
}
#endif // defined(VEC_SIZE) && VEC_SIZE == 2

#if defined(VEC_SIZE) && VEC_SIZE == 4
/** This OpenCL kernel performs Winograd output transform when the output tile is 4x1, the filter size 3x1 and the data layout is NCHW
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=4
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=1
 * @note -DWINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_4x1_3x1_nchw(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst)
#if defined(HAS_BIAS)
    ,
    VECTOR_DECLARATION(bias)
#endif // defined(HAS_BIAS)
)
{
    winograd_output_transform_4x4_3x3_nchw(src_ptr,
                                           src_stride_x,
                                           src_step_x,
                                           src_stride_y,
                                           src_step_y,
                                           src_stride_z,
                                           src_step_z,
                                           src_stride_w,
                                           src_step_w,
                                           src_offset_first_element_in_bytes,
                                           dst_ptr,
                                           dst_stride_x,
                                           dst_step_x,
                                           dst_stride_y,
                                           dst_step_y,
                                           dst_stride_z,
                                           dst_step_z,
                                           dst_stride_w,
                                           dst_step_w,
                                           dst_offset_first_element_in_bytes
#if defined(HAS_BIAS)
                                           ,
                                           bias_ptr,
                                           bias_stride_x,
                                           bias_step_x,
                                           bias_offset_first_element_in_bytes
#endif // defined(HAS_BIAS)
                                          );
}

/** This OpenCL kernel performs Winograd output transform when the output tile is 4x1, the filter size 5x1 and the data layout is NCHW
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=4
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=1
 * @note -DWINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_4x1_5x1_nchw(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst)
#if defined(HAS_BIAS)
    ,
    VECTOR_DECLARATION(bias)
#endif // defined(HAS_BIAS)
)
{
    winograd_output_transform_4x4_5x5_nchw(src_ptr,
                                           src_stride_x,
                                           src_step_x,
                                           src_stride_y,
                                           src_step_y,
                                           src_stride_z,
                                           src_step_z,
                                           src_stride_w,
                                           src_step_w,
                                           src_offset_first_element_in_bytes,
                                           dst_ptr,
                                           dst_stride_x,
                                           dst_step_x,
                                           dst_stride_y,
                                           dst_step_y,
                                           dst_stride_z,
                                           dst_step_z,
                                           dst_stride_w,
                                           dst_step_w,
                                           dst_offset_first_element_in_bytes
#if defined(HAS_BIAS)
                                           ,
                                           bias_ptr,
                                           bias_stride_x,
                                           bias_step_x,
                                           bias_offset_first_element_in_bytes
#endif // defined(HAS_BIAS)
                                          );
}

/** This OpenCL kernel performs Winograd output transform when the output tile is 4x1, the filter size 3x1 and the data layout is NHWC
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=4
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=1
 * @note -DWINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_4x1_3x1_nhwc(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst),
#if defined(HAS_BIAS)
    VECTOR_DECLARATION(bias),
#endif // defined(HAS_BIAS)
    int dst_size)
{
    winograd_output_transform_4x4_3x3_nhwc(src_ptr,
                                           src_stride_x,
                                           src_step_x,
                                           src_stride_y,
                                           src_step_y,
                                           src_stride_z,
                                           src_step_z,
                                           src_stride_w,
                                           src_step_w,
                                           src_offset_first_element_in_bytes,
                                           dst_ptr,
                                           dst_stride_x,
                                           dst_step_x,
                                           dst_stride_y,
                                           dst_step_y,
                                           dst_stride_z,
                                           dst_step_z,
                                           dst_stride_w,
                                           dst_step_w,
                                           dst_offset_first_element_in_bytes,
#if defined(HAS_BIAS)
                                           bias_ptr,
                                           bias_stride_x,
                                           bias_step_x,
                                           bias_offset_first_element_in_bytes,
#endif // defined(HAS_BIAS)
                                           dst_size);
}

/** This OpenCL kernel performs Winograd output transform when the output tile is 4x1, the filter size 5x1 and the data layout is NHWC
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=4
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=1
 * @note -DWINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_4x1_5x1_nhwc(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst),
#if defined(HAS_BIAS)
    VECTOR_DECLARATION(bias),
#endif // defined(HAS_BIAS)
    int dst_size)
{
    winograd_output_transform_4x4_5x5_nhwc(src_ptr,
                                           src_stride_x,
                                           src_step_x,
                                           src_stride_y,
                                           src_step_y,
                                           src_stride_z,
                                           src_step_z,
                                           src_stride_w,
                                           src_step_w,
                                           src_offset_first_element_in_bytes,
                                           dst_ptr,
                                           dst_stride_x,
                                           dst_step_x,
                                           dst_stride_y,
                                           dst_step_y,
                                           dst_stride_z,
                                           dst_step_z,
                                           dst_stride_w,
                                           dst_step_w,
                                           dst_offset_first_element_in_bytes,
#if defined(HAS_BIAS)
                                           bias_ptr,
                                           bias_stride_x,
                                           bias_step_x,
                                           bias_offset_first_element_in_bytes,
#endif // defined(HAS_BIAS)
                                           dst_size);
}
#endif // defined(VEC_SIZE) && VEC_SIZE == 4
#endif // defined(WINOGRAD_OUTPUT_TRANSFORM_HORIZONTAL)

#if defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
#if defined(VEC_SIZE) && VEC_SIZE == 2
/** This OpenCL kernel performs Winograd output transform when the output tile is 1x2, the filter size 1x3 and the data layout is NCHW
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=1
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=2
 * @note -DWINOGRAD_OUTPUT_TRANSFORM_VERTICAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_1x2_1x3_nchw(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst)
#if defined(HAS_BIAS)
    ,
    VECTOR_DECLARATION(bias)
#endif // defined(HAS_BIAS)
)
{
    winograd_output_transform_2x2_3x3_nchw(src_ptr,
                                           src_stride_x,
                                           src_step_x,
                                           src_stride_y,
                                           src_step_y,
                                           src_stride_z,
                                           src_step_z,
                                           src_stride_w,
                                           src_step_w,
                                           src_offset_first_element_in_bytes,
                                           dst_ptr,
                                           dst_stride_x,
                                           dst_step_x,
                                           dst_stride_y,
                                           dst_step_y,
                                           dst_stride_z,
                                           dst_step_z,
                                           dst_stride_w,
                                           dst_step_w,
                                           dst_offset_first_element_in_bytes
#if defined(HAS_BIAS)
                                           ,
                                           bias_ptr,
                                           bias_stride_x,
                                           bias_step_x,
                                           bias_offset_first_element_in_bytes
#endif // defined(HAS_BIAS)
                                          );
}

/** This OpenCL kernel performs Winograd output transform when the output tile is 1x2, the filter size 1x7 and the data layout is NHWC
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=1
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=2
 * @note -DWINOGRAD_OUTPUT_TRANSFORM_VERTICAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_1x2_1x7_nhwc(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst),
#if defined(HAS_BIAS)
    VECTOR_DECLARATION(bias),
#endif // defined(HAS_BIAS)
    int dst_size)
{
    winograd_output_transform_2x2_7x7_nhwc(src_ptr,
                                           src_stride_x,
                                           src_step_x,
                                           src_stride_y,
                                           src_step_y,
                                           src_stride_z,
                                           src_step_z,
                                           src_stride_w,
                                           src_step_w,
                                           src_offset_first_element_in_bytes,
                                           dst_ptr,
                                           dst_stride_x,
                                           dst_step_x,
                                           dst_stride_y,
                                           dst_step_y,
                                           dst_stride_z,
                                           dst_step_z,
                                           dst_stride_w,
                                           dst_step_w,
                                           dst_offset_first_element_in_bytes,
#if defined(HAS_BIAS)
                                           bias_ptr,
                                           bias_stride_x,
                                           bias_step_x,
                                           bias_offset_first_element_in_bytes,
#endif // defined(HAS_BIAS)
                                           dst_size);
}
#endif // defined(VEC_SIZE) && VEC_SIZE == 2

#if defined(VEC_SIZE) && VEC_SIZE == 4
/** This OpenCL kernel performs Winograd output transform when the output tile is 1x4, the filter size 1x3 and the data layout is NCHW
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=1
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=4
 * @note -DWINOGRAD_OUTPUT_TRANSFORM_VERTICAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_1x4_1x3_nchw(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst)
#if defined(HAS_BIAS)
    ,
    VECTOR_DECLARATION(bias)
#endif // defined(HAS_BIAS)
)
{
    winograd_output_transform_4x4_3x3_nchw(src_ptr,
                                           src_stride_x,
                                           src_step_x,
                                           src_stride_y,
                                           src_step_y,
                                           src_stride_z,
                                           src_step_z,
                                           src_stride_w,
                                           src_step_w,
                                           src_offset_first_element_in_bytes,
                                           dst_ptr,
                                           dst_stride_x,
                                           dst_step_x,
                                           dst_stride_y,
                                           dst_step_y,
                                           dst_stride_z,
                                           dst_step_z,
                                           dst_stride_w,
                                           dst_step_w,
                                           dst_offset_first_element_in_bytes
#if defined(HAS_BIAS)
                                           ,
                                           bias_ptr,
                                           bias_stride_x,
                                           bias_step_x,
                                           bias_offset_first_element_in_bytes
#endif // defined(HAS_BIAS)
                                          );
}

/** This OpenCL kernel performs Winograd output transform when the output tile is 1x4, the filter size 1x5 and the data layout is NCHW
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=1
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=4
 * @note -DWINOGRAD_OUTPUT_TRANSFORM_VERTICAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_1x4_1x5_nchw(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst)
#if defined(HAS_BIAS)
    ,
    VECTOR_DECLARATION(bias)
#endif // defined(HAS_BIAS)
)
{
    winograd_output_transform_4x4_5x5_nchw(src_ptr,
                                           src_stride_x,
                                           src_step_x,
                                           src_stride_y,
                                           src_step_y,
                                           src_stride_z,
                                           src_step_z,
                                           src_stride_w,
                                           src_step_w,
                                           src_offset_first_element_in_bytes,
                                           dst_ptr,
                                           dst_stride_x,
                                           dst_step_x,
                                           dst_stride_y,
                                           dst_step_y,
                                           dst_stride_z,
                                           dst_step_z,
                                           dst_stride_w,
                                           dst_step_w,
                                           dst_offset_first_element_in_bytes
#if defined(HAS_BIAS)
                                           ,
                                           bias_ptr,
                                           bias_stride_x,
                                           bias_step_x,
                                           bias_offset_first_element_in_bytes
#endif // defined(HAS_BIAS)
                                          );
}

/** This OpenCL kernel performs Winograd output transform when the output tile is 1x4, the filter size 1x3 and the data layout is NHWC
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=1
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=4
 * @note -DWINOGRAD_OUTPUT_TRANSFORM_VERTICAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_1x4_1x3_nhwc(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst),
#if defined(HAS_BIAS)
    VECTOR_DECLARATION(bias),
#endif // defined(HAS_BIAS)
    int dst_size)
{
    winograd_output_transform_4x4_3x3_nhwc(src_ptr,
                                           src_stride_x,
                                           src_step_x,
                                           src_stride_y,
                                           src_step_y,
                                           src_stride_z,
                                           src_step_z,
                                           src_stride_w,
                                           src_step_w,
                                           src_offset_first_element_in_bytes,
                                           dst_ptr,
                                           dst_stride_x,
                                           dst_step_x,
                                           dst_stride_y,
                                           dst_step_y,
                                           dst_stride_z,
                                           dst_step_z,
                                           dst_stride_w,
                                           dst_step_w,
                                           dst_offset_first_element_in_bytes,
#if defined(HAS_BIAS)
                                           bias_ptr,
                                           bias_stride_x,
                                           bias_step_x,
                                           bias_offset_first_element_in_bytes,
#endif // defined(HAS_BIAS)
                                           dst_size);
}

/** This OpenCL kernel performs Winograd output transform when the output tile is 1x4, the filter size 1x5 and the data layout is NHWC
 *
 * @note The number of tiles along the X direction must be passed at compile time using -DNUM_TILES_X: e.g. -DNUM_TILES_X=16
 * @note The width of the output tile must be passed at compile time using -DOUTPUT_TILE_W: e.g. -DOUTPUT_TILE_W=1
 * @note The height of the output tile must be passed at compile time using -DOUTPUT_TILE_H: e.g. -DOUTPUT_TILE_H=4
 * @note -DWINOGRAD_OUTPUT_TRANSFORM_VERTICAL has to be passed at compile time
 * @note The data type must be passed at compile time using -DDATA_TYPE e.g. -DDATA_TYPE=float. Supported data types: float/half.
 *
 * @param[in]  src_ptr                           Pointer to the source tensor. Supported data types: F32/F16
 * @param[in]  src_stride_x                      Stride of the source tensor in X dimension (in bytes)
 * @param[in]  src_step_x                        src_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  src_stride_y                      Stride of the source tensor in Y dimension (in bytes)
 * @param[in]  src_step_y                        src_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  src_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  src_step_z                        src_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  src_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  src_step_w                        src_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  src_offset_first_element_in_bytes The offset of the first element in the source tensor
 * @param[out] dst_ptr                           Pointer to the destination tensor. Supported data types: same as @p src_ptr
 * @param[in]  dst_stride_x                      Stride of the destination tensor in X dimension (in bytes)
 * @param[in]  dst_step_x                        dst_stride_x * number of elements along X processed per workitem(in bytes)
 * @param[in]  dst_stride_y                      Stride of the destination tensor in Y dimension (in bytes)
 * @param[in]  dst_step_y                        dst_stride_y * number of elements along Y processed per workitem(in bytes)
 * @param[in]  dst_stride_z                      Stride of the source tensor in Z dimension (in bytes)
 * @param[in]  dst_step_z                        dst_stride_z * number of elements along Z processed per workitem(in bytes)
 * @param[in]  dst_stride_w                      Stride of the source tensor in W dimension (in bytes)
 * @param[in]  dst_step_w                        dst_stride_w * number of elements along W processed per workitem(in bytes)
 * @param[in]  dst_offset_first_element_in_bytes The offset of the first element in the destination tensor
 */
__kernel void winograd_output_transform_1x4_1x5_nhwc(
    TENSOR4D_DECLARATION(src),
    TENSOR4D_DECLARATION(dst),
#if defined(HAS_BIAS)
    VECTOR_DECLARATION(bias),
#endif // defined(HAS_BIAS)
    int dst_size)
{
    winograd_output_transform_4x4_5x5_nhwc(src_ptr,
                                           src_stride_x,
                                           src_step_x,
                                           src_stride_y,
                                           src_step_y,
                                           src_stride_z,
                                           src_step_z,
                                           src_stride_w,
                                           src_step_w,
                                           src_offset_first_element_in_bytes,
                                           dst_ptr,
                                           dst_stride_x,
                                           dst_step_x,
                                           dst_stride_y,
                                           dst_step_y,
                                           dst_stride_z,
                                           dst_step_z,
                                           dst_stride_w,
                                           dst_step_w,
                                           dst_offset_first_element_in_bytes,
#if defined(HAS_BIAS)
                                           bias_ptr,
                                           bias_stride_x,
                                           bias_step_x,
                                           bias_offset_first_element_in_bytes,
#endif // defined(HAS_BIAS)
                                           dst_size);
}
#endif // defined(VEC_SIZE) && VEC_SIZE == 4
#endif // defined(WINOGRAD_OUTPUT_TRANSFORM_VERTICAL)
#endif // defined(NUM_TILES_X) && defined(OUTPUT_TILE_W) && defined(OUTPUT_TILE_H)
