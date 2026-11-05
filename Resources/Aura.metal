// The light. Compiled at launch by the Metal driver, so building the app needs no Metal toolchain.
#include <metal_stdlib>
using namespace metal;

// Mirrors AuraUniforms in Aura.swift. All float4, so the two layouts can't drift apart.
struct Uniforms {
    float4 size;        // width, height, pixels per point, 1 over dark
    float4 notch;       // half width, height, radius, openness
    float4 flow;        // phase, energy, sweep, breath
    float4 comet;       // strength, head on the perimeter, arc strength, arc progress
    float4 blob;        // x, y, radius, strength
    float4 lean;        // x, y, narrowness, top fade
    float4 pulse;       // envelope, ring (negative for none), bloom, spectrum
    float4 pulseColor;
    float4 palette[5];
};

vertex float4 auraVertex(uint id [[vertex_id]]) {
    float2 corner = float2((id << 1) & 2, id & 2);
    return float4(corner * 2 - 1, 0, 1);
}

static inline float3 toLinear(float3 c) { return pow(c, 2.2); }

// Display P3 shares the sRGB transfer curve. Its linear toe keeps the tails from lifting.
static inline float3 encode(float3 c) {
    c = saturate(c);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, 12.92 * c, c <= 0.0031308);
}

static inline float maxOf(float3 c) { return max(c.r, max(c.g, c.b)); }

// Colour stays creamy because five moving lights in a warped domain are normalised, not summed:
// they trade hue where they meet instead of adding up to white. `density` is how much of them
// is really there, for the brightness to breathe with.
static float3 flowColor(float2 q, float t, constant float4 *palette, thread float &density) {
    // Kept weak enough never to fold over itself, which would draw a crease through the colour.
    q += 0.42 * float2(sin(q.y * 1.3 + t * 0.71), cos(q.x * 1.1 - t * 0.53));
    q += 0.13 * float2(sin(q.y * 2.6 - t * 0.93 + 1.7), cos(q.x * 2.3 + t * 0.61 + 0.4));
    float3 sum = 0;
    float total = 0.0001;
    for (int i = 0; i < 5; i++) {
        float n = float(i);
        float2 centre = float2(sin(t * (0.31 + 0.07 * n) + n * 2.4), cos(t * (0.27 + 0.05 * n) + n * 1.7)) * 1.15;
        float2 e = q - centre;
        // Inverse-square, not gaussian: a ratio of gaussians turns into a hard border far from the centres.
        float weight = 1.0 / (0.75 + dot(e, e));
        weight *= weight;
        sum += palette[i].rgb * weight;
        total += weight;
    }
    density = saturate(total * 0.4);
    float3 colour = sum / total;
    // Mixing opposite hues greys them, so give back what the mix took.
    colour = saturate(mix(float3(dot(colour, float3(0.3, 0.59, 0.11))), colour, 1.4));
    // Every hue peaks at 1. Holding the mix there too stops dark, muddy seams between them.
    return toLinear(colour / max(maxOf(colour), 0.001));
}

// How far the glow reaches at each point along the perimeter, so it licks rather than rings.
static inline float tongues(float u, float t) {
    return 1.0 + 0.36 * sin(u * 0.029 + t * 0.9) + 0.25 * sin(u * 0.061 - t * 1.3 + 1.2) + 0.14 * sin(u * 0.113 + t * 1.9 + 4.0);
}

static inline float smoothMin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1 - h);
}

static inline float gaussian(float x) { return exp(-x * x); }

// Blue-noise-like, so a 1/255 nudge hides the steps in a soft gradient.
static inline float gradientNoise(float2 p) {
    return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715)))) - 0.5;
}

fragment float4 auraFragment(float4 position [[position]], constant Uniforms &u [[buffer(0)]]) {
    float2 size = u.size.xy;
    float pixel = u.size.z;
    float2 p = position.xy / pixel;
    float onDark = u.size.w;
    float t = u.flow.x;
    float energy = u.flow.y;
    float breath = u.flow.w;
    float envelope = u.pulse.x;
    float bloom = u.pulse.z;
    float3 pulseColor = toLinear(u.pulseColor.rgb) * u.pulseColor.a;

    float3 outside = 0;     // light over whatever is behind the view
    float3 inside = 0;      // light on the black body
    float cover = 0;        // how much of this pixel the body fills

    float open = u.notch.w;
    if (u.notch.y > 0.01) {
        float halfWidth = u.notch.x, height = u.notch.y, radius = u.notch.z;
        float2 folded = float2(abs(p.x - size.x * 0.5), p.y);
        float2 q = folded - float2(halfWidth - radius, height - radius);
        float box = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;

        // The top line sits just above the view, or the fill would leave a hairline along it.
        float fillet = min(20.0, height * 0.7);
        float fill = smoothMin(box, p.y + 1.5, fillet);
        cover = saturate(0.5 - fill * pixel);

        // Distance along the edge, from the bottom centre out and up each side.
        float straight = halfWidth - radius;
        float corner = radius * M_PI_2_F;
        float side = height - radius;
        float along;
        if (q.x > 0 && q.y > 0) along = straight + atan2(q.x, q.y) * radius;
        else if (q.y > 0) along = folded.x;
        else if (q.x > 0) along = straight + corner - q.y;
        else {
            // Deep inside there's no nearest edge, so ease between them instead of leaving a seam.
            float soft = min(-max(q.x, q.y) * 3.0, 70.0) + 0.001;
            along = mix(folded.x, straight + corner - q.y, smoothstep(-soft, soft, q.x - q.y));
        }
        float perimeter = straight + corner + side;
        float signedAlong = (p.x < size.x * 0.5 ? -along : along);
        float s = signedAlong / perimeter;

        float density;
        float distance = max(box, 0.0);

        // Stirring the coordinates with distance turns radial stripes into soft tongues.
        float stir = saturate(distance / 36.0);
        float wander = stir * (26.0 * sin(p.x * 0.019 + p.y * 0.014 + t * 0.6) + 15.0 * sin(p.y * 0.033 - p.x * 0.023 - t * 0.43 + 2.1));
        float wavy = stir * (6.0 * sin(p.x * 0.026 - p.y * 0.017 + t * 0.51) + 4.0 * sin(p.x * 0.051 + p.y * 0.04 - t * 0.77 + 1.0));
        float flowAlong = signedAlong + wander;
        float reachDistance = max(distance + wavy, 0.0);

        float3 colour = flowColor(float2(flowAlong / perimeter * 1.8 + 0.5 * sin(t * 0.3), distance / 170.0 - t * 0.12), t, u.palette, density);

        float sweep = exp(-pow(s / mix(0.32, 3.0, u.flow.z), 2.0));
        float reach = tongues(flowAlong, t) * (1 + bloom * 0.9);
        float reachFar = (0.74 + 0.26 * tongues(flowAlong * 0.6 + 40.0, t * 0.7)) * (1 + bloom * 1.3);

        float ripple = 0;
        if (u.pulse.y >= 0) {
            float offset = (distance + wavy * 0.45 - u.pulse.y * 118.0) / (7.0 + u.pulse.y * 20.0);
            ripple = gaussian(offset) * envelope;
            reachDistance = max(reachDistance - ripple * 6.0, 0.0);     // the ring carries the glow out with it
        }

        // Hugs the edge: gamma lifts a long tail into a wash over the whole desktop.
        float near = exp(-reachDistance / (6.5 * reach));
        float far = exp(-reachDistance / (15.0 * reachFar)) * smoothstep(84.0 * (1 + bloom), 18.0, reachDistance);
        float glow = (near * 1.05 + far * 0.36) * (0.72 + 0.5 * density) * sweep;
        float rimGlow = (0.8 + 0.4 * reach) * (0.7 + 0.5 * density) * sweep;
        // A smooth minimum, because a box's true inner distance mitres at the corners.
        float depth = max(smoothMin(halfWidth - folded.x, height - p.y, 34.0) + 6.0, 0.0);

        float lit = 1;
        float spark = 0;
        if (u.comet.z > 0.001) {
            float unit = 0.5 + (signedAlong + wander * 0.5) / perimeter * 0.5;
            float soft = (5.0 + distance * 2.4 + depth * 1.6) / (2.0 * perimeter);   // the cut softens away from the edge
            float filled = smoothstep(u.comet.w + soft, u.comet.w - soft, unit);
            lit = mix(1.0, 0.1 + 1.25 * filled, u.comet.z);
            spark = u.comet.z * exp(-abs(unit - u.comet.w) * perimeter * 0.14) * (u.comet.w > 0.001 ? 1.0 : 0.0);
        }

        float shine = energy * (1 + breath * 0.35) * (1 + envelope * 0.6 + bloom * 1.2);
        float3 tint = u.pulse.w > 0 ? mix(float3(1), colour * 2.2, u.pulse.w) : float3(1);
        float flash = envelope * (near * 0.9 + far * 0.32) * (1 - bloom * 0.5);
        outside += colour * glow * lit * shine;
        float3 wave = mix(float3(1), colour * 2.0, 0.45);   // a ring of pure white reads as grey once it dims
        outside += pulseColor * tint * (flash + ripple * 0.3 * (0.7 + 0.3 * reachFar) * wave);
        outside += colour * spark * exp(-distance / 7.0) * 2.2;

        float edgeFade = smoothstep(1.0, 16.0, p.y);
        float rim = exp(fill / 1.1) * rimGlow * edgeFade;
        float sheen = exp(-depth / 13.0) * 0.26 * rimGlow * edgeFade;
        float hairline = exp(fill / 4.5) * 0.5 * edgeFade;   // for what moves along the edge: deep inside, there's no "along"
        inside += colour * (rim * 1.7 + sheen) * lit * shine;
        inside += pulseColor * tint * rim * envelope * 2.0;
        inside += colour * spark * (rim * 3.0 + hairline * 2.0);

        if (u.comet.x > 0.001) {
            // Measured along the stirred edge, and blurring with distance, so the head has no hard front.
            float behind = u.comet.y * perimeter - signedAlong - wander * 0.7;
            float blur = 8.0 + distance * 1.3;
            float tail = behind > 0 ? exp(-behind / 120.0) : exp(behind / blur);
            float head = behind > 0 ? exp(-behind / (24.0 + distance)) : exp(behind / blur);
            float3 icy = float3(0.16, 0.38, 1.0);
            float reachOut = exp(-reachDistance / 6.5) * 1.5 + exp(-reachDistance / 14.0) * 0.4 * smoothstep(84.0, 18.0, reachDistance);
            outside += u.comet.x * (icy * tail * reachOut + float3(0.5, 0.7, 1.0) * head * exp(-reachDistance / 7.0) * 1.3);
            inside += u.comet.x * (icy * tail * (rim * 2.2 + hairline * 1.6) + float3(0.8, 0.88, 1.0) * head * rim * 2.2);
        }

        outside *= open;
        inside *= open;
    }

    float shadow = 0;
    float strength = u.blob.w;
    if (strength > 0.001) {
        float radius = u.blob.z * (1 + breath * 0.09 + bloom * 0.3);
        float2 drift = 0.07 * float2(sin(t * 0.37), cos(t * 0.29)) + 0.05 * float2(sin(t * 0.71 + 1.3), cos(t * 0.53 + 0.7));
        float2 centre = u.blob.xy + radius * (drift + u.lean.xy * 0.2);
        float2 v = (p - centre) / radius;
        v.x *= 1 + u.lean.z * 0.5;
        v -= u.lean.xy * dot(v, u.lean.xy) * 0.14;      // leaning stretches it toward where it's aimed

        float2 warped = v + 0.15 * float2(sin(v.y * 2.3 + t * 0.6), cos(v.x * 1.9 - t * 0.5));
        warped += 0.06 * float2(sin(warped.y * 5.1 - t * 0.8 + 2.0), cos(warped.x * 4.3 + t * 0.7));
        float r2 = dot(warped, warped);

        float density;
        float3 colour = flowColor(warped * 1.75 + u.lean.xy * 0.35, t * 0.8, u.palette, density);
        float core = exp(-r2 * 2.7);
        float halo = exp(-sqrt(r2) * 3.0);
        float shine = strength * energy * (1 + breath * 0.3) * (1 + bloom * 1.1);
        float3 blob = colour * (core * 1.5 * (0.75 + 0.35 * density) + halo * 0.38) * shine;
        blob += mix(colour, float3(1), 0.45) * exp(-r2 * 9.0) * 0.45 * shine;

        // The anamorphic streak: a hairline and a wider haze, both far wider than they are tall.
        float dy = p.y - centre.y - u.lean.y * 4.0;
        float dx = (p.x - centre.x - u.lean.x * radius * 0.35) / (radius * 1.5);
        float span = exp(-dx * dx * 1.6) * (0.85 + 0.15 * sin(t * 1.3 + dx * 3.0));
        float streak = (gaussian(dy / 1.15) * 0.9 + gaussian(dy / 6.5) * 0.14) * span;
        blob += mix(colour, float3(0.62, 0.8, 1.0), 0.6) * streak * shine * (0.8 + 0.2 * onDark);

        if (envelope > 0.001) {
            float3 tint = pulseColor * (u.pulse.w > 0 ? mix(float3(1), colour * 2.2, u.pulse.w) : float3(1));
            blob += tint * envelope * (core * 0.4 + exp(-r2 * 7.0) * 0.8) * strength;
            if (u.pulse.y >= 0 && u.notch.y < 0.01) {
                float ring = gaussian((sqrt(r2) - 0.3 - u.pulse.y * 1.15) / (0.1 + u.pulse.y * 0.22));
                blob += tint * mix(float3(1), colour * 2.0, 0.45) * ring * envelope * 0.32 * strength;
            }
        }

        // Over the notch the blob stays on the black, and only the edge reaches the desktop.
        if (u.notch.y < 0.01) outside += blob;
        inside += blob;

        float2 contact = (p - float2(centre.x, u.blob.y + u.blob.z * 0.66)) / float2(u.blob.z * 0.56, u.blob.z * 0.1);
        shadow = (1 - onDark) * 0.13 * exp(-dot(contact, contact)) * strength;
    }

    // Nothing reaches the view's bounds. Over the notch the top edge is the screen's, so it may.
    float fade;
    if (u.lean.w > 0.5) {
        // A box reaching up past the screen, with corners round enough not to read as a box.
        float2 corner = abs(p - float2(size.x * 0.5, 0)) - float2(size.x * 0.5, size.y) + 100.0;
        fade = smoothstep(0.0, 1.0, saturate(1 - length(max(corner, 0.0)) / 100.0));
    } else {
        // Round, so that a blob too big for its view doesn't take on the view's shape.
        fade = smoothstep(1.0, 0.5, length((p - size * 0.5) / (size * 0.5)));
    }
    outside *= fade * fade;
    inside *= fade * fade;
    shadow *= fade;

    float3 rgb = 0;
    float alpha = 0;
    if (onDark > 0) {
        float3 mapped = encode(1 - exp(-outside * 1.15));
        rgb = mapped * onDark;
        alpha = 0.6 * dot(mapped, float3(0.3, 0.59, 0.11)) * onDark;
    }
    if (onDark < 1) {
        // Keep the hue at full chroma and let alpha carry the falloff, or pale tints go grey.
        float peak = maxOf(outside);
        float3 hue = encode(outside / max(peak, 0.0001));
        hue = mix(hue, float3(1), 0.1 + 0.3 * smoothstep(1.2, 3.0, peak));
        float tinted = (1 - exp(-pow(peak, 0.62) * 2.3)) * 0.9;
        rgb += hue * tinted * (1 - onDark);
        alpha += tinted * (1 - onDark);
    }
    // The shadow sits under the light, in a violet ink, not black.
    float under = shadow * (1 - alpha);
    rgb += float3(0.13, 0.11, 0.26) * under;
    alpha += under;

    if (cover > 0) {
        float3 body = encode(1 - exp(-inside * 1.15));
        rgb = mix(rgb, body, cover);
        alpha = mix(alpha, 1.0, cover);
    }

    // Dither, and only where there's light: clamped noise elsewhere would show the view's box.
    float noise = gradientNoise(position.xy) * 1.5 / 255.0 * saturate(alpha * 180.0);
    return float4(max(rgb + noise, 0.0), saturate(alpha + noise));
}
