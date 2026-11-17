#include "Precomp.h"
#include "Engine.h"
#include "Packages/Engine/UDXEngineClient.h"
#include "Packages/Engine/Subsystems/UDXEngineRenderDevice.h"
#include <array>
#include "RenderDevice/RenderDevice.h"
#include "RenderDevice/OpenGL/GLTextureUploader.h"
#include "Packages/Engine/Resources/Level/UModel.h"
#include <dxwidgets/core/widget.h>
#include <dxwidgets/window/cocoanativehandle.h>
#import "../../../DXWidgets/src/window/cocoa/AppKitWrapper.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <dispatch/dispatch.h>
#include <objc/runtime.h>
#include <unordered_map>
#include <vector>
#include <stdexcept>

extern "C" {
void* objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void* context);
}

namespace {
struct Vertex { vec4 position,color; vec2 uv,lm,detail,macro; vec4 fog; float clipDistance,pad0,pad1,pad2; };
struct DrawFlags { uint32_t poly, textures; };
static_assert(sizeof(Vertex)==96);

int TextureBaseMip(const TextureInfo& info, const UDXEngineClient& client)
{
    if (!info.Texture || info.NumMips <= 1) return 0;
    const auto lod = info.Texture->LODSet();
    const NameString quality = lod == 1 ? client.TextureDetail : lod == 2 ? client.SkinDetail : "High";
    const int level = quality == "Low" ? (lod == 2 ? 1 : 2) : quality == "Medium" ? 1 : 0;
    return std::min(level, info.NumMips - 1);
}
// Each slot is reused only after its command buffer has finished reading it.
struct FrameVertices {
    std::vector<id<MTLBuffer>> chunks;
    size_t chunk=0, offset=0;
    void reset() {
        chunk=offset=0;
    }
    std::pair<id<MTLBuffer>,size_t> reserve(id<MTLDevice> device,size_t bytes) {
        if (!bytes || bytes>device.maxBufferLength-15) throw std::runtime_error("Metal: invalid vertex buffer size");
        if (chunk<chunks.size() && bytes>chunks[chunk].length-offset) { ++chunk; offset=0; }
        if (chunk==chunks.size()) chunks.push_back(nil);
        if (!chunks[chunk] || chunks[chunk].length<bytes) {
            chunks[chunk]=[device newBufferWithLength:std::max((bytes+15)&~size_t(15),size_t(1024*1024)) options:MTLResourceStorageModeShared];
            if (!chunks[chunk]) throw std::runtime_error("Metal: vertex allocation failed");
        }
        size_t start=offset;
        offset=(start+bytes+15)&~size_t(15);
        return {chunks[chunk],start};
    }
};

static thread_local std::vector<uint8_t> g_uploadScratchBuffer;

void UploadMetalMipLevel(id<MTLTexture> texture, GLTextureUploader* uploader, const TextureInfo& info, int mipIndex, int level, size_t pixelSize, size_t inputSize, bool masked)
{
    auto& mip = info.Mips[mipIndex];
    if (mip.Width <= 0 || mip.Height <= 0) return;
    size_t needed = size_t(mip.Width) * mip.Height * pixelSize;
    if (g_uploadScratchBuffer.size() < needed) {
        g_uploadScratchBuffer.resize(needed);
    }
    uploader->UploadRect(g_uploadScratchBuffer.data(), &mip, 0, 0, mip.Width, mip.Height, info.Palette, masked);
    [texture replaceRegion:MTLRegionMake2D(0, 0, mip.Width, mip.Height)
               mipmapLevel:level
                 withBytes:g_uploadScratchBuffer.data()
               bytesPerRow:size_t(mip.Width) * pixelSize];
}

void UpdateMetalTextureRect(id<MTLTexture> texture, const TextureInfo& info, int baseMip, int x, int y, int w, int h, bool masked)
{
    if (!texture || !info.Mips || baseMip >= info.NumMips || baseMip < 0) return;
    auto uploader = GLTextureUploader::GetUploader(info.Format);
    if (!uploader) return;
    auto& base = info.Mips[baseMip];
    if (x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > base.Width || y + h > base.Height) return;
    const size_t pixelSize = info.Format == TextureFormat::RGBA32_F ? 16 : 4;
    size_t needed = size_t(w) * h * pixelSize;
    if (g_uploadScratchBuffer.size() < needed) {
        g_uploadScratchBuffer.resize(needed);
    }
    uploader->UploadRect(g_uploadScratchBuffer.data(), &base, x, y, w, h, info.Palette, masked);
    [texture replaceRegion:MTLRegionMake2D(x, y, w, h)
               mipmapLevel:0
                 withBytes:g_uploadScratchBuffer.data()
               bytesPerRow:size_t(w) * pixelSize];
}

id<MTLTexture> UploadOrUpdateMetalTexture(id<MTLDevice> device, id<MTLTexture> existing, const TextureInfo& info, int baseMip, bool masked)
{
    if (!info.Mips || baseMip < 0 || baseMip >= info.NumMips) throw std::runtime_error("Metal: invalid mip level");
    auto uploader = GLTextureUploader::GetUploader(info.Format);
    if (!uploader || (uploader->GetInternalformat() != GL_RGBA8 && uploader->GetInternalformat() != GL_RGBA32F))
        throw std::runtime_error("Metal: unsupported texture format " + std::to_string(uint32_t(info.Format)));
    auto& base = info.Mips[baseMip];
    if (base.Width <= 0 || base.Height <= 0 || base.Width > 16384 || base.Height > 16384)
        throw std::runtime_error("Metal: invalid texture dimensions");
    int levels = 1;
    for (int size = std::max(base.Width, base.Height); size > 1 && levels < info.NumMips - baseMip; size /= 2) ++levels;
    const size_t pixelSize = info.Format == TextureFormat::RGBA32_F ? 16 : 4;
    const size_t inputSize = info.Format == TextureFormat::P8 ? 1 : info.Format == TextureFormat::RGB8 ? 3 : pixelSize;
    const auto format = info.Format == TextureFormat::BGRA8 ? MTLPixelFormatBGRA8Unorm : info.Format == TextureFormat::RGBA32_F ? MTLPixelFormatRGBA32Float : MTLPixelFormatRGBA8Unorm;

    id<MTLTexture> result = existing;
    if (!result || result.width != (NSUInteger)base.Width || result.height != (NSUInteger)base.Height || result.pixelFormat != format || result.mipmapLevelCount != (NSUInteger)levels) {
        auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:base.Width height:base.Height mipmapped:levels > 1];
        desc.mipmapLevelCount = levels; desc.storageMode = MTLStorageModeShared; desc.usage = MTLTextureUsageShaderRead;
        result = [device newTextureWithDescriptor:desc];
        if (!result) throw std::runtime_error("Metal: texture allocation failed");
    }

    for (int level = 0; level < levels; ++level) {
        auto& mip = info.Mips[baseMip + level];
        if (mip.Width != std::max(base.Width >> level, 1) || mip.Height != std::max(base.Height >> level, 1))
            throw std::runtime_error("Metal: inconsistent mip dimensions");
        const size_t expectedBytes = info.Format == TextureFormat::BC1
            ? size_t((mip.Width + 3) / 4) * ((mip.Height + 3) / 4) * 8
            : size_t(mip.Width) * mip.Height * inputSize;
        if (mip.Data.size() < expectedBytes || (info.Format == TextureFormat::P8 && !info.Palette))
            throw std::runtime_error("Metal: truncated texture");
        UploadMetalMipLevel(result, uploader, info, baseMip + level, level, pixelSize, inputSize, masked);
    }
    return result;
}

[[maybe_unused]] id<MTLTexture> UploadMetalTexture(id<MTLDevice> device, const TextureInfo& info, int baseMip, bool masked)
{
    return UploadOrUpdateMetalTexture(device, nil, info, baseMip, masked);
}

float MetalGammaExponent(float brightness)
{
    return 1.0f/std::clamp(std::isfinite(brightness) ? brightness*2.0f : 1.0f,0.05f,2.99f);
}

const char* source=R"(
#include <metal_stdlib>
using namespace metal;
struct V { float4 position,color; float2 uv,lm,detail,macro; float4 fog; float clipDistance,pad0,pad1,pad2; };
struct DrawFlags { uint poly, textures; };
struct Out { float4 position [[position]]; float4 color; float2 uv,lm,detail,macro; float4 fog; float clipDistance [[clip_distance]]; };
vertex Out mainVS(uint i [[vertex_id]],const device V* v [[buffer(0)]]) {
    Out o;
    o.position=v[i].position; o.color=v[i].color; o.uv=v[i].uv; o.lm=v[i].lm;
    o.detail=v[i].detail; o.macro=v[i].macro; o.fog=v[i].fog;
    o.clipDistance=v[i].clipDistance;
    return o;
}
fragment float4 mainPS(Out v [[stage_in]],texture2d<float> tex [[texture(0)]],texture2d<float> light [[texture(1)]],texture2d<float> detail [[texture(2)]],texture2d<float> macro [[texture(3)]],sampler s [[sampler(0)]],sampler lightSampler [[sampler(1)]],constant DrawFlags& flags [[buffer(0)]]) {
    float4 c=tex.sample(s,v.uv);
    c*=v.color;
    if (flags.textures&4) c*=macro.sample(s,v.macro);
    if ((flags.poly&2) && c.a<0.5) discard_fragment();
    if (flags.textures&1) c.rgb*=clamp(light.sample(lightSampler,v.lm).rgb,0.0f,1.0f)*2.0;
    if (flags.textures&2) {
        float fade=clamp(2.0f-(1.0f/v.position.w)/380.0f,0.0f,1.0f);
        float3 detailColor=(detail.sample(s,v.detail).rgb-0.5f)*0.8f+1.0f;
        c.rgb=mix(c.rgb,c.rgb*detailColor,fade);
    }
    if (flags.textures&8) {
        float4 fog=detail.sample(lightSampler,v.detail);
        c.rgb=fog.rgb+c.rgb*(1.0f-fog.a);
    } else if (flags.textures&16) c.rgb=v.fog.rgb+c.rgb*(1.0f-v.fog.a);
    return c;
}
struct CompositeOut { float4 position [[position]]; float2 uv; };
vertex CompositeOut compositeVS(uint i [[vertex_id]]) {
    float2 uv=float2((i<<1)&2,i&2);
    return {float4(uv.x*2-1,1-uv.y*2,0,1),uv};
}
fragment float4 compositePS(CompositeOut v [[stage_in]],texture2d<float> world [[texture(0)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    return world.sample(s,v.uv);
}
fragment float4 gammaPS(CompositeOut v [[stage_in]],texture2d<float> frame [[texture(0)]],constant float& exponent [[buffer(0)]]) {
    float4 c=frame.read(uint2(v.position.xy));
    return float4(pow(clamp(c.rgb,0.0f,1.0f),float3(exponent)),c.a);
})";
class MetalRenderDevice final : public RenderDevice {
    friend struct MetalRenderChecks;
    static constexpr size_t MaxFramesInFlight = 3;
    dispatch_semaphore_t inFlightSemaphore = nullptr;
    bool frameLocked = false;
    void* framePool = nullptr;

    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLLibrary> library;
    CAMetalLayer* layer;
    id<CAMetalDrawable> drawable;
    id<MTLCommandBuffer> commands, lastSubmitted;
    std::array<FrameVertices,MaxFramesInFlight> verticesByFrame;
    size_t frameIndex=0;
    id<MTLRenderCommandEncoder> encoder;
    id<MTLTexture> depth,white,lastFrame,worldColor,worldDepth,captureTarget;
    id<MTLRenderPipelineState> compositePipeline,gammaPipeline;
    id<MTLTexture> frameColor;
    float gammaExponent=1.0f;
    bool captureReadableFrame=false;
    struct DrawBatch {
        __unsafe_unretained id<MTLBuffer> buffer = nil;
        size_t offset=0,count=0;
        uint32_t poly=0,textures=0;
        MTLPrimitiveType primitive=MTLPrimitiveTypeTriangle;
        std::array<__unsafe_unretained id<MTLTexture>,4> images{};
        __unsafe_unretained id<MTLSamplerState> sampler = nil;
        int depthBias=0;
    } batch;
    struct BoundState {
        bool valid = false;
        __unsafe_unretained id<MTLDepthStencilState> depthStencil = nil;
        uint32_t stencilRef = 0xffffffff;
        __unsafe_unretained id<MTLRenderPipelineState> pipeline = nil;
        __unsafe_unretained id<MTLBuffer> buffer = nil;
        std::array<__unsafe_unretained id<MTLTexture>,4> images{};
        __unsafe_unretained id<MTLSamplerState> sampler = nil;
        uint32_t poly = 0, textures = 0;
        int depthBias = 0;
        void reset() { *this = BoundState{}; }
    } bound;
    enum class PortalPhase : uint8_t { Scene, Mask, Unmask };
    PortalPhase portalPhase = PortalPhase::Scene;
    uint8_t stencilDepth = 0;
    size_t drawCalls=0;
    bool worldPass=false,worldRendering=false;
    id<MTLSamplerState> sampler,nearest,nearestClamp,linear,lightSampler;
    std::unordered_map<uint32_t,id<MTLRenderPipelineState>> pipelines;
    std::array<id<MTLDepthStencilState>,2> depths{};
    std::array<id<MTLDepthStencilState>,2> portalDepths{};
    id<MTLDepthStencilState> portalMaskState=nil,portalUnmaskState=nil;
    struct CachedTexture { int mip; id<MTLTexture> texture; };
    struct TextureKeyHash {
        size_t operator()(const std::pair<uint64_t,bool>& k) const noexcept {
            return std::hash<uint64_t>{}(k.first) ^ (size_t(k.second) * 0x9e3779b97f4a7c15ULL);
        }
    };
    std::unordered_map<std::pair<uint64_t,bool>,CachedTexture,TextureKeyHash> textures;
    Rect renderRect, lastFrameRect;
    mat4 transform=mat4::identity();
    vec4 clipPlane{0,0,0,1};
    SceneNode* current=nullptr;
    vec4 flashScale{},flashFog{};
    bool frameReported=false;

    id<MTLTexture> texture(TextureInfo* info,bool masked=false) {
        if (!info || !info->NumMips || !info->Mips) return white;
        if (info->Texture && (info->Texture->PolyFlags()&PF_Masked)) masked=true;
        if (info->Format!=TextureFormat::P8) masked=false;
        const int baseMip=TextureBaseMip(*info,*engine->client);
        const auto key=std::make_pair(info->CacheID,masked);
        auto found=textures.find(key);
        if (found!=textures.end() && found->second.mip==baseMip && !info->bRealtimeChanged) return found->second.texture;
        id<MTLTexture> existing = (found!=textures.end() && found->second.mip==baseMip) ? found->second.texture : nil;
        if (info->bRealtimeChanged && existing && info->UpdateWidth > 0) {
            UpdateMetalTextureRect(existing, *info, baseMip, info->UpdateX, info->UpdateY, info->UpdateWidth, info->UpdateHeight, masked);
            info->bRealtimeChanged = false;
            return existing;
        }
        auto result=UploadOrUpdateMetalTexture(device,existing,*info,baseMip,masked);
        info->bRealtimeChanged = false;
        textures[key]={baseMip,result};
        return result;
    }
    id<MTLRenderPipelineState> pipeline(uint32_t flags) {
        const uint32_t key=flags&(PF_Invisible|PF_Translucent|PF_Modulated|PF_Highlighted);
        auto found=pipelines.find(key); if (found!=pipelines.end()) return found->second;
        auto desc=[MTLRenderPipelineDescriptor new];
        desc.vertexFunction=[library newFunctionWithName:@"mainVS"];
        desc.fragmentFunction=[library newFunctionWithName:@"mainPS"];
        desc.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
        desc.stencilAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
        auto c=desc.colorAttachments[0]; c.pixelFormat=MTLPixelFormatBGRA8Unorm;
        c.writeMask=(flags&PF_Invisible) ? MTLColorWriteMaskNone : MTLColorWriteMaskAll;
        c.blendingEnabled=bool(key&(PF_Translucent|PF_Modulated|PF_Highlighted));
        c.sourceRGBBlendFactor=MTLBlendFactorOne; c.destinationRGBBlendFactor=MTLBlendFactorZero;
        if (flags&PF_Translucent) c.destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceColor;
        else if (flags&PF_Modulated) { c.sourceRGBBlendFactor=MTLBlendFactorDestinationColor; c.destinationRGBBlendFactor=MTLBlendFactorSourceColor; }
        else if (flags&PF_Highlighted) c.destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
        c.sourceAlphaBlendFactor=c.sourceRGBBlendFactor; c.destinationAlphaBlendFactor=c.destinationRGBBlendFactor;
        NSError* error=nil; auto result=[device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!result) throw std::runtime_error(error.localizedDescription.UTF8String);
        pipelines[key]=result; return result;
    }
    id<MTLTexture> presentTarget() const {
        return captureReadableFrame ? captureTarget : drawable.texture;
    }
    void beginPass(bool clearColor,bool clearDepth,vec4 color={},bool clearStencil=false) {
        auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=worldPass ? worldColor : gammaExponent!=1.0f ? frameColor : presentTarget();
        pass.colorAttachments[0].loadAction=clearColor ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        pass.colorAttachments[0].clearColor=MTLClearColorMake(color.x,color.y,color.z,color.w);
        id<MTLTexture> dsTex=worldPass ? worldDepth : depth;
        pass.depthAttachment.texture=dsTex;
        pass.depthAttachment.loadAction=clearDepth ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.depthAttachment.storeAction=MTLStoreActionDontCare; pass.depthAttachment.clearDepth=1;
        pass.stencilAttachment.texture=dsTex;
        pass.stencilAttachment.loadAction=clearStencil ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.stencilAttachment.storeAction=MTLStoreActionStore; pass.stencilAttachment.clearStencil=0;
        encoder=[commands renderCommandEncoderWithDescriptor:pass];
        [encoder setCullMode:MTLCullModeNone];
        [encoder setFragmentSamplerState:lightSampler atIndex:1];
        bound.reset();
        if (current) SetSceneNode(current);
    }
    void flushDraws() {
        if (!batch.count) return;
        const bool writes=!(batch.poly&(PF_Translucent|PF_Modulated)) || (batch.poly&PF_Occlude);
        id<MTLRenderPipelineState> pipe=pipeline(batch.poly);
        id<MTLDepthStencilState> dsState=nil;
        uint32_t ref=0;
        if (portalPhase==PortalPhase::Mask) { dsState=portalMaskState; ref=stencilDepth; }
        else if (portalPhase==PortalPhase::Unmask) { dsState=portalUnmaskState; ref=stencilDepth; }
        else if (stencilDepth>0) { dsState=portalDepths[writes ? 1 : 0]; ref=stencilDepth; }
        else { dsState=depths[writes ? 1 : 0]; }
        if (!bound.valid || bound.depthStencil!=dsState) {
            [encoder setDepthStencilState:dsState];
            bound.depthStencil=dsState;
        }
        if (!bound.valid || bound.stencilRef!=ref) {
            [encoder setStencilReferenceValue:ref];
            bound.stencilRef=ref;
        }
        if (!bound.valid || bound.buffer!=batch.buffer) {
            [encoder setVertexBuffer:batch.buffer offset:batch.offset atIndex:0];
            bound.buffer=batch.buffer;
        } else {
            [encoder setVertexBufferOffset:batch.offset atIndex:0];
        }
        for (size_t i=0;i<batch.images.size();++i) {
            if (!bound.valid || bound.images[i]!=batch.images[i]) {
                [encoder setFragmentTexture:batch.images[i] atIndex:i];
                bound.images[i]=batch.images[i];
            }
        }
        if (!bound.valid || bound.poly!=batch.poly || bound.textures!=batch.textures) {
            DrawFlags flags{batch.poly,batch.textures};
            [encoder setFragmentBytes:&flags length:sizeof(flags) atIndex:0];
            bound.poly=batch.poly;
            bound.textures=batch.textures;
        }
        if (!bound.valid || bound.sampler!=batch.sampler) {
            [encoder setFragmentSamplerState:batch.sampler atIndex:0];
            bound.sampler=batch.sampler;
        }
        if (!bound.valid || bound.pipeline!=pipe) {
            [encoder setRenderPipelineState:pipe];
            bound.pipeline=pipe;
        }
        if (!bound.valid || bound.depthBias!=batch.depthBias) {
            [encoder setDepthBias:float(-batch.depthBias) slopeScale:float(-batch.depthBias) clamp:0.0f];
            bound.depthBias=batch.depthBias;
        }
        bound.valid=true;
        [encoder drawPrimitives:batch.primitive vertexStart:0 vertexCount:batch.count];
        ++drawCalls; batch=DrawBatch{};
    }
    Vertex* reserveDraw(size_t count,TextureInfo* tex,TextureInfo* lm,uint32_t flags,MTLPrimitiveType primitive=MTLPrimitiveTypeTriangle,TextureInfo* detail=nullptr,TextureInfo* macro=nullptr,bool fogMap=false,bool meshFog=false,bool smoothWorld=true,int depthBias=0,bool clamp=false) {
        if (!encoder || !count) return nullptr;
        if (count>device.maxBufferLength/sizeof(Vertex)) throw std::runtime_error("Metal: too many vertices");
        const bool masked=(flags&PF_Masked)!=0;
        flags=ApplyPrecedenceRules(flags);
        if (portalPhase!=PortalPhase::Scene) flags=(flags&~PF_Occlude)|PF_Invisible;
        std::array<__unsafe_unretained id<MTLTexture>,4> images={texture(tex,masked),texture(lm),texture(detail),texture(macro)};
        const uint32_t textureFlags=(lm ? 1u : 0u) | (detail ? (fogMap ? 8u : 2u) : 0u) | (macro ? 4u : 0u) | (meshFog ? 16u : 0u);
        __unsafe_unretained id<MTLSamplerState> selected=(flags&PF_NoSmooth) ? (clamp ? nearestClamp : nearest) : clamp ? lightSampler : smoothWorld ? sampler : linear;
        auto [buffer,offset]=verticesByFrame[frameIndex].reserve(device,count*sizeof(Vertex));
        // Only adjacent draws merge; never sort transparent geometry or cross a state boundary.
        if (batch.count && (batch.poly!=flags || batch.textures!=textureFlags || batch.primitive!=primitive || batch.images!=images || batch.sampler!=selected || batch.depthBias!=depthBias || batch.buffer!=buffer || batch.offset+batch.count*sizeof(Vertex)!=offset)) flushDraws();
        if (!batch.count) batch={buffer,offset,0,flags,textureFlags,primitive,images,selected,depthBias};
        batch.count+=count;
        return reinterpret_cast<Vertex*>(static_cast<uint8_t*>(buffer.contents)+offset);
    }
    void prepareFrameColor(id<MTLTexture> target) {
        gammaExponent=MetalGammaExponent(Brightness);
        drawCalls=0;
        if (gammaExponent!=1.0f && (!frameColor || frameColor.width!=target.width || frameColor.height!=target.height)) {
            auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:layer.pixelFormat width:target.width height:target.height mipmapped:NO];
            desc.storageMode=MTLStorageModePrivate; desc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
            frameColor=[device newTextureWithDescriptor:desc];
            if (!frameColor) throw std::runtime_error("Metal: gamma target allocation failed");
        }
    }
    void applyGamma() {
        if (gammaExponent==1.0f) return;
        auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=presentTarget();
        pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        auto output=[commands renderCommandEncoderWithDescriptor:pass];
        [output setRenderPipelineState:gammaPipeline];
        [output setFragmentTexture:frameColor atIndex:0];
        [output setFragmentBytes:&gammaExponent length:sizeof(gammaExponent) atIndex:0];
        [output drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [output endEncoding];
    }
    vec4 screen(const SceneNode* frame,float x,float y,float z) const {
        const SceneNode* node=frame ? frame : current;
        if (!node) throw std::runtime_error("Metal: no scene node");
        return {2*x/node->FX-1,1-2*y/node->FY,std::clamp(z/32768.0f,0.0f,1.0f),1};
    }
    explicit MetalRenderDevice(CAMetalLayer* nativeLayer) {
        GLTextureUploader::SetS3TCSupported(false);
        layer=nativeLayer;
        if (!layer) throw std::runtime_error("Metal: no native layer");
        device=layer.device ?: MTLCreateSystemDefaultDevice(); layer.device=device;
        layer.pixelFormat=MTLPixelFormatBGRA8Unorm; layer.framebufferOnly=YES; layer.opaque=YES;
        layer.maximumDrawableCount=MaxFramesInFlight;
        inFlightSemaphore=dispatch_semaphore_create(MaxFramesInFlight);
        queue=[device newCommandQueue];
        NSError* error=nil; library=[device newLibraryWithSource:[NSString stringWithUTF8String:source] options:nil error:&error];
        if (!library) throw std::runtime_error(error.localizedDescription.UTF8String);
        auto sd=[MTLSamplerDescriptor new]; sd.sAddressMode=sd.tAddressMode=MTLSamplerAddressModeRepeat;
        sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear; linear=[device newSamplerStateWithDescriptor:sd];
        sd.mipFilter=MTLSamplerMipFilterLinear; sd.maxAnisotropy=8; sampler=[device newSamplerStateWithDescriptor:sd];
        sd.mipFilter=MTLSamplerMipFilterNotMipmapped; sd.maxAnisotropy=1;
        sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterNearest; nearest=[device newSamplerStateWithDescriptor:sd];
        sd.sAddressMode=sd.tAddressMode=MTLSamplerAddressModeClampToEdge;
        nearestClamp=[device newSamplerStateWithDescriptor:sd];
        sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear;
        lightSampler=[device newSamplerStateWithDescriptor:sd];
        auto composite=[MTLRenderPipelineDescriptor new];
        composite.vertexFunction=[library newFunctionWithName:@"compositeVS"];
        composite.fragmentFunction=[library newFunctionWithName:@"compositePS"];
        composite.colorAttachments[0].pixelFormat=layer.pixelFormat;
        composite.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
        composite.stencilAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
        compositePipeline=[device newRenderPipelineStateWithDescriptor:composite error:&error];
        if (!compositePipeline) throw std::runtime_error(error.localizedDescription.UTF8String);
        composite.fragmentFunction=[library newFunctionWithName:@"gammaPS"];
        composite.depthAttachmentPixelFormat=MTLPixelFormatInvalid;
        composite.stencilAttachmentPixelFormat=MTLPixelFormatInvalid;
        gammaPipeline=[device newRenderPipelineStateWithDescriptor:composite error:&error];
        if (!gammaPipeline) throw std::runtime_error(error.localizedDescription.UTF8String);
        for (bool write:{false,true}) {
            auto d=[MTLDepthStencilDescriptor new]; d.depthCompareFunction=MTLCompareFunctionLessEqual; d.depthWriteEnabled=write;
            depths[write ? 1 : 0]=[device newDepthStencilStateWithDescriptor:d];
            auto st=[MTLStencilDescriptor new];
            st.stencilCompareFunction=MTLCompareFunctionEqual;
            st.stencilFailureOperation=MTLStencilOperationKeep;
            st.depthFailureOperation=MTLStencilOperationKeep;
            st.depthStencilPassOperation=MTLStencilOperationKeep;
            st.readMask=0xff; st.writeMask=0x00;
            d.frontFaceStencil=st; d.backFaceStencil=st;
            portalDepths[write ? 1 : 0]=[device newDepthStencilStateWithDescriptor:d];
        }
        {
            auto d=[MTLDepthStencilDescriptor new]; d.depthCompareFunction=MTLCompareFunctionAlways; d.depthWriteEnabled=NO;
            auto st=[MTLStencilDescriptor new];
            st.stencilCompareFunction=MTLCompareFunctionEqual;
            st.stencilFailureOperation=MTLStencilOperationKeep;
            st.depthFailureOperation=MTLStencilOperationKeep;
            st.depthStencilPassOperation=MTLStencilOperationIncrementClamp;
            st.readMask=0xff; st.writeMask=0xff;
            d.frontFaceStencil=st; d.backFaceStencil=st;
            portalMaskState=[device newDepthStencilStateWithDescriptor:d];
            st.depthStencilPassOperation=MTLStencilOperationDecrementClamp;
            d.frontFaceStencil=st; d.backFaceStencil=st;
            portalUnmaskState=[device newDepthStencilStateWithDescriptor:d];
        }
        white=[device newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO]];
        uint32_t pixel=0xffffffff; [white replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&pixel bytesPerRow:4];
        fprintf(stderr,"Native ARM64 Metal backend: %s\n",device.name.UTF8String);
    }
public:
    explicit MetalRenderDevice(Widget* viewport) : MetalRenderDevice((__bridge CAMetalLayer*)static_cast<CocoaNativeHandle*>(viewport->GetNativeHandle())->metalLayer) {
        Viewport=viewport;
    }
    ~MetalRenderDevice() override {
        if (inFlightSemaphore) {
            for (size_t i = 0; i < MaxFramesInFlight; ++i) {
                dispatch_semaphore_wait(inFlightSemaphore, DISPATCH_TIME_FOREVER);
            }
            for (size_t i = 0; i < MaxFramesInFlight; ++i) {
                dispatch_semaphore_signal(inFlightSemaphore);
            }
        }
    }
    void Flush(bool) override { flushDraws(); textures.clear(); }
    void Lock(vec4 scale,vec4 fog,vec4 clear) override {
        framePool=objc_autoreleasePoolPush();
        flashScale=scale;flashFog=fog;
        worldPass=worldRendering=false;
        renderRect=engine->window->GetRenderRect();
        CGSize targetSize=CGSizeMake(std::max(1,engine->window->GetNativePixelWidth()),std::max(1,engine->window->GetNativePixelHeight()));
        if (layer.drawableSize.width!=targetSize.width || layer.drawableSize.height!=targetSize.height) {
            layer.drawableSize=targetSize;
        }
        dispatch_semaphore_wait(inFlightSemaphore, DISPATCH_TIME_FOREVER);
        frameLocked=true;
        verticesByFrame[frameIndex].reset();
        id<MTLTexture> t = nil;
        if (captureReadableFrame) {
            NSUInteger w = std::max<NSUInteger>(1, NSUInteger(targetSize.width));
            NSUInteger h = std::max<NSUInteger>(1, NSUInteger(targetSize.height));
            if (!captureTarget || captureTarget.width!=w || captureTarget.height!=h) {
                auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:layer.pixelFormat width:w height:h mipmapped:NO];
                desc.storageMode=MTLStorageModeShared;
                desc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
                captureTarget=[device newTextureWithDescriptor:desc];
            }
            t = captureTarget;
        } else {
            drawable=[layer nextDrawable];
            t = drawable ? drawable.texture : nil;
        }
        if (!t) {
            frameLocked=false;
            dispatch_semaphore_signal(inFlightSemaphore);
            if (framePool) { objc_autoreleasePoolPop(framePool); framePool=nullptr; }
            return;
        }
        if (!depth || depth.width!=t.width || depth.height!=t.height) {
            auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:t.width height:t.height mipmapped:NO];
            desc.storageMode=MTLStorageModePrivate; desc.usage=MTLTextureUsageRenderTarget; depth=[device newTextureWithDescriptor:desc];
        }
        prepareFrameColor(t);
        commands=[queue commandBuffer]; current=nullptr; clipPlane={0,0,0,1}; portalPhase=PortalPhase::Scene; stencilDepth=0;
        beginPass(true,true,engine->classicAspectRatio ? vec4(0,0,0,1) : clear,true);
    }
    void Unlock(bool blit) override {
        if (!commands) {
            if (framePool) { objc_autoreleasePoolPop(framePool); framePool=nullptr; }
            return;
        }
        flushDraws();
        [encoder endEncoding]; encoder=nil;
        applyGamma();
        id<MTLTexture> target = presentTarget();
        lastFrame=captureReadableFrame ? captureTarget : nil; lastFrameRect=renderRect;
        lastSubmitted = commands;
        if (frameLocked) {
            frameLocked = false;
            dispatch_semaphore_t sem = inFlightSemaphore;
            [commands addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
                if (buffer.error) {
                    fprintf(stderr,"Metal error: %s\n",buffer.error.localizedDescription.UTF8String);
                }
                dispatch_semaphore_signal(sem);
            }];
        }
        if (blit && drawable) [commands presentDrawable:drawable];
        [commands commit];
        frameIndex=(frameIndex+1)%MaxFramesInFlight;
        if (!frameReported) {
            fprintf(stderr,"Metal frame submitted: %lux%lu; triple-buffered display sync; %zu GPU frames in flight\n",(unsigned long)target.width,(unsigned long)target.height,MaxFramesInFlight);
            frameReported=true;
        }
        commands=nil;drawable=nil;current=nullptr;
        if (framePool) {
            objc_autoreleasePoolPop(framePool);
            framePool=nullptr;
        }
    }
    void BeginWorld() override {
        worldRendering=true;
        if (!encoder || engine->renderScale>=1.0f) return;
        flushDraws();
        [encoder endEncoding]; encoder=nil;
        int width=std::max(1,int(std::round(renderRect.width*engine->renderScale)));
        int height=std::max(1,int(std::round(renderRect.height*engine->renderScale)));
        if (!worldColor || worldColor.width!=width || worldColor.height!=height) {
            auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:layer.pixelFormat width:width height:height mipmapped:NO];
            desc.storageMode=MTLStorageModePrivate; desc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
            worldColor=[device newTextureWithDescriptor:desc];
            desc.pixelFormat=MTLPixelFormatDepth32Float_Stencil8; desc.usage=MTLTextureUsageRenderTarget;
            worldDepth=[device newTextureWithDescriptor:desc];
            if (!worldColor || !worldDepth) throw std::runtime_error("Metal: world target allocation failed");
        }
        worldPass=true; portalPhase=PortalPhase::Scene; stencilDepth=0; beginPass(true,true,vec4(0,0,0,1),true);
    }
    bool SupportsPortalMask() const override { return true; }
    void BeginPortalMask() override { flushDraws(); portalPhase=PortalPhase::Mask; }
    void BeginPortalScene() override { flushDraws(); portalPhase=PortalPhase::Scene; if (stencilDepth<255) ++stencilDepth; }
    void BeginPortalUnmask() override { flushDraws(); portalPhase=PortalPhase::Unmask; }
    void EndPortalMask() override { flushDraws(); portalPhase=PortalPhase::Scene; if (stencilDepth>0) --stencilDepth; }
    void EndWorld() override {
        worldRendering=false;
        if (!worldPass) return;
        flushDraws();
        [encoder endEncoding]; worldPass=false;
        beginPass(false,true);
        [encoder setViewport:MTLViewport{renderRect.x,renderRect.y,renderRect.width,renderRect.height,0,1}];
        [encoder setScissorRect:MTLScissorRect{NSUInteger(renderRect.x),NSUInteger(renderRect.y),NSUInteger(renderRect.width),NSUInteger(renderRect.height)}];
        [encoder setRenderPipelineState:compositePipeline];
        [encoder setDepthStencilState:depths[0]];
        bound.reset();
        [encoder setFragmentSamplerState:lightSampler atIndex:1];
        [encoder setFragmentTexture:worldColor atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        if (current) SetSceneNode(current);
    }
    void SetSceneNode(SceneNode* frame) override {
        flushDraws();
        current=frame;
        float rz=std::tan(radians(frame->FovAngle)*0.5f),aspect=frame->FY/frame->FX;
        mat4 objectToView=frame->WorldToView*frame->ObjectToWorld;
        transform=mat4::scale(1,-1,1)*PolygonShift(frame)*mat4::frustum(-rz,rz,-aspect*rz,aspect*rz,1,32768,handedness::left,clipzrange::zero_positive_w)*objectToView;
        bool mirror=frame->NearClip!=vec4(0.0f,0.0f,1.0f,-1.0f);
        clipPlane=mirror ? (mat4::transpose(objectToView)*frame->NearClip) : vec4(0.0f,0.0f,0.0f,1.0f);
        if (encoder) {
            const double sx=worldPass ? double(worldColor.width)/renderRect.width : 1.0;
            const double sy=worldPass ? double(worldColor.height)/renderRect.height : 1.0;
            const double x=worldPass ? 0 : renderRect.x, y=worldPass ? 0 : renderRect.y;
            [encoder setViewport:MTLViewport{x+frame->XB*sx,y+frame->YB*sy,frame->X*sx,frame->Y*sy,0,1}];
            [encoder setScissorRect:MTLScissorRect{NSUInteger(x),NSUInteger(y),NSUInteger(worldPass ? worldColor.width : renderRect.width),NSUInteger(worldPass ? worldColor.height : renderRect.height)}];
        }
    }
    void DrawComplexSurface(SceneNode* frame,SurfaceInfo& surface,SurfaceFacet& facet) override {
        if (facet.VertexCount<3) return;
        // VisibleBrush::Draw applies ObjectToWorld via SetSceneNode(&brushframe)
        // and then passes &frame->Frame here; only initialize if no node is bound.
        if (!current) SetSceneNode(frame);
        const bool fog=surface.FogMap && surface.FogMap->NumMips>0 && surface.FogMap->Mips && !surface.FogMap->Mips[0].Data.empty();
        TextureInfo* extra=fog ? surface.FogMap : !surface.FogMap && engine->renderdev->DetailTextures ? surface.DetailTexture : nullptr;
        Vertex* out=reserveDraw(size_t(facet.VertexCount-2)*3,surface.Texture,surface.LightMap,surface.PolyFlags,MTLPrimitiveTypeTriangle,extra,surface.MacroTexture,fog,false,true,surface.DepthBias);
        if (!out) return;
        auto vertex=[&](uint32_t i) {
            auto p=facet.Vertices[i]; auto relative=p-facet.MapCoords.Origin;
            vec2 uv{dot(facet.MapCoords.XAxis,relative),dot(facet.MapCoords.YAxis,relative)},base{},light{},detail{},macro{};
            if (surface.Texture) base={(uv.x-surface.Texture->Pan.x)*GetUMult(*surface.Texture),(uv.y-surface.Texture->Pan.y)*GetVMult(*surface.Texture)};
            if (surface.LightMap) light={(uv.x-surface.LightMap->Pan.x+0.5f*surface.LightMap->UScale)*GetUMult(*surface.LightMap),(uv.y-surface.LightMap->Pan.y+0.5f*surface.LightMap->VScale)*GetVMult(*surface.LightMap)};
            if (extra) detail={(uv.x-extra->Pan.x+(fog ? 0.5f*extra->UScale : 0))*GetUMult(*extra),(uv.y-extra->Pan.y+(fog ? 0.5f*extra->VScale : 0))*GetVMult(*extra)};
            if (surface.MacroTexture) macro={(uv.x-surface.MacroTexture->Pan.x)*GetUMult(*surface.MacroTexture),(uv.y-surface.MacroTexture->Pan.y)*GetVMult(*surface.MacroTexture)};
            vec4 pos{p,1};
            return Vertex{transform*pos,vec4(1),base,light,detail,macro,{},dot(clipPlane,pos),0,0,0};
        };
        Vertex first=vertex(0),previous=vertex(1);
        for (uint32_t i=2;i<facet.VertexCount;++i) {
            Vertex next=vertex(i); *out++=first; *out++=previous; *out++=next; previous=next;
        }
    }
    void DrawGouraudPolygon(SceneNode* frame,TextureInfo& info,const GouraudVertex* p,int count,uint32_t flags) override {
        if (count<3) return; if (!current) SetSceneNode(frame);
        const bool fog=(flags&(PF_RenderFog|PF_Translucent|PF_Modulated))==PF_RenderFog;
        Vertex* out=reserveDraw(size_t(count-2)*3,&info,nullptr,flags,MTLPrimitiveTypeTriangle,nullptr,nullptr,false,fog);
        if (!out) return;
        auto vertex=[&](int i) { vec4 pos{p[i].Point,1}; return Vertex{transform*pos,(flags&PF_Modulated) ? vec4(1) : vec4(p[i].Light,1),{p[i].UV.x*GetUMult(info),p[i].UV.y*GetVMult(info)},{},{},{},p[i].Fog,dot(clipPlane,pos),0,0,0}; };
        Vertex first=vertex(0),previous=vertex(1);
        for(int i=2;i<count;++i) {
            Vertex next=vertex(i); *out++=first; *out++=previous; *out++=next; previous=next;
        }
    }
    void DrawGouraudTriangles(SceneNode* frame,TextureInfo& info,const GouraudVertex* p,int numTris,uint32_t flags) override {
        if (numTris<=0) return; if (!current) SetSceneNode(frame);
        const bool fog=(flags&(PF_RenderFog|PF_Translucent|PF_Modulated))==PF_RenderFog;
        size_t count=size_t(numTris)*3;
        Vertex* out=reserveDraw(count,&info,nullptr,flags,MTLPrimitiveTypeTriangle,nullptr,nullptr,false,fog);
        if (!out) return;
        float um=GetUMult(info),vm=GetVMult(info);
        for(size_t i=0;i<count;++i) {
            vec4 pos{p[i].Point,1};
            out[i]=Vertex{transform*pos,(flags&PF_Modulated) ? vec4(1) : vec4(p[i].Light,1),{p[i].UV.x*um,p[i].UV.y*vm},{},{},{},p[i].Fog,dot(clipPlane,pos),0,0,0};
        }
        info.bRealtimeChanged=false;
    }
    void DrawTile(SceneNode* frame,TextureInfo& info,float x,float y,float w,float h,float u,float v,float ul,float vl,float z,vec4 color,vec4,uint32_t flags) override {
        flags=TileFlags(info,flags);
        if (!current) SetSceneNode(frame);
        if (flags&PF_Modulated) color=vec4(1);
        u*=GetUMult(info);ul*=GetUMult(info);v*=GetVMult(info);vl*=GetVMult(info);
        const bool clamp=(u>=0.0f && u+ul<=1.00001f && v>=0.0f && v+vl<=1.00001f);
        Vertex* out=reserveDraw(6,&info,nullptr,flags,MTLPrimitiveTypeTriangle,nullptr,nullptr,false,false,worldRendering,0,clamp);
        if (!out) return;
        out[0]={screen(frame,x,y,z),color,{u,v},{},{},{},{},1,0,0,0};
        out[1]={screen(frame,x+w,y,z),color,{u+ul,v},{},{},{},{},1,0,0,0};
        out[2]={screen(frame,x+w,y+h,z),color,{u+ul,v+vl},{},{},{},{},1,0,0,0};
        out[3]=out[0]; out[4]=out[2];
        out[5]={screen(frame,x,y+h,z),color,{u,v+vl},{},{},{},{},1,0,0,0};
    }
    void Draw3DLine(SceneNode* frame,vec4 color,uint32_t,vec3 a,vec3 b) override {
        if(!current) SetSceneNode(frame);
        if (auto* out=reserveDraw(2,nullptr,nullptr,PF_Highlighted,MTLPrimitiveTypeLine)) {
            vec4 pa{a,1},pb{b,1};
            out[0]={transform*pa,color,{},{},{},{},{},dot(clipPlane,pa),0,0,0};
            out[1]={transform*pb,color,{},{},{},{},{},dot(clipPlane,pb),0,0,0};
        }
    }
    void Draw2DLine(SceneNode* frame,vec4 color,uint32_t,vec3 a,vec3 b) override {
        if(!current) SetSceneNode(frame);
        if (auto* out=reserveDraw(2,nullptr,nullptr,PF_Highlighted,MTLPrimitiveTypeLine)) {
            out[0]={screen(frame,a.x,a.y,a.z),color,{},{},{},{},{},1,0,0,0};
            out[1]={screen(frame,b.x,b.y,b.z),color,{},{},{},{},{},1,0,0,0};
        }
    }
    void ClearZ() override { if(encoder) { flushDraws(); [encoder endEncoding];beginPass(false,true); } }
    void LastFrameSize(int& width,int& height) const override {
        width=lastFrame ? int(lastFrameRect.width) : 0;
        height=lastFrame ? int(lastFrameRect.height) : 0;
    }
    bool NeedsReadableFrameForReadPixels() const override {
        return !lastFrame || lastFrame.framebufferOnly;
    }
    void SetCaptureReadableFrame(bool enable) override {
        captureReadableFrame = enable;
    }
    void ReadPixels(TextureColor* pixels) override {
        if (!lastFrame || !pixels || lastFrame.framebufferOnly) return;
        if (lastSubmitted) {
            [lastSubmitted waitUntilCompleted];
            if (lastSubmitted.error) throw std::runtime_error(lastSubmitted.error.localizedDescription.UTF8String);
        }
        [lastFrame getBytes:pixels bytesPerRow:NSUInteger(lastFrameRect.width)*4 fromRegion:MTLRegionMake2D(lastFrameRect.x,lastFrameRect.y,lastFrameRect.width,lastFrameRect.height) mipmapLevel:0];
        for(size_t i=0;i<size_t(lastFrameRect.width)*size_t(lastFrameRect.height);++i) std::swap(pixels[i].R,pixels[i].B);
        if (lastFrame == captureTarget) {
            lastFrame = nil;
            captureTarget = nil;
        }
    }
    void EndFlash() override {
        if(!current || (flashScale==vec4(0.5f,0.5f,0.5f,0) && flashFog==vec4(0))) return;
        TextureInfo empty;vec4 color{flashFog.x,flashFog.y,flashFog.z,1-std::min(flashScale.x*2,1.0f)};
        DrawTile(current,empty,0,0,current->FX,current->FY,0,0,1,1,0,color,{},PF_Highlighted);
    }
    void PrecacheTexture(TextureInfo& info,uint32_t flags) override { texture(&info,flags&PF_Masked); }
    bool SupportsTextureFormat(TextureFormat f) override { auto u=GLTextureUploader::GetUploader(f);return u && (u->GetInternalformat()==GL_RGBA8 || u->GetInternalformat()==GL_RGBA32F); }
    void UpdateTextureRect(TextureInfo& info,int,int,int,int) override { flushDraws(); textures.erase({info.CacheID,false});textures.erase({info.CacheID,true}); }
};
}
std::unique_ptr<RenderDevice> CreateMetalRenderDevice(Widget* viewport) { return std::make_unique<MetalRenderDevice>(viewport); }
