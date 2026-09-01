// Metal source for the black hole renderer. Compiled at load time because the
// offline `metal` compiler ships only with full Xcode.

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

constant float RS       = 1.0;    // Schwarzschild radius (units of the sim)
constant float DISK_IN  = 2.6;    // inner edge, just inside the ISCO for a soft plunge
constant float DISK_OUT = 13.0;
constant float ESCAPE   = 70.0;
constant float PERIOD   = 9.0;    // cross-dissolve period for the disk turbulence

struct Uniforms {
    float2 res;
    float  time;
    float  camDist;
    float  incl;
    float  azim;
    float  steps;
    float  exposure;
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VOut vsMain(uint vid [[vertex_id]]) {
    // Fullscreen triangle.
    float2 p[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    VOut o;
    o.pos = float4(p[vid], 0.0, 1.0);
    o.uv  = p[vid];
    return o;
}

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float hash31(float3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

static inline float noise3(float3 x) {
    float3 i = floor(x);
    float3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash31(i + float3(0,0,0));
    float n100 = hash31(i + float3(1,0,0));
    float n010 = hash31(i + float3(0,1,0));
    float n110 = hash31(i + float3(1,1,0));
    float n001 = hash31(i + float3(0,0,1));
    float n101 = hash31(i + float3(1,0,1));
    float n011 = hash31(i + float3(0,1,1));
    float n111 = hash31(i + float3(1,1,1));
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

static inline float fbm(float3 p) {
    float a = 0.5, s = 0.0;
    for (int i = 0; i < 5; i++) { s += a * noise3(p); p *= 2.07; a *= 0.5; }
    return s;
}

static inline float diskTurb(float r, float a, float seed) {
    float3 np = float3(cos(a) * r, sin(a) * r, r * 0.45) * 0.62;
    return fbm(np + float3(seed));
}

// Warm blackbody ramp: cool red at the rim, white hot at the inner edge.
static inline float3 diskColor(float t) {
    float3 c = mix(float3(0.30, 0.045, 0.008), float3(1.0, 0.30, 0.035),
                   smoothstep(0.00, 0.38, t));
    c = mix(c, float3(1.0, 0.72, 0.34), smoothstep(0.34, 0.68, t));
    c = mix(c, float3(1.0, 0.96, 0.90), smoothstep(0.66, 1.0, t));
    return c;
}

static inline float3 starfield(float3 d) {
    float3 col = float3(0.0);
    for (int k = 0; k < 3; k++) {
        float sc = 70.0 * pow(2.3, float(k));
        float3 q = d * sc;
        float3 cell = floor(q);
        float3 f = fract(q);
        float h = hash31(cell + float3(float(k) * 7.13));
        float thresh = 0.960 - 0.012 * float(k);
        if (h > thresh) {
            float3 sp = float3(hash31(cell + 1.7), hash31(cell + 3.3), hash31(cell + 5.9));
            float dist = length(f - sp);
            float b = smoothstep(0.30, 0.0, dist);
            b = pow(b, 7.0);
            float t = fract(h * 91.7);
            float3 tint = mix(float3(0.62, 0.72, 1.0), float3(1.0, 0.84, 0.60), t);
            float mag = 0.5 + 2.6 * fract(h * 311.7);
            col += tint * b * mag / (1.0 + 1.4 * float(k));
        }
    }
    // Very faint dust so the sky is not pure black between stars.
    float n = fbm(d * 2.6 + 11.0);
    col += pow(max(n - 0.56, 0.0), 2.0) * float3(0.16, 0.10, 0.26) * 1.6;
    return col;
}

static inline float3 aces(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

fragment float4 fsMain(VOut vin [[stage_in]], constant Uniforms &U [[buffer(0)]]) {
    float2 uv = vin.uv;
    uv.x *= U.res.x / max(U.res.y, 1.0);

    float ci = cos(U.incl), si = sin(U.incl);
    float ca = cos(U.azim), sa = sin(U.azim);
    float3 camPos = U.camDist * float3(ci * sa, si, ci * ca);

    float3 fwd   = normalize(-camPos);
    float3 right = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    float3 up    = cross(right, fwd);
    float3 rd    = normalize(fwd * 2.1 + right * uv.x + up * uv.y);

    // A photon in Schwarzschild geometry stays in the plane spanned by the
    // camera position and its direction, so integrate u = 1/r against phi in 2D.
    float3 e1 = normalize(camPos);
    float3 tv = rd - dot(rd, e1) * e1;
    float  tl = length(tv);
    float3 e2 = tl > 1e-6 ? tv / tl : normalize(cross(e1, float3(0.0, 1.0, 0.0)));
    tl = max(tl, 1e-6);

    float r0 = length(camPos);
    float u  = 1.0 / r0;
    float du = -dot(rd, e1) / (r0 * tl);

    // Rotate the (cos phi, sin phi) pair incrementally instead of calling trig.
    float dphi = 0.024;
    float cd = cos(dphi), sd = sin(dphi);
    float cp = 1.0, sp = 0.0;

    float3 prevP  = camPos;
    float3 acc    = float3(0.0);
    float  transm = 1.0;
    float3 escDir = rd;
    bool   escaped = false;
    bool   captured = false;

    int steps = int(U.steps);
    for (int i = 0; i < steps; i++) {
        // Midpoint step on u'' = -u + 1.5 * RS * u^2.
        float a1    = -u + 1.5 * RS * u * u;
        float uMid  = u + du * dphi * 0.5;
        float duMid = du + a1 * dphi * 0.5;
        float a2    = -uMid + 1.5 * RS * uMid * uMid;
        u  += duMid * dphi;
        du += a2 * dphi;

        float nc = cp * cd - sp * sd;
        float ns = sp * cd + cp * sd;
        cp = nc; sp = ns;

        if (u * RS >= 1.0) { captured = true; break; }
        if (u <= 1.0 / ESCAPE) { escaped = true; }

        float  r = 1.0 / max(u, 1e-6);
        float3 p = r * (cp * e1 + sp * e2);

        if (prevP.y * p.y < 0.0) {
            float  f   = prevP.y / (prevP.y - p.y);
            float3 hit = mix(prevP, p, f);
            float  hr  = length(hit);
            if (hr > DISK_IN && hr < DISK_OUT) {
                float3 n     = hit / hr;
                float3 pdir  = normalize(hit - prevP);
                float3 vdir  = normalize(cross(float3(0.0, 1.0, 0.0), n));
                float  speed = sqrt(0.5 * RS / hr);              // Keplerian
                float  beta  = dot(vdir * speed, -pdir);
                float  gam   = 1.0 / sqrt(max(1.0 - speed * speed, 1e-4));
                float  dopp  = 1.0 / (gam * (1.0 - beta));       // relativistic beaming
                float  grav  = sqrt(max(1.0 - RS / hr, 0.0));    // gravitational redshift
                float  shift = clamp(dopp * grav, 0.05, 4.0);

                float ang = atan2(hit.z, hit.x);
                // Differential rotation shears the noise into ever-finer rings.
                // Advect two copies and cross-dissolve so the winding stays
                // bounded no matter how long the saver runs.
                float omega = 8.1 * pow(hr, -1.5);
                float ph = U.time / PERIOD;
                float f0 = fract(ph);
                float f1 = fract(ph + 0.5);
                float w  = abs(1.0 - 2.0 * f0);
                float turb = mix(diskTurb(hr, ang - omega * PERIOD * f0, 0.0),
                                 diskTurb(hr, ang - omega * PERIOD * f1, 37.0), w);

                float tN     = saturate((hr - DISK_IN) / (DISK_OUT - DISK_IN));
                float radial = pow(1.0 - tN, 2.3);
                float edgeIn = smoothstep(0.0, 0.10, tN);
                float edgeOut = 1.0 - smoothstep(0.72, 1.0, tN);
                float dens = radial * edgeIn * edgeOut * (0.28 + 1.05 * turb);

                float T = saturate(pow(DISK_IN / hr, 0.75) * 1.12);
                float3 col = diskColor(T) * pow(shift, 3.0);

                acc += transm * col * dens * 2.6;
                transm *= exp(-dens * 0.55);
            }
        }

        if (escaped) { escDir = normalize(p - prevP); break; }
        prevP = p;
    }

    float3 bg = (escaped && !captured) ? starfield(escDir) : float3(0.0);
    float3 color = acc + bg * transm;

    color = aces(color * U.exposure);
    // Dither to kill banding in the dark gradients.
    color += (hash21(vin.pos.xy + fract(U.time) * 91.7) - 0.5) * 0.010;
    return float4(max(color, 0.0), 1.0);
}
"""
