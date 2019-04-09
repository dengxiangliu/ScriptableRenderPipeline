#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonLighting.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/VolumeRendering.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Sky/PbrSky/PbrSkyRenderer.cs.hlsl"

CBUFFER_START(UnityPbrSky)
    // All the distance-related entries use km and 1/km units.
    float  _PlanetaryRadius;
    float  _RcpPlanetaryRadius;
    float  _AtmosphericDepth;
    float  _RcpAtmosphericDepth;

    float  _PlanetaryRadiusSquared;
    float  _AtmosphericRadiusSquared;
    float  _AerosolAnisotropy;
    float  _AerosolPhasePartConstant;

    float  _AirDensityFalloff;
    float  _AirScaleHeight;
    float  _AerosolDensityFalloff;
    float  _AerosolScaleHeight;

    float3 _AirSeaLevelExtinction;
    float  _AerosolSeaLevelExtinction;

    float3 _AirSeaLevelScattering;
    float  _AerosolSeaLevelScattering;

    float3 _GroundAlbedo;

    float3 _PlanetCenterPosition;

    float3 _SunRadiance;  // TODO: isn't that just a global multiplier?
CBUFFER_END

TEXTURE2D(_OpticalDepthTexture);
TEXTURE2D(_GroundIrradianceTexture);
TEXTURE3D(_InScatteredRadianceTexture); // Emulate a 4D texture with a "deep" 3D texture

#ifndef UNITY_SHADER_VARIABLES_INCLUDED
    SAMPLER(s_linear_clamp_sampler);
#endif

float3 AirScatter(float LdotV, float height)
{
    float3 kS = _AirSeaLevelScattering * exp(-height * _AirDensityFalloff);

    return kS * RayleighPhaseFunction(-LdotV);
}

float AerosolScatter(float LdotV, float height)
{
    float kS = _AerosolSeaLevelScattering * exp(-height * _AerosolDensityFalloff);

    return kS * _AerosolPhasePartConstant * CornetteShanksPhasePartVarying(_AerosolAnisotropy, -LdotV);
}

float3 AtmosphereScatter(float LdotV, float height)
{
    return AirScatter(LdotV, height) + AerosolScatter(LdotV, height);
}

// Returns a negative number if there's no intersection.
float IntersectAtmosphereFromOutside(float cosChi, float height)
{
    float R = _PlanetaryRadius;
    float h = height;
    float r = R + h;

    // r_o = float2(0, r)
    // r_d = float2(sinChi, cosChi)
    // p_s = r_o + t * r_d
    //
    // (R + H)^2 = dot(r_o + t * r_d, r_o + t * r_d)
    // (R + H)^2 = ((r_o + t * r_d).x)^2 + ((r_o + t * r_d).y)^2
    // (R + H)^2 = t^2 + 2 * dot(r_o, r_d) + dot(r_o, r_o)
    //
    // t^2 + 2 * dot(r_o, r_d) + dot(r_o, r_o) - (R + H)^2 = 0
    //
    // Solve: t^2 + (2 * b) * t + c = 0.
    //
    // t = (-2 * b + sqrt((2 * b)^2 - 4 * c)) / 2
    // t = -b + sqrt(b^2 - c)
    // t = -b + sqrt(d)

    float b = r * cosChi;
    float c = r * r - _AtmosphericRadiusSquared;
    float d = b * b - c;

    // We are only interested in the smallest root (closest intersection).
    return (d >= 0) ? (-b - sqrt(d)) : d;
}

// Assumes there is an intersection.
float IntersectPlanetFromOutside(float cosChi, float height)
{
    float R = _PlanetaryRadius;
    float h = height;
    float r = R + h;

    float b = r * cosChi;
    float c = r * r - _PlanetaryRadiusSquared;
    float d = b * b - c;

    // We are only interested in the smallest root (closest intersection).
    return -b - sqrt(abs(d)); // Prevent NaNs
}

float MapQuadraticHeight(float height)
{
    // TODO: we should adjust sub-texel coordinates
    // to account for the non-linear height distribution.
    return sqrt(height * _RcpAtmosphericDepth);
}

// Returns the height.
float UnmapQuadraticHeight(float v)
{
    return (v * v) * _AtmosphericDepth;
}

float GetCosineOfHorizonZenithAngle(float height)
{
    float R = _PlanetaryRadius;
    float h = height;
    float r = R + h;

    // cos(Pi - x) = -cos(x).
    // Compute -sqrt(r^2 - R^2) / r = -sqrt(1 - (R / r)^2).
    return -sqrt(saturate(1 - Sq(R * rcp(r))));
}

// We use the parametrization from "Outdoor Light Scattering Sample Update" by E. Yusov.
float3 MapAerialPerspective(float cosChi, float height)
{
    float cosHor = GetCosineOfHorizonZenithAngle(height);

    // Above horizon?
    float s = FastSign(cosChi - cosHor);

    // Map: cosHor -> 0, 1 -> +/- 1.
    // The pow(u, 0.2) will allocate most samples near the horizon.
    float u = pow(saturate((cosHor - cosChi) * rcp(cosHor - s)), 0.2);
    float v = MapQuadraticHeight(height);

    // Make the mapping discontinuous along the horizon to avoid interpolation artifacts.
    // We'll use an array texture for this.
    float w = max(s, 0); // 0 or 1

    return float3(u, v, w);
}

// returns {cosChi, height}.
float2 UnmapAerialPerspective(float3 uvw)
{
    float height = UnmapQuadraticHeight(uvw.y);
    float cosHor = GetCosineOfHorizonZenithAngle(height);

    // Above horizon?
    float s = uvw.z * 2 - 1;

    float uPow5  = uvw.x  * (uvw.x * uvw.x) * (uvw.x * uvw.x);
    float cosChi = uPow5 * (s - cosHor) + cosHor;

    return float2(cosChi, height);
}

float3 SampleTransmittanceTexture(float cosChi, float height, bool belowHorizon)
{
    // TODO: pass the sign? Do not recompute?
    float s = belowHorizon ? -1 : 1;

    // From the current position to the atmospheric boundary.
    float2 uv       = MapAerialPerspective(s * cosChi, height).xy;
    float2 optDepth = SAMPLE_TEXTURE2D_LOD(_OpticalDepthTexture, s_linear_clamp_sampler, uv, 0).xy;

    if (belowHorizon)
    {
        // Direction points below the horizon.
        // What we want to know is transmittance from the ground level to our current position.
        // Therefore, first, we must flip the direction and perform the look-up from the ground.
        // The direction must be parametrized w.r.t. the normal of the intersection point.
        // This value corresponds to transmittance from the ground level to the atmospheric boundary.
        // If we perform a look-up from the current position (using the reversed direction),
        // we can compute transmittance from the current position to the atmospheric boundary.
        // Taking the difference will give us the desired value.

        float rcpR = _RcpPlanetaryRadius;
        float h    = height;

        // r / R = (R + h) / R = 1 + h / R.
        float x = 1 + h * rcpR;

        // Using the Law of Sines (and remembering that the angle is obtuse),
        // sin(Pi - gamma) = c / b * sin(beta),
        // sin(Pi - gamma) = r / R * sin(Pi - chi),
        // sin(Pi - gamma) = r / R * sqrt(1 - cos(chi)^2),
        // cos(Pi - gamma) = sqrt(1 - sin(Pi - gamma)^2).
        float cosPhi = sqrt(saturate(1 - Sq(x * sqrt(saturate(1 - Sq(cosChi))))));

        // From the ground level to the atmospheric boundary -
        // from the current position to the atmospheric boundary.
        uv       = MapAerialPerspective(cosPhi, 0).xy;
        optDepth = SAMPLE_TEXTURE2D_LOD(_OpticalDepthTexture, s_linear_clamp_sampler, uv, 0).xy
                 - optDepth;
    }

    // Compose the optical depth with extinction at the sea level.
    return TransmittanceFromOpticalDepth(optDepth.x * _AirSeaLevelExtinction +
                                         optDepth.y * _AerosolSeaLevelExtinction);
}

float3 SampleTransmittanceTexture(float cosChi, float height)
{
    bool belowHorizon = MapAerialPerspective(cosChi, height).z == 0;

    return SampleTransmittanceTexture(cosChi, height, belowHorizon);
}

// Map: [-0.1975, 1] -> [0, 1].
float MapCosineOfZenithAngle(float NdotL)
{
    // Clamp to around 101 degrees. Seems arbitrary?
    float x = max(NdotL, -0.1975);
    return 0.5 * (atan(x) * rcp(1.1) + (1 - 0.26));
}

// Map: [0, 1] -> [-0.1975, 1].
float UnmapCosineOfZenithAngle(float u)
{
    return -0.186929 * tan(0.814 - 2.2 * u);
}

float3 SampleGroundIrradianceTexture(float NdotL)
{
    float2 uv = float2(MapCosineOfZenithAngle(NdotL), 0);

    return SAMPLE_TEXTURE2D_LOD(_GroundIrradianceTexture, s_linear_clamp_sampler, uv, 0).rgb;
}
