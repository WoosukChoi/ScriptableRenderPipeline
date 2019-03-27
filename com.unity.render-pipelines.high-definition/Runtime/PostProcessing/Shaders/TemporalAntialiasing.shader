Shader "Hidden/HDRP/TemporalAntialiasing"
{
    HLSLINCLUDE



        #pragma target 4.5
        #pragma multi_compile_local _ ORTHOGRAPHIC
        #pragma multi_compile_local _ REDUCED_HISTORY_CONTRIB
        #pragma only_renderers d3d11 ps4 xboxone vulkan metal switch
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"
        #include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/Builtin/BuiltinData.hlsl"
        #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"

        TEXTURE2D_X(_InputTexture);
        TEXTURE2D_X(_InputHistoryTexture);

        CBUFFER_START(cb0)
            float4 _ScreenToTargetScaleHistory;
        CBUFFER_END

        #define HDR_MAPUNMAP        1
        #define CLIP_AABB           1
        #define RADIUS              0.75
        #define FEEDBACK_MIN        0.96
        #define FEEDBACK_MAX        0.91
        #define SHARPEN             0
        #define SHARPEN_STRENGTH    0.35

        #define CLAMP_MAX       65472.0 // HALF_MAX minus one (2 - 2^-9) * 2^15

        #if UNITY_REVERSED_Z
            #define COMPARE_DEPTH(a, b) step(b, a)
        #else
            #define COMPARE_DEPTH(a, b) step(a, b)
        #endif


        struct Attributes
        {
            uint vertexID : SV_VertexID;
            UNITY_VERTEX_INPUT_INSTANCE_ID
        };

        struct Varyings
        {
            float4 positionCS : SV_POSITION;
            float2 texcoord   : TEXCOORD0;
            UNITY_VERTEX_OUTPUT_STEREO
        };

        Varyings Vert(Attributes input)
        {
            Varyings output;
            UNITY_SETUP_INSTANCE_ID(input);
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
            output.positionCS = GetFullScreenTriangleVertexPosition(input.vertexID);
            output.texcoord = GetFullScreenTriangleVertexPosition(input.vertexID);
            return output;
        }

        float3 Fetch(TEXTURE2D_X(tex), float2 coords, float2 offset, float2 scale)
        {
            float2 uv = (coords + offset * _ScreenSize.zw) * scale;
            return SAMPLE_TEXTURE2D_X_LOD(tex, sampler_LinearClamp, uv, 0).xyz;
        }

        float3 Map(float3 x)
        {
            #if HDR_MAPUNMAP
            return FastTonemap(x);
            #else
            return x;
            #endif
        }

        float3 Unmap(float3 x)
        {
            #if HDR_MAPUNMAP
            return FastTonemapInvert(x);
            #else
            return x;
            #endif
        }

        float3 ClipToAABB(float3 color, float3 minimum, float3 maximum)
        {
            // note: only clips towards aabb center (but fast!)
            float3 center  = 0.5 * (maximum + minimum);
            float3 extents = 0.5 * (maximum - minimum);

            // This is actually `distance`, however the keyword is reserved
            float3 offset = color - center;
            
            float3 ts = abs(extents) / max(abs(offset), 1e-4);
            float t = saturate(Min3(ts.x, ts.y,  ts.z));
            return center + offset * t;
        }

        float2 GetClosestFragment(int2 positionSS)
        {
            float center  = LoadCameraDepth(positionSS);
            float nw = LoadCameraDepth(positionSS + int2(-1, -1));
            float ne = LoadCameraDepth(positionSS + int2( 1, -1));
            float sw = LoadCameraDepth(positionSS + int2(-1,  1));
            float se = LoadCameraDepth(positionSS + int2( 1,  1));

            float4 neighborhood = float4(nw, ne, sw, se);

            float3 closest = float3(0.0, 0.0, center);
            closest = lerp(closest, float3(-1.0, -1.0, neighborhood.x), COMPARE_DEPTH(neighborhood.x, closest.z));
            closest = lerp(closest, float3( 1.0, -1.0, neighborhood.y), COMPARE_DEPTH(neighborhood.y, closest.z));
            closest = lerp(closest, float3(-1.0,  1.0, neighborhood.z), COMPARE_DEPTH(neighborhood.z, closest.z));
            closest = lerp(closest, float3( 1.0,  1.0, neighborhood.w), COMPARE_DEPTH(neighborhood.w, closest.z));

            return posInputs.positionSS + closest.xy;
        }


        void FragTAA(Varyings input, out float4 outColor : SV_Target0, out float4 outColorHistory : SV_Target1)
        {
            float2 jitter = _TaaJitterStrength.zw;

            #if defined(ORTHOGRAPHIC)
            // Don't dilate in ortho
            float2 closest = input.positionCS.xy;
            #else
            float2 closest = GetClosestFragment(input.positionCS.xy);
            #endif

            float2 motionVector;
            DecodeMotionVector(LOAD_TEXTURE2D_X(_CameraMotionVectorsTexture, closest), motionVector);
            float motionVecLength = length(motionVector);

            float2 uv = input.texcoord - jitter;

            float3 color = Fetch(_InputTexture, uv, 0.0, _ScreenToTargetScale.xy);
            float3 history = Fetch(_InputHistoryTexture, posInputs.positionNDC - motionVector, 0.0, _ScreenToTargetScaleHistory.xy);

            float3 topLeft = Fetch(_InputTexture, uv, -RADIUS, _ScreenToTargetScale.xy);
            float3 bottomRight = Fetch(_InputTexture, uv, RADIUS, _ScreenToTargetScale.xy);

            float3 corners = 4.0 * (topLeft + bottomRight) - 2.0 * color;

            // Sharpen output
            #if SHARPEN
            float3 topRight = Fetch(_InputTexture, uv, float2(RADIUS, -RADIUS), _ScreenToTargetScale.xy);
            float3 bottomLeft = Fetch(_InputTexture, uv, float2(-RADIUS, RADIUS), _ScreenToTargetScale.xy);
            float3 blur = (topLeft + topRight + bottomLeft + bottomRight) * 0.25;
            color += (color - blur) * SHARPEN_STRENGTH;
            #endif
            
            color = clamp(color, 0.0, CLAMP_MAX);

            float3 average = Map((corners + color) / 7.0);

            topLeft = Map(topLeft);
            bottomRight = Map(bottomRight);
            color = Map(color);

            float colorLuma = Luminance(color);
            float averageLuma = Luminance(average);
            float nudge = lerp(4.0, 0.25, saturate(motionVecLength * 100.0)) * abs(averageLuma - colorLuma);

            float3 minimum = min(bottomRight, topLeft) - nudge;
            float3 maximum = max(topLeft, bottomRight) + nudge;

            history = Map(history);

            // Clip history samples
            #if CLIP_AABB
            history = ClipToAABB(history, minimum, maximum);
            #else
            history = clamp(history, minimum, maximum);
            #endif

            // Blend color & history
            // Feedback weight from unbiased luminance diff (Timothy Lottes)
            float historyLuma = Luminance(history);
            float diff = abs(colorLuma - historyLuma) / Max3(colorLuma, historyLuma, 0.2);
            float weight = 1.0 - diff;
            float feedback = lerp(FEEDBACK_MIN, FEEDBACK_MAX, weight * weight);

            color = Unmap(lerp(color, history, feedback));
            color = clamp(color, 0.0, CLAMP_MAX);

            outColor = color;
            outColorHistory = color;
        }
    ENDHLSL

    SubShader
    {
        Tags{ "RenderPipeline" = "HDRenderPipeline" }

        // TAA
        Pass
        {
            ZWrite Off ZTest Off Blend Off Cull Off

            HLSLPROGRAM
                #pragma vertex Vert
                #pragma fragment FragTAA
            ENDHLSL
        }

        // TODO_FCC: Need copy history at all? Why not simple blit?        
    }
    Fallback Off
}
