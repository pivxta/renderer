module mesh;

public static const uint ATTR_POSITION    = 0;
public static const uint ATTR_NORMAL      = 1;
public static const uint ATTR_TANGENT     = 2;
public static const uint ATTR_TEX_COORD_0 = 3;
public static const uint ATTR_TEX_COORD_1 = 4;
public static const uint ATTR_COLOR       = 5;
public static const uint ATTR_JOINTS      = 6;
public static const uint ATTR_WEIGHTS     = 7;
public static const uint ATTR_CUSTOM_0    = 8;
public static const uint ATTR_CUSTOM_1    = 9;
public static const uint ATTR_CUSTOM_2    = 10;
public static const uint ATTR_CUSTOM_3    = 11;
public static const uint ATTR_CUSTOM_4    = 12;
public static const uint ATTR_CUSTOM_5    = 13;
public static const uint ATTR_CUSTOM_6    = 14;
public static const uint ATTR_CUSTOM_7    = 15;

static const uint ENC_F32X1 = 0,  ENC_F32X2 = 1,  ENC_F32X3 = 2,  ENC_F32X4 = 3;
static const uint ENC_F16X2 = 4,  ENC_F16X4 = 5;
static const uint ENC_U32X1 = 6,  ENC_U32X2 = 7,  ENC_U32X3 = 8,  ENC_U32X4 = 9;
static const uint ENC_U16X2 = 10, ENC_U16X4 = 11;
static const uint ENC_U8X4  = 12;
static const uint ENC_SNORM16X2 = 13, ENC_SNORM16X4 = 14;
static const uint ENC_UNORM16X2 = 15, ENC_UNORM16X4 = 16;
static const uint ENC_SNORM8X4  = 17;
static const uint ENC_UNORM8X4  = 18;
static const uint ENC_OCT16     = 19;

static const uint ENCODING_SIZE[20] = {
    4, 8, 12, 16, 4, 8, 4, 8, 12, 16, 4, 8, 4, 4, 8, 4, 8, 4, 4, 4,
};

public struct MeshRecord {
    public uint64_t dataAddress;
    public uint     dataOffsets[16];
    public uint8_t  encodings[16];
    public uint     divisors[16];
    public uint     attributes;
    public uint     vertexCount;
};

public bool MeshHas(MeshRecord* mesh, uint attribute) {
    return ((mesh->attributes >> attribute) & 1) != 0;
}

uint64_t ElementAddress(MeshRecord* mesh, uint vertexID, uint attribute) {
    uint encoding = mesh->encodings[attribute];
    uint element = vertexID / mesh->divisors[attribute];
    return mesh->dataAddress + mesh->dataOffsets[attribute]
         + uint64_t(element) * ENCODING_SIZE[encoding];
}

public float4 MeshLoadFloat(MeshRecord* mesh, uint vertexID, uint attribute, float4 fallback) {
    if (!MeshHas(mesh, attribute)) {
        return fallback;
    }
    return DecodeFloat(mesh->encodings[attribute], ElementAddress(mesh, vertexID, attribute));
}

public uint4 MeshLoadUint(MeshRecord* mesh, uint vertexID, uint attribute) {
    if (!MeshHas(mesh, attribute)) {
        return uint4(0);
    }
    return DecodeUint(mesh->encodings[attribute], ElementAddress(mesh, vertexID, attribute));
}

uint LoadWord(uint64_t address) {
    return *((uint*)address);
}

float Snorm16(uint bits) { 
    return max(float(int(bits << 16) >> 16) / 32767.0, -1.0); 
}

float Unorm16(uint bits) { 
    return float(bits & 0xFFFF) / 65535.0; 
}

float Snorm8(uint w, uint i) { 
    return max(float(int(w << (24 - 8 * i)) >> 24) / 127.0, -1.0); 
}

float Unorm8(uint w, uint i) { 
    return float((w >> (8 * i)) & 0xFF) / 255.0; 
}

float3 OctDecode(float2 e) {
    float3 v = float3(e, 1.0 - abs(e.x) - abs(e.y));
    float t = saturate(-v.z);
    v.x += v.x >= 0.0 ? -t : t;
    v.y += v.y >= 0.0 ? -t : t;
    return normalize(v);
}

float4 DecodeFloat(uint encoding, uint64_t a) {
    uint w0 = LoadWord(a);
    switch (encoding) {
    case ENC_F32X1: return float4(asfloat(w0), 0, 0, 1);
    case ENC_F32X2: return float4(asfloat(w0), asfloat(LoadWord(a + 4)), 0, 1);
    case ENC_F32X3: return float4(asfloat(w0), asfloat(LoadWord(a + 4)), asfloat(LoadWord(a + 8)), 1);
    case ENC_F32X4: return float4(asfloat(w0), asfloat(LoadWord(a + 4)), asfloat(LoadWord(a + 8)), asfloat(LoadWord(a + 12)));
    case ENC_F16X2: return float4(unpackHalf2x16ToFloat(w0), 0, 1);
    case ENC_F16X4: { 
        uint w1 = LoadWord(a + 4);
        return float4(unpackHalf2x16ToFloat(w0), unpackHalf2x16ToFloat(w1)); 
    }
    case ENC_SNORM16X2: return float4(Snorm16(w0), Snorm16(w0 >> 16), 0, 1);
    case ENC_SNORM16X4: { 
        uint w1 = LoadWord(a + 4);
        return float4(Snorm16(w0), Snorm16(w0 >> 16), Snorm16(w1), Snorm16(w1 >> 16)); 
    }
    case ENC_UNORM16X2: return float4(Unorm16(w0), Unorm16(w0 >> 16), 0, 1);
    case ENC_UNORM16X4: { 
        uint w1 = LoadWord(a + 4);
        return float4(Unorm16(w0), Unorm16(w0 >> 16), Unorm16(w1), Unorm16(w1 >> 16)); 
    }
    case ENC_SNORM8X4: return float4(Snorm8(w0, 0), Snorm8(w0, 1), Snorm8(w0, 2), Snorm8(w0, 3));
    case ENC_UNORM8X4: return float4(Unorm8(w0, 0), Unorm8(w0, 1), Unorm8(w0, 2), Unorm8(w0, 3));
    case ENC_OCT16:    return float4(OctDecode(float2(Snorm16(w0), Snorm16(w0 >> 16))), 0);
    default:           return float4(0, 0, 0, 1);
    }
}

uint4 DecodeUint(uint encoding, uint64_t a) {
    uint w0 = LoadWord(a);
    switch (encoding) {
    case ENC_U32X1: return uint4(w0, 0, 0, 0);
    case ENC_U32X2: return uint4(w0, LoadWord(a + 4), 0, 0);
    case ENC_U32X3: return uint4(w0, LoadWord(a + 4), LoadWord(a + 8), 0);
    case ENC_U32X4: return uint4(w0, LoadWord(a + 4), LoadWord(a + 8), LoadWord(a + 12));
    case ENC_U16X2: return uint4(w0 & 0xFFFF, w0 >> 16, 0, 0);
    case ENC_U16X4: { 
        uint w1 = LoadWord(a + 4);
        return uint4(w0 & 0xFFFF, w0 >> 16, w1 & 0xFFFF, w1 >> 16); 
    }
    case ENC_U8X4:  return uint4(w0 & 0xFF, (w0 >> 8) & 0xFF, (w0 >> 16) & 0xFF, w0 >> 24);
    default:        return uint4(0);
    }
}
