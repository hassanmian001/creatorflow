__kernel void screen_rgb(__write_only image2d_t destination,
                         unsigned int frame_index,
                         __read_only image2d_t base,
                         __read_only image2d_t watermark)
{
    const sampler_t sampler = CLK_NORMALIZED_COORDS_FALSE |
                              CLK_ADDRESS_CLAMP_TO_EDGE |
                              CLK_FILTER_NEAREST;
    int2 location = (int2)(get_global_id(0), get_global_id(1));
    float4 a = read_imagef(base, sampler, location);
    float4 b = read_imagef(watermark, sampler, location);
    float4 result = 1.0f - (1.0f - a) * (1.0f - b);
    result.w = a.w;
    write_imagef(destination, location, clamp(result, 0.0f, 1.0f));
}

__kernel void alpha_over(__write_only image2d_t destination,
                         unsigned int frame_index,
                         __read_only image2d_t base,
                         __read_only image2d_t overlay)
{
    const sampler_t sampler = CLK_NORMALIZED_COORDS_FALSE |
                              CLK_ADDRESS_CLAMP_TO_EDGE |
                              CLK_FILTER_NEAREST;
    int2 location = (int2)(get_global_id(0), get_global_id(1));
    float4 a = read_imagef(base, sampler, location);
    float4 b = read_imagef(overlay, sampler, location);
    float alpha = clamp(b.w, 0.0f, 1.0f);
    float4 result;
    result.xyz = b.xyz * alpha + a.xyz * (1.0f - alpha);
    result.w = alpha + a.w * (1.0f - alpha);
    write_imagef(destination, location, clamp(result, 0.0f, 1.0f));
}

__kernel void screen_caption_rgb(__write_only image2d_t destination,
                                 unsigned int frame_index,
                                 __read_only image2d_t base,
                                 __read_only image2d_t watermark,
                                 __read_only image2d_t caption)
{
    const sampler_t sampler = CLK_NORMALIZED_COORDS_FALSE |
                              CLK_ADDRESS_CLAMP_TO_EDGE |
                              CLK_FILTER_NEAREST;
    int2 location = (int2)(get_global_id(0), get_global_id(1));
    float4 a = read_imagef(base, sampler, location);
    float4 b = read_imagef(watermark, sampler, location);
    float4 c = read_imagef(caption, sampler, location);
    float4 screened = 1.0f - (1.0f - a) * (1.0f - b);
    float alpha = clamp(c.w, 0.0f, 1.0f);
    float4 result;
    result.xyz = c.xyz * alpha + screened.xyz * (1.0f - alpha);
    result.w = alpha + a.w * (1.0f - alpha);
    write_imagef(destination, location, clamp(result, 0.0f, 1.0f));
}
