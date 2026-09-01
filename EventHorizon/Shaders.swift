// Metal source for the overlay. Compiled at load time because the offline
// `metal` compiler ships only with full Xcode.

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

constant float RS       = 1.0;        // Schwarzschild radius, sets the unit scale
constant float BC       = 2.598076;   // photon capture impact parameter, 3*sqrt(3)/2
constant float DISK_IN  = 2.6;
constant float DISK_OUT = 8.0;
constant float ESCAPE   = 160.0;
constant float PERIOD   = 6.0;        // cross-dissolve period for the sheared turbulence

struct Uniforms {
    float2 capSize;        // the screen capture texture, in pixels
    float2 winOriginCap;   // our top-left corner in capture pixels
    float2 holeCap;        // black hole centre in capture pixels
    float  hasDesktop;     // 0 when capture is unavailable
    float  pad0;
    float  pxPerUnit;      // capture pixels per world unit at the focal plane
    float  camDist;
    float  planeDist;      // the desktop plane sits this far behind the hole
    float  time;
    float  incl;
    float  roll;
    float  maxSteps;
    float  exposure;
    float  diskGain;
    float  fade;           // global opacity of the whole effect
    float  swirl;          // winds the desktop into the hole
    float  warpReach;      // pixels; distortion decays to nothing beyond this
    float  frontX;         // consumption front, in capture pixels
    float  frontSoft;      // width of the front's gradient, in pixels
    float  mixLeft;        // desktop visibility left of the front (1 = intact)
    float  mixRight;       // desktop visibility right of the front
};

struct VOut {
    float4 pos [[position]];
};

vertex VOut vsMain(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    VOut o;
    o.pos = float4(p[vid], 0.0, 1.0);
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
    for (int i = 0; i < 6; i++) { s += a * noise3(p); p *= 2.07; a *= 0.5; }
    return s;
}

// Sampled in the disk's own rotating frame. `angK` vs `radK` sets how far
// features are stretched along the orbit; `z` is height above the midplane so
// the gas has structure through its thickness, not just across it.
static inline float diskTurb(float r, float a, float z,
                             float angK, float radK, float seed) {
    float3 np = float3(cos(a) * angK, sin(a) * angK, r * radK + z * 2.0);
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

// Shown where the desktop has been consumed, or where a ray misses it entirely.
static inline float3 starfield(float3 d) {
    float3 col = float3(0.0);
    for (int k = 0; k < 3; k++) {
        float sc = 70.0 * pow(2.3, float(k));
        float3 q = d * sc;
        float3 cell = floor(q);
        float3 f = fract(q);
        float h = hash31(cell + float3(float(k) * 7.13));
        if (h > 0.960 - 0.012 * float(k)) {
            float3 sp = float3(hash31(cell + 1.7), hash31(cell + 3.3), hash31(cell + 5.9));
            float b = pow(smoothstep(0.30, 0.0, length(f - sp)), 7.0);
            float t = fract(h * 91.7);
            float3 tint = mix(float3(0.62, 0.72, 1.0), float3(1.0, 0.84, 0.60), t);
            col += tint * b * (0.5 + 2.6 * fract(h * 311.7)) / (1.0 + 1.4 * float(k));
        }
    }
    float n = fbm(d * 2.6 + 11.0);
    col += pow(max(n - 0.54, 0.0), 2.0) * float3(0.10, 0.15, 0.34) * 1.9;
    col += float3(0.010, 0.019, 0.042);          // faint ambient, not flat black
    return col * 0.6;
}

// The desktop texture is sampled raw (already display-encoded), so anything we
// generate has to be encoded to match before it is mixed in.
static inline float3 enc(float3 c) {
    return pow(max(c, 0.0), float3(1.0 / 2.2));
}

static inline float3 aces(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

fragment float4 fsMain(VOut vin [[stage_in]],
                       constant Uniforms &U [[buffer(0)]],
                       texture2d<float> screenTex [[texture(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge, coord::normalized);

    float2 fragPx = vin.pos.xy;                  // top-left origin, pixels
    float2 capPx  = U.winOriginCap + fragPx;

    // How much of the desktop survives here: one side of the hole's trailing
    // front is still desktop, the other has already been eaten.
    float dmix = mix(U.mixLeft, U.mixRight,
                     smoothstep(U.frontX - U.frontSoft, U.frontX, capPx.x));

    // The camera's forward axis meets the screen at its centre, and the hole is
    // positioned by moving the camera sideways rather than by shifting the
    // image. That is what makes it a three dimensional object crossing the
    // screen - the disk turns, foreshortens, and the Doppler-bright side swaps
    // - instead of a rigid picture sliding across.
    float2 centrePx = U.capSize * 0.5;
    float2 uv     = float2(capPx.x - centrePx.x, centrePx.y - capPx.y) / U.pxPerUnit;
    float2 holeUV = float2(U.holeCap.x - centrePx.x, centrePx.y - U.holeCap.y) / U.pxPerUnit;

    // Placing the camera here puts the hole (always at the origin) exactly on
    // holeCap, because the ray toward the origin has uv == holeUV.
    float3 camPos = float3(-holeUV * U.camDist, U.camDist);
    float3 rd     = normalize(float3(uv, -1.0));
    float  planeK = U.camDist + U.planeDist;
    float  camR   = length(camPos);

    // Impact parameter drives the step size: grazing rays need fine steps,
    // far-field rays are almost straight and finish in a handful.
    float b = length(cross(camPos, rd));
    float dphi = clamp(0.018 * pow(max(b, 0.1) / BC, 1.6), 0.018, 0.14);
    // Anything that can reach the disk has to step finely enough to resolve its
    // thickness, or the volume integration bands.
    if (b < DISK_OUT + 1.0) dphi = min(dphi, 0.026);

    float3 e1 = camPos / camR;
    float3 tv = rd - dot(rd, e1) * e1;
    float  tl = length(tv);
    float3 e2 = tl > 1e-6 ? tv / tl : normalize(cross(e1, float3(0.0, 1.0, 0.0)));
    tl = max(tl, 1e-6);

    float u  = 1.0 / camR;
    float du = -dot(rd, e1) / (camR * tl);

    float cd = cos(dphi), sd = sin(dphi);
    float cp = 1.0, sp = 0.0;

    // Disk plane: near edge-on, tilted by incl and rocked slowly by roll.
    float ci = cos(U.incl), si = sin(U.incl);
    float cr = cos(U.roll),  sr = sin(U.roll);
    float3 N  = float3(-ci * sr, ci * cr, si);
    float3 dA = normalize(cross(N, float3(0.0, 0.0, 1.0)));
    float3 dB = cross(N, dA);

    float ph = U.time / PERIOD;
    float pf0 = fract(ph), pf1 = fract(ph + 0.5);
    float pw  = abs(1.0 - 2.0 * pf0);

    float3 prevP  = camPos;
    float3 acc    = float3(0.0);
    float  transm = 1.0;
    bool   hitPlane = false;
    bool   captured = false;
    float2 planeXY  = float2(0.0);
    float3 lastDir  = rd;

    int steps = int(U.maxSteps);
    for (int i = 0; i < steps; i++) {
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

        float  r = 1.0 / max(u, 1e-6);
        float3 p = r * (cp * e1 + sp * e2);
        lastDir = normalize(p - prevP);

        // The disk is a slab with real thickness, integrated along the ray.
        // A thin plane crossing is what made it read as a flat painted ring.
        if (r > DISK_IN && r < DISK_OUT) {
            float hgt = abs(dot(p, N));
            float hh  = 0.06 + 0.032 * r;          // flares outward
            if (hgt < hh) {
                float q    = hgt / hh;
                float vert = exp(-3.0 * q * q);
                float seg  = length(p - prevP);

                float3 nrm   = p / r;
                float3 vdir  = normalize(cross(N, nrm));
                float  speed = sqrt(0.5 * RS / r);
                float  beta  = dot(vdir * speed, -lastDir);
                float  gam   = 1.0 / sqrt(max(1.0 - speed * speed, 1e-4));
                float  dopp  = 1.0 / (gam * (1.0 - beta));
                float  grav  = sqrt(max(1.0 - RS / r, 0.0));
                float  shift = clamp(dopp * grav, 0.05, 4.0);

                float ang = atan2(dot(p, dB), dot(p, dA));
                float z   = dot(p, N);

                // Keplerian shear stretches turbulence into ever-finer rings, so
                // advect two copies and cross-dissolve to bound the winding.
                // Fast enough that the flow is legible as motion.
                float omega = 7.0 * pow(r, -1.5);
                float adv = mix(diskTurb(r, ang - omega * PERIOD * pf0, z, 4.0, 11.0, 0.0),
                                diskTurb(r, ang - omega * PERIOD * pf1, z, 4.0, 11.0, 37.0), pw);
                // Solid-body layer: no shear, so it never closes into rings and
                // keeps the sheared strands broken up.
                float clump = diskTurb(r, ang - U.time * 0.45, z, 6.0, 4.5, 5.0);

                float mixed = 0.62 * adv + 0.38 * clump;
                // Ridged, so the gas resolves into thin bright strands rather
                // than a smooth wash.
                float ridge = pow(saturate(1.0 - abs(2.0 * mixed - 1.0)), 3.0);
                float turb = saturate(smoothstep(0.26, 0.86, mixed) * 0.78 + ridge * 0.40);

                float tN      = saturate((r - DISK_IN) / (DISK_OUT - DISK_IN));
                float radial  = pow(1.0 - tN, 2.0);
                float edgeIn  = smoothstep(0.0, 0.10, tN);
                float edgeOut = 1.0 - smoothstep(0.62, 1.0, tN);
                float arm = 0.5 + 0.5 * cos(ang - 2.2 * log(r) - U.time * 0.5);
                float dens = radial * edgeIn * edgeOut * vert
                           * (0.08 + 1.30 * turb) * (0.72 + 0.52 * arm);

                float T = saturate(pow(DISK_IN / r, 0.75) * 1.12);
                acc += transm * diskColor(T) * pow(shift, 3.0) * dens * seg * U.diskGain;
                transm *= exp(-dens * seg * 0.9);
            }
        }

        if (prevP.z > -U.planeDist && p.z <= -U.planeDist) {
            float f = (prevP.z + U.planeDist) / (prevP.z - p.z);
            planeXY = mix(prevP, p, f).xy;
            hitPlane = true;
            break;
        }
        if (r > ESCAPE) break;
        prevP = p;
    }

    float2 srcCapPx = capPx;
    float  onScreen = 0.0;
    if (hitPlane && !captured) {
        // Undeflected this is exactly uv again, so the far field reproduces the
        // screen pixel for pixel.
        float2 srcUV = (planeXY - camPos.xy) / planeK;
        // Wind the sampled desktop around the hole so content visibly spirals in.
        if (U.swirl > 0.0001) {
            float2 rel = srcUV - holeUV;
            float rr = length(rel);
            float a  = U.swirl / (rr + 0.35);
            float ca = cos(a), sa = sin(a);
            srcUV = holeUV + float2(rel.x * ca - rel.y * sa, rel.x * sa + rel.y * ca);
        }
        srcCapPx = centrePx + float2(srcUV.x, -srcUV.y) * U.pxPerUnit;

        // Confine the warp to a neighbourhood of the hole. Lensing falls off as
        // 1/b, which would visibly displace the whole screen; this decays it to
        // nothing by warpReach so everything else stays untouched and live.
        float rpx   = distance(capPx, U.holeCap);
        float t     = rpx / max(U.warpReach, 1.0);
        float taper = exp(-2.6 * t * t * t);
        srcCapPx = capPx + (srcCapPx - capPx) * taper;

        float2 tc = srcCapPx / U.capSize;
        onScreen = smoothstep(0.0, 0.004, tc.x) * smoothstep(0.0, 0.004, tc.y)
                 * (1.0 - smoothstep(0.996, 1.0, tc.x)) * (1.0 - smoothstep(0.996, 1.0, tc.y));
    }

    float3 bg = float3(0.0);
    if (!captured) {
        float3 sky = enc(starfield(lastDir));
        float3 desktop = screenTex.sample(smp, srcCapPx / U.capSize).rgb;
        bg = mix(sky, desktop, onScreen * dmix);
    }

    float3 emit = enc(aces(acc * U.exposure));
    float3 col  = bg * transm + emit;

    // Only claim the pixels we actually change. Everywhere else stays fully
    // transparent so the live screen shows through instead of our copy of it.
    float defl = distance(srcCapPx, capPx);
    float a = (captured || !hitPlane) ? 1.0 : smoothstep(0.5, 3.0, defl);
    a = max(a, saturate(dot(emit, float3(0.299, 0.587, 0.114)) * 4.0));
    // Consumed regions are ours entirely - but only if there is a desktop to
    // consume. Without capture this would blank the screen instead of showing
    // the hole over it.
    a = max(a, (1.0 - dmix) * U.hasDesktop);
    a = saturate(a) * U.fade;

    col += (hash21(fragPx + fract(U.time) * 91.7) - 0.5) * 0.006;
    return float4(max(col, 0.0) * a, a);   // premultiplied
}
"""
